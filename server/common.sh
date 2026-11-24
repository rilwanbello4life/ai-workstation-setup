#!/usr/bin/env bash
# Shared helpers for the server platform scripts. Sourced, not executed.
#
# Builds on ubuntu/common.sh rather than duplicating it, so AI_ROOT, the
# logging helpers and confirm() behave identically on both sides.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../ubuntu" && pwd)/common.sh"

# Platform state lives outside $HOME so a user-account problem cannot take the
# cluster's data with it, and so backups can target one path.
export SRV_ROOT="${SRV_ROOT:-/srv}"
export PLATFORM_DIR="${PLATFORM_DIR:-$SRV_ROOT/platform}"
export GAMES_DIR="${GAMES_DIR:-$SRV_ROOT/games}"
export BACKUP_DIR="${BACKUP_DIR:-$SRV_ROOT/backups}"

# Every platform workload lives in one namespace so ai-pause can scale the lot.
export K8S_NS="${K8S_NS:-platform}"
export GAMES_NS="${GAMES_NS:-games}"

# Manifests shipped with this kit.
export K8S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/k8s"

# k3s writes a root-only kubeconfig. The scripts copy it to the user's config
# so kubectl works without sudo; this is the path they agree on.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

require_k3s() {
    have kubectl || die "kubectl not found. Run ./02-k3s.sh first."
    kubectl get nodes >/dev/null 2>&1 || \
        die "Cannot reach the cluster. Is k3s running? systemctl status k3s"
}

