#!/usr/bin/env python3
import http.server, json, pathlib, subprocess, sys, os

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
ROOT = pathlib.Path(__file__).parent
CONFIG_PATH = ROOT / "config.json"

def load_config():
    if CONFIG_PATH.exists():
        try:
            j = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            # Normalize to new format
            if "profiles" in j:
                return j
            if "relayUser" in j:
                # migrate old single
                return {
                    "relayHost": j.get("relayHost", "ssh-j.com"),
                    "profiles": [{
                        "relayUser": j.get("relayUser"),
                        "relayHost": j.get("relayHost", "ssh-j.com"),
                        "relayDevice": j.get("relayDevice", "winpc"),
                        "deviceId": j.get("deviceId"),
                        "windowsUser": j.get("windowsUser", "DEIN_BENUTZER"),
                        "filename": f"RemoteGate-{j.get('relayUser','meinuser')}.ps1",
                        "ntfyTopic": j.get("relayUser", "ki10sus"),
                        "created": j.get("created", "")
                    }],
                    "activeDeviceId": j.get("deviceId")
                }
            return j
        except Exception as e:
            print(f"config load fail: {e}")
            return {"profiles": []}
    return {"profiles": []}

def get_profile(data, device_id=None):
    profiles = data.get("profiles", [])
    if not profiles:
        return None
    if device_id:
        for p in profiles:
            if p.get("deviceId") == device_id:
                return p
    # fallback active or first
    active = data.get("activeDeviceId")
    if active:
        for p in profiles:
            if p.get("deviceId") == active:
                return p
    return profiles[0]

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.path = "/index.html"
            return http.server.SimpleHTTPRequestHandler.do_GET(self)
        if self.path == "/config":
            cfg = load_config()
            self.send_json(cfg)
            return
        if self.path == "/profiles":
            cfg = load_config()
            self.send_json(cfg.get("profiles", []))
            return
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        if self.path == "/exec":
            length = int(self.headers.get('content-length', 0))
            body = self.rfile.read(length)
            try:
                data = json.loads(body)
                cmd = data.get("cmd", "").strip()
                if not cmd:
                    self.send_json({"output": ""}); return
                device_id = data.get("deviceId") or data.get("activeDeviceId")
                cfg = load_config()
                profile = get_profile(cfg, device_id)
                if not profile:
                    self.send_json({"output": "Kein Profil gefunden — bitte zuerst gen.command ausführen", "returncode": 1}); return
                relay_user = profile.get("relayUser", "")
                relay_host = profile.get("relayHost", "ssh-j.com")
                relay_device = profile.get("relayDevice", "winpc")
                windows_user = profile.get("windowsUser", "")
                if not windows_user or windows_user == "DEIN_BENUTZER":
                    windows_user = ""
                safe = cmd.replace('"', '\\"')
                ssh_base = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes"]
                attempts = []
                if windows_user:
                    attempts.append(ssh_base + ["-J", f"{relay_user}@{relay_host}", f"{windows_user}@{relay_device}", f'cmd /c "{safe}"'])
                attempts.append(ssh_base + ["-J", f"{relay_user}@{relay_host}", relay_device, f'cmd /c "{safe}"'])
                last = ""
                for sc in attempts:
                    try:
                        r = subprocess.run(sc, capture_output=True, text=True, timeout=15)
                        out = (r.stdout or "") + (r.stderr or "")
                        if "administratively prohibited" in out or "stdio forwarding failed" in out or "jumphost loop" in out:
                            last = out; continue
                        if "Connection closed" in out and "Unknown" in out:
                            last = out; continue
                        self.send_json({"output": out.strip() or "(kein Output)", "returncode": r.returncode, "profile": profile}); return
                    except subprocess.TimeoutExpired:
                        last = "Timeout nach 15s"
                    except Exception as e:
                        last = str(e)
                friendly = f"⚠️ Windows nicht erreichbar ({relay_user}@{relay_host} device {relay_device})\n\nTunnel noch nicht bereit?\n1. Windows WIN+R Befehl als Admin ausgeführt? (UAC Ja)\n2. 30 Sek warten\n3. Auf Windows: C:\\ProgramData\\RemoteGate\\logs\\install.log prüfen\n4. Ntfy: https://ntfy.sh/{profile.get('ntfyTopic', relay_user)}\n\nTechnisch: {last}"
                self.send_json({"output": friendly, "returncode": 1, "profile": profile})
            except Exception as e:
                self.send_json({"output": f"Server Fehler: {e}", "returncode": 1})
            return
        if self.path == "/select":
            # set active profile
            length = int(self.headers.get('content-length', 0))
            body = self.rfile.read(length)
            try:
                data = json.loads(body)
                device_id = data.get("deviceId")
                cfg = load_config()
                # verify exists
                found = any(p.get("deviceId")==device_id for p in cfg.get("profiles",[]))
                if found:
                    cfg["activeDeviceId"] = device_id
                    CONFIG_PATH.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")
                    self.send_json({"ok": True, "activeDeviceId": device_id})
                else:
                    self.send_json({"ok": False, "error": "Profil nicht gefunden"})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)})
            return
        self.send_error(404)

    def send_json(self, o):
        d = json.dumps(o, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(d)))
        self.end_headers()
        self.wfile.write(d)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

os.chdir(ROOT)
cfg = load_config()
print(f"Control Panel: http://localhost:{PORT} — {len(cfg.get('profiles',[]))} Profile")
for p in cfg.get("profiles", []):
    print(f" - {p.get('relayUser')}@{p.get('relayHost')} device {p.get('relayDevice')} file {p.get('filename')} id {p.get('deviceId','')[:8]}")
http.server.HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
