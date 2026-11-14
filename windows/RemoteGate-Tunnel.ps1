<#
.SYNOPSIS
    RemoteGate — Persistent reverse SSH tunnel manager.

.DESCRIPTION
    Run by Scheduled Task as SYSTEM at startup/logon.
    Maintains: ssh -N -R 127.0.0.1:<remotePort>:127.0.0.1:22 <user>@<vm>

    Features:
      - Prevents duplicate processes (mutex + process check)
      - Handles host key via known_hosts (StrictHostKeyChecking yes)
      - Keepalives (ServerAliveInterval)
      - Auto-reconnect with exponential backoff
      - Logs connect/disconnect events to C:\ProgramData\RemoteGate\logs\tunnel.log
      - Graceful shutdown on task stop

    Visible — task is \RemoteGate\RemoteGate-Tunnel in Task Scheduler.
    Not hidden. Logs are in ProgramData.

.NOTES
    Run as SYSTEM via Scheduled Task. Do not run as user without testing ACLs on keys.
#>
[CmdletBinding()]
param(
    [string]$RemoteGateRoot = "C:\ProgramData\RemoteGate",
    [string]$ConfigPath = "C:\ProgramData\RemoteGate\config\config.json",
    [int]$MaxIterations = 0  # 0 = infinite (for scheduled task); set for testing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$LogPath = "$RemoteGateRoot\logs\tunnel.log"
$PidFile = "$RemoteGateRoot\logs\tunnel.pid"
$MutexName = "Global\RemoteGate-Tunnel-Mutex"

function Write-TunnelLog {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    # Console for task history / event log visibility
    Write-Host $line
    try {
        $dir = Split-Path $LogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
        # Rotate if > 10 MB
        if ((Get-Item $LogPath -ErrorAction SilentlyContinue).Length -gt 10MB) {
            $arch = "$LogPath.$(Get-Date -Format yyyyMMdd-HHmmss).old"
            Move-Item $LogPath $arch -Force -ErrorAction SilentlyContinue
            Add-Content -Path $LogPath -Value "[$ts] [INFO] Log rotated to $arch" -Encoding UTF8
        }
    } catch {}
    # Also to Windows Event Log if available
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists("RemoteGate")) {
            New-EventLog -LogName Application -Source RemoteGate -ErrorAction SilentlyContinue
        }
        $entryType = switch ($Level) { "ERROR" { "Error" } "WARN" { "Warning" } default { "Information" } }
        Write-EventLog -LogName Application -Source RemoteGate -EntryType $entryType -EventId 1001 -Message $line -ErrorAction SilentlyContinue
    } catch {}
}

Write-TunnelLog "════════════════════════════════════════════════════════"
Write-TunnelLog "RemoteGate-Tunnel starting (PID $PID)"
Write-TunnelLog "RemoteGateRoot=$RemoteGateRoot ConfigPath=$ConfigPath"

# ── Mutex: prevent duplicates (global across sessions) ─────────────────
$mutex = $null
$hasMutex = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $hasMutex = $mutex.WaitOne(1000, $false)
    if (-not $hasMutex) {
        Write-TunnelLog "Another tunnel instance is already running (mutex held) — exiting." "WARN"
        exit 0  # Not error — scheduler will retry later if needed
    }
    Write-TunnelLog "Acquired global mutex: $MutexName"
} catch {
    Write-TunnelLog "Could not acquire mutex, checking processes as fallback: $_" "WARN"
}

# ── Process duplicate check (fallback) ─────────────────────────────────
try {
    $selfPid = $PID
    $all = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*RemoteGate-Tunnel.ps1*" -and $_.ProcessId -ne $selfPid }
    if ($all -and ($all | Measure-Object).Count -gt 0) {
        Write-TunnelLog "Found $($all.Count) other RemoteGate-Tunnel powershell processes — exiting to prevent duplicate tunnel." "WARN"
        foreach ($p in $all) { Write-TunnelLog "  Other PID $($p.ProcessId): $($p.CommandLine)" "WARN" }
        if ($mutex -and $hasMutex) { $mutex.ReleaseMutex() | Out-Null }
        exit 0
    }
} catch { Write-TunnelLog "Process duplicate check failed: $_" "WARN" }

# Write PID file
try { Set-Content -Path $PidFile -Value $PID -Encoding UTF8 } catch {}

# ── Load config ─────────────────────────────────────────────────────────
$config = $null
try {
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-TunnelLog "Failed to load config: $_" "ERROR"
    Write-TunnelLog "Config must contain yandex.vmPublicIp, yandex.vmUser, etc. — exiting." "ERROR"
    if ($mutex -and $hasMutex) { $mutex.ReleaseMutex() | Out-Null }
    exit 1
}

