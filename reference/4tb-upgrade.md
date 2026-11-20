# Deferred to a 4 TB upgrade

Nothing in this kit was deleted when the build landed on a 2 TB drive instead of 4 TB. Everything that no longer fits, or that got trimmed to make room, is recorded here with its size, so you can cherry-pick an item back when you want it or restore the whole plan if you upgrade the drive.

**The AI stack was not cut.** The full Strata catalogue through tier F, every ComfyUI model, the GGUF set and the voice models all fit on 2 TB and are installed as originally planned. What absorbed the difference is gaming and headroom. That ordering was deliberate.

## Where the space actually went

| | 4 TB plan | 2 TB build | Difference |
|---|---:|---:|---:|
| Ubuntu, desktop and applications | 50 GB | 50 GB | — |
| **Strata, catalogue through tier E** | **673 GB** | **673 GB** | **—** |
| **Strata, tier F — `unsloth/UD-IQ4_XS`** | **94 GB** | **94 GB** | **—** |
| ComfyUI image models | 20 GB | 20 GB | — |
| ComfyUI video models | 55 GB | 55 GB | — |
| GGUF chat models | 30 GB | 30 GB | — |
| Voice models | 3 GB | 3 GB | — |
| k3s and container images | 50 GB | 50 GB | — |
| Postgres, n8n and app volumes | 50 GB | 50 GB | — |
| Game-server worlds | 200 GB | 100 GB | **−100 GB** |
| Local backups under `/srv/backups` | not budgeted | 100 GB | +100 GB |
| Reserved free space | not budgeted (would be 372 GB) | 186 GB | — |
| **Steam library** | **~2 011 GB available** | **~213 GB available** | **−1 798 GB** |

Two of those rows are corrections rather than cuts. The original 4 TB budget never accounted for the local backup copies that phase 18 writes, nor for the Steam library that phase 19 installs — both were added to the kit after that table was written. They would have had to come out of the 4 TB plan too.

## The original 4 TB budget, preserved

This is the table that was in [partition-layout.md](partition-layout.md) before the drive changed, kept so the reasoning is not lost. The structure is as it was; the Strata figure is the re-measured one, since quoting a number now known to be wrong would not preserve anything useful:

| Item | Size |
|---|---:|
| Ubuntu, desktop and applications | ~50 GB |
| Strata, full catalogue through tier E | ~673 GB |
| ComfyUI image models | 20 GB |
| ComfyUI video models | 55 GB |
| GGUF chat models | 30 GB |
| Voice models | 3 GB |
| k3s and container images | ~50 GB |
| Postgres, n8n and app volumes | ~50 GB |
| Game-server worlds | ~200 GB |
| **Total** | **~1 131 GB** |

> A 4 TB drive formats to roughly 3 725 GiB, so this leaves about **2.5 TB free** even with every Strata pack downloaded and a shelf of game servers. Storage stopped being a constraint the moment you chose 4 TB — RAM is the only thing you now have to ration.

## Cherry-pick list

Things you can add back individually on the 2 TB drive, cheapest first. Check `df -h /` before each — the 186 GB reserve is not spare capacity, it is what keeps the drive writing at full speed.

| Item | Size | What it costs you |
|---|---:|---|
| Game-server worlds back to 200 GB | +100 GB | Steam library drops to ~113 GB at `--tier all`, or ~352 GB at `--tier abcdef` |
| A second large game-server world (modded Minecraft, Satisfactory) | +50–100 GB | Same trade, smaller |
| **`nvfp4/NVFP4-NVIDIA` or `NVFP4-QAD`** | **~128 GB each** | The whole remaining Steam allocation for one variant of a pack you already have. Only sensible on 4 TB |
| **`unsloth` sizes above `UD-Q4_K_XL`** | **130 GB+ each** | Will not load in 96 GB either, so disk is the second problem rather than the first |
| `swift/IQ3_XXS`, `swift/IQ3_S` | ~150 GB for the pair | Runs fine at 64 GB; duplicates Flash-Next sizes you already have at tiers D and E |
| Raising the Windows Strata install past Coder + Qwen3.6 | +23–92 GB each | Comes off the Windows 1 TB, not this drive |

### What is no longer on this list

**DeepSeek V4.1-Flash has been removed from Strata.** Earlier revisions of this page carried it as the one AI item that genuinely needed the 4 TB upgrade — 257 GB for about 5 tok/s on a 16 GB card. A launch now answers *"Strata no longer offers DeepSeek models,"* so it is not a trade-off, a cherry-pick or an argument for a bigger drive any more. Nothing on this page reserves space for it.

What replaced it as the reason to want more disk is the other half of the Strata catalogue: 28 family/model combinations exist and `--tier all` installs 14. The rest are listed above, and `./07-strata.sh --catalogue` gives their measured sizes.

## What a 4 TB drive would actually buy

Honest summary, since you may be weighing the upgrade:

- **At 64 GB of RAM, nothing for AI capability.** Every model that fits in 64 GB already fits on 2 TB. The binding constraint is memory, not disk.
- **At 96 GB, that changes.** All three 96 GB packs are in the default install: `unsloth/UD-IQ4_XS` as tier F and `unsloth/UD-Q4_K_XL` plus `nvfp4/NVFP4` as tier G, ~333 GB between them. The Steam library absorbed all of it, falling from 546 GB to about 213 GB. This is the first time disk has limited what this machine can *run* rather than what it can store, and on a 2 TB drive the games are what pay for it. See [ram-upgrade-decision.md](ram-upgrade-decision.md).
- **About 1 798 GB more for games** — roughly twenty more modern titles installed at once rather than deleting and re-downloading. This is still the largest practical difference, and on a 4 TB drive `UD-Q4_K_XL` and `NVFP4` both become affordable without touching it.
- **Room for the half of the catalogue `--tier all` leaves out** — the remaining Unsloth quants, the other two NVFP4 variants and the Swift sizes, which together are well over another terabyte. On 2 TB they are a trade against games; on 4 TB they are simply affordable.
- **A larger SLC write cache**, because these drives scale cache with capacity. A 4 TB drive holding the same ~1.46 TB of stack sits at 39% full rather than 79%, and sustained write speed holds up better as a result.

## If you do upgrade

The machine has **no free M.2 slot in practice**: M.2_1 is Windows, M.2_2 is Ubuntu, and M.2_3 disables the PCIe 4.0 x16 slot when populated. So a 4 TB upgrade means replacing the Ubuntu drive, not adding to it.

Two routes:

**Clone.** Fit the 4 TB in M.2_3 temporarily, clone with `dd` or `rsync`, then swap it into M.2_2 and grow the filesystem:

```bash
sudo rsync -aHAXx --numeric-ids --info=progress2 / /mnt/new/
sudo resize2fs /dev/nvme1n1p2
```

Faster, but it carries over anything broken along with everything working.

**Reinstall.** Run phase 7 again, then `server/07-backup.sh`'s restore path to bring back Postgres, n8n workflows and secrets. Slower, and gives you a clean root. The backup job exists precisely so this is a real option — see [backups.md](backups.md).

Either way the Strata packs and Steam library are re-downloads, not backups. Do not spend restic space on them.
