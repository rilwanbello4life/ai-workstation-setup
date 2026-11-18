# Model manifest — 16 GB VRAM / 32 GB RAM

Every path below is relative to the AI root on whichever system you are on: `C:\AI` on Windows, `~/ai` on Ubuntu. The two systems share nothing, so **run the download on each OS separately**.

Download with [`download-models.ps1`](download-models.ps1) (Windows) or [`download-models.sh`](download-models.sh) (Linux). Both take a group name: `image`, `video`, `voice`, or `all`.

**Verification status** is marked on each entry. Entries marked *verify* are correct in shape but the exact repository may have been renamed — use ComfyUI Manager's model browser or `hf search` to confirm before downloading rather than trusting the string blindly.

## Text

Handled outside this manifest:

- **Strata model packs** — fetched by Strata itself, never manually. On 32 GB that is Flash-Next Coder (~68 GB), Qwen3.6-35B-A3B UD-Q4_K_XL (~23 GB) and Gyro-S (~59 GB); Windows gets the first two only. Install with `ubuntu/07-strata.sh` or `strata launch --family <f> --model <m>`, and see [strata-models.md](../reference/strata-models.md) for the full catalogue and what each memory tier adds.
- **Fast everyday chat model** — a 12–14B dense model at Q4_K_M, roughly 9 GB, which sits entirely in VRAM and answers instantly. Pick this through LM Studio's built-in model browser, which only lists GGUFs it has verified against the current runtime. Set LM Studio's models directory to `C:\AI\gguf` first.

Rule of thumb for what fits: at Q4_K_M a dense model needs about `parameters × 0.6 GB`. With 16 GB of VRAM, stay at or under 14B if you want the whole model resident with room for context.

## Image

### Z-Image Turbo — the default *(verified)*

Apache-2.0, photorealistic, ~11 s per image, 14.6 GB peak. Three files, ~20 GB total.

| File | Repository | Destination |
|---|---|---|
| `z_image_turbo_bf16.safetensors` | `Comfy-Org/z_image_turbo` → `split_files/diffusion_models/` | `models/diffusion_models/` |
| `qwen_3_4b.safetensors` | `Comfy-Org/z_image_turbo` → `split_files/text_encoders/` | `models/text_encoders/` |
| `ae.safetensors` | `Comfy-Org/z_image_turbo` → `split_files/vae/` | `models/vae/` |

Note that `ae.safetensors` is the FLUX.1 autoencoder, which Z-Image reuses. Apache-2.0 either way.

In ComfyUI: Templates → Image → Z-Image-Turbo: Text to Image.

### FLUX.2 klein 4B — the speed option *(verify)*

Open licence, ~2.9 s per image, 12.2 GB peak. The fastest thing that fits comfortably in 16 GB and the right default when you want to iterate on prompts quickly.

It reuses the **same Qwen3-4B conditioner** as Z-Image Turbo, so if you have downloaded Z-Image you only need the diffusion weights. Find the current FP8 repack through ComfyUI Manager rather than hardcoding a path — the klein repacks have been renamed more than once.

### FLUX.2 klein 9B — do not bother

About 29 GB. It does not fit this card.

### Optional additions

- **Ming-Image INT8** — best in class for text, posters and logos, but wants ~28 GB of system RAM. Tight at 32 GB; close everything else first.
- **Qwen-Image 2.1 INT8** — text-to-image and editing in one model, outputs transparent PNGs. Non-commercial licence. Take the INT8 build, which is about 2.5× faster than the GGUF.
- **RealESRGAN x4** for upscaling: `https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth` → `models/upscale_models/`

## Video

### Wan 2.2 TI2V-5B — the safe default *(verify)*

Single model handling both text-to-video and image-to-video at 720p, 24 fps, 5 seconds. The official ComfyUI tutorial states it fits well in 8 GB with native offloading, so your 16 GB has real headroom.

Three files from `Comfy-Org/Wan_2.2_ComfyUI_Repackaged`:

| File | Destination |
|---|---|
| `split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors` | `models/diffusion_models/` |
| `split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors` | `models/text_encoders/` |
| `split_files/vae/wan2.2_vae.safetensors` | `models/vae/` |

### Wan 2.2 I2V-A14B GGUF — the quality option

Needs `ComfyUI-GGUF` (installed by Phase 6). Use **Q4_K_M**, which is 9.65 GB per expert, together with the LightX2V 4-step distillation LoRAs. Four steps total (two high-noise, two low-noise) at CFG 1, resolution 832×480.

Without the 4-step LoRAs this is unusably slow on a 16 GB card. With them it is practical.

Image-to-video generally beats text-to-video for control: generate a still with Z-Image Turbo first, then animate it.

## Voice

### Speech to text — faster-whisper

No manual download needed. `faster-whisper` resolves and caches the model on first use:

```python
from faster_whisper import WhisperModel
model = WhisperModel("large-v3-turbo", device="cuda", compute_type="int8_float16")
```

`large-v3-turbo` is 809M parameters, MIT licensed, several times faster than `large-v3` at similar accuracy in the major languages, and runs in roughly 1.5 GB at int8.

Alternative if you want raw speed over language coverage: **`nvidia/parakeet-tdt-0.6b-v3`** *(verified)*, CC-BY-4.0, 25 European languages, the fastest open STT available.

### Text to speech — Kokoro-82M *(verified)*

`hexgrad/Kokoro-82M`, Apache-2.0, commercial use allowed. 82M parameters, faster than realtime on CPU alone, so it never competes with the GPU. Fixed voice pack, no cloning.

For voice cloning: **`ResembleAI/chatterbox`** *(verified)*, MIT, clones from about 10 seconds of reference audio with an emotion control. Needs roughly 6 GB of VRAM. Every output carries an inaudible watermark.

Avoid XTTS-v2 and F5-TTS unless the project is non-commercial — both have licences you cannot buy your way out of.

## Disk budget

| Group | Ubuntu | Windows |
|---|---:|---:|
| Strata packs | ~150 GB | ~91 GB |
| Z-Image Turbo | ~20 GB | ~20 GB |
| Wan 2.2 TI2V-5B | ~13 GB | ~13 GB |
| Wan 2.2 14B GGUF Q4_K_M + LoRAs | ~25 GB | ~25 GB |
| Voice models | ~3 GB | ~3 GB |
| A few 12–14B GGUF chat models | ~30 GB | ~30 GB |
| **Total** | **~241 GB** | **~182 GB** |

Strata is the reason the two columns differ. It serves one model at a time, so installing several is purely a disk question — Ubuntu's 2 TB takes the full catalogue, while Windows takes Coder and Qwen3.6 only.

On **Ubuntu** that lands against roughly 3.7 TB of usable space, so you can be relaxed about keeping multiple variants, the full ~677 GB Strata catalogue, the cluster's container images and a shelf of game servers all at once.

On **Windows** it is tighter: Windows and applications take ~80 GB of the 1 TB drive, leaving about 650 GB for games once the stack is in. If you want more room for games, skip the `video` group on Windows — that is 38 GB of the table above, and Wan 2.2 is the slowest thing on a 16 GB card anyway. Run it on Ubuntu instead.
