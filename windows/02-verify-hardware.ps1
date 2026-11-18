<#
.SYNOPSIS
    Phase 2 - Read-only hardware inventory and sanity checks.

.DESCRIPTION
    Confirms the assumptions the whole setup plan rests on:
      * how the memory is populated, and how much of it reaches Strata
      * that EXPO is actually active (DDR5-6000, not JEDEC 4800)
      * which M.2 slots are occupied
      * that the GPU and driver are what we expect

    Purely read-only. Safe to run at any time, does not need Administrator
    (though a few fields are richer if elevated).

.EXAMPLE
    .\02-verify-hardware.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Write-Section($Text) {
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}
function Write-Ok($Text)   { Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Warn($Text) { Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-Info($Text) { Write-Host "  [info] $Text" }

# ---------------------------------------------------------------------------
Write-Section 'CPU and motherboard'

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$bb  = Get-CimInstance Win32_BaseBoard
$bios = Get-CimInstance Win32_BIOS

Write-Info "CPU:         $($cpu.Name.Trim())"
Write-Info "Cores:       $($cpu.NumberOfCores) physical / $($cpu.NumberOfLogicalProcessors) logical"
Write-Info "Motherboard: $($bb.Manufacturer) $($bb.Product)"
Write-Info "BIOS:        $($bios.SMBIOSBIOSVersion), released $($bios.ReleaseDate)"

if ($bb.Product -notmatch 'B850') {
    Write-Warn "Expected a B850 board. The M.2 slot guidance in this kit assumes TUF GAMING B850-PLUS WIFI."
}

# ---------------------------------------------------------------------------
# Memory. After phase 11 this machine is in one of two valid states, and the
# module count tells them apart: four modules is 96 GB at ~DDR5-3600 (the 2x32
# kit added to the factory 2x16 pair), two is 64 GB at the full 6000 (the 2x32
# kit on its own). The 9800X3D runs DDR5-5600 with two modules but only
# DDR5-3600 with four, so ~3600 on a four-DIMM build is correct, not a fault.
# ---------------------------------------------------------------------------
Write-Section 'Memory'

$dimms = Get-CimInstance Win32_PhysicalMemory
$array = Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1
$totalSlots = if ($array) { $array.MemoryDevices } else { 4 }

foreach ($d in $dimms | Sort-Object DeviceLocator) {
    $gb = [math]::Round($d.Capacity / 1GB)
    Write-Info ("Slot {0,-10} {1,3} GB  {2} MT/s  {3} {4}" -f `
        $d.DeviceLocator, $gb, $d.ConfiguredClockSpeed, $d.Manufacturer, $d.PartNumber)
}

$populated = $dimms.Count
$free = $totalSlots - $populated
$totalGb = [math]::Round(($dimms | Measure-Object -Property Capacity -Sum).Sum / 1GB)

Write-Host ''
Write-Info "Populated: $populated of $totalSlots slots, $totalGb GB total, $free slot(s) free"

if ($populated -eq 2) {
    Write-Ok 'Two modules - correct configuration for the 9800X3D.'
    $locators = ($dimms.DeviceLocator | Sort-Object) -join ', '
    # ASUS AM5 boards want the second slot of each channel (A2/B2) when only two
    # modules are fitted. Different BIOS revisions label these differently.
    if ($locators -match 'A2' -and $locators -match 'B2') {
        Write-Ok "Seated in $locators - correct dual-channel slots."
    } else {
        Write-Warn "Seated in $locators."
        Write-Warn 'ASUS AM5 boards expect DIMM_A2 and DIMM_B2 when only two modules are fitted.'
        Write-Warn 'Check the manual and move them if needed - wrong slots cost real bandwidth.'
    }
} elseif ($populated -eq 4) {
    Write-Ok "Four modules - the 'add' configuration, $totalGb GB."
    # Mixed capacities are expected here: a 2x32 GB kit alongside the factory
    # 2x16 GB pair. That is fine as long as each channel holds the same mixture,
    # which is why the 32 GB modules belong in A2/B2 and the 16 GB pair in A1/B1.
    $sizes = ($dimms | ForEach-Object { [math]::Round($_.Capacity / 1GB) } | Sort-Object -Unique)
    if ($sizes.Count -gt 1) {
        Write-Info "Mixed module sizes ($($sizes -join ' and ') GB) - expected for this build."
        Write-Info 'Each channel must hold the same mixture; see reference\ram-upgrade-decision.md.'
    }
} else {
    Write-Warn "Unexpected module count: $populated"
}

# The expected speed depends on how many modules are fitted. AMD rates the
# 9800X3D at DDR5-5600 with two and only DDR5-3600 with four, so ~3600 on a
# four-DIMM build is correct and must not be reported as a missing EXPO
# profile - that was the behaviour of an earlier version of this script.
$speeds = $dimms.ConfiguredClockSpeed | Sort-Object -Unique
$speedList = $speeds -join ', '
$topSpeed = ($speeds | Measure-Object -Maximum).Maximum

if ($populated -ge 4) {
    if ($topSpeed -ge 3400) {
        Write-Ok "Running at $speedList MT/s - correct for four modules."
        Write-Info 'DDR5-3600 is the AMD limit at four DIMMs, not a misconfiguration.'
        Write-Info 'Leave EXPO enabled; the board trains down to this on its own.'
    } else {
        Write-Warn "Running at $speedList MT/s - lower than the ~3600 expected."
        Write-Todo 'Check EXPO is enabled, then let the board retrain.'
        Write-Info 'If it will not hold 3600, DDR5-3200 is the documented fallback.'
    }
} else {
    if ($speeds -contains 6000) {
        Write-Ok 'Running at 6000 MT/s - EXPO is active.'
    } elseif ($speeds | Where-Object { $_ -le 4800 }) {
        Write-Warn "Running at $speedList MT/s - this is the JEDEC fallback."
        Write-Warn 'Enable the EXPO profile in BIOS. You are leaving ~25% memory bandwidth on the table.'
    } else {
        Write-Info "Configured speed: $speedList MT/s"
    }
}

if ($free -ge 2 -and $totalGb -ge 60) {
    Write-Host ''
    Write-Info "Two slots are free at $totalGb GB - this is the 'swap' configuration,"
    Write-Info 'full DDR5-6000 on two modules. Adding the 2x16 GB pair back reaches'
    Write-Info '96 GB at roughly DDR5-3600: more capacity, about a fifth less'
    Write-Info 'bandwidth. See reference\ram-upgrade-decision.md for the trade-off.'
}

if ($totalGb -lt 40) {
    Write-Host ''
    Write-Warn "Only $totalGb GB fitted. The server platform (k3s, Postgres, n8n,"
    Write-Warn 'LiteLLM, Open WebUI) needs ~15 GB before a model loads, which does'
    Write-Warn 'not fit alongside Strata at 32 GB. Fit the 2x32 GB kit first.'
}

# The experts figure is what actually decides which Strata pack will load, so
# report it rather than making the reader do the arithmetic. ~15 GB for the
# server stack, ~10 GB for the OS, the remainder holds experts.
if ($totalGb -ge 60) {
    $reported  = [math]::Floor($totalGb * 0.969)
    $expertsUp = $reported - 25
    Write-Host ''
    Write-Info "Roughly $expertsUp GB for experts with the cluster up, $($reported - 10) GB after ai-pause."
    if ($expertsUp -ge 62) {
        Write-Info 'That reaches UD-IQ4_XS with the cluster running, NVFP4 after a pause.'
    } elseif ($expertsUp -ge 50) {
        Write-Info 'That reaches IQ3_S with the cluster running.'
    } else {
        Write-Info 'That reaches IQ2_XS with the cluster running, IQ3_S after a pause.'
    }
}

# ---------------------------------------------------------------------------
Write-Section 'GPU'

$gpus = Get-CimInstance Win32_VideoController
foreach ($g in $gpus) {
    # AdapterRAM is a signed 32-bit field and wraps above 4 GB, so read the real
    # value from the driver registry key instead.
    $vramGb = $null
    try {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\*"
        $match = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
                 Where-Object { $_.DriverDesc -eq $g.Name } | Select-Object -First 1
        if ($match -and $match.'HardwareInformation.qwMemorySize') {
            $vramGb = [math]::Round($match.'HardwareInformation.qwMemorySize' / 1GB)
        }
    } catch { }

    Write-Info "GPU:    $($g.Name)"
    Write-Info "Driver: $($g.DriverVersion)  ($($g.DriverDate))"
    if ($vramGb) { Write-Info "VRAM:   $vramGb GB" }
}

if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    Write-Host ''
    & nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv
} else {
    Write-Warn 'nvidia-smi not found. Install the NVIDIA driver from nvidia.com.'
}

if ($gpus.Name -match '5070 Ti') {
    Write-Ok 'RTX 5070 Ti detected (Blackwell, sm_120).'
    Write-Info 'On Linux this card REQUIRES the open kernel modules: nvidia-open.'
    Write-Info 'PyTorch must come from the cu128 index or newer - cu124 has no sm_120 kernels.'
}

# ---------------------------------------------------------------------------
Write-Section 'Storage'

$disks = Get-Disk | Sort-Object Number
foreach ($d in $disks) {
    $sizeGb = [math]::Round($d.Size / 1GB)
    $phys = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $d.Number } | Select-Object -First 1
    $bus = if ($phys) { $phys.BusType } else { 'unknown' }
    $tag = if ($d.IsSystem) { ' [SYSTEM]' } else { '' }
    Write-Info "Disk $($d.Number): $($d.FriendlyName) - ${sizeGb} GB, $bus, $($d.PartitionStyle)$tag"

    foreach ($p in (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)) {
        $pSizeGb = [math]::Round($p.Size / 1GB, 1)
        $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue
        $label = if ($vol -and $vol.FileSystemLabel) { $vol.FileSystemLabel } else { $p.Type }
        $letter = if ($p.DriveLetter) { "$($p.DriveLetter): " } else { '' }
        Write-Host "        partition $($p.PartitionNumber): $letter${pSizeGb} GB  $label"
    }

    $unalloc = [math]::Round($d.LargestFreeExtent / 1GB, 1)
    if ($unalloc -gt 1) { Write-Host "        unallocated: ${unalloc} GB" -ForegroundColor Yellow }
}

$nvmeCount = (Get-PhysicalDisk | Where-Object { $_.BusType -eq 'NVMe' }).Count
Write-Host ''
Write-Info "NVMe drives present: $nvmeCount (board has 3 M.2 slots)"
if ($nvmeCount -lt 2) {
    Write-Warn 'Only one NVMe found. The 2 TB Ubuntu drive belongs in M.2_2 (Phase 3).'
    Write-Warn 'Do NOT use M.2_3 - it disables the second PCIe x16 slot.'
}

Write-Host ''
Write-Host 'Phase 2 complete. Next: .\03-tune-windows.ps1' -ForegroundColor Cyan
