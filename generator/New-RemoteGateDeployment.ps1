<#
.SYNOPSIS
    RemoteGate Wizard — Generates the FINAL installer with your fixed password and Yandex config.

.DESCRIPTION
    Workflow (as requested):
      1. GitHub has installer + example script (this repo)
      2. You download repo (git clone)
      3. You run this wizard, set fixed password (DEIN_PASSWORT → your real password)
      4. If needed, enter Yandex account/API details
      5. Wizard injects values into the example template → gives you FINAL script
      6. Script is uploaded to Yandex Object Storage (automatic if possible)
      7. That Yandex-hosted script is executed on Windows PC
      8. Windows install command downloads from Yandex, not GitHub

    This keeps your password PRIVATE to your Yandex bucket — never committed to GitHub.
    The GitHub repo always contains only placeholders (DEIN_PASSWORT).

.PARAMETER ConfigFile
    Optional JSON config to pre-fill wizard (e.g. from previous run).

.PARAMETER NonInteractive
    Use values from ConfigFile without prompting (for automation).

.PARAMETER SkipUpload
    Do not upload to Yandex — just generate locally.

.PARAMETER OutputPath
    Where to write final script (default: dist/RemoteGate-Final.ps1)

.EXAMPLE
    # Interactive (on your admin PC where you downloaded the repo):
    .\generator\New-RemoteGateDeployment.ps1

    # With pre-filled config:
    .\generator\New-RemoteGateDeployment.ps1 -ConfigFile .\generator\my-config.json

