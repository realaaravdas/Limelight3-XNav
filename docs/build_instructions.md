# XNav Build Instructions

## Building the ISO Image

This guide explains how to build a flashable Raspberry Pi OS image with XNav pre-installed.

### Prerequisites

- Linux system with root/sudo access
- At least 8GB free disk space
- Internet connection
- `xz` utility (for compression)
- `curl` or `wget`

### Quick Build

```bash
cd /path/to/Limelight3-XNav
sudo bash system/scripts/build_iso.sh
```

The build process will:
1. Download Raspberry Pi OS Lite (64-bit) base image
2. Mount and expand the image
3. Inject XNav files and configuration
4. Set up first-boot installation script
5. Compress the final image

**Output:** `xnav-1.0.0.img.xz`

### Build Time

- Download base image: ~500 MB (varies by connection)
- Build process: 5-10 minutes
- Compression: 10-20 minutes

Total: ~15-40 minutes

### Detailed Build Process

#### 1. Download Base Image

The script downloads the official Raspberry Pi OS Lite (64-bit) from:
```
https://downloads.raspberrypi.org/raspios_lite_arm64_latest
```

#### 2. Image Preparation

- Decompress the base image
- Expand by 2GB for XNav packages
- Mount boot and root partitions

#### 3. File Injection

The following are copied to the image:

**Application Files:**
- `/opt/xnav/vision_core/` - Vision processing code
- `/opt/xnav/web_dashboard/` - Flask web interface

**Configuration:**
- `/etc/xnav/config.json` - Default configuration
- `/etc/xnav/first_boot.sh` - First-boot setup script
- `/etc/hostname` - Set to "xnav"
- `/etc/hosts` - Hostname mapping
- `/boot/config.txt` - Boot configuration (camera, GPU memory)
- `/etc/network/interfaces.d/eth0` - Network configuration (DHCP)

**Systemd Services:**
- `/etc/systemd/system/xnav-vision.service` - Vision pipeline service
- `/etc/systemd/system/xnav-dashboard.service` - Web dashboard service
- `/etc/systemd/system/multi-user.target.wants/` - Service symlinks

#### 4. First-Boot Setup

On first boot, `/etc/xnav/first_boot.sh` (run via `/etc/rc.local`) will:

1. Create Python virtual environment at `/opt/xnav/venv/`
2. Install Python dependencies from `requirements.txt`
3. Update service files to use venv Python interpreter
4. Reload systemd daemon
5. Enable and start services
6. Log progress to `/var/log/xnav-firstboot.log`
7. Remove itself to prevent re-running

**Important:** The first-boot process takes 5-10 minutes, depending on:
- Internet connection speed (for pip downloads)
- Raspberry Pi CM4 model
- Network performance

During this time, the services may restart multiple times as dependencies are installed.

### Service Architecture

XNav runs two systemd services:

#### xnav-vision.service
- **Purpose:** Core vision pipeline (AprilTag detection, NT4 publishing)
- **Port:** None (internal)
- **Dependencies:** Network
- **Priority:** High (CPU cores 0-3, nice=-10, realtime I/O)
- **Environment:** `XNAV_DISABLE_DASHBOARD=1` (to prevent duplicate dashboard)

#### xnav-dashboard.service
- **Purpose:** Web configuration interface
- **Port:** 5800 (HTTP)
- **Dependencies:** Network + vision service
- **Priority:** Normal
- **Environment:** `XNAV_CONFIG=/etc/xnav/config.json`

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

#### Image Too Large

The script expands the image by 2GB. If you need more space:
```bash
# Edit build_iso.sh line 86
# Change: truncate -s +2G "$OUTPUT_IMG"
# To:      truncate -s +4G "$OUTPUT_IMG"
```

#### Build Fails During Compression

If you run out of disk space during compression:
```bash
# Clean up temporary files
cd /tmp
rm -rf xnav-build

# Build again with less compression
# Edit build_iso.sh line 165
# Change: xz -v -T0 -9 "$OUTPUT_IMG"
# To:      xz -v -T0 -6 "$OUTPUT_IMG"
```

## Flashing the Image

### Using Raspberry Pi Imager (Recommended)

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Open Raspberry Pi Imager
3. Click "Choose OS" → "Use custom image" → select `xnav-1.0.0.img.xz`
4. Click "Choose Storage" → select your CM4 eMMC or SD card
5. Click "Write" and wait for completion

### Using balenaEtcher

1. Download [balenaEtcher](https://etcher.balena.io/)
2. Click "Flash from file" → select `xnav-1.0.0.img.xz`
3. Click "Select target" → choose your CM4 eMMC / SD card
4. Click "Flash!" and wait for completion

### Using Command Line (Linux)

```bash
# Decompress and flash
xzcat xnav-1.0.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
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
xzcat xnav-1.0.0.img.xz | sudo dd of=/dev/rdiskN bs=4m status=progress
sync
```

## First Boot

After flashing and powering on the device:

1. **Wait 5-10 minutes** for first-boot setup to complete
2. Check status via SSH (default hostname: `xnav.local`):
   ```bash
   ssh root@xnav.local
   # Check first-boot log
   cat /var/log/xnav-firstboot.log
   ```
3. Access web dashboard: `http://xnav.local:5800`
4. Configure your team number and other settings

### First-Boot Status Indicators

**Working correctly:**
- Device responds to ping
- First-boot script runs (check `/var/log/xnav-firstboot.log`)
- Services start after ~5-10 minutes
- Dashboard accessible at port 5800

**Issues:**
- Services fail to start: Check `/var/log/xnav-firstboot.log`
- Dashboard not accessible: See [Troubleshooting Guide](troubleshooting.md)
- No network connection: Check ethernet cable and robot network

## Version Information

Current XNav version: `1.0.0`

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
ssh root@xnav.local

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

### Adding Additional Packages

Edit the first-boot script in `build_iso.sh`:

```bash
# Find the pip install line
pip install -r /opt/xnav/vision_core/requirements.txt -q

# Add custom packages
pip install <package-name> -q
```

### Changing Hostname

Edit the build script:

```bash
# Find line 144
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
