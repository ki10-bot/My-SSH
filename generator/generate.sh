#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$REPO_ROOT/templates/RemoteGate-Deployment.template.ps1"

CONFIG_FILE=""; NON_INTERACTIVE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;;
    --non-interactive) NON_INTERACTIVE=true; shift;;
    -h|--help) echo "Usage: $0 [--config file.json] [--non-interactive]"; exit 0;;
    *) echo "Unknown: $1"; exit 1;;
  esac
done

json_get() {
  local f="$1" k="$2"
  [[ -f "$f" ]] || { echo ""; return; }
  python3 -c "import json; print(json.load(open('$f')).get('$k',''))" 2>/dev/null || echo ""
}

echo "RemoteGate — Generator v2"
echo ""

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  echo "FEHLER: Template fehlt: $TEMPLATE_PATH"
  exit 1
fi

# --- Config aus Datei (für Tests) ---
CFG_WindowsPassword=""; CFG_RelayUser=""; CFG_DeviceId=""
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  CFG_WindowsPassword=$(json_get "$CONFIG_FILE" "WindowsPassword")
  CFG_RelayUser=$(json_get "$CONFIG_FILE" "RelayUser")
  CFG_DeviceId=$(json_get "$CONFIG_FILE" "DeviceId")
  for v in CFG_WindowsPassword CFG_RelayUser CFG_DeviceId; do
    eval "val=\$$v"; [[ "$val" == "null" ]] && eval "$v=\"\""
  done
fi

CONFIG_JSON="$REPO_ROOT/control-panel/config.json"

# --- Eingaben: Passwort -> Name (Reihenfolge per Spec) ---
if [[ "$NON_INTERACTIVE" == "false" ]]; then
  read -r -p "Passwort: " WINDOWS_PASSWORD || true
  [[ -z "${WINDOWS_PASSWORD:-}" ]] && WINDOWS_PASSWORD="DEIN_PASSWORT"
  read -r -p "Name: " RELAY_USER || true
  [[ -z "${RELAY_USER:-}" ]] && RELAY_USER="user$(date +%s | tail -c 6)"
  RELAY_USER="$(echo "$RELAY_USER" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-20)"
  [[ -z "$RELAY_USER" ]] && RELAY_USER="user$(date +%s | tail -c 6)"

  # Falls Profil mit gleichem Name existiert: fragen ob neuer PC oder Update
  if [[ -f "$CONFIG_JSON" ]]; then
    export GEN_Q_USER="$RELAY_USER"
    export GEN_Q_JSON="$CONFIG_JSON"
    EXISTING_PROFILE=$(python3 << 'PYQ' 2>/dev/null || echo ""
import json, pathlib, os
p=pathlib.Path(os.environ["GEN_Q_JSON"])
try:
  j=json.loads(p.read_text(encoding="utf-8"))
  profiles=j.get('profiles', [])
  if not profiles and 'relayUser' in j: profiles=[j]
  for pr in profiles:
    if pr.get('relayUser')==os.environ["GEN_Q_USER"]:
      print(f"{pr.get('relayDevice')}|{pr.get('deviceId')}|{pr.get('filename')}")
      break
except: pass
PYQ
)
    if [[ -n "$EXISTING_PROFILE" ]]; then
      EXISTING_DEV=$(echo "$EXISTING_PROFILE" | cut -d'|' -f1)
      EXISTING_ID=$(echo "$EXISTING_PROFILE" | cut -d'|' -f2)
      echo ""
      echo "Bestehendes Profil gefunden: $RELAY_USER -> $EXISTING_DEV ($EXISTING_ID)"
      read -r -p "Neuen PC anlegen? (j=neues Gerät, n=Update bestehendes) [n]: " NEW_PC_ASK || true
      if [[ "$NEW_PC_ASK" == "j" || "$NEW_PC_ASK" == "J" || "$NEW_PC_ASK" == "y" || "$NEW_PC_ASK" == "Y" ]]; then
        echo "→ Neuer PC wird angelegt"
        CFG_DeviceId="" # force new ID
      else
        echo "→ Bestehendes Profil wird aktualisiert"
        CFG_DeviceId="$EXISTING_ID"
      fi
      echo ""
    fi
  fi
