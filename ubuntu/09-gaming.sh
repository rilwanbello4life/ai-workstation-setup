#!/usr/bin/env bash
# Phase 19 - gaming on Ubuntu.
#
# The point of this phase is to make Ubuntu the machine you actually use, with
# Windows kept bootable as a fallback you rarely touch. Whether that works is
# decided by anti-cheat, not by performance: Proton runs most games at 90-100%
# of Windows framerate, but cannot run kernel-level anti-cheat the publisher
# has not enabled for Linux. Valorant, Fortnite, Destiny 2, PUBG, modern Call
# of Duty and Rainbow Six Siege do not run here at all, and there is no
# workaround worth the ban risk.
#
# The second constraint is memory. A game wants most of the VRAM and 8-16 GB
# of RAM; Strata has mlocked 25-40 GB and holds the rest of the VRAM. Use
# 'ai-pause' before playing and 'ai-resume' after.
#
# Background: reference/linux-gaming.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

while (( $# )); do
    case "$1" in
        -y|--yes)  shift ;;
        -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
section "Prerequisites"

if ! have nvidia-smi; then
    die "No NVIDIA driver. Run ./01-nvidia.sh and reboot first."
fi
ok "Driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"

# Steam is 32-bit in places and will not install without this.
if ! dpkg --print-foreign-architectures | grep -q i386; then
    info "Enabling the i386 architecture (Steam needs 32-bit libraries)."
    sudo dpkg --add-architecture i386
    sudo apt-get update -qq
fi
ok "i386 architecture enabled."

# ---------------------------------------------------------------------------
section "Steam and tools"

# steam-installer pulls Valve's own bootstrap, which then self-updates. The
# distro 'steam' package is a thin wrapper around the same thing.
PKGS=(steam-installer gamemode mangohud lutris)
MISSING=()
for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done

if (( ${#MISSING[@]} )); then
    info "Installing: ${MISSING[*]}"
    sudo apt-get install -y "${MISSING[@]}"
fi
ok "Steam, GameMode, MangoHud and Lutris installed."

# Vulkan on both architectures: 32-bit games need the 32-bit loader and ICD.
info "Installing Vulkan loaders and Mesa utilities."
sudo apt-get install -y \
    libvulkan1 libvulkan1:i386 \
    mesa-vulkan-drivers mesa-vulkan-drivers:i386 \
    vulkan-tools >/dev/null
ok "Vulkan runtime present."

# ProtonUp-Qt manages Proton-GE, the community build that fixes games ahead of
# Valve's releases. Flatpak is how it is actually distributed.
if have flatpak; then
    if flatpak list --app 2>/dev/null | grep -q net.davidotek.pupgui2; then
        ok "ProtonUp-Qt already installed."
    else
        info "Installing ProtonUp-Qt for Proton-GE management."
        flatpak remote-add --if-not-exists --user flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
        flatpak install -y --user flathub net.davidotek.pupgui2 >/dev/null 2>&1 \
            && ok "Installed." \
            || warn "ProtonUp-Qt install failed. Not fatal; stock Proton still works."
    fi
else
    warn "Flatpak not present, skipping ProtonUp-Qt. Install later with:"
    warn "  sudo apt install flatpak && flatpak install flathub net.davidotek.pupgui2"
fi

# ---------------------------------------------------------------------------
section "Controllers"

# Steam ships these rules itself, but Lutris, Heroic and anything launched
# outside Steam do not, which is why a controller often works in one launcher
# and not another.
sudo tee /etc/udev/rules.d/99-gamepads.rules >/dev/null <<'EOF'
# Game controller access for non-Steam launchers.
# Steam installs equivalent rules; these cover Lutris, Heroic and direct runs.

# Sony DualSense / DualShock 4
SUBSYSTEM=="usb", ATTRS{idVendor}=="054c", MODE="0666", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{idVendor}=="054c", MODE="0666", TAG+="uaccess"

# Microsoft Xbox controllers and wireless adapters
SUBSYSTEM=="usb", ATTRS{idVendor}=="045e", MODE="0666", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{idVendor}=="045e", MODE="0666", TAG+="uaccess"

# Nintendo Switch Pro controller
SUBSYSTEM=="usb", ATTRS{idVendor}=="057e", MODE="0666", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{idVendor}=="057e", MODE="0666", TAG+="uaccess"

# Valve Steam Controller and Steam Deck
SUBSYSTEM=="usb", ATTRS{idVendor}=="28de", MODE="0666", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{idVendor}=="28de", MODE="0666", TAG+="uaccess"

# 8BitDo
SUBSYSTEM=="usb", ATTRS{idVendor}=="2dc8", MODE="0666", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{idVendor}=="2dc8", MODE="0666", TAG+="uaccess"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger
ok "Controller rules installed."

# GameMode needs the user in its group to raise priorities without prompting.
if getent group gamemode >/dev/null 2>&1; then
    if id -nG "$USER" | tr ' ' '\n' | grep -qx gamemode; then
        ok "Already in the gamemode group."
    else
        sudo usermod -aG gamemode "$USER"
        warn "Added to the gamemode group. Log out and back in for it to apply."
    fi
fi

# ---------------------------------------------------------------------------
section "MangoHud"

# A readable default rather than the wall of text MangoHud shows otherwise.
# vram and ram are first on purpose: on this machine they are the numbers that
# explain a bad framerate.
mkdir -p "$HOME/.config/MangoHud"
if [[ -f "$HOME/.config/MangoHud/MangoHud.conf" ]]; then
    ok "Existing MangoHud config left alone."
else
    cat > "$HOME/.config/MangoHud/MangoHud.conf" <<'EOF'
# Compact overlay. Toggle with Shift_R+F12.
legacy_layout=false
gpu_stats
gpu_temp
gpu_load_change
vram
cpu_stats
cpu_temp
ram
fps
frametime=1
frame_timing=1
gamemode
vulkan_driver
position=top-left
font_size=20
background_alpha=0.4
toggle_hud=Shift_R+F12
EOF
    ok "Wrote a compact MangoHud config."
fi

# ---------------------------------------------------------------------------
section "gaming-check"

sudo tee /usr/local/bin/gaming-check >/dev/null <<'CHECK_EOF'
#!/usr/bin/env bash
# Report whether this machine is currently able to run a game well.
set -uo pipefail

echo "=== GPU ==="
nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total \
           --format=csv,noheader 2>/dev/null || echo "  nvidia-smi unavailable"

echo
echo "=== Vulkan ==="
if command -v vulkaninfo >/dev/null 2>&1; then
    vulkaninfo --summary 2>/dev/null | grep -E 'driverName|deviceName|apiVersion' \
        | head -4 | sed 's/^/  /' || echo "  vulkaninfo produced no output"
else
    echo "  vulkan-tools not installed"
fi

echo
echo "=== GameMode ==="
if command -v gamemoded >/dev/null 2>&1; then
    gamemoded -s 2>/dev/null | sed 's/^/  /'
else
    echo "  not installed"
fi

echo
echo "=== Memory ==="
awk '/MemTotal|MemAvailable/ {printf "  %-14s %6.1f GB\n", $1, $2/1024/1024}' /proc/meminfo

echo
echo "=== Competing for resources ==="
busy=0
for p in strata llama-server comfyui; do
    if pgrep -f "$p" >/dev/null 2>&1; then
        echo "  $p is running"
        busy=1
    fi
done
if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
    running=$(kubectl get deploy -A --no-headers 2>/dev/null \
              | awk '$3 ~ /^[1-9]/ {n++} END {print n+0}')
    echo "  k3s: ${running} deployments running (~5 GB, fine to leave up)"
fi

# Someone else's work is the one thing here you cannot see by looking at the
# screen. Worth knowing before taking the GPU away: ai-pause drains first, so
# in-flight requests finish, but a long batch render can hold things for
# minutes. This only reports - a command called 'check' should not change
# anything, so draining stays an explicit choice.
shared=0
if command -v queue >/dev/null 2>&1; then
    qline="$(queue status --brief 2>/dev/null || true)"
    if [[ -n "$qline" ]]; then
        inflight="$(printf '%s\n' "$qline" | awk '/in flight/ {print $3 + $5}')"
        # the count can read "3, oldest waiting 14s", so keep only the digits
        queued="$(printf '%s\n'   "$qline" | awk '/^  queued/ {gsub(/[^0-9]/,"",$2); print $2}')"
        if [[ "${inflight:-0}" != 0 || "${queued:-0}" != 0 ]]; then
            echo "  queue: ${inflight:-0} request(s) running, ${queued:-0} waiting - someone is using it"
            shared=1
        else
            echo "  queue: idle"
        fi
    fi
fi

if (( busy || shared )); then
    echo
    echo "  A model server holds mlocked RAM and most of the VRAM. Free it:"
    echo "      ai-pause        then   ai-resume   when you are done"
    (( shared )) && \
    echo "      ai-pause drains the queue first, so nobody gets a dropped request."
else
    echo "  Nothing holding the GPU. Good to play."
fi

echo
echo "=== Session ==="
echo "  ${XDG_SESSION_TYPE:-unknown}  (X11 helps with older titles and overlays)"
CHECK_EOF
sudo chmod +x /usr/local/bin/gaming-check

ok "Installed 'gaming-check'."

# ---------------------------------------------------------------------------
section "Done"

cat <<'EOF'
  Enable Proton for every title, which Steam does not do by default:

      Steam > Settings > Compatibility
        [x] Enable Steam Play for supported titles
        [x] Enable Steam Play for all other titles

  Per game, under Properties > Launch Options:

      gamemoderun mangohud %command%

  Install games under your home directory: Settings > Storage > add a library
  folder. Keep them out of /srv, which is the backup target for platform and
  game-server data.

  Budget: the AI stack is installed in full and takes priority, so the Steam
  library gets roughly 221 GB - about two or three modern titles at once. Check
  before a big install, and delete rather than encroach on the free-space
  reserve:

      df -h /
      du -xh --max-depth=1 ~/ai

  What a 4 TB drive would buy back: reference/4tb-upgrade.md

  Before you play:

      gaming-check      is anything holding the GPU
      ai-pause          free the model's RAM and VRAM
      ai-resume         put back exactly what was running

  The thing that decides whether Windows can stay unused: these do not run on
  Linux at all, and no configuration changes that.

      Valorant            Vanguard, kernel-level
      Fortnite            EAC, Epic has not enabled Linux
      Destiny 2           BattlEye, bans Linux players
      PUBG: Battlegrounds BattlEye, not enabled
      Call of Duty        Ricochet, kernel-level
      Rainbow Six Siege   BattlEye, not enabled
      Roblox              support deliberately dropped

  Everything else: check protondb.com first. Gold or Platinum means it works.

  Full notes, including the Wayland and VRR caveats and a diagnosis order for
  games that will not start: reference/linux-gaming.md
EOF
