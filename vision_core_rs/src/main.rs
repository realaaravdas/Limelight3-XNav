//! XNav Vision System — main entry point (Rust port of `vision_core/src/main.py`).

mod calibration;
mod camera;
mod config;
mod detector;
mod fmap;
mod lights;
mod nt_client;
mod pose;
mod thermal;
mod web;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use parking_lot::Mutex as SyncMutex;
use serde_json::Value;
use tokio::sync::{broadcast, Mutex};
use tracing::{info, warn};
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

use crate::calibration::CalibrationManager;
use crate::camera::CameraManager;
use crate::config::ConfigManager;
use crate::detector::AprilTagDetector;
use crate::fmap::{load_fmap, FieldMap};
use crate::lights::LightsManager;
use crate::nt_client::NTPublisher;
use crate::pose::PoseCalculator;
use crate::thermal::ThermalManager;
use crate::web::{run_dashboard, AppState, SharedVisionState};

// ---------------------------------------------------------------------------
// Monotonic clock helper (thread-safe, zero-cost after first call)
// ---------------------------------------------------------------------------

fn monotonic_secs() -> f64 {
    use std::sync::OnceLock;
    static EPOCH: OnceLock<std::time::Instant> = OnceLock::new();
    EPOCH
        .get_or_init(std::time::Instant::now)
        .elapsed()
        .as_secs_f64()
}

// ---------------------------------------------------------------------------
// Vision Pipeline
// ---------------------------------------------------------------------------

struct VisionPipeline {
    cfg: ConfigManager,
    camera: CameraManager,
    detector: Arc<Mutex<AprilTagDetector>>,
    pose_calc: Arc<Mutex<PoseCalculator>>,
    nt: NTPublisher,
    calibration: CalibrationManager,
    lights: LightsManager,
    thermal: ThermalManager,
    field_map: Arc<SyncMutex<Option<FieldMap>>>,
    shared_state: Arc<Mutex<SharedVisionState>>,
    ws_tx: broadcast::Sender<String>,
    running: Arc<AtomicBool>,
    last_process_time: Arc<SyncMutex<f64>>,
}

impl VisionPipeline {
    fn new(config_path: Option<&str>) -> Self {
        let cfg = ConfigManager::new(config_path);
        let camera = CameraManager::new(cfg.clone());
        let detector = Arc::new(Mutex::new(AprilTagDetector::new(cfg.clone())));
        let pose_calc = Arc::new(Mutex::new(PoseCalculator::new(cfg.clone())));
        let nt = NTPublisher::new(cfg.clone());
        let calibration = CalibrationManager::new(cfg.clone());
        let lights = LightsManager::new(cfg.clone());
        let thermal = ThermalManager::new(cfg.clone());
        let (ws_tx, _rx) = broadcast::channel(64);

        let pipeline = Self {
            cfg: cfg.clone(),
            camera,
            detector,
            pose_calc,
            nt,
            calibration,
            lights,
            thermal,
            field_map: Arc::new(SyncMutex::new(None)),
            shared_state: Arc::new(Mutex::new(SharedVisionState::default())),
            ws_tx,
            running: Arc::new(AtomicBool::new(false)),
            last_process_time: Arc::new(SyncMutex::new(0.0)),
        };

        // Register config-change handler.
        // NOTE: `try_lock` is used for the tokio Mutex because this callback
        // may be invoked from within the tokio runtime (e.g. from a web handler
        // calling `ConfigManager::set`).  `blocking_lock` would panic there.
        let detector_ref = pipeline.detector.clone();
        let field_map_ref = pipeline.field_map.clone();
        let pose_calc_ref = pipeline.pose_calc.clone();
        let cfg_ref = cfg.clone();
        cfg.register_callback(Box::new(move |keys: &[String], _value: &Value| {
            if keys.is_empty() {
                return;
            }
            match keys[0].as_str() {
                "field_map" => {
                    reload_fmap_sync(&cfg_ref, &field_map_ref, &pose_calc_ref);
                }
                "camera" | "apriltag" => {
                    if let Ok(mut det) = detector_ref.try_lock() {
                        det.reload_config();
                    } else {
                        warn!("Could not acquire detector lock for config reload");
                    }
                }
                _ => {}
            }
        }));

        pipeline
    }

