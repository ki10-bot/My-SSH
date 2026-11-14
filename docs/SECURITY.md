# RemoteGate — Security Model

## Overview

RemoteGate is a **secure, transparent remote administration system** for one owned Windows computer via SSH, with a Yandex Cloud bastion as jump host. No hidden backdoors, no obfuscation, no credential exfiltration.

## Architecture & Data Flow

```
Windows (sshd:22) <--[reverse tunnel 127.0.0.1:2222]--- Yandex VM (sshd:22)
                                                            ^
Mac (ssh via ProxyJump) ------------------------------------+
                                                            |
Windows --HTTPS+HMAC--> API Gateway --> Cloud Function (status)
```

- **SSH path:** Mac → VM (jump) → Windows. Mac never connects directly to Windows public IP. Windows never exposes port 22 to Internet.
- **Status path:** Windows → HTTPS POST with HMAC-SHA256 (timestamp+nonce+deviceId+payloadHash).
- No VPN, no Discord/Telegram/ntfy, no public unauthenticated topics.

## Security Requirements (Implemented)

### Least privilege

- **VM `tunneluser`:** `nologin`, `ForceCommand /bin/false`, `PermitTTY no`, only `AllowTcpForwarding yes`. Can only forward `127.0.0.1:22` (via `permitopen` option recommended).
- **Windows task:** Runs as `SYSTEM` (machine scope) — alternative is a dedicated service account (documented in `installer/Configure-Tunnel.ps1` principal choice).
- **VM admin:** Your user (`rgadmin`) with sudo, key-only auth.

### SSH authentication

- **Default:** Key-based only (`PasswordAuthentication no`, `PubkeyAuthentication yes`).
- **Separate keys:** Mac→Windows and Windows→VM never reuse. Mac private key never on Windows, tunnel private key never on Mac.
- **Host key verification:** `StrictHostKeyChecking yes` everywhere (Windows `known_hosts`, Mac `known_hosts`). **Never** disable for convenience (prohibited).
- **No passwords in repo:** `DEIN_PASSWORT` is a placeholder meaning "your password" — never a real password. Keep password auth disabled.
- **Hardened `sshd_config`:** `PermitRootLogin no`, `PermitEmptyPasswords no`, `MaxAuthTries 3`, `LoginGraceTime 60`, `ClientAliveInterval 30`.

### Port forwarding

- **Loopback-only:** Tunnel binds `127.0.0.1:2222` on VM (`GatewayPorts no` on VM `sshd_config`). Not `0.0.0.0:2222`.
- **Firewall:** Windows rule `OpenSSH-Server-In-TCP` restricted to `LocalSubnet` (not `Any`). Prevents public exposure of Windows SSH.
- **No Internet-facing Windows SSH:** Router/NAT must NOT forward port 22 to Windows.

### Secrets management

- **Never in Git:** Private keys (`*.pem`, `tunnel_ed25519`), HMAC secret, Yandex API keys, `.tfvars` are in `.gitignore`.
- **Storage:**
  - Tunnel key: `C:\ProgramData\RemoteGate\keys\tunnel_ed25519` ACL: `SYSTEM`+`Administrators` only.
  - HMAC secret: ENV `REMOTEGATE_HMAC_SECRET` or file `hmac-secret.txt` ACL same; never logged.
  - On VM: `authorized_keys` perms `0600`, owner `tunneluser`.
- **Do not log secrets:** Scripts avoid `Write-Host $secret`; logs show only truncated fingerprints.

### HTTPS & input validation

- **TLS:** `Tls12`+ enforced; cert verification not disabled.
- **Input validation:** Function checks `deviceId` shape, `timestamp` drift (±5 min), `nonce` shape, payload size ≤10KB, missing auth headers → 401/403.
- **Forbidden payload patterns:** Rejects bodies containing `PRIVATE KEY`, `password`, etc. (defense in depth).
- **Minimal PII:** Status payload is hostname, local IPs, service states, OS version — no files, no full `authorized_keys`, no passwords. Disable via `includeHostname`/`includeLocalIps` or `statusEnabled=false`.

### Replay protection

- **HMAC:** `HMAC-SHA256(timestamp.nonce.deviceId.sha256(payload))`, base64-encoded, constant-time compare (`crypto.timingSafeEqual`).
- **Timestamp window:** ±5 min (requires device NTP sync).
- **Nonce:** Random 16-char hex per request, logged. **Full deduplication requires external store** (YDB/Redis with TTL) — documented in `cloud/functions/index.js` TODO. Current implementation logs nonce for audit; production should enforce uniqueness via YDB conditional write.

### Logging & monitoring

