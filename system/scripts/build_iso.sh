#!/bin/bash
# XNav ISO Builder
# Creates a flashable Raspberry Pi OS image with XNav pre-installed.
# Requirements: pi-gen or a Linux system with loop device support.
#
# Usage: sudo bash build_iso.sh
# Output: xnav-<version>.img.xz

set -e

XNAV_VERSION="1.2.0"
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

# Increase image size by 512 MB — just enough for XNav source files.
# Python packages are NOT pre-installed in the image; they are downloaded
# and installed by xnav-firstboot.service on the device's first boot.
truncate -s +512M "$OUTPUT_IMG"
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
BOOT="$WORK_DIR/mnt/boot"
mkdir -p "$ROOT/opt/xnav"
mkdir -p "$ROOT/etc/xnav"

cp -r "$REPO_ROOT/vision_core" "$ROOT/opt/xnav/"
cp -r "$REPO_ROOT/web_dashboard" "$ROOT/opt/xnav/"
cp "$REPO_ROOT/system/config/default_config.json" "$ROOT/etc/xnav/config.json"
cp "$REPO_ROOT/system/services/xnav-vision.service" "$ROOT/etc/systemd/system/"
cp "$REPO_ROOT/system/services/xnav-dashboard.service" "$ROOT/etc/systemd/system/"

# ── Limelight 3 Ethernet Driver Setup (outside chroot) ────────────────────────
# These files ensure the Realtek RTL8153 USB ethernet works on boot even if
# the QEMU chroot step is skipped (e.g., cross-platform builds).
log "Installing Limelight 3 ethernet driver config..."

# udev rule: name the Realtek USB adapter "eth0"
mkdir -p "$ROOT/etc/udev/rules.d"
cp "$REPO_ROOT/system/config/70-limelight-ethernet.rules" "$ROOT/etc/udev/rules.d/"

# Module loading: ensure r8152 loads on every boot
mkdir -p "$ROOT/etc/modules-load.d"
echo "r8152" > "$ROOT/etc/modules-load.d/usb-ethernet.conf"

# Copy network setup helper script
cp "$REPO_ROOT/system/scripts/setup_network.sh" "$ROOT/opt/xnav/"
chmod +x "$ROOT/opt/xnav/setup_network.sh"

# ── Root partition expansion (first boot) ─────────────────────────────────────
# The image is shrunk to minimum size for fast flashing.  On first boot, the
# root partition must be expanded to fill the target disk.  init_resize.sh from
# the base RPi OS image handles this in most cases, but we also install our own
# backup service for devices (e.g., eMMC via rpiboot) where init_resize.sh may
# not run.
log "Installing root partition expansion service..."
cp "$REPO_ROOT/system/scripts/expand_rootfs.sh" "$ROOT/etc/xnav/expand_rootfs.sh"
chmod +x "$ROOT/etc/xnav/expand_rootfs.sh"
cp "$REPO_ROOT/system/services/xnav-expand-rootfs.service" "$ROOT/etc/systemd/system/"
ln -sf /etc/systemd/system/xnav-expand-rootfs.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-expand-rootfs.service" 2>/dev/null || true

# Ensure init_resize.sh is referenced in cmdline.txt (belt-and-suspenders)
CMDLINE="$BOOT/cmdline.txt"
if [ -f "$CMDLINE" ]; then
  if ! grep -q "init_resize" "$CMDLINE"; then
    log "Adding init_resize.sh to cmdline.txt..."
    # cmdline.txt is a single line; append the init= parameter
    printf ' init=/usr/lib/raspi-config/init_resize.sh' >> "$CMDLINE"
  else
    log "init_resize.sh already in cmdline.txt"
  fi
else
  log "WARN: cmdline.txt not found in boot partition"
fi

# ── Enable SSH ────────────────────────────────────────────────────────────────
# RPi OS disables SSH by default.  An empty file named "ssh" on the boot
# partition tells the init system to enable and start the SSH server.
log "Enabling SSH..."
touch "$BOOT/ssh"

# Also enable the SSH service directly via symlink so it persists
mkdir -p "$ROOT/etc/systemd/system/sshd.service.wants" \
         "$ROOT/etc/systemd/system/multi-user.target.wants"
