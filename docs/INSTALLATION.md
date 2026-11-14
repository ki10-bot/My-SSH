# RemoteGate — Installation Guide — Zwei Wege

> **Weg A (empfohlen, deine 8 Schritte):** Wizard → festes Passwort (DEIN_PASSWORT) → Cloud.ru (Free Tier) Upload → Windows lädt aus Cloud.ru (siehe `docs/GENERATOR.md` + `docs/CLOUDRU-VM-GUIDE.md`).
> **Weg B (klassisch):** GitHub → Windows (key-only, manuelle config.json) — hier beschrieben.
> **Weg C (Legacy):** Yandex Cloud statt Cloud.ru — siehe `docs/YANDEX-VM-GUIDE.md`.
>
> Alle Wege installieren identische Windows-Komponenten — nur die Quelle (Cloud.ru vs Yandex vs GitHub) unterscheidet sich.

## Weg A — Wizard + Cloud.ru Free Tier (empfohlen)

Siehe `docs/GENERATOR.md` + `docs/CLOUDRU-VM-GUIDE.md` — komplett (Repo → Wizard → Passwort → Cloud.ru Bucket → Windows aus Cloud.ru).

> **Cloud.ru Free Tier:** VM 2vCPU/4GB/30GB + 15GB S3 gratis, nur Public IP ~146 ₽/Mo. Siehe [CLOUDRU-VM-GUIDE.md](CLOUDRU-VM-GUIDE.md). Yandex bleibt als Option [2] im Wizard.

Kurz:
```powershell
git clone https://github.com/ki10-bot/My-SSH.git; cd My-SSH
.\generator\New-RemoteGateDeployment.ps1  # [1] Cloud.ru wählen → Passwort + Cloud.ru IP/Bucket → dist/RemoteGate-Final.ps1 → auto Upload
# Windows (aus Cloud.ru, nicht GitHub, privat):
$url="https://<bucket>.s3.cloud.ru/RemoteGate-Final.ps1"; iwr $url -OutFile $env:TEMP\RemoteGate-Final.ps1; & $env:TEMP\RemoteGate-Final.ps1
# Yandex Alternative: $url="https://storage.yandexcloud.net/<bucket>/RemoteGate-Final.ps1"
```

Vorteil: Kein manuelles `config.json`, Passwort vor-konfiguriert, Quelle Cloud.ru privat (Free Tier 15 GB gratis).

## Weg B — Klassisch: Direkt aus GitHub (hier detailliert)

> For a technically interested beginner. Every command is explained.

## What you need

- **Windows 10 computer** you own, with Administrator account
- **PowerShell 5.1+** (preinstalled on Windows 10)
- **Internet** access to `github.com` (HTTPS) and your Yandex VM (outbound SSH)
- **Yandex VM** created first (see `docs/YANDEX-CLOUD-SETUP.md`) — or install SSH-only and configure VM later

## Quick start (one command, klassisch)

1. On Windows, open **PowerShell as Administrator**:
   - Press `Win + X` → **Windows PowerShell (Admin)** / **Terminal (Admin)**
   - Click **Yes** on UAC prompt (do NOT bypass UAC)

2. Run the bootstrap (secure downloader):

```powershell
# Option A: Pinned release (recommended — verify SHA256)
# Replace v0.1.0 and SHA with your published release
$ReleaseTag = "v0.1.0"
irm https://raw.githubusercontent.com/ki10-bot/My-SSH/$ReleaseTag/installer/Bootstrap.ps1 -OutFile $env:TEMP\Bootstrap.ps1
# (Optional) verify hash manually:
Get-FileHash $env:TEMP\Bootstrap.ps1 -Algorithm SHA256
# Check it matches the hash on the GitHub Releases page
& $env:TEMP\Bootstrap.ps1 -ReleaseTag $ReleaseTag -ExpectedSha256 "REPLACE_WITH_RELEASE_SHA256"

# Option B: Direct (development only — no checksum pin)
iex (irm https://raw.githubusercontent.com/ki10-bot/My-SSH/main/installer/Bootstrap.ps1)
```

> **Security note:** Never pipe an unverified script from a moving branch (`main`) directly to `iex` in production. Use a pinned release tag and verify SHA256. The bootstrap downloads to `TEMP`, verifies hash, then executes.

