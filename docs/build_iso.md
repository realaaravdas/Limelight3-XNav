# Building the XNav ISO

This guide explains how to build a flashable XNav `.img.xz` image on a standard Linux computer (including WSL2 on Windows) and flash it to your Limelight 3 hardware.

---

## Overview

XNav's vision core is written in **C++** and compiles to a single ~2 MB binary. There are no Python packages, no pip, and no virtual environments. The ISO build process:

1. Downloads the official Raspberry Pi OS Lite (64-bit) base image
2. Expands and mounts it via a loop device
3. Injects all XNav C++ source, web dashboard, and configuration
4. Compiles the C++ binary inside an **ARM64 QEMU chroot**
5. Installs required runtime shared libraries via `apt`
6. Removes build tools (keeps only runtime)
7. Shrinks the filesystem to minimum size
8. Compresses the result with `xz -9`

The resulting image is dramatically smaller than the previous Python-based version (no ~400 MB Python wheel bundle), which resolves the 91% flash stall on Limelight 3 eMMC.

---

## Build Machine Requirements

| Requirement | Notes |
|-------------|-------|
| **OS** | Linux or **WSL2** on Windows (Ubuntu 22.04 recommended) |
| **Architecture** | x86-64 (amd64) — ARM64 cross-compilation via QEMU |
| **Disk space** | ≥ 8 GB free in `/tmp` |
| **RAM** | 2 GB minimum |
| **Root / sudo** | Required — the script mounts loop devices |
| **Internet** | Required to download base RPi OS image (~500 MB) and apt packages |

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

> **WSL2 note:** Ensure you are running a WSL2 distro (not WSL1). Loop device and QEMU support require WSL2's Linux kernel. Enable `systemd` in WSL2 (`/etc/wsl.conf`: `[boot]\nsystemd=true`) and restart WSL.

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
2. Decompress and copy the base image
3. Expand the image by **512 MB** (much smaller than before — no Python wheels)
4. Mount the image partitions via a loop device
5. Inject XNav C++ source, web dashboard, and default configuration
6. Download Bootstrap CSS/JS for offline web dashboard
7. **Build the C++ binary inside an ARM64 QEMU chroot** (installs apt build tools, compiles, removes build tools)
8. Enable the `xnav-vision` systemd service
9. Set the hostname to `xnav`
10. Shrink the filesystem to minimum size
11. Compress the final image with `xz -9` (5–15 minutes)

### Expected output

```
[BUILD] XNav ISO Builder v1.1.0 (C++ edition)
[BUILD] Repo: /opt/xnav-src
[BUILD] Using image injection method...
[BUILD] Downloading base Raspberry Pi OS Lite (64-bit)...
...
[BUILD] Building C++ binary in ARM64 chroot (QEMU)...
...
[BUILD] C++ binary built and installed: /opt/xnav/bin/xnav
[BUILD] Root filesystem: 1234 MiB
[BUILD] Image size after shrink: 1290 MiB
[BUILD] Compressing image...
[BUILD] ═══════════════════════════════════════════
[BUILD]   Build complete: xnav-1.1.0.img.xz
[BUILD]   Flash with: rpi-imager or
[BUILD]     xzcat xnav-1.1.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
[BUILD] ═══════════════════════════════════════════
```

The finished image is at:
```
/tmp/xnav-build/xnav-1.1.0.img.xz
```

### Build time estimate

| Step | Time |
|------|------|
| Download base image | ~5 min (500 MB, varies by connection) |
| QEMU apt-get install (build tools) | ~10–20 min |
| C++ compilation (QEMU, 4 cores) | ~5–10 min |
| apt-get install (runtime libs only) | ~5 min |
| Filesystem shrink + compress | ~10–20 min |
| **Total** | **~35–55 min** |

---

## Step 3 — Flash with balenaEtcher

[balenaEtcher](https://etcher.balena.io/) is the easiest cross-platform tool for flashing images.

### 3a — Install balenaEtcher

Download from **https://etcher.balena.io/** (AppImage for Linux, `.exe` for Windows).

### 3b — Put Limelight 3 into USB Boot Mode

1. **Remove power** from the Limelight 3.
2. Locate the **Boot Mode jumper** (`BOOT` / `nBOOT`). Bridge the jumper pins.
3. Connect a **USB-A to USB-A cable** from the Limelight 3 USB port to your computer.
4. **Apply power** to the Limelight 3.

The CM4 eMMC will appear as a USB storage device. Verify with `lsblk` (Linux) or Disk Manager (Windows).

### 3c — Flash the Image

1. Open **balenaEtcher**
2. **Flash from file** → select `xnav-1.1.0.img.xz` (balenaEtcher decompresses automatically)
3. **Select target** → choose the Limelight 3 eMMC drive
4. **Flash!** — wait for write + verification to complete (~5–10 min)

### 3d — Finish Up

1. Remove power from the Limelight 3
2. Remove the Boot Mode jumper
3. Disconnect the USB cable

---

## Step 4 — First Boot

1. Connect the Limelight 3 to your robot network via Ethernet
2. Apply power
3. Wait **~30 seconds** for boot (no first-boot install needed — C++ binary starts immediately)
4. Open a browser:
   - `http://xnav.local:5800` (mDNS)
   - or `http://10.TE.AM.11:5800` (replace `TE.AM` with your team number)

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `losetup` fails with "no loop devices available" | Run: `sudo modprobe loop` |
| Download fails | Download RPi OS Lite manually from [raspberrypi.com/software/operating-systems/](https://www.raspberrypi.com/software/operating-systems/) and save as `/tmp/xnav-build/raspios_lite.img` |
| `parted` not found | `sudo apt-get install parted` |
| `resize2fs` not found | `sudo apt-get install e2fsprogs` |
| QEMU chroot build fails | The image still boots; SSH in and run `/opt/xnav/build_on_device.sh` manually |
| CM4 not detected as USB drive | Ensure BOOT jumper is bridged and power was cycled **after** connecting USB |
| Dashboard not reachable after flashing | Wait 30 seconds for boot; check Ethernet is connected; try IP directly |
| WSL2 loop device issues | Run `sudo modprobe loop` inside WSL2; ensure WSL2 kernel supports loop devices |

---

## Alternative: Flash with Command Line (Linux)

```bash
xzcat /tmp/xnav-build/xnav-1.1.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with the correct target device. **Verify the device name carefully.**

---

## Alternative: Flash with Raspberry Pi Imager

1. Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. **Operating System** → **Use custom** → select `xnav-1.1.0.img.xz`
3. **Storage** → select the CM4 eMMC / SD card
4. Click **Write**

---

## Size Comparison

| Version | Python wheels | Image size (compressed) | First-boot delay |
|---------|-------------|------------------------|-----------------|
| v1.0 (Python) | ~400 MB bundled | ~950 MB | 2–5 min |
| v1.1 (C++) | None | ~350 MB | None |

The C++ rewrite eliminates `opencv-python-headless`, `numpy`, `pupil-apriltags`, `pyntcore`, `flask`, `flask-socketio`, and all their dependencies.
