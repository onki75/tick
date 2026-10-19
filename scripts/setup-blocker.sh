#!/bin/bash
# One-time setup for Tick's site blocker. Run with administrator rights:
#
#   sudo ./scripts/setup-blocker.sh            install
#   sudo ./scripts/setup-blocker.sh uninstall  remove everything this script installed
#
# It installs a root-owned helper (/usr/local/libexec/tick-hosts) and lets your user run
# exactly that helper (block / unblock only) without a password via /etc/sudoers.d/tick.
# Nothing else is changed.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0 ${1:-}" >&2
  exit 1
fi
USER_NAME="${SUDO_USER:-}"
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; then
  echo "Run it through sudo from your normal user, not as root directly." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="/usr/local/libexec/tick-hosts"
SUDOERS="/etc/sudoers.d/tick"
HOME_DIR="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
SUPPORT="$HOME_DIR/Library/Application Support/Tick"

if [ "${1:-}" = "uninstall" ]; then
  if [ -x "$HELPER" ]; then "$HELPER" unblock || true; fi
  rm -f "$SUDOERS" "$HELPER"
  echo "Removed the helper and the sudoers rule. Your site list is kept at: $SUPPORT/blocklist.txt"
  exit 0
fi

# 1. Helper: owned by root, not writable by anyone else.
mkdir -p /usr/local/libexec
install -o root -g wheel -m 755 "$HERE/tick-hosts" "$HELPER"

# 2. sudoers rule for exactly the two commands, validated before it is put in place.
TMP="$(mktemp)"
cat > "$TMP" <<EOF
$USER_NAME ALL=(root) NOPASSWD: $HELPER block, $HELPER unblock
EOF
if ! visudo -cf "$TMP" >/dev/null; then
  rm -f "$TMP"
  echo "The sudoers rule did not validate; nothing was installed." >&2
  exit 1
fi
install -o root -g wheel -m 440 "$TMP" "$SUDOERS"
rm -f "$TMP"

# 3. Default site list (only created if it does not exist yet), owned by you.
if [ ! -e "$SUPPORT/blocklist.txt" ]; then
  sudo -u "$USER_NAME" mkdir -p "$SUPPORT"
  sudo -u "$USER_NAME" tee "$SUPPORT/blocklist.txt" >/dev/null <<'EOF'
# One site per line. "www." is added automatically. Lines starting with # are ignored.
youtube.com
m.youtube.com
youtu.be
instagram.com
tiktok.com
m.tiktok.com
x.com
twitter.com
mobile.twitter.com
EOF
fi

echo "Installed."
echo "  helper:    $HELPER"
echo "  sudoers:   $SUDOERS"
echo "  site list: $SUPPORT/blocklist.txt"
