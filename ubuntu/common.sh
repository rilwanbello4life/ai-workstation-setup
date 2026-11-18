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

# Unattended runs are the normal case for this kit: the model downloads alone
# are hundreds of GB, so you start it and go to bed. Two things break that if
# left at their defaults.
#
# Every apt call here already passes -y, which answers apt's own questions.
# It does not answer a package whose postinst opens a config dialog - grub, a
# kernel upgrade, keyboard-configuration - which ignores -y and waits at an
# ncurses screen until morning. noninteractive suppresses the dialog and
# makes dpkg keep the config file already on disk, which is the right answer
# when nobody is watching.
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

# Set by the setup-all wrappers when -y is given. confirm() honours it, which
# is what makes -y reach the prompts inside the individual phase scripts
# rather than only the wrapper's own "run this step?" question.
export AI_ASSUME_YES="${AI_ASSUME_YES:-0}"

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

    if [[ "$AI_ASSUME_YES" == 1 ]]; then
        printf '  %s [y/N] y   (assumed, -y)\n' "$prompt"
        return 0
    fi

    # With no terminal - cron, a systemd unit, nohup, a pipe - read returns
    # immediately with an empty reply, which would silently count as "no" and
    # skip the step while reporting success. Refuse instead, so the cause is
    # visible in the log rather than inferred from what is missing later.
    if [[ ! -t 0 ]]; then
        err "No terminal to ask: $prompt"
        die "Re-run with -y to accept prompts like this one non-interactively."
    fi

    read -r -p "  $prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Keep sudo's timestamp alive for the length of an unattended run.
#
# sudo caches authentication for ~15 minutes. A single phase here can exceed
# that comfortably - llama.cpp against CUDA is a long compile, and a Strata
# tier is hours of downloading - so the next sudo after a long step prompts
# for a password at 3am and waits forever. This primes the timestamp and then
# refreshes it in the background until the parent exits.
sudo_keepalive() {
    sudo -v || die "sudo authentication failed."
    (
        while kill -0 "$$" 2>/dev/null; do
            sudo -n true 2>/dev/null || exit
            sleep 60
        done
    ) &
    _SUDO_KEEPALIVE_PID=$!
    trap 'kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
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
