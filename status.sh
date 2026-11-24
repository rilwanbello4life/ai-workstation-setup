#!/usr/bin/env bash
# Whole-build status audit, phase 0 through 19.
#
# Read-only. Changes nothing, needs no arguments, and never exits early on a
# failed check - the point is to produce one complete report you can paste
# somewhere and have someone tell you what is missing.
#
# Deliberately standalone: it does not source common.sh, so you can copy this
# one file to the machine on its own.
#
#   ./status.sh              full report
#   ./status.sh > report.txt save it
#
# Markers:
#   [ok]  present and correct
#   [--]  not done yet (expected if you have not reached that phase)
#   [!!]  done, but something is wrong - look at these first
#   [..]  informational, nothing to judge
#   [??]  cannot tell without sudo or a running service

# NOTE: no 'set -e'. Most checks here are expected to fail on a partial build.
set -uo pipefail

# Written by ops/reorganise-home.sh. Read here too, because this script is
# standalone and does not source ubuntu/common.sh - without it the report
# would describe the layout the machine had before it was reorganised.
# shellcheck source=/dev/null
[[ -r "$HOME/.config/ai-workstation/paths.sh" ]] && source "$HOME/.config/ai-workstation/paths.sh"

AI_HOME="${AI_HOME:-$HOME/ai}"
AI_ROOT="${AI_ROOT:-$AI_HOME}"
APPS="${APPS:-$HOME/apps}"

OK=0; MISS=0; BAD=0
NEXT=""        # first incomplete phase, for the summary
PHASE=""

if [[ -t 1 ]]; then
    R=$'\033[0m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; E=$'\033[31m'; B=$'\033[1m'
else
    R=''; G=''; Y=''; C=''; E=''; B=''
fi

sec()  { PHASE="$*"; printf '\n%s=== %s ===%s\n' "$C" "$*" "$R"; }
ok()   { printf '  %s[ok]%s %-30s %s\n' "$G" "$R" "$1" "${2-}"; OK=$((OK+1)); }
miss() { printf '  %s[--]%s %-30s %s\n' "$Y" "$R" "$1" "${2-}"; MISS=$((MISS+1))
         [[ -z "$NEXT" ]] && NEXT="$PHASE"; return 0; }
bad()  { printf '  %s[!!]%s %-30s %s\n' "$E" "$R" "$1" "${2-}"; BAD=$((BAD+1)); }
note() { printf '  [..] %-30s %s\n' "$1" "${2-}"; }
unk()  { printf '  [??] %-30s %s\n' "$1" "${2-}"; }

have()    { command -v "$1" >/dev/null 2>&1; }
unit_on() { systemctl is-enabled "$1" >/dev/null 2>&1 || systemctl is-active "$1" >/dev/null 2>&1; }

# Check a file exists; report with an optional detail string.
f_chk() { if [[ -e "$2" ]]; then ok "$1" "${3-$2}"; else miss "$1" "$2"; fi; }

# kubectl pinned to the local k3s cluster only. Never inherit an unrelated
# context from the environment - this box is not the only cluster in the world.
KUBE=""
if [[ -r "$HOME/.kube/config" ]]; then KUBE="$HOME/.kube/config"
elif [[ -r /etc/rancher/k3s/k3s.yaml ]]; then KUBE=/etc/rancher/k3s/k3s.yaml; fi
kc() {
    [[ -n "$KUBE" ]] || return 1
    KUBECONFIG="$KUBE" kubectl --request-timeout=4s "$@" 2>/dev/null
}

listening() { ss -ltnH 2>/dev/null | grep -qE "[:.]$1[[:space:]]"; }

printf '%s' "$B"
cat <<BANNER
=========================================================================
 AI workstation build status
 $(date '+%Y-%m-%d %H:%M:%S %z')   $(hostname)   $(id -un)
=========================================================================
BANNER
printf '%s' "$R"

if [[ "$(uname -s)" != "Linux" ]]; then
    printf '\n  %s[!!]%s This is not Linux. Run it on the Ubuntu side.%s\n' "$E" "$R" "$R"
fi

# =========================================================================
sec "Machine"
# =========================================================================
note "Kernel"        "$(uname -r)"
note "Distribution"  "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
note "Uptime"        "$(uptime -p 2>/dev/null)"
note "CPU"           "$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//')"
note "Cores"         "$(have nproc && nproc || echo '?') logical"

mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"
mem_gb=$(( ${mem_kb:-0} / 1024 / 1024 ))
note "RAM reported"  "${mem_gb} GiB"

# Module layout needs dmidecode, which needs root. Infer what we can without.
if dmidecode -t 17 >/dev/null 2>&1; then
    dimms="$(dmidecode -t 17 2>/dev/null | awk '/Size: [0-9]/{n++} END{print n+0}')"
    sizes="$(dmidecode -t 17 2>/dev/null | awk '/Size: [0-9]/{print $2$3}' | sort | uniq -c | tr '\n' ' ')"
    speed="$(dmidecode -t 17 2>/dev/null | awk '/Configured Memory Speed: [0-9]/{print $4; exit}')"
    note "DIMMs populated" "${dimms} (${sizes}) at ${speed} MT/s"
else
    unk "DIMM layout" "needs sudo: sudo dmidecode -t 17"
fi

# Phase 11 landed in one of two valid states; say which, and what it buys.
if   (( mem_gb >= 90 )); then
    ok  "Memory configuration" "96 GB 'add' - four DIMMs, ~DDR5-3600"
elif (( mem_gb >= 58 )); then
    ok  "Memory configuration" "64 GB 'swap' - two DIMMs at full speed"
elif (( mem_gb >= 28 )); then
    miss "Memory configuration" "32 GB factory - phase 11 kit not fitted yet"
else
    bad "Memory configuration" "only ${mem_gb} GiB visible"
fi
experts=$(( mem_gb - 25 ))
(( experts > 0 )) && note "Experts, cluster up" "~${experts} GB -> $(
    if   (( experts >= 62 )); then echo 'UD-IQ4_XS'
    elif (( experts >= 50 )); then echo 'IQ3_S'
    elif (( experts >= 35 )); then echo 'IQ2_XS'
    else echo 'Qwen3.6 only'; fi)"

# =========================================================================
sec "Phase 7 - Disks and the Ubuntu install"
# =========================================================================
root_src="$(findmnt -no SOURCE / 2>/dev/null)"
root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1)"
note "Root filesystem" "$root_src on /dev/${root_disk:-?}"
note "Root free"       "$(df -h / | awk 'NR==2{print $4" free of "$2" ("$5" used)"}')"

