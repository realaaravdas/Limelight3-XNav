//! Camera calibration via checkerboard detection.
//!
//! Rust port of `vision_core/src/calibration.py`.

use crate::config::ConfigManager;
use opencv::core::{Mat, Point2f, Point3f, Size, TermCriteria, Vector};
use opencv::prelude::*;
use parking_lot::Mutex;
use serde::Serialize;
use std::fs;
use std::path::Path;
use std::sync::Arc;

// ── Public types ─────────────────────────────────────────────────────

#[derive(Clone)]
pub struct CalibrationManager {
    inner: Arc<Inner>,
}

struct Inner {
    cfg: ConfigManager,
    state: Mutex<CalibrationState>,
}

struct CalibrationState {
    frames: Vec<Mat>,
    is_collecting: bool,
    progress: usize,
    target_frames: usize,
    last_status: String,
    result: Option<CalibrationResult>,
}

#[derive(Clone, Debug, Serialize)]
pub struct CalibrationResult {
    pub camera_matrix: Vec<Vec<f64>>,
    pub dist_coeffs: Vec<Vec<f64>>,
    pub rms_error: f64,
    pub image_size: Vec<i32>,
    pub num_frames: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct CalibrationStatus {
    pub collecting: bool,
    pub progress: usize,
    pub target: usize,
    pub status: String,
    pub has_result: bool,
}

// ── Helpers ──────────────────────────────────────────────────────────

fn mat_to_vec2d(m: &Mat) -> Vec<Vec<f64>> {
    let rows = m.rows();
    let cols = m.cols();
    (0..rows)
        .map(|r| {
            (0..cols)
                .map(|c| *m.at_2d::<f64>(r, c).unwrap_or(&0.0))
                .collect()
        })
        .collect()
}

// ── Implementation ───────────────────────────────────────────────────

impl CalibrationManager {
    pub fn new(cfg: ConfigManager) -> Self {
        Self {
            inner: Arc::new(Inner {
                cfg,
                state: Mutex::new(CalibrationState {
                    frames: Vec::new(),
                    is_collecting: false,
                    progress: 0,
                    target_frames: 20,
                    last_status: "idle".into(),
                    result: None,
                }),
            }),
        }
    }

    // ── Collection control ───────────────────────────────────────────

    pub fn start_collection(&self, target_frames: usize) {
        let mut st = self.inner.state.lock();
        st.frames.clear();
        st.is_collecting = true;
        st.progress = 0;
        st.target_frames = target_frames;
        st.last_status = "collecting".into();
        tracing::info!("Calibration collection started, target {} frames", target_frames);
    }

    pub fn stop_collection(&self) {
        let mut st = self.inner.state.lock();
        st.is_collecting = false;
        st.last_status = "stopped".into();
    }

    /// Try to find a checkerboard in `gray` and store the frame if found.
    pub fn add_frame(&self, gray: &Mat) -> bool {
        {
            let st = self.inner.state.lock();
            if !st.is_collecting || st.progress >= st.target_frames {
                return false;
            }
        }

        let (cols, rows) = self.board_size();
        let pattern = Size::new(cols, rows);

        let flags = opencv::calib3d::CALIB_CB_ADAPTIVE_THRESH
            | opencv::calib3d::CALIB_CB_NORMALIZE_IMAGE
            | opencv::calib3d::CALIB_CB_FAST_CHECK;

        let mut corners = Vector::<Point2f>::new();
        let found = opencv::calib3d::find_chessboard_corners(gray, pattern, &mut corners, flags)
            .unwrap_or(false);

        if found {
            let mut st = self.inner.state.lock();
            if st.progress < st.target_frames {
                st.frames.push(gray.clone());
                st.progress += 1;
                tracing::debug!("Calibration frame {}/{}", st.progress, st.target_frames);
                if st.progress >= st.target_frames {
                    st.is_collecting = false;
                    st.last_status = "ready_to_calibrate".into();
                }
            }
            return true;
        }
        false
    }

    pub fn get_status(&self) -> CalibrationStatus {
        let st = self.inner.state.lock();
        CalibrationStatus {
            collecting: st.is_collecting,
            progress: st.progress,
            target: st.target_frames,
            status: st.last_status.clone(),
            has_result: st.result.is_some(),
        }
    }

    // ── Calibration computation ──────────────────────────────────────

