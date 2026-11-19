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

# Apply a manifest, substituting ${VAR} references from the environment.
# Keeps credentials out of the YAML files committed to this kit.
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
    local path="$1" bytes="${2:-24}"
    if [[ ! -f "$path" ]]; then
        sudo mkdir -p "$(dirname "$path")"
        gen_secret "$bytes" | sudo tee "$path" >/dev/null
        sudo chmod 600 "$path"
    fi
    sudo cat "$path"
}