if [[ -n "$root_disk" ]]; then
    sz="$(lsblk -dno SIZE "/dev/$root_disk" 2>/dev/null | tr -d ' ')"
    case "$sz" in
        1.8T|1,8T|1.9T|2T) ok "Ubuntu on the 2 TB drive" "/dev/$root_disk ($sz)" ;;
        *) note "Ubuntu drive size" "/dev/$root_disk ($sz)" ;;
    esac
fi

if findmnt -no TARGET /boot/efi >/dev/null 2>&1; then
    efi_src="$(findmnt -no SOURCE /boot/efi)"
    efi_disk="$(lsblk -no PKNAME "$efi_src" 2>/dev/null | head -n1)"
    if [[ "$efi_disk" == "$root_disk" ]]; then
        ok "EFI partition" "$efi_src - on the same drive as root, as designed"
    else
        bad "EFI partition" "$efi_src is on /dev/$efi_disk, not the Ubuntu drive"
    fi
else
    miss "EFI partition" "/boot/efi not mounted"
fi

ntfs="$(lsblk -no NAME,FSTYPE,SIZE,MOUNTPOINT 2>/dev/null | awk '$2=="ntfs"{print $1" "$3" "$4}' | tr '\n' ';')"
if [[ -n "$ntfs" ]]; then
    if lsblk -no FSTYPE,MOUNTPOINT 2>/dev/null | awk '$1=="ntfs" && $2!=""{f=1} END{exit !f}'; then
        bad "Windows drive" "an NTFS partition is MOUNTED - unmount it; the two systems must not share"
    else
        ok "Windows drive" "visible, not mounted (${ntfs%;})"
    fi
else
    note "Windows drive" "no NTFS partitions visible from here"
fi

# =========================================================================
sec "Phase 8.1 - NVIDIA driver"
# =========================================================================
if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    ok  "nvidia-smi"      "$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
    note "Driver"         "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)"
    note "VRAM"           "$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n1)"
    cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n1 | tr -d ' ')"
    if [[ "$cap" == "12.0" ]]; then ok "Compute capability" "12.0 (sm_120)"
    else bad "Compute capability" "$cap - expected 12.0"; fi
    note "VRAM in use"    "$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | head -n1)"
    pm="$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader | head -n1)"
    [[ "$pm" == "Enabled" ]] && ok "Persistence mode" "enabled" || miss "Persistence mode" "run 02-tune-linux.sh"
else
    bad "nvidia-smi" "no GPU - run ubuntu/01-nvidia.sh, then see troubleshooting.md"
fi

if have mokutil; then
    sb="$(mokutil --sb-state 2>/dev/null | head -n1)"
    note "Secure Boot" "${sb:-unknown}"
    if grep -qi enabled <<<"$sb"; then
        if mokutil --test-key /var/lib/shim-signed/mok/MOK.der 2>/dev/null | grep -qi 'already enrolled'; then
            ok "MOK key" "enrolled - DKMS rebuilds will stay signed"
        else
            note "MOK key" "not enrolled; modules must be Canonical-signed instead"
        fi
    fi
