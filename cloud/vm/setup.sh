#!/bin/bash
# RemoteGate — Yandex Cloud VM setup for bastion
# Run on the Ubuntu VM after creation (or via cloud-init).
# Hardens the VM, creates the restricted tunnel user, configures sshd.
#
# Usage:
#   sudo bash setup.sh
#
# Prerequisites:
#   - Ubuntu 22.04 LTS (or 20.04+)
#   - Run as root/sudo
#   - No secrets in this script — keys are injected via Yandex Console or yc CLI
#
set -euo pipefail

TUNNEL_USER="tunneluser"
TUNNEL_PORT=2222

echo "=== RemoteGate VM Setup ==="
echo "TUNNEL_USER=$TUNNEL_USER TUNNEL_PORT=$TUNNEL_PORT"

if [[ $EUID -ne 0 ]]; then echo "ERROR: run as root/sudo"; exit 1; fi

# 1. Update system
echo "[1/8] Updating packages..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq openssh-server fail2ban ufw curl jq

# 2. Harden SSHD
echo "[2/8] Hardening /etc/ssh/sshd_config ..."
SSHD="/etc/ssh/sshd_config"
cp -n "$SSHD" "${SSHD}.bak.$(date +%Y%m%d)" || true

# Helper: ensure directive
ensure_sshd() {
  local key="$1" val="$2"
  if grep -qE "^#?\s*${key}\s+" "$SSHD"; then
    sed -i -E "s|^#?\s*${key}\s+.*|${key} ${val}|" "$SSHD"
  else
    echo "${key} ${val}" >> "$SSHD"
  fi
}

ensure_sshd "PasswordAuthentication" "no"
ensure_sshd "ChallengeResponseAuthentication" "no"
ensure_sshd "PermitRootLogin" "no"
ensure_sshd "X11Forwarding" "no"
ensure_sshd "AllowTcpForwarding" "yes"
# GatewayPorts no ensures reverse tunnels only bind to loopback (security requirement)
ensure_sshd "GatewayPorts" "no"
ensure_sshd "ClientAliveInterval" "30"
ensure_sshd "ClientAliveCountMax" "3"
ensure_sshd "MaxAuthTries" "3"
ensure_sshd "LoginGraceTime" "60"
ensure_sshd "PermitEmptyPasswords" "no"

# Restrict AllowUsers to tunnel user + owner admin (edit after creation)
# Uncomment and set after you know your admin username:
# ensure_sshd "AllowUsers" "tunneluser youradmin"

systemctl restart sshd
echo "  sshd restarted — verify: systemctl status sshd"

# 3. Create dedicated tunnel user (restricted)
echo "[3/8] Creating tunnel user: $TUNNEL_USER ..."
if ! id "$TUNNEL_USER" &>/dev/null; then
  useradd -m -s /usr/sbin/nologin -c "RemoteGate tunnel (restricted)" "$TUNNEL_USER"
  echo "  Created $TUNNEL_USER with shell /usr/sbin/nologin (no interactive login)"
else
  echo "  User $TUNNEL_USER already exists"
fi

# Ensure .ssh dir
TUNNEL_HOME=$(eval echo "~$TUNNEL_USER")
SSH_DIR="$TUNNEL_HOME/.ssh"
mkdir -p "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"
chown -R "$TUNNEL_USER:$TUNNEL_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"

# Restrict tunnel user to port forwarding only (no shell, no X11, no agent)
# We add a Match block at end of sshd_config
if ! grep -q "Match User $TUNNEL_USER" "$SSHD"; then
  cat >> "$SSHD" <<EOF

# RemoteGate — restrict tunnel user to forwarding only
Match User $TUNNEL_USER
    AllowTcpForwarding yes
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
    ForceCommand /bin/false
EOF
  echo "  Added Match User $TUNNEL_USER block (ForceCommand /bin/false, forwarding only)"
  systemctl restart sshd
fi

# Alternative hardening: authorized_keys options
# If you prefer to restrict at key level, use in authorized_keys:
#   no-pty,no-agent-forwarding,no-X11-forwarding,permitopen="127.0.0.1:22" ssh-ed25519 AAAA...
echo "  TIP: For per-key restrictions, prefix the Windows public key in $SSH_DIR/authorized_keys with:"
echo '       no-pty,no-agent-forwarding,no-X11-forwarding,permitopen="127.0.0.1:22" ssh-ed25519 AAAA...'

# 4. Configure UFW (Yandex security groups are primary, UFW is defense-in-depth)
echo "[4/8] Configuring UFW..."
ufw --force reset || true
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH (bastion)'
# Do NOT open the reverse tunnel port to world — it's loopback only
# If you need monitoring, allow from specific IPs only:
#   ufw allow from <YOUR_MAC_IP> to any port 2222  (not recommended — use ProxyJump instead)
ufw --force enable
ufw status verbose

# 5. Fail2ban for SSH brute-force protection
echo "[5/8] Configuring fail2ban..."
cat > /etc/fail2ban/jail.local <<'JAIL'
[sshd]
enabled = true
maxretry = 5
bantime = 3600
findtime = 600
JAIL
systemctl enable fail2ban
systemctl restart fail2ban
echo "  fail2ban enabled"

# 6. Automatic security updates (Ubuntu)
echo "[6/8] Enabling unattended-upgrades..."
apt-get install -y -qq unattended-upgrades
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable unattended-upgrades || true

# 7. Banner / MOTD
echo "[7/8] Setting banner..."
cat > /etc/ssh/banner.txt <<'BANNER'
RemoteGate bastion — authorized access only.
All connections are logged. Disconnect if not authorized.
BANNER
ensure_sshd "Banner" "/etc/ssh/banner.txt"
systemctl restart sshd

# 8. Verify
echo "[8/8] Verification..."
echo "  sshd: $(systemctl is-active sshd)"
echo "  ufw:  $(ufw status | head)"
echo "  tunnel user: $(id $TUNNEL_USER)"
echo "  sshd_config GatewayPorts: $(grep -i GatewayPorts $SSHD)"
echo "  authorized_keys: $SSH_DIR/authorized_keys ($(wc -l < "$SSH_DIR/authorized_keys") keys)"

echo ""
echo "=== VM setup complete ==="
echo "Next steps:"
echo "  1. Add Windows tunnel public key to $SSH_DIR/authorized_keys"
echo "     (copy from C:\ProgramData\RemoteGate\keys\tunnel_ed25519.pub on Windows)"
echo "  2. Add your Mac public key to your admin user on this VM:"
echo "     e.g., /home/<admin>/.ssh/authorized_keys"
echo "  3. Test: ssh -i <key> -p 22 $TUNNEL_USER@\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo <VM_PUBLIC_IP>)"
echo "  4. Harden AllowUsers in $SSHD if desired"
echo "  5. See docs/YANDEX-CLOUD-SETUP.md"
