# Building the XNav ISO

This guide explains how to build a flashable XNav `.img.xz` image on a standard Linux computer and flash it to your Limelight 3 hardware using balenaEtcher.

---

## Overview

The XNav build script downloads a base Raspberry Pi OS Lite (64-bit) image, mounts it using a loop device, injects all XNav files and services, and compresses the result into a ready-to-flash `.img.xz` file. You run this on any modern Linux PC — no Raspberry Pi hardware is needed for the build step.

---

## Build Machine Requirements

| Requirement | Notes |
|-------------|-------|
| **OS** | Linux (Ubuntu 20.04 / 22.04 recommended; Debian 11+ also works) |
| **Architecture** | x86-64 (amd64) |
| **Disk space** | ≥ 8 GB free in `/tmp` |
| **RAM** | 2 GB minimum |
| **Root / sudo** | Required — the script mounts loop devices |
| **Internet** | Required to download the base RPi OS image (~500 MB) |

### Required packages

Install the following before running the build:

```bash
sudo apt-get update
sudo apt-get install -y \
    parted \
    e2fsprogs \
    xz-utils \
    curl \
    git \
    util-linux
```

> **Note:** On Fedora/RHEL use `dnf install` with the same package names (the `e2fsprogs` package provides `e2fsck` and `resize2fs`).

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
3. Expand the image by 2 GB to fit XNav files
4. Mount the image partitions via a loop device
5. Inject all XNav application files, systemd services, and default configuration
6. Set the hostname to `xnav`
7. Add camera and boot configuration
8. Unmount, then compress the final image with `xz -9` (may take 5–10 minutes)

### Expected output

```
[BUILD] XNav ISO Builder v1.0.0
[BUILD] Repo: /opt/xnav-src
[BUILD] Using image injection method...
[BUILD] Downloading base Raspberry Pi OS Lite (64-bit)...
...
[BUILD] Injecting XNav files...
[BUILD] Unmounting...
[BUILD] Compressing image...
[BUILD] ═══════════════════════════════════════════
[BUILD]   Build complete: xnav-1.0.0.img.xz
[BUILD]   Flash with: rpi-imager or
[BUILD]     xzcat xnav-1.0.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
[BUILD] ═══════════════════════════════════════════
```

The finished image is written to:
```
/tmp/xnav-build/xnav-1.0.0.img.xz
```

Copy it somewhere convenient before flashing:

```bash
cp /tmp/xnav-build/xnav-1.0.0.img.xz ~/Desktop/
```

---

## Step 3 — Flash with balenaEtcher

[balenaEtcher](https://etcher.balena.io/) is the easiest cross-platform tool for flashing images.

### 3a — Install balenaEtcher

Download the AppImage (Linux), `.dmg` (macOS), or `.exe` (Windows) from:

> https://etcher.balena.io/

On Linux you can also install via apt (if using the Balena apt repo) or simply run the AppImage directly:

```bash
chmod +x balenaEtcher-*.AppImage
./balenaEtcher-*.AppImage
```

### 3b — Put Limelight 3 into USB Boot Mode

The Limelight 3 uses a Raspberry Pi Compute Module 4 (CM4) with eMMC storage. To flash the eMMC from your computer you need to expose it as a USB mass-storage device:

1. **Remove power** from the Limelight 3.
2. Locate the **Boot Mode jumper** on the Limelight 3 board (labelled `BOOT` or `nBOOT`). Bridge the jumper pins.
3. Connect a **USB-A to USB-A cable** from the Limelight 3's USB port to your computer.
4. **Apply power** to the Limelight 3.

> If the CM4 eMMC is exposed correctly, your computer will recognise a new USB storage device (usually `/dev/sdb` or `/dev/sdc` on Linux, or a removable drive on Windows/macOS). You can verify with `lsblk` on Linux.

> **Alternative**: If your Limelight 3 variant accepts a microSD card instead of eMMC, simply insert the card into a USB card reader connected to your computer.

### 3c — Flash the Image

1. Open **balenaEtcher**.
2. Click **Flash from file** → select `xnav-1.0.0.img.xz`.
   - balenaEtcher can flash `.xz` compressed images directly — no need to decompress first.
3. Click **Select target** → choose the Limelight 3 / CM4 eMMC drive.
   - **Double-check you have the correct drive** — all data on the target will be erased.
4. Click **Flash!** and wait for the write and verification steps to complete (~5–15 minutes depending on speed).
5. When balenaEtcher shows **Flash Complete!**, close it.

### 3d — Finish Up

1. **Remove power** from the Limelight 3.
2. Remove the jumper (or unplug the USB-A cable).
3. Disconnect the USB cable.

---

## Step 4 — First Boot

1. Connect the Limelight 3 to your robot network via Ethernet.
2. Apply power.
3. Wait **2–3 minutes** for the first-boot setup to complete (Python packages are installed on first boot).
4. Open a browser and navigate to:
   - `http://xnav.local:5800` (mDNS)
   - or `http://10.TE.AM.11:5800` (replace `TE.AM` with your team number, e.g. `10.12.34.11:5800`)

You should see the XNav web dashboard.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `losetup` fails with "no loop devices available" | Load the loop module: `sudo modprobe loop` |
| Download fails | Download the RPi OS Lite image manually from [raspberrypi.com/software/operating-systems](https://www.raspberrypi.com/software/operating-systems/) and save as `/tmp/xnav-build/raspios_lite.img` |
| `parted` not found | Install: `sudo apt-get install parted` |
| `resize2fs` not found | Install: `sudo apt-get install e2fsprogs` |
| CM4 not detected as USB drive | Ensure the BOOT jumper is bridged and power was cycled **after** connecting USB |
| balenaEtcher shows drive is locked | Make sure no partition on the drive is mounted: `sudo umount /dev/sdX*` |
| Dashboard not reachable after flashing | Wait the full 3 minutes; check that the Ethernet cable is connected; try the IP address directly |

---

## Alternative: Flash with Command Line (Linux)

If you prefer not to use balenaEtcher:

```bash
xzcat /tmp/xnav-build/xnav-1.0.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with the correct target device (e.g. `/dev/sdb`). **Verify the device name carefully.**

---

## Alternative: Flash with Raspberry Pi Imager

1. Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
2. Under **Operating System** → choose **Use custom** → select `xnav-1.0.0.img.xz`.
3. Under **Storage** → select the CM4 eMMC / SD card.
4. Click **Write**.
