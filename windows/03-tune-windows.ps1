#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 4 - Windows performance pass for gaming and local AI.

.DESCRIPTION
    Reports on every setting that measurably affects frame rates or model
    throughput on this hardware, and reports the disk budget for running the
    full AI stack alongside a games library on a 1 TB drive.

    Read-only by default. Pass -Apply to make the changes it recommends.

    What -Apply changes:
      * Hardware-Accelerated GPU Scheduling -> on   (reboot required)
      * Power plan -> Balanced                      (AMD's recommendation for X3D)
      * Memory Integrity (HVCI) -> off              (reboot required, see note)

.EXAMPLE
    .\03-tune-windows.ps1
    .\03-tune-windows.ps1 -Apply
#>
[CmdletBinding()]
param(
    [switch]$Apply
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

$rebootNeeded = $false

# ---------------------------------------------------------------------------
Write-Section 'Resizable BAR'

# Neither WMI nor nvidia-smi exposes ReBAR state reliably, so try nvidia-smi
# and fall back to telling you where to look. This is worth getting right:
# ReBAR is one of the few free frame-rate wins on RTX 50 series cards.
$rebarKnown = $false
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $q = & nvidia-smi -q 2>&1 | Out-String
    if ($q -match '(?im)^\s*Resizable BAR\s*:\s*(\w+)') {
        $rebarKnown = $true
        if ($Matches[1] -match 'Yes|Enabled') { Write-Ok "Resizable BAR is active." }
        else { Write-Warn "Resizable BAR reports '$($Matches[1])'." }
    }
}
if (-not $rebarKnown) {
    Write-Info 'Cannot read ReBAR state programmatically on this driver.'
    Write-Todo 'Check NVIDIA Control Panel > Help > System Information > "Resizable BAR".'
    Write-Info 'If it says No, enable these two in BIOS (Del at boot):'
    Write-Info '    Advanced > PCI Subsystem Settings > Above 4G Decoding   -> Enabled'
    Write-Info '    Advanced > PCI Subsystem Settings > Re-Size BAR Support -> Enabled'
}

# ---------------------------------------------------------------------------
Write-Section 'Hardware-Accelerated GPU Scheduling'

$gfxKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$hwSch = (Get-ItemProperty -Path $gfxKey -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode

if ($hwSch -eq 2) {
    Write-Ok 'Enabled.'
} else {
    Write-Warn "Disabled (HwSchMode = $hwSch)."
    Write-Info 'Lowers latency and is a prerequisite for some NVIDIA features.'
    if ($Apply) {
        Set-ItemProperty -Path $gfxKey -Name HwSchMode -Value 2 -Type DWord
        Write-Ok 'Set to enabled.'
        $rebootNeeded = $true
    } else {
        Write-Todo 'Re-run with -Apply, or: Settings > System > Display > Graphics > Change default graphics settings.'
    }
}

# ---------------------------------------------------------------------------
Write-Section 'Memory Integrity (HVCI)'

# Virtualisation-based security costs a measurable amount of gaming
# performance. Turning it off is a real security trade-off, so it is only
# touched with -Apply and never silently.
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard `
          -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
    $hvciRunning = $dg.SecurityServicesRunning -contains 2
    $vbsRunning = $dg.VirtualizationBasedSecurityStatus -eq 2

    if ($hvciRunning -or $vbsRunning) {
        Write-Warn "Running (VBS status $($dg.VirtualizationBasedSecurityStatus))."
        Write-Info 'Costs a few percent of CPU-bound frame rate on X3D parts.'
        Write-Info 'Turning it off reduces protection against driver-level attacks.'
        if ($Apply) {
            $hvciKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
            if (-not (Test-Path $hvciKey)) { New-Item -Path $hvciKey -Force | Out-Null }
            Set-ItemProperty -Path $hvciKey -Name Enabled -Value 0 -Type DWord
            Write-Ok 'Memory Integrity disabled.'
            $rebootNeeded = $true
        } else {
            Write-Todo 'Your call. Re-run with -Apply to disable, or leave it on.'
        }
    } else {
        Write-Ok 'Not running - nothing to do.'
    }
} catch {
    Write-Info 'Device Guard status unavailable on this edition.'
}

# ---------------------------------------------------------------------------
Write-Section 'CPU power management'

$scheme = (& powercfg /getactivescheme) -join ''
Write-Info $scheme.Trim()

# AMD ships PPM provisioning with the chipset driver that teaches Windows how
# to park cores on X3D parts. With it installed, Balanced is what AMD
# recommends - High Performance actively hurts by defeating core parking.
if ($scheme -match 'Balanced') {
    Write-Ok 'Balanced - correct for the 9800X3D with the AMD chipset driver installed.'
} else {
    Write-Warn 'Not on Balanced.'
    Write-Info 'AMD recommends Balanced for X3D processors. High Performance defeats'
    Write-Info 'the core parking that keeps game threads on the cache-heavy CCD.'
    if ($Apply) {
        & powercfg /setactive SCHEME_BALANCED
        Write-Ok 'Switched to Balanced.'
    } else {
        Write-Todo 'Re-run with -Apply, or: powercfg /setactive SCHEME_BALANCED'
    }
}

Write-Host ''
$amdPnp = Get-PnpDevice -ErrorAction SilentlyContinue |
          Where-Object { $_.FriendlyName -match 'AMD.*(PPM|Provisioning|PSP|GPIO)' }
if ($amdPnp) {
    Write-Ok 'AMD chipset driver components present:'
    $amdPnp | Select-Object -First 4 | ForEach-Object { Write-Host "         $($_.FriendlyName)" }
} else {
    Write-Warn 'AMD chipset driver may be missing.'
    Write-Todo 'Download it from amd.com > Support > Chipsets > AM5 > B850.'
    Write-Info 'Without it, Windows parks cores wrongly on the 9800X3D.'
}

# ---------------------------------------------------------------------------
Write-Section 'Memory speed'

$dimms = Get-CimInstance Win32_PhysicalMemory
$speeds = $dimms.ConfiguredClockSpeed | Sort-Object -Unique
$speedList = $speeds -join ', '
$moduleCount = @($dimms).Count
$topSpeed = ($speeds | Measure-Object -Maximum).Maximum

# With four modules the 9800X3D is rated at DDR5-3600, so ~3600 is correct and
# telling the user to enable EXPO would be wrong advice they can never satisfy.
if ($moduleCount -ge 4) {
    if ($topSpeed -ge 3400) {
        Write-Ok "DDR5-$topSpeed - correct for a four-module build."
        Write-Info 'AMD rates the 9800X3D at 3600 with four DIMMs. Nothing to fix.'
    } else {
        Write-Warn "Running at $speedList MT/s, below the ~3600 expected at four DIMMs."
        Write-Todo 'Confirm EXPO is enabled, or set 3600 manually in Ai Tweaker.'
    }
    Write-Host ''
    Write-Info 'Bandwidth note: four DIMMs cost roughly a fifth of delivered'
    Write-Info 'bandwidth versus two - less than the headline, because a'
    Write-Info 'single-CCD part cannot consume DDR5-6000 anyway. Strata generates'
    Write-Info 'measurably slower as a result; this was the accepted trade for'
    Write-Info 'reaching 96 GB. Gaming is barely affected - the X3D cache'
    Write-Info 'absorbs most of it.'
} else {
    if ($speeds -contains 6000) {
        Write-Ok 'DDR5-6000 - EXPO is active.'
    } else {
        Write-Warn "Running at $speedList MT/s."
        Write-Todo 'Enable the EXPO profile in BIOS > Ai Tweaker > Memory Profile.'
        Write-Info 'This matters twice over: gaming frame rates, and Strata, whose'
        Write-Info 'CPU-resident experts are bound by memory bandwidth.'
    }
}

# ---------------------------------------------------------------------------
Write-Section 'Hibernation'

$hiberOn = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled

if ($hiberOn -eq 0) {
    Write-Ok 'Disabled - and that reclaimed roughly 32 GB of hiberfil.sys.'
} else {
    Write-Warn 'Still enabled.'
    Write-Info 'On a 32 GB machine hiberfil.sys consumes ~32 GB of your 1 TB drive.'
    if ($Apply) {
        & powercfg /H off
        Write-Ok 'Disabled.'
    } else {
        Write-Todo 'Re-run with -Apply, or: powercfg /H off'
    }
}

# ---------------------------------------------------------------------------
Write-Section 'Disk budget'

$c = Get-Volume -DriveLetter C
$freeGb  = [math]::Round($c.SizeRemaining / 1GB)
$totalGb = [math]::Round($c.Size / 1GB)
Write-Info "C: $freeGb GB free of $totalGb GB"

# Running the full AI stack on the same drive as Windows and games is tight on
# 1 TB. These are the actual download sizes.
#
# Strata is the line that varies. It serves one model at a time, so how many
# you install is a disk decision rather than a memory one. Windows gets the
# two that earn their space - Coder for code, Qwen3.6 for everything else -
# while Ubuntu's 2 TB drive holds the wider selection.
$budget = [ordered]@{
    'Strata: Flash-Next Coder'     = 68
    'Strata: Qwen3.6 UD-Q4_K_XL'   = 23
    'ComfyUI image models'         = 20
    'ComfyUI video models'         = 55
    'GGUF chat models'             = 30
    'Voice models'                 = 3
}
Write-Host ''
Write-Host '  Full AI stack on this drive:' -ForegroundColor White
$total = 0
foreach ($kv in $budget.GetEnumerator()) {
    Write-Host ("         {0,-36} {1,4} GB" -f $kv.Key, $kv.Value)
    $total += $kv.Value
}
Write-Host ("         {0,-36} {1,4} GB" -f 'TOTAL', $total)
Write-Host ''

$afterAi = $freeGb - $total
if ($afterAi -lt 150) {
    Write-Warn "Only ~$afterAi GB would remain for games."
    Write-Info 'Skip the ComfyUI video models here and run them on Ubuntu only.'
    Write-Info 'That frees 55 GB and loses nothing - Wan 2.2 is slow on 16 GB anyway.'
} else {
    Write-Ok "~$afterAi GB would remain for games after the full AI stack."
}

Write-Host ''
Write-Info 'Do not add more Strata models to this drive. Gyro-S is another 59 GB'
Write-Info 'and Gyro-M 92 GB; the rest of the catalogue belongs on Ubuntu.'
Write-Info 'See reference\strata-models.md.'

# ---------------------------------------------------------------------------
Write-Section 'Summary'

if ($rebootNeeded) {
    Write-Warn 'Reboot required for the graphics and security changes to take effect.'
}
if (-not $Apply) {
    Write-Info 'Nothing was changed. Re-run with -Apply to action the recommendations.'
}

Write-Host ''
Write-Host 'Phase 4 complete. Next: .\04-install-base.ps1' -ForegroundColor Cyan
