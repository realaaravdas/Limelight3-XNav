# XNav User Manual

**XNav** is a headless AprilTag vision system for FRC robots, designed to run on Raspberry Pi Compute Module 4 hardware (as used in the Limelight 3). This manual covers the complete installation, configuration, and day-to-day operation of XNav.

---

## Table of Contents

1. [Hardware Setup](#1-hardware-setup)
2. [Installation](#2-installation)
   - [Option A: Flash the XNav ISO](#option-a-flash-the-xnav-iso-recommended)
   - [Option B: Manual Install on Raspberry Pi OS](#option-b-manual-install-on-raspberry-pi-os)
3. [First-Time Configuration](#3-first-time-configuration)
4. [Web Dashboard Reference](#4-web-dashboard-reference)
5. [NetworkTables Reference](#5-networktables-reference)
6. [Robot Code Integration](#6-robot-code-integration)
   - [C++ (XNavLib)](#c-xnavlib)
   - [Java](#java)
   - [Python (robotpy)](#python-robotpy)
7. [Advanced Features](#7-advanced-features)
   - [Camera Calibration](#camera-calibration)
   - [Field-Centric Pose](#field-centric-pose)
   - [Offset Point](#offset-point)
   - [Turret Mode](#turret-mode)
   - [Match Mode](#match-mode)
   - [LED Lights](#led-lights)
8. [SSH Access & File System](#8-ssh-access--file-system)
9. [Competition Day Checklist](#9-competition-day-checklist)
10. [Troubleshooting](#10-troubleshooting)
11. [Network Ports Reference](#11-network-ports-reference)

---

## 1. Hardware Setup

### Required Hardware

| Component | Specification |
|-----------|--------------|
| Limelight 3 | Contains Raspberry Pi Compute Module 4 (CM4) |
| Camera | ArduCam or Raspberry Pi Camera Module (CSI) |
| Network | Ethernet cable to robot radio / switch |
| Power | 12V (supplied by PDP/PDH through Limelight power connector) |

### Optional Hardware

| Component | Notes |
|-----------|-------|
| LED Ring Light | 12V ring light; connect signal wire to GPIO 18 with a PWM MOSFET |
| microSD Card | Only if your CM4 variant does not have eMMC |

### Physical Installation

1. Mount the Limelight 3 on your robot with the camera facing the AprilTag targets.
2. Connect the Ethernet cable from the Limelight 3 to the robot radio or network switch.
3. Connect power (12V) to the Limelight 3 power connector from the PDP/PDH.
4. If using an LED ring light, connect it to the Limelight 3's LED port or directly to GPIO 18 via a MOSFET.

---

## 2. Installation

### Option A: Flash the XNav ISO (Recommended)

> **See [build_iso.md](build_iso.md) for the complete guide to building the ISO and flashing it with balenaEtcher.**

Quick summary:
1. Build the ISO: `sudo bash system/scripts/build_iso.sh` on a Linux computer.
2. Flash `xnav-1.0.0.img.xz` to the CM4 eMMC using [balenaEtcher](https://etcher.balena.io/).
3. Power on → wait ~3 minutes for first-boot setup.
4. Open `http://xnav.local:5800`.

### Option B: Manual Install on Raspberry Pi OS

Use this option if you want to install XNav on top of an existing Raspberry Pi OS installation, or if you cannot build the ISO.

#### Prerequisites

- Raspberry Pi OS Lite **64-bit** flashed to the CM4 eMMC or SD card.
- SSH access to the device (enable SSH during Raspberry Pi Imager configuration or via the `raspi-config` tool).
- Internet access from the device (for package installation).

#### Steps

1. **SSH into the device:**
   ```bash
   ssh pi@xnav.local
   # default password: raspberry
   ```

2. **Clone the repository:**
   ```bash
   sudo git clone https://github.com/realaaravdas/Limelight3-XNav /opt/xnav-src
   ```

3. **Run the setup script:**
   ```bash
   sudo bash /opt/xnav-src/system/scripts/setup.sh
   ```
   The script will:
   - Install all system dependencies (Python, OpenCV, libcamera, etc.)
   - Enable the camera interface in `/boot/config.txt`
   - Create a Python virtual environment at `/opt/xnav/venv`
   - Install Python packages from `requirements.txt`
   - Install and enable the `xnav-vision` and `xnav-dashboard` systemd services
   - Set the hostname to `xnav`

4. **Reboot:**
   ```bash
   sudo reboot
   ```

5. **Verify:**
   Open `http://xnav.local:5800` in a browser. The XNav dashboard should appear.

---

## 3. First-Time Configuration

After installation, open the web dashboard and complete these steps in order.

### Step 1 — Network

1. Go to the **Network** tab.
2. Enter your FRC **team number** (e.g. `1234`).
3. The NT server IP auto-resolves to `10.TE.AM.2` (e.g. `10.12.34.2`).
4. Click **Save Network Settings**.

### Step 2 — Camera

1. Go to the **Camera** tab.
2. Set **Resolution** and **FPS** (default: 1280×720 @ 90 fps).
3. Set **Exposure** (default: manual, value `100`). Lower values = faster shutter = less motion blur.
4. Click **Save & Apply**.

### Step 3 — AprilTags

1. Go to the **AprilTags** tab.
2. Set **Tag Family** to `tag36h11` (FRC 2025).
3. Set **Tag Size** to the physical tag size in meters.
   - FRC 2025 field tags: `0.1651` m (6.5 inches)
   - FRC 2025 source tags: `0.1016` m (4 inches)
4. Click **Save & Apply**.

### Step 4 — Camera Calibration (Strongly Recommended)

Calibration is required for accurate 3D pose estimation. See [Camera Calibration](#camera-calibration) for the full procedure.

### Step 5 — Field Map (for Robot Pose)

1. Download the WPILib `.fmap` for the current FRC season from the [WPILib releases](https://github.com/wpilibsuite/allwpilib/releases) or the game manual.
2. Go to the **Field Map** tab.
3. Click **Upload Field Map** → select your `.fmap` file.
4. Confirm the tag list appears.

---

## 4. Web Dashboard Reference

Access the dashboard at `http://xnav.local:5800` (or the device IP on port 5800).

### Overview Tab

| Element | Description |
|---------|-------------|
| Camera Feed | Live MJPEG stream with AprilTag overlays |
| Tag List | ID, distance, tx, ty, yaw for each detected tag |
| Robot Pose | X, Y, Z, roll, pitch, yaw (when field map is loaded) |
| FPS / Latency | Current pipeline performance |
| Status | Vision service health indicator |

### Camera Tab

| Setting | Description |
|---------|-------------|
| Resolution | Width × Height in pixels |
| FPS | Target frame rate |
| Exposure Mode | Auto or Manual |
| Exposure Value | Manual exposure level (lower = faster shutter) |
| Gain | Analog gain (higher = brighter but noisier) |
| Brightness | Digital brightness offset |

### Network Tab

| Setting | Description |
|---------|-------------|
| Team Number | Your FRC team number; used to set the NT server IP |
| NT Server IP | NetworkTables server address (auto-set from team number) |
| Hostname | mDNS hostname (default: `xnav`) |

### Lights Tab

| Setting | Description |
|---------|-------------|
| Enable Lights | Master on/off |
| Brightness | 0–100% PWM duty cycle |
| Mode | Solid, blink, strobe |
| GPIO Pin | BCM pin number for PWM output (default: 18) |

### AprilTags Tab

| Setting | Description |
|---------|-------------|
| Tag Family | AprilTag family (e.g. `tag36h11`) |
| Tag Size | Physical tag side length in meters |
| Detection Parameters | Quad decimate, sigma, etc. (advanced) |

### Field Map Tab

Upload a WPILib `.fmap` JSON file. Once loaded, XNav uses it to compute the robot's position on the field whenever at least one mapped tag is visible.

### Offset Point Tab

| Setting | Description |
|---------|-------------|
| Enable | Activate offset point calculations |
| Tag ID | The anchor tag |
| X / Y / Z | 3D offset from the tag center (meters) |

See [Offset Point](#offset-point) for usage details.

### Turret Tab

| Setting | Description |
|---------|-------------|
| Enable Turret Mode | Compensate pose for camera mounted on a rotating turret |
| Mount Angle Offset | Home-position angular offset of turret from robot forward (degrees) |

### Calibration Tab

| Control | Description |
|---------|-------------|
| Board Rows / Cols | Inner corner count of your checkerboard |
| Square Size (mm) | Physical size of each square |
| Start Collection | Begin capturing calibration frames |
| Compute | Run calibration and store results |

See [Camera Calibration](#camera-calibration) for the full procedure.

### System Tab

| Setting / Action | Description |
|------------------|-------------|
| Camera Mount Offsets | X/Y/Z/roll/pitch/yaw of camera relative to robot center |
| Match Mode | Toggle maximum-performance CPU/thread settings |
| Reboot | Reboot the device |
| Shutdown | Safely shut down the device |

---

## 5. NetworkTables Reference

XNav publishes all data under the `/XNav/` table. Requires WPILib NetworkTables 4.

Full reference: [../roborio_library/docs/nt_topics.md](../roborio_library/docs/nt_topics.md)

### Output Topics (XNav → Robot)

| Topic | Type | Description |
|-------|------|-------------|
| `/XNav/hasTarget` | `boolean` | `true` if at least one tag is visible |
| `/XNav/numTargets` | `int` | Number of detected tags |
| `/XNav/tagIds` | `int[]` | IDs of all visible tags |
| `/XNav/targets/<id>/distance` | `double` | Distance to tag in meters |
| `/XNav/targets/<id>/tx` | `double` | Horizontal angle to tag (degrees, positive = right) |
| `/XNav/targets/<id>/ty` | `double` | Vertical angle to tag (degrees, positive = up) |
| `/XNav/targets/<id>/yaw` | `double` | Tag yaw relative to camera (degrees) |
| `/XNav/targets/<id>/pitch` | `double` | Tag pitch relative to camera (degrees) |
| `/XNav/targets/<id>/roll` | `double` | Tag roll relative to camera (degrees) |
| `/XNav/robotPose` | `double[6]` | Field pose `[x, y, z, roll, pitch, yaw]` (meters / degrees) |
| `/XNav/offsetPoint/valid` | `boolean` | `true` if offset point is visible and enabled |
| `/XNav/offsetPoint/directDistance` | `double` | Direct (3D) distance to offset point (meters) |
| `/XNav/offsetPoint/tx` | `double` | Horizontal angle to offset point (degrees) |
| `/XNav/offsetPoint/ty` | `double` | Vertical angle to offset point (degrees) |
| `/XNav/fps` | `double` | Current pipeline FPS |
| `/XNav/latencyMs` | `double` | Pipeline latency in milliseconds |

### Input Topics (Robot → XNav)

| Topic | Type | Description |
|-------|------|-------------|
| `/XNav/input/turretAngle` | `double` | Current turret angle in degrees |
| `/XNav/input/turretEnabled` | `boolean` | Enable turret compensation |
| `/XNav/input/matchMode` | `boolean` | Enable/disable Match Mode |

---

## 6. Robot Code Integration

### C++ (XNavLib)

Include `XNavLib.h` from `roborio_library/include/` in your robot project.

Full docs: [../roborio_library/docs/README.md](../roborio_library/docs/README.md)

```cpp
#include "XNavLib.h"
#include <frc/geometry/Pose2d.h>

class Robot : public frc::TimedRobot {
  xnav::XNav m_vision{"XNav"};

  void RobotInit() override {
    m_vision.Init();
  }

  void TeleopPeriodic() override {
    // ── Basic targeting ──────────────────────────────────────
    if (m_vision.HasTarget()) {
      auto tag = m_vision.GetPrimaryTarget();
      double steer = tag.tx * kSteerGain;   // horizontal angle
      double range  = tag.distance;          // meters
    }

    // ── Specific tag ─────────────────────────────────────────
    auto speaker = m_vision.GetTarget(7);   // tag ID 7
    if (speaker) {
      double angle = speaker->tx;
    }

    // ── Field pose ────────────────────────────────────────────
    auto pose = m_vision.GetRobotPose();
    if (pose.valid) {
      frc::Pose2d p{
        units::meter_t{pose.x},
        units::meter_t{pose.y},
        frc::Rotation2d{units::degree_t{pose.yaw_deg}}
      };
      m_poseEstimator.AddVisionMeasurement(p, frc::Timer::GetFPGATimestamp());
    }

    // ── Offset point ──────────────────────────────────────────
    auto offset = m_vision.GetOffsetPoint();
    if (offset.valid) {
      double dist  = offset.direct_distance;
      double angle = offset.tx;
    }
  }

  void AutonomousInit() override { m_vision.SetMatchMode(true);  }
  void DisabledInit()   override { m_vision.SetMatchMode(false); }
};
```

### Java

```java
import edu.wpi.first.networktables.NetworkTableInstance;

var nt       = NetworkTableInstance.getDefault();
var xnavTable = nt.getTable("XNav");

boolean hasTarget = xnavTable.getEntry("hasTarget").getBoolean(false);
int     numTags   = (int) xnavTable.getEntry("numTargets").getNumber(0);

// Per-tag data (replace 1 with your tag ID)
double dist  = xnavTable.getEntry("targets/1/distance").getDouble(0.0);
double tx    = xnavTable.getEntry("targets/1/tx").getDouble(0.0);
double ty    = xnavTable.getEntry("targets/1/ty").getDouble(0.0);

// Field pose
double[] pose = xnavTable.getEntry("robotPose").getDoubleArray(new double[6]);
double robotX   = pose[0];
double robotY   = pose[1];
double robotYaw = pose[5];

// Send turret angle
xnavTable.getEntry("input/turretAngle").setDouble(turretEncoder.getAngle());
xnavTable.getEntry("input/turretEnabled").setBoolean(true);

// Enable match mode during auto
xnavTable.getEntry("input/matchMode").setBoolean(true);
```

### Python (robotpy)

```python
from ntcore import NetworkTableInstance

nt    = NetworkTableInstance.getDefault()
table = nt.getTable("XNav")

has_target = table.getBoolean("hasTarget", False)
dist       = table.getDouble("targets/1/distance", 0.0)
tx         = table.getDouble("targets/1/tx", 0.0)
robot_pose = table.getDoubleArray("robotPose", [0.0] * 6)

# Send turret angle
table.getEntry("input/turretAngle").setDouble(turret_encoder.get_angle())
table.getEntry("input/turretEnabled").setBoolean(True)
```

---

## 7. Advanced Features

### Camera Calibration

Camera calibration computes the intrinsic parameters (focal length, principal point, distortion coefficients) of your camera. This is required for accurate 3D pose estimation and distance calculations.

**What you need:**
- A printed **6×9 checkerboard** (inner corner count; standard A4/letter paper works)
- Square size: **25 mm** recommended (measure your printout to confirm)

**Procedure:**
1. Go to the **Calibration** tab in the dashboard.
2. Set **Board Rows** to `6`, **Board Cols** to `9`, **Square Size** to `25` (mm).
3. Click **Start Collection**.
4. Hold the checkerboard in front of the camera and move it slowly to different positions and angles:
   - Flat to camera, tilted left, tilted right, tilted up, tilted down
   - Near, mid-range, and far distances
   - Different corners of the frame
5. Wait for **20 frames** to be collected (the dashboard shows green detected corners for each valid frame).
6. Click **Compute**.
7. Review the **RMS reprojection error**:
   - `< 0.5` — excellent
   - `0.5 – 1.0` — good
   - `> 1.0` — consider recalibrating (better lighting, larger checkerboard, more varied poses)
8. If the result looks good, the calibration is saved automatically and applied to the pipeline.

### Field-Centric Pose

When a WPILib `.fmap` field map is loaded, XNav computes the robot's position and orientation on the field.

- The pose is published to `/XNav/robotPose` as `[x, y, z, roll, pitch, yaw]` (meters / degrees).
- It is valid whenever at least one field-map tag is visible.
- In WPILib, integrate the pose with `SwerveDrivePoseEstimator` or `DifferentialDrivePoseEstimator` using `AddVisionMeasurement()`.

### Offset Point

The offset point lets you aim at a specific point in 3D space relative to a tag — for example, the center of a scoring hole that is offset from the nearest AprilTag.

**Configuration (dashboard → Offset Point tab):**

| Field | Example | Meaning |
|-------|---------|---------|
| Tag ID | `5` | Anchor tag |
| X | `0.0` | No horizontal offset |
| Y | `-0.5` | 0.5 m above tag center (negative Y = up) |
| Z | `0.0` | No depth offset |

**Robot code:**
```cpp
auto offset = m_vision.GetOffsetPoint();
if (offset.valid) {
  // offset.direct_distance — 3D distance to the point (m)
  // offset.tx  — horizontal angle to the point (deg)
  // offset.ty  — vertical angle to the point (deg)
}
```

### Turret Mode

If your camera is mounted on a rotating turret, enable turret mode so XNav can compensate all pose and angle calculations for the current turret orientation.

1. Enable **Turret Mode** in the dashboard **Turret** tab and set the mount angle offset (the turret's home-position angle relative to robot forward).
2. Feed the live turret angle from your encoder every loop:
   ```cpp
   m_vision.SetTurretEnabled(true);
   m_vision.SetTurretAngle(m_turretEncoder.GetAngle());  // degrees
   ```
   Or via NT directly:
   ```java
   xnavTable.getEntry("input/turretAngle").setDouble(turretEncoder.getAngle());
   xnavTable.getEntry("input/turretEnabled").setBoolean(true);
   ```

### Match Mode

Match Mode maximises vision pipeline performance for use during a match.

When enabled:
- CPU governor is set to `performance` (maximum clock speed)
- Thread priorities are elevated
- Non-essential background processing is reduced

**Enable from robot code:**
```cpp
void AutonomousInit() override { m_vision.SetMatchMode(true); }
void DisabledInit()   override { m_vision.SetMatchMode(false); }
```

Or toggle manually from the **System** tab in the dashboard.

> **Tip:** Disable Match Mode when disabled / in the pits to reduce heat generation.

### LED Lights

XNav can control a 12V LED ring light connected via a PWM MOSFET to a GPIO pin.

**Wiring:**
- 12V LED ring → MOSFET drain
- MOSFET source → GND
- MOSFET gate → GPIO 18 (default, configurable) via 1 kΩ resistor
- Logic 3.3V from CM4 GPIO header

**Configuration (dashboard → Lights tab):**
- Enable lights, set brightness (0–100%), choose mode (solid/blink/strobe).
- Change the GPIO pin if needed.

---

## 8. SSH Access & File System

### Default Credentials

| Setting | Value |
|---------|-------|
| Hostname | `xnav.local` |
| Username | `pi` |
| Password | `raspberry` (change after setup!) |
| SSH port | `22` |

```bash
ssh pi@xnav.local
```

### Important File Paths

| Path | Description |
|------|-------------|
| `/opt/xnav/vision_core/` | Vision pipeline Python application |
| `/opt/xnav/web_dashboard/` | Flask web dashboard application |
| `/opt/xnav/venv/` | Python virtual environment |
| `/etc/xnav/config.json` | Live configuration (editable via dashboard or directly) |
| `/etc/systemd/system/xnav-vision.service` | Vision systemd unit |
| `/etc/systemd/system/xnav-dashboard.service` | Dashboard systemd unit |
| `/var/log/xnav-setup.log` | Setup script log |

### Service Management

```bash
# Check service status
sudo systemctl status xnav-vision
sudo systemctl status xnav-dashboard

# View live logs
sudo journalctl -fu xnav-vision
sudo journalctl -fu xnav-dashboard

# Restart services
sudo systemctl restart xnav-vision
sudo systemctl restart xnav-dashboard
```

### Editing Config Directly

```bash
sudo nano /etc/xnav/config.json
sudo systemctl restart xnav-vision xnav-dashboard
```

---

## 9. Competition Day Checklist

### Pre-Event

- [ ] Camera calibrated and RMS error < 1.0
- [ ] Field map (`.fmap`) for the current season uploaded
- [ ] Team number configured correctly
- [ ] NT connecting (verify `/XNav/hasTarget` appears in SmartDashboard)
- [ ] Camera feed visible in dashboard
- [ ] AprilTag family and size set correctly for this season's tags
- [ ] Verify robot pose is reasonable when tags are in view

### Before Each Match

- [ ] Power on XNav ≥ 60 seconds before the match
- [ ] Confirm dashboard shows camera feed and tag detection
- [ ] Enable **Match Mode** (or let robot code enable it in `AutonomousInit`)
- [ ] Verify robot pose estimate looks correct on field

### After Each Match

- [ ] Disable Match Mode (or let robot code disable in `DisabledInit`)
- [ ] Check for any error notifications in the dashboard

---

## 10. Troubleshooting

| Problem | Possible Cause | Solution |
|---------|---------------|----------|
| Dashboard not reachable | Wrong IP / port | Try `http://10.TE.AM.11:5800`; check Ethernet cable |
| Dashboard shows "Service Offline" | Vision service not running | `sudo systemctl restart xnav-vision` |
| No camera feed | Camera not detected | Check CSI cable; verify `/dev/video0` with `ls /dev/video*` |
| Tags not detected | Wrong family/size, poor lighting | Check AprilTags tab settings; improve lighting; calibrate |
| Robot pose wrong / jumping | Bad calibration, wrong field map | Recalibrate; re-upload correct `.fmap` |
| NT not connecting | Wrong team number, roboRIO IP | Verify team number in Network tab; ensure same subnet |
| Low FPS / high latency | CPU throttling, high resolution | Enable Match Mode; reduce resolution in Camera tab |
| LED lights not working | Wrong GPIO pin, no MOSFET | Check wiring; verify GPIO pin in Lights tab |
| `xnav.local` not resolving | mDNS not available | Use IP address directly; ensure Bonjour/Avahi on your OS |

---

## 11. Network Ports Reference

| Port | Protocol | Service |
|------|----------|---------|
| 22 | TCP | SSH |
| 5800 | TCP | Web dashboard (HTTP + WebSocket) |
| 5810 | TCP/UDP | NetworkTables 4 |
| 1182 | TCP | MJPEG stream (optional) |
