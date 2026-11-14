#!/bin/bash
# RemoteGate — einfacher Generator (Mac, Bash 3.2 safe) — Tailscale Standard (keine Karte)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$REPO_ROOT/templates/RemoteGate-Deployment.template.ps1"
DEFAULT_OUTPUT="$REPO_ROOT/dist/RemoteGate-Final.ps1"
CONFIG_FILE=""; NON_INTERACTIVE=false; SKIP_UPLOAD=false; OUTPUT_PATH="$DEFAULT_OUTPUT"
while [[ $# -gt 0 ]]; do case "$1" in --config) CONFIG_FILE="$2"; shift 2;; --output) OUTPUT_PATH="$2"; shift 2;; --non-interactive) NON_INTERACTIVE=true; shift;; --skip-upload) SKIP_UPLOAD=true; shift;; -h|--help) echo "Usage: $0 [--config file.json] [--skip-upload]"; exit 0;; *) echo "Unknown: $1"; exit 1;; esac; done
log_ok(){ echo "✓ $*"; }; log_warn(){ echo "! $*"; }
read_input(){ local p="$1" d="$2" v; if [[ -n "$d" ]]; then read -p "$p [$d]: " v; echo "${v:-$d}"; else read -p "$p: " v; echo "$v"; fi; }
read_secret(){ local p="$1" v c; while true; do echo -n "$p: "; read -s v; echo; if [[ -z "$v" ]]; then return 1; fi; echo -n "  nochmal: "; read -s c; echo; if [[ "$v" != "$c" ]]; then echo "  ≠ nochmal"; continue; fi; echo "$v"; return 0; done; }
json_get(){ local f="$1" k="$2"; if [[ ! -f "$f" ]]; then echo ""; return; fi; python3 -c "import json; print(json.load(open('$f')).get('$k',''))" 2>/dev/null || echo ""; }

echo "RemoteGate — einfach (0 ₽, keine Karte)"
echo "Repo: $REPO_ROOT"
if [[ ! -f "$TEMPLATE_PATH" ]]; then echo "Template fehlt"; exit 1; fi

CFG_WindowsPassword=""; CFG_YandexBucket=""; CFG_TailscaleAuthKey=""; CFG_CloudflareTunnelToken=""; CFG_CloudflareHostname=""; CFG_DeviceId=""
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  CFG_WindowsPassword=$(json_get "$CONFIG_FILE" "WindowsPassword")
  CFG_YandexBucket=$(json_get "$CONFIG_FILE" "YandexBucket")
  CFG_TailscaleAuthKey=$(json_get "$CONFIG_FILE" "TailscaleAuthKey")
  CFG_CloudflareTunnelToken=$(json_get "$CONFIG_FILE" "CloudflareTunnelToken")
  CFG_CloudflareHostname=$(json_get "$CONFIG_FILE" "CloudflareHostname")
  CFG_DeviceId=$(json_get "$CONFIG_FILE" "DeviceId")
  for v in CFG_WindowsPassword CFG_YandexBucket CFG_TailscaleAuthKey CFG_CloudflareTunnelToken CFG_CloudflareHostname CFG_DeviceId; do eval "val=\$$v"; if [[ "$val" == "null" ]]; then eval "$v=\"\""; fi; done
fi
if [[ -n "$CFG_YandexBucket" ]]; then DEFAULT_BUCKET="$CFG_YandexBucket"; else DEFAULT_BUCKET=""; fi
if [[ -n "$CFG_DeviceId" && "$CFG_DeviceId" != "REPLACE_WITH_UUID" ]]; then DEVICE_ID="$CFG_DeviceId"; else DEVICE_ID="$(uuidgen 2>/dev/null || python3 -c "import uuid;print(uuid.uuid4())" 2>/dev/null || echo "REPLACE_WITH_UUID")"; fi
DEVICE_ID="$(echo "$DEVICE_ID" | tr -d '[:space:]')"
DEFAULT_HOST="$(hostname -s 2>/dev/null || echo "WINDOWS-PC")"

YANDEX_VM_IP="CLOUDFLARE_MODE"; YANDEX_VM_USER="cloudflare"; YANDEX_VM_PORT=22; REVERSE_TUNNEL_PORT=2222; CLOUDFLARE_TUNNEL_NAME="remotegate-ssh"; CLOUD_ENDPOINT="https://s3.cloud.ru"; HOSTNAME="$DEFAULT_HOST"; STATUS_ENABLED='$false'; STATUS_ENDPOINT=""; HMAC_SECRET=""
if [[ "$NON_INTERACTIVE" == "false" ]]; then
  echo ""
  echo "1) Passwort für Windows (verdeckt, Enter = nur Key)"
  if WINDOWS_PASSWORD=$(read_secret "Passwort"); then USE_PASSWORD_AUTH=true; log_ok "Passwort ok"; else WINDOWS_PASSWORD="DEIN_PASSWORT"; USE_PASSWORD_AUTH=false; fi
  echo ""
  echo "2) Verbindung — wie willst du dich verbinden?"
  echo "   [1] Tailscale (0 ₽, keine Karte, keine Domain) ★ empfohlen"
  echo "   [2] Cloudflare Tunnel (0 ₽, braucht Domain)"
  echo "   [3] VM (Cloud.ru/Yandex, kostet IP)"
  choice=$(read_input "Wähle [1/2/3, Enter=1]" "1")
  case "$choice" in 2) CLOUD_PROVIDER="cloudflare";; 3) CLOUD_PROVIDER="vm";; *) CLOUD_PROVIDER="tailscale";; esac

  if [[ "$CLOUD_PROVIDER" == "tailscale" ]]; then
    echo "   Tailscale = kein Token nötig. Nur auf Windows + Mac installieren, einloggen."
    echo -n "   Auth-Key (optional, Enter = ohne, loggst dich später im Browser ein): "; read -s TAILSCALE_AUTHKEY; echo
    if [[ -z "$TAILSCALE_AUTHKEY" ]]; then TAILSCALE_AUTHKEY="DEIN_TAILSCALE_KEY"; fi
    YANDEX_BUCKET=$(read_input "   Bucket für Datei (Enter = kein Upload, per USB)" "$DEFAULT_BUCKET")
    CLOUDFLARE_TUNNEL_TOKEN="DEIN_CLOUDFLARE_TOKEN"; CLOUDFLARE_HOSTNAME="DEIN_HOSTNAME"; CLOUDFLARE_TUNNEL_NAME="remotegate-ssh"
  elif [[ "$CLOUD_PROVIDER" == "cloudflare" ]]; then
    echo -n "   Token (eyJh..., Enter=später): "; read -s CLOUDFLARE_TUNNEL_TOKEN; echo; if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then CLOUDFLARE_TUNNEL_TOKEN="DEIN_CLOUDFLARE_TOKEN"; fi
    CLOUDFLARE_HOSTNAME=$(read_input "   Hostname (ssh.deinedomain.ru)" "$CFG_CloudflareHostname"); if [[ -z "$CLOUDFLARE_HOSTNAME" ]]; then CLOUDFLARE_HOSTNAME="DEIN_HOSTNAME"; fi
    CLOUDFLARE_TUNNEL_NAME="remotegate-ssh"; TAILSCALE_AUTHKEY="DEIN_TAILSCALE_KEY"
    YANDEX_BUCKET=$(read_input "   Bucket (Enter=kein Upload)" "$DEFAULT_BUCKET")
  else
    YANDEX_VM_IP=$(read_input "   VM IP" ""); if [[ -z "$YANDEX_VM_IP" ]]; then YANDEX_VM_IP="DEIN_YANDEX_VM_IP"; fi
    YANDEX_BUCKET=$(read_input "   Bucket" "$DEFAULT_BUCKET")
    TAILSCALE_AUTHKEY="DEIN_TAILSCALE_KEY"; CLOUDFLARE_TUNNEL_TOKEN="DEIN_CLOUDFLARE_TOKEN"; CLOUDFLARE_HOSTNAME="DEIN_HOSTNAME"; CLOUDFLARE_TUNNEL_NAME="remotegate-ssh"
  fi
  WINDOWS_USER="DEIN_BENUTZER"
