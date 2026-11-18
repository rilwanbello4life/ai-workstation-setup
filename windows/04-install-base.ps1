<#
.SYNOPSIS
    Phase 5 - Base developer tooling via winget.

.DESCRIPTION
    Installs the prerequisites the AI stack needs (Git, Python, Node, uv) plus
    the hardware-inspection tools worth having on a new build.

    Every package is installed independently; a failure on one does not stop
    the rest. A summary is printed at the end.

.EXAMPLE
    .\04-install-base.ps1
    .\04-install-base.ps1 -SkipDiagnostics
#>
[CmdletBinding()]
param(
    [switch]$SkipDiagnostics
)

$ErrorActionPreference = 'Continue'

function Write-Section($Text) {
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}
function Write-Ok($Text)   { Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Warn($Text) { Write-Host "  [warn] $Text" -ForegroundColor Yellow }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
}

$results = [System.Collections.Generic.List[object]]::new()

function Install-Pkg {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name
    )

    Write-Host ''
    Write-Host "--- $Name ($Id)" -ForegroundColor Gray

    $installed = winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-String
    if ($installed -match [regex]::Escape($Id)) {
        Write-Ok "$Name already installed."
        $script:results.Add([pscustomobject]@{ Name = $Name; Status = 'already present' })
        return
    }

    winget install --id $Id --exact --silent `
        --accept-package-agreements --accept-source-agreements 2>&1 | Out-String | Write-Verbose

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$Name installed."
        $script:results.Add([pscustomobject]@{ Name = $Name; Status = 'installed' })
    } else {
        Write-Warn "$Name failed (exit $LASTEXITCODE). Install it manually."
        $script:results.Add([pscustomobject]@{ Name = $Name; Status = "FAILED ($LASTEXITCODE)" })
    }
}

# ---------------------------------------------------------------------------
Write-Section 'Core toolchain'

Install-Pkg -Id 'Git.Git'                    -Name 'Git'
Install-Pkg -Id 'Python.Python.3.12'         -Name 'Python 3.12'
Install-Pkg -Id 'astral-sh.uv'               -Name 'uv (fast Python package manager)'
Install-Pkg -Id 'OpenJS.NodeJS.LTS'          -Name 'Node.js LTS'   # Pi requires Node >= 22.19
Install-Pkg -Id '7zip.7zip'                  -Name '7-Zip'
Install-Pkg -Id 'Microsoft.PowerShell'       -Name 'PowerShell 7'
Install-Pkg -Id 'Microsoft.VCRedist.2015+.x64' -Name 'Visual C++ Redistributable'

if (-not $SkipDiagnostics) {
    Write-Section 'Hardware diagnostics'
    Install-Pkg -Id 'CPUID.CPU-Z'                     -Name 'CPU-Z (verify EXPO and DIMM slots)'
    Install-Pkg -Id 'CrystalDewWorld.CrystalDiskInfo' -Name 'CrystalDiskInfo (NVMe health)'
    Install-Pkg -Id 'REALiX.HWiNFO'                   -Name 'HWiNFO (thermals under load)'
}

# ---------------------------------------------------------------------------
Write-Section 'Summary'
$results | Format-Table Name, Status -AutoSize

$failed = $results | Where-Object { $_.Status -like 'FAILED*' }
if ($failed) {
    Write-Warn "$($failed.Count) package(s) failed. Install them manually before continuing."
} else {
    Write-Ok 'All packages present.'
}

# ---------------------------------------------------------------------------
Write-Section 'Verification'
Write-Host '  Open a NEW terminal (so PATH refreshes) and check:'
@(
    'git --version'
    'python --version'
    'node --version      # must be 22.19 or newer for Pi'
    'uv --version'
    'nvidia-smi'
) | ForEach-Object { Write-Host "    $_" }

Write-Host ''
Write-Host 'Phase 5 complete. Next: .\05-install-ai-stack.ps1' -ForegroundColor Cyan