else
  WINDOWS_PASSWORD="${CFG_WindowsPassword:-DEIN_PASSWORT}"
  RELAY_USER="${CFG_RelayUser:-meinuser}"
  RELAY_USER="$(echo "$RELAY_USER" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-20)"
  [[ -z "$RELAY_USER" ]] && RELAY_USER="meinuser"
fi

# --- DeviceId (nach Eingaben, damit Update-Entscheidung berücksichtigt wird) ---
if [[ -n "${CFG_DeviceId:-}" && "$CFG_DeviceId" != "REPLACE_WITH_UUID" && -n "$CFG_DeviceId" ]]; then
  DEVICE_ID="$CFG_DeviceId"
else
  DEVICE_ID="$(uuidgen 2>/dev/null || python3 -c "import uuid;print(uuid.uuid4())" 2>/dev/null || echo "REPLACE_WITH_UUID")"
fi
DEVICE_ID="$(echo "$DEVICE_ID" | tr -d '[:space:]')"

WINDOWS_USER="DEIN_BENUTZER"
RELAY_HOST="ssh-j.com"
NTFY_TOPIC="$RELAY_USER"
GENERATION_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

# --- RelayDevice: winpc + eindeutiger Suffix bei mehreren PCs mit gleichem User ---
RELAY_DEVICE_BASE="winpc"
RELAY_DEVICE="$RELAY_DEVICE_BASE"
CONFIG_JSON="$REPO_ROOT/control-panel/config.json"
EXISTING_COUNT=0
# Wenn DeviceId schon existiert -> bestehenden RelayDevice wiederverwenden (kein neues Profil)
EXISTING_RELAY_DEVICE=""
if [[ -f "$CONFIG_JSON" ]]; then
  export GEN_CHECK_USER="$RELAY_USER"
  export GEN_CHECK_BASE="$RELAY_DEVICE_BASE"
  export GEN_CHECK_JSON="$CONFIG_JSON"
  export GEN_CHECK_DEVICE_ID="$DEVICE_ID"
  EXISTING_CHECK=$(python3 << 'PYCHK' 2>/dev/null || echo "0|"
import json, pathlib, os
p=pathlib.Path(os.environ["GEN_CHECK_JSON"])
did=os.environ.get("GEN_CHECK_DEVICE_ID","")
user=os.environ["GEN_CHECK_USER"]
base=os.environ["GEN_CHECK_BASE"]
try:
  j=json.loads(p.read_text(encoding="utf-8"))
  profiles=j.get('profiles', [])
  if not profiles and 'relayUser' in j:
    profiles=[j]
  # Falls deviceId schon vorhanden -> bestehenden Device-Namen zurückgeben
  for pr in profiles:
    if pr.get('deviceId')==did and did:
      print(f"EXISTING|{pr.get('relayDevice','')}")
      raise SystemExit
  cnt=sum(1 for pr in profiles if pr.get('relayUser')==user and pr.get('relayDevice','').startswith(base))
  print(f"{cnt}|")
except SystemExit:
  pass
except: print("0|")
PYCHK
)
  # Parse EXISTING_CHECK: "1|" oder "EXISTING|winpc-2"
  if [[ "$EXISTING_CHECK" == EXISTING* ]]; then
    EXISTING_RELAY_DEVICE="${EXISTING_CHECK#EXISTING|}"
    EXISTING_RELAY_DEVICE="$(echo "$EXISTING_RELAY_DEVICE" | tr -d '\r\n ')"
    if [[ -n "$EXISTING_RELAY_DEVICE" ]]; then
      RELAY_DEVICE="$EXISTING_RELAY_DEVICE"
      echo "Bestehendes Profil gefunden — nutze Device '$RELAY_DEVICE' (Update)"
      EXISTING_COUNT=0
    fi
  else
    EXISTING_COUNT="${EXISTING_CHECK%%|*}"
    EXISTING_COUNT="$(echo "$EXISTING_COUNT" | tr -d ' \n\r')"
    [[ -z "$EXISTING_COUNT" ]] && EXISTING_COUNT=0
  fi
  if [[ "$EXISTING_RELAY_DEVICE" == "" && "$EXISTING_COUNT" != "0" && -n "$EXISTING_COUNT" ]]; then
    NEXT=$((EXISTING_COUNT + 1))
    RELAY_DEVICE="${RELAY_DEVICE_BASE}-${NEXT}"
    echo "Hinweis: Mehrere PCs mit User '$RELAY_USER' — nutze Device '$RELAY_DEVICE' (Profil $NEXT)"
  fi
