# Strata model catalogue and download plan

Strata is not a single-model runner. It serves a handful of base models, and most of what looks like a long model list is the same model at different precision. This page is the full catalogue, what runs on your hardware now, and exactly what to add when you reach 64 GB.

Install and switch with [`../ubuntu/07-strata.sh`](../ubuntu/07-strata.sh) or [`../windows/05-install-ai-stack.ps1`](../windows/05-install-ai-stack.ps1).

Two companion pages. [harnesses.md](harnesses.md) covers when to use Strata rather than llama.cpp, and what else could replace either. [uncensored-models.md](uncensored-models.md) covers abliterated and uncensored models, none of which Strata can run.

## Families, and why the family matters

Strata addresses a model as a **family** plus a **size**. The family is a base model *and the group who quantised it*; the size is a precision within that family. Getting the pairing wrong is the single easiest mistake to make here, because Strata validates the size name before the family, so a wrong family is not reported as a wrong family — it comes back as `<Family> has no size <Size>`, which reads like the model is missing.

These are the seven families on the current release, read back from Strata itself:

| Family | Base model | Sizes it offers |
|---|---|---|
| `qwen` | Qwen3.8-Flash-Next | `Q2_0`, `IQ2_XS`, `IQ3_XXS`, `IQ3_S` |
| `unsloth` | Qwen3.8-Flash-Next (Unsloth) | `UD-IQ1_M`, `UD-Q2_0`, `UD-IQ2_XS`, `UD-Q2_K_XL`, `UD-IQ3_XXS`, `UD-Q3_K_XL`, `UD-IQ4_XS`, `UD-IQ4_XS-v31`, `UD-Q4_K_XL`, `UD-Q5_K_XL`, `UD-Q6_K_XL`, `Q8_0` |
| `nvfp4` | Qwen3.8-Flash-Next (NVFP4) | `NVFP4`, `NVFP4-NVIDIA`, `NVFP4-QAD` |
| `gyro` | Qwen3.8-Flash-Next (Gyro) | `Gyro-S`, `Gyro-M` |
| `coder` | Qwen3.8-Flash-Next Coder | `IQ1_M` |
| `swift` | Swift 1.5 | `IQ2_XS`, `IQ3_XXS`, `IQ3_S` |
| `qwen36` | Qwen3.6-35B-A3B | `UD-Q4_K_XL`, `UD-Q6_K_XL`, `Q8_0` |

Twenty-eight combinations in total. Two things in that table are worth pausing on:

- **The `UD-` sizes are not sizes of `qwen`.** They belong to `unsloth`, which is its own family built on the same base model. `--family qwen --model UD-IQ4_XS` is rejected even though both halves exist.
- **`UD-Q4_K_XL` and `Q8_0` each appear in two families**, and mean different models in each. `qwen36/UD-Q4_K_XL` is a 23 GB quant of the 35B; `unsloth/UD-Q4_K_XL` is a 111 GB quant of the 125B. Same size name, nothing else in common.

`./07-strata.sh --catalogue` prints this table from the live install along with a measured download size for every row. It asks Strata and downloads nothing, so prefer it to this page whenever the two disagree.

## Choosing: family first, then size

Most of the confusion here comes from treating "which model" as one question. It is two, asked in order.

**The family is a decision about what the model is.** Six of the seven families are the same 125B base model prepared by different people, and one is a different model entirely:

| If you want | Family | Because |
|---|---|---|
| The flagship, highest quality available | `unsloth` | Dynamic quantisation — precision is allocated per tensor rather than uniformly, so a given file size scores better. Top of the quality ladder below. |
| The same thing, plainly quantised | `qwen` | The reference quants. Nothing wrong with them; `unsloth` simply beats them at equal size. |
| FP4 hardware acceleration | `nvfp4` | Your RTX 5070 Ti has FP4 tensor cores. This is the only family built for them. |
| Every expert kept, no quantisation of the routing | `gyro` | A different compression approach that preserves all experts. Trades differently: less GPU memory for similar quality. |
| Code | `coder` | A fine-tune that is deliberately weak outside code and non-English. Not a general model with coding ability — a coding instrument. |
| Short answers rather than long reasoning | `swift` | Same quality as the equivalent Flash-Next size with far shorter thinking. A latency choice, not a quality one. |
| A small, fast, permissively licensed model | `qwen36` | A different and much smaller base model. Apache 2.0, accepts video input, runs in a fraction of the memory. |

