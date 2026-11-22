<# RemoteGate — Minimal Installer (Relay ssh-j.com) — v2 #>
$ErrorActionPreference="Stop"
$Root="C:\ProgramData\RemoteGate"
$LogFile="$Root\logs\install.log"

function Write-Log {
  param([string]$Message,[string]$Level="INFO")
  $ts=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $safe=$Message -replace [regex]::Escape($Cfg.WindowsPassword),"***"
  $line="[$ts] [$Level] $safe"
  $color=if($Level -eq "ERROR"){"Red"}elseif($Level -eq "WARN"){"Yellow"}else{"Cyan"}
  Write-Host $line -ForegroundColor $color
  try {
    $dir=Split-Path $LogFile -Parent; if(-not (Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
    Add-Content $LogFile $line -Encoding UTF8
  } catch {}
}

$Cfg=@{
  WindowsUser     ="__WINDOWS_USER__"
  WindowsPassword ="__WINDOWS_PASSWORD__"
  RelayHost       ="__RELAY_HOST__"
  RelayUser       ="__RELAY_USER__"
  RelayDevice     ="__RELAY_DEVICE__"
  DeviceId        ="__DEVICE_ID__"
  GenerationTime  ="__GENERATION_TIME__"
  NtfyTopic       ="__NTFY_TOPIC__"
}

function Send-Ntfy {
  param([string]$Status="ok")
  Write-Host "Sende Log an https://ntfy.sh/$($Cfg.NtfyTopic) ..." -ForegroundColor Cyan
  Write-Log "Sende ntfy ($Status) -> https://ntfy.sh/$($Cfg.NtfyTopic)"
  try {
    $installLog=if(Test-Path $LogFile){(Get-Content $LogFile -Raw -ErrorAction SilentlyContinue)}else{"(kein install.log)"}
    $tunnelLogPath="$Root\logs\tunnel.log"
    $tunnelLog=if(Test-Path $tunnelLogPath){(Get-Content $tunnelLogPath -Tail 80 -ErrorAction SilentlyContinue|Out-String)}else{"(kein tunnel.log)"}
    $sysInfo="Host=$env:COMPUTERNAME User=$env:USERNAME DeviceId=$($Cfg.DeviceId) Relay=$($Cfg.RelayUser)@$($Cfg.RelayHost)/$($Cfg.RelayDevice) PassSet=$($Cfg.WindowsPassword -ne 'DEIN_PASSWORT') Time=$($Cfg.GenerationTime) Build=$([int](Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).BuildNumber)"
    $body="$sysInfo`n`n--- install.log ---`n$installLog`n`n--- tunnel.log (last 80) ---`n$tunnelLog"
    if($body.Length -gt 8000){$body=$body.Substring(0,8000)+"...[truncated]"}
    $title=if($Status -eq "fail"){"RemoteGate FAIL $env:COMPUTERNAME"}else{"RemoteGate OK $env:COMPUTERNAME"}
    $headers=@{Title=$title; Tags="computer,remotegate"; Priority=if($Status -eq "fail"){"high"}else{"default"}}
    $uri="https://ntfy.sh/$($Cfg.NtfyTopic)"
    $ok=$false
    # Methode 1: Invoke-RestMethod (PS 5.1+ mit TimeoutSec)
    try{
      Invoke-RestMethod -Uri $uri -Method Post -Body $body -Headers $headers -TimeoutSec 12 -ErrorAction Stop | Out-Null
      $ok=$true
      Write-Host " ntfy OK (Invoke-RestMethod)" -ForegroundColor Green
      Write-Log "ntfy OK via Invoke-RestMethod"
    } catch {
      Write-Log "ntfy IRM fail: $($_.Exception.Message)" "WARN"
      # Methode 2: Invoke-WebRequest Fallback
      try{
        Invoke-WebRequest -Uri $uri -Method Post -Body $body -Headers $headers -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop | Out-Null
        $ok=$true
        Write-Host " ntfy OK (Invoke-WebRequest)" -ForegroundColor Green
        Write-Log "ntfy OK via Invoke-WebRequest"
      } catch {
        Write-Log "ntfy IWR fail: $($_.Exception.Message)" "WARN"
        # Methode 3: curl.exe (Windows 10+ hat curl)
        try{
          $tmpBody="$env:TEMP\ntfy-body.txt"
          Set-Content -Path $tmpBody -Value $body -Encoding UTF8 -Force
          $curlOut=& curl.exe -s -m 15 -H "Title: $title" -H "Tags: computer,remotegate" -H "Priority: $($headers.Priority)" --data-binary "@$tmpBody" $uri 2>&1
          if($LASTEXITCODE -eq 0){ $ok=$true; Write-Host " ntfy OK (curl.exe)" -ForegroundColor Green; Write-Log "ntfy OK via curl.exe" } else { throw $curlOut }
          Remove-Item $tmpBody -Force -ErrorAction SilentlyContinue
        } catch {
          Write-Log "ntfy curl fail: $_" "WARN"
        }
      }
    }
    if(-not $ok){
      Write-Host " ntfy FEHLGESCHLAGEN — prüfe Internet/Firewall" -ForegroundColor Yellow
      Write-Log "ntfy alle Methoden fehlgeschlagen" "WARN"
    } else {
      Write-Host " Prüfe: https://ntfy.sh/$($Cfg.NtfyTopic)" -ForegroundColor Cyan
    }
  } catch {
    Write-Host " ntfy Fehler: $_" -ForegroundColor Red
    Write-Log "ntfy failed: $_" "WARN"
  }
}

trap {
  Write-Host "`n===== FEHLER =====" -ForegroundColor Red
  Write-Host $_ -ForegroundColor Red
  if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace -ForegroundColor Yellow}
  try{Write-Log "FEHLER: $_" "ERROR"}catch{}
  Write-Host "Sende Fehler-Log an ntfy..." -ForegroundColor Yellow
  try{Send-Ntfy "fail"}catch{ Write-Host " ntfy im trap failed: $_" -ForegroundColor Yellow }
  Write-Host "Log: $LogFile" -ForegroundColor Yellow
  Write-Host "Falls ntfy nicht ankam: C:\ProgramData\RemoteGate\logs\install.log manuell prüfen" -ForegroundColor Cyan
  Write-Host "Fenster schliesst in 6 Sekunden..." -ForegroundColor DarkGray
  Start-Sleep 6
  break
}

# Log-Header VOR allem
try {
  New-Item -ItemType Directory -Path "$Root\logs" -Force|Out-Null
  Add-Content $LogFile "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] START $PSCommandPath PID $PID USER $env:USERNAME ADMIN $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) Device $($Cfg.DeviceId)" -Encoding UTF8
} catch {}

Write-Host "RemoteGate Installer — $($Cfg.RelayUser)@$($Cfg.RelayHost) device $($Cfg.RelayDevice) id $($Cfg.DeviceId)" -ForegroundColor Cyan
Write-Host "Log: $LogFile" -ForegroundColor DarkGray

# --- Alte Downloads aufräumen (Spec: wenn schon heruntergeladener Skript da ist, löschen+ersetzen) ---
try {
  # TEMP alte RemoteGate Skripte löschen ausser dem aktuell laufenden
  Get-ChildItem "$env:TEMP\RemoteGate-*.ps1" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $PSCommandPath } | Remove-Item -Force -ErrorAction SilentlyContinue
  Write-Log "Alte TEMP Skripte bereinigt"
} catch {}