fi

# --- Dateiname MUSS Username enthalten (Spec: keine Verwechslungen) ---
# Bei mehreren PCs gleichen Users: RemoteGate-ki10sus-2.ps1 um Überschreiben zu vermeiden, enthält trotzdem Username
if [[ "$EXISTING_COUNT" != "0" && -n "$EXISTING_COUNT" && "$EXISTING_COUNT" != "0" ]]; then
  SAFE_FILENAME="RemoteGate-${RELAY_USER}-${NEXT}.ps1"
else
  SAFE_FILENAME="RemoteGate-${RELAY_USER}.ps1"
fi
OUTPUT_PATH="$REPO_ROOT/dist/${SAFE_FILENAME}"
# Legacy Alias für alte Doku (optional, gleicher Inhalt)
LEGACY_PATH="$REPO_ROOT/dist/RemoteGate-Final.ps1"

echo "Erstelle Datei: $SAFE_FILENAME ..."

mkdir -p "$(dirname "$OUTPUT_PATH")"

# --- Template ersetzen (Python, mit Escaping) - via ENV um Sonderzeichen sicher zu handhaben ---
export GEN_WINDOWS_USER="$WINDOWS_USER"
export GEN_WINDOWS_PASSWORD="$WINDOWS_PASSWORD"
export GEN_RELAY_HOST="$RELAY_HOST"
export GEN_RELAY_USER="$RELAY_USER"
export GEN_RELAY_DEVICE="$RELAY_DEVICE"
export GEN_DEVICE_ID="$DEVICE_ID"
export GEN_GENERATION_TIME="$GENERATION_TIME"
export GEN_NTFY_TOPIC="$NTFY_TOPIC"
export GEN_OUTPUT_PATH="$OUTPUT_PATH"
export GEN_LEGACY_PATH="$LEGACY_PATH"
export GEN_TEMPLATE_PATH="$TEMPLATE_PATH"
python3 << 'PYEOF'
import pathlib, os, re
t = pathlib.Path(os.environ["GEN_TEMPLATE_PATH"]).read_text(encoding="utf-8")
replacements = {
    "__WINDOWS_USER__": os.environ["GEN_WINDOWS_USER"],
    "__WINDOWS_PASSWORD__": os.environ["GEN_WINDOWS_PASSWORD"],
    "__RELAY_HOST__": os.environ["GEN_RELAY_HOST"],
    "__RELAY_USER__": os.environ["GEN_RELAY_USER"],
    "__RELAY_DEVICE__": os.environ["GEN_RELAY_DEVICE"],
    "__DEVICE_ID__": os.environ["GEN_DEVICE_ID"],
    "__GENERATION_TIME__": os.environ["GEN_GENERATION_TIME"],
    "__NTFY_TOPIC__": os.environ["GEN_NTFY_TOPIC"],
}
pw = replacements["__WINDOWS_PASSWORD__"]
if pw != "DEIN_PASSWORT":
    pw = pw.replace("`", "``").replace('"', '`"').replace("$", "`$")
    replacements["__WINDOWS_PASSWORD__"] = pw
o = t
for k, v in replacements.items():
    o = o.replace(k, v)
if "__" in o and "REPLACE" not in o:
    leftovers = re.findall(r"__[A-Z_]+__", o)
    if leftovers:
        print(f"WARN: Platzhalter übrig: {leftovers}")
open(os.environ["GEN_OUTPUT_PATH"], "w", encoding="utf-8").write(o)
open(os.environ["GEN_LEGACY_PATH"], "w", encoding="utf-8").write(o)
print(f"{len(o)} bytes -> {o.count(chr(10))} Zeilen")
PYEOF

