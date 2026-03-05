#!/bin/bash
# XNav ISO Verification Script
# Checks that the built image has all necessary components
# (Rust binary deployment model)
#
# Usage: sudo bash verify_iso.sh [image-file.img.xz]

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash verify_iso.sh"
  exit 1
fi

IMG_FILE="${1:-xnav-1.1.0.img.xz}"

if [ ! -f "$IMG_FILE" ]; then
  echo "ERROR: Image file not found: $IMG_FILE"
  exit 1
fi

log() { echo "[VERIFY] $*"; }
check() {
  if [ $? -eq 0 ]; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1 FAILED"
    exit 1
  fi
}

log "Verifying XNav ISO: $IMG_FILE"
log "================================"

# Decompress to temporary location
WORK_DIR="/tmp/xnav-verify-$$"
mkdir -p "$WORK_DIR"
log "Decompressing image..."
xz -d -k -f -T0 "$IMG_FILE" -o "$WORK_DIR/xnav.img"
check "Decompressed image"

# Mount partitions
log "Mounting partitions..."
mkdir -p "$WORK_DIR/mnt/boot" "$WORK_DIR/mnt/root"
LOOP=$(losetup -fP --show "$WORK_DIR/xnav.img")
mount "${LOOP}p1" "$WORK_DIR/mnt/boot"
mount "${LOOP}p2" "$WORK_DIR/mnt/root"
check "Mounted partitions"

ROOT="$WORK_DIR/mnt/root"

# Check XNav directories
log "Checking XNav directory structure..."
[ -d "$ROOT/opt/xnav" ]
check "Directory /opt/xnav exists"

[ -d "$ROOT/opt/xnav/bin" ]
check "Directory /opt/xnav/bin exists"

[ -d "$ROOT/etc/xnav" ]
check "Directory /etc/xnav exists"

# Check critical files
log "Checking critical files..."
[ -f "$ROOT/etc/xnav/config.json" ]
check "File config.json exists"

# Check Rust binary
log "Checking XNav binary..."
if [ -f "$ROOT/opt/xnav/bin/xnav" ]; then
  echo "  ✓ XNav binary present (/opt/xnav/bin/xnav)"
  [ -x "$ROOT/opt/xnav/bin/xnav" ]
  check "XNav binary is executable"
else
  # Binary not pre-built – first-boot compilation should be configured
  echo "  ⚠ Binary not pre-built — checking first-boot compilation setup..."
  [ -f "$ROOT/etc/xnav/first_boot.sh" ]
  check "First-boot compilation script exists"

  [ -x "$ROOT/etc/xnav/first_boot.sh" ]
  check "First-boot script is executable"

  grep -q "cargo build" "$ROOT/etc/xnav/first_boot.sh"
  check "First-boot script compiles Rust binary"

  grep -q "xnav-vision.service" "$ROOT/etc/xnav/first_boot.sh"
  check "First-boot script starts XNav service"
fi

# Check systemd service
log "Checking systemd service..."
[ -f "$ROOT/etc/systemd/system/xnav-vision.service" ]
check "File xnav-vision.service exists"

grep -q "After=network-online.target" "$ROOT/etc/systemd/system/xnav-vision.service"
check "Vision service waits for network"

grep -q "ExecStart=/opt/xnav/bin/xnav" "$ROOT/etc/systemd/system/xnav-vision.service"
check "Service runs Rust binary"

# Dashboard is integrated; ensure no duplicate XNAV_DISABLE_DASHBOARD
! grep -q "XNAV_DISABLE_DASHBOARD" "$ROOT/etc/systemd/system/xnav-vision.service"
check "Dashboard is integrated (XNAV_DISABLE_DASHBOARD not set)"

# Check service symlink
log "Checking service symlinks..."
[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-vision.service" ]
check "xnav-vision.service is enabled"

# Check hostname
log "Checking hostname configuration..."
[ -f "$ROOT/etc/hostname" ]
check "File /etc/hostname exists"

grep -q "^xnav$" "$ROOT/etc/hostname"
check "Hostname is set to 'xnav'"

grep -q "xnav" "$ROOT/etc/hosts"
check "Hostname entry in /etc/hosts"

# Check boot config
log "Checking boot configuration..."
[ -f "$WORK_DIR/mnt/boot/config.txt" ]
check "File config.txt exists"

grep -q "start_x=1" "$WORK_DIR/mnt/boot/config.txt"
check "Camera enabled in config.txt"

grep -q "disable_camera_led=1" "$WORK_DIR/mnt/boot/config.txt"
check "Camera LED disabled"

# Check network config
log "Checking network configuration..."
if [ -f "$ROOT/etc/network/interfaces.d/eth0" ]; then
  grep -q "iface eth0 inet dhcp" "$ROOT/etc/network/interfaces.d/eth0"
  check "Network config uses DHCP"
else
  echo "  ⚠ Network config file not found (will use system default)"
fi

# Cleanup
log ""
log "Unmounting..."
sync
umount "$WORK_DIR/mnt/boot"
umount "$WORK_DIR/mnt/root"
losetup -d "$LOOP"
rm -rf "$WORK_DIR"

log ""
log "================================"
log "✓ All checks passed!"
log "  Image is ready for flashing"
log "================================"

