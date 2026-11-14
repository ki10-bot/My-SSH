<#
.SYNOPSIS
    RemoteGate — Configure Windows OpenSSH Server.

.DESCRIPTION
    Idempotent configuration of the official Windows OpenSSH Server:
      - Installs capability OpenSSH.Server~~~~0.0.1.0 if missing
      - Starts sshd service and sets Automatic startup
      - Configures sshd_config for key-based auth
      - Sets DefaultShell to PowerShell if desired
      - Configures administrators_authorized_keys correctly
      - Verifies service is running

    Must run elevated. Safe to rerun.

.PARAMETER RemoteGateRoot
    Root directory for RemoteGate data (default C:\ProgramData\RemoteGate)
.PARAMETER ConfigPath
    Path to config.json (to read ssh.windowsUser etc.)
#>
[CmdletBinding()]
param(
    [string]$RemoteGateRoot = "C:\ProgramData\RemoteGate",
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LogFile = "$RemoteGateRoot\logs\install.log"
function Write-SSHLog { param([string]$M,[string]$L="INFO")
    $ts=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line="[$ts] [$L] [Configure-SSH] $M"
    Write-Host $line -ForegroundColor $(if($L -eq "ERROR"){"Red"}elseif($L -eq "WARN"){"Yellow"}else{"Cyan"})
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

Write-Host "`n[Configure-SSH] Starting OpenSSH Server configuration..." -ForegroundColor Cyan

# ── Elevation check ────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-SSHLog "Administrator privileges required." "ERROR"
    throw "Configure-SSH.ps1 must run elevated."
}

# ── Load config ────────────────────────────────────────────────────────
$windowsUser = $env:USERNAME
$allowUsers = ""
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.ssh.windowsUser -and $cfg.ssh.windowsUser -ne "REPLACE_WITH_WINDOWS_USERNAME" -and $cfg.ssh.windowsUser -ne "REPLACE_ME") {
            $windowsUser = $cfg.ssh.windowsUser
        }
        if ($cfg.security.allowUsers) { $allowUsers = $cfg.security.allowUsers }
        Write-SSHLog "Config: windowsUser=$windowsUser"
    } catch { Write-SSHLog "Could not parse config: $_" "WARN" }
}

# ── Check Windows capability ───────────────────────────────────────────
$capability = "OpenSSH.Server~~~~0.0.1.0"
Write-SSHLog "Checking capability $capability ..."
try {
    $state = Get-WindowsCapability -Online -Name $capability -ErrorAction Stop
    Write-SSHLog "Capability state: $($state.State)"
    if ($state.State -ne "Installed") {
        Write-Host "[Configure-SSH] Installing OpenSSH Server ... this may take a few minutes." -ForegroundColor Yellow
        Write-SSHLog "Installing $capability ..."
        $result = Add-WindowsCapability -Online -Name $capability -ErrorAction Stop
        Write-SSHLog "Add-WindowsCapability result: RestartNeeded=$($result.RestartNeeded)"
        if ($result.RestartNeeded) {
            Write-SSHLog "Restart required after OpenSSH install." "WARN"
            Write-Host "WARNING: A restart is required before sshd can be used. Please reboot and re-run installer." -ForegroundColor Yellow
        }
    } else {
        Write-SSHLog "OpenSSH Server already installed."
    }
} catch {
    Write-SSHLog "Failed to check/install capability: $_" "ERROR"
    Write-Host "ERROR: Could not install OpenSSH Server. Ensure Windows Update / FoD source is reachable." -ForegroundColor Red
    Write-Host "Details: $_" -ForegroundColor Red
    # Try alternative: Check if sshd already exists (manual install path)
    if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
        Write-SSHLog "sshd service exists despite capability error — continuing." "WARN"
    } else {
        throw
    }
}

# ── Verify sshd service exists ─────────────────────────────────────────
$svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-SSHLog "sshd service not found after installation." "ERROR"
    throw "sshd service not found."
}
Write-SSHLog "sshd service found: Status=$($svc.Status) StartType=$($svc.StartType)"

# ── Configure sshd_config ──────────────────────────────────────────────
$sshdConfig = "$env:ProgramData\ssh\sshd_config"
if (-not (Test-Path $sshdConfig)) {
    # Fallback location for older installs
    $sshdConfig = "C:\ProgramData\ssh\sshd_config"
}
Write-SSHLog "sshd_config path: $sshdConfig"

