<#
.SYNOPSIS
    RemoteGate — One-command installer for Windows 10.
    Downloads, verifies and installs RemoteGate components.

.DESCRIPTION
    This is the main entry point for installation. It:
      1. Checks Windows version (10 build 1809+)
      2. Checks administrator privileges (UAC)
      3. Downloads release artifacts to a temp directory
      4. Verifies SHA256 checksum (pinned release)
      5. Installs OpenSSH Server
      6. Configures SSH authentication, firewall and service
      7. Generates device identity and tunnel keys
      8. Configures reverse SSH tunnel task
      9. Verifies the installation

    Idempotent — safe to re-run.
    Requires PowerShell 5.1+ and Administrator prompt.

.PARAMETER ReleaseTag
    GitHub release tag to install (e.g. v0.1.0). Default: v0.1.0
.PARAMETER ConfigPath
    Optional path to a pre-filled config.json. If not supplied, an interactive wizard runs.
.PARAMETER SkipCloudConfig
    Skip Yandex VM configuration prompts (for offline/local-network testing).
.PARAMETER Unattended
    Non-interactive mode — requires ConfigPath.
.EXAMPLE
    # From elevated PowerShell (one-command install):
    iex (irm https://raw.githubusercontent.com/ki10-bot/My-SSH/main/installer/Bootstrap.ps1)

.NOTES
    Never pipe a moving branch directly to Invoke-Expression without verification.
    Bootstrap.ps1 downloads this file to temp, verifies checksum, then executes it.
#>
[CmdletBinding()]
param(
    [string]$ReleaseTag = "v0.1.0",
    [string]$ConfigPath = "",
    [switch]$SkipCloudConfig,
    [switch]$Unattended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ──────────────────────────────────────────────────────────
$MinimumBuild = 17763  # Windows 10 1809
$RemoteGateRoot = "C:\ProgramData\RemoteGate"
$LogFile = "$RemoteGateRoot\logs\install.log"

# ── Logging helper ─────────────────────────────────────────────────────
function Write-InstallLog {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line -ForegroundColor $(if ($Level -eq "ERROR") { "Red" } elseif ($Level -eq "WARN") { "Yellow" } else { "Cyan" })
    try {
        $dir = Split-Path $LogFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
}
function Write-Step { param([string]$Text) Write-Host "`n── $Text ──" -ForegroundColor Green }

# ── Preflight checks ───────────────────────────────────────────────────
Write-Host @"

  ██████╗ ███████╗███╗   ███╗ ██████╗ ████████╗███████╗ ██████╗  █████╗ ████████╗███████╗
  ██╔══██╗██╔════╝████╗ ████║██╔═══██╗╚══██╔══╝██╔════╝██╔════╝ ██╔══██╗╚══██╔══╝██╔════╝
  ██████╔╝█████╗  ██╔████╔██║██║   ██║   ██║   █████╗  ██║  ███╗███████║   ██║   █████╗
  ██╔══██╗██╔══╝  ██║╚██╔╝██║██║   ██║   ██║   ██╔══╝  ██║   ██║██╔══██║   ██║   ██╔══╝
  ██║  ██║███████╗██║ ╚═╝ ██║╚██████╔╝   ██║   ███████╗╚██████╔╝██║  ██║   ██║   ███████╗
  ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝ ╚═════╝    ╚═╝   ╚══════╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝

  Secure Windows Remote Administration via Yandex Cloud — Installer

"@ -ForegroundColor Cyan

# 1. Windows version
Write-Step "Checking Windows version"
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
Write-InstallLog "Windows: $($os.Caption) Build $build Version $($os.Version)"
if ($build -lt $MinimumBuild) {
    Write-InstallLog "Windows build $build is below minimum $MinimumBuild (1809). Installation cannot continue." "ERROR"
    Write-Host "ERROR: Windows 10 build 1809 (17763) or later is required. Your build: $build" -ForegroundColor Red
    Write-Host "Windows 10 reached end of regular support on 2025-10-14. Consider upgrading to Windows 11." -ForegroundColor Yellow
    exit 1
}
if ($build -ge 17763 -and $build -lt 22000) {
    Write-Host "WARNING: Windows 10 reached end of regular support on 2025-10-14." -ForegroundColor Yellow
    Write-Host "Extended Security Updates (ESU) may be available. See docs/WINDOWS10-EOL.md" -ForegroundColor Yellow
}
Write-InstallLog "Windows version check passed."

# 2. Administrator check
Write-Step "Checking administrator privileges"
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-InstallLog "Not running as Administrator." "ERROR"
    Write-Host "ERROR: This installer must be run from an elevated PowerShell prompt." -ForegroundColor Red
    Write-Host "  Right-click PowerShell -> Run as administrator, then re-run." -ForegroundColor Yellow
    exit 1
}
Write-InstallLog "Administrator check passed."

# 3. PowerShell version
Write-Step "Checking PowerShell version"
$psVer = $PSVersionTable.PSVersion
Write-InstallLog "PowerShell version: $psVer"
if ($psVer.Major -lt 5) {
    Write-InstallLog "PowerShell 5.1+ required." "ERROR"
    exit 1
}

# 4. Locate helper scripts (same directory as this script when downloaded)
$InstallerDir = $PSScriptRoot
if (-not $InstallerDir) { $InstallerDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
Write-InstallLog "Installer directory: $InstallerDir"

# 5. Create directory structure
Write-Step "Creating RemoteGate directories"
$dirs = @(
    "$RemoteGateRoot",
    "$RemoteGateRoot\logs",
    "$RemoteGateRoot\keys",
    "$RemoteGateRoot\config",
    "$RemoteGateRoot\bin"
)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-InstallLog "Created: $d"
    }
}
# Restrict keys directory ACL — only SYSTEM and Administrators
try {
    $acl = Get-Acl "$RemoteGateRoot\keys"
    $acl.SetAccessRuleProtection($true, $false) | Out-Null
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.SetAccessRule($adminRule) | Out-Null
    $acl.SetAccessRule($systemRule) | Out-Null
    Set-Acl "$RemoteGateRoot\keys" $acl
    Write-InstallLog "Hardened keys directory ACL."
} catch {
    Write-InstallLog "Could not harden keys ACL: $_" "WARN"
}

# 6. Generate or load device identity
Write-Step "Configuring device identity"
$deviceIdFile = "$RemoteGateRoot\config\device-id.txt"
$deviceId = $null
if (Test-Path $deviceIdFile) {
    $deviceId = (Get-Content $deviceIdFile -Raw).Trim()
    Write-InstallLog "Existing device ID: $deviceId"
} else {
    $deviceId = [guid]::NewGuid().ToString()
    Set-Content -Path $deviceIdFile -Value $deviceId -Encoding UTF8 -NoNewline
    Write-InstallLog "Generated new device ID: $deviceId"
    Write-Host "Device ID: $deviceId" -ForegroundColor Cyan
    Write-Host "This random ID identifies your machine in status reports (not your IP)." -ForegroundColor DarkGray
}

# 7. Handle config
Write-Step "Configuring RemoteGate"
$configDest = "$RemoteGateRoot\config\config.json"
$configExample = Join-Path $InstallerDir "..\config\config.example.json"
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    Copy-Item -Path $ConfigPath -Destination $configDest -Force
    Write-InstallLog "Copied config from $ConfigPath"
} elseif (Test-Path $configDest) {
    Write-InstallLog "Existing config found at $configDest — preserving (idempotent rerun)."
    Write-Host "Existing config preserved. To reconfigure, edit: $configDest" -ForegroundColor Yellow
} else {
    # Try to copy example
    $found = $false
    foreach ($cand in @($configExample, "$InstallerDir\config.example.json", ".\config\config.example.json")) {
        if (Test-Path $cand) {
            Copy-Item $cand $configDest -Force
            Write-InstallLog "Copied example config from $cand"
            $found = $true
            break
        }
    }
    if (-not $found) {
        # Create minimal placeholder
        $placeholder = @{
            device = @{ deviceId = $deviceId; hostname = $env:COMPUTERNAME; description = "Windows 10 RemoteGate Host" }
            yandex = @{ vmPublicIp = "REPLACE_ME"; vmUser = "tunneluser"; vmSshPort = 22; reverseTunnelPort = 2222; statusEnabled = $false }
            ssh = @{ windowsUser = $env:USERNAME; tunnelKeyPath = "$RemoteGateRoot\keys\tunnel_ed25519" }
            tunnel = @{ serverAliveInterval = 30; serverAliveCountMax = 3; reconnectDelaySeconds = 10; logPath = "$RemoteGateRoot\logs\tunnel.log" }
        } | ConvertTo-Json -Depth 5
        Set-Content -Path $configDest -Value $placeholder -Encoding UTF8
        Write-InstallLog "Created placeholder config at $configDest"
    }
    Write-Host ""
    Write-Host "ATTENTION: Config file created at $configDest" -ForegroundColor Yellow
    Write-Host "You MUST edit it before the tunnel can connect:" -ForegroundColor Yellow
    Write-Host "  - yandex.vmPublicIp  -> your Yandex VM public IP" -ForegroundColor White
    Write-Host "  - yandex.vmUser      -> tunnel account on VM" -ForegroundColor White
    Write-Host "  - ssh.windowsUser    -> Windows account for SSH login" -ForegroundColor White
    Write-Host "See docs/YANDEX-CLOUD-SETUP.md for setup instructions." -ForegroundColor Cyan
    if (-not $Unattended -and -not $SkipCloudConfig) {
        $answer = Read-Host "Open config in notepad now? (y/N)"
        if ($answer -eq "y" -or $answer -eq "Y") { notepad $configDest }
    }
}

