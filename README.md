# RemoteGate — Secure Windows Remote Administration via Yandex Cloud

> **Owner's setup:** MacBook (macOS, SSH via Terminal) controls one owned Windows 10 PC via SSH through a Yandex Cloud bastion. No VPN required.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#license)
[![Windows](https://img.shields.io/badge/Windows-10%201809%2B-blue)](#requirements)
[![Yandex Cloud](https://img.shields.io/badge/Yandex-Cloud-red)](#yandex-cloud-setup)

## What RemoteGate is

RemoteGate installs **official Windows OpenSSH Server**, hardens it (keys only, no passwords), restricts the firewall to your local network, and creates a **persistent outbound reverse SSH tunnel** to a Yandex Cloud VM (bastion). You connect from your Mac with a single `ssh -J` command. An optional authenticated HTTPS status endpoint lets the PC report health to Yandex.

## What it does

- Installs OpenSSH Server via Windows Capabilities
- Configures `sshd` (Automatic startup, `PasswordAuthentication no`, PowerShell as default shell)
- Restricts firewall (`OpenSSH-Server-In-TCP` → `LocalSubnet`, no public 22)
- Generates a **dedicated** tunnel key (ED25519) + device ID
- Creates a **visible** Scheduled Task (`\RemoteGate\RemoteGate-Tunnel`) that keeps the tunnel alive with keepalives and exponential backoff
- Verifies installation and logs everything
- (Optional) Reports status via HMAC-SHA256 + timestamp + nonce to a Yandex Cloud Function / API Gateway

## What it does NOT do

- No mass fleet / MDM
- No hidden persistence (task is documented, removable)
- No disabling of Windows Defender, UAC, or PowerShell protections
- No exposure of Windows port 22 to the public Internet
- No VPN, no Discord/Telegram/ntfy, no unauthenticated public topics
- No password `DEIN_PASSWORT` hardcoded (it's a placeholder, see `docs/SECURITY.md`)

## Architecture

```
                    SSH + Private Key (Mac → Windows)
MacBook ──────────────────────────────────────────────┐
   │  ssh -J cloud@YANDEX_VM -p 2222 user@127.0.0.1    │
   │                                                  ▼
   │          Yandex Cloud VM (Bastion, Ubuntu)   127.0.0.1:2222
   │          ┌────────────────────────────────────────┘
   │          │  Reverse tunnel (outbound from Windows)
   │          │  ssh -N -R 127.0.0.1:2222:127.0.0.1:22  tunneluser@VM
   │          ▼
   └─────► Windows 10 (OpenSSH Server :22, firewall LocalSubnet)
```

```
Windows ──HTTPS+HMAC──► API Gateway ──► Cloud Function ──► Logs/Storage
         (DeviceId, Timestamp, Nonce, Signature)    (optional)
```

- Reverse tunnel binds **only** `127.0.0.1:2222` on VM (`GatewayPorts no`).
- Mac uses `ProxyJump` (`-J`) → VM → loopback port.
- Status endpoint is **optional** — SSH works without it.

## Requirements

| Component | Requirement |
|-----------|-------------|
| Windows | 10 build 1809 (17763)+; 10 reached EOL 2025-10-14 — see `docs/WINDOWS10-EOL.md` (Windows 11 / supported Server recommended for production) |
| PowerShell | 5.1+ (for install), 7 optional as remote shell |
| Admin | Local Administrator approval (UAC) |
| Cloud | Yandex Cloud account (or SSH-only local mode with `-SkipCloudConfig`) |
| Mac | macOS with OpenSSH 7.3+ (all modern Macs) |
| Network | Outbound SSH (22) + HTTPS (443) to Yandex — no inbound firewall holes needed on Windows |

## Repository structure

```
RemoteGate/
├── README.md                     # This file
├── LICENSE (MIT)
├── .gitignore
├── installer/
│   ├── Bootstrap.ps1             # Secure downloader (SHA256 verify)
│   ├── Install-RemoteGate.ps1    # Main installer (idempotent)
│   ├── Configure-SSH.ps1
│   ├── Configure-Firewall.ps1
│   ├── Configure-Tunnel.ps1
│   ├── Verify-Installation.ps1
│   └── Uninstall-RemoteGate.ps1
├── windows/
│   ├── RemoteGate-Agent.ps1      # Health check / auto-repair
│   ├── RemoteGate-Tunnel.ps1     # Persistent tunnel manager
│   └── RemoteGate-Status.ps1     # HMAC status reporter
├── generator/                  # ⭐ NEW: Wizard for fixed password + Yandex upload
│   ├── New-RemoteGateDeployment.ps1  # Interactive wizard (DEIN_PASSWORT → dein PW)
│   ├── Upload-ToYandex.ps1           # S3 upload to Object Storage (yc/aws)
│   ├── Example-Install.ps1.example   # Example (DEIN_PASSWORT Platzhalter)
│   ├── Example-Config.json.example   # Prefill für -NonInteractive
│   └── README.md
├── templates/
│   └── RemoteGate-Deployment.template.ps1  # FINAL template (Platzhalter DEIN_PASSWORT etc.)
├── dist/                         # Generierter FINAL (privat, nicht committen! .gitignore)
│   └── RemoteGate-Final.ps1      # Aus Yandex herunterladen, nicht GitHub
├── cloud/
│   ├── vm/setup.sh               # VM hardening script
│   ├── vm/cloud-init.yaml
│   ├── functions/index.js        # HMAC status endpoint
│   ├── gateway/spec.yaml         # OpenAPI 3.0 + Yandex extension
│   ├── storage/                  # ⭐ NEW: Object Storage bucket (für Yandex Installer)
│   └── infrastructure/           # Terraform (VPC, VM, Function, Gateway)
├── mac/
│   ├── setup-keys.sh             # Generates Mac→Windows key
│   ├── connect.sh                # ProxyJump helper
│   └── ssh-config.example        # ~/.ssh/config snippet
├── config/config.example.json
├── docs/
│   ├── GENERATOR.md              # ⭐ NEW: Wizard & Yandex Upload Guide (deine 8 Schritte)
│   ├── INSTALLATION.md           # Installation (GitHub vs Yandex)
│   ├── YANDEX-CLOUD-SETUP.md     # Account/VM/Function/Gateway + regions/restrictions
│   ├── MAC-CONNECTION.md         # ssh -J guide + host keys
│   ├── SECURITY.md               # Threat model, threat table, audit checklist
│   ├── TROUBLESHOOTING.md
│   ├── UNINSTALLATION.md
│   └── WINDOWS10-EOL.md
└── tests/
    ├── powershell/               # Pester mocked unit tests
    ├── cloud/function.test.js    # Node HMAC tests
    └── integration/TEST-PLAN.md  # 15-test checklist
```

## Installation — zwei Wege (neu: mit festem Passwort & Yandex Hosting)

> **Empfohlen (deine 8 Schritte):** Wizard → festes Passwort (`DEIN_PASSWORT` → dein PW) → Upload nach Yandex Object Storage → Windows lädt aus Yandex (privat, kein GitHub).
> **Alternativ (klassisch):** Direkt aus GitHub (nur Keys, `DEIN_PASSWORT` Platzhalter, manuelle `config.json`).
> Full guides: `docs/GENERATOR.md` (Wizard) + `docs/INSTALLATION.md` (klassisch) + `docs/YANDEX-CLOUD-SETUP.md`.

### Weg A — ⭐ Empfohlen: Mit festem Passwort & Yandex Upload (dein Wunsch)

**1. Repo herunterladen + Wizard starten (auf Admin-PC, wo du Repo hast):**

```powershell
git clone https://github.com/ki10-bot/My-SSH.git
cd My-SSH
.\generator\New-RemoteGateDeployment.ps1
# Folgt Prompts:
# - Windows Benutzername (DEIN_BENUTZER → dein User)
# - Festes Passwort (DEIN_PASSWORT → dein sicheres PW, verdeckt + Bestätigung)
# - Yandex VM IP (DEIN_YANDEX_VM_IP → 51.250.12.34)
# - Bucket Name (DEIN_BUCKET → my-remotegate-bucket)
# → Generiert: dist/RemoteGate-Final.ps1 (privat, nicht committen!)
# → Auto-Upload zu Yandex Object Storage (wenn yc konfiguriert)
# → Gibt Windows Installations-Kommando (Yandex URL) aus
```

Wizard Schritte: `docs/GENERATOR.md` (inkl. Passwort-Stärke ≥12 Zeichen, Upload via yc/aws, presigned URLs für privaten Bucket).

**2. Yandex VM (einmalig) — vorher oder nachher:**

```bash
# Nach yc init:
yc compute instance create --name remotegate-bastion --zone ru-central1-a \
  --memory 2 --cores 2 --core-fraction 20 \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2204-lts,size=20,type=network-hdd \
  --network-interface subnet-name=default-ru-central1-a,nat-ip-version=ipv4 \
  --ssh-key ~/.ssh/remotegate_mac.pub
# Dann auf VM: sudo bash cloud/vm/setup.sh
# Bucket für Windows Installer (falls nicht via Wizard):
cd cloud/storage && terraform init && terraform apply -var="bucket_name=my-remotegate-bucket"
```

**3. Auf Windows (als Administrator) — aus Yandex (nicht GitHub!):**

```powershell
# Vom Wizard ausgegebenes Kommando (Yandex URL, nicht GitHub raw):
$url="https://storage.yandexcloud.net/my-remotegate-bucket/RemoteGate-Final.ps1"
# Falls privat: nutze presigned URL vom Wizard (gültig 7 Tage):
# $url="https://storage.yandexcloud.net/...?X-Amz-Signature=..."

Invoke-WebRequest -Uri $url -OutFile $env:TEMP\RemoteGate-Final.ps1
# Optional: Hash prüfen
Get-FileHash $env:TEMP\RemoteGate-Final.ps1 -Algorithm SHA256
& $env:TEMP\RemoteGate-Final.ps1

# Der finale Skript (templates/RemoteGate-Deployment.template.ps1 mit deinen Werten):
# - Prüft Windows Build, Admin
# - Setzt festes Passwort (wenn gesetzt) → PasswordAuthentication yes + net user
# - Schreibt config.json (Yandex IP etc. — kein manuelles Edit nötig)
# - Installiert OpenSSH, Firewall LocalSubnet, Tunnel Key + Task
# - Startet Tunnel automatisch
```

Verifizieren:

```powershell
Get-Content C:\ProgramData\RemoteGate\logs\tunnel.log -Tail 20
Get-Service sshd; Get-ScheduledTask -TaskName RemoteGate-Tunnel -TaskPath \RemoteGate\
# Passwort-Login testen: ssh johndoe@<WINDOWS_LAN_IP>  → dein festes PW
# Oder: ssh -J rgadmin@<VM_IP> -p 2222 johndoe@127.0.0.1
```

### Weg B — Klassisch: Direkt aus GitHub (nur Keys, manuelle config.json)

Open **PowerShell as Administrator** (Win+X → Terminal (Admin) → Yes on UAC):

```powershell
# Secure downloader — pinned release + SHA256 (replace hash from Releases page)
irm https://raw.githubusercontent.com/ki10-bot/My-SSH/v0.1.0/installer/Bootstrap.ps1 -OutFile $env:TEMP\Bootstrap.ps1
# Verify:
Get-FileHash $env:TEMP\Bootstrap.ps1 -Algorithm SHA256
& $env:TEMP\Bootstrap.ps1 -ReleaseTag v0.1.0 -ExpectedSha256 "REPLACE_WITH_RELEASE_SHA256"

# Development (no pin — no checksum, not for production):
iex (irm https://raw.githubusercontent.com/ki10-bot/My-SSH/main/installer/Bootstrap.ps1)
```

Der klassische Installer ist **idempotent**, manuelle `config.json` nötig:

```powershell
notepad C:\ProgramData\RemoteGate\config\config.json
# Set yandex.vmPublicIp, yandex.vmUser, ssh.windowsUser
cat C:\ProgramData\RemoteGate\keys\tunnel_ed25519.pub
# Paste to Yandex VM: /home/tunneluser/.ssh/authorized_keys
ssh-keyscan -p 22 <VM_IP> >> C:\ProgramData\RemoteGate\config\ssh\known_hosts
Start-ScheduledTask -TaskName RemoteGate-Tunnel -TaskPath \RemoteGate\
```

### 3. Connect from Mac

See `docs/MAC-CONNECTION.md`.

```bash
# Keys (one-time):
bash mac/setup-keys.sh  # generates ~/.ssh/remotegate_mac_ed25519
# Paste .pub to Windows administrators_authorized_keys (if admin) or ~/.ssh/authorized_keys

# Config (~/.ssh/config from mac/ssh-config.example):
#   Host remotegate-bastion  HostName <VM_IP>  User rgadmin
#   Host remotegate-windows  ProxyJump remotegate-bastion  Port 2222 ...

# Connect:
bash mac/connect.sh -b <VM_IP> -u <WINDOWS_USER>
# or:
ssh remotegate-windows
# or raw:
ssh -J rgadmin@<VM_IP> -i ~/.ssh/remotegate_mac_ed25519 -p 2222 <WINDOWS_USER>@127.0.0.1
```

The Mac uses its own private key; the Windows tunnel key stays on Windows.

## Security model

- **Keys:** Two ED25519 identities, never reused. See `docs/SECURITY.md`.
- **SSH:** `PasswordAuthentication no`, host key verification always on, `AllowTcpForwarding yes` + `GatewayPorts no`.
- **Firewall:** `LocalSubnet` only; no public 22.
- **Tunnel:** `127.0.0.1:2222` loopback, `tunneluser` `nologin` + `ForceCommand /bin/false`, keepalives + auto-reconnect, duplicate prevention (mutex).
- **Status:** HTTPS + `HMAC-SHA256(timestamp.nonce.deviceId.payloadHash)`, replay window 5 min, rate limit 10 rps, minimal PII, can be disabled.
- **No secrets in repo:** `.gitignore` covers `*.key`, `hmac-secret.txt`, `terraform.tfvars`.
- See `docs/SECURITY.md` for threat table and audit checklist.

## Testing

See `tests/integration/TEST-PLAN.md` (15 tests).

```powershell
# Mocked unit tests (no hardware needed — run on any runner with Pester):
Install-Module Pester -Force
Invoke-Pester tests/powershell -Output Detailed

# Cloud function tests (Node 18+):
npm install --prefix cloud/functions 2>&1 | Out-Null
node --test tests/cloud/function.test.js
```

Integration tests (1–15) require real Windows + Yandex account — marked `requires owner action`.

## Known limitations

- **Single device v1:** Designed for one Windows PC. Multi-device needs distinct `reverseTunnelPort` per host (2223, 2224...) — not implemented.
- **Windows 10 EOL:** Build 1809+ works, but Home/Pro without ESU gets no patches post-2025-10-14 — see `docs/WINDOWS10-EOL.md`.
- **Yandex VM required for remote access:** LAN SSH works without cloud (`-SkipCloudConfig`), but Internet remote needs the bastion.
- **Status endpoint nonce dedup:** Logged, but full YDB/Redis dedup is a TODO for production (documented in `cloud/functions/index.js`).
- **Preemptible VMs:** Cheaper but may evict — tunnel reconnects on restart.

## Uninstallation

```powershell
.\installer\Uninstall-RemoteGate.ps1          # removes task + data
.\installer\Uninstall-RemoteGate.ps1 -KeepKeys # keeps keys for reinstall
.\installer\Uninstall-RemoteGate.ps1 -RemoveOpenSSH # also removes capability
```

Full cleanup (VM, keys, gateway): `docs/UNINSTALLATION.md`.

## FAQ

**Q: What about `DEIN_PASSWORT`?**
A: Literal placeholder meaning “your password” (German). Never used as credential. Keep `PasswordAuthentication no`.

**Q: Can I use RDP instead?**
A: Yes for GUI, but RemoteGate is SSH-shell focused. Compare in `docs/SECURITY.md`.

**Q: Does this work through restrictive ISPs?**
A: It uses ordinary outbound SSH (22) + HTTPS (443). Some Russian ISPs throttle Cloudflare, but Yandex domestic endpoints are typically reachable. We don't guarantee every ISP — test and file issues if blocked.

**Q: Cost?**
A: Minimal VM ~$5–12/mo (non-preemptible) + function/gateway mostly free tier. See `docs/YANDEX-CLOUD-SETUP.md`.

## License

MIT — see `LICENSE`.

## Contributing / Issues

- Check `docs/TROUBLESHOOTING.md` first.
- Do NOT paste private keys or HMAC secrets in issues.
- After manual test runs, update `tests/integration/TEST-PLAN.md` with results.

---

**Maintained at:** https://github.com/ki10-bot/My-SSH