# --- Auto-Elevate ---
try {
  $isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if(-not $isAdmin -and $PSCommandPath -and (Test-Path $PSCommandPath)){
    Write-Host "Starte neu als Administrator (UAC)..." -ForegroundColor Yellow
    $psExe="C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    if(Test-Path "C:\Program Files\PowerShell\7\pwsh.exe"){$psExe="C:\Program Files\PowerShell\7\pwsh.exe"}
    Start-Process $psExe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Write-Host "Bitte im UAC auf Ja klicken — dieses Fenster schliesst." -ForegroundColor Cyan
    Start-Sleep 2
    exit 0
  }
  if(-not $isAdmin){
    Write-Log "FEHLER: Bitte als Administrator ausfuehren" "ERROR"
    Write-Host "Ohne Admin kein OpenSSH/Tunnel moeglich." -ForegroundColor Red
    Send-Ntfy "fail"
    Start-Sleep 4
    exit 1
  }
  Write-Log "Admin OK"
} catch {
  Write-Log "Elevate Fehler: $_" "WARN"
}

# --- Windows-Check ---
$os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
$build=[int]$os.BuildNumber
if($build -lt 17763){Write-Log "FEHLER: Windows 10 1809+ noetig Build $build" "ERROR"; Send-Ntfy "fail"; Start-Sleep 3; exit 1}
Write-Log "Windows Build $build OK"

