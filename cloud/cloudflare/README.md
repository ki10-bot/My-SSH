# RemoteGate — Cloudflare Tunnel (Option A: 0 ₽)

This folder contains helpers for the free Cloudflare Tunnel mode.

## What it does

Instead of a VM with public IP, Windows runs `cloudflared` outbound tunnel to Cloudflare.

```
Windows:22 ← cloudflared → Cloudflare Edge (ssh.deinedomain.ru) ← Mac (cloudflared access ssh)
```

No inbound ports, no bastion VM.

## Files

* `install-tunnel.ps1` — installs cloudflared on Windows (called by Final template when tunnel token present)
* `config.yml.example` — example cloudflared config for SSH

## Manual install (without wizard)

```powershell
# Download cloudflared
irm https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe -OutFile C:\ProgramData\RemoteGate\bin\cloudflared.exe

# Install service with token from Zero Trust → Tunnels → remotegate-ssh → Install
& C:\ProgramData\RemoteGate\bin\cloudflared.exe service install eyJh...

# Verify
Get-Service cloudflared
```

## See docs

* `docs/CLOUDFLARE-TUNNEL-GUIDE.md` — full German guide
* `docs/GENERATOR.md` — wizard step 2
