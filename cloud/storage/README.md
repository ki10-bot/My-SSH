# RemoteGate — Yandex Object Storage Bucket (for Windows Installer)

This Terraform creates the **private bucket** where the wizard uploads `RemoteGate-Final.ps1` (with your fixed password).

## Why?

Your fixed password (`DEIN_PASSWORT` → real password) is in the final script → it must be **private** on Yandex, not public GitHub. Object Storage provides:

- Private ACL (default) + presigned URLs for time-limited Windows download
- Public-read optional (wizard warns, needs explicit `-MakePublic`)

## Deploy

```bash
cd cloud/storage
cp ../infrastructure/terraform.tfvars.example terraform.tfvars
# Edit yc_cloud_id, yc_folder_id, bucket_name (globally unique!), make_public=false

terraform init
terraform plan
terraform apply
# Note access_key / secret_key outputs (sensitive)
terraform output bucket_url
terraform output access_key   # for aws configure or generator
```

Or reuse `cloud/infrastructure/` — add `yandex_storage_bucket` resource there if you already have infrastructure Terraform.

## Manual (Console / yc)

```bash
yc storage bucket create --name my-remotegate-bucket-uuid --default-storage-class standard
yc storage bucket update --name my-remotegate-bucket-uuid --acl private

# IAM for upload:
yc iam service-account create --name remotegate-storage
yc resource-manager folder add-access-binding --role storage.editor --subject serviceAccount:<id>
yc iam access-key create --service-account-name remotegate-storage
```

## Upload via Wizard

```powershell
.\generator\New-RemoteGateDeployment.ps1  # prompts for bucket, auto-uploads
# or manually:
.\generator\Upload-ToYandex.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-remotegate-bucket-uuid
```

## Windows download URLs

- Private (default): `https://storage.yandexcloud.net/<bucket>/RemoteGate-Final.ps1` → needs presigned: `aws s3 presign s3://<bucket>/RemoteGate-Final.ps1 --endpoint-url https://storage.yandexcloud.net --expires-in 604800`
- Public: same URL anonymously readable (only if ACL public-read)

Delete after install: `yc storage s3api delete-object --bucket <bucket> --key RemoteGate-Final.ps1`

## Security

- Never make bucket public unless you have deleted the password-script or accept risk.
- Wizard redacts password in logs; `.gitignore` prevents committing `dist/`.
- Rotate password by regenerating + re-uploading (overwrites object).
