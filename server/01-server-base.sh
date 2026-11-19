#!/usr/bin/env bash
# Phase 12 - turn the workstation into something that stays up.
#
# The AI stack in ubuntu/ was built for a machine you log into. Several of its
# assumptions break the moment nobody is at the keyboard:
#
#   * user systemd units stop at logout
#   * suspend drops Tailscale and every in-flight connection
#   * an OOM kill with no swap takes the cluster down rather than one pod
#   * nothing applies security updates
#
# This fixes all four, and installs ai-pause / ai-resume / ai-status, which
# every later script and the gaming setup depend on.
#
# Read-only by default. Pass --apply to make changes.
#
# Background: reference/server-architecture.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

APPLY=no
while (( $# )); do
    case "$1" in
        --apply)   APPLY=yes; shift ;;
        -y|--yes)  APPLY=yes; shift ;;
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

changed=0
note_change() { changed=$(( changed + 1 )); }

# ---------------------------------------------------------------------------
section "This machine"

ram="$(ram_gb)"
info "System RAM: ${ram} GB usable"
# The platform costs ~15 GB and Strata's fit rule is experts plus ~10 GB for
# the OS, so what is left over decides the largest pack that can coexist with
# the cluster. Report that rather than a fixed model name.
if (( ram < 40 )); then
    warn "The platform needs ~15 GB before a model loads. At ${ram} GB it will"
    warn "not fit alongside Strata. Fit the 2x32 GB memory kit first."
    warn "See reference/ram-upgrade-decision.md."
else
    experts=$(( ram - 25 ))
    if (( experts >= 62 )); then
        ok "Enough RAM for the platform plus a model up to UD-IQ4_XS (~${experts} GB of experts)."
    elif (( experts >= 50 )); then
        ok "Enough RAM for the platform plus a model up to IQ3_S (~${experts} GB of experts)."
    else
        ok "Enough RAM for the platform plus a model up to IQ2_XS (~${experts} GB of experts)."
    fi
fi

avail="$(disk_avail_gb /)"
size="$(disk_size_gb /)"
info "Free space on /: ${avail} GB of ${size} GB"

# Settled size of the platform: k3s container images, Postgres, n8n execution
# history and the local backup copies. The reserve on top exists because a
# DRAM-less NVMe loses sustained write speed as it fills, and Postgres fsync
# latency is the first thing that degrades.
reserve=$(( size / 10 ))
if (( avail - reserve < 200 )); then
    warn "The platform settles at roughly 200 GB (k3s images, Postgres, n8n history, backups)."
    warn "After a ${reserve} GB reserve, only $(( avail - reserve )) GB is spendable."
    warn "Free space before going further - Strata packs and the Steam library are the big two."
fi

# ---------------------------------------------------------------------------
section "Sleep and suspend"

# A server that suspends is a server that is down. Masking the targets is
# stronger than a logind setting: nothing can request them, including the
# desktop's idle timer and the power button.
suspend_masked=yes
for unit in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    if systemctl is-enabled "$unit" >/dev/null 2>&1; then
        suspend_masked=no
    fi
done

if [[ "$suspend_masked" == yes ]]; then
    ok "Sleep, suspend and hibernate are masked."
elif [[ "$APPLY" == yes ]]; then
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    ok "Masked sleep, suspend, hibernate and hybrid-sleep."
    note_change
else
    todo "Sleep targets are active. --apply masks them."
fi

# The desktop session has its own idle timer that logind does not control.
if have gsettings && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    idle="$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || echo unknown)"
    if [[ "$idle" == "'nothing'" ]]; then
        ok "GNOME will not suspend on idle."
    elif [[ "$APPLY" == yes ]]; then
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
        gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
        ok "Disabled GNOME idle suspend and screen blanking."
        note_change
    else
        todo "GNOME idle suspend is $idle. --apply sets it to 'nothing'."
    fi
fi

# ---------------------------------------------------------------------------
section "User service lingering"

# Without linger, every systemctl --user unit dies at logout - including the
# voice server this kit installs. Lingering starts the user manager at boot.
if loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
    ok "Lingering is enabled for $USER."
