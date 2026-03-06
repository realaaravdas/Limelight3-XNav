#!/bin/bash
# XNav ISO Builder (C++ edition)
# Creates a flashable Raspberry Pi OS image with XNav pre-installed.
# The vision core is a single C++ binary — no Python, no pip, no wheels.
#
# Usage: sudo bash build_iso.sh
# Output: xnav-<version>.img.xz
#
# Requirements on build machine:
#   sudo apt-get install -y parted e2fsprogs xz-utils curl git util-linux \
#       cmake g++ pkg-config qemu-user-static binfmt-support \
#       libopencv-dev libapriltag-dev libgpiod-dev

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

log "XNav ISO Builder v${XNAV_VERSION} (C++ edition)"
log "Repo: $REPO_ROOT"

# ── Download base image ──────────────────────────────────────────────────────
log "Using image injection method..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

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

if [ -f "$BASE_IMG" ] && [ ! -f "raspios_lite.img" ]; then
  log "Decompressing image..."
  xz -dk "$BASE_IMG"
  mv raspios_lite_arm64_latest.img raspios_lite.img 2>/dev/null || true
fi

if [ ! -f "raspios_lite.img" ]; then
  log "ERROR: No base image found."
  exit 1
fi

cp raspios_lite.img "$OUTPUT_IMG"

# ── Partition offsets ────────────────────────────────────────────────────────
BOOT_OFFSET=$(parted "$OUTPUT_IMG" -s unit B print | awk '/^ 1/{print $2}' | tr -d B)
ROOT_OFFSET=$(parted "$OUTPUT_IMG" -s unit B print | awk '/^ 2/{print $2}' | tr -d B)
log "Boot partition offset: $BOOT_OFFSET"
log "Root partition offset: $ROOT_OFFSET"

# Expand by 512 MB — the C++ build is much smaller than the Python+wheels build
truncate -s +512M "$OUTPUT_IMG"
parted "$OUTPUT_IMG" -s resizepart 2 100%

# ── Mount partitions ─────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR/mnt/boot" "$WORK_DIR/mnt/root"
LOOP=$(losetup -fP --show "$OUTPUT_IMG")
log "Loop device: $LOOP"

mount "${LOOP}p1" "$WORK_DIR/mnt/boot"
mount "${LOOP}p2" "$WORK_DIR/mnt/root"

e2fsck -f "${LOOP}p2" || true
resize2fs "${LOOP}p2"

ROOT="$WORK_DIR/mnt/root"

# ── Inject XNav source files ─────────────────────────────────────────────────
log "Injecting XNav files..."
mkdir -p "$ROOT/opt/xnav"
mkdir -p "$ROOT/etc/xnav"
mkdir -p "$ROOT/opt/xnav/bin"

# Copy web dashboard (static HTML/CSS/JS served by the C++ binary)
cp -r "$REPO_ROOT/web_dashboard" "$ROOT/opt/xnav/"

# Copy C++ source for compilation in chroot
cp -r "$REPO_ROOT/vision_core_cpp" "$ROOT/opt/xnav/"

# Copy config and services
cp "$REPO_ROOT/system/config/default_config.json" "$ROOT/etc/xnav/config.json"
cp "$REPO_ROOT/system/services/xnav-vision.service" "$ROOT/etc/systemd/system/"

# ── Download vendor web assets (Bootstrap + Icons) ───────────────────────────
log "Downloading Bootstrap vendor assets for offline web dashboard..."
VENDOR_DIR="$ROOT/opt/xnav/web_dashboard/static/vendor"
mkdir -p "$VENDOR_DIR"

# Bootstrap CSS
curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" \
    -o "$VENDOR_DIR/bootstrap.min.css" || \
  log "WARN: Could not download bootstrap.min.css — dashboard will need internet on first browser open"

# Bootstrap JS
curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js" \
    -o "$VENDOR_DIR/bootstrap.bundle.min.js" || \
  log "WARN: Could not download bootstrap.bundle.min.js"

# Bootstrap Icons CSS
curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" \
    -o "$VENDOR_DIR/bootstrap-icons.min.css" || \
  log "WARN: Could not download bootstrap-icons.min.css"

# Bootstrap Icons fonts (woff2)
mkdir -p "$VENDOR_DIR/fonts"
curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/fonts/bootstrap-icons.woff2" \
    -o "$VENDOR_DIR/fonts/bootstrap-icons.woff2" || true
curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/fonts/bootstrap-icons.woff" \
    -o "$VENDOR_DIR/fonts/bootstrap-icons.woff" || true

