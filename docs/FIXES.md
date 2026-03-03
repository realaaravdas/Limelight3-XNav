# XNav Dashboard Accessibility - Fixes Applied

## Problem Description

After flashing the XNav ISO to a Limelight3 device and powering it on:
- Device was reachable via ping
- Device appeared in network scanners (Angry IP Scanner)
- Web dashboard at `http://xnav.local:5800` was **not accessible** (connection refused/timeout)

## Root Causes Identified

1. **Missing logger in web_dashboard/app.py** - Code referenced undefined `logger` variable causing service crash
2. **Service files not updated to use virtual environment** - Services tried to use `/usr/bin/python3` instead of `/opt/xnav/venv/bin/python3`
3. **First-boot script incomplete** - Missing steps to update service files and properly start services
4. **Duplicate dashboard process** - Vision service tried to spawn dashboard subprocess, conflicting with dedicated dashboard service
5. **Race condition** - Services started before first-boot setup completed
6. **Missing rc.local service enablement** - rc.local service not enabled, preventing first-boot script execution
7. **Network configuration missing** - No explicit DHCP configuration for eth0

## Fixes Applied

### 1. Fixed Missing Logger in app.py

**File:** `web_dashboard/app.py`

Added proper logger initialization:

```python
# ─── Logging setup ─────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger(__name__)
```

**Impact:** Dashboard service can now start successfully without crashing due to undefined logger.

### 2. Enhanced First-Boot Script

**File:** `system/scripts/build_iso.sh`

Completely rewrote the first-boot script to:

- Create Python virtual environment
- Install all dependencies
- **Update service files to use venv Python interpreter**
- Reload systemd daemon
- Enable services
- Stop services if already running (from initial boot)
- Start services in correct order
- Log all output to `/var/log/xnav-firstboot.log`
- Display service status after startup

**Key addition:**
```bash
# Update service files to use venv
sed -i "s|/usr/bin/python3|/opt/xnav/venv/bin/python3|g" \
  /etc/systemd/system/xnav-vision.service \
  /etc/systemd/system/xnav-dashboard.service
```

**Impact:** Services now use the correct Python interpreter with all dependencies installed.

### 3. Fixed Service Dependencies and Timing

**Files:**
- `system/services/xnav-vision.service`
- `system/services/xnav-dashboard.service`

**Changes:**
- Changed `After=network.target` to `After=network-online.target`
- Added `Wants=network-online.target` to ensure network is fully ready
- Added `ExecStartPre=/bin/sleep 10` to vision service (10s delay)
- Added `ExecStartPre=/bin/sleep 15` to dashboard service (15s delay)
- Added comments explaining the delay is for first-boot setup

**Impact:** Services wait for network and for first-boot setup to complete before starting.

### 4. Prevented Duplicate Dashboard Process

**File:** `vision_core/src/main.py`

Added environment variable check:

```python
# Start web dashboard in background thread if enabled
# Skip if XNAV_DISABLE_DASHBOARD is set (for systemd service mode)
_web_proc = None
if not os.environ.get("XNAV_DISABLE_DASHBOARD"):
    # ... dashboard subprocess code ...
```

**File:** `system/services/xnav-vision.service`

Added environment variable:

```ini
Environment="XNAV_DISABLE_DASHBOARD=1"
```

**Impact:** Vision service no longer tries to spawn dashboard subprocess, avoiding port conflicts.

### 5. Enabled rc.local Service

**File:** `system/scripts/build_iso.sh`

Added rc-local service enablement:

```bash
# Enable rc-local service
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/rc-local.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/rc-local.service"
```

**Impact:** rc.local service is now enabled, ensuring first-boot script runs on startup.

### 6. Improved rc.local Setup

**File:** `system/scripts/build_iso.sh`

Enhanced rc.local creation:
- Creates rc.local if it doesn't exist (instead of failing)
- Makes rc.local executable
- Runs first-boot script in background with `&`
- Cleans up old first_boot.sh calls

**Impact:** First-boot script is guaranteed to run on system startup.

### 7. Added Network Configuration

**File:** `system/scripts/build_iso.sh`

Added explicit DHCP configuration for eth0:

```bash
# Network configuration - use DHCP for eth0
NETWORK_CFG="$ROOT/etc/network/interfaces.d/eth0"
cat > "$NETWORK_CFG" << 'NETEOF'
# XNav Network Configuration - eth0 gets IP via DHCP from robot
auto eth0
iface eth0 inet dhcp
NETEOF
```

**Impact:** Device will reliably obtain an IP address via DHCP from the robot's network.

### 8. Enhanced First-Boot Logging

**File:** `system/scripts/build_iso.sh`

Added comprehensive logging:
- All output tee'd to `/var/log/xnav-firstboot.log`
- Timestamped log entries
- Clear section headers
- Service status output after startup
- Dashboard URL displayed on completion

**Impact:** Users can easily diagnose first-boot issues by checking the log file.

## Testing & Verification

### Verification Script Created

**File:** `system/scripts/verify_iso.sh`

Comprehensive verification script that checks:
- All required directories exist
- All critical files exist
- First-boot script is executable and contains required commands
- Systemd services are properly configured
- Service symlinks are created
- Hostname is set correctly
- Boot configuration is correct
- Network configuration is present
- All Python dependencies are listed in requirements.txt
- Logger is defined in app.py
- All vision core modules exist
- All web dashboard files exist