- **Local logs:** `tunnel.log`, `status.log`, `agent.log`, `install.log` in `ProgramData\RemoteGate\logs\` (rotated at 10 MB).
- **Event Log:** `Application` source `RemoteGate` for tunnel connect/disconnect.
- **Cloud logs:** Function logs to Yandex Cloud Logging (IAM `logging.writer`).
- **No secrets in logs:** HMAC secret, private keys never logged.

### Access controls

- **VM security group:** Only TCP 22 inbound (restrict to your IP `/32` in production). No tunnel port ingress.
- **Function IAM:** Service account `remotegate-func-sa` with `logging.writer` only (least privilege). Gateway invokes function via SA.
- **Allowlist:** Function `ALLOWED_DEVICE_IDS` env var optionally restricts device IDs.

### Update & recovery

- **Auto-reconnect:** Tunnel `ServerAliveInterval 30`, `ServerAliveCountMax 3`, exponential backoff (reconnectDelay ×1.5, cap 5 min) + jitter.
- **Scheduled task:** Starts at startup+logon, `RestartCount 10`, `MultipleInstances IgnoreNew` (no duplicates), visible in `taskschd.msc`.
- **Unattended upgrades:** Enabled on VM.
- **Uninstall:** `Uninstall-RemoteGate.ps1` removes task, data (opt keep keys), optional OpenSSH removal.

---

## Threat Model

| Threat | Mitigation | Residual |
|--------|------------|----------|
| **MITM on SSH** | Host key pinning (`known_hosts`, `StrictHostKeyChecking yes`) | User must verify first fingerprint |
| **Stolen Mac key** | ED25519, per-device, `AllowUsers` restricts WHO can auth | Revoke by removing pubkey from `authorized_keys` |
| **Stolen tunnel key** | Separate from Mac key, restricted to forwarding, `permitopen` | Rotate via `ssh-keygen` + `authorized_keys` update |
| **Brute force on VM** | `fail2ban`, `MaxAuthTries 3`, keys only, SG restricts IPs | Rate limit still allows lockout if IP leaked |
| **Replaying status** | Timestamp window + nonce logging | Full dedup needs YDB (documented; warn in logs if reused nonce) |
| **Malicious status payload** | Size limit, schema validation, forbidden pattern check | Function must still escape logs (no code execution from payload) |
| **VM compromise** | Tunnel user `nologin`, no shell, loopback-only | Attacker with VM root could intercept forwarded traffic — use end-to-end SSH encryption (already) |
| **Windows malware via SSH** | `AllowUsers` restricts SSH logins, PowerShell execution policy per-task (`Bypass` only for task, not system-wide `RemoteSigned` remains) | User must keep Windows Defender enabled (installer does NOT disable it) |
| **Supply chain (GitHub)** | Pinned release + SHA256 verify, no silent `main` exec, code not obfuscated | User must verify hash from Releases page |

## What RemoteGate does NOT do

- Does NOT install hidden persistence (task is visible, documented, removable)
- Does NOT disable Windows Defender / PowerShell protections globally
- Does NOT exfiltrate passwords, private keys, or unrelated files
- Does NOT execute arbitrary commands from a public notification endpoint
- Does NOT expose unauthenticated SSH
- Does NOT commit secrets to GitHub
- Does NOT bypass UAC (requires Administrator approval)
- Does NOT hide execution windows (progress shown)

## Password & placeholder guidance

- **Literal `DEIN_PASSWORT`:** Appears only in `config/config.example.json` comments and docs as placeholder (“your password”). Never used as credential.
- **Policy:**
  - Never hardcode real passwords in repo.
  - Use SSH keys by default.
  - `PasswordAuthentication no` stays.
  - If password auth ever needed: require explicit config `AllowUsers` + Windows account password set by owner (not in repo), with `MaxAuthTries 3`.

## Connectivity & network assumptions

- **Yandex Cloud reachability:** Not promised for every Russian ISP. Tested via ordinary HTTPS/SSH (ports 443/22). Document ISP blocks in GitHub issues.
- **Cloudflare throttling:** Since June 2025, Russian ISPs throttle Cloudflare to ~16KB. RemoteGate avoids Cloudflare dependency (uses `github.com` and `yandexcloud.net` directly).
- **No VPN:** All transport is direct HTTPS/SSH; no WireGuard/etc.

## Secrets rotation

| Secret | How to rotate |
|--------|---------------|
| Tunnel key | Re-run `ssh-keygen -t ed25519 -f C:\ProgramData\RemoteGate\keys\tunnel_ed25519`, paste new `.pub` to VM `authorized_keys`, `Restart-ScheduledTask` |
| Mac key | `ssh-keygen -p -f ~/.ssh/remotegate_mac_ed25519` (passphrase) or new key `ssh-keygen -t ed25519 -f ..._new`, add pub to Windows, remove old |
| HMAC secret | Generate `openssl rand -base64 32`, set on Windows (`hmac-secret.txt`/ENV) + function `HMAC_SECRET` ENV, `Restart-Service` not needed |
| VM host key | `ssh-keygen -R VM_IP` on clients after rebuilding VM |

## Compliance & logging

- Logs are local by default; cloud logs retained per Yandex retention (30 days default).
- Do not log PHI beyond hostname/IP/service status. User may disable status entirely.
- For EU data: Yandex stores in ru-central1; consider data localization (Russian law requires personal data of Russian citizens stored in Russia — relevant if handling others' data).

## Responsible disclosure

Report security issues via GitHub Issues (or email owner directly). Do not exploit live VM without consent.

---

## Audit checklist (for reviewers)

- [ ] No `DEIN_PASSWORT` used as credential (grep shows only comments/examples)
- [ ] No private keys in repo (`*.pem`, `*.key` in `.gitignore`, no `BEGIN PRIVATE` in tracked files)
- [ ] `sshd_config` sets `PasswordAuthentication no` and `GatewayPorts no` on VM
- [ ] `StrictHostKeyChecking yes` (no `...no` or `/dev/null`)
- [ ] `AllowUsers` set or justified why not
- [ ] Firewall `RemoteAddress LocalSubnet` (or documented override)
- [ ] `tunneluser` shell `nologin` + `ForceCommand /bin/false`
- [ ] HMAC verified with `timingSafeEqual`, timestamp drift checked, size limit
- [ ] No `Disable Defender` / `Bypass` system-wide / `Obfuscated` in scripts
- [ ] Task visible (`taskschd.msc \RemoteGate\`), log path documented