# --- Control Panel profiles aktualisieren ---
mkdir -p "$REPO_ROOT/control-panel"
export GEN_CONFIG_JSON="$CONFIG_JSON"
export GEN_SAFE_FILENAME="$SAFE_FILENAME"
python3 << 'PYEOF'
import json, pathlib, os
config_path = pathlib.Path(os.environ["GEN_CONFIG_JSON"])
now = os.environ["GEN_GENERATION_TIME"]
new_profile = {
    "relayUser": os.environ["GEN_RELAY_USER"],
    "relayHost": os.environ["GEN_RELAY_HOST"],
    "relayDevice": os.environ["GEN_RELAY_DEVICE"],
    "deviceId": os.environ["GEN_DEVICE_ID"],
    "windowsUser": "DEIN_BENUTZER",
    "filename": os.environ["GEN_SAFE_FILENAME"],
    "ntfyTopic": os.environ["GEN_NTFY_TOPIC"],
    "created": now
}
data = {"relayHost": os.environ["GEN_RELAY_HOST"], "profiles": []}
if config_path.exists():
    try:
        j = json.loads(config_path.read_text(encoding="utf-8"))
        if "profiles" in j:
            data = j
        elif "relayUser" in j:
            old = {
                "relayUser": j.get("relayUser"),
                "relayHost": j.get("relayHost", os.environ["GEN_RELAY_HOST"]),
                "relayDevice": j.get("relayDevice", "winpc"),
                "deviceId": j.get("deviceId"),
                "windowsUser": j.get("windowsUser", "DEIN_BENUTZER"),
                "filename": f"RemoteGate-{j.get('relayUser','meinuser')}.ps1",
                "ntfyTopic": j.get("relayUser","meinuser"),
                "created": j.get("created", now)
            }
            data["profiles"] = [old]
            data["relayHost"] = j.get("relayHost", os.environ["GEN_RELAY_HOST"])
        else:
            data["profiles"] = []
    except Exception as e:
        print(f"WARN: config.json parse fail {e}, neu anlegen")
        data = {"relayHost": os.environ["GEN_RELAY_HOST"], "profiles": []}
found = False
for idx, p in enumerate(data["profiles"]):
    if p.get("deviceId") == new_profile["deviceId"]:
        data["profiles"][idx] = new_profile
        found = True
        break
if not found:
    data["profiles"].append(new_profile)
data["relayHost"] = os.environ["GEN_RELAY_HOST"]
data["activeDeviceId"] = new_profile["deviceId"]
config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
print(f"Profile: {len(data['profiles'])} gespeichert -> {config_path}")
for p in data["profiles"]:
    print(f" - {p['relayUser']}@{p['relayHost']} device {p['relayDevice']} file {p['filename']} id {p['deviceId'][:8]}")
last_path = pathlib.Path(os.environ["GEN_CONFIG_JSON"]).parent.parent / "generator" / "last-generation.json"
# fallback for old path
try:
    last_path = pathlib.Path(__file__).parent.parent / "generator" / "last-generation.json"
except: pass
import pathlib as _pl
_alt = _pl.Path(os.environ.get("GEN_CONFIG_JSON","")).parent.parent / "generator" / "last-generation.json"
for cand in [last_path, _alt, _pl.Path("generator/last-generation.json")]:
    try:
        cand.parent.mkdir(parents=True, exist_ok=True)
        cand.write_text(json.dumps({"RelayUser": new_profile["relayUser"], "RelayDevice": new_profile["relayDevice"], "DeviceId": new_profile["deviceId"], "Filename": new_profile["filename"]}, indent=2), encoding="utf-8")
        break
    except: pass
PYEOF

echo ""
echo "Lade hoch: $SAFE_FILENAME ..."

# Helper: prüft ob URL wirklich Raw-PS1 liefert (kein HTML Viewer)
validate_raw() {
  local url="$1"
  [[ -z "$url" ]] && return 1
  local sample
  sample=$(curl -sL --connect-timeout 5 -m 10 "$url" 2>&1 | head -c 4000 || true)
  if echo "$sample" | grep -qi "window\.dataLayer\|\bwindow\.dataLayer\b\|gtag(.*new Date\|<html\|<a href=\"https://onlyfiles"; then
    echo " -> Validierung: HTML statt PS1 erkannt ($url) -> verworfen" >&2
    return 1
  fi
  if echo "$sample" | grep -q "RemoteGate"; then
    return 0
  fi
  # Fallback: nicht leer und kein HTML -> ok
  if [[ -n "$sample" && "$sample" != *"Download ("* ]]; then
    return 0
  fi
  return 1
}

