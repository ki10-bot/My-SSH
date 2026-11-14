#!/bin/bash
# RemoteGate — ultra simple (nur 2 Fragen, sichtbare Eingabe)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$REPO_ROOT/templates/RemoteGate-Deployment.template.ps1"
DEFAULT_OUTPUT="$REPO_ROOT/dist/RemoteGate-Final.ps1"
CONFIG_FILE=""; NON_INTERACTIVE=false; SKIP_UPLOAD=false; OUTPUT_PATH="$DEFAULT_OUTPUT"
while [[ $# -gt 0 ]]; do case "$1" in --config) CONFIG_FILE="$2"; shift 2;; --output) OUTPUT_PATH="$2"; shift 2;; --non-interactive) NON_INTERACTIVE=true; shift;; --skip-upload) SKIP_UPLOAD=true; shift;; -h|--help) echo "Usage: $0 [--config file.json]"; exit 0;; *) echo "Unknown: $1"; exit 1;; esac; done
json_get(){ local f="$1" k="$2"; [[ -f "$f" ]] || { echo ""; return; }; python3 -c "import json; print(json.load(open('$f')).get('$k',''))" 2>/dev/null || echo ""; }
echo "RemoteGate — ultra simple"
echo ""
if [[ ! -f "$TEMPLATE_PATH" ]]; then echo "Template fehlt"; exit 1; fi
CFG_WindowsPassword=""; CFG_RelayUser=""; CFG_DeviceId=""
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  CFG_WindowsPassword=$(json_get "$CONFIG_FILE" "WindowsPassword")
  CFG_RelayUser=$(json_get "$CONFIG_FILE" "RelayUser")
  CFG_DeviceId=$(json_get "$CONFIG_FILE" "DeviceId")
  for v in CFG_WindowsPassword CFG_RelayUser CFG_DeviceId; do eval "val=\$$v"; [[ "$val" == "null" ]] && eval "$v=\"\""; done
fi
if [[ -n "$CFG_DeviceId" && "$CFG_DeviceId" != "REPLACE_WITH_UUID" ]]; then DEVICE_ID="$CFG_DeviceId"; else DEVICE_ID="$(uuidgen 2>/dev/null || python3 -c "import uuid;print(uuid.uuid4())" 2>/dev/null || echo "REPLACE_WITH_UUID")"; fi
DEVICE_ID="$(echo "$DEVICE_ID" | tr -d '[:space:]')"
DEFAULT_HOST="$(hostname -s 2>/dev/null || echo "WINDOWS-PC")"
# Defaults
YANDEX_VM_IP="CLOUDFLARE_MODE"; YANDEX_VM_USER="cloudflare"; YANDEX_VM_PORT=22; REVERSE_TUNNEL_PORT=2222
CLOUD_ENDPOINT="https://s3.cloud.ru"; HOSTNAME="$DEFAULT_HOST"; STATUS_ENABLED='$false'; STATUS_ENDPOINT=""; HMAC_SECRET=""
CLOUDFLARE_TUNNEL_TOKEN="DEIN_CLOUDFLARE_TOKEN"; CLOUDFLARE_HOSTNAME="DEIN_HOSTNAME"; CLOUDFLARE_TUNNEL_NAME="remotegate-ssh"; TAILSCALE_AUTHKEY="DEIN_TAILSCALE_KEY"
RELAY_HOST="ssh-j.com"; RELAY_DEVICE="winpc"
if [[ "$NON_INTERACTIVE" == "false" ]]; then
  echo "1) Passwort für Windows"
  read -p "   Passwort: " WINDOWS_PASSWORD
  if [[ -z "$WINDOWS_PASSWORD" ]]; then WINDOWS_PASSWORD="DEIN_PASSWORT"; USE_PASSWORD_AUTH=false; else USE_PASSWORD_AUTH=true; fi
  echo ""
  echo "2) Name für Verbindung (z.B. alex123)"
  read -p "   Name: " RELAY_USER
  if [[ -z "$RELAY_USER" ]]; then RELAY_USER="user$(date +%s | tail -c 6)"; echo "   → $RELAY_USER"; fi
  # sanitize: nur a-z 0-9, kein ß
  RELAY_USER="$(echo "$RELAY_USER" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-20)"
  if [[ -z "$RELAY_USER" ]]; then RELAY_USER="user$(date +%s | tail -c 6)"; fi
  WINDOWS_USER="DEIN_BENUTZER"; YANDEX_BUCKET=""; CLOUD_PROVIDER="relay"
else
  WINDOWS_USER="DEIN_BENUTZER"
  WINDOWS_PASSWORD="${CFG_WindowsPassword:-DEIN_PASSWORT}"
  [[ "$WINDOWS_PASSWORD" == "DEIN_PASSWORT" || -z "$WINDOWS_PASSWORD" ]] && USE_PASSWORD_AUTH=false || USE_PASSWORD_AUTH=true
  RELAY_USER="${CFG_RelayUser:-meinuser}"; RELAY_DEVICE="winpc"; YANDEX_BUCKET=""; CLOUD_PROVIDER="relay"
fi
GENERATION_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Erstelle Datei..."
mkdir -p "$(dirname "$OUTPUT_PATH")"
python3 << PYEOF
import pathlib
t=pathlib.Path("$TEMPLATE_PATH").read_text(encoding="utf-8")
r={"__WINDOWS_USER__":"""$WINDOWS_USER""","__WINDOWS_PASSWORD__":"""$WINDOWS_PASSWORD""","__YANDEX_VM_IP__":"""$YANDEX_VM_IP""","__YANDEX_VM_USER__":"""$YANDEX_VM_USER""","__YANDEX_VM_PORT__":"""$YANDEX_VM_PORT""","__REVERSE_TUNNEL_PORT__":"""$REVERSE_TUNNEL_PORT""","__STATUS_ENDPOINT__":"""$STATUS_ENDPOINT""","__HMAC_SECRET__":"""$HMAC_SECRET""","__STATUS_ENABLED__":"""$STATUS_ENABLED""","__DEVICE_ID__":"""$DEVICE_ID""","__HOSTNAME__":"""$HOSTNAME""","__YANDEX_BUCKET__":"""$YANDEX_BUCKET""","__CLOUD_BUCKET__":"""$YANDEX_BUCKET""","__CLOUD_PROVIDER__":"""$CLOUD_PROVIDER""","__S3_ENDPOINT__":"""$CLOUD_ENDPOINT""","__CLOUDFLARE_TUNNEL_TOKEN__":"""$CLOUDFLARE_TUNNEL_TOKEN""","__CLOUDFLARE_HOSTNAME__":"""$CLOUDFLARE_HOSTNAME""","__CLOUDFLARE_TUNNEL_NAME__":"""$CLOUDFLARE_TUNNEL_NAME""","__TAILSCALE_AUTHKEY__":"""$TAILSCALE_AUTHKEY""","__RELAY_HOST__":"""$RELAY_HOST""","__RELAY_USER__":"""$RELAY_USER""","__RELAY_DEVICE__":"""$RELAY_DEVICE""","__GENERATION_TIME__":"""$GENERATION_TIME"""}
pw=r["__WINDOWS_PASSWORD__"]
if pw!="DEIN_PASSWORT": pw=pw.replace("\`","\`\`").replace('"','\`"').replace("\$","\`\$"); r["__WINDOWS_PASSWORD__"]=pw
o=t
for k,v in r.items(): o=o.replace(k,v)
open("$OUTPUT_PATH","w",encoding="utf-8").write(o)
print(f"{len(o)} bytes -> $OUTPUT_PATH")
PYEOF
python3 << PYEOF
import json,pathlib
c={"WindowsPasswordSet": """$USE_PASSWORD_AUTH""".lower()=="true","RelayUser":"""$RELAY_USER""","RelayDevice":"""$RELAY_DEVICE""","DeviceId":"""$DEVICE_ID"""}
pathlib.Path("$SCRIPT_DIR/last-generation.json").write_text(json.dumps(c,indent=2,ensure_ascii=False),encoding="utf-8")
PYEOF
echo ""
echo ""
echo "══════════════════════════════════════"
echo "DEIN WINDOWS-BEFEHL — diese EINE Zeile kopieren:"
echo "══════════════════════════════════════"
# Versuche Upload für direkten Download-Befehl
UPLOAD_URL=""
if command -v curl >/dev/null 2>&1; then
  UPLOAD_URL=$(curl -s --connect-timeout 2 -m 5 -F "file=@$OUTPUT_PATH" https://0x0.st 2>&1 | grep -E "https://0x0.st" | head -1 | tr -d '[:space:]' || true)
  if [[ -z "$UPLOAD_URL" ]]; then
    UPLOAD_URL=$(curl -s --connect-timeout 2 -m 5 -F "file=@$OUTPUT_PATH" https://file.io 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('link',''))" 2>/dev/null || true)
  fi
fi
# Fallback falls kein Internet — immer ein Befehl anzeigen
if [[ -n "$UPLOAD_URL" ]]; then
  echo ""
  echo "powershell -Command \"iwr $UPLOAD_URL -OutFile \$env:TEMP\\RemoteGate-Final.ps1; & \$env:TEMP\\RemoteGate-Final.ps1\""
  echo ""
else
  echo ""
  echo "powershell -ExecutionPolicy Bypass -File E:\\RemoteGate-Final.ps1"
  echo ""
  echo "Hinweis: Datei vorher per USB nach E: kopieren (dist/RemoteGate-Final.ps1)"
fi
echo "══════════════════════════════════════"
echo "Auf Windows: PowerShell als Admin -> einfügen -> Enter"
echo "══════════════════════════════════════"
