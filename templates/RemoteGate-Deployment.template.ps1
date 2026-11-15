<#
.SYNOPSIS RemoteGate — FINAL Installer (Relay ssh-j.com)
#>

$GeneratedConfig = @{
    WindowsUser     = "__WINDOWS_USER__"
    WindowsPassword = "__WINDOWS_PASSWORD__"
    RelayHost       = "__RELAY_HOST__"
    RelayUser       = "__RELAY_USER__"
    RelayDevice     = "__RELAY_DEVICE__"
    DeviceId        = "__DEVICE_ID__"
    GenerationTime  = "__GENERATION_TIME__"
}

$UsePasswordAuth = $false
if ($GeneratedConfig.WindowsPassword -and $GeneratedConfig.WindowsPassword -ne "DEIN_PASSWORT" -and $GeneratedConfig.WindowsPassword.Length -ge 4) {
    $UsePasswordAuth = $true
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RemoteGateRoot = "C:\ProgramData\RemoteGate"
$LogFile = "$RemoteGateRoot\logs\install.log"

function Write-InstallLog {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $safeMsg = $Message -replace [regex]::Escape($GeneratedConfig.WindowsPassword), "***REDACTED***"
    $line = "[$ts] [$Level] $safeMsg"
    $color = if ($Level -eq "ERROR") { "Red" } elseif ($Level -eq "WARN") { "Yellow" } else { "Cyan" }
    Write-Host $line -ForegroundColor $color
    try {
        $dir = Split-Path $LogFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
}
function Write-Step { param([string]$Text) Write-Host "`n── $Text ──" -ForegroundColor Green }

# Keep window open on error — muss ganz oben stehen, bevor #Requires oder Admin-Checks
trap {
    Write-Host "`nFEHLER: $_" -ForegroundColor Red
    Write-Host "Log: $LogFile" -ForegroundColor Yellow
    Write-Host "Drücke Enter zum Schließen..." -ForegroundColor Yellow
    try { Read-Host | Out-Null } catch {}
    break
}

# Auto-Elevate wenn per Doppelklick / ohne Admin gestartet (Fallback)
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and $PSCommandPath) {
        Write-Host "Starte neu als Administrator (UAC)..." -ForegroundColor Yellow
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
        exit 0
    }
} catch {}

Write-Host @"
  RemoteGate — FINAL Installer
  Device: $($GeneratedConfig.DeviceId)
  User: $($GeneratedConfig.WindowsUser)  Pass: $UsePasswordAuth
  Relay: $($GeneratedConfig.RelayUser)@$($GeneratedConfig.RelayHost) device $($GeneratedConfig.RelayDevice)
"@ -ForegroundColor Cyan

