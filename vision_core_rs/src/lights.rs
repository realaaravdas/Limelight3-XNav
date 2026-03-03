//! LED lights manager.
//!
//! Rust port of `vision_core/src/lights_manager.py`.
//! Controls LED ring light via GPIO PWM on Raspberry Pi;
//! operates in simulation mode on other platforms.

use crate::config::ConfigManager;
use parking_lot::Mutex;
use serde::Serialize;
use std::sync::Arc;

/// Snapshot of the current lights state.
#[derive(Debug, Clone, Serialize)]
pub struct LightsState {
    pub enabled: bool,
    pub brightness: u8,
    pub mode: String,
    pub gpio_available: bool,
}

struct Inner {
    cfg: ConfigManager,
    state: Mutex<State>,
    #[cfg(feature = "rpi")]
    pwm: Mutex<Option<PwmChannel>>,
}

struct State {
    #[allow(dead_code)]
    pin: u8,
    enabled: bool,
    brightness: u8,
    mode: String,
}

// ---------- RPi GPIO helpers (feature-gated) ----------

#[cfg(feature = "rpi")]
struct PwmChannel {
    pin: u8,
}

#[cfg(feature = "rpi")]
impl PwmChannel {
    fn new(pin: u8, _freq_hz: u32) -> Result<Self, String> {
        use std::fs;
        use std::path::Path;

        let export_path = "/sys/class/gpio/export";
        let gpio_dir = format!("/sys/class/gpio/gpio{pin}");

        if !Path::new(&gpio_dir).exists() {
            fs::write(export_path, pin.to_string())
                .map_err(|e| format!("GPIO export failed: {e}"))?;
        }
        fs::write(format!("{gpio_dir}/direction"), "out")
            .map_err(|e| format!("GPIO direction failed: {e}"))?;

        Ok(Self { pin })
    }

    fn set_duty_cycle(&self, duty: u8) {
        let gpio_dir = format!("/sys/class/gpio/gpio{}", self.pin);
        let value = if duty > 0 { "1" } else { "0" };
        if let Err(e) = std::fs::write(format!("{gpio_dir}/value"), value) {
            tracing::warn!("GPIO write failed: {e}");
        }
    }

    fn stop(&self) {
        self.set_duty_cycle(0);
    }

    fn cleanup(&self) {
        self.stop();
        let unexport = "/sys/class/gpio/unexport";
        let _ = std::fs::write(unexport, self.pin.to_string());
    }
}

// ---------- LightsManager ----------

/// Controls LED ring light via GPIO PWM.
///
/// `Clone` is cheap – all clones share the same underlying state.
#[derive(Clone)]
pub struct LightsManager {
    inner: Arc<Inner>,
}

impl LightsManager {
    /// Create a new `LightsManager`, reading initial settings from `cfg`.
    pub fn new(cfg: ConfigManager) -> Self {
        let lights_val = cfg.get(&["lights"]);

        let pin = lights_val
            .as_ref()
            .and_then(|v| v.get("gpio_pin"))
            .and_then(|v| v.as_u64())
            .unwrap_or(18) as u8;

        let enabled = lights_val
            .as_ref()
            .and_then(|v| v.get("enabled"))
            .and_then(|v| v.as_bool())
            .unwrap_or(true);

        let brightness = lights_val
            .as_ref()
            .and_then(|v| v.get("brightness"))
            .and_then(|v| v.as_u64())
            .unwrap_or(100)
            .min(100) as u8;

        let mode = lights_val
            .as_ref()
            .and_then(|v| v.get("mode"))
            .and_then(|v| v.as_str())
            .unwrap_or("on")
            .to_string();

        let state = State {
            pin,
            enabled,
            brightness,
            mode,
        };

        #[cfg(feature = "rpi")]
        let pwm = {
            match PwmChannel::new(pin, 1000) {
                Ok(p) => {
                    tracing::info!("Lights initialized on GPIO pin {pin}");
                    Mutex::new(Some(p))
                }
                Err(e) => {
                    tracing::error!("Failed to init lights: {e}");
                    Mutex::new(None)
                }
            }
        };

        #[cfg(not(feature = "rpi"))]
        tracing::warn!(
            "RPi.GPIO not available - light control disabled (simulation mode)"
        );

        let mgr = Self {
            inner: Arc::new(Inner {
                cfg,
                state: Mutex::new(state),
                #[cfg(feature = "rpi")]
                pwm,
            }),
        };

        mgr.apply();
        mgr
    }