.NOTES
    Requires PowerShell 5.1+ or pwsh 7+.
    For Yandex upload, needs yc CLI configured or AWS CLI with Yandex S3 keys.
    See docs/GENERATOR.md for full guide.

    SECURITY:
    - Never commit dist/ to GitHub (in .gitignore).
    - Wizard writes password in PLAIN to generated script (needed for net user).
      That script must stay in PRIVATE Yandex bucket or be deleted after install.
    - Generator warns before upload if bucket is public.
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = "",
    [switch]$NonInteractive,
    [switch]$SkipUpload,
    [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# === Paths ===
$GeneratorDir = $PSScriptRoot
if (-not $GeneratorDir) { $GeneratorDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$RepoRoot = Split-Path -Parent $GeneratorDir
if (-not (Test-Path $RepoRoot)) { $RepoRoot = "." }
$TemplatePath = Join-Path $RepoRoot "templates\RemoteGate-Deployment.template.ps1"
if (-not (Test-Path $TemplatePath)) { $TemplatePath = Join-Path $RepoRoot "templates/RemoteGate-Deployment.template.ps1" }
# Fallback: try installer as template
if (-not (Test-Path $TemplatePath)) {
    # Try alternate location
    $TemplatePath = Join-Path $RepoRoot "installer\Install-RemoteGate.ps1"
}

$DefaultOutput = Join-Path $RepoRoot "dist\RemoteGate-Final.ps1"
if ($OutputPath) { $DefaultOutput = $OutputPath }

function Write-WizardLog {
    param([string]$Message, [string]$Level = "INFO")
    $color = if ($Level -eq "ERROR") { "Red" } elseif ($Level -eq "WARN") { "Yellow" } elseif ($Level -eq "PASS") { "Green" } else { "Cyan" }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}
function Read-SecureInput {
    param([string]$Prompt, [switch]$AllowEmpty)
    # Use SecureString to avoid shoulder surfing
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    $plain = [System.Net.NetworkCredential]::new("", $sec).Password
    if (-not $AllowEmpty -and -not $plain) {
        Write-WizardLog "Eingabe leer — erneut versuchen (oder Enter für Key-only)." "WARN"
        return $null
    }
    return $plain
}
function Test-PasswordStrength {
    param([string]$Password)
    $issues = @()
    if ($Password.Length -lt 12) { $issues += "Mindestens 12 Zeichen (du hast $($Password.Length))" }
    if ($Password -notmatch "[A-Z]") { $issues += "Mindestens ein Großbuchstabe" }
    if ($Password -notmatch "[a-z]") { $issues += "Mindestens ein Kleinbuchstabe" }
    if ($Password -notmatch "[0-9]") { $issues += "Mindestens eine Zahl" }
    if ($Password -notmatch "[^a-zA-Z0-9]") { $issues += "Mindestens ein Sonderzeichen (!@# etc.)" }
    if ($Password -match "DEIN_PASSWORT|password|123456|qwerty") { $issues += "Zu einfach / Platzhalter erkannt" }
    return $issues
}

Write-Host @"

  ██████╗ ███████╗███╗   ███╗ ██████╗ ████████╗███████╗ ██████╗  █████╗ ████████╗███████╗
  ██╔══██╗██╔════╝████╗ ████║██╔═══██╗╚══██╔══╝██╔════╝██╔════╝ ██╔══██╗╚══██╔══╝██╔════╝
  ██████╔╝█████╗  ██╔████╔██║██║   ██║   ██║   █████╗  ██║  ███╗███████║   ██║   █████╗
  ██╔══██╗██╔══╝  ██║╚██╔╝██║██║   ██║   ██║   ██╔══╝  ██║   ██║██╔══██║   ██║   ██╔══╝
  ██║  ██║███████╗██║ ╚═╝ ██║╚██████╔╝   ██║   ███████╗╚██████╔╝██║  ██║   ██║   ███████╗
  ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝ ╚═════╝    ╚═╝   ╚══════╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝

  RemoteGate — Wizard: Generiere FINALEN Installer für Yandex
  =================================================================
  1. GitHub hat Installer + Beispiel (Template)
  2. Du lädst Repo herunter (git clone)
  3. Hier setzt du dein festes Passwort (DEIN_PASSWORT → dein PW)
  4. Yandex Zugang optional
  5. Wizard injiziert Werte → FINALER Skript
  6. Upload nach Yandex Object Storage (automatisch, wenn möglich)
  7. Windows PC lädt von Yandex (nicht GitHub) — privat!

"@ -ForegroundColor Cyan

# Check template exists
if (-not (Test-Path $TemplatePath)) {
    Write-WizardLog "Template nicht gefunden: $TemplatePath" "ERROR"
    Write-Host "Suche in: $RepoRoot" -ForegroundColor Yellow
    Get-ChildItem $RepoRoot -Recurse -Filter "*.template.ps1" | ForEach-Object { Write-Host "  Gefunden: $($_.FullName)" }
    exit 1
}
Write-WizardLog "Template: $TemplatePath"

# === Load pre-fill config if provided ===
$prefill = @{}
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    try {
        $prefill = Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
        Write-WizardLog "Prefill aus $ConfigFile geladen."
    } catch { Write-WizardLog "Prefill parse Fehler: $_" "WARN" }
}

# === Interactive prompts (unless NonInteractive) ===
# Cloud provider: Cloud.ru (default) or Yandex (legacy). Wizard now defaults to Cloud.ru.
$CloudProvider = "cloudru"  # cloudru | yandex
$CloudEndpoint = "https://s3.cloud.ru"  # Cloud.ru default; Yandex: https://storage.yandexcloud.net
$WindowsUser = $null
$WindowsPassword = $null
$WindowsPasswordConfirm = $null
$UsePasswordAuth = $false
$YandexVmIp = $null  # Keep name for backward compat — actually CloudVmIp (Cloud.ru or Yandex)
$YandexVmUser = "tunneluser"
$YandexVmPort = 22
$ReverseTunnelPort = 2222
$YandexBucket = $null  # Cloud/Storage bucket (Cloud.ru default)
$StatusEndpoint = ""
$HmacSecret = ""
$StatusEnabled = $false
$Hostname = $env:COMPUTERNAME
if (-not $Hostname) { $Hostname = "WINDOWS-PC" }

if (-not $NonInteractive) {
    Write-Host "`n── Schritt 1: Windows Zugang (festes Passwort) ──" -ForegroundColor Green
    Write-Host "Hier legst du dein festes Passwort fest (DEIN_PASSWORT Platzhalter)." -ForegroundColor DarkGray
    Write-Host "ℹ️  Windows Benutzername wird NICHT hier abgefragt —" -ForegroundColor Cyan
    Write-Host "   der Windows PC erkennt ihn automatisch beim Installieren (aktueller Benutzer)." -ForegroundColor Cyan
    Write-Host "Wenn du kein Passwort willst, lasse leer → nur Key-Auth (sicherer)." -ForegroundColor DarkGray
    Write-Host ""

    # Windows User wird automatisch auf Windows erkannt — nicht im Mac-Wizard fragen
    $WindowsUser = "DEIN_BENUTZER"  # Platzhalter → Auto-Detect auf Windows (siehe template)
    Write-WizardLog "Windows Benutzer: AUTO (wird auf Windows erkannt, kein Mac-Prompt)" "INFO"
    Write-Host "  → Windows Benutzer: Automatische Erkennung auf dem Windows PC" -ForegroundColor Green

    # Password (SecureString) — mit Hinweis dass Eingabe unsichtbar ist
    Write-Host "  Hinweis: Passwort-Eingabe ist unsichtbar (Sicherheit) — tippe + Enter, du siehst nichts, das ist normal." -ForegroundColor DarkGray
    while ($true) {
        $pw = Read-SecureInput -Prompt "Festes Passwort für Windows SSH (verdeckt, leer = nur Key-Auth)" -AllowEmpty
        if (-not $pw) {
            Write-WizardLog "Kein Passwort — Key-only (PasswordAuthentication no)." "WARN"
            Write-Host "  → Sicherer: SSH nur mit Keys. Passwort-Login deaktiviert." -ForegroundColor Gray
            $WindowsPassword = "DEIN_PASSWORT" # will be treated as placeholder → no auth
            $UsePasswordAuth = $false
            break
        }
        $strength = Test-PasswordStrength $pw
        if ($strength.Count -gt 0) {
            Write-Host "`n  ⚠️  Schwaches Passwort:" -ForegroundColor Yellow
            foreach ($s in $strength) { Write-Host "     - $s" -ForegroundColor Yellow }
            $cont = Read-Host "Trotzdem verwenden? (j/N)"
            if ($cont -ne "j" -and $cont -ne "J" -and $cont -ne "y" -and $cont -ne "Y") {
                Write-Host "  Bitte neues Passwort eingeben." -ForegroundColor Cyan
                continue
            }
        }
        # Confirm
        $pw2 = Read-SecureInput -Prompt "Passwort bestätigen (erneut eingeben)" -AllowEmpty
        if ($pw -ne $pw2) {
            Write-WizardLog "Passwörter stimmen nicht überein — erneut." "ERROR"
            continue
        }
        $WindowsPassword = $pw
        $UsePasswordAuth = $true
        Write-WizardLog "Passwort gesetzt (wird im finalen Skript auf Yandex gespeichert, nicht in GitHub)!" "PASS"
        # Clear confirm var
        $pw2 = $null
        break
    }

    Write-Host "`n── Schritt 2: Yandex Zugang (oder später) ──" -ForegroundColor Green
    Write-Host "Gib Yandex VM Daten ein, oder lasse leer für späteren Upload." -ForegroundColor DarkGray

    $defaultIp = if ($prefill.YandexVmIp) { $prefill.YandexVmIp } else { "" }
    $promptIp = if ($defaultIp) { "Yandex VM öffentliche IP [$defaultIp]" } else { "Yandex VM öffentliche IP (z.B. 51.250.12.34, leer = Platzhalter)" }
    $inputIp = Read-Host $promptIp
    $YandexVmIp = if ($inputIp) { $inputIp } elseif ($defaultIp) { $defaultIp } else { "DEIN_YANDEX_VM_IP" }

    $defaultVmUser = if ($prefill.YandexVmUser) { $prefill.YandexVmUser } else { "tunneluser" }
    $inputVmUser = Read-Host "Yandex VM Tunnel Benutzer [$defaultVmUser]"
    $YandexVmUser = if ($inputVmUser) { $inputVmUser } else { $defaultVmUser }

    $inputPort = Read-Host "Yandex SSH Port [$YandexVmPort]"
    if ($inputPort -and $inputPort -match "^\d+$") { $YandexVmPort = [int]$inputPort }

    $inputTunPort = Read-Host "Reverse Tunnel Port auf VM [$ReverseTunnelPort]"
    if ($inputTunPort -and $inputTunPort -match "^\d+$") { $ReverseTunnelPort = [int]$inputTunPort }

    # Cloud provider choice (default Cloud.ru)
    $defaultEndpoint = if ($prefill.CloudEndpoint) { $prefill.CloudEndpoint } elseif ($prefill.S3Endpoint) { $prefill.S3Endpoint } else { "https://s3.cloud.ru" }
    $inputEndpoint = Read-Host "Cloud Anbieter? [1] Cloud.ru (Free Tier, https://s3.cloud.ru) [2] Yandex (https://storage.yandexcloud.net) [1/2, Enter=Cloud.ru]"
    if ($inputEndpoint -eq "2" -or $inputEndpoint -match "yandex") {
        $CloudProvider = "yandex"; $CloudEndpoint = "https://storage.yandexcloud.net"
        Write-WizardLog "Anbieter: Yandex ($CloudEndpoint)" "INFO"
    } elseif ($inputEndpoint -eq "1" -or -not $inputEndpoint) {
        $CloudProvider = "cloudru"; $CloudEndpoint = "https://s3.cloud.ru"
        Write-WizardLog "Anbieter: Cloud.ru (Free Tier) → $CloudEndpoint" "PASS"
    } elseif ($inputEndpoint -match "https?://") {
        $CloudEndpoint = $inputEndpoint; $CloudProvider = if ($CloudEndpoint -match "yandex") { "yandex" } else { "cloudru" }
        Write-WizardLog "Anbieter: Custom $CloudEndpoint"
    } else {
        $CloudProvider = "cloudru"; $CloudEndpoint = $defaultEndpoint
    }

    $defaultBucket = if ($prefill.YandexBucket) { $prefill.YandexBucket } elseif ($prefill.CloudBucket) { $prefill.CloudBucket } else { "" }
    $inputBucket = Read-Host "Object Storage Bucket für Final-Skript (z.B. my-remotegate-bucket, leer = kein Auto-Upload) — $CloudProvider"
    $YandexBucket = if ($inputBucket) { $inputBucket } elseif ($defaultBucket) { $defaultBucket } else { "" }
    if ($YandexBucket) { Write-WizardLog "Bucket: $YandexBucket ($CloudProvider) — Upload wird versucht via $CloudEndpoint." }

    # Optional Status
    $askStatus = Read-Host "Status Endpoint (HTTPS) konfigurieren? (j/N)"
    if ($askStatus -eq "j" -or $askStatus -eq "J" -or $askStatus -eq "y") {
        $StatusEndpoint = Read-Host "Status Endpoint URL (https://..../status)"
        $HmacSecret = Read-SecureInput -Prompt "HMAC Secret (für Status, verdeckt)"
        $StatusEnabled = $true
    }

    $inputHost = Read-Host "Windows Hostname [$Hostname]"
    if ($inputHost) { $Hostname = $inputHost }

} else {
    # Non-interactive: use prefill or defaults
    $WindowsUser = if ($prefill.WindowsUser) { $prefill.WindowsUser } else { "DEIN_BENUTZER" }
    $WindowsPassword = if ($prefill.WindowsPassword) { $prefill.WindowsPassword } else { "DEIN_PASSWORT" }
    $YandexVmIp = if ($prefill.YandexVmIp) { $prefill.YandexVmIp } else { "DEIN_YANDEX_VM_IP" }
    $YandexVmUser = if ($prefill.YandexVmUser) { $prefill.YandexVmUser } else { "tunneluser" }
    $YandexVmPort = if ($prefill.YandexVmPort) { $prefill.YandexVmPort } else { 22 }
    $ReverseTunnelPort = if ($prefill.ReverseTunnelPort) { $prefill.ReverseTunnelPort } else { 2222 }
    $YandexBucket = if ($prefill.YandexBucket) { $prefill.YandexBucket } else { "" }
    $StatusEndpoint = if ($prefill.StatusEndpoint) { $prefill.StatusEndpoint } else { "" }
    $HmacSecret = if ($prefill.HmacSecret) { $prefill.HmacSecret } else { "" }
    $StatusEnabled = if ($prefill.StatusEnabled) { [bool]$prefill.StatusEnabled } else { $false }
    $Hostname = if ($prefill.Hostname) { $prefill.Hostname } else { $Hostname }
    $UsePasswordAuth = ($WindowsPassword -ne "DEIN_PASSWORT" -and $WindowsPassword.Length -ge 4)
    Write-WizardLog "NonInteractive: User=$WindowsUser IP=$YandexVmIp PassAuth=$UsePasswordAuth"
}

# === Generate Device ID ===
$DeviceId = [guid]::NewGuid().ToString()
if ($prefill.DeviceId -and $prefill.DeviceId -notmatch "DEIN_|REPLACE") { $DeviceId = $prefill.DeviceId }
Write-WizardLog "DeviceId: $DeviceId (zufällig, nicht deine IP)"

# === Load template and replace ===
Write-Host "`n── Schritt 3: Generiere FINALEN Installer ──" -ForegroundColor Green
$templateContent = Get-Content $TemplatePath -Raw
if (-not $templateContent) { Write-WizardLog "Template leer!" "ERROR"; exit 1 }

$GenerationTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Replacement map — use double-quoted strings, escape for PowerShell
function Escape-ForPSDoubleQuote {
    param([string]$Value)
    if (-not $Value) { return "" }
    return $Value.Replace('"', '`"').Replace('$', '`$')
}

# Build replacements (order matters: longer placeholders first)
$replacements = @{
    "__WINDOWS_USER__"       = $WindowsUser
    "__WINDOWS_PASSWORD__"   = if ($UsePasswordAuth) { $WindowsPassword } else { "DEIN_PASSWORT" }
    "__YANDEX_VM_IP__"       = $YandexVmIp
    "__YANDEX_VM_USER__"     = $YandexVmUser
    "__YANDEX_VM_PORT__"     = $YandexVmPort.ToString()
    "__REVERSE_TUNNEL_PORT__" = $ReverseTunnelPort.ToString()
    "__STATUS_ENDPOINT__"    = $StatusEndpoint
    "__HMAC_SECRET__"        = if ($HmacSecret) { $HmacSecret } else { "" }
    "__STATUS_ENABLED__"     = if ($StatusEnabled) { '$true' } else { '$false' }
    "__DEVICE_ID__"          = $DeviceId
    "__HOSTNAME__"           = $Hostname
    "__YANDEX_BUCKET__"      = $YandexBucket
    "__GENERATION_TIME__"    = $GenerationTime
}

# For numeric fields, ensure no quotes in template — they are already bare
# WindowsPassword etc. are inside quotes in template, so plain string is OK
# But need to escape special chars for the PowerShell string context
# The template has: WindowsPassword = "__WINDOWS_PASSWORD__"  (inside double quotes)
# So if password contains " or ` etc., we must escape

# Special handling for WindowsPassword inside double quotes
if ($replacements["__WINDOWS_PASSWORD__"] -ne "DEIN_PASSWORT" -and $replacements["__WINDOWS_PASSWORD__"].Length -gt 0) {
    # Escape backticks and double quotes for safe injection
    $escapedPw = $replacements["__WINDOWS_PASSWORD__"].Replace('`', '``').Replace('"', '`"')
    # Also escape $ for PowerShell
    $escapedPw = $escapedPw.Replace('$', '`$')
    $replacements["__WINDOWS_PASSWORD__"] = $escapedPw
}

$outputContent = $templateContent
foreach ($key in $replacements.Keys) {
    $val = $replacements[$key]
    $outputContent = $outputContent.Replace($key, $val)
}

# Ensure output dir exists
$outDir = Split-Path $DefaultOutput -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

Set-Content -Path $DefaultOutput -Value $outputContent -Encoding UTF8
Write-WizardLog "FINALER Installer geschrieben: $DefaultOutput" "PASS"
Write-Host "  Größe: $((Get-Item $DefaultOutput).Length) Bytes" -ForegroundColor Gray
Write-Host "  DeviceId: $DeviceId" -ForegroundColor Cyan

# Also write a local config cache (without password in plain? but we need for re-run)
# Save a redacted version for next wizard run
$redactedPrefill = @{
    WindowsUser = $WindowsUser
    YandexVmIp = $YandexVmIp  # backward compat — actually CloudVmIp
    YandexVmUser = $YandexVmUser
    YandexVmPort = $YandexVmPort
    ReverseTunnelPort = $ReverseTunnelPort
    YandexBucket = $YandexBucket
    CloudBucket = $YandexBucket
    CloudProvider = $CloudProvider
    CloudEndpoint = $CloudEndpoint
    S3Endpoint = $CloudEndpoint
    StatusEndpoint = $StatusEndpoint
    StatusEnabled = $StatusEnabled
    Hostname = $Hostname
    DeviceId = $DeviceId
    GenerationTime = $GenerationTime
    UsePasswordAuth = $UsePasswordAuth
    # Do NOT save password in plain in prefill — save flag only
    WindowsPasswordSet = $UsePasswordAuth
}
$prefillPath = Join-Path $GeneratorDir "last-generation.json"
$redactedPrefill | ConvertTo-Json -Depth 4 | Set-Content -Path $prefillPath -Encoding UTF8
Write-WizardLog "Prefill-Cache (ohne Passwort) gespeichert: $prefillPath"

# Warn about password handling
if ($UsePasswordAuth) {
    Write-Host "`n⚠️  WICHTIG: Dein Passwort ist jetzt im FINALEN Skript ($DefaultOutput)" -ForegroundColor Yellow
    Write-Host "   — Dieses Skript darf NIEMALS auf GitHub gepusht werden (ist in .gitignore)!" -ForegroundColor Yellow
    Write-Host "   — Lege es nur in deinen PRIVATEN Bucket ($CloudProvider): $CloudEndpoint." -ForegroundColor Yellow
    Write-Host "   — Lösche lokale Kopie nach Upload, oder bewahre sicher auf." -ForegroundColor Yellow
    # Try to clear password variable
    try { $WindowsPassword = $null; $replacements["__WINDOWS_PASSWORD__"] = "***" } catch {}
} else {
    Write-Host "`nℹ️  Kein Passwort gesetzt — SSH nur mit Keys (sicherer Standard)." -ForegroundColor Gray
    Write-Host "   PasswordAuthentication bleibt 'no'. Du kannst später Passwort hinzufügen." -ForegroundColor Gray
}

# === Step 4: Upload (Cloud.ru default, Yandex legacy) ===
Write-Host "`n── Schritt 4: Upload nach $CloudProvider Object Storage ──" -ForegroundColor Green
if ($SkipUpload) {
    Write-WizardLog "SkipUpload gesetzt — kein Upload." "WARN"
} elseif (-not $YandexBucket) {
    Write-WizardLog "Kein Bucket angegeben — Upload übersprungen." "WARN"
    Write-Host "  Du kannst später manuell hochladen:" -ForegroundColor White
    Write-Host "    Cloud.ru: aws s3 cp `"$DefaultOutput`" s3://<bucket>/RemoteGate-Final.ps1 --endpoint-url $CloudEndpoint" -ForegroundColor Gray
    Write-Host "    Yandex:   yc storage s3api put-object --bucket <bucket> --key RemoteGate-Final.ps1 --body $DefaultOutput" -ForegroundColor Gray
    Write-Host "  Oder: .\generator\Upload-ToCloud.ps1 -FilePath `"$DefaultOutput`" -Bucket `"<bucket>`" -Endpoint `"$CloudEndpoint`"" -ForegroundColor Gray
} else {
    Write-WizardLog "Versuche Upload nach $CloudProvider Bucket: $YandexBucket ($CloudEndpoint) ..."
    # Prefer Upload-ToCloud (Cloud.ru + Yandex), fallback to Upload-ToYandex legacy
    $uploader = Join-Path $GeneratorDir "Upload-ToCloud.ps1"
    if (-not (Test-Path $uploader)) { $uploader = Join-Path $GeneratorDir "Upload-ToYandex.ps1" }
    if (Test-Path $uploader) {
        try {
            # Call uploader with explicit params (it handles Cloud.ru / Yandex)
            $uploadParams = @{ FilePath = $DefaultOutput; Bucket = $YandexBucket }
            if ($uploader -match "Upload-ToCloud") { $uploadParams["Endpoint"] = $CloudEndpoint }
            $uploadResult = & $uploader @uploadParams
            Write-WizardLog "Uploader ausgeführt." "PASS"
            if ($uploadResult) { Write-Host $uploadResult -ForegroundColor White }
        } catch {
            Write-WizardLog "Upload fehlgeschlagen: $_" "ERROR"
            Write-Host "  Cloud.ru: aws s3 cp `"$DefaultOutput`" s3://$YandexBucket/RemoteGate-Final.ps1 --endpoint-url $CloudEndpoint" -ForegroundColor White
            Write-Host "  Yandex:   yc storage s3api put-object --bucket $YandexBucket --key RemoteGate-Final.ps1 --body $DefaultOutput" -ForegroundColor White
        }
    } else {
        Write-WizardLog "Uploader nicht gefunden: $uploader" "WARN"
        Write-Host "  Versuch via yc CLI direkt..." -ForegroundColor Yellow
        # Fallback direct attempt
        try {
            # Check yc available
            $ycExists = Get-Command yc -ErrorAction SilentlyContinue
            if ($ycExists) {
                $bucketCheck = & yc storage bucket get --name $YandexBucket 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  Bucket existiert nicht — erstelle..." -ForegroundColor Yellow
                    & yc storage bucket create --name $YandexBucket 2>&1 | Out-String | Write-Host
                }
                & yc storage s3api put-object --bucket $YandexBucket --key RemoteGate-Final.ps1 --body $DefaultOutput 2>&1 | Out-String | Write-Host
                Write-WizardLog "yc upload versucht — prüfe Logs oben." "INFO"
            } else {
                Write-WizardLog "yc CLI nicht gefunden — installiere https://yandex.cloud/en/docs/cli/quickstart" "WARN"
            }
        } catch {
            Write-WizardLog "Fallback Upload Fehler: $_" "ERROR"
        }
    }
}