Write-Step "Prüfe Windows (als Admin?)"
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if ($build -lt 17763) { Write-Host "FEHLER: Windows 10 1809+ nötig. Build: $build" -ForegroundColor Red; Read-Host "Enter zum Schließen"; exit 1 }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "FEHLER: Bitte Rechtsklick → Als Administrator ausführen" -ForegroundColor Red
    Write-Host "Ohne Admin kein OpenSSH und kein Tunnel möglich." -ForegroundColor Yellow
    Write-Host "Tipp: Diesen EINEN Befehl in normalem PowerShell einfügen — er fragt automatisch nach Admin:" -ForegroundColor Cyan
    Write-Host "powershell -ExecutionPolicy Bypass -Command `"iwr 'URL' -OutFile `$env:TEMP\RemoteGate-Final.ps1; Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy Bypass -NoExit -File',`$env:TEMP+'\RemoteGate-Final.ps1'`"" -ForegroundColor White
    Read-Host "Enter zum Schließen"
    exit 1
}
Write-Host "  Admin OK" -ForegroundColor Green

if ($GeneratedConfig.WindowsUser -match "__WINDOWS_USER__|DEIN_BENUTZER" -or -not $GeneratedConfig.WindowsUser) {
    $GeneratedConfig.WindowsUser = $env:USERNAME
    if (-not $GeneratedConfig.WindowsUser -or $GeneratedConfig.WindowsUser -eq "SYSTEM") {
        try {
            $logged = (Get-CimInstance Win32_ComputerSystem | Select-Object -ExpandProperty UserName)
            if ($logged -and $logged.Contains("\")) { $GeneratedConfig.WindowsUser = ($logged -split "\\")[-1] }
        } catch {}
    }
    Write-Host "  Benutzer: $($GeneratedConfig.WindowsUser)" -ForegroundColor Green
}

Write-Step "Verzeichnisse"
$dirs = @("$RemoteGateRoot","$RemoteGateRoot\logs","$RemoteGateRoot\keys","$RemoteGateRoot\config","$RemoteGateRoot\bin")
foreach ($d in $dirs) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$deviceIdFile = "$RemoteGateRoot\config\device-id.txt"
if (-not (Test-Path $deviceIdFile)) { Set-Content -Path $deviceIdFile -Value $GeneratedConfig.DeviceId -Encoding UTF8 -NoNewline }

$configDest = "$RemoteGateRoot\config\config.json"
@{
    device = @{ deviceId = $GeneratedConfig.DeviceId; hostname = $env:COMPUTERNAME }
    relay = @{ host = $GeneratedConfig.RelayHost; user = $GeneratedConfig.RelayUser; device = $GeneratedConfig.RelayDevice }
    ssh = @{ windowsUser = $GeneratedConfig.WindowsUser }
} | ConvertTo-Json -Depth 4 | Set-Content -Path $configDest -Encoding UTF8

if ($UsePasswordAuth) {
    Write-Step "Passwort setzen"
    try {
        $secPw = ConvertTo-SecureString $GeneratedConfig.WindowsPassword -AsPlainText -Force
        try { $null = Get-LocalUser -Name $GeneratedConfig.WindowsUser -ErrorAction Stop } catch {
            New-LocalUser -Name $GeneratedConfig.WindowsUser -Password $secPw -PasswordNeverExpires | Out-Null
            Add-LocalGroupMember -Group "Users" -Member $GeneratedConfig.WindowsUser -ErrorAction SilentlyContinue
        }
        try { Set-LocalUser -Name $GeneratedConfig.WindowsUser -Password $secPw -ErrorAction Stop }
        catch {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "net.exe"; $psi.Arguments = "user `"$($GeneratedConfig.WindowsUser)`" `"$($GeneratedConfig.WindowsPassword)`""
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi); $p.WaitForExit()
        }
        Write-Host "  Passwort gesetzt" -ForegroundColor Green
        $GeneratedConfig.WindowsPassword = $null; $secPw = $null
    } catch { Write-Host "  Fehler Passwort: $_" -ForegroundColor Red }
}

Write-Step "OpenSSH installieren (dauert 1-2 Min)"
try {
    $cap = "OpenSSH.Server~~~~0.0.1.0"
    $state = (Get-WindowsCapability -Online -Name $cap -ErrorAction Stop).State
    if ($state -ne "Installed") { 
        Write-Host "  Installiere... bitte warten" -ForegroundColor Yellow
        Add-WindowsCapability -Online -Name $cap -ErrorAction Stop | Out-Null 
        Write-Host "  Installiert" -ForegroundColor Green
    } else { Write-Host "  Bereits installiert" -ForegroundColor Green }
} catch { Write-Host "  Hinweis: $($_.Exception.Message)" -ForegroundColor Yellow }
$svc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $svc) { Write-Host "FEHLER: sshd nicht gefunden nach Install — Neustart nötig?" -ForegroundColor Red; Read-Host "Enter"; exit 1 }
Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
try { & sc.exe failure sshd reset= 86400 actions= restart/5000 | Out-Null; & sc.exe failureflag sshd 1 | Out-Null } catch {}
Start-Service sshd -ErrorAction SilentlyContinue
Write-Host "  sshd: $((Get-Service sshd).Status)" -ForegroundColor Green