if (Test-Path $sshdConfig) {
    $backup = "$sshdConfig.remotegate-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item $sshdConfig $backup -Force
    Write-SSHLog "Backed up sshd_config to $backup"

    $content = Get-Content $sshdConfig -Raw

    # Helper to ensure directive exists and is correct
    function Set-SshdDirective {
        param([string]$FileContent, [string]$Directive, [string]$Value)
        $pattern = "(?m)^\s*#?\s*$Directive\s+.*$"
        $replacement = "$Directive $Value"
        if ($FileContent -match $pattern) {
            return [regex]::Replace($FileContent, $pattern, $replacement)
        } else {
            return $FileContent.TrimEnd() + "`r`n$replacement`r`n"
        }
    }

    # Security-hardened settings per project requirements
    $content = Set-SshdDirective $content "PasswordAuthentication" "no"
    $content = Set-SshdDirective $content "PubkeyAuthentication" "yes"
    $content = Set-SshdDirective $content "PermitEmptyPasswords" "no"
    $content = Set-SshdDirective $content "PermitRootLogin" "no"
    $content = Set-SshdDirective $content "X11Forwarding" "no"
    $content = Set-SshdDirective $content "AllowTcpForwarding" "yes"
    $content = Set-SshdDirective $content "GatewayPorts" "no"
    # ChallengeResponse disabled, strict modes enabled
    $content = Set-SshdDirective $content "ChallengeResponseAuthentication" "no"
    $content = Set-SshdDirective $content "UsePrivilegeSeparation" "sandbox"
    $content = Set-SshdDirective $content "StrictModes" "yes"
    $content = Set-SshdDirective $content "MaxAuthTries" "3"
    $content = Set-SshdDirective $content "LoginGraceTime" "60"
    $content = Set-SshdDirective $content "ClientAliveInterval" "30"
    $content = Set-SshdDirective $content "ClientAliveCountMax" "3"

    # Restrict to specific user if configured and not placeholder
    if ($allowUsers -and $allowUsers -ne "REPLACE_WITH_WINDOWS_USERNAME" -and $allowUsers -notmatch "REPLACE") {
        $content = Set-SshdDirective $content "AllowUsers" $allowUsers
        Write-SSHLog "Set AllowUsers $allowUsers"
    } elseif ($windowsUser -and $windowsUser -ne "REPLACE_ME") {
        # Optionally set AllowUsers to windowsUser — commented guidance in config
        # We do NOT force AllowUsers by default to avoid locking out other admins
        Write-SSHLog "AllowUsers not enforced — all valid local users can attempt SSH (restricted by keys)." "WARN"
    }

    # Banner (optional, non-blocking)
    # $content = Set-SshdDirective $content "Banner" "C:\ProgramData\RemoteGate\banner.txt"

    Set-Content -Path $sshdConfig -Value $content -Encoding UTF8
    Write-SSHLog "Updated sshd_config with secure defaults."
    Write-Host "[Configure-SSH] sshd_config hardened (PasswordAuthentication no, PubkeyAuthentication yes)." -ForegroundColor Green
} else {
    Write-SSHLog "sshd_config not found at $sshdConfig — using defaults." "WARN"
}

# ── Set PowerShell as default shell ────────────────────────────────────
Write-SSHLog "Setting PowerShell as default SSH shell..."
try {
    $regPath = "HKLM:\SOFTWARE\OpenSSH"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    $psPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    # Prefer PowerShell 7 if available
    if (Test-Path "C:\Program Files\PowerShell\7\pwsh.exe") {
        $psPath = "C:\Program Files\PowerShell\7\pwsh.exe"
    }
    New-ItemProperty -Path $regPath -Name DefaultShell -Value $psPath -PropertyType String -Force | Out-Null
    Write-SSHLog "DefaultShell set to $psPath"
} catch {
    Write-SSHLog "Could not set DefaultShell: $_" "WARN"
}

# ── Configure authorized_keys ──────────────────────────────────────────
# Windows OpenSSH has special handling for Administrators:
#   Administrators use C:\ProgramData\ssh\administrators_authorized_keys (ACL restricted)
#   Non-admins use %USERPROFILE%\.ssh\authorized_keys
Write-SSHLog "Configuring authorized_keys locations..."

