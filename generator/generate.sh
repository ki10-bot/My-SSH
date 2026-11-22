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
for HOST in "https://transfer.sh" "https://file.io" "https://0x0.st" "https://tmpfiles.org/api/v1/upload"; do
  if [[ "$HOST" == *"tmpfiles"* ]]; then
    RAW=$(curl -s --connect-timeout 3 -m 8 -F "file=@$OUTPUT_PATH" "$HOST" 2>&1 || true)
    UPLOAD_URL=$(echo "$RAW" | python3 -c "import json,sys; j=json.load(sys.stdin); u=j.get('data',{}).get('url','') or j.get('url',''); print(u)" 2>/dev/null || true)
    if [[ -z "$UPLOAD_URL" ]]; then
      UPLOAD_URL=$(echo "$RAW" | grep -oE "https://tmpfiles.org[^\"']*" | head -1 || true)
    fi
    UPLOAD_URL=$(echo "$UPLOAD_URL" | sed 's|\\/|/|g; s|\\||g' | tr -d '\r\n ')
    if [[ "$UPLOAD_URL" == *"tmpfiles.org"* && "$UPLOAD_URL" != *"/dl/"* ]]; then
      UPLOAD_URL="${UPLOAD_URL/tmpfiles.org\//tmpfiles.org\/dl\/}"
    fi
  elif [[ "$HOST" == *"transfer"* ]]; then
    UPLOAD_URL=$(curl -s --connect-timeout 3 -m 8 --upload-file "$OUTPUT_PATH" "$HOST/RemoteGate-Final.ps1" 2>&1 | grep -E "^https://" | head -1 | tr -d '[:space:]' || true)
  else
    UPLOAD_URL=$(curl -s --connect-timeout 3 -m 8 -F "file=@$OUTPUT_PATH" "$HOST" 2>&1 | grep -E "https://(0x0\.st|file\.io)[^ \"']*" | head -1 | tr -d '[:space:]' || true)
    if [[ -z "$UPLOAD_URL" && "$HOST" == *"file.io"* ]]; then
      UPLOAD_URL=$(curl -s --connect-timeout 3 -m 8 -F "file=@$OUTPUT_PATH" "$HOST" 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('link',''))" 2>/dev/null || true)
    fi
    UPLOAD_URL="${UPLOAD_URL:-}"
  fi
  [[ -n "$UPLOAD_URL" ]] && break
done
# Final sanitize: entferne \/ und stelle https:// sicher
UPLOAD_URL=$(echo "$UPLOAD_URL" | sed 's|\\/|/|g; s|\\||g' | tr -d '\r\n ')
if [[ -n "$UPLOAD_URL" && "$UPLOAD_URL" != https://* ]]; then
  # falls Chat-Markdown https:// abgeschnitten hat, wieder hinzufügen
  UPLOAD_URL="https://$UPLOAD_URL"
  UPLOAD_URL="${UPLOAD_URL/https:\/\/https:\/\//https://}"
fi
# tmpfiles dl ohne https fixen
if [[ "$UPLOAD_URL" == tmpfiles.org* ]]; then
  UPLOAD_URL="https://$UPLOAD_URL"
fi
echo ""
echo "══════════════════════════════════════"
# Portable base64: GNU -w 0, BSD -b 0, fallback openssl / stdin
B64_OFFLINE=""
if command -v base64 >/dev/null 2>&1; then
  B64_OFFLINE=$(base64 -w 0 "$OUTPUT_PATH" 2>/dev/null | tr -d '\n' || true)
  if [[ -z "$B64_OFFLINE" ]]; then
    B64_OFFLINE=$(base64 -b 0 -i "$OUTPUT_PATH" 2>/dev/null | tr -d '\n' || true)
  fi
  if [[ -z "$B64_OFFLINE" ]]; then
    B64_OFFLINE=$(base64 < "$OUTPUT_PATH" 2>/dev/null | tr -d ' \n\r' || true)
  fi
  if [[ -z "$B64_OFFLINE" ]]; then
    B64_OFFLINE=$(openssl base64 -A -in "$OUTPUT_PATH" 2>/dev/null | tr -d '\n' || true)
  fi
fi
if [[ -z "$B64_OFFLINE" ]]; then
  echo "WARN: base64 fehlgeschlagen - offline Befehl nicht verfügbar, nutze Online-Link"
fi
if [[ -n "$UPLOAD_URL" ]]; then
  echo "EIN BEFEHL für PowerShell (einfach kopieren, Enter, bei UAC Ja) - KURZ, bricht nicht um:"
  echo ""
  # KURZ: immer Start-Process mit -NoExit -Command + Read-Host, kein langer IsInRole Check -> kein Umbruch -> kein Copy-Fehler mit Leerzeichen
  printf '%s\n' "Remove-Item \$env:TEMP\\RemoteGate-Final.ps1 -Force -EA SilentlyContinue; iwr '$UPLOAD_URL' -OutFile \$env:TEMP\\RemoteGate-Final.ps1; Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -Command',\"& '\$env:TEMP\\RemoteGate-Final.ps1'; Read-Host 'Fertig'\""
  echo ""
  echo "Falls das HTML-Fehler gibt (window.dataLayer), nimm OFFLINE (braucht kein Internet, kein tmpfiles):"
  printf '%s\n' "\$b=[Convert]::FromBase64String('$B64_OFFLINE'); [IO.File]::WriteAllBytes(\$env:TEMP+'\\RemoteGate-Final.ps1',\$b); Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -Command',\"& '\$env:TEMP\\RemoteGate-Final.ps1'; Read-Host 'Fertig'\""
  echo ""
else
  echo "EIN BEFEHL (offline, ohne Upload) für PowerShell:"
  echo ""
  printf '%s\n' "\$b=[Convert]::FromBase64String('$B64_OFFLINE'); [IO.File]::WriteAllBytes(\$env:TEMP+'\\RemoteGate-Final.ps1',\$b); Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -Command',\"& '\$env:TEMP\\RemoteGate-Final.ps1'; Read-Host 'Fertig'\""
  echo ""
fi
echo "══════════════════════════════════════"
echo "Nach dem Einfügen bei UAC auf Ja klicken. Zweites Fenster bleibt IMMER offen - auch bei HTML-Fehler."
echo "Falls HTML-Fehler (window.dataLayer): 2. Befehl (Base64 offline) nehmen - braucht kein tmpfiles."
echo ""
echo "Falls gar kein zweites Fenster kommt: Auf Windows manuell PowerShell als Admin öffnen"
echo "(Startmenü -> PowerShell -> Rechtsklick -> Als Administrator -> Ja) und dort:"
if [[ -n "$UPLOAD_URL" ]]; then
  echo "  iwr '$UPLOAD_URL' -OutFile \$env:TEMP\\RemoteGate-Final.ps1; & \$env:TEMP\\RemoteGate-Final.ps1; Read-Host 'Enter'"
  echo "  oder offline: \$b=[Convert]::FromBase64String('...'); [IO.File]::WriteAllBytes(\$env:TEMP+'\\RemoteGate-Final.ps1',\$b); & \$env:TEMP\\RemoteGate-Final.ps1"
else
  echo "  (offline Befehl oben in Admin-Fenster einfügen)"
fi
echo ""
echo "Prüfen: C:\\ProgramData\\RemoteGate\\logs\\install.log  und  tunnel.log"
