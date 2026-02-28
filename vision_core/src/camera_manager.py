"""
XNav Camera Manager
Manages camera capture, settings, and frame delivery.
Supports V4L2 cameras on Raspberry Pi CM.
"""

import cv2
import threading
import time
import logging
import numpy as np
from typing import Optional, Tuple, Callable

logger = logging.getLogger(__name__)


class CameraManager:
    """Manages a camera capture device and exposes frames to consumers."""

    def __init__(self, config_manager):
        self._cfg = config_manager
        self._cap: Optional[cv2.VideoCapture] = None
        self._lock = threading.Lock()
        self._latest_frame: Optional[np.ndarray] = None
        self._latest_gray: Optional[np.ndarray] = None
        self._frame_time: float = 0.0
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._fps_actual: float = 0.0
        self._frame_count: int = 0
        self._fps_t0: float = 0.0
        self._on_frame_callbacks: list = []

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self):
        self._running = True
        self._thread = threading.Thread(target=self._capture_loop, daemon=True, name="CamCapture")
        self._thread.start()
        logger.info("Camera manager started")

    def stop(self):
        self._running = False
        if self._thread:
            self._thread.join(timeout=3)
        if self._cap:
            self._cap.release()
        logger.info("Camera manager stopped")

    def restart(self):
        self.stop()
        time.sleep(0.5)
        self.start()

    # ------------------------------------------------------------------
    # Frame access
    # ------------------------------------------------------------------

    def get_frame(self) -> Tuple[Optional[np.ndarray], Optional[np.ndarray], float]:
        """Returns (color_frame, gray_frame, timestamp)."""
        with self._lock:
            return (
                self._latest_frame.copy() if self._latest_frame is not None else None,
                self._latest_gray.copy() if self._latest_gray is not None else None,
                self._frame_time
            )

    def get_fps(self) -> float:
        return self._fps_actual

    def register_frame_callback(self, cb: Callable):
        """Register callback(color, gray, timestamp) for each new frame."""
        self._on_frame_callbacks.append(cb)

    # ------------------------------------------------------------------
    # Settings
    # ------------------------------------------------------------------

    def apply_settings(self):
        """Apply current config camera settings to the capture device."""
        if self._cap is None or not self._cap.isOpened():
            return
        cam = self._cfg.get("camera")
        if cam is None:
            return

        # Exposure (disable auto first)
        auto_exp = cam.get("auto_exposure", False)
        # V4L2 auto exposure: 1 = manual, 3 = auto
        self._cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 3 if auto_exp else 1)
        if not auto_exp:
            self._cap.set(cv2.CAP_PROP_EXPOSURE, cam.get("exposure", 100))

        self._cap.set(cv2.CAP_PROP_GAIN, cam.get("gain", 50))
        self._cap.set(cv2.CAP_PROP_BRIGHTNESS, cam.get("brightness", 50))
        self._cap.set(cv2.CAP_PROP_CONTRAST, cam.get("contrast", 50))
        logger.info("Camera settings applied")

    def get_jpeg_frame(self, quality: int = 70) -> Optional[bytes]:
        """Return latest frame as JPEG bytes for MJPEG streaming."""
        with self._lock:
            frame = self._latest_frame
        if frame is None:
            return None
        ret, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, quality])
        return buf.tobytes() if ret else None

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _open_camera(self):
        cam = self._cfg.get("camera")
        device = cam.get("device", "/dev/video0")
        width = cam.get("width", 1280)
        height = cam.get("height", 720)
        fps = cam.get("fps", 90)
        idx = cam.get("camera_index", 0)

        # Try device path first, fallback to index
        for src in [device, idx]:
            cap = cv2.VideoCapture(src, cv2.CAP_V4L2)
            if cap.isOpened():
                cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
                cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
                cap.set(cv2.CAP_PROP_FPS, fps)
                # Use MJPG codec for higher FPS
                cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
                # Minimize buffer for low latency
                cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
                logger.info("Camera opened: src=%s res=%dx%d fps=%d", src, width, height, fps)
                return cap
            cap.release()

        logger.error("Failed to open camera")
        return None

    def _capture_loop(self):
        self._cap = self._open_camera()
        if self._cap:
            self.apply_settings()
        self._fps_t0 = time.monotonic()
        self._frame_count = 0

        while self._running:
            if self._cap is None or not self._cap.isOpened():
                logger.warning("Camera not open, retrying in 2s...")
                time.sleep(2)
                self._cap = self._open_camera()
                if self._cap:
                    self.apply_settings()
                continue

            ret, frame = self._cap.read()
            if not ret:
                logger.warning("Failed to capture frame, retrying...")
                time.sleep(0.05)
                continue

            ts = time.monotonic()
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

            with self._lock:
                self._latest_frame = frame
                self._latest_gray = gray
                self._frame_time = ts

            # FPS calculation
            self._frame_count += 1
            elapsed = ts - self._fps_t0
            if elapsed >= 1.0:
                self._fps_actual = self._frame_count / elapsed
                self._frame_count = 0
                self._fps_t0 = ts

            # Fire callbacks
            for cb in self._on_frame_callbacks:
                try:
                    cb(frame, gray, ts)
                except Exception as e:
                    logger.warning("Frame callback error: %s", e)

        if self._cap:
            self._cap.release()
            self._cap = None
