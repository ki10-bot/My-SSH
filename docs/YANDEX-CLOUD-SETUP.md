# RemoteGate — Yandex Cloud Setup Guide

> You do NOT need an existing Yandex account. This guide covers account creation → VM → (optional) status endpoint.

## Overview

```
Mac --(SSH ProxyJump)--> Yandex VM:22 --(loopback 127.0.0.1:2222)--> Windows:22
Windows --(outbound SSH -R)--> Yandex VM
```

The VM is a **bastion** (jump host). Windows connects outbound to it; no inbound port forward to Windows is needed.

Status endpoint (optional) is a separate HTTPS API: `Windows --HTTPS+HMAC--> API Gateway --> Cloud Function`.

**Priority:** Get SSH working first. Status reporting is optional.

---

## 1. Yandex Cloud account setup

### 1.1 Create account

1. Go to https://console.yandex.cloud/ (Russia region) or https://console.yandex.kz/ (Kazakhstan region — single AZ, not recommended for primary).
2. **Sign in** with Yandex ID (create one if needed).
3. Create **Cloud** → **Folder** (e.g., `remotegate`).
   - Docs: https://yandex.cloud/en/docs/resource-manager/operations/cloud/create
   - See Section 2 below for region/zone choice and restrictions.

### 1.2 Billing

- Yandex Cloud requires **billing account** with payment method before creating VMs.
- Go to **Billing** → **Create billing account** → link bank card.
- Set **budget alert** to avoid surprises (e.g., 1000 RUB/month).
- Docs: https://yandex.cloud/en/docs/billing/concepts/billing-account

> Do NOT create paid resources until you approve cost (see Cost section below).

### 1.3 Install CLI (optional but recommended)

```bash
# macOS
brew install yandex-cloud-cli
# or download from https://yandex.cloud/en/docs/cli/quickstart

yc init  # follow prompts: choose cloud/folder/zone
yc iam create-token  # test auth
```

### 1.4 IAM roles

For manual console setup, your user needs:
- `compute.admin` or `compute.editor` (VMs)
- `vpc.admin` or `vpc.user` + `vpc.networks.list` (networks)
- For functions/gateway (optional): `serverless.functions.admin`, `serverless.apiGateway.admin`, `iam.serviceAccounts.user`

For Terraform, give the service account `compute.admin` + `storage.admin` + `serverless.*` as needed (see `cloud/infrastructure/README.md`).

Docs: https://yandex.cloud/en/docs/iam/concepts/access-control/roles

---

## 2. Regions, availability, and restrictions

Research before choosing a region/zone. This section documents current constraints (as of Nov 2025).

### 2.1 Regions

| Region | Zones | Notes |
|--------|-------|-------|
| **ru-central1** (Russia) | `ru-central1-a/b/d/e/m` | Primary. 5 AZs historically; after Oct 2026 incidents some zones degraded. Prefer `ru-central1-a` or `d` (check status board). |
| **kz1** (Kazakhstan) | `kz1-a` | Single AZ, limited capacity, not full parity. Use only if ru-central1 unavailable. |

**Source:** https://yandex.cloud/en/docs/overview/concepts/region

### 2.2 Service availability

- **Compute Cloud** (VMs): Available in all ru-central1 zones, limited in kz1.
- **Cloud Functions**: Available in ru-central1 (region-specific endpoint: `functions.yandexcloud.net`).
- **API Gateway**: Available in ru-central1.
- **Object Storage, Logging**: Cross-region replication differs; check per-service docs.

**Important:** Not every service is in every zone. Docs: verify at https://yandex.cloud/en/docs/

### 2.3 Network restrictions (Russia)

- **No VPN assumption:** This project uses only **outbound SSH (TCP 22)** and **HTTPS (443)** — both are ordinary ports. Do not assume VPN works (Russian ISPs throttle Cloudflare to ~16KB since June 2025 — see `SECURITY.md`).
- **DNS/HTTPS:** Yandex Cloud endpoints use standard HTTPS with CA verification (do NOT disable cert check).
- **ISP blocking:** Some ISPs may filter foreign CDNs, but Yandex Cloud domestic traffic is typically reachable. We do NOT promise 100% reachability from every ISP — document your ISP test in issues if blocked.
- **Sanctions:** Western tech export limits may affect new Yandex AZ provisioning (quotas at `ru-central1-f` noted in press). Prefer established zones.

### 2.4 Zone incidents (Oct–Nov 2026)

Press reports indicate drone strikes damaged Yandex DCs (ru-central1-b, etc.), with new zone `ru-central1-f` launched with quotas. For details see project `docs/SECURITY.md` and verify on Yandex Status: https://status.yandex.cloud/

