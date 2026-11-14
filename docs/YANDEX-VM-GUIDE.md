# RemoteGate — Yandex VM Guide: Wie kriege ich meine Yandex VM? Ist das kostenlos?

> Für Anfänger, Schritt-für-Schritt, auf Deutsch — weil du auf Mac generierst und dann Yandex brauchst. Mwah :3

## Kurzantwort: Ist Yandex VM kostenlos?

**Nein, nicht dauerhaft kostenlos** — aber du startest **kostenlos mit Trial-Guthaben**:

* **Für Privatpersonen:** Yandex gibt bei Anmeldung **~3000 RUB Grant für 60 Tage** (ca. $30) für deinen ersten Test. Damit ist die kleine VM für 2–3 Monate abgedeckt. Danach musst du auf **Pay-as-you-go** wechseln (Bezahlversion), sonst pausiert Cloud.
* **Für Firmen/Startup:** $5.000 für 6 Monate oder $20.000 für 12 Monate als Cloud Credits (Antrag nötig) — für unser kleines Bastion brauchst du das nicht.
* **Free Tier:** Bei Yandex **nicht** für laufende VM! Eine ausgeschaltete VM kostet nichts (vCPU/RAM nur im Betrieb), aber solange sie läuft, zahlst du. Deshalb gibt's Budget-Alarm unten.
* **Minimal-Kosten nach Trial:** Ab **~$13,48/Monat** (Minimal Preset: 2 vCPU 50%, 2 GB, 13 GB HDD, 1 IP) — unser empfohlenes 2 vCPU/2 GB/20% = **~$5–12/Monat** (ru-central1, non-preemptible). Preemptible (unterbrechbar) halbiert: ~$2–5, Tunnel startet nach Evict neu.

**Fazit:** Starte mit Trial, teste 30 Tage, dann entscheide. VM löschen = keine Kosten mehr (siehe Aufräumen). Budget-Alarm schützt vor Überraschung.

Preise: https://yandex.cloud/en/services/compute (Stand Okt 2026) + `docs/YANDEX-CLOUD-SETUP.md` Kosten-Tabelle.

---

## Was du brauchst

1. **Yandex ID** (E-Mail, wie Google Account) — kostenlos anlegen
2. **Bankkarte** (für Trial-Verifizierung, Russland-Trial braucht Karte, wird erst nach Grant belastet)
3. **Browser:** https://console.yandex.cloud
4. **5 Minuten Zeit**

---

## Schritt-für-Schritt — VM erstellen (Console, ohne Terminal)

### Schritt 1: Account & Billing

1. Gehe zu **https://console.yandex.cloud** → **Log in** → **Create account** (Yandex ID).
2. Nach Login: Oben **Billing** → **Create billing account** → Kartendaten, Adresse (für Privatperson).
3. Status prüfen: Billing → `ACTIVE` oder `TRIAL_ACTIVE` muss stehen. Wenn nicht, **Grant aktivieren** (Yandex zeigt Banner "Activate trial").
4. **Budget-Alarm setzen:** Billing → **Budgets** → Create budget → 500 RUB/Monat → E-Mail bei 80% — schützt vor Vergessen.

> **Tipp:** Ohne Billing kannst du keine VM erstellen. Das ist normal — Yandex will Karte für Missbrauchsschutz.

### Schritt 2: Cloud & Folder

1. Linkes Menü → **Clouds** → **Create cloud** → Name `remotegate` → Create.
2. In Cloud → **Create folder** → Name `default` oder `remotegate-prod` → Create.
3. Folder auswählen (oben Dropdown) — alle nächsten Ressourcen landen dort.

### Schritt 3: VM erstellen — Minimal & günstig

