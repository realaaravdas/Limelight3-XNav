#!/bin/bash
# XNav Colab ISO Builder (C++ edition)
# Creates a flashable Raspberry Pi OS image with XNav pre-installed.
# This script uses guestfish (libguestfs-tools) instead of losetup/mount,
# making it compatible with Google Colab and other containerised environments
# that lack kernel module loading or loop device support.
#
# Usage: bash colab_build.sh
# Output: xnav-<version>.img.xz
#
# Requirements on build machine:
#   apt-get install -y libguestfs-tools qemu-utils parted e2fsprogs \
#       xz-utils curl git

set -euo pipefail

XNAV_VERSION="1.1.0"
OUTPUT_IMG="xnav-${XNAV_VERSION}.img"
WORK_DIR="/tmp/xnav-build"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { echo "[COLAB-BUILD] $*"; }
die() { log "ERROR: $*"; exit 1; }

log "XNav Colab ISO Builder v${XNAV_VERSION} (C++ edition)"
log "Repo: $REPO_ROOT"

# ── Install dependencies (non-interactive) ───────────────────────────────────
log "Installing required packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    libguestfs-tools \
    qemu-utils \
    parted \
    e2fsprogs \
    xz-utils \
    curl \
    git \
    linux-image-generic 2>/dev/null || true

# libguestfs needs a kernel to boot its appliance; point it to one
if [ -z "${SUPERMIN_KERNEL:-}" ]; then
  KERN=$(find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | sort -V | tail -1 || true)
  if [ -n "$KERN" ]; then
    export SUPERMIN_KERNEL="$KERN"
    KERN_VER=$(basename "$KERN" | sed 's/vmlinuz-//')
    export SUPERMIN_MODULES="/lib/modules/$KERN_VER"
  fi
fi

# Disable libguestfs KVM if running inside a container (Colab has no /dev/kvm)
if [ ! -e /dev/kvm ]; then
  export LIBGUESTFS_BACKEND_SETTINGS="force_tcg"
  export LIBGUESTFS_BACKEND="direct"
fi

# ── Download base image ──────────────────────────────────────────────────────
log "Preparing work directory..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

BASE_URL="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"
BASE_IMG="raspios_lite_arm64_latest.img.xz"

if [ ! -f "$BASE_IMG" ]; then
  log "Downloading base Raspberry Pi OS Lite (64-bit)..."
  curl -L --fail -o "$BASE_IMG" "$BASE_URL" || \
    die "Download failed. Please download the image manually to $WORK_DIR/$BASE_IMG"
fi

if [ -f "$BASE_IMG" ] && [ ! -f "raspios_lite.img" ]; then
  log "Decompressing image..."
  xz -dk "$BASE_IMG"
  mv raspios_lite_arm64_latest.img raspios_lite.img 2>/dev/null || true
fi

[ -f "raspios_lite.img" ] || die "No base image found."

cp raspios_lite.img "$OUTPUT_IMG"

# ── Expand image ─────────────────────────────────────────────────────────────
log "Expanding image by 512 MB..."
truncate -s +512M "$OUTPUT_IMG"
parted "$OUTPUT_IMG" -s resizepart 2 100%

# Resize the ext4 filesystem inside partition 2 to fill the new space.
# We use guestfish to run e2fsck + resize2fs without loop devices.
log "Resizing root filesystem..."
guestfish --rw -a "$OUTPUT_IMG" <<'GF_RESIZE'
run
e2fsck-f /dev/sda2
resize2fs /dev/sda2
GF_RESIZE

# ── Prepare staging area for files to inject ─────────────────────────────────
log "Preparing staging area..."
STAGE="$WORK_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/opt/xnav/bin"
mkdir -p "$STAGE/etc/xnav"
mkdir -p "$STAGE/etc/systemd/system/multi-user.target.wants"
mkdir -p "$STAGE/etc/network/interfaces.d"

# Copy web dashboard
cp -r "$REPO_ROOT/web_dashboard" "$STAGE/opt/xnav/"

# Copy C++ source (will be compiled on-device since we cannot QEMU-chroot here)
cp -r "$REPO_ROOT/vision_core_cpp" "$STAGE/opt/xnav/"

