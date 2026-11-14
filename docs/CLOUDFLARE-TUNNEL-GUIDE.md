# RemoteGate — Cloudflare Tunnel Guide (Option A: 0 ₽/Monat)

> **Kostenlos, keine Public IP, funktioniert in Russland** — perfekt wenn 149 ₽ für IP zu viel sind. :3

## Kurzantwort: Was ist Cloudflare Tunnel?

Statt teurer VM mit IP (`51.250.12.34:2222`) baust du einen **ausgehenden Tunnel** von Windows zu Cloudflare. Windows ruft Cloudflare an — keine Ports öffnen, keine IP mieten.

```
Windows (OpenSSH :22) ←[cloudflared Tunnel, outbound]→ Cloudflare Edge → Dein Hostname (ssh.deinedomain.ru) ← Mac
```

* **Kosten:** Tunnel **0 ₽, unlimitiert, gratis auf Free Plan (bis 50 Users)** — nur Domain brauchst du (~7 $/Jahr oder gratis .tk).
* **Pfeil:** Dein `RemoteGate-Final.ps1` liegt weiter privat auf **Cloud.ru S3 15 GB gratis** (`s3.cloud.ru`) — Tunnel ist nur für SSH.
* **Haken:** RKN drosselt manchmal Cloudflare >16KB-Blöcke — teste ob `ssh.deinedomain.ru` von deinem Mac erreichbar ist. Falls nicht, nimm Option B (Tailscale).

---

## Was du vorher brauchst (5 Min)

1. **Cloudflare Account** — https://dash.cloudflare.com → Sign Up (kostenlos, E-Mail)
2. **Domain** — billigste .com/.ru bei Reg.ru/Namecheap für ~300 ₽/Jahr, oder gratis Subdomain bei freenom. Domain muss zu Cloudflare umgezogen werden (Nameserver ändern → Cloudflare gibt dir 2 Nameserver).
3. **Windows PC** mit Admin-Rechten
4. **Mac** mit `cloudflared` oder `ssh` + Browser für Token

---

## Schritt-für-Schritt — Tunnel erstellen (Console, ohne Terminal)

### Schritt 1: Domain zu Cloudflare hinzufügen

1. Cloudflare Dashboard → **Add a Site** → Domain eingeben (`deinedomain.ru`) → **Free Plan** wählen.
2. Cloudflare zeigt 2 Nameserver (`ava.ns.cloudflare.com`, `cody.ns.cloudflare.com`) → bei deinem Registrar (Reg.ru, NIC, etc.) **Nameserver ändern** auf diese.
3. Warten 5 Min bis 2h → Status **Active** (grün).

### Schritt 2: Zero Trust aktivieren (einmalig)

1. Dashboard links → **Zero Trust** → **Get Started** → **Free Plan** wählen (klick „Continue with Free“).
2. Es fragt nach **Team Name** (`remotegate`) → beliebig.
3. **Zahlung:** Cloudflare verlangt **Karte/PayPal für Verifizierung** (wird nicht belastet auf Free Plan) — ohne Karte kein Tunnel! Falls keine Karte: Alternative Tailscale nehmen.

### Schritt 3: Tunnel erstellen — Token holen

Das ist das **Wichtigste für Schritt 2 im Wizard!**

1. Zero Trust Dashboard → **Networks → Tunnels** → **Create a tunnel**.
2. **Select type:** `Cloudflared` → Name eingeben: `remotegate-ssh` → **Save**.
3. **Choose environment:** `Windows` → Cloudflare zeigt **Install-Befehl** mit **Token**:

   ```
   cloudflared.exe service install eyJhIjoiNWIxNDMyZTItZmYx...
   ```

   **Diesen langen Token kopieren!** (beginnt mit `eyJh...`, ~300 Zeichen). Das ist dein `Cloudflare Tunnel Token`.
4. **Configure hostname:** Im gleichen Wizard → **Public Hostname** → 
   - Subdomain: `ssh`
   - Domain: `deinedomain.ru` (deine Domain)
   - Type: `SSH`
   - URL: `ssh://localhost:22`
   → **Save**.

5. **Fertig:** Du siehst Tunnel `remotegate-ssh` + Hostname `ssh.deinedomain.ru` → Status bald `Healthy`.

**Wo finde ich Token später wieder?**
Zero Trust → **Tunnels** → `remotegate-ssh` → **Configure** → Tab **Install + Run** → Token steht dort. Oder **Edit** → Token neu generieren.

### Schritt 4: Bucket für Pfeil (Cloud.ru, gratis)

Wie vorher — dein Final-Skript liegt trotzdem auf Cloud.ru, nicht Cloudflare:

1. https://console.cloud.ru → Projekt → **Object Storage** → **Bucket erstellen** → Name `remotegate-<name>-<zufall>` (z.B. `remotegate-ki10-2026`) → **Standard, Privat**.
2. **Keys:** Console → **IAM → Service Accounts → Zugriffsschlüssel** → erstellen → merkst du für `aws configure` (Access/Secret, Endpoint `https://s3.cloud.ru`).

Wizard nutzt Bucket gleich — du gibst nur Namen ein, Upload geht automatisch.

---

## Was der Wizard bei Option A fragt (Schritt 2)

Wenn du `generate_template.command` doppelklickst und `[1] Cloudflare Tunnel` wählst, fragt er:

