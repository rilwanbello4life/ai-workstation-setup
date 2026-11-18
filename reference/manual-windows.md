# Manual setup — Windows

Everything the Windows scripts do, as commands you run yourself, with the reasoning for each one. Follow this instead of `windows\*.ps1` if you would rather understand each change than trust a script.

Nothing here is destructive except where explicitly flagged. The order matters: the safety steps genuinely must come first.

Open **PowerShell as Administrator** unless a section says otherwise. Right-click Start, "Terminal (Admin)".

| Section | Replaces |
|---|---|
| [1. Safety baseline](#1-safety-baseline) | `01-preflight.ps1` |
| [2. Hardware inventory](#2-hardware-inventory) | `02-verify-hardware.ps1` |
| [3. Performance pass](#3-performance-pass) | `03-tune-windows.ps1` |
| [4. Base tooling](#4-base-tooling) | `04-install-base.ps1` |
| [5. AI stack](#5-ai-stack) | `05-install-ai-stack.ps1` |
| [6. Models](#6-models) | `models\download-models.ps1` |
| [7. Remote access](#7-remote-access-optional) | `06-remote-access.ps1` |

---

## 1. Safety baseline

### 1.1 Export the BitLocker recovery key

**Do this before anything else.** Windows 11 Home silently enables device encryption when you sign in with a Microsoft account. Changing the boot chain — which you will, by adding a second drive with its own EFI partition — can alter the TPM measurements BitLocker uses to unlock automatically, and drop you into a recovery prompt. Without the key at that point, the data is gone.

```powershell
manage-bde -status C:
manage-bde -protectors -get C:
```

In the second command's output, find the **Numerical Password** protector and its 48-digit key. Save both outputs somewhere:

```powershell
manage-bde -status C:            | Out-File $HOME\Desktop\bitlocker.txt
manage-bde -protectors -get C:   | Out-File $HOME\Desktop\bitlocker.txt -Append
```

Then **move that file off this machine** — phone photo, password manager, another PC, printed. A recovery key stored on the encrypted disk it unlocks is worthless.

Also check the online copy at <https://account.microsoft.com/devices/recoverykey>. If `manage-bde` reports no Numerical Password protector, encryption has not activated yet; come back and repeat this after it does.

### 1.2 Disable Fast Startup and hibernation

```powershell
powercfg /H off
```

Two reasons. Fast Startup means "shutdown" actually hibernates the kernel and leaves NTFS in a half-closed state, which confuses installers and bootloaders. And `hiberfil.sys` is sized to your RAM — about **32 GB** of a 1 TB drive you need for games.

Verify:

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HibernateEnabled
```

`HibernateEnabled` should be `0`. Reversible at any time with `powercfg /H on`.

### 1.3 Confirm the firmware state

```powershell
Confirm-SecureBootUEFI
Get-Disk | Where-Object IsSystem
Get-Partition | Where-Object GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
```

What you want to see:

- **Secure Boot `True`.** Leave it on. Ubuntu ships a signed shim, and the NVIDIA driver is handled by enrolling a MOK key at first reboot.
- **PartitionStyle `GPT`** on the system disk. Required for UEFI dual boot.
- **One EFI System Partition**, typically 100–300 MB. Note it exists; you will not touch it, because Ubuntu gets its own on the other drive.

### 1.4 Things only you can do

These need the BIOS or a browser, so no script can do them:

1. **Enable EXPO.** Reboot, press **Del**, go to Ai Tweaker > Memory Profile, select EXPO I. Without it your DDR5-6000 kit runs at JEDEC 4800 — roughly 25% of your memory bandwidth left unused. This matters twice: gaming frame rates, and Strata, whose CPU-resident experts are bandwidth-bound.
2. **Update the BIOS** to the current ASUS release for the TUF GAMING B850-PLUS WIFI.
3. **Install the NVIDIA driver from [nvidia.com](https://www.nvidia.com/download/index.aspx)**, not Windows Update. The Windows Update build lags and sometimes omits components.
4. **Move the BitLocker key off this PC** if you have not already.

---

## 2. Hardware inventory

Read-only. The point is to verify the assumptions the rest of the plan rests on, rather than discovering a surprise halfway through.

### 2.1 CPU and board

```powershell
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors
Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer, Product
Get-CimInstance Win32_BIOS      | Select-Object SMBIOSBIOSVersion, ReleaseDate
```

Expect a Ryzen 7 9800X3D, 8 physical / 16 logical cores, and a B850 board.

### 2.2 Memory — the upgrade decision hinges on this

```powershell
Get-CimInstance Win32_PhysicalMemory |
    Select-Object DeviceLocator, @{n='GB';e={[math]::Round($_.Capacity/1GB)}},
                  ConfiguredClockSpeed, Manufacturer, PartNumber
```

What to check depends on how many modules are fitted.

**As delivered — two modules:**

- **Seated in DIMM_A2 and DIMM_B2.** ASUS AM5 boards want the second slot of each channel when only two modules are fitted. Wrong slots cost real bandwidth.
- **ConfiguredClockSpeed 6000.** If it reads 4800, EXPO is off — go back to step 1.4.

**After phase 11 — two modules, the swap configuration:**

- **64 GB across two slots** at **ConfiguredClockSpeed 6000**, the 2×32 GB kit alone in DIMM_A2 and DIMM_B2.

**After phase 11 — four modules, the add configuration:**

- **96 GB total**, with the 32 GB modules in DIMM_A2 and DIMM_B2 and the factory 16 GB pair in DIMM_A1 and DIMM_B1. Mixed capacities are expected; what matters is that each channel holds the same mixture.
- **ConfiguredClockSpeed around 3600**, and that is correct, not a fault. AMD rates the 9800X3D at DDR5-5600 with two modules but only **DDR5-3600 with four**. The script accepts anything at or above 3400 in this configuration and will not nag you about 6000.

The four-module route trades roughly a fifth of delivered memory bandwidth for the capacity that lets the server platform and a large model coexist comfortably. Strata computes cold experts on the CPU, so generation will be slower than published figures. If it fails to POST, the recovery ladder is in [ram-upgrade-decision.md](ram-upgrade-decision.md) — and the last rung of it, pulling the 16 GB pair, leaves you on the two-module configuration above rather than stranded.

### 2.3 GPU

```powershell
Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, DriverDate
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv
```

Expect an RTX 5070 Ti, 16 GB, compute capability **12.0** (sm_120).

Note that `Win32_VideoController`'s `AdapterRAM` field is a signed 32-bit integer and wraps above 4 GB, so ignore it and trust `nvidia-smi`. If you want the real figure from the registry:

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\*' |
    Where-Object DriverDesc -match '5070' |
    Select-Object DriverDesc, @{n='VRAM_GB';e={[math]::Round($_.'HardwareInformation.qwMemorySize'/1GB)}}
```

Two consequences of sm_120 that bite later: on Linux this card **requires** the open kernel modules (`nvidia-open`), and PyTorch must come from the **cu128** index or newer, because cu124 wheels contain no sm_120 kernels at all.

### 2.4 Storage

```powershell
Get-Disk | Sort-Object Number | Format-Table Number, FriendlyName, @{n='GB';e={[math]::Round($_.Size/1GB)}}, PartitionStyle, IsSystem
Get-PhysicalDisk | Where-Object BusType -eq 'NVMe'
```

Before fitting the second drive you will see one NVMe. Afterwards, two. The board has three M.2 slots but **never use M.2_3** — it shares bandwidth with the second PCIe x16 slot and disables it. Full slot details in [partition-layout.md](partition-layout.md).

---

## 3. Performance pass

Each of these measurably affects frame rates or model throughput. None is required for correctness.

### 3.1 Resizable BAR

One of the few free frame-rate wins on RTX 50 series cards. Check it:

```powershell
nvidia-smi -q | Select-String "Resizable BAR" -Context 0,3
```

If that reports nothing useful on your driver, look in **NVIDIA Control Panel > Help > System Information** for the "Resizable BAR" line instead. If it says No, enable both of these in BIOS:

```
Advanced > PCI Subsystem Settings > Above 4G Decoding    -> Enabled
Advanced > PCI Subsystem Settings > Re-Size BAR Support  -> Enabled
```

### 3.2 Hardware-Accelerated GPU Scheduling

Lowers latency and is a prerequisite for some NVIDIA features.

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode
```

`2` means on. To enable:

```powershell
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -Value 2 -Type DWord
```

Reboot required. The GUI equivalent is Settings > System > Display > Graphics > Change default graphics settings.

### 3.3 Memory Integrity (HVCI) — your judgement call

Virtualisation-based security costs a few percent of CPU-bound frame rate, which is exactly the regime an X3D chip plays in. Turning it off is a **real security trade-off**: it is what protects you against malicious or vulnerable kernel drivers.

Check:

```powershell
Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard |
    Select-Object SecurityServicesRunning, VirtualizationBasedSecurityStatus
```

`SecurityServicesRunning` containing `2` means HVCI is active. To disable:

```powershell
$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
New-Item -Path $k -Force | Out-Null
Set-ItemProperty -Path $k -Name Enabled -Value 0 -Type DWord
```

Reboot required. The GUI equivalent is Windows Security > Device security > Core isolation. Leaving it on is a perfectly defensible choice.

### 3.4 Power plan — stay on Balanced

```powershell
powercfg /getactivescheme
```

**Balanced is correct here, and High Performance is actively worse.** AMD's chipset driver installs PPM provisioning that teaches Windows how to park cores on X3D parts, keeping game threads on the cache-heavy CCD. High Performance defeats that parking. If you are not on Balanced:

```powershell
powercfg /setactive SCHEME_BALANCED
```

Confirm the chipset driver is actually present:

```powershell
Get-PnpDevice | Where-Object FriendlyName -match 'AMD.*(PPM|Provisioning|PSP|GPIO)'
```

If nothing comes back, download the AM5 / B850 chipset driver from amd.com. Without it Windows parks cores wrongly on the 9800X3D.

### 3.5 Disk budget

```powershell
Get-Volume -DriveLetter C | Select-Object @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB)}}, @{n='TotalGB';e={[math]::Round($_.Size/1GB)}}
```

The full AI stack is about **199 GB**:

| Component | Size |
|---|---|
| Strata: Flash-Next Coder | 68 GB |
| Strata: Qwen3.6 UD-Q4_K_XL | 23 GB |
| ComfyUI image models | 20 GB |
| ComfyUI video models | 55 GB |
| GGUF chat models | 30 GB |
| Voice models | 3 GB |

Windows and applications take roughly 80 GB, so expect around **650 GB left for games** — four to six modern titles. If less than ~150 GB would remain, skip the ComfyUI video models on this side: 55 GB back, and Wan 2.2 is the slowest thing a 16 GB card runs anyway. Ubuntu will have them.

Strata is the line to watch. It serves one model at a time, so how many you install is a disk decision, and each additional pack is 23–92 GB. Two is the right number for this drive — Coder for code, Qwen3.6 for everything else. The rest of the catalogue belongs on Ubuntu's 2 TB, which is budgeted to hold all of it; see [strata-models.md](strata-models.md).

---

## 4. Base tooling

All via `winget`. If `winget` is missing, install "App Installer" from the Microsoft Store.

```powershell
winget install --id Git.Git                      --exact --silent --accept-package-agreements --accept-source-agreements
winget install --id Python.Python.3.12           --exact --silent --accept-package-agreements --accept-source-agreements
winget install --id astral-sh.uv                 --exact --silent --accept-package-agreements --accept-source-agreements
winget install --id OpenJS.NodeJS.LTS            --exact --silent --accept-package-agreements --accept-source-agreements
winget install --id 7zip.7zip                    --exact --silent --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.PowerShell         --exact --silent --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.VCRedist.2015+.x64 --exact --silent --accept-package-agreements --accept-source-agreements
```

Why each one: **Git** clones Strata and ComfyUI. **Python 3.12** is what ComfyUI and the voice server run on. **uv** is a much faster drop-in for `pip`/`venv`. **Node LTS** is required by Pi, which needs **22.19 or newer** specifically. **VC++ Redistributable** is a dependency of several native Python wheels.

Optional diagnostics, genuinely useful on a new build:

```powershell
winget install --id CPUID.CPU-Z                     --exact --silent --accept-package-agreements --accept-source-agreements
winget install --id CrystalDewWorld.CrystalDiskInfo --exact --silent --accept-package-agreements --accept-source-agreements
winget install --id REALiX.HWiNFO                   --exact --silent --accept-package-agreements --accept-source-agreements
```

**Open a new terminal** so `PATH` refreshes, then verify:

```powershell
git --version
python --version
node --version      # must be 22.19 or newer
uv --version
nvidia-smi
```

---

## 5. AI stack

### 5.1 Create the layout and set HF_HOME

```powershell
$AiRoot = 'C:\AI'
'strata','gguf','comfyui\models','comfyui\output','voice','hf-cache' | ForEach-Object {
    New-Item -ItemType Directory -Path (Join-Path $AiRoot $_) -Force | Out-Null
}

[Environment]::SetEnvironmentVariable('AI_ROOT', $AiRoot, 'Machine')
[Environment]::SetEnvironmentVariable('HF_HOME', "$AiRoot\hf-cache", 'Machine')
[Environment]::SetEnvironmentVariable('HUGGINGFACE_HUB_CACHE', "$AiRoot\hf-cache\hub", 'Machine')
```

Every tool in the stack honours `HF_HOME`. Setting it once keeps tens of gigabytes of Hugging Face downloads out of `C:\Users\<you>\.cache`, where they are easy to lose track of. Open a new terminal afterwards for the variables to exist.

### 5.2 Strata

Strata specialises in large sparse mixture-of-experts models. Hot experts stay in VRAM, the rest sit in system RAM, and the remainder streams off the SSD. That layout is the whole reason a 125B model runs on a 16 GB card, and it is why comparing it to Ollama misses the point — Ollama splits by layer, which does not suit sparse MoE.

Install the terminal rather than cloning the repository. The CLI is what gives you model management — presets, `strata models list`, switching without reinstalling:

```powershell
irm -TimeoutSec 120 https://github.com/Niko1221/Strata/releases/latest/download/install.ps1 | iex
```

Two models fit 32 GB and earn their space on a drive shared with games:

```powershell
# Flash-Next Coder - the coding instrument. ~68 GB, 55 tok/s.
strata launch --family coder --model IQ1_M --yes --no-tui --save-preset coder
strata launch --stop

# Qwen3.6-35B-A3B - general purpose, Apache 2.0. ~23 GB.
strata launch --family qwen36 --model UD-Q4_K_XL --yes --no-tui --save-preset qwen36
strata launch --stop
```

Both are needed. Coder keeps only the 256 experts per layer chosen on code and is deliberately weak outside it — non-code text and CJK especially — so Qwen3.6 covers everything else.

Preview anything before committing to the download:

```powershell
strata launch --plan --family gyro --model Gyro-S
```

Downloads resume if interrupted. On first start the PC may **freeze for one to three minutes** while 35–55 GB is read into RAM and partly pinned for the GPU. That is expected; do not close the window.

When it is up: the app is at <http://127.0.0.1:8080> and the OpenAI- and Anthropic-compatible API at `http://127.0.0.1:8080/v1`.

```powershell
curl http://127.0.0.1:8080/v1/models

strata launch --list-presets     # saved configurations
strata launch --preset coder     # switch - one serves at a time
strata launch --stop             # free the VRAM
```

The rest of the catalogue — Gyro, Swift, the ISTA-DASLab sizes, and what each memory tier unlocks — is in [strata-models.md](strata-models.md). Windows has the smaller drive, so collect models on Ubuntu.

One thing worth knowing before you judge the speed: both Qwen models **think by default**, and Flash-Next's internal default is `xhigh`, its longest tier. Omitting `reasoning_effort` does not turn thinking off, so a model rated 55 tok/s can spend a while on reasoning you never see before the answer starts. Pass `reasoning_effort` as `none`, `low`, `medium` or `xhigh` to control it.

### 5.3 LM Studio Bionic

```powershell
winget install --id ElementLabs.LMStudio --exact --silent --accept-package-agreements --accept-source-agreements
```

If winget does not have it, download from <https://lmstudio.ai/download>.

After first launch, in settings set the **models directory to `C:\AI\gguf`** so GGUF files land with the rest of the stack.

LM Studio's runtime is your general-purpose engine on Windows — the role llama.cpp plays on Linux. Run **one** general engine, not several; they are redundant with each other. Strata is the exception: it is not a substitute for a general engine and no general engine substitutes for it, so run both.

Bionic can also talk to Strata. Add a custom OpenAI-compatible endpoint pointing at `http://127.0.0.1:8080/v1` and you can switch between a fast VRAM-resident small model and the 125B MoE inside one conversation.

### 5.4 Pi

Check Node first — Pi needs 22.19 or newer:

```powershell
node --version
```

Then:

```powershell
Invoke-RestMethod https://pi.dev/install.ps1 | Invoke-Expression
```

Point it at your local endpoints by creating `~\.pi\agent\models.json`:

```json
{
  "providers": {
    "strata": {
      "type": "openai",
      "baseUrl": "http://127.0.0.1:8080/v1",
      "apiKey": "local",
      "models": [{ "id": "strata", "name": "Strata (whichever pack is loaded)" }]
    },
    "lmstudio": {
      "type": "openai",
      "baseUrl": "http://127.0.0.1:1234/v1",
      "apiKey": "local",
      "models": [{ "id": "local", "name": "LM Studio GGUF" }]
    }
  }
}
```

Run `pi` in a project folder and switch models mid-session with `/model`.

### 5.5 ComfyUI

```powershell
git clone https://github.com/comfyanonymous/ComfyUI.git C:\AI\comfyui\ComfyUI
cd C:\AI\comfyui\ComfyUI

uv venv .venv --python 3.12
# or, without uv:  python -m venv .venv

.\.venv\Scripts\python.exe -m pip install --upgrade pip
```

PyTorch **must** come from the cu128 index. This is the single most common way to break a Blackwell setup:

```powershell
.\.venv\Scripts\python.exe -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Two custom nodes are worth having — Manager for browsing and installing models, GGUF for the quantised Wan 2.2 video weights:

```powershell
git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes\ComfyUI-Manager
git clone https://github.com/city96/ComfyUI-GGUF.git     custom_nodes\ComfyUI-GGUF
.\.venv\Scripts\python.exe -m pip install -r custom_nodes\ComfyUI-Manager\requirements.txt
```

Keep models outside the checkout so `git pull` never has to think about tens of gigabytes of weights. Create `C:\AI\comfyui\ComfyUI\extra_model_paths.yaml`:

```yaml
local:
    base_path: C:/AI/comfyui/models
    checkpoints: checkpoints
    diffusion_models: diffusion_models
    unet: unet
    text_encoders: text_encoders
    clip: text_encoders
    vae: vae
    loras: loras
    clip_vision: clip_vision
    upscale_models: upscale_models
```

And the directories it refers to:

```powershell
'checkpoints','diffusion_models','unet','text_encoders','vae','loras','clip_vision','upscale_models' |
    ForEach-Object { New-Item -ItemType Directory -Path "C:\AI\comfyui\models\$_" -Force | Out-Null }
```

Start it:

```powershell
cd C:\AI\comfyui\ComfyUI
.\.venv\Scripts\python.exe main.py --output-directory C:\AI\comfyui\output
```

Then open <http://127.0.0.1:8188>. **Never add `--listen`** — ComfyUI has no authentication and can execute code through the editor. For remote access use an SSH tunnel.

### 5.6 Voice server

One process serving both halves of the voice stack on the endpoints the OpenAI client libraries already speak: faster-whisper `large-v3-turbo` for transcription, Kokoro-82M for speech. Kokoro runs happily on CPU, so speech never competes with the GPU.

`$kit` below is wherever you copied this folder — the one containing `README.md`.

```powershell
$kit = 'D:\ai-workstation-setup'
Copy-Item "$kit\voice\server.py","$kit\voice\requirements.txt" C:\AI\voice
cd C:\AI\voice

uv venv .venv --python 3.12
.\.venv\Scripts\python.exe -m pip install torch --index-url https://download.pytorch.org/whl/cu128
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

`requirements.txt` deliberately leaves `torch` out, so that it can only ever come from the cu128 index above.

Run it:

```powershell
.\.venv\Scripts\python.exe C:\AI\voice\server.py --host 127.0.0.1 --port 8100
```

Models load lazily on first request, so the first call is slow and every later one is instant. Add `--whisper-device cpu` when the GPU is busy with Strata or ComfyUI.

```powershell
curl http://127.0.0.1:8100/health
```

See [../voice/README.md](../voice/README.md) for the full endpoint reference.

---

## 6. Models

With `HF_HOME` set from step 5.1, use the Hugging Face CLI directly:

```powershell
uv tool install huggingface-hub
hf download <repo-id> <filename> --local-dir C:\AI\comfyui\models\<category>
```

Which models, which quantisations and why: [../models/MANIFEST.md](../models/MANIFEST.md). Note that `hf download` preserves repo-internal paths, so files from repos using `split_files/` land nested — move them up into the right `models\<category>\` directory afterwards.

Pick your everyday chat model through LM Studio's built-in browser rather than by hand; it only lists GGUFs verified against the current runtime.

---

## 7. Remote access (optional)

Skip this unless you want to reach the models from a phone or another machine. Full reasoning and troubleshooting in [remote-access.md](remote-access.md); the short version:

```powershell
# Private mesh VPN between your own devices
winget install --id tailscale.tailscale --exact
tailscale up

# Tailscale SSH is Linux/macOS only, so use the built-in OpenSSH server,
# firewalled to the Tailscale range.
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic; Start-Service sshd
New-NetFirewallRule -Name 'sshd-tailscale' -DisplayName 'OpenSSH (Tailscale only)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
    -LocalPort 22 -RemoteAddress '100.64.0.0/10'

# Phone-friendly chat UI. Port 3000 because 8080 is Strata.
uv venv C:\AI\open-webui\.venv --python 3.12
C:\AI\open-webui\.venv\Scripts\python.exe -m pip install open-webui
C:\AI\open-webui\.venv\Scripts\open-webui.exe serve --host 127.0.0.1 --port 3000

# Publish loopback services as tailnet-only HTTPS URLs
tailscale serve --bg 3000
tailscale serve --bg --https=8443 8188   # ComfyUI
tailscale serve --bg --https=8444 8080   # Strata
tailscale serve --bg --https=8445 1234   # LM Studio
tailscale serve --bg --https=8446 8100   # voice
```

Nothing is rebound and no router port is opened — `tailscale serve` listens on the Tailscale interface only. Set `WEBUI_SECRET_KEY` from a file so restarts do not log everyone out.

**Never run `tailscale funnel`** — that is the public internet, in front of a ComfyUI that can execute arbitrary code.

---

## What you should have

| Service | URL | Notes |
|---|---|---|
| Strata | `http://127.0.0.1:8080/v1` | OpenAI + Anthropic compatible |
| LM Studio | `http://127.0.0.1:1234/v1` | OpenAI compatible |
| Voice | `http://127.0.0.1:8100/v1` | OpenAI audio endpoints |
| ComfyUI | `http://127.0.0.1:8188` | web UI, not an LLM API |

All loopback-only and **none has authentication** — never expose them to the network.

The standing constraint on this hardware: 16 GB of VRAM means **one heavy workload at a time**. Stop Strata before running ComfyUI video generation, and vice versa. Strata alone pins 25–40 GB of your 64 GB depending on the pack, so you cannot game while it runs either.

Next: [ubuntu-install-walkthrough.md](ubuntu-install-walkthrough.md), then [manual-ubuntu.md](manual-ubuntu.md).