elif [[ "$APPLY" == yes ]]; then
    sudo loginctl enable-linger "$USER"
    ok "Enabled lingering for $USER."
    note_change
else
    todo "Lingering is off. --apply enables it."
fi

# ---------------------------------------------------------------------------
section "Voice server as a system service"

# 06-voice.sh installs a --user unit. That is right for a workstation and
# wrong here: it stops at logout even with lingering if the user manager is
# restarted. Promote it to a system unit bound to the machine, not the session.
USER_UNIT="$HOME/.config/systemd/user/voice-server.service"
SYS_UNIT=/etc/systemd/system/voice-server.service
VOICE_DIR="$APPS/voice"

if [[ -f "$SYS_UNIT" ]]; then
    ok "voice-server is already a system service."
elif [[ ! -d "$VOICE_DIR" ]]; then
    info "Voice server not installed yet; skipping. Run ubuntu/06-voice.sh first."
elif [[ "$APPLY" == yes ]]; then
    sudo tee "$SYS_UNIT" >/dev/null <<EOF
[Unit]
Description=Whisper + Kokoro voice server (OpenAI-compatible)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$VOICE_DIR
Environment=HF_HOME=$AI_ROOT/hf-cache
Environment=HUGGINGFACE_HUB_CACHE=$AI_ROOT/hf-cache/hub
ExecStart=$VOICE_DIR/.venv/bin/python $VOICE_DIR/server.py --host 127.0.0.1 --port 8100
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    # Retire the user unit so the two cannot both bind port 8100.
    if [[ -f "$USER_UNIT" ]]; then
        systemctl --user disable --now voice-server.service 2>/dev/null || true
        mv "$USER_UNIT" "$USER_UNIT.replaced-by-system-unit"
        info "Disabled the old user unit."
    fi
    sudo systemctl daemon-reload
    sudo systemctl enable --now voice-server.service
    ok "voice-server now runs as a system service on port 8100."
    note_change
else
    todo "voice-server is a user unit. --apply promotes it to a system unit."
fi

# ---------------------------------------------------------------------------
section "Swap as OOM insurance"

# The kit deliberately ran without swap at 32 GB: Strata mlocks its weights, so
# swap could only hurt. With a cluster on top the calculus changes - an OOM
# kill with no swap takes whichever process the kernel picks, and that is
# often k3s rather than the thing that actually overcommitted.
#
# A small swapfile with swappiness 10 is insurance, not a memory extension.
# mlocked pages are never swapped, so Strata is unaffected either way.
SWAPFILE=/swapfile
if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
    ok "Swap is active: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
elif [[ "$APPLY" == yes ]]; then
    info "Creating a 16 GB swapfile."
    sudo fallocate -l 16G "$SWAPFILE" || sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=16384 status=progress
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE" >/dev/null
    sudo swapon "$SWAPFILE"
    grep -q "^$SWAPFILE" /etc/fstab || \
        echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
    ok "16 GB swapfile active and in /etc/fstab."
    note_change
else
    todo "No swap. --apply creates a 16 GB swapfile as OOM insurance."
fi

info "vm.swappiness is $(cat /proc/sys/vm/swappiness) - 10 is set by ubuntu/02-tune-linux.sh."

# ---------------------------------------------------------------------------
section "Unattended security updates"

