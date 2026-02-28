# XNav Usage Guide

## Robot Code Integration

See [roborio_library/docs/README.md](../roborio_library/docs/README.md) for the full C++ library reference.
See [roborio_library/docs/nt_topics.md](../roborio_library/docs/nt_topics.md) for raw NT topic reference.

---

## Typical Robot Code Pattern

```cpp
#include "XNavLib.h"
#include <frc/geometry/Pose2d.h>

class Robot : public frc::TimedRobot {
  xnav::XNav m_vision{"XNav"};

  void RobotInit() override {
    m_vision.Init();
  }

  void TeleopPeriodic() override {
    // ── Basic tag targeting ──────────────────────────────────────────
    if (m_vision.HasTarget()) {
      auto tag = m_vision.GetPrimaryTarget();

      // Aim turret using horizontal angle
      double steer = tag.tx * kSteerGain;
      m_turret.Set(steer);

      // Range to target
      double range = tag.distance;  // meters
    }

    // ── Get all tags ─────────────────────────────────────────────────
    for (auto& tag : m_vision.GetAllTargets()) {
      frc::SmartDashboard::PutNumber("Tag " + std::to_string(tag.id) + " dist", tag.distance);
    }

    // ── Look for specific tag (e.g., speaker = tag 7) ─────────────────
    auto speaker = m_vision.GetTarget(7);
    if (speaker) {
      double angle = speaker->tx;
    }

    // ── Field pose ────────────────────────────────────────────────────
    auto pose = m_vision.GetRobotPose();
    if (pose.valid) {
      frc::Pose2d p{
        units::meter_t{pose.x},
        units::meter_t{pose.y},
        frc::Rotation2d{units::degree_t{pose.yaw_deg}}
      };
      m_poseEstimator.AddVisionMeasurement(p, frc::Timer::GetFPGATimestamp());
    }

    // ── Offset point ──────────────────────────────────────────────────
    auto offset = m_vision.GetOffsetPoint();
    if (offset.valid) {
      // e.g., align to a point 0.5m in front of the speaker tag
      double dist = offset.direct_distance;
      double angle = offset.tx;
    }
  }

  void AutonomousInit() override {
    m_vision.SetMatchMode(true);
  }

  void DisabledInit() override {
    m_vision.SetMatchMode(false);
  }
};
```

---

## Turret Mode

If your camera is mounted on a rotating turret, feed the turret angle to XNav so it can compensate pose calculations:

```cpp
void TeleopPeriodic() override {
  // Send current turret angle from encoder
  double turretAngle = m_turretEncoder.GetAngle();  // degrees
  m_vision.SetTurretEnabled(true);
  m_vision.SetTurretAngle(turretAngle);
}
```

You can also toggle turret mode from the XNav dashboard (**Turret** tab) or set a mount angle offset to account for the turret's home position.

---

## Field-Centric Pose

1. Upload your `.fmap` field map in the dashboard
2. Ensure calibration is done
3. Call `GetRobotPose()` — valid when ≥1 tag from the map is visible

The returned pose is in the WPILib field coordinate frame (matches `frc::Pose2d` / `frc::Pose3d`).

---

## Offset Point

The offset point lets you aim at a specific point in 3D space relative to a tag.

**Example**: You want to score in a hole that is 0.5m directly above tag #5:
1. In dashboard → **Offset Point** tab:
   - Tag ID: `5`
   - X: `0.0`, Y: `-0.5` (negative Y = up in camera frame), Z: `0.0`
   - Enable offset
2. In robot code:
   ```cpp
   auto offset = m_vision.GetOffsetPoint();
   // offset.ty gives vertical angle to the hole
   // offset.direct_distance gives distance to the hole
   ```

---

## Java / Python (without C++ library)

```java
// Java
var nt = NetworkTableInstance.getDefault();
var xnavTable = nt.getTable("XNav");
boolean hasTarget = xnavTable.getEntry("hasTarget").getBoolean(false);
double dist = xnavTable.getEntry("targets/1/distance").getDouble(0.0);
double[] pose = xnavTable.getEntry("robotPose").getDoubleArray(new double[6]);
double robotX = pose[0];
double robotY = pose[1];
double robotYaw = pose[5];

// Send turret angle
xnavTable.getEntry("input/turretAngle").setDouble(turretEncoder.getAngle());
xnavTable.getEntry("input/turretEnabled").setBoolean(true);
```

```python
# Python (robotpy)
from ntcore import NetworkTableInstance
nt = NetworkTableInstance.getDefault()
table = nt.getTable("XNav")
has_target = table.getBoolean("hasTarget", False)
dist = table.getDouble("targets/1/distance", 0.0)
robot_pose = table.getDoubleArray("robotPose", [0.0]*6)
```
