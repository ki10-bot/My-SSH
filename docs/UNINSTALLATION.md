# RemoteGate — Uninstallation

## Windows

### Quick (recommended)

From elevated PowerShell in the cloned repo (or the temp downloaded folder):

```powershell
.\installer\Uninstall-RemoteGate.ps1
# Prompts for confirmation, removes:
#  - Scheduled task \RemoteGate\RemoteGate-Tunnel (and variants)
#  - Lingering ssh.exe tunnel processes (with confirm)
#  - Directory C:\ProgramData\RemoteGate (keeps keys if -KeepKeys)
# Leaves:
#  - sshd service running (use -RemoveOpenSSH to uninstall capability)
#  - Firewall rule OpenSSH-Server-In-TCP (shared — remove manually if desired)
#  - sshd_config backups (restore manually if needed)
```

Options:

```powershell
.\installer\Uninstall-RemoteGate.ps1 -Force              # no prompts
.\installer\Uninstall-RemoteGate.ps1 -KeepKeys            # preserve keys for reinstall
.\installer\Uninstall-RemoteGate.ps1 -RemoveOpenSSH -Force # also remove OpenSSH capability
```

### Manual (if script unavailable)

```powershell
# Tasks
Get-ScheduledTask -TaskName "*RemoteGate*" | Unregister-ScheduledTask -Confirm:$false
# or specific:
Unregister-ScheduledTask -TaskName RemoteGate-Tunnel -TaskPath \RemoteGate\ -Confirm:$false

# Processes
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where CommandLine -like "*RemoteGate*" | % { Stop-Process -Id $_.ProcessId -Force }

# Data
Remove-Item -Recurse -Force C:\ProgramData\RemoteGate

# Optional: disable sshd (only if you don't need SSH anymore)
Stop-Service sshd; Set-Service sshd -StartupType Disabled

# Optional: remove OpenSSH capability entirely
Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

# Optional: remove firewall rule (shared — caution)
Remove-NetFirewallRule -DisplayName "RemoteGate-Block-Public-SSH"
# Do NOT remove OpenSSH-Server-In-TCP unless you are sure no other SSH uses it
```

### After uninstall checklist

- [ ] Task Scheduler: `taskschd.msc` → folder `\RemoteGate\` is empty/removed
- [ ] Services: `Get-Service sshd` — decide to keep/disable
- [ ] Firewall: `Get-NetFirewallRule -DisplayName OpenSSH-Server-In-TCP` — restrict/remove as needed
- [ ] Restore `sshd_config` if you want defaults:
  ```powershell
  $backup = Get-ChildItem C:\ProgramData\ssh\sshd_config.remotegate-backup-* | Sort LastWriteTime | Select -Last 1
  Copy-Item $backup.FullName C:\ProgramData\ssh\sshd_config -Force
  Restart-Service sshd
  ```
- [ ] On Yandex VM: remove tunnel public key from `/home/tunneluser/.ssh/authorized_keys`
- [ ] Delete temp downloads: `Remove-Item $env:TEMP\RemoteGate-* -Recurse -Force`

### Reinstall

Re-running `Install-RemoteGate.ps1` is idempotent — it will recreate directories, keys (if `KeepKeys` kept them), task, and verify. Use `-Force` on uninstall only if you want a clean slate (new keys).

---

## Yandex Cloud

### Via Console

1. **Compute** → VMs → select `remotegate-bastion` → **Delete** (check “delete boot disk”).
2. **VPC** → Networks → delete `remotegate-net` if you created it for this project.
3. **Cloud Functions** → `remotegate-status` → Delete.
4. **API Gateway** → `remotegate-gateway` → Delete.
5. **IAM** → Service accounts → delete `remotegate-func-sa` etc.
6. Billing stays — delete billing account manually if desired (Billing → delete).

### Via Terraform

```bash
cd cloud/infrastructure
terraform destroy  # confirms, then removes network, VM, function, gateway
terraform output   # should error (no state)
```

### Via `yc` CLI

```bash
yc compute instance delete --name remotegate-bastion
yc vpc network delete --name remotegate-net
yc serverless function delete --name remotegate-status
yc serverless api-gateway delete --name remotegate-gateway
yc iam service-account delete --name remotegate-func-sa
yc iam service-account delete --name remotegate-vm-sa  # if created
```

### Keys / secrets

- Rotate/delete `HMAC_SECRET` in your password manager after removing function.
- Delete local `terraform.tfvars` and `hmac-secret.txt` copies.
- VM host keys are deleted with VM; remove stale `known_hosts` entries on clients:
  ```bash
  ssh-keygen -R <VM_PUBLIC_IP>
  ssh-keygen -R "[127.0.0.1]:2222"
  ```
  ```powershell
  # On Windows:
  ssh-keygen -R VM_IP
  ```

---

## Mac

```bash
# Remove SSH config entries
nano ~/.ssh/config  # delete Host remotegate-bastion and remotegate-windows blocks

# Remove host keys
ssh-keygen -R 51.250.12.34          # VM IP
ssh-keygen -R "[127.0.0.1]:2222"    # Windows via tunnel

# Remove keys (only if you won't reconnect)
# Keep them if you may reconnect to same Windows/VM
rm -i ~/.ssh/remotegate_mac_ed25519 ~/.ssh/remotegate_mac_ed25519.pub

# Unset env vars
# From ~/.zshrc / ~/.bash_profile: remove REMOTEGATE_* exports
```

---

## GitHub repo

If you cloned `My-SSH` locally and want to remove:

```bash
rm -rf /path/to/My-SSH
# GitHub remote stays — delete fork/repo via GitHub web if desired (dangerous — no undo)
```

No telemetry or hidden data remains after above steps. Verify no `RemoteGate` tasks/services/files linger with:

```powershell
Get-ScheduledTask | ? TaskName -like "*RemoteGate*"
Get-Service sshd
Get-NetFirewallRule -DisplayName "*RemoteGate*"
Test-Path C:\ProgramData\RemoteGate
```

If all return nothing/`False`, uninstall is complete.
