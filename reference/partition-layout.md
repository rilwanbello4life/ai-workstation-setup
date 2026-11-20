# Drive layout: two independent systems

One drive per operating system. Neither can see the other's filesystem, neither can damage the other's boot chain, and both run on their native filesystem at full speed.

## The layout

**Disk 0 — Kingston NV3 1 TB: Windows**

- Factory Windows 11 install, left exactly as it came
- Its own EFI System Partition, untouched by anything in this kit
- Games, plus the Windows AI stack under `C:\AI`

**Disk 1 — 2 TB NVMe: Ubuntu**

- Entire drive, single ext4 root
- **Its own EFI System Partition**, created by the Ubuntu installer
- Ubuntu, applications under `~/apps`, AI models under `~/ai`

No swap *partition*. Ubuntu 24.04 uses zram by default, and phase 12 adds a 16 GB swapfile on the root filesystem as OOM insurance once the cluster is running — a file is easier to resize or remove later than a partition. Strata's `mlock`ed pages are never swapped either way, so this costs nothing in model performance.

## Why separate EFI partitions

The usual dual-boot advice is to share one ESP. Two is better here:

- A Windows feature update cannot overwrite or de-prioritise GRUB
- Ubuntu's installer never writes to the Windows disk at all
- Either drive can be pulled out and the other still boots
- Recovering one OS cannot break the other

The cost is that you pick the OS from the firmware boot menu (**F8** on ASUS) rather than a GRUB menu. In exchange, the two systems are genuinely independent rather than merely separate.

Set whichever you use more often as the default in BIOS under Boot > Boot Option Priorities.

## Which M.2 slot

The ASUS TUF GAMING B850-PLUS WIFI has three M.2 slots and they are not equivalent.

- **M.2_1** — PCIe 5.0 x4, 2280 only, has its own screwed-on heatsink. Occupied by the factory 1 TB drive.
- **M.2_2** — PCIe 4.0 x4, accepts 2242 through 22110. **The 2 TB Ubuntu drive goes here.**
- **M.2_3** — PCIe 4.0 x4, but **disables the PCIe 4.0 x16 slot when populated**. Never use it.

Since both drives are PCIe 4.0 parts, there is nothing to gain from relocating anything to the Gen 5 slot.

## Physical install

1. Full shutdown, switch off the PSU, unplug the power cable, hold the power button five seconds to drain.
2. Ground yourself — anti-static strap, or keep a hand on the bare chassis.
3. Remove the tempered-glass side panel of the TUF GT302.
4. Unscrew the M.2_2 heatsink, peel the blue film off the thermal pad beneath it.
5. Insert the drive at roughly 30 degrees, press flat, secure with the clip or screw.
6. Refit the heatsink. Do not overtighten. The NV3 throttles after about 40 seconds of sustained load when bare, so this is not optional.
7. Leave the side panel off — you will be unplugging the Windows drive shortly, during the Ubuntu install.

## Directory layout

Both systems use the same structure so they are navigable the same way, even though they share nothing.

```
C:\AI\                     (Windows)        ~/ai/           (Ubuntu)
├── strata\                                 ├── strata/      Strata model packs
├── hf-cache\                               ├── hf-cache/    HF_HOME
├── gguf\                                   ├── gguf/        llama.cpp / LM Studio models
├── comfyui\models\                         ├── comfyui/models/
├── comfyui\output\                         ├── comfyui/output/
└── voice\                                  └── voice/
```

Applications live separately: `~/apps` on Ubuntu, and under the normal install locations on Windows.

The server platform adds its own trees on Ubuntu, outside `~/ai` because they are machine state rather than downloadable assets:

```
/var/lib/rancher/k3s/        k3s itself, plus every pulled container image
/srv/platform/               Postgres, n8n, LiteLLM and app persistent volumes
/srv/games/                  game-server worlds and saves
```

`/srv` is deliberately separate from `$HOME`, so a user-account problem cannot take the cluster's data with it, and so backups can target one path.

## Disk budget

Strata is what makes this a real question. It serves several models, each 23–92 GB, and only one at a time — so how many you install is purely a disk decision. The two drives therefore get different answers.

### Ubuntu, 2 TB — the full AI stack fits; games take what is left

A 2 TB drive formats to roughly **1 863 GiB**. The AI stack is installed in full and nothing in it was trimmed:

| Item | Size |
|---|---:|
| Ubuntu, desktop and applications | ~50 GB |
| **Strata, tiers A-E** | **~673 GB** |
| **Strata, tier F — `unsloth/UD-IQ4_XS`** | **~94 GB** |
| **Strata, tier G — `unsloth/UD-Q4_K_XL` + `nvfp4/NVFP4`** | **~239 GB** |
| ComfyUI image models | 20 GB |
| ComfyUI video models | 55 GB |
| GGUF chat models | 30 GB |
| Voice models | 3 GB |
| k3s and container images | ~50 GB |
| Postgres, n8n and app volumes | ~50 GB |
| Game-server worlds | ~100 GB |
| Local backups under `/srv/backups` | ~100 GB |
| **Total** | **~1 464 GB** |

