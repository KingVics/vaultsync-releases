

#!/usr/bin/env bash
# VaultSync Agent installer
# Usage: curl -fsSL https://cdn.jsdelivr.net/gh/KingVics/vaultsync-releases@main/install.sh | sudo bash
# Override version: VAULTSYNC_VERSION=v1.2.0 curl -fsSL https://dub.sh/vaultsync-install | sudo bash

set -euo pipefail

INSTALL_DIR="/usr/local/bin"
IDENTITY_DIR="/etc/vaultsync"
REPO="KingVics/vaultsync-releases"
VERSION="${VAULTSYNC_VERSION:-latest}"

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root" >&2
  exit 1
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)          ARCH="amd64" ;;
  aarch64|arm64)   ARCH="arm64" ;;
  *)
    echo "Error: unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

# Resolve download URL
if [[ "$VERSION" == "latest" ]]; then
  BINARY_URL="https://github.com/${REPO}/releases/latest/download/vaultsync-linux-${ARCH}"
else
  BINARY_URL="https://github.com/${REPO}/releases/download/${VERSION}/vaultsync-linux-${ARCH}"
fi

BINARY_URL="${VAULTSYNC_BINARY_URL:-$BINARY_URL}"

CHECKSUM_URL="${BINARY_URL%/*}/checksums.txt"
TMP_BINARY="/tmp/vaultsync-download"
TMP_CHECKSUMS="/tmp/vaultsync-checksums.txt"

# Clean up temp files on any exit (success or failure)
trap 'rm -f "$TMP_BINARY" "$TMP_CHECKSUMS"' EXIT

echo "→ Downloading VaultSync agent (linux/${ARCH}) ..."
curl -fsSL "$BINARY_URL" -o "$TMP_BINARY"

echo "→ Verifying checksum..."
if ! curl -fsSL "$CHECKSUM_URL" -o "$TMP_CHECKSUMS" 2>/dev/null; then
  echo "Error: could not fetch checksums.txt — aborting for security" >&2
  exit 1
fi

EXPECTED=$(grep "vaultsync-linux-${ARCH}" "$TMP_CHECKSUMS" | awk '{print $1}')
if [[ -z "$EXPECTED" ]]; then
  echo "Error: no checksum entry found for vaultsync-linux-${ARCH} — aborting" >&2
  exit 1
fi

ACTUAL=$(sha256sum "$TMP_BINARY" | awk '{print $1}')
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "Error: checksum mismatch — binary may be corrupted or tampered" >&2
  echo "  expected: $EXPECTED" >&2
  echo "  got:      $ACTUAL" >&2
  exit 1
fi
echo "✓ Checksum verified"

# Only install after successful verification
install -m 755 "$TMP_BINARY" "$INSTALL_DIR/vaultsync"

echo "→ Creating vaultsync system user..."
useradd --system --no-create-home --shell /usr/sbin/nologin vaultsync 2>/dev/null || true

echo "→ Creating identity directory..."
mkdir -p "$IDENTITY_DIR"
chown vaultsync:vaultsync "$IDENTITY_DIR"
chmod 700 "$IDENTITY_DIR"

echo "→ Installing systemd service..."
cat > /etc/systemd/system/vaultsync-run.service << 'SERVICE'
[Unit]
Description=VaultSync Secret Runner
After=network.target

[Service]
Type=simple
User=vaultsync
EnvironmentFile=/etc/vaultsync/run.env
ExecStart=/bin/sh -c 'exec /usr/local/bin/vaultsync run --label "$LABEL" --env "$ENVIRONMENT" -- $APP_COMMAND'
Restart=on-failure
RestartSec=5s
# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/etc/vaultsync
SERVICE

systemctl daemon-reload

echo ""
echo "✓ VaultSync agent installed to $INSTALL_DIR/vaultsync"
echo ""
echo "Next steps:"
echo "  1. On your dev machine: vaultsync machine create --name <name>"
echo "  2. Copy the OTET token, then on this VPS:"
echo "     vaultsync enroll <OTET>"
echo "  3. On dev: vaultsync grant --machine <name> --label <label> --env Production"
echo "  4. On this VPS: vaultsync run --label <l> --env Production -- node dist/index.js"
