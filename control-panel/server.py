#!/usr/bin/env python3
import http.server, json, pathlib, subprocess, sys, os

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
ROOT = pathlib.Path(__file__).parent
CONFIG_PATH = ROOT / "config.json"

def load_config():
    if CONFIG_PATH.exists():
        try: return json.loads(CONFIG_PATH.read_text())
        except: return {}
    return {}

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/", "/index.html"): self.path = "/index.html"
        return http.server.SimpleHTTPRequestHandler.do_GET(self)
    def do_POST(self):
        if self.path == "/exec":
            length = int(self.headers.get('content-length', 0))
            body = self.rfile.read(length)
            try:
                data = json.loads(body)
                cmd = data.get("cmd","").strip()
                if not cmd: self.send_json({"output":""}); return
                cfg = load_config()
                relay_user = cfg.get("relayUser","")
                relay_host = cfg.get("relayHost","ssh-j.com")
                relay_device = cfg.get("relayDevice","winpc")
                windows_user = cfg.get("windowsUser","")
                if not windows_user or windows_user=="DEIN_BENUTZER": windows_user=""
                safe = cmd.replace('"','\\"')
                # Wichtig: bei ssh-j.com ist das Ziel NICHT user@device sondern nur device
                # ssh -J user@ssh-j.com device "cmd /c ..."
                # Loop vermeiden: nie -J und Ziel gleich
                ssh_base = ["ssh","-o","StrictHostKeyChecking=no","-o","ConnectTimeout=10","-o","BatchMode=yes"]
                attempts=[]
                # Korrekte ssh-j.com Syntax: ssh -J user@host device
                if windows_user:
                    attempts.append(ssh_base+["-J",f"{relay_user}@{relay_host}",f"{windows_user}@{relay_device}",f'cmd /c "{safe}"'])
                attempts.append(ssh_base+["-J",f"{relay_user}@{relay_host}",relay_device,f'cmd /c "{safe}"'])
                last=""
                for sc in attempts:
                    try:
                        r=subprocess.run(sc, capture_output=True, text=True, timeout=15)
                        out=(r.stdout or "")+(r.stderr or "")
                        if "administratively prohibited" in out or "stdio forwarding failed" in out or "jumphost loop" in out:
                            last=out; continue
                        if "Connection closed" in out and "Unknown" in out:
                            last=out; continue
                        # Erfolg wenn kein administratively Fehler
                        self.send_json({"output": out.strip() or "(kein Output)", "returncode": r.returncode}); return
                    except subprocess.TimeoutExpired: last="Timeout"
                    except Exception as e: last=str(e)
                friendly=f"⚠️ Windows nicht erreichbar\n\nTunnel noch nicht bereit?\n1. Windows-Befehl wirklich als Admin ausgeführt? (UAC Ja klicken)\n2. 30 Sek warten\n3. Auf Windows: C:\\ProgramData\\RemoteGate\\logs\\install.log prüfen\n\nTechnisch: {last}"
                self.send_json({"output":friendly,"returncode":1})
            except Exception as e: self.send_json({"output":f"Server Fehler: {e}","returncode":1})
            return
        self.send_error(404)
    def send_json(self,o):
        d=json.dumps(o).encode()
        self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Access-Control-Allow-Origin","*"); self.send_header("Content-Length",str(len(d))); self.end_headers(); self.wfile.write(d)
    def do_OPTIONS(self):
        self.send_response(200); self.send_header("Access-Control-Allow-Origin","*"); self.send_header("Access-Control-Allow-Methods","POST, GET, OPTIONS"); self.send_header("Access-Control-Allow-Headers","Content-Type"); self.end_headers()
os.chdir(ROOT)
print(f"Control Panel: http://localhost:{PORT} {load_config()}")
http.server.HTTPServer(("0.0.0.0",PORT),Handler).serve_forever()
