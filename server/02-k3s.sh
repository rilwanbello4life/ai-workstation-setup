#!/usr/bin/env bash
# Phase 13 - k3s: a real Kubernetes cluster on one node, without the overhead.
#
# Why k3s rather than kubeadm or microk8s:
#   * one binary, ~1.5 GB resident for the whole control plane
#   * CNCF-certified Kubernetes, so manifests and kubectl behave normally
#   * bundles Traefik, CoreDNS and a local-path storage class
#   * kubeadm on a single node spends several GB to achieve the same thing
#
# What this does NOT do: run the models. Strata mlocks 25-30 GB, owns the GPU
# and takes 1-3 minutes to load. It stays on the host, and pods reach it
# through a Service with hand-written Endpoints. See:
#   reference/kubernetes.md
#   reference/server-architecture.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

SKIP_GPU=no
while (( $# )); do
    case "$1" in
        --skip-gpu) SKIP_GPU=yes; shift ;;
        -y|--yes)   shift ;;
        -h|--help)  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
section "Prerequisites"

[[ -x /usr/local/bin/ai-pause ]] || warn "ai-pause missing - run ./01-server-base.sh --apply first."

# 01-server-base.sh creates $SRV_ROOT and chowns it to you; the PersistentVolumes
# later in this script bind to directories inside $PLATFORM_DIR and are created
# here as your user, not with sudo.
#
# This was a warning once, and that was wrong. Without 01 the script installs
# k3s, configures kubectl, sets up the GPU runtime and the namespaces, and only
# then dies on "mkdir: Permission denied" against /srv - leaving a cluster with
# no storage, no host-model bridge and no loopback forwarding, from an error
# that names neither the cause nor the fix. Check it before anything is changed.
if [[ ! -d "$PLATFORM_DIR" ]]; then
    err "$PLATFORM_DIR does not exist."
    die "Run ./01-server-base.sh --apply first; it creates $SRV_ROOT and gives it to you."
fi
if [[ ! -w "$PLATFORM_DIR" ]]; then
    err "$PLATFORM_DIR exists but is not writable by $USER."
    die "Fix with: sudo chown -R $USER:$USER $SRV_ROOT"
fi
ok "$PLATFORM_DIR is present and writable."

if ! have nvidia-smi; then
    warn "nvidia-smi not found. GPU workloads in the cluster will not work."
    SKIP_GPU=yes
fi

ram="$(ram_gb)"
info "System RAM: ${ram} GB usable"
info "k3s itself will hold roughly 1.5 GB."

# ---------------------------------------------------------------------------
section "Installing k3s"

if have k3s && systemctl is-active --quiet k3s; then
    ok "k3s already running: $(k3s --version | head -n1)"
else
    info "Installing k3s."
    # --write-kubeconfig-mode 644 avoids needing sudo for every kubectl call.
    # Traefik stays enabled: it is the ingress controller for the apps.
    # servicelb stays too; it is how game servers get LoadBalancer ports.
    # The eviction threshold must be quoted: the '<' is part of the kubelet
    # flag value, not a shell redirect.
    #
    # --node-ip is pinned rather than auto-detected. See lan_ip() in
    # common.sh: with Tailscale installed, k3s can register the node under
    # its 100.x address, which is absent from the kubelet serving
    # certificate and breaks logs, exec and port-forward.
    node_ip_args=()
    if NODE_IP="$(lan_ip)"; then
        info "Pinning the node IP to $NODE_IP."
        node_ip_args=(--node-ip "$NODE_IP")
    else
        warn "Could not determine a LAN address; letting k3s choose."
        warn "If kubectl logs later fails on a certificate, re-run this script."
    fi

    curl -sfL https://get.k3s.io | sudo sh -s - server \
        --write-kubeconfig-mode 644 \
        --disable-cloud-controller \
        ${node_ip_args[@]+"${node_ip_args[@]}"} \
        '--kubelet-arg=eviction-hard=memory.available<1Gi' \
        '--kubelet-arg=system-reserved=memory=2Gi'
    ok "k3s installed."
