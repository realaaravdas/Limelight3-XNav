> **⚠️ This document describes the old Python-based build process (v1.0) and is no longer current.**
> The ISO build has been rewritten in C++ (v1.1+) and no longer uses Python, pip, or wheels.
> See **[build_iso.md](build_iso.md)** for the current build instructions.

---

# Building XNav ISO for Offline Deployment (Legacy — v1.0 Python build)

XNav is designed to work offline on the Limelight device. The ISO build process includes all Python dependencies pre-bundled, so no internet connection is required during first-boot setup.

## Overview

The Limelight device only has LAN connectivity (to the robot network) and cannot access the internet. To handle this, the build process:

1. **Pre-downloads all Python wheels** during the ISO build phase (on a machine with internet)
2. **Bundles the wheels** into the ISO image in `/opt/xnav/wheels/`
3. **Installs from local wheels** during first boot (no internet required)

## Building the ISO

### Prerequisites

- Linux system with root/sudo access
- 3GB+ free disk space (for temporary files)
- Internet connection (for downloading base OS image and Python packages)

### Quick Build

```bash
cd /path/to/Limelight3-XNav
sudo bash system/scripts/build_iso.sh
```

This will:

1. Download Raspberry Pi OS Lite (64-bit) base image (~500MB)
2. Download all Python dependencies as wheels (~100-200MB)
3. Inject XNav code and pre-downloaded wheels
4. Create flashable ISO: `xnav-1.1.0.img.xz`

### Output

The output file will be named `xnav-1.1.0.img.xz` and located in `/tmp/xnav-build/`.

### ISO Size

- Base Raspberry Pi OS Lite: ~2.0 GB (uncompressed)
- XNav + Python wheels: ~500 MB
- Total: ~2.5 GB (uncompressed)
- Compressed (.xz): ~800 MB

This fits easily on the 7.8 GB flash limit.

## Installation

### Using Raspberry Pi Imager

```bash
# Uncompress first
xzcat xnav-1.1.0.img.xz > xnav-1.1.0.img

# Use Raspberry Pi Imager GUI to flash
# Or use command line:
sudo dd if=xnav-1.1.0.img of=/dev/sdX bs=4M status=progress
```

### First Boot

When the Limelight boots for the first time:

1. Wait 2-5 minutes for first-boot setup to complete
2. The device will install Python packages from pre-bundled wheels (offline)
3. Services will start automatically
4. Access the dashboard at `http://xnav.local:5800`

Monitor progress via SSH:
```bash
ssh root@xnav.local
cat /var/log/xnav-firstboot.log
```

## Troubleshooting

### Build fails downloading base image

Manually download the base image:
```bash
wget https://downloads.raspberrypi.org/raspios_lite_arm64_latest
```

Then run the build script - it will use the downloaded file.

### Build fails downloading Python wheels

Check your internet connection. The build script uses pip to download wheels from PyPI.

### First boot hangs or services don't start

Check the first-boot log:
```bash
ssh root@xnav.local
cat /var/log/xnav-firstboot.log
```

Common issues:
- Missing wheels: Build process failed to download them
- Venv creation failed: Check Python 3 is installed on base image

### Wheel installation fails

If pip can't install from wheels, check:
- Wheels directory exists: `/opt/xnav/wheels/`
- Wheel files match architecture: `*.whl` files present
- Python version compatibility: Wheels for Python 3.11+ required

## Manual Installation (Alternative)

If you have an existing Raspberry Pi with internet access:

```bash
# Clone the repo
git clone https://github.com/realaaravdas/Limelight3-XNav /opt/xnav-src

# Run setup script (downloads packages online)
sudo bash /opt/xnav-src/system/scripts/setup.sh
```

## Architecture Details

### Wheel Bundling Process

The `build_iso.sh` script:

1. Creates a temporary virtual environment on the build machine
2. Downloads all requirements from `vision_core/requirements.txt`
3. Saves them as wheels: `pip download -r requirements.txt --dest wheels`
4. Copies wheels to ISO: `/opt/xnav/wheels/*.whl`

### First-Boot Installation

The `first_boot.sh` script (running on the device):

1. Creates virtual environment: `python3 -m venv /opt/xnav/venv`
2. Installs from local wheels: `pip install --no-index --find-links=/opt/xnav/wheels`
3. No internet connection required!

### Dependencies

The bundled wheels include:
- opencv-python-headless
- numpy
- pupil-apriltags
- robotpy-ntcore (and dependencies)
- flask, flask-socketio
- gevent, gevent-websocket
- Pillow, and more

See `vision_core/requirements.txt` for the full list.

## Advanced: Custom Wheelhouse

To update or customize the bundled packages:

1. Create a custom wheelhouse:
```bash
python3 -m venv /tmp/wheel-env
source /tmp/wheel-env/bin/activate
pip download -r vision_core/requirements.txt --dest /tmp/wheelhouse
```

2. Copy to your build:
```bash
cp /tmp/wheelhouse/*.whl /path/to/system/wheelhouse/
```

3. Modify `build_iso.sh` to use your custom wheelhouse instead of downloading.

## Size Considerations

The wheelhouse is approximately 150-200 MB. This is included in the ISO and remains on the device after installation.

To save space on the device, you could delete `/opt/xnav/wheels` after first boot:
```bash
ssh root@xnav.local
rm -rf /opt/xnav/wheels
```

However, keeping it allows for easy reinstallation if needed.
