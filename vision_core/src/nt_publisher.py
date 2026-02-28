"""
XNav Network Tables Publisher
Publishes vision data to a roboRIO via WPILib NT4 using struct format.

NT Topics:
  /XNav/status            string   - System status
  /XNav/fps               float64  - Camera FPS
  /XNav/latencyMs         float64  - Processing latency (ms)
  /XNav/hasTarget         boolean  - At least one tag detected
  /XNav/numTargets        int64    - Number of detected tags
  /XNav/tagIds            int64[]  - Array of detected tag IDs
  /XNav/primaryTagId      int64    - ID of primary (closest) tag
  /XNav/targets/<id>/tx   float64  - Horizontal angle (deg)
  /XNav/targets/<id>/ty   float64  - Vertical angle (deg)
  /XNav/targets/<id>/x    float64  - X in camera frame (m)
  /XNav/targets/<id>/y    float64  - Y in camera frame (m)
  /XNav/targets/<id>/z    float64  - Z in camera frame (m)
  /XNav/targets/<id>/distance float64  - Direct distance (m)
  /XNav/targets/<id>/yaw  float64  - Yaw (deg)
  /XNav/targets/<id>/pitch float64 - Pitch (deg)
  /XNav/targets/<id>/roll float64  - Roll (deg)
  /XNav/robotPose         float64[6] - [x,y,z,roll,pitch,yaw] field-centric
  /XNav/offsetPoint/valid boolean
  /XNav/offsetPoint/x     float64
  /XNav/offsetPoint/y     float64
  /XNav/offsetPoint/z     float64
  /XNav/offsetPoint/directDistance float64
  /XNav/offsetPoint/tx    float64
  /XNav/offsetPoint/ty    float64

  Inputs (robot -> XNav):
  /XNav/input/turretAngle  float64 - Turret angle (deg) from robot
  /XNav/input/turretEnabled boolean
  /XNav/input/matchMode    boolean
"""

import threading
import time
import logging
from typing import List, Optional

logger = logging.getLogger(__name__)

try:
    import ntcore
    _NT_AVAILABLE = True
except ImportError:
    _NT_AVAILABLE = False
    ntcore = None


