#!/bin/bash
# RemoteGate Generator — Bash version for Mac (no PowerShell needed)
# Works on macOS Bash 3.2 (no associative arrays) — fixed for generate_template.command
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
    # Strength check — use case statements for Bash 3.2 compat
    issues=""
    if [[ ${#val} -lt 12 ]]; then issues="$issues • ≥12 Zeichen (du hast ${#val})"$'\n'; fi
    case "$val" in *[A-Z]*) ;; *) issues="$issues • Großbuchstabe"$'\n';; esac
    case "$val" in *[a-z]*) ;; *) issues="$issues • Kleinbuchstabe"$'\n';; esac
    case "$val" in *[0-9]*) ;; *) issues="$issues • Zahl"$'\n';; esac
    case "$val" in *[^a-zA-Z0-9]*) ;; *) issues="$issues • Sonderzeichen"$'\n';; esac
    case "$val" in *"DEIN_PASSWORT"*|*password*) issues="$issues • Zu einfach / Platzhalter"$'\n';; esac
    if [[ -n "$issues" ]]; then
      echo -e "\033[33m  ⚠️  Schwach:\033[0m"
      echo -e "$issues" | sed 's/^/     /'
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

# JSON helper — works without jq/python assoc arrays, Bash 3.2 safe
json_get() {
  local file="$1" key="$2"
  if [[ ! -f "$file" ]]; then echo ""; return; fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json; print(json.load(open('$file')).get('$key', ''))" 2>/dev/null || echo ""
  elif command -v python >/dev/null 2>&1; then
    python -c "import json; print(json.load(open('$file')).get('$key', ''))" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# === Start ===
banner
echo "Repo: $REPO_ROOT"
echo "Template: $TEMPLATE_PATH"
if [[ ! -f "$TEMPLATE_PATH" ]]; then
  log_err "Template nicht gefunden: $TEMPLATE_PATH"
  exit 1
fi

# Load prefill if config file provided — Bash 3.2 safe (no declare -A)
CFG_WindowsUser=""
CFG_WindowsPassword=""
CFG_YandexVmIp=""
CFG_YandexVmUser=""
CFG_YandexVmPort=""
CFG_ReverseTunnelPort=""
CFG_YandexBucket=""
CFG_StatusEndpoint=""
CFG_HmacSecret=""
CFG_StatusEnabled=""
CFG_Hostname=""
CFG_DeviceId=""

if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  log_info "Prefill aus $CONFIG_FILE"
  if command -v jq >/dev/null 2>&1; then
    CFG_WindowsUser=$(jq -r '."WindowsUser" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_WindowsPassword=$(jq -r '."WindowsPassword" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_YandexVmIp=$(jq -r '."YandexVmIp" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_YandexVmUser=$(jq -r '."YandexVmUser" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_YandexVmPort=$(jq -r '."YandexVmPort" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_ReverseTunnelPort=$(jq -r '."ReverseTunnelPort" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_YandexBucket=$(jq -r '."YandexBucket" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_StatusEndpoint=$(jq -r '."StatusEndpoint" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_HmacSecret=$(jq -r '."HmacSecret" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_StatusEnabled=$(jq -r '."StatusEnabled" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_Hostname=$(jq -r '."Hostname" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_DeviceId=$(jq -r '."DeviceId" // empty' "$CONFIG_FILE" 2>/dev/null || true)
  elif command -v python3 >/dev/null 2>&1; then
    CFG_WindowsUser=$(json_get "$CONFIG_FILE" "WindowsUser")
    CFG_WindowsPassword=$(json_get "$CONFIG_FILE" "WindowsPassword")
    CFG_YandexVmIp=$(json_get "$CONFIG_FILE" "YandexVmIp")
    CFG_YandexVmUser=$(json_get "$CONFIG_FILE" "YandexVmUser")
    CFG_YandexVmPort=$(json_get "$CONFIG_FILE" "YandexVmPort")
    CFG_ReverseTunnelPort=$(json_get "$CONFIG_FILE" "ReverseTunnelPort")
    CFG_YandexBucket=$(json_get "$CONFIG_FILE" "YandexBucket")
    CFG_StatusEndpoint=$(json_get "$CONFIG_FILE" "StatusEndpoint")
    CFG_HmacSecret=$(json_get "$CONFIG_FILE" "HmacSecret")
    CFG_StatusEnabled=$(json_get "$CONFIG_FILE" "StatusEnabled")
    CFG_Hostname=$(json_get "$CONFIG_FILE" "Hostname")
    CFG_DeviceId=$(json_get "$CONFIG_FILE" "DeviceId")
  else
    log_warn "Kein jq/python3 — Prefill übersprungen"
  fi
  # Clean "null" strings from jq
  for v in CFG_WindowsUser CFG_WindowsPassword CFG_YandexVmIp CFG_YandexVmUser CFG_YandexVmPort CFG_ReverseTunnelPort CFG_YandexBucket CFG_StatusEndpoint CFG_HmacSecret CFG_StatusEnabled CFG_Hostname CFG_DeviceId; do
    eval "val=\$$v"
    if [[ "$val" == "null" ]]; then eval "$v=\"\""; fi
  done
fi

# Defaults — Bash 3.2 safe (no associative array)
if [[ -n "$CFG_WindowsUser" ]]; then DEFAULT_USER="$CFG_WindowsUser"; else DEFAULT_USER="${USER:-RemoteUser}"; fi
if [[ -n "$CFG_YandexVmIp" ]]; then DEFAULT_IP="$CFG_YandexVmIp"; else DEFAULT_IP=""; fi
if [[ -n "$CFG_YandexVmUser" ]]; then DEFAULT_VMUSER="$CFG_YandexVmUser"; else DEFAULT_VMUSER="tunneluser"; fi
if [[ -n "$CFG_YandexVmPort" ]]; then DEFAULT_VMPORT="$CFG_YandexVmPort"; else DEFAULT_VMPORT="22"; fi
if [[ -n "$CFG_ReverseTunnelPort" ]]; then DEFAULT_TUNPORT="$CFG_ReverseTunnelPort"; else DEFAULT_TUNPORT="2222"; fi
if [[ -n "$CFG_YandexBucket" ]]; then DEFAULT_BUCKET="$CFG_YandexBucket"; else DEFAULT_BUCKET=""; fi
if [[ -n "$CFG_Hostname" ]]; then DEFAULT_HOST="$CFG_Hostname"; else DEFAULT_HOST="$(hostname -s 2>/dev/null || echo "WINDOWS-PC")"; fi
if [[ -n "$CFG_DeviceId" && "$CFG_DeviceId" != "REPLACE_WITH_UUID" ]]; then DEVICE_ID="$CFG_DeviceId"; else DEVICE_ID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid;print(uuid.uuid4())" 2>/dev/null || echo "REPLACE_WITH_UUID")"; fi
if [[ -n "$CFG_StatusEndpoint" ]]; then STATUS_ENDPOINT="$CFG_StatusEndpoint"; else STATUS_ENDPOINT=""; fi
if [[ -n "$CFG_HmacSecret" ]]; then HMAC_SECRET="$CFG_HmacSecret"; else HMAC_SECRET=""; fi
DEVICE_ID="$(echo "$DEVICE_ID" | tr -d '[:space:]')"

if [[ "$NON_INTERACTIVE" == "false" ]]; then
  echo ""
  echo -e "\033[32m── Schritt 1: Windows Zugang (festes Passwort) ──\033[0m"
  echo "Hier legst du dein festes Passwort fest (DEIN_PASSWORT Platzhalter)."
  echo -e "\033[36mℹ️  Windows Benutzername wird NICHT hier abgefragt —\033[0m"
  echo -e "\033[36m   der Windows PC erkennt ihn automatisch beim Installieren.\033[0m"
  echo "Leer lassen = nur Key-Auth (sicherer)."
  echo -e "\033[33mHinweis: Passwort-Eingabe ist unsichtbar (Sicherheit) — tippe + Enter, siehst nichts, ist normal.\033[0m"

  # Windows Benutzer wird automatisch auf Windows erkannt — kein Mac-Prompt mehr
  WINDOWS_USER="DEIN_BENUTZER"
  log_info "Windows Benutzer: AUTO (wird auf Windows erkannt, kein Mac-Prompt)"
  echo -e "\033[32m  → Windows Benutzer: Automatische Erkennung auf dem Windows PC\033[0m"

  if WINDOWS_PASSWORD=$(read_secret "Festes Passwort für Windows SSH (verdeckt, leer=nur Key-Auth)"); then
    USE_PASSWORD_AUTH=true
    log_ok "Passwort gesetzt (privat, nur im Yandex-Skript)!  (${#WINDOWS_PASSWORD} Zeichen erfasst)"
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
  tmp=$(read_input "Yandex SSH Port" "$DEFAULT_VMPORT"); case "$tmp" in ''|*[!0-9]* ) ;; *) DEFAULT_VMPORT="$tmp";; esac
  YANDEX_VM_PORT="$DEFAULT_VMPORT"
  tmp=$(read_input "Reverse Tunnel Port auf VM" "$DEFAULT_TUNPORT"); case "$tmp" in ''|*[!0-9]* ) ;; *) DEFAULT_TUNPORT="$tmp";; esac
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
  if [[ -n "$CFG_WindowsUser" ]]; then WINDOWS_USER="$CFG_WindowsUser"; else WINDOWS_USER="DEIN_BENUTZER"; fi
  if [[ -n "$CFG_WindowsPassword" ]]; then WINDOWS_PASSWORD="$CFG_WindowsPassword"; else WINDOWS_PASSWORD="DEIN_PASSWORT"; fi
  if [[ "$WINDOWS_PASSWORD" == "DEIN_PASSWORT" || -z "$WINDOWS_PASSWORD" ]]; then USE_PASSWORD_AUTH=false; else USE_PASSWORD_AUTH=true; fi
  if [[ -n "$CFG_YandexVmIp" ]]; then YANDEX_VM_IP="$CFG_YandexVmIp"; else YANDEX_VM_IP="DEIN_YANDEX_VM_IP"; fi
  YANDEX_VM_USER="$DEFAULT_VMUSER"
  YANDEX_VM_PORT="$DEFAULT_VMPORT"
  REVERSE_TUNNEL_PORT="$DEFAULT_TUNPORT"
  YANDEX_BUCKET="$DEFAULT_BUCKET"
  HOSTNAME="$DEFAULT_HOST"
  STATUS_ENABLED='$false'
  if [[ -n "$CFG_StatusEndpoint" ]]; then STATUS_ENDPOINT="$CFG_StatusEndpoint"; fi
  log_info "NonInteractive: User=$WINDOWS_USER IP=$YANDEX_VM_IP PassAuth=$USE_PASSWORD_AUTH"
fi

if [[ -z "${YANDEX_BUCKET:-}" ]]; then YANDEX_BUCKET=""; fi
if [[ -z "${STATUS_ENDPOINT:-}" ]]; then STATUS_ENDPOINT=""; fi
if [[ -z "${HMAC_SECRET:-}" ]]; then HMAC_SECRET=""; fi

GENERATION_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

# === Templating ===
echo ""
echo -e "\033[32m── Schritt 3: Generiere FINALEN Installer ──\033[0m"

mkdir -p "$(dirname "$OUTPUT_PATH")"

# Use python for robust replacement to avoid sed pitfalls with special chars
python3 << PYEOF
import pathlib
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
    pw = pw.replace("\`", "\`\`").replace('"', '\`"').replace("\$", "\`\$")
    replacements["__WINDOWS_PASSWORD__"] = pw

out = template
for k,v in replacements.items():
    out = out.replace(k, v)

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
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -File "$UPLOADER_PS" -FilePath "$OUTPUT_PATH" -Bucket "$YANDEX_BUCKET" || log_warn "Upload via pwsh fehlgeschlagen"
  elif command -v powershell >/dev/null 2>&1; then
    powershell -File "$UPLOADER_PS" -FilePath "$OUTPUT_PATH" -Bucket "$YANDEX_BUCKET" || log_warn "Upload via powershell fehlgeschlagen"
  else
    if command -v yc >/dev/null 2>&1; then
      yc storage s3api put-object --bucket "$YANDEX_BUCKET" --key RemoteGate-Final.ps1 --body "$OUTPUT_PATH" && log_ok "Upload via yc erfolgreich"
    elif command -v aws >/dev/null 2>&1; then
      aws --endpoint-url https://storage.yandexcloud.net s3 cp "$OUTPUT_PATH" "s3://$YANDEX_BUCKET/RemoteGate-Final.ps1" && log_ok "Upload via aws erfolgreich"
    else
      log_warn "Kein Uploader gefunden (yc/aws/pwsh). Manuell hochladen."
    fi
  fi
fi

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
  echo -e "\033[33m  ⚠️  Privater Bucket — presigned URL für Download nutzen!\033[0m"
else
  cat <<EOF
  Kein Yandex Bucket — lokal übertragen:
    scp "$OUTPUT_PATH" WINDOWS-PC:/tmp/RemoteGate-Final.ps1
    # Auf Windows als Admin: & C:\\tmp\\RemoteGate-Final.ps1
EOF
fi
cat <<EOF
  Nächste: ssh -J rgadmin@$YANDEX_VM_IP -p $REVERSE_TUNNEL_PORT $WINDOWS_USER@127.0.0.1
════════════════════════════════════════════════════════════

EOF

WINDOWS_PASSWORD=""
HMAC_SECRET=""
