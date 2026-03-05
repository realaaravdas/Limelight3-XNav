//! AprilTag detector using OpenCV's ArUco module.
//!
//! Rust port of `vision_core/src/apriltag_detector.py`.
//! Detects AprilTag 36h11 markers and computes 3D pose via solvePnP.
//! Uses the classic `cv::aruco` API (OpenCV 4.x contrib module).

use crate::config::ConfigManager;
use opencv::{
    aruco,
    calib3d,
    core::{self, Mat, Ptr, Point2f, Point3f, Vector},
    prelude::*,
};
use parking_lot::Mutex;
use serde::Serialize;
use std::sync::Arc;

/// 3D detection result for a single AprilTag.
#[derive(Clone, Debug, Serialize)]
pub struct TagDetection {
    pub id: i32,
    /// Camera-frame translation (meters)
    pub x: f64,
    pub y: f64,
    pub z: f64,
    /// Distance (meters)
    pub distance: f64,
    /// Horizontal angle from camera center (degrees)
    pub tx: f64,
    /// Vertical angle from camera center (degrees)
    pub ty: f64,
    /// Orientation (degrees)
    pub yaw: f64,
    pub pitch: f64,
    pub roll: f64,
    /// Pixel center
    pub cx: f64,
    pub cy: f64,
    /// Rotation vector (3,)
    #[serde(skip)]
    pub rvec: Option<Vec<f64>>,
    /// Translation vector (3,)
    #[serde(skip)]
    pub tvec: Option<Vec<f64>>,
    pub hamming: i32,
    pub decision_margin: f64,
    pub timestamp: f64,
}

impl Default for TagDetection {
    fn default() -> Self {
        Self {
            id: 0,
            x: 0.0,
            y: 0.0,
            z: 0.0,
            distance: 0.0,
            tx: 0.0,
            ty: 0.0,
            yaw: 0.0,
            pitch: 0.0,
            roll: 0.0,
            cx: 0.0,
            cy: 0.0,
            rvec: None,
            tvec: None,
            hamming: 0,
            decision_margin: 0.0,
            timestamp: 0.0,
        }
    }
}

/// Convert a rotation vector to (roll, pitch, yaw) in degrees using Rodrigues.
fn rvec_to_euler(rvec: &[f64]) -> (f64, f64, f64) {
    let rvec_mat = match Mat::from_slice(rvec) {
        Ok(m) => m,
        Err(_) => return (0.0, 0.0, 0.0),
    };
    let mut r_mat = Mat::default();
    let mut _jacobian = Mat::default();
    if calib3d::rodrigues(&rvec_mat, &mut r_mat, &mut _jacobian).is_err() {
        return (0.0, 0.0, 0.0);
    }

    // R is a 3x3 rotation matrix
    let r = |row: i32, col: i32| -> f64 {
        *r_mat.at_2d::<f64>(row, col).unwrap_or(&0.0)
    };

    let roll = r(2, 1).atan2(r(2, 2)).to_degrees();
    let pitch = (-r(2, 0))
        .atan2((r(2, 1).powi(2) + r(2, 2).powi(2)).sqrt())
        .to_degrees();
    let yaw = r(1, 0).atan2(r(0, 0)).to_degrees();

    (roll, pitch, yaw)
}

struct DetectorInner {
    cfg: ConfigManager,
    dict: Ptr<aruco::Dictionary>,
    params: Ptr<aruco::DetectorParameters>,
    camera_matrix: Option<Mat>,
    dist_coeffs: Option<Mat>,
    tag_size: f64,
}

/// AprilTag detector backed by OpenCV's ArUco module (tag36h11 dictionary).
///
/// Clone-cheap via internal `Arc`; `Send + Sync` via `parking_lot::Mutex`.
#[derive(Clone)]
pub struct AprilTagDetector {
    inner: Arc<Mutex<DetectorInner>>,
}

// Arc<Mutex<_>> is Send+Sync when inner is Send.
unsafe impl Send for AprilTagDetector {}
unsafe impl Sync for AprilTagDetector {}

impl AprilTagDetector {
    /// Create a new detector, loading calibration from `cfg`.
    pub fn new(cfg: ConfigManager) -> Self {
        let tag_size = cfg.get_f64(&["apriltag", "tag_size"], 0.1524);
        let (dict, params) = Self::create_aruco_dict_and_params();
        let (camera_matrix, dist_coeffs) = Self::load_calibration_from_config(&cfg);

        Self {
            inner: Arc::new(Mutex::new(DetectorInner {
                cfg,
                dict,
                params,
                camera_matrix,
                dist_coeffs,
                tag_size,
            })),
        }
    }

