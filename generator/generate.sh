#!/bin/bash
# RemoteGate Generator — Bash version for Mac (no PowerShell needed)
# Mirror of generator/New-RemoteGateDeployment.ps1, for macOS/Linux
# Usage: bash generator/generate.sh [--non-interactive] [--config my-config.json] [--skip-upload] [--output dist/RemoteGate-Final.ps1]

set -euo pipefail

# === Paths ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$REPO_ROOT/templates/RemoteGate-Deployment.template.ps1"
DEFAULT_OUTPUT="$REPO_ROOT/dist/RemoteGate-Final.ps1"
CONFIG_FILE=""
NON_INTERACTIVE=false
SKIP_UPLOAD=false
OUTPUT_PATH="$DEFAULT_OUTPUT"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --skip-upload) SKIP_UPLOAD=true; shift ;;
    -h|--help) echo "Usage: $0 [--config file.json] [--output path] [--non-interactive] [--skip-upload]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Helpers
log_info()  { echo -e "\033[36m[INFO]\033[0m $*"; }
log_ok()    { echo -e "\033[32m[PASS]\033[0m $*"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m $*"; }
log_err()   { echo -e "\033[31m[ERROR]\033[0m $*"; }

read_input() {
  local prompt="$1"
  local default="$2"
  local var
  if [[ -n "$default" ]]; then
    read -p "$prompt [$default]: " var
    echo "${var:-$default}"
  else
    read -p "$prompt: " var
    echo "$var"
  fi
}

read_secret() {
  local prompt="$1"
  local val confirm
  while true; do
    echo -n "$prompt (verdeckt): "
    read -s val
    echo
    if [[ -z "$val" ]]; then
      echo ""
      return 1  # empty → no password
    fi
    # Strength check
    local issues=()
    if [[ ${#val} -lt 12 ]]; then issues+=("≥12 Zeichen (du hast ${#val})"); fi
    if ! [[ "$val" =~ [A-Z] ]]; then issues+=("Großbuchstabe"); fi
    if ! [[ "$val" =~ [a-z] ]]; then issues+=("Kleinbuchstabe"); fi
    if ! [[ "$val" =~ [0-9] ]]; then issues+=("Zahl"); fi
    if ! [[ "$val" =~ [^a-zA-Z0-9] ]]; then issues+=("Sonderzeichen"); fi
    if [[ "$val" == *"DEIN_PASSWORT"* ]] || [[ "$val" == *"password"* ]]; then issues+=("Zu einfach / Platzhalter"); fi
    if [[ ${#issues[@]} -gt 0 ]]; then
      echo -e "\033[33m  ⚠️  Schwach: ${issues[*]}\033[0m"
      read -p "  Trotzdem verwenden? (j/N): " cont
      if [[ "$cont" != "j" && "$cont" != "J" && "$cont" != "y" && "$cont" != "Y" ]]; then continue; fi
    fi
    echo -n "  Bestätigen (erneut): "
    read -s confirm
    echo
    if [[ "$val" != "$confirm" ]]; then
      log_err "Passwörter stimmen nicht überein — erneut."
      continue
    fi
    echo "$val"
    return 0
  done
}

banner() {
  cat <<'BANNER'
  ██████╗ ███████╗███╗   ███╗ ██████╗ ████████╗███████╗ ██████╗  █████╗ ████████╗███████╗
  ██╔══██╗██╔════╝████╗ ████║██╔═══██╗╚══██╔══╝██╔════╝██╔════╝ ██╔══██╗╚══██╔══╝██╔════╝
  ██████╔╝█████╗  ██╔████╔██║██║   ██║   ██║   █████╗  ██║  ███╗███████║   ██║   █████╗
  ██╔══██╗██╔══╝  ██║╚██╔╝██║██║   ██║   ██║   ██╔══╝  ██║   ██║██╔══██║   ██║   ██╔══╝
  ██║  ██║███████╗██║ ╚═╝ ██║╚██████╔╝   ██║   ███████╗╚██████╔╝██║  ██║   ██║   ███████╗
  ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝ ╚═════╝    ╚═╝   ╚══════╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝

  RemoteGate — Generator (Mac, Bash, kein PowerShell nötig)
  === festes Passwort (DEIN_PASSWORT → dein PW) + Yandex → FINAL ===
BANNER
}

# === Start ===
banner
echo "Repo: $REPO_ROOT"
echo "Template: $TEMPLATE_PATH"
if [[ ! -f "$TEMPLATE_PATH" ]]; then
  log_err "Template nicht gefunden: $TEMPLATE_PATH"
  exit 1
fi

# Load prefill if config file provided
declare -A PREFILL
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  log_info "Prefill aus $CONFIG_FILE"
  # Simple JSON parse via python3 or jq
  if command -v jq &>/dev/null; then
    for key in WindowsUser WindowsPassword YandexVmIp YandexVmUser YandexVmPort ReverseTunnelPort YandexBucket StatusEndpoint HmacSecret StatusEnabled Hostname DeviceId; do
      val=$(jq -r ".\"$key\" // empty" "$CONFIG_FILE" 2>/dev/null || true)
      if [[ -n "$val" && "$val" != "null" ]]; then PREFILL[$key]="$val"; fi
    done
  elif command -v python3 &>/dev/null; then
    while IFS="=" read -r k v; do
      if [[ -n "$k" && "$k" != "_"* ]]; then PREFILL[$k]="$v"; fi
    done < <(python3 -c "import json,sys; d=json.load(open('$CONFIG_FILE')); [print(f'{k}={v}') for k,v in d.items() if not k.startswith('_')]" 2>/dev/null || true)
  else
    log_warn "Kein jq/python3 — Prefill übersprungen"
  fi
fi

# Defaults
DEFAULT_USER="${PREFILL[WindowsUser]:-${USER:-RemoteUser}}"
DEFAULT_IP="${PREFILL[YandexVmIp]:-}"
DEFAULT_VMUSER="${PREFILL[YandexVmUser]:-tunneluser}"
DEFAULT_VMPORT="${PREFILL[YandexVmPort]:-22}"
DEFAULT_TUNPORT="${PREFILL[ReverseTunnelPort]:-2222}"
DEFAULT_BUCKET="${PREFILL[YandexBucket]:-}"
DEFAULT_HOST="${PREFILL[Hostname]:-$(hostname -s 2>/dev/null || echo "WINDOWS-PC")}"
DEVICE_ID="${PREFILL[DeviceId]:-$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid;print(uuid.uuid4())" 2>/dev/null || echo "REPLACE_WITH_UUID")}"
STATUS_ENDPOINT="${PREFILL[StatusEndpoint]:-}"
HMAC_SECRET="${PREFILL[HmacSecret]:-}"
# Normalize device id trim
DEVICE_ID="$(echo "$DEVICE_ID" | tr -d '[:space:]')"

if [[ "$NON_INTERACTIVE" == "false" ]]; then
  echo ""
  echo -e "\033[32m── Schritt 1: Windows Zugang (festes Passwort) ──\033[0m"
  echo "Hier legst du dein festes Passwort fest (DEIN_PASSWORT Platzhalter)."
  echo "Leer lassen = nur Key-Auth (sicherer)."

  WINDOWS_USER=$(read_input "Windows Benutzername" "$DEFAULT_USER")
  echo "Benutzer: $WINDOWS_USER"

  # Password with read -s
  if WINDOWS_PASSWORD=$(read_secret "Festes Passwort für $WINDOWS_USER"); then
    USE_PASSWORD_AUTH=true
    log_ok "Passwort gesetzt (privat, nur im Yandex-Skript)!"
  else
    WINDOWS_PASSWORD="DEIN_PASSWORT"
    USE_PASSWORD_AUTH=false
    log_warn "Kein Passwort — Key-only (PasswordAuthentication no)"
  fi

  echo ""
  echo -e "\033[32m── Schritt 2: Yandex Zugang ──\033[0m"
  if [[ -z "$DEFAULT_IP" || "$DEFAULT_IP" == "null" ]]; then DEFAULT_IP=""; fi
  YANDEX_VM_IP=$(read_input "Yandex VM öffentliche IP (z.B. 51.250.12.34, leer=Platzhalter)" "$DEFAULT_IP")
  if [[ -z "$YANDEX_VM_IP" ]]; then YANDEX_VM_IP="DEIN_YANDEX_VM_IP"; fi
  YANDEX_VM_USER=$(read_input "Yandex VM Tunnel Benutzer" "$DEFAULT_VMUSER")
  tmp=$(read_input "Yandex SSH Port" "$DEFAULT_VMPORT"); [[ "$tmp" =~ ^[0-9]+$ ]] && DEFAULT_VMPORT="$tmp"
  YANDEX_VM_PORT="$DEFAULT_VMPORT"
  tmp=$(read_input "Reverse Tunnel Port auf VM" "$DEFAULT_TUNPORT"); [[ "$tmp" =~ ^[0-9]+$ ]] && DEFAULT_TUNPORT="$tmp"
  REVERSE_TUNNEL_PORT="$DEFAULT_TUNPORT"
  YANDEX_BUCKET=$(read_input "Yandex Object Storage Bucket (z.B. my-remotegate-bucket, leer=kein Auto-Upload)" "$DEFAULT_BUCKET")
  read -p "Status Endpoint (HTTPS) konfigurieren? (j/N): " ask
  if [[ "$ask" == "j" || "$ask" == "J" || "$ask" == "y" ]]; then
    STATUS_ENDPOINT=$(read_input "Status Endpoint URL" "$STATUS_ENDPOINT")
    echo -n "HMAC Secret (verdeckt): "
    read -s HMAC_SECRET; echo
    STATUS_ENABLED='$true'
  else
    STATUS_ENABLED='$false'
  fi
  tmp=$(read_input "Windows Hostname" "$DEFAULT_HOST"); [[ -n "$tmp" ]] && DEFAULT_HOST="$tmp"
  HOSTNAME="$DEFAULT_HOST"
else
  # Non-interactive
  WINDOWS_USER="${PREFILL[WindowsUser]:-DEIN_BENUTZER}"
  WINDOWS_PASSWORD="${PREFILL[WindowsPassword]:-DEIN_PASSWORT}"
  if [[ "$WINDOWS_PASSWORD" == "DEIN_PASSWORT" || -z "$WINDOWS_PASSWORD" ]]; then USE_PASSWORD_AUTH=false; else USE_PASSWORD_AUTH=true; fi
  YANDEX_VM_IP="${PREFILL[YandexVmIp]:-DEIN_YANDEX_VM_IP}"
  YANDEX_VM_USER="$DEFAULT_VMUSER"
  YANDEX_VM_PORT="$DEFAULT_VMPORT"
  REVERSE_TUNNEL_PORT="$DEFAULT_TUNPORT"
  YANDEX_BUCKET="$DEFAULT_BUCKET"
  HOSTNAME="$DEFAULT_HOST"
  STATUS_ENABLED='$false'
  if [[ "${PREFILL[StatusEndpoint]:-}" != "" ]]; then STATUS_ENDPOINT="${PREFILL[StatusEndpoint]}"; fi
  log_info "NonInteractive: User=$WINDOWS_USER IP=$YANDEX_VM_IP PassAuth=$USE_PASSWORD_AUTH"
fi

if [[ -z "${YANDEX_BUCKET:-}" ]]; then YANDEX_BUCKET=""; fi
if [[ -z "${STATUS_ENDPOINT:-}" ]]; then STATUS_ENDPOINT=""; fi
if [[ -z "${HMAC_SECRET:-}" ]]; then HMAC_SECRET=""; fi

GENERATION_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

# === Templating via sed ===
echo ""
echo -e "\033[32m── Schritt 3: Generiere FINALEN Installer ──\033[0m"

mkdir -p "$(dirname "$OUTPUT_PATH")"

# Read template
TEMPLATE_CONTENT="$(cat "$TEMPLATE_PATH")"

# Escape for sed: need to handle /, &, \, and for PowerShell also handle quoting
# For password, we already have escaping in PS template, but we need to escape sed special chars
escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g' -e 's/\\/\\\\/g'
}

# Special handling for password: escape PowerShell double-quote context (`", `$ etc.)
escape_pw() {
  local pw="$1"
  # For PowerShell double-quoted string: ` -> ``, " -> `", $ -> `$
  pw="${pw//\`/\"\`\"}"  # this is tricky — do simpler: use python for escaping
  printf '%s' "$pw"
}

# Use python for robust replacement to avoid sed pitfalls with special chars
python3 << PYEOF
import pathlib, os
template = pathlib.Path("$TEMPLATE_PATH").read_text(encoding="utf-8")
replacements = {
    "__WINDOWS_USER__": """$WINDOWS_USER""",
    "__WINDOWS_PASSWORD__": """$WINDOWS_PASSWORD""",
    "__YANDEX_VM_IP__": """$YANDEX_VM_IP""",
    "__YANDEX_VM_USER__": """$YANDEX_VM_USER""",
    "__YANDEX_VM_PORT__": """$YANDEX_VM_PORT""",
    "__REVERSE_TUNNEL_PORT__": """$REVERSE_TUNNEL_PORT""",
    "__STATUS_ENDPOINT__": """$STATUS_ENDPOINT""",
    "__HMAC_SECRET__": """$HMAC_SECRET""",
    "__STATUS_ENABLED__": """$STATUS_ENABLED""",
    "__DEVICE_ID__": """$DEVICE_ID""",
    "__HOSTNAME__": """$HOSTNAME""",
    "__YANDEX_BUCKET__": """$YANDEX_BUCKET""",
    "__GENERATION_TIME__": """$GENERATION_TIME""",
}
# Escape password for PowerShell double-quoted string
pw = replacements["__WINDOWS_PASSWORD__"]
if pw != "DEIN_PASSWORT":
    # Escape for PowerShell: backtick, double-quote, dollar
    pw = pw.replace("\`", "\`\`").replace('"', '\`"').replace("\$", "\`\$")
    replacements["__WINDOWS_PASSWORD__"] = pw

out = template
for k,v in replacements.items():
    out = out.replace(k, v)

# Validate no template placeholders remain (except maybe DEIN_* comments)
# Check for __.*__ pattern
import re
leftovers = re.findall(r'__[A-Z_]+__', out)
if leftovers:
    print(f"WARN: Verbleibende Platzhalter: {leftovers}")

out_path = pathlib.Path("$OUTPUT_PATH")
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(out, encoding="utf-8")
print(f"Generated {len(out)} bytes to {out_path}")
PYEOF

if [[ $? -ne 0 ]]; then
  log_err "Generierung fehlgeschlagen"
  exit 1
fi

FILE_SIZE=$(wc -c < "$OUTPUT_PATH" 2>/dev/null || stat -f%z "$OUTPUT_PATH" 2>/dev/null || echo "?")
log_ok "FINALER Installer geschrieben: $OUTPUT_PATH ($FILE_SIZE Bytes)"
echo "DeviceId: $DEVICE_ID"

# Prepare bool for Python cache
if [[ "$STATUS_ENABLED" == '$true' ]]; then STATUS_ENABLED_PY="True"; else STATUS_ENABLED_PY="False"; fi
# Save prefill cache without password
CACHE_PATH="$SCRIPT_DIR/last-generation.json"
python3 << PYEOF
import json, pathlib
cache = {
    "WindowsUser": """$WINDOWS_USER""",
    "YandexVmIp": """$YANDEX_VM_IP""",
    "YandexVmUser": """$YANDEX_VM_USER""",
    "YandexVmPort": $YANDEX_VM_PORT,
    "ReverseTunnelPort": $REVERSE_TUNNEL_PORT,
    "YandexBucket": """$YANDEX_BUCKET""",
    "StatusEndpoint": """$STATUS_ENDPOINT""",
    "StatusEnabled": $STATUS_ENABLED_PY,
    "Hostname": """$HOSTNAME""",
    "DeviceId": """$DEVICE_ID""",
    "GenerationTime": """$GENERATION_TIME""",
    "UsePasswordAuth": """$USE_PASSWORD_AUTH""".lower() == "true",
    "WindowsPasswordSet": """$USE_PASSWORD_AUTH""".lower() == "true"
}
pathlib.Path("$CACHE_PATH").write_text(json.dumps(cache, indent=2, ensure_ascii=False), encoding="utf-8")
print(f"Cache gespeichert: $CACHE_PATH")
PYEOF

if [[ "$USE_PASSWORD_AUTH" == "true" ]]; then
  echo ""
  echo -e "\033[33m⚠️  WICHTIG: Passwort ist im FINALEN Skript ($OUTPUT_PATH)\033[0m"
  echo -e "\033[33m   — Niemals zu GitHub pushen (dist/ in .gitignore)!\033[0m"
  echo -e "\033[33m   — Nur in privaten Yandex Bucket!\033[0m"
else
  echo ""
  echo -e "\033[36mℹ️  Kein Passwort — Key-only (PasswordAuthentication no)\033[0m"
fi

# === Upload ===
echo ""
echo -e "\033[32m── Schritt 4: Upload nach Yandex ──\033[0m"
if [[ "$SKIP_UPLOAD" == "true" ]]; then
  log_warn "SkipUpload — kein Upload"
elif [[ -z "$YANDEX_BUCKET" ]]; then
  log_warn "Kein Bucket — Upload übersprungen"
  echo "Manuell: ./generator/Upload-ToYandex.ps1 -FilePath \"$OUTPUT_PATH\" -Bucket \"<bucket>\""
  echo "Oder: yc storage s3api put-object --bucket <bucket> --key RemoteGate-Final.ps1 --body \"$OUTPUT_PATH\""
else
  log_info "Versuche Upload nach $YANDEX_BUCKET ..."
  UPLOADER_PS="$SCRIPT_DIR/Upload-ToYandex.ps1"
  UPLOADER_SH="$SCRIPT_DIR/upload-to-yandex.sh"
  if command -v pwsh &>/dev/null; then
    pwsh -File "$UPLOADER_PS" -FilePath "$OUTPUT_PATH" -Bucket "$YANDEX_BUCKET" || log_warn "Upload via pwsh fehlgeschlagen"
  elif command -v powershell &>/dev/null; then
    powershell -File "$UPLOADER_PS" -FilePath "$OUTPUT_PATH" -Bucket "$YANDEX_BUCKET" || log_warn "Upload via powershell fehlgeschlagen"
  elif [[ -f "$UPLOADER_SH" ]]; then
    bash "$UPLOADER_SH" "$OUTPUT_PATH" "$YANDEX_BUCKET" || log_warn "Upload via bash fehlgeschlagen"
  else
    # Try yc directly
    if command -v yc &>/dev/null; then
      yc storage s3api put-object --bucket "$YANDEX_BUCKET" --key RemoteGate-Final.ps1 --body "$OUTPUT_PATH" && log_ok "Upload via yc erfolgreich"
    elif command -v aws &>/dev/null; then
      aws --endpoint-url https://storage.yandexcloud.net s3 cp "$OUTPUT_PATH" "s3://$YANDEX_BUCKET/RemoteGate-Final.ps1" && log_ok "Upload via aws erfolgreich"
    else
      log_warn "KeinUploader gefunden (yc/aws/pwsh). Manuell hochladen."
    fi
  fi
fi

# === Final output ===
cat <<EOF

════════════════════════════════════════════════════════════
  ✅ GENERATOR FERTIG (Mac Bash) — FINALER INSTALLER BEREIT
════════════════════════════════════════════════════════════
  Lokal: $OUTPUT_PATH
EOF
if [[ -n "$YANDEX_BUCKET" ]]; then
  YANDEX_URL="https://storage.yandexcloud.net/$YANDEX_BUCKET/RemoteGate-Final.ps1"
  YANDEX_URL_ALT="https://$YANDEX_BUCKET.storage.yandexcloud.net/RemoteGate-Final.ps1"
  cat <<EOF
  Yandex URLs:
    $YANDEX_URL
    $YANDEX_URL_ALT

  🖥️  WINDOWS INSTALL (aus Yandex, nicht GitHub):
  ┌─────────────────────────────────────────────────────────┐
  │ PowerShell als Administrator, dann:
  │ \$url="$YANDEX_URL"
  │ Invoke-WebRequest -Uri \$url -OutFile \$env:TEMP\\RemoteGate-Final.ps1
  │ & \$env:TEMP\\RemoteGate-Final.ps1
  └─────────────────────────────────────────────────────────┘

  Einzeiler: irm $YANDEX_URL -OutFile \$env:TEMP\\RemoteGate-Final.ps1; & \$env:TEMP\\RemoteGate-Final.ps1
EOF
  echo -e "\033[33m  ⚠️  Privater Bucket — presigned URL für Download nutzen (siehe Upload log)!\033[0m"
else
  cat <<EOF
  Kein Yandex Bucket — lokal übertragen:
    scp "$OUTPUT_PATH" WINDOWS-PC:/tmp/RemoteGate-Final.ps1
    # Auf Windows als Admin: & C:\\tmp\\RemoteGate-Final.ps1

  Oder: ./generator/Upload-ToYandex.ps1 -FilePath "$OUTPUT_PATH" -Bucket "<bucket>"
EOF
fi
cat <<EOF
  Nächste: ssh -J rgadmin@$YANDEX_VM_IP -p $REVERSE_TUNNEL_PORT $WINDOWS_USER@127.0.0.1
════════════════════════════════════════════════════════════

EOF

# Clear sensitive
WINDOWS_PASSWORD=""
HMAC_SECRET=""
