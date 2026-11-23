# Model manifest — 16 GB VRAM, 32 GB RAM now and 96 GB after phase 11

Every path below is relative to the AI root on whichever system you are on: `C:\AI` on Windows, `~/ai` on Ubuntu. The two systems share nothing, so **run the download on each OS separately**.

Download with [`download-models.ps1`](download-models.ps1) (Windows) or [`download-models.sh`](download-models.sh) (Linux). Both take a group name: `image`, `video`, `voice`, `text`, or `all`. Everything in the tables below that is marked *verified* is in [`manifest.tsv`](manifest.tsv) and arrives with `all`; entries marked *verify* or listed as optional are deliberately left for you to fetch by hand.

**Verification status** is marked on each entry. Entries marked *verify* are correct in shape but the exact repository may have been renamed — use ComfyUI Manager's model browser or `hf search` to confirm before downloading rather than trusting the string blindly.

## What the memory upgrade changes, and what it does not

96 GB of RAM changes the text models completely and the image, video and voice models not at all. The reason is worth internalising before pruning anything, because the instinct to "use bigger models now" is right for one of these and wrong for the others.

**Language models are memory-bound.** A 125B MoE touches ~2% of its parameters per token, so experts can live in RAM and be fetched as needed. More RAM means more experts resident means a bigger model runs. That is the whole story of [strata-models.md](../reference/strata-models.md), and at 96 GB the small packs genuinely are obsolete.

**Diffusion models are VRAM-bound.** Image and video generation runs every parameter for every step. There is no sparse activation to exploit and no useful way to stream weights from RAM mid-step — a model that does not fit in 16 GB of VRAM either runs at a fraction of the speed or does not run. **The upgrade bought nothing here.** The card still governs, and the right models are the same ones as before.

So, applying the same "delete what is outclassed" logic to each group:

| Group | Verdict |
|---|---|
| **Voice** | Nothing to prune. Kokoro-82M and faster-whisper-large-v3-turbo are 3 GB together, both are already the best of their kind at this size, and both run on CPU so they never compete with the GPU. |
| **Image** | Z-Image Turbo stays. It is a distilled few-step model — the point is 4–8 steps rather than 30, and a bigger model does not outclass it so much as do a different job. If you want a quality tier beside it, that is an addition, not a replacement. |
| **Video** | Here the logic does apply. **Wan 2.2 I2V-A14B GGUF outclasses TI2V-5B**, and if you install the 14B there is little reason to keep the 5B — 13 GB back. Keep the 5B only while you are still deciding, since it is the one that runs comfortably in 16 GB. |
| **Text (GGUF)** | Qwen2.5-14B-Instruct Q4_K_M stays despite being small. It is 9 GB, it is VRAM-resident, and LiteLLM's `local` and `checker` aliases point at it — deleting it silently breaks two routes. It is infrastructure, not a model you chose. |

The general principle: **prune where more memory made something obsolete, not everywhere at once.** A small language model next to a 125B is redundant. A small diffusion model next to a large one is a speed tier you will actually use.

## Text

Handled outside this manifest:

- **Strata model packs** — fetched by Strata itself, never manually, and sized by RAM rather than by this manifest. On the factory 32 GB that is tier A: Flash-Next Coder (~68 GB), Qwen3.6-35B-A3B UD-Q4_K_XL (~23 GB) and Gyro-S (~59 GB), with Windows taking the first two only. After the phase 11 upgrade to 96 GB, `./07-strata.sh --tier all --install` fetches tiers A-G, about 1 006 GB - every pack this machine can run. That is 14 of the 28 family/model combinations Strata offers; the rest will not fit on the drive, and `./07-strata.sh --catalogue` lists them with measured sizes.

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

On **Ubuntu** that lands against roughly 1 863 GiB of usable space on the 2 TB drive. The 1 006 GB of Strata packs, these ComfyUI and voice models, the cluster's container images, the game-server worlds and the local backups come to about 1 464 GB, which leaves roughly 213 GB for a Steam library after a 186 GB free-space reserve. [partition-layout.md](../reference/partition-layout.md) has the full arithmetic.

On **Windows** it is tighter: Windows and applications take ~80 GB of the 1 TB drive, leaving about 650 GB for games once the stack is in. If you want more room for games, skip the `video` group on Windows — that is 38 GB of the table above, and Wan 2.2 is the slowest thing on a 16 GB card anyway. Run it on Ubuntu instead.

## The download ledger

Every confirmed download is recorded in `$AI_ROOT/.downloads.tsv`, and that
file — not the filesystem, and not the Hugging Face cache — is what later runs
consult. A recorded entry is skipped outright: no hub request, no directory
scan, nothing handed to Strata or to `hf`.

This is not only about speed. `hf` contacts the hub for every entry even when
the file is already cached, so re-running a finished manifest used to spend a
long time on the network in order to do nothing. Strata is worse: the only way
to ask it for a pack is `strata launch`, which loads the pack after fetching
it, and on a 32 GB machine loading a 128 GB pack is what gets the desktop
killed.

It is a five-column TSV — `kind`, `id`, `status`, `when`, `note` — where `kind`
is `strata` or `file` and the last row for an id wins. Readable and editable by
hand: delete a row to force a re-download, or change `failed` to `ok` to stop a
retry.

| Want | Strata packs | Everything else |
|---|---|---|
| See what is done and what is left | `./07-strata.sh --tier all --status` | `./10-models.sh --status` |
| Fetch without loading | `./07-strata.sh --tier all --install -y --download-only` | not needed — these are never loaded |
| Retry the failures | re-run; failures are retried by default | re-run |
| Leave the failures alone | add `--skip-failed` | `SKIP_FAILED=yes ./10-models.sh` |

If the ledger is deleted, nothing is lost. Both scripts fall back to checking
the disk, find the files already there, and record them again — so recovery
costs one pass, not one re-download.

### Downloading on a machine that cannot run the models

`strata launch` always loads a pack after downloading it, and there is no
download-only flag in Strata itself. `--download-only` supplies one: it runs
the launch inside a systemd scope capped at 12 GB. Downloading needs very
little memory and loading needs tens of gigabytes, so the fetch completes and
the load is killed the moment it starts.

That is why a pack killed for memory is recorded as **downloaded**. Reaching
the point of being killed proves the download finished — a network failure
exits long before anything large is resident. The bytes are on disk, and after
a memory upgrade the same pack loads without fetching anything again.