**Recommendation:** Create VM in `ru-central1-a` or `ru-central1-d` (historically stable), with backup plan to recreate in another zone.

---

## 3. Bastion VM setup

### 3.1 Requirements

- **Image:** Ubuntu 22.04 LTS (recommended) from `standard-images` (`ubuntu-2204-lts`)
  - Why: Long-term support, cloud-init, smallest attack surface vs Windows on cloud
- **Size (cost-optimized):** 2 vCPU (20% burstable), 2 GB RAM, 20 GB network-hdd
  - Terraform default: `cores=2 memory=2 core_fraction=20` — ~ $5–12/mo non-preemptible
  - Preemptible: `preemptible=true` saves 50–70% but VM may be evicted (tunnel reconnects on restart)
- **Network:** VPC + subnet `10.10.0.0/24` in chosen zone, security group allowing TCP 22 inbound
  - **Do NOT open port 2222 publicly** — it's loopback only (`GatewayPorts no`)

### 3.2 Option A: Console (step-by-step)

1. In console, go to **Compute Cloud** → **Create VM**.
2. **Name:** `remotegate-bastion`, **Zone:** `ru-central1-a`.
3. **Image:** Boot disk → Marketplace → Search `Ubuntu 22.04 LTS` → `standard-images`, size 20 GB, `network-hdd`.
4. **Resources:** 2 vCPU, 2 GB, core fraction 20% (Intel Ice Lake or Cascade Lake).
5. **Network:** Select VPC `default` or create `remotegate-net` → subnet `remotegate-subnet-a` (`10.10.0.0/24`) → **Public IP: Auto** → Security groups: create `remotegate-sg-bastion`:
   - **Ingress:** `0.0.0.0/0` TCP 22 allow (restrict to your Mac IP `/32` in production)
   - **Egress:** `0.0.0.0/0` any allow
6. **Access:** Add SSH key → **Login:** `rgadmin` → **Key:** paste `~/.ssh/remotegate_mac_ed25519.pub` (from `mac/setup-keys.sh`).
7. Create. Wait for `Running`, note **Public IP**.

Or via CLI:

```bash
yc compute instance create \
  --name remotegate-bastion \
  --hostname remotegate-bastion \
  --zone ru-central1-a \
  --memory 2 --cores 2 --core-fraction 20 \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2204-lts,size=20,type=network-hdd \
  --network-interface subnet-name=default-ru-central1-a,nat-ip-version=ipv4 \
  --ssh-key ~/.ssh/remotegate_mac.pub \
  --preemptible=false
```

### 3.3 Option B: Terraform

See `cloud/infrastructure/`:

```bash
cd cloud/infrastructure
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
export YC_TOKEN=$(yc iam create-token)
terraform init && terraform apply
terraform output bastion_public_ip
```

### 3.4 VM Hardening

SSH into new VM:

```bash
ssh rgadmin@<VM_PUBLIC_IP>
sudo bash /path/to/cloud/vm/setup.sh  # or cloud-init handles it
```

What `setup.sh` does (see `cloud/vm/setup.sh` for full script):
- `apt update && upgrade`, install `fail2ban`, `ufw`
- Harden `sshd_config`: `PasswordAuthentication no`, `PermitRootLogin no`, `GatewayPorts no`, `AllowTcpForwarding yes`
- Create `tunneluser` (`/usr/sbin/nologin`, no shell) with `Match User tunneluser { ForceCommand /bin/false, PermitTTY no }`
- `ufw` deny incoming (except 22), fail2ban for brute-force
- Unattended security upgrades + banner

**Post-setup:**
1. Paste Windows tunnel public key:
   ```bash
   # On Windows:
   cat C:\ProgramData\RemoteGate\keys\tunnel_ed25519.pub
   # On VM:
   sudo -u tunneluser nano /home/tunneluser/.ssh/authorized_keys
   # Optionally restrict per-key:
   # no-pty,no-agent-forwarding,no-X11-forwarding,permitopen="127.0.0.1:22" ssh-ed25519 AAA...
   sudo chmod 600 /home/tunneluser/.ssh/authorized_keys
   sudo chown tunneluser:tunneluser /home/tunneluser/.ssh/authorized_keys
   ```
2. Test Windows → VM (from Windows admin PowerShell, once to accept host key):
   ```powershell
   ssh-keyscan -p 22 <VM_IP> >> C:\ProgramData\RemoteGate\config\ssh\known_hosts
   ssh -i C:\ProgramData\RemoteGate\keys\tunnel_ed25519 -p 22 tunneluser@<VM_IP>
   # Should immediately disconnect (ForceCommand /bin/false) — that means auth worked
   ```
3. Verify loopback binding after tunnel starts:
   ```bash
   # On VM after Windows tunnel connects:
   ss -tlnp | grep 2222  # expect 127.0.0.1:2222, NOT 0.0.0.0:2222
   ```

