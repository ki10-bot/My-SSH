# RemoteGate — Generator & Yandex Upload Guide

> **Neuer Workflow (deine 8 Schritte):** GitHub enthält Installer + Beispiel → du lädst Repo herunter → öffnest Wizard → setzt festes Passwort (`DEIN_PASSWORT` → dein echtes) + Yandex Daten → Wizard injiziert in Beispiel → finaler Skript → Upload nach Yandex → Windows lädt aus Yandex (nicht GitHub).

## 1. Warum Yandex statt GitHub für Windows Installation?

- **Privatsphäre:** Dein festes Passwort ist im finalen Skript (für `net user`) — es darf nicht öffentlich auf GitHub stehen. Yandex Object Storage Bucket ist **privat** (ACL private) oder zeitlich begrenzt via presigned URL.
- **Kontrolle:** Du kontrollierst Bucket-Zugriff (IAM, Löschung nach Installation).
- **Aktualisierbarkeit:** Du kannst finalen Skript neu generieren und erneut hochladen, ohne GitHub Release.

Das GitHub Repo enthält immer nur **Platzhalter** (`DEIN_PASSWORT`, `DEIN_YANDEX_VM_IP` etc.) — niemals echte Passwörter (`.gitignore` schützt `dist/`).

## 2. Voraussetzungen

- **Repo herunterladen:**
  ```bash
  git clone https://github.com/ki10-bot/My-SSH.git
  cd My-SSH
  # oder: Download ZIP von GitHub → entpacken
  ```
- **PowerShell 5.1+** (Windows, für Wizard) oder `pwsh` 7+ (Mac/Linux auch möglich). Für Passwort-Prompt ist PowerShell ideal.
- **Optional für Auto-Upload:** Yandex Cloud CLI `yc` konfiguriert (`yc init`) oder AWS CLI mit Yandex S3 Keys.
  - Service Account: `yc iam service-account create --name remotegate-storage`
  - Rolle: `yc resource-manager folder add-access-binding --role storage.editor --subject serviceAccount:<id>`
  - Keys: `yc iam access-key create --service-account-name remotegate-storage` → `aws configure` (Access/Secret, Region `ru-central1`, Endpoint `https://storage.yandexcloud.net`)

## 3. Wizard starten

```powershell
# Im Repo-Root, PowerShell:
.\generator\New-RemoteGateDeployment.ps1
```

### Schritt 1 — Passwort festlegen

```
── Schritt 1: Windows Zugang (festes Passwort) ──
Windows Benutzername [RemoteUser]: johndoe
Festes Passwort für johndoe (verdeckt, leer = kein Passwort): ********
Passwort bestätigen: ********
```

- **Stärke-Check:** ≥12 Zeichen, Groß/Klein/Zahl/Sonderzeichen. Wizard warnt bei schwachen (z.B. `DEIN_PASSWORT`, `123456`).
- **Leer lassen:** → Key-only (sicherer), `PasswordAuthentication no` im finalen Skript.
- **Gefüllt:** → Wizard aktiviert `PasswordAuthentication yes` + `AllowUsers <user>` + setzt Windows Passwort via `net user`/`Set-LocalUser` (nicht im Log).

### Schritt 2 — Yandex Daten

```
── Schritt 2: Yandex Zugang ──
Yandex VM öffentliche IP (z.B. 51.250.12.34, leer = Platzhalter): 51.250.12.34
Yandex VM Tunnel Benutzer [tunneluser]: tunneluser
Yandex SSH Port [22]:
Reverse Tunnel Port auf VM [2222]:
Yandex Object Storage Bucket für Final-Skript (z.B. my-remotegate-bucket): my-remotegate-bucket
Status Endpoint (HTTPS) konfigurieren? (j/N): N
Windows Hostname [DESKTOP-XYZ]:
```

- Alles kann leer bleiben → Platzhalter bleibt, du editierst später `config.json` auf Windows.
- **Bucket:** Wird für Auto-Upload verwendet. Existiert er nicht, Wizard erstellt ihn via `yc`.

