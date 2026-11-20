# Phase 0 — Shopping list and pre-delivery prep

> **Bought and built.** The machine is assembled, both operating systems are installed, and the memory is ordered. Two things went differently from what this page recommends:
>
> - **The Ubuntu drive is 2 TB, not 4 TB.** The full Strata catalogue still fits; gaming absorbs the difference. What a 4 TB drive would buy back is itemised in [reference/4tb-upgrade.md](reference/4tb-upgrade.md).
> - **The memory is one 2×32 GB DDR5-6000 kit, not a second 2×16 GB pair.** Added to the factory pair that is 96 GB at ~DDR5-3600; on its own it is 64 GB at the full 6000. The decision and the test plan are in [reference/ram-upgrade-decision.md](reference/ram-upgrade-decision.md).
>
> Everything below is kept for the reasoning that led there.

Prices checked **13 November 2026**, Swedish retailers, incl. moms; the NVMe section was re-verified against Prisjakt on **17 November 2026**. The DRAM and NAND markets are in a severe AI-driven shortage, so treat every figure as a moving target that trends upward — the 4 TB NVMe rose about 23% in the six weeks to 17 November.

## Buy now

**What this page recommended, at 17 November 2026 prices:**

| | Part | Price |
|---|---|---|
| RAM | Patriot Viper Venom DDR5-6000 2×16 GB CL36 — Proshop | 6 367 kr |
| SSD | Lexar NM790 4 TB — Proshop or CS MegaStore | 7 374 kr |
| | **Total** | **13 741 kr** |

Swapping the SSD for the Samsung 990 Pro 4 TB at 8 490 kr makes it **14 857 kr**; dropping to a Kingston KC3000 2 TB makes it **10 557 kr**. Reasoning for each choice is below.

**What was actually bought:**

| | Part | Price |
|---|---|---|
| RAM | Corsair Vengeance RGB DDR5-6000 2×32 GB CL40 `CMH64GX5M2D6000Z40` — Komplett | 11 999 kr |
| SSD | 2 TB NVMe, fitted in M.2_2 | — |

The RAM went the other way from the recommendation below: a 2×32 GB kit at roughly double the price of a second 2×16 GB pair. It buys an option the cheap route does not have — fitted alongside the factory pair it reaches **96 GB**, which no 64 GB configuration does, and if four mixed DIMMs prove unstable it falls back to 64 GB at the full DDR5-6000 rather than 3600. See [reference/ram-upgrade-decision.md](reference/ram-upgrade-decision.md).

### The second NVMe — required

This becomes the **entire Ubuntu system**: root filesystem, its own EFI partition, applications, all AI models, the k3s cluster, databases, app data and game-server worlds. Windows keeps the factory 1 TB drive and the two never touch.

#### 2 TB or 4 TB — buy 4 TB

A 2 TB drive does fit the realistic build. At 64 GB of RAM the server stack caps you at IQ2_XS, so you would install two or three Strata packs rather than the full 673 GB catalogue — call it 900 GB of real usage against 1 863 GiB, under half full.

*As built this reasoning did not hold. Every pack through tier E was installed rather than two or three, and the three that a 96 GB machine adds above IQ3_S are 94, 111 and 128 GB — ~333 GB that takes the drive to ~1 464 GB and the Steam library down to ~213 GB. The 2 TB drive works, but gaming is what pays for it.*

The reason to buy 4 TB anyway is that **this machine has no spare drive bay in practice.** M.2_1 holds Windows, M.2_2 takes this drive, and M.2_3 disables the PCIe x16 slot you are keeping for a capture card or 10GbE NIC. So the drive you buy now is the drive you have, and growing later means replacing it rather than adding to it.

The marginal price makes the same case. Going from a good 2 TB drive at 4 190 kr to the 4 TB NM790 at 7 374 kr costs **3 184 kr for a second 2 TB** — cheaper per terabyte than the 2 TB drive itself.

Buy 2 TB only if the budget genuinely requires it.