# === Final output: Windows command ===
Write-Host "`n════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ✅ GENERATOR FERTIG — FINALER INSTALLER BEREIT ($CloudProvider)" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Lokal: $DefaultOutput" -ForegroundColor White
if ($YandexBucket) {
    if ($CloudProvider -eq "cloudru") {
        $cloudUrl = "https://$YandexBucket.s3.cloud.ru/RemoteGate-Final.ps1"
        $cloudUrlAlt = "$CloudEndpoint/$YandexBucket/RemoteGate-Final.ps1"
    } else {
        $cloudUrl = "https://storage.yandexcloud.net/$YandexBucket/RemoteGate-Final.ps1"
        $cloudUrlAlt = "https://$YandexBucket.storage.yandexcloud.net/RemoteGate-Final.ps1"
    }
    Write-Host ""
    Write-Host "  $CloudProvider URLs (nach Upload):" -ForegroundColor Yellow
    Write-Host "    $cloudUrl" -ForegroundColor White
    Write-Host "    $cloudUrlAlt (alternativ)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  🖥️  WINDOWS INSTALLATIONS-KOMMANDO (aus $CloudProvider, nicht GitHub):" -ForegroundColor Green
    Write-Host "  ┌─────────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │ PowerShell als Administrator öffnen, dann:" -ForegroundColor White
    Write-Host "  │" -ForegroundColor White
    Write-Host "  `$url=`"$cloudUrl`"" -ForegroundColor White
    Write-Host "  `$out=`"`$env:TEMP\RemoteGate-Final.ps1`"" -ForegroundColor White
    Write-Host "  `Invoke-WebRequest -Uri `$url -OutFile `$out -UseBasicParsing" -ForegroundColor White
    Write-Host "  `# Presigned wenn privat: aws s3 presign s3://$YandexBucket/RemoteGate-Final.ps1 --endpoint-url $CloudEndpoint --expires-in 604800" -ForegroundColor DarkGray
    Write-Host "  `& `$out" -ForegroundColor White
    Write-Host "  └─────────────────────────────────────────────────────────┘" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Einzeiler (verifiziert + ausgeführt):" -ForegroundColor Cyan
    Write-Host "  irm $cloudUrl -OutFile `$env:TEMP\RemoteGate-Final.ps1; & `$env:TEMP\RemoteGate-Final.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "  ⚠️  Dieser Befehl lädt dein PRIVATES $CloudProvider-Skript (mit Passwort) —" -ForegroundColor Yellow
    Write-Host "     nicht das öffentliche GitHub Skript. Teile URL nicht öffentlich!" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "  Kein Bucket — lokaler Installer:" -ForegroundColor Yellow
    Write-Host "  Windows Kommando (lokal übertragen, dann ausführen):" -ForegroundColor White
    Write-Host "    Copy-Item `"$DefaultOutput`" -Destination `"\\WINDOWS-PC\C$\Temp\RemoteGate-Final.ps1`"" -ForegroundColor Gray
    Write-Host "    # Auf Windows als Admin: & C:\Temp\RemoteGate-Final.ps1" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Oder manuell zu Cloud hochladen:" -ForegroundColor White
    Write-Host "    .\generator\Upload-ToCloud.ps1 -FilePath `"$DefaultOutput`" -Bucket `"<dein-bucket>`" -Endpoint `"$CloudEndpoint`"" -ForegroundColor White
}
Write-Host ""
Write-Host "  Nächste Schritte:" -ForegroundColor Yellow
Write-Host "    1. Prüfe $DefaultOutput (Passwort ist dort — nicht committen!)" -ForegroundColor White
Write-Host "    2. Lade zu $CloudProvider hoch (auto, falls möglich, sonst manuell)" -ForegroundColor White
Write-Host "    3. Führe auf Windows das $CloudProvider-Kommando aus (als Admin)" -ForegroundColor White
Write-Host "    4. Teste: ssh -J rgadmin@$YandexVmIp -p $ReverseTunnelPort $WindowsUser@127.0.0.1" -ForegroundColor White
Write-Host "       Passwort: dein festgelegtes Passwort (nicht DEIN_PASSWORT)" -ForegroundColor White
Write-Host "    5. Lösche lokale Kopie nach Upload, wenn nicht mehr benötigt" -ForegroundColor DarkGray
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Clear sensitive vars
try {
    $WindowsPassword = $null
    $HmacSecret = $null
    [GC]::Collect()
} catch {}

exit 0
