#!/usr/bin/env bash
# Phase 22 - the code sandbox n8n's Assistant runs generated code in.
#
#   ./10-sandbox.sh            check and report, change nothing
#   ./10-sandbox.sh --apply    build the VM and wire n8n to it
#   ./10-sandbox.sh --status   what exists right now
#   ./10-sandbox.sh --destroy  remove the VM and the cluster bridge
#
# This is the only component in the kit that exists to run code written by a
# model. Everything else runs code you chose. That difference is the whole
# reason it is built the way it is, so it is worth stating plainly before the
# first line of configuration.
#
# WHY A VIRTUAL MACHINE AND NOT A POD
#
# n8n recommends running the sandbox on Kubernetes with Sysbox runners on a
# dedicated node pool. Three things rule that out here:
#
#   * Sysbox supports Ubuntu Bionic, Focal, Jammy and Noble - up to 24.04.
#     This workstation runs 26.04.
#   * k3s is not among the Kubernetes distributions Sysbox tests against,
#     and it keeps containerd's configuration under /var/lib/rancher/k3s
#     rather than the paths the installer writes to.
#   * On a cluster whose containerd predates 2.0.5, the Sysbox installer
#     replaces it with CRI-O and restarts the kubelet. On a multi-node
#     cluster that drains one node. Here it would stop Postgres, LiteLLM,
#     n8n and Argo CD simultaneously.
#
# Sysbox also wants a node with no other workloads on it, and this node holds
# the GPU, /srv, the game worlds and a home directory.
#
# A VM satisfies "dedicated host" honestly rather than by assertion, and it
# nests the two boundaries: the sandbox is isolated by Sysbox inside the VM,
# and the VM is isolated from the workstation by the hypervisor. Code that
# escapes the sandbox lands in a disposable Ubuntu image holding nothing,
# instead of on the machine with the secrets and the models. That is a
# stronger position than the Kubernetes path would have given us, not a
# compromise forced by the Ubuntu version.
#
# WHAT IT COSTS
#
# 6 GB of RAM and 4 CPUs while it runs, which at 32 GB total is not free.
# 'multipass stop n8n-sandbox' reclaims it; see --status for the current
# figure.
#
# Background: reference/troubleshooting.md and the n8n sandbox service docs
# at https://github.com/n8n-io/n8n-sandbox-service

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_not_root

VM_NAME="${SANDBOX_VM_NAME:-n8n-sandbox}"
VM_CPUS="${SANDBOX_VM_CPUS:-4}"
VM_MEM="${SANDBOX_VM_MEM:-6G}"
VM_DISK="${SANDBOX_VM_DISK:-20G}"
VM_IMAGE="${SANDBOX_VM_IMAGE:-24.04}"          # Sysbox supports up to Noble
SANDBOX_PORT=8080
REPO_RAW=https://raw.githubusercontent.com/n8n-io/n8n-sandbox-service/refs/heads/main

APPLY=no
DESTROY=no
STATUS_ONLY=no
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)   APPLY=yes; shift ;;
        --destroy) DESTROY=yes; shift ;;
        --status)  STATUS_ONLY=yes; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

vm_exists()  { multipass info "$VM_NAME" >/dev/null 2>&1; }
vm_running() { [[ "$(multipass info "$VM_NAME" --format csv 2>/dev/null | awk -F, 'NR==2{print $2}')" == "Running" ]]; }
vm_ip()      { multipass info "$VM_NAME" --format csv 2>/dev/null | awk -F, 'NR==2{print $3}'; }

# ---------------------------------------------------------------------------
if [[ "$DESTROY" == yes ]]; then
    section "Removing the sandbox"
    kubectl delete -f "$K8S_DIR/14-sandbox-bridge.yaml" --ignore-not-found >/dev/null 2>&1 || true
    rm -f "$K8S_DIR/14-sandbox-bridge.yaml"
    if have multipass && vm_exists; then
        multipass delete --purge "$VM_NAME"
        ok "VM $VM_NAME deleted."
    else
        info "No VM to delete."
    fi
    warn "The secrets in $SECRETS/sandbox-* are left in place deliberately."
    warn "Delete them by hand if you are not rebuilding."
    exit 0
fi

# ---------------------------------------------------------------------------
section "Status"

if have multipass && vm_exists; then
    ip="$(vm_ip)"
    if vm_running; then
        ok "VM $VM_NAME is running at ${ip:-unknown}"
        if curl -fsS --max-time 5 "http://${ip}:${SANDBOX_PORT}/healthz" >/dev/null 2>&1; then
            ok "Sandbox API answering on ${ip}:${SANDBOX_PORT}"
        else
            warn "VM is up but the API is not answering yet."
        fi
    else
        warn "VM $VM_NAME exists but is stopped. 'multipass start $VM_NAME'"
    fi
else
    info "No sandbox VM yet."
fi

