#!/bin/bash
# XNav ISO Builder
# Creates a flashable Raspberry Pi OS image with XNav pre-installed.
# The device-side code is a single statically-linked Rust binary (xnav)
# that replaces all Python runtime dependencies.
#
# Usage: sudo bash build_iso.sh
# Output: xnav-<version>.img.xz
#
# Build machine requirements (Ubuntu/Debian):
#   sudo apt-get install -y parted e2fsprogs xz-utils curl git \
#       util-linux qemu-user-static binfmt-support \
#       gcc-aarch64-linux-gnu
#
# Optional (for cross-compilation without QEMU):
#   cargo install cross   # uses Docker
#
# The script will try compilation methods in order:
#   1. Cross-compile on host with 'cross' (Docker required)
#   2. Native compile inside QEMU ARM64 chroot
#   3. First-boot compilation fallback (slow but self-contained)

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

log "XNav ISO Builder v${XNAV_VERSION} (Rust binary)"
log "Repo: $REPO_ROOT"

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

# Increase image size for XNav binary + OpenCV runtime libraries (~300MB)
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

ROOT="$WORK_DIR/mnt/root"

# ── Inject XNav config and service ──────────────────────────────────────────
log "Injecting XNav configuration..."

mkdir -p "$ROOT/opt/xnav"
mkdir -p "$ROOT/opt/xnav/bin"
mkdir -p "$ROOT/etc/xnav"

cp "$REPO_ROOT/system/config/default_config.json" "$ROOT/etc/xnav/config.json"
cp "$REPO_ROOT/system/services/xnav-vision.service" "$ROOT/etc/systemd/system/"

# Enable service via symlink
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/xnav-vision.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-vision.service" 2>/dev/null || true

# ── Build Rust binary ─────────────────────────────────────────────────────────
log "Building XNav Rust binary..."

RUST_BINARY=""

# ── Method 1: Use pre-built binary if provided ────────────────────────────────
PREBUILT_BINARY="$REPO_ROOT/vision_core_rs/dist/xnav-aarch64"
if [ -f "$PREBUILT_BINARY" ] && [ -x "$PREBUILT_BINARY" ]; then
  log "Using pre-built binary: $PREBUILT_BINARY"
  RUST_BINARY="$PREBUILT_BINARY"
fi

# ── Method 2: Cross-compile with 'cross' tool (requires Docker) ──────────────
if [ -z "$RUST_BINARY" ] && command -v cross &>/dev/null && command -v docker &>/dev/null; then
  log "Attempting cross-compilation with 'cross' tool..."
  SUDO_USER_HOME=$(eval echo "~$(logname 2>/dev/null || echo root)")
  export HOME="$SUDO_USER_HOME"
  
  if (cd "$REPO_ROOT/vision_core_rs" && cross build --release --target aarch64-unknown-linux-gnu 2>&1); then
    BUILT="$REPO_ROOT/vision_core_rs/target/aarch64-unknown-linux-gnu/release/xnav"
    if [ -f "$BUILT" ]; then
      log "Cross-compilation successful!"
      RUST_BINARY="$BUILT"
    fi
  else
    log "WARN: cross-compilation failed, trying next method"
  fi
fi

