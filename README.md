# Limelight3-XNav

<img width="2752" height="1536" alt="Gemini_Generated_Image_8y01dk8y01dk8y01" src="https://github.com/user-attachments/assets/9c0705c2-9a6c-4031-8005-5ab7777a07a5" />

**XNav** is a custom, headless AprilTag vision system for FRC robots, designed to run on Raspberry Pi Compute Module 4 hardware (as used in the Limelight 3). It communicates with the roboRIO via WPILib NetworkTables 4, features a web configuration dashboard, and includes a C++ client library for robot code.

The device-side code is a **single statically-linked Rust binary** (~10-20 MB), replacing the previous ~300 MB Python runtime stack. This eliminates first-boot installation delays and allows the ISO to flash without stalling.

---

## Features

- **AprilTag detection** — tag36h11 family, 3D pose estimation (x/y/z/yaw/pitch/roll, distance in meters)
- **NetworkTables 4** — WPILib-compatible NT4 topics; struct-format robot pose, per-tag data, offset point
- **Field-centric pose** — upload a `.fmap` field map, get robot position on the field
- **Robot-to-target calculations** — direct distance, horizontal/vertical angles
- **Offset point** — define an XYZ offset from a specific tag and get distance/angles to that exact point
- **Turret support** — feed turret angle via NT, XNav compensates calculations; togglable
- **Web dashboard** (port 5800) — configure everything: camera, network, lights, AprilTag settings, upload `.fmap`, calibration
- **Camera calibration** — checkerboard calibration wizard in the dashboard, auto-applied to 3D calculations
- **Match Mode** — squeezes maximum performance from hardware (CPU governor, thread priority)
- **LED light control** — GPIO PWM brightness control, configurable via dashboard
- **Headless Linux** — auto-starts on boot via a single systemd service (`xnav-vision.service`)
- **Flashable ISO** — build script to create a ready-to-flash Raspberry Pi image

---

## Quick Start

### Flash the Image

1. Flash `xnav-1.1.0.img.xz` to your CM4 / SD card using [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Insert into Limelight 3 / Raspberry Pi CM4 carrier board
3. Connect to robot network, power on
4. Open **http://xnav.local:5800** or **http://10.TE.AM.11:5800**

Services start automatically on boot — no first-boot installation delay.

> **Note:** If the image was built without QEMU/Docker cross-compilation support, a first-boot script compiles the Rust binary directly on the device (takes ~20-40 minutes). You can monitor progress via SSH:
> ```bash
> ssh root@xnav.local
> tail -f /var/log/xnav-firstboot.log
> ```

### Manual Install (on existing Raspberry Pi OS)

```bash
git clone https://github.com/realaaravdas/Limelight3-XNav /opt/xnav-src
sudo bash /opt/xnav-src/system/scripts/setup.sh
```

### Building Your Own Image

See [docs/build_iso.md](docs/build_iso.md) for detailed steps to build a flashable ISO image on an Ubuntu/Debian machine.

---

## Repository Structure

```
Limelight3-XNav/
├── vision_core_rs/       # Rust vision system (binary replaces all Python)
│   ├── src/
│   │   ├── main.rs              # Entry point / pipeline orchestrator
│   │   ├── config.rs            # Thread-safe JSON config manager
│   │   ├── camera.rs            # V4L2 camera capture
│   │   ├── detector.rs          # AprilTag detection + solvePnP pose
│   │   ├── pose.rs              # Robot/field pose, turret, offset math
│   │   ├── nt_client.rs         # NT4 publisher (WebSocket + MessagePack)
│   │   ├── web.rs               # Axum HTTP/WebSocket dashboard server
│   │   ├── calibration.rs       # Checkerboard calibration
│   │   ├── fmap.rs              # WPILib .fmap parser
│   │   ├── lights.rs            # GPIO PWM LED control
│   │   └── thermal.rs           # CPU temperature monitoring
│   └── Cargo.toml
│
├── vision_core/          # Legacy Python code (reference / not deployed)
├── web_dashboard/        # Dashboard HTML/CSS/JS (embedded into Rust binary)
│   ├── templates/index.html
│   └── static/
│       ├── css/style.css
│       └── js/app.js
│
├── roborio_library/      # C++ client library for roboRIO
│   ├── include/XNavLib.h
│   ├── src/XNavLib.cpp
│   └── docs/
│
├── system/               # System configuration & build tools
│   ├── config/default_config.json
│   ├── services/xnav-vision.service   # Single unified systemd service
│   └── scripts/
│       ├── setup.sh             # Manual installation script
│       ├── build_iso.sh         # ISO image builder
│       └── verify_iso.sh        # Image validation script
│
└── docs/
    ├── build_iso.md             # ISO build instructions (Ubuntu/Debian)
    ├── setup.md                 # Manual installation guide
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

The dashboard is served by the same `xnav` binary (no separate process/service).

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
| No camera feed | Verify camera is connected, check `/dev/video0` exists |
| Tags not detecting | Check lighting, calibrate camera, verify tag family/size |
| Robot pose wrong | Upload correct .fmap, recalibrate camera |
| NT not connecting | Verify team number, check roboRIO is on same network |
| Low FPS | Enable match mode, reduce resolution, check CPU temperature |
| Service not starting | Check `journalctl -u xnav-vision.service` for errors |

For detailed guides, see:
- [Troubleshooting Guide](docs/troubleshooting.md)
- [Build Instructions](docs/build_iso.md)

---

## License

MIT License — see LICENSE file.

---

<img width="2752" height="1536" alt="Gemini_Generated_Image_dvjb3odvjb3odvjb" src="https://github.com/user-attachments/assets/e403eae7-d5cc-4b28-92aa-f362fbdd745b" />