**The size is a decision about how much of the model's quality you keep.** Within a family, every size is the same network at a different precision. Higher is better and bigger; there is no "different strengths" trade between them, only quality against memory and speed.

Three rules that cover almost every case:

1. **Pick the largest size your RAM holds, then stop.** The quality ladder is monotonic. There is no reason to run a smaller size than fits except speed, and the speed difference between adjacent sizes is far smaller than the quality difference at the bottom of the ladder.
2. **Do not go below IQ2_XS on the 125B.** Q2_0 is where perplexity jumps about 10% while everything above it stays within 2%. That is a cliff, not a gradient.
3. **Quantise a big sparse model harder than a small dense one.** A 125B MoE at 3 bits has enormous total capacity to draw on. A 27B dense model at 3 bits is just a damaged 27B model. This is why Flash-Next at IQ3_S is excellent and why the uncensored dense models in [uncensored-models.md](uncensored-models.md) should be Q6 or Q8.

**When the two decisions interact:** `UD-Q4_K_XL` and `Q8_0` each exist in two families and mean different models in each. `qwen36/UD-Q4_K_XL` is a 23 GB quant of the 35B; `unsloth/UD-Q4_K_XL` is a 111 GB quant of the 125B. Strata validates the size before the family, so getting this wrong reports `<Family> has no size <Size>` rather than naming the real mistake.

## The base models

| | Qwen3.8-Flash-Next | Qwen3.6-35B-A3B |
|---|---|---|
| Total / active parameters | 125B / 6B | 35B / 3B |
| Experts | 512 per layer, 10 routed + 1 shared | 256 per layer, 8 routed + 1 shared |
| Layers | 48 — 36 GatedDeltaNet + 12 sparse attention | 40 |
| Extra weights | 51B n-gram (Engram) table + 4B MTP head | MTP draft layer |
| Native context | 262,144, to 1M with YaRN | 262,144, to 1.01M |
| Input | text + images | text + images + video |
| Licence | Qwen Community 1.0 | **Apache 2.0** |

Swift 1.5 is a separate fine-tune of Flash-Next, covered under tier D below. **DeepSeek V4.1-Flash is gone** — Strata removed it, and a launch now answers *"Strata no longer offers DeepSeek models."* Earlier revisions of this page budgeted 257 GB of disk for it; that is no longer a decision anyone has to make.

The ~2% activation rate on Flash-Next is why a 125B model runs on a 16 GB card at all: roughly 6B parameters are touched per token, hot experts stay in VRAM, the rest sit in RAM, and a 29 GB n-gram lookup table is read from the SSD.

**Licence note.** Qwen Community 1.0 permits commercial use until you pass 100M monthly active users or US$20M monthly revenue, but running a Model-as-a-Service or "AI Work Assistant" business needs a separate licence from Qwen. Qwen3.6-35B-A3B is Apache 2.0 with none of that. Swift 1.5 carries its own licence — check it before commercial use.

## The fit rule

For Flash-Next: **RAM must hold the experts plus about 10 GB** for the operating system. That single rule explains the whole table below.

| Pack | Experts in shard 1 | So RAM needed | 96 GB, cluster up | 64 GB, cluster up |
|---|---:|---:|---|---|
| Coder (IQ1_M) | 23 GB | ~33 GB | yes | yes |
| Q2_0 | 34 GB | ~44 GB | yes | yes |
| IQ2_XS | 35.5 GB | ~45.5 GB | yes | yes — the practical ceiling |
| IQ3_XXS | 43 GB | ~53 GB | yes | no, needs `ai-pause` |
| IQ3_S | 50 GB | ~60 GB | yes | no, needs `ai-pause` |
| `unsloth/UD-IQ4_XS` | 62 GB | ~72 GB | yes, 6 GB margin | no |
| `nvfp4/NVFP4` | 70 GB | ~80 GB | no, needs `ai-pause` | no |
| `unsloth/UD-Q4_K_XL` | 78 GB | ~88 GB | no, needs `ai-pause` | no |

A bigger graphics card makes things faster but does **not** lower the RAM requirement, except in low-RAM mode — and low-RAM mode needs a 24 GB card to help. With 16 GB, what you see above is what you get.

### Which configuration this machine is in