else
  WINDOWS_USER="DEIN_BENUTZER"
  if [[ -n "$CFG_WindowsPassword" ]]; then WINDOWS_PASSWORD="$CFG_WindowsPassword"; else WINDOWS_PASSWORD="DEIN_PASSWORT"; fi
  if [[ "$WINDOWS_PASSWORD" == "DEIN_PASSWORT" || -z "$WINDOWS_PASSWORD" ]]; then USE_PASSWORD_AUTH=false; else USE_PASSWORD_AUTH=true; fi
  YANDEX_VM_IP="CLOUDFLARE_MODE"; YANDEX_VM_USER="cloudflare"; YANDEX_VM_PORT=22; REVERSE_TUNNEL_PORT=2222; YANDEX_BUCKET="$DEFAULT_BUCKET"; TAILSCALE_AUTHKEY="${CFG_TailscaleAuthKey:-DEIN_TAILSCALE_KEY}"; CLOUDFLARE_TUNNEL_TOKEN="${CFG_CloudflareTunnelToken:-DEIN_CLOUDFLARE_TOKEN}"; CLOUDFLARE_HOSTNAME="${CFG_CloudflareHostname:-DEIN_HOSTNAME}"; CLOUDFLARE_TUNNEL_NAME="remotegate-ssh"; CLOUD_PROVIDER="tailscale"; CLOUD_ENDPOINT="https://s3.cloud.ru"; HOSTNAME="$DEFAULT_HOST"; STATUS_ENABLED='$false'; STATUS_ENDPOINT=""; HMAC_SECRET=""