| 2 TB option | NAND | DRAM | TBW | Price | Where |
|---|---|---|---|---|---|
| **Kingston KC3000 2 TB** | TLC | **yes** | 1 600 | **4 190 kr** | The right 2 TB drive if you take this route |
| WD Black SN7100 2 TB | TLC | no, HMB | 1 200 | 4 314 kr | CS MegaStore |
| Crucial P310 2 TB | TLC | no, HMB | **440** | 2 799 kr | Amazon.se. Cheapest, but see TBW |
| WD Green SN3000 2 TB | QLC | no | — | 2 797 kr | No |
| Kingston NV3 2 TB | QLC | no | — | 2 949 kr | No |

The Crucial P310 is honest TLC and very cheap at 1 400 kr/TB, but **440 TBW over 4 TB-years is thin** — 220 TBW per TB, against 600 TBW/TB as the usual bar for a drive you trust. For a games drive that is irrelevant; for one running Postgres, container churn and a nightly backup for five years it is the spec to be least comfortable with.

| Drive | NAND | DRAM | Cheapest | Where |
|---|---|---|---|---|
| **Samsung 990 Pro 4 TB** | TLC | yes | **8 490 kr** | Amazon.se; 8 946 CS MegaStore, 8 990 Proshop |
| WD Black SN8100 4 TB | TLC | yes | ~8 792 kr | Gen 5 buys nothing here |
| **Lexar NM790 4 TB** | **TLC** | no, HMB | **7 374 kr** | CS MegaStore and Proshop, same price |
| Lexar NQ790 4 TB | **QLC** | no, HMB | ~5 700 kr | **No.** Same controller, worse flash — see below |
| Kingston NV3 4 TB | QLC | no | ~6 500–7 500 kr | No, for the same reason |

Prices verified against Prisjakt on **17 November 2026**, incl. moms. The two Lexar part numbers are `LNM790X004T-RNNNG` (buy this one) and `LNQ790X004T-RNNNG` (avoid).

**You are shopping at a bad moment, and waiting has not been working.** Prisgrisen's history for the NM790 4 TB puts the 74-day median at **6 260 kr** and the September low at **5 764 kr**. It has climbed more or less every week since: 6 008 on 1 October, 6 698 on 22 October, 7 309 on 3 November, 7 374 now — about **+23% in six weeks**, which is the NAND shortage showing up in retail. Prisgrisen currently flags today's price as "högt pris." Nobody can tell you where it goes next, but six straight weeks of increases means holding out for the old price has lost money every week so far.

**The cheap pick is no longer the right pick.** The earlier version of this list recommended a QLC drive because the workload was "one big download followed by months of reads", where QLC and a missing DRAM cache cost you nothing. That is not this workload any more. A k3s node layering container images, Postgres committing with `fsync`, n8n writing execution history, and the nightly backup are all **sustained small writes**, which is what QLC is worst at.

#### NM790 versus NQ790 — one letter, very different drive

They are easy to confuse and are nearly the same hardware: both use the **Maxio MAP1602A** controller, both are DRAM-less with Host Memory Buffer, both single-sided, both five-year warranty. Only the flash differs, and it decides everything:

| | NQ790 4 TB | NM790 4 TB |
|---|---|---|
| NAND | QLC | TLC, YMTC 232-layer |
| Endurance | 2 400 TBW | 3 000 TBW |
| SLC cache, empty | ~1 TB | ~642 GB |
| Cache at half full | ~160 GB | — |
| **Write speed once cache is spent** | **~200 MB/s** | **~2 500 MB/s** |

A 12× gap on the row that matters. And the cache shrinks to about 160 GB on a half-full drive, which a single 68–76 GB Strata pack download walks straight through.

In fairness, downloads are network-bound anyway, so 200 MB/s would not actually feel slow there. The problem is the server workload: when the controller folds SLC cache down into QLC in the background while new writes arrive, QLC folding is far slower than TLC, and a Postgres commit waiting on `fsync` through one of those stalls becomes a stalled transaction that surfaces as n8n timeouts. It looks like a software fault, which is the worst kind of hardware problem.

There is also a batch lottery: Tweakers found retail NQ790s shipping with TLC during a QLC shortage, with Lexar confirming they reverted to QLC once supply recovered. For the drive holding the entire operating system, a part whose core specification varies by production run is a bad trade at any price.

