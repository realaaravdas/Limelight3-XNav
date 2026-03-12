#!/bin/bash
# XNav ISO Builder v1.2.0 — Limelight 3 (Raspberry Pi CM3 / CM4)
#
# What's new in v1.2.0 vs v1.1.0:
#   + Cross-compile C++ binary on host (~1-3 min) with QEMU fallback
#   + Fast xz -3 compression (~2-5 min vs 15-30 min for xz -9)
#   + Installs firmware-realtek — RTL8153B USB ethernet works on first boot
#   + Loads r8152 kernel module + udev rule pins adapter to stable name "eth0"
#   + Installs avahi-daemon + libnss-mdns for xnav.local mDNS resolution
#   + SSH enabled by default (required for headless access — no monitor/keyboard)
#   + First-boot service brings up ethernet, optionally refreshes firmware
#   + make -j$(nproc) — uses all available CPU cores for compilation
#   + Image expands +1 GB; headers stripped after compilation; shrinks on finish
#   + Full cleanup trap — no stale loop devices or mount points on error
#
# Expected build time:
#   ~15-25 min with cross-compile toolchain installed
#   ~30-50 min with QEMU-only fallback
#
# Build machine requirements:
#   sudo apt-get install -y parted e2fsprogs xz-utils curl git util-linux \
#       qemu-user-static binfmt-support
#   # Optional but recommended — saves 10-20 min:
#   sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
#       cmake pkg-config
#
# Usage:
#   sudo bash system/scripts/build_iso.sh
#
# Output:
#   /tmp/xnav-build/xnav-1.2.0.img.xz

set -e