UPLOAD_URL=""
# Priorität: catbox (direkt raw, permanent) > 0x0.st (direkt raw) > transfer.sh (mit Dateiname) > file.io > tmpfiles (last, anfällig für HTML)
for HOST in "https://catbox.moe/user/api.php" "https://0x0.st" "https://transfer.sh" "https://file.io" "https://tmpfiles.org/api/v1/upload"; do
  if [[ "$HOST" == *"catbox"* ]]; then
    UPLOAD_URL=$(curl -s --connect-timeout 5 -m 15 -F "reqtype=fileupload" -F "fileToUpload=@$OUTPUT_PATH" "$HOST" 2>&1 | tr -d '\r\n ' | grep -E "^https://files\.catbox\.moe/" | head -1 || true)
    if [[ -n "$UPLOAD_URL" ]]; then
      echo " -> catbox OK: $UPLOAD_URL"
      if validate_raw "$UPLOAD_URL"; then
        echo " -> Validiert: raw OK"
        break
      else
        UPLOAD_URL=""
      fi
    else
      echo " -> catbox fail"
    fi
  elif [[ "$HOST" == *"tmpfiles"* ]]; then
    RAW=$(curl -s --connect-timeout 3 -m 8 -F "file=@$OUTPUT_PATH" "$HOST" 2>&1 || true)
    UPLOAD_URL=$(echo "$RAW" | python3 -c "import json,sys; j=json.load(sys.stdin); u=j.get('data',{}).get('url','') or j.get('url',''); print(u)" 2>/dev/null || true)
    if [[ -z "$UPLOAD_URL" ]]; then
      UPLOAD_URL=$(echo "$RAW" | grep -oE "https://tmpfiles.org[^\"']*" | head -1 || true)
    fi
    UPLOAD_URL=$(echo "$UPLOAD_URL" | sed 's|\\/|/|g; s|\\||g' | tr -d '\r\n ')
    if [[ "$UPLOAD_URL" == *"tmpfiles.org"* && "$UPLOAD_URL" != *"/dl/"* ]]; then
      UPLOAD_URL="${UPLOAD_URL/tmpfiles.org\//tmpfiles.org\/dl\/}"
    fi
    if [[ -n "$UPLOAD_URL" ]]; then
      echo " -> tmpfiles Roh-URL: $UPLOAD_URL"
      if validate_raw "$UPLOAD_URL"; then
        echo " -> tmpfiles OK: $UPLOAD_URL"
        break
      else
        # tmpfiles liefert oft HTML Viewer -> verwerfen und nächsten Host probieren
        echo " -> tmpfiles validierung fehlgeschlagen, nächsten Host probieren"
        UPLOAD_URL=""
      fi
    else
      echo " -> tmpfiles fail"
    fi
  elif [[ "$HOST" == *"transfer"* ]]; then
    UPLOAD_URL=$(curl -s --connect-timeout 4 -m 10 --upload-file "$OUTPUT_PATH" "$HOST/$SAFE_FILENAME" 2>&1 | grep -E "^https://" | head -1 | tr -d '[:space:]' || true)
    if [[ -z "$UPLOAD_URL" ]]; then
      UPLOAD_URL=$(curl -s --connect-timeout 4 -m 10 --upload-file "$OUTPUT_PATH" "$HOST/RemoteGate-Final.ps1" 2>&1 | grep -E "^https://" | head -1 | tr -d '[:space:]' || true)
    fi
    if [[ -n "$UPLOAD_URL" ]]; then
      echo " -> transfer.sh OK: $UPLOAD_URL"
      if validate_raw "$UPLOAD_URL"; then
        echo " -> Validiert: raw OK"
        break
      else
        UPLOAD_URL=""
      fi
    else
      echo " -> transfer.sh fail"
    fi
  else
    UPLOAD_URL=$(curl -s --connect-timeout 3 -m 8 -F "file=@$OUTPUT_PATH" "$HOST" 2>&1 | grep -E "https://(0x0\.st|file\.io)[^ \"']*" | head -1 | tr -d '[:space:]' || true)
    if [[ -z "$UPLOAD_URL" && "$HOST" == *"file.io"* ]]; then
      UPLOAD_URL=$(curl -s --connect-timeout 3 -m 8 -F "file=@$OUTPUT_PATH" "$HOST" 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('link',''))" 2>/dev/null || true)
    fi
    UPLOAD_URL="${UPLOAD_URL:-}"
    if [[ -n "$UPLOAD_URL" ]]; then
      echo " -> $HOST OK: $UPLOAD_URL"
      if validate_raw "$UPLOAD_URL"; then
        echo " -> Validiert: raw OK"
        break
      else
        UPLOAD_URL=""
      fi
    else
      echo " -> $HOST fail"
    fi
  fi