#### If you buy a MAP1602 drive, note the kernel requirement

The MAP1602A misreports its maximum initialisation time, and **Linux kernels between roughly 6.2 and 6.5.4 fail to bring these drives up at all** — the disk simply does not appear. Fixed in 6.5.5 by a quirk for MAXIO MAP1602.

Ubuntu 24.04 LTS ships 6.8, so the install is fine. Worth remembering if you ever boot an older rescue USB and the drive seems to have died.

#### Where the 990 Pro now sits

Earlier drafts of this list guessed the 990 Pro 4 TB at 9 500–9 900 kr and concluded the NM790 saved you about 2 100 kr. The real figure is **8 490 kr** at Amazon.se and **8 946 kr** at CS MegaStore, so the gap is **1 100–1 600 kr, not 2 100**. That is close enough to change the answer.

At a ~1 500 kr premium on a drive that holds the operating system, the databases and every model, and that runs 24/7 for years, the 990 Pro's DRAM cache is worth it. DRAM keeps flash-translation-layer lookups off the host and latency predictable as the drive fills under random access, which is exactly the Postgres-plus-k3s profile. The NM790's HMB is good, but HMB borrows system RAM and degrades under memory pressure — and this machine is deliberately run near its memory ceiling with a 35 GB model resident.

The NM790 remains the right pick if you want to save the money; it is a genuinely good drive, ComputerBase measured it at or above 990 Pro speeds, and its 3 000 TBW actually **beats** the 990 Pro's 2 400 TBW. But the decision is now closer than the 2 100 kr gap implied.

**If you buy the NM790, give it a heatsink.** KitGuru found it needs proper cooling under sustained load, which is what this box does. Buy the bare version — both Swedish listings are "utan värmespridare" — and seat it under the motherboard's own M.2 heatsink rather than stacking two.

#### Where to buy

CS MegaStore is genuinely among the cheapest and is a Swedish entity (CS MEGASTORE AB, org. 559522-9401, Malmö), so **36 months' reklamationsrätt under konsumentköplagen applies**. Their headline price includes moms with "ex. moms" shown beneath, so the figures above are comparable. Trustpilot sits at 4.1 across ~11 700 reviews and Prisjakt rates the store 4.4.

Two caveats worth knowing before you order:

- **Returns ship to Ringsted, Denmark**, not Malmö, and the recurring Trustpilot complaint is slow RMA handling rather than bad pricing or slow delivery. CS MegaStore's own terms recommend going **direct to the manufacturer** for warranty work because it "reduces processing time drastically" — for an SSD that is the right move anyway, since Lexar and Samsung both handle drive warranties directly.
- **Check whether the item ships from stock or from a remote warehouse** (*fjärrlager*). Stocked items go out quickly; remote-warehouse items are quoted at 2–10 working days and several reviewers report that estimate running long.

For the NM790 specifically, **Proshop matches CS MegaStore exactly at 7 374 kr** with free shipping, six units in stock and 1–2 day delivery, so there is no price reason to choose on anything but which returns process you prefer. Avoid buying storage from Amazon marketplace sellers; if you take the 8 490 kr 990 Pro, confirm it is sold *and* shipped by Amazon itself.

**Gen 4 is still enough.** Strata streams experts as individual tensors scattered across a 68 GB file — random read, bounded by NAND latency rather than the PCIe link — so Gen 5 lands in roughly the same place.

**Endurance matters more than before.** Container churn plus database writes plus model downloads will burn through TBW faster than a pure model store. The 990 Pro's 2 400 TBW at 4 TB is comfortable for years of this; check the warranty figure on whatever you buy.

Where it goes: **M.2_2**. **Never M.2_3** — it disables the PCIe x16 slot. With only two drives, M.2_3 stays empty and that slot stays usable for a capture card or 10GbE NIC later. See [reference/partition-layout.md](reference/partition-layout.md).

### USB stick — 8 GB or larger

For the Ubuntu 24.04 LTS ISO.

## RAM: past 32 GB

DDR5 in Sweden is averaging **~200 kr/GB** on the cheaper kits, roughly 3–5× mid-2025 levels.

