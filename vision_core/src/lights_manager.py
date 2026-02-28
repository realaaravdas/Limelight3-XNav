"""
XNav Lights Manager
Controls LED lights via GPIO on Raspberry Pi CM.
"""

import logging
import threading

logger = logging.getLogger(__name__)

try:
    import RPi.GPIO as GPIO
    _GPIO_AVAILABLE = True
except (ImportError, RuntimeError):
    _GPIO_AVAILABLE = False
    GPIO = None


class LightsManager:
    """Controls LED ring light via GPIO PWM."""

    def __init__(self, config_manager):
        self._cfg = config_manager
        self._pwm = None
        self._pin: int = 18
        self._enabled: bool = True
        self._brightness: int = 100
        self._mode: str = "on"
        self._lock = threading.Lock()
        self._init()

    def _init(self):
        lights = self._cfg.get("lights") or {}
        self._pin = int(lights.get("gpio_pin", 18))
        self._enabled = bool(lights.get("enabled", True))
        self._brightness = int(lights.get("brightness", 100))
        self._mode = str(lights.get("mode", "on"))

        if not _GPIO_AVAILABLE:
            logger.warning("RPi.GPIO not available - light control disabled (simulation mode)")
            return

        try:
            GPIO.setmode(GPIO.BCM)
            GPIO.setwarnings(False)
            GPIO.setup(self._pin, GPIO.OUT)
            self._pwm = GPIO.PWM(self._pin, 1000)  # 1kHz PWM
            self._pwm.start(0)
            self._apply()
            logger.info("Lights initialized on GPIO pin %d", self._pin)
        except Exception as e:
            logger.error("Failed to init lights: %s", e)

    def set_enabled(self, enabled: bool):
        with self._lock:
            self._enabled = enabled
            self._cfg.set("lights", "enabled", enabled)
            self._apply()

    def set_brightness(self, brightness: int):
        with self._lock:
            self._brightness = max(0, min(100, brightness))
            self._cfg.set("lights", "brightness", self._brightness)
            self._apply()

    def set_mode(self, mode: str):
        """Mode: 'on', 'off', 'blink'"""
        with self._lock:
            self._mode = mode
            self._cfg.set("lights", "mode", mode)
            self._apply()

    def get_state(self) -> dict:
        return {
            "enabled": self._enabled,
            "brightness": self._brightness,
            "mode": self._mode,
            "gpio_available": _GPIO_AVAILABLE
        }

    def cleanup(self):
        if self._pwm:
            try:
                self._pwm.stop()
                GPIO.cleanup(self._pin)
            except Exception:
                pass

    def _apply(self):
        if not _GPIO_AVAILABLE or self._pwm is None:
            return
        if not self._enabled or self._mode == "off":
            duty = 0
        else:
            duty = self._brightness
        try:
            self._pwm.ChangeDutyCycle(duty)
        except Exception as e:
            logger.warning("Light apply error: %s", e)
