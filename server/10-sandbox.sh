#!/usr/bin/env bash
# Phase 22 - the code sandbox n8n's Assistant runs generated code in.
# (Phases 23 to 27 in reference/roadmap.md shifted up by one to make room.)
#
#   ./10-sandbox.sh            check and report, change nothing
#   ./10-sandbox.sh --apply    build the VM and wire n8n to it
#   ./10-sandbox.sh --status   what exists right now
#   ./10-sandbox.sh --shell    a root-capable shell inside the guest
#   ./10-sandbox.sh --logs     follow the sandbox container logs
#   ./10-sandbox.sh --restart  restart the containers, keep the VM
#   ./10-sandbox.sh --password set a login password for the guest
#   ./10-sandbox.sh --destroy  remove the VM and the cluster bridge
#
# Re-running --apply is safe and is the intended way to repair a half-built
# sandbox. There is exactly one VM, because it is addressed by name and the
# script starts the existing one rather than launching a second; exactly one
# set of containers, because compose reconciles a named project rather than
# adding to it; and one lock, so two copies of this script cannot interleave.
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
ACTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)   APPLY=yes; shift ;;
        --destroy) DESTROY=yes; shift ;;
        --status)  STATUS_ONLY=yes; shift ;;
        --shell)   ACTION=shell; shift ;;
        --logs)    ACTION=logs; shift ;;
        --restart) ACTION=restart; shift ;;
        --password) ACTION=password; shift ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

vm_exists()  { multipass info "$VM_NAME" >/dev/null 2>&1; }

# Read one column out of multipass's CSV by its header name. Positional
# fields are not safe here: 1.17 added a Zone column ahead of IPv4, so a
# hard-coded $3 returns the availability zone on a new multipass and the
# address on an old one.
vm_field() {
    multipass info "$VM_NAME" --format csv 2>/dev/null |
    awk -F, -v want="$1" '
        NR==1 { for (i=1; i<=NF; i++) if (tolower($i) == tolower(want)) col=i; next }
        NR==2 && col { print $col }'
}
vm_running() { [[ "$(vm_field State)" == "Running" ]]; }
vm_ip()      { vm_field IPv4 | cut -d\; -f1; }

# Everything that touches the guest goes through compose in one directory, so
# the project name is fixed and a second run reconciles the containers that
# are already there instead of starting a parallel set beside them.
SANDBOX_DIR=/home/ubuntu/sandbox
in_vm()    { multipass exec "$VM_NAME" -- bash -c "$1"; }
compose()  { in_vm "cd $SANDBOX_DIR && sudo docker compose -p sandbox $*"; }
api_up()   { curl -fsS --max-time 5 "http://$1:$SANDBOX_PORT/healthz" >/dev/null 2>&1; }

need_vm() {
    have multipass && vm_exists || die "No sandbox VM. Build it with --apply."
    vm_running || die "VM $VM_NAME is stopped. 'multipass start $VM_NAME'"
}

case "$ACTION" in
    shell)
        need_vm
        echo "Entering $VM_NAME. The service lives in $SANDBOX_DIR. 'exit' to leave."
        echo "sudo needs no password here. If something prompts for one, it asked"
        echo "for a tty - Ctrl-C and run it as 'sudo <command>' instead, or set a"
        echo "password with ./10-sandbox.sh --password."
        exec multipass shell "$VM_NAME" ;;
    password)
        # The guest has no user password at all: multipass authenticates with
        # its own key and grants the ubuntu user passwordless sudo. That is
        # fine until something inside the guest asks for one interactively,
        # at which point there is nothing to type and no way to find out.
        need_vm
        read -rsp "New password for ubuntu@$VM_NAME: " p1; echo
        read -rsp "Again: " p2; echo
        [[ "$p1" == "$p2" && -n "$p1" ]] || die "Passwords did not match."
        printf 'ubuntu:%s' "$p1" |
            multipass exec "$VM_NAME" -- sudo chpasswd \
            || die "Could not set the password."
        ok "Password set. It is yours to remember; nothing stores it."
        exit 0 ;;
    logs)
        need_vm
        exec multipass exec "$VM_NAME" -- \
             bash -c "cd $SANDBOX_DIR && sudo docker compose -p sandbox logs -f --tail=100" ;;
    restart)
        need_vm
        compose "up -d --force-recreate" || die "Restart failed. --logs to see why."
        ok "Containers restarted."
        exit 0 ;;
esac

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

ip=""
if have multipass && vm_exists; then
    ip="$(vm_ip)"

    # There is only ever one VM with this name, but say so explicitly: the
    # thing people worry about after a failed run is a second copy quietly
    # holding 6 GB, and multipass is the only honest witness to that.
    others="$(multipass list --format csv 2>/dev/null |
              awk -F, -v me="$VM_NAME" 'NR>1 && $1!=me && $1 ~ /sandbox/ {print $1}' || true)"
    if [[ -n "$others" ]]; then
        warn "Other sandbox-like VMs exist: $(tr '\n' ' ' <<<"$others")"
    fi

    if vm_running; then
        ok "VM $VM_NAME running at ${ip:-unknown}, ${VM_CPUS} CPUs, ${VM_MEM} RAM"
        if api_up "$ip"; then
            ok "Sandbox API answering on ${ip}:${SANDBOX_PORT}"
        else
            warn "VM is up but the API is not answering. --logs to see why."
        fi
        running="$(compose "ps --services --filter status=running" 2>/dev/null |
                   tr '\n' ' ' || true)"
        if [[ -n "${running// }" ]]; then
            info "Containers: ${running% }"
        else
            warn "No containers running. --apply builds them."
        fi
    else
        warn "VM $VM_NAME exists but is stopped. 'multipass start $VM_NAME'"
    fi
