# Deferred to a 4 TB upgrade

Nothing in this kit was deleted when the build landed on a 2 TB drive instead of 4 TB. Everything that no longer fits, or that got trimmed to make room, is recorded here with its size, so you can cherry-pick an item back when you want it or restore the whole plan if you upgrade the drive.

**The AI stack was not cut.** The full Strata catalogue through tier F, every ComfyUI model, the GGUF set and the voice models all fit on 2 TB and are installed as originally planned. What absorbed the difference is gaming and headroom. That ordering was deliberate.

## Where the space actually went

| | 4 TB plan | 2 TB build | Difference |
|---|---:|---:|---:|
| Ubuntu, desktop and applications | 50 GB | 50 GB | — |
| **Strata, catalogue through tier E** | **677 GB** | **677 GB** | **—** |
| **Strata, tier F — UD-IQ4_XS** | **111 GB** | **111 GB** | **—** |
| ComfyUI image models | 20 GB | 20 GB | — |
| ComfyUI video models | 55 GB | 55 GB | — |
| GGUF chat models | 30 GB | 30 GB | — |
| Voice models | 3 GB | 3 GB | — |
| k3s and container images | 50 GB | 50 GB | — |
| Postgres, n8n and app volumes | 50 GB | 50 GB | — |
| Game-server worlds | 200 GB | 100 GB | **−100 GB** |
| Local backups under `/srv/backups` | not budgeted | 100 GB | +100 GB |
| Reserved free space | not budgeted (would be 372 GB) | 186 GB | — |
| **Steam library** | **~2 007 GB available** | **~431 GB available** | **−1 576 GB** |

Two of those rows are corrections rather than cuts. The original 4 TB budget never accounted for the local backup copies that phase 18 writes, nor for the Steam library that phase 19 installs — both were added to the kit after that table was written. They would have had to come out of the 4 TB plan too.

## The original 4 TB budget, preserved

This is the table that was in [partition-layout.md](partition-layout.md) before the drive changed, kept verbatim so the reasoning is not lost:

| Item | Size |
|---|---:|
| Ubuntu, desktop and applications | ~50 GB |
| Strata, full catalogue through tier E | ~677 GB |
| ComfyUI image models | 20 GB |
| ComfyUI video models | 55 GB |
| GGUF chat models | 30 GB |
| Voice models | 3 GB |
| k3s and container images | ~50 GB |
| Postgres, n8n and app volumes | ~50 GB |
| Game-server worlds | ~200 GB |
| **Total** | **~1 135 GB** |

> A 4 TB drive formats to roughly 3 725 GiB, so this leaves about **2.5 TB free** even with every Strata pack downloaded and a shelf of game servers. Storage stopped being a constraint the moment you chose 4 TB — RAM is the only thing you now have to ration.

## Cherry-pick list

Things you can add back individually on the 2 TB drive, cheapest first. Check `df -h /` before each — the 186 GB reserve is not spare capacity, it is what keeps the drive writing at full speed.

| Item | Size | What it costs you |
|---|---:|---|
| Game-server worlds back to 200 GB | +100 GB | Steam library drops to ~442 GB |
| A second large game-server world (modded Minecraft, Satisfactory) | +50–100 GB | Same trade, smaller |
| **DeepSeek V4.1-Flash** | **+257 GB** | Steam drops to ~285 GB. See the caution below |
| Raising the Windows Strata install past Coder + Qwen3.6 | +23–92 GB each | Comes off the Windows 1 TB, not this drive |

### On DeepSeek V4.1-Flash

It is the one AI item that genuinely does not fit comfortably, and disk is only half the reason. It wants **257 GB** and measures around **5 tok/s** on a 16 GB card — slower than you can read. It was already outside the recommended set on the 4 TB plan for that reason, so this is not something the smaller drive took away from you.

If you want it anyway, it fits — it just leaves roughly 285 GB for games.

## What a 4 TB drive would actually buy

Honest summary, since you may be weighing the upgrade:

- **At 64 GB of RAM, nothing for AI capability.** Every model that fits in 64 GB already fits on 2 TB. The binding constraint is memory, not disk.
- **At 96 GB, that changes.** UD-IQ4_XS at ~111 GB was taken into the default install as tier F, and it cost the Steam library about 111 GB to do it — the figure above dropped from 542 GB to 431 GB. UD-Q4_K_XL at a further ~130 GB, and NVFP4, no longer fit alongside it without giving up games more or less entirely. This is the first time disk has limited what this machine can *run* rather than what it can store. See [ram-upgrade-decision.md](ram-upgrade-decision.md).
- **About 1 576 GB more for games** — roughly eighteen more modern titles installed at once rather than deleting and re-downloading. This is still the largest practical difference, and on a 4 TB drive UD-Q4_K_XL and NVFP4 both become affordable without touching it.
- **Room for DeepSeek without trade-offs**, if the 5 tok/s ever becomes acceptable to you.
- **A larger SLC write cache**, because these drives scale cache with capacity. A 4 TB drive holding the same ~1.2 TB sits at 33% full rather than 61%, and sustained write speed holds up better as a result.

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