if kubectl get svc sandbox -n "$K8S_NS" >/dev/null 2>&1; then
    ok "Cluster name: sandbox.$K8S_NS.svc.cluster.local:$SANDBOX_PORT"
else
    info "No cluster bridge yet."
fi

[[ "$STATUS_ONLY" == yes ]] && exit 0

# ---------------------------------------------------------------------------
section "Prerequisites"

[[ "$(uname -s)" == "Linux" ]] || die "This builds a KVM guest. Linux only."
[[ -e /dev/kvm ]] || die "No /dev/kvm. Enable virtualisation in the BIOS."
ok "KVM available."

# 6 GB for the guest plus headroom for the host. Checked rather than assumed
# because the failure mode otherwise is the OOM killer picking a victim
# somewhere else entirely - usually Postgres, never the thing that caused it.
free_gb="$(free -g | awk '/^Mem:/ {print $7}')"
want_gb="${VM_MEM%G}"
if (( free_gb < want_gb + 2 )); then
    warn "Only ${free_gb} GB available; the VM wants ${want_gb} GB plus headroom."
    warn "Run 'ai-pause --cluster' or stop the model server first."
    [[ "$APPLY" == yes ]] && confirm "Continue anyway?" || true
else
    ok "${free_gb} GB free, enough for a ${want_gb} GB guest."
fi

if have multipass; then
    ok "multipass present."
else
    todo "multipass not installed. --apply installs it from snap."
fi

if [[ "$APPLY" != yes ]]; then
    echo
    warn "Read-only. Re-run with --apply to build it."
    exit 0
fi

# ---------------------------------------------------------------------------
section "multipass"

if ! have multipass; then
    have snap || die "snap is required to install multipass."
    info "Installing multipass. This pulls about 300 MB."
    sudo snap install multipass
    ok "multipass installed."
fi

# ---------------------------------------------------------------------------
section "Credentials"

# Three separate secrets, as the upstream .env.example defines them. The API
# key is the one n8n sends; the other two are how the runner authenticates to
# the API and are never seen outside the guest.
API_KEY="$(secret_file "$SECRETS/sandbox-api-key" 32)"
REG_TOKEN="$(secret_file "$SECRETS/sandbox-registration-token" 32)"
RUNNER_KEY="$(secret_file "$SECRETS/sandbox-runner-api-key" 32)"
ok "Secrets ready in $SECRETS/sandbox-*"

# n8n reads the API key from a cluster Secret rather than having it baked into
# the Deployment, so it can be rotated without editing a manifest.
kubectl create secret generic sandbox-credentials -n "$K8S_NS" \
    --from-literal=api-key="$API_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "sandbox-credentials applied to the cluster."

# ---------------------------------------------------------------------------
section "The virtual machine"

if vm_exists; then
    ok "VM $VM_NAME already exists."
    vm_running || { info "Starting it."; multipass start "$VM_NAME"; }
else
    info "Launching Ubuntu $VM_IMAGE with $VM_CPUS CPUs and $VM_MEM. This takes a few minutes."
    multipass launch "$VM_IMAGE" \
        --name "$VM_NAME" \
        --cpus "$VM_CPUS" \
        --memory "$VM_MEM" \
        --disk "$VM_DISK" \
        || die "multipass launch failed."
    ok "VM created."
fi

IP="$(vm_ip)"
[[ -n "$IP" ]] || die "Could not determine the VM's address."
ok "VM address: $IP"

# ---------------------------------------------------------------------------
section "Docker and Sysbox inside the guest"

# Everything below runs in the guest. It is idempotent: Docker's convenience
# script and the Sysbox setup script both detect an existing install.
if multipass exec "$VM_NAME" -- docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q sysbox-runc; then
    ok "Docker and sysbox-runc already present."
else
    info "Installing Docker in the guest."
    multipass exec "$VM_NAME" -- bash -c '
        set -e
        if ! command -v docker >/dev/null; then
            curl -fsSL https://get.docker.com | sudo sh
            sudo usermod -aG docker ubuntu
        fi' || die "Docker install failed."

    info "Installing Sysbox. This replaces the guest's container runtime and takes a few minutes."
    multipass exec "$VM_NAME" -- bash -c "
        set -e
        cd /home/ubuntu
        curl -fsSL -o setup-sysbox.sh $REPO_RAW/scripts/setup-sysbox.sh
        chmod +x setup-sysbox.sh
        sudo ./setup-sysbox.sh" || die "Sysbox install failed. 'multipass shell $VM_NAME' to investigate."
    ok "Sysbox installed."
fi

# ---------------------------------------------------------------------------
section "The sandbox service"

info "Writing the compose file and credentials into the guest."
multipass exec "$VM_NAME" -- bash -c "
    set -e
    mkdir -p /home/ubuntu/sandbox
    cd /home/ubuntu/sandbox
    [[ -f compose.yaml ]] || curl -fsSL -o compose.yaml $REPO_RAW/docs/examples/compose.linux.yaml