# ssh.service is the canonical name on RPi OS
for SVC in ssh sshd; do
  SVC_FILE="$ROOT/lib/systemd/system/${SVC}.service"
  if [ -f "$SVC_FILE" ]; then
    ln -sf "$SVC_FILE" \
      "$ROOT/etc/systemd/system/multi-user.target.wants/${SVC}.service" 2>/dev/null || true
    log "  Enabled ${SVC}.service"
  fi
done

# ── Create default user account ──────────────────────────────────────────────
# RPi OS Bookworm removed the default 'pi' user.  userconf.txt on the boot
# partition creates a user on first boot.  Format: username:password-hash
# Default credentials: pi / raspberry
log "Creating default user account (pi/raspberry)..."
log "  ⚠ IMPORTANT: Change the default password after first login!"
# Generate the password hash for 'raspberry'
PASS_HASH='$6$rBoByrWRKMY1EHFy$k3LnTRpQ0OhJsNDwjMy3VjXcRbZ.r5xR.aRIwTnnr7FRvBcbns7x7KpSKLJzrdMG8E9chlVLXDgLo0T4tEYAL/'
echo "pi:${PASS_HASH}" > "$BOOT/userconf.txt"

# ── Download web dashboard vendor files for offline use ───────────────────────
log "Downloading web dashboard vendor files for offline use..."
VENDOR_DIR="$ROOT/opt/xnav/web_dashboard/static/vendor"
mkdir -p "$VENDOR_DIR"
curl -sL "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" \
  -o "$VENDOR_DIR/bootstrap.min.css" 2>/dev/null || log "WARN: Could not download bootstrap.min.css"
curl -sL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" \
  -o "$VENDOR_DIR/bootstrap-icons.min.css" 2>/dev/null || log "WARN: Could not download bootstrap-icons.min.css"
curl -sL "https://cdn.jsdelivr.net/npm/socket.io@4.7.4/client-dist/socket.io.min.js" \
  -o "$VENDOR_DIR/socket.io.min.js" 2>/dev/null || log "WARN: Could not download socket.io.min.js"

# ── Inject xnav-firstboot.service ────────────────────────────────────────────
# A systemd oneshot service that runs ONCE on the device's first boot to
# install Python packages from the internet.  On every subsequent boot,
# systemd detects /opt/xnav/venv already exists (ConditionPathExists check)
# and skips the unit instantly — so xnav services start without any delay.
log "Injecting xnav-firstboot.service..."
cp "$REPO_ROOT/system/services/xnav-firstboot.service" "$ROOT/etc/systemd/system/"

# Enable services via symlinks
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/xnav-firstboot.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-firstboot.service" 2>/dev/null || true
ln -sf /etc/systemd/system/xnav-vision.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-vision.service" 2>/dev/null || true
ln -sf /etc/systemd/system/xnav-dashboard.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-dashboard.service" 2>/dev/null || true

# Create first-boot install script (invoked by xnav-firstboot.service)
cat > "$ROOT/etc/xnav/first_boot.sh" << 'FIRSTBOOT'
#!/bin/bash
# Runs ONCE on first boot (via xnav-firstboot.service) to install Python
# packages from the internet.  Subsequent boots skip this entirely because
# xnav-firstboot.service has ConditionPathExists=!/opt/xnav/venv.
#
# If this script fails partway through, the partially-created venv is cleaned
# up so the service can try again on the next reboot.

FIRSTBOOT_LOG="/var/log/xnav-firstboot.log"
exec > >(tee -a "$FIRSTBOOT_LOG") 2>&1

echo "========================================="
echo "XNav First-Boot Setup - $(date)"
echo "========================================="

# Clean up partial venv from a previous failed attempt
if [ -d /opt/xnav/venv ] && [ ! -f /opt/xnav/venv/.xnav-firstboot-ok ]; then
  echo "Cleaning up partial venv from previous failed attempt..."
  rm -rf /opt/xnav/venv
fi

# Trap: if the script exits with an error, remove the partial venv so the
# ConditionPathExists guard allows the service to retry on the next boot.
cleanup_on_failure() {
  if [ ! -f /opt/xnav/venv/.xnav-firstboot-ok ]; then
    echo "ERROR: First-boot setup failed — cleaning up partial venv for retry."
    rm -rf /opt/xnav/venv
  fi
}
trap cleanup_on_failure EXIT

