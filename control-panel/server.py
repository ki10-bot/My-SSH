#!/usr/bin/env python3
import http.server, json, pathlib, subprocess, sys, urllib.parse, os

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
ROOT = pathlib.Path(__file__).parent
REPO = ROOT.parent
CONFIG_PATH = ROOT / "config.json"

def load_config():
    if CONFIG_PATH.exists():
        return json.loads(CONFIG_PATH.read_text())
    return {}

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self.path = "/index.html"
            return http.server.SimpleHTTPRequestHandler.do_GET(self)
        # Favicon etc
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        if self.path == "/exec":
            length = int(self.headers.get('content-length', 0))
            body = self.rfile.read(length)
            try:
                data = json.loads(body)
                cmd = data.get("cmd", "").strip()
                if not cmd:
                    self.send_json({"output": ""})
                    return
                # Block dangerous? but admin requested
                cfg = load_config()
                relay_user = cfg.get("relayUser", "")
                relay_host = cfg.get("relayHost", "ssh-j.com")
                relay_device = cfg.get("relayDevice", "winpc")
                windows_user = cfg.get("windowsUser", "DEIN_BENUTZER")
                # Wenn windowsUser Platzhalter, versuche echten Namen via ssh-j Liste? Fallback: nehme cfg
                # Führe aus: ssh -J relayUser@ssh-j.com windowsUser@relayDevice "cmd /c <cmd>"
                # Nutze BatchMode, Timeout 15s
                ssh_cmd = [
                    "ssh",
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "ConnectTimeout=10",
                    "-o", "ServerAliveInterval=10",
                    "-J", f"{relay_user}@{relay_host}",
                    f"{windows_user}@{relay_device}",
                    f"cmd /c {cmd}"
                ]
                # Falls windowsUser DEIN_BENUTZER, versuche ohne User-Präfix (manche haben auto-detect)
                # Fallback: direkt device (ssh -J user@host device) geht bei ssh-j.com, aber für cmd brauchen wir user@device
                # Wenn erster Versuch fehlschlägt, probiere ohne windowsUser
                result = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=20)
                output = result.stdout + result.stderr
                if result.returncode != 0 and "DEIN_BENUTZER" in windows_user:
                    # Versuche mit device direkt und cmd via ssh -J
                    ssh_cmd2 = ["ssh","-o","StrictHostKeyChecking=no","-o","ConnectTimeout=10","-J", f"{relay_user}@{relay_host}", relay_device, f"cmd /c {cmd}"]
                    result2 = subprocess.run(ssh_cmd2, capture_output=True, text=True, timeout=20)
                    output = result2.stdout + result2.stderr
                self.send_json({"output": output, "returncode": result.returncode})
            except subprocess.TimeoutExpired:
                self.send_json({"output": "Timeout — Windows nicht erreichbar (läuft Tunnel? Neustart abwarten)", "returncode": 124})
            except Exception as e:
                self.send_json({"output": f"Fehler: {e}", "returncode": 1})
            return
        self.send_error(404)

    def send_json(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

os.chdir(ROOT)
print(f"Control Panel: http://localhost:{PORT}")
print(f"Config: {CONFIG_PATH} -> {load_config()}")
http.server.HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
