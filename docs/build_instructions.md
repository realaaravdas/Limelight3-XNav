# XNav Build Instructions

## Building the ISO Image

This guide explains how to build a flashable Raspberry Pi OS image with XNav pre-installed.

### Prerequisites

- Ubuntu 22.04 LTS (recommended) or Ubuntu 20.04 / Debian 11+
- At least 4 GB free disk space
- Internet connection (to download base image ~500 MB)
- `xz`, `parted`, `e2fsprogs`, `curl` installed (see below)

```bash
sudo apt-get update
sudo apt-get install -y parted e2fsprogs xz-utils curl git util-linux
```

### Quick Build

```bash
cd /path/to/Limelight3-XNav
sudo bash system/scripts/build_iso.sh
```

The build process will:
1. Download Raspberry Pi OS Lite (64-bit) base image (~500 MB)
2. Mount and expand the image by 512 MB (XNav source files only — no pre-bundled packages)
3. Inject XNav files, configuration, and systemd services
4. Inject `xnav-firstboot.service` (runs once on device to install Python packages)
5. Shrink and compress the final image

**Output:** `xnav-1.1.0.img.xz`

### Build Time (Ubuntu 22.04)

| Step | Duration |
|------|----------|
| Download base image | 1–3 min (network dependent) |
| Image preparation & injection | ~1 min |
| Compression (`xz -3`) | ~2–4 min |
| **Total** | **~5–10 min** |

> **Note:** The old build used a QEMU ARM64 chroot (10–30 min) and downloaded Python wheels (~200 MB). Both are eliminated — Python packages are installed on the device at first boot instead.

### Detailed Build Process

#### 1. Download Base Image

The script downloads the official Raspberry Pi OS Lite (64-bit) from:
```
https://downloads.raspberrypi.org/raspios_lite_arm64_latest
```

#### 2. Image Preparation

- Decompress the base image
- Expand by 512 MB for XNav source files
- Mount boot and root partitions

#### 3. File Injection

The following are copied to the image:

**Application Files:**
- `/opt/xnav/vision_core/` - Vision processing code
- `/opt/xnav/web_dashboard/` - Flask web interface

**Configuration:**
- `/etc/xnav/config.json` - Default configuration
- `/etc/xnav/first_boot.sh` - First-boot setup script (runs via systemd)
- `/etc/hostname` - Set to "xnav"
- `/etc/hosts` - Hostname mapping
- `/boot/config.txt` - Boot configuration (camera, GPU memory)
- `/etc/network/interfaces.d/eth0` - Network configuration (DHCP)
- `/etc/udev/rules.d/70-limelight-ethernet.rules` - Names Realtek USB adapter "eth0"
- `/etc/modules-load.d/usb-ethernet.conf` - Loads r8152 module on boot

**Systemd Services:**
- `/etc/systemd/system/xnav-firstboot.service` - One-shot first-boot installer (auto-enabled)
- `/etc/systemd/system/xnav-vision.service` - Vision pipeline service (auto-enabled)
- `/etc/systemd/system/xnav-dashboard.service` - Web dashboard service (auto-enabled)

#### 4. First-Boot Setup (on device)

On first power-on, `xnav-firstboot.service` (a systemd oneshot unit) automatically:

1. Brings up the RTL8153 USB ethernet (`eth0`) via DHCP
2. Waits up to 60 s for internet connectivity
3. Installs system packages via apt: `firmware-realtek`, `python3-opencv`, `python3-numpy`, `python3-rpi.gpio`, `python3-venv`, `python3-pip`
4. Creates a Python venv at `/opt/xnav/venv/` with `--system-site-packages`
5. pip-installs `dt-apriltags`, `pyntcore`, `flask`, `flask-socketio`
6. Caches web dashboard vendor files for offline use
7. Logs progress to `/var/log/xnav-firstboot.log`

**Important:** The first boot requires internet. Connect to a router with internet access. After first boot the device works fully offline on the robot intranet.

On every subsequent boot, systemd detects `/opt/xnav/venv` exists and skips `xnav-firstboot.service` instantly, so the XNav services start right away.

**First-boot time:** ~3–5 minutes

### Service Architecture

XNav runs three systemd services:

#### xnav-firstboot.service
- **Purpose:** One-time internet install of Python packages (runs only when `/opt/xnav/venv` is absent)
- **Type:** oneshot (runs to completion then exits)
- **Must complete before:** xnav-vision and xnav-dashboard

#### xnav-vision.service
- **Purpose:** Core vision pipeline (AprilTag detection, NT4 publishing)
- **Port:** None (internal)
- **Dependencies:** Network + xnav-firstboot
- **Priority:** High (CPU cores 0-3, nice=-10, realtime I/O)
- **Environment:** `XNAV_DISABLE_DASHBOARD=1` (to prevent duplicate dashboard)