Phase 11 fitted a 2×32 GB DDR5-6000 kit, which can be run two ways. **Adding** it to the factory 2×16 GB pair gives 96 GB at roughly DDR5-3600; **swapping** gives 64 GB at the full 6000. The add configuration is the plan, with the swap as a tested fallback if four mixed DIMMs prove unstable. Every table on this page carries both columns for that reason. [ram-upgrade-decision.md](ram-upgrade-decision.md) has the whole trade.

### The server stack takes 15 GB off the top

k3s, Postgres, n8n, LiteLLM, Open WebUI and one game server cost roughly 15 GB before a model loads.

| | Experts, cluster up | Experts, after `ai-pause` |
|---|---:|---:|
| 96 GB (reports ~93 GiB) | **~68 GB** | ~83 GB |
| 64 GB (reports ~62 GiB) | **~37 GB** | ~52 GB |

`ai-pause` stops the cluster and the model server, freeing the stack's share; `ai-resume` brings it back. At 64 GB that is a routine part of using the machine, because IQ3_XXS and above need it. At 96 GB it is reserved for the very top of the catalogue.

The arithmetic is in [server-architecture.md](server-architecture.md).

### Published speeds assume full-rate memory

In the 96 GB configuration this machine runs **four DIMMs at roughly DDR5-3600**, below the dual-module rate, and Strata computes cold experts on the CPU. Every tokens-per-second figure on this page was measured on a full-speed system — expect less here, by an amount only measurement can tell you.

The shortfall is smaller than the headline suggests, because the 9800X3D is a single-CCD part whose Infinity Fabric caps delivered bandwidth around 60–64 GB/s however fast the memory is. Reckon on losing a fifth rather than two fifths, and nothing at all on the hot experts held in VRAM. See [ram-upgrade-decision.md](ram-upgrade-decision.md).

## The 96 GB working set — what to keep

The tiers below this section were written for a machine that had to choose. At 96 GB most of them collapse into one answer, so this is the recommendation and the tier tables are the reasoning behind it.

The budget, measured rather than nominal. `free -h` reports **89 GiB** usable. Take 10 GB for the operating system and desktop, and 15 GB more when the server platform is up:

| | Available for experts |
|---|---:|
| Cluster up | **~64 GB** |
| After `ai-pause --cluster` | **~79 GB** |

Those are 4 GB tighter than the figures in the tier tables, which assumed 93 GiB. Treat anything within 5 GB of the limit as needing a measurement rather than an assumption.

### Where the packs actually live

Two directories, which matters before deleting anything.

```
~/Documents/Strata/
├── models -> Models        a symlink; du reports it as 0 bytes
├── Models/                 490 GB - the large packs
├── packs/                   86 GB - tokenizers and pack metadata
├── mtp/                    6.5 GB - MTP draft layers, shared
└── dflash2/                823 MB
```

The second store is `~/.local/share/strata/Strata-data/`, and it is the larger half:

```
~/.local/share/strata/Strata-data/
├── models/                 364 GB
├── packs/                  195 GB
├── mtp/                    6.5 GB
└── dflash2/                823 MB
```

Which store a pack lands in depends on what `data_dir` was set to when it was installed, so the split follows install order rather than anything meaningful. **A pack reported `present` by `strata models list` may have its weights in either place, or — if only its run config survives — in neither.** Use `strata models explain <size>` before deleting anything; it prints where Strata looks, what it found, and the exact file sizes, and changes nothing.

There is **no remove verb**. `strata models` offers `list, inspect, explain, import, move` and nothing else, so removal is `rm -rf` on directories you have confirmed with `explain`.

### Keep these six — the ones I am confident run here

Sizes below are **measured on this machine** with `du -sh`, not catalogue download figures — they include the MTP draft layer and the picture reader, so they run larger than the download column in the tier tables.

