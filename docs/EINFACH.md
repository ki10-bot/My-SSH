# Einfach — 2 Minuten (Tailscale, 0 ₽, keine Karte)

Das ist jetzt Standard. Du brauchst nur ein Passwort.

## Was du brauchst

- Passwort für Windows — du wählst es
- Keine Domain, keine Karte, keine IP

## Wizard (Mac)

1. `generate_template.command` doppelklicken
2. Passwort eingeben (verdeckt, Enter = nur Key) — nochmal
3. `1` wählen für Tailscale (Enter) — fertig.
4. Datei liegt in `dist/RemoteGate-Final.ps1`

Mehr fragt er nicht.

## Windows + Mac: Tailscale installieren (1 Min)

1. **Windows**: https://tailscale.com/download → Download → Installieren → unten rechts Icon → **Log in** → mit Google einloggen
2. **Mac**: gleiche Seite → Download → Installieren → **Log in** (gleiche E-Mail!)
3. Beide sehen sich unter `100.x.x.x`

## Windows: Final ausführen

- Wizard gibt Link `https://....s3.cloud.ru/RemoteGate-Final.ps1` (oder per USB kopieren)
- Auf Windows als Admin: `Invoke-WebRequest -Uri "LINK" -OutFile $env:TEMP\RemoteGate-Final.ps1` → `& $env:TEMP\RemoteGate-Final.ps1`
- Falls Tailscale fehlt, installiert es sich. Browser öffnet → einloggen → fertig.

Teste: `ping 100.x.x.x` und `ssh deinuser@100.x.x.x` vom Mac.

## Alternative: Cloudflare Tunnel

Willst du Domain statt Tailscale? Siehe `docs/CLOUDFLARE-TUNNEL-GUIDE.md`.
Im Wizard dann `2` wählen und Token `eyJh...` + `ssh.deinedomain.ru` eingeben.

Hilfe? Sag mir was du siehst.