" || die "Could not fetch the compose file."

# The .env is written through stdin rather than an exec argument, so the
# secrets never appear in the guest's process list or shell history.
printf '%s\n' \
    "SANDBOX_API_KEYS=$API_KEY" \
    "SANDBOX_API_RUNNER_REGISTRATION_TOKEN=$REG_TOKEN" \
    "SANDBOX_API_RUNNER_API_KEY=$RUNNER_KEY" \
    "SANDBOX_RUNNER_API_KEYS=$RUNNER_KEY" \
    "SANDBOX_RUNNER_REGISTRATION_TOKEN=$REG_TOKEN" \
  | multipass exec "$VM_NAME" -- bash -c 'cat > /home/ubuntu/sandbox/.env && chmod 600 /home/ubuntu/sandbox/.env'
ok "Credentials written to the guest."

info "Starting the sandbox containers."
multipass exec "$VM_NAME" -- bash -c '
    cd /home/ubuntu/sandbox && sudo docker compose up -d' \
    || die "docker compose failed. 'multipass shell $VM_NAME' then 'cd sandbox && sudo docker compose logs'."

info "Waiting for the API to answer (up to 120s)."
for _ in $(seq 1 24); do
    if curl -fsS --max-time 5 "http://${IP}:${SANDBOX_PORT}/healthz" >/dev/null 2>&1; then
        ok "Sandbox API healthy on ${IP}:${SANDBOX_PORT}"
        break
    fi
    sleep 5
done
curl -fsS --max-time 5 "http://${IP}:${SANDBOX_PORT}/healthz" >/dev/null 2>&1 \
    || warn "Not answering yet. Check: multipass exec $VM_NAME -- sudo docker compose -f /home/ubuntu/sandbox/compose.yaml logs"

# ---------------------------------------------------------------------------
section "Cluster bridge"

# Same pattern as 03-host-models.yaml: a Service with no selector cannot get
# endpoints automatically, so we write them ourselves. This gives n8n a stable
# DNS name instead of a VM address that changes whenever the guest is rebuilt.
cat > "$K8S_DIR/14-sandbox-bridge.yaml" <<YAML
# GENERATED by server/10-sandbox.sh - the address below is this machine's
# sandbox VM and is not portable. Re-run that script rather than editing it.
apiVersion: v1
kind: Service
metadata:
  name: sandbox
  namespace: $K8S_NS
  annotations:
    description: "n8n code sandbox, running in the $VM_NAME VM"
spec:
  type: ClusterIP
  ports:
    - name: http
      port: $SANDBOX_PORT
      targetPort: $SANDBOX_PORT
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: sandbox-vm
  namespace: $K8S_NS
  labels:
    kubernetes.io/service-name: sandbox
addressType: IPv4
ports:
  - name: http
    port: $SANDBOX_PORT
    protocol: TCP
endpoints:
  - addresses:
      - "$IP"
    conditions:
      ready: true
YAML

kubectl apply -f "$K8S_DIR/14-sandbox-bridge.yaml" >/dev/null
ok "Cluster name: sandbox.$K8S_NS.svc.cluster.local:$SANDBOX_PORT"

# ---------------------------------------------------------------------------
section "Wiring n8n"

apply_manifest "$K8S_DIR/12-n8n.yaml"
kubectl -n "$K8S_NS" rollout status deploy/n8n --timeout=180s >/dev/null 2>&1 \
    && ok "n8n restarted with the sandbox settings." \
    || warn "n8n did not restart cleanly. kubectl -n $K8S_NS get pods -l app=n8n"

# ---------------------------------------------------------------------------
section "Done"

cat <<EOF

  The Assistant should now find the sandbox by itself, because n8n is
  configured through environment variables rather than the settings page.
  If it still asks, these are the values:

      Service URL   http://sandbox.$K8S_NS.svc.cluster.local:$SANDBOX_PORT
      API key       sudo cat $SECRETS/sandbox-api-key

  Use the cluster name, not $IP. n8n runs inside the cluster and the VM
  address changes when the guest is rebuilt.

  Managing it:

      multipass stop $VM_NAME      reclaim ${VM_MEM} of RAM
      multipass start $VM_NAME     and give it back
      multipass shell $VM_NAME     a shell in the guest
      ./10-sandbox.sh --status     is any of it running
      ./10-sandbox.sh --destroy    remove the VM and the bridge

  The VM does not start itself at boot. That is deliberate - it is the
  single largest optional consumer of memory on this machine, and at 32 GB
  you cannot have the sandbox, the cluster and a Strata pack at once. Start
  it when you want the Assistant to write code.

  What is actually isolated: code runs in a Sysbox container inside the VM,
  so an escape reaches a disposable Ubuntu guest holding nothing but this
  service. It does not reach /srv, the secrets, the models or the GPU.

EOF
