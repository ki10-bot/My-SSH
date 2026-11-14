param([string]$ConfigFile="",[switch]$NonInteractive,[string]$OutputPath="")
$GeneratorDir=$PSScriptRoot; if(-not $GeneratorDir){$GeneratorDir=Split-Path -Parent $MyInvocation.MyCommand.Path}
$RepoRoot=Split-Path -Parent $GeneratorDir
$TemplatePath=Join-Path $RepoRoot "templates\RemoteGate-Deployment.template.ps1"
$DefaultOutput=Join-Path $RepoRoot "dist\RemoteGate-Final.ps1"
if($OutputPath){$DefaultOutput=$OutputPath}
$prefill=@{}
if($ConfigFile -and (Test-Path $ConfigFile)){ try{$prefill=Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable}catch{} }
elseif(Test-Path (Join-Path $GeneratorDir "last-generation.json")){ try{$prefill=Get-Content (Join-Path $GeneratorDir "last-generation.json") -Raw | ConvertFrom-Json -AsHashtable}catch{} }
$WindowsPassword=Read-Host "Passwort"
if(-not $WindowsPassword){$WindowsPassword="DEIN_PASSWORT"}
$RelayUser=Read-Host "Name"
if(-not $RelayUser){$RelayUser="user$(Get-Random -Min 10000 -Max 99999)"}
$RelayUser=$RelayUser.ToLower() -replace '[^a-z0-9]',''
if(-not $RelayUser){$RelayUser="user$(Get-Random -Min 10000 -Max 99999)"}
$WindowsUser="DEIN_BENUTZER"; $RelayHost="ssh-j.com"; $RelayDevice="winpc"; $DeviceId=[guid]::NewGuid().ToString()
if($prefill.DeviceId -and $prefill.DeviceId -notmatch "DEIN_|REPLACE"){ $DeviceId=$prefill.DeviceId }
$GenerationTime=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$tpl=Get-Content $TemplatePath -Raw
$rep=@{"__WINDOWS_USER__"=$WindowsUser; "__WINDOWS_PASSWORD__"=$WindowsPassword; "__RELAY_HOST__"=$RelayHost; "__RELAY_USER__"=$RelayUser; "__RELAY_DEVICE__"=$RelayDevice; "__DEVICE_ID__"=$DeviceId; "__GENERATION_TIME__"=$GenerationTime}
if($rep["__WINDOWS_PASSWORD__"] -ne "DEIN_PASSWORT"){ $rep["__WINDOWS_PASSWORD__"]=$rep["__WINDOWS_PASSWORD__"].Replace('`','``').Replace('"','`"').Replace('$','`$') }
$out=$tpl; foreach($k in $rep.Keys){ $out=$out.Replace($k,$rep[$k]) }
$dir=Split-Path $DefaultOutput -Parent; if(-not (Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
Set-Content -Path $DefaultOutput -Value $out -Encoding UTF8
$config=@{relayUser=$RelayUser; relayHost=$RelayHost; relayDevice=$RelayDevice; deviceId=$DeviceId}
$config | ConvertTo-Json | Set-Content -Path (Join-Path $RepoRoot "control-panel\config.json") -Encoding UTF8
$uploadUrl=""
try{ $uploadUrl=(curl -F "file=@$DefaultOutput" https://0x0.st 2>$null | Select-String "https://0x0.st" | Out-String).Trim() }catch{}
if(-not $uploadUrl){ try{ $j=curl -F "file=@$DefaultOutput" https://file.io 2>$null | ConvertFrom-Json; $uploadUrl=$j.link }catch{} }
if(-not $uploadUrl){ Write-Host "Upload fehlgeschlagen — prüfe Internet, dann nochmal gen.command starten"; exit 1 }
Write-Host "══════════════════════════════════════"
Write-Host "DEIN WINDOWS-BEFEHL:"
Write-Host "powershell -Command ""iwr $uploadUrl -OutFile `$env:TEMP\RemoteGate-Final.ps1; & `$env:TEMP\RemoteGate-Final.ps1"""
Write-Host "══════════════════════════════════════"
