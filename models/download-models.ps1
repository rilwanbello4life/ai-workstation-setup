<#
.SYNOPSIS
    Download the models listed in manifest.tsv into the local AI root (C:\AI).

.DESCRIPTION
    Already-present files are skipped, so re-running is cheap and safe.
    Downloads are staged in a temporary folder and then flattened into the
    destination by basename, because the Hugging Face CLI preserves the
    repo-internal path under --local-dir.

.EXAMPLE
    .\download-models.ps1 -Group image
    .\download-models.ps1 -Group all -AiRoot E:\AI
#>
[CmdletBinding()]
param(
    [ValidateSet('image', 'video', 'voice', 'all')]
    [string]$Group = 'image',

    [string]$AiRoot = $(if ($env:AI_ROOT) { $env:AI_ROOT } else { 'C:\AI' })
)

$ErrorActionPreference = 'Continue'

function Write-Ok($Text)   { Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Warn($Text) { Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-Info($Text) { Write-Host "  [info] $Text" }

if (-not (Test-Path $AiRoot)) {
    throw "AI root not found: $AiRoot. Run windows\05-install-ai-stack.ps1 first, or pass -AiRoot."
}

$manifestPath = Join-Path $PSScriptRoot 'manifest.tsv'
if (-not (Test-Path $manifestPath)) {
    throw 'manifest.tsv not found next to this script.'
}

# The CLI was renamed from huggingface-cli to hf; support both.
$hfExe = $null
foreach ($candidate in @('hf', 'huggingface-cli')) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) { $hfExe = $candidate; break }
}
if (-not $hfExe) {
    throw 'Hugging Face CLI not found. Install it with: pip install huggingface_hub'
}
Write-Info "Using CLI: $hfExe"

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("hfstage-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$downloaded = 0; $skipped = 0; $failed = 0

try {
    Write-Host ''
    Write-Host "Downloading group '$Group' into $AiRoot" -ForegroundColor Cyan
    Write-Host ''

    foreach ($line in Get-Content $manifestPath) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }

        $fields = $line -split "`t"
        if ($fields.Count -lt 4) { continue }

        $g    = $fields[0].Trim()
        $repo = $fields[1].Trim()
        $file = $fields[2].Trim()
        $dest = $fields[3].Trim()

        if ($Group -ne 'all' -and $Group -ne $g) { continue }

        $targetDir = Join-Path $AiRoot ($dest -replace '/', '\')
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

        if ($file -eq '*') {
            Write-Host "$repo (whole repository)" -ForegroundColor White
            if ((Get-ChildItem $targetDir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
                Write-Ok "already populated: $targetDir"
                $skipped++
                continue
            }
            & $hfExe download $repo --local-dir $targetDir
            if ($LASTEXITCODE -eq 0) { Write-Ok "$repo -> $targetDir"; $downloaded++ }
            else                     { Write-Warn "failed: $repo"; $failed++ }
            continue
        }

        $base  = Split-Path $file -Leaf
        $final = Join-Path $targetDir $base

        Write-Host $base -ForegroundColor White
        if (Test-Path $final) {
            $sizeGb = [math]::Round((Get-Item $final).Length / 1GB, 2)
            Write-Ok "already present (${sizeGb} GB)"
            $skipped++
            continue
        }

        Write-Info "$repo :: $file"
        & $hfExe download $repo $file --local-dir $staging

        if ($LASTEXITCODE -eq 0) {
            $src = Get-ChildItem -Path $staging -Recurse -File -Filter $base -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($src) {
                Move-Item -Path $src.FullName -Destination $final -Force
                $sizeGb = [math]::Round((Get-Item $final).Length / 1GB, 2)
                Write-Ok "-> $final  (${sizeGb} GB)"
                $downloaded++
            } else {
                Write-Warn "downloaded but could not locate $base in staging"
                $failed++
            }
        } else {
            Write-Warn "failed: $repo :: $file"
            Write-Warn "the repository may have been renamed - check with: $hfExe search $($repo.Split('/')[-1])"
            $failed++
        }
        Write-Host ''
    }
}
finally {
    Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Summary: $downloaded downloaded, $skipped already present, $failed failed" -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 }
