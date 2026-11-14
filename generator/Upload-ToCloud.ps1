<#
.SYNOPSIS
    RemoteGate — Upload final installer to Cloud.ru (default) or Yandex Object Storage.

.DESCRIPTION
    S3-compatible uploader for final installer (dist/RemoteGate-Final.ps1).
    Default: Cloud.ru Evolution (endpoint https://s3.cloud.ru, Free Tier 15 GB).
    Also supports Yandex (endpoint https://storage.yandexcloud.net) via -Endpoint.

    Bucket should be PRIVATE — script contains password.

.PARAMETER FilePath
    Path to local file to upload.

.PARAMETER Bucket
    Destination bucket name (e.g. my-remotegate-bucket).

.PARAMETER Endpoint
    S3 endpoint URL. Default: https://s3.cloud.ru (Cloud.ru). Use https://storage.yandexcloud.net for Yandex.

.PARAMETER ObjectKey
    Object key in bucket (default: RemoteGate-Final.ps1).

.PARAMETER MakePublic
    Make object public-read (WARN: password world-readable).

.PARAMETER PresignHours
    Generate presigned URL valid for N hours (default 168 = 7 days).

.EXAMPLE
    .\generator\Upload-ToCloud.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-bucket
    .\generator\Upload-ToCloud.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-bucket -Endpoint https://storage.yandexcloud.net
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string]$Bucket,
    [string]$Endpoint = "https://s3.cloud.ru",
    [string]$ObjectKey = "RemoteGate-Final.ps1",
    [switch]$MakePublic,
    [int]$PresignHours = 168
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-ULog { param([string]$M,[string]$L="INFO")
    $c = if($L -eq "ERROR"){"Red"}elseif($L -eq "WARN"){"Yellow"}elseif($L -eq "PASS"){"Green"}else{"Cyan"}
    Write-Host "[Upload] $M" -ForegroundColor $c
}

if (-not (Test-Path $FilePath)) { Write-ULog "Datei nicht gefunden: $FilePath" "ERROR"; exit 1 }
$fileSize = (Get-Item $FilePath).Length
$provider = if ($Endpoint -match "storage.yandexcloud.net") { "Yandex" } else { "Cloud.ru" }
Write-ULog "Datei: $FilePath ($fileSize bytes) → $provider bucket: $Bucket / $ObjectKey (endpoint $Endpoint)"

if ($MakePublic) {
    Write-ULog "WARNUNG: -MakePublic — Objekt wird öffentlich lesbar! Passwort für jeden mit URL sichtbar." "WARN"
    Write-Host "  Enter zum Fortfahren, Ctrl+C zum Abbrechen..." -ForegroundColor Yellow
    Read-Host | Out-Null
}

$yc = Get-Command yc -ErrorAction SilentlyContinue
$aws = Get-Command aws -ErrorAction SilentlyContinue
$uploaded = $false

# Try yc only for Yandex endpoint
if ($yc -and $provider -eq "Yandex") {
    Write-ULog "yc CLI gefunden: $($yc.Source) (Yandex)"
    try {
        $bucketList = & yc storage bucket list --format json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        $exists = $false
        if ($bucketList) { foreach ($b in $bucketList) { if ($b.name -eq $Bucket) { $exists = $true; break } } }
        if (-not $exists) {
            Write-ULog "Bucket $Bucket nicht gelistet — versuche Erstellung..."
            $createOut = & yc storage bucket create --name $Bucket --default-storage-class standard 2>&1 | Out-String
            Write-ULog "Create: $createOut"
        }
        $uploadArgs = @("storage", "s3api", "put-object", "--bucket", $Bucket, "--key", $ObjectKey, "--body", $FilePath)
        if ($MakePublic) { $uploadArgs += @("--acl", "public-read") } else { $uploadArgs += @("--acl", "private") }
        $putOut = & yc @uploadArgs 2>&1 | Out-String
        Write-ULog "Put: $putOut"
        if ($LASTEXITCODE -eq 0) { $uploaded = $true; Write-ULog "Upload via yc erfolgreich!" "PASS" } else { throw "yc failed $LASTEXITCODE" }
    } catch { Write-ULog "yc Fehler: $_" "ERROR" }
}

if (-not $uploaded -and $aws) {
    Write-ULog "Versuche AWS CLI mit Endpoint $Endpoint ..."
    try {
        $env:AWS_EC2_METADATA_DISABLED = "true"
        $listArgs = @("s3", "ls", "s3://$Bucket/", "--endpoint-url", $Endpoint)
        Write-ULog "aws s3 ls s3://$Bucket/ --endpoint-url $Endpoint"
        $listOut = & aws @listArgs 2>&1 | Out-String
        Write-ULog "List: $listOut"
        if ($LASTEXITCODE -ne 0 -and $listOut -match "NoSuchBucket") {
            Write-ULog "Bucket nicht vorhanden — versuche mb ..."
            $mbOut = & aws s3 mb "s3://$Bucket" --endpoint-url $Endpoint 2>&1 | Out-String
            Write-ULog "mb: $mbOut"
        }
        $extraArgs = @(); if ($MakePublic) { $extraArgs += @("--acl", "public-read") }
        $cpArgs = @("s3", "cp", $FilePath, "s3://$Bucket/$ObjectKey", "--endpoint-url", $Endpoint) + $extraArgs
        Write-ULog "aws s3 cp ... --endpoint-url $Endpoint"
        $cpOut = & aws @cpArgs 2>&1 | Out-String
        Write-ULog "cp: $cpOut"
        if ($LASTEXITCODE -eq 0) { $uploaded = $true; Write-ULog "Upload via aws erfolgreich!" "PASS" } else { throw "aws cp exit $LASTEXITCODE" }
    } catch { Write-ULog "AWS Fehler: $_" "ERROR" }
}

if (-not $uploaded) {
    Write-ULog "Kein Upload erfolgreich (yc/aws fehlgeschlagen oder nicht installiert)." "ERROR"
    Write-Host ""
    Write-Host "Manuelle Schritte:" -ForegroundColor Yellow
    Write-Host "  Cloud.ru: Console → Haltung → Object Storage → Bucket $Bucket erstellen" -ForegroundColor White
    Write-Host "  aws s3 cp `"$FilePath`" s3://$Bucket/$ObjectKey --endpoint-url $Endpoint" -ForegroundColor White
    Write-Host "  Yandex: yc storage s3api put-object --bucket $Bucket --key $ObjectKey --body `"$FilePath`"" -ForegroundColor White
    Write-Host "  Docs Cloud.ru: https://cloud.ru/docs/s3e/ug/topics/quickstart" -ForegroundColor Gray
    exit 1
}

$publicUrl = if ($provider -eq "Cloud.ru") { "https://$Bucket.s3.cloud.ru/$ObjectKey" } else { "$Endpoint/$Bucket/$ObjectKey" }
$altUrl = if ($provider -eq "Cloud.ru") { "$Endpoint/$Bucket/$ObjectKey" } else { "https://$Bucket.storage.yandexcloud.net/$ObjectKey" }
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ✅ Upload erfolgreich! ($provider)" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Bucket:  $Bucket" -ForegroundColor White
Write-Host "  Objekt:  $ObjectKey" -ForegroundColor White
Write-Host "  Größe:   $fileSize bytes" -ForegroundColor White
Write-Host "  Endpoint: $Endpoint" -ForegroundColor White
Write-Host "  URLs:" -ForegroundColor Yellow
Write-Host "    $publicUrl" -ForegroundColor White
Write-Host "    $altUrl" -ForegroundColor DarkGray
if (-not $MakePublic) {
    Write-Host ""
    Write-Host "  Objekt privat (ACL private) — presigned URL für Windows:" -ForegroundColor Green
    Write-Host "    aws s3 presign s3://$Bucket/$ObjectKey --endpoint-url $Endpoint --expires-in $((3600*$PresignHours))" -ForegroundColor White
}
if ($aws -and -not $MakePublic -and $PresignHours -gt 0) {
    try {
        Write-ULog "Generiere presigned URL ($PresignHours Stunden)..."
        $expires = $PresignHours * 3600
        $presignArgs = @("s3", "presign", "s3://$Bucket/$ObjectKey", "--endpoint-url", $Endpoint, "--expires-in", $expires)
        $presignedUrl = & aws @presignArgs 2>&1 | Out-String; $presignedUrl = $presignedUrl.Trim()
        if ($LASTEXITCODE -eq 0 -and $presignedUrl -match "^https") {
            Write-Host ""
            Write-Host "  Presigned URL (privat, $PresignHours Stunden):" -ForegroundColor Green
            Write-Host "    $presignedUrl" -ForegroundColor White
            Write-Host ""
            Write-Host "  Windows Install (presigned, privat):" -ForegroundColor Cyan
            Write-Host "    `$url=`"$presignedUrl`"" -ForegroundColor White
            Write-Host "    Invoke-WebRequest -Uri `$url -OutFile `$env:TEMP\RemoteGate-Final.ps1" -ForegroundColor White
            Write-Host "    & `$env:TEMP\RemoteGate-Final.ps1" -ForegroundColor White
            $presignFile = Join-Path (Split-Path $FilePath -Parent) "cloud-url.presigned.txt"
            Set-Content -Path $presignFile -Value $presignedUrl -Encoding UTF8
            Write-ULog "Presigned gespeichert: $presignFile"
        } else { Write-ULog "Presign fehlgeschlagen: $presignedUrl" "WARN" }
    } catch { Write-ULog "Presign Fehler: $_" "WARN" }
}
if ($MakePublic) {
    Write-Host ""
    Write-Host "  ⚠️  Öffentlich — Windows:" -ForegroundColor Yellow
    Write-Host "    irm $publicUrl -OutFile `$env:TEMP\RemoteGate-Final.ps1; & `$env:TEMP\RemoteGate-Final.ps1" -ForegroundColor White
    Write-Host "  Jeder mit URL kann Skript löschen!" -ForegroundColor Red
}
Write-Host ""
Write-Host "  Löschen nach Install: aws s3 rm s3://$Bucket/$ObjectKey --endpoint-url $Endpoint" -ForegroundColor DarkGray
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
exit 0
