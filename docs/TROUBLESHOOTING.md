# RemoteGate — Troubleshooting

Quick diagnostics for common failures. Run `Verify-Installation.ps1` first.

## General

### `Verify-Installation.ps1` shows WARN/FAIL
```powershell
.\installer\Verify-Installation.ps1
# Read hints — often placeholder config (vmPublicIp = REPLACE_ME)
# Fill config and re-run
```

### Logs

```powershell
Get-Content C:\ProgramData\RemoteGate\logs\install.log -Tail 50
Get-Content C:\ProgramData\RemoteGate\logs\tunnel.log -Tail 50
Get-Content C:\ProgramData\RemoteGate\logs\status.log -Tail 50
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='RemoteGate'} | Select -First 20
```

---

## OpenSSH / sshd

| Symptom | Fix |
|---------|-----|
| `Get-WindowsCapability` fails, `Add-WindowsCapability` no source | `Get-WindowsCapability -Online` needs Windows Update/FoD. On air-gapped, provide `-Source E:\Sources\SxS -LimitAccess` (see docs link in `Configure-SSH.ps1`). Or use GitHub MSI (manual, not recommended). |
| `RestartNeeded True` after install | Reboot: `Restart-Computer`, then re-run installer. |
| `sshd` not running | `Get-Service sshd`; `Start-Service sshd -Verbose`; check `C:\ProgramData\ssh\logs\sshd.log` if configured. Check `sshd_config` syntax: `sshd -T` (run as admin). |
| `sshd` starts then stops | Backup `sshd_config`: `Copy-Item C:\ProgramData\ssh\sshd_config C:\temp\sshd_config.bak`; restore default from `sshd_config.remotegate-backup-*`; `Restart-Service sshd`. |
| `Port 22 already in use` | `Get-NetTCPConnection -LocalPort 22`; another SSHd (e.g., Win32-OpenSSH MSI) may conflict. Uninstall duplicate. |
| `sshd` listening on 22 but `ssh` from LAN fails | Firewall: `Get-NetFirewallRule -DisplayName OpenSSH-Server-In-TCP | Get-NetFirewallAddressFilter` should be `LocalSubnet` — LAN PC is on same subnet? Test with `Test-NetConnection -ComputerName WINDOWS_IP -Port 22`. Temporarily allow `Any` to test, then re-restrict. |

### Administrators vs regular users

- Admins (in `Administrators` group) use `C:\ProgramData\ssh\administrators_authorized_keys`, **not** `~/.ssh/authorized_keys`. This is Windows OpenSSH behavior.
- Symptom: `Permission denied (publickey)` for admin even though `~/.ssh/authorized_keys` has key → move key to `administrators_authorized_keys`, fix ACL (`Administrators`+`SYSTEM` only), restart sshd.
- Check which file sshd uses: See `%ProgramData%\ssh\sshd_config` `AuthorizedKeysFile` (default differs by user).

### sshd_config hardening

- After editing `sshd_config`, validate: `sshd -T` should print effective config without error.
- `StrictModes yes` checks perms: `authorized_keys` must not be writable by group/others. Fix ACL as in `Configure-SSH.ps1`.
- `AllowUsers` typo locks you out — keep a console open while testing, have local admin fallback.

---

## Firewall

| Symptom | Fix |
|---------|-----|
| LAN cannot SSH, but localhost `ssh 127.0.0.1` works | Firewall `RemoteAddress` is `LocalSubnet` but client is on different VLAN/WiFi isolation? Check client's IP: is it in same subnet? `ipconfig /all` on Windows vs `ifconfig` on Mac. Change firewall to `Any` for testing: `Set-NetFirewallRule -DisplayName OpenSSH-Server-In-TCP -RemoteAddress Any`. |
| Public Internet can SSH directly | **Do not** forward router port 22 to Windows. Firewall should be `LocalSubnet`; verify `Get-NetFirewallRule ... \| Get-NetFirewallAddressFilter` is not `Any`. Check router NAT rules. |