if dpkg -s unattended-upgrades >/dev/null 2>&1 && \
   [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    ok "unattended-upgrades is installed and configured."
elif [[ "$APPLY" == yes ]]; then
    sudo apt-get install -y unattended-upgrades >/dev/null
    sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    # Security updates only, and never an automatic reboot - a reboot would
    # take the cluster down unannounced.
    sudo tee /etc/apt/apt.conf.d/51-ai-server >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF
    ok "Security updates will install automatically; reboots stay manual."
    note_change
else
    todo "unattended-upgrades not configured. --apply installs it."
fi

# ---------------------------------------------------------------------------
section "Firewall baseline"

# Every service binds to loopback and reaches the outside through Tailscale,
# so the firewall is defence in depth rather than the primary control. k3s
# needs its own interfaces exempted or pod networking breaks in confusing ways.
if have ufw && sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
    ok "ufw is active."
    sudo ufw status numbered | sed 's/^/    /'
elif [[ "$APPLY" == yes ]]; then
    sudo apt-get install -y ufw >/dev/null
    sudo ufw --force reset >/dev/null
    sudo ufw default deny incoming >/dev/null
    sudo ufw default allow outgoing >/dev/null
    # Tailscale carries all remote access.
    sudo ufw allow in on tailscale0 >/dev/null
    # k3s pod and service networks must not be filtered.
    sudo ufw allow in on cni0 >/dev/null 2>&1 || true
    sudo ufw allow from 10.42.0.0/16 >/dev/null   # pods
    sudo ufw allow from 10.43.0.0/16 >/dev/null   # services
    sudo ufw --force enable >/dev/null
    ok "ufw: deny inbound, allow Tailscale and the cluster networks."
    note_change
else
    todo "ufw not active. --apply applies a deny-inbound baseline."
fi

# ---------------------------------------------------------------------------
section "ai-pause, ai-resume and ai-status"

# These are the levers everything else leans on: freeing the platform's ~15 GB
# so a bigger model can load, and freeing everything before a gaming session.
PAUSE_BIN=/usr/local/bin/ai-pause

# Bumped whenever the helpers below change, so that re-running this script
# replaces an older copy instead of silently leaving it in place. Version 2
# added Argo CD ordering and the GPU queue drain.
HELPERS_VERSION=2

write_helpers() {
    sudo tee "$PAUSE_BIN" >/dev/null <<'PAUSE_EOF'
#!/usr/bin/env bash
# helpers-version: 2
# Free the server platform's memory so a larger model - or a game - can have it.
#
#   ai-pause              scale platform workloads to zero, stop the model server
#   ai-pause --cluster    also stop k3s itself, freeing its ~1.5 GB
#   ai-pause --games      only stop game servers
#
# Scales Deployments rather than deleting them, so persistent volumes and all
# state in Postgres survive untouched. ai-resume reverses it.
set -euo pipefail

STATE=/var/lib/ai-pause
sudo mkdir -p "$STATE"

stop_cluster=no
only_games=no
for a in "$@"; do
    case "$a" in
        --cluster) stop_cluster=yes ;;
        --games)   only_games=yes ;;
        -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

scale_ns_down() {
    local ns="$1"
    kubectl get ns "$ns" >/dev/null 2>&1 || return 0
    # Record current replica counts so ai-resume can restore them exactly.
    # Deployments and StatefulSets are recorded separately because Argo CD
    # runs its controller as a StatefulSet and it has to come back too.
    kubectl -n "$ns" get deploy -o \
        'jsonpath={range .items[*]}{.metadata.name}={.spec.replicas}{"\n"}{end}' \
        2>/dev/null | sudo tee "$STATE/$ns.replicas" >/dev/null
    kubectl -n "$ns" get statefulset -o \
        'jsonpath={range .items[*]}{.metadata.name}={.spec.replicas}{"\n"}{end}' \
        2>/dev/null | sudo tee "$STATE/$ns.statefulsets" >/dev/null
    kubectl -n "$ns" scale deploy --all --replicas=0 >/dev/null 2>&1 || true
    kubectl -n "$ns" scale statefulset --all --replicas=0 >/dev/null 2>&1 || true
    echo "  paused namespace: $ns"
}

# Let in-flight generations finish and stop admitting new ones, so a friend
# mid-request gets an answer rather than a dropped connection.
if command -v queue >/dev/null 2>&1; then
    queue drain >/dev/null 2>&1 && echo "  drained the GPU queue" || true
fi

if command -v kubectl >/dev/null 2>&1; then
    # Argo CD FIRST, and this ordering is not cosmetic. With self-heal on,
    # a controller that is still running sees replicas:0 as drift from the
    # manifest and scales everything back up within a couple of seconds. The
    # memory never comes back and nothing in the output says why.
    scale_ns_down argocd

    scale_ns_down games
    [[ "$only_games" == yes ]] || scale_ns_down platform
