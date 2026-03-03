# XNav Troubleshooting Guide

## Dashboard Not Accessible

### Symptoms
- Device is reachable via ping
- Device appears in network scanners (Angry IP Scanner, etc.)
- Web dashboard at `http://xnav.local:5800` or `http://<IP>:5800` shows connection refused/timeout

### Common Causes and Solutions

#### 1. Services Not Running

Check if services are running:
```bash
ssh root@xnav.local
# or use IP: ssh root@<device-IP>

# Check service status
systemctl status xnav-vision.service
systemctl status xnav-dashboard.service
```

**If services are failed or inactive:**

```bash
# View service logs
journalctl -u xnav-vision.service -n 50 --no-pager
journalctl -xnav-dashboard.service -n 50 --no-pager

# Check first-boot log
cat /var/log/xnav-firstboot.log

# Restart services
systemctl restart xnav-vision.service
systemctl restart xnav-dashboard.service
```

#### 2. Virtual Environment Not Created

The first-boot script should create a Python virtual environment. Check if it exists:
```bash
ls -la /opt/xnav/venv
```

**If venv doesn't exist, run setup manually:**
```bash
cd /opt/xnav
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r /opt/xnav/vision_core/requirements.txt
```

#### 3. Service Files Not Updated to Use venv

Check if service files use the correct Python interpreter:
```bash
cat /etc/systemd/system/xnav-vision.service | grep ExecStart
cat /etc/systemd/system/xnav-dashboard.service | grep ExecStart
```

Should show: `/opt/xnav/venv/bin/python3`

**If still using `/usr/bin/python3`, update manually:**
```bash
sed -i "s|/usr/bin/python3|/opt/xnav/venv/bin/python3|g" \
  /etc/systemd/system/xnav-vision.service \
  /etc/systemd/system/xnav-dashboard.service

systemctl daemon-reload
systemctl restart xnav-vision.service
systemctl restart xnav-dashboard.service
```

#### 4. Missing Python Dependencies

If services fail to start due to missing packages:
```bash
cd /opt/xnav
source venv/bin/activate
pip install -r /opt/xnav/vision_core/requirements.txt
```

#### 5. Port Already in Use

Check if port 5800 is already in use:
```bash
netstat -tlnp | grep 5800
# or
ss -tlnp | grep 5800
```

If another process is using the port, kill it:
```bash
kill <PID>
systemctl restart xnav-dashboard.service
```

#### 6. Firewall Blocking Port 5800

Check if firewall is active:
```bash
ufw status
```

If active, allow port 5800:
```bash
ufw allow 5800/tcp
```

## No Camera Feed

### Check Camera Device
```bash
ls -la /dev/video*
v4l2-ctl --list-devices
```

### Check Permissions
```bash
groups
# Should include 'video' group
# If not, add user:
usermod -aG video root
```

## AprilTags Not Detected

### Check Lighting
- Ensure sufficient lighting
- Try adjusting camera exposure/gain in dashboard

### Check Calibration
- Run calibration wizard in dashboard
- Verify calibration result has RMS error < 1.0

### Check Tag Settings
- Verify correct tag family (tag36h11 for FRC 2024+)
- Verify tag size in meters (e.g., 0.1651 for 6.5" tags)

## NetworkTables Not Connecting

### Check Team Number
```bash
cat /etc/xnav/config.json | grep -A 5 network
```

Verify team number matches roboRIO team number.

### Check NT Server IP
- Should be `10.TE.AM.2` (replace TEAM with your team number)
- Example: Team 1234 → `10.12.34.2`

### Check roboRIO Connection
```bash
ping 10.TE.AM.2
```

## Performance Issues

### Check CPU Usage
```bash
top
htop
```

### Enable Match Mode
- Enable in dashboard System tab
- Or set via robot code: `m_vision.SetMatchMode(true)`

### Check Thermal Throttling
```bash
vcgencmd measure_temp
```

If temperature > 70°C, consider:
- Adding cooling
- Reducing resolution/FPS
- Adjusting exposure settings

## System Logs

### Vision System Log
```bash
tail -f /var/log/xnav.log
```

### System Journal
```bash
journalctl -f
```

### Service Logs
```bash
journalctl -u xnav-vision.service -f
journalctl -u xnav-dashboard.service -f
```

## Factory Reset

If all else fails, reset to default configuration:

```bash
# Stop services
systemctl stop xnav-vision.service
systemctl stop xnav-dashboard.service

# Backup current config
cp /etc/xnav/config.json /etc/xnav/config.json.backup

# Restore default config
cp /opt/xnav/system/config/default_config.json /etc/xnav/config.json

# Restart services
systemctl start xnav-vision.service
systemctl start xnav-dashboard.service
```

## First-Boot Issues

If first-boot setup didn't complete properly:

```bash
# Check if script still exists
ls -la /etc/xnav/first_boot.sh

# Run manually if needed
bash /etc/xnav/first_boot.sh

# Or re-run setup
bash /opt/xnav-src/system/scripts/setup.sh
```

## Getting Help

When reporting issues, please provide:
1. XNav version: `cat /etc/xnav/version` (if exists)
2. Service status: `systemctl status xnav-vision.service` and `systemctl status xnav-dashboard.service`
3. Relevant log snippets from `/var/log/xnav.log` or `journalctl`
4. Hardware: Raspberry Pi CM4 model, camera model
5. Network configuration: Team number, IP address