#### xnav-dashboard.service
- **Purpose:** Web configuration interface
- **Port:** 5800 (HTTP)
- **Dependencies:** Network + xnav-firstboot + vision service
- **Priority:** Normal

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

#### Build Fails During Compression

If you run out of disk space during compression:
```bash
# Clean up temporary files
cd /tmp
rm -rf xnav-build

# Build again (compression is already at level 3, the fastest useful level)
sudo bash system/scripts/build_iso.sh
```

## Flashing the Image

### Using Raspberry Pi Imager (Recommended)

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Open Raspberry Pi Imager
3. Click "Choose OS" → "Use custom image" → select `xnav-1.1.0.img.xz`
4. Click "Choose Storage" → select your CM4 eMMC or SD card
5. Click "Write" and wait for completion

### Using balenaEtcher

1. Download [balenaEtcher](https://etcher.balena.io/)
2. Click "Flash from file" → select `xnav-1.1.0.img.xz`
3. Click "Select target" → choose your CM4 eMMC / SD card
4. Click "Flash!" and wait for completion

### Using Command Line (Linux)

```bash
# Decompress and flash
xzcat xnav-1.1.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
sync

# Replace /dev/sdX with your device (e.g., /dev/sda, /dev/mmcblk0)
# Be careful - this will erase all data on the device!
```

### Using Command Line (macOS)

```bash
# Find your device
diskutil list

# Unmount the disk (replace N with disk number)
diskutil unmountDisk /dev/diskN

# Decompress and flash
xzcat xnav-1.1.0.img.xz | sudo dd of=/dev/rdiskN bs=4m status=progress
sync
```

## First Boot

> **Internet required on first boot.** Connect the device to a router with internet access. After first boot the device works fully offline on the robot intranet.

After flashing and powering on the device:

1. **Connect to a router with internet access** via Ethernet
2. Apply power — `xnav-firstboot.service` starts automatically
3. **Wait 3–5 minutes** for first-boot setup to complete
4. Check status via SSH:
   ```bash
   ssh pi@xnav.local
   sudo journalctl -u xnav-firstboot.service -f
   # or
   sudo tail -f /var/log/xnav-firstboot.log
   ```
5. Access web dashboard: `http://xnav.local:5800`
6. Configure your team number and other settings

On every subsequent boot (including on the robot's intranet) the device starts immediately — the firstboot service is skipped automatically.

### First-Boot Status Indicators

**Working correctly:**
- Device responds to ping
- `xnav-firstboot.service` shows `active (exited)` in journalctl
- Services start after ~3–5 minutes
- Dashboard accessible at port 5800

**Issues:**
- Services fail to start: Check `sudo journalctl -u xnav-firstboot.service`
- "No internet connectivity" error: Ensure Ethernet is connected to a www router
- Dashboard not accessible: See [Troubleshooting Guide](troubleshooting.md)

## Version Information

Current XNav version: `1.1.0`

To check installed version (after flashing):
```bash
cat /etc/xnav/version
# Or check git tag if building from source
cd /path/to/Limelight3-XNav
git describe --tags
```

## Updating an Existing Installation

If you have XNav already installed and want to update:

```bash
# SSH into device
ssh pi@xnav.local

# Pull latest changes
cd /opt/xnav-src
git pull

# Re-run setup
sudo bash system/scripts/setup.sh

# Reboot
sudo reboot
```

**Note:** This will update code but preserve your configuration in `/etc/xnav/config.json`.

## Customizing the Build

### Changing Default Configuration

Edit `system/config/default_config.json` before building:

```bash
nano system/config/default_config.json
```

Common customizations:
- Team number
- Camera settings
- Network configuration
- AprilTag parameters

### Adding Additional pip Packages

Edit `vision_core/requirements-pip.txt` before building. These packages are pip-installed on first boot:

```
dt-apriltags>=3.0.0
pyntcore>=2024.0.0
flask>=3.0.0
flask-socketio>=5.3.0
my-extra-package>=1.0.0   # add here
```

### Changing Hostname

Edit the build script near the hostname section:

```bash
# In system/scripts/build_iso.sh, find:
echo "xnav" > "$ROOT/etc/hostname"

# Change to your preferred hostname
echo "myxnav" > "$ROOT/etc/hostname"
echo "127.0.1.1    myxnav" >> "$ROOT/etc/hosts"
```

### Changing Web Port

Edit `system/config/default_config.json`:

```json
{
  "web_port": 5800
}
```

Or configure via dashboard after installation.

## Support

For build issues:
1. Check this guide
2. Review [Troubleshooting Guide](troubleshooting.md)
3. Check GitHub Issues: https://github.com/realaaravdas/Limelight3-XNav/issues
