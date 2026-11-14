<#
.SYNOPSIS
    RemoteGate — Configure reverse SSH tunnel to Yandex Cloud VM.

.DESCRIPTION
    Sets up a persistent outbound reverse tunnel:
      Windows (sshd:22) --[ssh -R 127.0.0.1:2222:127.0.0.1:22]--> Yandex VM

    Uses:
      - Dedicated tunnel key (never Mac's key)
      - Loopback-only binding (127.0.0.1:2222 on VM)
      - Keepalives, auto-reconnect, duplicate prevention
      - Scheduled Task for startup/recovery (visible, documented)
      - Local logging of connect/disconnect events

    Idempotent. Requires OpenSSH Client (ssh.exe).

.PARAMETER RemoteGateRoot
    Root directory.
.PARAMETER ConfigPath
    Path to config.json
#>
[CmdletBinding()]
param(
    [string]$RemoteGateRoot = "C:\ProgramData\RemoteGate",
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LogFile = "$RemoteGateRoot\logs\install.log"
function Write-TunnelLog { param([string]$M,[string]$L="INFO")
    $ts=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line="[$ts] [$L] [Configure-Tunnel] $M"
    Write-Host $line -ForegroundColor $(if($L -eq "ERROR"){"Red"}elseif($L -eq "WARN"){"Yellow"}else{"Cyan"})
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

Write-Host "`n[Configure-Tunnel] Configuring reverse SSH tunnel..." -ForegroundColor Cyan

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-TunnelLog "Administrator required." "ERROR"
    throw "Configure-Tunnel.ps1 must run elevated."
}

# ── Load config ─────────────────────────────────────────────────────────
$vmIp = $null; $vmUser = "tunneluser"; $vmPort = 22; $remotePort = 2222
$serverAliveInterval = 30; $serverAliveCountMax = 3; $reconnectDelay = 10

if ($ConfigPath -and (Test-Path $ConfigPath)) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.yandex.vmPublicIp -and $cfg.yandex.vmPublicIp -notmatch "REPLACE") { $vmIp = $cfg.yandex.vmPublicIp }
        if ($cfg.yandex.vmUser) { $vmUser = $cfg.yandex.vmUser }
        if ($cfg.yandex.vmSshPort) { $vmPort = $cfg.yandex.vmSshPort }
        if ($cfg.yandex.reverseTunnelPort) { $remotePort = $cfg.yandex.reverseTunnelPort }
        if ($cfg.tunnel.serverAliveInterval) { $serverAliveInterval = $cfg.tunnel.serverAliveInterval }
        if ($cfg.tunnel.serverAliveCountMax) { $serverAliveCountMax = $cfg.tunnel.serverAliveCountMax }
        if ($cfg.tunnel.reconnectDelaySeconds) { $reconnectDelay = $cfg.tunnel.reconnectDelaySeconds }
        Write-TunnelLog "Config: vmIp=$vmIp vmUser=$vmUser vmPort=$vmPort remotePort=$remotePort"
    } catch { Write-TunnelLog "Config parse: $_" "WARN" }
} else {
    Write-TunnelLog "No ConfigPath or file missing — using defaults with placeholder IP." "WARN"
}

# ── Check OpenSSH Client ───────────────────────────────────────────────
$sshExe = (Get-Command ssh -ErrorAction SilentlyContinue).Source
if (-not $sshExe) {
    # Try common path
    $sshExe = "C:\Windows\System32\OpenSSH\ssh.exe"
    if (-not (Test-Path $sshExe)) {
        Write-TunnelLog "ssh.exe not found. Installing OpenSSH Client..." "WARN"
        try {
            Add-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0" | Out-Null
            $sshExe = (Get-Command ssh -ErrorAction SilentlyContinue).Source
        } catch {
            Write-TunnelLog "Could not install OpenSSH Client: $_" "ERROR"
            throw "OpenSSH Client required for tunnel."
        }
    }
}
Write-TunnelLog "ssh.exe: $sshExe"

# ── Generate dedicated tunnel key if missing ────────────────────────────
$keyPath = "$RemoteGateRoot\keys\tunnel_ed25519"
$keyPubPath = "$keyPath.pub"