# --- Benutzer ---
if($Cfg.WindowsUser -match "DEIN_BENUTZER|__WINDOWS_USER__" -or -not $Cfg.WindowsUser){
  $Cfg.WindowsUser=$env:USERNAME
  if(-not $Cfg.WindowsUser -or $Cfg.WindowsUser -eq "SYSTEM"){
    try{$logged=(Get-CimInstance Win32_ComputerSystem|Select-Object -ExpandProperty UserName); if($logged -and $logged.Contains("\")){$Cfg.WindowsUser=($logged -split "\\")[-1]}}catch{}
  }
  Write-Log "Benutzer: $($Cfg.WindowsUser)"
}

# --- Verzeichnisse ---
foreach($d in @($Root,"$Root\logs","$Root\keys","$Root\config","$Root\bin")){if(-not (Test-Path $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null}}
$deviceIdFile="$Root\config\device-id.txt"
if(-not (Test-Path $deviceIdFile)){Set-Content -Path $deviceIdFile -Value $Cfg.DeviceId -Encoding UTF8 -NoNewline}
$configDest="$Root\config\config.json"
@{device=@{deviceId=$Cfg.DeviceId; hostname=$env:COMPUTERNAME}; relay=@{host=$Cfg.RelayHost; user=$Cfg.RelayUser; device=$Cfg.RelayDevice; ntfyTopic=$Cfg.NtfyTopic}; ssh=@{windowsUser=$Cfg.WindowsUser}; generatedAt=$Cfg.GenerationTime} | ConvertTo-Json -Depth 4 | Set-Content -Path $configDest -Encoding UTF8
Write-Log "Verzeichnisse + config.json OK"

# --- Passwort (optional) ---
$usePw=$false
if($Cfg.WindowsPassword -and $Cfg.WindowsPassword -ne "DEIN_PASSWORT" -and $Cfg.WindowsPassword.Length -ge 4){$usePw=$true}
if($usePw){
  Write-Host "Setze Passwort fuer $($Cfg.WindowsUser)..." -ForegroundColor Yellow
  try{
    $secPw=ConvertTo-SecureString $Cfg.WindowsPassword -AsPlainText -Force
    try{$null=Get-LocalUser -Name $Cfg.WindowsUser -ErrorAction Stop}catch{
      New-LocalUser -Name $Cfg.WindowsUser -Password $secPw -PasswordNeverExpires|Out-Null
      Add-LocalGroupMember -Group "Users" -Member $Cfg.WindowsUser -ErrorAction SilentlyContinue
      Write-Log "Lokaler Benutzer erstellt"
    }
    try{Set-LocalUser -Name $Cfg.WindowsUser -Password $secPw -ErrorAction Stop; Write-Log "Passwort gesetzt"}catch{
      $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName="net.exe"; $psi.Arguments="user `"$($Cfg.WindowsUser)`" `"$($Cfg.WindowsPassword)`""; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
      $p=[System.Diagnostics.Process]::Start($psi); $p.WaitForExit(); Write-Log "Passwort via net.exe exit $($p.ExitCode)"
    }
    $Cfg.WindowsPassword=$null; $secPw=$null
  }catch{Write-Log "Passwort Fehler: $_" "WARN"}
}

# --- OpenSSH Server ---
Write-Host "Pruefe OpenSSH Server..." -ForegroundColor Green
try{
  $cap="OpenSSH.Server~~~~0.0.1.0"
  $state=(Get-WindowsCapability -Online -Name $cap -ErrorAction Stop).State
  if($state -ne "Installed"){
    Write-Host " Installiere OpenSSH Server (1-2 Min)..." -ForegroundColor Yellow
    Add-WindowsCapability -Online -Name $cap -ErrorAction Stop|Out-Null
    Write-Log "OpenSSH installiert"
  } else {Write-Log "OpenSSH bereits installiert"}
}catch{Write-Log "OpenSSH Check: $($_.Exception.Message)" "WARN"}
$svc=Get-Service sshd -ErrorAction SilentlyContinue
if(-not $svc){Write-Log "FEHLER: sshd nicht gefunden — Neustart noetig?" "ERROR"; Send-Ntfy "fail"; Start-Sleep 4; exit 1}
Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
try{& sc.exe failure sshd reset= 86400 actions= restart/5000|Out-Null; & sc.exe failureflag sshd 1|Out-Null}catch{}
try{Start-Service sshd -ErrorAction SilentlyContinue}catch{}
Write-Log "sshd Status $((Get-Service sshd).Status)"

# sshd_config
$sshdConfig="C:\ProgramData\ssh\sshd_config"
if(Test-Path $sshdConfig){
  Copy-Item $sshdConfig "$sshdConfig.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force -ErrorAction SilentlyContinue
  $content=Get-Content $sshdConfig -Raw
  function Set-Directive{param($FileContent,$Directive,$Value)$pattern="(?m)^\s*#?\s*$Directive\s+.*$"; if($FileContent -match $pattern){return [regex]::Replace($FileContent,$pattern,"$Directive $Value")}else{return $FileContent.TrimEnd()+"`r`n$Directive $Value`r`n"}}
  $content=Set-Directive $content "PubkeyAuthentication" "yes"
  $content=Set-Directive $content "PasswordAuthentication" $(if($usePw){"yes"}else{"no"})
  $content=Set-Directive $content "PermitEmptyPasswords" "no"
  $content=Set-Directive $content "AllowUsers" $Cfg.WindowsUser
  $content=Set-Directive $content "ClientAliveInterval" "30"
  $content=Set-Directive $content "ClientAliveCountMax" "3"
  Set-Content -Path $sshdConfig -Value $content -Encoding UTF8
  Write-Log "sshd_config aktualisiert"
  Restart-Service sshd -Force -ErrorAction SilentlyContinue; Start-Sleep 1
}
# DefaultShell
$regPath="HKLM:\SOFTWARE\OpenSSH"; if(-not (Test-Path $regPath)){New-Item -Path $regPath -Force|Out-Null}
$psPath="C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"; if(Test-Path "C:\Program Files\PowerShell\7\pwsh.exe"){$psPath="C:\Program Files\PowerShell\7\pwsh.exe"}
New-ItemProperty -Path $regPath -Name DefaultShell -Value $psPath -PropertyType String -Force|Out-Null
# Firewall
$rule=Get-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if(-not $rule){New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH-Server-In-TCP" -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any|Out-Null; $rule=Get-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue}
if($rule -and $rule.Enabled -ne "True"){Enable-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue}
Write-Log "Firewall OK"

# --- Relay Tunnel (klassisch ssh -R, stabil) ---
Write-Host "Richte Relay Tunnel ein..." -ForegroundColor Green
$relayHost=$Cfg.RelayHost.Trim(); $relayUser=$Cfg.RelayUser.Trim(); $relayDevice=$Cfg.RelayDevice.Trim()
if(-not $relayDevice){$relayDevice=$env:COMPUTERNAME}

$sshCfgDir="$Root\config\ssh"; if(-not (Test-Path $sshCfgDir)){New-Item -ItemType Directory -Path $sshCfgDir -Force|Out-Null}
$knownHosts="$sshCfgDir\known_hosts"; if(-not (Test-Path $knownHosts)){New-Item -ItemType File -Path $knownHosts -Force|Out-Null}
Write-Log "Hole Host-Key $relayHost ..."
try{& "C:\Windows\System32\OpenSSH\ssh-keyscan.exe" $relayHost 2>$null | Add-Content -Path $knownHosts -Encoding UTF8; Write-Log "Host-Key OK"}catch{Write-Log "ssh-keyscan fehlgeschlagen" "WARN"}

$binDir="$Root\bin"; if(-not (Test-Path $binDir)){New-Item -ItemType Directory -Path $binDir -Force|Out-Null}
$tunnelScript="$binDir\RemoteGate-Tunnel.ps1"

# Minimaler Tunnel-Runner — hidden, Reconnect, kein Blinken
$runner=@'
param([string]$Root="C:\ProgramData\RemoteGate")
$ErrorActionPreference="Continue"
$Log="$Root\logs\tunnel.log"
$CfgPath="$Root\config\config.json"
$Known="$Root\config\ssh\known_hosts"
function WL($m){$ts=Get-Date -Format "yyyy-MM-dd HH:mm:ss"; Add-Content $Log "[$ts] $m" -Encoding UTF8}
WL "Relay start PID $PID"
try{$mutex=New-Object System.Threading.Mutex($false,"Global\RemoteGate-Tunnel"); if(-not $mutex.WaitOne(1000,$false)){WL "Andere Instanz laeuft"; exit 0}}catch{}
try{
  $cfg=Get-Content $CfgPath -Raw | ConvertFrom-Json
  $h=$cfg.relay.host; $u=$cfg.relay.user; $d=$cfg.relay.device
  $sshExe="C:\Windows\System32\OpenSSH\ssh.exe"
  $argsList=@("-N","-R","${d}:22:localhost:22","-o","ServerAliveInterval=30","-o","ServerAliveCountMax=3","-o","ExitOnForwardFailure=yes","-o","StrictHostKeyChecking=yes","-o","UserKnownHostsFile=$Known","-o","BatchMode=yes","${u}@${h}")
  WL "Verbinde $u@$h device $d -> localhost:22"
  $fails=0
  while($true){
    $sshd=Get-Service sshd -ErrorAction SilentlyContinue
    if(-not $sshd -or $sshd.Status -ne "Running"){WL "sshd down, warte"; Start-Sleep 10; continue}
    WL "Versuch..."
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$sshExe; $psi.Arguments=($argsList -join " "); $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.RedirectStandardError=$true; $psi.RedirectStandardOutput=$true
    $proc=[System.Diagnostics.Process]::Start($psi)
    WL "ssh PID $($proc.Id)"
    while(-not $proc.HasExited){Start-Sleep 5}
    $ec=$proc.ExitCode; WL "ssh exit $ec"; $fails++
    $wait=[math]::Min(10 * [math]::Pow(1.5,[math]::Min($fails,8)),300)
    WL "Reconnect in $wait s"; Start-Sleep $wait
  }
} finally {WL "Exit"; try{$mutex.ReleaseMutex()}catch{}}
'@

Set-Content -Path $tunnelScript -Value $runner -Encoding UTF8
Write-Log "Tunnel-Skript erstellt"

# Task: Hidden, RunAs SYSTEM, StartWhenAvailable
$taskName="RemoteGate-Tunnel"; $taskPath="\RemoteGate\"
$psExe="C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"; if(Test-Path "C:\Program Files\PowerShell\7\pwsh.exe"){$psExe="C:\Program Files\PowerShell\7\pwsh.exe"}
$action=New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tunnelScript`""
$triggerStartup=New-ScheduledTaskTrigger -AtStartup
$triggerLogon=New-ScheduledTaskTrigger -AtLogOn
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew -Hidden
$principal=New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
try{Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue}catch{}
Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger @($triggerStartup,$triggerLogon) -Settings $settings -Principal $principal -Description "RemoteGate Relay $relayUser@$relayHost $relayDevice" | Out-Null
Write-Log "Task $taskPath$taskName erstellt"

try{
  Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
  Start-Sleep 2
  $info=Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
  Write-Log "Task gestartet LastRun $($info.LastRunTime) Result $($info.LastTaskResult)"
  Write-Host " Task gestartet — laeuft im Hintergrund" -ForegroundColor Green
}catch{Write-Log "Task Start Warnung: $_" "WARN"}

# --- Fertig: Log + ntfy + Fenster schliessen ---
Write-Host ""
Write-Host "FERTIG — sende Log an ntfy.sh/$($Cfg.NtfyTopic) ..." -ForegroundColor Cyan
Write-Log "Installation fertig — sende ntfy"
try{Send-Ntfy "ok"}catch{Write-Log "Send ntfy Fehler $_" "WARN"}

# Anzeige + Fenster schliesst ERST nach ntfy (Spec) — 5s sichtbar
Write-Host " Log: $LogFile" -ForegroundColor DarkGray
Write-Host " Relay: $relayUser@$relayHost device $relayDevice -> localhost:22" -ForegroundColor White
Write-Host " Auf Mac: ssh -J $relayUser@$relayHost $relayDevice" -ForegroundColor Cyan
Write-Host " Fenster schliesst in 5 Sekunden..." -ForegroundColor DarkGray
Start-Sleep 5
exit 0
