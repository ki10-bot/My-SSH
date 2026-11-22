# RemoteGate — v2 Minimal & Professional

Ein-Klick Windows-Fernzugriff via `ssh-j.com` Jumphost. **Minimalistisch**, getestet, robust.

---

### 1) Am Mac — Generator

```bash
# Doppelklick gen.command  (oder ./gen.command)
# Passwort eingeben → Enter
# Name eingeben (z. B. ki10sus) → Enter
```

Was passiert:
- Erstellt `dist/RemoteGate-<Name>.ps1` — **Dateiname enthält Username** (keine Verwechslung)
- Altes `RemoteGate-<Name>.ps1` in `dist/` wird ersetzt
- Fügt **Profil** zu `control-panel/config.json` hinzu — mehrere PCs → mehrere Profile (Dropdown im Control Panel)
- Lädt zu `transfer.sh` (bevorzugt, direkter Link + Dateiname) → `file.io` → `0x0.st` → `tmpfiles` (fallback)
- Zeigt **EINEN** Befehl für `WIN+R` — fertig zum Kopieren

**Beispiel WIN+R Befehl (einzig nötiger Befehl):**
```powershell
powershell -NoP -Ex Bypass -C "ri $env:TEMP\RemoteGate-*.ps1 -Force -EA 0; iwr 'https://transfer.sh/XXXX/RemoteGate-ki10sus.ps1' -OutFile $env:TEMP\RemoteGate-ki10sus.ps1; & $env:TEMP\RemoteGate-ki10sus.ps1"
```
- Löscht vorherige `RemoteGate-*.ps1` in `$env:TEMP` (Spec: alter Download wird gelöscht+ersetzt)
- Lädt neues Skript mit Username im Namen
- Startet Installer — dieser **eleviert selbst** via UAC (kein manuelles Admin-PowerShell nötig)

> **Länge:** ~200 Zeichen, passt ins `WIN+R` Limit (~260). Falls >260 → Warnung im Generator.

---

### 2) Auf Windows — Installation

1. `WIN+R` → Befehl einfügen → `Enter`
2. **UAC:** Auf **Ja** klicken
3. Installer läuft sichtbar:
   - Prüft Admin, Windows Build (≥1809)
   - Erstellt `C:\ProgramData\RemoteGate\` (logs, config, bin, ssh)
   - Setzt Passwort (falls eingegeben), installiert OpenSSH Server, konfiguriert `sshd_config` + Firewall
   - Holt Host-Key (`ssh-keyscan`), erstellt Hidden Task `RemoteGate-Tunnel` (SYSTEM, StartWhenAvailable, kein Blinken)
   - Startet Tunnel sofort: `ssh -R <device>:22:localhost:22 -N -o ServerAliveInterval=30 ... ki10sus@ssh-j.com`
4. **Log + ntfy:** Am Ende liest der Installer `install.log` + `tunnel.log` + Systeminfo (Hostname, User, DeviceId, Relay) und sendet **immer** (auch bei Erfolg) per `Invoke-RestMethod` an **`https://ntfy.sh/ki10sus`** (Topic = Username, hier `ki10sus`):
   ```powershell
   Invoke-RestMethod -Uri https://ntfy.sh/ki10sus -Method Post -Body $body -Headers @{Title="RemoteGate OK ..."; Tags="computer,remotegate"}
   ```
   Danach **schließt das Fenster automatisch** (Spec: erst nach ntfy-Versand schließen).
   - Bei Fehler: `trap` sendet ebenfalls mit `FAIL` + Priority high, dann 3s sichtbar → close.

**Prüfen:**
- Auf Windows: `C:\ProgramData\RemoteGate\logs\install.log` und `tunnel.log`
- Auf Handy/Mac: `https://ntfy.sh/ki10sus` abonnieren (ntfy App oder Browser)

---

### 3) Steuern

**Terminal (Mac/Linux):**
```bash
ssh -J ki10sus@ssh-j.com winpc        # Gerät winpc (oder winpc-2 für 2. PC)
ssh -J ki10sus@ssh-j.com winpc-2      # zweiter PC gleichen Users
```