# Phase 13 creates the PersistentVolumes the platform workloads claim. Without
# them a deployment applies cleanly and then sits Pending forever on a missing
# PVC, which reads as "the image is slow" rather than "storage is absent".
require_platform_storage() {
    local missing=()
    local pvc
    for pvc in postgres-data n8n-data openwebui-data; do
        kubectl -n "$K8S_NS" get pvc "$pvc" >/dev/null 2>&1 || missing+=("$pvc")
    done
    (( ${#missing[@]} == 0 )) && return 0
    err "Missing PersistentVolumeClaims in $K8S_NS: ${missing[*]}"
    err "Phase 13 did not finish - it applies k8s/02-storage.yaml."
    die "Run ./02-k3s.sh first, then this script again."
}

# The IPv4 address k3s should call this node.
#
# Left to itself k3s inspects the interfaces at startup and can choose the
# Tailscale 100.64.0.0/10 address. That address is not in the kubelet serving
# certificate, so afterwards every 'kubectl logs', 'exec' and 'port-forward'
# fails with "certificate is valid for ... not 100.x.x.x" while the cluster
# otherwise looks healthy. Taking the address on the default route, with any
# tailscale interface excluded, keeps the node IP the same whether or not the
# tailnet happens to be up.
lan_ip() {
    local dev ip
    # Read the token after "dev" rather than a fixed column: a default route
    # can be written "default via GW dev IF ..." or "default dev IF table N",
    # and the interface is in a different position in each.
    dev="$(ip -4 route show default 2>/dev/null | awk '
        { d = ""
          for (i = 1; i <= NF; i++) if ($i == "dev") d = $(i + 1)
          if (d != "" && d !~ /^tailscale/) { print d; exit } }')"
    [[ -n "$dev" ]] || return 1
    ip="$(ip -4 addr show "$dev" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
    [[ -n "$ip" ]] || return 1
    echo "$ip"
}

# Total RAM in GiB. MemTotal is in KiB and excludes firmware-reserved memory,
# so a 64 GB machine reports about 62. Callers must allow for that.
ram_gb() {
    echo $(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
}

# ---------------------------------------------------------------------------
# The host side of the cluster bridge.
#
# Pods reach host services by dialing unix sockets in /run/ai-model-bridge.
# The unit ai-model-bridge.service v2 owns those sockets - one socat per
# line of /etc/ai-model-bridge/services, each "name port" exposing
# /run/ai-model-bridge/<name>.sock forwarded to 127.0.0.1 - and the
# host-model-proxy DaemonSet in server/k8s/03-host-models.yaml dials them
# from inside the cluster. No host address and no cluster address appear
# anywhere, so nothing here depends on the pod CIDR k3s happened to pick.
#
# The port list lives in a data file, not in ExecStart, on purpose. The
# previous design had each script rewrite the unit to add its own ports:
# 02-k3s.sh wrote three, 09-gpu-queue.sh rewrote the file to five, and
# whichever ran last silently owned the truth. Appending a line has exactly
# one winner.
HOST_BRIDGE_DIR=/etc/ai-model-bridge
HOST_BRIDGE_LIST=$HOST_BRIDGE_DIR/services
HOST_BRIDGE_UNIT=/etc/systemd/system/ai-model-bridge.service
HOST_BRIDGE_MARK="ai-model-bridge v2"

# Register one host service with the bridge: append (or correct) its line in
# the port list, install the v2 unit if this box still has v1 or nothing,
# and restart if anything changed. Idempotent; safe from any script.
host_model_bridge_add() {
    local name="$1" port="$2" changed=no

    [[ -n "$name" && -n "$port" ]] || die "host_model_bridge_add needs a name and a port"
    have socat || { info "Installing socat."; sudo apt-get install -y socat >/dev/null; }
    sudo mkdir -p "$HOST_BRIDGE_DIR"

    if grep -qE "^${name}[[:space:]]" "$HOST_BRIDGE_LIST" 2>/dev/null; then
        if [[ "$(grep -E "^${name}[[:space:]]" "$HOST_BRIDGE_LIST")" != "$name $port" ]]; then
            sudo sed -i "s|^${name}[[:space:]].*|${name} ${port}|" "$HOST_BRIDGE_LIST"
            changed=yes
        fi
    else
        printf '%s %s\n' "$name" "$port" | sudo tee -a "$HOST_BRIDGE_LIST" >/dev/null
        changed=yes
    fi

    if [[ -f "$HOST_BRIDGE_UNIT" ]] && grep -q "$HOST_BRIDGE_MARK" "$HOST_BRIDGE_UNIT"; then
        if [[ "$changed" == yes ]]; then
            sudo systemctl restart ai-model-bridge.service
            ok "Bridge now forwards $name on port $port."
        else
            ok "Bridge already forwards $name on port $port."
        fi
        return 0
    fi

    # Either nothing is installed or the box still has v1: write v2 over
    # whatever is there. v1 bound socats to the cni0 address and was
    # Type=oneshot, so a unit whose every socat failed to bind exited 0 and
    # sat "active" with nothing listening - the exact failure this replaces.
    info "Installing ai-model-bridge v2 (unix-socket bridge)."
    sudo tee "$HOST_BRIDGE_UNIT" >/dev/null <<'UNIT_EOF'
[Unit]
# ai-model-bridge v2
Description=Expose host loopback services to the cluster over unix sockets
After=k3s.service
Wants=k3s.service

[Service]
# Type=simple, and the shell exits as soon as any socat does: systemd sees
# the truth, and Restart=always keeps trying until it is true again. v1 was
# Type=oneshot + RemainAfterExit and a shell whose socats all failed to bind
# still exited 0, so a dead bridge reported itself healthy.
Type=simple
# Creates /run/ai-model-bridge on start and removes it on stop, so stale
# sockets are never a question. 0755 so the path is readable; the sockets
# themselves are created at 0660 by socat, and the proxy pods dial them as
# root inside their own namespaces.
RuntimeDirectory=ai-model-bridge
RuntimeDirectoryMode=0755
# One socat per line of /etc/ai-model-bridge/services, "name port". Adding a
# host service appends a line to that file; nothing rewrites this unit.
# 'wait -n' returns when the first forwarder dies, the unit fails, and the
# whole set comes back under Restart=always - one dead listener is repaired
# in seconds instead of rotting quietly.
ExecStart=/bin/bash -c 'while read -r name port; do socat "UNIX-LISTEN:/run/ai-model-bridge/${name}.sock,fork,reuseaddr,mode=0660" "TCP:127.0.0.1:${port}" & done < <(grep -Ev "^[[:space:]]*(#|$)" /etc/ai-model-bridge/services); wait -n; exit 1'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
    sudo systemctl daemon-reload
    sudo systemctl enable ai-model-bridge.service >/dev/null 2>&1 || true
    sudo systemctl restart ai-model-bridge.service
    ok "Bridge active; sockets in /run/ai-model-bridge."
}

# The proxy DaemonSet only schedules on labelled nodes, so a node that runs
# no host models never grows a proxy that forwards nothing. This kit is
# single-node k3s: 'the node' and 'this machine' are the same thing, and
# head -n1 reflects that.
host_model_node_label() {
    local node
    node="$(kubectl get nodes -o name 2>/dev/null | head -n1)"
    [[ -n "$node" ]] || { warn "No cluster node to label."; return 1; }
    if kubectl label "$node" ai.workstation/host-models=true --overwrite >/dev/null 2>&1; then
        ok "Node labelled ai.workstation/host-models=true."
    else
        warn "Could not label the node; host-model-proxy will not schedule."
        return 1
    fi
}

# Delete the hand-written EndpointSlices the pre-v2 manifests created.
# Pruning is off in this pipeline, and an EndpointSlice no manifest mentions
# is not garbage-collected: it would sit beside the new pod endpoints and
# split every request between a working forwarder and the dead 10.42.0.1.
# Pass the service names being migrated; the slices were named <name>-host.
host_model_prune_slices() {
    local n
    for n in "$@"; do
        kubectl -n "$K8S_NS" delete endpointslice "${n}-host" --ignore-not-found >/dev/null 2>&1 || true
    done
}

# Apply a manifest, substituting ${VAR} references from the environment.
# Keeps credentials out of the YAML files committed to this kit.
# The host-bridge manifests no longer carry placeholders; envsubst on a
# file with none is a no-op, so the helper stays for everything else.
apply_manifest() {
    local file="$1"
    [[ -f "$file" ]] || die "Manifest not found: $file"
    envsubst < "$file" | kubectl apply -f -
}

# Wait for a Deployment to become Available, reporting rather than hanging.
wait_for_deploy() {
    local name="$1" ns="${2:-$K8S_NS}" timeout="${3:-300}"
    info "Waiting for deployment/$name in $ns (up to ${timeout}s)"
    if kubectl -n "$ns" wait --for=condition=Available \
           "deployment/$name" --timeout="${timeout}s" >/dev/null 2>&1; then
        ok "$name is ready."
        return 0
    fi
    warn "$name did not become ready in ${timeout}s."
    # Report the pod state here rather than leaving it to be looked up. A
    # deployment describe shows only the replica count, and 'logs' needs a
    # container that has actually started - neither says anything useful when
    # the pod is Pending on a missing PVC, which is the common case.
    kubectl -n "$ns" get pods -l "app=$name" \
        -o custom-columns='POD:.metadata.name,STATUS:.status.phase,REASON:.status.conditions[0].reason' \
        2>/dev/null | sed 's/^/    /' || true
    kubectl -n "$ns" describe pod -l "app=$name" 2>/dev/null \
        | sed -n '/^Events:/,$p' | head -n 12 | sed 's/^/    /' || true
    warn "In order: kubectl -n $ns describe pod -l app=$name"
    warn "          kubectl -n $ns get pvc"
    warn "          kubectl -n $ns logs deployment/$name --tail=50"
    return 1
}

export SECRETS="${SECRETS:-$PLATFORM_DIR/secrets}"

# Generate a URL-safe secret. Used for database passwords and API keys.
gen_secret() {
    openssl rand -hex "${1:-24}"
}

# Read a secret from a file, creating it on first call. Means re-running a
# script does not invalidate credentials already handed to clients.
secret_file() {
    local path="$1" bytes="${2:-24}" dir
    dir="$(dirname "$path")"
    if [[ ! -f "$path" ]]; then
        sudo mkdir -p "$dir"
        gen_secret "$bytes" | sudo tee "$path" >/dev/null
        sudo chmod 600 "$path"
    fi
    # Every run, not just on creation. mkdir -p takes the default umask, so
    # the directory lands at 755 and anyone on the machine can list which
    # credentials exist and how recently each changed. The files themselves
    # are 600, so this is not a disclosure of the secrets - but it is free
    # to close, and an existing install needs it repaired rather than
    # merely avoided next time.
    sudo chmod 700 "$dir"
    sudo cat "$path"
}
