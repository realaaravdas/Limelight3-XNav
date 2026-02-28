"""
XNav AprilTag Detector
Detects AprilTags and computes 3D pose using PnP.
"""

import numpy as np
import cv2
import math
import time
import logging
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

try:
    import pupil_apriltags as apriltag
    _APRILTAG_AVAILABLE = True
except ImportError:
    _APRILTAG_AVAILABLE = False
    apriltag = None

logger = logging.getLogger(__name__)


@dataclass
class TagDetection:
    """3D detection result for a single AprilTag."""
    id: int
    # Camera-frame translation (meters)
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0
    # Distance (meters)
    distance: float = 0.0
    # Angles from camera center (degrees)
    tx: float = 0.0    # horizontal angle
    ty: float = 0.0    # vertical angle
    # Orientation (degrees)
    yaw: float = 0.0
    pitch: float = 0.0
    roll: float = 0.0
    # Image-space
    cx: float = 0.0    # pixel center x
    cy: float = 0.0    # pixel center y
    corners: Optional[np.ndarray] = None
    # Rotation matrix (3x3) and translation vector (3,)
    rvec: Optional[np.ndarray] = None
    tvec: Optional[np.ndarray] = None
    # Hamming distance (tag confidence)
    hamming: int = 0
    decision_margin: float = 0.0
    # Latency contribution
    timestamp: float = 0.0


def _rvec_to_euler(rvec: np.ndarray) -> Tuple[float, float, float]:
    """Convert rotation vector to (roll, pitch, yaw) in degrees."""
    R, _ = cv2.Rodrigues(rvec)
    # Roll (x-axis rotation)
    roll = math.degrees(math.atan2(R[2, 1], R[2, 2]))
    # Pitch (y-axis rotation)
    pitch = math.degrees(math.atan2(-R[2, 0], math.sqrt(R[2, 1] ** 2 + R[2, 2] ** 2)))
    # Yaw (z-axis rotation)
    yaw = math.degrees(math.atan2(R[1, 0], R[0, 0]))
    return roll, pitch, yaw