### Schritt 3 — Generierung

```
── Schritt 3: Generiere FINALEN Installer ──
[INFO] Template: templates/RemoteGate-Deployment.template.ps1
[PASS] FINALER Installer geschrieben: dist/RemoteGate-Final.ps1 (45230 Bytes)
DeviceId: a1b2c3d4-e5f6...
```

- `dist/RemoteGate-Final.ps1` ist der **finale, private Skript** mit echten Werten (Passwort in plain für Windows).
- Cache `generator/last-generation.json` speichert Werte **ohne** Passwort für nächsten Durchlauf.

### Schritt 4 — Upload

Wenn Bucket angegeben:

```
── Schritt 4: Upload nach Yandex Object Storage ──
[INFO] Versuche Upload nach Yandex Bucket: my-remotegate-bucket ...
[INFO] yc CLI gefunden
[PASS] Upload via yc erfolgreich!
Bucket: my-remotegate-bucket
URLs:
  https://storage.yandexcloud.net/my-remotegate-bucket/RemoteGate-Final.ps1
  https://my-remotegate-bucket.storage.yandexcloud.net/RemoteGate-Final.ps1

Presigned URL (privat, gültig 168 Stunden):
  https://storage.yandexcloud.net/...?X-Amz-Signature=...

Windows Install (presigned, privat):
  $url="https://storage...?X-Amz..."
  Invoke-WebRequest -Uri $url -OutFile $env:TEMP\RemoteGate-Final.ps1
  & $env:TEMP\RemoteGate-Final.ps1
```

- Bei **privatem** Objekt (Standard) → presigned URL (7 Tage default, `-PresignHours` einstellbar).
- Bei `-MakePublic` → öffentliche URL (Wartung: nach Installation löschen!).
- Ohne yc/aws → manuelle Anleitung (YC Console → Object Storage → Upload).

## 4. Windows Installation (aus Yandex)

**Als Administrator** auf Windows PC:

```powershell
# Variante A: Private (presigned, empfohlen):
$url="https://storage.yandexcloud.net/my-remotegate-bucket/RemoteGate-Final.ps1?X-Amz-Signature=..."
Invoke-WebRequest -Uri $url -OutFile $env:TEMP\RemoteGate-Final.ps1
# Optional: Hash prüfen
Get-FileHash $env:TEMP\RemoteGate-Final.ps1 -Algorithm SHA256
& $env:TEMP\RemoteGate-Final.ps1

# Variante B: Öffentlich (wenn du -MakePublic gewählt hast):
irm https://storage.yandexcloud.net/my-remotegate-bucket/RemoteGate-Final.ps1 -OutFile $env:TEMP\RemoteGate-Final.ps1; & $env:TEMP\RemoteGate-Final.ps1

# Variante C: Einzeiler (aus Wizard Output kopieren):
iwr "https://storage.yandexcloud.net/my-bucket/RemoteGate-Final.ps1" -OutFile $env:TEMP\RemoteGate-Final.ps1; & $env:TEMP\RemoteGate-Final.ps1
```

Der finale Skript macht alles in einem Rutsch (kein Download von GitHub nötig):
- Prüft Windows Build, Admin
- Setzt DeviceId (aus Wizard)
- Schreibt `config.json` (mit Yandex IP etc. — kein manuelles Edit nötig)
- Setzt festes Passwort (wenn eingegeben) + `PasswordAuthentication yes`
- Installiert OpenSSH Server, Firewall LocalSubnet
- Generiert Tunnel Key, Scheduled Task
- Startet Tunnel (falls IP konfiguriert)

**Nicht mehr nötig:** `notepad config.json` + manuelles `ssh-keyscan` — Wizard hat bereits alles vor-konfiguriert!

## 5. Vorab: Yandex VM + Bucket erstellen

Siehe `docs/YANDEX-CLOUD-SETUP.md` für VM. Für Bucket zusätzlich:

