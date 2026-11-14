# RemoteGate — Mac Connection Guide

> Connect from macOS Terminal to your Windows computer via the Yandex bastion.

## Prerequisites

- **macOS** with built-in `ssh` (Terminal)
- **Yandex VM** running and reachable (public IP)
- **Windows** with OpenSSH Server + tunnel established (see `docs/INSTALLATION.md`)
- **Keys generated** (see `mac/setup-keys.sh` or manual below)

---

## 1. Generate keys (one-time)

RemoteGate uses **two separate keys** (never reuse):

| Key | Lives on | Authenticates | Path |
|-----|----------|---------------|------|
| Mac → Windows | Mac only | You → Windows `sshd` | `~/.ssh/remotegate_mac_ed25519` |
| Windows → Yandex | Windows only | Windows tunnel → VM | `C:\ProgramData\RemoteGate\keys\tunnel_ed25519` |

### Automatic

```bash
bash mac/setup-keys.sh
# Generates ~/.ssh/remotegate_mac_ed25519 (ED25519, no passphrase)
# Prints public key to paste into Windows
```

### Manual

```bash
ssh-keygen -t ed25519 -f ~/.ssh/remotegate_mac_ed25519 -C "remotegate-mac@$(hostname -s)"
chmod 600 ~/.ssh/remotegate_mac_ed25519
chmod 644 ~/.ssh/remotegate_mac_ed25519.pub
cat ~/.ssh/remotegate_mac_ed25519.pub
```

---

## 2. Install Mac public key on Windows

On **Windows** (as Administrator, choose based on account type):

**For Administrator accounts** (member of local Administrators):
```powershell
# On Windows — paste Mac public key:
$pub = "ssh-ed25519 AAAAC3... macbook@local"  # replace with actual
Add-Content C:\ProgramData\ssh\administrators_authorized_keys $pub
# Fix ACL (required — sshd checks it):
$acl = Get-Acl C:\ProgramData\ssh\administrators_authorized_keys
$acl.SetAccessRuleProtection($true,$false)
$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")))
$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM","FullControl","Allow")))
Set-Acl C:\ProgramData\ssh\administrators_authorized_keys $acl
Restart-Service sshd
```

**For non-admin accounts:**
```powershell
$pub = "ssh-ed25519 AAAAC3... macbook@local"
$dir = "$env:USERPROFILE\.ssh"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
Add-Content $dir\authorized_keys $pub
Restart-Service sshd
```

Test from Mac later (Section 4).

> **Never** use `DEIN_PASSWORT` as a real password. It's a placeholder meaning "your password" — keep `PasswordAuthentication no` in `sshd_config`. See `docs/SECURITY.md`.

---

## 3. Configure SSH (recommended)

Copy example config:

```bash
cp mac/ssh-config.example ~/.ssh/config
nano ~/.ssh/config  # replace placeholders
# chmod 600 ~/.ssh/config
```

Edit:

```
Host remotegate-bastion
    HostName 51.250.12.34          # your Yandex VM public IP
    User rgadmin
    Port 22
    IdentityFile ~/.ssh/remotegate_mac_ed25519

Host remotegate-windows
    HostName 127.0.0.1
    User johndoe                    # Windows username
    Port 2222
    IdentityFile ~/.ssh/remotegate_mac_ed25519
    ProxyJump remotegate-bastion
```

Then connect with:

```bash
ssh remotegate-windows
```

---

## 4. Connect

### Method A: Helper script

```bash
# One-off (no config needed):
bash mac/connect.sh -b 51.250.12.34 -u johndoe

# With env vars:
export REMOTEGATE_BASTION_HOST=51.250.12.34
export REMOTEGATE_WINDOWS_USER=johndoe
bash mac/connect.sh --test   # test (runs hostname; whoami)
bash mac/connect.sh          # interactive shell
```

### Method B: Manual SSH (ProxyJump)

```bash
# Conceptual example from spec — actual verified syntax:
ssh -J rgadmin@51.250.12.34 -i ~/.ssh/remotegate_mac_ed25519 -p 2222 johndoe@127.0.0.1

# Explanation:
# -J rgadmin@51.250.12.34     Jump via bastion (uses your Mac key)
# -i ...mac_ed25519           Mac key for Windows auth
# -p 2222                     Port on bastion where Windows tunnel is exposed (127.0.0.1:2222)
# johndoe@127.0.0.1            User/port are from bastion's perspective (loopback)
```

> **Host key verification** stays enabled (`StrictHostKeyChecking yes`). First connection will ask: `Are you sure you want to continue connecting (yes/no)?` → type `yes`. Subsequent connections verify automatically.

### Method C: SSH config alias

