# RemoteGate — Cloud.ru Object Storage Bucket (for Windows Installer)

> **Primary: Cloud.ru Evolution Object Storage (S3, https://s3.cloud.ru) — Free Tier 15 GB gratis**
> Yandex Storage (`https://storage.yandexcloud.net`) bleibt als Alternative unterstützt, ist aber nicht mehr Default.

This Terraform creates the **private bucket** where the wizard uploads `RemoteGate-Final.ps1` (with your fixed password).

## Why?

Your fixed password (`DEIN_PASSWORT` → real password) is in the final script → it must be **private** on Cloud.ru, not public GitHub. Object Storage provides:

- Private ACL (default) + presigned URLs for time-limited Windows download
- Public-read optional (wizard warns, needs explicit `-MakePublic`)
- Free Tier: first 15 GB, 100k PUT, 1M GET gratis — your 40KB script is free.

## Cloud.ru vs Yandex

| | Cloud.ru | Yandex |
|---|---|---|
| Endpoint | `https://s3.cloud.ru` | `https://storage.yandexcloud.net` |
| Free Tier | 15 GB S3 + VM free | Nur Trial 60 Tage |
| Bucket Console | Console → Haltung → Object Storage | Console → Object Storage |
| Preis IP | 146 ₽/Mo fix | variabel $5-15 |
| Docs | https://cloud.ru/docs/s3e/ug/topics/quickstart | https://yandex.cloud/en/docs/storage/ |

## Deploy — Cloud.ru (default)

### Via Console (einfach)

1. console.cloud.ru → Projekt → Haltung → Object Storage → **Bucket erstellen**
2. Name `my-remotegate-bucket-xyz123` (global unique) → Klasse **Standard** → **Privat** → Erstellen.

### Via AWS CLI (S3 API)

```bash
# Keys: Console → IAM → Service Account → Zugriffsschlüssel
aws configure  # Access/Secret, region ru-moscow-1 (oder leer), endpoint https://s3.cloud.ru

aws s3 mb s3://my-remotegate-bucket-xyz123 --endpoint-url https://s3.cloud.ru
aws s3 cp dist/RemoteGate-Final.ps1 s3://my-remotegate-bucket-xyz123/RemoteGate-Final.ps1 --endpoint-url https://s3.cloud.ru

# Presigned (privat):
aws s3 presign s3://my-remotegate-bucket-xyz123/RemoteGate-Final.ps1 --endpoint-url https://s3.cloud.ru --expires-in 604800
```

### Via Terraform (Cloud.ru)

```bash
cd cloud/storage
terraform init
terraform plan -var="bucket_name=my-remotegate-bucket-xyz123"
terraform apply
# Output: bucket_url, s3_endpoint
```

Or reuse `cloud/infrastructure/` — see its Terraform for combined VM+Bucket.

## Deploy — Yandex (alternative)

```bash
yc storage bucket create --name my-yandex-bucket --default-storage-class standard
yc iam service-account create --name remotegate-storage
yc resource-manager folder add-access-binding --role storage.editor --subject serviceAccount:<id>
yc iam access-key create --service-account-name remotegate-storage
```

## Upload via Wizard

```powershell
.\generator\New-RemoteGateDeployment.ps1  # prompts for bucket, auto-uploads to Cloud.ru (default)
# or manually:
.\generator\Upload-ToCloud.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-bucket -Endpoint s3.cloud.ru
.\generator\Upload-ToYandex.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-bucket  # legacy Yandex
```

## Windows download URLs

- **Cloud.ru Private (default):** `https://my-bucket.s3.cloud.ru/RemoteGate-Final.ps1` → needs presigned:
  `aws s3 presign s3://my-bucket/RemoteGate-Final.ps1 --endpoint-url https://s3.cloud.ru --expires-in 604800`
- **Cloud.ru Public:** same URL anonymously readable (only if ACL public-read)
- **Yandex Private:** `https://storage.yandexcloud.net/<bucket>/RemoteGate-Final.ps1` → presign via Yandex endpoint.

Delete after install: `aws s3 rm s3://<bucket>/RemoteGate-Final.ps1 --endpoint-url https://s3.cloud.ru`

## Security

- Never make bucket public unless you have deleted the password-script or accept risk.
- Wizard redacts password in logs; `.gitignore` prevents committing `dist/`.
- Rotate password by regenerating + re-uploading (overwrites object).
