#!/usr/bin/env bash
# Phase 8.1 - NVIDIA driver for the RTX 5070 Ti.
#
# Blackwell cards work ONLY with NVIDIA's open kernel modules. Installing the
# classic proprietary driver leaves you on a software-rendered desktop.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

section "GPU detection"

if ! have lspci; then
    sudo apt-get install -y -qq pciutils
fi

gpu_line="$(lspci -nn | grep -i 'VGA\|3D controller' | grep -i nvidia || true)"
if [[ -z "$gpu_line" ]]; then
    die "No NVIDIA GPU found by lspci."
fi
info "$gpu_line"

# 10de:2b83 is the GeForce RTX 5070 Ti.
if grep -qi '10de:2b83' <<<"$gpu_line"; then
    ok "RTX 5070 Ti confirmed (Blackwell, sm_120)."
elif grep -qiE '10de:2b8[0-9a-f]|10de:2c[0-9a-f]{2}|10de:2d30' <<<"$gpu_line"; then
    ok "Blackwell-class GPU detected."
else
    warn "This does not look like a Blackwell card. The open modules are still fine"
    warn "on any Turing or newer GPU, so continuing."
fi

section "Secure Boot"

if have mokutil && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    secure_boot=yes
    warn "Secure Boot is ENABLED."
    warn "The installer will ask you to set a one-time MOK password."
    warn "On the next reboot a blue 'MOK Manager' screen appears:"
    warn "    Enroll MOK -> Continue -> Yes -> enter that password -> Reboot"
    warn "Miss it and Secure Boot will block the driver."
    echo
    # MOK Manager is a UEFI application with a hardcoded US keyboard map. On a
    # Swedish layout every symbol lands on a different key, so a password with
    # punctuation in it cannot be typed back correctly and looks like a wrong
    # password. Digits are identical in both layouts.
    warn "USE DIGITS ONLY for that password, e.g. 12345678."
    warn "The blue screen types on a US keyboard layout whatever your keyboard"
    warn "is, so symbols will not come back the way you typed them here."
    warn "It is discarded once the key is enrolled and protects nothing after."
else
    secure_boot=no
    info "Secure Boot is disabled or undetectable; no MOK enrollment needed."
fi

section "Installing the driver"

add_nvidia_repo

sudo apt-get update -qq

installed=no
# NVIDIA's metapackage, available once the repo above is configured.
if apt-cache show nvidia-open >/dev/null 2>&1; then
    info "Installing nvidia-open (NVIDIA open kernel modules)."
    if sudo apt-get install -y nvidia-open; then
        installed=yes
        ok "nvidia-open installed."
    fi
fi

# Fall back to Ubuntu's own packaging, picking the newest -open driver.
if [[ "$installed" == no ]]; then
    warn "nvidia-open unavailable; trying Ubuntu's driver packages."
    candidate="$(apt-cache search --names-only '^nvidia-driver-[0-9]+-open$' |
                 awk '{print $1}' | sort -V | tail -n1)"
    if [[ -n "$candidate" ]]; then
        info "Installing $candidate"
        sudo apt-get install -y "$candidate" && installed=yes && ok "$candidate installed."
    fi
fi

[[ "$installed" == yes ]] || die "Driver installation failed. Check 'ubuntu-drivers devices'."

section "Next"

if [[ "$secure_boot" == yes ]]; then
    todo "Reboot now and complete the MOK enrollment on the blue screen."
else
    todo "Reboot now to load the new kernel module."
fi

cat <<'EOF'

  After rebooting, verify with:

      nvidia-smi

  Expect the RTX 5070 Ti and driver 580 or newer. Then continue with:

      ./02-tune-linux.sh

  If nvidia-smi finds no devices, the key did not enrol. Re-arm it with:

      sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
      mokutil --list-new | head     # confirm it is pending, then reboot

  A failed or cancelled enrolment deletes the pending request, which is why
  the blue screen stops appearing. See reference/troubleshooting.md.

EOF