fi
if [[ -r /sys/module/nvidia_drm/parameters/modeset ]]; then
    md="$(cat /sys/module/nvidia_drm/parameters/modeset)"
    [[ "$md" == "Y" ]] && ok "nvidia-drm modeset" "Y" || bad "nvidia-drm modeset" "$md - Wayland misbehaves without this"
fi
note "Session type" "${XDG_SESSION_TYPE:-none (text console or ssh)}"

xids="$(dmesg 2>/dev/null | grep -ci 'xid' || true)"
if [[ "$xids" =~ ^[0-9]+$ ]] && (( xids > 0 )); then
    bad "GPU Xid errors" "$xids in dmesg - run: sudo dmesg -T | grep -i xid"
else
    note "GPU Xid errors" "none visible (run with sudo for the full ring buffer)"
fi

# =========================================================================
sec "Phase 8.2 - System tuning"
# =========================================================================
ml="$(ulimit -l)"
[[ "$ml" == "unlimited" ]] && ok "memlock (this shell)" "unlimited" \
    || bad "memlock (this shell)" "$ml KB - log out and back in, Strata cannot pin"
f_chk "memlock limits.d"   /etc/security/limits.d/90-ai-memlock.conf
f_chk "memlock systemd"    /etc/systemd/user.conf.d/90-ai-memlock.conf
f_chk "sysctl tuning"      /etc/sysctl.d/90-ai-tuning.conf

sw="$(sysctl -n vm.swappiness 2>/dev/null)"
[[ "$sw" == "10" ]] && ok "vm.swappiness" "10" || bad "vm.swappiness" "$sw - expected 10"
mm="$(sysctl -n vm.max_map_count 2>/dev/null)"
(( mm >= 1048576 )) && ok "vm.max_map_count" "$mm" || bad "vm.max_map_count" "$mm - expected >= 1048576"

gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
[[ "$gov" == "performance" ]] && ok "CPU governor" "performance" || bad "CPU governor" "${gov:-unknown}"
unit_on cpu-performance.service && ok "cpu-performance.service" "persists across reboots" \
    || miss "cpu-performance.service" "governor will reset on reboot"

f_chk "ai-console-mode" /usr/local/bin/ai-console-mode
for d in strata gguf comfyui voice hf-cache; do
    [[ -d "$AI_ROOT/$d" ]] || { miss "AI_ROOT/$d" "missing"; continue; }
done
[[ -d "$AI_ROOT/strata" && -d "$AI_ROOT/gguf" && -d "$AI_ROOT/hf-cache" ]] \
    && ok "AI_ROOT layout" "$AI_ROOT"
