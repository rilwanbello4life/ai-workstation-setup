#!/usr/bin/env bash
# Shared helpers for the Ubuntu setup scripts. Sourced, not executed.

set -euo pipefail

# This machine is one of two fully independent systems. Nothing is shared with
# the Windows install on the other drive, so every path here is local ext4.
#
#   AI_ROOT  models and generated output
#   APPS     application checkouts and virtualenvs
export AI_ROOT="${AI_ROOT:-$HOME/ai}"
export APPS="${APPS:-$HOME/apps}"

# RTX 5070 Ti is Blackwell: compute capability 12.0.
export CUDA_ARCH="${CUDA_ARCH:-120}"

if [[ -t 1 ]]; then
    _C_RESET=$'\033[0m'; _C_BOLD=$'\033[1m'; _C_GREEN=$'\033[32m'
    _C_YELLOW=$'\033[33m'; _C_CYAN=$'\033[36m'; _C_RED=$'\033[31m'
else
    _C_RESET=''; _C_BOLD=''; _C_GREEN=''; _C_YELLOW=''; _C_CYAN=''; _C_RED=''
fi

section() { printf '\n%s=== %s ===%s\n' "$_C_CYAN" "$*" "$_C_RESET"; }
ok()      { printf '  %s[ok]%s   %s\n' "$_C_GREEN" "$_C_RESET" "$*"; }
warn()    { printf '  %s[warn]%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*"; }
err()     { printf '  %s[fail]%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }
info()    { printf '  [info] %s\n' "$*"; }
todo()    { printf '  %s[TODO]%s %s\n' "$_C_BOLD" "$_C_RESET" "$*"; }

die() { err "$*"; exit 1; }

require_not_root() {
    [[ ${EUID} -ne 0 ]] || die "Run this as your normal user, not root. It calls sudo where needed."
}

have() { command -v "$1" >/dev/null 2>&1; }

# Create the AI_ROOT layout. Mirrors C:\AI on the Windows side so both systems
# are navigable the same way, despite sharing nothing.
ensure_ai_dirs() {
    mkdir -p "$AI_ROOT"/{strata,gguf,comfyui/models,comfyui/output,voice,hf-cache}
}

confirm() {
    local prompt="${1:-Continue?}"
    read -r -p "  $prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Add NVIDIA's apt repository for this Ubuntu release. Idempotent.
add_nvidia_repo() {
    if [[ -f /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list ]] ||
       apt-cache policy 2>/dev/null | grep -q 'developer.download.nvidia.com'; then
        ok "NVIDIA apt repository already configured."
        return 0
    fi

    local codename deb url tmp
    codename="$(. /etc/os-release && echo "${VERSION_ID//./}")"
    deb="cuda-keyring_1.1-1_all.deb"
    url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${codename}/x86_64/${deb}"

    info "Adding NVIDIA repository for ubuntu${codename}"
    tmp="$(mktemp -d)"
    if wget -q -O "$tmp/$deb" "$url"; then
        sudo dpkg -i "$tmp/$deb"
        sudo apt-get update -qq
        ok "NVIDIA repository added."
    else
        warn "Could not fetch $url"
        warn "Falling back to Ubuntu's own driver packages."
    fi
    rm -rf "$tmp"
}
