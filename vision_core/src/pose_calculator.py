"""
XNav Pose Calculator
Computes robot-to-target, field-centric, and offset-point calculations.
"""

import numpy as np
import math
import logging
from typing import List, Optional, Tuple, Dict
from dataclasses import dataclass, field

from apriltag_detector import TagDetection
from fmap_loader import FieldMap, TagPose

logger = logging.getLogger(__name__)


@dataclass
class RobotPose:
    """Robot pose in field-centric frame."""
    x: float = 0.0      # meters
    y: float = 0.0
    z: float = 0.0
    roll: float = 0.0   # degrees
    pitch: float = 0.0
    yaw: float = 0.0
    valid: bool = False
    source_tag_ids: List[int] = field(default_factory=list)


@dataclass
class OffsetResult:
    """Distance and angles to an offset point relative to a tag."""
    tag_id: int = 0
    # 3D position in camera frame
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0
    # Distances
    distance_x: float = 0.0
    distance_y: float = 0.0
    distance_z: float = 0.0
    direct_distance: float = 0.0
    # Angles (degrees)
    tx: float = 0.0
    ty: float = 0.0
    valid: bool = False


def _rot_y(angle_deg: float) -> np.ndarray:
    """Rotation matrix around Y axis."""
    a = math.radians(angle_deg)
    return np.array([
        [math.cos(a), 0, math.sin(a)],
        [0,           1, 0          ],
        [-math.sin(a),0, math.cos(a)]
    ])


def _rot_x(angle_deg: float) -> np.ndarray:
    a = math.radians(angle_deg)
    return np.array([
        [1, 0,            0           ],
        [0, math.cos(a), -math.sin(a) ],
        [0, math.sin(a),  math.cos(a) ]
    ])


def _rot_z(angle_deg: float) -> np.ndarray:
    a = math.radians(angle_deg)
    return np.array([
        [math.cos(a), -math.sin(a), 0],
        [math.sin(a),  math.cos(a), 0],
        [0,            0,           1]
    ])


def _build_camera_to_robot(mount: dict) -> np.ndarray:
    """Build 4x4 camera-to-robot transform from mount config."""
    rx = mount.get("roll", 0.0)
    ry = mount.get("pitch", 0.0)
    rz = mount.get("yaw", 0.0)
    tx = mount.get("x_offset", 0.0)
    ty = mount.get("y_offset", 0.0)
    tz = mount.get("z_offset", 0.0)

    R = _rot_z(rz) @ _rot_y(ry) @ _rot_x(rx)
    T = np.eye(4)
    T[:3, :3] = R
    T[:3, 3] = [tx, ty, tz]
    return T


def _quat_to_rot(qw, qx, qy, qz) -> np.ndarray:
    """Quaternion to 3x3 rotation matrix."""
    return np.array([
        [1 - 2*(qy*qy + qz*qz),   2*(qx*qy - qz*qw),   2*(qx*qz + qy*qw)],
        [2*(qx*qy + qz*qw),   1 - 2*(qx*qx + qz*qz),   2*(qy*qz - qx*qw)],
        [2*(qx*qz - qy*qw),       2*(qy*qz + qx*qw),   1 - 2*(qx*qx + qy*qy)]
    ])


def _rot_to_euler(R: np.ndarray) -> Tuple[float, float, float]:
    """3x3 rotation matrix to (roll, pitch, yaw) degrees."""
    pitch = math.degrees(math.asin(max(-1, min(1, -R[2, 0]))))
    if abs(R[2, 0]) < 0.9999:
        roll = math.degrees(math.atan2(R[2, 1], R[2, 2]))
        yaw = math.degrees(math.atan2(R[1, 0], R[0, 0]))
    else:
        roll = 0.0
        yaw = math.degrees(math.atan2(-R[0, 1], R[1, 1]))
    return roll, pitch, yaw


