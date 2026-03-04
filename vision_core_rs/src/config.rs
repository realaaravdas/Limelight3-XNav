//! Thread-safe configuration manager.
//!
//! Rust port of `vision_core/src/config_manager.py`.
//! Loads JSON config from disk, supports nested key-path access,
//! atomic saves, and change-notification callbacks.

use parking_lot::RwLock;
use serde_json::Value;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

type Callback = Box<dyn Fn(&[String], &Value) + Send + Sync>;

struct Inner {
    path: PathBuf,
    config: RwLock<Value>,
    callbacks: RwLock<Vec<Callback>>,
}

/// Thread-safe configuration manager backed by a JSON file.
///
/// Wraps its state in an `Arc` so cloning is cheap and all clones
/// share the same underlying config.
#[derive(Clone)]
pub struct ConfigManager {
    inner: Arc<Inner>,
}

impl ConfigManager {
    /// Create a new `ConfigManager`.
    ///
    /// * `config_path` – override the on-disk path.  When `None` the
    ///   path is read from the `XNAV_CONFIG` env-var, falling back to
    ///   `/etc/xnav/config.json`.
    pub fn new(config_path: Option<&str>) -> Self {
        let path = match config_path {
            Some(p) => PathBuf::from(p),
            None => PathBuf::from(
                env::var("XNAV_CONFIG").unwrap_or_else(|_| "/etc/xnav/config.json".into()),
            ),
        };

        let config = Self::load(&path);

        let mgr = Self {
            inner: Arc::new(Inner {
                path,
                config: RwLock::new(config),
                callbacks: RwLock::new(Vec::new()),
            }),
        };

        // If we fell back to defaults, persist them so the file exists.
        mgr.save();
        mgr
    }

    // ------------------------------------------------------------------
    // Public API
    // ------------------------------------------------------------------

    /// Retrieve a nested config value by key path.
    ///
    /// ```ignore
    /// let fps = cfg.get(&["camera", "fps"]);
    /// ```
    pub fn get(&self, keys: &[&str]) -> Option<Value> {
        let config = self.inner.config.read();
        let mut node = &*config;
        for key in keys {
            node = node.get(*key)?;
        }
        Some(node.clone())
    }

    /// Retrieve a nested value, deserializing it into `T`, or return `default`.
    pub fn get_or<T: serde::de::DeserializeOwned>(&self, keys: &[&str], default: T) -> T {
        self.get(keys)
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or(default)
    }

    /// Convenience: get a float or return `default`.
    pub fn get_f64(&self, keys: &[&str], default: f64) -> f64 {
        self.get(keys)
            .and_then(|v| v.as_f64())
            .unwrap_or(default)
    }

    /// Convenience: get an integer or return `default`.
    pub fn get_i64(&self, keys: &[&str], default: i64) -> i64 {
        self.get(keys)
            .and_then(|v| v.as_i64())
            .unwrap_or(default)
    }

    /// Convenience: get a bool or return `default`.
    pub fn get_bool(&self, keys: &[&str], default: bool) -> bool {
        self.get(keys)
            .and_then(|v| v.as_bool())
            .unwrap_or(default)
    }

    /// Convenience: get a string or return `default`.
    pub fn get_str(&self, keys: &[&str], default: &str) -> String {
        self.get(keys)
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_else(|| default.to_owned())
    }

    /// Set a nested config value and persist.
    ///
    /// Intermediate objects are created automatically.
    ///
    /// ```ignore
    /// cfg.set(&["camera", "fps"], serde_json::json!(90));
    /// ```
    pub fn set(&self, keys: &[&str], value: Value) {
        if keys.is_empty() {
            return;
        }

        {
            let mut config = self.inner.config.write();
            let mut node = &mut *config;
            for key in &keys[..keys.len() - 1] {
                // Create intermediate objects when missing.
                if !node.get(*key).map_or(false, Value::is_object) {
                    node[*key] = Value::Object(serde_json::Map::new());
                }
                node = node.get_mut(*key).unwrap();
            }
            node[*keys.last().unwrap()] = value.clone();
        }

        self.save();
        self.notify(keys, &value);
    }

    /// Replace an entire top-level section and persist.
    pub fn update_section(&self, section: &str, data: Value) {
        {
            let mut config = self.inner.config.write();
            config[section] = data.clone();
        }
        self.save();
        self.notify(&[section], &data);
    }

    /// Return a deep copy of the entire config tree.
    pub fn all(&self) -> Value {
        self.inner.config.read().clone()
    }

