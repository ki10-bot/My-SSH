# RemoteGate — Test Plan (15 required tests)

> Do not report a test as successful unless actually executed. Mark each as `pass / fail / requires owner action`.

This plan separates unit (mocked), integration (real VMs/network), and manual (owner's hardware).

## Test matrix

| # | Test | Type | Requires | Status | Notes |
|---|------|------|----------|--------|-------|
| 1 | OpenSSH installation | Integration | Real Windows 10+ | ☐ | `Add-WindowsCapability OpenSSH.Server` |
| 2 | SSH service startup + Automatic | Integration | Real Windows | ☐ | `Get-Service sshd` Running/Automatic |
| 3 | Automatic startup after reboot | Manual | Reboot | ☐ | Reboot, check `Get-Service sshd` still Running |
| 4 | Key-based login (valid key) | Integration | Mac+Windows | ☐ | `ssh -i key user@host` succeeds |
| 5 | Invalid key rejection | Integration | Real SSH | ☐ | Wrong key → `Permission denied` |
| 6 | Local firewall restriction (LocalSubnet) | Integration | LAN | ☐ | LAN host outside subnet blocked, localhost allowed |
| 7 | Reverse tunnel establishment | Integration | Yandex VM + Windows | ☐ | `ss -tlnp` shows `127.0.0.1:2222` on VM |
| 8 | Tunnel reconnection (network bounce) | Manual | Network interruption | ☐ | Disconnect WiFi 30s, check `tunnel.log` reconnects |
| 9 | Mac-to-Windows via bastion (ProxyJump) | Integration | Mac+VM+Windows | ☐ | `ssh -J ... -p 2222 user@127.0.0.1` works |
| 10 | Authenticated HTTPS heartbeat (valid HMAC) | Integration | Yandex Function | ☐ | POST with HMAC → 200 |
| 11 | Invalid status auth rejection (bad HMAC) | Unit + Integration | Function | ☐ | Bad sig → 401 |
| 12 | Installer rerun idempotency | Integration | Real Windows | ☐ | Second run preserves config/keys, exits 0 |
| 13 | Uninstallation | Integration | Real Windows | ☐ | `Uninstall-RemoteGate.ps1` removes task/data |
| 14 | Missing cloud config behavior | Integration | No VM config | ☐ | Placeholder `vmPublicIp` → warn, SSH LAN still works, no crash |
| 15 | Network interruption recovery | Manual | Network | ☐ | Same as #8 but measure time to reconnect (<2 min) |

## Execution instructions

### Group A: Static / Unit (no hardware, can run in CI)

```powershell
# PowerShell Pester tests (mocked, no real Windows needed)
Install-Module Pester -Force -SkipPublisherCheck
Invoke-Pester -Path tests/powershell -Output Detailed
# Expected: ~25 tests pass

# Cloud Function HMAC tests (Node)
node --test tests/cloud/function.test.js
# Expected: 8-10 tests pass
```

These run anywhere (including this sandbox via bash, though Pester needs Windows to fully execute — see CI notes).

### Group B: Windows integration (requires real Windows 10+ machine, admin)

```powershell
# 1. OpenSSH installation
Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0  # State Installed

# 2. Service
Get-Service sshd | Select Name,Status,StartType  # Running, Automatic
Get-NetTCPConnection -LocalPort 22 -State Listen

# 3. Reboot
Restart-Computer
# After reboot:
Get-Service sshd  # Still Running

# 4/5. Key auth
# On Mac: ssh-keygen -t ed25519 -f ~/.ssh/test_key; paste .pub to Windows authorized_keys
ssh -i ~/.ssh/test_key johndoe@WINDOWS_LAN_IP  # should succeed
ssh -i ~/.ssh/wrong_key johndoe@WINDOWS_LAN_IP  # should fail Permission denied

# 6. Firewall
Get-NetFirewallRule -DisplayName OpenSSH-Server-In-TCP | Get-NetFirewallAddressFilter
# Should be LocalSubnet, not Any
# Test from another LAN host: ssh johndoe@WINDOWS_IP (should work if same subnet)
# Test from WAN (not forwarded — should fail; no port forward on router)

# 12. Rerun
.\installer\Install-RemoteGate.ps1  # check idempotent: no new keys generated, config preserved
Get-Content C:\ProgramData\RemoteGate\config\device-id.txt  # same UUID

# 13. Uninstall
.\installer\Uninstall-RemoteGate.ps1
Get-ScheduledTask -TaskName "*RemoteGate*"  # should be gone
Test-Path C:\ProgramData\RemoteGate  # should be false (unless -KeepKeys)

# 14. Missing cloud
# Fill config with REPLACE_ME, run tunnel: check log says placeholder, no crash
Get-Content C:\ProgramData\RemoteGate\logs\tunnel.log  # contains placeholder warning
```

### Group C: Cloud integration (requires Yandex Cloud account + billing)

```bash
# 7. Tunnel
yc compute instance get --name remotegate-bastion
ssh rgadmin@VM_IP
sudo -u tunneluser cat ~/.ssh/authorized_keys  # has Windows key
ss -tlnp | grep 2222  # 127.0.0.1:2222

# 8. Reconnection
# From Windows: disconnect network 30s (or reboot)
# On VM: watch -n 2 'ss -tlnp|grep 2222' should reappear within 1-2 min

# 9. Mac via bastion
ssh -J rgadmin@VM_IP -i ~/.ssh/remotegate_mac_ed25519 -p 2222 johndoe@127.0.0.1
hostname  # should show Windows hostname

# 10/11. Status heartbeat
# Valid:
curl -X POST https://API_GW_DOMAIN/status \
  -H "X-RemoteGate-DeviceId: $DEVICE_ID" \
  -H "X-RemoteGate-Timestamp: $(date +%s)" \
  -H "X-RemoteGate-Nonce: $(openssl rand -hex 8)" \
  -H "X-RemoteGate-Signature: $(./scripts/compute-hmac.sh)" \
  -d '{"deviceId":"...","sshStatus":"Running"}'
# Expect 200 {"ok":true}
# Invalid (bad sig): expect 401
```

## Reporting results

Update this table after execution. Example:

```
| 4 | Key-based login | Integration | Mac+Windows | PASS | 2025-11-14, johndoe@DESKTOP, key auth works |
```

Commit updated `TEST-PLAN.md` with actual timestamps. Do NOT fabricate.

## CI status (sandbox without Windows)

- Pester tests are mocked → can run on any runner with PowerShell + Pester (Windows runner ideal).
- Cloud function tests run on Linux with Node 18+.
- Real Windows tests marked `requires owner action` until owner runs on their hardware.

## Current execution in this sandbox (2025-11-14, Linux, no Windows)

- `tests/powershell/*.Tests.ps1` — **Not executed** (needs Windows PowerShell + Pester; sandbox is Linux). Will be executed by owner on Windows.
- `tests/cloud/function.test.js` — **Executed** (see `Test results` in task output).
- Integration 1–15 — **Requires owner action** (real Windows + Yandex account).

Update after owner provides Windows logs and Yandex outputs.
