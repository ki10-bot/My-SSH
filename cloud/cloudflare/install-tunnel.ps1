# RemoteGate — Cloudflare Tunnel installer (called by Final template)
param(
    [Parameter(Mandatory=$true)][string]$TunnelToken,
    [string]$TunnelName = "remotegate-ssh",
    [string]$Hostname = "",
    [string]$BinDir = "C:\ProgramData\RemoteGate\bin"
)
$ErrorActionPreference = "Stop"
Write-Host "[cloudflared] Installing to $BinDir" -ForegroundColor Cyan
if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
$exe = Join-Path $BinDir "cloudflared.exe"
# Download if missing
if (-not (Test-Path $exe)) {
    $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
    Write-Host "  Downloading $url -> $exe" -ForegroundColor Gray
    try {
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    } catch {
        # Fallback via bitsadmin
        Start-BitsTransfer -Source $url -Destination $exe
    }
    Write-Host "  Downloaded $( (Get-Item $exe).Length) bytes" -ForegroundColor Green
}
# Stop old service if exists
$svc = Get-Service cloudflared -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "  Stopping old cloudflared service..." -ForegroundColor Yellow
    Stop-Service cloudflared -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    & $exe service uninstall 2>&1 | Out-Null
}
# Install with token
Write-Host "  Installing service with token (len $($TunnelToken.Length))..." -ForegroundColor Cyan
# cloudflared expects token via `service install <token>`
$out = & $exe service install $TunnelToken 2>&1 | Out-String
Write-Host $out
if ($LASTEXITCODE -ne 0 -and $out -notmatch "already installed") {
    Write-Host "  service install failed, trying config file mode..." -ForegroundColor Yellow
    # Alternative: write config.yml and install
    $cfgDir = "$env:ProgramData\cloudflared"
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
    $cfg = @"
tunnel: $TunnelName
credentials-file: $cfgDir\$TunnelName.json
ingress:
  - hostname: $Hostname
    service: ssh://localhost:22
  - service: http_status:404
"@
    $cfg | Set-Content -Path "$cfgDir\config.yml" -Encoding UTF8
    Write-Host "  Wrote $cfgDir\config.yml"
}
Start-Service cloudflared -ErrorAction SilentlyContinue
Start-Sleep 3
$svc2 = Get-Service cloudflared -ErrorAction SilentlyContinue
if ($svc2 -and $svc2.Status -eq "Running") {
    Write-Host "[cloudflared] Service RUNNING" -ForegroundColor Green
    # Show tunnel info
    & $exe tunnel info $TunnelName 2>&1 | Out-String | Write-Host
} else {
    Write-Host "[cloudflared] Service NOT running — check Event Viewer -> Application" -ForegroundColor Red
    Get-WinEvent -LogName Application -MaxEvents 5 | Where-Object Message -match "cloudflared" | Format-List | Out-String | Write-Host
}