ENV_FILE="$HOME/.config/ai-workstation/env.sh"
if [[ -f "$ENV_FILE" ]]; then
    ok "Shell environment" "$ENV_FILE"

    # Both files, not either: ~/.profile covers login shells, ~/.bashrc covers
    # the terminal you open on the desktop. Missing the second one is the case
    # that looks like a broken install after a reboot.
    unwired=()
    for rc in "$HOME/.profile" "$HOME/.bashrc"; do
        # The tilde is escaped: unescaped, bash expands it in the replacement
        # back to $HOME and the substitution becomes a no-op.
        grep -qF 'ai-workstation/env.sh' "$rc" 2>/dev/null || unwired+=("${rc/#$HOME/\~}")
    done
    (( ${#unwired[@]} )) \
        && bad "Shell env sourcing" "not sourced from ${unwired[*]} - run ubuntu/11-shell-env.sh" \
        || ok "Shell env sourcing" "~/.profile and ~/.bashrc"

    # PLATFORM_DIR is read back by server/common.sh as "${PLATFORM_DIR:-...}",
    # so a wrong value in the environment wins silently instead of failing.
    env_pd="$(env -i HOME="$HOME" bash -c ". '$ENV_FILE' 2>/dev/null; echo \"\$PLATFORM_DIR\"" 2>/dev/null)"
    env_sr="$(env -i HOME="$HOME" bash -c ". '$ENV_FILE' 2>/dev/null; echo \"\$SRV_ROOT\"" 2>/dev/null)"
    if [[ -n "$env_pd" && "$env_pd" != "$env_sr/platform" ]]; then
        bad "PLATFORM_DIR" "$env_pd does not match \$SRV_ROOT/platform ($env_sr/platform)"
    fi
elif grep -q 'AI_ROOT' "$HOME/.profile" 2>/dev/null; then
    bad "Shell environment" "old inline ~/.profile block - run ubuntu/11-shell-env.sh to migrate"
else
    miss "Shell environment" "not configured - run ubuntu/11-shell-env.sh"
fi

# =========================================================================
sec "Phase 8.3 - Python and CUDA toolchain"
# =========================================================================
have uv      && ok "uv"      "$(uv --version 2>/dev/null)"            || miss "uv"      "run 03-python-cuda.sh"
have python3 && note "python3" "$(python3 --version 2>&1)"
if have nvcc; then
    ok "nvcc" "$(nvcc --version 2>/dev/null | awk '/release/{print $5,$6}' | tr -d ',')"
else
    miss "nvcc" "needed by 04-llamacpp.sh"
fi

# =========================================================================
sec "Phase 8.4 - llama.cpp"
# =========================================================================
f_chk "llama.cpp checkout" "$APPS/llama.cpp"
if [[ -x "$HOME/.local/bin/llama-server" ]] || have llama-server; then
    ok "llama-server" "on PATH or in ~/.local/bin"
else
    miss "llama-server" "run 04-llamacpp.sh"
fi
f_chk "start-llama-server.sh" "$APPS/start-llama-server.sh"
gg="$(find "$AI_ROOT/gguf" -maxdepth 2 -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')"
note "GGUF files" "$gg in $AI_ROOT/gguf"

# =========================================================================
sec "Phase 8.5 - ComfyUI"
# =========================================================================
f_chk "ComfyUI checkout" "$APPS/ComfyUI"
f_chk "ComfyUI venv"     "$APPS/ComfyUI/.venv"
f_chk "start-comfyui.sh" "$APPS/start-comfyui.sh"
if [[ -d "$APPS/ComfyUI/custom_nodes" ]]; then
    n="$(find "$APPS/ComfyUI/custom_nodes" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    note "Custom nodes" "$n installed"
fi
[[ -d "$AI_ROOT/comfyui/models" ]] && note "ComfyUI models" \
    "$(du -sh "$AI_ROOT/comfyui/models" 2>/dev/null | cut -f1) in $AI_ROOT/comfyui/models"

# =========================================================================
sec "Phase 8.6 - Voice"
# =========================================================================
f_chk "voice app"      "$APPS/voice"
f_chk "voice venv"     "$APPS/voice/.venv"
f_chk "start-voice.sh" "$APPS/start-voice.sh"
unit_on voice-server.service && ok "voice-server.service" "$(systemctl is-active voice-server.service 2>/dev/null)" \
    || miss "voice-server.service" "optional - only if you want it always on"

# =========================================================================
sec "Phase 8.7 / 9 - Strata and models"
# =========================================================================
# Every strata call is wrapped in a timeout: these can block on a model load
# or a stale socket, and a status report must never hang.
run() { if have timeout; then timeout 10 "$@"; else "$@"; fi; }

if have strata; then
    ok "strata CLI" "$(run strata --version 2>/dev/null | head -n1)"
    ml_out="$(run strata models list 2>/dev/null)"
    if [[ -n "$ml_out" ]]; then
        note "Installed packs" "$(printf '%s\n' "$ml_out" | grep -cvE '^[[:space:]]*$') line(s):"
        printf '%s\n' "$ml_out" | sed 's/^/        /'
    else
        miss "Strata packs" "none installed - run 07-strata.sh --tier a --install"
    fi
    presets="$(run strata launch --list-presets 2>/dev/null | grep -cvE '^[[:space:]]*$')"
    note "Saved presets" "${presets:-0}"
    note "Serving now" "$(run strata launch --status 2>/dev/null | head -n1 || echo 'nothing')"
else
    miss "strata CLI" "run 07-strata.sh"
fi
# Strata keeps its packs in its own store, not under AI_ROOT. This used to
# measure $AI_ROOT/strata, which the kit creates and Strata never writes to,
# so it reported an empty directory while hundreds of gigabytes sat
# elsewhere. Ask Strata's own settings where the library is, fall back to
# the documented default, and say which one is being measured.
strata_store=""
if [[ -r "$HOME/.config/strata/settings.json" ]] && have python3; then
    strata_store="$(python3 -c 'import json,os,sys
try:
    d = json.load(open(os.path.expanduser("~/.config/strata/settings.json"))).get("data_dir") or ""
except Exception:
    d = ""
print(d if d and os.path.isdir(d) else "")' 2>/dev/null || true)"
fi
if [[ -z "$strata_store" ]]; then
    cand="${XDG_DATA_HOME:-$HOME/.local/share}/strata"
    [[ -d "$cand" ]] && strata_store="$cand"
fi
if [[ -n "$strata_store" ]]; then
    note "Strata store" "$(du -sh "$strata_store" 2>/dev/null | cut -f1)  at ${strata_store/#$HOME/\~}"
else
    note "Strata store" "not found - no packs downloaded yet"
fi
if [[ -d "$AI_ROOT/strata" && ! -L "$AI_ROOT/strata" ]] \
   && [[ -z "$(ls -A "$AI_ROOT/strata" 2>/dev/null)" ]]; then
    note "${AI_ROOT/#$HOME/\~}/strata" "empty - Strata does not use it; the store above is the real one"
fi
note "AI_ROOT total" "$(du -sh "$AI_ROOT" 2>/dev/null | cut -f1)"

# =========================================================================
sec "Phase 10 - Remote access"
# =========================================================================
if have tailscale; then
    ts="$(tailscale status --peers=false 2>/dev/null | head -n1)"
    [[ -n "$ts" ]] && ok "Tailscale" "$ts" || miss "Tailscale" "installed but not logged in"
    # A funnel exposes this box to the public internet. It must never be on.
    if tailscale funnel status 2>/dev/null | grep -qiE 'https|proxy'; then
        bad "Tailscale Funnel" "ACTIVE - this box is on the public internet. Turn it off."
    fi
else
    miss "Tailscale" "optional - phase 10"
fi
unit_on ssh && ok "OpenSSH server" "$(systemctl is-active ssh 2>/dev/null)" || miss "OpenSSH server" "optional"

# =========================================================================
sec "Phase 11 - Memory validation"
# =========================================================================
if have memtest86+ || ls /boot/memtest86+* >/dev/null 2>&1; then
    ok "memtest86+" "installed - pick it from the GRUB menu"
else
    miss "memtest86+" "sudo apt install memtest86+   (prove four DIMMs before trusting Postgres)"
fi
segv="$(journalctl -k --since '7 days ago' --no-pager 2>/dev/null | grep -ciE 'segfault|machine check|mce:' || true)"
if [[ "$segv" =~ ^[0-9]+$ ]] && (( segv > 0 )); then
    bad "Kernel faults, 7 days" "$segv segfault/MCE lines - suspect memory before software"
else
    note "Kernel faults, 7 days" "none"
fi

# =========================================================================
sec "Phase 12 - Server base"
# =========================================================================
masked=yes
for u in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    systemctl is-enabled "$u" 2>/dev/null | grep -q masked || masked=no
done
[[ "$masked" == yes ]] && ok "Sleep targets" "masked" || miss "Sleep targets" "run server/01-server-base.sh"
sws="$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ')"
[[ -n "$sws" ]] && ok "Swap" "$sws" || miss "Swap" "no swap - an OOM kill takes the cluster down"
for h in ai-pause ai-resume ai-status; do f_chk "$h" "/usr/local/bin/$h"; done
f_chk "/srv/platform" /srv/platform
if have ufw; then
    u="$(ufw status 2>/dev/null | head -n1)"
    [[ -n "$u" ]] && note "Firewall" "$u" || unk "Firewall" "needs sudo: sudo ufw status"
fi

# =========================================================================
sec "Phase 13 - k3s cluster"
# =========================================================================
if unit_on k3s; then
    ok "k3s service" "$(systemctl is-active k3s 2>/dev/null)"
    if nodes="$(kc get nodes --no-headers)" && [[ -n "$nodes" ]]; then
        ok "Node status" "$(printf '%s' "$nodes" | awk '{print $1" "$2}')"
        note "Namespaces" "$(kc get ns --no-headers -o custom-columns=:metadata.name | tr '\n' ' ')"
        kc get runtimeclass nvidia >/dev/null && ok "nvidia RuntimeClass" "present" \
            || miss "nvidia RuntimeClass" "GPU pods will not schedule"
    else
        bad "Node status" "k3s is running but kubectl cannot reach it"
    fi
else
    miss "k3s" "run server/02-k3s.sh"
fi
if unit_on ai-model-bridge.service; then
    # 'systemctl is-active' once called a dead bridge healthy: v1 was
    # Type=oneshot and its shell exited 0 even when every socat failed to
    # bind. Check what traffic actually uses - the socket on the host and
    # the proxy pod in the cluster - rather than what the unit reports.
    if [[ -S /run/ai-model-bridge/strata.sock ]]; then
        ok "ai-model-bridge.service" "socket present, forwarders listening"
    else
        bad "ai-model-bridge.service" "active but no /run/ai-model-bridge/strata.sock"
    fi
    proxy="$(kc get ds host-model-proxy -n platform \
             -o custom-columns=':status.numberReady,:status.desiredNumberScheduled' \
             --no-headers 2>/dev/null | tr -d '[:space:]')"
    case "$proxy" in
        "")   miss "host-model-proxy" "DaemonSet not applied - re-run server/02-k3s.sh" ;;
        0/0)  warn "host-model-proxy" "no node labelled for host models" ;;
        */0)  warn "host-model-proxy" "no node labelled for host models" ;;
        0/*)  bad  "host-model-proxy" "proxy pod not ready - host-backed names are dead" ;;
        *)    ok   "host-model-proxy" "$proxy proxy pods ready" ;;
    esac
else
    miss "ai-model-bridge.service" "part of server/02-k3s.sh"
fi

# =========================================================================
sec "Phase 14 - Platform services"
# =========================================================================
if kc get ns platform >/dev/null; then
    deploys="$(kc get deploy -n platform --no-headers 2>/dev/null)"
    if [[ -n "$deploys" ]]; then
        # Here-string, not a pipe: a pipeline would run this in a subshell and
        # the ok/bad counters would not survive to the summary.
        while read -r name ready _rest; do
            [[ -n "$name" ]] || continue
            case "$ready" in
                0/*|"") bad "$name" "$ready - not ready" ;;
                *)      ok  "$name" "$ready" ;;
            esac
        done <<<"$deploys"
    else
        miss "Platform deployments" "run server/03-platform.sh"
    fi
else
    miss "platform namespace" "run server/03-platform.sh"
fi
if [[ -d /srv/platform/secrets ]]; then
    perm="$(stat -c '%a' /srv/platform/secrets 2>/dev/null)"
    [[ "$perm" == "700" || "$perm" == "600" ]] && ok "Secrets directory" "mode $perm" \
        || bad "Secrets directory" "mode $perm - should be 700"
fi
unit_on platform-forward.service && ok "platform-forward.service" "ports published to loopback" \
    || miss "platform-forward.service" "part of server/03-platform.sh"

sec "Listening ports"
for p in 8080:Strata 8081:llama.cpp 8188:ComfyUI 8100:voice 4000:LiteLLM 5432:Postgres 3000:Open-WebUI 5678:n8n; do
    port="${p%%:*}"; name="${p##*:}"
    listening "$port" && ok "$name" "listening on $port" || note "$name" "not listening on $port"
done

# =========================================================================
sec "Phases 15-18 - Agents, games, friends, backups"
# =========================================================================
for h in agent-roles agent-runs; do f_chk "$h" "/usr/local/bin/$h"; done
f_chk "games helper"   /usr/local/bin/games
f_chk "friends helper" /usr/local/bin/friends
[[ -d /srv/games ]] && note "Game data" "$(du -sh /srv/games 2>/dev/null | cut -f1) in /srv/games"

if unit_on platform-backup.timer; then
    ok "platform-backup.timer" "$(systemctl is-active platform-backup.timer 2>/dev/null)"
    note "Next backup" "$(systemctl list-timers platform-backup.timer --no-pager --no-legend 2>/dev/null | awk '{print $1,$2,$3}')"
    note "Last result"  "$(systemctl show platform-backup.service -p Result --value 2>/dev/null)"
else
    miss "platform-backup.timer" "run server/07-backup.sh"
fi
if [[ -d /srv/backups ]]; then
    ok "/srv/backups" "$(du -sh /srv/backups 2>/dev/null | cut -f1), $(find /srv/backups -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ') entries"
else
    miss "/srv/backups" "no local backups yet"
fi

# =========================================================================
sec "Phase 19 - Gaming on Ubuntu (optional)"
# =========================================================================
have steam        && ok "Steam" "installed"            || miss "Steam" "optional - run ubuntu/09-gaming.sh"
have gamemoderun  && ok "GameMode" "installed"         || miss "GameMode" "optional"
f_chk "gaming-check" /usr/local/bin/gaming-check

# =========================================================================
sec "Phase 20 - GitOps with Argo CD (optional)"
# =========================================================================
f_chk "gitops helper" /usr/local/bin/gitops

if [[ -d /srv/gitops.git ]]; then
    ok "/srv/gitops.git" "bare repo"
else
    miss "/srv/gitops.git" "optional - run server/08-gitops.sh"
fi

if [[ -d /srv/gitops ]]; then
    ok "/srv/gitops" "working tree"
    for d in source rendered apps; do
        [[ -d "/srv/gitops/$d" ]] && note "  $d/" \
            "$(find "/srv/gitops/$d" -type f 2>/dev/null | wc -l | tr -d ' ') file(s)"
    done
    # The secret guard is only as good as the file being present.
    [[ -f /srv/gitops/.gitignore ]] && ok "  secret .gitignore" "present" \
        || bad "  secret .gitignore" "missing - commits are not screened"

    if head="$(git -C /srv/gitops log -1 --format='%h %s' 2>/dev/null)" && [[ -n "$head" ]]; then
        note "  last commit" "$head"
    fi
    # Uncommitted work means the cluster is running something older than
    # what is on disk, which is the confusing state worth surfacing.
    if dirty="$(git -C /srv/gitops status --porcelain 2>/dev/null)" && [[ -n "$dirty" ]]; then
        bad "  uncommitted changes" "$(printf '%s\n' "$dirty" | wc -l | tr -d ' ') path(s) - run: gitops commit"
    elif [[ -d /srv/gitops/.git ]]; then
        ok "  working tree" "clean"
    fi
fi

if unit_on git-daemon.service; then
    ok "git-daemon.service" "$(systemctl is-active git-daemon.service 2>/dev/null)"
    listening 9418 && ok "  git daemon port" "listening on 9418" \
        || bad "  git daemon port" "enabled but nothing on 9418"
    [[ -f /srv/gitops.git/git-daemon-export-ok ]] && ok "  export marker" "present" \
        || bad "  export marker" "missing - Argo CD cannot clone the repo"
else
    miss "git-daemon.service" "optional - Argo CD reads the repo over this"
fi

f_chk "gitops-watch.path" /etc/systemd/system/gitops-watch.path
if [[ -f /etc/systemd/system/gitops-watch.path ]]; then
    # Shipped disabled on purpose; both states are correct.
    unit_on gitops-watch.path && note "  auto-commit" "enabled" \
        || note "  auto-commit" "disabled (the default)"
fi

if kc get ns argocd >/dev/null; then
    ok "argocd namespace" "present"
    argo_deploys="$(kc get deploy -n argocd --no-headers 2>/dev/null)"
    if [[ -n "$argo_deploys" ]]; then
        a_ok=0; a_bad=0
        while read -r name ready rest; do
            [[ -n "${name:-}" ]] || continue
            if [[ "$ready" == */* && "${ready%%/*}" == "${ready##*/}" && "${ready%%/*}" != 0 ]]; then
                a_ok=$((a_ok+1))
            else
                a_bad=$((a_bad+1)); bad "  $name" "$ready ready"
            fi
        done <<<"$argo_deploys"
        (( a_ok  > 0 )) && ok  "argocd workloads" "$a_ok ready"
        # Scaled to zero is what ai-pause leaves behind, not a fault.
        (( a_bad > 0 )) && note "argocd workloads" "$a_bad not ready - paused, or still starting"
    fi

    apps="$(kc get applications -n argocd --no-headers \
            -o custom-columns=':metadata.name,:status.sync.status,:status.health.status' 2>/dev/null)"
    if [[ -n "$apps" ]]; then
        # Health decides the colour, not sync. The platform app is adopted on
        # manual sync deliberately, so OutOfSync is its normal resting state
        # and flagging it red would train you to ignore red.
        while read -r aname async ahealth; do
            [[ -n "${aname:-}" ]] || continue
            case "${ahealth:-}" in
                Healthy)
                    if [[ "$async" == Synced ]]; then
                        ok "  app/$aname" "Synced, Healthy"
                    else
                        note "  app/$aname" "${async:-?} - manual sync, or an uncommitted render"
                    fi ;;
                Progressing|"")
                    note "  app/$aname" "${async:-?}, ${ahealth:-unknown} - still settling" ;;
                *)
                    bad  "  app/$aname" "${async:-?}, $ahealth" ;;
            esac
        done <<<"$apps"
    else
        miss "Argo CD Applications" "none registered yet"
    fi

    listening 8090 && ok "Argo CD UI" "listening on 8090" \
        || note "Argo CD UI" "not forwarded to 8090"
