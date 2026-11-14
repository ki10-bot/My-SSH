# RemoteGate

Mac steuert Windows — 0 ₽, nur SSH.

### Schritt 1: Am Mac
Doppelklick auf **`gen.command`** → Passwort eingeben → Name eingeben → Enter

Du bekommst einen Befehl für Windows.

### Schritt 2: Auf Windows
PowerShell **als Administrator** öffnen → Befehl einfügen → Enter

Fertig — Windows ist bereit.

### Schritt 3: Vom Mac steuern
```
ssh -J DEIN_NAME@ssh-j.com winpc
```

Mehr steht in `docs/EINFACH.md`.