fi

# Repair an existing node whose address moved after the certificate was
# issued - the usual cause is Tailscale coming up between two k3s starts.
# k3s regenerates the serving certificate from the current addresses when
# it is missing, so removing it is the whole fix.
if have openssl && [[ -f /var/lib/rancher/k3s/agent/serving-kubelet.crt ]]; then
    cur_ip="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    if [[ -n "$cur_ip" ]] && ! sudo openssl x509 -in /var/lib/rancher/k3s/agent/serving-kubelet.crt \
            -noout -text 2>/dev/null | grep -q "IP Address:${cur_ip}\b"; then
        warn "The kubelet certificate does not cover the node address ${cur_ip}."
        warn "kubectl logs, exec and port-forward would fail against it."
        info "Removing the stale certificate so k3s reissues it."
        sudo systemctl stop k3s
        sudo rm -f /var/lib/rancher/k3s/agent/serving-kubelet.crt \
                   /var/lib/rancher/k3s/agent/serving-kubelet.key
        sudo systemctl start k3s
        kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null 2>&1 || true
        ok "Certificate reissued for ${cur_ip}."
    fi
fi

# --kubelet-arg above is the important part. Default eviction thresholds are
# generous, and on a box where Strata can take 45 GB in a minute the kubelet
# must give up memory early rather than let the kernel OOM-kill k3s itself.

# ---------------------------------------------------------------------------
section "kubectl configuration"

mkdir -p "$HOME/.kube"
if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    sudo cat /etc/rancher/k3s/k3s.yaml > "$HOME/.kube/config"
    chmod 600 "$HOME/.kube/config"
    ok "Wrote $HOME/.kube/config"
else
    die "/etc/rancher/k3s/k3s.yaml not found - did k3s start?"
fi

# Make KUBECONFIG permanent for interactive shells.
if ! grep -q 'KUBECONFIG' "$HOME/.profile" 2>/dev/null; then
    cat >> "$HOME/.profile" <<'EOF'

# k3s cluster access (added by server/02-k3s.sh)
export KUBECONFIG="$HOME/.kube/config"
EOF
    info "Added KUBECONFIG to ~/.profile"
fi

info "Waiting for the node to become Ready."
for _ in $(seq 1 60); do
    kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
    sleep 2
done
kubectl get nodes | sed 's/^/    /'

# ---------------------------------------------------------------------------
section "GPU support in the cluster"

if [[ "$SKIP_GPU" == yes ]]; then
    warn "Skipping GPU setup."
else
    # The container toolkit lets containerd hand the card to a container.
    # k3s ships its own containerd, so the toolkit must write into k3s's
    # config template rather than /etc/containerd.
    if dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
        ok "nvidia-container-toolkit already installed."
    else
        info "Installing nvidia-container-toolkit."
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
            sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y nvidia-container-toolkit
        ok "Installed."
    fi

    # k3s auto-detects the nvidia runtime at startup and writes a
    # RuntimeClass-compatible containerd config. Restart so it notices.
    info "Restarting k3s so containerd picks up the nvidia runtime."
    sudo systemctl restart k3s
    for _ in $(seq 1 60); do
        kubectl get nodes >/dev/null 2>&1 && break
        sleep 2
    done

    if sudo grep -q 'nvidia' /var/lib/rancher/k3s/agent/etc/containerd/config.toml 2>/dev/null; then
        ok "containerd has the nvidia runtime."
    else
        warn "containerd did not pick up the nvidia runtime."
        warn "Check: sudo grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml"
    fi

    apply_manifest "$K8S_DIR/00-runtimeclass.yaml"
    ok "RuntimeClass 'nvidia' created."

    cat <<'EOF'

  Important: this does NOT make the GPU shareable. The device plugin hands the
  whole card to one pod. Nothing else schedules against it while that pod runs,
  and Strata on the host is already using it. Request the GPU in a pod only
  for batch work, after ai-pause.

