<#
.SYNOPSIS
  RemoteGate Wizard — einfach (nur Passwort + Tunnel)
#>
[CmdletBinding()]param([string]$ConfigFile="",[switch]$NonInteractive,[switch]$SkipUpload,[string]$OutputPath="")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$GeneratorDir=$PSScriptRoot; if(-not $GeneratorDir){$GeneratorDir=Split-Path -Parent $MyInvocation.MyCommand.Path}
$RepoRoot=Split-Path -Parent $GeneratorDir
$TemplatePath=Join-Path $RepoRoot "templates\RemoteGate-Deployment.template.ps1"
$DefaultOutput=Join-Path $RepoRoot "dist\RemoteGate-Final.ps1"
if($OutputPath){$DefaultOutput=$OutputPath}
function WLog{param([string]$m,[string]$l="INFO") $c=if($l -eq "ERROR"){"Red"}elseif($l -eq "WARN"){"Yellow"}else{"Green"}; Write-Host "$m" -ForegroundColor $c}
function Read-Sec{param([string]$Prompt,[switch]$AllowEmpty) $s=Read-Host -Prompt $Prompt -AsSecureString; $p=[Net.NetworkCredential]::new("",$s).Password; if(-not $AllowEmpty -and -not $p){return $null}; return $p }

$prefill=@{}
if($ConfigFile -and (Test-Path $ConfigFile)){ try{$prefill=Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable}catch{} }
elseif(Test-Path (Join-Path $GeneratorDir "last-generation.json")){ try{$prefill=Get-Content (Join-Path $GeneratorDir "last-generation.json") -Raw | ConvertFrom-Json -AsHashtable}catch{} }

$WindowsUser="DEIN_BENUTZER"; $WindowsPassword="DEIN_PASSWORT"; $UsePasswordAuth=$false
$CloudflareTunnelToken=""; $CloudflareHostname=""; $CloudflareTunnelName="remotegate-ssh"
$YandexBucket=""; $CloudProvider="cloudflare"; $CloudEndpoint="https://s3.cloud.ru"
$Hostname=$env:COMPUTERNAME; if(-not $Hostname){$Hostname="WINDOWS-PC"}
$YandexVmIp="CLOUDFLARE_MODE"; $YandexVmUser="cloudflare"; $YandexVmPort=22; $ReverseTunnelPort=2222; $StatusEndpoint=""; $HmacSecret=""; $StatusEnabled=$false

if(-not $NonInteractive){
  Write-Host "`nRemoteGate — einfach" -ForegroundColor Green
  Write-Host "1) Passwort für Windows (verdeckt, Enter wenn keins)" -ForegroundColor White
  while($true){
    $pw=Read-Sec -Prompt "Passwort" -AllowEmpty
    if(-not $pw){ WLog "Kein Passwort — nur Key" "WARN"; $WindowsPassword="DEIN_PASSWORT"; $UsePasswordAuth=$false; break }
    $pw2=Read-Sec -Prompt "Nochmal" -AllowEmpty
    if($pw -ne $pw2){ WLog "Nicht gleich — nochmal" "ERROR"; continue }
    $WindowsPassword=$pw; $UsePasswordAuth=$true; WLog "Passwort ok"; break
  }
  Write-Host "`n2) Cloudflare Tunnel (0 ₽) — Token + Hostname" -ForegroundColor Green
  Write-Host "Wo? dash.cloudflare.com → Zero Trust → Tunnels → Create → Token (eyJh...)" -ForegroundColor DarkGray
  $prefT=if($prefill.CloudflareTunnelToken){$prefill.CloudflareTunnelToken}else{""}
  $inT=Read-Sec -Prompt "Token (eyJh..., Enter=später)" -AllowEmpty
  if($inT){$CloudflareTunnelToken=$inT} elseif($prefT -and $prefT -ne "***"){ $CloudflareTunnelToken=$prefT } else { $CloudflareTunnelToken="DEIN_CLOUDFLARE_TOKEN" }
  $prefH=if($prefill.CloudflareHostname){$prefill.CloudflareHostname}else{""}
  $inH=Read-Host "Hostname (z.B. ssh.deinedomain.ru) [$prefH]"
  if($inH){$CloudflareHostname=$inH} elseif($prefH){$CloudflareHostname=$prefH} else { $CloudflareHostname="DEIN_HOSTNAME" }
  $inN=Read-Host "Tunnel Name [remotegate-ssh]"
  if($inN){$CloudflareTunnelName=$inN}
  $prefB=if($prefill.YandexBucket){$prefill.YandexBucket}elseif($prefill.CloudBucket){$prefill.CloudBucket}else{""}
  $inB=Read-Host "Bucket für Datei (Enter=kein Upload) [$prefB]"
  $YandexBucket=if($inB){$inB} elseif($prefB){$prefB} else {""}
} else {
  $WindowsPassword=if($prefill.WindowsPassword){$prefill.WindowsPassword}else{"DEIN_PASSWORT"}
  $YandexBucket=if($prefill.YandexBucket){$prefill.YandexBucket}else{""}
  $CloudflareTunnelToken=if($prefill.CloudflareTunnelToken){$prefill.CloudflareTunnelToken}else{"DEIN_CLOUDFLARE_TOKEN"}
  $CloudflareHostname=if($prefill.CloudflareHostname){$prefill.CloudflareHostname}else{"DEIN_HOSTNAME"}
  $UsePasswordAuth=($WindowsPassword -ne "DEIN_PASSWORT" -and $WindowsPassword.Length -ge 4)
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
 "__GENERATION_TIME__"=$GenerationTime
}
if($rep["__WINDOWS_PASSWORD__"] -ne "DEIN_PASSWORT"){ $rep["__WINDOWS_PASSWORD__"]=$rep["__WINDOWS_PASSWORD__"].Replace('`','``').Replace('"','`"').Replace('$','`$') }
$out=$tpl; foreach($k in $rep.Keys){ $out=$out.Replace($k,$rep[$k]) }
$dir=Split-Path $DefaultOutput -Parent; if(-not (Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
Set-Content -Path $DefaultOutput -Value $out -Encoding UTF8
WLog "Fertig: $DefaultOutput"
$red=@{YandexBucket=$YandexBucket; CloudProvider=$CloudProvider; CloudflareHostname=$CloudflareHostname; CloudflareTunnelToken="***"; DeviceId=$DeviceId}
$red|ConvertTo-Json|Set-Content -Path (Join-Path $GeneratorDir "last-generation.json") -Encoding UTF8

if(-not $SkipUpload -and $YandexBucket){
  Write-Host "Upload zu $YandexBucket..." -ForegroundColor Cyan
  $up=Join-Path $GeneratorDir "Upload-ToCloud.ps1"; if(Test-Path $up){ try{& $up -FilePath $DefaultOutput -Bucket $YandexBucket -Endpoint $CloudEndpoint}catch{ WLog "Upload Fehler: $_" "ERROR" } }
}
Write-Host "`nFERTIG" -ForegroundColor Green
Write-Host "Datei: $DefaultOutput" -ForegroundColor White
if($YandexBucket){ Write-Host "Link: https://$YandexBucket.s3.cloud.ru/RemoteGate-Final.ps1" -ForegroundColor White }
Write-Host "Windows: iwr LINK -OutFile `$env:TEMP\RemoteGate-Final.ps1; & `$env:TEMP\RemoteGate-Final.ps1" -ForegroundColor Gray
Write-Host "SSH: ssh -o ProxyCommand=`"cloudflared access ssh --hostname %h`" $CloudflareHostname" -ForegroundColor Gray