fi

GENERATION_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Erstelle Datei..."
mkdir -p "$(dirname "$OUTPUT_PATH")"
python3 << PYEOF
import pathlib
t=pathlib.Path("$TEMPLATE_PATH").read_text(encoding="utf-8")
r={"__WINDOWS_USER__":"""$WINDOWS_USER""","__WINDOWS_PASSWORD__":"""$WINDOWS_PASSWORD""","__YANDEX_VM_IP__":"""$YANDEX_VM_IP""","__YANDEX_VM_USER__":"""$YANDEX_VM_USER""","__YANDEX_VM_PORT__":"""$YANDEX_VM_PORT""","__REVERSE_TUNNEL_PORT__":"""$REVERSE_TUNNEL_PORT""","__STATUS_ENDPOINT__":"""$STATUS_ENDPOINT""","__HMAC_SECRET__":"""$HMAC_SECRET""","__STATUS_ENABLED__":"""$STATUS_ENABLED""","__DEVICE_ID__":"""$DEVICE_ID""","__HOSTNAME__":"""$HOSTNAME""","__YANDEX_BUCKET__":"""$YANDEX_BUCKET""","__CLOUD_BUCKET__":"""$YANDEX_BUCKET""","__CLOUD_PROVIDER__":"""$CLOUD_PROVIDER""","__S3_ENDPOINT__":"""$CLOUD_ENDPOINT""","__CLOUDFLARE_TUNNEL_TOKEN__":"""$CLOUDFLARE_TUNNEL_TOKEN""","__CLOUDFLARE_HOSTNAME__":"""$CLOUDFLARE_HOSTNAME""","__CLOUDFLARE_TUNNEL_NAME__":"""$CLOUDFLARE_TUNNEL_NAME""","__TAILSCALE_AUTHKEY__":"""$TAILSCALE_AUTHKEY""","__GENERATION_TIME__":"""$GENERATION_TIME"""}
pw=r["__WINDOWS_PASSWORD__"]
if pw!="DEIN_PASSWORT": pw=pw.replace("\`","\`\`").replace('"','\`"').replace("\$","\`\$"); r["__WINDOWS_PASSWORD__"]=pw
o=t
for k,v in r.items(): o=o.replace(k,v)
open("$OUTPUT_PATH","w",encoding="utf-8").write(o)
print(f"{len(o)} bytes -> $OUTPUT_PATH")
PYEOF
FILE_SIZE=$(wc -c < "$OUTPUT_PATH" 2>/dev/null || echo "?")
echo "Fertig: $OUTPUT_PATH ($FILE_SIZE bytes)"
python3 << PYEOF
import json,pathlib
c={"WindowsPasswordSet": """$USE_PASSWORD_AUTH""".lower()=="true","YandexBucket":"""$YANDEX_BUCKET""","CloudProvider":"""$CLOUD_PROVIDER""","TailcaleAuthkey":"""$TAILSCALE_AUTHKEY"""[:10]+"***" if """$TAILSCALE_AUTHKEY"""!="DEIN_TAILSCALE_KEY" else "","DeviceId":"""$DEVICE_ID"""}
pathlib.Path("$SCRIPT_DIR/last-generation.json").write_text(json.dumps(c,indent=2,ensure_ascii=False),encoding="utf-8")
PYEOF
echo ""
if [[ -n "$YANDEX_BUCKET" && "$SKIP_UPLOAD" != "true" ]]; then echo "Upload..."; aws --endpoint-url "$CLOUD_ENDPOINT" s3 cp "$OUTPUT_PATH" "s3://$YANDEX_BUCKET/RemoteGate-Final.ps1" 2>&1 && echo "Upload ok" || echo "Kein aws — manuell"; fi
echo ""
echo "FERTIG — nur Passwort, kein Token nötig!"
echo "Datei: $OUTPUT_PATH"
if [[ -n "$YANDEX_BUCKET" ]]; then echo "Link: https://$YANDEX_BUCKET.s3.cloud.ru/RemoteGate-Final.ps1"; fi
echo "Windows: iwr LINK -OutFile \$env:TEMP\\RemoteGate-Final.ps1; & \$env:TEMP\\RemoteGate-Final.ps1"
if [[ "$CLOUD_PROVIDER" == "tailscale" ]]; then echo "Dann: Auf Windows + Mac https://tailscale.com/download installieren → gleiche E-Mail einloggen → ssh 100.x.x.x"; fi