if (-not (Test-Path $keyPath)) {
    Write-TunnelLog "Generating dedicated ED25519 tunnel key at $keyPath ..."
    Write-Host "[Configure-Tunnel] Generating new tunnel key (ED25519, no passphrase)..." -ForegroundColor Yellow
    try {
        # ssh-keygen is included with OpenSSH Client
        $keygen = (Get-Command ssh-keygen -ErrorAction SilentlyContinue).Source
        if (-not $keygen) { $keygen = "C:\Windows\System32\OpenSSH\ssh-keygen.exe" }
        $argsKeygen = @("-t", "ed25519", "-f", $keyPath, "-N", "", "-C", "remotegate-tunnel@$env:COMPUTERNAME")
        $proc = Start-Process -FilePath $keygen -ArgumentList $argsKeygen -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "ssh-keygen exited with $($proc.ExitCode)" }

        # Harden ACL — only SYSTEM and Administrators
        $acl = Get-Acl $keyPath
        $acl.SetAccessRuleProtection($true, $false) | Out-Null
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM","FullControl","Allow")
        $acl.SetAccessRule($adminRule) | Out-Null
        $acl.SetAccessRule($systemRule) | Out-Null
        Set-Acl $keyPath $acl
        # Public key can be more permissive
        if (Test-Path $keyPubPath) {
            Write-TunnelLog "Public key generated: $(Get-Content $keyPubPath -Raw)"
            Write-Host ""
            Write-Host "  === TUNNEL PUBLIC KEY (add to Yandex VM) ===" -ForegroundColor Cyan
            Write-Host "  $(Get-Content $keyPubPath -Raw)" -ForegroundColor White
            Write-Host "  On Yandex VM, append to: /home/$vmUser/.ssh/authorized_keys" -ForegroundColor Yellow
            Write-Host "  See docs/YANDEX-CLOUD-SETUP.md for VM setup." -ForegroundColor Yellow
            Write-Host "  ============================================" -ForegroundColor Cyan
            Write-Host ""
        }
    } catch {
        Write-TunnelLog "Failed to generate tunnel key: $_" "ERROR"
        throw
    }
} else {
    Write-TunnelLog "Tunnel key already exists at $keyPath"
    if (Test-Path $keyPubPath) {
        Write-TunnelLog "Existing public key: $(Get-Content $keyPubPath -Raw)"
    }
}

# ── Create SSH config for tunnel (strict host key checking) ─────────────
$sshConfigDir = "$RemoteGateRoot\config\ssh"
if (-not (Test-Path $sshConfigDir)) { New-Item -ItemType Directory -Path $sshConfigDir -Force | Out-Null }
$sshConfigFile = "$sshConfigDir\tunnel_ssh_config"
# Do NOT disable StrictHostKeyChecking — requirement
$sshConfigContent = @"
# RemoteGate tunnel SSH config — auto-generated, do not edit manually
# Host key verification is ENABLED (StrictHostKeyChecking yes)
Host remotegate-bastion
    HostName $vmIp
    User $vmUser
    Port $vmPort
    IdentityFile $keyPath
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    UserKnownHostsFile $RemoteGateRoot/config/ssh/known_hosts
    ServerAliveInterval $serverAliveInterval
    ServerAliveCountMax $serverAliveCountMax
    ExitOnForwardFailure yes
    TCPKeepAlive yes
    Compression no
    LogLevel INFO
"@
if ($vmIp -and $vmIp -notmatch "REPLACE") {
    Set-Content -Path $sshConfigFile -Value $sshConfigContent -Encoding UTF8
    Write-TunnelLog "Created SSH config at $sshConfigFile"
} else {
    Write-TunnelLog "VM IP is placeholder — SSH config will be updated after config.json is filled." "WARN"
    Set-Content -Path $sshConfigFile -Value $sshConfigContent -Encoding UTF8
}

# Ensure known_hosts file exists
$knownHosts = "$RemoteGateRoot\config\ssh\known_hosts"
if (-not (Test-Path $knownHosts)) { New-Item -ItemType File -Path $knownHosts -Force | Out-Null }

# ── Install agent scripts to bin ────────────────────────────────────────
$binDir = "$RemoteGateRoot\bin"
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

# Locate source scripts
$scriptSourceDir = $null
foreach ($cand in @("$PSScriptRoot\..\windows", "$PSScriptRoot", ".\windows", "$RemoteGateRoot\bin")) {
    if (Test-Path "$cand\RemoteGate-Tunnel.ps1") { $scriptSourceDir = $cand; break }
}
if ($scriptSourceDir) {
    Copy-Item "$scriptSourceDir\RemoteGate-*.ps1" -Destination $binDir -Force -ErrorAction SilentlyContinue
    Write-TunnelLog "Copied agent scripts from $scriptSourceDir to $binDir"
} else {
    Write-TunnelLog "Agent script source not found — will create stub if missing." "WARN"
}

# Ensure RemoteGate-Tunnel.ps1 exists in bin (create if not)
$tunnelScript = "$binDir\RemoteGate-Tunnel.ps1"
if (-not (Test-Path $tunnelScript)) {
    Write-TunnelLog "Creating tunnel script at $tunnelScript ..."
    # Minimal inline fallback — full version should be in windows/RemoteGate-Tunnel.ps1
    $tunnelScriptContent = @'
# RemoteGate Tunnel — fallback stub (full version in repo windows/RemoteGate-Tunnel.ps1)
param()
$ErrorActionPreference = "Stop"
$RemoteGateRoot = "C:\ProgramData\RemoteGate"
$ConfigPath = "$RemoteGateRoot\config\config.json"
$LogPath = "$RemoteGateRoot\logs\tunnel.log"
function WL($m){ $ts=Get-Date -Format "yyyy-MM-dd HH:mm:ss"; $l="[$ts] $m"; Add-Content $LogPath $l -Encoding UTF8; Write-Host $l }
WL "RemoteGate-Tunnel stub invoked — please ensure full windows/RemoteGate-Tunnel.ps1 is present."
'@
    Set-Content -Path $tunnelScript -Value $tunnelScriptContent -Encoding UTF8
}