# ── Method 3: Native compile inside QEMU ARM64 chroot ────────────────────────
if [ -z "$RUST_BINARY" ]; then
  QEMU_BINARY=""
  for q in /usr/bin/qemu-aarch64-static /usr/local/bin/qemu-aarch64-static; do
    [ -f "$q" ] && QEMU_BINARY="$q" && break
  done

  if [ -z "$QEMU_BINARY" ] && command -v apt-get &>/dev/null; then
    log "Installing qemu-user-static for ARM64 chroot support..."
    apt-get install -y -qq qemu-user-static binfmt-support 2>&1 | tail -3 || true
    update-binfmts --enable qemu-aarch64 2>/dev/null || true
    [ -f "/usr/bin/qemu-aarch64-static" ] && QEMU_BINARY="/usr/bin/qemu-aarch64-static"
  fi

  if [ -n "$QEMU_BINARY" ]; then
    log "Compiling Rust binary natively in ARM64 QEMU chroot..."
    log "  (This may take 20-40 minutes on the first run)"
    cp "$QEMU_BINARY" "$ROOT/usr/bin/qemu-aarch64-static"

    # Copy source into the image for compilation
    log "Copying source files into chroot..."
    rm -rf "$ROOT/tmp/xnav-src"
    mkdir -p "$ROOT/tmp/xnav-src"
    cp -r "$REPO_ROOT/vision_core_rs/." "$ROOT/tmp/xnav-src/vision_core_rs/"
    cp -r "$REPO_ROOT/web_dashboard" "$ROOT/tmp/xnav-src/web_dashboard"

    # Mount essential filesystems for chroot
    mount --bind /proc    "$ROOT/proc"    2>/dev/null || true
    mount --bind /sys     "$ROOT/sys"     2>/dev/null || true
    mount --bind /dev     "$ROOT/dev"     2>/dev/null || true
    mount --bind /dev/pts "$ROOT/dev/pts" 2>/dev/null || true

    CHROOT_BUILD_OK=false
    chroot "$ROOT" /bin/bash -ec '
      set -e
      export DEBIAN_FRONTEND=noninteractive

      echo "Installing build dependencies..."
      apt-get update -qq
      apt-get install -y -qq \
        curl build-essential pkg-config \
        libopencv-dev libopencv-core-dev libopencv-videoio-dev \
        libopencv-objdetect-dev libopencv-calib3d-dev \
        libopencv-imgproc-dev libopencv-imgcodecs-dev \
        libclang-dev clang 2>&1 | tail -10

      echo "Installing Rust toolchain..."
      curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --no-modify-path 2>&1 | tail -5
      source /root/.cargo/env

      echo "Building XNav binary..."
      cd /tmp/xnav-src/vision_core_rs
      cargo build --release 2>&1

      echo "Copying binary..."
      cp /tmp/xnav-src/vision_core_rs/target/release/xnav /opt/xnav/bin/xnav
      chmod +x /opt/xnav/bin/xnav

      echo "Cleaning up build environment..."
      rm -rf /root/.cargo /root/.rustup
      rm -rf /tmp/xnav-src
      apt-get remove -y -qq libopencv-dev libclang-dev clang 2>/dev/null || true
      apt-get autoremove -y -qq 2>&1 | tail -3

      echo "Build complete!"
    ' && CHROOT_BUILD_OK=true || {
      log "WARN: QEMU chroot build failed, falling back to first-boot compilation"
      CHROOT_BUILD_OK=false
    }

    # Unmount filesystems
    for mnt in "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/sys" "$ROOT/proc"; do
      umount "$mnt" 2>/dev/null || true
    done
    rm -f "$ROOT/usr/bin/qemu-aarch64-static"

    if $CHROOT_BUILD_OK && [ -f "$ROOT/opt/xnav/bin/xnav" ]; then
      log "Rust binary compiled successfully in QEMU chroot"
      RUST_BINARY="CHROOT_BUILT"
    fi
  else
    log "WARN: qemu-aarch64-static not available"
  fi
fi

# ── Copy pre-built binary into image (Methods 1 & 2) ─────────────────────────
if [ -n "$RUST_BINARY" ] && [ "$RUST_BINARY" != "CHROOT_BUILT" ]; then
  log "Installing binary from: $RUST_BINARY"
  cp "$RUST_BINARY" "$ROOT/opt/xnav/bin/xnav"
  chmod +x "$ROOT/opt/xnav/bin/xnav"
fi

# ── Method 4: First-boot compilation fallback ─────────────────────────────────
if [ ! -f "$ROOT/opt/xnav/bin/xnav" ]; then
  log "WARN: Binary not built at ISO time — configuring first-boot compilation"
  log "      First boot will take 20-40 minutes to compile the Rust binary."

  # Copy source files for first-boot compilation
  cp -r "$REPO_ROOT/vision_core_rs/." "$ROOT/opt/xnav/vision_core_rs/"
  cp -r "$REPO_ROOT/web_dashboard" "$ROOT/opt/xnav/web_dashboard"

  cat > "$ROOT/etc/xnav/first_boot.sh" << 'FIRSTBOOT'
