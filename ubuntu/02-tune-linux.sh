#!/usr/bin/env bash
# Phase 8.2 - Linux performance tuning for local AI.
#
# Four things matter on this machine, in order of impact:
#   1. memlock limits   - Strata pins 25-60 GB; the 8 MB default blocks it
#   2. swappiness       - zram swap plus a pinned model is a bad pairing
#   3. CPU governor     - MoE experts run on the CPU, so clocks matter
#   4. console mode     - frees the 1-1.5 GB of VRAM the desktop holds
#
# Everything here is reversible and nothing is applied silently.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

# ---------------------------------------------------------------------------
section "Memory lock limit"

# Strata mlocks a large share of the model so the kernel cannot page it out
# mid-generation. Ubuntu's default RLIMIT_MEMLOCK is 8 MB, which makes that
# fail outright or silently degrade to unpinned memory.
current_memlock="$(ulimit -l)"
info "Current limit for this shell: $current_memlock KB"

limits_file="/etc/security/limits.d/90-ai-memlock.conf"
if [[ -f "$limits_file" ]]; then
    ok "Already configured: $limits_file"
else
    sudo tee "$limits_file" >/dev/null <<'EOF'
# Raised for local AI inference. Strata and llama.cpp pin tens of gigabytes
# so the kernel cannot page model weights out during generation.
*    soft    memlock    unlimited
*    hard    memlock    unlimited
root soft    memlock    unlimited
root hard    memlock    unlimited
EOF
    ok "Wrote $limits_file"
    warn "Takes effect at your next login, not in this shell."
fi

# PAM limits do not apply to systemd user services, which need this instead.
sysd_dir="/etc/systemd/user.conf.d"
sudo mkdir -p "$sysd_dir"
if [[ -f "$sysd_dir/90-ai-memlock.conf" ]]; then
    ok "systemd user limit already configured."
else
    sudo tee "$sysd_dir/90-ai-memlock.conf" >/dev/null <<'EOF'
[Manager]
DefaultLimitMEMLOCK=infinity
EOF
    ok "Wrote $sysd_dir/90-ai-memlock.conf"
fi

# ---------------------------------------------------------------------------
section "Virtual memory"

sysctl_file="/etc/sysctl.d/90-ai-tuning.conf"
if [[ -f "$sysctl_file" ]]; then
    ok "Already configured: $sysctl_file"
else
    sudo tee "$sysctl_file" >/dev/null <<'EOF'
# Local AI tuning.

# Ubuntu defaults to 60. With zram swap and a 25-60 GB pinned model, eager
# swapping evicts pages that are about to be needed again.
vm.swappiness = 10

# Strata memory-maps a ~68 GB file. Keep cached pages around longer.
vm.vfs_cache_pressure = 50

# Large models need many mappings; the default can be hit by mmap-heavy
# inference engines.
vm.max_map_count = 1048576
EOF
    sudo sysctl --system >/dev/null
    ok "Wrote $sysctl_file and applied it."
fi

info "swappiness      = $(cat /proc/sys/vm/swappiness)"
info "max_map_count   = $(cat /proc/sys/vm/max_map_count)"

# ---------------------------------------------------------------------------
section "CPU governor"

if have cpupower || sudo apt-get install -y -qq linux-tools-common "linux-tools-$(uname -r)" 2>/dev/null; then
    :
fi

gov_file=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
if [[ -r "$gov_file" ]]; then
    info "Current governor: $(cat "$gov_file")"
    avail="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo '')"

    # amd-pstate in active mode exposes 'performance' / 'powersave' only, and
    # powersave there is not what the name suggests - it still boosts.
    if [[ "$avail" == *performance* ]]; then
        if confirm "Set all cores to the 'performance' governor?"; then
            echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
            ok "Governor set to performance."

            unit=/etc/systemd/system/cpu-performance.service
            sudo tee "$unit" >/dev/null <<'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable cpu-performance.service >/dev/null 2>&1
            ok "Made persistent across reboots."
        else
            info "Left unchanged."
        fi
    else
        info "Available governors: ${avail:-unknown}"
    fi
else
    warn "cpufreq not exposed; skipping. Check that amd_pstate is loaded."
fi

# ---------------------------------------------------------------------------
section "NVIDIA persistence mode"

if have nvidia-smi; then
    # Without persistence the driver unloads between processes, adding seconds
    # of re-initialisation to every run.
    if systemctl list-unit-files 2>/dev/null | grep -q nvidia-persistenced; then
        sudo systemctl enable --now nvidia-persistenced >/dev/null 2>&1 && \
            ok "nvidia-persistenced enabled." || \
            warn "Could not enable nvidia-persistenced."
    else
        sudo nvidia-smi -pm 1 >/dev/null 2>&1 && ok "Persistence mode on (this boot only)." || \
            warn "Could not set persistence mode."
    fi
    nvidia-smi --query-gpu=name,persistence_mode,memory.total --format=csv | sed 's/^/    /'
else
    warn "nvidia-smi not found. Run ./01-nvidia.sh first."
fi

# ---------------------------------------------------------------------------
section "Console mode helper"

# The desktop session holds 1-1.5 GB of VRAM. On a 16 GB card that is the
# difference between a model fitting and spilling to system RAM.
helper=/usr/local/bin/ai-console-mode
sudo tee "$helper" >/dev/null <<'EOF'
#!/usr/bin/env bash
# Drop to a text console to free the VRAM the desktop holds, or return to it.
#
#   ai-console-mode off   stop the graphical session (frees 1-1.5 GB VRAM)
#   ai-console-mode on    bring the desktop back
#   ai-console-mode       show current VRAM usage
set -euo pipefail

case "${1:-status}" in
    off)
        echo "Stopping the graphical session. Switch to a TTY with Ctrl+Alt+F3 if needed."
        sudo systemctl isolate multi-user.target
        ;;
    on)
        sudo systemctl isolate graphical.target
        ;;
    status)
        nvidia-smi --query-gpu=memory.used,memory.total --format=csv
        echo
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
        ;;
    *)
        echo "usage: $0 [on|off|status]" >&2
        exit 1
        ;;
esac
EOF
sudo chmod +x "$helper"
ok "Installed $helper"

# ---------------------------------------------------------------------------
section "Environment"

ensure_ai_dirs
ok "Created $AI_ROOT/{strata,gguf,comfyui,voice,hf-cache}"

profile="$HOME/.profile"
marker="# ai-workstation-setup"
if grep -q "$marker" "$profile" 2>/dev/null; then
    ok "Already configured in $profile"
else
    cat >> "$profile" <<EOF

$marker
export AI_ROOT="$AI_ROOT"
export HF_HOME="\$AI_ROOT/hf-cache"
export HUGGINGFACE_HUB_CACHE="\$AI_ROOT/hf-cache/hub"
export PATH="\$HOME/.local/bin:\$PATH"
EOF
    ok "Added AI_ROOT, HF_HOME and HUGGINGFACE_HUB_CACHE to $profile"
fi

# ---------------------------------------------------------------------------
section "Summary"

cat <<EOF
  Applied:
    memlock unlimited       so Strata can pin 25-60 GB
    vm.swappiness=10        so zram does not fight the model
    vm.max_map_count raised for mmap-heavy inference
    NVIDIA persistence      no driver re-init between runs
    ai-console-mode         frees desktop VRAM on demand

  Log out and back in for the memlock change to apply, then confirm:

      ulimit -l          # should print 'unlimited'

  Before loading a large model, consider:

      ai-console-mode off

  Next: ./03-python-cuda.sh
EOF