---

## 4. Status endpoint (optional)

> Skip this section if you only need SSH. Status is NOT required for tunnel functionality.

### 4.1 Why HMAC?

We use **HMAC-SHA256** (shared secret) instead of IAM tokens for device → cloud because:
- No token expiry to manage on device (IAM tokens expire in 12h)
- Works without VM metadata service
- Secret stays on device (file/ENV) and in function env, not in repo

Replay protection: `timestamp` (±5 min) + `nonce` (logged, deduplicate via YDB in production).

### 4.2 Create Cloud Function

**Console:**

1. **Cloud Functions** → **Create function** → Name `remotegate-status` → Runtime `nodejs20` → Entrypoint `index.handler` → Memory 128 MB, Timeout 10s.
2. Upload `cloud/functions/index.js` (or zip: `zip -j function.zip cloud/functions/index.js`).
3. **Service account:** Create `remotegate-func-sa` with role `logging.writer` (to write logs).
4. **Environment variables:**
   - `HMAC_SECRET` = random 32+ char string (e.g., `openssl rand -base64 32`)
   - `ALLOWED_DEVICE_IDS` = comma-separated device IDs (or empty)
5. **Invocation:** Private (require IAM/API Gateway) — do NOT make public without HMAC check (function checks HMAC itself, but keep IAM layer too).

**CLI:**

```bash
yc serverless function create --name remotegate-status

yc serverless function version create \
  --function-name remotegate-status \
  --runtime nodejs20 --entrypoint index.handler --memory 128m --execution-timeout 10s \
  --source-path ./cloud/functions/function.zip \
  --service-account-id <SA_ID> \
  --environment HMAC_SECRET="<secret>",ALLOWED_DEVICE_IDS=""

yc serverless function get remotegate-status  # note function ID
```

### 4.3 Create API Gateway

Upload `cloud/gateway/spec.yaml` after replacing placeholders:

```bash
# Get function ID
FUNC_ID=$(yc serverless function get remotegate-status --format json | jq -r .id)
SA_ID=$(yc iam service-account get remotegate-func-sa --format json | jq -r .id)

# Replace in spec
sed -e "s/REPLACE_WITH_FUNCTION_ID/$FUNC_ID/" \
    -e "s/REPLACE_WITH_SERVICE_ACCOUNT_ID/$SA_ID/" \
    cloud/gateway/spec.yaml > /tmp/spec.yaml

yc serverless api-gateway create \
  --name remotegate-gateway \
  --spec=/tmp/spec.yaml

yc serverless api-gateway get remotegate-gateway --format json | jq -r .domain
# => d5d...apigw.yandexcloud.net

# Status endpoint:
# https://<domain>/status  (POST, HMAC headers)
# https://<domain>/health  (GET, no auth)
```

### 4.4 Configure Windows device

Set HMAC secret on Windows (pick one, first is recommended):

```powershell
# Option A: Environment variable (per-machine, for SYSTEM task — requires reboot or task restart)
[Environment]::SetEnvironmentVariable("REMOTEGATE_HMAC_SECRET", "your-secret-here", "Machine")
# Verify: [Environment]::GetEnvironmentVariable("REMOTEGATE_HMAC_SECRET","Machine")

# Option B: File (ACL restricted, SYSTEM-readable)
$secret = "your-secret-here"
Set-Content -Path C:\ProgramData\RemoteGate\config\hmac-secret.txt -Value $secret -NoNewline
# Harden ACL:
$acl = Get-Acl C:\ProgramData\RemoteGate\config\hmac-secret.txt
$acl.SetAccessRuleProtection($true,$false)
$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")))
$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM","FullControl","Allow")))
Set-Acl C:\ProgramData\RemoteGate\config\hmac-secret.txt $acl
```

Edit `C:\ProgramData\RemoteGate\config\config.json`:

```json
{
  "yandex": {
    "statusEndpoint": "https://d5d...apigw.yandexcloud.net/status",
    "statusEnabled": true
  },
  "statusReporting": {
    "enabled": true,
    "intervalMinutes": 5
  }
}
```

Test:

```powershell
C:\ProgramData\RemoteGate\bin\RemoteGate-Status.ps1 -DryRun   # no send
C:\ProgramData\RemoteGate\bin\RemoteGate-Status.ps1          # send
Get-Content C:\ProgramData\RemoteGate\logs\status.log -Tail 20
# or check function logs:
# yc serverless function logs remotegate-status --since 10m
```

Set up scheduled status reporter (optional — runs every 5 min):

```powershell
$action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\RemoteGate\bin\RemoteGate-Status.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName RemoteGate-Status -TaskPath \RemoteGate\ -Action $action -Trigger $trigger -Principal $principal -Description "RemoteGate status reporter"
```

