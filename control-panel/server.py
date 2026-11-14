#!/usr/bin/env python3
import http.server, json, pathlib, subprocess, sys, os

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
ROOT = pathlib.Path(__file__).parent
CONFIG_PATH = ROOT / "config.json"

def load_config():
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text())
        except: return {}
    return {}

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self.path = "/index.html"
            return http.server.SimpleHTTPRequestHandler.do_GET(self)
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
                cfg = load_config()
                relay_user = cfg.get("relayUser", "")
                relay_host = cfg.get("relayHost", "ssh-j.com")
                relay_device = cfg.get("relayDevice", "winpc")
                windows_user = cfg.get("windowsUser", "")
                # Versuche WindowsUser aus Relay zu ermitteln wenn Platzhalter
                if not windows_user or windows_user == "DEIN_BENUTZER":
                    windows_user = relay_device  # Fallback, oft gleich
                # Sichere cmd für ssh: ersetze " durch \"
                safe_cmd = cmd.replace('"', '\\"')
                # 1. Versuch: windowsUser@device
                ssh_base = ["ssh","-o","StrictHostKeyChecking=no","-o","ConnectTimeout=10","-o","ServerAliveInterval=10","-J", f"{relay_user}@{relay_host}"]
                attempts = []
                if windows_user and windows_user != relay_device:
                    attempts.append(ssh_base + [f"{windows_user}@{relay_device}", f'cmd /c "{safe_cmd}"'])
                attempts.append(ssh_base + [relay_device, f'cmd /c "{safe_cmd}"'])
                # Letzter Versuch: direkt über ssh-j.com ohne device (manche nutzen das so)
                attempts.append(ssh_base + [f"{relay_user}@{relay_host}", f'cmd /c "{safe_cmd}"'])

                last_output = ""
                for ssh_cmd in attempts:
                    try:
                        result = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=15)
                        output = (result.stdout or "") + (result.stderr or "")
                        # Erkenne typischen ssh-j Fehler: administratively prohibited = Gerät nicht online
                        if "administratively prohibited" in output or "stdio forwarding failed" in output or "Connection closed" in output:
                            last_output = output
                            continue
                        self.send_json({"output": output.strip() or "(kein Output)", "returncode": result.returncode})
                        return
                    except subprocess.TimeoutExpired:
                        last_output = "Timeout — Windows nicht erreichbar"
                    except Exception as e:
                        last_output = f"Fehler: {e}"
                # Alle Versuche fehlgeschlagen -> hilfreiche Meldung
                friendly = (
                    "⚠️ Windows nicht verbunden.\n\n"
                    "1. Hast du auf Windows den Befehl als ADMIN ausgeführt (Rechtsklick → Als Administrator)?\n"
                    "2. Warte 20 Sekunden nach dem Windows-Befehl — Tunnel braucht kurz.\n"
                    "3. Prüfe auf Windows: Task-Manager → Dienste → sshd läuft?\n"
                    "4. Prüfe Logs: C:\\ProgramData\\RemoteGate\\logs\\install.log\n\n"
                    f"Technisch: {last_output}"
                )
                self.send_json({"output": friendly, "returncode": 1})
            except Exception as e:
                self.send_json({"output": f"Server Fehler: {e}", "returncode": 1})
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
print(f"Config: {load_config()}")
http.server.HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