fi

if [[ "$only_games" != yes ]]; then
    if command -v strata >/dev/null 2>&1; then
        strata launch --stop >/dev/null 2>&1 && echo "  stopped Strata" || true
    fi
    systemctl is-active --quiet llama-server 2>/dev/null && \
        sudo systemctl stop llama-server && echo "  stopped llama.cpp" || true
fi

if [[ "$stop_cluster" == yes ]]; then
    sudo systemctl stop k3s && echo "  stopped k3s"
    sudo touch "$STATE/k3s-stopped"
fi

echo
free -g | awk 'NR<=2 {print "  " $0}'
PAUSE_EOF
    sudo chmod +x "$PAUSE_BIN"

    sudo tee /usr/local/bin/ai-resume >/dev/null <<'RESUME_EOF'
#!/usr/bin/env bash
# helpers-version: 2
# Reverse ai-pause, restoring the replica counts it recorded.
set -euo pipefail
STATE=/var/lib/ai-pause

if [[ -f "$STATE/k3s-stopped" ]]; then
    sudo systemctl start k3s
    sudo rm -f "$STATE/k3s-stopped"
    echo "  started k3s, waiting for the API"
    for _ in $(seq 1 60); do
        kubectl get nodes >/dev/null 2>&1 && break
        sleep 2
    done
fi

restore_kind() {
    local ns="$1" kind="$2" file="$3"
    [[ -f "$file" ]] || return 0
    while IFS='=' read -r name replicas; do
        [[ -n "$name" ]] || continue
        # Anything recorded at zero was already scaled down on purpose.
        [[ "${replicas:-0}" -gt 0 ]] || continue
        kubectl -n "$ns" scale "$kind/$name" --replicas="$replicas" >/dev/null 2>&1 || true
    done < "$file"
}

restore_ns() {
    local ns="$1"
    kubectl get ns "$ns" >/dev/null 2>&1 || return 0
    restore_kind "$ns" deploy       "$STATE/$ns.replicas"
    restore_kind "$ns" statefulset  "$STATE/$ns.statefulsets"
    echo "  resumed namespace: $ns"
}

if command -v kubectl >/dev/null 2>&1; then
    restore_ns platform
    restore_ns games

    # Argo CD LAST, mirroring ai-pause. Bringing the controller back before
    # the workloads it manages means it spends its first reconciliation
    # racing ai-resume to set the same replica counts.
    restore_ns argocd
fi

systemctl is-enabled --quiet llama-server 2>/dev/null && \
    sudo systemctl start llama-server && echo "  started llama.cpp" || true

echo
echo "  Strata is not restarted automatically - choose a pack:"
echo "      strata launch --list-presets"
echo "      strata launch --preset <name>"
RESUME_EOF
    sudo chmod +x /usr/local/bin/ai-resume

    sudo tee /usr/local/bin/ai-status >/dev/null <<'STATUS_EOF'
#!/usr/bin/env bash
# helpers-version: 2
# What is running, and what it is costing in memory and VRAM.
set -uo pipefail

echo "=== Memory ==="
free -h | awk 'NR<=2 {print "  " $0}'
echo
echo "  swap in use: $(free -h | awk '/Swap/ {print $3 " of " $2}')"

echo
echo "=== GPU ==="
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu \
               --format=csv,noheader | sed 's/^/  /'
    echo "  processes holding VRAM:"
    nvidia-smi --query-compute-apps=pid,process_name,used_memory \
               --format=csv,noheader 2>/dev/null | sed 's/^/    /' || true
else
    echo "  nvidia-smi not available"
fi

echo
echo "=== Model servers ==="
for entry in "8080:Strata" "8081:llama.cpp" "8100:voice" "8101:gpu-probe" "8188:ComfyUI"; do
    p="${entry%%:*}"; name="${entry#*:}"
    if ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
        printf '  :%-5s %-12s listening\n' "$p" "$name"
    else
        printf '  :%-5s %-12s down\n' "$p" "$name"
    fi
done

