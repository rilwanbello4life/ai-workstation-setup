# Manual setup — Ubuntu

Everything the Ubuntu scripts do, as commands you run yourself, with the reasoning for each one. Follow this instead of `ubuntu/setup-all.sh` if you would rather understand each change than trust a script.

Assumes Ubuntu 24.04 LTS is already installed on the 2 TB drive — see [ubuntu-install-walkthrough.md](ubuntu-install-walkthrough.md) for that part, which is the only genuinely risky phase.

Run everything as **your normal user**, not root. The steps that need elevation call `sudo` explicitly, and a few would put root-owned files in your home directory if you ran the whole thing as root.

| Section | Replaces |
|---|---|
| [1. NVIDIA driver](#1-nvidia-driver) | `01-nvidia.sh` |
| [2. Performance tuning](#2-performance-tuning) | `02-tune-linux.sh` |
| [3. Python and CUDA](#3-python-and-cuda) | `03-python-cuda.sh` |
| [4. llama.cpp](#4-llamacpp) | `04-llamacpp.sh` |
| [5. ComfyUI](#5-comfyui) | `05-comfyui.sh` |
| [6. Voice server](#6-voice-server) | `06-voice.sh` |
| [7. Strata](#7-strata) | `07-strata.sh` |
| [8. Models](#8-models) | `models/download-models.sh` |
| [9. Remote access](#9-remote-access-optional) | `08-remote-access.sh` |

Two paths are used throughout, matching `C:\AI` and the Windows layout on the other drive:

```bash
export AI_ROOT="$HOME/ai"     # models and generated output
export APPS="$HOME/apps"      # application checkouts and virtualenvs
```

---

## 1. NVIDIA driver

### 1.1 Confirm the card

```bash
sudo apt-get install -y pciutils
lspci -nn | grep -i 'VGA\|3D controller'
```

You are looking for `10de:2b83` — the GeForce RTX 5070 Ti.

### 1.2 Check Secure Boot

```bash
mokutil --sb-state
```

If it says enabled, leave it that way, but read step 1.4 before rebooting. Missing the MOK screen is the single most common way to end up on a software-rendered desktop wondering what went wrong.

### 1.3 Install the open kernel modules

**Blackwell cards work only with NVIDIA's open kernel modules.** The classic proprietary driver does not support this GPU. This is not a preference.

Add NVIDIA's apt repository, then install:

```bash
codename=$(. /etc/os-release && echo "${VERSION_ID//./}")   # 2404 on 24.04
wget -O /tmp/cuda-keyring.deb \
  "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${codename}/x86_64/cuda-keyring_1.1-1_all.deb"
sudo dpkg -i /tmp/cuda-keyring.deb
sudo apt-get update

sudo apt-get install -y nvidia-open
```

If `nvidia-open` is unavailable, fall back to Ubuntu's own packaging, picking the newest **`-open`** variant:

```bash
apt-cache search --names-only '^nvidia-driver-[0-9]+-open$' | sort -V | tail -n1
sudo apt-get install -y nvidia-driver-580-open    # substitute whatever that printed
```

### 1.4 MOK enrollment

If Secure Boot is on, the install prompts you for a one-time password. **Set it to digits only — `12345678` is fine.** MOK Manager is a UEFI application with a hardcoded US keyboard map, so on a Swedish layout every symbol lands on a different key and a password with punctuation cannot be typed back correctly. It is discarded once the key is enrolled and protects nothing afterwards.

**Reboot, and watch for a blue "MOK Manager" screen.** It is not an error:

1. **Enroll MOK**
2. Continue
3. Yes
4. Enter the password you just set
5. Reboot

Miss it, or fail the password, and Secure Boot blocks the module and you get a slow software-rendered desktop. The screen will not come back on its own either — shim deletes the pending request so it does not block every boot. Re-arm it:

```bash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
mokutil --list-new | head     # confirm it is pending, then reboot
```

Full recovery path, including turning Secure Boot off instead, is in [troubleshooting.md](troubleshooting.md).

### 1.5 Verify

```bash
nvidia-smi
```

Expect the RTX 5070 Ti with driver 580 or newer.

---

## 2. Performance tuning

Four things matter here, in descending order of impact.

### 2.1 Memory lock limits — the one that actually breaks things

Strata `mlock`s a large share of the model so the kernel cannot page it out mid-generation. **Ubuntu's default `RLIMIT_MEMLOCK` is 8 MB** and Strata wants 25–30 GB, so without this it either fails outright or silently degrades to unpinned memory and pages during generation.

```bash
sudo tee /etc/security/limits.d/90-ai-memlock.conf >/dev/null <<'EOF'
# Raised for local AI inference. Strata and llama.cpp pin tens of gigabytes
# so the kernel cannot page model weights out during generation.
*    soft    memlock    unlimited
*    hard    memlock    unlimited
root soft    memlock    unlimited
root hard    memlock    unlimited
EOF
```

PAM limits do not apply to systemd user services, which need their own setting:

```bash
sudo mkdir -p /etc/systemd/user.conf.d
sudo tee /etc/systemd/user.conf.d/90-ai-memlock.conf >/dev/null <<'EOF'
[Manager]
DefaultLimitMEMLOCK=infinity
EOF
```

**Log out and back in**, then confirm:

```bash
ulimit -l      # should print: unlimited
```

This does not take effect in your current shell. If `ulimit -l` still shows a number after logging back in, nothing downstream will work properly.

### 2.2 Virtual memory

```bash
sudo tee /etc/sysctl.d/90-ai-tuning.conf >/dev/null <<'EOF'
# Local AI tuning.

# Ubuntu defaults to 60. With zram swap and a 25-30 GB pinned model, eager
# swapping evicts pages that are about to be needed again.
vm.swappiness = 10

# Strata memory-maps a ~68 GB file. Keep cached pages around longer.
vm.vfs_cache_pressure = 50

# Large models need many mappings; the default can be hit by mmap-heavy
# inference engines.
vm.max_map_count = 1048576
EOF

sudo sysctl --system
```

Verify:

```bash
cat /proc/sys/vm/swappiness /proc/sys/vm/max_map_count
```

### 2.3 CPU governor

The MoE experts that do not fit in VRAM run on the CPU, so clock behaviour matters more than on a typical desktop.

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
```

To set it:

```bash
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

That does not survive a reboot. To make it persistent:

```bash
sudo tee /etc/systemd/system/cpu-performance.service >/dev/null <<'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cpu-performance.service
```

A note on naming: with `amd-pstate` in active mode you only get `performance` and `powersave`, and `powersave` there is not what it sounds like — it still boosts. The difference is smaller than the names suggest.

### 2.4 NVIDIA persistence mode

Without it the driver unloads between processes, adding seconds of re-initialisation to every run.

```bash
sudo systemctl enable --now nvidia-persistenced
nvidia-smi --query-gpu=name,persistence_mode,memory.total --format=csv
```

If that unit does not exist on your install, `sudo nvidia-smi -pm 1` sets it for the current boot only.

### 2.5 A helper to free desktop VRAM

The desktop session holds 1–1.5 GB of VRAM. On a 16 GB card that is the difference between experts staying resident and spilling to system RAM.

```bash
sudo tee /usr/local/bin/ai-console-mode >/dev/null <<'EOF'
#!/usr/bin/env bash
# Drop to a text console to free the VRAM the desktop holds, or return to it.
#
#   ai-console-mode off   stop the graphical session (frees 1-1.5 GB VRAM)
#   ai-console-mode on    bring the desktop back
#   ai-console-mode       show current VRAM usage
set -euo pipefail

case "${1:-status}" in
    off)
        echo "Stopping the graphical session. Switch to a TTY with Ctrl+Alt+F3 if needed."
        sudo systemctl isolate multi-user.target
        ;;
    on)
        sudo systemctl isolate graphical.target
        ;;
    status)
        nvidia-smi --query-gpu=memory.used,memory.total --format=csv
        echo
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
        ;;
    *)
        echo "usage: $0 [on|off|status]" >&2
        exit 1
        ;;
esac
EOF

sudo chmod +x /usr/local/bin/ai-console-mode
```

Every AI service here is a loopback listener rather than a desktop app, so they keep running while the desktop is down, and stay reachable over SSH from another machine.

### 2.6 Directory layout and environment

```bash
mkdir -p "$AI_ROOT"/{strata,gguf,comfyui/models,comfyui/output,voice,hf-cache}

cat >> ~/.profile <<'EOF'

# ai-workstation-setup
export AI_ROOT="$HOME/ai"
export HF_HOME="$AI_ROOT/hf-cache"
export HUGGINGFACE_HUB_CACHE="$AI_ROOT/hf-cache/hub"
export PATH="$HOME/.local/bin:$PATH"
EOF
```

`HF_HOME` keeps tens of gigabytes of Hugging Face downloads out of `~/.cache`, where they are easy to lose track of.

---

## 3. Python and CUDA

### 3.1 Build prerequisites

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake ninja-build pkg-config \
    git curl wget ca-certificates \
    python3 python3-venv python3-pip python3-dev \
    libsndfile1 ffmpeg
```

`libsndfile1` and `ffmpeg` are for the voice server; the rest is the toolchain for building llama.cpp.

### 3.2 uv

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
uv --version
```

Optional but worth it — it is a much faster drop-in for `pip` and `venv`. Everything below works with plain `python3 -m venv` and `pip` too.

### 3.3 Verify PyTorch actually runs on this GPU

**Do this before building anything that depends on it.** Torch wheels below 2.7 — the cu124/cu126 era — ship no sm_120 kernels at all, and no amount of configuration fixes that. Anything built against such a pin has to be reinstalled from scratch.

```bash
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv
```

Compute capability should read `12.0`. Now build a throwaway venv and prove a real kernel executes:

```bash
probe=$(mktemp -d)
uv venv "$probe/venv" --python 3.12
uv pip install --python "$probe/venv/bin/python" torch --index-url https://download.pytorch.org/whl/cu128

"$probe/venv/bin/python" - <<'PY'
import torch
print("torch      ", torch.__version__)
print("cuda avail ", torch.cuda.is_available())
print("device     ", torch.cuda.get_device_name(0))
print("capability ", "sm_" + "".join(map(str, torch.cuda.get_device_capability(0))))

# Actually execute a kernel. is_available() can be True while no kernel image
# exists for this architecture.
x = torch.randn(4096, 4096, device="cuda")
y = x @ x
torch.cuda.synchronize()
print("matmul     ", tuple(y.shape), "on", y.device, "OK")
PY

rm -rf "$probe"
```

The matmul is the part that matters. `torch.cuda.is_available()` returns `True` on a machine with no usable kernels — you only find out when a real operation fails. If you see `CUDA error: no kernel image is available for execution on the device`, the wheel is too old: reinstall from the cu128 index, never cu124.

---

## 4. llama.cpp

This is the engine underneath most of the stack, and your general-purpose server on Linux.

### 4.1 CUDA toolkit

`nvcc` is needed to compile the CUDA backend. **Ubuntu's own `nvidia-cuda-toolkit` package is CUDA 12.0, which predates sm_120** — it has to come from NVIDIA's repository, which you added in step 1.3.

```bash
nvcc --version || sudo apt-get install -y cuda-toolkit
export PATH="/usr/local/cuda/bin:$PATH"
nvcc --version
```

You need CUDA 12.8 or newer.

### 4.2 Build

```bash
mkdir -p "$APPS"
git clone https://github.com/ggml-org/llama.cpp.git "$APPS/llama.cpp"

cmake -S "$APPS/llama.cpp" -B "$APPS/llama.cpp/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES=120 \
    -DLLAMA_CURL=ON

cmake --build "$APPS/llama.cpp/build" --config Release -j"$(nproc)"
```

`CMAKE_CUDA_ARCHITECTURES=120` targets Blackwell only, which keeps compile time down. Add more (`"86;120"`) only if you plan to move the binaries to another machine.

### 4.3 Put the tools on PATH

```bash
mkdir -p "$HOME/.local/bin"
for tool in llama-server llama-cli llama-bench llama-quantize; do
    ln -sf "$APPS/llama.cpp/build/bin/$tool" "$HOME/.local/bin/$tool"
done

llama-cli --version
```

### 4.4 Serve a model

```bash
llama-server \
    --model "$AI_ROOT/gguf/your-model.gguf" \
    --host 127.0.0.1 --port 8081 \
    --n-gpu-layers 999 \
    --ctx-size 8192 \
    --flash-attn
```

Port 8081 keeps clear of Strata (8080), LM Studio (1234) and ComfyUI (8188). `--n-gpu-layers 999` means "offload everything that fits".

Sizing rule on 16 GB of VRAM: at Q4_K_M a dense model needs roughly `parameters × 0.6 GB`, so stay at or below 14B to keep it fully resident with room for context.

---

## 5. ComfyUI

### 5.1 Install

Keep the application and its virtualenv under `$APPS`, and the models under `$AI_ROOT`, so that `git pull` never has to think about tens of gigabytes of weights.

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git "$APPS/ComfyUI"
cd "$APPS/ComfyUI"

uv venv .venv --python 3.12
uv pip install --python .venv/bin/python torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu128
uv pip install --python .venv/bin/python -r requirements.txt
```

The cu128 index again, for the same sm_120 reason as step 3.3.

### 5.2 Custom nodes

```bash
cd "$APPS/ComfyUI/custom_nodes"
git clone https://github.com/ltdrdata/ComfyUI-Manager.git
git clone https://github.com/city96/ComfyUI-GGUF.git
cd "$APPS/ComfyUI"
uv pip install --python .venv/bin/python -r custom_nodes/ComfyUI-Manager/requirements.txt
```

**Manager** browses and installs models from inside the UI, which saves guessing at repository names. **GGUF** is required for the quantised Wan 2.2 14B video weights.

### 5.3 Point it at the model directory

```bash
mkdir -p "$AI_ROOT"/comfyui/models/{checkpoints,diffusion_models,unet,text_encoders,vae,loras,clip_vision,upscale_models}
mkdir -p "$AI_ROOT/comfyui/output"

cat > "$APPS/ComfyUI/extra_model_paths.yaml" <<EOF
local:
    base_path: $AI_ROOT/comfyui/models
    checkpoints: checkpoints
    diffusion_models: diffusion_models
    unet: unet
    text_encoders: text_encoders
    clip: text_encoders
    vae: vae
    loras: loras
    clip_vision: clip_vision
    upscale_models: upscale_models
EOF
```

ComfyUI reads that file only at startup.

### 5.4 Run

```bash
cd "$APPS/ComfyUI"
./.venv/bin/python main.py --output-directory "$AI_ROOT/comfyui/output"
```

Open <http://127.0.0.1:8188>. **Never add `--listen`** — ComfyUI has no authentication and can execute code through the editor. Use an SSH tunnel for remote access:

```bash
ssh -L 8188:localhost:8188 user@workstation
```

Good first run: Templates → Image → Z-Image-Turbo: Text to Image.

---

## 6. Voice server

One process serving both halves of the voice stack on the endpoints the OpenAI client libraries already speak: faster-whisper `large-v3-turbo` for transcription, Kokoro-82M for speech. Kokoro runs fine on CPU, so speech never competes with the GPU.

`$kit` below is wherever you copied this folder — the one containing `README.md`.

```bash
kit=/media/$USER/USB/ai-workstation-setup
mkdir -p "$APPS/voice"
cp "$kit/voice/server.py" "$kit/voice/requirements.txt" "$APPS/voice/"
cd "$APPS/voice"

uv venv .venv --python 3.12
uv pip install --python .venv/bin/python torch --index-url https://download.pytorch.org/whl/cu128
uv pip install --python .venv/bin/python -r requirements.txt
```

`requirements.txt` deliberately omits `torch` so it can only ever come from the cu128 index above.

Run it:

```bash
./.venv/bin/python "$APPS/voice/server.py" --host 127.0.0.1 --port 8100
```

Models download on first request, not at startup, so the first call is slow and every later one is instant. Add `--whisper-device cpu` when Strata or ComfyUI holds the GPU.

### 6.1 Optional: run it as a service

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/voice-server.service <<EOF
[Unit]
Description=Local voice server (Whisper + Kokoro)
After=network.target

[Service]
Type=simple
ExecStart=$APPS/voice/.venv/bin/python $APPS/voice/server.py --host 127.0.0.1 --port 8100
Environment=HF_HOME=$AI_ROOT/hf-cache
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now voice-server
systemctl --user status voice-server
```

### 6.2 Check it

```bash
curl http://127.0.0.1:8100/health

curl -s http://127.0.0.1:8100/v1/audio/transcriptions \
     -F file=@recording.m4a -F response_format=json

curl -s http://127.0.0.1:8100/v1/audio/speech \
     -H 'Content-Type: application/json' \
     -d '{"input":"Workstation ready.","voice":"af_heart"}' \
     --output speech.wav
```

---

## 7. Strata

### 7.1 Check you can actually run it

```bash
free -g                                                              # RAM
nvidia-smi --query-gpu=memory.total --format=csv                     # VRAM, want >= 12 GB
df -h "$AI_ROOT"                                                     # want ~180 GB free
ulimit -l                                                            # must be 'unlimited'
```

If `ulimit -l` is not `unlimited`, go back to step 2.1 — this is the step people skip and then spend an evening debugging.

### 7.2 Which models fit

Strata serves three base models, and most of its long model list is one model at different precision. For Qwen3.8-Flash-Next the rule is simple: **RAM must hold the experts plus about 10 GB** for the OS. A bigger card does not change that, because the low-RAM mode that would help needs a 24 GB GPU.

| Pack | Experts | RAM needed | Download | On 32 GB |
|---|---:|---:|---:|---|
| Flash-Next **Coder** | 23 GB | ~33 GB | ~68 GB | yes, 55 tok/s |
| **Qwen3.6** UD-Q4_K_XL | — | plans 32 GB | 23 GB | yes |
| **Gyro-S** | — | 27.6 GB total | 59 GB | yes |
| **Gyro-M** | — | 35 GB total | 92 GB | tight |
| Flash-Next **Q2_0** | 34 GB | ~44 GB | ~70 GB | SSD-streamed, slow |
| Flash-Next **IQ2_XS** | 35.5 GB | ~45.5 GB | ~72 GB | SSD-streamed, slow |
| Flash-Next **IQ3_XXS** | 43 GB | ~53 GB | ~74 GB | no |
| Flash-Next **IQ3_S** | 50 GB | ~60 GB | ~76 GB | no |

Install the first three. Coder scores 91% of the full model on SWE-bench Verified and 99% on LiveCodeBench, but it keeps only the 256 experts per layer chosen on code and is weak on general and CJK text — that is what Qwen3.6-35B-A3B is for, and it is Apache 2.0 besides. Gyro-S is the only full-expert Flash-Next build that fits 32 GB.

Q2_0 and IQ2_XS will start and Strata will warn you; most experts then come from the NVMe on every token. That is 142 GB of download for a degraded experience, and both become first-class the day you fit 64 GB. Wait.

### 7.3 Free the VRAM the desktop is holding

```bash
nvidia-smi --query-gpu=memory.used --format=csv
ai-console-mode off      # if that showed more than ~800 MB
```

On a 16 GB card the 1–1.5 GB the desktop holds is the difference between more experts staying resident and spilling to system RAM.

### 7.4 Install

Install the terminal rather than cloning the repository. The CLI is what gives you model management — presets, `strata models list`, switching without reinstalling:

```bash
curl -fsSL --connect-timeout 15 --max-time 120 \
  https://github.com/Niko1221/Strata/releases/latest/download/install.sh -o install.sh
sh install.sh
```

Preview before downloading anything. `--plan` prints the size and the memory it expects to need:

```bash
strata launch --plan --family coder --model IQ1_M
```

Then install the three that fit, saving a preset for each so switching later is one command:

```bash
strata launch --family coder  --model IQ1_M      --yes --no-tui --save-preset coder
strata launch --stop

strata launch --family qwen36 --model UD-Q4_K_XL --yes --no-tui --save-preset qwen36
strata launch --stop

strata launch --family gyro   --model Gyro-S     --yes --no-tui --save-preset gyro-s
strata launch --stop
```

That is about 150 GB in total, less where the shared 29 GB n-gram table deduplicates. Downloads resume if interrupted and re-running skips what is already present.

Expect the machine to **freeze for one to three minutes** the first time a Flash-Next pack loads, while 35–55 GB is read into RAM and partly pinned for the GPU. That is normal. Do not close the window.

`ubuntu/07-strata.sh` does all of the above, and `--tier abc` or `--tier de` extends it to the tight and post-upgrade sets.

### 7.5 Switch between them

Only one model serves at a time. Installing several is a disk-space question, not a memory one.

```bash
strata models list               # what is installed
strata launch --list-presets     # saved configurations
strata launch --preset qwen36    # switch
strata launch --status           # what is serving now
strata launch --stop             # unload and free VRAM
```

Launching a second model while one serves asks to restart, or refuses under `--no-tui` until you add `--restart`. A different `--port` lets two run at once, but 16 GB of VRAM will not hold two large models.

### 7.6 Use it

```bash
curl http://127.0.0.1:8080/v1/models
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="local")
print(client.chat.completions.create(
    model="strata",
    messages=[{"role": "user", "content": "Hello"}],
).choices[0].message.content)
```

The same endpoint works from Pi, Cursor and LM Studio Bionic. It speaks both the OpenAI and Anthropic APIs.

Before you judge the speed: both Qwen models **think by default**, and Flash-Next's internal default is `xhigh`, its longest tier. Omitting `reasoning_effort` does not turn thinking off, so a model rated 55 tok/s can spend a long stretch generating reasoning you never see before the answer begins. Pass `reasoning_effort` as `none`, `low`, `medium` or `xhigh`, and note that thinking and instruct modes want different sampling parameters — details and the full catalogue in [strata-models.md](strata-models.md).

---

## 8. Models

With `HF_HOME` set from step 2.6:

```bash
uv tool install huggingface-hub
hf download <repo-id> <filename> --local-dir "$AI_ROOT/comfyui/models/<category>"
```

Which models, which quantisations and why: [../models/MANIFEST.md](../models/MANIFEST.md). `hf download` preserves repo-internal paths, so files from repos that use `split_files/` arrive nested — move them up into the right category directory afterwards.

If a repository 404s, it has probably been renamed; repacks move around constantly. Search rather than guessing:

```bash
hf search z_image_turbo
```

---

## 9. Remote access (optional)

Skip this unless you want to reach the models from a phone or another machine. Full reasoning and troubleshooting in [remote-access.md](remote-access.md); the short version:

```bash
# Private mesh VPN between your own devices
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh

# Phone-friendly chat UI. Port 3000 because 8080 is Strata.
uv venv ~/apps/open-webui/.venv --python 3.12
uv pip install --python ~/apps/open-webui/.venv/bin/python open-webui
export WEBUI_SECRET_KEY=$(openssl rand -hex 32)   # persist this
~/apps/open-webui/.venv/bin/open-webui serve --host 127.0.0.1 --port 3000

# Publish loopback services as tailnet-only HTTPS URLs
sudo tailscale serve --bg 3000               # Open WebUI on 443
sudo tailscale serve --bg --https=8443 8188  # ComfyUI
sudo tailscale serve --bg --https=8444 8080  # Strata
sudo tailscale serve --bg --https=8445 8081  # llama.cpp
sudo tailscale serve --bg --https=8446 8100  # voice
```

Nothing is rebound and no port is opened — `tailscale serve` listens on the Tailscale interface only. Install the Tailscale app on your phone, sign in with the same account, and `https://<host>.<tailnet>.ts.net` is your chat UI.

**Never run `tailscale funnel`** — that is the public internet, in front of a ComfyUI that can execute arbitrary code.

---

## What you should have

| Service | URL | Notes |
|---|---|---|
| Strata | `http://127.0.0.1:8080/v1` | OpenAI + Anthropic compatible |
| llama.cpp | `http://127.0.0.1:8081/v1` | OpenAI compatible |
| Voice | `http://127.0.0.1:8100/v1` | OpenAI audio endpoints |
| ComfyUI | `http://127.0.0.1:8188` | web UI, not an LLM API |

All loopback-only and **none has authentication** — never expose them to the network.

The standing constraint: 16 GB of VRAM means **one heavy workload at a time**. Strata and ComfyUI cannot share the GPU. Strata alone pins 25–60 GB of RAM depending on the pack, so nothing else heavy runs alongside it either.

If you are going on to build the server platform, continue with [manual-server.md](manual-server.md). Note that it takes about 15 GB of RAM permanently, which caps the resident Strata pack at IQ2_XS while it runs.

When something misbehaves, [troubleshooting.md](troubleshooting.md) is indexed by symptom.
