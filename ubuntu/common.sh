#!/usr/bin/env bash
# Shared helpers for the Ubuntu setup scripts. Sourced, not executed.

set -euo pipefail

# This machine is one of two fully independent systems. Nothing is shared with
# the Windows install on the other drive, so every path here is local ext4.
#
#   AI_HOME   everything AI, the one directory to back up or move
#   AI_ROOT   models and weights
#   APPS      application checkouts and virtualenvs
#   AI_OUTPUT generated images and video
#
# A machine that has been through ops/reorganise-home.sh records its chosen
# roots in the file below, and it is read before the defaults so the new
# layout applies everywhere at once.
#
# The defaults themselves are deliberately unchanged from the original
# layout. That is what makes pulling this file safe mid-download: on a
# machine that has not been reorganised there is no paths.sh, nothing moves
# under a running job, and the ledger stays where the running job is writing
# it. The migration script is the only thing that switches layouts, and it
# refuses to run while a download is in progress.
AI_PATHS_FILE="${AI_PATHS_FILE:-$HOME/.config/ai-workstation/paths.sh}"
# shellcheck source=/dev/null
[[ -r "$AI_PATHS_FILE" ]] && source "$AI_PATHS_FILE"

export AI_HOME="${AI_HOME:-$HOME/ai}"
export AI_ROOT="${AI_ROOT:-$AI_HOME}"
export APPS="${APPS:-$HOME/apps}"
export AI_OUTPUT="${AI_OUTPUT:-$AI_ROOT/comfyui/output}"

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

