<#
.SYNOPSIS
    Phase 6 - Install the AI stack on Windows: Strata, LM Studio Bionic, Pi
    and ComfyUI, all under C:\AI.

.DESCRIPTION
    This is the Windows half of two fully independent systems. It shares
    nothing with the Ubuntu install on the other drive, so every model is
    downloaded locally and every path is on C:.

    Run the whole thing, or a single component with -Only.

    Components:
      Strata   Runner for large mixture-of-experts models. Installs the two
               that earn their space on a drive shared with games: Flash-Next
               Coder for code, and Qwen3.6-35B-A3B for everything else.
               Switch between them with "strata launch --preset".
      LMStudio GUI agent app (Bionic) over the LM Studio runtime.
      Pi       Minimal terminal coding agent. Needs Node >= 22.19.
      ComfyUI  Image and video generation.
      Voice    Whisper transcription + Kokoro speech on an OpenAI-compatible
               endpoint, installed from ..\voice\.

    Disk note: the full stack is ~199 GB. On a 1 TB drive shared with games,
    run 03-tune-windows.ps1 first - it reports the budget and tells you what
    to leave out. The rest of the Strata catalogue lives on Ubuntu's 2 TB
    drive; see reference\strata-models.md.

.EXAMPLE
    .\05-install-ai-stack.ps1
    .\05-install-ai-stack.ps1 -Only ComfyUI
    .\05-install-ai-stack.ps1 -AiRoot E:\AI
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Strata', 'LMStudio', 'Pi', 'ComfyUI', 'Voice')]
    [string]$Only = 'All',

    [string]$AiRoot = $(if ($env:AI_ROOT) { $env:AI_ROOT } else { 'C:\AI' })
)

$ErrorActionPreference = 'Continue'