---

## Reverse tunnel

| Symptom | Fix |
|---------|-----|
| `tunnel.log` says placeholder IP | Fill `C:\ProgramData\RemoteGate\config\config.json` `yandex.vmPublicIp` with real VM IP. |
| `Host key verification failed` | `ssh-keyscan -p VM_PORT VM_IP >> C:\ProgramData\RemoteGate\config\ssh\known_hosts` or `ssh -i keys\tunnel_ed25519 -p PORT tunneluser@VM_IP` once (type yes). |
| `Permission denied (publickey)` from Windows to VM | Check VM: `sudo cat /home/tunneluser/.ssh/authorized_keys` has `tunnel_ed25519.pub` line. Check perms `0600` owner `tunneluser`. Check VM `sshd_config` `PasswordAuthentication no` means key must match. Test from Windows admin: `ssh -vvv -i ...\tunnel_ed25519 -p 22 tunneluser@VM_IP` (verbose). |
| `ssh` exits immediately with `0` but tunnel not up | `ForceCommand /bin/false` is correct — tunnel `ssh -N` should stay alive even with that. If it exits, check VM `sshd_config` `Match User tunneluser` syntax: `sshd -T -p 22` to dump. Also `ss -tlnp \| grep 2222` on VM should show `127.0.0.1:2222` — if `0.0.0.0:2222`, `GatewayPorts` is not `no` (fix + `systemctl restart sshd`). |
| Task shows `LastTaskResult 0x1` or `0xFF` | `tunnel.log` stderr shows `ssh: Could not resolve hostname` (DNS), `Connection timed out` (SG), `Connection refused` (sshd down on VM). Fix network/VM. |
| Duplicate `ssh.exe` processes | Normal if task was manually started twice. Mutex + process check should prevent. Kill extras: `Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" \| ? CommandLine -like "*RemoteGate*"` then `Stop-Process`. |
| Task not starting at boot | Task uses `AtStartup` + `AtLogOn`; on Server Core without logon, startup still should. Check Task Scheduler history (`taskschd.msc > \RemoteGate\ > History`). Enable history if off. Check `TaskPath \RemoteGate\` exists: `Get-ScheduledTask -TaskPath \RemoteGate\`. |
| `Tunnel alive` heartbeat but Mac cannot connect | On VM: `curl -v 127.0.0.1:2222` should get `SSH-2.0-OpenSSH...` banner. If not, tunnel failed `ExitOnForwardFailure yes` means ssh exited — check `tunnel.log`. Also check VM `ss -tlnp` shows listener. |
| `Network interruption recovery` | Tunnel has `ServerAliveInterval 30` + task `RestartInterval 1m` + exponential backoff (cap 5m). Simulate: disconnect WiFi 30s, logs should show `disconnected (exit code)` → `Reconnecting in Xs`. |
| `Missing cloud configuration behavior` | Expected: installer warns but does not fail. Status reporting exits 0 with `placeholder` message. SSH LAN still works. |

### Manual tunnel test

```powershell
# On Windows, bypass task — run ssh directly (shows stderr):
& "C:\Windows\System32\OpenSSH\ssh.exe" -v -N -R 127.0.0.1:2222:127.0.0.1:22 `
  -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=yes `
  -o UserKnownHostsFile=C:\ProgramData\RemoteGate\config\ssh\known_hosts `
  -o IdentitiesOnly=yes -i C:\ProgramData\RemoteGate\keys\tunnel_ed25519 -p 22 tunneluser@VM_IP
```

---

## Mac connection

