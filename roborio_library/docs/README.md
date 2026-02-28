# XNavLib - C++ RoboRIO Library Documentation

**XNavLib** is the C++ client library for using the XNav custom vision system from your FRC roboRIO code.

## Quick Start

### 1. Add to your robot project

Copy `include/XNavLib.h` and `src/XNavLib.cpp` into your robot project, or build as a static library.

In `CMakeLists.txt` (or vendor dep equivalent):
```cmake
add_subdirectory(XNavLib)
target_link_libraries(Robot PRIVATE xnavlib)
```

### 2. Initialize

```cpp
#include "XNavLib.h"

class Robot : public frc::TimedRobot {
    xnav::XNav m_vision;

    void RobotInit() override {
        m_vision.Init();  // auto-connects via WPILib NT server discovery
        // Or connect to explicit IP:
        // m_vision.Init("10.12.34.2");
    }
};
```

### 3. Read detected tags

```cpp
void TeleopPeriodic() override {
    if (m_vision.HasTarget()) {
        // Primary (closest) tag
        auto target = m_vision.GetPrimaryTarget();
        double distance = target.distance;  // meters
        double tx = target.tx;              // degrees, positive = right
        double ty = target.ty;              // degrees, positive = up
        double yaw = target.yaw;            // degrees
    }
}
```

### 4. Get a specific tag

```cpp
auto maybeTag = m_vision.GetTarget(5);
if (maybeTag.has_value()) {
    double dist = maybeTag->distance;
}
```

### 5. Robot field-centric pose

Requires `.fmap` field map to be loaded on the XNav device.

```cpp
auto pose = m_vision.GetRobotPose();
if (pose.valid) {
    frc::Pose2d robotPose{
        units::meter_t{pose.x},
        units::meter_t{pose.y},
        frc::Rotation2d{units::degree_t{pose.yaw_deg}}
    };
    m_odometry.ResetPosition(gyro.GetRotation2d(), leftEncoder, rightEncoder, robotPose);
}
```

### 6. Offset point

Configure an offset from a specific tag in the XNav dashboard, then read it:

```cpp
auto offset = m_vision.GetOffsetPoint();
if (offset.valid) {
    double dist = offset.direct_distance;   // direct 3D distance (m)
    double tx   = offset.tx;               // horizontal angle (deg)
    double ty   = offset.ty;               // vertical angle (deg)
    double dx   = offset.x;               // X component (m)
    double dy   = offset.y;               // Y component (m)
    double dz   = offset.z;               // Z / depth (m)
}
```

### 7. Turret support

```cpp
// Send turret angle (e.g., from encoder) to XNav for compensation
m_vision.SetTurretEnabled(true);
m_vision.SetTurretAngle(turretEncoder.GetAngle());  // degrees
```

### 8. Match mode

Enable maximum performance mode at match start:

```cpp
void AutonomousInit() override {
    m_vision.SetMatchMode(true);
}

void DisabledInit() override {
    m_vision.SetMatchMode(false);
}
```

---

## API Reference

### `XNav` class

| Method | Description |
|--------|-------------|
| `Init()` | Connect via WPILib auto-discovery |
| `Init(server)` | Connect to specific NT server IP |
| `HasTarget()` | Returns true if ≥1 tag detected |
| `GetNumTargets()` | Number of detected tags |
| `GetTagIds()` | Vector of all detected tag IDs |
| `GetPrimaryTarget()` | Closest detected tag data |
| `GetTarget(id)` | Optional tag data for specific ID |
| `GetAllTargets()` | All detected tags |
| `GetRobotPose()` | Field-centric robot pose |
| `GetOffsetPoint()` | Offset point distances/angles |
| `SetTurretAngle(deg)` | Send turret angle to XNav |
| `SetTurretEnabled(bool)` | Toggle turret compensation |
| `SetMatchMode(bool)` | Toggle match mode |
| `GetStatus()` | System status/FPS/latency |
| `IsConnected()` | NT connection status |
| `OnNewTargets(cb)` | Register callback for new data |

---

## Building

### Requirements
- CMake 3.16+
- WPILib (or frcdev toolchain)
- C++17 compiler

### Build steps
```bash
mkdir build && cd build
cmake .. -DWPILIB_ROOT=/home/user/wpilib/2024
make -j4
```

For FRC toolchain (cross-compile for roboRIO):
```bash
cmake .. -DCMAKE_TOOLCHAIN_FILE=/home/user/wpilib/2024/roborio.toolchain.cmake \
         -DWPILIB_ROOT=/home/user/wpilib/2024
make -j4
```