```
── Schritt 2: Cloudflare Tunnel (kostenlos, keine IP) ──

Cloudflare Tunnel Token (eyJh... aus Dashboard → Tunnels → Install):
> eyJhIjoiNWIxNDMyZTItZmYx...

Public Hostname (z.B. ssh.deinedomain.ru):
> ssh.deinedomain.ru

Tunnel Name (Enter = remotegate-ssh):
> [ remotegate-ssh ]

Object Storage Bucket für Final-Skript (Cloud.ru, z.B. remotegate-ki10-2026):
> remotegate-ki10-2026
```

**Wo kriege ich das her?**

| Frage im Wizard | Woher? |
|---|---|
| **Tunnel Token** (`eyJh...`) | Zero Trust → Tunnels → `remotegate-ssh` → Configure → Install+Run → langer Token kopieren |
| **Public Hostname** | Das was du bei Tunnel → Public Hostnames eingetragen hast: `ssh`+`deinedomain.ru` → `ssh.deinedomain.ru` |
| **Tunnel Name** | Name beim Erstellen: `remotegate-ssh` — kannst Enter lassen |
| **Bucket** | Cloud.ru Console → Object Storage → dein Bucket-Name |

Alles andere (Tunnel Port, VM IP) **entfällt** — du zahlst 0 ₽!

---

## Windows Installation (nach Wizard)

1. Wizard hat `dist/RemoteGate-Final.ps1` erstellt + auf Cloud.ru hochgeladen.

2. **Auf Windows als Admin:**

   ```powershell
   # Presigned URL aus Wizard kopieren (privat, 7 Tage gültig):
   $url="https://remotegate-ki10-2026.s3.cloud.ru/RemoteGate-Final.ps1?X-Amz-Algorithm=..."
   Invoke-WebRequest -Uri $url -OutFile $env:TEMP\RemoteGate-Final.ps1
   & $env:TEMP\RemoteGate-Final.ps1
   ```

   Der Final-Skript macht automatisch:
   - OpenSSH installieren, Firewall LocalSubnet
   - **cloudflared.exe herunterladen** (nach `C:\ProgramData\RemoteGate\bin\cloudflared.exe`)
   - Tunnel mit deinem Token installieren: `cloudflared service install eyJh...`
   - Service starten → in Cloudflare Dashboard wird Tunnel `Healthy` grün

3. **Prüfen auf Windows:**

   ```powershell
   Get-Service cloudflared  # muss Running sein
   & "C:\ProgramData\RemoteGate\bin\cloudflared.exe" tunnel info remotegate-ssh
   ```

4. **Mac Verbindung testen:**

   ```bash
   # Mit cloudflared auf Mac (brew install cloudflared):
   cloudflared access ssh --hostname ssh.deinedomain.ru

   # Oder einfach SSH via Cloudflare (wenn SSH über Tunnel konfiguriert):
   ssh -o ProxyCommand="cloudflared access ssh --hostname %h" windowsuser@ssh.deinedomain.ru
   ```

   **Alternative ohne cloudflared auf Mac:** Nutze `ssh` über Cloudflare Access → `ssh ssh.deinedomain.ru` (wenn du Access Policy auf Bypass stellst).

---

## Kosten im Detail (Option A)

| Resource | Gratis? | Kosten |
|---|---|---|
| Cloudflare Tunnel | **Ja (Free, 50 Users)** | 0 ₽ |
| Domain | Nein (einmalig) | ~300-700 ₽/Jahr (~3-5 €) — oder gratis Freenom |
| Cloud.ru S3 15 GB | **Ja** | 0 ₽ |
| Windows OpenSSH | Ja | 0 ₽ |
| **Gesamt** | **Free Tier** | **~0 ₽/Monat + Domain einmalig** |

Vgl. Cloud.ru mit IP: 149 ₽/Monat; Yandex: 500+ ₽/Monat.

---

## Häufige Fragen

**Brauche ich Domain?**
Ja, Tunnel braucht Hostname (`ssh.example.com`). Ohne Domain kein Tunnel. Billigste .ru/.com reicht, oder Cloudflare kauft Domain direkt (7 $/Jahr). Gratis-Alternative: Tailscale braucht keine Domain.

**Was wenn Cloudflare in RU geblockt ist?**
Teste: `curl -I https://ssh.deinedomain.ru` vom Mac. Wenn Timeout >16KB: RKN-Drossel aktiv. Dann nimm Tailscale (Option C) — funktioniert immer in RU.

**Kann ich Bucket weglassen?**
Ja — Wizard lässt Bucket leer, dann musst du Final per USB/scp auf Windows bringen. Aber S3 ist gratis, nutze es!

**Token verloren?**
Zero Trust → Tunnels → Configure → neuen Token generieren → Wizard neu ausführen → neu hochladen.

**Will zurück zu VM?**
Wizard neu → [2] Cloud.ru oder [3] Yandex wählen → neu generieren.

---

## Nächste Schritte

1. Wizard: `open generate_template.command` → [1] Cloudflare → Token + Hostname + Bucket → `dist/RemoteGate-Final.ps1`
2. Windows: Final aus Cloud.ru laden (oben)
3. Teste Mac: `ssh via ssh.deinedomain.ru`

Siehe `docs/GENERATOR.md` + `cloud/cloudflare/README.md`.