| Pack | Params | On disk | Experts in RAM | Top-1 vs Q8_0 | Runs | What to expect |
|---|---|---:|---:|---:|---|---|
| **`unsloth/UD-Q4_K_XL`** | 125B / 6B active | 104 GB | 78 GB | **93.1%** | after `ai-pause`, 1 GB margin | The quality ceiling of anything you can execute. The margin is genuinely thin — it will load some days and not others depending on what else the kernel is holding. A deliberate "stop everything and think hard" mode. |
| **`nvfp4/NVFP4`** | 125B / 6B active | 120 GB | 70 GB | not published | after `ai-pause`, 9 GB margin | The only pack built for your card's FP4 tensor cores. A comfortable margin, unlike the one above, so this is the realistic paused-mode default. |
| **`unsloth/UD-IQ4_XS`** | 125B / 6B active | 88 GB | 62 GB | 88.9% | cluster up, 2 GB margin | The best quality that runs while the platform is up. Measure it once before relying on it; 2 GB is inside the noise. |
| **`qwen/IQ3_S`** | 125B / 6B active | 78 GB | 50 GB | 87.7% | cluster up, comfortable | **The day-to-day default.** 1.2 points behind UD-IQ4_XS for 12 GB less memory and real headroom. ~53 tok/s, slower on four DIMMs. |
| **`coder/IQ1_M`** | 125B coder fine-tune | ~75 GB | 23 GB | n/a | always | The coding instrument, ~55 tok/s. IQ1 is not a compromise here: it is a different model trained for one job, and deliberately weak outside code and English. |
| **`qwen36/Q8_0`** | 35B / 3B active | 37 GB | ~10 GB | closest to the full 35B | always | A different base model, not a smaller Flash-Next. Apache 2.0, accepts video, light enough to run beside other work. For when the 125B is overkill. |

Six packs, about **500 GB**: a quality ceiling, a hardware-native option, a working best, a comfortable default, a coder and a lightweight generalist.

**On the margins.** Those figures of 9 GB, 2 GB and 1 GB are the difference between a pack's experts and your available RAM, and they are the numbers on this page most worth distrusting — expert sizes are published approximations, not measurements of your install. A 9 GB margin is safe. A 2 GB margin is probably fine. A 1 GB margin is a coin toss, and the failure mode is the OOM killer choosing a victim somewhere else, usually Postgres.

### Delete these — you own something strictly better

Every pack here is **outclassed by a pack you already have and can run**. That is the only criterion applied: not size, not age, but that something better fits in the same machine.

| Pack | Outclassed by | The argument |
|---|---|---|
| `qwen/Q2_0` | `qwen/IQ3_S` | 80.6% top-1 and perplexity 4.475, against IQ3_S's 87.7% and 4.097. **This is the pack below the quality cliff** — everything above it sits within 2% of the reference and Q2_0 jumps about 10%. It bought speed on a machine that could not hold anything larger. Yours can. |
| `qwen/IQ2_XS` | `qwen/IQ3_S` | It was the recommended default at 64 GB because it was the largest pack that coexisted with the cluster. That constraint is the only reason it was ever the answer, and it is gone — IQ3_S coexists with the cluster now, and scores higher. |
| `qwen/IQ3_XXS` | `qwen/IQ3_S` | 84.5% against 87.7%, for 7 GB less RAM. Same family, same shape, three points worse. There is no situation on this machine where you would choose it. |
| `gyro/Gyro-S` | `qwen/IQ3_S` | Gyro-S exists to keep every expert on a machine that cannot hold a decent quantisation — the full-expert fallback. You are no longer that machine, and IQ3_S beats it outright. |
| `gyro/Gyro-M` | `qwen/IQ3_S` | The largest single win here: ~92 GB for roughly IQ3_XXS quality, which IQ3_S already beats. Its distinguishing feature is using ~20% less GPU memory, which matters when VRAM is the binding constraint. Yours is RAM, so it buys nothing. |
| `qwen36/UD-Q4_K_XL` | `qwen36/Q8_0` | The same 35B model at lower precision. You hold the 8-bit version — the closest thing to the full model — for 15 GB more disk. Keeping both means keeping a worse copy of something you have. |
| `qwen36/UD-Q6_K_XL` | `qwen36/Q8_0` | Same argument, smaller gap. Q6 is close to Q8 on this model, but "close to something you already own" is not a reason to hold 33 GB. |
| `swift/IQ2_XS` | `qwen/IQ3_S`, **with a caveat** | Quality-wise it matches IQ2_XS, which IQ3_S beats, so by the criterion above it goes. But quality was never its argument. Flash-Next thinks at `xhigh` by default and can reason at length before answering; Swift is a fine-tune that thinks much shorter at the same quality. It is the fastest-to-useful-answer model you own, not the best. **Decide on behaviour rather than benchmarks:** if verbose reasoning irritates you in daily use, keep it. If `reasoning_effort` on the API is control enough, take back the 64 GB. |

**Roughly 420 GB**, and not one of them is something you would choose over a pack you are keeping.

