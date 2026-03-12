# Building the XNav ISO (v1.2.0)

This guide explains how to build a flashable XNav `.img.xz` image for the
**Limelight 3** (Raspberry Pi Compute Module 3 or 4) on a standard Linux
computer (including WSL2 on Windows).

---

## Overview

XNav's vision core is a single **C++ binary** (`/opt/xnav/bin/xnav`).  
There are **no Python packages, no pip, no wheels** in the ISO.

The build process:

1. Downloads the official Raspberry Pi OS Lite (64-bit / arm64) base image
2. Expands and mounts it via a loop device
3. Injects the XNav C++ source, web dashboard, config files, and system services
4. Sets up the **Realtek RTL8153B USB ethernet driver** (`firmware-realtek`,
   `r8152` module, udev rule) — required for headless SSH access
5. **Compiles the C++ binary**:
   - **Fast path**: cross-compiled on the host with `aarch64-linux-gnu-g++` (~1-3 min)
   - **Fallback**: compiled inside an ARM64 QEMU chroot (~10-20 min)
6. Installs `avahi-daemon` for `xnav.local` mDNS (headless IP discovery)
7. Enables SSH by default
8. Strips development headers from the image (keeps runtime libs, saves ~100-150 MB)
9. Shrinks the filesystem to minimum size
10. Compresses with **`xz -3`** (~2-5 min vs 15-30 min for `xz -9`)

**Resulting image fits comfortably on the Limelight 3's 8 GB eMMC** (~350-550 MB
compressed; well under 6 GB uncompressed).

---

## Build Machine Requirements

| Requirement | Notes |
|-------------|-------|
| **OS** | Linux or **WSL2** on Windows (Ubuntu 22.04+ recommended) |
| **Architecture** | x86-64 (amd64) |
| **Disk space** | ≥ 8 GB free in `/tmp` |
| **RAM** | 2 GB minimum |
| **Root / sudo** | Required — loop device mounting |
| **Internet** | Required to download base RPi OS image + apt packages |

### Required packages (minimal)

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

### Recommended: cross-compile toolchain (saves 10-20 min)

If these packages are installed, the script cross-compiles the C++ binary on
the host in ~1-3 min instead of using QEMU emulation (~10-20 min):

```bash
sudo apt-get install -y \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    cmake \
    pkg-config
```

> **WSL2 note:** Ensure WSL2 (not WSL1) is used.  
> Enable systemd: add `[boot]\nsystemd=true` to `/etc/wsl.conf` and restart WSL.  
> Run `sudo modprobe loop` inside WSL2 if loop device errors occur.

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

### What happens

| Step | With cross-compile | QEMU only |
|------|--------------------|-----------|
| Download base image | ~5 min | ~5 min |
| apt-get (firmware + libs) | ~10-15 min | ~10-15 min |
| C++ compilation | ~1-3 min ✓ | ~10-20 min |
| Header strip + filesystem shrink | ~2 min | ~2 min |
| xz -3 compression | ~2-5 min | ~2-5 min |
| **Total** | **~20-30 min** | **~30-47 min** |

### Expected output

```
[BUILD] XNav ISO Builder v1.2.0 — Limelight 3 (CM3/CM4)
[BUILD] Downloading Raspberry Pi OS Lite arm64 (~500 MB)...
...
[BUILD] Installing packages in ARM64 chroot...
[BUILD]   firmware-realtek  — RTL8153B USB ethernet firmware (REQUIRED)
...
[BUILD] Cross-compiling xnav on host (fast path — ~1-3 min)...
...
[BUILD] Cross-compiled: -rwxr-xr-x 1 root root 2.1M /opt/xnav/bin/xnav
[BUILD] Removing development headers (keeping runtime libs)...
[BUILD] Root filesystem after shrink: 1124 MiB
[BUILD] Uncompressed image: 1192 MiB
[BUILD] Compressing with xz -3 (~2-5 min)...
[BUILD] ═══════════════════════════════════════════════════════════════
[BUILD]   Build complete!
[BUILD]   File: /tmp/xnav-build/xnav-1.2.0.img.xz
[BUILD]   Size: 387M
```

The finished image is at:
```
/tmp/xnav-build/xnav-1.2.0.img.xz
```

---

## Step 3 — Flash the Image