    /// Register a callback invoked on every change.
    ///
    /// The callback receives the key path and the new value.
    pub fn register_callback(&self, cb: Box<dyn Fn(&[String], &Value) + Send + Sync>) {
        self.inner.callbacks.write().push(cb);
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// Load config from `path`, falling back to the default template.
    fn load(path: &Path) -> Value {
        if path.exists() {
            match fs::read_to_string(path) {
                Ok(text) => match serde_json::from_str::<Value>(&text) {
                    Ok(val) => {
                        tracing::info!("Config loaded from {}", path.display());
                        return val;
                    }
                    Err(e) => {
                        tracing::warn!("Failed to parse config {}: {}", path.display(), e);
                    }
                },
                Err(e) => {
                    tracing::warn!("Failed to read config {}: {}", path.display(), e);
                }
            }
        }

        // Fallback: default config relative to the current executable.
        let default_path = Self::default_config_path();
        match fs::read_to_string(&default_path) {
            Ok(text) => match serde_json::from_str::<Value>(&text) {
                Ok(val) => {
                    tracing::info!("Loaded default config from {}", default_path.display());
                    val
                }
                Err(e) => {
                    tracing::error!("Failed to parse default config: {}", e);
                    Value::Object(serde_json::Map::new())
                }
            },
            Err(e) => {
                tracing::error!("Failed to load default config: {}", e);
                Value::Object(serde_json::Map::new())
            }
        }
    }

    /// Resolve the path to `system/config/default_config.json` relative to the
    /// running binary (mirrors the Python `../../system/config/default_config.json`).
    fn default_config_path() -> PathBuf {
        env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(Path::to_path_buf))
            .unwrap_or_else(|| PathBuf::from("."))
            .join("../../system/config/default_config.json")
    }

    /// Atomically persist the current config (write to tmp + rename).
    fn save(&self) {
        let config = self.inner.config.read();
        let path = &self.inner.path;

        if let Some(parent) = path.parent() {
            if let Err(e) = fs::create_dir_all(parent) {
                tracing::error!("Failed to create config directory: {}", e);
                return;
            }
        }

        let tmp = path.with_extension("json.tmp");
        match serde_json::to_string_pretty(&*config) {
            Ok(text) => {
                if let Err(e) = fs::write(&tmp, &text) {
                    tracing::error!("Failed to write tmp config: {}", e);
                    return;
                }
                if let Err(e) = fs::rename(&tmp, path) {
                    tracing::error!("Failed to rename tmp config: {}", e);
                }
            }
            Err(e) => {
                tracing::error!("Failed to serialize config: {}", e);
            }
        }
    }

    /// Invoke all registered callbacks.
    fn notify(&self, keys: &[&str], value: &Value) {
        let owned_keys: Vec<String> = keys.iter().map(|k| (*k).to_owned()).collect();
        let callbacks = self.inner.callbacks.read();
        for cb in callbacks.iter() {
            if let Err(e) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                cb(&owned_keys, value);
            })) {
                tracing::warn!("Config callback panicked: {:?}", e);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};
    use tempfile::NamedTempFile;

    fn tmp_config(content: &str) -> NamedTempFile {
        let f = NamedTempFile::new().unwrap();
        fs::write(f.path(), content).unwrap();
        f
    }

    #[test]
    fn load_and_get() {
        let f = tmp_config(r#"{"camera":{"fps":90}}"#);
        let cfg = ConfigManager::new(Some(f.path().to_str().unwrap()));

        assert_eq!(cfg.get_i64(&["camera", "fps"], 0), 90);
        assert_eq!(cfg.get_i64(&["missing"], 42), 42);
    }

    #[test]
    fn set_creates_intermediate() {
        let f = tmp_config(r#"{}"#);
        let cfg = ConfigManager::new(Some(f.path().to_str().unwrap()));

        cfg.set(&["a", "b", "c"], serde_json::json!(true));
        assert!(cfg.get_bool(&["a", "b", "c"], false));
    }

    #[test]
    fn update_section_replaces() {
        let f = tmp_config(r#"{"s":{"old":1}}"#);
        let cfg = ConfigManager::new(Some(f.path().to_str().unwrap()));

        cfg.update_section("s", serde_json::json!({"new": 2}));
        assert_eq!(cfg.get_i64(&["s", "new"], 0), 2);
        assert!(cfg.get(&["s", "old"]).is_none());
    }

    #[test]
    fn all_returns_deep_copy() {
        let f = tmp_config(r#"{"x":1}"#);
        let cfg = ConfigManager::new(Some(f.path().to_str().unwrap()));

        let snap = cfg.all();
        cfg.set(&["x"], serde_json::json!(2));

        // snap must still reflect the old value
        assert_eq!(snap["x"], 1);
    }

    #[test]
    fn callbacks_fire() {
        let f = tmp_config(r#"{}"#);
        let cfg = ConfigManager::new(Some(f.path().to_str().unwrap()));

        let counter = Arc::new(AtomicU32::new(0));
        let c = counter.clone();
        cfg.register_callback(Box::new(move |_keys, _val| {
            c.fetch_add(1, Ordering::Relaxed);
        }));

        cfg.set(&["a"], serde_json::json!(1));
        cfg.update_section("b", serde_json::json!(2));

        assert_eq!(counter.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn atomic_save_persists() {
        let f = tmp_config(r#"{}"#);
        let path = f.path().to_str().unwrap().to_owned();
        let cfg = ConfigManager::new(Some(&path));

        cfg.set(&["k"], serde_json::json!("v"));

        let raw = fs::read_to_string(&path).unwrap();
        let val: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(val["k"], "v");
    }
}