### Too big for this machine — identified, not deleted

None of these are installed, so there is nothing to remove. They are listed so you recognise them and do not install one by accident.

| Pack | Experts needed | Why it misses |
|---|---:|---|
| `unsloth/UD-Q5_K_XL` | ~95 GB | Past the ~79 GB available with everything paused. 94.6% top-1, half a point above UD-Q4_K_XL, for memory you do not have. |
| `unsloth/UD-Q6_K_XL` | ~110 GB | The same, further out. |
| `unsloth/Q8_0` | ~130 GB | The barely-quantised 125B. Needs 128 GB of RAM and then some. |
| `qwen36` at full precision | ~136 GB | 188 GB of download as well. |
| `nvfp4/NVFP4-NVIDIA`, `NVFP4-QAD` | same as `NVFP4` | **Disk is the problem here, not memory** — roughly 128 GB each for variants of a pack you already have. A different kind of "too big": a larger drive buys these back, where more RAM would not. |

**If you ever want to remove one of the large packs you are keeping**, the method is the one below — `strata models explain <name>` to find the files, then `rm -rf` what it names. Nothing in this kit deletes them for you, and `--tier all` would fetch them again.

### How to remove a pack

There is no `strata models remove`. The verbs are `list`, `inspect`, `explain`, `import` and `move`, so deletion is manual and the first step is always to ask Strata where the files are:

```sh
strata models explain IQ3_XXS      # changes nothing; prints the paths it uses
```

**`explain` takes the size name, not the folder tag `models list` printed.** `strata models explain iq3_xxs` works because the size is unique; `gyro-gyro-s` and `swift-iq2_xs` are rejected outright. Use `Gyro-S`, and add `--family` where a size exists in more than one family — `UD-Q4_K_XL` and `Q8_0` both do. The error is helpful rather than cryptic: it lists every size it knows.

Then remove the directories it names, the installed run config, and the launch preset:

```sh
rm -rf <the directory explain printed under "Uses:">
rm -f  ~/.local/share/strata/install/strata-<tag>.json
rm -f  ~/.config/strata/launch-presets/<preset>.json
strata models list                 # confirm it is gone
```

The run config is what makes a pack show as `present`. Deleting the weights without it leaves an entry in `models list` pointing at nothing, which is worse than either state on its own.

Three cautions learned on this machine:

- **`~/Documents/Strata/models` is a symlink to `Models`.** `du` reports the symlink as 0 bytes, which makes the store look empty when it holds 490 GB.
- **There are two stores.** `~/Documents/Strata/` and `~/.local/share/strata/Strata-data/`. A pack reported `present` may have its weights in either, which is exactly what `explain` is for.
- **`mtp/` is shared.** The draft layers are used by more than one pack. Deleting one pack's directory does not mean its MTP entry is orphaned, so leave `mtp/` alone unless `explain` tells you otherwise.

### Confirmed on this machine

Verified with `explain`, in `~/.local/share/strata/Strata-data/models/`:

| Pack | Directory | Measured |
|---|---|---:|
| `qwen/Q2_0` | `Q2_0` | 66.4 GB in 2 files |
| `qwen/IQ2_XS` | `IQ2_XS` | 68.0 GB in 2 files |
| `qwen/IQ3_XXS` | `IQ3_XXS` | 75.8 GB in 2 files |

**210 GB**, all three beaten by `qwen/IQ3_S`, which stays. Each has a run config at `~/.local/share/strata/install/strata-<tag>.json` to remove with it.

Note the second file in each pair is 28.80 GB and identical across all three — that is the n-gram table, and it is held per pack rather than shared. Deleting a pack genuinely frees its full size.

## Tier A — modest, and fits with everything running

This is what the setup script installs by default. Every pack here loads with the server platform up, without `ai-pause`.

| Pack | Command | Download | On disk | Speed | Why |
|---|---|---:|---:|---|---|
| **Flash-Next Coder** | `--family coder --model IQ1_M` | ~68 GB | ~75 GB | 55 tok/s | the coding instrument |
| **Qwen3.6** UD-Q4_K_XL | `--family qwen36 --model UD-Q4_K_XL` | 22.9 GB | ~24 GB | ~60 tok/s | the general-purpose one |
| **Gyro-S** | `--family gyro --model Gyro-S` | 58.5 GB | ~59 GB | ~20% under Q2_0 | full-expert fallback |

