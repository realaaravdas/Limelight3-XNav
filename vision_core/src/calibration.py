"""
XNav Calibration
Handles camera calibration using checkerboard images.
"""

import cv2
import numpy as np
import json
import os
import logging
import threading
import time
from typing import Optional, List, Tuple

logger = logging.getLogger(__name__)


class CalibrationManager:
    """Manages camera calibration with a checkerboard pattern."""

    def __init__(self, config_manager):
        self._cfg = config_manager
        self._lock = threading.Lock()
        self._calibration_frames: List[np.ndarray] = []
        self._is_collecting = False
        self._progress: int = 0
        self._target_frames: int = 20
        self._last_status: str = "idle"
        self._result: Optional[dict] = None

    # ------------------------------------------------------------------
    # Collection control
    # ------------------------------------------------------------------

    def start_collection(self, target_frames: int = 20):
        with self._lock:
            self._calibration_frames = []
            self._is_collecting = True
            self._progress = 0
            self._target_frames = target_frames
            self._last_status = "collecting"
        logger.info("Calibration collection started, target %d frames", target_frames)

    def stop_collection(self):
        with self._lock:
            self._is_collecting = False
            self._last_status = "stopped"

    def add_frame(self, gray: np.ndarray) -> bool:
        """Try to find checkerboard in frame and add if found."""
        with self._lock:
            if not self._is_collecting:
                return False
            if self._progress >= self._target_frames:
                return False

        cal = self._cfg.get("calibration") or {}
        rows = int(cal.get("checkerboard_rows", 6))
        cols = int(cal.get("checkerboard_cols", 9))
        pattern = (cols, rows)

        flags = cv2.CALIB_CB_ADAPTIVE_THRESH | cv2.CALIB_CB_NORMALIZE_IMAGE | cv2.CALIB_CB_FAST_CHECK
        found, _ = cv2.findChessboardCorners(gray, pattern, flags)

        if found:
            with self._lock:
                if self._progress < self._target_frames:
                    self._calibration_frames.append(gray.copy())
                    self._progress += 1
                    logger.debug("Calibration frame %d/%d", self._progress, self._target_frames)
                    if self._progress >= self._target_frames:
                        self._is_collecting = False
                        self._last_status = "ready_to_calibrate"
            return True
        return False

    def get_status(self) -> dict:
        with self._lock:
            return {
                "collecting": self._is_collecting,
                "progress": self._progress,
                "target": self._target_frames,
                "status": self._last_status,
                "has_result": self._result is not None
            }

    # ------------------------------------------------------------------
    # Calibration computation
    # ------------------------------------------------------------------

    def compute_calibration(self) -> Tuple[bool, str]:
        """Run calibration on collected frames. Returns (success, message)."""
        with self._lock:
            frames = list(self._calibration_frames)

        if len(frames) < 5:
            return False, f"Need at least 5 frames, have {len(frames)}"

        cal = self._cfg.get("calibration") or {}
        rows = int(cal.get("checkerboard_rows", 6))
        cols = int(cal.get("checkerboard_cols", 9))
        square_size = float(cal.get("checkerboard_square_size", 0.025))
        pattern = (cols, rows)

        # Prepare object points
        obj_p = np.zeros((rows * cols, 3), np.float32)
        obj_p[:, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2) * square_size

        obj_points = []
        img_points = []
        img_shape = None

        criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)

        for gray in frames:
            found, corners = cv2.findChessboardCorners(gray, pattern)
            if not found:
                continue
            corners_refined = cv2.cornerSubPix(gray, corners, (11, 11), (-1, -1), criteria)
            obj_points.append(obj_p)
            img_points.append(corners_refined)
            img_shape = gray.shape[::-1]

        if len(obj_points) < 5:
            return False, "Not enough valid frames for calibration"

        logger.info("Computing calibration from %d frames...", len(obj_points))
        with self._lock:
            self._last_status = "computing"

        try:
            ret, mtx, dist, rvecs, tvecs = cv2.calibrateCamera(
                obj_points, img_points, img_shape, None, None
            )
        except Exception as e:
            with self._lock:
                self._last_status = "error"
            return False, f"Calibration failed: {e}"

        rms_error = ret
        result = {
            "camera_matrix": mtx.tolist(),
            "dist_coeffs": dist.tolist(),
            "rms_error": float(rms_error),
            "image_size": list(img_shape),
            "num_frames": len(obj_points)
        }

        with self._lock:
            self._result = result
            self._last_status = "done"

        # Save to file
        self._save_calibration(result)

        logger.info("Calibration done. RMS error: %.4f", rms_error)
        return True, f"Calibration successful. RMS error: {rms_error:.4f}"

    def get_result(self) -> Optional[dict]:
        with self._lock:
            return dict(self._result) if self._result else None

    def draw_preview(self, frame: np.ndarray) -> np.ndarray:
        """Draw checkerboard corners on frame for live preview."""
        cal = self._cfg.get("calibration") or {}
        rows = int(cal.get("checkerboard_rows", 6))
        cols = int(cal.get("checkerboard_cols", 9))
        pattern = (cols, rows)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if len(frame.shape) == 3 else frame
        found, corners = cv2.findChessboardCorners(gray, pattern)
        out = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR) if len(frame.shape) == 2 else frame.copy()
        if found:
            cv2.drawChessboardCorners(out, pattern, corners, found)
        return out

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def _save_calibration(self, result: dict):
        cal = self._cfg.get("calibration") or {}
        cal_file = cal.get("calibration_file", "/etc/xnav/calibration.json")
        try:
            os.makedirs(os.path.dirname(cal_file), exist_ok=True)
            with open(cal_file, "w") as f:
                json.dump(result, f, indent=2)
            logger.info("Calibration saved to %s", cal_file)

            # Also update in config
            self._cfg.set("calibration", "camera_matrix", result["camera_matrix"])
            self._cfg.set("calibration", "dist_coeffs", result["dist_coeffs"])
        except Exception as e:
            logger.error("Failed to save calibration: %s", e)

    def load_saved_calibration(self) -> Optional[dict]:
        cal = self._cfg.get("calibration") or {}
        cal_file = cal.get("calibration_file", "/etc/xnav/calibration.json")
        if not os.path.exists(cal_file):
            return None
        try:
            with open(cal_file) as f:
                data = json.load(f)
            with self._lock:
                self._result = data
            return data
        except Exception as e:
            logger.error("Failed to load calibration: %s", e)
            return None