XNAV_VERSION="1.2.0"
OUTPUT_IMG="xnav-${XNAV_VERSION}.img"
WORK_DIR="/tmp/xnav-build"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log()  { echo "[BUILD] $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

[ "$EUID" -ne 0 ] && die "Please run as root: sudo bash system/scripts/build_iso.sh"

log "XNav ISO Builder v${XNAV_VERSION} — Limelight 3 (CM3/CM4)"
log "Repo: $REPO_ROOT"

# ── Download Raspberry Pi OS Lite (arm64/64-bit) ─────────────────────────────
log "Preparing Raspberry Pi OS Lite (64-bit)..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

BASE_XZ="raspios_lite_arm64_latest.img.xz"
BASE_IMG="raspios_lite.img"
BASE_URL="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"

if [ ! -f "$BASE_IMG" ]; then
  if [ ! -f "$BASE_XZ" ]; then
    log "Downloading Raspberry Pi OS Lite arm64 (~500 MB)..."
    curl -L --fail --progress-bar -o "$BASE_XZ" "$BASE_URL" \
      || die "Download failed. Manually save: $BASE_URL -> $WORK_DIR/$BASE_XZ"
  fi
  log "Decompressing base image..."
  xz -dk "$BASE_XZ"
  # Handle date-stamped filenames like 2024-11-19-raspios-bookworm-arm64-lite.img
  EXTRACTED=$(find "$WORK_DIR" -maxdepth 1 -name "*.img" ! -name "$OUTPUT_IMG" | head -1)
  [ -n "$EXTRACTED" ] && mv "$EXTRACTED" "$BASE_IMG"
fi

[ -f "$BASE_IMG" ] || die "Base image not found at $WORK_DIR/$BASE_IMG"
log "Copying base image to working copy..."
cp "$BASE_IMG" "$OUTPUT_IMG"

# ── Expand image (+1 GB) ─────────────────────────────────────────────────────
log "Expanding image by 1 GB..."
truncate -s +1G "$OUTPUT_IMG"

# ── Partition layout ─────────────────────────────────────────────────────────
BOOT_OFFSET=$(parted "$OUTPUT_IMG" -s unit B print | awk '/^ 1/{print $2}' | tr -d B)
ROOT_OFFSET=$(parted "$OUTPUT_IMG" -s unit B print | awk '/^ 2/{print $2}' | tr -d B)
log "Boot offset: ${BOOT_OFFSET} B   Root offset: ${ROOT_OFFSET} B"
parted "$OUTPUT_IMG" -s resizepart 2 100%

# ── Mount image ──────────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR/mnt/boot" "$WORK_DIR/mnt/root"
LOOP=$(losetup -fP --show "$OUTPUT_IMG")
log "Loop device: $LOOP"

mount "${LOOP}p1" "$WORK_DIR/mnt/boot"
mount "${LOOP}p2" "$WORK_DIR/mnt/root"
e2fsck -f "${LOOP}p2" || true
resize2fs "${LOOP}p2"

ROOT="$WORK_DIR/mnt/root"
BOOT="$WORK_DIR/mnt/boot"

# ── Cleanup trap (runs on error or at script exit) ───────────────────────────
_CLEANUP_DONE=false
cleanup() {
  $_CLEANUP_DONE && return
  _CLEANUP_DONE=true
  for mnt in "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/sys" "$ROOT/proc"; do
    umount "$mnt" 2>/dev/null || true
  done
  rm -f "$ROOT/usr/bin/qemu-aarch64-static" 2>/dev/null || true
  sync 2>/dev/null || true
  umount "$BOOT" 2>/dev/null || true
  umount "$ROOT"  2>/dev/null || true
  losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# ── Inject XNav application files ───────────────────────────────────────────
log "Injecting XNav files..."
mkdir -p "$ROOT/opt/xnav/bin" "$ROOT/etc/xnav"

cp -r "$REPO_ROOT/web_dashboard"        "$ROOT/opt/xnav/"
cp -r "$REPO_ROOT/vision_core_cpp"      "$ROOT/opt/xnav/"
cp "$REPO_ROOT/system/config/default_config.json"      "$ROOT/etc/xnav/config.json"
cp "$REPO_ROOT/system/services/xnav-vision.service"    "$ROOT/etc/systemd/system/"
cp "$REPO_ROOT/system/services/xnav-firstboot.service" "$ROOT/etc/systemd/system/"

# ── Ethernet driver (file-copy only — no QEMU needed) ───────────────────────
log "Setting up Limelight 3 ethernet driver (Realtek RTL8153B / r8152)..."
mkdir -p "$ROOT/etc/udev/rules.d" "$ROOT/etc/modules-load.d"
# Udev rule: pins the Realtek USB ethernet adapter to the stable name "eth0"
cp "$REPO_ROOT/system/config/70-limelight-ethernet.rules" \
   "$ROOT/etc/udev/rules.d/70-limelight-ethernet.rules"
# Load r8152 module on every boot
echo "r8152" > "$ROOT/etc/modules-load.d/usb-ethernet.conf"

# ── Download web dashboard vendor assets ────────────────────────────────────
log "Downloading Bootstrap vendor assets for offline web dashboard..."
VENDOR_DIR="$ROOT/opt/xnav/web_dashboard/static/vendor"
mkdir -p "$VENDOR_DIR/fonts"

curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" \
    -o "$VENDOR_DIR/bootstrap.min.css"       || warn "bootstrap.min.css download failed"
curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js" \
    -o "$VENDOR_DIR/bootstrap.bundle.min.js" || warn "bootstrap.bundle.min.js download failed"
curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" \
    -o "$VENDOR_DIR/bootstrap-icons.min.css" || warn "bootstrap-icons.min.css download failed"
curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/fonts/bootstrap-icons.woff2" \
    -o "$VENDOR_DIR/fonts/bootstrap-icons.woff2" || true
curl -sSL "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/fonts/bootstrap-icons.woff" \
    -o "$VENDOR_DIR/fonts/bootstrap-icons.woff" || true
if [ -f "$VENDOR_DIR/bootstrap-icons.min.css" ]; then
  sed -i 's|url("./fonts/|url("/static/vendor/fonts/|g' \
      "$VENDOR_DIR/bootstrap-icons.min.css"
fi

# ── Set up QEMU for ARM64 chroot ────────────────────────────────────────────
QEMU_BIN=""
for q in /usr/bin/qemu-aarch64-static /usr/local/bin/qemu-aarch64-static; do
  [ -f "$q" ] && QEMU_BIN="$q" && break
done
if [ -z "$QEMU_BIN" ] && command -v apt-get &>/dev/null; then
  log "Installing qemu-user-static..."
  apt-get install -y -qq qemu-user-static binfmt-support 2>&1 | tail -5 || true
  [ -f "/usr/bin/qemu-aarch64-static" ] && QEMU_BIN="/usr/bin/qemu-aarch64-static"
fi
[ -n "$QEMU_BIN" ] || die "qemu-aarch64-static not found. Run: sudo apt-get install qemu-user-static"

cp "$QEMU_BIN" "$ROOT/usr/bin/qemu-aarch64-static"
mount --bind /proc    "$ROOT/proc"    2>/dev/null || true
mount --bind /sys     "$ROOT/sys"     2>/dev/null || true
mount --bind /dev     "$ROOT/dev"     2>/dev/null || true
mount --bind /dev/pts "$ROOT/dev/pts" 2>/dev/null || true
update-binfmts --enable qemu-aarch64 2>/dev/null || true

# ── Step 1: Install packages in ARM64 chroot ────────────────────────────────
# Install -dev packages so the rootfs can act as a cross-compile sysroot.
# Headers are stripped after compilation to keep the final image small.
log "Installing packages in ARM64 chroot..."
log "  firmware-realtek  — RTL8153B USB ethernet firmware (REQUIRED)"
log "  libopencv-dev     — C++ vision library"
log "  libapriltag-dev   — AprilTag C library"
log "  libgpiod-dev      — GPIO control"
log "  avahi-daemon      — mDNS for xnav.local resolution"
log "(this takes ~10-15 min via QEMU)"

chroot "$ROOT" /bin/bash -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  # Ethernet firmware — CRITICAL: RTL8153B will not connect without this
  apt-get install -y --no-install-recommends firmware-realtek 2>&1 | tail -5

  # C++ dev headers (used as cross-compile sysroot; stripped after build)
  apt-get install -y --no-install-recommends \
      libopencv-dev \
      libapriltag-dev \
      libgpiod-dev \
      2>&1 | tail -10

  # mDNS daemon — allows "ssh pi@xnav.local" without knowing the IP address
  apt-get install -y --no-install-recommends \
      avahi-daemon \
      libnss-mdns \
      2>&1 | tail -5

  apt-get clean
  rm -rf /var/lib/apt/lists/*
' || {
  warn "Package install had errors — retrying with minimal set..."
  chroot "$ROOT" /bin/bash -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        firmware-realtek libopencv-dev libapriltag-dev libgpiod-dev || true
    apt-get clean; rm -rf /var/lib/apt/lists/*
  ' || warn "Package installation failed — image may be incomplete"
}

# ── Step 2: Compile the C++ binary ──────────────────────────────────────────
BINARY_BUILT=false
HOST_NPROC=$(nproc)

# 2a — Cross-compile on host (fast, no emulation overhead)
if command -v aarch64-linux-gnu-g++ &>/dev/null && command -v cmake &>/dev/null; then
  log "Cross-compiling xnav on host (fast path — ~1-3 min)..."
  CROSS_BUILD="$WORK_DIR/cross-build"
  rm -rf "$CROSS_BUILD"; mkdir -p "$CROSS_BUILD"

  # CMake toolchain file: use cross-compiler with the ARM64 rootfs as sysroot
  cat > "$WORK_DIR/toolchain-aarch64.cmake" << TCEOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_SYSROOT "${ROOT}")
set(CMAKE_FIND_ROOT_PATH "${ROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
TCEOF

  # Point pkg-config at the ARM64 rootfs .pc files
  export PKG_CONFIG_SYSROOT_DIR="$ROOT"
  export PKG_CONFIG_PATH="$ROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$ROOT/usr/share/pkgconfig"
  export PKG_CONFIG_LIBDIR="$ROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$ROOT/usr/share/pkgconfig"

  if cmake -S "$REPO_ROOT/vision_core_cpp" \
           -B "$CROSS_BUILD" \
           -DCMAKE_TOOLCHAIN_FILE="$WORK_DIR/toolchain-aarch64.cmake" \
           -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -20 \
  && cmake --build "$CROSS_BUILD" -j"$HOST_NPROC" 2>&1 | tail -20; then
    cp "$CROSS_BUILD/xnav" "$ROOT/opt/xnav/bin/xnav"
    chmod +x "$ROOT/opt/xnav/bin/xnav"
    log "Cross-compiled: $(ls -lh "$ROOT/opt/xnav/bin/xnav")"
    BINARY_BUILT=true
  else
    warn "Cross-compilation failed — falling back to QEMU compilation"
  fi
  unset PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_PATH PKG_CONFIG_LIBDIR
fi

# 2b — QEMU fallback (slower but always works)
if ! $BINARY_BUILT; then
  log "Compiling xnav inside ARM64 QEMU chroot (fallback — ~10-20 min)..."
  chroot "$ROOT" /bin/bash -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq cmake g++ pkg-config 2>&1 | tail -5
    mkdir -p /opt/xnav/vision_core_cpp/build
    cd /opt/xnav/vision_core_cpp/build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/xnav 2>&1 | tail -10
    make -j'"$HOST_NPROC"' 2>&1 | tail -20
    make install
    echo "Binary: $(ls -lh /opt/xnav/bin/xnav)"
    apt-get remove --purge -y cmake g++ pkg-config 2>/dev/null || true
    apt-get clean
    rm -rf /var/lib/apt/lists/*
  ' && BINARY_BUILT=true || warn "QEMU compilation failed — binary not in image"
fi

# ── Step 3: Strip dev headers to shrink image ────────────────────────────────
# Runtime .so files remain; only headers / cmake / .pc files are removed.
# Direct rm is used — much faster than another QEMU invocation.
if $BINARY_BUILT; then
  log "Removing development headers (keeping runtime libs, saves ~100-150 MB)..."
  rm -rf "$ROOT/usr/include/opencv4"        2>/dev/null || true
  rm -rf "$ROOT/usr/include/apriltag"       2>/dev/null || true
  find "$ROOT/usr/include" -name "gpiod*.h" -delete 2>/dev/null || true
  find "$ROOT/usr/lib/aarch64-linux-gnu" -name "*.la" -delete 2>/dev/null || true
  find "$ROOT/usr/lib/aarch64-linux-gnu/pkgconfig" -name "*.pc" \
       -delete 2>/dev/null || true
  rm -rf "$ROOT/usr/lib/aarch64-linux-gnu/cmake" 2>/dev/null || true
  rm -rf "$ROOT/usr/share/opencv4"               2>/dev/null || true
  # Remove C++ source tree — only the compiled binary is needed at runtime
  rm -rf "$ROOT/opt/xnav/vision_core_cpp"
fi

# Unmount QEMU bind-mounts
for mnt in "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/sys" "$ROOT/proc"; do
  umount "$mnt" 2>/dev/null || true
done
rm -f "$ROOT/usr/bin/qemu-aarch64-static"

# ── Enable systemd services ──────────────────────────────────────────────────
log "Enabling systemd services..."
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/xnav-vision.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-vision.service"
ln -sf /etc/systemd/system/xnav-firstboot.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-firstboot.service"
# Remove old standalone dashboard service (dashboard is now inside xnav binary)
rm -f "$ROOT/etc/systemd/system/multi-user.target.wants/xnav-dashboard.service"

# ── SSH (required for headless — no monitor/keyboard/mouse) ─────────────────
log "Enabling SSH (required for headless access)..."
touch "$BOOT/ssh"

# ── First-boot script ────────────────────────────────────────────────────────
log "Installing first-boot script..."
cat > "$ROOT/opt/xnav/firstboot.sh" << 'FBEOF'
#!/bin/bash
# XNav First-Boot Setup
# Runs once on first power-on via xnav-firstboot.service.
# Ensures Realtek USB ethernet (r8152) is loaded and gets an IP.
# When internet is reachable (home router), refreshes firmware-realtek.
# On subsequent boots (robot network / intranet) this script is skipped.
set -e
LOG="/var/log/xnav-firstboot.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== XNav First-Boot Setup === $(date)"
mkdir -p /etc/xnav

modprobe r8152 2>/dev/null || true
sleep 1

ip link set eth0 up 2>/dev/null || true
sleep 3

# Request a DHCP lease.  Raspberry Pi OS Bookworm ships dhcpcd by default;
# fall back to dhclient on systems where only it is available.
if command -v dhcpcd >/dev/null 2>&1; then
  dhcpcd eth0 --waitip 2>/dev/null || true
elif command -v dhclient >/dev/null 2>&1; then
  dhclient eth0 2>/dev/null || true
fi
sleep 5

IP=$(ip addr show eth0 2>/dev/null | awk '/inet /{print $2; exit}')
if [ -n "$IP" ]; then
  echo "eth0 up: $IP"
  if ping -c1 -W5 8.8.8.8 >/dev/null 2>&1; then
    echo "Internet reachable — refreshing firmware-realtek..."
    apt-get update -qq 2>/dev/null || true
    apt-get install -y --no-install-recommends firmware-realtek 2>/dev/null || true
    echo "Firmware refresh done."
  else
    echo "No internet (expected on robot/intranet network)."
  fi
else
  echo "WARNING: eth0 has no IP. Check Ethernet cable and DHCP."
fi

touch /etc/xnav/.firstboot-done
systemctl disable xnav-firstboot.service 2>/dev/null || true
echo "=== First-boot complete ==="
FBEOF
chmod +x "$ROOT/opt/xnav/firstboot.sh"

# ── Hostname ─────────────────────────────────────────────────────────────────
echo "xnav" > "$ROOT/etc/hostname"
sed -i '/127.0.1.1/d' "$ROOT/etc/hosts"
echo "127.0.1.1    xnav" >> "$ROOT/etc/hosts"

# ── Boot configuration (CM3 / CM4) ──────────────────────────────────────────
BOOTCFG="$BOOT/config.txt"
sed -i '/# XNav Configuration/,+10d' "$BOOTCFG" 2>/dev/null || true
cat >> "$BOOTCFG" << 'BOOTEOF'
# XNav Configuration — Limelight 3 (CM3/CM4)
start_x=1
gpu_mem=128
disable_camera_led=1
# Disable USB autosuspend — keeps the RTL8153B ethernet adapter active
usbcore.autosuspend=-1
BOOTEOF

# ── Network: eth0 DHCP ───────────────────────────────────────────────────────
mkdir -p "$ROOT/etc/network/interfaces.d"
cat > "$ROOT/etc/network/interfaces.d/eth0" << 'NETEOF'
# XNav Network — Realtek RTL8153B USB Ethernet (Limelight 3)
# DHCP: gets IP from robot controller or internet router on first boot.
auto eth0
iface eth0 inet dhcp
NETEOF

# ── rc.local ─────────────────────────────────────────────────────────────────
cat > "$ROOT/etc/rc.local" << 'RCEOF'
#!/bin/bash
# XNav rc.local — main services start via systemd
ip link set eth0 up 2>/dev/null || true
exit 0
RCEOF
chmod +x "$ROOT/etc/rc.local"

# ── Shrink filesystem ────────────────────────────────────────────────────────
log "Unmounting filesystems for shrink..."
sync
umount "$BOOT"
umount "$ROOT"

log "Shrinking root filesystem to minimum size..."
e2fsck -fy "${LOOP}p2"
EC=$?
[ $EC -le 2 ] || { losetup -d "$LOOP"; die "e2fsck returned $EC"; }
resize2fs -M "${LOOP}p2"

TUNE=$(tune2fs -l "${LOOP}p2" 2>/dev/null)
FS_BLOCKS=$(echo "$TUNE" | awk '/^Block count:/{print $NF}')
FS_BLKSZ=$(echo  "$TUNE" | awk '/^Block size:/{print $NF}')
[ -n "$FS_BLOCKS" ] && [ -n "$FS_BLKSZ" ] \
  || { losetup -d "$LOOP"; die "tune2fs could not read filesystem size"; }

FS_BYTES=$(( FS_BLOCKS * FS_BLKSZ ))
log "Root filesystem after shrink: $(( FS_BYTES / 1024 / 1024 )) MiB"

losetup -d "$LOOP"
_CLEANUP_DONE=true  # Prevent double-cleanup in EXIT trap

# Trim image file: partition end + 64 MiB padding (room for partition table overhead)
NEW_END=$(( ROOT_OFFSET + FS_BYTES + 64 * 1024 * 1024 ))
parted "$OUTPUT_IMG" -s resizepart 2 "${NEW_END}B"
# Add a small tail beyond the last partition (required by some tools)
NEW_SIZE=$(( NEW_END + 1024 * 1024 ))
truncate -s "$NEW_SIZE" "$OUTPUT_IMG"
log "Uncompressed image: $(( NEW_SIZE / 1024 / 1024 )) MiB"

# ── Compress ─────────────────────────────────────────────────────────────────
log "Compressing with xz -3 (~2-5 min)..."
xz -v -T0 -3 "$OUTPUT_IMG"

FINAL="$WORK_DIR/${OUTPUT_IMG}.xz"
log "═══════════════════════════════════════════════════════════════"
log "  Build complete!"
log "  File: $FINAL"
log "  Size: $(ls -lh "$FINAL" | awk '{print $5}')"
log "  ─────────────────────────────────────────────────────────────"
log "  Flash: rpi-imager → 'Use custom image' → select the .xz file"
log "    or:  xzcat ${OUTPUT_IMG}.xz | sudo dd of=/dev/sdX bs=4M"
log "═══════════════════════════════════════════════════════════════"
