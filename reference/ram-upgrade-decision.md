# Phase 11 — RAM: 96 GB, with 64 GB at DDR5-6000 as the fallback

**Bought: one Corsair Vengeance RGB 2×32 GB DDR5-6000 CL40 kit, `CMH64GX5M2D6000Z40`, 11 999 kr.**

That single kit can be fitted two ways, and the choice between them is reversible — which is the most useful thing about it:

- **Add** it to the factory 2×16 GB pair. Four DIMMs, **96 GB at roughly DDR5-3600**.
- **Swap** it for the factory pair. Two DIMMs, **64 GB at DDR5-6000**.

**Fit all four first.** If the machine proves stable, you have 96 GB for the price of 64. If it does not, pull the 16 GB pair and you are on the swap configuration, having lost a week and nothing else.

Earlier versions of this page argued first against any upgrade, then for a second 2×16 GB kit at ~6 400 kr. What changed each time was the workload, not the arithmetic. The parts of those arguments that still hold are kept below.

## What is in the machine

| | Factory pair | New pair |
|---|---|---|
| Kit | Corsair Vengeance DDR5 2×16 GB | Corsair Vengeance RGB 2×32 GB |
| Part number | check the label | `CMH64GX5M2D6000Z40` |
| Rated | 6000, 1.35 V | 6000 CL40, 1.35 V |
| JEDEC fallback | — | 4800 CL40, 40-40-40-77, 1.1 V |
| EXPO profile | — | 6000 CL40, 40-50-50-96, 1.35 V |
| Corsair version | **3.43.04** | — |
| Memory ICs | **Micron** | assume not Micron |
| Rank | single | dual |
| Module height | — | 44 mm |

**The factory sticks are Micron, and that is worth knowing before you fit four DIMMs.** Corsair encodes the IC in the version number printed on the label: `3.43.x` is Micron, `4.43.02` is Samsung, `5.43.01` and `5.43.13` are SK hynix A- and M-die. Micron's early DDR5 dies are the least cooperative in a four-module fill. It does not make the add configuration unworkable — it makes it something to prove rather than assume.

Two specifications that look alarming and are not. The 44 mm module height is fine because this build uses a 240 mm AIO, so nothing overhangs the DIMM slots; it would be a real clearance problem with a tower air cooler. And the kit genuinely carries both of the timing sets you will see quoted by retailers — `40-40-40-77` is the JEDEC profile it boots at before you touch BIOS, `40-50-50-96` is the EXPO profile. Neither listing was wrong.

## Add or swap

| | Add — 96 GB | Swap — 64 GB |
|---|---|---|
| Modules | 2×32 + 2×16, four DIMMs | 2×32, two DIMMs |
| Ranks | six — dual-rank 32s, single-rank 16s | four, matched |
| Trained speed | ~DDR5-3600 | **DDR5-6000** |
| Per-channel capacity | 48 GB each — symmetric, fully interleaved | 32 GB each |
| Delivered bandwidth | ~50 GB/s | ~62 GB/s |
| Experts, cluster up | **~68 GB** | ~37 GB |
| Experts, after `ai-pause` | **~83 GB** | ~52 GB |
| Daily driver without pausing | **UD-IQ4_XS** | IQ2_XS |
| Largest with `ai-pause` | **NVFP4** | IQ3_S |
| Net cash | 11 999 kr | 11 999 kr less ~4 500 resale |
| Free DIMM slots after | none | two |
| Stability | needs proving | trivial |

Channel balance when adding is fine: 32 GB plus 16 GB in each channel means both channels hold 48 GB, so all 96 GB interleaves at full width. This is **not** the three-module trap described below — that one is asymmetric, this one is not.

### What adding buys

Two full tiers of model, and it closes both of the gaps this kit has been complaining about since it was written:

| Pack | Experts | 96 GB, cluster up | 96 GB, paused | 64 GB, cluster up | 64 GB, paused |
|---|---:|---|---|---|---|
| Coder IQ1_M | 23 GB | yes | yes | yes | yes |
| Q2_0 | 34 GB | yes | yes | yes | yes |
| IQ2_XS | 35.5 GB | yes | yes | **the ceiling** | yes |
| IQ3_XXS | 43 GB | yes | yes | no | yes |
| IQ3_S | 50 GB | **yes** | yes | no | **the ceiling** |
| Unsloth UD-IQ4_XS | 62 GB | yes, 6 GB margin | yes | no | no |
| NVFP4 | 70 GB | no | **yes** | no | no |
| Unsloth UD-Q4_K_XL | 78 GB | no | yes, 5 GB margin | no | no |
| Qwen3.6 Q8_0 class | 126 GB | no | no | no | no |

Three things on that table are new.