| Capacity | Config | Price | Verdict |
|---|---|---|---|
| 32 GB | 2×16 DDR5-6000 | — | Factory fitment |
| 64 GB | 4×16, adding a second 2×16 kit | ~6 200–6 700 kr | Cheapest route to 64 GB, runs at DDR5-3600 |
| **96 GB** | **2×32 added to the factory 2×16** | **11 999 kr** | **Bought.** Runs IQ3_S with the cluster up, at ~3600 |
| **64 GB** | **the same 2×32 kit on its own** | **same kit** | **The fallback.** Full DDR5-6000 if four DIMMs misbehave |
| 96 GB | 2×48 DDR5-6000 | ~21 715–21 884 kr | 96 GB *and* full speed, for 9 700 kr more |
| 128 GB | 2×64 DDR5-6400 | ~40 000 kr | Barely in stock |
| ~~64 GB~~ | ~~2×16 plus one 32 GB~~ | ~~cheapest~~ | **Never.** See below |

The two bold rows are the same purchase fitted two ways, which is why it won. A second 2×16 GB kit commits you to 64 GB at 3600 and nothing else; the 2×32 kit reaches 96 GB if the board cooperates and 64 GB at full speed if it does not. For 5 600 kr more than the cheap route you buy the better of two outcomes instead of the only one.

### What the factory kit actually is

Confirmed from the module label: **Corsair Vengeance DDR5 2×16 GB, 6000, 1.35 V, version 3.43.04.**

That version string is the useful part. Corsair encodes the memory IC in it, and the mapping is public from motherboard QVLs:

| Corsair version | ICs |
|---|---|
| **3.43.x** | **Micron** — early DDR5 dies |
| 4.43.02 | Samsung |
| 5.43.01 / 5.43.13 | SK hynix A-die / M-die |

So the factory sticks are Micron, single-rank, and Micron's early DDR5 dies are the least cooperative in a four-module fill. It does not rule the four-DIMM route out — four DIMMs train to ~3600 regardless, where margins are wide, and mixed kits fail predominantly when forced to hold an aggressive EXPO profile. It does mean the configuration has to be proven with `memtest86+` rather than assumed.

An earlier version of this page guessed from a NetOnNet listing that the factory RAM was Kingston FURY Beast RGB. That listing was for the Gigabyte B850 EAGLE variant of the SG G700, not this ASUS TUF build, and the guess was wrong.

### Which 2×16 kit to buy — superseded

*Kept for reference. The machine went to a 2×32 GB kit instead, for the reasons in the table above.*

Prices checked 17 November 2026. All are DDR5-6000 2×16 GB with EXPO:

| Kit | CL | Price | Note |
|---|---|---|---|
| Team Group T-Force Delta RGB `FF3D516G6000HC38A01X2` | 38 | 5 999 kr | Cheapest |
| Corsair Vengeance RGB `CMH32GX5M2E6000Z36` | 36 | 6 190 kr | |
| **Patriot Viper Venom `PVV532G600C36K`** | 36 | **6 367 kr** | **Pick.** In stock at Proshop, free shipping |
| Patriot Viper Venom `PVV532G600C30K` | 30 | 6 683 kr | |
| Corsair Vengeance `CMK32GX5M2E6000Z36` | 36 | 6 790 kr | |
| Kingston FURY Beast RGB 32 GB | 36 | 8 819 kr | |

**Do not pay for CL30 or for a 6000-rated kit's headroom.** With four modules the board trains to roughly DDR5-3600 and sets its own timings, so the EXPO profile you paid for is never loaded. Buy on price and brand reputation, not on the rating.

**On matching the factory kit.** Buying the identical part number *and* version is the strongest form of matching available, because the version is what fixes the die. In practice you cannot specify it when ordering, so the realistic options are to ask the retailer to read the label before shipping, or to accept mixed dies and rely on 14 days' ångerrätt if the board will not train.

That matters less than it sounds for a 3600 target and more than it sounds for anything faster, which is the whole reason this section ends in a 2×32 GB kit instead.

### Do not reach 64 GB with a single 32 GB stick

It is the obvious-looking cheap route and it is a trap, so it is worth spelling out.