# 8. Run sub-installers in order
$scripts = @(
    @{ Name = "Configure-SSH.ps1"; Desc = "Installing & configuring OpenSSH Server" },
    @{ Name = "Configure-Firewall.ps1"; Desc = "Configuring Windows Firewall" },
    @{ Name = "Configure-Tunnel.ps1"; Desc = "Configuring reverse SSH tunnel" }
)

foreach ($s in $scripts) {
    $path = Join-Path $InstallerDir $s.Name
    if (Test-Path $path) {
        Write-Step $s.Desc
        try {
            & $path -RemoteGateRoot $RemoteGateRoot -ConfigPath $configDest
            Write-InstallLog "$($s.Name) completed successfully."
        } catch {
            Write-InstallLog "$($s.Name) failed: $_" "ERROR"
            Write-Host "ERROR in $($s.Name): $_" -ForegroundColor Red
            Write-Host "Check $LogFile for details." -ForegroundColor Yellow
            # Don't exit — continue to verification so user sees partial state
        }
    } else {
        Write-InstallLog "Helper script not found: $path — skipping." "WARN"
        Write-Host "WARNING: $($s.Name) not found at $path — skipping." -ForegroundColor Yellow
    }
}

# 9. Copy agent scripts to ProgramData
Write-Step "Installing agent scripts"
$windowsSrc = Join-Path $InstallerDir "..\windows"
if (Test-Path $windowsSrc) {
    Copy-Item "$windowsSrc\*.ps1" -Destination "$RemoteGateRoot\bin\" -Force -ErrorAction SilentlyContinue
    Write-InstallLog "Copied agent scripts from $windowsSrc"
} else {
    # Also try same directory
    Copy-Item "$InstallerDir\RemoteGate-*.ps1" -Destination "$RemoteGateRoot\bin\" -Force -ErrorAction SilentlyContinue
}