$vmIp = $config.yandex.vmPublicIp
$vmUser = if ($config.yandex.vmUser) { $config.yandex.vmUser } else { "tunneluser" }
$vmPort = if ($config.yandex.vmSshPort) { [int]$config.yandex.vmSshPort } else { 22 }
$remotePort = if ($config.yandex.reverseTunnelPort) { [int]$config.yandex.reverseTunnelPort } else { 2222 }
$keyPath = if ($config.ssh.tunnelKeyPath) { $config.ssh.tunnelKeyPath } else { "$RemoteGateRoot\keys\tunnel_ed25519" }
$serverAliveInterval = if ($config.tunnel.serverAliveInterval) { [int]$config.tunnel.serverAliveInterval } else { 30 }
$serverAliveCountMax = if ($config.tunnel.serverAliveCountMax) { [int]$config.tunnel.serverAliveCountMax } else { 3 }
$reconnectDelay = if ($config.tunnel.reconnectDelaySeconds) { [int]$config.tunnel.reconnectDelaySeconds } else { 10 }
$knownHosts = "$RemoteGateRoot\config\ssh\known_hosts"

if (-not $vmIp -or $vmIp -match "REPLACE" -or $vmIp -eq "REPLACE_ME") {
    Write-TunnelLog "yandex.vmPublicIp is placeholder ($vmIp) — tunnel cannot connect. Fill config.json and restart task." "ERROR"
    Write-TunnelLog "Edit $ConfigPath then run: Start-ScheduledTask -TaskName RemoteGate-Tunnel -TaskPath \RemoteGate\" "INFO"
    if ($mutex -and $hasMutex) { $mutex.ReleaseMutex() | Out-Null }
    exit 1
}
if (-not (Test-Path $keyPath)) {
    Write-TunnelLog "Tunnel key not found: $keyPath — run Configure-Tunnel.ps1 or Install-RemoteGate.ps1" "ERROR"
    if ($mutex -and $hasMutex) { $mutex.ReleaseMutex() | Out-Null }
    exit 1
}

# Validate IP/hostname shape (basic)
if ($vmIp -notmatch "^[a-zA-Z0-9\.\-]+$") {
    Write-TunnelLog "vmPublicIp looks invalid: $vmIp" "ERROR"
    if ($mutex -and $hasMutex) { $mutex.ReleaseMutex() | Out-Null }
    exit 1
}

# ── Locate ssh.exe ──────────────────────────────────────────────────────
$sshExe = (Get-Command ssh -ErrorAction SilentlyContinue).Source
if (-not $sshExe) {
    $sshExe = "C:\Windows\System32\OpenSSH\ssh.exe"
    if (-not (Test-Path $sshExe)) {
        Write-TunnelLog "ssh.exe not found." "ERROR"
        if ($mutex -and $hasMutex) { $mutex.ReleaseMutex() | Out-Null }
        exit 1
    }
}
Write-TunnelLog "ssh.exe: $sshExe"
Write-TunnelLog "Tunnel: 127.0.0.1:$remotePort (on $vmIp) -> 127.0.0.1:22 (local sshd)"
Write-TunnelLog "SSH: $vmUser@$vmIp -p $vmPort -i $keyPath (StrictHostKeyChecking yes, keepalive ${serverAliveInterval}s)"

# Check known_hosts has entry for VM — if not, log guidance instead of failing
if (-not (Test-Path $knownHosts) -or (Get-Content $knownHosts -Raw -ErrorAction SilentlyContinue).Trim().Length -eq 0) {
    Write-TunnelLog "known_hosts is empty/missing: $knownHosts — first connection will fail host key verification." "WARN"
    Write-TunnelLog "To fix, run once as admin: ssh-keyscan -p $vmPort $vmIp >> `"$knownHosts`"" "WARN"
    Write-TunnelLog "Or: ssh -i `"$keyPath`" -p $vmPort ${vmUser}@${vmIp} (type yes to accept)" "WARN"
}

# ── Build SSH args (array for Start-Process) ───────────────────────────
# We use ssh -N -R 127.0.0.1:2222:127.0.0.1:22 -o ... user@host
# Crucial: Bind to 127.0.0.1 only — not 0.0.0.0 (GatewayPorts no on VM should also enforce)
$sshArgsTemplate = @(
    "-N"
    "-R", "127.0.0.1:${remotePort}:127.0.0.1:22"
    "-o", "ServerAliveInterval=$serverAliveInterval"
    "-o", "ServerAliveCountMax=$serverAliveCountMax"
    "-o", "ExitOnForwardFailure=yes"
    "-o", "TCPKeepAlive=yes"
    "-o", "StrictHostKeyChecking=yes"
    "-o", "UserKnownHostsFile=$knownHosts"
    "-o", "IdentitiesOnly=yes"
    "-o", "PasswordAuthentication=no"
    "-o", "BatchMode=yes"
    "-i", $keyPath
    "-p", "$vmPort"
    "${vmUser}@${vmIp}"
)

Write-TunnelLog "SSH command: ssh $($sshArgsTemplate -join ' ')"

# ── Main reconnect loop ────────────────────────────────────────────────
$iteration = 0
$consecutiveFailures = 0
$sshProcess = $null

# Handle graceful shutdown (task stop sends Close)
trap {
    Write-TunnelLog "Trap: $_" "WARN"
    continue
}