---

## 5. Object Storage Bucket (for Yandex-hosted Windows Installer — NEW)

For the new wizard flow (fixed password → Yandex URL → Windows), you need a **private Object Storage bucket** to host `RemoteGate-Final.ps1` (contains your password, so keep private!).

**Via Console (quick):**
```bash
yc storage bucket create --name my-remotegate-bucket-uuid --default-storage-class standard
# Make private (default): yc storage bucket update --name my-remotegate-bucket-uuid --acl private
# IAM for wizard upload:
yc iam service-account create --name remotegate-storage
yc resource-manager folder add-access-binding --role storage.editor --subject serviceAccount:<id> --id <folder-id>
yc iam access-key create --service-account-name remotegate-storage
# Use keys in `aws configure` or `yc` (wizard's Upload-ToYandex.ps1 uses them)
```

**Via Terraform:**
```bash
cd cloud/storage
terraform init && terraform apply -var="bucket_name=my-remotegate-bucket-uuid"
terraform output bucket_url  # https://storage.yandexcloud.net/.../RemoteGate-Final.ps1
```

**Upload:** Wizard does it automatically (`.\generator\New-RemoteGateDeployment.ps1` → Step 4), or manually:
```powershell
.\generator\Upload-ToYandex.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket my-remotegate-bucket-uuid
# Private → generate presigned URL:
aws s3 presign s3://my-remotegate-bucket-uuid/RemoteGate-Final.ps1 --endpoint-url https://storage.yandexcloud.net --expires-in 604800
```

Details: `docs/GENERATOR.md` and `cloud/storage/README.md`. Delete after install: `yc storage s3api delete-object --bucket <bucket> --key RemoteGate-Final.ps1`.

## 6. Cost considerations

| Resource | Approx. monthly cost (ru-central1, 2025) | Notes |
|----------|------------------------------------------|-------|
| VM 2vCPU/2GB/20GB HDD, 20% | $5–12 | Non-preemptible |
| VM preemptible | $2–5 | May be evicted, tunnel reconnects |
| Cloud Function | Free tier 100k invocations, then ~ $0.10/100k | Status every 5 min = ~8.6k/mo |
| API Gateway | Free tier generous |  |
| Object Storage (installer) | ~ $0.01/mo for one script + requests | Bucket itself free, minimal storage/requests |
| Egress (outbound SSH) | Minimal for shell sessions | Bulk transfers cost more |
| Static public IP | Included with VM while attached | |

**Budget:** Set Yandex billing budget alert at 500–1000 RUB.

Docs: https://yandex.cloud/en/docs/billing/concepts/budget

---

## 7. Resource cleanup

### Console

1. **Compute Cloud** → VM → **Delete** (releases public IP).
2. **Object Storage** → Buckets → Delete `my-remotegate-bucket` (or remove object `RemoteGate-Final.ps1` if bucket shared).
3. **VPC** → Network → Delete (if created for project).
4. **Cloud Functions** → Function → Delete.
5. **API Gateway** → Gateway → Delete.
6. **IAM** → Service accounts → Delete `remotegate-*`.
7. **Billing** → Budgets → Keep or delete.

### Terraform

```bash
cd cloud/infrastructure
terraform destroy
```

### Billing stays

Yandex Cloud keeps billing account; delete it manually if you want to stop all charges.

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Permission denied (publickey)` VM | Wrong key in `authorized_keys` | Check `~/.ssh/authorized_keys` perms `600`, owner correct |
| `Connection timed out` to VM | Security group blocks 22 | Check VPC security group ingress 22 |
| `Host key verification failed` from Windows | `known_hosts` missing | `ssh-keyscan -p 22 VM_IP >> ...\known_hosts` |
| Function 500 | `HMAC_SECRET` not set | Check function env vars |
| Gateway 429 | Rate limited (10 rps) | Status is 1 req/5 min — should not hit |

See also `docs/TROUBLESHOOTING.md` and `cloud/vm/README.md`.

---

## 8. Security checklist (VM side)

- [ ] `PasswordAuthentication no` in `sshd_config`
- [ ] `tunneluser` is `nologin` + `ForceCommand /bin/false`
- [ ] `GatewayPorts no` (loopback only)
- [ ] UFW `deny incoming` except 22
- [ ] fail2ban enabled
- [ ] Unattended upgrades on
- [ ] Only your IP(s) in security group ingress (not `0.0.0.0/0` long-term)
- [ ] `AllowUsers` restricts to `tunneluser` + your admin (optional hardening)
- [ ] HMAC secret not in repo, rotated periodically

See `docs/SECURITY.md` for full threat model.
