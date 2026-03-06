//! Camera capture manager.
//!
//! Rust port of `vision_core/src/camera_manager.py`.
//! Manages V4L2 camera capture, settings, and frame delivery.

use crate::config::ConfigManager;
use opencv::{core, imgcodecs, imgproc, prelude::*, videoio};
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

/// Callback invoked for each captured frame: `(color, gray, timestamp)`.
pub type FrameCallback = Box<dyn Fn(&core::Mat, &core::Mat, f64) + Send + Sync>;

struct CameraState {
    latest_frame: Option<core::Mat>,
    latest_gray: Option<core::Mat>,
    frame_time: f64,
    fps_actual: f64,
}

struct Inner {
    cfg: ConfigManager,
    state: Mutex<CameraState>,
    running: AtomicBool,
    callbacks: Mutex<Vec<FrameCallback>>,
}

/// Thread-safe camera capture manager.
///
/// Wraps state in an `Arc` so cloning is cheap and all clones share the
/// same underlying capture pipeline.
#[derive(Clone)]
pub struct CameraManager {
    inner: Arc<Inner>,
}

impl CameraManager {
    pub fn new(cfg: ConfigManager) -> Self {
        Self {
            inner: Arc::new(Inner {
                cfg,
                state: Mutex::new(CameraState {
                    latest_frame: None,
                    latest_gray: None,
                    frame_time: 0.0,
                    fps_actual: 0.0,
                }),
                running: AtomicBool::new(false),
                callbacks: Mutex::new(Vec::new()),
            }),
        }
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    /// Start the background capture thread.
    pub fn start(&self) {
        self.inner.running.store(true, Ordering::SeqCst);
        let inner = Arc::clone(&self.inner);
        thread::Builder::new()
            .name("CamCapture".into())
            .spawn(move || capture_loop(&inner))
            .expect("failed to spawn capture thread");
        tracing::info!("Camera manager started");
    }

    /// Signal the capture thread to stop.
    pub fn stop(&self) {
        self.inner.running.store(false, Ordering::SeqCst);
        // Give the capture thread time to exit and release the device.
        thread::sleep(Duration::from_millis(500));
        tracing::info!("Camera manager stopped");
    }

    /// Stop and restart the capture pipeline.
    pub fn restart(&self) {
        self.stop();
        thread::sleep(Duration::from_millis(500));
        self.start();
    }

    // ------------------------------------------------------------------
    // Frame access
    // ------------------------------------------------------------------

    /// Returns cloned `(color_frame, gray_frame, timestamp)`.
    pub fn get_frame(&self) -> (Option<core::Mat>, Option<core::Mat>, f64) {
        let state = self.inner.state.lock();
        (
            state.latest_frame.as_ref().map(|m| m.clone()),
            state.latest_gray.as_ref().map(|m| m.clone()),
            state.frame_time,
        )
    }

    /// Current measured capture FPS.
    pub fn get_fps(&self) -> f64 {
        self.inner.state.lock().fps_actual
    }

    /// Register a callback invoked for each new frame.
    pub fn register_frame_callback(&self, cb: FrameCallback) {
        self.inner.callbacks.lock().push(cb);
    }

    // ------------------------------------------------------------------
    // Settings
    // ------------------------------------------------------------------

    /// Apply current config camera settings to the capture device.
    ///
    /// This is called automatically when the camera is opened, but can
    /// also be called externally after config changes.
    pub fn apply_settings(&self) {
        // We cannot hold the V4L2 device handle across threads via the
        // public API—settings are applied inside the capture loop after
        // opening the device.  This method is kept for API parity; the
        // capture loop re-reads config each time it (re-)opens the camera.
        tracing::info!("Camera settings will be applied on next open");
    }

    /// Return the latest frame encoded as JPEG bytes for MJPEG streaming.
    pub fn get_jpeg_frame(&self, quality: i32) -> Option<Vec<u8>> {
        let frame = {
            let state = self.inner.state.lock();
            state.latest_frame.as_ref().map(|m| m.clone())
        };
        let frame = frame?;
        let params = core::Vector::from_slice(&[imgcodecs::IMWRITE_JPEG_QUALITY, quality]);
        let mut buf = core::Vector::<u8>::new();
        imgcodecs::imencode(".jpg", &frame, &mut buf, &params).ok()?;
        Some(buf.iter().collect())
    }
}

// ------------------------------------------------------------------
// Internal helpers (free functions keep `Inner` non-`pub`)
// ------------------------------------------------------------------

/// Try to open a V4L2 camera; device path first, then index fallback.
fn open_camera(cfg: &ConfigManager) -> Option<videoio::VideoCapture> {
    let device = cfg.get_str(&["camera", "device"], "/dev/video0");
    let width = cfg.get_i64(&["camera", "width"], 1280) as f64;
    let height = cfg.get_i64(&["camera", "height"], 720) as f64;
    let fps = cfg.get_i64(&["camera", "fps"], 90) as f64;
    let idx = cfg.get_i64(&["camera", "camera_index"], 0) as i32;

    let fourcc = videoio::VideoWriter::fourcc('M', 'J', 'P', 'G')
        .unwrap_or(0) as f64;

    // Try device path first, then index.
    let sources: Vec<Box<dyn Fn() -> opencv::Result<videoio::VideoCapture>>> = vec![
        Box::new({
            let dev = device.clone();
            move || videoio::VideoCapture::from_file(&dev, videoio::CAP_V4L2)
        }),
        Box::new(move || videoio::VideoCapture::new(idx, videoio::CAP_V4L2)),
    ];

    for open_fn in &sources {
        if let Ok(mut cap) = open_fn() {
            if cap.is_opened().unwrap_or(false) {
                let _ = cap.set(videoio::CAP_PROP_FRAME_WIDTH, width);
                let _ = cap.set(videoio::CAP_PROP_FRAME_HEIGHT, height);
                let _ = cap.set(videoio::CAP_PROP_FPS, fps);
                let _ = cap.set(videoio::CAP_PROP_FOURCC, fourcc);
                let _ = cap.set(videoio::CAP_PROP_BUFFERSIZE, 1.0);
                tracing::info!(
                    "Camera opened: res={}x{} fps={}",
                    width as i32,
                    height as i32,
                    fps as i32
                );
                return Some(cap);
            }
            let _ = cap.release();
        }
    }

    tracing::error!("Failed to open camera");
    None
}

/// Apply exposure, gain, brightness and contrast from config.
fn apply_settings_to_device(cap: &mut videoio::VideoCapture, cfg: &ConfigManager) {
    let auto_exp = cfg.get_bool(&["camera", "auto_exposure"], false);
    // V4L2 auto exposure: 1 = manual, 3 = auto
    let _ = cap.set(
        videoio::CAP_PROP_AUTO_EXPOSURE,
        if auto_exp { 3.0 } else { 1.0 },
    );
    if !auto_exp {
        let exposure = cfg.get_f64(&["camera", "exposure"], 100.0);
        let _ = cap.set(videoio::CAP_PROP_EXPOSURE, exposure);
    }

    let gain = cfg.get_f64(&["camera", "gain"], 50.0);
    let brightness = cfg.get_f64(&["camera", "brightness"], 50.0);
    let contrast = cfg.get_f64(&["camera", "contrast"], 50.0);

    let _ = cap.set(videoio::CAP_PROP_GAIN, gain);
    let _ = cap.set(videoio::CAP_PROP_BRIGHTNESS, brightness);
    let _ = cap.set(videoio::CAP_PROP_CONTRAST, contrast);
    tracing::info!("Camera settings applied");
}

/// Main capture loop executed on a background thread.
fn capture_loop(inner: &Inner) {
    let mut cap = open_camera(&inner.cfg);
    if let Some(ref mut c) = cap {
        apply_settings_to_device(c, &inner.cfg);
    }

    let mut frame_count: u64 = 0;
    let mut fps_t0 = Instant::now();
    let epoch = Instant::now();

    while inner.running.load(Ordering::SeqCst) {
        // Ensure camera is open.
        let c = match cap.as_mut() {
            Some(c) if c.is_opened().unwrap_or(false) => c,
            _ => {
                tracing::warn!("Camera not open, retrying in 2s…");
                thread::sleep(Duration::from_secs(2));
                cap = open_camera(&inner.cfg);
                if let Some(ref mut c) = cap {
                    apply_settings_to_device(c, &inner.cfg);
                }
                continue;
            }
        };

        let mut frame = core::Mat::default();
        let ok = c.read(&mut frame).unwrap_or(false);
        if !ok || frame.empty() {
            tracing::warn!("Failed to capture frame, retrying…");
            thread::sleep(Duration::from_millis(50));
            continue;
        }

        let ts = epoch.elapsed().as_secs_f64();

        // Convert to grayscale.
        let mut gray = core::Mat::default();
        if imgproc::cvt_color(&frame, &mut gray, imgproc::COLOR_BGR2GRAY, 0).is_err() {
            tracing::warn!("cvtColor failed, skipping frame");
            continue;
        }

        // Store latest frame.
        {
            let mut state = inner.state.lock();
            state.latest_frame = Some(frame.clone());
            state.latest_gray = Some(gray.clone());
            state.frame_time = ts;
        }

        // FPS calculation.
        frame_count += 1;
        let elapsed = fps_t0.elapsed().as_secs_f64();
        if elapsed >= 1.0 {
            let fps = frame_count as f64 / elapsed;
            inner.state.lock().fps_actual = fps;
            frame_count = 0;
            fps_t0 = Instant::now();
        }

        // Fire callbacks.
        let callbacks = inner.callbacks.lock();
        for cb in callbacks.iter() {
            if let Err(e) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                cb(&frame, &gray, ts);
            })) {
                tracing::warn!("Frame callback error: {:?}", e);
            }
        }
    }

    // Release device on exit.
    if let Some(ref mut c) = cap {
        let _ = c.release();
    }
}
