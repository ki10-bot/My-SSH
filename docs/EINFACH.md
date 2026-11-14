# So geht's — Schritt für Schritt

### 1. Am Mac vorbereiten
1. `gen.command` doppelklicken
2. Passwort eingeben → Enter
3. Name eingeben (z.B. `alex123`) → Enter
4. Du siehst einen Befehl — kopieren

Beispiel Befehl:
```
powershell -Command "iwr https://0x0.st/abc -OutFile $env:TEMP\RemoteGate-Final.ps1; & $env:TEMP\RemoteGate-Final.ps1"
```

### 2. Auf Windows installieren
1. Auf Windows PowerShell suchen → Rechtsklick → **Als Administrator ausführen**
2. Befehl einfügen → Enter
3. Warten bis fertig — Fenster kann zu

Jetzt läuft Windows automatisch im Hintergrund.

### 3. Vom Mac den Windows-PC steuern
Auf dem Mac Terminal öffnen:
```
ssh -J DEIN_NAME@ssh-j.com winpc
```
`DEIN_NAME` ist der Name aus Schritt 1.

Dann bist du auf dem Windows-PC und kannst alles machen.

Fertig.