```bash
# Via yc:
yc storage bucket create --name my-remotegate-bucket --default-storage-class standard

# Via Terraform (erweitert in cloud/infrastructure/):
# In cloud/storage/ oder cloud/infrastructure/Bucket hinzufügen (siehe cloud/storage/README.md)
```

Oder Wizard erstellt Bucket automatisch beim ersten Upload.

## 6. Non-Interactive (Automation)

```powershell
# my-config.json aus generator/Example-Config.json.example kopieren + füllen
.\generator\New-RemoteGateDeployment.ps1 -ConfigFile .\generator\my-config.json -NonInteractive -SkipUpload
# Ergebnis: dist/RemoteGate-Final.ps1
# Dann: .\generator\Upload-ToYandex.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-bucket
```

## 7. Beispiel vs Template vs Final

| Datei | Ort | Enthält Passwort? | Verwendung |
|-------|-----|------------------|------------|
| `generator/Example-Install.ps1.example` | GitHub | `DEIN_PASSWORT` Platzhalter | Anschauung — nicht ausführen |
| `templates/RemoteGate-Deployment.template.ps1` | GitHub | `__WINDOWS_PASSWORD__` → `DEIN_PASSWORT` | Template für Wizard |
| `dist/RemoteGate-Final.ps1` | Lokal + Yandex Bucket (privat) | Dein echtes Passwort (plain) | Wird auf Windows ausgeführt (aus Yandex) |

**Regel:** `dist/` niemals committen! (`.gitignore`).

## 8. Sicherheitshinweise

- **DEIN_PASSWORT** ist nur Platzhalter — niemals als echtes Passwort verwenden.
- Finaler Skript enthält Passwort in plain — Bucket **privat** halten, presigned URLs nach Gebrauch widerrufen, lokalen `dist/` nach Upload sicher löschen oder verschlüsseln.
- Wizard loggt Passwort **nie** (redacted `***REDACTED***`), speichert es nicht in `last-generation.json`.
- `PasswordAuthentication yes` nur wenn du explizit Passwort im Wizard setzt — sonst bleibt `no` (Key-only, empfohlen).
- Bucket ACL: Default `private`. Für `public-read` musst du `-MakePublic` explizit setzen — Wizard warnt + verlangt Enter.
- Nach Windows Installation: `Remove-Item $env:TEMP\RemoteGate-Final.ps1` auf Windows, `rm dist/RemoteGate-Final.ps1` lokal, oder Objekt aus Yandex löschen: `yc storage s3api delete-object --bucket <bucket> --key RemoteGate-Final.ps1`

## 9. Troubleshooting Wizard

| Problem | Lösung |
|---------|--------|
| `Template nicht gefunden` | Pfad prüfen, `templates/RemoteGate-Deployment.template.ps1` muss existieren |
| `yc nicht gefunden` | https://yandex.cloud/en/docs/cli/quickstart → `yc init` |
| `Bucket existiert nicht` | Wizard erstellt ihn; manuell: `yc storage bucket create --name <bucket>` |
| `403 Forbidden` beim Upload | Service Account braucht `storage.editor` → Folder IAM Binding hinzufügen |
| `Passwort enthält " oder $` | Wizard escapet automatisch für PowerShell String |
| `Windows PC kann Yandex URL nicht erreichen` | Prüfe ISP/ Firewall — Yandex Storage `storage.yandexcloud.net` Port 443 offen? Presigned URL gültig? |

## 10. Update / Neugenerierung

Wenn sich Yandex IP oder Passwort ändert:

```powershell
.\generator\New-RemoteGateDeployment.ps1  # liest last-generation.json als Default, nur Neues eingeben
# oder mit neuer Config-Datei und -NonInteractive
```

Neuen Final erneut hochladen (überschreibt Objekt), Windows erneut ausführen (idempotent).

Siehe auch `docs/INSTALLATION.md` und `docs/TROUBLESHOOTING.md`.