    /// Async field-map reload used during startup (safe to `.await`).
    async fn reload_fmap(&self) {
        let enabled = self.cfg.get_bool(&["field_map", "enabled"], false);
        let fmap_file = self.cfg.get_str(&["field_map", "fmap_file"], "");

        if enabled && !fmap_file.is_empty() {
            if let Some(fm) = load_fmap(&fmap_file) {
                info!("Field map loaded: {}", fmap_file);
                self.pose_calc.lock().await.set_field_map(Some(fm.clone()));
                *self.field_map.lock() = Some(fm);
            } else {
                warn!("Failed to load field map: {}", fmap_file);
                self.pose_calc.lock().await.set_field_map(None);
                *self.field_map.lock() = None;
            }
        } else {
            self.pose_calc.lock().await.set_field_map(None);
            *self.field_map.lock() = None;
        }
    }

    async fn start(&self) {
        self.running.store(true, Ordering::SeqCst);

        // Load field map before starting subsystems.
        self.reload_fmap().await;

        // Start subsystems.
        self.nt.start().await;
        self.camera.start();
        self.thermal.start();

        {
            let mut state = self.shared_state.lock().await;
            state.status = "running".to_string();
        }
        self.nt.publish_status("running");
        info!("XNav vision pipeline started");

        // ── Register frame callback (runs on camera thread — fully synchronous) ──
        let running = self.running.clone();
        let cfg = self.cfg.clone();
        let detector = self.detector.clone();
        let pose_calc = self.pose_calc.clone();
        let nt = self.nt.clone();
        let calibration = self.calibration.clone();
        let camera = self.camera.clone();
        let thermal = self.thermal.clone();
        let field_map = self.field_map.clone();
        let shared_state = self.shared_state.clone();
        let last_process_time = self.last_process_time.clone();
        let ws_tx = self.ws_tx.clone();

        self.camera.register_frame_callback(Box::new(
            move |_frame: &opencv::core::Mat, gray: &opencv::core::Mat, timestamp: f64| {
                if !running.load(Ordering::Relaxed) {
                    return;
                }

                // ── Throttle gate ──
                let effective_fps = get_effective_throttle_fps(&cfg, &thermal);
                if effective_fps > 0.0 {
                    let min_interval = 1.0 / effective_fps;
                    let now = monotonic_secs();
                    let mut last = last_process_time.lock();
                    if (now - *last) < min_interval {
                        return;
                    }
                    *last = now;
                }

                let t0 = std::time::Instant::now();

                // Read NT inputs.
                let inputs = nt.read_inputs();

                // Detect AprilTags.
                // `blocking_lock` is safe here — the camera thread is outside the
                // tokio runtime so it will never panic.
                let mut detections = detector.blocking_lock().detect(gray, timestamp);

                // Turret compensation.
                let turret_enabled = cfg.get_bool(&["turret", "enabled"], false);
                let use_nt_turret = turret_enabled && inputs.turret_enabled;
                let mut turret_angle = if use_nt_turret {
                    inputs.turret_angle
                } else {
                    0.0
                };
                turret_angle += cfg.get_f64(&["turret", "mount_angle_offset"], 0.0);

                if turret_angle.abs() > 0.001 {
                    detections = pose_calc.blocking_lock().apply_turret(&detections, turret_angle);
                }

                // Robot pose (field-centric).
                let has_field_map = field_map.lock().is_some();
                let robot_pose = if has_field_map {
                    pose_calc.blocking_lock().compute_robot_pose(&detections)
                } else {
                    None
                };

                // Offset point.
                let offset_cfg = cfg
                    .get(&["offset_point"])
                    .unwrap_or_else(|| Value::Object(Default::default()));
                let offset_result = pose_calc
                    .blocking_lock()
                    .compute_offset_point(&detections, &offset_cfg);

                // Timing.
                let latency_ms = t0.elapsed().as_secs_f64() * 1000.0;
                let fps = camera.get_fps();

                // Calibration frame collection.
                let cal_status = calibration.get_status();
                if cal_status.collecting {
                    calibration.add_frame(gray);
                }

                // Thermal status.
                let thermal_status = thermal.get_status();

                // Update shared state and broadcast to WebSocket clients.
                let json = {
                    let mut state = shared_state.blocking_lock();
                    state.detections = detections.clone();
                    state.robot_pose = robot_pose.clone();
                    state.offset_result = offset_result.clone();
                    state.fps = fps;
                    state.latency_ms = latency_ms;
                    state.status = "running".to_string();
                    state.temperature_c = thermal_status.temperature_c;
                    state.thermal_state = thermal_status.state.clone();
                    state.throttle_fps = effective_fps;
                    serde_json::to_string(&*state).ok()
                };
                if let Some(json) = json {
                    let _ = ws_tx.send(json);
                }

                // Publish to NetworkTables.
                nt.publish_frame(
                    &detections,
                    robot_pose.as_ref(),
                    offset_result.as_ref(),
                    fps,
                    latency_ms,
                );
            },
        ));
    }

    fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        self.camera.stop();
        self.nt.stop();
        self.thermal.stop();
        self.lights.cleanup();
        // Best-effort update — `try_lock` avoids panic if called during cleanup.
        if let Ok(mut state) = self.shared_state.try_lock() {
            state.status = "stopped".to_string();
        }
        info!("XNav vision pipeline stopped");
    }

    fn app_state(&self) -> AppState {
        AppState {
            cfg: self.cfg.clone(),
            camera: self.camera.clone(),
            detector: self.detector.clone(),
            pose_calc: self.pose_calc.clone(),
            calibration: self.calibration.clone(),
            lights: self.lights.clone(),
            thermal: self.thermal.clone(),
            nt: self.nt.clone(),
            shared: self.shared_state.clone(),
            ws_tx: self.ws_tx.clone(),
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Synchronous field-map reload for use in config-change callbacks.
/// Uses `try_lock` for the tokio Mutex to avoid panicking when called from
/// within the tokio runtime.
fn reload_fmap_sync(
    cfg: &ConfigManager,
    field_map: &Arc<SyncMutex<Option<FieldMap>>>,
    pose_calc: &Arc<Mutex<PoseCalculator>>,
) {
    let enabled = cfg.get_bool(&["field_map", "enabled"], false);
    let fmap_file = cfg.get_str(&["field_map", "fmap_file"], "");

    if enabled && !fmap_file.is_empty() {
        if let Some(fm) = load_fmap(&fmap_file) {
            info!("Field map loaded: {}", fmap_file);
            if let Ok(mut pc) = pose_calc.try_lock() {
                pc.set_field_map(Some(fm.clone()));
            } else {
                warn!("Could not acquire pose_calc lock for field-map reload");
            }
            *field_map.lock() = Some(fm);
        } else {
            warn!("Failed to load field map: {}", fmap_file);
            if let Ok(mut pc) = pose_calc.try_lock() {
                pc.set_field_map(None);
            }
            *field_map.lock() = None;
        }
    } else {
        if let Ok(mut pc) = pose_calc.try_lock() {
            pc.set_field_map(None);
        }
        *field_map.lock() = None;
    }
}

/// Return the effective processing throttle FPS.
/// Returns 0.0 when no throttle is active (process every frame).
fn get_effective_throttle_fps(cfg: &ConfigManager, thermal: &ThermalManager) -> f64 {
    let manual_fps = cfg.get_f64(&["throttle", "fps"], 0.0);
    let auto_fps = thermal.get_auto_throttle_fps();

    if manual_fps > 0.0 && auto_fps > 0.0 {
        manual_fps.min(auto_fps)
    } else if manual_fps > 0.0 {
        manual_fps
    } else {
        auto_fps
    }
}

// ---------------------------------------------------------------------------
// Tracing setup
// ---------------------------------------------------------------------------

fn setup_tracing() {
    use tracing_subscriber::layer::SubscriberExt;

    let stdout_layer = fmt::layer().with_target(true).with_thread_ids(false);

    let file_layer = if std::path::Path::new("/var/log").exists() {
        let appender = tracing_appender::rolling::never("/var/log", "xnav.log");
        Some(fmt::layer().with_writer(appender).with_ansi(false))
    } else {
        None
    };

    let subscriber = tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .with(stdout_layer)
        .with(file_layer);

    tracing::subscriber::set_global_default(subscriber)
        .expect("failed to set tracing subscriber");
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() {
    setup_tracing();

    info!("═══════════════════════════════════════════");
    info!("  XNav Vision System - Starting");
    info!("═══════════════════════════════════════════");

    let config_path =
        std::env::var("XNAV_CONFIG").unwrap_or_else(|_| "/etc/xnav/config.json".to_string());

    let pipeline = VisionPipeline::new(Some(&config_path));
    pipeline.start().await;

    // Start web dashboard as a background task (unless disabled).
    if std::env::var("XNAV_DISABLE_DASHBOARD").is_err() {
        let app_state = pipeline.app_state();
        tokio::spawn(async move {
            info!("Starting web dashboard");
            run_dashboard(app_state).await;
        });
    }

    // ── Wait for shutdown signal ──
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut sigterm =
            signal(SignalKind::terminate()).expect("failed to register SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                info!("Received SIGINT, shutting down...");
            }
            _ = sigterm.recv() => {
                info!("Received SIGTERM, shutting down...");
            }
        }
    }

    #[cfg(not(unix))]
    {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to listen for Ctrl+C");
        info!("Received SIGINT, shutting down...");
    }

    pipeline.stop();
    info!("XNav vision system stopped");
}