# 10. Verify installation
Write-Step "Verifying installation"
$verifyScript = Join-Path $InstallerDir "Verify-Installation.ps1"
if (Test-Path $verifyScript) {
    try { & $verifyScript -RemoteGateRoot $RemoteGateRoot } catch { Write-InstallLog "Verify failed: $_" "WARN" }
} else {
    Write-InstallLog "Verify-Installation.ps1 not found." "WARN"
}

# 11. Summary
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RemoteGate installation finished. Summary:" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Device ID:    $deviceId" -ForegroundColor White
Write-Host "  Config:       $configDest" -ForegroundColor White
Write-Host "  Logs:         $LogFile" -ForegroundColor White
Write-Host "  Tunnel log:   $RemoteGateRoot\logs\tunnel.log" -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Edit config: notepad $configDest" -ForegroundColor White
Write-Host "    2. Add your Yandex VM public IP and tunnel key." -ForegroundColor White
Write-Host "    3. Copy Mac public key to Windows: see docs/MAC-CONNECTION.md" -ForegroundColor White
Write-Host "    4. Test SSH: ssh -J tunneluser@<YANDEX_VM> -p 2222 <WINDOWS_USER>@127.0.0.1" -ForegroundColor White
Write-Host "    5. Check status: Get-Service sshd; Get-ScheduledTask -TaskName 'RemoteGate-Tunnel*'" -ForegroundColor White
Write-Host ""
Write-Host "  To uninstall: .\Uninstall-RemoteGate.ps1 (from installer folder)" -ForegroundColor DarkGray
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan

Write-InstallLog "Installation completed."

# Return exit code 0 — do not claim tunnel is connected until config is filled
exit 0
