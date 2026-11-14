<#
.SYNOPSIS
    RemoteGate — Authenticated HTTPS status reporter.

.DESCRIPTION
    Collects local status and POSTs to Yandex Cloud HTTPS endpoint.
    - Uses HMAC-SHA256 signature over (timestamp.nonce.deviceId.payloadHash)
    - Replay protection via timestamp (±5 min) and nonce (server checks uniqueness)
    - Never sends private keys, passwords, or full authorized_keys
    - Minimal PII — hostname, local IPs, service states, OS version
    - Can be disabled via config: statusReporting.enabled = false

    Triggered by Scheduled Task RemoteGate-Status (every 5 min) or manually.

.PARAMETER ConfigPath
    Path to config.json
.PARAMETER DryRun
    Collect and print payload without sending (for testing).
.PARAMETER RemoteGateRoot
    Root path.

.NOTES
    HMAC secret is read from environment variable REMOTEGATE_HMAC_SECRET or
    from a file at C:\ProgramData\RemoteGate\config\hmac-secret.txt (ACL restricted).
    Never commit the secret to Git. Never log it.
#>
[CmdletBinding()]
param(
    [string]$RemoteGateRoot = "C:\ProgramData\RemoteGate",
    [string]$ConfigPath = "C:\ProgramData\RemoteGate\config\config.json",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StatusLog = "$RemoteGateRoot\logs\status.log"
function Write-StatusLog { param([string]$M,[string]$L="INFO")
    $ts=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line="[$ts] [$L] [Status] $M"
    Write-Host $line -ForegroundColor $(if($L -eq "ERROR"){"Red"}elseif($L -eq "WARN"){"Yellow"}else{"Cyan"})
    try {
        $dir = Split-Path $StatusLog -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $StatusLog -Value $line -Encoding UTF8
    } catch {}
}

Write-StatusLog "Status reporter starting..."

# ── Load config ─────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    Write-StatusLog "Config not found: $ConfigPath — exiting." "WARN"
    exit 0  # Not error — status is optional
}
try { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch {
    Write-StatusLog "Config parse failed: $_" "ERROR"
    exit 1
}

if ($cfg.statusReporting.enabled -eq $false -or $cfg.yandex.statusEnabled -eq $false) {
    Write-StatusLog "Status reporting disabled in config — skipping." "INFO"
    exit 0
}

$endpoint = $cfg.yandex.statusEndpoint
if (-not $endpoint -or $endpoint -match "REPLACE") {
    Write-StatusLog "Status endpoint is placeholder ($endpoint) — skipping (configure yandex.statusEndpoint)." "INFO"
    exit 0
}

# Validate endpoint is HTTPS
if ($endpoint -notmatch "^https://") {
    Write-StatusLog "Status endpoint must be HTTPS: $endpoint" "ERROR"
    exit 1
}

# ── Resolve HMAC secret (never log it) ─────────────────────────────────
$hmacSecret = $null
$envVarName = if ($cfg.statusReporting.hmacSecretEnvVar) { $cfg.statusReporting.hmacSecretEnvVar } else { "REMOTEGATE_HMAC_SECRET" }

if ($env:$envVarName) {
    $hmacSecret = $env:$envVarName
    Write-StatusLog "Using HMAC secret from env var $envVarName"
} else {
    $secretFile = "$RemoteGateRoot\config\hmac-secret.txt"
    if (Test-Path $secretFile) {
        $hmacSecret = (Get-Content $secretFile -Raw).Trim()
        Write-StatusLog "Using HMAC secret from file $secretFile"
    }
}

if (-not $hmacSecret -or $hmacSecret.Length -lt 16) {
    Write-StatusLog "HMAC secret not configured or too short (min 16 chars). Set env var $envVarName or create $RemoteGateRoot\config\hmac-secret.txt" "WARN"
    Write-StatusLog "Skipping status report — see docs/SECURITY.md for setup." "WARN"
    exit 0
}

# ── Collect status payload ────────────────────────────────────────────
Write-StatusLog "Collecting status..."

# Device ID
$deviceId = $null
$deviceIdFile = "$RemoteGateRoot\config\device-id.txt"
if (Test-Path $deviceIdFile) { $deviceId = (Get-Content $deviceIdFile -Raw).Trim() }
if (-not $deviceId) { $deviceId = $cfg.device.deviceId }
if (-not $deviceId -or $deviceId -match "REPLACE") { $deviceId = [guid]::NewGuid().ToString(); Write-StatusLog "Generated ephemeral device ID: $deviceId" "WARN" }

# Hostname / OS
$hostname = $env:COMPUTERNAME
if ($cfg.device.hostname -and $cfg.device.hostname -notmatch "REPLACE") { $hostname = $cfg.device.hostname }
$osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$osVersion = if ($osInfo) { "$($osInfo.Caption) $($osInfo.Version) Build $($osInfo.BuildNumber)" } else { "Unknown" }

# Current user (who owns the tunnel task — SYSTEM, but record interactive user if any)
$currentUser = $env:USERNAME
if (-not $currentUser) { $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }

# Local IPv4 addresses (exclude loopback, link-local)
$localIps = @()
try {
    $addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch "^127\." -and $_.IPAddress -notmatch "^169\.254\." }
    $localIps = @($addrs | Select-Object -ExpandProperty IPAddress)
    if (-not $localIps) { $localIps = @() }
} catch { Write-StatusLog "Could not collect IPs: $_" "WARN" }

