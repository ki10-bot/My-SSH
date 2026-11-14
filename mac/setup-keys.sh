#!/bin/bash
# RemoteGate — Mac key setup
# Generates two separate ED25519 keys:
#   1. mac-to-windows  (for SSH into Windows via bastion)
#   2. Optional tunnel key reference (tunnel key lives on Windows, not Mac — this just documents it)
#
# Usage:
#   bash mac/setup-keys.sh
#   # Then follow prompts; public keys are in ~/.ssh/

set -euo pipefail

SSH_DIR="$HOME/.ssh"
MAC_KEY="$SSH_DIR/remotegate_mac_ed25519"
TUNNEL_KEY_REF="$SSH_DIR/remotegate_tunnel_ed25519.pub.windows"  # placeholder note

echo "=== RemoteGate — Mac Key Setup ==="
echo "SSH dir: $SSH_DIR"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# 1. Mac-to-Windows key
if [[ -f "$MAC_KEY" ]]; then
  echo "[1/2] Mac key already exists: $MAC_KEY"
  ssh-keygen -l -f "$MAC_KEY" || true
  read -p "Regenerate? (y/N) " ans
  if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
    rm -f "$MAC_KEY" "$MAC_KEY.pub"
  else
    echo "Keeping existing key."
  fi
fi

if [[ ! -f "$MAC_KEY" ]]; then
  echo "[1/2] Generating Mac-to-Windows ED25519 key: $MAC_KEY"
  ssh-keygen -t ed25519 -f "$MAC_KEY" -C "remotegate-mac@$(hostname -s)" -N ""
  chmod 600 "$MAC_KEY"
  chmod 644 "$MAC_KEY.pub"
  echo "Generated."
  echo ""
  echo "Public key (add to Windows):"
  cat "$MAC_KEY.pub"
  echo ""
  echo "Add to Windows (choose based on account):"
  echo "  Admin: C:\\ProgramData\\ssh\\administrators_authorized_keys"
  echo "  Non-admin: C:\\Users\\<user>\\.ssh\\authorized_keys"
  echo ""
  echo "Windows command (run as admin on Windows):"
  echo "  \$pub = Get-Content '$MAC_KEY.pub'  # copy file to Windows first"
  echo "  # For admin:"
  echo "  Add-Content C:\\ProgramData\\ssh\\administrators_authorized_keys \$pub"
  echo "  # For non-admin:"
  echo "  Add-Content \$env:USERPROFILE\\.ssh\\authorized_keys \$pub"
  echo ""
fi

echo "[2/2] Tunnel key info (SEPARATE from Mac key)"
echo "The tunnel key is generated ON WINDOWS at C:\\ProgramData\\RemoteGate\\keys\\tunnel_ed25519"
echo "It must NOT be copied to Mac. It authenticates Windows -> Yandex VM only."
echo "Your Mac NEVER needs the tunnel private key."
echo ""
echo "=== Done ==="
echo "Keys:"
ls -l "$MAC_KEY"* 2>/dev/null || echo "  (no keys found)"
echo ""
echo "Next: Configure SSH (mac/ssh-config.example -> ~/.ssh/config)"
echo "See docs/MAC-CONNECTION.md"
