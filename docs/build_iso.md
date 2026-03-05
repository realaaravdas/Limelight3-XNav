# Building the XNav ISO

This guide explains how to build a flashable XNav `.img.xz` image on an Ubuntu/Debian machine and flash it to your Limelight 3 hardware.

XNav uses a **single Rust binary** (~10-20 MB) instead of a Python runtime stack. The build process compiles the binary for ARM64 and injects it — along with the systemd service and default config — into a Raspberry Pi OS Lite image.

---

## Overview

The build script (`system/scripts/build_iso.sh`):
1. Downloads the official Raspberry Pi OS Lite (64-bit ARM) image
2. Mounts it via a loop device and injects all XNav files
3. Compiles the Rust binary for ARM64 (via QEMU chroot, `cross` tool, or first-boot fallback)
4. Shrinks and compresses the final image

---

## Build Machine Requirements

| Requirement | Notes |
|-------------|-------|
| **OS** | Ubuntu 20.04 / 22.04 or Debian 11+ (recommended) |
| **Architecture** | x86-64 (amd64) |
| **Disk space** | ≥ 10 GB free in `/tmp` (QEMU chroot build needs ~4 GB for Rust + OpenCV) |
| **RAM** | 4 GB minimum (8 GB recommended for QEMU build) |
| **Root / sudo** | Required — the script mounts loop devices |
| **Internet** | Required to download the base RPi OS image (~500 MB) |

### Required packages

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

### Optional: for `cross` tool (Docker-based cross-compilation)

```bash
# Install Docker
curl -fsSL https://get.docker.com | bash

# Install Rust + cross
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
cargo install cross
```

Using `cross` is faster than QEMU chroot (no OpenCV in the build environment).

---

## Step 1 — Clone the Repository

```bash
git clone https://github.com/realaaravdas/Limelight3-XNav /opt/xnav-src
cd /opt/xnav-src
```

---

## Step 2 — Run the Build Script

```bash
sudo bash system/scripts/build_iso.sh
```

The script will:

1. Download the official Raspberry Pi OS Lite 64-bit image (~500 MB) to `/tmp/xnav-build/`
2. Expand the image and mount its partitions
3. Inject the XNav service file and config
4. **Compile the Rust binary** using the best available method:
   - **Method 1** (fastest): Pre-built binary in `vision_core_rs/dist/xnav-aarch64`
   - **Method 2**: Cross-compilation with the `cross` tool (requires Docker)
   - **Method 3**: Native ARM64 compilation inside a QEMU chroot (~20-40 min)
   - **Method 4** (fallback): First-boot compilation on the device (~20-40 min on device)
5. Shrink the root filesystem
6. Compress the final image with `xz -9`

### Expected output (QEMU chroot build)

```
[BUILD] XNav ISO Builder v1.1.0 (Rust binary)
[BUILD] Repo: /opt/xnav-src
[BUILD] Downloading base Raspberry Pi OS Lite (64-bit)...
...
[BUILD] Injecting XNav configuration...
[BUILD] Building XNav Rust binary...
[BUILD] Compiling Rust binary natively in ARM64 QEMU chroot...
[BUILD]   (This may take 20-40 minutes on the first run)
...
[BUILD] Rust binary compiled successfully in QEMU chroot
[BUILD] Shrinking root filesystem to minimum size...
[BUILD] Compressing image...
[BUILD] ═══════════════════════════════════════════
[BUILD]   Build complete: xnav-1.1.0.img.xz
[BUILD]   Flash with: rpi-imager or
[BUILD]     xzcat xnav-1.1.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
[BUILD] ═══════════════════════════════════════════
```

The finished image is written to:
```
/tmp/xnav-build/xnav-1.1.0.img.xz
```

Copy it somewhere convenient before flashing:

```bash
cp /tmp/xnav-build/xnav-1.1.0.img.xz ~/Desktop/
```

---

## Step 3 — Flash with balenaEtcher

[balenaEtcher](https://etcher.balena.io/) is the easiest cross-platform tool for flashing images.

### 3a — Install balenaEtcher

Download from [etcher.balena.io](https://etcher.balena.io/). On Linux, run the AppImage:

```bash
chmod +x balenaEtcher-*.AppImage
./balenaEtcher-*.AppImage
```

### 3b — Put Limelight 3 into USB Boot Mode

1. **Remove power** from the Limelight 3.
2. Bridge the **Boot Mode jumper** (labelled `BOOT` or `nBOOT`).
3. Connect a **USB-A to USB-A cable** from the Limelight 3 USB port to your computer.
4. **Apply power** to the Limelight 3.

> Verify the CM4 eMMC is detected with `lsblk` (usually `/dev/sdb` or `/dev/sdc`).

### 3c — Flash the Image

1. Open **balenaEtcher**.
2. **Flash from file** → select `xnav-1.1.0.img.xz`
3. **Select target** → choose the CM4 eMMC drive.
4. **Flash!** — wait for write and verification (~5–15 minutes).

### 3d — Finish Up

1. **Remove power** from the Limelight 3.
2. Remove the Boot Mode jumper.
3. Disconnect the USB cable.

---

## Step 4 — First Boot

1. Connect the Limelight 3 to your robot network via Ethernet.
2. Apply power.
3. **Services start automatically** — no installation delay when the binary was compiled at build time.
4. Open a browser and navigate to:
   - `http://xnav.local:5800`
   - or `http://10.TE.AM.11:5800` (replace `TE.AM` with your team number)

> **First-boot compilation fallback**: If the binary was not built during the ISO build (QEMU and `cross` both unavailable), a first-boot script compiles the binary on the device. This takes **20-40 minutes**. Monitor progress:
> ```bash
> ssh root@xnav.local
> tail -f /var/log/xnav-firstboot.log
> ```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `losetup` fails | Load loop module: `sudo modprobe loop` |
| Download fails | Manually download RPi OS Lite and save as `/tmp/xnav-build/raspios_lite.img` |
| `parted` not found | `sudo apt-get install parted` |
| `resize2fs` not found | `sudo apt-get install e2fsprogs` |
| QEMU build runs out of space | Increase the `truncate -s +512M` line in `build_iso.sh` to `+2G` |
| QEMU build fails | Install Docker and use `cross` instead (see above) |
| CM4 not detected as USB drive | Ensure BOOT jumper is set; cycle power after connecting USB |
| Dashboard not reachable | Check Ethernet cable; wait for first-boot if applicable |

---

## Alternative: Flash with Command Line (Linux)

```bash
xzcat /tmp/xnav-build/xnav-1.1.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with the correct target device. **Verify carefully.**

---

## Alternative: Flash with Raspberry Pi Imager

1. Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
2. **Operating System** → **Use custom** → select `xnav-1.1.0.img.xz`.
3. **Storage** → select the CM4 eMMC / SD card.
4. Click **Write**.

---

## Verifying the Image

Before flashing, you can validate the image:

```bash
sudo bash system/scripts/verify_iso.sh /tmp/xnav-build/xnav-1.1.0.img.xz
```

This checks that the binary is present, the service is configured, and hostname/boot config is correct.
