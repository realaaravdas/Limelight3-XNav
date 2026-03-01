#!/usr/bin/env python3
"""
XNav Vision Core - Main Entry Point
Headless AprilTag vision system for FRC robots.
"""

import sys
import os
import time
import signal
import logging
import threading

# Add vision_core/src to path
sys.path.insert(0, os.path.dirname(__file__))

from config_manager import ConfigManager
from camera_manager import CameraManager
from apriltag_detector import AprilTagDetector
from pose_calculator import PoseCalculator
from nt_publisher import NTPublisher
from fmap_loader import load_fmap
from calibration import CalibrationManager
from lights_manager import LightsManager
from thermal_manager import ThermalManager

# ── Shared state (accessed by web dashboard) ──────────────────────────────────
_state = {
    "detections": [],
    "robot_pose": None,
    "offset_result": None,
    "fps": 0.0,
    "latency_ms": 0.0,
    "status": "starting",
    "calibration_preview": None,  # latest JPEG bytes for calibration preview
    "temperature_c": 0.0,
    "thermal_state": "unknown",
    "throttle_fps": 0.0,
}
_state_lock = threading.Lock()


def get_shared_state() -> dict:
    with _state_lock:
        return dict(_state)


def update_shared_state(**kwargs):
    with _state_lock:
        _state.update(kwargs)


# ─────────────────────────────────────────────────────────────────────────────

def setup_logging(level_str: str):
    level = getattr(logging, level_str.upper(), logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        handlers=[
            logging.StreamHandler(sys.stdout),
            logging.FileHandler("/var/log/xnav.log", mode="a")
        ] if os.path.exists("/var/log") else [logging.StreamHandler(sys.stdout)]
    )


