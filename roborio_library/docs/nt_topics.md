# XNav NetworkTables 4 Topics Reference

XNav uses **NetworkTables 4 (NT4)** as defined by WPILib. All topics live under the `/XNav/` table.

## Connection

| Setting | Value |
|---------|-------|
| NT Version | NT4 |
| Table Name | `XNav` |
| Default Client Name | `XNav` |
| Server port | 5810 (standard NT4) |
| Dashboard port | 5800 (HTTP) |

---

## Output Topics (XNav → Robot)

### System

| Topic | Type | Description |
|-------|------|-------------|
| `/XNav/status` | `string` | System status: `"running"`, `"starting"`, `"error"` |
| `/XNav/fps` | `double` | Camera processing FPS |
| `/XNav/latencyMs` | `double` | Processing latency in milliseconds |
| `/XNav/hasTarget` | `boolean` | `true` if at least one tag is detected |
| `/XNav/numTargets` | `int` | Number of currently detected tags |
| `/XNav/tagIds` | `int[]` | Array of all currently detected tag IDs |
| `/XNav/primaryTagId` | `int` | ID of the primary (closest) tag, or `-1` |

### Per-Tag Data

For each detected tag `<id>`:

| Topic | Type | Description |
|-------|------|-------------|
| `/XNav/targets/<id>/tx` | `double` | Horizontal angle from camera center (degrees, + = right) |
| `/XNav/targets/<id>/ty` | `double` | Vertical angle from camera center (degrees, + = up) |
| `/XNav/targets/<id>/x` | `double` | X translation in camera frame (meters) |
| `/XNav/targets/<id>/y` | `double` | Y translation in camera frame (meters) |
| `/XNav/targets/<id>/z` | `double` | Z translation in camera frame = forward distance (meters) |
| `/XNav/targets/<id>/distance` | `double` | Direct 3D distance from camera to tag (meters) |
| `/XNav/targets/<id>/yaw` | `double` | Tag yaw relative to camera (degrees) |
| `/XNav/targets/<id>/pitch` | `double` | Tag pitch relative to camera (degrees) |
| `/XNav/targets/<id>/roll` | `double` | Tag roll relative to camera (degrees) |

### Robot Pose (Field-Centric)

Requires a `.fmap` field map to be loaded.

| Topic | Type | Description |
|-------|------|-------------|
| `/XNav/robotPose` | `double[6]` | `[x, y, z, roll, pitch, yaw]` in meters / degrees |

Array indices:
- `[0]` = X position on field (meters)
- `[1]` = Y position on field (meters)
- `[2]` = Z position (meters, usually ~0 for ground robots)
- `[3]` = Roll (degrees)
- `[4]` = Pitch (degrees)
- `[5]` = Yaw / heading (degrees, CCW positive from field X-axis)

### Offset Point

Configured via dashboard. Gives distance/angles to a point offset from a tag.

| Topic | Type | Description |
|-------|------|-------------|
| `/XNav/offsetPoint/valid` | `boolean` | True if offset point is visible/computed |
| `/XNav/offsetPoint/tag_id` | `int` | Source tag ID for the offset |
| `/XNav/offsetPoint/x` | `double` | X to offset point in camera frame (meters) |
| `/XNav/offsetPoint/y` | `double` | Y to offset point in camera frame (meters) |
| `/XNav/offsetPoint/z` | `double` | Z to offset point in camera frame (meters) |
| `/XNav/offsetPoint/directDistance` | `double` | 3D Euclidean distance to offset point (meters) |
| `/XNav/offsetPoint/tx` | `double` | Horizontal angle to offset point (degrees) |
| `/XNav/offsetPoint/ty` | `double` | Vertical angle to offset point (degrees) |

---

## Input Topics (Robot → XNav)

| Topic | Type | Description |
|-------|------|-------------|
| `/XNav/input/turretAngle` | `double` | Turret rotation angle (degrees). Used for pose compensation when turret mode is enabled. |
| `/XNav/input/turretEnabled` | `boolean` | Enable/disable turret compensation |
| `/XNav/input/matchMode` | `boolean` | Enable/disable match mode (max performance) |

---

## Coordinate Frames

### Camera Frame
Right-handed coordinate system:
- **+X**: right
- **+Y**: down
- **+Z**: forward (into scene)

### Field Frame (robot pose output)
- Follows WPILib/FRC field coordinate convention
- **+X**: toward red alliance wall
- **+Y**: toward left when facing red alliance
- **Yaw**: CCW positive (from field coordinate system perspective)

---

## Example NT paths

```
/XNav/hasTarget          → true
/XNav/numTargets         → 2
/XNav/tagIds             → [1, 7]
/XNav/primaryTagId       → 1
/XNav/targets/1/tx       → -5.3
/XNav/targets/1/ty       → 2.1
/XNav/targets/1/distance → 3.142
/XNav/targets/1/yaw      → 12.5
/XNav/robotPose          → [8.24, 4.12, 0.0, 0.0, 0.0, 178.5]
/XNav/latencyMs          → 8.2
/XNav/fps                → 89.4
```

---

## Using from Java/Python (WPILib)

```java
// Java
var table = NetworkTableInstance.getDefault().getTable("XNav");
var hastarget = table.getEntry("hasTarget").getBoolean(false);
var dist = table.getEntry("targets/1/distance").getDouble(0.0);
var pose = table.getEntry("robotPose").getDoubleArray(new double[6]);
```

```python
# Python (robotpy)
from ntcore import NetworkTableInstance
table = NetworkTableInstance.getDefault().getTable("XNav")
has_target = table.getBoolean("hasTarget", False)
dist = table.getDouble("targets/1/distance", 0.0)
```