**Total: roughly 150 GB**, less where the shared n-gram table deduplicates.

On-disk figures add the MTP draft layer (~6 GB, fetched at first start) and the picture reader (0.9 GB).

Why these three cover the ground: Coder is deliberately crippled outside code and non-English, so Qwen3.6 is there for everything else, and Gyro-S is the smallest Flash-Next build that keeps *every* expert.

## Tier B — larger, pause the cluster first

| Pack | Command | Download | Memory | Caveat |
|---|---|---:|---:|---|
| **Gyro-M** | `--family gyro --model Gyro-M` | 92 GB | 35 GB VRAM+RAM | ~IQ3_XXS quality at ~20% less GPU memory |
| **Qwen3.6** UD-Q6_K_XL | `--family qwen36 --model UD-Q6_K_XL` | 32.6 GB | plans 44 GB | fits with the cluster up at 96 GB; needs `ai-pause` at 64 GB |

Gyro-M's 35 GB is VRAM and RAM combined, so with 16 GB on the card about 19 GB lands in RAM.

## Tier C — what the upgrade resolved

Q2_0 and IQ2_XS used to belong here, as packs that would start on 32 GB but stream most experts from the NVMe on every token. Strata's docs were blunt about it: *"With a small card most experts come from the SSD and it is much slower; setup says so."*

**That is no longer the situation.** At either 64 or 96 GB both hold their experts in RAM and are first-class — they are listed in Tier D below. The 16 GB card still rules out low-RAM mode, which needs 24 GB to help, but low-RAM mode is no longer what you are relying on.

## Tier D — the current working set

| Pack | Command | Download | Speed | Quality vs Q8_0 |
|---|---|---:|---|---|
| **Flash-Next Q2_0** | `--family qwen --model q2_0` | ~70 GB | **94 tok/s** | 80.6% top-1, perplexity 4.475 |
| **Flash-Next IQ2_XS** | `--family qwen --model iq2_xs` | ~72 GB | 79 tok/s | — |
| **Flash-Next IQ3_XXS** | `--family qwen --model iq3_xxs` | ~74 GB | 62 tok/s | 84.5% top-1, perplexity 4.119 |
| **Swift 1.5** IQ2_XS | `--family swift --model IQ2_XS` | ~68 GB | as IQ2_XS | same quality, much shorter thinking |
| **Qwen3.6** Q8_0 | `--family qwen36 --model Q8_0` | 37.8 GB | — | closest to the full 35B |

**IQ2_XS is the recommended default at 64 GB** — Strata's own pick at that tier, the balance point between Q2_0's speed and IQ3's quality, and the largest pack that coexists with the server platform. Those three things landing on the same answer is the reason it is the default rather than a compromise.

At 96 GB the constraint moves off it entirely and the sensible default becomes **IQ3_S**, with IQ2_XS kept for when you want the speed.

## Tier E — the top of the Flash-Next line

| Pack | Command | Download | Note |
|---|---|---:|---|
| **Flash-Next IQ3_S** | `--family qwen --model iq3_s` | ~76 GB | 50 GB of experts + 10 GB OS = 60 GB |

IQ3_S matches the full model on the published tests. At 53 tok/s it is the slowest of the line, and on four DIMMs slower still.

Which tier it belongs to depends entirely on how the memory was fitted. **At 64 GB** its 60 GB leaves nothing for the platform, so it needs `ai-pause --cluster` and is a deliberate "stop everything and think hard" mode. **At 96 GB** it loads with the cluster running and is simply the best default available.

## Tier F — only at 96 GB

**All three are now in the tier system**, and `./07-strata.sh --tier all` installs every one of them. UD-IQ4_XS is **tier F**: the best pack this configuration holds with the cluster still running. UD-Q4_K_XL and NVFP4 are **tier G**, separated because 96 GB is necessary but not sufficient for them — they only fit once `ai-pause --cluster` has freed the platform's ~15 GB.

Together they take the Steam allocation from roughly 546 GB down to about 213 GB. That is the deliberate trade behind `--tier all`; `--tier abcdef` stops at 767 GB and 452 GB of games, `--tier abcde` at 673 GB and 546 GB.