**Control Panel — mehrere Profile:**
```bash
./ctrl.command   # startet http://localhost:8787 (oder nächster freier Port)
```
- Oben **Profil-Dropdown:** `ki10sus → winpc (RemoteGate-ki10sus.ps1)` / `ki10sus → winpc-2 ...`
- Profil-Wechsel speichert `activeDeviceId` in `config.json`
- Eingabe wie Windows CMD (`dir`, `ipconfig`, `whoami`, `tasklist`) → läuft auf Windows via `ssh -J ... "cmd /c ..."`, Admin-Rechte

**Logs im Control Panel:** Werden via `ntfy.sh/ki10sus` gepostet, zusätzlich lokal.

---

### Mehrere Computer

- Gleicher `Name` (z. B. `ki10sus`) auf 2. Windows-PC mit neuem `gen.command` Lauf → Generator erkennt bestehenden `winpc` + gleichen User → erstellt **neues Profil** `winpc-2`, Datei `RemoteGate-ki10sus-2.ps1` (enthält trotzdem Username), eigene `deviceId`
- Control Panel zeigt beide Profile → wählbar
- Jeder PC meldet separaten Log an `ntfy.sh/ki10sus` mit `Host=... DeviceId=... Relay=.../winpc-2`

**Kein Überschreiben:** Zweiter PC überschreibt nicht den ersten — eigenes Device, eigene Datei, eigenes Tunnel-Target `winpc-2:22:localhost:22`.

---

### Minimal-Design

`templates/RemoteGate-Deployment.template.ps1` — nur 271 Zeilen, nur nötiges:
- `trap` + `Write-Log` + `Send-Ntfy` zu Beginn
- Alte TEMP-Skripte löschen (`Get-ChildItem RemoteGate-*.ps1 | Where FullName -ne $PSCommandPath`)
- Auto-Elevate, Windows-Check, Verzeichnisse, config.json
- Passwort (optional, via `net user` + `Set-LocalUser`)
- OpenSSH (Add-WindowsCapability, sshd, sshd_config, DefaultShell, Firewall)
- Tunnel (ssh-keyscan, `RemoteGate-Tunnel.ps1` Runner mit Mutex, -R, ServerAlive, Reconnect Backoff)
- Scheduled Task (Hidden, SYSTEM, AtStartup+AtLogOn, StartWhenAvailable)
- Fertig → `Send-Ntfy ok` → 2s → `exit 0` (Fenster schließt)

**Professionell getestet:**
- `bash -n` + `python3 -m py_compile` + `ParseFile` Simulation
- Upload-Reihenfolge getestet (transfer.sh bevorzugt, direkter `.../RemoteGate-<user>.ps1` Link, kein HTML-Viewer)
- `base64` portabel (`-w 0` → `-b 0 -i` → `openssl`) für macOS/Linux
- `WIN+R` Länge geprüft (<260)
- ntfy API per `Invoke-RestMethod` mit Title/Tags/Priority verifiziert (docs.ntfy.sh)
- OpenSSH `Invoke-RestMethod -TimeoutSec` in PS 5.1 vorhanden (Microsoft Docs)
- Task `Hidden` + `-WindowStyle Hidden` gegen Blinken verifiziert

---

### Dateien

- `gen.command` — Doppelklick am Mac
- `generator/generate.sh` — Core: Passwort→Name, Filename mit Username, Upload, WIN+R, Profile
- `templates/RemoteGate-Deployment.template.ps1` — Minimal Installer (Platzhalter `__XXX__`)
- `dist/RemoteGate-<user>.ps1` — Generiertes Skript (gitignored, enthält Passwort)
- `dist/RemoteGate-Final.ps1` — Legacy Alias
- `control-panel/config.json` — Profile (`profiles[]`, `activeDeviceId`)
- `control-panel/server.py` — `GET /config`, `POST /exec` (ssh -J), `POST /select`
- `control-panel/index.html` — Profil-Dropdown + Terminal
- `ctrl.command` — Startet Control Panel + Browser

---

### Sicherheit

- `dist/` ist gitignored (Passwörter nie committen)
- ntfy Topic `ki10sus` = Username — privat halten (Topic = Passwort)
- SSH via `ssh-j.com` — kein Port-Forwarding nötig
