<#
.SYNOPSIS
  RemoteGate Wizard — einfach, Relay ssh-j.com Standard (0 ₽, nur SSH)
#>
[CmdletBinding()]param([string]$ConfigFile="",[switch]$NonInteractive,[switch]$SkipUpload,[string]$OutputPath="")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$GeneratorDir=$PSScriptRoot; if(-not $GeneratorDir){$GeneratorDir=Split-Path -Parent $MyInvocation.MyCommand.Path}
$RepoRoot=Split-Path -Parent $GeneratorDir
$TemplatePath=Join-Path $RepoRoot "templates\RemoteGate-Deployment.template.ps1"
$DefaultOutput=Join-Path $RepoRoot "dist\RemoteGate-Final.ps1"
if($OutputPath){$DefaultOutput=$OutputPath}
function WLog{param([string]$m,[string]$l="INFO") $c=if($l -eq "ERROR"){"Red"}else{"Green"}; Write-Host "$m" -ForegroundColor $c}
function Read-Sec{param([string]$Prompt,[switch]$AllowEmpty) $s=Read-Host -Prompt $Prompt -AsSecureString; $p=[Net.NetworkCredential]::new("",$s).Password; if(-not $AllowEmpty -and -not $p){return $null}; return $p }
$prefill=@{}
if($ConfigFile -and (Test-Path $ConfigFile)){ try{$prefill=Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable}catch{} }
elseif(Test-Path (Join-Path $GeneratorDir "last-generation.json")){ try{$prefill=Get-Content (Join-Path $GeneratorDir "last-generation.json") -Raw | ConvertFrom-Json -AsHashtable}catch{} }

$WindowsUser="DEIN_BENUTZER"; $WindowsPassword="DEIN_PASSWORT"; $UsePasswordAuth=$false
$CloudflareTunnelToken="DEIN_CLOUDFLARE_TOKEN"; $CloudflareHostname="DEIN_HOSTNAME"; $CloudflareTunnelName="remotegate-ssh"; $TailscaleAuthKey="DEIN_TAILSCALE_KEY"
$RelayHost="ssh-j.com"; $RelayUser=""; $RelayDevice="winpc"
$YandexBucket=""; $CloudProvider="relay"; $CloudEndpoint="https://s3.cloud.ru"
$Hostname=$env:COMPUTERNAME; if(-not $Hostname){$Hostname="WINDOWS-PC"}
$YandexVmIp="CLOUDFLARE_MODE"; $YandexVmUser="cloudflare"; $YandexVmPort=22; $ReverseTunnelPort=2222; $StatusEndpoint=""; $HmacSecret=""; $StatusEnabled=$false

