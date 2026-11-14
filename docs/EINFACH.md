# Einfach — 2 Minuten (0 ₽, keine Karte, nur SSH)

Du brauchst nur ein Passwort. Keine Domain, keine Karte, keine Extra-Software auf Windows.

## Was du brauchst

- Passwort für Windows — du wählst es
- 2 Namen für Relay (frei wählbar, wie Nutzername): z.B. `alex12345` + Gerät `winpc`
  — das ist dein privater Namespace auf **ssh-j.com** (gratis, nur SSH, kein VPN)

## Wizard (Mac)

1. `generate_template.command` doppelklicken (oder `bash generator/generate.sh`)
2. Passwort eingeben (verdeckt, 2×) — Enter = nur Key (Passwort-Login aus)
3. `[1]` wählen für Relay ssh-j.com (Enter) — empfohlen
4. Relay-Nutzer eingeben: z.B. `alex12345` (einzigartig, kein `root`) — Enter
5. Gerätename: z.B. `winpc` — Enter
6. Bucket Enter (= per USB) oder S3-Link — fertig.

Datei liegt in `dist/RemoteGate-Final.ps1`.

## Windows: Final ausführen

- Link aus Wizard: `https://....s3.cloud.ru/RemoteGate-Final.ps1` (oder USB kopieren)
- Auf Windows als **Admin**: 
  ```
  Invoke-WebRequest -Uri "LINK" -OutFile $env:TEMP\RemoteGate-Final.ps1
  & $env:TEMP\RemoteGate-Final.ps1
  ```
- Skript installiert OpenSSH, setzt Passwort, und startet automatisch:
  `ssh -N -R winpc:22:localhost:22 alex12345@ssh-j.com` → hält Verbindung mit Keepalive.
- Kein Tailscale/Extra-Tool — nur das eingebaute OpenSSH.

## Mac: verbinden

Danach vom Mac:
```bash
ssh -J alex12345@ssh-j.com winpc
# dann im Jump: ssh DEIN_BENUTZER@winpc
# Kurzform direkt:
ssh -J alex12345@ssh-j.com DEIN_BENUTZER@winpc
```
Ersetze `DEIN_BENUTZER` durch Windows-Benutzer (wird auto-erkannt, meist dein Name) und Passwort = dein gewähltes.

Prüfe: `ssh alex12345@ssh-j.com` zeigt Liste deiner Geräte (50 max pro Name).

## Hinweise

- **ssh-j.com** ist public Relay (ValdikSS, auch via Tor onion erreichbar). Keine Registrierung, kein Geld, nutzt nur SSH.
- Windows baut ausgehenden Tunnel auf — keine eingehende Firewall-Regel nötig.
- Reconnect automatisch via Scheduled Task `\RemoteGate\RemoteGate-Tunnel` (SYSTEM).
- Willst du feste IP (149 ₽ Cloud.ru) oder Tailscale/Cloudflare? Im Wizard `[2]/[3]/[4]` wählen — siehe `docs/TAILSCALE-GUIDE.md` und `CLOUDFLARE-TUNNEL-GUIDE.md`.

Hilfe? Sag mir was du siehst — ich sag dir nächsten Klick.
