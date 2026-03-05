#!/bin/bash
# XNav Setup Script
# Run as root on a Raspberry Pi CM (Raspberry Pi OS Lite 64-bit)
# Installs the XNav Rust binary and systemd service.
#
# Usage: sudo bash setup.sh
#
# The script will:
#   1. Install OpenCV system libraries and camera dependencies
#   2. Build the Rust binary natively (requires ~20-40 min on first run)
#   3. Deploy the binary, config, and systemd service

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
  libcamera-apps libcamera-dev \
  libopencv-dev libopencv-core-dev libopencv-videoio-dev \
  libopencv-objdetect-dev libopencv-calib3d-dev \
  libopencv-imgproc-dev libopencv-imgcodecs-dev \
  v4l-utils \
  pigpio \
  curl build-essential pkg-config \
  libclang-dev clang \
  2>&1 | tail -5

# ── Enable camera & GPU ──────────────────────────────────────────────────────
log "Enabling camera interface..."
BOOT_CFG=""
for f in /boot/config.txt /boot/firmware/config.txt; do
  [ -f "$f" ] && BOOT_CFG="$f" && break
done
if [ -n "$BOOT_CFG" ]; then
  grep -q "^start_x=1" "$BOOT_CFG" || echo "start_x=1" >> "$BOOT_CFG"
  grep -q "^gpu_mem=128" "$BOOT_CFG" || echo "gpu_mem=128" >> "$BOOT_CFG"
  grep -q "disable_camera_led=1" "$BOOT_CFG" || echo "disable_camera_led=1" >> "$BOOT_CFG"
fi

# ── Install XNav directories ─────────────────────────────────────────────────
log "Creating XNav directories..."
mkdir -p "$XNAV_DIR/bin"
mkdir -p "$XNAV_CFG"
mkdir -p /var/log

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Install default config
if [ ! -f "$XNAV_CFG/config.json" ]; then
  cp "$REPO_ROOT/system/config/default_config.json" "$XNAV_CFG/config.json"
  log "Installed default config"
fi

# ── Build Rust binary ────────────────────────────────────────────────────────

# Check for a pre-built binary first
PREBUILT_BINARY="$REPO_ROOT/vision_core_rs/dist/xnav-aarch64"
if [ -f "$PREBUILT_BINARY" ] && [ -x "$PREBUILT_BINARY" ]; then
  log "Installing pre-built binary from dist/..."
  cp "$PREBUILT_BINARY" "$XNAV_DIR/bin/xnav"
  chmod +x "$XNAV_DIR/bin/xnav"
else
  log "No pre-built binary found — building from source..."

  # Install Rust toolchain (if not already present)
  if ! command -v cargo &>/dev/null; then
    log "Installing Rust toolchain (this may take a few minutes)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --no-modify-path
    export PATH="${HOME}/.cargo/bin:$PATH"
  fi
  source "${HOME}/.cargo/env" 2>/dev/null || true
  export PATH="${HOME}/.cargo/bin:$PATH"

  log "Building XNav Rust binary (this takes ~20-40 minutes)..."
  log "  Output will be logged to $LOG_FILE"
  (cd "$REPO_ROOT/vision_core_rs" && cargo build --release 2>&1 | tee -a "$LOG_FILE")

  cp "$REPO_ROOT/vision_core_rs/target/release/xnav" "$XNAV_DIR/bin/xnav"
  chmod +x "$XNAV_DIR/bin/xnav"

  log "XNav binary built successfully!"
  log "  Size: $(du -sh "$XNAV_DIR/bin/xnav" | cut -f1)"

  # Optional: remove Rust toolchain to save ~1 GB of disk space
  echo ""
  echo "  Remove Rust build toolchain (~1 GB)? (y/N)"
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    log "Removing Rust toolchain to save disk space..."
    "${HOME}/.cargo/bin/rustup" self uninstall -y 2>/dev/null || true
    apt-get remove -y -qq libclang-dev clang build-essential 2>/dev/null || true
    apt-get autoremove -y -qq 2>/dev/null || true
    log "Rust toolchain removed."
  fi
fi

# ── Install systemd service ───────────────────────────────────────────────────
log "Installing systemd service..."
cp "$REPO_ROOT/system/services/xnav-vision.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable xnav-vision.service

# ── Hostname ─────────────────────────────────────────────────────────────────
log "Setting hostname to 'xnav'..."
hostnamectl set-hostname xnav
grep -q "127.0.1.1.*xnav" /etc/hosts || echo "127.0.1.1    xnav" >> /etc/hosts

# ── Permissions ─────────────────────────────────────────────────────────────
chmod -R 755 "$XNAV_DIR"
chmod 644 "$XNAV_CFG/config.json"

log "═══════════════════════════════════════════"
log "  Installation complete!"
log "  Binary: $XNAV_DIR/bin/xnav"
log "  Config: $XNAV_CFG/config.json"
log "  Dashboard: http://xnav.local:5800"
log "  Reboot to start service."
log "═══════════════════════════════════════════"
echo
echo "  Reboot now? (y/N)"
read -r ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  reboot
fi

