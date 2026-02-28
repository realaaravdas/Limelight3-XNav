#!/bin/bash
# XNav Setup Script
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
log "  XNav Vision System - Installation"
log "═══════════════════════════════════════════"

# ── System dependencies ──────────────────────────────────────────────────────
log "Updating package lists..."
apt-get update -qq

log "Installing system packages..."
apt-get install -y -qq \
  python3 python3-pip python3-venv python3-dev \
  libcamera-apps libcamera-dev \
  libatlas-base-dev \
  libhdf5-dev libhdf5-serial-dev \
  libgtk-3-0 \
  libavcodec-dev libavformat-dev libswscale-dev \
  libjpeg-dev libpng-dev libtiff-dev \
  v4l-utils \
  git curl \
  hostapd dhcpcd5 \
  pigpio \
  2>&1 | tail -5

# ── Enable camera & GPIO ─────────────────────────────────────────────────────
log "Enabling camera interface..."
if ! grep -q "^start_x=1" /boot/config.txt 2>/dev/null; then
  echo "start_x=1" >> /boot/config.txt
fi
if ! grep -q "^gpu_mem=128" /boot/config.txt 2>/dev/null; then
  echo "gpu_mem=128" >> /boot/config.txt
fi
# Disable camera LED (Limelight doesn't need it)
if ! grep -q "disable_camera_led=1" /boot/config.txt 2>/dev/null; then
  echo "disable_camera_led=1" >> /boot/config.txt
fi

# ── Performance tweaks ───────────────────────────────────────────────────────
log "Applying performance configuration..."

# CPU Governor
if [ -f /etc/rc.local ]; then
  grep -q "performance" /etc/rc.local || \
    sed -i '/^exit 0/i for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $governor; done' /etc/rc.local
fi

# GPU memory split for vision
cat > /boot/config.txt.xnav_perf << 'EOF'
# XNav performance settings
arm_freq=1800
gpu_freq=750
over_voltage=6
EOF

# ── Install XNav ─────────────────────────────────────────────────────────────
log "Installing XNav to $XNAV_DIR..."
mkdir -p "$XNAV_DIR"
mkdir -p "$XNAV_CFG"
mkdir -p /var/log

# Copy application files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cp -r "$REPO_ROOT/vision_core" "$XNAV_DIR/"
cp -r "$REPO_ROOT/web_dashboard" "$XNAV_DIR/"

# Install default config
if [ ! -f "$XNAV_CFG/config.json" ]; then
  cp "$REPO_ROOT/system/config/default_config.json" "$XNAV_CFG/config.json"
  log "Installed default config"
fi

# ── Python virtual environment ───────────────────────────────────────────────
log "Creating Python virtual environment..."
python3 -m venv "$XNAV_DIR/venv"
source "$XNAV_DIR/venv/bin/activate"

log "Installing Python packages (this may take a while)..."
pip install --upgrade pip -q
pip install -r "$XNAV_DIR/vision_core/requirements.txt" -q
deactivate

# Update service scripts to use venv (only the installed copies)
log "Installing systemd services..."
cp "$REPO_ROOT/system/services/xnav-vision.service" /etc/systemd/system/
cp "$REPO_ROOT/system/services/xnav-dashboard.service" /etc/systemd/system/

# Update installed service files to use the venv interpreter
sed -i "s|/usr/bin/python3|$XNAV_DIR/venv/bin/python3|g" \
  /etc/systemd/system/xnav-vision.service \
  /etc/systemd/system/xnav-dashboard.service

systemctl daemon-reload
systemctl enable xnav-vision.service
systemctl enable xnav-dashboard.service

# ── Hostname ─────────────────────────────────────────────────────────────────
log "Setting hostname to 'xnav'..."
hostnamectl set-hostname xnav
echo "127.0.1.1    xnav" >> /etc/hosts

# ── Permissions ─────────────────────────────────────────────────────────────
chmod -R 755 "$XNAV_DIR"
chmod 644 "$XNAV_CFG/config.json"

log "═══════════════════════════════════════════"
log "  Installation complete!"
log "  Dashboard: http://xnav.local:5800"
log "  Reboot to start services."
log "═══════════════════════════════════════════"
echo
echo "  Reboot now? (y/N)"
read -r ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  reboot
fi