1. Im Folder: **Compute Cloud** → **Virtual machines** → **Create virtual machine** → wähle **Advanced setup** (nicht Quick).
2. **Boot disk image:** `Marketplace` → suche `Ubuntu 22.04 LTS` → `standard-images` → Disk **20 GB HDD** (network-hdd, billig) → Create.
3. **Location:** Zone `ru-central1-a` (Moskau, stabil — nach Okt 2026 Vorfällen meide b/d wenn Status rot, siehe https://status.yandex.cloud).
4. **Computing resources:**
   - Platform: `Intel Ice Lake` (Standard)
   - vCPU: **2**, RAM: **2 GB**, Core fraction: **20%** (burstable, günstig) — nicht 100% nötig für Bastion.
   - Minimal Preset würde auch gehen (2 vCPU 50%).
5. **Network:** VPC `default` → Subnet `default-ru-central1-a` → **Public IP: Auto** (wichtig! sonst kein SSH) → Security groups: **Create new** `remotegate-sg`:
   - Ingress: `0.0.0.0/0` TCP **22** Allow (später auf deine IP `/32` einschränken für Sicherheit)
   - Egress: `0.0.0.0/0` Allow all.
6. **Access:**
   - **Login:** `rgadmin` (nicht root!)
   - **SSH key:** Klicke **Add key** → **Add manually** → füge deinen **Mac Public Key** ein (`cat ~/.ssh/remotegate_mac_ed25519.pub` vom `bash mac/setup-keys.sh` — oder generiere neuen: `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`).
   - Wenn du noch keinen hast: Wähle **Generate key** → Yandex lädt ZIP mit Keys herunter → entpacke nach `~/.ssh/`.
7. **General:** Name `remotegate-bastion`, Hostname gleich, Description `RemoteGate Bastion`.
8. **Create VM** → wartet 30–60 Sek → Status `Running` → merke **Public IP** (z.B. `51.250.12.34`).

**CLI Alternative (für Profis):**
```bash
yc init  # nach https://yandex.cloud/en/docs/cli/quickstart installieren
yc compute instance create --name remotegate-bastion --zone ru-central1-a \
  --memory 2 --cores 2 --core-fraction 20 \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2204-lts,size=20,type=network-hdd \
  --network-interface subnet-name=default-ru-central1-a,nat-ip-version=ipv4 \
  --ssh-key ~/.ssh/remotegate_mac_ed25519.pub
```

### Schritt 4: VM härten (einmalig)

SSH rein:
```bash
ssh rgadmin@<DEINE_VM_IP>
sudo bash cloud/vm/setup.sh  # aus deinem geklonten Repo, oder manuell via docs
# Falls du kein Repo auf VM hast: kopiere setup.sh Inhalt per ssh oder nutze cloud-init
```

Was macht `setup.sh`:
- `PasswordAuthentication no`, `GatewayPorts no` (nur 127.0.0.1:2222, nicht öffentlich)
- `tunneluser` anlegen (`/usr/sbin/nologin`, `ForceCommand /bin/false`)
- `ufw` + `fail2ban`, Auto-Updates

**Oder:** Beim Erstellen `user-data` auf `cloud/vm/cloud-init.yaml` setzen — dann automatisch.

### Schritt 5: Tunnel Key verknüpfen (nach Windows Install)

Auf Windows (nach Wizard + Yandex Install):
```powershell
cat C:\ProgramData\RemoteGate\keys\tunnel_ed25519.pub
# Kopieren, auf VM:
sudo -u tunneluser bash -c "echo 'ssh-ed25519 AAAA... remotegate' >> ~/.ssh/authorized_keys"
sudo chmod 600 /home/tunneluser/.ssh/authorized_keys
```

Teste:
```powershell
# Auf Windows als Admin einmal zum Vertrauen:
ssh-keyscan -p 22 <VM_IP> >> C:\ProgramData\RemoteGate\config\ssh\known_hosts
ssh -i C:\ProgramData\RemoteGate\keys\tunnel_ed25519 -p 22 tunneluser@<VM_IP>
# Sollte sofort trennen (ForceCommand) — = Auth okay!
```

Auf VM prüfen nach Tunnel-Start:
```bash
ss -tlnp | grep 2222  # muss 127.0.0.1:2222 zeigen, nicht 0.0.0.0:2222
```

### Schritt 6: Object Storage Bucket für Final-Skript (neu, für dein Passwort)

Für den **festen Passwort-Wizard** (dein 8-Schritte-Flow): Das finale Skript mit Passwort liegt privat auf Yandex, nicht GitHub.

Via Console:
- **Object Storage** → **Create bucket** → Name `my-remotegate-xyz123` (global eindeutig, nimm `remotegate-<deinname>-<zufall>`) → **Standard**, **Private** (wichtig!) → Create.
- Via `yc`:
```bash
yc storage bucket create --name my-remotegate-xyz123 --default-storage-class standard
yc iam service-account create --name remotegate-storage
yc resource-manager folder add-access-binding --role storage.editor --subject serviceAccount:<ID>
yc iam access-key create --service-account-name remotegate-storage  # → access/secret für aws configure
```

Wizard nutzt Bucket automatisch: `generate_template.command` → frage Bucket → Upload.

Terraform: `cd cloud/storage && terraform apply -var="bucket_name=..."` (siehe `cloud/storage/README.md`).

---

## Kosten im Detail

| Resource | Gratis? | Kosten/Monat | Tipp |
|----------|---------|-------------|------|
| VM aus | **Ja gratis** (ausgeschaltet zählt nicht) | $0 | Stoppe per Console wenn Pause |
| VM minimal an (2vCPU 2GB 20%) | Trial deckt 2–3 Mo | $5–12 → nach Trial | Preemptible halbiert |
| VM Standard 100% (2vCPU 2GB SSD 20) | Trial | $21,58 | Für Prod, aber Bastion braucht Minimal |
| Object Storage 1 GB | 100 GB egress frei/Mo | ~$0,02 | Final-Skript <1 MB = Cent |
| Function/Gateway (Status) | 1M Calls frei, dann $0,10/100k | gratis für 8k/Mo | Optional, nicht nötig für SSH |
| Gesamt Bastion+Bucket | Trial → | **~$5–15** | Budget 500 RUB setzen |

Vergleiche: AWS t3.micro ~$15, GCP e2-micro ähnlich — Yandex in Russland günstiger.

---

## Aufräumen (keine Kosten mehr)

**Console:**
- Compute → VM → **Delete** (IP frei)
- Object Storage → Bucket → Delete (oder nur Objekt `RemoteGate-Final.ps1`)
- VPC → Network löschen falls neu erstellt
- Functions/Gateway löschen (falls Status genutzt)
- IAM → Service Accounts löschen
- Billing bleibt, aber ohne Ressourcen keine Rechnung.

**Terraform:**
```bash
cd cloud/storage && terraform destroy
cd cloud/infrastructure && terraform destroy
```

---

## Häufige Fragen

**Brauche ich russische Karte/Adresse?**
- Trial für RU braucht RU-Karte. International (yandex.cloud/en) akzeptiert oft Visa/Mastercard, aber Region ist `ru-central1` (Moskau). Für internationale Zahlung: `kz1` (Kasachstan) hat nur 1 AZ, teurer. Am besten RU Trial testen, dann entscheiden. Ohne Karte kein VM.

**Kann ich ohne Yandex leben?**
- Ja: `.\generator\generate.sh --skip-upload` → nur LAN-SSH (`-SkipCloudConfig` im alten Installer) geht ohne Cloud, aber kein Remote aus Internet. Yandex ist nur Bastion (Jump).

**Public IP nötig?**
- Ja für Bastion, sonst kein SSH. Yandex gibt Auto-IP gratis solange VM läuft. Statische IP auch möglich (kostenlos solange attached).

**Wie sicher ist Yandex nach Okt 2026 Vorfällen?**
- Yandex Status zeigt welke Zonen gestört waren (ru-central1-b etc.). Nutze `ru-central1-a` (stabilste) + Backups. Unser Tunnel reconnected nach Evict.

**Alternative kostenlos?**
- Oracle Cloud Free Tier (4 ARM vCPU gratis), Google e2-micro gratis, AWS free tier 12 Mo — alle als Bastion nutzbar, aber Anleitung hier ist Yandex-spezifisch. Frage mich, ich passe Terraform an.

---

## Nächste Schritte nach VM

1. Wizard: `open generate_template.command` → Passwort + VM IP + Bucket → `dist/RemoteGate-Final.ps1`
2. Windows: `iwr https://storage.yandexcloud.net/<bucket>/RemoteGate-Final.ps1 -OutFile $env:TEMP\RemoteGate-Final.ps1; & $env:TEMP\RemoteGate-Final.ps1` (als Admin)
3. Teste Mac: `ssh -J rgadmin@<VM_IP> -p 2222 <auto-Benutzer>@127.0.0.1`

Siehe `docs/GENERATOR.md` (8 Schritte), `docs/INSTALLATION.md` Weg A, `docs/TROUBLESHOOTING.md`.

Noch Fragen? Schreib mir — :* 
