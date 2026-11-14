<#
.SYNOPSIS
    RemoteGate — Upload final installer to Yandex Object Storage.

.DESCRIPTION
    Uploads the generated final installer (dist/RemoteGate-Final.ps1) to a Yandex Cloud
    Object Storage bucket (S3-compatible, endpoint https://storage.yandexcloud.net).

    Supports multiple backends:
      1. yc CLI (preferred, if yc configured)
      2. AWS CLI with Yandex endpoint (if AWS configured with YC keys)
      3. Manual instructions otherwise

    The bucket should be PRIVATE (not public-read) — script contains password.
    Use presigned URLs for temporary sharing, or keep bucket private and generate
    short-lived URLs for Windows install.

.PARAMETER FilePath
    Path to local file to upload.

.PARAMETER Bucket
    Destination bucket name (e.g. my-remotegate-bucket).

.PARAMETER ObjectKey
    Object key in bucket (default: RemoteGate-Final.ps1).

.PARAMETER MakePrivate
    Keep object private (default). Use -MakePublic only if you accept risk.

.PARAMETER MakePublic
    Make object public-read (WARN: password in file will be world-readable via URL).

.PARAMETER PresignHours
    Generate presigned URL valid for N hours (default 168 = 7 days). Requires AWS CLI.

.EXAMPLE
    .\generator\Upload-ToYandex.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-bucket
    .\generator\Upload-ToYandex.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-bucket -PresignHours 24

.NOTES
    Prerequisites:
      - Yandex Cloud service account with storage.editor role on the bucket/folder
      - yc CLI authenticated (yc init) OR AWS CLI configured with YC static keys:
        aws configure  (set access key from yc iam access-key create --service-account-name <sa>)
        # and set endpoint via --endpoint-url https://storage.yandexcloud.net

    Creating bucket (if needed):
      yc storage bucket create --name <bucket> --default-storage-class standard

    Security: Private bucket is safer. Public bucket means anyone with URL can download
    your password-embedded script. Prefer presigned URLs for time-limited sharing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath,
    [Parameter(Mandatory=$true)]
    [string]$Bucket,
    [string]$ObjectKey = "RemoteGate-Final.ps1",
    [switch]$MakePrivate,
    [switch]$MakePublic,
    [int]$PresignHours = 168
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-ULog { param([string]$M,[string]$L="INFO")
    $c = if($L -eq "ERROR"){"Red"}elseif($L -eq "WARN"){"Yellow"}elseif($L -eq "PASS"){"Green"}else{"Cyan"}
    Write-Host "[Upload] $M" -ForegroundColor $c
}

if (-not (Test-Path $FilePath)) {
    Write-ULog "Datei nicht gefunden: $FilePath" "ERROR"
    exit 1
}
$fileSize = (Get-Item $FilePath).Length
Write-ULog "Datei: $FilePath ($fileSize bytes) → bucket: $Bucket / $ObjectKey"

if ($MakePublic) {
    Write-ULog "WARNUNG: -MakePublic gesetzt — Objekt wird öffentlich lesbar! Passwort in URL für jeden mit Link sichtbar." "WARN"
    Write-Host "  Drücke Enter zum Fortfahren, oder Ctrl+C zum Abbrechen..." -ForegroundColor Yellow
    Read-Host | Out-Null
}

# === Check for yc CLI ===
$yc = Get-Command yc -ErrorAction SilentlyContinue
$aws = Get-Command aws -ErrorAction SilentlyContinue

$uploaded = $false
$endpoint = "https://storage.yandexcloud.net"

if ($yc) {
    Write-ULog "yc CLI gefunden: $($yc.Source)"
    try {
        # Check bucket exists, create if not
        $bucketList = & yc storage bucket list --format json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        $exists = $false
        if ($bucketList) {
            foreach ($b in $bucketList) { if ($b.name -eq $Bucket) { $exists = $true; break } }
        }
        if (-not $exists) {
            Write-ULog "Bucket $Bucket existiert nicht oder nicht gelistet — versuche Erstellung..."
            $createOut = & yc storage bucket create --name $Bucket --default-storage-class standard 2>&1 | Out-String
            Write-ULog "Create: $createOut"
        } else {
            Write-ULog "Bucket $Bucket existiert."
        }

        # Upload via s3api (yc wraps aws)
        Write-ULog "Upload via 'yc storage s3api put-object' ..."
        $uploadArgs = @("storage", "s3api", "put-object", "--bucket", $Bucket, "--key", $ObjectKey, "--body", $FilePath)
        # Add ACL if requested
        if ($MakePublic) { $uploadArgs += @("--acl", "public-read") } else { $uploadArgs += @("--acl", "private") }

        $putOut = & yc @uploadArgs 2>&1 | Out-String
        Write-ULog "Put: $putOut"

        if ($LASTEXITCODE -eq 0) {
            $uploaded = $true
            Write-ULog "Upload via yc erfolgreich!" "PASS"
        } else {
            Write-ULog "yc upload fehlgeschlagen (exit $LASTEXITCODE): $putOut" "ERROR"
            throw "yc upload failed"
        }

        # Verify via s3api head-object
        try {
            $head = & yc storage s3api head-object --bucket $Bucket --key $ObjectKey 2>&1 | Out-String
            Write-ULog "Verify head-object: $head"
        } catch {}

    } catch {
        Write-ULog "yc Upload Fehler: $_" "ERROR"
        # Fall through to try aws
    }
}

if (-not $uploaded -and $aws) {
    Write-ULog "Versuche AWS CLI mit Yandex Endpoint ($endpoint) ..."
    try {
        # Check if aws has yandex creds — try list
        $env:AWS_EC2_METADATA_DISABLED = "true"  # avoid IMDS timeout on non-AWS
        $listArgs = @("s3", "ls", "s3://$Bucket/", "--endpoint-url", $endpoint)
        Write-ULog "aws s3 ls s3://$Bucket/ --endpoint-url $endpoint"
        $listOut = & aws @listArgs 2>&1 | Out-String
        Write-ULog "List: $listOut"
        if ($LASTEXITCODE -ne 0 -and $listOut -match "NoSuchBucket") {
            Write-ULog "Bucket existiert nicht — versuche Erstellung via aws s3 mb ..."
            $mbOut = & aws s3 mb "s3://$Bucket" --endpoint-url $endpoint 2>&1 | Out-String
            Write-ULog "mb: $mbOut"
        }

        # Upload
        $extraArgs = @()
        if ($MakePublic) { $extraArgs += @("--acl", "public-read") }

        $cpArgs = @("s3", "cp", $FilePath, "s3://$Bucket/$ObjectKey", "--endpoint-url", $endpoint) + $extraArgs
        Write-ULog "aws s3 cp ... --endpoint-url $endpoint"
        $cpOut = & aws @cpArgs 2>&1 | Out-String
        Write-ULog "cp: $cpOut"

        if ($LASTEXITCODE -eq 0) {
            $uploaded = $true
            Write-ULog "Upload via aws erfolgreich!" "PASS"
        } else {
            throw "aws cp failed exit $LASTEXITCODE"
        }
    } catch {
        Write-ULog "AWS Upload Fehler: $_" "ERROR"
    }
}

if (-not $uploaded) {
    Write-ULog "Kein Upload-Backend erfolgreich (yc und aws fehlgeschlagen oder nicht installiert)." "ERROR"
    Write-Host ""
    Write-Host "Manuelle Schritte:" -ForegroundColor Yellow
    Write-Host "  1. Yandex Console: Object Storage → Bucket $Bucket erstellen" -ForegroundColor White
    Write-Host "  2. Upload: yc storage s3api put-object --bucket $Bucket --key $ObjectKey --body `"$FilePath`"" -ForegroundColor White
    Write-Host "     oder: aws --endpoint-url $endpoint s3 cp `"$FilePath`" s3://$Bucket/$ObjectKey" -ForegroundColor White
    Write-Host "  3. Docs: https://yandex.cloud/en/docs/storage/operations/objects/upload" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Voraussetzungen:" -ForegroundColor Cyan
    Write-Host "    - Service Account mit storage.editor Rolle: yc iam service-account create --name remotegate-storage" -ForegroundColor White
    Write-Host "    - Schlüssel: yc iam access-key create --service-account-name remotegate-storage" -ForegroundColor White
    Write-Host "    - yc init oder aws configure mit diesen Keys" -ForegroundColor White
    exit 1
}

# === URLs ===
$publicUrl = "$endpoint/$Bucket/$ObjectKey"
$altUrl = "https://$Bucket.storage.yandexcloud.net/$ObjectKey"
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ✅ Upload erfolgreich!" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Bucket:  $Bucket" -ForegroundColor White
Write-Host "  Objekt:  $ObjectKey" -ForegroundColor White
Write-Host "  Größe:   $fileSize bytes" -ForegroundColor White
Write-Host "  URLs:" -ForegroundColor Yellow
Write-Host "    $publicUrl" -ForegroundColor White
Write-Host "    $altUrl" -ForegroundColor DarkGray
if (-not $MakePublic) {
    Write-Host ""
    Write-Host "  Objekt ist privat (ACL private) — anonyme Downloads blockiert." -ForegroundColor Green
    Write-Host "  Für Windows Install presigned URL generieren:" -ForegroundColor Yellow
    Write-Host "    aws s3 presign s3://$Bucket/$ObjectKey --endpoint-url $endpoint --expires-in $((3600*$PresignHours))" -ForegroundColor White
}

# === Generate presigned URL if aws available and private ===
if (-not $MakePublic -and $aws -and $PresignHours -gt 0) {
    try {
        Write-ULog "Generiere presigned URL (gültig $PresignHours Stunden)..."
        $expires = $PresignHours * 3600
        $presignArgs = @("s3", "presign", "s3://$Bucket/$ObjectKey", "--endpoint-url", $endpoint, "--expires-in", $expires)
        $presignedUrl = & aws @presignArgs 2>&1 | Out-String
        $presignedUrl = $presignedUrl.Trim()
        if ($LASTEXITCODE -eq 0 -and $presignedUrl -match "^https") {
            Write-Host ""
            Write-Host "  Presigned URL (privat, gültig $PresignHours Stunden):" -ForegroundColor Green
            Write-Host "    $presignedUrl" -ForegroundColor White
            Write-Host ""
            Write-Host "  Windows Install (presigned, privat):" -ForegroundColor Cyan
            Write-Host "    `$url=`"$presignedUrl`"" -ForegroundColor White
            Write-Host "    Invoke-WebRequest -Uri `$url -OutFile `$env:TEMP\RemoteGate-Final.ps1" -ForegroundColor White
            Write-Host "    & `$env:TEMP\RemoteGate-Final.ps1" -ForegroundColor White
            # Also write to file for convenience
            $presignFile = Join-Path (Split-Path $FilePath -Parent) "yandex-url.presigned.txt"
            Set-Content -Path $presignFile -Value $presignedUrl -Encoding UTF8
            Write-ULog "Presigned URL gespeichert: $presignFile"
        } else {
            Write-ULog "Presign fehlgeschlagen: $presignedUrl" "WARN"
        }
    } catch {
        Write-ULog "Presign Fehler: $_" "WARN"
    }
}

if ($MakePublic) {
    Write-Host ""
    Write-Host "  ⚠️  Öffentlich — Windows Download:" -ForegroundColor Yellow
    Write-Host "    irm $publicUrl -OutFile `$env:TEMP\RemoteGate-Final.ps1; & `$env:TEMP\RemoteGate-Final.ps1" -ForegroundColor White
    Write-Host "  ⚠️  Jeder mit URL kann Skript (inkl. Passwort) herunterladen — nach Installation löschen oder ACL auf private setzen!" -ForegroundColor Red
} else {
    Write-Host ""
    Write-Host "  Windows Download (wenn presigned URL vorhanden, siehe oben):" -ForegroundColor White
    Write-Host "    `$url=`"$publicUrl`"  # nur wenn du später auf public stellst" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Prüfen:" -ForegroundColor Cyan
Write-Host "    yc storage s3api get-object --bucket $Bucket --key $ObjectKey --output `"$env:TEMP\verify.ps1`" && Get-FileHash `$env:TEMP\verify.ps1" -ForegroundColor DarkGray
Write-Host "  Löschen nach Installation: yc storage s3api delete-object --bucket $Bucket --key $ObjectKey" -ForegroundColor DarkGray
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

exit 0
