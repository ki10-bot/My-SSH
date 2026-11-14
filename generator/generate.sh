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
CFG_CloudProvider=""
CFG_CloudEndpoint=""
CFG_CloudflareTunnelToken=""
CFG_CloudflareHostname=""
CFG_CloudflareTunnelName=""
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
    CFG_CloudProvider=$(jq -r '."CloudProvider" // .CloudBucket // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_CloudEndpoint=$(jq -r '."CloudEndpoint" // .S3Endpoint // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_CloudflareTunnelToken=$(jq -r '."CloudflareTunnelToken" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_CloudflareHostname=$(jq -r '."CloudflareHostname" // empty' "$CONFIG_FILE" 2>/dev/null || true)
    CFG_CloudflareTunnelName=$(jq -r '."CloudflareTunnelName" // empty' "$CONFIG_FILE" 2>/dev/null || true)
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
    CFG_CloudProvider=$(json_get "$CONFIG_FILE" "CloudProvider")
    CFG_CloudEndpoint=$(json_get "$CONFIG_FILE" "CloudEndpoint")
    CFG_CloudflareTunnelToken=$(json_get "$CONFIG_FILE" "CloudflareTunnelToken")
    CFG_CloudflareHostname=$(json_get "$CONFIG_FILE" "CloudflareHostname")
    CFG_CloudflareTunnelName=$(json_get "$CONFIG_FILE" "CloudflareTunnelName")
    CFG_StatusEndpoint=$(json_get "$CONFIG_FILE" "StatusEndpoint")
    CFG_HmacSecret=$(json_get "$CONFIG_FILE" "HmacSecret")
    CFG_StatusEnabled=$(json_get "$CONFIG_FILE" "StatusEnabled")
    CFG_Hostname=$(json_get "$CONFIG_FILE" "Hostname")
    CFG_DeviceId=$(json_get "$CONFIG_FILE" "DeviceId")
  else
    log_warn "Kein jq/python3 — Prefill übersprungen"
  fi
  # Clean "null" strings from jq
  for v in CFG_WindowsUser CFG_WindowsPassword CFG_YandexVmIp CFG_YandexVmUser CFG_YandexVmPort CFG_ReverseTunnelPort CFG_YandexBucket CFG_CloudProvider CFG_CloudEndpoint CFG_CloudflareTunnelToken CFG_CloudflareHostname CFG_CloudflareTunnelName CFG_StatusEndpoint CFG_HmacSecret CFG_StatusEnabled CFG_Hostname CFG_DeviceId; do
    eval "val=\$$v"
    if [[ "$val" == "null" ]]; then eval "$v=\"\""; fi
  done
  # Backward compat: YandexBucket alias for Yandex-era configs
  if [[ -z "$CFG_CloudEndpoint" && -n "$CFG_YandexBucket" ]]; then
    : # keep bucket
  fi
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
if [[ -n "$CFG_CloudProvider" ]]; then DEFAULT_PROVIDER="$CFG_CloudProvider"; else DEFAULT_PROVIDER="cloudru"; fi
if [[ -n "$CFG_CloudEndpoint" ]]; then DEFAULT_ENDPOINT="$CFG_CloudEndpoint"; else DEFAULT_ENDPOINT="https://s3.cloud.ru"; fi
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
    log_ok "Passwort gesetzt (privat, nur im Cloud-Skript)!  (${#WINDOWS_PASSWORD} Zeichen erfasst)"
  else
    WINDOWS_PASSWORD="DEIN_PASSWORT"
    USE_PASSWORD_AUTH=false
    log_warn "Kein Passwort — Key-only (PasswordAuthentication no)"
  fi

  echo ""
  echo -e "\033[32m── Schritt 2: Verbindung — wähle kostenlose Option ──\033[0m"
  echo -e "\033[36m  [1] Cloudflare Tunnel (0 ₽, empfohlen, keine VM/IP nötig) — docs/CLOUDFLARE-TUNNEL-GUIDE.md\033[0m"
  echo -e "\033[33m  [2] Cloud.ru VM (gratis VM, aber IP ~149 ₽/Mo) — alt\033[0m"
  echo -e "\033[33m  [3] Yandex VM (~500 ₽/Mo) — alt\033[0m"
  echo "  Wähle: [1/2/3, Enter=1 Cloudflare Tunnel]"
  prov=$(read_input "  Anbieter" "${DEFAULT_PROVIDER:-cloudflare}")
  # Normalize: default to cloudflare
  case "$prov" in
    1|cloudflare|Cloudflare|"") CLOUD_PROVIDER="cloudflare"; CLOUD_ENDPOINT="https://s3.cloud.ru" ;;
    2|cloudru|cloud.ru) CLOUD_PROVIDER="cloudru"; CLOUD_ENDPOINT="https://s3.cloud.ru" ;;
    3|yandex|Yandex) CLOUD_PROVIDER="yandex"; CLOUD_ENDPOINT="https://storage.yandexcloud.net" ;;
    *) CLOUD_PROVIDER="cloudflare"; CLOUD_ENDPOINT="https://s3.cloud.ru" ;;
  esac

  # Cloudflare mode: ask Tunnel Token + Hostname + Bucket, no VM IP
  if [[ "$CLOUD_PROVIDER" == "cloudflare" ]]; then
    log_info "Anbieter: Cloudflare Tunnel (0 ₽, keine VM) → S3 $CLOUD_ENDPOINT"
    echo -e "\033[36m  ℹ️  Cloudflare braucht: Token (eyJh...) + Hostname (ssh.deinedomain.ru)\033[0m"
    echo "  Siehe docs/CLOUDFLARE-TUNNEL-GUIDE.md → Schritt 3 (Zero Trust → Tunnels → Create → Token)"
    echo -n "  Cloudflare Tunnel Token (eyJh..., verdeckt, leer=Platzhalter): "
    read -s CLOUDFLARE_TUNNEL_TOKEN; echo
    if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then CLOUDFLARE_TUNNEL_TOKEN="DEIN_CLOUDFLARE_TOKEN"; fi
    CLOUDFLARE_HOSTNAME=$(read_input "  Public Hostname (z.B. ssh.deinedomain.ru, leer=Platzhalter)" "")
    if [[ -z "$CLOUDFLARE_HOSTNAME" ]]; then CLOUDFLARE_HOSTNAME="DEIN_HOSTNAME"; fi
    CLOUDFLARE_TUNNEL_NAME=$(read_input "  Tunnel Name" "remotegate-ssh")
    YANDEX_BUCKET=$(read_input "  Object Storage Bucket für Final-Skript (Cloud.ru S3, z.B. remotegate-ki10-2026, leer=kein Auto-Upload)" "$DEFAULT_BUCKET")
    # Dummy VM values unused in cloudflare mode
    YANDEX_VM_IP="CLOUDFLARE_MODE"
    YANDEX_VM_USER="cloudflare"
    YANDEX_VM_PORT=22
    REVERSE_TUNNEL_PORT=2222
    log_ok "Cloudflare Modus: $CLOUDFLARE_TUNNEL_NAME → $CLOUDFLARE_HOSTNAME"
  else
    log_info "Anbieter: $CLOUD_PROVIDER → $CLOUD_ENDPOINT"
    if [[ -z "$DEFAULT_IP" || "$DEFAULT_IP" == "null" ]]; then DEFAULT_IP=""; fi
    YANDEX_VM_IP=$(read_input "  VM öffentliche IP (z.B. 51.250.12.34, leer=Platzhalter)" "$DEFAULT_IP")
    if [[ -z "$YANDEX_VM_IP" ]]; then YANDEX_VM_IP="DEIN_YANDEX_VM_IP"; fi
    YANDEX_VM_USER=$(read_input "  VM Tunnel Benutzer" "$DEFAULT_VMUSER")
    tmp=$(read_input "  VM SSH Port" "$DEFAULT_VMPORT"); case "$tmp" in ''|*[!0-9]* ) ;; *) DEFAULT_VMPORT="$tmp";; esac
    YANDEX_VM_PORT="$DEFAULT_VMPORT"
    tmp=$(read_input "  Reverse Tunnel Port auf VM" "$DEFAULT_TUNPORT"); case "$tmp" in ''|*[!0-9]* ) ;; *) DEFAULT_TUNPORT="$tmp";; esac
    REVERSE_TUNNEL_PORT="$DEFAULT_TUNPORT"
    YANDEX_BUCKET=$(read_input "  Object Storage Bucket für Final-Skript (z.B. my-remotegate-bucket, leer=kein Auto-Upload) — $CLOUD_PROVIDER" "$DEFAULT_BUCKET")
    CLOUDFLARE_TUNNEL_TOKEN="DEIN_CLOUDFLARE_TOKEN"
    CLOUDFLARE_HOSTNAME="DEIN_HOSTNAME"
    CLOUDFLARE_TUNNEL_NAME="remotegate-ssh"
  fi
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
  # Cloudflare fields for non-interactive
  CLOUDFLARE_TUNNEL_TOKEN="${CFG_CloudflareTunnelToken:-DEIN_CLOUDFLARE_TOKEN}"
  CLOUDFLARE_HOSTNAME="${CFG_CloudflareHostname:-DEIN_HOSTNAME}"
  CLOUDFLARE_TUNNEL_NAME="${CFG_CloudflareTunnelName:-remotegate-ssh}"
  if [[ -n "$CFG_CloudflareHostname" ]]; then CLOUDFLARE_HOSTNAME="$CFG_CloudflareHostname"; fi
  if [[ -n "$CFG_CloudflareTunnelToken" ]]; then CLOUDFLARE_TUNNEL_TOKEN="$CFG_CloudflareTunnelToken"; fi
  CLOUD_PROVIDER="${DEFAULT_PROVIDER:-cloudflare}"
  CLOUD_ENDPOINT="${DEFAULT_ENDPOINT:-https://s3.cloud.ru}"
  if [[ -n "$CFG_CloudProvider" ]]; then CLOUD_PROVIDER="$CFG_CloudProvider"; fi
  if [[ -n "$CFG_CloudEndpoint" ]]; then CLOUD_ENDPOINT="$CFG_CloudEndpoint"; fi
  # If Cloudflare token present, force provider cloudflare
  if [[ "$CLOUDFLARE_TUNNEL_TOKEN" != "DEIN_CLOUDFLARE_TOKEN" && -n "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then CLOUD_PROVIDER="cloudflare"; YANDEX_VM_IP="CLOUDFLARE_MODE"; fi
  HOSTNAME="$DEFAULT_HOST"
  STATUS_ENABLED='$false'
  if [[ -n "$CFG_StatusEndpoint" ]]; then STATUS_ENDPOINT="$CFG_StatusEndpoint"; fi
  log_info "NonInteractive: User=$WINDOWS_USER IP=$YANDEX_VM_IP Bucket=$YANDEX_BUCKET Provider=$CLOUD_PROVIDER Hostname=$CLOUDFLARE_HOSTNAME PassAuth=$USE_PASSWORD_AUTH"
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
    "__CLOUD_BUCKET__": """$YANDEX_BUCKET""",
    "__CLOUD_PROVIDER__": """$CLOUD_PROVIDER""",
    "__S3_ENDPOINT__": """$CLOUD_ENDPOINT""",
    "__CLOUDFLARE_TUNNEL_TOKEN__": """$CLOUDFLARE_TUNNEL_TOKEN""",
    "__CLOUDFLARE_HOSTNAME__": """$CLOUDFLARE_HOSTNAME""",
    "__CLOUDFLARE_TUNNEL_NAME__": """$CLOUDFLARE_TUNNEL_NAME""",
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
    "CloudBucket": """$YANDEX_BUCKET""",
    "CloudProvider": """$CLOUD_PROVIDER""",
    "CloudEndpoint": """$CLOUD_ENDPOINT""",
    "S3Endpoint": """$CLOUD_ENDPOINT""",
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
  echo -e "\033[33m   — Nur in privaten $CLOUD_PROVIDER Bucket ($CLOUD_ENDPOINT)!\033[0m"
else
  echo ""
  echo -e "\033[36mℹ️  Kein Passwort — Key-only (PasswordAuthentication no)\033[0m"
fi

echo ""
echo -e "\033[32m── Schritt 4: Upload nach $CLOUD_PROVIDER ──\033[0m"
if [[ "$SKIP_UPLOAD" == "true" ]]; then
  log_warn "SkipUpload — kein Upload"
elif [[ -z "$YANDEX_BUCKET" ]]; then
  log_warn "Kein Bucket — Upload übersprungen"
  echo "Manuell: ./generator/Upload-ToCloud.ps1 -FilePath \"$OUTPUT_PATH\" -Bucket \"<bucket>\" -Endpoint \"$CLOUD_ENDPOINT\""
  echo "Oder: aws s3 cp \"$OUTPUT_PATH\" \"s3://<bucket>/RemoteGate-Final.ps1\" --endpoint-url \"$CLOUD_ENDPOINT\""
else
  log_info "Versuche Upload nach $CLOUD_PROVIDER Bucket $YANDEX_BUCKET ($CLOUD_ENDPOINT) ..."
  UPLOADER_PS="$SCRIPT_DIR/Upload-ToCloud.ps1"
  if [[ -f "$UPLOADER_PS" ]]; then
    if command -v pwsh >/dev/null 2>&1; then
      pwsh -File "$UPLOADER_PS" -FilePath "$OUTPUT_PATH" -Bucket "$YANDEX_BUCKET" -Endpoint "$CLOUD_ENDPOINT" || log_warn "Upload via pwsh fehlgeschlagen"
    elif command -v powershell >/dev/null 2>&1; then
      powershell -File "$UPLOADER_PS" -FilePath "$OUTPUT_PATH" -Bucket "$YANDEX_BUCKET" -Endpoint "$CLOUD_ENDPOINT" || log_warn "Upload via powershell fehlgeschlagen"
    else
      log_warn "Kein pwsh — versuche yc/aws direkt"
      if [[ "$CLOUD_PROVIDER" == "yandex" ]] && command -v yc >/dev/null 2>&1; then
        yc storage s3api put-object --bucket "$YANDEX_BUCKET" --key RemoteGate-Final.ps1 --body "$OUTPUT_PATH" && log_ok "Upload via yc erfolgreich"
      elif command -v aws >/dev/null 2>&1; then
        aws --endpoint-url "$CLOUD_ENDPOINT" s3 cp "$OUTPUT_PATH" "s3://$YANDEX_BUCKET/RemoteGate-Final.ps1" && log_ok "Upload via aws ($CLOUD_PROVIDER) erfolgreich"
      else
        log_warn "Kein Uploader (yc/aws/pwsh). Manuell: aws s3 cp --endpoint-url $CLOUD_ENDPOINT"
      fi
    fi
  else
    # Fallback legacy
    if [[ "$CLOUD_PROVIDER" == "yandex" ]] && command -v yc >/dev/null 2>&1; then
      yc storage s3api put-object --bucket "$YANDEX_BUCKET" --key RemoteGate-Final.ps1 --body "$OUTPUT_PATH" && log_ok "Upload via yc erfolgreich"
    elif command -v aws >/dev/null 2>&1; then
      aws --endpoint-url "$CLOUD_ENDPOINT" s3 cp "$OUTPUT_PATH" "s3://$YANDEX_BUCKET/RemoteGate-Final.ps1" && log_ok "Upload via aws erfolgreich"
    else
      log_warn "Kein Uploader gefunden (yc/aws/pwsh). Manuell hochladen."
    fi
  fi
fi

cat <<EOF

════════════════════════════════════════════════════════════
  ✅ GENERATOR FERTIG (Mac Bash) — FINALER INSTALLER BEREIT ($CLOUD_PROVIDER)
════════════════════════════════════════════════════════════
  Lokal: $OUTPUT_PATH
EOF
if [[ -n "$YANDEX_BUCKET" ]]; then
  if [[ "$CLOUD_PROVIDER" == "cloudru" ]]; then
    CLOUD_URL="https://$YANDEX_BUCKET.s3.cloud.ru/RemoteGate-Final.ps1"
    CLOUD_URL_ALT="https://s3.cloud.ru/$YANDEX_BUCKET/RemoteGate-Final.ps1"
  else
    CLOUD_URL="https://storage.yandexcloud.net/$YANDEX_BUCKET/RemoteGate-Final.ps1"
    CLOUD_URL_ALT="https://$YANDEX_BUCKET.storage.yandexcloud.net/RemoteGate-Final.ps1"
  fi
  cat <<EOF
  $CLOUD_PROVIDER URLs:
    $CLOUD_URL
    $CLOUD_URL_ALT

  🖥️  WINDOWS INSTALL (aus $CLOUD_PROVIDER, nicht GitHub):
  ┌─────────────────────────────────────────────────────────┐
  │ PowerShell als Administrator, dann:
  │ \$url="$CLOUD_URL"
  │ Invoke-WebRequest -Uri \$url -OutFile \$env:TEMP\\RemoteGate-Final.ps1
  │ & \$env:TEMP\\RemoteGate-Final.ps1
  └─────────────────────────────────────────────────────────┘

  Einzeiler: irm $CLOUD_URL -OutFile \$env:TEMP\\RemoteGate-Final.ps1; & \$env:TEMP\\RemoteGate-Final.ps1
  Presigned (privat): aws s3 presign s3://$YANDEX_BUCKET/RemoteGate-Final.ps1 --endpoint-url $CLOUD_ENDPOINT --expires-in 604800
EOF
  echo -e "\033[33m  ⚠️  Privater Bucket — presigned URL für Download nutzen!\033[0m"
else
  cat <<EOF
  Kein Bucket — lokal übertragen:
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
