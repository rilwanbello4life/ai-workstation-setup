# Strata model catalogue and download plan

Strata is not a single-model runner. It serves three base models, and most of what looks like a long model list is the same model at different precision. This page is the full catalogue, what runs on your hardware now, and exactly what to add when you reach 64 GB.

Install and switch with [`../ubuntu/07-strata.sh`](../ubuntu/07-strata.sh) or [`../windows/05-install-ai-stack.ps1`](../windows/05-install-ai-stack.ps1).

## The three base models

| | Qwen3.8-Flash-Next | Qwen3.6-35B-A3B | DeepSeek V4.1-Flash-1017 |
|---|---|---|---|
| Total / active parameters | 125B / 6B | 35B / 3B | 6 of 384 experts per layer |
| Experts | 512 per layer, 10 routed + 1 shared | 256 per layer, 8 routed + 1 shared | 384 per layer, 6 active |
| Layers | 48 — 36 GatedDeltaNet + 12 sparse attention | 40 | — |
| Extra weights | 51B n-gram (Engram) table + 4B MTP head | MTP draft layer | Engram table + DSpark drafter |
| Native context | 262,144, to 1M with YaRN | 262,144, to 1.01M | **8,192 as Strata runs it** |
| Input | text + images | text + images + video | text + images |
| Licence | Qwen Community 1.0 | **Apache 2.0** | see model card |

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
| UD-IQ4_XS | 62 GB | ~72 GB | yes, 6 GB margin | no |
| NVFP4 | 70 GB | ~80 GB | no, needs `ai-pause` | no |
| UD-Q4_K_XL | 78 GB | ~88 GB | no, needs `ai-pause` | no |

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
| **Swift 1.5** IQ2_XS | `--family swift --model IQ2_XS` | ~72 GB | as IQ2_XS | same quality, much shorter thinking |
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

**UD-IQ4_XS is now tier F in the scripts** and is included in `./07-strata.sh --tier all`. It is the best pack this configuration holds with the cluster still running, so it earns a place in the default install rather than being a manual afterthought. It costs about 111 GB, taking the Steam allocation from roughly 542 GB down to 431 GB — see [partition-layout.md](partition-layout.md).

The other two stay outside the tier letters on purpose, and are fetched by hand once the four-DIMM configuration has passed `memtest86+`:

| Pack | Experts | Download | When |
|---|---:|---:|---|
| **Unsloth UD-IQ4_XS** | ~62 GB | ~111 GB | **tier F, in `--tier all`.** Cluster up, against ~68 GB available — a 6 GB margin, so measure before relying on it |
| **NVFP4** (all three) | ~70 GB | — | by hand, after `ai-pause`. Your RTX 5070 Ti has FP4 tensor cores built for exactly these |
| **Unsloth UD-Q4_K_XL** | ~78 GB | ~130 GB | by hand, after `ai-pause`, against ~83 GB — a 5 GB margin |

Both margins come from approximate published figures, so treat them as worth attempting rather than guaranteed.

The reason NVFP4 and UD-Q4_K_XL are excluded from `--tier all` is not caution about memory — it is disk. Tier F plus either one overruns the Steam allocation entirely, and NVFP4 publishes no download size, so the installer has no figure to check against its disk guard.

**Disk, not memory, is the constraint up here.** Tiers A-F are 788 GB. Adding either remaining pack to that overruns what [partition-layout.md](partition-layout.md) leaves for a Steam library. Take one only if you have decided what it displaces, or see [4tb-upgrade.md](4tb-upgrade.md).

## Still out of reach

| Pack | Needs | Why it misses |
|---|---:|---|
| Qwen3.6 Q8_0 class | ~136 GB RAM | 188 GB download as well; not without 128 GB and then some |
| DeepSeek V4.1-Flash | 46 GB RAM min, **257 GB disk** | memory is fine at either tier — it measures ~5 tok/s on this class of card and Strata caps its context at 8K |

DeepSeek is the one judgement call here. It *will* start, comfortably. At five tokens a second and a quarter-terabyte download on a 2 TB drive, it is a curiosity rather than a tool on this hardware.

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
| Everything through Tier E (post-upgrade) | ~677 GB |
| Everything through Tier F — `--tier all` | ~788 GB |

Two consequences:

- **Ubuntu (2 TB)** takes the **entire catalogue through tier F — all 788 GB**, which is what `--tier all` now installs. After the OS, the cluster, game-server worlds, the local backups and a 186 GB free-space reserve, that leaves roughly 431 GB for a Steam library. Stopping at tier E keeps the Steam figure at 542 GB. The AI side was given priority deliberately; gaming absorbs the difference.
- **Windows (1 TB)** cannot hold much at all. Windows and applications take ~80 GB and the rest of the AI stack another ~108 GB. Install **Coder and Qwen3.6 UD-Q4_K_XL only** there — about 91 GB, leaving roughly 650 GB for games — and keep the rest on Ubuntu.

Worth being clear about what the full install buys, since memory rather than disk decides what you can actually run. With the server platform up, the ceiling is IQ2_XS at 64 GB and UD-IQ4_XS at 96 GB; anything above that needs `ai-pause --cluster` first. Having every pack already on disk is what makes switching between those modes a one-liner instead of a 76 GB download, which is the whole argument for spending the 788 GB.

Of the three 96 GB packs only UD-IQ4_XS is in that 788 GB. You can run the other two at 96 GB but you cannot hold them all — budget a further 130 GB for UD-Q4_K_XL against the Steam library, and take it only if you have decided what it displaces.

The one model that does not fit cleanly at any memory tier is **DeepSeek V4.1-Flash** at 257 GB — and disk is the lesser of its two problems, since it measures about 5 tok/s on this card. It is itemised with the rest of the trade-offs in [4tb-upgrade.md](4tb-upgrade.md).

See [partition-layout.md](partition-layout.md) for the full disk budget and [ram-upgrade-decision.md](ram-upgrade-decision.md) for the add-versus-swap decision behind the two memory columns on this page.
