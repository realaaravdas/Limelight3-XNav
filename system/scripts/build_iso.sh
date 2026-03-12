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

# Increase image size by 2GB for XNav (space for apt packages, wheels and code files)
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

# ── Prepare Python environment offline ─────────────────────────────────────────
log "Preparing Python packages for offline installation..."

# Build a temporary venv on the host to download packages
TEMP_VENV=$(mktemp -d)
python3 -m venv "$TEMP_VENV"
source "$TEMP_VENV/bin/activate"

log "Downloading Python packages for ARM64 (this may take a while)..."
pip install --upgrade pip -q

# Detect host architecture and request correct platform wheels
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]; then
  # Native ARM64 build machine - pip downloads correct architecture automatically
  pip download \
    -r "$REPO_ROOT/vision_core/requirements.txt" \
    --dest "$TEMP_VENV/wheels" \
    --prefer-binary
else
  # Cross-platform build (e.g., x86_64 host) - explicitly request ARM64 wheels
  log "Cross-platform build detected ($HOST_ARCH -> aarch64), requesting ARM64 wheels..."
  pip download \
    -r "$REPO_ROOT/vision_core/requirements.txt" \
    --dest "$TEMP_VENV/wheels" \
    --prefer-binary \
    --platform manylinux_2_17_aarch64 \
    --platform manylinux_2_28_aarch64 \
    --platform manylinux_2_31_aarch64 \
    --platform linux_aarch64 \
    --python-version 311 \
    --only-binary :all: || {
      log "WARN: Could not download all ARM64 binary wheels, retrying without platform restriction..."
      rm -f "$TEMP_VENV/wheels"/*.whl 2>/dev/null || true
      pip download \
        -r "$REPO_ROOT/vision_core/requirements.txt" \
        --dest "$TEMP_VENV/wheels" \
        --prefer-binary
    }
fi

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

# ── Pre-install Python packages via QEMU chroot (immediate boot support) ─────
# If qemu-aarch64-static is available, install packages now so the device
# can start services immediately on first boot without any pip step.
CHROOT_INSTALLED=false
QEMU_BINARY=""
for q in /usr/bin/qemu-aarch64-static /usr/local/bin/qemu-aarch64-static; do
  [ -f "$q" ] && QEMU_BINARY="$q" && break
done

if [ -z "$QEMU_BINARY" ] && command -v apt-get &>/dev/null; then
  log "Installing qemu-user-static for ARM64 chroot support..."
  apt-get install -y -qq qemu-user-static 2>&1 | tail -3 || log "WARN: qemu-user-static installation failed"
  [ -f "/usr/bin/qemu-aarch64-static" ] && QEMU_BINARY="/usr/bin/qemu-aarch64-static"
elif [ -z "$QEMU_BINARY" ]; then
  log "WARN: apt-get not available, cannot install qemu-user-static"
fi

if [ -n "$QEMU_BINARY" ]; then
  log "Pre-installing Python packages in ARM64 chroot (no first-boot install needed)..."
  cp "$QEMU_BINARY" "$ROOT/usr/bin/qemu-aarch64-static"

  # Provide DNS resolution so apt-get can download packages inside the chroot
  cp /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true

  # Mount essential filesystems for chroot
  mount --bind /proc    "$ROOT/proc"    2>/dev/null || true
  mount --bind /sys     "$ROOT/sys"     2>/dev/null || true
  mount --bind /dev     "$ROOT/dev"     2>/dev/null || true
  mount --bind /dev/pts "$ROOT/dev/pts" 2>/dev/null || true

  chroot "$ROOT" /bin/bash -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    # ── Limelight 3 Ethernet Driver ──────────────────────────────────────
    # The Limelight 3 uses a Realtek RTL8153B USB Gigabit Ethernet adapter.
    # The r8152 kernel module handles it; firmware-realtek provides firmware.
    apt-get install -y --no-install-recommends firmware-realtek usbutils

    # Ensure r8152 module loads on every boot
    mkdir -p /etc/modules-load.d
    echo "r8152" > /etc/modules-load.d/usb-ethernet.conf

    # ── Python packages ──────────────────────────────────────────────────
    # Install large packages via apt to avoid bundling their wheels in the image.
    # python3-opencv (~4.6 from RPi OS Bookworm) covers all cv2 usage in the codebase.
    apt-get install -y --no-install-recommends python3-opencv python3-numpy python3-rpi.gpio

    # ── Cleanup to reduce image size ─────────────────────────────────────
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
    rm -rf /usr/share/locale/[a-d]* /usr/share/locale/[f-z]* 2>/dev/null || true
    rm -rf /var/cache/apt/archives/* /tmp/*
    find /usr/lib/python3* -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find /usr/lib/python3* -name "tests" -prune -exec rm -rf {} + 2>/dev/null || true

    # Create venv with access to system-installed packages (cv2, numpy, RPi.GPIO).
    # Only the smaller pip-only packages are then installed from bundled wheels.
    python3 -m venv --system-site-packages /opt/xnav/venv
    /opt/xnav/venv/bin/pip install --upgrade pip -q
    /opt/xnav/venv/bin/pip install \
      --no-index --find-links=/opt/xnav/wheels \
      -r /opt/xnav/vision_core/requirements-pip.txt -q || \
    /opt/xnav/venv/bin/pip install \
      --find-links=/opt/xnav/wheels \
      --prefer-binary \
      -r /opt/xnav/vision_core/requirements-pip.txt -q
  ' && CHROOT_INSTALLED=true || {
    log "WARN: QEMU chroot install failed (check ARM64 wheel compatibility), will use first-boot install"
  }

  # Unmount filesystems
  for mnt in "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/sys" "$ROOT/proc"; do
    umount "$mnt" 2>/dev/null || true
  done
  rm -f "$ROOT/usr/bin/qemu-aarch64-static"
  # Remove the host resolv.conf that was copied in for apt access; it must not
  # persist into the final image (the device manages its own DNS at runtime).
  rm -f "$ROOT/etc/resolv.conf"

  if $CHROOT_INSTALLED; then
    log "Python packages pre-installed - services will start immediately on boot"
    # Point service files at the pre-installed venv and remove the wait-for-firstboot delays
    sed -i \
      -e "s|ExecStart=/usr/bin/python3|ExecStart=/opt/xnav/venv/bin/python3|g" \
      -e "/ExecStartPre=\/bin\/sleep/d" \
      "$ROOT/etc/systemd/system/xnav-vision.service" \
      "$ROOT/etc/systemd/system/xnav-dashboard.service"
    # Remove bundled wheel cache — all packages are pre-installed in the venv.
    # opencv, numpy, and RPi.GPIO came from apt; pip-only packages from wheels.
    # The venv is fully functional offline; removing wheels reclaims ~150-200 MiB.
    rm -rf "$ROOT/opt/xnav/wheels"
    log "Wheel cache removed: all packages pre-installed (offline boot still works)"
  fi
else
  log "qemu-aarch64-static not available - packages will be installed from bundled wheels on first boot"
fi

# Enable services via symlinks
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/xnav-vision.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-vision.service" 2>/dev/null || true
ln -sf /etc/systemd/system/xnav-dashboard.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-dashboard.service" 2>/dev/null || true

# Create first-boot install script (uses pre-downloaded wheels, skips if venv pre-installed)
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

# ── Limelight 3 Ethernet Driver ─────────────────────────────────────────
echo "Ensuring Limelight 3 ethernet driver is loaded..."
modprobe r8152 2>/dev/null || true

# If eth0 has no IP, try to bring it up
if ! ip addr show eth0 2>/dev/null | grep -q "inet "; then
  echo "Bringing up eth0..."
  ip link set eth0 up 2>/dev/null || true
  dhcpcd eth0 2>/dev/null || dhclient eth0 2>/dev/null || true
  sleep 3
fi

# If we have internet, install firmware-realtek (needed for some RTL8153 variants)
if ping -c1 -W3 8.8.8.8 &>/dev/null; then
  echo "Internet available - installing Realtek firmware..."
  apt-get update -qq 2>/dev/null
  apt-get install -y --no-install-recommends firmware-realtek 2>/dev/null | tail -2
  apt-get clean 2>/dev/null
  rm -rf /var/lib/apt/lists/* 2>/dev/null

  # Cache web dashboard vendor files for offline use
  echo "Downloading web dashboard vendor files for offline use..."
  VENDOR_DIR="/opt/xnav/web_dashboard/static/vendor"
  mkdir -p "$VENDOR_DIR"
  curl -sL "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" \
    -o "$VENDOR_DIR/bootstrap.min.css" 2>/dev/null || true
  curl -sL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" \
    -o "$VENDOR_DIR/bootstrap-icons.min.css" 2>/dev/null || true
  curl -sL "https://cdn.jsdelivr.net/npm/socket.io@4.7.4/client-dist/socket.io.min.js" \
    -o "$VENDOR_DIR/socket.io.min.js" 2>/dev/null || true
fi

# Check if Python packages were already pre-installed during ISO build
if [ -f /opt/xnav/venv/bin/python3 ]; then
  echo "Python venv pre-installed - skipping package installation"
else
  # Install Python packages from pre-downloaded wheels (OFFLINE, no internet needed)
  echo "Creating Python virtual environment..."
  python3 -m venv venv

  echo "Installing Python packages from pre-bundled wheels (offline)..."
  venv/bin/pip install --upgrade pip -q
  venv/bin/pip install --no-index --find-links=/opt/xnav/wheels \
    -r /opt/xnav/vision_core/requirements.txt -q

  # Update service files to use venv Python
  echo "Updating systemd service files..."
  sed -i "s|/usr/bin/python3|/opt/xnav/venv/bin/python3|g" \
    /etc/systemd/system/xnav-vision.service \
    /etc/systemd/system/xnav-dashboard.service

  # Reload systemd
  echo "Reloading systemd..."
  systemctl daemon-reload
fi

# Enable services
echo "Enabling XNav services..."
systemctl enable xnav-vision.service 2>/dev/null || true
systemctl enable xnav-dashboard.service 2>/dev/null || true

# Restart services (or start if not running yet)
echo "Starting XNav services..."
systemctl restart xnav-vision.service || systemctl start xnav-vision.service || true
sleep 2
systemctl restart xnav-dashboard.service || systemctl start xnav-dashboard.service || true

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
parted "$OUTPUT_IMG" -s resizepart 2 ${NEW_PART_END}B

# Truncate the image file to remove the now-unused trailing space (1 MiB tail)
NEW_IMG_SIZE=$(( NEW_PART_END + 1 * 1024 * 1024 ))
truncate -s "$NEW_IMG_SIZE" "$OUTPUT_IMG"
log "Image size after shrink: $((NEW_IMG_SIZE / 1024 / 1024)) MiB"

# Compress
log "Compressing image..."
xz -v -T0 -9 "$OUTPUT_IMG"

log "═══════════════════════════════════════════"
log "  Build complete: ${OUTPUT_IMG}.xz"
log "  Flash with: rpi-imager or"
log "    xzcat ${OUTPUT_IMG}.xz | sudo dd of=/dev/sdX bs=4M status=progress"
log "═══════════════════════════════════════════"