class NTPublisher:
    """Publishes XNav data to NetworkTables 4."""

    def __init__(self, config_manager):
        self._cfg = config_manager
        self._lock = threading.Lock()
        self._inst = None
        self._publishers: dict = {}
        self._subscribers: dict = {}
        self._connected = False
        self._initialized = False
        self._turret_angle: float = 0.0
        self._turret_enabled: bool = False
        self._match_mode_nt: bool = False

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self):
        if not _NT_AVAILABLE:
            logger.error("ntcore not installed. NT4 publishing unavailable.")
            return
        self._init_nt()
        logger.info("NT Publisher started")

    def stop(self):
        if self._inst:
            self._inst.stopClient()
        logger.info("NT Publisher stopped")

    # ------------------------------------------------------------------
    # Publish
    # ------------------------------------------------------------------

    def publish_frame(self, detections, robot_pose, offset_result, fps: float, latency_ms: float):
        """Publish one full detection cycle to NT."""
        if not self._initialized:
            return

        try:
            self._pub("hasTarget", len(detections) > 0)
            self._pub("numTargets", len(detections))
            self._pub("fps", fps)
            self._pub("latencyMs", latency_ms)
            self._pub("tagIds", [d.id for d in detections])

            # Primary target (closest)
            if detections:
                primary = min(detections, key=lambda d: d.distance)
                self._pub("primaryTagId", primary.id)
            else:
                self._pub("primaryTagId", -1)

            # Per-tag data
            for tag in detections:
                prefix = f"targets/{tag.id}"
                self._pub(f"{prefix}/tx", tag.tx)
                self._pub(f"{prefix}/ty", tag.ty)
                self._pub(f"{prefix}/x", tag.x)
                self._pub(f"{prefix}/y", tag.y)
                self._pub(f"{prefix}/z", tag.z)
                self._pub(f"{prefix}/distance", tag.distance)
                self._pub(f"{prefix}/yaw", tag.yaw)
                self._pub(f"{prefix}/pitch", tag.pitch)
                self._pub(f"{prefix}/roll", tag.roll)

            # Robot pose
            if robot_pose and robot_pose.valid:
                self._pub("robotPose", [
                    robot_pose.x, robot_pose.y, robot_pose.z,
                    robot_pose.roll, robot_pose.pitch, robot_pose.yaw
                ])
            else:
                self._pub("robotPose", [0.0] * 6)

            # Offset point
            if offset_result and offset_result.valid:
                self._pub("offsetPoint/valid", True)
                self._pub("offsetPoint/x", offset_result.x)
                self._pub("offsetPoint/y", offset_result.y)
                self._pub("offsetPoint/z", offset_result.z)
                self._pub("offsetPoint/directDistance", offset_result.direct_distance)
                self._pub("offsetPoint/tx", offset_result.tx)
                self._pub("offsetPoint/ty", offset_result.ty)
            else:
                self._pub("offsetPoint/valid", False)

        except Exception as e:
            logger.warning("NT publish error: %s", e)

    def publish_status(self, status: str):
        try:
            self._pub("status", status)
        except Exception as e:
            logger.warning("NT status publish error: %s", e)

    # ------------------------------------------------------------------
    # Input reading
    # ------------------------------------------------------------------

    def read_inputs(self) -> dict:
        """Read NT inputs from robot."""
        result = {
            "turret_angle": self._turret_angle,
            "turret_enabled": self._turret_enabled,
            "match_mode": self._match_mode_nt
        }
        if not self._initialized:
            return result

        try:
            ta = self._sub_get("input/turretAngle", self._turret_angle)
            te = self._sub_get("input/turretEnabled", self._turret_enabled)
            mm = self._sub_get("input/matchMode", self._match_mode_nt)
            self._turret_angle = float(ta)
            self._turret_enabled = bool(te)
            self._match_mode_nt = bool(mm)
        except Exception as e:
            logger.debug("NT input read error: %s", e)

        return {
            "turret_angle": self._turret_angle,
            "turret_enabled": self._turret_enabled,
            "match_mode": self._match_mode_nt
        }

    def is_connected(self) -> bool:
        return self._connected

    # ------------------------------------------------------------------
    # NT4 setup
    # ------------------------------------------------------------------

    def _init_nt(self):
        net = self._cfg.get("network") or {}
        team = int(net.get("team_number", 0))
        server_ip = net.get("nt_server_ip", "")

        self._inst = ntcore.NetworkTableInstance.getDefault()
        self._inst.startClient4("XNav")

        if server_ip:
            self._inst.setServer(server_ip)
            logger.info("NT4 connecting to server %s", server_ip)
        elif team > 0:
            self._inst.setServerTeam(team)
            logger.info("NT4 connecting via team number %d", team)
        else:
            logger.warning("No NT server configured. Waiting for connection...")
            self._inst.startServer()

        # Connection listener
        self._inst.addConnectionListener(self._on_connection, immediateNotify=True)

        # Pre-create subscribers for inputs
        table = self._inst.getTable("XNav")
        self._subscribers["input/turretAngle"] = table.getDoubleTopic("input/turretAngle").subscribe(0.0)
        self._subscribers["input/turretEnabled"] = table.getBooleanTopic("input/turretEnabled").subscribe(False)
        self._subscribers["input/matchMode"] = table.getBooleanTopic("input/matchMode").subscribe(False)

        self._initialized = True
        logger.info("NT4 initialized")

    def _on_connection(self, connected: bool, info):
        self._connected = connected
        logger.info("NT4 %s", "connected" if connected else "disconnected")

    def _get_pub(self, sub_key: str, value):
        """Get or create a publisher based on value type."""
        if sub_key in self._publishers:
            return self._publishers[sub_key]

        table = self._inst.getTable("XNav")
        topic_name = sub_key

        if isinstance(value, bool):
            pub = table.getBooleanTopic(topic_name).publish()
        elif isinstance(value, int):
            pub = table.getIntegerTopic(topic_name).publish()
        elif isinstance(value, float):
            pub = table.getDoubleTopic(topic_name).publish()
        elif isinstance(value, str):
            pub = table.getStringTopic(topic_name).publish()
        elif isinstance(value, list):
            if len(value) == 0 or isinstance(value[0], float):
                pub = table.getDoubleArrayTopic(topic_name).publish()
            elif isinstance(value[0], int):
                pub = table.getIntegerArrayTopic(topic_name).publish()
            else:
                pub = table.getStringArrayTopic(topic_name).publish()
        else:
            return None

        self._publishers[sub_key] = pub
        return pub

    def _pub(self, key: str, value):
        pub = self._get_pub(key, value)
        if pub is None:
            return
        try:
            pub.set(value)
        except Exception:
            # Type mismatch - remove and recreate next time
            del self._publishers[key]

    def _sub_get(self, key: str, default):
        sub = self._subscribers.get(key)
        if sub is None:
            return default
        try:
            return sub.get(default)
        except Exception:
            return default