Against 1 863 GiB that leaves **399 GB**. Hold back **186 GB** as permanent free space — the reason is the next bullet list — and roughly **213 GB remains for a Steam library**.

Stopping earlier buys games back. Without tier G the total is ~1 225 GB, which leaves about **452 GB** for Steam; without tier F as well it is ~1 131 GB and about **546 GB**. Those are the three numbers worth knowing:

| Installed with | Strata takes | Steam gets |
|---|---:|---:|
| `--tier abcde` | ~673 GB | ~546 GB |
| `--tier abcdef` | ~767 GB | ~452 GB |
| `--tier all` | ~1 006 GB | ~213 GB |

So the ordering is: the entire AI stack, then the cluster and backups, then games with whatever is left. At `--tier abcdef` that is still six to eight modern titles installed simultaneously; at `--tier all` it is two or three. This is the only place the smaller drive costs you anything.

**Memory, not disk, is what limits which models you can run.** With the server platform up, the largest pack that fits in RAM is IQ2_XS at 64 GB or UD-IQ4_XS at 96 GB; anything above needs `ai-pause --cluster` first. Having all of them on disk means switching is a one-liner rather than a download, which is exactly why installing the full catalogue is worth the 1 006 GB.

### What is deliberately left out

`--tier all` is everything this *drive* can hold, not everything Strata offers. Strata publishes 28 family/model combinations across seven families; the installer takes 14. The remainder is mostly the larger Unsloth quants above `UD-Q4_K_XL` and the two other NVFP4 variants, and fetching them would need well over another terabyte — so they are a disk decision rather than an oversight.

Run `./07-strata.sh --catalogue` to list all 28 with their measured download sizes. It asks Strata and downloads nothing, so the numbers are current rather than copied from this page. See also [4tb-upgrade.md](4tb-upgrade.md) for what a larger drive would buy back.

Three things to keep an eye on:

- **Leave 10–15% of the drive empty, and treat that as a hard rule rather than tidiness.** Your drive is DRAM-less with a *dynamic* SLC write cache, which shrinks as the disk fills. Run it near full and sustained write speed drops sharply — on exactly the Postgres commits, image pulls and nightly backups this machine does all the time.
- **`/var/lib/rancher/k3s` grows quietly.** Container images accumulate across upgrades. `k3s crictl rmi --prune` reclaims them.
- **Postgres and n8n execution history grow without bound** unless pruned. [server-architecture.md](server-architecture.md) sets retention.

Check where you actually stand at any point with:

```bash
df -h /
du -xh --max-depth=1 ~/ai /srv 2>/dev/null | sort -h
```

Everything that was trimmed to make this fit, and everything a 4 TB drive would buy back, is itemised in [4tb-upgrade.md](4tb-upgrade.md) — including a cherry-pick list with sizes.

### Windows, 1 TB — shared with games

| Item | Size |
|---|---:|
| Windows and applications | ~80 GB |
| Strata: Coder + Qwen3.6 only | ~91 GB |
| ComfyUI image models | 20 GB |
| ComfyUI video models | 55 GB |
| GGUF chat models | 30 GB |
| Voice models | 3 GB |
| **Total** | **~279 GB**, leaving ~650 GB for games |

Install **Coder and Qwen3.6 UD-Q4_K_XL only** on Windows. Coder handles code, Qwen3.6 handles everything else, and together they are 91 GB rather than the 150 GB the full tier costs. [windows/03-tune-windows.ps1](../windows/03-tune-windows.ps1) reports this against your actual free space.

If it gets tighter still, **drop the ComfyUI video models from Windows next**. They are the largest remaining item at 55 GB, Wan 2.2 is the slowest thing you can run on a 16 GB card anyway, and Ubuntu will have them.

The per-model breakdown is in [strata-models.md](strata-models.md).

Disabling hibernation in Phase 1 also reclaims about 32 GB of `hiberfil.sys` on the Windows drive, which is worth having on a 1 TB disk.

## Moving files between the two systems

There is no shared partition, deliberately. The sharing it replaced cost more in complexity and performance than it was worth — Strata memory-maps its weights, and mmap over `ntfs3` is slower than native ext4.

On the rare occasion you need to move something, use the network. Both systems sit on the same LAN, so `scp` works, as does a USB stick. This comes up far less often than it sounds like it would, because each system has its own complete copy of everything it needs.

## One thing to expect

Windows cannot read ext4. Disk Management shows the 2 TB drive as a healthy partition with no filesystem and no drive letter, and Windows may occasionally offer to format it.

**Never accept.** Formatting destroys the Ubuntu install. Nothing is wrong; Windows simply has no ext4 driver and reports that badly.
