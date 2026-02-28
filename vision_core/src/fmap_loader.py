"""
XNav FMap Loader
Parses WPILib .fmap (field map) JSON files containing AprilTag 3D poses.
"""

import json
import os
import math
import logging
from dataclasses import dataclass, field
from typing import Dict, Optional, List

logger = logging.getLogger(__name__)


@dataclass
class TagPose:
    id: int
    x: float          # meters, field-centric
    y: float
    z: float
    qw: float = 1.0   # quaternion
    qx: float = 0.0
    qy: float = 0.0
    qz: float = 0.0
    # Euler (derived)
    roll: float = 0.0
    pitch: float = 0.0
    yaw: float = 0.0


@dataclass
class FieldMap:
    length: float = 0.0     # meters
    width: float = 0.0
    tags: Dict[int, TagPose] = field(default_factory=dict)


def _quat_to_euler(w, x, y, z):
    """Convert quaternion to (roll, pitch, yaw) in degrees."""
    sinr_cosp = 2 * (w * x + y * z)
    cosr_cosp = 1 - 2 * (x * x + y * y)
    roll = math.atan2(sinr_cosp, cosr_cosp)

    sinp = 2 * (w * y - z * x)
    if abs(sinp) >= 1:
        pitch = math.copysign(math.pi / 2, sinp)
    else:
        pitch = math.asin(sinp)

    siny_cosp = 2 * (w * z + x * y)
    cosy_cosp = 1 - 2 * (y * y + z * z)
    yaw = math.atan2(siny_cosp, cosy_cosp)

    return math.degrees(roll), math.degrees(pitch), math.degrees(yaw)


def load_fmap(path: str) -> Optional[FieldMap]:
    """Load a WPILib .fmap file and return a FieldMap."""
    if not os.path.exists(path):
        logger.warning("FMap file not found: %s", path)
        return None

    try:
        with open(path, "r") as f:
            data = json.load(f)
    except Exception as e:
        logger.error("Failed to parse fmap %s: %s", path, e)
        return None

    fm = FieldMap()

    # Field dimensions (optional in some fmap formats)
    field_info = data.get("field", {})
    fm.length = field_info.get("length", 0.0)
    fm.width = field_info.get("width", 0.0)

    tags_data = data.get("tags", [])
    if not tags_data:
        # Some fmap files use "fiducials"
        tags_data = data.get("fiducials", [])

    for tag_data in tags_data:
        tag_id = tag_data.get("ID") or tag_data.get("id") or tag_data.get("fiducialId")
        if tag_id is None:
            continue
        tag_id = int(tag_id)

        pose = tag_data.get("pose", {})
        translation = pose.get("translation", {})
        tx = float(translation.get("x", 0))
        ty = float(translation.get("y", 0))
        tz = float(translation.get("z", 0))

        rotation = pose.get("rotation", {})
        quat = rotation.get("quaternion", {})
        qw = float(quat.get("W", 1))
        qx = float(quat.get("X", 0))
        qy = float(quat.get("Y", 0))
        qz = float(quat.get("Z", 0))

        roll, pitch, yaw = _quat_to_euler(qw, qx, qy, qz)

        tp = TagPose(
            id=tag_id,
            x=tx, y=ty, z=tz,
            qw=qw, qx=qx, qy=qy, qz=qz,
            roll=roll, pitch=pitch, yaw=yaw
        )
        fm.tags[tag_id] = tp

    logger.info("Loaded fmap with %d tags (field %gx%gm)", len(fm.tags), fm.length, fm.width)
    return fm