# Copy config and service files
cp "$REPO_ROOT/system/config/default_config.json" "$STAGE/etc/xnav/config.json"
cp "$REPO_ROOT/system/services/xnav-vision.service" "$STAGE/etc/systemd/system/"

# Create systemd enable symlink directory
ln -sf /etc/systemd/system/xnav-vision.service \
    "$STAGE/etc/systemd/system/multi-user.target.wants/xnav-vision.service"

# ── Download vendor web assets (Bootstrap + Icons) ───────────────────────────
log "Downloading Bootstrap vendor assets for offline web dashboard..."
VENDOR_DIR="$STAGE/opt/xnav/web_dashboard/static/vendor"
mkdir -p "$VENDOR_DIR/fonts"

curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" \
    -o "$VENDOR_DIR/bootstrap.min.css" || \
  log "WARN: Could not download bootstrap.min.css"

curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js" \
    -o "$VENDOR_DIR/bootstrap.bundle.min.js" || \
  log "WARN: Could not download bootstrap.bundle.min.js"

curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" \
    -o "$VENDOR_DIR/bootstrap-icons.min.css" || \
  log "WARN: Could not download bootstrap-icons.min.css"

curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/fonts/bootstrap-icons.woff2" \
    -o "$VENDOR_DIR/fonts/bootstrap-icons.woff2" || true
curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/fonts/bootstrap-icons.woff" \
    -o "$VENDOR_DIR/fonts/bootstrap-icons.woff" || true

# Fix bootstrap-icons.min.css font path to use local /static/vendor/fonts/
if [ -f "$VENDOR_DIR/bootstrap-icons.min.css" ]; then
  sed -i 's|url("./fonts/|url("/static/vendor/fonts/|g' "$VENDOR_DIR/bootstrap-icons.min.css"
fi

# ── Create on-device build script ────────────────────────────────────────────
# QEMU chroot is not feasible in Colab containers, so the C++ binary will be
# compiled on first boot (or manually via SSH).
cat > "$STAGE/opt/xnav/build_on_device.sh" << 'DEVBUILD'
#!/bin/bash
# Build XNav C++ binary on the Raspberry Pi device
set -e
echo "[XNav] Installing build tools..."
apt-get update
apt-get install -y libopencv-dev libapriltag-dev libgpiod-dev cmake g++ pkg-config
echo "[XNav] Compiling..."
mkdir -p /opt/xnav/vision_core_cpp/build
cd /opt/xnav/vision_core_cpp/build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/xnav
make -j4
make install
echo "[XNav] Removing build tools..."
apt-get remove --purge -y cmake g++ pkg-config
apt-get autoremove -y
apt-get clean
echo "[XNav] Restarting XNav service..."
systemctl restart xnav-vision.service
echo "[XNav] Build complete! XNav is running."
DEVBUILD
chmod +x "$STAGE/opt/xnav/build_on_device.sh"

# ── Create first-boot service that compiles on the Pi ────────────────────────
mkdir -p "$STAGE/etc/systemd/system"
cat > "$STAGE/etc/systemd/system/xnav-firstboot.service" << 'FBSVC'
[Unit]
Description=XNav First-Boot C++ Build
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/xnav/bin/xnav

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/xnav/build_on_device.sh
ExecStartPost=/bin/systemctl disable xnav-firstboot.service
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
FBSVC

ln -sf /etc/systemd/system/xnav-firstboot.service \
    "$STAGE/etc/systemd/system/multi-user.target.wants/xnav-firstboot.service"

# ── Create rc.local ──────────────────────────────────────────────────────────
cat > "$STAGE/etc/rc.local" << 'RCEOF'
#!/bin/bash
# XNav rc.local - services start via systemd
exit 0
RCEOF
chmod +x "$STAGE/etc/rc.local"

# ── Create network config ───────────────────────────────────────────────────
cat > "$STAGE/etc/network/interfaces.d/eth0" << 'NETEOF'
# XNav Network Configuration - eth0 gets IP via DHCP from robot
auto eth0
iface eth0 inet dhcp
NETEOF

# ── Inject everything into the image via guestfish ───────────────────────────
log "Injecting files into image via guestfish..."

