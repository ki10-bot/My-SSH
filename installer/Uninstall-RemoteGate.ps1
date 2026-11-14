<#
.SYNOPSIS
    RemoteGate — Uninstall script.

.DESCRIPTION
    Removes:
      - Scheduled task RemoteGate-Tunnel
      - RemoteGate directories (logs, keys, config, bin) after confirmation
      - Firewall informational rule
      - Optionally stops/disables sshd (with confirmation)

    Does NOT automatically uninstall OpenSSH Server (it's a shared Windows capability).
    Use -RemoveOpenSSH to do so explicitly.

    Requires elevation for task/service removal. Logs actions.

.PARAMETER RemoveOpenSSH
    Also remove OpenSSH Server capability.
.PARAMETER Force
    Skip confirmation prompts.
.PARAMETER KeepKeys
    Do not delete keys directory (so reinstall can reuse).
.PARAMETER RemoteGateRoot
    Root path to remove.

.EXAMPLE
    .\Uninstall-RemoteGate.ps1
    .\Uninstall-RemoteGate.ps1 -Force
    .\Uninstall-RemoteGate.ps1 -RemoveOpenSSH -Force
#>
[CmdletBinding()]
param(
    [switch]$RemoveOpenSSH,
    [switch]$Force,
    [switch]$KeepKeys,
    [string]$RemoteGateRoot = "C:\ProgramData\RemoteGate"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function ULog { param([string]$M,[string]$L="INFO")
    $c = if($L -eq "ERROR"){"Red"}elseif($L -eq "WARN"){"Yellow"}else{"Cyan"}
    Write-Host "[Uninstall] $M" -ForegroundColor $c
}

Write-Host @"

  RemoteGate — Uninstall
  Root: $RemoteGateRoot

"@ -ForegroundColor Yellow

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    ULog "Administrator privileges recommended (task/service removal requires elevation)." "WARN"
    Write-Host "Some steps will fail without elevation. Re-run as Administrator to fully uninstall." -ForegroundColor Yellow
}

if (-not $Force) {
    Write-Host "This will remove:" -ForegroundColor White
    Write-Host "  - Scheduled task: \RemoteGate\RemoteGate-Tunnel" -ForegroundColor White
    Write-Host "  - Directory: $RemoteGateRoot (logs, config, bin$(if($KeepKeys){' (keys kept)'} else {', keys'}))" -ForegroundColor White
    if ($RemoveOpenSSH) { Write-Host "  - OpenSSH Server capability (shared — may affect other SSH uses)" -ForegroundColor Red }
    else { Write-Host "  - sshd service will be stopped/disabled only if you confirm" -ForegroundColor White }
    Write-Host ""
    $ans = Read-Host "Continue? (y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { Write-Host "Cancelled."; exit 0 }
}

# 1. Stop and remove scheduled task
ULog "Removing scheduled tasks..."
foreach ($spec in @(
    @{Name="RemoteGate-Tunnel"; Path="\RemoteGate\"},
    @{Name="RemoteGate-Tunnel"; Path="\"},
    @{Name="RemoteGate Tunnel"; Path="\"},
    @{Name="RemoteGateTunnel"; Path="\"}
)) {
    try {
        $t = Get-ScheduledTask -TaskName $spec.Name -TaskPath $spec.Path -ErrorAction SilentlyContinue
        if ($t) {
            try { Stop-ScheduledTask -TaskName $spec.Name -TaskPath $spec.Path -ErrorAction SilentlyContinue } catch {}
            Unregister-ScheduledTask -TaskName $spec.Name -TaskPath $spec.Path -Confirm:$false -ErrorAction Stop
            ULog "Removed task $($spec.Path)$($spec.Name)"
        }
    } catch { ULog "Could not remove $($spec.Path)$($spec.Name): $_" "WARN" }
}
# Try generic search
try {
    $all = Get-ScheduledTask | Where-Object { $_.TaskName -like "*RemoteGate*" }
    foreach ($t in $all) {
        try {
            Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false
            ULog "Removed task $($t.TaskPath)$($t.TaskName)"
        } catch { ULog "Failed to remove $($t.TaskPath)$($t.TaskName): $_" "WARN" }
    }
} catch {}

# 2. Kill lingering ssh tunnel processes that match RemoteGate config
ULog "Checking for lingering tunnel processes..."
try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*remotegate*" -or $_.CommandLine -like "*$RemoteGateRoot*" }
    foreach ($p in $procs) {
        ULog "Found tunnel ssh.exe PID $($p.ProcessId): $($p.CommandLine)" "WARN"
        if ($Force -or (Read-Host "Kill PID $($p.ProcessId)? (y/N)") -match "^y") {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            ULog "Killed PID $($p.ProcessId)"
        }
    }
    if (-not $procs) { ULog "No lingering RemoteGate ssh.exe processes found." }
} catch { ULog "Process check: $_" "WARN" }

# 3. Firewall informational rule
ULog "Removing informational firewall rule..."
try {
    $r = Get-NetFirewallRule -DisplayName "RemoteGate-Block-Public-SSH" -ErrorAction SilentlyContinue
    if ($r) { Remove-NetFirewallRule -DisplayName "RemoteGate-Block-Public-SSH" -ErrorAction Stop; ULog "Removed RemoteGate-Block-Public-SSH" }
} catch { ULog "Firewall cleanup: $_" "WARN" }
ULog "NOTE: OpenSSH-Server-In-TCP rule is left as-is (shared). Remove manually if desired: Remove-NetFirewallRule -DisplayName 'OpenSSH-Server-In-TCP'"

# 4. sshd service handling
if ($RemoveOpenSSH) {
    ULog "Removing OpenSSH Server capability..."
    try {
        Remove-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction Stop | Out-Null
        ULog "Removed OpenSSH Server."
    } catch { ULog "Failed to remove OpenSSH Server: $_" "ERROR" }
} else {
    # Offer to stop sshd
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($svc) {
        ULog "sshd service is $($svc.Status) / $($svc.StartType) — left running."
        Write-Host "  To stop/disable: Stop-Service sshd; Set-Service sshd -StartupType Disabled" -ForegroundColor DarkGray
        if ($Force) {
            # In force mode, don't auto-stop — too destructive
            ULog "Force mode: leaving sshd running (use -RemoveOpenSSH to uninstall)."
        }
    }
}

# 5. Restore sshd_config backup (optional)
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
$backups = Get-ChildItem "$sshdConfig.remotegate-backup-*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
if ($backups) {
    # Don't auto-restore — just inform
    ULog "sshd_config backups found: $($backups[0].FullName) (most recent)"
    Write-Host "  To restore: Copy-Item '$($backups[0].FullName)' '$sshdConfig' -Force; Restart-Service sshd" -ForegroundColor DarkGray
}

# 6. Remove directories
ULog "Removing RemoteGate data..."
if (Test-Path $RemoteGateRoot) {
    try {
        if ($KeepKeys -and (Test-Path "$RemoteGateRoot\keys")) {
            # Remove everything except keys
            Get-ChildItem $RemoteGateRoot -Exclude "keys" | Remove-Item -Recurse -Force -ErrorAction Stop
            ULog "Removed $RemoteGateRoot contents (keys kept at $RemoteGateRoot\keys)"
        } else {
            Remove-Item -Path $RemoteGateRoot -Recurse -Force -ErrorAction Stop
            ULog "Removed $RemoteGateRoot"
        }
    } catch { ULog "Could not fully remove ${RemoteGateRoot}: $_" "ERROR"; ULog "Try manually: Remove-Item '$RemoteGateRoot' -Recurse -Force" "WARN" }
} else {
    ULog "$RemoteGateRoot not found — nothing to remove."
}

# 7. Remove empty task folder \RemoteGate\ (if no tasks remain)
try {
    $leftover = Get-ScheduledTask -TaskPath "\RemoteGate\" -ErrorAction SilentlyContinue
    if (-not $leftover) { ULog "Task folder \RemoteGate\ is now empty (Windows keeps empty folders — harmless)." }
} catch {}

ULog "Uninstall completed."
Write-Host ""
Write-Host "Checklist:" -ForegroundColor Cyan
Write-Host "  [ ] Task Scheduler — verify no RemoteGate tasks remain (taskschd.msc -> \RemoteGate\)" -ForegroundColor White
Write-Host "  [ ] Services — sshd status: Get-Service sshd" -ForegroundColor White
Write-Host "  [ ] Firewall — Get-NetFirewallRule -DisplayName 'OpenSSH-Server-In-TCP'" -ForegroundColor White
Write-Host "  [ ] Known_hosts — remove Yandex VM entry from $RemoteGateRoot\config\ssh\known_hosts if desired" -ForegroundColor White
Write-Host "  [ ] Yandex Cloud — remove tunnel public key from VM authorized_keys" -ForegroundColor White
Write-Host "  [ ] Delete temp downloads: Remove-Item `$env:TEMP\RemoteGate-* -Recurse -Force" -ForegroundColor White
Write-Host ""
