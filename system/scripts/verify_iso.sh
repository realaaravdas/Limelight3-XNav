#!/bin/bash
# XNav ISO Verification Script
# Checks that the built image has all necessary components
#
# Usage: sudo bash verify_iso.sh [image-file.img.xz]

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash verify_iso.sh"
  exit 1
fi

IMG_FILE="${1:-xnav-1.2.0.img.xz}"

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

[ -d "$ROOT/opt/xnav/vision_core" ]
check "Directory /opt/xnav/vision_core exists"

[ -d "$ROOT/opt/xnav/web_dashboard" ]
check "Directory /opt/xnav/web_dashboard exists"

[ -d "$ROOT/etc/xnav" ]
check "Directory /etc/xnav exists"

# Check critical files
log "Checking critical files..."
[ -f "$ROOT/opt/xnav/vision_core/src/main.py" ]
check "File main.py exists"

[ -f "$ROOT/opt/xnav/web_dashboard/app.py" ]
check "File app.py exists"

[ -f "$ROOT/opt/xnav/vision_core/requirements.txt" ]
check "File requirements.txt exists"

[ -f "$ROOT/etc/xnav/config.json" ]
check "File config.json exists"

# Check first-boot script
log "Checking first-boot setup..."
[ -f "$ROOT/etc/xnav/first_boot.sh" ]
check "File first_boot.sh exists"

[ -x "$ROOT/etc/xnav/first_boot.sh" ]
check "File first_boot.sh is executable"

# Venv may be pre-installed during build (QEMU chroot) or installed on first boot
if [ -f "$ROOT/opt/xnav/venv/bin/python3" ]; then
  echo "  ✓ Python venv pre-installed in image (immediate boot support)"
  # When venv is pre-installed, service files should already point to it
  grep -q "/opt/xnav/venv/bin/python3" "$ROOT/etc/systemd/system/xnav-vision.service"
  check "Vision service uses pre-installed venv Python"
else
  echo "  ✓ Python venv will be installed from bundled wheels on first boot"
  grep -q "python3 -m venv\|pip install --no-index" "$ROOT/etc/xnav/first_boot.sh"
  check "First-boot script installs packages from bundled wheels"
fi

grep -q "systemctl start xnav-dashboard.service\|systemctl restart xnav-dashboard.service\|xnav-firstboot-ok" "$ROOT/etc/xnav/first_boot.sh"
check "First-boot script has completion marker"

# Check pre-downloaded wheels for offline installation
log "Checking offline package wheelhouse..."
[ -d "$ROOT/opt/xnav/wheels" ]
check "Wheels directory /opt/xnav/wheels exists"