set -e

# ── Ensure Limelight 3 ethernet is up ───────────────────────────────────────
echo "Bringing up eth0 (RTL8153 USB ethernet)..."
modprobe r8152 2>/dev/null || true
ip link set eth0 up 2>/dev/null || true

# Kick DHCP client in case NetworkManager hasn't acquired a lease yet
if command -v dhcpcd &>/dev/null; then
  dhcpcd -n eth0 2>/dev/null || true
elif command -v dhclient &>/dev/null; then
  dhclient eth0 2>/dev/null || true
fi

echo "Waiting for eth0 to get a DHCP address (up to 90 s)..."
for i in $(seq 1 45); do
  if ip addr show eth0 2>/dev/null | grep -q "inet "; then
    echo "eth0 is up: $(ip -4 addr show eth0 | grep inet | awk '{print $2}')"
    break
  fi
  sleep 2
done

if ! ip addr show eth0 2>/dev/null | grep -q "inet "; then
  echo "WARN: eth0 has no IP address after 90 s. Proceeding anyway."
fi

# ── Wait for internet connectivity ──────────────────────────────────────────
echo "Waiting for internet connectivity (up to 90 s)..."
for i in $(seq 1 45); do
  if ping -c1 -W3 8.8.8.8 &>/dev/null || ping -c1 -W3 1.1.1.1 &>/dev/null; then
    echo "Internet reachable."
    break
  fi
  sleep 2
done

if ! ping -c1 -W3 8.8.8.8 &>/dev/null && ! ping -c1 -W3 1.1.1.1 &>/dev/null; then
  echo "ERROR: No internet connectivity after 90 s."
  echo "Connect the device to a router with internet access and reboot."
  exit 1
fi

# ── Install system packages ──────────────────────────────────────────────────
echo "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Ethernet firmware (improves RTL8153B stability on some units)
apt-get install -y --no-install-recommends firmware-realtek

# Install cloud-guest-utils for growpart (used by rootfs expansion service)
apt-get install -y --no-install-recommends cloud-guest-utils 2>/dev/null || true

# Python packages via apt — avoids bundling large pip wheels in the image.
# python3-opencv (~4.6 from RPi OS Bookworm) covers all cv2 usage.
apt-get install -y --no-install-recommends \
  python3-opencv \
  python3-numpy \
  python3-rpi.gpio \
  python3-venv \
  python3-pip \
  avahi-daemon

