# RemoteGate — Yandex Cloud VM (Bastion)

This folder contains the bastion VM configuration that forwards the Windows reverse tunnel.

## Architecture

```
Mac (ProxyJump) --> Yandex VM:22 --> 127.0.0.1:2222 (reverse tunnel) --> Windows:22
                    ↑
Windows --[ssh -R 127.0.0.1:2222:127.0.0.1:22]--> Yandex VM
```

The tunnel is **outbound from Windows** — no inbound firewall rule for port 22 from the Internet to Windows is needed.

On the VM, the forwarded port binds to `127.0.0.1` only (`GatewayPorts no`). It is NOT reachable from the Internet directly; you must SSH into the VM first (ProxyJump).

## Quick Start

### Option A: Manual via Console

1. Create VM in Yandex Cloud Console (see `docs/YANDEX-CLOUD-SETUP.md` for step-by-step).
2. SSH into VM as admin.
3. `sudo bash cloud/vm/setup.sh`

### Option B: cloud-init

Set `user-data` to `cloud/vm/cloud-init.yaml` when creating the VM.

```bash
yc compute instance create \
  --name remotegate-bastion \
  --zone ru-central1-a \
  --memory 2 --cores 2 --core-fraction 20 \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2204-lts,size=20 \
  --network-interface subnet-name=default-ru-central1-a,nat-ip-version=ipv4 \
  --ssh-key ~/.ssh/remotegate_mac.pub \
  --metadata-from-file user-data=cloud/vm/cloud-init.yaml
```

### Option C: Terraform

See `cloud/infrastructure/` — includes VM, VPC, security groups, IAM.

## After provisioning

1. Copy Windows tunnel public key:
   ```powershell
   cat C:\ProgramData\RemoteGate\keys\tunnel_ed25519.pub
   ```
2. On VM:
   ```bash
   sudo -u tunneluser nano /home/tunneluser/.ssh/authorized_keys
   # Paste key, optionally with restrictions:
   # no-pty,no-agent-forwarding,no-X11-forwarding,permitopen="127.0.0.1:22" ssh-ed25519 AAAA...
   ```
3. Add Mac key to VM admin:
   ```bash
   nano ~/.ssh/authorized_keys  # your admin user
   ```
4. Test from Windows (run as admin once):
   ```powershell
   ssh-keyscan -p 22 <VM_IP> >> C:\ProgramData\RemoteGate\config\ssh\known_hosts
   Start-ScheduledTask -TaskName RemoteGate-Tunnel -TaskPath \RemoteGate\
   ```
5. Verify on VM:
   ```bash
   ss -tlnp | grep 2222   # should show 127.0.0.1:2222
   ```

## Security notes

- `GatewayPorts no` in `sshd_config` — forwarded port not exposed publicly.
- `tunneluser` has `ForceCommand /bin/false` and `PermitTTY no` — no shell.
- `PasswordAuthentication no` — keys only.
- UFW denies inbound by default (security groups are primary).
- fail2ban protects SSH.
- Do NOT open port 2222 in Yandex security group.

## Cost

See `docs/YANDEX-CLOUD-SETUP.md` Cost section. Minimal VM (2 vCPU, 2GB, 20GB, preemptible off) ~ $5–10/month in ru-central1.
