<#
  RemoteGate Wizard — ultra simple (nur 2 Fragen, sichtbare Eingabe)
#>
param([string]$ConfigFile="",[switch]$NonInteractive,[string]$OutputPath="")
$GeneratorDir=$PSScriptRoot; if(-not $GeneratorDir){$GeneratorDir=Split-Path -Parent $MyInvocation.MyCommand.Path}
$RepoRoot=Split-Path -Parent $GeneratorDir
$TemplatePath=Join-Path $RepoRoot "templates\RemoteGate-Deployment.template.ps1"
$DefaultOutput=Join-Path $RepoRoot "dist\RemoteGate-Final.ps1"
if($OutputPath){$DefaultOutput=$OutputPath}
$prefill=@{}
if($ConfigFile -and (Test-Path $ConfigFile)){ try{$prefill=Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable}catch{} }
elseif(Test-Path (Join-Path $GeneratorDir "last-generation.json")){ try{$prefill=Get-Content (Join-Path $GeneratorDir "last-generation.json") -Raw | ConvertFrom-Json -AsHashtable}catch{} }
$WindowsUser="DEIN_BENUTZER"; $WindowsPassword="DEIN_PASSWORT"; $RelayHost="ssh-j.com"; $RelayDevice="winpc"; $RelayUser=""
if(-not $NonInteractive){
  Write-Host "`nRemoteGate — ultra simple" -ForegroundColor Green
  $WindowsPassword=Read-Host "1) Passwort für Windows"
  if(-not $WindowsPassword){$WindowsPassword="DEIN_PASSWORT"}
  $RelayUser=Read-Host "2) Name (z.B. alex123)"
  if(-not $RelayUser){$RelayUser="user$(Get-Random -Min 10000 -Max 99999)"}
  $RelayUser=$RelayUser.ToLower() -replace '[^a-z0-9]',''
  if(-not $RelayUser){$RelayUser="user$(Get-Random -Min 10000 -Max 99999)"}
} else {
  $WindowsPassword=if($prefill.WindowsPassword){$prefill.WindowsPassword}else{"DEIN_PASSWORT"}
  $RelayUser=if($prefill.RelayUser){$prefill.RelayUser}else{"meinuser"}
}
$UsePasswordAuth=($WindowsPassword -ne "DEIN_PASSWORT")
$DeviceId=[guid]::NewGuid().ToString()
if($prefill.DeviceId -and $prefill.DeviceId -notmatch "DEIN_|REPLACE"){ $DeviceId=$prefill.DeviceId }
$GenerationTime=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$YandexVmIp="CLOUDFLARE_MODE"; $YandexVmUser="cloudflare"; $YandexVmPort=22; $ReverseTunnelPort=2222; $YandexBucket=""; $CloudProvider="relay"; $CloudEndpoint="https://s3.cloud.ru"
$CloudflareTunnelToken="DEIN_CLOUDFLARE_TOKEN"; $CloudflareHostname="DEIN_HOSTNAME"; $CloudflareTunnelName="remotegate-ssh"; $TailscaleAuthKey="DEIN_TAILSCALE_KEY"
$Hostname=$env:COMPUTERNAME; if(-not $Hostname){$Hostname="WINDOWS-PC"}
$tpl=Get-Content $TemplatePath -Raw
$rep=@{"__WINDOWS_USER__"=$WindowsUser; "__WINDOWS_PASSWORD__"=$WindowsPassword; "__YANDEX_VM_IP__"=$YandexVmIp; "__YANDEX_VM_USER__"=$YandexVmUser; "__YANDEX_VM_PORT__"=$YandexVmPort.ToString(); "__REVERSE_TUNNEL_PORT__"=$ReverseTunnelPort.ToString(); "__STATUS_ENDPOINT__"=""; "__HMAC_SECRET__"=""; "__STATUS_ENABLED__"='$false'; "__DEVICE_ID__"=$DeviceId; "__HOSTNAME__"=$Hostname; "__YANDEX_BUCKET__"=$YandexBucket; "__CLOUD_BUCKET__"=$YandexBucket; "__CLOUD_PROVIDER__"=$CloudProvider; "__S3_ENDPOINT__"=$CloudEndpoint; "__CLOUDFLARE_TUNNEL_TOKEN__"=$CloudflareTunnelToken; "__CLOUDFLARE_HOSTNAME__"=$CloudflareHostname; "__CLOUDFLARE_TUNNEL_NAME__"=$CloudflareTunnelName; "__TAILSCALE_AUTHKEY__"=$TailscaleAuthKey; "__RELAY_HOST__"=$RelayHost; "__RELAY_USER__"=$RelayUser; "__RELAY_DEVICE__"=$RelayDevice; "__GENERATION_TIME__"=$GenerationTime}
if($rep["__WINDOWS_PASSWORD__"] -ne "DEIN_PASSWORT"){ $rep["__WINDOWS_PASSWORD__"]=$rep["__WINDOWS_PASSWORD__"].Replace('`','``').Replace('"','`"').Replace('$','`$') }
$out=$tpl; foreach($k in $rep.Keys){ $out=$out.Replace($k,$rep[$k]) }
$dir=Split-Path $DefaultOutput -Parent; if(-not (Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
Set-Content -Path $DefaultOutput -Value $out -Encoding UTF8
Write-Host "`nFertig: $DefaultOutput" -ForegroundColor Cyan
# Upload für Windows-Befehl
$uploadUrl=""
try{ $uploadUrl=(curl -F "file=@$DefaultOutput" https://0x0.st 2>$null | Select-String "https://0x0.st" | Out-String).Trim() }catch{}
if(-not $uploadUrl){ try{ $j=curl -F "file=@$DefaultOutput" https://file.io 2>$null | ConvertFrom-Json; $uploadUrl=$j.link }catch{} }
Write-Host "`n══════════════════════════════════════" -ForegroundColor White
if($uploadUrl){
  Write-Host "FERTIG! Dein Windows-Befehl:" -ForegroundColor Green
  Write-Host "powershell -Command `"iwr $uploadUrl -OutFile `$env:TEMP\RemoteGate-Final.ps1; & `$env:TEMP\RemoteGate-Final.ps1`""
} else {
  Write-Host "FERTIG! Datei: $DefaultOutput (per USB kopieren)" -ForegroundColor Yellow
  Write-Host "Windows: powershell -ExecutionPolicy Bypass -File E:\RemoteGate-Final.ps1"
}
Write-Host "══════════════════════════════════════"
Write-Host "Danach: ssh -J $RelayUser@ssh-j.com $RelayDevice"
