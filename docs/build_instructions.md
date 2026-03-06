# XNav Build Instructions

## Building the ISO Image

This guide explains how to build a flashable Raspberry Pi OS image with XNav pre-installed as a Rust binary.

> **See also**: [docs/build_iso.md](build_iso.md) for the detailed step-by-step guide including balenaEtcher and Raspberry Pi Imager instructions.

### Prerequisites

Install the following on your Ubuntu/Debian build machine:

```bash
sudo apt-get update
sudo apt-get install -y \
    parted \
    e2fsprogs \
    xz-utils \
    curl \
    git \
    util-linux \
    qemu-user-static \
    binfmt-support
```

Optional (for faster cross-compilation via Docker):

```bash
curl -fsSL https://get.docker.com | bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
cargo install cross
```

### Quick Build

```bash
cd /path/to/Limelight3-XNav
sudo bash system/scripts/build_iso.sh
```

**Output:** `xnav-1.1.0.img.xz`

### Build Compilation Methods

The build script tries the following methods in order to compile the ARM64 Rust binary:

| Method | Requirements | Time |
|--------|-------------|------|
| Pre-built binary (`vision_core_rs/dist/xnav-aarch64`) | Binary file present | Instant |
| `cross` tool (Docker) | Docker + `cross` installed | ~10 min |
| QEMU chroot (native ARM64) | `qemu-user-static` | ~20-40 min |
| First-boot compilation | None (compiles on device) | ~20-40 min on device |

### Build Time

- Download base image: ~500 MB (varies by connection)
- Rust binary compilation (QEMU): 20-40 minutes
- Image compression: 5-10 minutes

### Detailed Build Process

#### 1. Download Base Image

The script downloads the official Raspberry Pi OS Lite (64-bit) from:
```
https://downloads.raspberrypi.org/raspios_lite_arm64_latest
```

#### 2. Image Preparation

- Decompress the base image
- Expand by 512 MB for XNav binary + OpenCV runtime
- Mount boot and root partitions

#### 3. File Injection

The following are copied to the image:

**Configuration:**
- `/etc/xnav/config.json` — Default configuration
- `/etc/hostname` — Set to `xnav`
- `/etc/hosts` — Hostname mapping
- `/boot/config.txt` — Camera + GPU memory settings
- `/etc/network/interfaces.d/eth0` — DHCP network config

**Service:**
- `/etc/systemd/system/xnav-vision.service` — Unified vision + dashboard service
- `/etc/systemd/system/multi-user.target.wants/xnav-vision.service` — Autostart symlink

**Binary:**
- `/opt/xnav/bin/xnav` — Compiled Rust binary (vision + dashboard in one process)

#### 4. Rust Binary Compilation

The `xnav` binary is compiled for `aarch64` ARM64. It embeds the web dashboard assets at compile time (via `rust-embed`), so no Python runtime, wheels, or separate web server process is needed.

The binary links against system OpenCV libraries which are pre-installed in the image during QEMU chroot compilation.

#### 5. First-Boot Fallback

If no binary is compiled at build time, a first-boot script (`/etc/xnav/first_boot.sh`) installs the Rust toolchain and OpenCV dev libraries, compiles the binary on the device, then starts the service. This is a one-time operation.

### Service Architecture

XNav runs as a **single systemd service**:

#### xnav-vision.service
- **Purpose:** Vision pipeline (AprilTag detection, NT4) + web dashboard (port 5800) in one process
- **Binary:** `/opt/xnav/bin/xnav`
- **Priority:** High (CPU cores 0-3, nice=-10, realtime I/O)
- **Config:** `/etc/xnav/config.json`

### Troubleshooting Build Issues

#### Build Fails with "No base image found"

```bash
cd /tmp/xnav-build
wget https://downloads.raspberrypi.org/raspios_lite_arm64_latest
xzcat raspios_lite_arm64_latest > raspios_lite.img
```

Then re-run the build script.

#### QEMU Chroot Build Fails / Runs Out of Space

```bash
# Edit build_iso.sh: increase image expansion
# Change: truncate -s +512M "$OUTPUT_IMG"
# To:      truncate -s +2G "$OUTPUT_IMG"
```

Or use Docker + `cross` instead:
```bash
cargo install cross
cross build --release --target aarch64-unknown-linux-gnu
mkdir -p vision_core_rs/dist
cp vision_core_rs/target/aarch64-unknown-linux-gnu/release/xnav \
    vision_core_rs/dist/xnav-aarch64
sudo bash system/scripts/build_iso.sh
```

#### Build Fails During Compression

```bash
# Use less aggressive compression (faster, slightly larger file)
# Edit build_iso.sh: change xz -v -T0 -9 to xz -v -T0 -6
```

## Flashing the Image

### Using Raspberry Pi Imager (Recommended)

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. **Choose OS** → **Use custom image** → select `xnav-1.1.0.img.xz`
3. **Choose Storage** → select your CM4 eMMC or SD card
4. Click **Write** and wait for completion

### Using balenaEtcher

1. Download [balenaEtcher](https://etcher.balena.io/)
2. **Flash from file** → select `xnav-1.1.0.img.xz`
3. **Select target** → choose your CM4 eMMC / SD card
4. **Flash!** and wait

### Using Command Line (Linux)

```bash
xzcat xnav-1.1.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
sync
# Replace /dev/sdX with your device
```

## First Boot

After flashing and powering on:

1. Services start **immediately** (binary is pre-compiled in the image)
2. Access dashboard: `http://xnav.local:5800`

If the binary was not compiled at build time (first-boot compilation fallback):
1. Wait 20-40 minutes for compilation
2. Monitor: `ssh root@xnav.local && tail -f /var/log/xnav-firstboot.log`
3. Access dashboard: `http://xnav.local:5800`

## Updating an Existing Installation

```bash
# SSH into device
ssh root@xnav.local

# Pull latest changes
cd /opt/xnav-src
git pull

# Re-run setup (recompiles and redeploys)
sudo bash system/scripts/setup.sh
sudo reboot
```

**Note:** Configuration in `/etc/xnav/config.json` is preserved.

## Customizing the Build

### Changing Default Configuration

Edit `system/config/default_config.json` before building:

```bash
nano system/config/default_config.json
```

### Changing Web Port

Edit `system/config/default_config.json`:

```json
{
  "web_port": 5800
}
```

### Changing Hostname

Edit `build_iso.sh`:

```bash
# Find: echo "xnav" > "$ROOT/etc/hostname"
# Change to your hostname
echo "myxnav" > "$ROOT/etc/hostname"
```

## Support

For build issues:
1. Check [docs/build_iso.md](build_iso.md)
2. Review [Troubleshooting Guide](troubleshooting.md)
3. Check GitHub Issues: https://github.com/realaaravdas/Limelight3-XNav/issues

