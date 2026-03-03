# Offline Installation Implementation - Summary

## Problem Statement

The Limelight3-XNav device only has LAN connectivity (to the robot network) and cannot access the internet. The original ISO build process required an internet connection during first boot to download Python dependencies via pip, which would fail on the offline device.

## Solution

Implemented a pre-bundled Python dependency wheelhouse system that downloads all required packages during the ISO build phase (on a machine with internet) and bundles them into the ISO image for offline installation during first boot.

## Changes Made

### 1. Updated `build_iso.sh`

**Changes:**
- Increased image size from 2GB to 3GB to accommodate bundled wheels
- Added wheelhouse download section that:
  - Creates a temporary virtual environment
  - Downloads all packages from `requirements.txt` as wheels
  - Copies wheels to `/opt/xnav/wheels/` in the ISO
- Modified `first_boot.sh` script to install from local wheels instead of PyPI:
  - Uses `pip install --no-index --find-links=/opt/xnav/wheels`
  - No internet connection required

**Location:** `/system/scripts/build_iso.sh`

### 2. Updated `setup.sh` (Manual Installation)

**Changes:**
- Added offline detection logic:
  - Checks if `/opt/xnav/wheels/` directory exists and contains wheels
  - If wheels are present: installs offline using `pip install --no-index`
  - If no wheels: falls back to online installation (for dev setups)

**Location:** `/system/scripts/setup.sh`

### 3. Fixed `requirements.txt`

**Changes:**
- Changed `robotpy-ntcore>=2024.0.0` → `pyntcore>=2024.0.0`
- The correct package name for NetworkTables 4 is `pyntcore`, not `robotpy-ntcore`

**Location:** `/vision_core/requirements.txt`

### 4. Created `download_wheels.sh`

**New File:**
- Utility script to download Python wheels for testing
- Can be used independently to create a wheelhouse
- Downloads wheels for the current architecture

**Location:** `/system/scripts/download_wheels.sh`

### 5. Updated Documentation

**Changes:**
- Updated `README.md` to clarify offline installation
- Added reference to new `docs/build_offline.md`
- Created comprehensive `docs/build_offline.md` documenting:
  - Offline build process
  - First-boot installation details
  - Troubleshooting guide
  - Size considerations

### 6. Updated `.gitignore`

**Added:**
- `/system/wheelhouse/` - to exclude downloaded wheels from git (optional)
- Wheelhouse can be optionally committed if desired

## How It Works

### Build Phase (On Builder Machine with Internet)

1. Download Raspberry Pi OS Lite base image (~500MB)
2. Download all Python dependencies as wheels (~95MB):
   - Creates temporary venv
   - Runs `pip download -r requirements.txt --dest wheels`
   - Saves 29 wheel files
3. Inject XNav code + wheels into ISO
4. Create final ISO: ~2.5GB (uncompressed), ~800MB (compressed with xz)

### Installation Phase (On Limelight Device - No Internet)

1. Flash ISO to SD card
2. Boot device
3. First-boot script runs:
   - Creates virtual environment: `python3 -m venv /opt/xnav/venv`
   - Installs from bundled wheels: `pip install --no-index --find-links=/opt/xnav/wheels`
   - No internet required!
   - Takes 2-5 minutes
4. Services start automatically
5. Dashboard accessible at `http://xnav.local:5800`

## Package List (29 wheels)

Core dependencies:
- opencv-python-headless (60.4 MB) - Computer vision
- numpy (16.6 MB) - Numerical computing
- pupil-apriltags (4.9 MB) - AprilTag detection
- pyntcore (1.5 MB) - NetworkTables 4
- pillow (7.0 MB) - Image processing

NetworkTables dependencies:
- robotpy-native-ntcore (655 KB)
- robotpy-native-wpinet (667 KB)
- robotpy-native-wpiutil (2.6 MB)
- robotpy-wpinet (116 KB)
- robotpy-wpiutil (657 KB)

Web dashboard:
- flask (103 KB) - Web framework
- flask-socketio (18 KB) - WebSocket support
- gevent (2.1 MB) - Async networking
- gevent-websocket (22 KB) - WebSocket transport

And supporting libraries: python-socketio, python-engineio, simple-websocket, werkzeug, click, itsdangerous, jinja2, markupsafe, blinker, bidict, wsproto, h11, zope.event, zope.interface, greenlet

Total wheelhouse size: ~95 MB

## ISO Size Analysis

- Base Raspberry Pi OS Lite: ~2.0 GB
- XNav application code: ~5 MB
- Python wheels: ~95 MB
- Virtual environment (after install): ~300 MB
- Total required: ~2.4 GB

Final compressed ISO: ~800 MB (well under 7.8 GB flash limit)

## Backwards Compatibility

The implementation maintains backwards compatibility:

1. **Manual Installation:** The `setup.sh` script detects if wheels are present
   - With wheels: installs offline
   - Without wheels: installs from PyPI (online mode)

2. **Development:** Developers can use the existing venv installation method

3. **ISO Building:** Build process automatically bundles wheels; no manual steps needed

## Testing

To test the offline installation without building a full ISO:

```bash
# Download wheels
bash system/scripts/download_wheels.sh /tmp/wheels

# Test installation (on a Raspberry Pi)
python3 -m venv /tmp/test_venv
source /tmp/test_venv/bin/activate
pip install --no-index --find-links=/tmp/wheels -r vision_core/requirements.txt
```

## Future Improvements

Potential enhancements for future releases:

1. **Multi-platform wheels:** Bundle both ARM64 and ARMv6/7 wheels for compatibility
2. **Wheelhouse cleanup:** Add option to delete wheels after installation to save space
3. **Delta updates:** Support for updating individual packages offline
4. **Custom wheelhouse:** Allow users to add custom packages to the wheelhouse

## Troubleshooting

### Issue: First boot hangs

**Solution:** Check `/var/log/xnav-firstboot.log` - verify wheels are present and installation is progressing

### Issue: Wheel installation fails

**Solution:**
1. Verify `/opt/xnav/wheels/` contains wheel files
2. Check Python version compatibility (requires Python 3.11+)
3. Ensure architecture matches (ARM64 wheels for CM4)

### Issue: Build fails downloading wheels

**Solution:**
1. Check internet connection on build machine
2. Verify PyPI is accessible
3. Try manually running: `bash system/scripts/download_wheels.sh`

## Conclusion

The offline installation implementation ensures that Limelight3-XNav can be deployed on completely air-gapped networks while maintaining a simple, reliable installation process. All Python dependencies are bundled in the ISO, and first-boot setup requires no internet connectivity.