# Remove apt cache to keep the device disk usage low
apt-get clean
rm -rf /var/lib/apt/lists/*

# ── Create Python venv ───────────────────────────────────────────────────────
echo "Creating Python virtual environment..."
# --system-site-packages lets the venv reuse the apt-installed cv2/numpy/RPi.GPIO
# so we only pip-install the smaller packages below.
python3 -m venv --system-site-packages /opt/xnav/venv
/opt/xnav/venv/bin/pip install --upgrade pip -q

# ── Install pip-only packages ────────────────────────────────────────────────
echo "Installing pip packages (dt-apriltags, pyntcore, flask, flask-socketio)..."
/opt/xnav/venv/bin/pip install \
  --prefer-binary \
  -r /opt/xnav/vision_core/requirements-pip.txt

# ── Cache web dashboard vendor files for offline intranet use ────────────────
echo "Caching web dashboard vendor files..."
VENDOR_DIR="/opt/xnav/web_dashboard/static/vendor"
mkdir -p "$VENDOR_DIR"
curl -sL "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" \
  -o "$VENDOR_DIR/bootstrap.min.css" || true
curl -sL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" \
  -o "$VENDOR_DIR/bootstrap-icons.min.css" || true
curl -sL "https://cdn.jsdelivr.net/npm/socket.io@4.7.4/client-dist/socket.io.min.js" \
  -o "$VENDOR_DIR/socket.io.min.js" || true

# Mark first-boot as fully complete — prevents cleanup_on_failure from removing
# the venv if the script exits successfully.
touch /opt/xnav/venv/.xnav-firstboot-ok

echo "========================================="
echo "First-boot setup complete! - $(date)"
echo "Dashboard: http://xnav.local:5800"
echo "========================================="
FIRSTBOOT
chmod +x "$ROOT/etc/xnav/first_boot.sh"

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

# Network configuration - ensure DHCP works regardless of network manager
mkdir -p "$ROOT/etc/network/interfaces.d"
NETWORK_CFG="$ROOT/etc/network/interfaces.d/eth0"
cat > "$NETWORK_CFG" << 'NETEOF'
# XNav Network Configuration - eth0 gets IP via DHCP from robot
auto eth0
iface eth0 inet dhcp
NETEOF

# Also configure dhcpcd (used by some RPi OS variants)
if [ -f "$ROOT/etc/dhcpcd.conf" ]; then
  if ! grep -q "interface eth0" "$ROOT/etc/dhcpcd.conf"; then
    cat >> "$ROOT/etc/dhcpcd.conf" << 'DHCPCD'

# XNav: ensure DHCP on eth0
interface eth0
  # Use DHCP (default behaviour, but be explicit)
DHCPCD
  fi
fi

# Create a NetworkManager connection profile for eth0 (used by RPi OS Bookworm)
NM_CONN_DIR="$ROOT/etc/NetworkManager/system-connections"
mkdir -p "$NM_CONN_DIR"
cat > "$NM_CONN_DIR/eth0.nmconnection" << 'NMCONN'
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
NMCONN
chmod 600 "$NM_CONN_DIR/eth0.nmconnection"

# Enable avahi-daemon for mDNS (.local hostname resolution)
if [ -f "$ROOT/lib/systemd/system/avahi-daemon.service" ]; then
  ln -sf /lib/systemd/system/avahi-daemon.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/avahi-daemon.service" 2>/dev/null || true
fi

# ── Shrink filesystem & cleanup ───────────────────────────────────────────────
log "Unmounting filesystems..."
sync
umount "$WORK_DIR/mnt/boot"
umount "$WORK_DIR/mnt/root"

# Shrink the root filesystem to its minimum size.
# This eliminates the large block of empty space added by truncate,
# which would otherwise slow eMMC flashing to a crawl (the 91% stall).
log "Shrinking root filesystem to minimum size..."
e2fsck -fy "${LOOP}p2"; EC=$?; [ $EC -le 2 ] || { log "ERROR: e2fsck returned $EC (filesystem has errors)"; losetup -d "$LOOP"; exit 1; }
resize2fs -M "${LOOP}p2"

# Read the resulting filesystem size
TUNE2FS_OUT=$(tune2fs -l "${LOOP}p2" 2>/dev/null)
FS_BLOCKS=$(echo "$TUNE2FS_OUT" | grep "^Block count:" | awk '{print $NF}')
FS_BLOCK_SZ=$(echo "$TUNE2FS_OUT" | grep "^Block size:" | awk '{print $NF}')
if [ -z "$FS_BLOCKS" ] || [ -z "$FS_BLOCK_SZ" ]; then
  log "ERROR: Could not read filesystem size from tune2fs"
  losetup -d "$LOOP"
  exit 1
fi
FS_BYTES=$(( FS_BLOCKS * FS_BLOCK_SZ ))
log "Root filesystem: $((FS_BYTES / 1024 / 1024)) MiB"

losetup -d "$LOOP"

# Shrink the partition to match the filesystem (2 MiB alignment buffer)
NEW_PART_END=$(( ROOT_OFFSET + FS_BYTES + 2 * 1024 * 1024 ))
echo "Yes" | parted ---pretend-input-tty "$OUTPUT_IMG" resizepart 2 ${NEW_PART_END}B

# Truncate the image file to remove the now-unused trailing space (1 MiB tail)
NEW_IMG_SIZE=$(( NEW_PART_END + 1 * 1024 * 1024 ))
truncate -s "$NEW_IMG_SIZE" "$OUTPUT_IMG"
log "Image size after shrink: $((NEW_IMG_SIZE / 1024 / 1024)) MiB"

# Compress — level 3 gives a good size/speed balance (level 9 takes 10x longer).
log "Compressing image..."
xz -v -T0 -3 "$OUTPUT_IMG"

log "═══════════════════════════════════════════"
log "  Build complete: ${OUTPUT_IMG}.xz"
log "  Flash with: rpi-imager or"
log "    xzcat ${OUTPUT_IMG}.xz | sudo dd of=/dev/sdX bs=4M status=progress"
log "═══════════════════════════════════════════"
