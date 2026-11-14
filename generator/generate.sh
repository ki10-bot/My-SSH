#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$REPO_ROOT/templates/RemoteGate-Deployment.template.ps1"
DEFAULT_OUTPUT="$REPO_ROOT/dist/RemoteGate-Final.ps1"
CONFIG_FILE=""; NON_INTERACTIVE=false; OUTPUT_PATH="$DEFAULT_OUTPUT"
while [[ $# -gt 0 ]]; do case "$1" in --config) CONFIG_FILE="$2"; shift 2;; --output) OUTPUT_PATH="$2"; shift 2;; --non-interactive) NON_INTERACTIVE=true; shift;; -h|--help) echo "Usage: $0 [--config file.json]"; exit 0;; *) echo "Unknown: $1"; exit 1;; esac; done
json_get(){ local f="$1" k="$2"; [[ -f "$f" ]] || { echo ""; return; }; python3 -c "import json; print(json.load(open('$f')).get('$k',''))" 2>/dev/null || echo ""; }
echo "RemoteGate"
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
if [[ "$NON_INTERACTIVE" == "false" ]]; then
  read -p "Passwort: " WINDOWS_PASSWORD
  [[ -z "$WINDOWS_PASSWORD" ]] && WINDOWS_PASSWORD="DEIN_PASSWORT"
  read -p "Name: " RELAY_USER
  [[ -z "$RELAY_USER" ]] && RELAY_USER="user$(date +%s | tail -c 6)"
  RELAY_USER="$(echo "$RELAY_USER" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-20)"
  [[ -z "$RELAY_USER" ]] && RELAY_USER="user$(date +%s | tail -c 6)"
else
  WINDOWS_PASSWORD="${CFG_WindowsPassword:-DEIN_PASSWORT}"
  RELAY_USER="${CFG_RelayUser:-meinuser}"
fi
WINDOWS_USER="DEIN_BENUTZER"; RELAY_HOST="ssh-j.com"; RELAY_DEVICE="winpc"; DEVICE_ID="$DEVICE_ID"
GENERATION_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
echo "Erstelle Datei..."
mkdir -p "$(dirname "$OUTPUT_PATH")"
python3 << PYEOF
import pathlib
t=pathlib.Path("$TEMPLATE_PATH").read_text(encoding="utf-8")
r={"__WINDOWS_USER__":"""$WINDOWS_USER""","__WINDOWS_PASSWORD__":"""$WINDOWS_PASSWORD""","__RELAY_HOST__":"""$RELAY_HOST""","__RELAY_USER__":"""$RELAY_USER""","__RELAY_DEVICE__":"""$RELAY_DEVICE""","__DEVICE_ID__":"""$DEVICE_ID""","__GENERATION_TIME__":"""$GENERATION_TIME"""}
pw=r["__WINDOWS_PASSWORD__"]
if pw!="DEIN_PASSWORT": pw=pw.replace("\`","\`\`").replace('"','\`"').replace("\$","\`\$"); r["__WINDOWS_PASSWORD__"]=pw
o=t
for k,v in r.items(): o=o.replace(k,v)
open("$OUTPUT_PATH","w",encoding="utf-8").write(o)
print(f"{len(o)} bytes")
PYEOF
mkdir -p "$REPO_ROOT/control-panel"
python3 << PYEOF
import json, pathlib
cfg={"relayUser":"""$RELAY_USER""","relayHost":"""$RELAY_HOST""","relayDevice":"""$RELAY_DEVICE""","windowsUser":"DEIN_BENUTZER","deviceId":"""$DEVICE_ID"""}
pathlib.Path("$REPO_ROOT/control-panel/config.json").write_text(json.dumps(cfg, indent=2), encoding="utf-8")
pathlib.Path("$SCRIPT_DIR/last-generation.json").write_text(json.dumps({"RelayUser":cfg["relayUser"],"DeviceId":cfg["deviceId"]}, indent=2), encoding="utf-8")
PYEOF
echo ""
echo "Lade hoch..."
UPLOAD_URL=""
for HOST in "https://0x0.st" "https://tmpfiles.org/api/v1/upload" "https://file.io" "https://transfer.sh"; do
  if [[ "$HOST" == *"tmpfiles"* ]]; then
    UPLOAD_URL=$(curl -s --connect-timeout 3 -m 8 -F "file=@$OUTPUT_PATH" "$HOST" 2>&1 | grep -oE "https://tmpfiles.org[^\"']*" | head -1 || true)
  elif [[ "$HOST" == *"transfer"* ]]; then
    UPLOAD_URL=$(curl -s --connect-timeout 3 -m 8 --upload-file "$OUTPUT_PATH" "$HOST/RemoteGate-Final.ps1" 2>&1 | grep -E "^https://" | head -1 | tr -d '[:space:]' || true)
  else
    UPLOAD_URL=$(curl -s --connect-timeout 3 -m 8 -F "file=@$OUTPUT_PATH" "$HOST" 2>&1 | grep -E "https://(0x0\.st|file\.io)[^ \"']*" | head -1 | tr -d '[:space:]' || true)
    if [[ -z "$UPLOAD_URL" && "$HOST" == *"file.io"* ]]; then
      UPLOAD_URL=$(curl -s --connect-timeout 3 -m 8 -F "file=@$OUTPUT_PATH" "$HOST" 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('link',''))" 2>/dev/null || true)
    fi
  fi
  [[ -n "$UPLOAD_URL" ]] && break
done
echo ""
echo "══════════════════════════════════════"
echo "SCHRITT 1 — Auf Windows PowerShell als ADMIN öffnen:"
echo "  Startmenü -> \"PowerShell\" tippen -> Rechtsklick -> Als Administrator ausführen -> Ja klicken"
echo "══════════════════════════════════════"
echo ""
if [[ -n "$UPLOAD_URL" ]]; then
  echo "SCHRITT 2 — Diese EINE Zeile dort einfügen und Enter:"
  echo ""
  echo "iwr $UPLOAD_URL -OutFile \$env:TEMP\\RemoteGate-Final.ps1; & \$env:TEMP\\RemoteGate-Final.ps1"
  echo ""
else
  B64=$(base64 -w 0 "$OUTPUT_PATH" 2>/dev/null || base64 "$OUTPUT_PATH" | tr -d '\n')
  echo "SCHRITT 2 — Diese EINE Zeile dort einfügen und Enter (offline, ohne Internet):"
  echo ""
  echo "\$b=[Convert]::FromBase64String('$B64'); [IO.File]::WriteAllBytes(\"\$env:TEMP\\RemoteGate-Final.ps1\",\$b); & \$env:TEMP\\RemoteGate-Final.ps1"
  echo ""
fi
echo "══════════════════════════════════════"
echo "Fenster bleibt offen und zeigt Fortschritt. Am Ende Enter drücken."
echo ""
echo "Prüfen: C:\\ProgramData\\RemoteGate\\logs\\install.log"