EOF
fi

# ---------------------------------------------------------------------------
section "Namespaces and storage"

apply_manifest "$K8S_DIR/01-namespaces.yaml"
ok "Namespaces: $K8S_NS, $GAMES_NS"

kubectl get storageclass | sed 's/^/    /'
info "local-path provisions under /var/lib/rancher/k3s/storage."

# Persistent data belongs on /srv so it is one backup target and survives a
# cluster rebuild. These PVs bind to directories 01-server-base.sh created.
mkdir -p "$PLATFORM_DIR"/{postgres,n8n,litellm,openwebui}
apply_manifest "$K8S_DIR/02-storage.yaml"
ok "PersistentVolumes bound to $PLATFORM_DIR."

# ---------------------------------------------------------------------------
section "Host model bridge"

# Pods need a stable name for services running on the host. A Service with no
# selector plus hand-written EndpointSlices does this without hairpinning
# through an ingress or hardcoding an IP into every workload.
#
# The host IP as seen from pods is the cni0 gateway, normally 10.42.0.1.
HOST_IP="$(ip -4 addr show cni0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
if [[ -z "$HOST_IP" ]]; then
    HOST_IP="10.42.0.1"
    warn "cni0 has no address yet; assuming $HOST_IP."
fi
info "Pods will reach the host at $HOST_IP"

export HOST_IP
apply_manifest "$K8S_DIR/03-host-models.yaml"

ok "Created in-cluster names for the host services:"
cat <<EOF
      http://strata.${K8S_NS}.svc.cluster.local:8080/v1
      http://llamacpp.${K8S_NS}.svc.cluster.local:8081/v1
      http://voice.${K8S_NS}.svc.cluster.local:8100/v1
EOF

# Strata binds to 127.0.0.1 only, so pods cannot actually reach it yet. Rather
# than rebinding it to 0.0.0.0 - which would expose it to the LAN - forward
# just the cni0 address into loopback.
section "Loopback forwarding"

FWD_UNIT=/etc/systemd/system/ai-model-bridge.service
if [[ -f "$FWD_UNIT" ]]; then
    ok "ai-model-bridge already installed."
else
    info "Installing a socat bridge from $HOST_IP to 127.0.0.1."
    sudo apt-get install -y socat >/dev/null

    sudo tee "$FWD_UNIT" >/dev/null <<EOF
[Unit]
Description=Forward cluster-facing ports to loopback model servers
After=k3s.service
Wants=k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
# One socat per port. Binding only to the cni0 address keeps these services
# invisible to the LAN while letting pods reach them.
ExecStart=/bin/sh -c '\
  socat TCP-LISTEN:8080,bind=$HOST_IP,fork,reuseaddr TCP:127.0.0.1:8080 & \
  socat TCP-LISTEN:8081,bind=$HOST_IP,fork,reuseaddr TCP:127.0.0.1:8081 & \
  socat TCP-LISTEN:8100,bind=$HOST_IP,fork,reuseaddr TCP:127.0.0.1:8100 & \
  wait'
ExecStop=/usr/bin/pkill -f "socat TCP-LISTEN:80(80|81)|socat TCP-LISTEN:8100"

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now ai-model-bridge.service
    ok "Bridge active on $HOST_IP ports 8080, 8081, 8100."
fi

# ---------------------------------------------------------------------------
section "Verification"

kubectl get pods -A --no-headers | sed 's/^/    /'

echo
ok "Cluster is up."
cat <<'EOF'

  Useful commands:

      kubectl get pods -A              everything running
      kubectl get svc -A               every service and its cluster IP
      k3s crictl rmi --prune           reclaim space from old images
      sudo systemctl status k3s        the control plane itself

  Memory note: k3s holds ~1.5 GB. ai-pause --cluster stops it entirely when
  you need that back for a large model or a game.

  Next: ./03-platform.sh
EOF
