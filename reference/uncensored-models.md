# Abliterated and uncensored models

**None of these come from Strata.** Its catalogue is seven families of Qwen and one Swift fine-tune, all with their original alignment, and there is no way to point Strata at a file you downloaded. Everything on this page runs under llama.cpp — see [harnesses.md](harnesses.md) for why that split exists.

## The two things people mean by "uncensored"

They are different techniques with different failure modes, and the difference matters when choosing.

**Abliteration** is weight editing. The refusal direction is identified in the model's activation space and removed from specific layers. Nothing is retrained. It is surgical and cheap, and because it is subtractive, it is honest about what it did — a good card names the layers edited. The cost is that removing a direction the model uses for refusal may also remove the parts of it used for other judgements, and almost nobody publishes a measurement of what that cost.

**Fine-tuning** retrains on a dataset without refusals. More expensive, less precise about what changed, but the model remains internally consistent rather than having a direction surgically excised. Dolphin is the long-running example.

A third term, **heretic**, has appeared recently: automated abliteration with published before-and-after numbers. Where the numbers exist, prefer it — it is the only one of the three that routinely tells you what the modification cost.

## Picks for this machine

96 GB of RAM and 16 GB of VRAM. These are dense models, not MoE, so unlike Flash-Next the whole weight file is active and the rule is simply *weights plus KV cache must fit in RAM, and as much as possible should fit in VRAM*.

| Pick | Base | Params | Size at the quant I would use | Why this one |
|---|---|---:|---:|---|
| **Huihui-Qwen3.8-27B-abliterated** | Qwen3.8-27B | 27.8B | Q8_0_L, ~31 GiB | The card names the exact layers edited (18–51) and says the vision and MTP parts were left alone. Apache 2.0. 262K native context. Same model generation as your main Strata pack, so the behaviour is familiar. |
| **Llama-3.3-70B-Instruct-abliterated** | Llama 3.3 70B | 70.6B | Q6_K, ~58 GiB | The large dense option. Runs on every stack, has been re-quantised by several publishers, and at 70B dense it reasons differently from a sparse MoE — genuinely a second opinion rather than the same model unlocked. **Licence caveat below.** |
| **Dolphin Mistral 24B Venice Edition** | Mistral-Small-24B | 24B | Q8_0, ~26 GiB | The fine-tune rather than the edit, for when abliteration damage is the thing you are working around. Apache 2.0. |

Use [bartowski](https://huggingface.co/bartowski)'s imatrix GGUF conversions where they exist. Importance-matrix quantisation measurably beats plain quantisation at the same file size, and it costs nothing extra to prefer it.

**Two is the right number to keep**, not five. These are dense models where quality tracks size closely, so a 27B and a 70B cover the ground; a 13B abliterated model adds nothing a 27B does not do better.

### On quantisation level

Be less aggressive here than with Flash-Next. A 125B MoE at Q2 still has enormous total capacity to draw on; a 27B dense model at Q2 is simply a damaged 27B model. **Q6_K is the floor for these, Q8_0 where it fits.** You have the memory — the whole point of the upgrade was to stop trading quality for fit.

### Licence, stated plainly

The Llama 3.3 acceptable use policy prohibits acting to *"intentionally circumvent or remove usage restrictions or other safety measures"*. An abliterated Llama is, on the face of it, exactly that. The Qwen and Mistral picks are Apache 2.0 with no equivalent clause, which is a real reason to prefer them if the distinction matters to you. This is not legal advice, and it is your call — but it should be a decision rather than a surprise.

## Running one

```sh
# Fetch (the exact filename comes from the repo's file list)
hf download bartowski/Huihui-Qwen3.8-27B-abliterated-GGUF \
    --include '*Q8_0_L*' --local-dir ~/ai/gguf

# Serve it on 8081, the llama.cpp port
ops/switch.sh llamacpp ~/ai/gguf/<the-file>.gguf
```

`ops/switch.sh` stops Strata first and waits for the driver to release the VRAM. Starting llama.cpp by hand while a Strata pack is resident gives an out-of-memory error that reads like the model being too large.

For a 27B at Q8 on a 16 GB card, most of the model lives in RAM and the card holds what it can. That is expected and still comfortably usable; these are small models by this machine's standards.

## Adding one to the gateway

So that n8n, Open WebUI and the agent roles can reach it like any other model, add it to `model_list` in `server/k8s/11-litellm.yaml` beside the Strata entries:

```yaml
- model_name: uncensored
  litellm_params:
    model: openai/llamacpp
    api_base: http://llamacpp.platform.svc.cluster.local:8081/v1
    api_key: "none"
```

The same entry has to go into `server/gitops/source/platform/templates/_helpers.tpl`, and the two must stay identical or Argo CD reads the difference as drift. See [gitops.md](gitops.md).

## What to be careful about

These models will produce whatever is asked of them, including things that are wrong, dangerous or illegal to act on. That is the entire point and also the entire risk. Two specific cautions for this setup rather than general ones:

- **Never give an uncensored model a tool with write access.** The agent roles in [agent-orchestration.md](agent-orchestration.md) and the MCP gateway planned in [roadmap.md](roadmap.md) are where this becomes concrete: a model with reduced refusal behaviour and a `gmail.send` scope is a worse combination than either alone. Keep them on the read side.
- **Do not put one behind a friends key.** [sharing-with-friends.md](sharing-with-friends.md) covers handing out model access; what a guest generates on your hardware and your address is your problem. Keep the uncensored aliases out of the model groups the queue exposes on 4100.
