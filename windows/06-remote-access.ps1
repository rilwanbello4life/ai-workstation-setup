#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 10 - Remote access over Tailscale.

.DESCRIPTION
    None of the AI services has authentication, so nothing here ever binds
    them to a public interface. Instead:

      1. Tailscale builds a private WireGuard network between your devices.
      2. Open WebUI gives phones a real chat UI with its own user accounts.
      3. 'tailscale serve' publishes loopback services as HTTPS URLs that
         only your tailnet can reach. The services stay on 127.0.0.1.

    Never use 'tailscale funnel' here - that is the public internet.

.EXAMPLE
    .\06-remote-access.ps1
    .\06-remote-access.ps1 -SkipWebUI
    .\06-remote-access.ps1 -WebUIPort 3000
#>
[CmdletBinding()]
param(
    [int]$WebUIPort = 3000,     # 8080 is Strata; Open WebUI must move
    [switch]$SkipWebUI,
    [switch]$SkipSsh
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

$AiRoot = if ($env:AI_ROOT) { $env:AI_ROOT } else { 'C:\AI' }

# ---------------------------------------------------------------------------
Write-Section 'Tailscale'

if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    Write-Ok 'Already installed.'
} else {
    winget install --id tailscale.tailscale --exact --silent `
        --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Get-Command tailscale -ErrorAction SilentlyContinue) {
        Write-Ok 'Installed.'
    } else {
        Write-Warn 'Not on PATH yet. Open a new terminal and re-run, or install from https://tailscale.com/download'
        return
    }
}

& tailscale status 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Ok 'Already signed in.'
} else {
    Write-Info 'A browser will open. Use the same account on every device.'
    & tailscale up
}

$tsIp = (& tailscale ip -4 2>$null | Select-Object -First 1)
if ($tsIp) { Write-Ok "Tailnet IP: $tsIp" }

# ---------------------------------------------------------------------------
if (-not $SkipSsh) {
    Write-Section 'OpenSSH Server'

    # Tailscale's own SSH server is Linux and macOS only, so on Windows the
    # built-in OpenSSH server does the job, reached over the tailnet.
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue |
           Select-Object -First 1

    if ($cap -and $cap.State -eq 'Installed') {
        Write-Ok 'Already installed.'
    } elseif ($cap) {
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        Write-Ok 'Installed.'
    } else {
        Write-Warn 'OpenSSH Server capability not found on this edition.'
    }

    if (Get-Service sshd -ErrorAction SilentlyContinue) {
        Set-Service -Name sshd -StartupType Automatic
        Start-Service sshd
        Write-Ok 'sshd running and set to start automatically.'

        # Only reachable over the tailnet, so no LAN or internet exposure.
        if (-not (Get-NetFirewallRule -Name 'sshd-tailscale' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'sshd-tailscale' -DisplayName 'OpenSSH Server (Tailscale only)' `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
                -LocalPort 22 -RemoteAddress '100.64.0.0/10' | Out-Null
            Write-Ok 'Firewall rule added, scoped to the Tailscale CGNAT range.'
        } else {
            Write-Ok 'Firewall rule already present.'
        }
    }
}