| Symptom | Fix |
|---------|-----|
| `ssh: Could not resolve` bastion | Wrong `VM_IP` in `~/.ssh/config` or `connect.sh -b`. Check `yc compute instance get --name remotegate-bastion`. |
| `Permission denied (publickey)` on bastion | Mac key not in VM `~/.ssh/authorized_keys` for `rgadmin`. `ssh-copy-id -i ~/.ssh/remotegate_mac_ed25519.pub rgadmin@VM_IP` (if password auth temporarily allowed) or via console. |
| `Permission denied (publickey)` on Windows via jump | Same as OpenSSH section — Mac key not in `administrators_authorized_keys` or `authorized_keys` on Windows. Check `ssh -v -J ...` verbose: “Offering public key: ...”. |
| `Connection refused` on port 2222 via jump | Tunnel not running — see Reverse tunnel section. Check VM `ss -tlnp \| grep 2222` — if nothing, tunnel down. |
| `Host key verification failed` for `[127.0.0.1]:2222` | Windows host key changed (reinstall). `ssh-keygen -R "[127.0.0.1]:2222"` on Mac, reconnect. |
| `ProxyJump` unknown | macOS `ssh` supports `-J` since OpenSSH 7.3 (all modern macOS do). Update macOS if very old. Alternative: `ProxyCommand ssh -W %h:%p rgadmin@VM_IP`. |

### Verbose debugging

```bash
ssh -vvv -J rgadmin@VM_IP -i ~/.ssh/remotegate_mac_ed25519 -p 2222 johndoe@127.0.0.1
# -J verbose: ssh -vvv -J ... shows jump negotiation
```

---

## Status endpoint

| Symptom | Fix |
|---------|-----|
| `Status endpoint is placeholder` | Set `yandex.statusEndpoint` to `https://<domain>/status` in Windows `config.json`. |
| `HMAC secret not configured` | Set env var `REMOTEGATE_HMAC_SECRET` or `hmac-secret.txt`. Ensure SYSTEM can read file (ACL). |
| `Invalid signature` 401 | Secret mismatch Windows vs function `HMAC_SECRET`. Check no newline/whitespace (file should be `NoNewline`). Base64 vs utf8: both tried, but use plain utf8. |
| `Timestamp drift too large` | Device clock off by >5 min. Sync Windows time: `w32tm /resync`; Mac `sntp`. |
| `Payload too large` 413 | Local IPs array huge? Unlikely (<10KB). Check custom payload modifications. |
| Function 500 `Server misconfigured` | `HMAC_SECRET` env not set on function. `yc serverless function version list --function-name remotegate-status` → check env. |
| Gateway 429 | Rare — status is 1 req/5 min, limit is 10 rps. If many devices share DeviceId, spread intervals. |
| `curl` from Mac to `/health` fails | Gateway spec not deployed or VM routing_private not allowed. Check `yc serverless api-gateway get --name remotegate-gateway` → `domain`. `curl https://<domain>/health`. |

---

## Windows 10 EOL

- **Error:** Installer warns `Windows 10 reached end of support 2025-10-14`.
- **Fix:** Upgrade to Windows 11 if hardware allows (see `docs/WINDOWS10-EOL.md`). Or enroll in **Extended Security Updates (ESU)** program: https://learn.microsoft.com/en-us/windows/whats-new/extended-security-updates
- **Risk:** Continuing on unsupported Windows without ESU means no security patches — only for isolated/lab use behind firewall, not Internet-facing. Firewall `LocalSubnet` helps but OS vulns remain.

---

## Uninstall / cleanup

See `docs/UNINSTALLATION.md`.

```powershell
.\installer\Uninstall-RemoteGate.ps1
# Then on VM: remove tunnel key from /home/tunneluser/.ssh/authorized_keys
# On Mac: remove ~/.ssh/config Host remotegate-* entries
```

---

## Get help

1. Run `Verify-Installation.ps1` and `RemoteGate-Agent.ps1 -Fix`.
2. Capture `install.log` + `tunnel.log` (redact secrets).
3. Check `yc compute instance list`, `yc serverless function logs --since 10m`.
4. File issue at `https://github.com/ki10-bot/My-SSH/issues` with logs + `Get-ComputerInfo` output.

Do not paste private keys or HMAC secrets in issues.
