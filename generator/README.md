# RemoteGate — Generator (Wizard) — Setup via Yandex

Dieser Generator setzt dein festes Passwort (`DEIN_PASSWORT` → dein echtes Passwort) und deine Yandex-Daten in das Beispiel-Template ein und erzeugt den **finalen, Yandex-gehosteten Installer**.

## Workflow (deine 8 Schritte)

1. **GitHub hat Installer + Beispiel:** `templates/RemoteGate-Deployment.template.ps1` (mit `DEIN_PASSWORT` Platzhalter) + `generator/New-RemoteGateDeployment.ps1` (Wizard) + `generator/Example-Install.ps1.example` (Beispiel)
2. **Repo herunterladen:** `git clone https://github.com/ki10-bot/My-SSH.git && cd My-SSH`
3. **Installer öffnen + Passwort setzen:** `.\generator\New-RemoteGateDeployment.ps1` → interaktive Prompts (festes Passwort)
4. **Yandex Account/API eingeben (wenn nötig):** VM IP, Bucket, optional Status Endpoint + HMAC
5. **Aus Beispiel + Eingaben → finaler Skript:** `dist/RemoteGate-Final.ps1` (mit echten Werten, kein Platzhalter mehr)
6. **Upload nach Yandex:** automatisch via `Upload-ToYandex.ps1` (yc oder aws cli), wenn möglich
7. **Yandex-Skript ist der ausgeführte:** Windows lädt von Yandex Object Storage, nicht GitHub
8. **Windows Installations-Kommando:** `irm https://storage.yandexcloud.net/<bucket>/RemoteGate-Final.ps1 | iex` (aus Yandex URL)

## Schnellstart

```powershell
# In PowerShell (oder pwsh auf Mac/Linux) im Repo-Root:
.\generator\New-RemoteGateDeployment.ps1

# Folgt Prompts:
# - Windows Benutzername [default]
# - Festes Passwort (verdeckt) + Bestätigung
# - Yandex VM IP (z.B. 51.250.12.34)
# - Bucket Name (z.B. my-remotegate-bucket)
# - Status Endpoint optional

# Output:
# - dist/RemoteGate-Final.ps1 (lokal, privat!)
# - dist/yandex-url.presigned.txt (falls privater Upload + presign)
# - Windows Installationskommando (Yandex URL, nicht GitHub)
```

## Ohne interaktiven Wizard (automation)

```powershell
# Vorher: JSON mit Werten erstellen (siehe generator/Example-Config.json.example)
.\generator\New-RemoteGateDeployment.ps1 -ConfigFile .\generator\my-config.json -NonInteractive -SkipUpload
```

## Upload manuell

```powershell
.\generator\Upload-ToYandex.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-bucket
# oder presigned (privat):
.\generator\Upload-ToYandex.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-bucket -PresignHours 24
# oder via yc direkt:
yc storage s3api put-object --bucket my-bucket --key RemoteGate-Final.ps1 --body dist/RemoteGate-Final.ps1
```

## Voraussetzungen für Auto-Upload

- Yandex Cloud Service Account mit `storage.editor` Rolle
- Schlüssel: `yc iam access-key create --service-account-name remotegate-storage`
- Authentifizierung: `yc init` (yc CLI) oder `aws configure` (mit YC keys) + endpoint `https://storage.yandexcloud.net`
- Bucket: `yc storage bucket create --name <bucket>` (oder Wizard erstellt ihn)

Siehe `docs/YANDEX-CLOUD-SETUP.md` für Account Creation und `cloud/infrastructure/` Terraform bucket.

## Sicherheit

- `dist/` ist in `.gitignore` — finaler Skript enthält Passwort in plain (für `net user`), darf nie zu GitHub!
- Bucket sollte **privat** (ACL private) sein; nutze presigned URLs für zeitlich begrenzten Zugang.
- Public bucket = jeder mit URL kann Passwort-Skript laden — nach Installation löschen oder privat stellen.
- Wizard zeigt Passwort-Stärke (≥12 Zeichen, Groß/Klein/Zahl/Sonder), warnt vor schwachen.
- Generator-Cache `generator/last-generation.json` speichert Passwort NICHT (nur Flag).

## Dateien

| Datei | Zweck |
|-------|-------|
| `generator/New-RemoteGateDeployment.ps1` | Wizard — interaktiv + templating |
| `generator/Upload-ToYandex.ps1` | Upload zu Object Storage (yc/aws) |
| `generator/Example-Install.ps1.example` | Beispiel wie Final aussieht (mit DEIN_PASSWORT) |
| `templates/RemoteGate-Deployment.template.ps1` | Template (Platzhalter DEIN_PASSWORT etc.) |
| `dist/RemoteGate-Final.ps1` | Generierter Final (lokal, nicht committen) |
| `docs/GENERATOR.md` | Vollständige Anleitung |

## Troubleshooting Wizard

- **Template nicht gefunden:** Prüfe Pfad `templates/RemoteGate-Deployment.template.ps1` existiert.
- **yc nicht gefunden:** Installiere https://yandex.cloud/en/docs/cli/quickstart, dann `yc init`.
- **Upload 403:** Service Account braucht `storage.editor` auf Bucket/Folder → `yc resource-manager folder add-access-binding --role storage.editor --subject serviceAccount:<id>`.
- **Passwort enthält `"` oder `$`:** Wizard escapet automatisch für PowerShell-String im Template.
