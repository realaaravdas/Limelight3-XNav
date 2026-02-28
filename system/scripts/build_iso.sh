#!/bin/bash
# XNav ISO Builder
# Creates a flashable Raspberry Pi OS image with XNav pre-installed.
# Requirements: pi-gen or a Linux system with loop device support.
#
# Usage: sudo bash build_iso.sh
# Output: xnav-<version>.img.xz

set -e

XNAV_VERSION="1.0.0"
OUTPUT_IMG="xnav-${XNAV_VERSION}.img"
WORK_DIR="/tmp/xnav-build"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { echo "[BUILD] $*"; }

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash build_iso.sh"
  exit 1
fi

log "XNav ISO Builder v${XNAV_VERSION}"
log "Repo: $REPO_ROOT"

# ── Method 1: Using pi-gen ───────────────────────────────────────────────────
# pi-gen is the official Raspberry Pi OS build tool.

BUILD_USING_PIGEN=false

if command -v pi-gen &>/dev/null || [ -d "/opt/pi-gen" ]; then
  BUILD_USING_PIGEN=true
fi

# ── Method 2: Inject into existing image ─────────────────────────────────────
# Download official RPi OS Lite, mount, and inject XNav.

log "Using image injection method..."

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Base image URL (64-bit RPi OS Lite)
BASE_URL="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"
BASE_IMG="raspios_lite_arm64_latest.img.xz"

if [ ! -f "$BASE_IMG" ]; then
  log "Downloading base Raspberry Pi OS Lite (64-bit)..."
  if command -v curl &>/dev/null; then
    curl -L --fail -o "$BASE_IMG" "$BASE_URL" || {
      log "ERROR: Download failed. Please download manually:"
      log "  URL: $BASE_URL"
      log "  Save to: $WORK_DIR/$BASE_IMG"
      exit 1
    }
  else
    log "ERROR: curl not found. Please download manually:"
    log "  URL: $BASE_URL"
    log "  Save to: $WORK_DIR/$BASE_IMG"
    exit 1
  fi
fi

# Decompress
if [ -f "$BASE_IMG" ] && [ ! -f "raspios_lite.img" ]; then
  log "Decompressing image..."
  xz -dk "$BASE_IMG"
  mv raspios_lite_arm64_latest.img raspios_lite.img 2>/dev/null || true
fi

if [ ! -f "raspios_lite.img" ]; then
  log "ERROR: No base image found. Please download RPi OS Lite to $WORK_DIR/raspios_lite.img"
  exit 1
fi

cp raspios_lite.img "$OUTPUT_IMG"

# Find partitions
BOOT_OFFSET=$(parted "$OUTPUT_IMG" -s unit B print | awk '/^ 1/{print $2}' | tr -d B)
ROOT_OFFSET=$(parted "$OUTPUT_IMG" -s unit B print | awk '/^ 2/{print $2}' | tr -d B)

log "Boot partition offset: $BOOT_OFFSET"
log "Root partition offset: $ROOT_OFFSET"

# Increase image size by 2GB for XNav
truncate -s +2G "$OUTPUT_IMG"
parted "$OUTPUT_IMG" -s resizepart 2 100%

# Mount partitions
mkdir -p "$WORK_DIR/mnt/boot" "$WORK_DIR/mnt/root"
LOOP=$(losetup -fP --show "$OUTPUT_IMG")
log "Loop device: $LOOP"

mount "${LOOP}p1" "$WORK_DIR/mnt/boot"
mount "${LOOP}p2" "$WORK_DIR/mnt/root"

# Resize root filesystem
e2fsck -f "${LOOP}p2" || true
resize2fs "${LOOP}p2"

# ── Inject XNav files ────────────────────────────────────────────────────────
log "Injecting XNav files..."

ROOT="$WORK_DIR/mnt/root"
mkdir -p "$ROOT/opt/xnav"
mkdir -p "$ROOT/etc/xnav"

cp -r "$REPO_ROOT/vision_core" "$ROOT/opt/xnav/"
cp -r "$REPO_ROOT/web_dashboard" "$ROOT/opt/xnav/"
cp "$REPO_ROOT/system/config/default_config.json" "$ROOT/etc/xnav/config.json"
cp "$REPO_ROOT/system/services/xnav-vision.service" "$ROOT/etc/systemd/system/"
cp "$REPO_ROOT/system/services/xnav-dashboard.service" "$ROOT/etc/systemd/system/"

# Enable services via symlinks
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/xnav-vision.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-vision.service" 2>/dev/null || true
ln -sf /etc/systemd/system/xnav-dashboard.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-dashboard.service" 2>/dev/null || true

# Create first-boot install script
cat > "$ROOT/etc/xnav/first_boot.sh" << 'FIRSTBOOT'
#!/bin/bash
# Runs once on first boot to complete installation
set -e
cd /opt/xnav
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
pip install -r /opt/xnav/vision_core/requirements.txt
deactivate
# Mark done
rm -f /etc/xnav/first_boot.sh
FIRSTBOOT
chmod +x "$ROOT/etc/xnav/first_boot.sh"

# rc.local: run first boot if needed
RCLOCAL="$ROOT/etc/rc.local"
if [ -f "$RCLOCAL" ]; then
  sed -i '/^exit 0/i [ -f /etc/xnav/first_boot.sh ] \&\& bash /etc/xnav/first_boot.sh' "$RCLOCAL"
fi

# Set hostname
echo "xnav" > "$ROOT/etc/hostname"
echo "127.0.1.1    xnav" >> "$ROOT/etc/hosts"

# Boot config
BOOTCFG="$WORK_DIR/mnt/boot/config.txt"
cat >> "$BOOTCFG" << 'BOOTEOF'
# XNav Configuration
start_x=1
gpu_mem=128
disable_camera_led=1
BOOTEOF

# ── Cleanup ───────────────────────────────────────────────────────────────────
log "Unmounting..."
sync
umount "$WORK_DIR/mnt/boot"
umount "$WORK_DIR/mnt/root"
losetup -d "$LOOP"

# Compress
log "Compressing image..."
xz -v -T0 -9 "$OUTPUT_IMG"

log "═══════════════════════════════════════════"
log "  Build complete: ${OUTPUT_IMG}.xz"
log "  Flash with: rpi-imager or"
log "    xzcat ${OUTPUT_IMG}.xz | sudo dd of=/dev/sdX bs=4M status=progress"
log "═══════════════════════════════════════════"
