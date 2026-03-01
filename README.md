# Limelight3-XNav

<img width="2752" height="1536" alt="Gemini_Generated_Image_8y01dk8y01dk8y01" src="https://github.com/user-attachments/assets/9c0705c2-9a6c-4031-8005-5ab7777a07a5" />

**XNav** is a custom, headless AprilTag vision system for FRC robots, designed to run on Raspberry Pi Compute Module 4 hardware (as used in the Limelight 3). It communicates with the roboRIO via WPILib NetworkTables 4, features a web configuration dashboard, and includes a C++ client library for robot code.

---

## Features

- **AprilTag detection** — tag36h11 and other families, 3D pose estimation (x/y/z/yaw/pitch/roll, distance in meters)
- **NetworkTables 4** — WPILib-compatible NT4 topics; struct-format robot pose, per-tag data, offset point
- **Field-centric pose** — upload a `.fmap` field map, get robot position on the field
- **Robot-to-target calculations** — direct distance, horizontal/vertical angles
- **Offset point** — define an XYZ offset from a specific tag and get distance/angles to that exact point
- **Turret support** — feed turret angle via NT, XNav compensates calculations; togglable
- **Web dashboard** (port 5800) — configure everything: camera, network, lights, AprilTag settings, upload `.fmap`, calibration
- **Camera calibration** — checkerboard calibration wizard in the dashboard, auto-applied to 3D calculations
- **Match Mode** — squeezes maximum performance from hardware (CPU governor, thread priority)
- **LED light control** — GPIO PWM brightness control, configurable via dashboard
- **Headless Linux** — auto-starts on boot via systemd services
- **Flashable ISO** — build script to create a ready-to-flash Raspberry Pi image

---

## Quick Start

### Flash the Image

1. Flash `xnav-1.0.0.img.xz` to your CM4 / SD card using [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Insert into Limelight 3 / Raspberry Pi CM4 carrier board
3. Connect to robot network, power on
4. Open **http://xnav.local:5800** or **http://10.TE.AM.11:5800**

### Manual Install (on existing Raspberry Pi OS)

```bash
git clone https://github.com/realaaravdas/Limelight3-XNav /opt/xnav-src
sudo bash /opt/xnav-src/system/scripts/setup.sh
```

---

## Repository Structure

```
Limelight3-XNav/
├── vision_core/          # Python vision service (AprilTags, NT4, pose)
│   ├── src/
│   │   ├── main.py              # Entry point / pipeline orchestrator
│   │   ├── config_manager.py    # Thread-safe config (JSON)
│   │   ├── camera_manager.py    # V4L2 camera capture
│   │   ├── apriltag_detector.py # AprilTag detection + PnP pose
│   │   ├── pose_calculator.py   # Robot/field pose, turret, offset
│   │   ├── nt_publisher.py      # NT4 publisher + input subscriber
│   │   ├── fmap_loader.py       # WPILib .fmap parser
│   │   ├── calibration.py       # Checkerboard calibration
│   │   └── lights_manager.py    # GPIO LED control
│   └── requirements.txt
│
├── web_dashboard/        # Flask web configuration portal
│   ├── app.py                   # Flask + SocketIO server
│   ├── templates/index.html     # Dashboard UI
│   └── static/                  # CSS + JavaScript
│
├── roborio_library/      # C++ client library for roboRIO
│   ├── include/XNavLib.h        # Header (API)
│   ├── src/XNavLib.cpp          # Implementation
│   ├── CMakeLists.txt
│   └── docs/
│       ├── README.md            # Library usage guide
│       └── nt_topics.md         # Full NT topic reference
│
├── system/               # System configuration & build tools
│   ├── config/default_config.json
│   ├── services/                # systemd service files
│   └── scripts/
│       ├── setup.sh             # Installation script
│       └── build_iso.sh         # ISO image builder
│
└── docs/
    ├── setup.md                 # Installation guide
    └── usage.md                 # Usage & robot code guide
```

---

## Web Dashboard

Access at **http://xnav.local:5800**

| Tab | Description |
|-----|-------------|
| Overview | Live camera feed, tag list, robot pose, FPS/latency |
| Camera | Resolution, FPS, exposure, gain, brightness |
| Network | Team number, NT server IP, hostname |
| Lights | Enable/disable, brightness, mode, GPIO pin |
| AprilTags | Tag family, size, detection parameters |
| Field Map | Upload `.fmap` for field-centric pose |
| Offset Point | Configure offset from tag, view live distances |
| Turret | Enable turret compensation, mount offset |
| Calibration | Checkerboard calibration wizard |
| System | Camera mount offsets, match mode, reboot/shutdown |

---

## NetworkTables Topics

Full reference: [roborio_library/docs/nt_topics.md](roborio_library/docs/nt_topics.md)

Key topics:

| Topic | Type | Description |
|-------|------|-------------|
| `/XNav/hasTarget` | boolean | Tag detected |
| `/XNav/numTargets` | int | Count of detected tags |
| `/XNav/tagIds` | int[] | IDs of visible tags |
| `/XNav/targets/<id>/distance` | double | Distance to tag (m) |
| `/XNav/targets/<id>/tx` | double | Horizontal angle (deg) |
| `/XNav/targets/<id>/ty` | double | Vertical angle (deg) |
| `/XNav/targets/<id>/yaw` | double | Tag yaw (deg) |
| `/XNav/robotPose` | double[6] | Field pose [x,y,z,r,p,yaw] |
| `/XNav/offsetPoint/directDistance` | double | Distance to offset point (m) |
| `/XNav/input/turretAngle` | double | **Input**: turret angle (deg) |
| `/XNav/input/matchMode` | boolean | **Input**: match mode toggle |

---

## C++ Library (roboRIO)

```cpp
#include "XNavLib.h"

xnav::XNav m_vision;

void RobotInit() { m_vision.Init(); }

void TeleopPeriodic() {
  if (m_vision.HasTarget()) {
    auto tag = m_vision.GetPrimaryTarget();
    // tag.distance, tag.tx, tag.ty, tag.yaw ...
  }
  auto pose = m_vision.GetRobotPose();
  if (pose.valid) {
    // pose.x, pose.y, pose.yaw_deg
  }
  // Turret
  m_vision.SetTurretAngle(turretEncoder.GetAngle());
}
```

Full docs: [roborio_library/docs/README.md](roborio_library/docs/README.md)

---

## Configuration

All settings stored in `/etc/xnav/config.json` on the device.
Edit via web dashboard or directly via SSH.

---

## License

MIT License — see LICENSE file.

---

<img width="2752" height="1536" alt="Gemini_Generated_Image_dvjb3odvjb3odvjb" src="https://github.com/user-attachments/assets/e403eae7-d5cc-4b28-92aa-f362fbdd745b" />