else
    miss "argocd namespace" "optional - run server/08-gitops.sh"
fi

# =========================================================================
sec "Phase 21 - GPU queue (optional)"
# =========================================================================
f_chk "queue helper" /usr/local/bin/queue

if unit_on gpu-probe.service; then
    ok "gpu-probe.service" "$(systemctl is-active gpu-probe.service 2>/dev/null)"
    probe="$(run curl -fsS --max-time 4 http://127.0.0.1:8101/gpu 2>/dev/null)"
    if [[ -n "$probe" ]]; then
        ok "  probe response" "$(printf '%s' "$probe" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unparseable"); raise SystemExit
if d.get("available"):
    print(str(d.get("memory_free_mb")) + " MB free, "
          + str(d.get("utilization_pct")) + "% busy")
else:
    print("unavailable: " + str(d.get("reason")))
' 2>/dev/null)"
    else
        bad "  probe response" "running but not answering on 8101"
    fi
else
    miss "gpu-probe.service" "optional - the queue falls back to static limits"
fi

# The queue reaches the probe and ComfyUI through the same bridge. A socket
# file proves the forwarder exists; whether the host service behind it is
# up is a separate, honest question the probe check above already answers.
if [[ -d /run/ai-model-bridge ]]; then
    for sock in gpu-probe comfyui; do
        [[ -S "/run/ai-model-bridge/${sock}.sock" ]] \
            && ok "host bridge" "socket present for ${sock}" \
            || miss "host bridge" "no socket for ${sock} - re-run server/02-k3s.sh"
    done