#!/bin/bash
# XNav First-Boot: compile Rust binary on device
set -e
FIRSTBOOT_LOG="/var/log/xnav-firstboot.log"
exec > >(tee -a "$FIRSTBOOT_LOG") 2>&1

echo "========================================="
echo "XNav First-Boot Compilation - $(date)"
echo "========================================="

# Already compiled?
if [ -f /opt/xnav/bin/xnav ]; then
  echo "Binary already present, skipping compilation"
  systemctl start xnav-vision.service || true
  rm -f /etc/xnav/first_boot.sh
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
echo "Installing build dependencies..."
apt-get update -qq
apt-get install -y -qq \
  curl build-essential pkg-config \
  libopencv-dev libopencv-core-dev libopencv-videoio-dev \
  libopencv-objdetect-dev libopencv-calib3d-dev \
  libopencv-imgproc-dev libopencv-imgcodecs-dev \
  libclang-dev clang

echo "Installing Rust toolchain..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --default-toolchain stable --no-modify-path
source /root/.cargo/env

echo "Building XNav binary (this takes ~20-40 minutes)..."
cd /opt/xnav/vision_core_rs
cargo build --release

mkdir -p /opt/xnav/bin
cp target/release/xnav /opt/xnav/bin/xnav
chmod +x /opt/xnav/bin/xnav

echo "Cleaning up build environment..."
rm -rf /root/.cargo /root/.rustup
rm -rf /opt/xnav/vision_core_rs
apt-get remove -y -qq libopencv-dev libclang-dev clang || true
apt-get autoremove -y -qq || true

echo "Starting XNav service..."
systemctl daemon-reload
systemctl enable xnav-vision.service
systemctl start xnav-vision.service || true

echo "First-boot compilation complete!"
echo "Dashboard: http://xnav.local:5800"
echo "========================================="
rm -f /etc/xnav/first_boot.sh
FIRSTBOOT
  chmod +x "$ROOT/etc/xnav/first_boot.sh"

  # rc.local: run first boot if needed
  RCLOCAL="$ROOT/etc/rc.local"
  if [ -f "$RCLOCAL" ]; then
    sed -i '/first_boot.sh/d' "$RCLOCAL"
    sed -i '/^exit 0/i [ -f /etc/xnav/first_boot.sh ] \&\& bash /etc/xnav/first_boot.sh &' "$RCLOCAL"
  else
    cat > "$RCLOCAL" << 'RCEOF'
#!/bin/bash
# rc.local - local startup script
[ -f /etc/xnav/first_boot.sh ] && bash /etc/xnav/first_boot.sh &
exit 0
RCEOF
    chmod +x "$RCLOCAL"
  fi

  mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
  ln -sf /lib/systemd/system/rc-local.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/rc-local.service"
fi

# ── System configuration ──────────────────────────────────────────────────────

# Set hostname
echo "xnav" > "$ROOT/etc/hostname"
grep -q "127.0.1.1.*xnav" "$ROOT/etc/hosts" 2>/dev/null || \
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
cat > "$ROOT/etc/network/interfaces.d/eth0" << 'NETEOF'
# XNav Network Configuration - eth0 gets IP via DHCP from robot
auto eth0
iface eth0 inet dhcp
NETEOF

# ── Shrink filesystem & cleanup ───────────────────────────────────────────────
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

# Compress
log "Compressing image..."
xz -v -T0 -9 "$OUTPUT_IMG"

log "═══════════════════════════════════════════"
log "  Build complete: ${OUTPUT_IMG}.xz"
log "  Flash with: rpi-imager or"
log "    xzcat ${OUTPUT_IMG}.xz | sudo dd of=/dev/sdX bs=4M status=progress"
log "═══════════════════════════════════════════"

