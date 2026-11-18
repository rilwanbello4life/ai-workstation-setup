# Phase 7 — Installing Ubuntu on its own drive

> **Done.** Both operating systems are installed and booting. This page is kept as the record of how the drive was laid out, and as the procedure to follow if you ever reinstall or move to a larger drive — see [4tb-upgrade.md](4tb-upgrade.md).

This is the only phase that can damage the Windows install, so it is written out step by step rather than scripted.

The approach is deliberately blunt: **physically unplug the Windows drive before installing Ubuntu.** An installer cannot touch a disk that is not connected. Every "I selected the wrong device" dual-boot disaster becomes impossible, and the Ubuntu installer gets a single empty disk to work with, which is the simplest case it handles.

## Why Ubuntu 24.04 LTS and not 26.04

Both are officially supported by NVIDIA. The difference is tooling completeness: NVIDIA publishes a `ubuntu2604` apt repository, but at present it contains only driver packages — no `cuda-toolkit-*` and no cuDNN — so on 26.04 the CUDA toolkit has to come from a runfile installer.

You almost certainly do not need the toolkit, since PyTorch wheels bundle their own runtime and cuDNN. But on a first build, pick the release where the fallback path exists.

## Before you start

Phase 1 handled the first two.

- [ ] BitLocker recovery key exported **and copied off this machine**
- [ ] Fast Startup and hibernation off (`powercfg /H off`)
- [ ] The 2 TB drive is fitted in **M.2_2** (Phase 3)
- [ ] Ubuntu 24.04.x LTS desktop ISO written to a USB stick with Rufus or balenaEtcher
- [ ] **Full shutdown**, not a restart

## Unplug the Windows drive

1. Full shutdown. Switch off the PSU, unplug the power cable, hold the power button five seconds to drain.
2. Open the side panel.
3. Unscrew the **M.2_1** heatsink and remove the 1 TB Kingston drive. Put it somewhere safe — it holds your Windows install.
4. Leave the 2 TB drive in M.2_2.
5. Reconnect power.

Only one drive is now visible to anything.

## Boot the installer

1. Power on, tap **F8** for the ASUS boot menu.
2. Choose the USB entry prefixed **UEFI:**. The non-UEFI entry produces a BIOS-mode install that will not coexist with your UEFI Windows.
3. Leave Secure Boot enabled. Ubuntu ships a signed shim and boots fine with it on.
4. Choose **Try Ubuntu** first and confirm Wi-Fi, display and mouse work before committing.

## Install

Choose **Erase disk and install Ubuntu**. With the Windows drive out of the machine, this is unambiguous and safe — there is only one disk, it is empty, and erasing it is exactly what you want.

Confirm the installer shows a single 2 TB device and nothing else before you continue.

This gives you:

- Ubuntu's **own EFI System Partition** on the 2 TB drive
- A single ext4 root filling the rest
- No swap partition, which is correct — Ubuntu 24.04 uses zram

Do not create a separate `/home`. With one user and everything under `~/ai` and `~/apps`, it only adds a boundary you will later have to resize.

Set up your user, let it finish, and reboot into Ubuntu once to confirm the desktop comes up.

## Plug the Windows drive back in

1. Full shutdown, power off, unplug, drain.
2. Refit the 1 TB drive into **M.2_1** and refit its heatsink.
3. Close up and power on.

## Choosing an OS from now on

Tap **F8** at power-on and pick from the firmware boot menu. You will see two entries — `ubuntu` and `Windows Boot Manager` — one per drive.

To set a default, enter BIOS with **Del**, go to Boot > Boot Option Priorities, and put whichever you use more often first. Press **F8** when you want the other one.

There is no GRUB menu listing Windows, and that is intentional. GRUB on the Ubuntu drive never learns about Windows, so a Windows feature update can never break it and vice versa. Each OS owns its own boot chain completely.

If you prefer a GRUB menu anyway, `sudo os-prober && sudo update-grub` will add a Windows entry. It works, but it reintroduces the coupling the two-ESP layout exists to avoid.

## Windows will not see the Ubuntu drive

Disk Management will show the 2 TB drive as a healthy partition with no filesystem and no drive letter, and Windows may offer to format it.

**Never accept.** Formatting destroys the Ubuntu install. Windows simply has no ext4 driver and reports that badly.

## NVIDIA driver and the MOK enrollment

Your RTX 5070 Ti is Blackwell (PCI ID `10de:2b83`, sm_120) and **requires NVIDIA's open kernel modules**. The proprietary non-open driver will not work.

Run [`../ubuntu/01-nvidia.sh`](../ubuntu/01-nvidia.sh), which installs `nvidia-open` and prompts for a MOK password.

**Set that password to digits only — `12345678` is fine.** The blue screen types on a hardcoded US keyboard layout whatever your keyboard is, so on a Swedish layout any symbol comes back as a different character and looks like a wrong password. It is one-time and protects nothing after enrollment.

On the reboot that follows, a blue **MOK Manager** screen appears. This is not an error.

1. Select **Enroll MOK**
2. Continue
3. Yes
4. Enter the password you just set
5. Reboot

Miss this screen, or fail the password, and Secure Boot blocks the driver and you get a slow software-rendered desktop. The screen does not come back by itself — shim deletes the pending request rather than blocking every boot. Re-arm it with `sudo mokutil --import /var/lib/shim-signed/mok/MOK.der` and reboot again; the full recovery path is in [troubleshooting.md](troubleshooting.md).

Verify afterwards:

```bash
nvidia-smi
```

You want the RTX 5070 Ti listed with driver 580 or newer.

## If Windows asks for the BitLocker recovery key

Possible but less likely now, since the Windows boot chain is untouched. Pulling and refitting the drive can still shift the TPM measurements BitLocker uses to unlock automatically.

Enter the 48-digit key you exported in Phase 1, let Windows boot, and it reseals itself. This is exactly why that key is step one of the whole plan.

## Then

Run [`../ubuntu/setup-all.sh`](../ubuntu/setup-all.sh) for the rest of the Ubuntu build, or follow [manual-ubuntu.md](manual-ubuntu.md) to do the same steps by hand.
