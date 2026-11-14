#!/bin/bash
# RemoteGate — Mac connection helper
# Connects to Windows via Yandex bastion using ProxyJump
#
# Usage:
#   bash mac/connect.sh                          # uses defaults
#   bash mac/connect.sh -u winuser -b bastion_ip # custom
#   bash mac/connect.sh --shell powershell       # force powershell
#   bash mac/connect.sh --test                   # test connection (no login)
#
# Prerequisites:
#   - Mac key exists: ~/.ssh/remotegate_mac_ed25519
#   - Windows authorized_keys has Mac public key
#   - Yandex VM has tunnel (port 2222 on 127.0.0.1)
#   - Bastion known_hosts entry

set -euo pipefail

# Defaults (override via args or env)
BASTION_USER="${REMOTEGATE_BASTION_USER:-rgadmin}"
BASTION_HOST="${REMOTEGATE_BASTION_HOST:-REPLACE_WITH_YANDEX_VM_IP}"
BASTION_PORT="${REMOTEGATE_BASTION_PORT:-22}"
WINDOWS_USER="${REMOTEGATE_WINDOWS_USER:-REPLACE_WITH_WINDOWS_USERNAME}"
TUNNEL_PORT="${REMOTEGATE_TUNNEL_PORT:-2222}"
MAC_KEY="${REMOTEGATE_MAC_KEY:-$HOME/.ssh/remotegate_mac_ed25519}"
BASTION_KEY="${REMOTEGATE_BASTION_KEY:-$HOME/.ssh/remotegate_mac_ed25519}" # same key for bastion unless separate
EXTRA_ARGS=()
RUN_TEST=false
SHELL_CMD=""

usage() {
  cat <<EOF
RemoteGate connect — SSH to Windows via Yandex bastion

Usage: $0 [options] [-- ssh_extra_args]

Options:
  -b HOST     Bastion IP/host (env REMOTEGATE_BASTION_HOST)
  -u USER     Windows username (env REMOTEGATE_WINDOWS_USER)
  --bastion-user USER  Bastion username (default rgadmin)
  -p PORT     Tunnel port on bastion (default 2222)
  -i KEY      Mac private key (default ~/.ssh/remotegate_mac_ed25519)
  --shell SH  Remote shell: powershell, pwsh, cmd (default = server DefaultShell)
  --test      Test only (ssh with 'hostname; whoami' then exit)
  -h, --help  Show this help

Examples:
  $0 -b 51.250.1.2 -u johndoe
  $0 --test
  ssh -J $BASTION_USER@$BASTION_HOST -i $MAC_KEY -p $TUNNEL_PORT $WINDOWS_USER@127.0.0.1

Config file: Set REMOTEGATE_* env vars or edit defaults in this script.
See docs/MAC-CONNECTION.md for SSH config (ProxyJump) setup.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b) BASTION_HOST="$2"; shift 2 ;;
    -u) WINDOWS_USER="$2"; shift 2 ;;
    --bastion-user) BASTION_USER="$2"; shift 2 ;;
    -p) TUNNEL_PORT="$2"; shift 2 ;;
    -i) MAC_KEY="$2"; shift 2 ;;
    --shell) SHELL_CMD="$2"; shift 2 ;;
    --test) RUN_TEST=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA_ARGS+=("$@"); break ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

echo "=== RemoteGate Connect ==="
echo "Bastion: $BASTION_USER@$BASTION_HOST:$BASTION_PORT"
echo "Windows: $WINDOWS_USER@127.0.0.1:$TUNNEL_PORT (via tunnel)"
echo "Key: $MAC_KEY"
echo ""

# Validate
if [[ "$BASTION_HOST" == *"REPLACE"* ]]; then
  echo "ERROR: Set bastion host: -b <IP> or env REMOTEGATE_BASTION_HOST" >&2
  echo "See docs/YANDEX-CLOUD-SETUP.md for VM IP" >&2
  exit 1
fi
if [[ "$WINDOWS_USER" == *"REPLACE"* ]]; then
  echo "ERROR: Set Windows user: -u <user> or env REMOTEGATE_WINDOWS_USER" >&2
  exit 1
fi
if [[ ! -f "$MAC_KEY" ]]; then
  echo "ERROR: Key not found: $MAC_KEY" >&2
  echo "Run: bash mac/setup-keys.sh" >&2
  exit 1
fi

# Check known_hosts for bastion (warn if missing)
if ! ssh-keygen -F "$BASTION_HOST" >/dev/null 2>&1 && ! ssh-keygen -F "[$BASTION_HOST]:$BASTION_PORT" >/dev/null 2>&1; then
  echo "WARNING: Bastion $BASTION_HOST not in ~/.ssh/known_hosts — first connection will prompt to accept host key." >&2
  echo "TIP: ssh-keyscan -p $BASTION_PORT $BASTION_HOST >> ~/.ssh/known_hosts" >&2
fi

# Build SSH command
# Use ProxyJump (-J) to hop via bastion to the loopback-forwarded port
# On bastion, the tunnel exposes Windows SSH on 127.0.0.1:2222 (loopback only)
SSH_CMD=(
  ssh
  -i "$MAC_KEY"
  -J "${BASTION_USER}@${BASTION_HOST}:${BASTION_PORT}"
  -p "$TUNNEL_PORT"
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
)

if [[ -n "$SHELL_CMD" ]]; then
  case "$SHELL_CMD" in
    powershell) SSH_CMD+=(-t "powershell.exe") ;;
    pwsh) SSH_CMD+=(-t "pwsh.exe") ;;
    cmd) SSH_CMD+=(-t "cmd.exe") ;;
    *) echo "Unknown shell: $SHELL_CMD" >&2; exit 1 ;;
  esac
fi

SSH_CMD+=("${WINDOWS_USER}@127.0.0.1")
SSH_CMD+=("${EXTRA_ARGS[@]:-}")

if [[ "$RUN_TEST" == true ]]; then
  echo "[TEST] Running: hostname; whoami; ver (Windows) via bastion..."
  # Override target to run a command instead of interactive
  SSH_CMD=(
    ssh
    -i "$MAC_KEY"
    -J "${BASTION_USER}@${BASTION_HOST}:${BASTION_PORT}"
    -p "$TUNNEL_PORT"
    -o StrictHostKeyChecking=yes
    -o ServerAliveInterval=30
    "${WINDOWS_USER}@127.0.0.1"
    "hostname; whoami; powershell -Command \"Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion\""
  )
fi

echo "Command: ${SSH_CMD[*]}"
echo "Connecting... (Ctrl+C to abort)"
echo ""

# Enable verbose with env
if [[ "${REMOTEGATE_DEBUG:-}" == "1" ]]; then
  SSH_CMD=(ssh -vvv "${SSH_CMD[@]:1}")
fi

# Keep host key checking enabled — do NOT pass StrictHostKeyChecking=no
exec "${SSH_CMD[@]}"