done

# Final sanitize: entferne \/ und stelle https:// sicher
UPLOAD_URL=$(echo "$UPLOAD_URL" | sed 's|\\/|/|g; s|\\||g' | tr -d '\r\n ')
if [[ -n "$UPLOAD_URL" && "$UPLOAD_URL" != https://* ]]; then
  UPLOAD_URL="https://$UPLOAD_URL"
  UPLOAD_URL="${UPLOAD_URL/https:\/\/https:\/\//https://}"
fi
if [[ "$UPLOAD_URL" == tmpfiles.org* ]]; then
  UPLOAD_URL="https://$UPLOAD_URL"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
if [[ -n "$UPLOAD_URL" ]]; then
  echo "EIN BEFEHL für WIN+R (kopieren, WIN+R, Einfügen, Enter):"
  echo ""
  # Minimal: löscht alte Skripte, lädt neues mit Username im Namen, führt aus
  # WIN+R Limit ~260 Zeichen — dieser Befehl ist ~160 + URL Länge
  WINR_CMD="powershell -NoP -Ex Bypass -C \"ri \$env:TEMP\\RemoteGate-*.ps1 -Force -EA 0; iwr '$UPLOAD_URL' -OutFile \$env:TEMP\\$SAFE_FILENAME; & \$env:TEMP\\$SAFE_FILENAME\""
  # Alternative falls URL sehr lang: zeige auch gekürzt
  printf '%s\n' "$WINR_CMD"
  echo ""
  # Länge prüfen
  LEN=${#WINR_CMD}
  echo "Länge: $LEN Zeichen (Limit WIN+R ~260)"
  if [[ $LEN -gt 260 ]]; then
    echo "WARN: Befehl >260 Zeichen — kann in WIN+R abgeschnitten werden!"
    echo " Tipp: URL manuell kürzen oder transfer.sh nutzen (kürzer)"
  fi
  echo ""
  echo "Was passiert danach:"
  echo " 1. PowerShell lädt $SAFE_FILENAME nach \$env:TEMP"
  echo " 2. Altes $SAFE_FILENAME wird vorher gelöscht (keine Verwechslung)"
  echo " 3. Skript installiert OpenSSH, Tunnel (hidden Task), loggt nach C:\\ProgramData\\RemoteGate\\logs\\install.log"
  echo " 4. Sendet Log automatisch an https://ntfy.sh/$NTFY_TOPIC (auch bei Erfolg)"
  echo " 5. Fenster schliesst erst NACH ntfy-Versand"
else
  echo "WARN: Upload fehlgeschlagen — kein Internet? Nutze lokale Datei:"
  echo "  Datei liegt in dist/$SAFE_FILENAME — manuell auf Windows kopieren"
  echo "  und dort: powershell -Ex Bypass -File $SAFE_FILENAME"
fi
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Control Panel Profile: $RELAY_USER -> $RELAY_DEVICE ($DEVICE_ID)"
echo " Nächster Schritt: WIN+R Befehl oben auf Windows ausführen (UAC Ja klicken)"
echo " Prüfen: https://ntfy.sh/$NTFY_TOPIC  (Log kommt nach 30-60s)"
echo " Control Panel starten: ./ctrl.command"
echo ""
