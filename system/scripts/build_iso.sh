#!/bin/bash
# XNav ISO Builder
# Creates a flashable Raspberry Pi OS image with XNav pre-installed.
# Requirements: pi-gen or a Linux system with loop device support.
#
# Usage: sudo bash build_iso.sh
# Output: xnav-<version>.img.xz

set -e

XNAV_VERSION="1.1.0"
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

# Increase image size by 3GB for XNav (extra space for venv)
truncate -s +3G "$OUTPUT_IMG"
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

# ── Prepare Python environment offline ─────────────────────────────────────────
log "Preparing Python packages for offline installation..."

# Build a temporary venv on the host to download packages
TEMP_VENV=$(mktemp -d)
python3 -m venv "$TEMP_VENV"
source "$TEMP_VENV/bin/activate"

log "Downloading Python packages (this may take a while)..."
pip install --upgrade pip -q
pip download -r "$REPO_ROOT/vision_core/requirements.txt" --dest "$TEMP_VENV/wheels" --prefer-binary

deactivate

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

# Copy pre-downloaded wheels
log "Copying pre-downloaded Python wheels..."
mkdir -p "$ROOT/opt/xnav/wheels"
cp "$TEMP_VENV"/wheels/*.whl "$ROOT/opt/xnav/wheels/"

# Enable services via symlinks
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/xnav-vision.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-vision.service" 2>/dev/null || true
ln -sf /etc/systemd/system/xnav-dashboard.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-dashboard.service" 2>/dev/null || true

# Create first-boot install script (uses pre-downloaded wheels)
cat > "$ROOT/etc/xnav/first_boot.sh" << 'FIRSTBOOT'
#!/bin/bash
# Runs once on first boot to complete installation (OFFLINE MODE)
set -e

# Log file
FIRSTBOOT_LOG="/var/log/xnav-firstboot.log"
exec > >(tee -a "$FIRSTBOOT_LOG") 2>&1

echo "========================================="
echo "XNav First-Boot Setup - $(date)"
echo "========================================="

cd /opt/xnav

# Create virtual environment
echo "Creating Python virtual environment..."
python3 -m venv venv
source venv/bin/activate

# Install Python packages from pre-downloaded wheels (OFFLINE)
echo "Installing Python packages from pre-bundled wheels..."
pip install --upgrade pip -q
pip install --no-index --find-links=/opt/xnav/wheels -r /opt/xnav/vision_core/requirements.txt

# Update service files to use venv
echo "Updating systemd service files..."
sed -i "s|/usr/bin/python3|/opt/xnav/venv/bin/python3|g" \
  /etc/systemd/system/xnav-vision.service \
  /etc/systemd/system/xnav-dashboard.service

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

# Enable services
echo "Enabling XNav services..."
systemctl enable xnav-vision.service
systemctl enable xnav-dashboard.service

# Stop services if already running (from initial boot)
systemctl stop xnav-vision.service 2>/dev/null || true
systemctl stop xnav-dashboard.service 2>/dev/null || true

# Start services
echo "Starting XNav services..."
systemctl start xnav-vision.service
sleep 2
systemctl start xnav-dashboard.service

# Check service status
echo ""
echo "Service Status:"
echo "==============="
systemctl status xnav-vision.service --no-pager || true
echo ""
systemctl status xnav-dashboard.service --no-pager || true
echo ""

# Mark done
echo "First-boot setup complete! (Offline mode)"
echo "Dashboard: http://xnav.local:5800"
echo "========================================="
rm -f /etc/xnav/first_boot.sh
FIRSTBOOT
chmod +x "$ROOT/etc/xnav/first_boot.sh"

# rc.local: run first boot if needed
RCLOCAL="$ROOT/etc/rc.local"
if [ -f "$RCLOCAL" ]; then
  # Remove old first_boot call if exists
  sed -i '/first_boot.sh/d' "$RCLOCAL"
  # Add new first_boot call before exit 0
  sed -i '/^exit 0/i [ -f /etc/xnav/first_boot.sh ] \&\& bash /etc/xnav/first_boot.sh &' "$RCLOCAL"
else
  # Create rc.local if it doesn't exist
  cat > "$RCLOCAL" << 'RCEOF'
#!/bin/bash
# rc.local - local startup script

# Run XNav first-boot setup if needed
[ -f /etc/xnav/first_boot.sh ] && bash /etc/xnav/first_boot.sh &

exit 0
RCEOF
  chmod +x "$RCLOCAL"
fi

# Enable rc-local service
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/rc-local.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/rc-local.service"

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

# Network configuration - use DHCP for eth0
mkdir -p "$ROOT/etc/network/interfaces.d"
NETWORK_CFG="$ROOT/etc/network/interfaces.d/eth0"
cat > "$NETWORK_CFG" << 'NETEOF'
# XNav Network Configuration - eth0 gets IP via DHCP from robot
auto eth0
iface eth0 inet dhcp
NETEOF

# Clean up temporary venv
rm -rf "$TEMP_VENV"

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