else
    info "No sandbox VM yet."
fi

if kubectl get svc sandbox -n "$K8S_NS" >/dev/null 2>&1; then
    ok "Cluster name: sandbox.$K8S_NS.svc.cluster.local:$SANDBOX_PORT"

    # A guest that was rebuilt or simply rebooted can come back on a new
    # address, and nothing in the cluster notices: the Service still
    # resolves, the EndpointSlice still looks valid, and n8n just times out.
    bridged="$(kubectl get endpointslice sandbox-vm -n "$K8S_NS" \
               -o jsonpath='{.endpoints[0].addresses[0]}' 2>/dev/null || true)"
    if [[ -n "$ip" && -n "$bridged" && "$ip" != "$bridged" ]]; then
        warn "The bridge points at $bridged but the VM is at $ip."
        warn "Re-run with --apply to correct it."
    fi
else
    info "No cluster bridge yet."
fi

if [[ -f "$SECRETS/sandbox-api-key" ]]; then
    ok "API key: sudo cat $SECRETS/sandbox-api-key"
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

# A second --apply started while the first is still launching the guest is
# the one way to end up with a mess: both see no VM, both call launch, and
# multipass fails the loser halfway through. Non-blocking on purpose - the
# right answer is to tell the operator, not to queue behind a ten-minute run.
exec 9>"${TMPDIR:-/tmp}/r1wc-sandbox.lock"
flock -n 9 || die "Another copy of this script is already running."

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
    # The setup script ends by checking that sysbox is running, and that
    # check fails here even though the package installed cleanly: dpkg's
    # postinst cannot reach systemd over a non-interactive multipass exec
    # ("Could not execute systemctl" from deb-systemd-invoke), so the units
    # are written and enabled but never started. So the install is allowed
    # to report failure, and the units are started from the next step.
    multipass exec "$VM_NAME" -- bash -c "
        cd /home/ubuntu
        curl -fsSL -o setup-sysbox.sh $REPO_RAW/scripts/setup-sysbox.sh
        chmod +x setup-sysbox.sh
        sudo ./setup-sysbox.sh" || true

    info "Starting sysbox and reloading Docker."
    multipass exec "$VM_NAME" -- bash -c '
        set -e
        sudo systemctl daemon-reload
        sudo systemctl enable --now sysbox
        sudo systemctl restart docker' \
        || die "Could not start sysbox. 'multipass shell $VM_NAME' then 'systemctl status sysbox'."

    multipass exec "$VM_NAME" -- docker info --format '{{json .Runtimes}}' 2>/dev/null |
        grep -q sysbox-runc \
        || die "sysbox-runc is not a Docker runtime in the guest. 'multipass shell $VM_NAME' to investigate."
    ok "Sysbox installed and running."
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
# -p pins the project name. compose then reconciles the set of containers it
# already owns - a second run restarts them rather than starting a parallel
# stack - and the name stays the same even if the directory is ever moved.
compose "up -d --remove-orphans" \
    || die "docker compose failed. Run './10-sandbox.sh --logs' to see why."

info "Waiting for the API to answer (up to 120s)."
for _ in $(seq 1 24); do
    if api_up "$IP"; then
        ok "Sandbox API healthy on ${IP}:${SANDBOX_PORT}"
        break
    fi
    sleep 5
done
api_up "$IP" || warn "Not answering yet. Run './10-sandbox.sh --logs'."

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

      ./10-sandbox.sh --status     what exists and whether it answers
      ./10-sandbox.sh --shell      a shell inside the guest
      ./10-sandbox.sh --logs       follow the container logs
      ./10-sandbox.sh --restart    restart the containers, keep the VM
      ./10-sandbox.sh --apply      safe to re-run; repairs a broken build
      ./10-sandbox.sh --destroy    remove the VM and the bridge
      multipass stop $VM_NAME      reclaim ${VM_MEM} of RAM
      multipass start $VM_NAME     and give it back

  Or r1wc, where the sandbox is an ordinary row with start and stop.

  The VM does not start itself at boot. That is deliberate - it is the
  single largest optional consumer of memory on this machine, and at 32 GB
  you cannot have the sandbox, the cluster and a Strata pack at once. Start
  it when you want the Assistant to write code.

  What is actually isolated: code runs in a Sysbox container inside the VM,
  so an escape reaches a disposable Ubuntu guest holding nothing but this
  service. It does not reach /srv, the secrets, the models or the GPU.

EOF
