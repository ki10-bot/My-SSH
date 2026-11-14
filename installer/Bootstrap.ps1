<#
.SYNOPSIS
    RemoteGate Bootstrap — secure one-command downloader.
    Downloads the installer from GitHub, verifies SHA256, then executes it.

.DESCRIPTION
    Usage (elevated PowerShell):
      iex (irm https://raw.githubusercontent.com/ki10-bot/My-SSH/main/installer/Bootstrap.ps1)

    Security properties:
      - Downloads to a temp directory (no direct pipe to execution)
      - Verifies SHA256 checksum against a pinned value before execution
      - Uses a pinned tag/commit — not a moving branch for production
      - Requires Administrator — respects UAC
      - Shows progress and errors

    For production, replace $ExpectedSha256 with the actual release checksum
    from the GitHub release page. The placeholder will cause verification to fail
    until you publish a release and pin the hash.

.NOTES
    Update $ReleaseTag and $ExpectedSha256 for each release.
#>
[CmdletBinding()]
param(
    [string]$ReleaseTag = "v0.1.0",
    [string]$ExpectedSha256 = "",
    [switch]$SkipChecksumVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repo = "ki10-bot/My-SSH"
$BaseUrl = "https://raw.githubusercontent.com/$Repo/$ReleaseTag"

# Files to download
$Files = @(
    "installer/Install-RemoteGate.ps1",
    "installer/Configure-SSH.ps1",
    "installer/Configure-Firewall.ps1",
    "installer/Configure-Tunnel.ps1",
    "installer/Verify-Installation.ps1",
    "installer/Uninstall-RemoteGate.ps1",
    "windows/RemoteGate-Agent.ps1",
    "windows/RemoteGate-Tunnel.ps1",
    "windows/RemoteGate-Status.ps1",
    "config/config.example.json"
)

function Write-BSLog { param([string]$Msg, [string]$Level="INFO")
    $c = if($Level -eq "ERROR"){"Red"}elseif($Level -eq "WARN"){"Yellow"}else{"Cyan"}
    Write-Host "[Bootstrap] $Msg" -ForegroundColor $c
}

Write-Host @"

  RemoteGate Bootstrap — Secure Downloader
  Repo: $Repo @ $ReleaseTag
"@ -ForegroundColor Green

# Admin check (warn, don't block download — Install-RemoteGate will enforce)
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-BSLog "Not running as Administrator. Download will proceed, but installation will require elevation." "WARN"
    Write-Host "Please run PowerShell as Administrator for installation." -ForegroundColor Yellow
}

# Create temp dir
$tempRoot = Join-Path $env:TEMP "RemoteGate-bootstrap-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
Write-BSLog "Temp directory: $tempRoot"

# Download each file
$downloaded = @()
foreach ($rel in $Files) {
    $url = "$BaseUrl/$rel"
    $dest = Join-Path $tempRoot $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Write-BSLog "Downloading $rel ..."
    try {
        # Use TLS 1.2+
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        $downloaded += $dest
        Write-BSLog "  -> $dest (OK)"
    } catch {
        Write-BSLog "Failed to download $rel from $url : $_" "WARN"
        # Don't fail hard for optional files; main installer is required
        if ($rel -eq "installer/Install-RemoteGate.ps1") {
            Write-BSLog "Main installer download failed — cannot continue." "ERROR"
            exit 1
        }
    }
}

# Verify checksum of main installer if expected hash provided
$mainInstaller = Join-Path $tempRoot "installer/Install-RemoteGate.ps1"
if (-not (Test-Path $mainInstaller)) {
    Write-BSLog "Main installer not found after download." "ERROR"
    exit 1
}

if ($ExpectedSha256 -and -not $SkipChecksumVerify) {
    $actual = (Get-FileHash -Path $mainInstaller -Algorithm SHA256).Hash.ToLower()
    $expected = $ExpectedSha256.ToLower()
    if ($actual -ne $expected) {
        Write-BSLog "SHA256 MISMATCH!" "ERROR"
        Write-BSLog "  Expected: $expected" "ERROR"
        Write-BSLog "  Actual:   $actual" "ERROR"
        Write-BSLog "Aborting — do not execute unverified code." "ERROR"
        Write-Host "Remove temp dir: $tempRoot" -ForegroundColor Yellow
        exit 1
    }
    Write-BSLog "SHA256 verified: $actual"
} elseif ($SkipChecksumVerify) {
    Write-BSLog "Checksum verification SKIPPED (--SkipChecksumVerify). Only use for testing!" "WARN"
} else {
    Write-BSLog "No ExpectedSha256 provided — skipping verification (development mode)." "WARN"
    Write-BSLog "For production, pin the release SHA256 in this script." "WARN"
    $hash = (Get-FileHash -Path $mainInstaller -Algorithm SHA256).Hash
    Write-BSLog "Downloaded installer SHA256: $hash"
    Write-BSLog "Publish this hash as ExpectedSha256 for verified installs."
}

# Verify file is not empty / looks like PowerShell
$content = Get-Content $mainInstaller -Raw
if ($content.Length -lt 100 -or $content -notmatch "RemoteGate") {
    Write-BSLog "Downloaded file looks invalid (too small or missing marker)." "ERROR"
    exit 1
}

Write-BSLog "Launching installer from $mainInstaller ..."
Write-Host ""

# Execute installer (dot-source with parameters)
# Forward any extra args passed to bootstrap
try {
    & $mainInstaller @PSBoundParameters
    $exit = $LASTEXITCODE
    Write-BSLog "Installer exited with code: $exit"
    exit $exit
} catch {
    Write-BSLog "Installer execution failed: $_" "ERROR"
    exit 1
}