# ── Create Scheduled Task ──────────────────────────────────────────────
# Visible, documented task — NOT hidden
$taskName = "RemoteGate-Tunnel"
$taskPath = "\RemoteGate\"
$taskDesc = "RemoteGate reverse SSH tunnel to Yandex Cloud bastion. Outbound tunnel forwarding 127.0.0.1:2222 on VM to localhost:22. Visible and removable via Uninstall-RemoteGate.ps1."

Write-TunnelLog "Creating scheduled task: $taskPath$taskName"

# Remove old task if exists (handle migration)
foreach ($oldName in @("RemoteGate-Tunnel", "RemoteGate Tunnel", "RemoteGateTunnel")) {
    $old = Get-ScheduledTask -TaskName $oldName -ErrorAction SilentlyContinue
    if ($old) {
        try { Unregister-ScheduledTask -TaskName $oldName -Confirm:$false -ErrorAction Stop; Write-TunnelLog "Removed old task $oldName" } catch {}
    }
}
# Also check in our path
$existing = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
    Write-TunnelLog "Removed existing task for re-creation."
}

# Action: run PowerShell executing the tunnel script
# Use -ExecutionPolicy Bypass only for this task (not system-wide) and -NoProfile
$psExe = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if (Test-Path "C:\Program Files\PowerShell\7\pwsh.exe") { $psExe = "C:\Program Files\PowerShell\7\pwsh.exe" }

$actionArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tunnelScript`""
$action = New-ScheduledTaskAction -Execute $psExe -Argument $actionArgs

# Triggers: at startup + every 5 minutes (recovery if missed) + on event (network)
$triggerStartup = New-ScheduledTaskTrigger -AtStartup
# Logon trigger as fallback for workstations where startup is unreliable
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn
# Daily trigger is not needed — startup covers it

# Settings: run ASAP if missed, restart on failure, allow start on demand
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 10 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
    -MultipleInstances IgnoreNew `
    -DisallowHardTerminate:$false

# Principal: run as SYSTEM (has necessary privileges, no password needed, not a user account)
# Alternative would be a dedicated service account — SYSTEM is appropriate for a machine-level tunnel
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

try {
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath `
        -Action $action -Trigger @($triggerStartup, $triggerLogon) `
        -Settings $settings -Principal $principal `
        -Description $taskDesc | Out-Null
    Write-TunnelLog "Scheduled task registered: $taskPath$taskName"
    Write-Host "[Configure-Tunnel] Scheduled task created: $taskPath$taskName" -ForegroundColor Green
    Write-Host "  Trigger: At startup + At logon (auto-reconnect)" -ForegroundColor DarkGray
    Write-Host "  User:    NT AUTHORITY\SYSTEM (visible in Task Scheduler)" -ForegroundColor DarkGray
    Write-Host "  Action:  $psExe $actionArgs" -ForegroundColor DarkGray
} catch {
    Write-TunnelLog "Failed to register scheduled task: $_" "ERROR"
    throw
}

# ── Do not auto-start tunnel if VM IP is placeholder ─────────────────────
if (-not $vmIp -or $vmIp -match "REPLACE") {
    Write-Host ""
    Write-Host "[Configure-Tunnel] VM IP not configured — tunnel will not start until config.json is filled." -ForegroundColor Yellow
    Write-Host "  Edit: $ConfigPath" -ForegroundColor White
    Write-Host "  Then run: Start-ScheduledTask -TaskName '$taskName' -TaskPath '$taskPath'" -ForegroundColor White
    Write-TunnelLog "Skipping tunnel start (placeholder VM IP)."
} else {
    Write-TunnelLog "Attempting to start tunnel task..."
    try {
        Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
        Write-Host "[Configure-Tunnel] Tunnel task started. Check logs: $RemoteGateRoot\logs\tunnel.log" -ForegroundColor Green
        Start-Sleep -Seconds 2
        $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
        Write-TunnelLog "Task state: LastRunTime=$($info.LastRunTime) LastTaskResult=$($info.LastTaskResult) NumberOfMissedRuns=$($info.NumberOfMissedRuns)"
    } catch {
        Write-TunnelLog "Could not start task immediately: $_" "WARN"
    }
}

# ── Guidance on first connection ────────────────────────────────────────
Write-Host ""
Write-Host "  First-time Yandex VM connection:" -ForegroundColor Cyan
Write-Host "    1. Connect manually once to accept host key:" -ForegroundColor White
Write-Host "       ssh -i `"$keyPath`" -p $vmPort ${vmUser}@${vmIp}  (type yes)" -ForegroundColor White
Write-Host "    2. Or use ssh-keyscan:" -ForegroundColor White
Write-Host "       ssh-keyscan -p $vmPort $vmIp >> `"$knownHosts`"" -ForegroundColor White
Write-Host "    3. Then start task: Start-ScheduledTask -TaskName '$taskName' -TaskPath '$taskPath'" -ForegroundColor White
Write-Host ""

Write-TunnelLog "Configure-Tunnel completed."