# Fix bootstrap-icons.min.css font path to use local /static/vendor/fonts/
if [ -f "$VENDOR_DIR/bootstrap-icons.min.css" ]; then
  sed -i 's|url("./fonts/|url("/static/vendor/fonts/|g' "$VENDOR_DIR/bootstrap-icons.min.css"
fi

# ── QEMU chroot: install runtime libs + compile C++ binary ───────────────────
CHROOT_BUILT=false
QEMU_BINARY=""
for q in /usr/bin/qemu-aarch64-static /usr/local/bin/qemu-aarch64-static; do
  [ -f "$q" ] && QEMU_BINARY="$q" && break
done

if [ -z "$QEMU_BINARY" ] && command -v apt-get &>/dev/null; then
  log "Installing qemu-user-static..."
  apt-get install -y -qq qemu-user-static binfmt-support 2>&1 | tail -3 || true
  [ -f "/usr/bin/qemu-aarch64-static" ] && QEMU_BINARY="/usr/bin/qemu-aarch64-static"
fi

if [ -n "$QEMU_BINARY" ]; then
  log "Building C++ binary in ARM64 chroot (QEMU)..."
  cp "$QEMU_BINARY" "$ROOT/usr/bin/qemu-aarch64-static"

  # Mount essential filesystems for chroot
  mount --bind /proc    "$ROOT/proc"    2>/dev/null || true
  mount --bind /sys     "$ROOT/sys"     2>/dev/null || true
  mount --bind /dev     "$ROOT/dev"     2>/dev/null || true
  mount --bind /dev/pts "$ROOT/dev/pts" 2>/dev/null || true

  # Register binfmt so the kernel knows to use qemu for aarch64 binaries
  update-binfmts --enable qemu-aarch64 2>/dev/null || true

  chroot "$ROOT" /bin/bash -ec '
    export DEBIAN_FRONTEND=noninteractive

    # ── Install runtime libraries + build tools ─────────────────────────
    echo "Installing runtime libraries and build tools..."
    apt-get update -qq
    apt-get install -y -qq \
        libopencv-core-dev libopencv-imgproc-dev libopencv-videoio-dev \
        libopencv-calib3d-dev libopencv-imgcodecs-dev \
        libapriltag-dev libgpiod-dev \
        cmake g++ pkg-config

    # ── Compile xnav binary ────────────────────────────────────────────
    echo "Compiling XNav C++ binary..."
    mkdir -p /opt/xnav/vision_core_cpp/build
    cd /opt/xnav/vision_core_cpp/build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/xnav
    make -j4
    make install
    echo "Binary installed: $(ls -lh /opt/xnav/bin/xnav)"

    # ── Remove build tools to save space (keep runtime libs) ──────────
    echo "Removing build tools..."
    apt-get remove --purge -y cmake g++ pkg-config \
        libopencv-core-dev libopencv-imgproc-dev libopencv-videoio-dev \
        libopencv-calib3d-dev libopencv-imgcodecs-dev \
        libapriltag-dev libgpiod-dev 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    # Install only runtime libraries (much smaller)
    apt-get update -qq
    apt-get install -y -qq \
        libopencv-core406 libopencv-imgproc406 libopencv-videoio406 \
        libopencv-calib3d406 libopencv-imgcodecs406 \
        libapriltag3 libgpiod2
    apt-get clean
    rm -rf /var/lib/apt/lists/*
  ' && CHROOT_BUILT=true || {
    log "WARN: QEMU chroot build failed. Trying alternate package names..."

    chroot "$ROOT" /bin/bash -ec '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      # Bookworm uses t64 suffix for some packages
      apt-get install -y -qq \
          libopencv-core-dev libopencv-imgproc-dev libopencv-videoio-dev \
          libopencv-calib3d-dev libopencv-imgcodecs-dev \
          libapriltag-dev libgpiod-dev \
          cmake g++ pkg-config
      mkdir -p /opt/xnav/vision_core_cpp/build
      cd /opt/xnav/vision_core_cpp/build
      cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/xnav
      make -j4 && make install
      apt-get remove --purge -y cmake g++ pkg-config 2>/dev/null || true
      apt-get autoremove -y 2>/dev/null || true
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      apt-get update -qq
      apt-get install -y -qq \
          libapriltag3 libgpiod2 || true
      apt-get clean
      rm -rf /var/lib/apt/lists/*
    ' && CHROOT_BUILT=true || log "ERROR: C++ build in chroot failed"
  }

  # Unmount filesystems
  for mnt in "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/sys" "$ROOT/proc"; do
    umount "$mnt" 2>/dev/null || true
  done
  rm -f "$ROOT/usr/bin/qemu-aarch64-static"

  if $CHROOT_BUILT; then
    log "C++ binary built and installed: /opt/xnav/bin/xnav"
    # Remove build source to save image space
    rm -rf "$ROOT/opt/xnav/vision_core_cpp/build"
    # Optionally remove source (the binary is installed; source can be removed)
    rm -rf "$ROOT/opt/xnav/vision_core_cpp"
  fi
else
  log "WARN: qemu-aarch64-static not available."
  log "      C++ source is included in the image at /opt/xnav/vision_core_cpp"
  log "      Boot the device and run: sudo bash /opt/xnav/build_on_device.sh"
  # Create on-device build script as fallback
  cat > "$ROOT/opt/xnav/build_on_device.sh" << 'DEVBUILD'
#!/bin/bash
# Build XNav C++ binary on the Raspberry Pi device
set -e
apt-get update
apt-get install -y libopencv-dev libapriltag-dev libgpiod-dev cmake g++ pkg-config
mkdir -p /opt/xnav/vision_core_cpp/build
cd /opt/xnav/vision_core_cpp/build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/xnav
make -j4
make install
apt-get remove --purge -y cmake g++ pkg-config
apt-get autoremove -y
systemctl restart xnav-vision.service
echo "Build complete! XNav is running."
DEVBUILD
  chmod +x "$ROOT/opt/xnav/build_on_device.sh"
fi

# ── Enable service ───────────────────────────────────────────────────────────
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/xnav-vision.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-vision.service" 2>/dev/null || true

# Remove old dashboard service symlink (now built into xnav binary)
rm -f "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-dashboard.service"

# ── Set hostname ─────────────────────────────────────────────────────────────
echo "xnav" > "$ROOT/etc/hostname"
sed -i '/127.0.1.1/d' "$ROOT/etc/hosts"
echo "127.0.1.1    xnav" >> "$ROOT/etc/hosts"

# ── Boot config ──────────────────────────────────────────────────────────────
BOOTCFG="$WORK_DIR/mnt/boot/config.txt"
# Remove any existing XNav block before re-adding
grep -v "# XNav" "$BOOTCFG" > /tmp/config_clean.txt || true
mv /tmp/config_clean.txt "$BOOTCFG"
cat >> "$BOOTCFG" << 'BOOTEOF'
# XNav Configuration
start_x=1
gpu_mem=128
disable_camera_led=1
BOOTEOF

# ── Network configuration ────────────────────────────────────────────────────
mkdir -p "$ROOT/etc/network/interfaces.d"
cat > "$ROOT/etc/network/interfaces.d/eth0" << 'NETEOF'
# XNav Network Configuration - eth0 gets IP via DHCP from robot
auto eth0
iface eth0 inet dhcp
NETEOF

# ── rc.local: no first-boot needed for C++ (binary is already installed) ─────
RCLOCAL="$ROOT/etc/rc.local"
cat > "$RCLOCAL" << 'RCEOF'
#!/bin/bash
# XNav rc.local - services start via systemd
exit 0
RCEOF
chmod +x "$RCLOCAL"

# ── Shrink filesystem & cleanup ──────────────────────────────────────────────
log "Unmounting filesystems..."
sync
umount "$WORK_DIR/mnt/boot"
umount "$WORK_DIR/mnt/root"

log "Shrinking root filesystem to minimum size..."
e2fsck -fy "${LOOP}p2"; EC=$?; [ $EC -le 2 ] || { log "ERROR: e2fsck returned $EC"; losetup -d "$LOOP"; exit 1; }
resize2fs -M "${LOOP}p2"

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

NEW_PART_END=$(( ROOT_OFFSET + FS_BYTES + 2 * 1024 * 1024 ))
parted "$OUTPUT_IMG" -s resizepart 2 ${NEW_PART_END}B

NEW_IMG_SIZE=$(( NEW_PART_END + 1 * 1024 * 1024 ))
truncate -s "$NEW_IMG_SIZE" "$OUTPUT_IMG"
log "Image size after shrink: $((NEW_IMG_SIZE / 1024 / 1024)) MiB"

# ── Compress ─────────────────────────────────────────────────────────────────
log "Compressing image..."
xz -v -T0 -9 "$OUTPUT_IMG"

log "═══════════════════════════════════════════"
log "  Build complete: ${OUTPUT_IMG}.xz"
log "  Flash with: rpi-imager or"
log "    xzcat ${OUTPUT_IMG}.xz | sudo dd of=/dev/sdX bs=4M status=progress"
log "═══════════════════════════════════════════"