# SSH service status
$sshStatus = "unknown"
$sshStartType = "unknown"
try {
    $svc = Get-Service -Name sshd -ErrorAction Stop
    $sshStatus = $svc.Status.ToString()
    $sshStartType = $svc.StartType.ToString()
} catch { $sshStatus = "not_installed" }

# Tunnel status (check scheduled task + process)
$tunnelStatus = "unknown"
$tunnelLastRun = $null
try {
    $task = Get-ScheduledTask -TaskName "RemoteGate-Tunnel" -TaskPath "\RemoteGate\" -ErrorAction SilentlyContinue
    if (-not $task) { $task = Get-ScheduledTask -TaskName "RemoteGate-Tunnel" -ErrorAction SilentlyContinue }
    if ($task) {
        $tunnelStatus = $task.State.ToString()  # Ready, Running, etc.
        $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        if ($info) {
            $tunnelStatus = if ($info.LastTaskResult -eq 0) { "running" } else { "last_exit_$($info.LastTaskResult)" }
            $tunnelLastRun = $info.LastRunTime.ToString("o")
        }
    } else {
        $tunnelStatus = "not_configured"
    }
    # Also check if ssh.exe tunnel process is actually alive
    $tunnelProcs = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*127.0.0.1*" }
    if ($tunnelProcs) { $tunnelStatus = "running (ssh PID $($tunnelProcs.ProcessId))" }
} catch { $tunnelStatus = "error: $_" }

# Build payload (minimal, no secrets)
$payload = @{
    deviceId       = $deviceId
    hostname       = if ($cfg.statusReporting.includeHostname -ne $false) { $hostname } else { $null }
    username       = $currentUser  # Windows username, not password
    localIps       = if ($cfg.statusReporting.includeLocalIps -ne $false) { $localIps } else { @() }
    osVersion      = $osVersion
    sshStatus      = $sshStatus
    sshStartType   = $sshStartType
    tunnelStatus   = $tunnelStatus
    tunnelLastRun  = $tunnelLastRun
    timestamp      = (Get-Date).ToUniversalTime().ToString("o")
    version        = "1.0.0"
}

# Remove nulls
$payload = $payload.GetEnumerator() | Where-Object { $null -ne $_.Value } | ForEach-Object { $h=@{} } { $h[$_.Key]=$_.Value } { $h }
# Actually build clean hashtable
$clean = @{}
foreach ($k in @("deviceId","hostname","username","localIps","osVersion","sshStatus","sshStartType","tunnelStatus","tunnelLastRun","timestamp","version")) {
    if ($payload.ContainsKey($k)) { $clean[$k] = $payload[$k] }
}
# But localIps may be array — ensure it's serialized
$payloadJson = $clean | ConvertTo-Json -Compress -Depth 4
Write-StatusLog "Payload: $payloadJson"

if ($DryRun) {
    Write-Host "`n[DRY RUN] Would POST to $endpoint" -ForegroundColor Cyan
    Write-Host $payloadJson -ForegroundColor White
    exit 0
}

# ── Sign request (HMAC-SHA256) ────────────────────────────────────────
# Signature base: timestamp.nonce.deviceId.sha256(payloadJson)
$timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
$nonce = [guid]::NewGuid().ToString("N").Substring(0,16)
$payloadHash = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
).Replace("-","").ToLower()

$signingString = "$timestamp.$nonce.$deviceId.$payloadHash"
Write-StatusLog "Signing string: $timestamp.$nonce.$deviceId.$payloadHash (payload hash, not secret)"

try {
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($hmacSecret)
    $sigBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($signingString))
    $signature = [Convert]::ToBase64String($sigBytes)
    $hmac.Dispose()
} catch {
    Write-StatusLog "HMAC computation failed: $_" "ERROR"
    exit 1
}

# Zero out secret variable ASAP (best effort)
$hmacSecret = $null

# ── Send HTTPS POST ────────────────────────────────────────────────────
Write-StatusLog "POST $endpoint (device $deviceId, ts $timestamp, nonce $nonce)"

$headers = @{
    "X-RemoteGate-DeviceId"  = $deviceId
    "X-RemoteGate-Timestamp" = $timestamp
    "X-RemoteGate-Nonce"     = $nonce
    "X-RemoteGate-Signature" = $signature
    "Content-Type"           = "application/json"
}

# Enforce TLS 1.2+
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch {}

try {
    $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $payloadJson -TimeoutSec 15 -ErrorAction Stop
    Write-StatusLog "Status reported successfully: $($resp | ConvertTo-Json -Compress)" "INFO"
    # Write heartbeat marker
    Set-Content -Path "$RemoteGateRoot\logs\last-heartbeat.txt" -Value (Get-Date -Format "o") -Encoding UTF8
    exit 0
} catch {
    # Extract status code if available
    $statusCode = $null
    if ($_.Exception.Response) {
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $body = $reader.ReadToEnd()
            Write-StatusLog "Server error ($statusCode): $body" "ERROR"
        } catch {}
    }
    Write-StatusLog "Failed to report status: $_" "ERROR"
    if ($statusCode -eq 401 -or $statusCode -eq 403) {
        Write-StatusLog "Authentication failed — check HMAC secret matches server." "ERROR"
    } elseif ($statusCode -eq 429) {
        Write-StatusLog "Rate limited — backing off." "WARN"
    }
    exit 1
}