$sshdConfig = "C:\ProgramData\ssh\sshd_config"
if (Test-Path $sshdConfig) {
    Copy-Item $sshdConfig "$sshdConfig.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force -ErrorAction SilentlyContinue
    $content = Get-Content $sshdConfig -Raw
    function Set-Directive { param($FileContent,$Directive,$Value)
        $pattern = "(?m)^\s*#?\s*$Directive\s+.*$"
        if ($FileContent -match $pattern) { return [regex]::Replace($FileContent,$pattern,"$Directive $Value") }
        else { return $FileContent.TrimEnd() + "`r`n$Directive $Value`r`n" }
    }
    $content = Set-Directive $content "PubkeyAuthentication" "yes"
    $content = Set-Directive $content "PasswordAuthentication" $(if($UsePasswordAuth){"yes"}else{"no"})
    $content = Set-Directive $content "PermitEmptyPasswords" "no"
    $content = Set-Directive $content "AllowUsers" $GeneratedConfig.WindowsUser
    $content = Set-Directive $content "ClientAliveInterval" "30"
    Set-Content -Path $sshdConfig -Value $content -Encoding UTF8
    Write-Host "  sshd_config aktualisiert" -ForegroundColor Green
}
$regPath = "HKLM:\SOFTWARE\OpenSSH"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
$psPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if (Test-Path "C:\Program Files\PowerShell\7\pwsh.exe") { $psPath = "C:\Program Files\PowerShell\7\pwsh.exe" }
New-ItemProperty -Path $regPath -Name DefaultShell -Value $psPath -PropertyType String -Force | Out-Null

