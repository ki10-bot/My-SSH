# RemoteGate — Cloud.ru VM Guide: Wie kriege ich meine Cloud.ru VM? Ist das kostenlos?

> Für Anfänger, Schritt-für-Schritt, auf Deutsch — weil du auf Mac generierst und dann Cloud.ru brauchst. Mwah :3
> **Update Nov 2026: Wir sind von Yandex auf Cloud.ru umgestiegen — weil Cloud.ru einen echten Free Tier hat!**

## Kurzantwort: Ist Cloud.ru VM kostenlos?

**Ja — fast komplett kostenlos, dauerhaft!** Das ist der Grund für den Wechsel:

* **Free Tier VM für immer:** **1 VM mit 2 vCPU / 4 GB RAM / 30 GB NVMe** — **kostenlos für immer** (eine VM pro Organisation, solange Free Tier aktiv + 60 Tage Inaktivitäts-Limit). [Cloud.ru Docs: VM Free Tier](https://cloud.ru/docs/evolution/overview/topics/free-tier__virtual-machines)
* **Free Tier Object Storage:** **15 GB Speicher + 100.000 PUT + 1.000.000 GET + 10 TB Traffic pro Monat gratis** — dein `RemoteGate-Final.ps1` (~40 KB) kostet 0 ₽. [Cloud.ru Docs: S3 Free Tier](https://cloud.ru/docs/s3e/ug/topics/pricing) / [Free Tier Übersicht](https://cloud.ru/offers/free-tier)
* **Was kostet doch? Public IP / SNAT** — **nicht im Free Tier!** VM wird ohne Internet erstellt. Für Bastion brauchst du **Public IP oder SNAT-Gateway: 0,17 ₽/Stunde ohne MwSt. = 0,204 ₽/Stunde mit 22% MwSt. ≈ 146–148 ₽/Monat (~1,50 €)**. [Tarife Evolution Compute](https://cloud.ru/documents/tariffs/evolution/evolution-compute) [Pepper Test](https://www.pepper.ru/deals/besplatnyi-virutalnyi-server-navsegda-ot-cloudru-463337)
* **Bonus bei Start:** Bei Registrierung + Kartenbindung **4.000 Bonus-RUB für 60 Tage** — damit zahlst du IP 27 Monate theoretisch gratis. [Habr FAQ](https://habr.com/ru/companies/cloud_ru/articles/819727/) [Kod.ru Test](https://kod.ru/test-draiv-oblaka-cloud-ru)
* **Mindestguthaben:** Zum Erstellen musst du **100 RUB** einmalig einzahlen (verfällt nicht sofort, wird nur für IP verbraucht) — sonst kein Free Tier. [Pepper](https://www.pepper.ru/deals/besplatnyi-virutalnyi-server-navsegda-ot-cloudru-463337)

**Fazit:** VM + S3 = 0 ₽/Monat, nur Public IP ~146 ₽/Monat. **~1,50 €/Monat für Bastion+Bucket — günstiger als Yandex (~5-15 €)**. Kein Trial-Ende wie Yandex (60 Tage). Wenn du IP nicht brauchst (pausiert), zahlst du 0 ₽. Budget-Alarm unten schützt dich.

Preise: [Evolution Compute Tarife](https://cloud.ru/documents/tariffs/evolution/evolution-compute) + [S3 Tarife](https://cloud.ru/documents/tariffs/evolution/object-storage) Stand Sep 2026.

---

## Was du brauchst

1. **Cloud.ru Account** (E-Mail, wie Google Account) — kostenlos auf [console.cloud.ru](https://console.cloud.ru)
2. **Russische Bankkarte** (für Verifizierung, auch Mir-Visa/Mastercard) + Telefon — für 100 RUB Aufladung
3. **Browser:** https://console.cloud.ru
4. **5 Minuten Zeit**

---

## Schritt-für-Schritt — VM erstellen (Console, ohne Terminal)

### Schritt 1: Account & Free Tier aktivieren

1. Gehe zu **https://console.cloud.ru** → **Registrieren** → E-Mail + Telefon bestätigen.
2. **Organisation erstellen:** Name `remotegate` → **Projekt erstellen:** `default`.
3. **Free Tier aktivieren:** Im Projekt → **Evolution** → **Free Tier** → Formular ausfüllen → **Aktivieren**. Es wird 1 VM (2/4/30) + 15 GB S3 freigeschaltet.
4. **Guthaben aufladen:** **Finanzen → Aufladen → 100 RUB** (Mindestbetrag für Ressourcenerstellung, via SBP/Karte). 4.000 Bonus-RUB kommen dann automatisch (60 Tage gültig).
5. **Budget-Alarm:** Finanzen → **Benachrichtigungen** → Limit 300 RUB/Monat → E-Mail bei 80%.

> Tipp: Ohne Free Tier + 100 RUB kannst du keine VM erstellen — das ist normal. Geld wird nur für IP verbraucht, VM selbst bleibt 0 ₽.

### Schritt 2: Netzwerk & IP

Cloud.ru braucht vor VM Netzwerk + IP (anders als Yandex):

1. **VPC:** Evolution → **Netzwerk → VPC** → **Erstellen** → Name `remotegate-net` → `10.10.0.0/24` → Erstellen.
2. **Subnet:** Im VPC → **Subnet hinzufügen** → Zone `ru-moscow-1` (oder `ru-central` — Moskau) → CIDR `10.10.0.0/24` → Erstellen.
3. **Public IP:** Evolution → **Netzwerk → Public IP** → **Reservieren** → Name `remotegate-ip` → Zone `ru-moscow-1` → **Erstellen** (kostet 0,204 ₽/Std. ab jetzt). Merke IP (z.B. `80.87.XXX.XXX`).
   - *Alternative SNAT:* Wenn du mehrere VMs hast, nimm **SNAT-Gateway** (gleicher Preis, teilt IP). Für 1 Bastion: Public IP direkt ist einfacher.
4. **Security Group:** Netzwerk → **Security Groups** → **Erstellen** → `remotegate-sg` → VPC `remotegate-net` →
   - Ingress: `0.0.0.0/0` TCP **22** Allow (später auf deine Mac-IP `/32` einschränken!)
   - Egress: `0.0.0.0/0` Allow all.

### Schritt 3: VM erstellen — Free Tier

1. Evolution → **Compute → Virtuelle Maschinen** → **Erstellen**.
2. **Name:** `remotegate-bastion`, **Zone:** `ru-moscow-1a`.
3. **Ressourcen:** Wähle **Free Tier** Preset: **2 vCPU / 4 GB RAM / 30 GB NVMe / 10% garantiert** — sollte 0 ₽/Monat zeigen. Nicht ändern, sonst kostenpflichtig!
4. **Image:** `Ubuntu 22.04 LTS` (Standard-Image).
5. **Netzwerk:** VPC `remotegate-net`, Subnet `10.10.0.0/24`, **Public IP → `remotegate-ip` zuweisen** (wichtig! sonst kein SSH), Security Group `remotegate-sg`.
6. **Zugang:**
   - **Login:** `rgadmin` (nicht root!)
   - **SSH-Key:** **Hinzufügen** → **Manuell** → füge deinen **Mac Public Key** ein (`cat ~/.ssh/remotegate_mac_ed25519.pub` vom `bash mac/setup-keys.sh` — oder `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`).
7. **Erstellen** → 30–60 Sek → Status `Running` → merke **Public IP** aus Schritt 2.

**CLI Alternative:**
```bash
# Cloud.ru CLI (https://cloud.ru/docs/evolution/cli/quickstart)
cloudru auth login
cloudru compute vm create --name remotegate-bastion --zone ru-moscow-1a \
  --flavor 2vcpu-4gb --disk 30 --image ubuntu-2204-lts \
  --vpc remotegate-net --subnet 10.10.0.0/24 --public-ip remotegate-ip \
  --ssh-key ~/.ssh/remotegate_mac_ed25519.pub --user rgadmin
```

### Schritt 4: VM härten (einmalig)

SSH rein:
```bash
ssh rgadmin@<DEINE_CLOUDRU_IP>
sudo bash cloud/vm/setup.sh  # aus deinem Repo, oder manuell via docs
# Falls kein Repo auf VM: nutze cloud-init beim Erstellen (user-data = cloud/vm/cloud-init.yaml)
```

Was macht `setup.sh` (gleich wie Yandex, funktioniert überall):
- `PasswordAuthentication no`, `GatewayPorts no` (nur 127.0.0.1:2222)
- `tunneluser` anlegen (`/usr/sbin/nologin`, `ForceCommand /bin/false`)
- `ufw` + `fail2ban`, Auto-Updates

### Schritt 5: Tunnel Key verknüpfen (nach Windows Install)

Auf Windows (nach Wizard + Cloud.ru Install):
```powershell
cat C:\ProgramData\RemoteGate\keys\tunnel_ed25519.pub
# Kopieren, auf VM:
sudo -u tunneluser bash -c "echo 'ssh-ed25519 AAAA... remotegate' >> ~/.ssh/authorized_keys"
sudo chmod 600 /home/tunneluser/.ssh/authorized_keys
```

Teste:
```powershell
ssh-keyscan -p 22 <CLOUDRU_IP> >> C:\ProgramData\RemoteGate\config\ssh\known_hosts
ssh -i C:\ProgramData\RemoteGate\keys\tunnel_ed25519 -p 22 tunneluser@<CLOUDRU_IP>
# Sollte sofort trennen (ForceCommand) — = Auth okay!
```
Auf VM prüfen: `ss -tlnp | grep 2222` → muss `127.0.0.1:2222` zeigen.

### Schritt 6: Object Storage Bucket für Final-Skript (neu, für dein Passwort)

Dein festes Passwort-Skript liegt privat auf Cloud.ru, nicht GitHub.

Via Console (einfach):
- **Haltung → Object Storage** → **Bucket erstellen** → Name `my-remotegate-xyz123` (global eindeutig, nimm `remotegate-<name>-<zufall>`) → **Standard Klasse** → **Privat** (wichtig!) → Erstellen.
- Via API (S3-kompatibel, Endpoint `https://s3.cloud.ru`):
```bash
# Keys: Console → IAM → Service Account → Zugriffsschlüssel erstellen
aws s3 mb s3://my-remotegate-xyz123 --endpoint-url https://s3.cloud.ru
```

Wizard nutzt Bucket automatisch: `generate_template.command` → fragt Bucket → Upload via `aws s3 cp --endpoint-url https://s3.cloud.ru`.

Terraform: `cd cloud/storage && terraform apply -var="bucket_name=..."` (siehe `cloud/storage/README.md` — jetzt Cloud.ru).

---

## Kosten im Detail (Cloud.ru)

| Resource | Gratis? | Kosten/Monat | Tipp |
|----------|---------|-------------|------|
| VM 2vCPU/4GB/30GB Free Tier | **Ja, für immer (1 VM/Org)** | 0 ₽ | Nicht ändern, sonst PayGo ~2745 ₽/Mo für 2/4/40 [Tproger Vergleich](https://tproger.ru/articles/oblachnye-servery-v-rossii-sravnivaem-provajderov-na-odinakovoj) |
| S3 15 GB + 1M GET/100k PUT + 10 TB Traffic | **Ja** | 0 ₽ | Final-Skript <1 MB = im Free |
| Public IP | **Nein** | 146,88 ₽ (~1,50 €) | Mit Bonus 4000 RUB 27 Monate gratis; ohne IP kein SSH |
| S3 über 15 GB | Nein | 1,13 ₽/GB + 1,17 ₽/GB Traffic [S3 Docs](https://cloud.ru/docs/s3e/ug/topics/pricing) | Für 1 GB extra ~2 ₽ |
| SNAT statt Public IP | Nein | gleich 146 ₽/Mo | Teilt IP für mehrere VMs |
| **Gesamt Bastion+Bucket** | **Free Tier →** | **~146 ₽/Mo (~1,50 €)** | **Yandex war ~500-1500 ₽/Mo** |

Vergleiche: Yandex Minimal $13,48/Monat, Timeweb ab 180 ₽, Selectel ab 385 ₽ — Cloud.ru Free Tier ist günstigste mit vollständiger Cloud.

---

## Aufräumen (keine Kosten mehr)

**Console:**
- Compute → VM → **Löschen** (Public IP freigeben → Kosten stoppen)
- Object Storage → Bucket → Löschen (oder nur Objekt `RemoteGate-Final.ps1`)
- Netzwerk → VPC/Public IP/Security Group löschen
- IAM → Service Accounts löschen

**Terraform:**
```bash
cd cloud/storage && terraform destroy
cd cloud/infrastructure && terraform destroy
```

---

## Häufige Fragen

**Brauche ich russische Karte?**
- Ja, 100 RUB via SBP/Mir/Karte. Ohne Guthaben kein VM. Bonus 4000 RUB deckt IP lange.

**Kann ich ohne Cloud.ru leben?**
- Ja: `./generator/generate.sh --skip-upload` → nur LAN-SSH (kein Remote). Cloud.ru ist nur Bastion (Jump).

**Public IP nötig?**
- Ja für Bastion, sonst kein SSH. Cloud.ru vergibt reservierte IP (kostet), nicht Auto wie Yandex. SNAT nur für Outbound, nicht für SSH-Jump — nimm Public IP.

**Wie sicher ist Cloud.ru?**
- Sber-Tochter, 9 Tier-III DCs in Russland, 152-FZ, seit 2024 Evolution. VM-Tunnel reconnected nach Reboot.

**Wechsel von Yandex?**
- Einfach IP im Wizard neu eingeben → neu generieren → neuer Upload → Windows neu installieren (idempotent). Alte Yandex VM löschen.

---

## Nächste Schritte nach VM

1. Wizard: `open generate_template.command` → Passwort + Cloud.ru IP + Bucket → `dist/RemoteGate-Final.ps1`
2. Windows: `aws s3 cp` braucht Endpoint `https://s3.cloud.ru` — Wizard zeigt Befehl: `iwr https://<bucket>.s3.cloud.ru/RemoteGate-Final.ps1 -OutFile $env:TEMP\RemoteGate-Final.ps1; & $env:TEMP\RemoteGate-Final.ps1` (als Admin, via presigned wenn privat)
3. Teste Mac: `ssh -J rgadmin@<CLOUDRU_IP> -p 2222 <auto-Benutzer>@127.0.0.1`

Siehe `docs/GENERATOR.md` (8 Schritte), `docs/INSTALLATION.md` Weg A, `docs/TROUBLESHOOTING.md`.

Noch Fragen? Schreib mir — :*