# ---------------------------------------------------------------------------
if (-not $SkipWebUI) {
    Write-Section 'Open WebUI'

    # Open WebUI supports Python 3.11 and 3.12 only - 3.13 has no compatible
    # release of some dependencies and fails at runtime.
    $app  = Join-Path $AiRoot 'open-webui'
    $venv = Join-Path $app '.venv'
    $py   = Join-Path $venv 'Scripts\python.exe'
    New-Item -ItemType Directory -Path $app -Force | Out-Null

    if (-not (Test-Path $py)) {
        if (Get-Command uv -ErrorAction SilentlyContinue) {
            uv venv $venv --python 3.12
        } else {
            py -3.12 -m venv $venv
        }
    }

    if (Test-Path $py) {
        & $py -m pip install --upgrade pip --quiet
        & $py -m pip install open-webui
        Write-Ok "Installed at $app"

        # The session signing key must be stable, or every restart logs
        # everyone out.
        $secretFile = Join-Path $app '.webui_secret_key'
        if (-not (Test-Path $secretFile)) {
            $bytes = [byte[]]::new(32)
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
            ($bytes | ForEach-Object { $_.ToString('x2') }) -join '' |
                Set-Content -Path $secretFile -Encoding ASCII -NoNewline
            Write-Ok 'Generated a persistent session key.'
        }

        $launcher = Join-Path $app 'start-open-webui.ps1'
        @"
# Loopback only. Remote access goes through 'tailscale serve', never by
# binding this to 0.0.0.0.
`$env:DATA_DIR          = '$app\data'
`$env:HF_HOME           = '$AiRoot\hf-cache'
`$env:WEBUI_AUTH        = 'True'
`$env:WEBUI_SECRET_KEY  = (Get-Content '$secretFile' -Raw).Trim()
Set-Location '$app'
& '$venv\Scripts\open-webui.exe' serve --host 127.0.0.1 --port $WebUIPort
"@ | Set-Content -Path $launcher -Encoding UTF8
        Write-Ok "Wrote launcher: $launcher"
        Write-Info "Start it with: pwsh -File `"$launcher`""
    } else {
        Write-Warn 'Virtual environment creation failed. Is Python 3.12 installed?'
    }
}

# ---------------------------------------------------------------------------
Write-Section 'Publishing to the tailnet'

# Each service gets its own HTTPS port on the same MagicDNS hostname. The
# listener binds to the Tailscale interface only - the service stays on
# loopback and is still invisible to the LAN.
Write-Info 'The first serve command prompts you to enable HTTPS certificates'
Write-Info 'for your tailnet. That is a one-time consent in the browser.'
Write-Host ''
Write-Host '  Planned mapping:' -ForegroundColor White
@(
    "      443   ->  Open WebUI    127.0.0.1:$WebUIPort"
    '      8443  ->  ComfyUI       127.0.0.1:8188'
    '      8444  ->  Strata API    127.0.0.1:8080'
    '      8445  ->  LM Studio API 127.0.0.1:1234'
    '      8446  ->  Voice API     127.0.0.1:8100'
) | ForEach-Object { Write-Host $_ }
Write-Host ''

$answer = Read-Host '  Publish these now? [y/N]'
if ($answer -match '^[Yy]$') {
    & tailscale serve --bg $WebUIPort
    & tailscale serve --bg --https=8443 8188
    & tailscale serve --bg --https=8444 8080
    & tailscale serve --bg --https=8445 1234
    & tailscale serve --bg --https=8446 8100
    Write-Host ''
    & tailscale serve status
    Write-Ok 'Published. These URLs resolve only for devices on your tailnet.'
} else {
    Write-Todo 'Publish later with the commands in reference\remote-access.md'
}

# ---------------------------------------------------------------------------
Write-Section 'Summary'

@'
  Install Tailscale on your phone and laptop, sign in with the same account,
  then run `tailscale status` here to get your exact hostname.

      https://<host>.<tailnet>.ts.net          Open WebUI (start here on a phone)
      https://<host>.<tailnet>.ts.net:8443     ComfyUI
      https://<host>.<tailnet>.ts.net:8444/v1  Strata API
      https://<host>.<tailnet>.ts.net:8445/v1  LM Studio API
      https://<host>.<tailnet>.ts.net:8446/v1  Voice API

      ssh <user>@<tailnet-ip>                  OpenSSH over the tailnet

  First time in Open WebUI: the first account you create becomes the admin.
  Then Settings > Admin > Connections > Manage OpenAI API Connections, and add

      http://127.0.0.1:8080/v1   Strata      (API key: anything)
      http://127.0.0.1:1234/v1   LM Studio

  Open WebUI reaches those over loopback because it runs on this machine.

  Two things to remember:
    * This machine must be awake, and booted into THIS operating system.
      Windows and Ubuntu are independent - whichever is running is what you
      can reach.
    * Never run `tailscale funnel`. That publishes to the public internet,
      and ComfyUI can execute arbitrary code.
'@ | Write-Host

Write-Host ''
Write-Host 'Phase 10 complete. Details: reference\remote-access.md' -ForegroundColor Cyan