| Pack | Experts | Download | When |
|---|---:|---:|---|
| **`unsloth/UD-IQ4_XS`** | ~62 GB | **94 GB** | **tier F.** Cluster up, against ~68 GB available — a 6 GB margin, so measure before relying on it |
| **`unsloth/UD-Q4_K_XL`** | ~78 GB | **111 GB** | **tier G.** After `ai-pause`, against ~83 GB — a 5 GB margin |
| **`nvfp4/NVFP4`** | ~70 GB | **128 GB** | **tier G.** After `ai-pause`. Your RTX 5070 Ti has FP4 tensor cores built for exactly these |

Note the families: these are `unsloth` and `nvfp4`, not sizes of `qwen`. Asking `qwen` for any of them is rejected.

The three download figures are **measured**, each one read from the `download` line of `strata launch --plan` for that exact pair. They replace estimates that were wrong by 17 to 48 GB — NVFP4 in particular was carried here as "~80 GB, estimated" and is actually 128 GB, the largest single pack in the install. The expert figures beside them are still approximate published numbers, so treat the memory margins as worth attempting rather than guaranteed.

**Disk, not memory, is the constraint up here.** All seven tiers are 1 006 GB, which leaves about 213 GB for games — two or three modern titles. That buys every pack this hardware can execute, switchable without a download. If you would rather keep the games, `--tier abcdef` is the sensible stopping point. See [partition-layout.md](partition-layout.md), or [4tb-upgrade.md](4tb-upgrade.md) for what a larger drive gives back.

## Still out of reach

| Pack | Needs | Why it misses |
|---|---:|---|
| Qwen3.6 `Q8_0` class at full precision | ~136 GB RAM | 188 GB download as well; not without 128 GB and then some |
| `unsloth` sizes above `UD-Q4_K_XL` | 96 GB+ RAM | `UD-Q5_K_XL`, `UD-Q6_K_XL` and `Q8_0` of the 125B are past what 96 GB holds, and each is larger on disk than the 128 GB NVFP4 pack |
| `nvfp4/NVFP4-NVIDIA`, `nvfp4/NVFP4-QAD` | — | memory is the same as `NVFP4`; it is the ~128 GB each that the drive cannot take on top of tier G |
| `swift/IQ3_XXS`, `swift/IQ3_S` | 64 GB+ RAM | they would run, but they duplicate the Flash-Next sizes already installed at tier D and E for ~150 GB |

The last three rows are disk decisions rather than hardware limits, which is a different kind of "out of reach" — a larger drive buys them back, more memory does not. `--catalogue` gives the exact figures if you want to trade a tier for one of them.

**DeepSeek V4.1-Flash is no longer offered by Strata at all.** It used to sit in this table at 257 GB and ~5 tok/s; it is now simply unavailable, and attempting it returns *"Strata no longer offers DeepSeek models."* Nothing in the disk budget on this page or in [4tb-upgrade.md](4tb-upgrade.md) reserves space for it any more.

## Quality ladder, measured

Strata scores each pack against Q8_0 over a fixed 4,995-position set. Top-1 agreement is how often it picks the same most likely token.

| Pack | Same top token | Mean KL | Perplexity (Q8_0 = 4.052) |
|---|---:|---:|---:|
| UD-Q6_K_XL | 94.61% | 0.033 | 4.020 |
| UD-Q5_K_XL | 94.55% | 0.038 | 4.024 |
| UD-Q4_K_XL | 93.09% | 0.056 | 4.068 |
| UD-IQ4_XS | 88.91% | 0.101 | 4.120 |
| IQ3_S | 87.69% | 0.144 | 4.097 |
| IQ3_XXS | 84.46% | 0.202 | 4.119 |
| Q2_0 | 80.60% | 0.315 | **4.475** |

**Q2_0 is the cliff.** It is the fastest thing you can run, but perplexity jumps about 10% while everything above it stays within 2% of the reference. Worth knowing when you pick a default — it argues for climbing as far up this ladder as memory allows, and for not reaching below IQ2_XS to buy back speed.

## Thinking — read this before you judge the speed

Both Qwen models **think by default, and Flash-Next's internal default is `xhigh`, its longest tier.** Omitting `reasoning_effort` does not disable thinking; a plain request returns populated reasoning and a non-zero reasoning-token count.

So a model advertised at 55 tok/s can spend a long stretch generating reasoning you never see before the answer begins. Tokens per second is not latency to first useful output.

Controls, passed through the API:

| Parameter | Values |
|---|---|
| `reasoning_effort` | `none`, `low`, `medium`, `xhigh` (the default) |
| `enable_thinking` | on/off |
| `preserve_thinking` | carry traces across turns |

Qwen3.6 dropped the old `/think` and `/nothink` soft switches, so it has to be an API parameter.

Two cautions before reaching for `none`:

- Qwen's own guidance is that in multi-turn agentic work, **lower reasoning effort does not reliably finish faster**. It causes insufficient analysis, more failures and retries, which can increase total latency and token spend.
- **Sampling parameters differ by mode.** Thinking wants `temperature=1.0, top_p=0.95, top_k=20`. Instruct mode wants `temperature=0.7, top_p=0.80, top_k=20, presence_penalty=1.5`. A client that does not switch these gives you worse output than the model can produce.

This is why **Swift 1.5** is worth a slot: a fine-tune of the same model that thinks much shorter at about the same quality, with identical RAM and per-token speed. It is the targeted fix for verbose reasoning, rather than turning thinking off and losing the capability — and it matters more, not less, on four DIMMs, where every generated token costs more wall-clock time.

## A tension specific to 16 GB of VRAM

Qwen advises keeping at least 128K of context to preserve Qwen3.6's reasoning quality. But context costs VRAM, and on a 16 GB card you are in Strata's hybrid mode where the KV cache competes directly with expert slots: each parallel slot holds about 1.5 GB at 32K context, and a 16 GB card supports about 2 slots at that length.

More system RAM does not fix this — it is a property of the card. Expect to trade context length against how many experts stay resident, at either RAM tier.

## Switching between installed models

Install as many as disk allows; **only one serves at a time** by default.

```sh
strata models list                                  # what is installed
strata launch --plan --family qwen36 --model UD-Q4_K_XL   # preview, downloads nothing
strata launch --family coder --model IQ1_M          # run one
strata launch --stop                                # free the VRAM
strata launch --list-presets                        # the saved configurations
strata launch --preset coder                        # switch
```

The setup scripts save a preset per installed model, so switching is one command. Presets capture context size, parallel slots, vision and access settings alongside the model.

Launching a different model while one serves prompts *"Restart the model with these settings?"*, or refuses under `--no-tui` until you add `--restart`. You can run two at once on different `--port` values, but on 16 GB of VRAM two large models will not fit together.

## Disk footprint

| Plan | Download |
|---|---:|
| Tier A only — the default | ~150 GB |
| Tier A + B | ~275 GB |
| Tier A + B + C | ~417 GB |
| Everything through Tier E (post-upgrade) | ~673 GB |
| Everything through Tier F | ~767 GB |
| Everything through Tier G — `--tier all` | ~1 006 GB |

Two consequences:

- **Ubuntu (2 TB)** takes **all 1 006 GB through tier G**, which is what `--tier all` installs. After the OS, the cluster, game-server worlds, the local backups and a 186 GB free-space reserve, that leaves roughly 213 GB for a Steam library. Tier F stops at 767 GB and 452 GB of games; tier E at 673 GB and 546 GB. The AI side was given priority deliberately; gaming absorbs the difference.
- **Windows (1 TB)** cannot hold much at all. Windows and applications take ~80 GB and the rest of the AI stack another ~108 GB. Install **Coder and Qwen3.6 UD-Q4_K_XL only** there — about 91 GB, leaving roughly 650 GB for games — and keep the rest on Ubuntu.

Worth being clear about what the full install buys, since memory rather than disk decides what you can actually run. With the server platform up, the ceiling is IQ2_XS at 64 GB and UD-IQ4_XS at 96 GB; anything above that needs `ai-pause --cluster` first. Having every pack already on disk is what makes switching between those modes a one-liner instead of a 76 GB download, which is the whole argument for spending the 1 006 GB.

All three 96 GB packs are in that 1 006 GB. `unsloth/UD-IQ4_XS` runs with the cluster up; the other two need `ai-pause --cluster` first, which is the only practical difference between tiers F and G.

**`--tier all` is not the whole catalogue.** It is 14 of Strata's 28 family/model combinations — everything this *drive* holds, not everything Strata offers. The other 14 are listed under "Still out of reach" above and enumerated with live sizes by `./07-strata.sh --catalogue`.

See [partition-layout.md](partition-layout.md) for the full disk budget and [ram-upgrade-decision.md](ram-upgrade-decision.md) for the add-versus-swap decision behind the two memory columns on this page.