**IQ3_S runs with the cluster up.** That was the entire justification for 96 GB in the previous version of this page, costed there at ~21 800 kr via a 2×48 GB kit. Adding to sticks you already own reaches it for 11 999.

**UD-IQ4_XS comes into range**, which this kit has been calling "the closest miss — 8 GB short" for its whole life.

**NVFP4 becomes reachable after `ai-pause`.** Your RTX 5070 Ti has FP4 tensor cores that have had nothing to run on them.

The last two margins are thin — 6 GB and 5 GB against figures that were themselves approximations. Treat them as worth attempting and measuring, not as guarantees.

### What adding costs

**Roughly 20–30% of generation speed on cold experts.** Less than the headline bandwidth numbers suggest, for the reason set out below, and nothing at all on the hot experts resident in VRAM.

**A configuration that has to be proven.** Mixing a dual-rank pair with a single-rank pair across four slots is the least forgiving thing AM5 does, and this machine runs Postgres continuously. DDR5's on-die ECC protects the die, not the bus, so a marginal configuration corrupts data quietly and you will suspect your own code for weeks. This is why the test plan below is not optional.

**The upgrade path.** Four occupied slots means the next step is replacing everything rather than adding to it.

### Why the loss is smaller than 40% looks

Worth knowing before the benchmark disappoints you more than it should.

AMD rates the 9800X3D at **DDR5-5600 with two modules and only DDR5-3600 with four**, which reads as giving up about 40% of theoretical memory bandwidth. The practical loss is much smaller.

The 9800X3D is a **single-CCD** part, and a single CCD reaches memory through one Infinity Fabric link that tops out around 60–64 GB/s. Dual-channel DDR5-6000 can supply about 96 GB/s, which is more than that link can carry — so at full speed the fabric is the bottleneck and some of the bandwidth you paid for never reaches the cores. Dropping to DDR5-3600 gives about 58 GB/s theoretical, landing just below the fabric limit. Memory becomes the constraint rather than the fabric, but *delivered* bandwidth falls by perhaps a fifth rather than two fifths.

Pulling the other way: absolute latency in nanoseconds gets worse at 3600 unless timings tighten in proportion, and MoE expert gather is a scattered-access pattern that cares about latency as well as throughput. A kit rated 6000 CL40 running at 3600 will keep timings too loose to compensate fully.

These two effects partly cancel and nobody can give you the net figure from first principles. Measure it, which is what the benchmark below is for.

### Why add first rather than decide

The decision is not really 96 against 64. It is "try 96 and keep it if it holds" against "do not try" — because adding is a superset of swapping, and backing out costs only the week you spent testing. Your 2×16 pair will not lose value in that window; DRAM prices are trending up, not down.

The only way adding loses is if you skip the proving and discover the problem through a corrupted database.

### Never three modules

If the arithmetic tempts you — 2×16 plus a single 32 GB stick also reaches 64 GB, for less — do not. One channel would hold 48 GB and the other 16 GB, so only 32 GB interleaves at full width and **the rest runs single-channel at half bandwidth**, with the mlocked experts landing partly in the slow half and differently on each load. The controller still clocks down because one channel has two DIMMs, so there is no speed saved either.

Note the contrast with the add configuration above, which is also mixed-capacity but puts the *same* mixture in both channels. Symmetry across channels is what matters, not uniformity within one. Dual-channel boards take two or four modules, never three. [00-shopping-list.md](../00-shopping-list.md) has the full reasoning.

## Fitting it

### Slot order

**This differs from the advice for two identical kits.** The dual-rank 32 GB modules go in the primary pair; the single-rank 16 GB modules move down.

| Slot | Module |
|---|---|
| DIMM_A2 | new 32 GB |
| DIMM_B2 | new 32 GB |
| DIMM_A1 | factory 16 GB |
| DIMM_B1 | factory 16 GB |

So you are relocating the factory pair, not simply filling the empty slots. If you are swapping rather than adding, the 32 GB pair alone goes in **DIMM_A2 and DIMM_B2** — ASUS AM5 boards want the second slot of each channel when only two modules are fitted.

### First boot

Leave EXPO enabled. The board will ignore the 6000 profile with four modules and train down on its own; anywhere from 3600 to 4800 is a plausible landing spot, since AMD's 3600 rating is conservative and many AM5 boards hold 4800 JEDEC across four DIMMs. Take whatever proves stable rather than chasing a number.

Expect the first POST to take 30–60 seconds with the amber DRAM light lit, and one or two automatic reboots during training. That is normal and not a fault.

Verify with [`../windows/02-verify-hardware.ps1`](../windows/02-verify-hardware.ps1), which reports both the four-DIMM and two-DIMM configurations as correct, or on Ubuntu:

```bash
sudo dmidecode -t 17 | grep -E 'Size|Locator|Speed|Part Number|Rank'
```

### Prove it before the cluster touches it

Do not skip this. Run a **full** `memtest86+` pass overnight — not the quick test — before starting k3s or Postgres for the first time on the new configuration.

```bash
# Ubuntu: memtest86+ is a GRUB boot entry, not something you run from the desktop
sudo apt install memtest86+
sudo update-grub      # then reboot and pick it from the GRUB menu
```

Through the first week of real load, watch for the signature of marginal memory, which does not look like a memory failure:

```bash
journalctl -k --since '1 week ago' | grep -iE 'segfault|machine check|mce|oops'
```

Random application crashes, `segfault` in `dmesg` and corrupted container images are what you are looking for. If any of that appears, go to the recovery sequence below rather than debugging the application.

### If it will not POST or is unstable

Four mixed DIMMs are the least reliable configuration on AM5, and mixed ranks are the least reliable version of that. In order:

1. Clear CMOS, boot, and let it train again without touching anything.
2. In BIOS, set the memory frequency manually to **DDR5-3200**.
3. Raise DRAM voltage slightly, or relax primary timings one step.
4. **Pull the 16 GB pair.** You are on 64 GB at DDR5-6000, which is a good configuration, not a defeat. Sell the 2×16.

Step 4 is the designed fallback, not a last resort. Reaching it means you paid 11 999 kr for 64 GB at full speed and spent a week finding out — which was always the risk, and is why the 2×16 should not be sold until the machine has proven itself.

## The memory budget

k3s, Postgres, n8n, LiteLLM, Open WebUI and one game server cost about 15 GB before a model loads. The fit rule for Flash-Next is that **RAM must hold the experts plus about 10 GB** for the operating system.

| | 96 GB (reports ~93 GiB) | 64 GB (reports ~62 GiB) |
|---|---:|---:|
| Server stack | 15 GB | 15 GB |
| Operating system | 10 GB | 10 GB |
| **Experts, cluster up** | **~68 GB** | **~37 GB** |
| **Experts, after `ai-pause`** | **~83 GB** | **~52 GB** |

`ai-pause` stops the cluster and the model server, freeing the stack's share; `ai-resume` brings it back. At 64 GB it is a routine part of using the machine. At 96 GB it becomes something you reach for only at the very top of the catalogue, which is most of the quality-of-life argument for adding.

A bigger graphics card makes things faster but does **not** lower the RAM requirement, except in low-RAM mode — and low-RAM mode needs a 24 GB card to help. With 16 GB, the tables above are what you get.

## What to measure first

### Did the bandwidth cost you what you feared?

Benchmark once in each configuration if you have the patience, and write the numbers down:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"strata","messages":[{"role":"user","content":"Count to 200."}],
       "reasoning_effort":"none","stream":false}' | jq '.usage'
