//! Thermal monitoring and auto-throttle.
//!
//! Rust port of `vision_core/src/thermal_manager.py`.
//! Reads CPU temperature from sysfs and recommends FPS throttling
//! when the device is running hot.  The system **never** shuts down
//! due to temperature — only processing load is reduced.

use crate::config::ConfigManager;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// Thermal zone paths to probe (Raspberry Pi / generic Linux).
const THERMAL_ZONE_PATHS: &[&str] = &[
    "/sys/class/thermal/thermal_zone0/temp",
    "/sys/class/thermal/thermal_zone1/temp",
];

/// Snapshot of the current thermal state.
#[derive(Debug, Clone)]
pub struct ThermalStatus {
    /// CPU temperature in degrees Celsius (0.0 if unavailable).
    pub temperature_c: f64,
    /// One of `"unknown"`, `"ok"`, `"warm"`, `"hot"`, `"critical"`.
    pub state: String,
}

/// Read CPU temperature in Celsius.  Returns `0.0` if unavailable.
fn read_cpu_temp() -> f64 {
    for path in THERMAL_ZONE_PATHS {
        match std::fs::read_to_string(path) {
            Ok(contents) => match contents.trim().parse::<f64>() {
                Ok(millideg) => return millideg / 1000.0,
                Err(_) => continue,
            },
            Err(_) => continue,
        }
    }
    0.0
}

struct Inner {
    cfg: ConfigManager,
    status: Mutex<ThermalStatus>,
    running: AtomicBool,
}

/// Monitors CPU temperature on a background thread and provides
/// auto-throttle FPS recommendations.
///
/// Cheap to clone — all clones share the same underlying state.
#[derive(Clone)]
pub struct ThermalManager {
    inner: Arc<Inner>,
}

// Explicit marker: Inner uses AtomicBool + parking_lot::Mutex which
// are both Send + Sync, and ConfigManager is Clone + Send + Sync.
unsafe impl Send for ThermalManager {}
unsafe impl Sync for ThermalManager {}