try {
    while ($true) {
        $iteration++
        if ($MaxIterations -gt 0 -and $iteration -gt $MaxIterations) {
            Write-TunnelLog "MaxIterations $MaxIterations reached — exiting." "INFO"
            break
        }

        # Check sshd is running locally before tunneling
        $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if (-not $sshd -or $sshd.Status -ne "Running") {
            Write-TunnelLog "sshd not running (status: $($sshd.Status)) — waiting ${reconnectDelay}s before retry." "WARN"
            Start-Sleep -Seconds $reconnectDelay
            continue
        }

        # Optional: quick TCP check that VM is reachable
        # (don't fail hard — ssh will report anyway)
        Write-TunnelLog "Connecting (attempt $iteration, consecutive failures: $consecutiveFailures) ..." "INFO"

        # Launch ssh as child process — it blocks until disconnect
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $sshExe
        $psi.Arguments = ($sshArgsTemplate | ForEach-Object {
            if ($_ -match "[\s`"']") { "`"$_`"" } else { $_ }
        }) -join " "
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = "Hidden"

        $sshProcess = New-Object System.Diagnostics.Process
        $sshProcess.StartInfo = $psi

        # Capture stderr/stdout async
        $stdErr = New-Object System.Text.StringBuilder
        $stdOut = New-Object System.Text.StringBuilder

        $errHandler = {
            param($sender, $e)
            if ($e.Data) { $stdErr.AppendLine($e.Data) | Out-Null }
        }
        $outHandler = {
            param($sender, $e)
            if ($e.Data) { $stdOut.AppendLine($e.Data) | Out-Null }
        }

        # Note: Register-ObjectEvent requires careful cleanup, but for simplicity poll
        $started = $sshProcess.Start()
        if (-not $started) {
            Write-TunnelLog "Failed to start ssh.exe" "ERROR"
            $consecutiveFailures++
            Start-Sleep -Seconds $reconnectDelay
            continue
        }

        Write-TunnelLog "ssh.exe started (PID $($sshProcess.Id)) — tunnel should be establishing..."

        # Wait for process exit (blocking). This is the steady state — tunnel is up while process lives.
        # Poll every 5s so we can log heartbeat.
        $heartbeatInterval = 60  # seconds
        $lastHeartbeat = Get-Date

        while (-not $sshProcess.HasExited) {
            Start-Sleep -Seconds 5
            if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $heartbeatInterval) {
                Write-TunnelLog "Tunnel alive (ssh PID $($sshProcess.Id) up for $([int]((Get-Date)-$sshProcess.StartTime).TotalSeconds)s)" "INFO"
                $lastHeartbeat = Get-Date
            }
        }

        # Process exited — log reason
        $exitCode = $sshProcess.ExitCode
        $stderrText = ""
        try { $stderrText = $sshProcess.StandardError.ReadToEnd() } catch {}
        try { $stdoutText = $sshProcess.StandardOutput.ReadToEnd() } catch {}

        # Normalize exit codes: 0 = clean (task stop), 255 = SSH error, etc.
        if ($exitCode -eq 0) {
            Write-TunnelLog "ssh exited cleanly (code 0) — task may have been stopped. Output: $stdoutText $stderrText" "INFO"
            # If task was stopped intentionally, exit loop gracefully
            # Check if parent task still wants us — if mutex still held, we should reconnect unless clean shutdown
            # For clean stop, the scheduler kills this process — so if we reach here with 0, likely transient
            $consecutiveFailures = 0  # reset on clean-ish
        } else {
            Write-TunnelLog "ssh disconnected (exit code $exitCode). stderr: $stderrText stdout: $stdoutText" "WARN"
            $consecutiveFailures++
        }

        # Exponential backoff: base reconnectDelay, cap at 5 minutes
        $backoff = [math]::Min($reconnectDelay * [math]::Pow(1.5, [math]::Min($consecutiveFailures, 8)), 300)
        # Add jitter 0-5s to avoid thundering herd
        $jitter = Get-Random -Minimum 0 -Maximum 5
        $waitSec = [int]($backoff + $jitter)

        if ($consecutiveFailures -ge 3) {
            Write-TunnelLog "Consecutive failures: $consecutiveFailures — backing off ${waitSec}s before reconnect." "WARN"
        } else {
            Write-TunnelLog "Reconnecting in ${waitSec}s ..." "INFO"
        }

        Start-Sleep -Seconds $waitSec

        # Reset failure count after long uptime (>10 min) — not tracked here, but next success resets
        # Success path resets above
    }
} finally {
    Write-TunnelLog "Tunnel manager exiting (iteration $iteration)." "INFO"
    if ($sshProcess -and -not $sshProcess.HasExited) {
        try {
            Write-TunnelLog "Terminating ssh PID $($sshProcess.Id) ..."
            $sshProcess.Kill()
        } catch {}
    }
    if ($mutex -and $hasMutex) {
        try { $mutex.ReleaseMutex() | Out-Null } catch {}
        $mutex.Dispose()
    }
    try { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue } catch {}
}
