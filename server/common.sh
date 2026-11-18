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
    warn "Check with: kubectl -n $ns describe deployment/$name"
    warn "       and: kubectl -n $ns logs deployment/$name --tail=50"
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