    /// Enable or disable the lights.
    pub fn set_enabled(&self, enabled: bool) {
        {
            let mut s = self.inner.state.lock();
            s.enabled = enabled;
        }
        self.inner
            .cfg
            .set(&["lights", "enabled"], serde_json::Value::Bool(enabled));
        self.apply();
    }

    /// Set brightness (clamped to 0–100).
    pub fn set_brightness(&self, brightness: u8) {
        let clamped = brightness.min(100);
        {
            let mut s = self.inner.state.lock();
            s.brightness = clamped;
        }
        self.inner.cfg.set(
            &["lights", "brightness"],
            serde_json::Value::Number(clamped.into()),
        );
        self.apply();
    }

    /// Set mode: `"on"`, `"off"`, or `"blink"`.
    pub fn set_mode(&self, mode: &str) {
        {
            let mut s = self.inner.state.lock();
            s.mode = mode.to_string();
        }
        self.inner.cfg.set(
            &["lights", "mode"],
            serde_json::Value::String(mode.to_string()),
        );
        self.apply();
    }

    /// Return a snapshot of the current lights state.
    pub fn get_state(&self) -> LightsState {
        let s = self.inner.state.lock();
        LightsState {
            enabled: s.enabled,
            brightness: s.brightness,
            mode: s.mode.clone(),
            gpio_available: Self::gpio_available(),
        }
    }

    /// Release GPIO resources.
    pub fn cleanup(&self) {
        #[cfg(feature = "rpi")]
        {
            let mut pwm = self.inner.pwm.lock();
            if let Some(ref p) = *pwm {
                p.cleanup();
            }
            *pwm = None;
        }
    }

    // ---- private ----

    fn gpio_available() -> bool {
        cfg!(feature = "rpi")
    }

    fn apply(&self) {
        #[cfg(feature = "rpi")]
        {
            let s = self.inner.state.lock();
            let pwm_guard = self.inner.pwm.lock();
            let pwm = match pwm_guard.as_ref() {
                Some(p) => p,
                None => return,
            };

            let duty = if !s.enabled || s.mode == "off" {
                0
            } else {
                s.brightness
            };

            pwm.set_duty_cycle(duty);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_cfg() -> (ConfigManager, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("lights_test.json");
        let cfg = ConfigManager::new(Some(path.to_str().unwrap()));
        (cfg, dir)
    }

    #[test]
    fn default_state() {
        let (cfg, _dir) = test_cfg();
        let mgr = LightsManager::new(cfg);
        let st = mgr.get_state();
        assert!(st.enabled);
        assert_eq!(st.brightness, 100);
        assert_eq!(st.mode, "on");
    }

    #[test]
    fn set_brightness_clamps() {
        let (cfg, _dir) = test_cfg();
        let mgr = LightsManager::new(cfg);
        mgr.set_brightness(200);
        assert_eq!(mgr.get_state().brightness, 100);
        mgr.set_brightness(50);
        assert_eq!(mgr.get_state().brightness, 50);
    }

    #[test]
    fn set_mode_and_enabled() {
        let (cfg, _dir) = test_cfg();
        let mgr = LightsManager::new(cfg);
        mgr.set_mode("off");
        assert_eq!(mgr.get_state().mode, "off");
        mgr.set_enabled(false);
        assert!(!mgr.get_state().enabled);
    }

    #[test]
    fn clone_shares_state() {
        let (cfg, _dir) = test_cfg();
        let mgr = LightsManager::new(cfg);
        let mgr2 = mgr.clone();
        mgr.set_brightness(42);
        assert_eq!(mgr2.get_state().brightness, 42);
    }
}