if(-not $NonInteractive){
  Write-Host "`nRemoteGate — einfach (0 ₽, nur SSH, keine Extra-Software)" -ForegroundColor Green
  Write-Host "1) Passwort für Windows (verdeckt, Enter = nur Key)" -ForegroundColor White
  while($true){
    $pw=Read-Sec -Prompt "Passwort" -AllowEmpty
    if(-not $pw){ WLog "Kein Passwort — nur Key" "WARN"; $WindowsPassword="DEIN_PASSWORT"; $UsePasswordAuth=$false; break }
    $pw2=Read-Sec -Prompt "Nochmal" -AllowEmpty
    if($pw -ne $pw2){ WLog "Nicht gleich — nochmal" "ERROR"; continue }
    $WindowsPassword=$pw; $UsePasswordAuth=$true; WLog "Passwort ok"; break
  }
  Write-Host "`n2) Verbindung — wähle:" -ForegroundColor Green
  Write-Host "   [1] Relay ssh-j.com (0 ₽, keine Karte, nur SSH) ★ empfohlen" -ForegroundColor Cyan
  Write-Host "   [2] VM (Cloud.ru/Yandex, feste IP ~150 ₽)" -ForegroundColor DarkGray
  Write-Host "   [3] Tailscale (0 ₽, braucht Install)  [4] Cloudflare (Domain)" -ForegroundColor DarkGray
  $choice=Read-Host "Wähle [1/2/3/4, Enter=1]"
  if(-not $choice){$choice="1"}
  if($choice -eq "2"){
    $CloudProvider="vm"
    $inIp=Read-Host "VM IP"; if($inIp){$YandexVmIp=$inIp}
    $prefB=if($prefill.YandexBucket){$prefill.YandexBucket}else{""}
    $inB=Read-Host "Bucket [$prefB]"; $YandexBucket=if($inB){$inB}else{$prefB}
  } elseif($choice -eq "3"){
    $CloudProvider="tailscale"
    Write-Host "   → Tailscale: auf Windows + Mac installieren, gleiche E-Mail." -ForegroundColor Green
    $inKey=Read-Sec -Prompt "Auth-Key (optional, Enter = ohne)" -AllowEmpty
    if($inKey){$TailscaleAuthKey=$inKey}
    $prefB=if($prefill.YandexBucket){$prefill.YandexBucket}else{""}
    $inB=Read-Host "Bucket (Enter = per USB) [$prefB]"; $YandexBucket=if($inB){$inB}else{$prefB}
  } elseif($choice -eq "4"){
    $CloudProvider="cloudflare"
    $inT=Read-Sec -Prompt "Token (eyJh..., Enter=später)" -AllowEmpty; if($inT){$CloudflareTunnelToken=$inT}
    $inH=Read-Host "Hostname (ssh.deinedomain.ru)"; if($inH){$CloudflareHostname=$inH}
    $prefB=if($prefill.YandexBucket){$prefill.YandexBucket}else{""}
    $inB=Read-Host "Bucket (Enter=kein Upload) [$prefB]"; $YandexBucket=if($inB){$inB}else{$prefB}
  } else {
    $CloudProvider="relay"
    Write-Host "   → ssh-j.com: gratis, nur SSH, wähle einzigartigen Namen + Gerät." -ForegroundColor Green
    $prefU=if($prefill.RelayUser){$prefill.RelayUser}else{""}
    $prefD=if($prefill.RelayDevice){$prefill.RelayDevice}else{"winpc"}
    $inU=Read-Host "Relay-Nutzer (z.B. alex123456) [$prefU]"; if($inU){$RelayUser=$inU} elseif($prefU){$RelayUser=$prefU} else { $RelayUser="user$(Get-Random -Min 10000 -Max 99999)"; Write-Host "   → auto: $RelayUser (notiere!)" -ForegroundColor Yellow }
    $inD=Read-Host "Gerätename (z.B. winpc) [$prefD]"; $RelayDevice=if($inD){$inD}else{$prefD}
    $prefB=if($prefill.YandexBucket){$prefill.YandexBucket}else{""}
    $inB=Read-Host "Bucket (Enter = per USB) [$prefB]"; $YandexBucket=if($inB){$inB}else{$prefB}
    Write-Host "   → Mac: ssh -J $RelayUser@ssh-j.com $RelayDevice" -ForegroundColor Cyan
  }
} else {
  $WindowsPassword=if($prefill.WindowsPassword){$prefill.WindowsPassword}else{"DEIN_PASSWORT"}
  $YandexBucket=if($prefill.YandexBucket){$prefill.YandexBucket}else{""}
  $RelayUser=if($prefill.RelayUser){$prefill.RelayUser}else{"meinuser"}
  $RelayDevice=if($prefill.RelayDevice){$prefill.RelayDevice}else{"winpc"}
  $TailscaleAuthKey=if($prefill.TailscaleAuthKey){$prefill.TailscaleAuthKey}else{"DEIN_TAILSCALE_KEY"}
  $UsePasswordAuth=($WindowsPassword -ne "DEIN_PASSWORT" -and $WindowsPassword.Length -ge 4)
  $CloudProvider="relay"
}
$DeviceId=[guid]::NewGuid().ToString()
if($prefill.DeviceId -and $prefill.DeviceId -notmatch "DEIN_|REPLACE"){ $DeviceId=$prefill.DeviceId }
$GenerationTime=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "`nErstelle Datei..." -ForegroundColor Cyan
$tpl=Get-Content $TemplatePath -Raw
$rep=@{
 "__WINDOWS_USER__"=$WindowsUser; "__WINDOWS_PASSWORD__"=if($UsePasswordAuth){$WindowsPassword}else{"DEIN_PASSWORT"}
 "__YANDEX_VM_IP__"=$YandexVmIp; "__YANDEX_VM_USER__"=$YandexVmUser; "__YANDEX_VM_PORT__"=$YandexVmPort.ToString()
 "__REVERSE_TUNNEL_PORT__"=$ReverseTunnelPort.ToString(); "__STATUS_ENDPOINT__"=$StatusEndpoint; "__HMAC_SECRET__"=if($HmacSecret){$HmacSecret}else{""}
 "__STATUS_ENABLED__"=if($StatusEnabled){'$true'}else{'$false'}; "__DEVICE_ID__"=$DeviceId; "__HOSTNAME__"=$Hostname
 "__YANDEX_BUCKET__"=$YandexBucket; "__CLOUD_BUCKET__"=$YandexBucket; "__CLOUD_PROVIDER__"=$CloudProvider; "__S3_ENDPOINT__"=$CloudEndpoint
 "__CLOUDFLARE_TUNNEL_TOKEN__"=$CloudflareTunnelToken; "__CLOUDFLARE_HOSTNAME__"=$CloudflareHostname; "__CLOUDFLARE_TUNNEL_NAME__"=$CloudflareTunnelName
 "__TAILSCALE_AUTHKEY__"=$TailscaleAuthKey; "__RELAY_HOST__"=$RelayHost; "__RELAY_USER__"=$RelayUser; "__RELAY_DEVICE__"=$RelayDevice; "__GENERATION_TIME__"=$GenerationTime
}
if($rep["__WINDOWS_PASSWORD__"] -ne "DEIN_PASSWORT"){ $rep["__WINDOWS_PASSWORD__"]=$rep["__WINDOWS_PASSWORD__"].Replace('`','``').Replace('"','`"').Replace('$','`$') }
$out=$tpl; foreach($k in $rep.Keys){ $out=$out.Replace($k,$rep[$k]) }
$dir=Split-Path $DefaultOutput -Parent; if(-not (Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
Set-Content -Path $DefaultOutput -Value $out -Encoding UTF8
WLog "Fertig: $DefaultOutput"
$red=@{YandexBucket=$YandexBucket; CloudProvider=$CloudProvider; RelayUser=$RelayUser; RelayDevice=$RelayDevice; DeviceId=$DeviceId}
$red|ConvertTo-Json|Set-Content -Path (Join-Path $GeneratorDir "last-generation.json") -Encoding UTF8
if(-not $SkipUpload -and $YandexBucket){
  Write-Host "Upload..." -ForegroundColor Cyan
  $up=Join-Path $GeneratorDir "Upload-ToCloud.ps1"; if(Test-Path $up){ try{& $up -FilePath $DefaultOutput -Bucket $YandexBucket -Endpoint $CloudEndpoint}catch{ WLog "Upload Fehler" "ERROR" } }
}
if($CloudProvider -eq "relay"){
  Write-Host "`nFERTIG — Relay ssh-j.com (0 ₽, nur SSH, keine Extra-Software)!" -ForegroundColor Green
  Write-Host "Datei: $DefaultOutput" -ForegroundColor White
  if($YandexBucket){ Write-Host "Link: https://$YandexBucket.s3.cloud.ru/RemoteGate-Final.ps1" -ForegroundColor White }
  Write-Host "Windows: iwr LINK -OutFile `$env:TEMP\RemoteGate-Final.ps1; & `$env:TEMP\RemoteGate-Final.ps1" -ForegroundColor Gray
  Write-Host "Mac: ssh -J $RelayUser@ssh-j.com $RelayDevice  → ssh $WindowsUser@$RelayDevice" -ForegroundColor Cyan
  Write-Host "Kurz: ssh -J $RelayUser@ssh-j.com $WindowsUser@$RelayDevice" -ForegroundColor Green
} else {
  Write-Host "`nFERTIG — nur Passwort, kein Token nötig!" -ForegroundColor Green
  Write-Host "Datei: $DefaultOutput" -ForegroundColor White
  if($YandexBucket){ Write-Host "Link: https://$YandexBucket.s3.cloud.ru/RemoteGate-Final.ps1" -ForegroundColor White }
}