class VisionPipeline:
    def __init__(self, config_path: str = None):
        kwargs = {"config_path": config_path} if config_path else {}
        self._cfg = ConfigManager(**kwargs)
        self._camera = CameraManager(self._cfg)
        self._detector = AprilTagDetector(self._cfg)
        self._pose_calc = PoseCalculator(self._cfg)
        self._nt = NTPublisher(self._cfg)
        self._calibration = CalibrationManager(self._cfg)
        self._lights = LightsManager(self._cfg)
        self._thermal = ThermalManager(self._cfg)
        self._field_map = None
        self._running = False

        # Throttle state
        self._throttle_lock = threading.Lock()
        self._last_process_time: float = 0.0

        # Register config change handler
        self._cfg.register_callback(self._on_config_change)

        # Expose components for web dashboard
        self.config = self._cfg
        self.camera = self._camera
        self.detector = self._detector
        self.pose_calc = self._pose_calc
        self.nt = self._nt
        self.calibration = self._calibration
        self.lights = self._lights
        self.thermal = self._thermal

    def start(self):
        self._running = True

        # Load field map
        self._reload_fmap()

        # Start subsystems
        self._nt.start()
        self._camera.start()
        self._thermal.start()

        update_shared_state(status="running")
        self._nt.publish_status("running")
        logging.getLogger(__name__).info("XNav vision pipeline started")

        # Camera frame callback
        self._camera.register_frame_callback(self._on_frame)

    def stop(self):
        self._running = False
        self._camera.stop()
        self._nt.stop()
        self._thermal.stop()
        self._lights.cleanup()
        update_shared_state(status="stopped")
        logging.getLogger(__name__).info("XNav vision pipeline stopped")

    def wait(self):
        """Block until stopped."""
        while self._running:
            time.sleep(0.5)

    # ------------------------------------------------------------------
    # Frame processing
    # ------------------------------------------------------------------

    def _on_frame(self, frame, gray, timestamp):
        if not self._running:
            return

        # ── Throttle gate ──────────────────────────────────────────────
        effective_fps = self._get_effective_throttle_fps()
        if effective_fps > 0:
            min_interval = 1.0 / effective_fps
            now = time.monotonic()
            with self._throttle_lock:
                if (now - self._last_process_time) < min_interval:
                    return
                self._last_process_time = now

        t0 = time.monotonic()

        # Read NT inputs (turret angle, match mode)
        inputs = self._nt.read_inputs()

        # Check match mode
        match_mode = self._cfg.get("match_mode") or inputs.get("match_mode", False)

        # Detect AprilTags
        detections = self._detector.detect(gray, timestamp)

        # Apply turret compensation
        turret_cfg = self._cfg.get("turret") or {}
        use_nt_turret = turret_cfg.get("enabled", False) and inputs.get("turret_enabled", False)
        turret_angle = inputs.get("turret_angle", 0.0) if use_nt_turret else 0.0
        turret_angle += float(turret_cfg.get("mount_angle_offset", 0.0))

        if abs(turret_angle) > 0.001:
            detections = self._pose_calc.apply_turret(detections, turret_angle)

        # Robot pose (field-centric)
        robot_pose = None
        if self._field_map:
            robot_pose = self._pose_calc.compute_robot_pose(detections)

        # Offset point
        offset_cfg = self._cfg.get("offset_point") or {}
        offset_result = self._pose_calc.compute_offset_point(detections, offset_cfg)

        # Latency
        latency_ms = (time.monotonic() - t0) * 1000.0
        fps = self._camera.get_fps()

        # Calibration frame collection
        cal_status = self._calibration.get_status()
        if cal_status["collecting"]:
            self._calibration.add_frame(gray)

        # Update shared state for web dashboard
        thermal_status = self._thermal.get_status()
        update_shared_state(
            detections=detections,
            robot_pose=robot_pose,
            offset_result=offset_result,
            fps=fps,
            latency_ms=latency_ms,
            status="running",
            temperature_c=thermal_status["temperature_c"],
            thermal_state=thermal_status["state"],
            throttle_fps=effective_fps,
        )

        # Publish to NT
        self._nt.publish_frame(detections, robot_pose, offset_result, fps, latency_ms)

    # ------------------------------------------------------------------
    # Config change handler
    # ------------------------------------------------------------------

    def _on_config_change(self, keys, value):
        if not keys:
            return
        section = keys[0]
        if section == "field_map":
            self._reload_fmap()
        elif section in ("camera", "apriltag"):
            self._detector.reload_config()
        elif section == "lights":
            pass  # LightsManager reads from cfg directly

    def _get_effective_throttle_fps(self) -> float:
        """Return the effective processing throttle FPS (manual or thermal auto-throttle).
        Returns 0.0 when no throttle is active (process every frame)."""
        throttle_cfg = self._cfg.get("throttle") or {}
        manual_fps = float(throttle_cfg.get("fps", 0))
        auto_fps = self._thermal.get_auto_throttle_fps()
        # Use the more restrictive of the two (lower value = more throttling,
        # ensuring both the manual cap and the thermal cap are respected)
        if manual_fps > 0 and auto_fps > 0:
            return min(manual_fps, auto_fps)
        return manual_fps or auto_fps

    def _reload_fmap(self):
        fm_cfg = self._cfg.get("field_map") or {}
        fmap_file = fm_cfg.get("fmap_file", "")
        enabled = fm_cfg.get("enabled", False)
        if enabled and fmap_file:
            fm = load_fmap(fmap_file)
            self._field_map = fm
            self._pose_calc.set_field_map(fm)
        else:
            self._field_map = None
            self._pose_calc.set_field_map(None)


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

_pipeline: VisionPipeline = None


def get_pipeline() -> VisionPipeline:
    return _pipeline


def main():
    global _pipeline

    config_path = os.environ.get("XNAV_CONFIG", "/etc/xnav/config.json")
    setup_logging("INFO")
    logger = logging.getLogger("xnav.main")
    logger.info("═══════════════════════════════════════════")
    logger.info("  XNav Vision System - Starting")
    logger.info("═══════════════════════════════════════════")

    _pipeline = VisionPipeline(config_path=config_path)

    def _signal_handler(sig, frame):
        logger.info("Registering shutdown handler...")

    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)

    _pipeline.start()

    # Start web dashboard in background thread if enabled
    _web_proc = None
    try:
        web_mod_path = os.path.join(os.path.dirname(__file__), "../../web_dashboard/app.py")
        if os.path.exists(web_mod_path):
            import subprocess
            _web_proc = subprocess.Popen(
                [sys.executable, web_mod_path],
                env={**os.environ, "XNAV_CONFIG": config_path}
            )
            logger.info("Web dashboard started (PID %d)", _web_proc.pid)
    except Exception as e:
        logger.warning("Could not start web dashboard: %s", e)

    def _signal_handler_with_web(sig, frame):
        logger.info("Shutting down...")
        _pipeline.stop()
        if _web_proc is not None:
            _web_proc.terminate()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _signal_handler_with_web)
    signal.signal(signal.SIGINT, _signal_handler_with_web)

    _pipeline.wait()


if __name__ == "__main__":
    main()