    /// Run calibration on collected frames. Returns `(success, message)`.
    pub fn compute_calibration(&self) -> (bool, String) {
        let frames: Vec<Mat> = {
            let st = self.inner.state.lock();
            st.frames.clone()
        };

        if frames.len() < 5 {
            return (false, format!("Need at least 5 frames, have {}", frames.len()));
        }

        let (cols, rows) = self.board_size();
        let square_size = self.inner.cfg.get_f64(
            &["calibration", "checkerboard_square_size"],
            0.025,
        );
        let pattern = Size::new(cols, rows);

        // Prepare template object points.
        let mut obj_p = Vector::<Point3f>::new();
        for r in 0..rows {
            for c in 0..cols {
                obj_p.push(Point3f::new(
                    c as f32 * square_size as f32,
                    r as f32 * square_size as f32,
                    0.0,
                ));
            }
        }

        let criteria = TermCriteria {
            typ: opencv::core::TermCriteria_EPS + opencv::core::TermCriteria_MAX_ITER,
            max_count: 30,
            epsilon: 0.001,
        };

        let mut obj_points = Vector::<Vector<Point3f>>::new();
        let mut img_points = Vector::<Vector<Point2f>>::new();
        let mut img_size = Size::default();

        for gray in &frames {
            let mut corners = Vector::<Point2f>::new();
            let found =
                opencv::calib3d::find_chessboard_corners(gray, pattern, &mut corners, 0)
                    .unwrap_or(false);
            if !found {
                continue;
            }

            let mut refined = corners.clone();
            // Refine in-place; on failure `refined` retains the original corners.
            let _ = opencv::imgproc::corner_sub_pix(
                gray,
                &mut refined,
                Size::new(11, 11),
                Size::new(-1, -1),
                criteria,
            );

            obj_points.push(obj_p.clone());
            img_points.push(refined);
            img_size = Size::new(gray.cols(), gray.rows());
        }

        if obj_points.len() < 5 {
            return (false, "Not enough valid frames for calibration".into());
        }

        tracing::info!("Computing calibration from {} frames...", obj_points.len());
        {
            let mut st = self.inner.state.lock();
            st.last_status = "computing".into();
        }

        let mut camera_matrix = Mat::default();
        let mut dist_coeffs = Mat::default();
        let mut rvecs = Vector::<Mat>::new();
        let mut tvecs = Vector::<Mat>::new();

        let rms = match opencv::calib3d::calibrate_camera(
            &obj_points,
            &img_points,
            img_size,
            &mut camera_matrix,
            &mut dist_coeffs,
            &mut rvecs,
            &mut tvecs,
            0,
            criteria,
        ) {
            Ok(v) => v,
            Err(e) => {
                let mut st = self.inner.state.lock();
                st.last_status = "error".into();
                return (false, format!("Calibration failed: {e}"));
            }
        };

        let result = CalibrationResult {
            camera_matrix: mat_to_vec2d(&camera_matrix),
            dist_coeffs: mat_to_vec2d(&dist_coeffs),
            rms_error: rms,
            image_size: vec![img_size.width, img_size.height],
            num_frames: obj_points.len(),
        };

        {
            let mut st = self.inner.state.lock();
            st.result = Some(result.clone());
            st.last_status = "done".into();
        }

        self.save_calibration(&result);

        tracing::info!("Calibration done. RMS error: {:.4}", rms);
        (true, format!("Calibration successful. RMS error: {rms:.4}"))
    }

    pub fn get_result(&self) -> Option<CalibrationResult> {
        self.inner.state.lock().result.clone()
    }

    /// Draw checkerboard corners on `frame` for a live preview.
    pub fn draw_preview(&self, frame: &Mat) -> Mat {
        let (cols, rows) = self.board_size();
        let pattern = Size::new(cols, rows);

        // Convert to gray for detection.
        let gray = if frame.channels() == 3 {
            let mut g = Mat::default();
            let _ = opencv::imgproc::cvt_color(frame, &mut g, opencv::imgproc::COLOR_BGR2GRAY, 0);
            g
        } else {
            frame.clone()
        };

        let mut corners = Vector::<Point2f>::new();
        let found =
            opencv::calib3d::find_chessboard_corners(&gray, pattern, &mut corners, 0)
                .unwrap_or(false);

        // Build output as BGR.
        let mut out = if frame.channels() == 1 {
            let mut bgr = Mat::default();
            let _ = opencv::imgproc::cvt_color(frame, &mut bgr, opencv::imgproc::COLOR_GRAY2BGR, 0);
            bgr
        } else {
            frame.clone()
        };

        if found {
            let _ = opencv::calib3d::draw_chessboard_corners(&mut out, pattern, &corners, found);
        }

        out
    }

    // ── Persistence ──────────────────────────────────────────────────

    fn save_calibration(&self, result: &CalibrationResult) {
        let cal_file = self.inner.cfg.get_str(
            &["calibration", "calibration_file"],
            "/etc/xnav/calibration.json",
        );

        if let Some(parent) = Path::new(&cal_file).parent() {
            let _ = fs::create_dir_all(parent);
        }

        match serde_json::to_string_pretty(result) {
            Ok(json) => {
                if let Err(e) = fs::write(&cal_file, &json) {
                    tracing::error!("Failed to save calibration: {e}");
                } else {
                    tracing::info!("Calibration saved to {cal_file}");
                }
            }
            Err(e) => {
                tracing::error!("Failed to serialize calibration: {e}");
            }
        }

        // Also update config.
        if let Ok(v) = serde_json::to_value(&result.camera_matrix) {
            self.inner.cfg.set(&["calibration", "camera_matrix"], v);
        }
        if let Ok(v) = serde_json::to_value(&result.dist_coeffs) {
            self.inner.cfg.set(&["calibration", "dist_coeffs"], v);
        }
    }

    pub fn load_saved_calibration(&self) -> Option<CalibrationResult> {
        let cal_file = self.inner.cfg.get_str(
            &["calibration", "calibration_file"],
            "/etc/xnav/calibration.json",
        );

        let data = fs::read_to_string(&cal_file).ok()?;
        match serde_json::from_str::<CalibrationResult>(&data) {
            Ok(result) => {
                let mut st = self.inner.state.lock();
                st.result = Some(result.clone());
                Some(result)
            }
            Err(e) => {
                tracing::error!("Failed to load calibration: {e}");
                None
            }
        }
    }

    // ── Internal helpers ─────────────────────────────────────────────

    fn board_size(&self) -> (i32, i32) {
        let cols = self.inner.cfg.get_i64(&["calibration", "checkerboard_cols"], 9) as i32;
        let rows = self.inner.cfg.get_i64(&["calibration", "checkerboard_rows"], 6) as i32;
        (cols, rows)
    }
}