    /// Detect AprilTag markers in a grayscale image and estimate 3D pose.
    pub fn detect(&self, gray: &Mat, timestamp: f64) -> Vec<TagDetection> {
        let inner = self.inner.lock();

        let mut corners: Vector<Vector<Point2f>> = Vector::new();
        let mut ids = Mat::default();
        let mut rejected: Vector<Vector<Point2f>> = Vector::new();

        if let Err(e) = aruco::detect_markers(
            gray,
            &inner.dict,
            &mut corners,
            &mut ids,
            &inner.params,
            &mut rejected,
        ) {
            tracing::warn!("ArUco detect_markers failed: {e}");
            return Vec::new();
        }

        let n = ids.rows();
        if n == 0 {
            return Vec::new();
        }

        // Resolve camera params for angle calculation fallback.
        let (fx, fy, cx_cam, cy_cam) = Self::camera_params(&inner, gray);

        // 3D object points for a square tag centred at the origin.
        let half = (inner.tag_size / 2.0) as f32;
        let obj_pts = Vector::<Point3f>::from_iter([
            Point3f::new(-half, -half, 0.0),
            Point3f::new(half, -half, 0.0),
            Point3f::new(half, half, 0.0),
            Point3f::new(-half, half, 0.0),
        ]);

        let mut results = Vec::with_capacity(n as usize);

        for i in 0..n {
            let tag_id = *ids.at_2d::<i32>(i, 0).unwrap_or(&-1);
            let corner_vec = match corners.get(i as usize) {
                Ok(c) => c,
                Err(_) => continue,
            };

            // Compute pixel centre.
            let mut sum_x: f64 = 0.0;
            let mut sum_y: f64 = 0.0;
            let num = corner_vec.len();
            let mut img_pts = Vector::<Point2f>::with_capacity(num);
            for j in 0..num {
                let p = corner_vec.get(j).unwrap();
                sum_x += p.x as f64;
                sum_y += p.y as f64;
                img_pts.push(p);
            }
            let cx = sum_x / num as f64;
            let cy = sum_y / num as f64;

            let mut tag = TagDetection {
                id: tag_id,
                cx,
                cy,
                timestamp,
                // Pixel-based angle estimate (fallback).
                tx: ((cx - cx_cam) / fx).atan().to_degrees(),
                ty: -((cy - cy_cam) / fy).atan().to_degrees(),
                ..Default::default()
            };

            // Pose estimation via solvePnP when calibration is available.
            if let (Some(cam_mtx), Some(dist)) = (&inner.camera_matrix, &inner.dist_coeffs) {
                let mut rvec = Mat::default();
                let mut tvec = Mat::default();
                let ok = calib3d::solve_pnp(
                    &obj_pts,
                    &img_pts,
                    cam_mtx,
                    dist,
                    &mut rvec,
                    &mut tvec,
                    false,
                    calib3d::SOLVEPNP_IPPE_SQUARE,
                );

                if ok.unwrap_or(false) {
                    let tx_val = *tvec.at_2d::<f64>(0, 0).unwrap_or(&0.0);
                    let ty_val = *tvec.at_2d::<f64>(1, 0).unwrap_or(&0.0);
                    let tz_val = *tvec.at_2d::<f64>(2, 0).unwrap_or(&0.0);

                    tag.x = tx_val;
                    tag.y = ty_val;
                    tag.z = tz_val;
                    tag.distance = (tx_val * tx_val + ty_val * ty_val + tz_val * tz_val).sqrt();

                    // Angles from 3D position
                    tag.tx = (tx_val / tz_val).atan().to_degrees();
                    tag.ty = -(ty_val / tz_val).atan().to_degrees();

                    let rv = vec![
                        *rvec.at_2d::<f64>(0, 0).unwrap_or(&0.0),
                        *rvec.at_2d::<f64>(1, 0).unwrap_or(&0.0),
                        *rvec.at_2d::<f64>(2, 0).unwrap_or(&0.0),
                    ];

                    let (roll, pitch, yaw) = rvec_to_euler(&rv);
                    tag.roll = roll;
                    tag.pitch = pitch;
                    tag.yaw = yaw;

                    tag.rvec = Some(rv);
                    tag.tvec = Some(vec![tx_val, ty_val, tz_val]);
                }
            }

            results.push(tag);
        }

        results
    }

    /// Reload configuration (detector params + calibration).
    pub fn reload_config(&mut self) {
        let mut inner = self.inner.lock();
        inner.tag_size = inner.cfg.get_f64(&["apriltag", "tag_size"], 0.1524);
        let (dict, params) = Self::create_aruco_dict_and_params();
        inner.dict = dict;
        inner.params = params;
        let (cam, dist) = Self::load_calibration_from_config(&inner.cfg);
        inner.camera_matrix = cam;
        inner.dist_coeffs = dist;
        tracing::info!("AprilTag detector config reloaded");
    }