### With Raspberry Pi Imager (easiest)

1. Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. **Operating System** → **Use custom** → select `xnav-1.2.0.img.xz`
3. **Storage** → select the Limelight 3 eMMC / SD card
4. Click **Write**

### With balenaEtcher

1. Open [balenaEtcher](https://etcher.balena.io/)
2. **Flash from file** → select `xnav-1.2.0.img.xz`
3. **Select target** → choose the Limelight 3 eMMC
4. **Flash!**

### With command line (Linux)

```bash
xzcat /tmp/xnav-build/xnav-1.2.0.img.xz | \
  sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with the correct target device — verify carefully with `lsblk`.

### Put Limelight 3 into USB Boot Mode (for eMMC flashing)

1. Remove power from the Limelight 3
2. Bridge the **Boot Mode jumper** (`BOOT` / `nBOOT`)
3. Connect a USB-A to USB-A cable: Limelight 3 → computer
4. Apply power — the eMMC appears as a USB storage device
5. Flash the image, then remove power, remove jumper, disconnect USB

---

## Step 4 — First Boot

1. Connect an **Ethernet cable** (required — there is no Wi-Fi)
2. Apply power to the Limelight 3
3. Wait **~30-45 seconds** for boot
4. On first power-on, `xnav-firstboot.service` runs automatically:
   - Loads the `r8152` Realtek USB ethernet module
   - Brings up `eth0` via DHCP
   - **If an internet router is connected** (e.g., home setup): refreshes
     `firmware-realtek` to ensure the latest version
   - Disables itself — future boots skip this step entirely
5. SSH into the device:

```bash
ssh pi@xnav.local         # via mDNS (avahi-daemon)
# or if mDNS is not available:
ssh pi@<IP from router>   # check your router's DHCP table
```

6. Open the web dashboard:
   - `http://xnav.local:5800`
   - or `http://<device-IP>:5800`

### On the robot network (intranet)

After first boot, the device works on any DHCP network — no internet required.
Plug it into the robot Ethernet switch and it will get an IP automatically.
The `firmware-realtek` is already baked into the image, so ethernet works
even without ever connecting to the internet.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `losetup` fails with "no loop devices" | Run `sudo modprobe loop` |
| Download fails | Download manually from [raspberrypi.com/software/operating-systems](https://www.raspberrypi.com/software/operating-systems/) and save as `/tmp/xnav-build/raspios_lite.img` |
| `parted` not found | `sudo apt-get install parted` |
| `qemu-aarch64-static` not found | `sudo apt-get install qemu-user-static binfmt-support` |
| Cross-compile fails, QEMU fallback used | Normal — QEMU build is slower but produces an identical image |
| Ethernet not working after flash | Ensure first-boot ran: `sudo journalctl -u xnav-firstboot` |
| `ssh pi@xnav.local` fails | Try `ssh pi@<IP>` using your router's DHCP table; or check `avahi-daemon` with `systemctl status avahi-daemon` |
| Dashboard not reachable | Wait 30-45 s for boot; check `systemctl status xnav-vision` via SSH |
| CM3/CM4 not detected as USB drive | Ensure BOOT jumper is bridged and power was cycled **after** connecting USB |
| WSL2 loop device issues | Run `sudo modprobe loop` inside WSL2 |

---

## Verifying the Image

```bash
sudo bash system/scripts/verify_iso.sh /tmp/xnav-build/xnav-1.2.0.img.xz
```

This mounts the image and checks for the binary, services, ethernet driver
files, SSH, hostname, and boot config. All checks must pass before flashing.

---

## Size Reference

| Version | Approach | Compressed size | First-boot delay |
|---------|----------|-----------------|-----------------|
| v1.0 (Python) | Python wheels bundled | ~950 MB | 2-5 min (pip install) |
| v1.1 (C++) | QEMU compile, xz -9 | ~350 MB | None |
| **v1.2 (C++)** | Cross-compile, xz -3, ethernet | **~350-550 MB** | **~15 s (eth setup)** |

The C++ rewrite eliminates `opencv-python-headless`, `numpy`, `dt-apriltags`,
`pupil-apriltags`, `pyntcore`, `flask`, `flask-socketio`, and all their
dependencies — the image fits on any microSD card ≥ 4 GB and is well within
the Limelight 3's 8 GB eMMC limit.