3. The installer will:
   - Check Windows build ≥ 17763 (1809)
   - Check Administrator
   - Create `C:\ProgramData\RemoteGate\` (logs, keys, config, bin)
   - Generate device ID (`config/device-id.txt`)
   - Create placeholder `config/config.json` → **edit it** (see below)
   - Install OpenSSH Server (`OpenSSH.Server~~~~0.0.1.0`), start `sshd` (Automatic)
   - Harden `C:\ProgramData\ssh\sshd_config` (`PasswordAuthentication no`, etc.)
   - Configure Windows Firewall (`OpenSSH-Server-In-TCP` → `LocalSubnet` only)
   - Generate tunnel key `keys/tunnel_ed25519` (ED25519, no passphrase, ACL: SYSTEM+Admin only)
   - Create scheduled task `\RemoteGate\RemoteGate-Tunnel` (SYSTEM, at startup+logon)
   - Verify installation

4. **Edit config**:

```powershell
notepad C:\ProgramData\RemoteGate\config\config.json
```

Fill in:

```json
{
  "yandex": {
    "vmPublicIp": "51.250.12.34",
    "vmUser": "tunneluser",
    "vmSshPort": 22,
    "reverseTunnelPort": 2222
  },
  "ssh": {
    "windowsUser": "johndoe"
  }
}
```

See `config/config.example.json` for all options.

5. **Copy tunnel public key to Yandex VM** (see `docs/YANDEX-CLOUD-SETUP.md`):

```powershell
cat C:\ProgramData\RemoteGate\keys\tunnel_ed25519.pub
# Paste into VM: /home/tunneluser/.ssh/authorized_keys
```

6. **First trust** (host key verification — do NOT disable):

```powershell
# From Windows, as Administrator:
ssh-keyscan -p 22 51.250.12.34 >> C:\ProgramData\RemoteGate\config\ssh\known_hosts
# Or connect once manually:
ssh -i C:\ProgramData\RemoteGate\keys\tunnel_ed25519 -p 22 tunneluser@51.250.12.34
# Type yes when prompted
```

7. **Start tunnel**:

```powershell
Start-ScheduledTask -TaskName RemoteGate-Tunnel -TaskPath \RemoteGate\
Get-ScheduledTask -TaskName RemoteGate-Tunnel -TaskPath \RemoteGate\ | Get-ScheduledTaskInfo
Get-Content C:\ProgramData\RemoteGate\logs\tunnel.log -Tail 20
```

8. **Test from Mac** (see `docs/MAC-CONNECTION.md`):

```bash
ssh -J rgadmin@51.250.12.34 -i ~/.ssh/remotegate_mac_ed25519 -p 2222 johndoe@127.0.0.1
```

## What each component does

| Component | Location | Purpose |
|-----------|----------|---------|
| `sshd` service | Windows Service `sshd` | Accepts SSH on 127.0.0.1:22 (firewall restricts to local) |
| `tunnel_ed25519` | `C:\ProgramData\RemoteGate\keys\` | Authenticates Windows → Yandex VM |
| Scheduled Task | `\RemoteGate\RemoteGate-Tunnel` | Keeps tunnel alive, reconnects, logs |
| `sshd_config` | `C:\ProgramData\ssh\sshd_config` | Hardened (keys only, no passwords) |
| `known_hosts` | `...\config\ssh\known_hosts` | Pins Yandex VM host key |

## Installer files

| File | Role |
|------|------|
| `installer/Install-RemoteGate.ps1` | Main installer (idempotent) |
| `installer/Bootstrap.ps1` | Secure downloader (temp + SHA256 verify) |
| `installer/Configure-SSH.ps1` | OpenSSH install + sshd_config |
| `installer/Configure-Firewall.ps1` | Firewall → LocalSubnet |
| `installer/Configure-Tunnel.ps1` | Key + task creation |
| `installer/Verify-Installation.ps1` | Post-install checks |
| `installer/Uninstall-RemoteGate.ps1` | Clean removal |

All scripts are **visible**, logged, not obfuscated, and not hidden.

## Idempotency

You can re-run `Install-RemoteGate.ps1` safely:
- Existing `config.json` is preserved
- Device ID is kept
- Keys are not regenerated if present
- Task is recreated cleanly
- `sshd_config` backup is made before changes

## Upgrading

1. Download new release.
2. Re-run installer — it will preserve config and keys.
3. Restart task: `Restart-Service sshd; Start-ScheduledTask ...`

## Offline / no cloud yet

Run with `-SkipCloudConfig`:

```powershell
.\Install-RemoteGate.ps1 -SkipCloudConfig
```

This installs SSH locally (for LAN use) without requiring VM IP.

## Verification

```powershell
.\Verify-Installation.ps1
# or
C:\ProgramData\RemoteGate\bin\RemoteGate-Agent.ps1 -Fix
```

Checks:
- Capability installed
- `sshd` Running/Automatic
- Firewall → LocalSubnet
- Port 22 listening
- `sshd_config` hardened
- Tunnel key + task exist
- Config filled

## Logs

| Log | Path |
|-----|------|
| Install | `C:\ProgramData\RemoteGate\logs\install.log` |
| Tunnel | `C:\ProgramData\RemoteGate\logs\tunnel.log` |
| Status | `C:\ProgramData\RemoteGate\logs\status.log` |
| Agent | `C:\ProgramData\RemoteGate\logs\agent.log` |
| Windows Event | Application log, source `RemoteGate` |

## Next steps

- `docs/YANDEX-CLOUD-SETUP.md` — create VM
- `docs/MAC-CONNECTION.md` — connect
- `docs/SECURITY.md` — threat model
- `docs/TROUBLESHOOTING.md` — if stuck
