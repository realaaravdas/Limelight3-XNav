# Limelight3-XNav

<img width="2752" height="1536" alt="Gemini_Generated_Image_8y01dk8y01dk8y01" src="https://github.com/user-attachments/assets/9c0705c2-9a6c-4031-8005-5ab7777a07a5" />

**XNav** is a custom, headless AprilTag vision system for FRC robots, designed to run on **Raspberry Pi Compute Module 3 or 4** hardware (as used in the Limelight 3). It communicates with the roboRIO via WPILib NetworkTables 4, features a web configuration dashboard, and includes a C++ client library for robot code.

The vision core is written in **C++** — a single ~2 MB binary with no Python dependencies, delivering a compact flashable image that fits comfortably on Limelight 3's 8 GB eMMC.

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
- **Headless Linux** — auto-starts on boot via a single systemd service
- **Flashable ISO** — build script to create a ready-to-flash Raspberry Pi image
- **C++ core** — single ~2 MB binary; no Python, no pip, no virtual environments; minimal image size

---

## Quick Start

### Flash the Image

1. Flash `xnav-1.2.0.img.xz` to your CM3/CM4 eMMC using [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Insert into Limelight 3 / Raspberry Pi CM3 or CM4 carrier board
3. Connect an **Ethernet cable** (required — no Wi-Fi; uses Realtek RTL8153B USB ethernet)
4. Power on — on first boot, ethernet is configured automatically
5. Open **http://xnav.local:5800** or SSH in: `ssh pi@xnav.local`

**No internet connection required on the device after first boot.** The C++ binary is pre-compiled in the ISO. The ethernet firmware (`firmware-realtek`) is baked in — the RTL8153B adapter works immediately.

### Manual Install (on existing Raspberry Pi OS)

```bash
git clone https://github.com/realaaravdas/Limelight3-XNav /opt/xnav-src
sudo bash /opt/xnav-src/system/scripts/setup.sh
```

### Building Your Own Image

See [Build Instructions](docs/build_iso.md) for detailed steps to build a flashable ISO image. The C++ vision core binary is compiled during the build — no Python packages or pip required.

---

## Repository Structure

```
Limelight3-XNav/
├── vision_core_cpp/      # C++ vision service (AprilTags, NT4, pose, web server)
│   ├── src/
│   │   ├── main.cpp             # Entry point / pipeline orchestrator
│   │   ├── config_manager.*     # Thread-safe config (JSON, nlohmann/json)
│   │   ├── camera_manager.*     # V4L2 camera capture (OpenCV)
│   │   ├── apriltag_detector.*  # AprilTag detection + PnP pose (libapriltag)
│   │   ├── pose_calculator.*    # Robot/field pose, turret, offset
│   │   ├── nt_publisher.*       # NT4 publisher (raw WebSocket + msgpack)
│   │   ├── fmap_loader.*        # WPILib .fmap parser
│   │   ├── calibration_manager.*# Checkerboard calibration (OpenCV)
│   │   ├── lights_manager.*     # GPIO LED control (libgpiod)
│   │   ├── thermal_manager.*    # CPU temp monitoring + auto-throttle
│   │   └── web_server.*         # HTTP REST API + MJPEG + SSE (cpp-httplib)
│   ├── third_party/
│   │   ├── json.hpp             # nlohmann/json (header-only)
│   │   └── httplib.h            # cpp-httplib (header-only)
│   └── CMakeLists.txt
│
├── vision_core/          # Legacy Python vision service (kept for reference)
│   └── ...
│
├── web_dashboard/        # Web configuration portal (served by C++ binary)
│   ├── templates/index.html     # Dashboard UI (Bootstrap, offline-capable)
│   └── static/                  # CSS, JavaScript, vendor assets
│
├── roborio_library/      # C++ client library for roboRIO
│   ├── include/XNavLib.h        # Header (API)
│   ├── src/XNavLib.cpp          # Implementation
│   └── CMakeLists.txt
│
├── system/               # System configuration & build tools
│   ├── config/
│   │   ├── default_config.json
│   │   └── 70-limelight-ethernet.rules  # udev: RTL8153B USB ethernet -> eth0
│   ├── services/
│   │   ├── xnav-vision.service      # Main systemd service (C++ binary)
│   │   └── xnav-firstboot.service   # One-shot first-boot ethernet setup
│   └── scripts/
│       ├── setup.sh             # Installation script
│       ├── build_iso.sh         # ISO image builder (v1.2.0 — fast, ethernet-ready)
│       └── verify_iso.sh        # ISO verification script
│
└── docs/
    ├── build_iso.md             # ISO build guide (WSL-compatible)
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

## Troubleshooting & Support

| Problem | Solution |
|---------|----------|
| Dashboard not accessible | Check IP address, ensure port 5800 is not blocked |
| Ethernet not working | Ensure `firmware-realtek` is installed (`dpkg -l firmware-realtek`); check `systemctl status xnav-firstboot` |
| No camera feed | Verify camera is connected, check `/dev/video0` exists |
| Tags not detecting | Check lighting, calibrate camera, verify tag family/size |
| Robot pose wrong | Upload correct .fmap, recalibrate camera |
| NT not connecting | Verify team number, check roboRIO is on same network |
| Low FPS | Enable match mode, reduce resolution, check CPU temperature |

For detailed troubleshooting guides, see:
- [Troubleshooting Guide](docs/troubleshooting.md) - Common issues and solutions
- [Build Instructions](docs/build_instructions.md) - ISO building and flashing

---

## License

MIT License — see LICENSE file.

---

<img width="2752" height="1536" alt="Gemini_Generated_Image_dvjb3odvjb3odvjb" src="https://github.com/user-attachments/assets/e403eae7-d5cc-4b28-92aa-f362fbdd745b" />