else
    miss "host bridge" "/run/ai-model-bridge missing - ai-model-bridge.service is not v2"
fi

if kc get deploy gpu-queue -n platform >/dev/null; then
    q_ready="$(kc get deploy gpu-queue -n platform \
               -o custom-columns=':status.readyReplicas' --no-headers 2>/dev/null | tr -d ' ')"
    q_spec="$(kc get deploy gpu-queue -n platform \
              -o custom-columns=':spec.replicas' --no-headers 2>/dev/null | tr -d ' ')"
    if [[ "${q_ready:-0}" == 1 ]]; then
        ok "gpu-queue deployment" "1/1 ready"
    elif [[ "${q_spec:-0}" == 0 ]]; then
        note "gpu-queue deployment" "scaled to zero (ai-pause)"
    else
        bad "gpu-queue deployment" "${q_ready:-0}/${q_spec:-?} ready"
    fi
    # More than one replica double-counts admissions: each keeps its own
    # in-memory counters, so the real concurrency becomes twice the limit.
    [[ -n "${q_spec:-}" && "$q_spec" != 0 && "$q_spec" != 1 ]] && \
        bad "  replica count" "$q_spec - must be 1, admission counters are in memory"

    if listening 4100; then
        ok "queue port" "listening on 4100"
        qs="$(run curl -fsS --max-time 5 http://127.0.0.1:4100/queue/status 2>/dev/null)"
        [[ -n "$qs" ]] && printf '%s' "$qs" | python3 -c '
