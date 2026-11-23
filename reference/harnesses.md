# Harnesses — Strata, llama.cpp, and the alternatives

Two things run models on this machine and they are not competitors. This page says what each is for, why both exist, and what else could replace either.

## The short version

| | Strata | llama.cpp |
|---|---|---|
| Runs | Strata's own packs, from its catalogue | any GGUF file you can find |
| Chooses the layout | yes, automatically | no, you pass flags |
| Model selection | seven families, fixed list | all of Hugging Face |
| Good at | one very large MoE on modest hardware | everything else, and total control |
| Port in this kit | 8080 | 8081 |
| Installed by | [`../ubuntu/07-strata.sh`](../ubuntu/07-strata.sh) | [`../ubuntu/04-llamacpp.sh`](../ubuntu/04-llamacpp.sh) |

**Strata for the 125B, llama.cpp for everything else.** That is the whole rule, and the rest of this page is why.

## What Strata actually does for you

Strata is a packaging and placement layer over an inference engine. The part that earns its place is placement.

Qwen3.8-Flash-Next is 125B parameters with 512 experts per layer, of which 11 are active per token. Running it on a 16 GB card means deciding, continuously, which experts live in VRAM, which live in RAM, and which are read from the SSD — plus where the 29 GB n-gram table goes and how much VRAM the KV cache may take. Those decisions interact: more context means fewer resident experts means more SSD reads means slower tokens.

Strata measures your machine and makes those decisions. `strata launch --plan` shows the result before committing to it. Doing the same by hand in llama.cpp means `--n-gpu-layers`, `--override-tensor` regex patterns to pin specific expert tensors to CPU, `--n-cpu-moe`, and a tuning loop to find out which combination is fastest — per model, per context length.

That is a real service, and it is the reason this kit uses Strata for the big model rather than driving llama.cpp directly.

**What you give up is choice.** Strata serves its own catalogue. You cannot point it at an arbitrary GGUF from Hugging Face, which means no abliterated models, no fine-tunes, no community quants, nothing published after Strata adds it. The catalogue is seven families — see [strata-models.md](strata-models.md).

## What llama.cpp is for

Everything Strata will not run. It is the engine underneath most of the local-model world, it takes any GGUF, and this kit builds it from source against `sm_120` so the RTX 5070 Ti is used properly.

In practice that means:

- **Abliterated and uncensored models.** None exist in Strata's catalogue and none ever will. See [uncensored-models.md](uncensored-models.md).
- **Anything newer than Strata's catalogue.** A model released this week has GGUF conversions within days.
- **Small, fast models** held entirely in VRAM, for classification, routing and anything called in a loop.
- **Embeddings and reranking**, which Strata does not serve at all.

The cost is that you make the placement decisions yourself. For a dense model that fits in VRAM this is trivial — `--n-gpu-layers 999` and you are done. For a large MoE that does not fit, it is the work Strata was doing for you.

## When to reach for which

```
Is it in Strata's catalogue?
├── yes → is it the thing you actually want?
│         ├── yes → Strata
│         └── no  → llama.cpp with a GGUF of the thing you want
└── no  → llama.cpp
```

Both serve an OpenAI-compatible API, so everything downstream — LiteLLM, n8n, Open WebUI, the agent roles — does not care which answered. They are two entries in LiteLLM's `model_list` and nothing else in the stack knows the difference. That is the point of putting a gateway in front.

**They cannot both hold the GPU.** `ops/switch.sh` stops one before starting the other and waits for the driver to release the VRAM. Starting the second by hand without that wait produces an out-of-memory error that looks like the model is too big.

## The other harnesses, and whether they are worth it

| Harness | What it is | Worth it here? |
|---|---|---|
| **Ollama** | a wrapper around llama.cpp with a model registry | No. You already have llama.cpp and a gateway. Ollama adds a second model store and its own API conventions to keep in sync. |
| **LM Studio** | a desktop GUI over llama.cpp | No, for the same reason, plus it wants to be the thing you interact with. Open WebUI already fills that slot and is reachable from your phone. |
| **vLLM** | high-throughput GPU serving, continuous batching | **No, and this is a hardware fact rather than a preference.** vLLM is built on the assumption that the weights fit in VRAM. 16 GB does not hold a 125B model at any quantisation. It is the right answer for a 24B model on a 48 GB card serving many users, which is not this machine. |
| **SGLang** | like vLLM, with better structured-output handling | No, same reason. |
| **ExLlamaV2 / V3** | very fast GPU-resident quantised inference | No, same reason — GPU-resident is the whole design. |
| **ik_llama.cpp** | a llama.cpp fork specialising in CPU-side MoE performance | **Genuinely interesting.** It exists for exactly this shape of problem — large MoE, small card, most experts in RAM — and reports meaningful gains over upstream on CPU-bound MoE work. The cost is another engine to build and track, and Strata is already doing informed placement. Worth trying if you become convinced Strata is leaving speed on the table; not worth it speculatively. |
| **KTransformers** | CPU+GPU hybrid MoE inference, from Tsinghua | **Same category.** Purpose-built for running very large MoE models with a single consumer GPU by keeping attention on the GPU and expert FFNs on the CPU. Closest thing to a real alternative to Strata for the 125B. Rougher to operate, and sensitive to exact model support. |

The pattern: everything GPU-resident is ruled out by 16 GB of VRAM, not by preference. Everything that wraps llama.cpp is redundant because llama.cpp is already here. The only serious alternatives are the two CPU-MoE specialists, and they compete with Strata rather than with llama.cpp.

## Can llama.cpp run Strata's packs?

Partly, and it is rarely worth it. Strata's packs are GGUF underneath, so `llama-server --model <the .gguf>` will often start. What you lose is the placement work — the expert pinning, the n-gram table handling and the tuned context/VRAM split — which is precisely the part you were using Strata for. Expect it to be slower, sometimes by a lot, and to need manual `--override-tensor` work to get back to parity.

The one good reason to do it is a capability Strata does not expose: grammars, custom sampling, speculative decoding with a draft model of your choosing.

## Can Strata run a model you downloaded?

No. Strata installs from its own catalogue into its own data directory with its own metadata. There is no supported path for pointing it at an arbitrary GGUF. If the model you want is not in `strata models list`, it is a llama.cpp model.

This is the single most important consequence of the Strata/llama.cpp split, and it is why llama.cpp is not optional on this machine even though Strata serves the flagship.
