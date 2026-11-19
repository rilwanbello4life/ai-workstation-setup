# Model manifest — 16 GB VRAM, 32 GB RAM now and 96 GB after phase 11

Every path below is relative to the AI root on whichever system you are on: `C:\AI` on Windows, `~/ai` on Ubuntu. The two systems share nothing, so **run the download on each OS separately**.

Download with [`download-models.ps1`](download-models.ps1) (Windows) or [`download-models.sh`](download-models.sh) (Linux). Both take a group name: `image`, `video`, `voice`, `text`, or `all`. Everything in the tables below that is marked *verified* is in [`manifest.tsv`](manifest.tsv) and arrives with `all`; entries marked *verify* or listed as optional are deliberately left for you to fetch by hand.

**Verification status** is marked on each entry. Entries marked *verify* are correct in shape but the exact repository may have been renamed — use ComfyUI Manager's model browser or `hf search` to confirm before downloading rather than trusting the string blindly.

## Text

Handled outside this manifest:

- **Strata model packs** — fetched by Strata itself, never manually, and sized by RAM rather than by this manifest. On the factory 32 GB that is tier A: Flash-Next Coder (~68 GB), Qwen3.6-35B-A3B UD-Q4_K_XL (~23 GB) and Gyro-S (~59 GB), with Windows taking the first two only. After the phase 11 upgrade to 96 GB, `./07-strata.sh --tier all --install` fetches tiers A-G, about 998 GB - everything this machine can run.

  Packs are downloaded once and kept, so there is no harm in fetching the larger tiers before the DIMMs arrive — they simply sit on disk until the memory is there, and the installer warns rather than refuses. See [strata-models.md](../reference/strata-models.md) for the catalogue and what each memory tier unlocks.
- **Fast everyday chat model** *(verified)* — `bartowski/Qwen2.5-14B-Instruct-GGUF` → `Qwen2.5-14B-Instruct-Q4_K_M.gguf`, roughly 9 GB, which sits entirely in 16 GB of VRAM and answers instantly. This is the `text` group, so `download-models.sh text` or `all` fetches it into `gguf/`.

  It is not an optional extra on Ubuntu: `ubuntu/04-llamacpp.sh` installs the server but ships no weights, and LiteLLM's `local` and `checker` aliases both point at it, so without a GGUF in `gguf/` those two routes answer nothing. Serve it with `start-llama-server.sh Qwen2.5-14B-Instruct-Q4_K_M.gguf`.

  On Windows you can equally pick one through LM Studio's model browser, which only lists GGUFs it has verified against the current runtime — point LM Studio's models directory at `C:\AI\gguf` so both tools share the same files.

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

### Speech to text — faster-whisper *(verified)*

`deepdml/faster-whisper-large-v3-turbo-ct2`, a CTranslate2 build of large-v3-turbo, fetched as a whole repository into `voice/whisper/` by the `voice` group.

`faster-whisper` will also resolve the model by name and cache it on first use, so this download is not strictly required — but the first transcription on a fresh install then stalls for minutes while it pulls, and fails outright with no network. `voice/server.py` prefers `$AI_ROOT/voice/whisper` when it finds a `model.bin` there and falls back to the bare name otherwise, so pre-downloading simply makes the first request fast:

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

On **Ubuntu** that lands against roughly 1 863 GiB of usable space on the 2 TB drive. The 998 GB Strata catalogue, these ComfyUI and voice models, the cluster's container images, the game-server worlds and the local backups come to about 1 456 GB, which leaves roughly 221 GB for a Steam library after a 186 GB free-space reserve. [partition-layout.md](../reference/partition-layout.md) has the full arithmetic.

On **Windows** it is tighter: Windows and applications take ~80 GB of the 1 TB drive, leaving about 650 GB for games once the stack is in. If you want more room for games, skip the `video` group on Windows — that is 38 GB of the table above, and Wan 2.2 is the slowest thing on a 16 GB card anyway. Run it on Ubuntu instead.