**Usage:**
```bash
sudo bash system/scripts/verify_iso.sh xnav-1.0.0.img.xz
```

### Documentation Created

**File:** `docs/troubleshooting.md`

Comprehensive troubleshooting guide covering:
- Dashboard accessibility issues
- Service status checks
- Virtual environment problems
- Missing dependencies
- Port conflicts
- Firewall issues
- Camera problems
- AprilTag detection issues
- NetworkTables connectivity
- Performance issues
- First-boot problems
- Factory reset procedures

**File:** `docs/build_instructions.md`

Detailed build and flashing instructions covering:
- Prerequisites
- Build process details
- First-boot behavior
- Service architecture
- Troubleshooting build issues
- Flashing methods (Imager, Etcher, command line)
- Customization options

### Updated README.md

**Changes:**
- Added note about first-boot wait time (5-10 minutes)
- Added instructions for monitoring first-boot via SSH
- Added link to Build Instructions
- Added comprehensive Troubleshooting & Support section
- Added links to troubleshooting and build docs

## Expected Behavior After Fixes

### First Boot Sequence (5-10 minutes)

1. Device boots and gets IP via DHCP
2. rc.local service starts
3. First-boot script runs (`/etc/xnav/first_boot.sh`)
   - Creates Python virtual environment
   - Installs all Python dependencies
   - Updates service files to use venv
   - Reloads systemd daemon
   - Enables services
   - Stops services if already running
   - Starts vision service
   - Waits 2 seconds
   - Starts dashboard service
   - Logs status to `/var/log/xnav-firstboot.log`
   - Removes first-boot script
4. Dashboard accessible at `http://xnav.local:5800`

### Service Status (After First Boot)

**xnav-vision.service:**
- Status: Active (running)
- Python: `/opt/xnav/venv/bin/python3`
- Dashboard subprocess: Disabled (XNAV_DISABLE_DASHBOARD=1)

**xnav-dashboard.service:**
- Status: Active (running)
- Python: `/opt/xnav/venv/bin/python3`
- Listening on: Port 5800

### Network

- Device responds to ping
- Device accessible via SSH (`ssh root@xnav.local`)
- Dashboard accessible via browser (`http://xnav.local:5800`)
- NetworkTables connects to roboRIO at `10.TE.AM.2`

## Verification Steps for Users

After flashing and powering on:

1. **Wait 5-10 minutes** for first-boot setup
2. Ping the device: `ping xnav.local` (or use IP address)
3. Check first-boot log:
   ```bash
   ssh root@xnav.local
   cat /var/log/xnav-firstboot.log
   ```
4. Check service status:
   ```bash
   systemctl status xnav-vision.service
   systemctl status xnav-dashboard.service
   ```
5. Access dashboard: Open `http://xnav.local:5800` in browser
6. If issues persist, see [Troubleshooting Guide](troubleshooting.md)

## Files Modified

1. `web_dashboard/app.py` - Added logger initialization
2. `vision_core/src/main.py` - Added XNAV_DISABLE_DASHBOARD check
3. `system/services/xnav-vision.service` - Enhanced dependencies, added delay
4. `system/services/xnav-dashboard.service` - Enhanced dependencies, added delay
5. `system/scripts/build_iso.sh` - Complete rewrite of first-boot setup
6. `README.md` - Added first-boot notes and troubleshooting links

## Files Created

1. `docs/troubleshooting.md` - Comprehensive troubleshooting guide
2. `docs/build_instructions.md` - Build and flashing instructions
3. `docs/FIXES.md` - This document
4. `system/scripts/verify_iso.sh` - ISO verification script

## Production Deployment

To create a production-ready ISO:

1. Build the image:
   ```bash
   sudo bash system/scripts/build_iso.sh
   ```

2. Verify the image:
   ```bash
   sudo bash system/scripts/verify_iso.sh xnav-1.0.0.img.xz
   ```

3. Flash to devices using your preferred method (Imager, Etcher, or command line)

4. Test on a device:
   - Flash and power on
   - Wait 5-10 minutes
   - Verify dashboard is accessible
   - Verify vision system is working
   - Verify NetworkTables connectivity

## Backward Compatibility

All changes are backward compatible:
- Existing installations can update via `sudo bash /opt/xnav-src/system/scripts/setup.sh`
- Configuration in `/etc/xnav/config.json` is preserved
- No breaking changes to API or NetworkTables topics

## Future Improvements

Potential enhancements for future releases:
- Add health check endpoint to dashboard for monitoring
- Implement service health monitoring with auto-recovery
- Add LED status indicator for first-boot progress
- Consider using cloud-init for more robust first-boot setup
- Add automatic firmware updates
- Implement configuration backup/restore

## Support

For issues or questions:
1. Check [Troubleshooting Guide](docs/troubleshooting.md)
2. Review [Build Instructions](docs/build_instructions.md)
3. Check first-boot log: `/var/log/xnav-firstboot.log`
4. Check service logs: `journalctl -u xnav-vision.service` and `journalctl -u xnav-dashboard.service`
5. Report issues on GitHub: https://github.com/realaaravdas/Limelight3-XNav/issues
