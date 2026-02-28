"""
XNav Config Manager
Handles loading, saving, and accessing system configuration from /etc/xnav/config.json
"""

import json
import os
import copy
import threading
import logging

logger = logging.getLogger(__name__)

CONFIG_PATH = os.environ.get("XNAV_CONFIG", "/etc/xnav/config.json")
DEFAULT_CONFIG_PATH = os.path.join(os.path.dirname(__file__), "../../system/config/default_config.json")


class ConfigManager:
    """Thread-safe configuration manager."""

    def __init__(self, config_path: str = CONFIG_PATH):
        self._path = config_path
        self._lock = threading.RLock()
        self._config: dict = {}
        self._callbacks: list = []
        self._load()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def get(self, *keys, default=None):
        """Retrieve a nested config value using dot-path keys."""
        with self._lock:
            node = self._config
            for k in keys:
                if not isinstance(node, dict) or k not in node:
                    return default
                node = node[k]
            return copy.deepcopy(node)

    def set(self, *keys_and_value):
        """Set a nested config value. Last argument is the value.
        e.g. set("camera", "fps", 90)
        """
        if len(keys_and_value) < 2:
            raise ValueError("Need at least one key and one value")
        keys = keys_and_value[:-1]
        value = keys_and_value[-1]
        with self._lock:
            node = self._config
            for k in keys[:-1]:
                node = node.setdefault(k, {})
            node[keys[-1]] = value
        self._save()
        self._notify(list(keys), value)

    def update_section(self, section: str, data: dict):
        """Replace an entire top-level section and save."""
        with self._lock:
            self._config[section] = data
        self._save()
        self._notify([section], data)

    def all(self) -> dict:
        with self._lock:
            return copy.deepcopy(self._config)

    def register_callback(self, cb):
        """Register a callback(keys: list, value) called on any change."""
        self._callbacks.append(cb)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _load(self):
        if os.path.exists(self._path):
            try:
                with open(self._path, "r") as f:
                    self._config = json.load(f)
                logger.info("Config loaded from %s", self._path)
                return
            except Exception as e:
                logger.warning("Failed to load config %s: %s", self._path, e)

        # Load defaults
        try:
            with open(DEFAULT_CONFIG_PATH, "r") as f:
                self._config = json.load(f)
            logger.info("Loaded default config from %s", DEFAULT_CONFIG_PATH)
        except Exception as e:
            logger.error("Failed to load default config: %s", e)
            self._config = {}

        self._save()

    def _save(self):
        try:
            os.makedirs(os.path.dirname(self._path), exist_ok=True)
            tmp = self._path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self._config, f, indent=2)
            os.replace(tmp, self._path)
        except Exception as e:
            logger.error("Failed to save config: %s", e)

    def _notify(self, keys, value):
        for cb in self._callbacks:
            try:
                cb(keys, value)
            except Exception as e:
                logger.warning("Config callback error: %s", e)