class PoseCalculator:
    """Handles all pose calculations."""

    def __init__(self, config_manager):
        self._cfg = config_manager
        self._field_map: Optional[FieldMap] = None

    def set_field_map(self, field_map: Optional[FieldMap]):
        self._field_map = field_map

    # ------------------------------------------------------------------
    # Turret compensation
    # ------------------------------------------------------------------

    def apply_turret(self, detections: List[TagDetection], turret_angle_deg: float) -> List[TagDetection]:
        """Rotate tag positions by turret angle (around Y axis)."""
        if abs(turret_angle_deg) < 1e-6:
            return detections

        R = _rot_y(turret_angle_deg)
        result = []
        for tag in detections:
            if tag.tvec is None:
                result.append(tag)
                continue
            import copy
            t = copy.copy(tag)
            tvec_rot = R @ tag.tvec
            t.x = float(tvec_rot[0])
            t.y = float(tvec_rot[1])
            t.z = float(tvec_rot[2])
            t.distance = float(np.linalg.norm(tvec_rot))
            t.tx = math.degrees(math.atan2(t.x, t.z))
            t.ty = -math.degrees(math.atan2(t.y, t.z))
            # Rotate rvec
            if tag.rvec is not None:
                import cv2
                R_tag, _ = cv2.Rodrigues(tag.rvec)
                R_new = R @ R_tag
                rvec_new, _ = cv2.Rodrigues(R_new)
                t.rvec = rvec_new
                t.roll, t.pitch, t.yaw = _rvec_to_euler_simple(rvec_new)
            result.append(t)
        return result

    # ------------------------------------------------------------------
    # Robot pose (field-centric)
    # ------------------------------------------------------------------

    def compute_robot_pose(self, detections: List[TagDetection]) -> Optional[RobotPose]:
        """Estimate robot field pose using detected tags and the field map."""
        if self._field_map is None or not self._field_map.tags:
            return None

        mount = self._cfg.get("camera_mount") or {}
        T_cam_to_robot = _build_camera_to_robot(mount)

        poses = []
        tag_ids = []

        for tag in detections:
            if tag.tvec is None or tag.rvec is None:
                continue
            field_tag = self._field_map.tags.get(tag.id)
            if field_tag is None:
                continue

            # Camera pose in tag frame
            import cv2
            R_cam_tag, _ = cv2.Rodrigues(tag.rvec)
            T_cam_in_tag = np.eye(4)
            T_cam_in_tag[:3, :3] = R_cam_tag
            T_cam_in_tag[:3, 3] = tag.tvec

            # Tag pose in field frame
            R_tag_field = _quat_to_rot(field_tag.qw, field_tag.qx, field_tag.qy, field_tag.qz)
            T_tag_in_field = np.eye(4)
            T_tag_in_field[:3, :3] = R_tag_field
            T_tag_in_field[:3, 3] = [field_tag.x, field_tag.y, field_tag.z]

            # Camera in field = tag_in_field * inv(cam_in_tag)
            T_cam_in_field = T_tag_in_field @ np.linalg.inv(T_cam_in_tag)

            # Robot in field = camera_in_field * inv(cam_to_robot)
            T_robot_in_field = T_cam_in_field @ np.linalg.inv(T_cam_to_robot)

            poses.append(T_robot_in_field)
            tag_ids.append(tag.id)

        if not poses:
            return None

        # Average translation; for rotation, use the one from the closest tag
        # (averaging rotation matrices directly is mathematically invalid).
        # We average quaternions (normalized sum method) for all poses.
        translations = np.array([T[:3, 3] for T in poses])
        t_avg = np.mean(translations, axis=0)

        # Extract quaternions from rotation matrices and average them
        def rot_to_quat(R):
            trace = R[0,0] + R[1,1] + R[2,2]
            if trace > 0:
                s = 0.5 / math.sqrt(trace + 1.0)
                w = 0.25 / s
                x = (R[2,1] - R[1,2]) * s
                y = (R[0,2] - R[2,0]) * s
                z = (R[1,0] - R[0,1]) * s
            elif R[0,0] > R[1,1] and R[0,0] > R[2,2]:
                s = 2.0 * math.sqrt(1.0 + R[0,0] - R[1,1] - R[2,2])
                w = (R[2,1] - R[1,2]) / s
                x = 0.25 * s
                y = (R[0,1] + R[1,0]) / s
                z = (R[0,2] + R[2,0]) / s
            elif R[1,1] > R[2,2]:
                s = 2.0 * math.sqrt(1.0 + R[1,1] - R[0,0] - R[2,2])
                w = (R[0,2] - R[2,0]) / s
                x = (R[0,1] + R[1,0]) / s
                y = 0.25 * s
                z = (R[1,2] + R[2,1]) / s
            else:
                s = 2.0 * math.sqrt(1.0 + R[2,2] - R[0,0] - R[1,1])
                w = (R[1,0] - R[0,1]) / s
                x = (R[0,2] + R[2,0]) / s
                y = (R[1,2] + R[2,1]) / s
                z = 0.25 * s
            return np.array([w, x, y, z])

        quats = np.array([rot_to_quat(T[:3, :3]) for T in poses])
        # Ensure all quaternions are in the same hemisphere
        for i in range(1, len(quats)):
            if np.dot(quats[0], quats[i]) < 0:
                quats[i] = -quats[i]
        q_avg = np.mean(quats, axis=0)
        norm = np.linalg.norm(q_avg)
        if norm < 1e-9:
            q_avg = np.array([1.0, 0.0, 0.0, 0.0])
        else:
            q_avg /= norm

        R_avg = _quat_to_rot(q_avg[0], q_avg[1], q_avg[2], q_avg[3])
        roll, pitch, yaw = _rot_to_euler(R_avg)

        return RobotPose(
            x=float(t_avg[0]),
            y=float(t_avg[1]),
            z=float(t_avg[2]),
            roll=roll,
            pitch=pitch,
            yaw=yaw,
            valid=True,
            source_tag_ids=tag_ids
        )

    # ------------------------------------------------------------------
    # Offset point calculation
    # ------------------------------------------------------------------

    def compute_offset_point(self, detections: List[TagDetection], cfg_offset: dict) -> Optional[OffsetResult]:
        """Compute distance and angles to an offset point relative to a tag."""
        if not cfg_offset.get("enabled", False):
            return None

        tag_id = int(cfg_offset.get("tag_id", 0))
        ox = float(cfg_offset.get("x", 0.0))
        oy = float(cfg_offset.get("y", 0.0))
        oz = float(cfg_offset.get("z", 0.0))

        # Find the target tag
        target_tag = None
        for tag in detections:
            if tag.id == tag_id and tag.tvec is not None and tag.rvec is not None:
                target_tag = tag
                break

        if target_tag is None:
            return None

        # Transform offset from tag frame to camera frame
        import cv2
        R_cam_tag, _ = cv2.Rodrigues(target_tag.rvec)
        offset_tag = np.array([ox, oy, oz])
        # Offset point in camera frame = tag_translation + R * offset
        offset_cam = target_tag.tvec + R_cam_tag @ offset_tag

        dx = float(offset_cam[0])
        dy = float(offset_cam[1])
        dz = float(offset_cam[2])
        direct = float(np.linalg.norm(offset_cam))
        tx = math.degrees(math.atan2(dx, dz))
        ty = -math.degrees(math.atan2(dy, dz))

        return OffsetResult(
            tag_id=tag_id,
            x=dx, y=dy, z=dz,
            distance_x=abs(dx),
            distance_y=abs(dy),
            distance_z=abs(dz),
            direct_distance=direct,
            tx=tx,
            ty=ty,
            valid=True
        )


def _rvec_to_euler_simple(rvec: np.ndarray) -> Tuple[float, float, float]:
    import cv2
    R, _ = cv2.Rodrigues(rvec)
    roll = math.degrees(math.atan2(R[2, 1], R[2, 2]))
    pitch = math.degrees(math.atan2(-R[2, 0], math.sqrt(R[2, 1]**2 + R[2, 2]**2)))
    yaw = math.degrees(math.atan2(R[1, 0], R[0, 0]))
    return roll, pitch, yaw
