# XNav Build Instructions

## Building the ISO Image

XNav v1.1+ uses a **C++ vision core** — a single binary with no Python dependencies. The ISO build process compiles the binary inside a QEMU ARM64 chroot on your build machine.

### Prerequisites

- Linux system (or **WSL2** on Windows) with root/sudo access
- At least 8 GB free disk space in `/tmp`
- Internet connection (to download RPi OS base image and apt packages)

```bash
sudo apt-get update
sudo apt-get install -y \
    parted e2fsprogs xz-utils curl git util-linux \
    qemu-user-static binfmt-support
```

### Quick Build

```bash
cd /path/to/Limelight3-XNav
sudo bash system/scripts/build_iso.sh
```

### Build Process

1. Download Raspberry Pi OS Lite (64-bit) base image (~500 MB)
2. Mount and expand the image (+512 MB)
3. Inject XNav C++ source, web dashboard, and configuration
4. Download Bootstrap CSS/JS for offline web dashboard
5. **Compile C++ binary in QEMU ARM64 chroot** (installs apt build tools, compiles, removes build tools)
6. Install runtime apt libraries (`libopencv`, `libapriltag3`, `libgpiod2`)
7. Enable systemd service
8. Shrink filesystem to minimum size
9. Compress the image

**Output:** `/tmp/xnav-build/xnav-1.1.0.img.xz`

### Build Time

| Step | Time |
|------|------|
| Download base image | ~5 min |
| QEMU chroot compile | ~15–30 min |
| Compress | ~10–20 min |
| **Total** | **~35–55 min** |

### WSL2 Notes

WSL2 is fully supported. Ensure:
1. You're running WSL2 (not WSL1): `wsl --set-default-version 2`
2. Loop device module is loaded: `sudo modprobe loop`
3. Systemd is enabled in WSL2 (`/etc/wsl.conf`):
   ```ini
   [boot]
   systemd=true
   ```

### Troubleshooting Build Issues

#### Build Fails with "No base image found"

Manually download the base image:
```bash
cd /tmp/xnav-build
wget https://downloads.raspberrypi.org/raspios_lite_arm64_latest
xzcat raspios_lite_arm64_latest | sudo dd of=raspios_lite.img bs=4M status=progress
```

Then re-run the build script (it will skip download).

#### Build Fails with Permission Errors

Ensure you're running with sudo:
```bash
sudo bash system/scripts/build_iso.sh
```

#### QEMU Chroot Build Fails

If the C++ binary fails to compile in the QEMU chroot, the image still boots. SSH into the device and run the on-device build script:
```bash
ssh root@xnav.local
bash /opt/xnav/build_on_device.sh
```
This builds the binary natively on the Raspberry Pi (requires internet on the device).

#### Build Fails During Compression

If you run out of disk space during compression:
```bash
# Build again with less compression (faster, slightly larger)
# Edit build_iso.sh, change:
#   xz -v -T0 -9 "$OUTPUT_IMG"
# To:
#   xz -v -T0 -6 "$OUTPUT_IMG"
```

#### `parted` not found

```bash
sudo apt-get install parted
```

#### `resize2fs` not found

```bash
sudo apt-get install e2fsprogs
```

---

## Manual Installation on Existing Raspberry Pi OS

```bash
git clone https://github.com/realaaravdas/Limelight3-XNav /opt/xnav-src
cd /opt/xnav-src
sudo bash system/scripts/setup.sh
```

---

## Development Build (Build on Device)

To build and run directly on a Raspberry Pi:

```bash
# Install dependencies
sudo apt-get install -y libopencv-dev libapriltag-dev libgpiod-dev cmake g++ pkg-config

# Clone and build
git clone https://github.com/realaaravdas/Limelight3-XNav /opt/xnav-src
mkdir -p /opt/xnav-src/vision_core_cpp/build
cd /opt/xnav-src/vision_core_cpp/build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/xnav
make -j4
sudo make install

# Install web dashboard and config
sudo mkdir -p /opt/xnav
sudo cp -r /opt/xnav-src/web_dashboard /opt/xnav/
sudo mkdir -p /etc/xnav
sudo cp /opt/xnav-src/system/config/default_config.json /etc/xnav/config.json
sudo cp /opt/xnav-src/system/services/xnav-vision.service /etc/systemd/system/
sudo systemctl enable xnav-vision.service
sudo systemctl start xnav-vision.service
```
