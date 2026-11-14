<#
.SYNOPSIS
    RemoteGate — Windows agent entry point (health check / orchestration).

.DESCRIPTION
    Lightweight agent that:
      - Verifies sshd is running (restarts if needed)
      - Triggers tunnel task if not running
      - Optionally triggers status report
      - Logs to Application event log

    Run via Scheduled Task (RemoteGate-Agent) on schedule or manually.
    Idempotent.

.PARAMETER RemoteGateRoot
    Root path.
.PARAMETER ReportStatus
    Also trigger status report.
.PARAMETER Fix
    Attempt to fix issues (restart sshd, start tunnel task).
#>
[CmdletBinding()]
param(
    [string]$RemoteGateRoot = "C:\ProgramData\RemoteGate",
    [switch]$ReportStatus,
    [switch]$Fix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$LogPath = "$RemoteGateRoot\logs\agent.log"
function Write-AgentLog { param([string]$M,[string]$L="INFO")
    $ts=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line="[$ts] [$L] [Agent] $M"
    Write-Host $line -ForegroundColor $(if($L -eq "ERROR"){"Red"}elseif($L -eq "WARN"){"Yellow"}else{"Cyan"})
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {}
}

Write-AgentLog "Agent check starting..."

# Check sshd
$issues = 0
try {
    $svc = Get-Service -Name sshd -ErrorAction Stop
    Write-AgentLog "sshd: $($svc.Status) / $($svc.StartType)"
    if ($svc.Status -ne "Running") {
        Write-AgentLog "sshd not running!" "WARN"
        $issues++
        if ($Fix) {
            try { Start-Service sshd -ErrorAction Stop; Write-AgentLog "Restarted sshd." } catch { Write-AgentLog "Failed to start sshd: $_" "ERROR" }
        }
    }
    if ($svc.StartType -ne "Automatic") {
        Write-AgentLog "sshd StartupType is $($svc.StartType), expected Automatic" "WARN"
        $issues++
        if ($Fix) { try { Set-Service sshd -StartupType Automatic; Write-AgentLog "Set sshd to Automatic." } catch {} }
    }
} catch {
    Write-AgentLog "sshd service not found: $_" "ERROR"
    $issues++
}

# Check tunnel task
try {
    $task = Get-ScheduledTask -TaskName "RemoteGate-Tunnel" -TaskPath "\RemoteGate\" -ErrorAction SilentlyContinue
    if (-not $task) { $task = Get-ScheduledTask -TaskName "RemoteGate-Tunnel" -ErrorAction SilentlyContinue }
    if (-not $task) {
        Write-AgentLog "Tunnel task not found!" "WARN"
        $issues++
    } else {
        Write-AgentLog "Tunnel task: $($task.TaskName) State=$($task.State)"
        $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        if ($info) { Write-AgentLog "  LastRun=$($info.LastRunTime) Result=0x$($info.LastTaskResult.ToString('X')) Missed=$($info.NumberOfMissedRuns)" }
        # Check if task is ready but ssh process not alive — may need kick
        if ($task.State -eq "Ready" -and $Fix) {
            # If no ssh tunnel process, start task
            $procs = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*127.0.0.1*" }
            if (-not $procs) {
                Write-AgentLog "No tunnel ssh.exe process — starting task..." "WARN"
                Start-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
            }
        }
    }
} catch { Write-AgentLog "Task check: $_" "WARN" }

# Port check
try {
    $listen = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    if ($listen) { Write-AgentLog "sshd listening on 22 (OwningProcess $($listen.OwningProcess))" }
    else { Write-AgentLog "Nothing listening on 22!" "WARN"; $issues++ }
} catch {}

# Status report
if ($ReportStatus) {
    Write-AgentLog "Triggering status report..."
    $statusScript = "$RemoteGateRoot\bin\RemoteGate-Status.ps1"
    if (Test-Path $statusScript) {
        try { & $statusScript -RemoteGateRoot $RemoteGateRoot } catch { Write-AgentLog "Status report failed: $_" "WARN" }
    } else { Write-AgentLog "Status script not found: $statusScript" "WARN" }
}

Write-AgentLog "Agent check finished — issues: $issues"
if ($issues -gt 0 -and -not $Fix) { Write-Host "Run with -Fix to attempt auto-repair: .\RemoteGate-Agent.ps1 -Fix" -ForegroundColor Yellow }
exit $issues
