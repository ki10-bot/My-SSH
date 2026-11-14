# Einfach — 5 Minuten

Du brauchst nur 3 Dinge. Ich zeige dir wo genau klicken.

## Was du brauchst

1. Domain — z.B. `meinname.ru` (bei Reg.ru kaufen, ~300 ₽)
2. Passwort für Windows — du wählst es
3. Token — hole ich dir in 2 Minuten (siehe unten)

Das ist alles.

## So holst du Token + Hostname (2 Min)

Cloudflare hat Knopf umbenannt — deshalb findest du "Add site" nicht. Mache so:

1. Gehe zu **https://dash.cloudflare.com** — einloggen
2. Oben links steht **"+ Add a site"** oder **"Website hinzufügen"** — gleicher Knopf. Falls du ihn nicht siehst: Links Menü → **Websites** → dort ist **Add site**.
3. Domain eintragen → **Free** wählen → Weiter
4. Cloudflare zeigt 2 Adressen wie `ava.ns.cloudflare.com` — diese bei Reg.ru unter **DNS / Nameserver** eintragen (2 Zeilen kopieren). Dann **Done** klicken.
5. Jetzt links → **Zero Trust** → **Create tunnel** → Name `remotegate` → **Save** → **Windows** wählen → du siehst langen Text `eyJh...` → **Kopieren**. Das ist Token.
6. Im gleichen Fenster → **Public hostname → Add** → `ssh` + deine Domain → `ssh://localhost:22` → Save.

Fertig. Token + `ssh.deinedomain.ru` hast du.

## Wizard (Mac)

1. `generate_template.command` doppelklicken
2. Passwort eingeben (du siehst nichts — normal, Enter)
3. Token einfügen (Enter)
4. Hostname `ssh.deinedomain.ru` eingeben (Enter)
5. Fertig — Datei liegt in `dist/`

Mehr fragt er nicht. Kein langer Text mehr.

## Windows

1. Wizard gibt dir Link `https://....s3.cloud.ru/RemoteGate-Final.ps1`
2. Auf Windows als Admin: Link kopieren → `Invoke-WebRequest -Uri "LINK" -OutFile $env:TEMP\RemoteGate-Final.ps1` → `& $env:TEMP\RemoteGate-Final.ps1`
3. Fertig — Tunnel läuft.

Teste: `ssh deinuser@ssh.deinedomain.ru` vom Mac.

Hilfe? Sag mir was du auf Bildschirm siehst — ich sage dir nächsten Klick. Du schaffst das.