    /// Replace the camera calibration at runtime.
    pub fn set_calibration(&mut self, camera_matrix: Mat, dist_coeffs: Mat) {
        let mut inner = self.inner.lock();
        inner.camera_matrix = Some(camera_matrix);
        inner.dist_coeffs = Some(dist_coeffs);
        tracing::info!("Calibration updated in detector");
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// Build an ArUco dictionary and detector parameters for AprilTag 36h11.
    fn create_aruco_dict_and_params() -> (Ptr<aruco::Dictionary>, Ptr<aruco::DetectorParameters>) {
        let dict = aruco::get_predefined_dictionary(
            aruco::PREDEFINED_DICTIONARY_NAME::DICT_APRILTAG_36h11,
        )
        .expect("Failed to load DICT_APRILTAG_36h11");

        let params = aruco::DetectorParameters::create()
            .expect("Failed to create DetectorParameters");

        (dict, params)
    }

    /// Extract (fx, fy, cx, cy) from calibration or estimate defaults.
    fn camera_params(inner: &DetectorInner, gray: &Mat) -> (f64, f64, f64, f64) {
        if let Some(ref cam) = inner.camera_matrix {
            let fx = *cam.at_2d::<f64>(0, 0).unwrap_or(&1.0);
            let fy = *cam.at_2d::<f64>(1, 1).unwrap_or(&1.0);
            let cx = *cam.at_2d::<f64>(0, 2).unwrap_or(&0.0);
            let cy = *cam.at_2d::<f64>(1, 2).unwrap_or(&0.0);
            (fx, fy, cx, cy)
        } else {
            let size = gray.size().unwrap_or(core::Size::new(640, 480));
            let w = size.width as f64;
            let h = size.height as f64;
            let f = w.max(h) * 1.2;
            (f, f, w / 2.0, h / 2.0)
        }
    }

    /// Load camera_matrix and dist_coeffs from the config manager.
    fn load_calibration_from_config(cfg: &ConfigManager) -> (Option<Mat>, Option<Mat>) {
        // Try inline arrays first.
        let mtx_val = cfg.get(&["calibration", "camera_matrix"]);
        let dist_val = cfg.get(&["calibration", "dist_coeffs"]);

        if let (Some(mtx_json), Some(dist_json)) = (mtx_val, dist_val) {
            if let (Ok(mtx), Ok(dist)) = (
                Self::json_to_mat_2d(&mtx_json),
                Self::json_to_mat_1d(&dist_json),
            ) {
                tracing::info!("Loaded calibration from config");
                return (Some(mtx), Some(dist));
            }
        }

        // Try calibration file path.
        let cal_file = cfg.get_str(&["calibration", "calibration_file"], "");
        if !cal_file.is_empty() {
            if let Ok(contents) = std::fs::read_to_string(&cal_file) {
                if let Ok(doc) = serde_json::from_str::<serde_json::Value>(&contents) {
                    if let (Some(m), Some(d)) = (doc.get("camera_matrix"), doc.get("dist_coeffs"))
                    {
                        if let (Ok(mtx), Ok(dist)) =
                            (Self::json_to_mat_2d(m), Self::json_to_mat_1d(d))
                        {
                            tracing::info!("Loaded calibration from file: {cal_file}");
                            return (Some(mtx), Some(dist));
                        }
                    }
                }
            } else {
                tracing::warn!("Could not read calibration file: {cal_file}");
            }
        }

        tracing::warn!(
            "No calibration found – using default intrinsics. Accuracy will be reduced."
        );
        (None, None)
    }

    /// Parse a JSON 2-D array (e.g. [[fx,0,cx],[0,fy,cy],[0,0,1]]) into a CV_64F Mat.
    fn json_to_mat_2d(val: &serde_json::Value) -> Result<Mat, String> {
        let rows: Vec<Vec<f64>> = serde_json::from_value(val.clone()).map_err(|e| e.to_string())?;
        let nrows = rows.len() as i32;
        if nrows == 0 {
            return Err("empty matrix".into());
        }
        let flat: Vec<f64> = rows.into_iter().flatten().collect();
        let row_mat = Mat::from_slice(&flat).map_err(|e| e.to_string())?;
        row_mat
            .reshape(1, nrows)
            .map(|br| br.clone_pointee())
            .map_err(|e| e.to_string())
    }

    /// Parse a JSON 1-D array into a single-row CV_64F Mat.
    fn json_to_mat_1d(val: &serde_json::Value) -> Result<Mat, String> {
        let flat: Vec<f64> = serde_json::from_value(val.clone()).map_err(|e| e.to_string())?;
        Mat::from_slice(&flat)
            .map(|br| br.clone_pointee())
            .map_err(|e: opencv::Error| e.to_string())
    }
}