# Build the guestfish command script.
# We use copy-in for directories and upload for single files, then fix
# ownership/permissions, hostname, hosts, and boot config.
if ! guestfish --rw -a "$OUTPUT_IMG" <<GF_INJECT
run

# ── Mount partitions ──────────────────────────────────────────────────────
mount /dev/sda2 /
mount /dev/sda1 /boot

# ── Create target directories ────────────────────────────────────────────
mkdir-p /opt/xnav/bin
mkdir-p /etc/xnav
mkdir-p /etc/systemd/system/multi-user.target.wants
mkdir-p /etc/network/interfaces.d

# ── Copy XNav application files ──────────────────────────────────────────
copy-in $STAGE/opt/xnav/web_dashboard /opt/xnav/
copy-in $STAGE/opt/xnav/vision_core_cpp /opt/xnav/
copy-in $STAGE/opt/xnav/build_on_device.sh /opt/xnav/

# ── Copy configuration ──────────────────────────────────────────────────
copy-in $STAGE/etc/xnav/config.json /etc/xnav/

# ── Copy systemd service files ───────────────────────────────────────────
copy-in $STAGE/etc/systemd/system/xnav-vision.service /etc/systemd/system/
copy-in $STAGE/etc/systemd/system/xnav-firstboot.service /etc/systemd/system/

# ── Enable services via symlinks ─────────────────────────────────────────
ln-sf /etc/systemd/system/xnav-vision.service /etc/systemd/system/multi-user.target.wants/xnav-vision.service
ln-sf /etc/systemd/system/xnav-firstboot.service /etc/systemd/system/multi-user.target.wants/xnav-firstboot.service

# ── Remove stale dashboard service (now built into xnav binary) ──────────
rm-f /etc/systemd/system/multi-user.target.wants/xnav-dashboard.service

# ── Copy network config ─────────────────────────────────────────────────
copy-in $STAGE/etc/network/interfaces.d/eth0 /etc/network/interfaces.d/

# ── Copy rc.local ────────────────────────────────────────────────────────
copy-in $STAGE/etc/rc.local /etc/
chmod 0755 /etc/rc.local

# ── Set hostname ─────────────────────────────────────────────────────────
write /etc/hostname "xnav\n"

# Patch /etc/hosts: append xnav entry
download /etc/hosts /tmp/xnav_hosts_tmp
! sed -i '/127.0.1.1/d' /tmp/xnav_hosts_tmp && echo '127.0.1.1    xnav' >> /tmp/xnav_hosts_tmp
upload /tmp/xnav_hosts_tmp /etc/hosts

# ── Boot configuration ──────────────────────────────────────────────────
download /boot/config.txt /tmp/xnav_bootcfg_tmp
! grep -v '# XNav' /tmp/xnav_bootcfg_tmp > /tmp/xnav_bootcfg_clean && printf '\n# XNav Configuration\nstart_x=1\ngpu_mem=128\ndisable_camera_led=1\n' >> /tmp/xnav_bootcfg_clean
upload /tmp/xnav_bootcfg_clean /boot/config.txt

# ── Set permissions ──────────────────────────────────────────────────────
chmod 0755 /opt/xnav/build_on_device.sh

# ── Unmount ──────────────────────────────────────────────────────────────
umount-all

GF_INJECT
then
  die "guestfish injection failed"
fi

log "File injection complete."

# ── Compress ─────────────────────────────────────────────────────────────────
log "Compressing image (this may take 10-20 minutes)..."
xz -v -T0 -9 "$OUTPUT_IMG"

log "═══════════════════════════════════════════"
log "  Build complete: $WORK_DIR/${OUTPUT_IMG}.xz"
log "  Flash with: rpi-imager or"
log "    xzcat ${OUTPUT_IMG}.xz | sudo dd of=/dev/sdX bs=4M status=progress"
log "═══════════════════════════════════════════"
log ""
log "NOTE: The C++ binary is NOT pre-compiled in this image."
log "      On first boot the device will compile it automatically"
log "      (requires internet). Alternatively, SSH in and run:"
log "        sudo bash /opt/xnav/build_on_device.sh"