```bash
ssh remotegate-windows
# Equivalent to full command above
```

### What you'll see

```
Microsoft Windows [Version 10.0.19045.2006]
(c) Microsoft Corporation...

C:\Users\johndoe> powershell
Windows PowerShell
PS C:\Users\johndoe> Get-ComputerInfo | Select WindowsProductName
```

The default shell is PowerShell (set by `DefaultShell` registry on Windows). You can run any authorized PowerShell command.

---

## 5. SSH host key behavior

- **Bastion host key** (Yandex VM): Stored in `~/.ssh/known_hosts` on Mac. First `ssh rgadmin@VM_IP` prompts to accept; thereafter verified. If VM is rebuilt, its host key changes — remove old entry: `ssh-keygen -R VM_IP`.

- **Windows host key** (sshd on Windows): Also in `known_hosts` on Mac, but tunneled via `127.0.0.1:2222`. Since `127.0.0.1` is ambiguous (it could be bastion's own loopback vs Windows'), the Mac will store a key for `[127.0.0.1]:2222`. If Windows is reinstalled, remove: `ssh-keygen -R "[127.0.0.1]:2222"`.

- **Never** use `StrictHostKeyChecking=no` or `UserKnownHostsFile=/dev/null` — those disable MITM protection (prohibited by `docs/SECURITY.md`).

---

## 6. PowerShell commands (examples)

Once connected, you can run:

```powershell
# System info
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, CsName
Get-Service sshd | Select Status, StartType
Get-NetIPAddress -AddressFamily IPv4 | Where IPAddress -notlike "127.*"

# Files
dir C:\Users\johndoe
Get-Content C:\ProgramData\RemoteGate\logs\tunnel.log -Tail 20

# Network
Test-NetConnection -ComputerName 8.8.8.8 -Port 443
Get-NetFirewallRule -DisplayName OpenSSH-Server-In-TCP | Get-NetFirewallAddressFilter

# Safe — never run untrusted commands piped from public endpoints
```

> Only execute **authorized** commands you intentionally type. Do not pipe remote URLs to `iex` without verification.

---

## 7. Advanced

### SCP / SFTP

```bash
# Copy file TO Windows:
scp -J rgadmin@51.250.12.34 -P 2222 -i ~/.ssh/remotegate_mac_ed25519 local.txt johndoe@127.0.0.1:C:/Users/johndoe/

# Copy FROM Windows:
scp -J rgadmin@51.250.12.34 -P 2222 -i ~/.ssh/remotegate_mac_ed25519 johndoe@127.0.0.1:C:/Users/johndoe/report.log ./

# Or with config alias (uses Port 2222 via ProxyJump):
scp -P 2222 remotegate-windows:C:/Users/johndoe/file.txt ./
```

### VS Code Remote SSH

Install **Remote - SSH** extension, add to `~/.ssh/config` as above, then **Remote-SSH: Connect to Host** → `remotegate-windows`. Use `powershell.exe` as remote shell (set already).

### Multiple Windows machines (future)

Not in v1 (single device). For future fleet: use distinct `remotePort` per device (2223, 2224...) and `DeviceId` in status. See `README.md` Limitations.

### Persistent connection (autossh alternative)

This project uses Windows scheduled task for tunnel persistence. On Mac, for interactive sessions, `ServerAliveInterval 30` keeps it alive through NAT. No `autossh` needed on Mac.

---

## 8. Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Permission denied (publickey)` | Mac key not in Windows `authorized_keys` or ACL wrong | Re-add key, fix ACL, `Restart-Service sshd` |
| `Host key verification failed` | Old key in `known_hosts` | `ssh-keygen -R <host>`, reconnect |
| `Connection timed out` to bastion | VM down or SG blocks | `yc compute instance get --name remotegate-bastion`, check SG |
| `Connection refused` on 2222 | Tunnel not running | On Windows: `Get-ScheduledTask -TaskName RemoteGate-Tunnel -TaskPath \RemoteGate\; cat logs\tunnel.log` |
| `kex_exchange_identification` | sshd not running | On Windows: `Get-Service sshd; Start-Service sshd` |

More: `docs/TROUBLESHOOTING.md`.

---

## 9. Security tips (Mac side)

- **Passphrase** your Mac key if possible: `ssh-keygen -p -f ~/.ssh/remotegate_mac_ed25519` (you'll need `ssh-add` + keychain).
- **Do not share** `remotegate_mac_ed25519` (private) — only `.pub` goes to Windows.
- **Verify** bastion host key on first connect (compare fingerprint shown by `ssh` with `ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub` on VM).
- **Do not** set `ForwardAgent yes` unless you need it (and understand risk).

See `docs/SECURITY.md` for full threat model.