```

Published figures in [strata-models.md](strata-models.md) assume dual-channel at rated speed. IQ2_XS is rated 79 tok/s; expect meaningfully less on four DIMMs. The honest comparison is not "96 GB slow against 64 GB fast" but "a pack you can run slowly against a pack you cannot run at all".

### Is RAM actually the binding constraint?

While Strata is loaded and generating, check committed memory.

**Windows** — Task Manager → Performance → Memory. Watch "Committed".

```powershell
Get-Counter '\Memory\Committed Bytes','\Memory\Available MBytes' -SampleInterval 5 -MaxSamples 60
```

**Ubuntu:**

```bash
# Peak committed memory and swap pressure over a work session
vmstat -SM 5 | awk 'NR>2 {print "free="$4"M  si="$7"  so="$8}'
```

You want to know two things: whether available memory approaches zero, and whether `si`/`so` (swap in/out) stay at zero. Occasional paging is survivable; sustained paging means the machine is thrashing.

### Is model quality actually limiting you?

Coder keeps 256 of each layer's 512 experts, selected on code. Its authors report **91% of the full model's SWE-bench Verified score and 99% of LiveCodeBench**. For writing and reviewing code, that is close enough that you are unlikely to notice.

Where it is genuinely weaker is general non-code text, and CJK languages specifically can come out wrong or loop. Qwen3.6-35B-A3B at UD-Q4_K_XL is 22.9 GB, Apache 2.0, and handles that work — SWE-bench Verified 73.4, GPQA 86.0, MMLU-Pro 85.2, AIME26 92.7. Install both and switch between them.

So the question that justifies climbing the catalogue is narrow: are you hitting ceilings on *both* models that feel like capability rather than prompting? If not, IQ2_XS on either configuration is enough and the rest of this page is insurance.

### Is the speed still acceptable?

Coder runs at roughly 55 tok/s on a full-speed machine of this class. At DDR5-3600 expect less on every pack. Both figures remain faster than you read, so the practical cost shows up in agent loops that generate thousands of tokens unattended rather than in interactive chat.

Two mitigations cost nothing:

- **Thinking is a bigger lever than bandwidth.** Flash-Next defaults to `reasoning_effort: xhigh`, its longest tier. Dropping to `low` for worker and checker roles saves far more wall-clock time than the memory downgrade cost you.
- **Swift 1.5** produces much shorter reasoning at the same quality, size and per-token speed.

## What to download

`--tier all` is ~788 GB: tiers A-E at 677 GB, plus UD-IQ4_XS at 111 GB as tier F. Install all of it regardless of which memory configuration you land on — packs are fetched once, and having every one resident is what makes switching modes a one-liner rather than a 76 GB wait.

Tier F only *loads* in the 96 GB configuration. Downloading it on 64 GB, or before the DIMMs are fitted, is fine and the installer says so; it simply sits on disk until the memory is there. Use `--tier abcde` to leave it out and keep the Steam library at 542 GB rather than 431 GB.

```bash
cd ai-workstation-setup/ubuntu
./07-strata.sh --tier de            # plan first - prints sizes, downloads nothing
./07-strata.sh --tier de --install
```

### Comfortable — tier D, ~326 GB

| Pack | Command | Download | Speed |
|---|---|---:|---|
| Flash-Next **Q2_0** | `--family qwen --model q2_0` | ~70 GB | **94 tok/s** — the fast one |
| Flash-Next **IQ2_XS** | `--family qwen --model iq2_xs` | ~72 GB | 79 tok/s |
| Flash-Next **IQ3_XXS** | `--family qwen --model iq3_xxs` | ~74 GB | 62 tok/s |
| **Swift 1.5** IQ2_XS | `--family swift --model IQ2_XS` | ~72 GB | as IQ2_XS, thinks far shorter |
| **Qwen3.6** Q8_0 | `--family qwen36 --model Q8_0` | 37.8 GB | closest to the full 35B |

Q2_0 is where quality falls off: perplexity jumps about 10% against the Q8_0 reference, while everything above it stays within 2%.

Swift 1.5 is the one worth explaining. It is a fine-tune of the same model at the same size and speed that produces much shorter reasoning for about the same answer quality — the targeted fix for Flash-Next thinking at `xhigh` by default.

### Tier E — ~76 GB

| Pack | Command | Note |
|---|---|---|
| Flash-Next **IQ3_S** | `--family qwen --model iq3_s` | 50 GB of experts. Daily driver at 96 GB; needs `ai-pause` at 64 GB |

IQ3_S matches the full model on the published tests and is the slowest of the line at 53 tok/s before any bandwidth penalty. At 64 GB it is a deliberate "stop everything and think hard" mode. At 96 GB it is simply the default.

### Beyond tier E — only at 96 GB

UD-IQ4_XS is tier F and comes with `--tier all`. The other two are not in the tier letters, and fetching them is a deliberate manual step once the memory configuration is proven.

| Pack | Experts | Download | When |
|---|---:|---:|---|
| Unsloth UD-IQ4_XS | ~62 GB | ~111 GB | **tier F, in `--tier all`.** Cluster up, 6 GB margin — measure before trusting |
| NVFP4 | ~70 GB | — | by hand, after `ai-pause`; the FP4 tensor cores finally earn their keep |
| Unsloth UD-Q4_K_XL | ~78 GB | ~130 GB | by hand, after `ai-pause`, 5 GB margin |

**Disk becomes the constraint here, not memory.** Tiers A-F are 788 GB, and adding either remaining pack on top overruns what [partition-layout.md](partition-layout.md) leaves for Steam. Take one only if you have decided what it displaces, or see [4tb-upgrade.md](4tb-upgrade.md).

## What neither configuration reaches

| Pack | Needs | Gap |
|---|---:|---|
| Qwen3.6 Q8_0 class | ~136 GB RAM | not without 128 GB and then some |
| DeepSeek V4.1-Flash | 46 GB RAM, **257 GB disk** | memory is fine at either tier; disk and ~5 tok/s are not |

DeepSeek is the judgement call. It *will* start on 64 GB, let alone 96. At five tokens a second and a quarter-terabyte download on a 2 TB drive, it is a curiosity rather than a tool on this hardware. It is itemised in [4tb-upgrade.md](4tb-upgrade.md).

The full catalogue, quality measurements and thinking-mode notes are in [strata-models.md](strata-models.md). The arithmetic behind the 15 GB server stack is in [server-architecture.md](server-architecture.md).