WHEEL_COUNT=$(ls -1 "$ROOT/opt/xnav/wheels"/*.whl 2>/dev/null | wc -l)
[ "$WHEEL_COUNT" -gt 0 ]
check "Wheels directory contains wheel files ($WHEEL_COUNT wheels)"

# Check systemd services
log "Checking systemd services..."
[ -f "$ROOT/etc/systemd/system/xnav-vision.service" ]
check "File xnav-vision.service exists"

[ -f "$ROOT/etc/systemd/system/xnav-dashboard.service" ]
check "File xnav-dashboard.service exists"

grep -q "After=network-online.target" "$ROOT/etc/systemd/system/xnav-vision.service"
check "Vision service waits for network"

grep -q "After=network-online.target" "$ROOT/etc/systemd/system/xnav-dashboard.service"
check "Dashboard service waits for network"

grep -q "XNAV_DISABLE_DASHBOARD=1" "$ROOT/etc/systemd/system/xnav-vision.service"
check "Vision service disables dashboard subprocess"

# Check service symlinks
log "Checking service symlinks..."
[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-vision.service" ]
check "xnav-vision.service is enabled"

[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-dashboard.service" ]
check "xnav-dashboard.service is enabled"

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

# Check SSH enablement
log "Checking SSH configuration..."
[ -f "$WORK_DIR/mnt/boot/ssh" ]
check "SSH marker file exists in boot partition"

# Check user configuration
log "Checking user configuration..."
[ -f "$WORK_DIR/mnt/boot/userconf.txt" ]
check "userconf.txt exists in boot partition"

grep -q "^pi:" "$WORK_DIR/mnt/boot/userconf.txt"
check "Default 'pi' user configured"

# Check root partition expansion service
log "Checking root partition expansion..."
[ -f "$ROOT/etc/xnav/expand_rootfs.sh" ]
check "Root expansion script exists"

[ -x "$ROOT/etc/xnav/expand_rootfs.sh" ]
check "Root expansion script is executable"

[ -f "$ROOT/etc/systemd/system/xnav-expand-rootfs.service" ]
check "xnav-expand-rootfs.service exists"

[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-expand-rootfs.service" ]
check "xnav-expand-rootfs.service is enabled"

# Check that init_resize.sh is in cmdline.txt
if [ -f "$WORK_DIR/mnt/boot/cmdline.txt" ]; then
  grep -q "init_resize\.sh" "$WORK_DIR/mnt/boot/cmdline.txt"
  check "cmdline.txt has init_resize.sh"
else
  echo "  ⚠ cmdline.txt not found in boot partition"
fi

# Check rc.local
log "Checking rc.local..."
if [ -f "$ROOT/etc/rc.local" ]; then
  grep -q "first_boot.sh" "$ROOT/etc/rc.local"
  check "rc.local calls first_boot.sh"
else
  echo "  ⚠ File /etc/rc.local does not exist (will be created)"
fi

# Check network config
log "Checking network configuration..."
if [ -f "$ROOT/etc/network/interfaces.d/eth0" ]; then
  grep -q "iface eth0 inet dhcp" "$ROOT/etc/network/interfaces.d/eth0"
  check "ifupdown network config uses DHCP"
else
  echo "  ⚠ ifupdown network config file not found (will use system default)"
fi

# Check NetworkManager configuration
if [ -f "$ROOT/etc/NetworkManager/system-connections/eth0.nmconnection" ]; then
  grep -q "method=auto" "$ROOT/etc/NetworkManager/system-connections/eth0.nmconnection"
  check "NetworkManager eth0 profile uses DHCP (auto)"
else
  echo "  ⚠ NetworkManager connection profile not found"
fi

# Check Limelight 3 ethernet driver config
log "Checking Limelight 3 ethernet driver..."
if [ -f "$ROOT/etc/udev/rules.d/70-limelight-ethernet.rules" ]; then
  grep -q "r8152" "$ROOT/etc/udev/rules.d/70-limelight-ethernet.rules"
  check "udev rule for Realtek USB ethernet"
else
  echo "  ⚠ Limelight 3 udev rule not found"
fi

if [ -f "$ROOT/etc/modules-load.d/usb-ethernet.conf" ]; then
  grep -q "r8152" "$ROOT/etc/modules-load.d/usb-ethernet.conf"
  check "r8152 module auto-load configured"
else
  echo "  ⚠ r8152 module auto-load not configured"
fi

# Check for common Python dependencies
log "Checking Python dependencies..."
grep -q "flask" "$ROOT/opt/xnav/vision_core/requirements.txt"
check "Flask in requirements"

grep -q "flask-socketio" "$ROOT/opt/xnav/vision_core/requirements.txt"
check "Flask-SocketIO in requirements"

grep -q "opencv-python-headless" "$ROOT/opt/xnav/vision_core/requirements.txt"
check "OpenCV in requirements"

grep -q "pupil-apriltags" "$ROOT/opt/xnav/vision_core/requirements.txt"
check "pupil-apriltags in requirements"

grep -q "pyntcore" "$ROOT/opt/xnav/vision_core/requirements.txt"
check "pyntcore in requirements"

# Check web dashboard files
log "Checking web dashboard files..."
[ -d "$ROOT/opt/xnav/web_dashboard/templates" ]
check "Web dashboard templates directory exists"

[ -f "$ROOT/opt/xnav/web_dashboard/templates/index.html" ]
check "Web dashboard index.html exists"

[ -d "$ROOT/opt/xnav/web_dashboard/static" ]
check "Web dashboard static directory exists"

[ -f "$ROOT/opt/xnav/web_dashboard/static/css/style.css" ]
check "Web dashboard CSS exists"

[ -f "$ROOT/opt/xnav/web_dashboard/static/js/app.js" ]
check "Web dashboard JavaScript exists"

# Check for logger definition in app.py
grep -q "logger = logging.getLogger" "$ROOT/opt/xnav/web_dashboard/app.py"
check "Logger defined in app.py"

# Check vision core modules
log "Checking vision core modules..."
[ -f "$ROOT/opt/xnav/vision_core/src/config_manager.py" ]
check "Module config_manager.py exists"

[ -f "$ROOT/opt/xnav/vision_core/src/camera_manager.py" ]
check "Module camera_manager.py exists"

[ -f "$ROOT/opt/xnav/vision_core/src/apriltag_detector.py" ]
check "Module apriltag_detector.py exists"

[ -f "$ROOT/opt/xnav/vision_core/src/pose_calculator.py" ]
check "Module pose_calculator.py exists"

[ -f "$ROOT/opt/xnav/vision_core/src/nt_publisher.py" ]
check "Module nt_publisher.py exists"

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