The board is dual-channel with two slots per channel. Adding one 32 GB module puts 48 GB on one channel and 16 GB on the other. Only the matched part — 16 GB from each channel — interleaves at full width. **The other 32 GB sits on one channel and runs at half bandwidth.**

Strata mlocks 25–40 GB of experts, so some of them land in the slow half, and which ones changes between loads. The result is generation speed that varies run to run with no visible cause.

There is no compensating upside. The controller clocks to the worst-populated channel, which would have two DIMMs on it, so you drop to DDR5-3600 anyway — the four-DIMM penalty plus the asymmetry penalty, for the same money.

Two further strikes: three-module layouts are not on the ASUS QVL, and AM5 memory training is fragile enough that untested configurations matter; and a 32 GB UDIMM is usually dual-rank against single-rank 16 GB modules, so you would also be mixing ranks across channels.

**Populate a dual-channel board in matched pairs. Two or four modules, never three.**

### What the four-DIMM route costs you

Be clear-eyed about this one, because it is a real trade rather than a free win.

AMD rates the 9800X3D at **DDR5-5600 with two modules but only DDR5-3600 with four**, which reads as giving up about 40% of theoretical memory bandwidth. The practical loss is nearer a fifth, because the 9800X3D is a single-CCD part whose Infinity Fabric caps delivered bandwidth around 60–64 GB/s however fast the memory runs — so much of what DDR5-6000 supplies never reaches the cores anyway. The arithmetic is in [reference/ram-upgrade-decision.md](reference/ram-upgrade-decision.md).

That matters here specifically: Strata keeps cold experts in system RAM and computes them on the CPU, so token generation is directly bandwidth-bound. **Expect published tokens-per-second figures to land materially below quoted numbers** — IQ2_XS is rated 79 tok/s on a full-speed system and will not reach that. Measure it rather than assume a figure; the hot experts in VRAM are unaffected.

What you gain is the thing you actually needed: **capacity**. No amount of bandwidth on 32 GB makes the server stack and a large model coexist, and no amount on 64 GB reaches IQ3_S with the cluster up.

Two caveats to plan for:

- **Mixing kits on AM5 is unreliable** even when specifications match on paper, and mixing ranks — dual-rank 32 GB modules against single-rank 16 GB ones — is the hardest version of it.
- **Four mixed DIMMs may not POST at 3600.** If the machine is unstable, drop to DDR5-3200 in BIOS, or fall back to the matched pair. See [reference/troubleshooting.md](reference/troubleshooting.md).

### The escape hatch

This is the argument that settled the purchase. Because the 2×32 GB kit is a complete memory configuration on its own, the four-DIMM fill is an experiment rather than a commitment: fit all four, prove it, and if it will not hold, pull the 16 GB pair and sell it. You land on 64 GB at the full DDR5-6000, which is a good machine.

That is not true in the other direction. Had the second 2×16 GB kit been bought instead, an unstable four-DIMM fill would leave you back at 32 GB with 6 400 kr spent and nothing to show for it.

Do not sell the 2×16 pair until the machine has run clean for a week. DRAM prices are rising, so holding costs nothing.

## Pre-delivery checklist

- [ ] Order the 4 TB NVMe, timed to arrive with or before the PC
- [ ] Order the memory — a 2×32 GB DDR5-6000 kit, which works fitted either alongside the factory pair or instead of it
- [ ] Download the Ubuntu 24.04 LTS desktop ISO from <https://releases.ubuntu.com/24.04/>
- [ ] Verify the ISO checksum against `SHA256SUMS` on that page
- [ ] Write it to USB with [Rufus](https://rufus.ie) (Windows) or `dd` / Balena Etcher
- [ ] Copy this entire `ai-workstation-setup` folder onto the same USB stick
- [ ] Have a Philips screwdriver and an anti-static strap ready

## On opening the case

You will be inside the machine twice regardless: once to fit the 4 TB drive and the RAM, and once during Phase 7, which unplugs the 1 TB Windows drive so the Ubuntu installer physically cannot reach it. Leave the side panel off until Phase 7 is done.

If the SSD arrives before the PC, fit it before first boot and save yourself a teardown. If the PC arrives first, that is fine — just power down fully, switch off the PSU and unplug before opening the case.
