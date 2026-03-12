#!/bin/bash
# XNav ISO Verification Script (v1.2.0 — C++ edition)
# Checks that the built image contains all required components.
#
# Usage: sudo bash verify_iso.sh [/path/to/xnav-1.2.0.img.xz]

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash verify_iso.sh"
  exit 1
fi

IMG_FILE="${1:-/tmp/xnav-build/xnav-1.2.0.img.xz}"

if [ ! -f "$IMG_FILE" ]; then
  echo "ERROR: Image file not found: $IMG_FILE"
  echo "Usage: sudo bash verify_iso.sh [image.img.xz]"
  exit 1
fi

log()   { echo "[VERIFY] $*"; }
pass()  { echo "  ✓ $1"; }
fail()  { echo "  ✗ $1  FAILED"; FAILURES=$(( FAILURES + 1 )); }
check() {
  if [ $? -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

FAILURES=0

log "Verifying XNav ISO: $IMG_FILE"
log "================================================"

# Decompress to a temporary location
WORK_DIR="/tmp/xnav-verify-$$"
mkdir -p "$WORK_DIR"
trap "umount '$WORK_DIR/mnt/boot' 2>/dev/null; umount '$WORK_DIR/mnt/root' 2>/dev/null; losetup -d \"\$LOOP\" 2>/dev/null; rm -rf '$WORK_DIR'" EXIT

log "Decompressing image..."
xz -d -k -T0 -c "$IMG_FILE" > "$WORK_DIR/xnav.img"
check "Decompressed image"

log "Mounting partitions..."
mkdir -p "$WORK_DIR/mnt/boot" "$WORK_DIR/mnt/root"
LOOP=$(losetup -fP --show "$WORK_DIR/xnav.img")
mount "${LOOP}p1" "$WORK_DIR/mnt/boot"
mount "${LOOP}p2" "$WORK_DIR/mnt/root"
check "Mounted partitions"

ROOT="$WORK_DIR/mnt/root"
BOOT="$WORK_DIR/mnt/boot"

# ── XNav binary ──────────────────────────────────────────────────────────────
log "Checking XNav binary..."
[ -f "$ROOT/opt/xnav/bin/xnav" ]
check "Binary /opt/xnav/bin/xnav exists"

[ -x "$ROOT/opt/xnav/bin/xnav" ]
check "Binary /opt/xnav/bin/xnav is executable"

file "$ROOT/opt/xnav/bin/xnav" | grep -q "aarch64\|ARM aarch64\|ELF 64-bit"
check "Binary is ARM64 (aarch64) ELF"

# ── Web dashboard ─────────────────────────────────────────────────────────────
log "Checking web dashboard..."
[ -d "$ROOT/opt/xnav/web_dashboard" ]
check "Directory /opt/xnav/web_dashboard exists"

[ -d "$ROOT/opt/xnav/web_dashboard/templates" ]
check "Web dashboard templates directory exists"

[ -f "$ROOT/opt/xnav/web_dashboard/templates/index.html" ]
check "Web dashboard index.html exists"

# ── Configuration ─────────────────────────────────────────────────────────────
log "Checking configuration..."
[ -f "$ROOT/etc/xnav/config.json" ]
check "File /etc/xnav/config.json exists"

# ── Systemd services ──────────────────────────────────────────────────────────
log "Checking systemd services..."
[ -f "$ROOT/etc/systemd/system/xnav-vision.service" ]
check "File xnav-vision.service exists"

[ -f "$ROOT/etc/systemd/system/xnav-firstboot.service" ]
check "File xnav-firstboot.service exists"

[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-vision.service" ]
check "xnav-vision.service is enabled (symlink present)"

[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-firstboot.service" ]
check "xnav-firstboot.service is enabled (symlink present)"

# ── Ethernet driver ───────────────────────────────────────────────────────────
log "Checking Realtek RTL8153B ethernet driver..."
[ -f "$ROOT/etc/udev/rules.d/70-limelight-ethernet.rules" ]
check "Udev rule 70-limelight-ethernet.rules exists"

grep -q "eth0" "$ROOT/etc/udev/rules.d/70-limelight-ethernet.rules"
check "Udev rule names adapter 'eth0'"

[ -f "$ROOT/etc/modules-load.d/usb-ethernet.conf" ]
check "modules-load.d/usb-ethernet.conf exists"

grep -q "r8152" "$ROOT/etc/modules-load.d/usb-ethernet.conf"
check "r8152 module is set to auto-load"

# firmware-realtek should be installed in the image
find "$ROOT/lib/firmware" -name "rtl8153*" 2>/dev/null | grep -q . \
  || find "$ROOT/usr/lib/firmware" -name "rtl*" 2>/dev/null | grep -q .
check "Realtek firmware files present in image"

# ── Network config ────────────────────────────────────────────────────────────
log "Checking network configuration..."
[ -f "$ROOT/etc/network/interfaces.d/eth0" ]
check "Network config file eth0 exists"

grep -q "iface eth0 inet dhcp" "$ROOT/etc/network/interfaces.d/eth0"
check "eth0 configured for DHCP"

# ── SSH ───────────────────────────────────────────────────────────────────────
log "Checking SSH..."
[ -f "$BOOT/ssh" ]
check "SSH enabled (ssh file in boot partition)"

# ── Hostname ──────────────────────────────────────────────────────────────────
log "Checking hostname..."
grep -q "^xnav$" "$ROOT/etc/hostname"
check "Hostname is 'xnav'"

grep -q "xnav" "$ROOT/etc/hosts"
check "Hostname entry in /etc/hosts"

# ── Boot config ───────────────────────────────────────────────────────────────
log "Checking boot configuration..."
grep -q "start_x=1" "$BOOT/config.txt"
check "Camera enabled (start_x=1)"

grep -q "disable_camera_led=1" "$BOOT/config.txt"
check "Camera LED disabled"

grep -q "usbcore.autosuspend=-1" "$BOOT/config.txt"
check "USB autosuspend disabled (keeps ethernet active)"

# ── First-boot script ─────────────────────────────────────────────────────────
log "Checking first-boot script..."
[ -f "$ROOT/opt/xnav/firstboot.sh" ]
check "First-boot script /opt/xnav/firstboot.sh exists"

[ -x "$ROOT/opt/xnav/firstboot.sh" ]
check "First-boot script is executable"

grep -q "r8152" "$ROOT/opt/xnav/firstboot.sh"
check "First-boot script loads r8152 module"

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "================================================"
if [ "$FAILURES" -eq 0 ]; then
  log "✓ All checks passed — image is ready for flashing"
else
  log "✗ $FAILURES check(s) FAILED — review output above"
  exit 1
fi
