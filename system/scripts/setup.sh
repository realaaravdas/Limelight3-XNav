#!/bin/bash
# XNav Setup Script (C++ edition)
# Run as root on a Raspberry Pi CM (Raspberry Pi OS Lite 64-bit)
# Usage: sudo bash setup.sh

set -e

XNAV_DIR="/opt/xnav"
XNAV_CFG="/etc/xnav"
LOG_FILE="/var/log/xnav-setup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash setup.sh"
  exit 1
fi

log "═══════════════════════════════════════════"
log "  XNav Vision System - Installation (C++)"
log "═══════════════════════════════════════════"

# ── System dependencies ──────────────────────────────────────────────────────
log "Updating package lists..."
apt-get update -qq

log "Installing runtime libraries..."
apt-get install -y -qq \
  libopencv-core-dev libopencv-imgproc-dev libopencv-videoio-dev \
  libopencv-calib3d-dev libopencv-imgcodecs-dev \
  libapriltag-dev libgpiod-dev \
  v4l-utils curl git \
  2>&1 | tail -5

log "Installing build tools (will remove after compile)..."
apt-get install -y -qq cmake g++ pkg-config 2>&1 | tail -3

# ── Enable camera ─────────────────────────────────────────────────────────────
log "Enabling camera interface..."
BOOTCFG="/boot/config.txt"
[ -f "/boot/firmware/config.txt" ] && BOOTCFG="/boot/firmware/config.txt"
grep -q "^start_x=1" "$BOOTCFG" 2>/dev/null || echo "start_x=1" >> "$BOOTCFG"
grep -q "^gpu_mem=128" "$BOOTCFG" 2>/dev/null || echo "gpu_mem=128" >> "$BOOTCFG"
grep -q "^disable_camera_led=1" "$BOOTCFG" 2>/dev/null || echo "disable_camera_led=1" >> "$BOOTCFG"

# ── Install XNav ─────────────────────────────────────────────────────────────
log "Installing XNav to $XNAV_DIR..."
mkdir -p "$XNAV_DIR"
mkdir -p "$XNAV_DIR/bin"
mkdir -p "$XNAV_CFG"
mkdir -p /var/log

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cp -r "$REPO_ROOT/web_dashboard" "$XNAV_DIR/"
cp -r "$REPO_ROOT/vision_core_cpp" "$XNAV_DIR/"

# Install default config
if [ ! -f "$XNAV_CFG/config.json" ]; then
  cp "$REPO_ROOT/system/config/default_config.json" "$XNAV_CFG/config.json"
  log "Installed default config"
fi

# ── Compile C++ binary ───────────────────────────────────────────────────────
log "Compiling XNav C++ binary..."
mkdir -p "$XNAV_DIR/vision_core_cpp/build"
cd "$XNAV_DIR/vision_core_cpp/build"
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$XNAV_DIR"
make -j4
make install
log "Binary installed: $(ls -lh $XNAV_DIR/bin/xnav)"

# Remove build source and tools to save space
log "Removing build tools..."
apt-get remove --purge -y cmake g++ pkg-config 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
cd /
rm -rf "$XNAV_DIR/vision_core_cpp"

# ── systemd service ──────────────────────────────────────────────────────────
log "Installing systemd service..."
cp "$REPO_ROOT/system/services/xnav-vision.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable xnav-vision.service

# ── Hostname ─────────────────────────────────────────────────────────────────
log "Setting hostname to 'xnav'..."
hostnamectl set-hostname xnav 2>/dev/null || echo "xnav" > /etc/hostname
grep -q "127.0.1.1.*xnav" /etc/hosts || echo "127.0.1.1    xnav" >> /etc/hosts

# ── Permissions ─────────────────────────────────────────────────────────────
chmod 644 "$XNAV_CFG/config.json"

log "═══════════════════════════════════════════"
log "  Installation complete!"
log "  Dashboard: http://xnav.local:5800"
log "  Reboot to start services."
log "═══════════════════════════════════════════"
echo
echo -n "  Reboot now? (y/N) "
read -r ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  reboot
fi