# Free and total space in GB on the filesystem holding a path.
#
# These exist because `df -BG --output=avail` is GNU-only, and the obvious
# spelling of it is a trap under `set -euo pipefail`: when df rejects the
# flags the command substitution fails, the assignment inherits that status,
# and the script exits before reaching the "${x:-0}" fallback on the next
# line. With 2>/dev/null on the df it exits silently, printing the section
# heading and nothing else. `df -Pk` is POSIX and works everywhere, and the
# `|| true` means a path that cannot be stated reports 0 rather than killing
# the caller - a disk check should never be the thing that stops an install.
disk_avail_gb() {
    local blocks
    blocks="$(df -Pk "${1:-.}" 2>/dev/null | awk 'NR==2 {print $4}')" || true
    [[ "$blocks" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
    echo $(( blocks / 1024 / 1024 ))
}

disk_size_gb() {
    local blocks
    blocks="$(df -Pk "${1:-.}" 2>/dev/null | awk 'NR==2 {print $2}')" || true
    [[ "$blocks" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
    echo $(( blocks / 1024 / 1024 ))
}

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

# ---------------------------------------------------------------------------
# Strata's engine settings, defined once and applied at every launch.
#
# The channel is `--set name=value`. The Terminal CLI has first-class flags for
# --context, --kv and --vision and nothing else; an engine setting goes through
# --set, which the CLI layers over whatever its own setup wrote (strata_cli/
# launch/settings.py split_setting, then tune_knobs.apply_to_argv, with
# strata_control/user_args.py keeping a person's value over the generated one).
# A name the engine has not heard of earns a warning rather than a refusal, so
# every name below was checked against the engine on this box
# (~/.local/share/strata/components/engine/0.1.66-*, whose --help lists all of
# them) before being written here. Pasting a whole config across is the part
# that bites: it looks correct, and half the numbers are for another card.
#
# Why these numbers. They came from a friend's 32 GB card, and this box is the
# opposite shape - 16 GB of VRAM against 89 GB of system RAM - so the two
# memories scale apart. A Flash-Next pack pins 25-62 GB of RAM while it is
# loaded, which is why the RAM-side knobs keep the host's values and the card-
# side ones cannot.
#
#   expert-cache auto     the engine sizes the hot-expert cache from whatever
#                         the card has left after the rest of this list; Strata's
#                         own installer writes the same word
#   prefill auto          prompt chunks sized to the buffers that fit
#   spec 4, spec-min-p 0.5
#                         the draft layer's verify window and the confidence it
#                         needs to extend it - Strata's own figures for Flash-Next
#   kv-resident 32768     how much of the conversation memory stays on the card.
#                         A 131072-token session costs 1.9 GB of VRAM with the
#                         whole KV pool on the GPU against about 0.75 GB here,
#                         and what that gives back is expert slots (vram_fit.py
#                         prices a streamed session at max(N, floor) cells plus
#                         a per-cell remainder). It is also what makes parallel
#                         requests affordable at all: every batch slot is a
#                         session of the main one's size, so an unstreamed
#                         session has to fit three times. RAM has room for the
#                         part that streams.
#   vram-reserve-mib 2048 (STRATA_VRAM_RESERVE_MIB)
#                         the slice of the card left free for other programs -
#                         the engine's own default is 700, which is why a pack
#                         used to own all 16 GB. This is the setting that makes
#                         the card shared instead of handed over, and it is why
#                         the launcher stopped insisting on one workload at a
#                         time. Two GB holds a small GGUF or a quantised image
#                         pipeline. The knob is overridable per start
#                         (STRATA_VRAM_RESERVE_MIB) because on a 32 GB card the
#                         right answer is a much bigger room, and handing back
#                         10 GB on every start here would buy Strata experts it
#                         then never had a second model to make room for.
#
#                         What cannot be bought by raising it here: the 9 GB
#                         Q4_K_M 14B the agent layer parks beside a pack as its
#                         `checker` (models/MANIFEST.md, LiteLLM's `checker`
#                         alias). Once that GGUF is up, what is left of 16 GB
#                         is under what Strata's own slotted base, prompt
#                         buffers and a streamed session need before a single
#                         expert is placed - vram_fit.py's own terms put that
#                         floor at 4990 + 110 + 1522 MiB plus about 0.45 GB of
#                         streamed KV, and a 9 GB GGUF and its own KV leave
#                         less than the floor. So no reserve value makes the
#                         pair fit on this card; it is a 32 GB card's pair.
#                         Two
#                         answers on this box mean a smaller GGUF in the room
#                         you left, or the 14B while no pack is resident.
#   conversation-cache-mib 8192, slots 4, min-free-mib 8192
#                         parked conversations, which live in RAM: the engine
#                         takes a budget sized from free RAM up to 8192, four
#                         slots, and a 2560 MiB floor. The budget and the slots
#                         are the host's numbers, and they are already this
#                         engine's defaults. The floor is half his, because the
#                         figure that matters is MemAvailable with a pack
#                         resident - nearer 20 GB here than the 89 GB total.
#
# Two of his settings are deliberately absent:
#   --vision on        his card takes the picture path; ours stays on the CPU
#                      path, which is what keeps the card free for the other
#                      workloads. Every preset here already carries
#                      --vision cpu, and a launch that wants pictures can say
#                      --vision gpu for itself.
#   --batch-mtp        batching is opt-in and every slot is a whole session
#                      (roughly 0.75 GB of the card each at the KV window above),
#                      so the Desktop's own rule - auto only on a card of 24 GB
#                      or more - is left to stand. Say --parallel 2 --set
#                      batch-mtp=on if you want to pay for it.
#   --max-context      his 500000 is above the 256K this model was trained on,
#                      where the CLI warns that answers get less reliable and
#                      rope scaling has to be switched on. The packs on this box
#                      sit at 131072 by setup's own choice; 262144 is the top of
#                      the trained range and the arithmetic above still fits it,
#                      so raise it per pack (`strata launch --preset NAME
#                      --context 262144`) rather than for everything at once.

# Overridable per start rather than per install, because the number is a claim
# about what else runs on the card, and only the person starting it knows that:
# STRATA_VRAM_RESERVE_MIB=8192 strata launch --preset NAME ...
# The override is a room, not a licence - what you ask for has to fit in it, and
# the 9 GB checker GGUF above has no room that does on this card.
STRATA_VRAM_RESERVE_MIB="${STRATA_VRAM_RESERVE_MIB:-2048}"

STRATA_ENGINE_ARGS=(
    --set expert-cache=auto
    --set prefill=auto
    --set spec=4
    --set spec-min-p=0.5
    --set kv-resident=32768
    --set "vram-reserve-mib=${STRATA_VRAM_RESERVE_MIB}"
    --set conversation-cache-mib=8192
    --set conversation-cache-slots=4
    --set conversation-cache-min-free-mib=8192
)

# The control vectors are a model-shaped setting, not a card-shaped one: they
# ride on the speed-projection GGUF the terminal bundle ships for the Flash-
# Next families, under data/experimental-speed-projection/ beside the
# installed version, and the layer range 4..44 is that architecture's 48
# layers. A Qwen3.6 pack is a different model with different layers, so the
# trio is skipped for it rather than aimed at it blind - and the whole block is
# skipped when the bundle has no such file, which is what a launch does on a
# machine whose bundle predates the feature.
#
# Resolve the path rather than store it: it sits under the versioned terminal
# directory, and 'current' is the indirection that keeps it true across an
# update. Takes a preset name or a family name; leaves the arguments for that
# one launch in STRATA_ARGS.
#
# What the trio is allowed to aim at comes out of the file's own name, not out
# of a list of families: the bundle names the asset after the architecture it
# was fitted on, and `strata models list` prints the architecture in the model
# id (qwen3.8-flash-next-unsloth-ud-iq4_xs beside qwen3.6-35b-a3b-q8_0), where
# the preset name does not carry it - 'qwen-iq3_s' is Flash-Next and 'qwen36-
# q8_0' is not. So the key is matched into the catalogue and the trio ships
# only when every pack that key could resolve to is of that architecture. A
# key the catalogue does not know gets no vectors, which is the same reason a
# key that straddles two architectures gets none: aiming vectors at the wrong
# layer count is silent, not an error.
strata_args_for() {
    local key="${1,,}"
    local esp esp_arch hits
    STRATA_ARGS=("${STRATA_ENGINE_ARGS[@]}")
    esp="$(ls -1 "$HOME/.local/share/strata/terminal/current/data/experimental-speed-projection/"*.gguf 2>/dev/null | head -n1)"
    [[ -n "$esp" ]] || return 0
    esp_arch="${esp##*/}"
    esp_arch="${esp_arch,,}"
    esp_arch="${esp_arch%%-experimental-*}"
    [[ -n "$key" ]] || return 0
    # The catalogue's first field is not always the preset's own name - the
    # qwen family is listed as 'iq3_s' while the preset is 'qwen-iq3_s' - so
    # match on the whole name or on its quant part, and let the all-of-one-
    # architecture rule below decide what a loose match cost.
    hits="$(strata models list 2>/dev/null | tr 'A-Z' 'a-z' \
            | grep -F -e "$key" -e "${key#*-}" | cut -d' ' -f3-)" || true
    # Counted rather than grepped -v, because -v on this box's grep is the
    # version flag, and it reports success on a file that agrees completely.
    local total=0 wrong=0 line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        total=$(( total + 1 ))
        [[ "$line" == *"$esp_arch"* ]] || wrong=$(( wrong + 1 ))
    done <<< "$hits"
    if (( total && wrong == 0 )); then
        STRATA_ARGS+=(
            "--set" "control-vector-scaled=${esp}:1.0"
            "--set" "control-vector-layer-range=4 44"
            "--set" "cvec-mode=project"
            "--set" "cvec-dir=per-layer"
        )
    fi
}

# ---------------------------------------------------------------------------
# One file owns the interactive shell environment, and both ~/.profile and
# ~/.bashrc source it.
#
# This kit used to append the exports straight into ~/.profile from two
# different scripts. The problem is that ~/.profile is read by *login* shells
# only. A terminal opened on the desktop is normally a non-login interactive
# shell, which reads ~/.bashrc instead - so after a reboot `strata` and `hf`
# were missing from PATH and AI_ROOT was empty, in exactly the window where
# you would notice and assume the install was broken.
SHELL_ENV_VERSION=3
SHELL_ENV_FILE="${SHELL_ENV_FILE:-$HOME/.config/ai-workstation/env.sh}"

_write_env_file() {
    local tmp="$1"
    printf '# ai-workstation-setup shell environment (v%s) - generated, do not edit.\n' \
        "$SHELL_ENV_VERSION" > "$tmp"
    cat >> "$tmp" <<'ENVEOF'
# Sourced by ~/.profile (login shells) and ~/.bashrc (desktop terminals).
# Re-running any setup script rewrites this file, so do not edit it. To
# change where things live, edit paths.sh beside it - that one is yours and
# is never regenerated. Every value below falls back only when the variable
# is already unset, so whatever paths.sh sets wins.

# shellcheck source=/dev/null
[[ -r "$HOME/.config/ai-workstation/paths.sh" ]] && source "$HOME/.config/ai-workstation/paths.sh"

export AI_HOME="${AI_HOME:-$HOME/ai}"
export AI_ROOT="${AI_ROOT:-$AI_HOME}"
export APPS="${APPS:-$HOME/apps}"
export AI_OUTPUT="${AI_OUTPUT:-$AI_ROOT/comfyui/output}"
export HF_HOME="${HF_HOME:-$AI_ROOT/hf-cache}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"

# Derived exactly the way server/common.sh derives them, so the shell and the
# scripts cannot disagree. Note that server/common.sh reads PLATFORM_DIR back
# as "${PLATFORM_DIR:-$SRV_ROOT/platform}", which means a wrong value here
# wins silently: every server script would create and look for platform state
# in the wrong directory without erroring. Change SRV_ROOT and let the other
# two follow rather than editing them individually.
export SRV_ROOT="${SRV_ROOT:-/srv}"
export PLATFORM_DIR="${PLATFORM_DIR:-$SRV_ROOT/platform}"
export BACKUP_DIR="${BACKUP_DIR:-$SRV_ROOT/backups}"

# k3s writes a root-only kubeconfig; server/02-k3s.sh copies it here.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# Strata refuses requests whose Host header is not one it expects, as
# protection against DNS rebinding. It is right to do that, but the cluster
# reaches Strata through the host bridge in server/k8s/03-host-models.yaml,
# so LiteLLM arrives with Host: strata.platform.svc.cluster.local and is
# turned away:
#
#   Host 'strata.platform.svc.cluster.local:8080' is not allowed
#   (DNS rebinding protection)
#
# What makes that hard to place is where it surfaces. The failure is
# reported by whatever is three hops upstream - n8n's assistant, or Open
# WebUI - as a provider error, so it reads as a broken API key or a
# misconfigured gateway rather than as the model server declining a name.
#
# Listing the names it is legitimately reached by is the narrow fix. The
# alternative Strata offers is setting an API key, which disables the check
# altogether; that is a bigger change, since the key then has to be
# configured in LiteLLM's model list too.
export STRATA_ALLOWED_HOSTS="${STRATA_ALLOWED_HOSTS:-localhost,127.0.0.1,strata.platform.svc.cluster.local,strata.platform.svc,strata,10.42.0.1}"

# strata, hf and uv install here. The guard matters because ~/.bashrc is
# re-read by every nested shell and every tmux pane, and an unguarded prepend
# grows PATH without bound.
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# K8S_DIR is deliberately not set here. server/common.sh derives it from
# BASH_SOURCE so it always points at the k8s directory beside the script that
# is running. A fixed value would go stale the moment the repo is moved or
# cloned elsewhere - and would be ignored anyway, because that assignment has
# no :- fallback.
ENVEOF
}

# Remove an older inline block so there is exactly one definition. Both of
# them had a stable marker and ran to the next blank line, which is what this
# matches. Backing up is the caller's job: this gets called twice against the
# same file, so a backup here would overwrite the first with an already
# half-stripped copy and leave nothing to restore from.
_strip_legacy_env_block() {
    local file="$1" marker="$2" tmp
    [[ -f "$file" ]] || return 0
    grep -qF "$marker" "$file" 2>/dev/null || return 0

    tmp="$(mktemp)"
    awk -v marker="$marker" '
        index($0, marker) == 1 { skipping = 1; next }
        skipping && /^[[:space:]]*$/ { skipping = 0; next }
        skipping && /^export / { next }
        { skipping = 0; print }
    ' "$file" > "$tmp"

    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Make $rcfile source the env file, exactly once.
_link_env_file() {
    local rcfile="$1" ref="$SHELL_ENV_FILE"
    local marker="# ai-workstation-setup environment"

    [[ -f "$rcfile" ]] || touch "$rcfile"
    if grep -qF "$marker" "$rcfile" 2>/dev/null; then
        return 1
    fi

    # Write $HOME rather than the expanded path, so the line stays correct if
    # the home directory is ever mounted somewhere else.
    [[ "$ref" == "$HOME/"* ]] && ref="\$HOME/${ref#"$HOME/"}"

    cat >> "$rcfile" <<EOF

$marker
[ -f "$ref" ] && . "$ref"
EOF
    return 0
}

# ---------------------------------------------------------------------------
# A record of what has been downloaded, so a re-run skips it without asking
# the network or the disk.
#
# Checking "is it there already" is not free at this scale. hf contacts the
# hub for every entry even when the file is cached, and Strata re-reads a
# pack directory before deciding. Across ~1.1 TB of models that is minutes of
# waiting before anything happens, every single run. The ledger makes an
# already-finished entry cost nothing: it is not attempted at all.
#
# Tab-separated, one row per entry, last row wins:
#
#   kind    id                      status  when                 note
#   strata  unsloth/UD-IQ4_XS       ok      2026-11-19T20:14:02  downloaded
#   file    bartowski/x::y.gguf     failed  2026-11-19T20:31:55  hf exit 1
#
# models/download-models.sh writes the same format without sourcing this
# file, because it has to keep working standalone next to its PowerShell
# twin. Keep the two in step.
DOWNLOAD_LEDGER="${DOWNLOAD_LEDGER:-$AI_ROOT/.downloads.tsv}"

ledger_init() {
    mkdir -p "$(dirname "$DOWNLOAD_LEDGER")" 2>/dev/null || true
    [[ -f "$DOWNLOAD_LEDGER" ]] && return 0
    printf '# kind\tid\tstatus\twhen\tnote\n' > "$DOWNLOAD_LEDGER"
}

# Prints ok, failed, or nothing at all. Never fails: an unreadable ledger
# must degrade to "unknown, try it" rather than end the run.
ledger_status() {
    local kind="$1" id="$2"
    [[ -f "$DOWNLOAD_LEDGER" ]] || return 0
    awk -F'\t' -v k="$kind" -v i="$id" \
        '$1 == k && $2 == i { s = $3 } END { if (s != "") print s }' \
        "$DOWNLOAD_LEDGER" 2>/dev/null || true
}

ledger_mark() {
    local kind="$1" id="$2" status="$3" note="${4:-}" tmp
    ledger_init
    tmp="$(mktemp)" || return 0
    # Drop any earlier row for this id so the file does not grow without
    # bound across retries, then append the current verdict.
    awk -F'\t' -v k="$kind" -v i="$id" '!($1 == k && $2 == i)' \
        "$DOWNLOAD_LEDGER" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$kind" "$id" "$status" "$(date -Is 2>/dev/null || date)" "$note" >> "$tmp"
    cat "$tmp" > "$DOWNLOAD_LEDGER" 2>/dev/null || true
    rm -f "$tmp"
}

# Render the whole plan with each entry's state, so one glance answers "what
# is left". Rows arrive on stdin as  id <TAB> label.
ledger_progress() {
    local kind="$1" title="${2:-Progress}" id label st mark colour
    local n_ok=0 n_fail=0 n_todo=0 out=""

    while IFS=$'\t' read -r id label; do
        [[ -n "$id" ]] || continue
        st="$(ledger_status "$kind" "$id")"
        case "$st" in
            ok)     mark="[done]"; colour="$_C_GREEN";  n_ok=$((n_ok + 1)) ;;
            failed) mark="[fail]"; colour="$_C_RED";    n_fail=$((n_fail + 1)) ;;
            *)      mark="[    ]"; colour="";           n_todo=$((n_todo + 1)) ;;
        esac
        out+="$(printf '    %s%s%s %s' "$colour" "$mark" "$_C_RESET" "$label")"$'\n'
    done

    printf '\n  %s%s%s\n' "$_C_BOLD" "$title" "$_C_RESET"
    printf '%s' "$out"
    printf '  %s%d done, %d failed, %d to go%s\n' \
        "$_C_BOLD" "$n_ok" "$n_fail" "$n_todo" "$_C_RESET"
}

ensure_shell_env() {
    local tmp
    mkdir -p "$(dirname "$SHELL_ENV_FILE")"

    tmp="$(mktemp)"
    _write_env_file "$tmp"

    if [[ -f "$SHELL_ENV_FILE" ]] && cmp -s "$tmp" "$SHELL_ENV_FILE"; then
        ok "Shell environment already current: $SHELL_ENV_FILE"
    else
        cat "$tmp" > "$SHELL_ENV_FILE"
        ok "Wrote $SHELL_ENV_FILE"
    fi
    rm -f "$tmp"

    # One backup of the original, taken before either block is touched.
    local legacy="$HOME/.profile" backup
    if [[ -f "$legacy" ]] && grep -qE '^# (ai-workstation-setup$|k3s cluster access)' "$legacy" 2>/dev/null; then
        backup="$legacy.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$legacy" "$backup"
        _strip_legacy_env_block "$legacy" "# ai-workstation-setup"
        _strip_legacy_env_block "$legacy" "# k3s cluster access"
        ok "Migrated the old inline exports out of ~/.profile"
        info "Original saved as ${backup/#$HOME/\~}"
    fi

    local wired=()
    _link_env_file "$HOME/.profile" && wired+=("~/.profile")
    _link_env_file "$HOME/.bashrc"  && wired+=("~/.bashrc")

    if (( ${#wired[@]} )); then
        ok "Sourced from ${wired[*]}"
    else
        ok "Already sourced from ~/.profile and ~/.bashrc"
    fi

    info "Open a new terminal, or run: . $SHELL_ENV_FILE"
}
