#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 1 - Windows safety baseline before any dual-boot work.

.DESCRIPTION
    Exports the BitLocker recovery key, disables Fast Startup and hibernation,
    and reports Secure Boot / TPM / partition style. Run this FIRST, before
    installing anything and before opening the case.

    Nothing here is destructive. Disabling hibernation is reversible with
    `powercfg /H on`.

.EXAMPLE
    .\01-preflight.ps1
    .\01-preflight.ps1 -KeyOutputPath D:\bitlocker-key.txt
#>
[CmdletBinding()]
param(
    [string]$KeyOutputPath = (Join-Path $PSScriptRoot 'bitlocker-recovery-key.txt')
)

$ErrorActionPreference = 'Stop'

function Write-Section($Text) {
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Ok($Text)   { Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Warn($Text) { Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-Info($Text) { Write-Host "  [info] $Text" }

Write-Section 'System identity'
$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
Write-Info "Model:   $($cs.Manufacturer) $($cs.Model)"
Write-Info "OS:      $($os.Caption) build $($os.BuildNumber)"
Write-Info "RAM:     $([math]::Round($cs.TotalPhysicalMemory / 1GB, 1)) GB"

# ---------------------------------------------------------------------------
# BitLocker recovery key. This is the single most important step: changing the
# boot chain or Secure Boot state can drop Windows into recovery, and without
# this key the data is unreachable.
# ---------------------------------------------------------------------------
Write-Section 'BitLocker / device encryption'

$bdeStatus = & manage-bde.exe -status C: 2>&1 | Out-String
$isProtected = $bdeStatus -match 'Protection\s+On'

if ($isProtected) {
    Write-Warn 'Device encryption is ON for C:. Exporting the recovery key.'
} else {
    Write-Info 'Device encryption appears to be OFF for C:.'
    Write-Info 'It can switch on later when you sign in with a Microsoft account,'
    Write-Info 'so the export below is still attempted.'
}

$protectors = & manage-bde.exe -protectors -get C: 2>&1 | Out-String

if ($protectors -match 'Numerical Password') {
    $report = @(
        "BitLocker recovery information for $($cs.Model)"
        "Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ''
        '--- manage-bde -status C: ---'
        $bdeStatus
        '--- manage-bde -protectors -get C: ---'
        $protectors
    ) -join [Environment]::NewLine

    Set-Content -Path $KeyOutputPath -Value $report -Encoding UTF8
    Write-Ok "Recovery key written to: $KeyOutputPath"
    Write-Warn 'MOVE THIS FILE OFF THIS PC NOW. A key stored on the encrypted disk is useless.'
    Write-Info 'Also check https://account.microsoft.com/devices/recoverykey for the online copy.'
} else {
    Write-Warn 'No numerical password protector found - nothing to export yet.'
    Write-Info 'Re-run this script after device encryption activates.'
}

# ---------------------------------------------------------------------------
# Fast Startup. With it on, "shutdown" hibernates the kernel, NTFS volumes stay
# dirty, and Linux writes to a shared partition can corrupt it.
# ---------------------------------------------------------------------------
Write-Section 'Fast Startup and hibernation'

& powercfg.exe /H off
if ($LASTEXITCODE -eq 0) {
    Write-Ok 'Hibernation and Fast Startup disabled (powercfg /H off).'
} else {
    Write-Warn "powercfg returned exit code $LASTEXITCODE - disable Fast Startup manually."
    Write-Info 'Control Panel > Power Options > Choose what the power buttons do.'
}

$hiberKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$hiberOn = (Get-ItemProperty -Path $hiberKey -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
if ($null -ne $hiberOn) {
    if ($hiberOn -eq 0) { Write-Ok 'Verified: HibernateEnabled = 0' }
    else                { Write-Warn "HibernateEnabled is still $hiberOn" }
}

# ---------------------------------------------------------------------------
# Firmware state. Secure Boot can stay ON: Ubuntu ships a signed shim, and the
# NVIDIA driver is handled by enrolling a MOK key at first reboot.
# ---------------------------------------------------------------------------
Write-Section 'Firmware and boot mode'

try {
    $secureBoot = Confirm-SecureBootUEFI
    if ($secureBoot) { Write-Ok 'Secure Boot is enabled. Leave it on - Ubuntu handles it.' }
    else             { Write-Info 'Secure Boot is disabled.' }
} catch {
    Write-Warn "Could not read Secure Boot state: $($_.Exception.Message)"
}

$sysDisk = Get-Disk | Where-Object { $_.IsSystem -eq $true }
foreach ($d in $sysDisk) {
    if ($d.PartitionStyle -eq 'GPT') { Write-Ok "System disk $($d.Number) is GPT (required for UEFI dual boot)." }
    else                             { Write-Warn "System disk $($d.Number) is $($d.PartitionStyle) - expected GPT." }
}

$esp = Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
if ($esp) {
    foreach ($p in $esp) {
        $sizeMb = [math]::Round($p.Size / 1MB)
        Write-Info "EFI System Partition: disk $($p.DiskNumber) partition $($p.PartitionNumber), ${sizeMb} MB"
        if ($sizeMb -lt 300) {
            Write-Warn 'ESP is small. Ubuntu will still fit, but avoid installing many kernels.'
        }
    }
} else {
    Write-Warn 'No EFI System Partition found. Investigate before installing Ubuntu.'
}

# ---------------------------------------------------------------------------
Write-Section 'Manual steps this script cannot do'
@(
    '1. Enter BIOS (Del at boot) and enable the EXPO memory profile.'
    '   Without it the DDR5-6000 kit runs at JEDEC 4800.'
    '2. Update the BIOS to the latest ASUS release for the TUF B850-PLUS WIFI.'
    '3. Install the current NVIDIA driver from nvidia.com (not Windows Update).'
    '4. Move the exported BitLocker key onto a different device.'
    '5. Run a full shutdown (not restart) before booting the Ubuntu USB.'
) | ForEach-Object { Write-Host "  $_" }

Write-Host ''
Write-Host 'Phase 1 complete. Next: .\02-verify-hardware.ps1' -ForegroundColor Cyan