impl ThermalManager {
    /// Create a new `ThermalManager`.
    ///
    /// Call [`start`](Self::start) to begin background monitoring.
    pub fn new(cfg: ConfigManager) -> Self {
        Self {
            inner: Arc::new(Inner {
                cfg,
                status: Mutex::new(ThermalStatus {
                    temperature_c: 0.0,
                    state: "unknown".into(),
                }),
                running: AtomicBool::new(false),
            }),
        }
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    /// Start the background temperature-monitoring thread.
    pub fn start(&self) {
        self.inner.running.store(true, Ordering::SeqCst);
        let inner = Arc::clone(&self.inner);
        thread::Builder::new()
            .name("thermal-monitor".into())
            .spawn(move || monitor_loop(&inner))
            .expect("failed to spawn thermal-monitor thread");
        tracing::info!("Thermal monitor started");
    }

    /// Signal the background thread to stop.
    pub fn stop(&self) {
        self.inner.running.store(false, Ordering::SeqCst);
    }

    // ------------------------------------------------------------------
    // Public accessors
    // ------------------------------------------------------------------

    /// Return a snapshot of the current thermal status.
    pub fn get_status(&self) -> ThermalStatus {
        let s = self.inner.status.lock();
        ThermalStatus {
            temperature_c: (s.temperature_c * 10.0).round() / 10.0,
            state: s.state.clone(),
        }
    }

    /// Return an auto-throttle FPS cap based on the current temperature.
    ///
    /// * `>= temp_crit_c` → `throttle_fps_crit` (default 5.0)
    /// * `>= temp_hot_c`  → `throttle_fps_hot`  (default 15.0)
    /// * otherwise        → `0.0` (no throttling)
    pub fn get_auto_throttle_fps(&self) -> f64 {
        let cfg = &self.inner.cfg;
        let temp_hot = cfg.get_f64(&["thermal", "temp_hot_c"], 75.0);
        let temp_crit = cfg.get_f64(&["thermal", "temp_crit_c"], 80.0);
        let fps_hot = cfg.get_f64(&["thermal", "throttle_fps_hot"], 15.0);
        let fps_crit = cfg.get_f64(&["thermal", "throttle_fps_crit"], 5.0);

        let temp = self.inner.status.lock().temperature_c;

        if temp >= temp_crit {
            fps_crit
        } else if temp >= temp_hot {
            fps_hot
        } else {
            0.0
        }
    }
}

// ------------------------------------------------------------------
// Background loop
// ------------------------------------------------------------------

fn monitor_loop(inner: &Inner) {
    while inner.running.load(Ordering::SeqCst) {
        let temp = read_cpu_temp();

        let warn_c = inner.cfg.get_f64(&["thermal", "temp_warn_c"], 70.0);
        let hot_c = inner.cfg.get_f64(&["thermal", "temp_hot_c"], 75.0);
        let crit_c = inner.cfg.get_f64(&["thermal", "temp_crit_c"], 80.0);

        let state = if temp == 0.0 {
            "unknown"
        } else if temp >= crit_c {
            tracing::warn!(
                "CPU temperature CRITICAL: {:.1}°C - throttling to minimum processing rate",
                temp
            );
            "critical"
        } else if temp >= hot_c {
            tracing::warn!(
                "CPU temperature HOT: {:.1}°C - auto-throttling processing",
                temp
            );
            "hot"
        } else if temp >= warn_c {
            tracing::info!("CPU temperature warm: {:.1}°C", temp);
            "warm"
        } else {
            "ok"
        };

        {
            let mut s = inner.status.lock();
            s.temperature_c = temp;
            s.state = state.into();
        }

        thread::sleep(Duration::from_secs(2));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::NamedTempFile;

    fn tmp_config(content: &str) -> (NamedTempFile, ConfigManager) {
        let f = NamedTempFile::new().unwrap();
        fs::write(f.path(), content).unwrap();
        let cfg = ConfigManager::new(Some(f.path().to_str().unwrap()));
        (f, cfg)
    }

    #[test]
    fn initial_status_is_unknown() {
        let (_f, cfg) = tmp_config(r#"{}"#);
        let tm = ThermalManager::new(cfg);
        let s = tm.get_status();
        assert_eq!(s.state, "unknown");
        assert_eq!(s.temperature_c, 0.0);
    }

    #[test]
    fn throttle_fps_defaults_no_throttle() {
        let (_f, cfg) = tmp_config(r#"{}"#);
        let tm = ThermalManager::new(cfg);
        // temp is 0.0 → no throttle
        assert_eq!(tm.get_auto_throttle_fps(), 0.0);
    }

    #[test]
    fn throttle_fps_hot() {
        let (_f, cfg) = tmp_config(r#"{"thermal":{"temp_hot_c":75,"temp_crit_c":80}}"#);
        let tm = ThermalManager::new(cfg);
        {
            let mut s = tm.inner.status.lock();
            s.temperature_c = 76.0;
            s.state = "hot".into();
        }
        assert_eq!(tm.get_auto_throttle_fps(), 15.0);
    }

    #[test]
    fn throttle_fps_critical() {
        let (_f, cfg) = tmp_config(r#"{"thermal":{"temp_hot_c":75,"temp_crit_c":80}}"#);
        let tm = ThermalManager::new(cfg);
        {
            let mut s = tm.inner.status.lock();
            s.temperature_c = 85.0;
            s.state = "critical".into();
        }
        assert_eq!(tm.get_auto_throttle_fps(), 5.0);
    }

    #[test]
    fn status_rounds_temperature() {
        let (_f, cfg) = tmp_config(r#"{}"#);
        let tm = ThermalManager::new(cfg);
        {
            let mut s = tm.inner.status.lock();
            s.temperature_c = 42.456;
        }
        let status = tm.get_status();
        assert_eq!(status.temperature_c, 42.5);
    }

    #[test]
    fn clone_shares_state() {
        let (_f, cfg) = tmp_config(r#"{}"#);
        let tm1 = ThermalManager::new(cfg);
        let tm2 = tm1.clone();
        {
            let mut s = tm1.inner.status.lock();
            s.temperature_c = 55.0;
            s.state = "ok".into();
        }
        let s2 = tm2.get_status();
        assert_eq!(s2.temperature_c, 55.0);
        assert_eq!(s2.state, "ok");
    }

    #[test]
    fn stop_sets_running_false() {
        let (_f, cfg) = tmp_config(r#"{}"#);
        let tm = ThermalManager::new(cfg);
        tm.inner.running.store(true, Ordering::SeqCst);
        tm.stop();
        assert!(!tm.inner.running.load(Ordering::SeqCst));
    }
}