echo
echo "=== Platform ports ==="
for entry in "4000:LiteLLM" "4100:gpu-queue" "5678:n8n" "3000:Open WebUI" "8090:Argo CD"; do
    p="${entry%%:*}"; name="${entry#*:}"
    if ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
        printf '  :%-5s %-12s listening\n' "$p" "$name"
    else
        printf '  :%-5s %-12s down\n' "$p" "$name"
    fi
done

# The queue knows what is actually waiting, which free(1) and nvidia-smi do
# not: a deep queue on an idle GPU means admission is blocked, not that
# nothing is happening.
if command -v queue >/dev/null 2>&1; then
    echo
    echo "=== GPU queue ==="
    queue status --brief 2>/dev/null | sed 's/^/  /' || echo "  not responding"
fi

echo
echo "=== Cluster ==="
if systemctl is-active --quiet k3s 2>/dev/null; then
    kubectl get deploy -A --no-headers 2>/dev/null | \
        awk '{printf "  %-12s %-28s %s\n", $1, $2, $3}' || echo "  API not responding"
else
    echo "  k3s is stopped"
fi
STATUS_EOF
    sudo chmod +x /usr/local/bin/ai-status
}

# An installed-but-stale copy is worse than a missing one: ai-pause would
# still appear to work while leaving Argo CD running to undo it. Compare the
# version marker rather than just checking the file exists.
# The '|| true' is load-bearing. awk exits 2 when the file is absent, and
# under set -e a failed command substitution takes the whole script down with
# it - silently, because of the 2>/dev/null. The file is absent on exactly
# the machines that need these helpers installed, so this line used to kill
# the run one step before writing them: --apply could only ever update
# helpers that already existed.
installed_version="$(awk -F': ' '/^# helpers-version:/{print $2; exit}' "$PAUSE_BIN" 2>/dev/null || true)"

if [[ -x "$PAUSE_BIN" && "${installed_version:-0}" == "$HELPERS_VERSION" ]]; then
    ok "ai-pause, ai-resume and ai-status are installed (v$HELPERS_VERSION)."
elif [[ "$APPLY" == yes ]]; then
    write_helpers
    if [[ -n "${installed_version:-}" ]]; then
        ok "Updated the helpers from v$installed_version to v$HELPERS_VERSION."
    elif [[ -x "$PAUSE_BIN" ]]; then
        ok "Replaced the pre-versioning helpers with v$HELPERS_VERSION."
    else
        ok "Installed ai-pause, ai-resume and ai-status to /usr/local/bin."
    fi
    note_change
elif [[ -x "$PAUSE_BIN" ]]; then
    todo "Helpers are v${installed_version:-1}, this kit ships v$HELPERS_VERSION. --apply updates them."
else
    todo "Helpers not installed. --apply writes ai-pause/ai-resume/ai-status."
fi

# ---------------------------------------------------------------------------
section "Platform directories"

if [[ -d "$PLATFORM_DIR" && -d "$GAMES_DIR" && -d "$BACKUP_DIR" ]]; then
    ok "/srv layout exists."
elif [[ "$APPLY" == yes ]]; then
    sudo mkdir -p "$PLATFORM_DIR" "$GAMES_DIR" "$BACKUP_DIR"
    sudo chown -R "$USER:$USER" "$SRV_ROOT"
    ok "Created $PLATFORM_DIR, $GAMES_DIR and $BACKUP_DIR."
    note_change
else
    todo "/srv layout missing. --apply creates it."
fi

# ---------------------------------------------------------------------------
section "Summary"

if [[ "$APPLY" != yes ]]; then
    cat <<EOF
  Nothing was changed. To action the items above:

      ./01-server-base.sh --apply

  Then continue with ./02-k3s.sh
EOF
    exit 0
fi

ok "$changed change(s) applied."
cat <<'EOF'

  New commands:

      ai-status      what is running and what it costs
      ai-pause       free the platform's ~15 GB for a bigger model
      ai-resume      bring it back

  Note that masking the sleep targets means the power button no longer
  suspends. Shut down with: systemctl poweroff

  Next: ./02-k3s.sh
EOF
