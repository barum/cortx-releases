<#
.SYNOPSIS
  CorTxOS single-binary installer for Windows (PowerShell).

.DESCRIPTION
  Downloads the `cortx.exe` for this machine's architecture from the GitHub
  release, verifies its SHA-256 against the published sidecar, installs it to
  %LOCALAPPDATA%\Programs\cortx, and adds that directory to the user PATH.

  One-liner:
    irm https://raw.githubusercontent.com/barum/cortx-releases/main/scripts/install-cortx.ps1 | iex

.PARAMETER Version
  Release version to install (default: latest).
#>
[CmdletBinding()]
param(
    [string]$Version = "latest",
    [string]$Repo = "barum/cortx-releases"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Only x86_64 Windows is published today; fail loudly on anything else.
$arch = (Get-CimInstance Win32_Processor).Architecture
if ($arch -ne 9) {
    throw "cortx: unsupported Windows architecture (only x86_64 is published)."
}
$triple = "x86_64-pc-windows-msvc"

if ($Version -eq "latest") {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "cortx-installer" }
    $Version = $rel.tag_name -replace '^v', ''
}
Write-Host "→ Installing cortx $Version ($triple)…"

$base = "https://github.com/$Repo/releases/download/v$Version"
$zipName = "cortx-$Version-$triple.zip"
$zipUrl = "$base/$zipName"
$shaUrl = "$zipUrl.sha256"

$tmp = Join-Path $env:TEMP ("cortx-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $zipPath = Join-Path $tmp $zipName
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    $expected = ((Invoke-WebRequest -Uri $shaUrl -UseBasicParsing).Content -split '\s+')[0].ToLower()
    $actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
    if ($actual -ne $expected) {
        throw "cortx: SHA-256 mismatch (expected $expected, got $actual). Refusing to install."
    }
    Write-Host "✓ SHA-256 verified."

    # GAP-SRF0059 — require Sigstore sidecar; refuse when messageDigest mismatches.
    $bundleUrl = "$zipUrl.sigstore.json"
    $bundlePath = "$zipPath.sigstore.json"
    Invoke-WebRequest -Uri $bundleUrl -OutFile $bundlePath -UseBasicParsing
    $bundle = Get-Content -Raw -Path $bundlePath | ConvertFrom-Json
    $digestB64 = $bundle.messageSignature.messageDigest.digest
    if (-not $digestB64) {
        throw "cortx: Sigstore bundle missing messageDigest — refusing to install."
    }
    $digestBytes = [Convert]::FromBase64String($digestB64)
    $expectedDigest = ([BitConverter]::ToString($digestBytes) -replace '-', '').ToLower()
    if ($expectedDigest -ne $actual) {
        throw "cortx: Sigstore messageDigest mismatch (bundle=$expectedDigest, asset=$actual). Refusing to install."
    }
    Write-Host "✓ Sigstore messageDigest verified ($actual)."

    Expand-Archive -Path $zipPath -DestinationPath $tmp -Force
    $installDir = Join-Path $env:LOCALAPPDATA "Programs\cortx"
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -Path (Join-Path $tmp "cortx.exe") -Destination (Join-Path $installDir "cortx.exe") -Force

    # Add to the user PATH if missing.
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$installDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
        Write-Host "✓ Added $installDir to your user PATH (restart your shell)."
    }
    Write-Host "✓ cortx installed at $installDir\cortx.exe"
    Write-Host "  Durable memory: run ``cortx graph-server`` (keep running). Verify: ``cortx memory health``."
    Write-Host "  Update later:   cortx self-update --apply"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