$rule = Get-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if (-not $rule) { New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH-Server-In-TCP" -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null; $rule = Get-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" }
if ($rule.Enabled -ne "True") { Enable-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" }
try { $af = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule; if ($af.RemoteAddress -contains "Any") { Set-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -RemoteAddress LocalSubnet } } catch {}

Write-Step "Relay einrichten (Hintergrund, kein Blinken)"

$relayHost = $GeneratedConfig.RelayHost.Trim()
$relayUser = $GeneratedConfig.RelayUser.Trim()
$relayDevice = $GeneratedConfig.RelayDevice.Trim()
if (-not $relayDevice) { $relayDevice = $env:COMPUTERNAME }

$sshCfgDir = "$RemoteGateRoot\config\ssh"
if (-not (Test-Path $sshCfgDir)) { New-Item -ItemType Directory -Path $sshCfgDir -Force | Out-Null }
$knownHosts = "$sshCfgDir\known_hosts"
if (-not (Test-Path $knownHosts)) { New-Item -ItemType File -Path $knownHosts -Force | Out-Null }
Write-Host "  Host-Key holen..." -ForegroundColor DarkGray
try { & "C:\Windows\System32\OpenSSH\ssh-keyscan.exe" $relayHost 2>$null | Add-Content -Path $knownHosts -Encoding UTF8; Write-Host "  OK" -ForegroundColor Green } catch { Write-Host "  Hinweis: ssh-keyscan fehlgeschlagen" -ForegroundColor Yellow }

$binDir = "$RemoteGateRoot\bin"
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
$tunnelScript = "$binDir\RemoteGate-Tunnel.ps1"

$runner = @'
param([string]$Root="C:\ProgramData\RemoteGate")
$ErrorActionPreference="Continue"
$Log="$Root\logs\tunnel.log"
$CfgPath="$Root\config\config.json"
$Known="$Root\config\ssh\known_hosts"
function WL($m){ $ts=Get-Date -Format "yyyy-MM-dd HH:mm:ss"; $l="[$ts] $m"; Add-Content $Log $l -Encoding UTF8 }
WL "Relay start PID $PID"
try{ $mutex=New-Object System.Threading.Mutex($false,"Global\RemoteGate-Tunnel"); if(-not $mutex.WaitOne(1000,$false)){ WL "Andere Instanz läuft"; exit 0 }}catch{}
try{
  $cfg=Get-Content $CfgPath -Raw | ConvertFrom-Json
  $h=$cfg.relay.host; $u=$cfg.relay.user; $d=$cfg.relay.device
  $sshExe="C:\Windows\System32\OpenSSH\ssh.exe"
  $argsList=@("-N","-R","${d}:22:localhost:22","-o","ServerAliveInterval=30","-o","ServerAliveCountMax=3","-o","ExitOnForwardFailure=yes","-o","StrictHostKeyChecking=yes","-o","UserKnownHostsFile=$Known","-o","BatchMode=yes","${u}@${h}")
  WL "Verbinde $u@$h device $d"
  $fails=0
  while($true){
    $sshd=Get-Service sshd -ErrorAction SilentlyContinue
    if(-not $sshd -or $sshd.Status -ne "Running"){ WL "sshd down, warte"; Start-Sleep 10; continue }
    WL "Versuch..."
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$sshExe
    $psi.Arguments=($argsList -join " ")
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.RedirectStandardError=$true; $psi.RedirectStandardOutput=$true
    $proc=[System.Diagnostics.Process]::Start($psi)
    WL "ssh PID $($proc.Id)"
    while(-not $proc.HasExited){ Start-Sleep 5 }
    $ec=$proc.ExitCode; WL "exit $ec"; $fails++
    $wait=[math]::Min(10 * [math]::Pow(1.5,[math]::Min($fails,8)),300)
    WL "Reconnect in $wait s"; Start-Sleep $wait
  }
} finally { WL "Exit"; try{$mutex.ReleaseMutex()}catch{} }
'@

Set-Content -Path $tunnelScript -Value $runner -Encoding UTF8

# Task: Hintergrund, kein Blinken
$taskName = "RemoteGate-Tunnel"
$taskPath = "\RemoteGate\"
$psExe = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if (Test-Path "C:\Program Files\PowerShell\7\pwsh.exe") { $psExe = "C:\Program Files\PowerShell\7\pwsh.exe" }
$action = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tunnelScript`""
$triggerStartup = New-ScheduledTaskTrigger -AtStartup
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew -Hidden
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
try { Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue } catch {}
Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger @($triggerStartup,$triggerLogon) -Settings $settings -Principal $principal -Description "RemoteGate Relay $relayUser@$relayHost $relayDevice" | Out-Null
Write-Host "  Task erstellt: $taskPath$taskName (Hintergrund, startet nach Neustart)" -ForegroundColor Green

try {
    Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath
    Start-Sleep 3
    $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath
    Write-Host "  Task gestartet (kein Fenster blinkt)" -ForegroundColor Green
    Write-Host "  Letzter Lauf: $($info.LastRunTime) Ergebnis: $($info.LastTaskResult)" -ForegroundColor DarkGray
} catch { Write-Host "  Warnung: Task Start: $_" -ForegroundColor Yellow }

Write-Host ""
Write-Host "══════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  FERTIG! Bitte nicht schließen, 10 Sek warten" -ForegroundColor Green
Start-Sleep 10
# Prüfe Tunnel Log
$log = "$RemoteGateRoot\logs\tunnel.log"
if (Test-Path $log) {
    $last = Get-Content $log -Tail 5 -ErrorAction SilentlyContinue
    if ($last) { Write-Host "  Tunnel Log:" -ForegroundColor DarkGray; $last | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
}
Write-Host ""
Write-Host "  Relay: $relayUser@$relayHost device $relayDevice -> localhost:22" -ForegroundColor White
Write-Host "  Läuft im Hintergrund, nach Neustart automatisch" -ForegroundColor Green
Write-Host "  Prüfen: C:\ProgramData\RemoteGate\logs\install.log" -ForegroundColor DarkGray
Write-Host "══════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Vom Mac: ssh -J $relayUser@ssh-j.com $relayDevice" -ForegroundColor Cyan
Write-Host "       oder: ssh -J $relayUser@ssh-j.com $($GeneratedConfig.WindowsUser)@$relayDevice" -ForegroundColor White
Write-Host ""
Write-Host "Drücke Enter zum Schließen..." -ForegroundColor Yellow
Read-Host | Out-Null
exit 0