function Write-Section($Text) {
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}
function Write-Ok($Text)   { Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Warn($Text) { Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-Info($Text) { Write-Host "  [info] $Text" }
function Write-Todo($Text) { Write-Host "  [TODO] $Text" -ForegroundColor Magenta }

function Should-Run([string]$Component) {
    return ($Only -eq 'All' -or $Only -eq $Component)
}

# Create the local AI root and its layout. Mirrors ~/ai on the Ubuntu side so
# the two systems are navigable the same way, despite sharing nothing.
foreach ($d in @('strata', 'gguf', 'comfyui\models', 'comfyui\output', 'voice', 'hf-cache')) {
    New-Item -ItemType Directory -Path (Join-Path $AiRoot $d) -Force | Out-Null
}
Write-Info "Using AI root: $AiRoot"

# Every tool in the stack honours HF_HOME, so one variable keeps Hugging Face
# downloads out of the default C:\Users\<you>\.cache location.
[Environment]::SetEnvironmentVariable('AI_ROOT', $AiRoot, 'Machine')
[Environment]::SetEnvironmentVariable('HF_HOME', (Join-Path $AiRoot 'hf-cache'), 'Machine')
[Environment]::SetEnvironmentVariable('HUGGINGFACE_HUB_CACHE', (Join-Path $AiRoot 'hf-cache\hub'), 'Machine')
Write-Ok 'Set AI_ROOT, HF_HOME and HUGGINGFACE_HUB_CACHE (machine scope).'

$freeGb = [math]::Round((Get-Volume -DriveLetter $AiRoot[0]).SizeRemaining / 1GB)
if ($freeGb -lt 230) {
    Write-Warn "Only $freeGb GB free on $($AiRoot[0]): - the full stack wants ~199 GB."
    Write-Warn 'Consider skipping the ComfyUI video models here and using Ubuntu for video.'
}

$strataDir  = Join-Path $AiRoot 'strata'
$comfyDir   = Join-Path $AiRoot 'comfyui'
$comfyApp   = Join-Path $comfyDir 'ComfyUI'
$comfyModels = Join-Path $comfyDir 'models'

# ===========================================================================
if (Should-Run 'Strata') {
    Write-Section 'Strata'

    # Strata serves three base models; most of its long model list is one
    # model at different precision. The terminal CLI is what gives model
    # management - strata launch, presets, strata models list - so it is the
    # install route here rather than the source checkout.
    if (Get-Command strata -ErrorAction SilentlyContinue) {
        Write-Ok 'Strata terminal already installed.'
    } else {
        Write-Info 'Installing the Strata terminal.'
        try {
            Invoke-RestMethod -TimeoutSec 120 `
                https://github.com/Niko1221/Strata/releases/latest/download/install.ps1 |
                Invoke-Expression
            Write-Ok 'Installed.'
        } catch {
            Write-Warn "Install failed: $($_.Exception.Message)"
            Write-Warn 'Check network access to github.com, then re-run with -Only Strata.'
        }
    }

    # Windows shares this 1 TB drive with games, so it gets the two models
    # that earn their space rather than the whole tier. Ubuntu has the 2 TB
    # drive and the wider selection - see reference/strata-models.md.
    $strataModels = @(
        @{ Family = 'coder';  Model = 'IQ1_M';      Gb = 68
           Desc = 'Flash-Next Coder - coding instrument, 55 tok/s' }
        @{ Family = 'qwen36'; Model = 'UD-Q4_K_XL'; Gb = 23
           Desc = 'Qwen3.6-35B-A3B - general purpose, Apache 2.0' }
    )
    $strataGb = ($strataModels | Measure-Object -Property Gb -Sum).Sum

    Write-Host ''
    Write-Info "Models for this machine (~$strataGb GB total):"
    foreach ($m in $strataModels) {
        Write-Host ("    {0,-8} {1,-12} {2,4} GB  {3}" -f `
            $m.Family, $m.Model, $m.Gb, $m.Desc) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Info 'Coder is deliberately weak outside code and in non-English, so'
    Write-Info 'Qwen3.6 is there for everything else. Both fit 32 GB of RAM.'
    Write-Host ''

    if (Get-Command strata -ErrorAction SilentlyContinue) {
        Write-Warn 'First start freezes the PC for 1-3 minutes while 35-55 GB is'
        Write-Warn 'read into RAM and pinned for the GPU. This is normal - wait.'
        Write-Warn 'Downloads resume if interrupted; re-running skips what is present.'
        Write-Host ''

        foreach ($m in $strataModels) {
            $preset = "$($m.Family)-$($m.Model)".ToLower()
            Write-Info "Installing $($m.Family)/$($m.Model) (~$($m.Gb) GB)..."

            # --no-tui serves and returns instead of opening the monitor;
            # --save-preset makes switching to it a one-liner afterwards.
            strata launch --family $m.Family --model $m.Model `
                          --yes --no-tui --save-preset $preset
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "$($m.Family)/$($m.Model) installed."
                strata launch --stop 2>&1 | Out-Null
            } else {
                Write-Warn "$($m.Family)/$($m.Model) failed. Retry on its own:"
                Write-Host "           strata launch --family $($m.Family) --model $($m.Model)" -ForegroundColor Gray
            }
        }

        Write-Host ''
        Write-Info 'Switching between them (one serves at a time):'
        Write-Host '           strata launch --list-presets' -ForegroundColor Gray
        Write-Host '           strata launch --preset coder-iq1_m' -ForegroundColor Gray
        Write-Host '           strata launch --stop' -ForegroundColor Gray
        Write-Host ''
        Write-Info 'API: http://127.0.0.1:8080/v1  (OpenAI and Anthropic compatible)'
        Write-Host ''
        Write-Info 'Preview any other model without downloading it:'
        Write-Host '           strata launch --plan --family gyro --model Gyro-S' -ForegroundColor Gray
        Write-Info 'Full catalogue and what each memory tier adds:'
        Write-Host '           reference\strata-models.md' -ForegroundColor Gray
    }
}

# ===========================================================================
if (Should-Run 'LMStudio') {
    Write-Section 'LM Studio (Bionic)'

    $found = winget search --id ElementLabs.LMStudio --exact --accept-source-agreements 2>&1 | Out-String
    if ($found -match 'ElementLabs.LMStudio') {
        winget install --id ElementLabs.LMStudio --exact --silent `
            --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { Write-Ok 'LM Studio installed.' }
        else { Write-Warn "winget returned $LASTEXITCODE - install manually from https://lmstudio.ai/download" }
    } else {
        Write-Warn 'Package not found in winget.'
        Write-Todo 'Download the installer from https://lmstudio.ai/download'
    }

    Write-Host ''
    Write-Info 'After first launch, in LM Studio settings:'
    Write-Info "  Models directory -> $(Join-Path $AiRoot 'gguf')"
    Write-Info '  This keeps GGUF files alongside the rest of the stack.'
    Write-Host ''
    Write-Info 'Bionic can also talk to Strata. Add a custom OpenAI-compatible'
    Write-Info 'endpoint pointing at http://127.0.0.1:8080/v1 so you can switch'
    Write-Info 'between a fast small local model and the 125B MoE mid-conversation.'
}

# ===========================================================================
if (Should-Run 'Pi') {
    Write-Section 'Pi coding agent'

    $nodeOk = $false
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $nodeVersion = (node --version) -replace '^v', ''
        $parts = $nodeVersion.Split('.')
        $major = [int]$parts[0]
        $minor = [int]$parts[1]
        # Pi requires Node 22.19 or newer.
        $nodeOk = ($major -gt 22) -or ($major -eq 22 -and $minor -ge 19)
        if ($nodeOk) { Write-Ok "Node $nodeVersion meets the >= 22.19 requirement." }
        else         { Write-Warn "Node $nodeVersion is too old. Pi needs 22.19+." }
    } else {
        Write-Warn 'Node not found. Run 04-install-base.ps1 first.'
    }

    if ($nodeOk) {
        Invoke-RestMethod https://pi.dev/install.ps1 | Invoke-Expression
        if (Get-Command pi -ErrorAction SilentlyContinue) {
            Write-Ok 'Pi installed.'
        } else {
            Write-Warn 'Pi not on PATH yet - open a new terminal and check `pi --version`.'
        }
    }

    Write-Host ''
    Write-Info 'Point Pi at Strata by adding this to ~\.pi\agent\models.json:'
    Write-Host @'
    {
      "providers": {
        "strata": {
          "type": "openai",
          "baseUrl": "http://127.0.0.1:8080/v1",
          "apiKey": "local",
          "models": [{ "id": "strata", "name": "Strata (whichever pack is loaded)" }]
        }
      }
    }
'@ -ForegroundColor Gray
    Write-Info 'Then run `pi` in a project folder and pick the model with /model.'
}

# ===========================================================================
if (Should-Run 'ComfyUI') {
    Write-Section 'ComfyUI'

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warn 'Git not found. Run 04-install-base.ps1 first.'
    } else {
        New-Item -ItemType Directory -Path $comfyDir -Force | Out-Null

        if (Test-Path (Join-Path $comfyApp '.git')) {
            Write-Info 'ComfyUI already cloned, pulling latest.'
            git -C $comfyApp pull --ff-only
        } else {
            git clone https://github.com/comfyanonymous/ComfyUI.git $comfyApp
        }

        $venv = Join-Path $comfyApp '.venv'
        $py   = Join-Path $venv 'Scripts\python.exe'

        if (-not (Test-Path $py)) {
            Write-Info 'Creating virtual environment.'
            if (Get-Command uv -ErrorAction SilentlyContinue) {
                uv venv $venv --python 3.12
            } else {
                python -m venv $venv
            }
        }

        if (Test-Path $py) {
            Write-Info 'Installing PyTorch (cu128 - required for Blackwell sm_120).'
            & $py -m pip install --upgrade pip --quiet
            & $py -m pip install torch torchvision torchaudio `
                --index-url https://download.pytorch.org/whl/cu128

            Write-Info 'Installing ComfyUI requirements.'
            & $py -m pip install -r (Join-Path $comfyApp 'requirements.txt')

            # Custom nodes: Manager for model browsing, GGUF for quantised
            # Wan 2.2 video weights.
            $customNodes = Join-Path $comfyApp 'custom_nodes'
            New-Item -ItemType Directory -Path $customNodes -Force | Out-Null

            $nodes = @{
                'ComfyUI-Manager' = 'https://github.com/ltdrdata/ComfyUI-Manager.git'
                'ComfyUI-GGUF'    = 'https://github.com/city96/ComfyUI-GGUF.git'
            }
            foreach ($n in $nodes.GetEnumerator()) {
                $target = Join-Path $customNodes $n.Key
                if (Test-Path (Join-Path $target '.git')) {
                    Write-Info "$($n.Key) already present."
                } else {
                    git clone $n.Value $target
                    $req = Join-Path $target 'requirements.txt'
                    if (Test-Path $req) { & $py -m pip install -r $req }
                    Write-Ok "$($n.Key) installed."
                }
            }

            # Keep models outside the ComfyUI checkout so git updates never
            # touch tens of gigabytes of weights.
            foreach ($sub in @('checkpoints','diffusion_models','text_encoders','vae','loras','clip_vision','upscale_models','unet')) {
                New-Item -ItemType Directory -Path (Join-Path $comfyModels $sub) -Force | Out-Null
            }

            $yamlPath = Join-Path $comfyApp 'extra_model_paths.yaml'
            $base = $comfyModels -replace '\\', '/'
            @"
# Generated by ai-workstation-setup.
# Keeps models outside the ComfyUI checkout so git updates never touch them.
local:
    base_path: $base
    checkpoints: checkpoints
    diffusion_models: diffusion_models
    unet: unet
    text_encoders: text_encoders
    clip: text_encoders
    vae: vae
    loras: loras
    clip_vision: clip_vision
    upscale_models: upscale_models
"@ | Set-Content -Path $yamlPath -Encoding UTF8
            Write-Ok "Wrote $yamlPath"

            # Convenience launcher.
            $launcher = Join-Path $comfyDir 'start-comfyui.ps1'
            @"
# Launches ComfyUI on loopback only. Do not add --listen: ComfyUI has no
# authentication and can execute code through the editor.
Set-Location '$comfyApp'
& '$py' main.py --output-directory '$(Join-Path $comfyDir 'output')'
"@ | Set-Content -Path $launcher -Encoding UTF8
            Write-Ok "Wrote launcher: $launcher"

            Write-Host ''
            Write-Info 'Start ComfyUI with that launcher, then open http://127.0.0.1:8188'
            Write-Todo "Download models next - see models\MANIFEST.md"
        } else {
            Write-Warn 'Virtual environment creation failed; skipping ComfyUI dependencies.'
        }
    }
}

# ===========================================================================
if (Should-Run 'Voice') {
    Write-Section 'Voice server (Whisper + Kokoro)'

    $kitRoot  = Split-Path -Parent $PSScriptRoot
    $voiceSrc = Join-Path $kitRoot 'voice'
    $voiceApp = Join-Path $AiRoot 'voice'

    if (-not (Test-Path (Join-Path $voiceSrc 'server.py'))) {
        Write-Warn "Cannot find $voiceSrc\server.py - run this from inside the kit."
    } else {
        Copy-Item (Join-Path $voiceSrc 'server.py') $voiceApp -Force
        Copy-Item (Join-Path $voiceSrc 'requirements.txt') $voiceApp -Force
        Write-Ok 'Copied server.py and requirements.txt'

        $venv = Join-Path $voiceApp '.venv'
        $py   = Join-Path $venv 'Scripts\python.exe'

        if (-not (Test-Path $py)) {
            Write-Info 'Creating virtual environment.'
            if (Get-Command uv -ErrorAction SilentlyContinue) {
                uv venv $venv --python 3.12
            } else {
                python -m venv $venv
            }
        }

        if (Test-Path $py) {
            # PyTorch must come from the cu128 index: Blackwell is sm_120 and
            # cu124 wheels ship no kernels for it. requirements.txt leaves
            # torch out for exactly this reason.
            Write-Info 'Installing PyTorch (cu128 - required for Blackwell sm_120).'
            & $py -m pip install --upgrade pip --quiet
            & $py -m pip install torch --index-url https://download.pytorch.org/whl/cu128

            Write-Info 'Installing server dependencies.'
            & $py -m pip install -r (Join-Path $voiceApp 'requirements.txt')

            $launcher = Join-Path $voiceApp 'start-voice.ps1'
            @"
# Loopback only - the server has no authentication.
# Add --whisper-device cpu if the GPU is busy with Strata or ComfyUI.
& '$py' '$(Join-Path $voiceApp 'server.py')' --host 127.0.0.1 --port 8100 @args
"@ | Set-Content -Path $launcher -Encoding UTF8
            Write-Ok "Wrote launcher: $launcher"

            Write-Host ''
            Write-Info 'Models download on first request, so the first call is slow.'
            Write-Info 'Check it with: curl http://127.0.0.1:8100/health'
        } else {
            Write-Warn 'Virtual environment creation failed; skipping voice dependencies.'
        }
    }
}

# ===========================================================================
Write-Section 'Ports'
@(
    'Strata        http://127.0.0.1:8080/v1   OpenAI + Anthropic compatible'
    'LM Studio     http://127.0.0.1:1234/v1   OpenAI compatible'
    'Voice         http://127.0.0.1:8100/v1   OpenAI audio endpoints'
    'ComfyUI       http://127.0.0.1:8188      web UI, not an LLM API'
) | ForEach-Object { Write-Host "  $_" }

Write-Host ''
Write-Warn 'Only one heavy workload at a time on 16 GB VRAM.'
Write-Warn 'Stop Strata before running ComfyUI video generation, and vice versa.'

Write-Host ''
Write-Host 'Phase 6 complete.' -ForegroundColor Cyan
Write-Host 'Next: .\06-remote-access.ps1 for phone/laptop access, or install Ubuntu' -ForegroundColor Cyan
Write-Host '      - see reference\ubuntu-install-walkthrough.md' -ForegroundColor Cyan
