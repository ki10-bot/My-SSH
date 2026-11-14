# Tailscale — 2 Minuten, 0 ₽, keine Karte

Die einfachste Art. Kein Cloudflare, keine Domain, keine Karte.

## Was du brauchst

- Nur E-Mail (Google, Microsoft oder GitHub)

## Schritte

1. Gehe zu **https://tailscale.com/download** → **Download** für **Windows** → Installieren
   - Auf Windows nach Installation: **Tailscale Icon unten rechts → Log in** → Browser öffnet → mit Google einloggen → Fertig. Windows hat jetzt Adresse `100.x.x.x`

2. Gleich für **Mac**: https://tailscale.com/download → Mac → Installieren → Log in (gleiche E-Mail!)

3. Fertig. Beide Geräte sehen sich. Teste vom Mac:
   ```
   ping 100.x.x.x  (die Windows Adresse aus Tailscale)
   ssh deinuser@100.x.x.x
   ```

## Wizard

Jetzt fragt Generator nur noch **Passwort**. Keine Token, keine IP.

```
generate_template.command → Passwort → Enter → Fertig
```

Auf Windows: Final ausführen → installiert Tailscale automatisch falls fehlt → du loggst dich einmal im Browser ein → fertig.

Keine Karte, kein Geld, 2 Minuten.
