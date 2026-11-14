# So geht's

### 1. Am Mac
`gen.command` doppelklicken → Passwort → Name → Enter → Befehl kopieren

Beispiel:
```
powershell -Command "iwr https://0x0.st/abc -OutFile $env:TEMP\RemoteGate-Final.ps1; & $env:TEMP\RemoteGate-Final.ps1"
```

### 2. Auf Windows
PowerShell als **Administrator** → einfügen → Enter → fertig, läuft im Hintergrund, startet nach Neustart automatisch.

### 3. Windows steuern

**Per Terminal:**
```
ssh -J DEIN_NAME@ssh-j.com winpc
```

**Per Control Panel:**
`ctrl.command` doppelklicken → schwarzes Fenster wie CMD → Befehl eingeben → Output kommt zurück (läuft auf Windows als Admin).
