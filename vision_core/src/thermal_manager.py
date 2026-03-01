"""
XNav Thermal Manager

Monitors CPU temperature and manages processing throttle to prevent overheating.
This is a critical system - temperature events NEVER trigger a shutdown, only
reduced processing load.
"""

import os
import time
import threading
import logging

logger = logging.getLogger(__name__)

# Primary thermal zone path (Raspberry Pi / generic Linux)
_THERMAL_ZONE_PATHS = [
    "/sys/class/thermal/thermal_zone0/temp",
    "/sys/class/thermal/thermal_zone1/temp",
]


def _read_cpu_temp() -> float:
    """Read CPU temperature in Celsius. Returns 0.0 if unavailable."""
    for path in _THERMAL_ZONE_PATHS:
        try:
            with open(path) as f:
                return float(f.read().strip()) / 1000.0
        except (OSError, ValueError):
            continue
        except Exception as e:
            logger.debug("Unexpected error reading thermal zone %s: %s", path, e)
            continue
    return 0.0


class ThermalManager:
    """
    Reads CPU temperature on a background thread and exposes the current
    temperature and thermal state.  Provides an auto-throttle FPS recommendation
    when the device is running hot.

    States: ok / warm / hot / critical
    The system never shuts down due to temperature - only processing load is reduced.
    """

    def __init__(self, cfg):
        self._cfg = cfg
        self._lock = threading.Lock()
        self._temp_c: float = 0.0
        self._state: str = "unknown"
        self._running = False
        self._thread: threading.Thread = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self):
        self._running = True
        self._thread = threading.Thread(
            target=self._monitor_loop, daemon=True, name="thermal-monitor"
        )
        self._thread.start()
        logger.info("Thermal monitor started")

    def stop(self):
        self._running = False

    # ------------------------------------------------------------------
    # Public accessors
    # ------------------------------------------------------------------

    @property
    def temperature_c(self) -> float:
        with self._lock:
            return self._temp_c

    @property
    def state(self) -> str:
        with self._lock:
            return self._state

    def get_status(self) -> dict:
        with self._lock:
            return {"temperature_c": round(self._temp_c, 1), "state": self._state}

    def get_auto_throttle_fps(self) -> float:
        """
        Return an auto-throttle FPS cap based on current temperature.
        Returns 0.0 when no thermal throttling is needed.
        """
        thermal_cfg = self._cfg.get("thermal") or {}
        temp_hot  = float(thermal_cfg.get("temp_hot_c",  75.0))
        temp_crit = float(thermal_cfg.get("temp_crit_c", 80.0))
        fps_hot   = float(thermal_cfg.get("throttle_fps_hot",  15.0))
        fps_crit  = float(thermal_cfg.get("throttle_fps_crit",  5.0))

        with self._lock:
            temp = self._temp_c

        if temp >= temp_crit:
            return fps_crit
        if temp >= temp_hot:
            return fps_hot
        return 0.0

    # ------------------------------------------------------------------
    # Background loop
    # ------------------------------------------------------------------

    def _monitor_loop(self):
        while self._running:
            temp = _read_cpu_temp()

            thermal_cfg = self._cfg.get("thermal") or {}
            warn_c = float(thermal_cfg.get("temp_warn_c", 70.0))
            hot_c  = float(thermal_cfg.get("temp_hot_c",  75.0))
            crit_c = float(thermal_cfg.get("temp_crit_c", 80.0))

            if temp == 0.0:
                state = "unknown"
            elif temp >= crit_c:
                state = "critical"
                logger.warning(
                    "CPU temperature CRITICAL: %.1f°C - throttling to minimum processing rate", temp
                )
            elif temp >= hot_c:
                state = "hot"
                logger.warning(
                    "CPU temperature HOT: %.1f°C - auto-throttling processing", temp
                )
            elif temp >= warn_c:
                state = "warm"
                logger.info("CPU temperature warm: %.1f°C", temp)
            else:
                state = "ok"

            with self._lock:
                self._temp_c = temp
                self._state = state

            time.sleep(2.0)