import json, sys
d = json.load(sys.stdin)
fl = d.get("inflight") or {}
lim = d.get("limits") or {}
g = d.get("gpu") or {}
print("  [..] " + "queue depth".ljust(30)
      + str(fl.get("heavy", 0)) + " heavy, " + str(fl.get("light", 0))
      + " light in flight, " + str(d.get("queued", 0)) + " waiting"
      + ("  DRAINING" if d.get("draining") else ""))
print("  [..] " + "admission limits".ljust(30)
      + str(lim.get("heavy")) + " heavy, " + str(lim.get("light_now"))
      + " light (floor " + str(lim.get("light_floor"))
      + ", ceiling " + str(lim.get("light_ceiling")) + ")")
print("  [..] " + "profile store".ljust(30) + str(d.get("store")))
' 2>/dev/null
    else
        note "queue port" "not forwarded to 4100"
    fi
else
    miss "gpu-queue deployment" "optional - run server/09-gpu-queue.sh"
fi

# Schema presence, via the same database the gateway uses.
if kc get deploy postgres -n platform >/dev/null; then
    qtabs="$(KUBECONFIG="$KUBE" kubectl -n platform --request-timeout=6s exec deploy/postgres -- \
             psql -U postgres -d litellm -A -t -c \
             "SELECT count(*) FROM information_schema.tables
               WHERE table_name IN ('user_profiles','skills','gpu_jobs','user_profile_history')" 2>/dev/null | tr -d ' \r')"
    if [[ "${qtabs:-0}" == 4 ]]; then
        ok "queue schema" "4 tables present"
        prof="$(KUBECONFIG="$KUBE" kubectl -n platform --request-timeout=6s exec deploy/postgres -- \
                psql -U postgres -d litellm -A -t -c \
                'SELECT count(*) FROM user_profiles' 2>/dev/null | tr -d ' \r')"
        note "  profiles" "${prof:-?} configured"
    elif [[ -n "${qtabs:-}" && "$qtabs" != 0 ]]; then
        bad "queue schema" "$qtabs of 4 tables - re-apply server/k8s/21-queue-schema.sql"
    fi