class AprilTagDetector:
    """Detects AprilTags and computes 3D pose."""

    def __init__(self, config_manager):
        self._cfg = config_manager
        self._detector = None
        self._camera_matrix: Optional[np.ndarray] = None
        self._dist_coeffs: Optional[np.ndarray] = None
        self._tag_size: float = 0.1524  # default 6 inches in meters
        self._init_detector()
        self._load_calibration()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def detect(self, gray: np.ndarray, timestamp: float) -> List[TagDetection]:
        """Run detection on a grayscale frame."""
        if self._detector is None or gray is None:
            return []

        try:
            detections = self._detector.detect(
                gray,
                estimate_tag_pose=self._camera_matrix is not None,
                camera_params=self._get_camera_params(gray),
                tag_size=self._tag_size
            )
        except Exception as e:
            logger.warning("Detection error: %s", e)
            return []

        results = []
        for d in detections:
            tag = self._process_detection(d, gray, timestamp)
            if tag is not None:
                results.append(tag)

        return results

    def reload_config(self):
        self._init_detector()
        self._load_calibration()

    def set_calibration(self, camera_matrix: np.ndarray, dist_coeffs: np.ndarray):
        self._camera_matrix = camera_matrix
        self._dist_coeffs = dist_coeffs
        logger.info("Calibration updated in detector")

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _init_detector(self):
        if not _APRILTAG_AVAILABLE:
            logger.error("pupil-apriltags not installed. AprilTag detection unavailable.")
            return

        at_cfg = self._cfg.get("apriltag") or {}
        self._tag_size = float(at_cfg.get("tag_size", 0.1524))

        try:
            self._detector = apriltag.Detector(
                families=at_cfg.get("family", "tag36h11"),
                nthreads=int(at_cfg.get("nthreads", 4)),
                quad_decimate=float(at_cfg.get("quad_decimate", 2.0)),
                quad_sigma=float(at_cfg.get("quad_sigma", 0.0)),
                refine_edges=int(at_cfg.get("refine_edges", 1)),
                decode_sharpening=float(at_cfg.get("decode_sharpening", 0.25)),
                debug=0
            )
            logger.info("AprilTag detector initialized: family=%s nthreads=%d",
                        at_cfg.get("family", "tag36h11"), at_cfg.get("nthreads", 4))
        except Exception as e:
            logger.error("Failed to init detector: %s", e)
            self._detector = None

    def _load_calibration(self):
        cal = self._cfg.get("calibration") or {}
        mtx = cal.get("camera_matrix")
        dist = cal.get("dist_coeffs")
        if mtx and dist:
            self._camera_matrix = np.array(mtx, dtype=np.float64)
            self._dist_coeffs = np.array(dist, dtype=np.float64)
            logger.info("Loaded calibration from config")
        else:
            # Try loading from calibration file
            cal_file = cal.get("calibration_file", "")
            if cal_file:
                import json, os
                if os.path.exists(cal_file):
                    try:
                        with open(cal_file) as f:
                            d = json.load(f)
                        self._camera_matrix = np.array(d["camera_matrix"], dtype=np.float64)
                        self._dist_coeffs = np.array(d["dist_coeffs"], dtype=np.float64)
                        logger.info("Loaded calibration from file: %s", cal_file)
                        return
                    except Exception as e:
                        logger.warning("Could not load calibration file: %s", e)

            logger.warning("No calibration found - using default intrinsics. Accuracy will be reduced.")
            self._camera_matrix = None
            self._dist_coeffs = None

    def _get_camera_params(self, gray: np.ndarray):
        """Return (fx, fy, cx, cy) for the apriltag detector."""
        h, w = gray.shape[:2]
        if self._camera_matrix is not None:
            fx = self._camera_matrix[0, 0]
            fy = self._camera_matrix[1, 1]
            cx = self._camera_matrix[0, 2]
            cy = self._camera_matrix[1, 2]
        else:
            # Estimate reasonable defaults
            fx = fy = max(w, h) * 1.2
            cx = w / 2.0
            cy = h / 2.0
        return (fx, fy, cx, cy)

    def _process_detection(self, d, gray: np.ndarray, timestamp: float) -> Optional[TagDetection]:
        """Convert a raw apriltag detection to TagDetection."""
        h, w = gray.shape[:2]
        fx, fy, cx_cam, cy_cam = self._get_camera_params(gray)

        tag = TagDetection(id=int(d.tag_id), timestamp=timestamp)
        tag.hamming = int(d.hamming)
        tag.decision_margin = float(d.decision_margin)
        tag.corners = d.corners
        tag.cx = float(d.center[0])
        tag.cy = float(d.center[1])

        # Pixel-angle (from image center)
        tag.tx = math.degrees(math.atan2(tag.cx - cx_cam, fx))
        tag.ty = -math.degrees(math.atan2(tag.cy - cy_cam, fy))

        if hasattr(d, "pose_t") and d.pose_t is not None:
            tvec = d.pose_t.flatten()
            rvec_mat = d.pose_R
            rvec, _ = cv2.Rodrigues(np.array(rvec_mat, dtype=np.float64))
            tag.tvec = tvec
            tag.rvec = rvec

            # Camera-frame coordinates
            tag.x = float(tvec[0])
            tag.y = float(tvec[1])
            tag.z = float(tvec[2])
            tag.distance = float(np.linalg.norm(tvec))

            # Update angles from actual 3D position
            tag.tx = math.degrees(math.atan2(tag.x, tag.z))
            tag.ty = -math.degrees(math.atan2(tag.y, tag.z))

            tag.roll, tag.pitch, tag.yaw = _rvec_to_euler(rvec)
        else:
            tag.distance = 0.0

        return tag