# Ensure .ssh directory for current user (for non-admin case)
$userSshDir = "$env:USERPROFILE\.ssh"
if (-not (Test-Path $userSshDir)) {
    New-Item -ItemType Directory -Path $userSshDir -Force | Out-Null
    Write-SSHLog "Created $userSshDir"
}
$authKeys = Join-Path $userSshDir "authorized_keys"
if (-not (Test-Path $authKeys)) {
    New-Item -ItemType File -Path $authKeys -Force | Out-Null
    Write-SSHLog "Created $authKeys (empty — add your Mac public key per docs/MAC-CONNECTION.md)"
    Set-Content -Path $authKeys -Value "# RemoteGate authorized_keys — add Mac public key(s) here`r`n# Example: ssh-ed25519 AAAAC3... macbook@local`r`n" -Encoding UTF8
}

# Fix ACL on authorized_keys — must NOT be writable by group/others (StrictModes)
try {
    $acl = Get-Acl $authKeys
    $acl.SetAccessRuleProtection($true, $false) | Out-Null
    # Remove inherited rules and add explicit owner-only
    $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($owner, "FullControl", "Allow")
    $acl.SetAccessRule($rule) | Out-Null
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "Allow")
    $acl.SetAccessRule($systemRule) | Out-Null
    Set-Acl $authKeys $acl
    Write-SSHLog "Hardened ACL on $authKeys"
} catch { Write-SSHLog "Could not harden ACL on ${authKeys}: $_" "WARN" }

# If current user is admin, also prepare administrators_authorized_keys
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    $adminKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
    if (-not (Test-Path $adminKeys)) {
        Write-SSHLog "Creating $adminKeys (administrators use this file, not ~/.ssh/authorized_keys)"
        # Copy from user file as starter if it has real keys
        if ((Test-Path $authKeys) -and ((Get-Content $authKeys -Raw).Trim().Length -gt 50)) {
            Copy-Item $authKeys $adminKeys -Force
        } else {
            Set-Content -Path $adminKeys -Value "# RemoteGate administrators_authorized_keys — add Mac public key(s) here`r`n" -Encoding UTF8
        }
    }
    # ACL: only SYSTEM and Administrators, no inheritance — required by sshd
    try {
        $acl = Get-Acl $adminKeys
        $acl.SetAccessRuleProtection($true, $false) | Out-Null
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "Allow")
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "Allow")
        $acl.SetAccessRule($adminRule) | Out-Null
        $acl.SetAccessRule($systemRule) | Out-Null
        Set-Acl $adminKeys $acl
        Write-SSHLog "Hardened ACL on $adminKeys"
        Write-Host "[Configure-SSH] IMPORTANT: Administrator SSH keys go in: $adminKeys" -ForegroundColor Yellow
        Write-Host "  Non-admin keys go in: $authKeys" -ForegroundColor Yellow
    } catch { Write-SSHLog "Could not harden ACL on ${adminKeys}: $_" "WARN" }
}

# ── Start and enable service ───────────────────────────────────────────
Write-SSHLog "Starting sshd service..."
try {
    # Ensure ssh-agent is also available (for key forwarding if needed)
    Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
    Write-SSHLog "Set sshd StartupType to Automatic."

    # Configure recovery: restart on failure (sc failure command)
    try {
        & sc.exe failure sshd reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
        & sc.exe failureflag sshd 1 | Out-Null
        Write-SSHLog "Configured sshd recovery actions (restart on failure)."
    } catch { Write-SSHLog "Could not configure recovery: $_" "WARN" }

    Start-Service -Name sshd -ErrorAction Stop
    # Also ensure ssh-agent is manual (not required but available)
    try { Set-Service -Name ssh-agent -StartupType Manual -ErrorAction SilentlyContinue } catch {}

    $svc = Get-Service -Name sshd
    Write-SSHLog "sshd status: $($svc.Status)"
    if ($svc.Status -ne "Running") {
        Write-SSHLog "sshd not running after start attempt." "ERROR"
        throw "sshd failed to start."
    }
    Write-Host "[Configure-SSH] sshd is running (Automatic startup)." -ForegroundColor Green
} catch {
    Write-SSHLog "Failed to start sshd: $_" "ERROR"
    throw
}

# ── Verify listening ───────────────────────────────────────────────────
Write-SSHLog "Verifying sshd is listening on port 22..."
try {
    $listen = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    if ($listen) {
        Write-SSHLog "sshd listening on port 22: $($listen | Out-String)"
        Write-Host "[Configure-SSH] Verified: sshd listening on TCP 22." -ForegroundColor Green
    } else {
        Write-SSHLog "No listener on port 22 yet — may need a moment or restart." "WARN"
    }
} catch { Write-SSHLog "Could not check port 22: $_" "WARN" }

Write-SSHLog "Configure-SSH completed successfully."