fi

if [[ -d /srv/platform/gpu-queue/outputs ]]; then
    ok "job outputs" "$(find /srv/platform/gpu-queue/outputs -maxdepth 1 -mindepth 1 2>/dev/null \
        | wc -l | tr -d ' ') result(s) in /srv/platform/gpu-queue/outputs"
fi

if have tailscale && tailscale serve status >/dev/null 2>&1; then
    if tailscale serve status 2>/dev/null | grep -q '127.0.0.1:4100'; then
        ok "tailnet endpoint" ":8447 points at the queue"
    elif tailscale serve status 2>/dev/null | grep -q '127.0.0.1:4000'; then
        note "tailnet endpoint" ":8447 still points at LiteLLM on 4000"
    fi
fi

# =========================================================================
sec "Disk budget"
# =========================================================================
df -h / "$AI_ROOT" /srv 2>/dev/null | awk 'NR==1 || !seen[$1]++' | sed 's/^/  /'
echo
for d in "$AI_ROOT" "$APPS" /srv; do
    [[ -d "$d" ]] && du -sh "$d" 2>/dev/null | sed 's/^/  /'
done

# =========================================================================
printf '\n%s=========================================================================%s\n' "$C" "$R"
printf ' %sSUMMARY%s   %s%d ok%s   %s%d not done%s   %s%d need attention%s\n' \
    "$B" "$R" "$G" "$OK" "$R" "$Y" "$MISS" "$R" "$E" "$BAD" "$R"
printf '%s=========================================================================%s\n' "$C" "$R"

if (( BAD > 0 )); then
    echo
    echo " Fix the [!!] lines first - those are things that are done but wrong."
fi
if [[ -n "$NEXT" ]]; then
    echo
    echo " First incomplete section: $NEXT"
fi
cat <<'TAIL'

 Paste this whole report into the chat to get it read back to you.
 Phase order and scripts: README.md      Symptom index: reference/troubleshooting.md
TAIL
