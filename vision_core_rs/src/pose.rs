//! XNav Pose Calculator
//!
//! Rust port of `vision_core/src/pose_calculator.py`.
//! Computes robot-to-target, field-centric, and offset-point calculations
//! using pure Rust math (no numpy, no external linear algebra crate).

use crate::config::ConfigManager;
use crate::detector::TagDetection;
use crate::fmap::{FieldMap, TagPose};
use serde::Serialize;

// ── Structs ──────────────────────────────────────────────────────────

/// Robot pose in field-centric frame.
#[derive(Clone, Debug, Default, Serialize)]
pub struct RobotPose {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub roll: f64,
    pub pitch: f64,
    pub yaw: f64,
    pub valid: bool,
    pub source_tag_ids: Vec<i32>,
}

/// Distance and angles to an offset point relative to a tag.
#[derive(Clone, Debug, Default, Serialize)]
pub struct OffsetResult {
    pub tag_id: i32,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub distance_x: f64,
    pub distance_y: f64,
    pub distance_z: f64,
    pub direct_distance: f64,
    pub tx: f64,
    pub ty: f64,
    pub valid: bool,
}

// ── 3×3 matrix helpers (row-major [f64; 9]) ──────────────────────────

/// Rotation matrix around Y axis.
pub fn rot_y(angle_deg: f64) -> [f64; 9] {
    let a = angle_deg.to_radians();
    let (s, c) = (a.sin(), a.cos());
    [
        c,   0.0, s,
        0.0, 1.0, 0.0,
       -s,   0.0, c,
    ]
}

/// Rotation matrix around X axis.
pub fn rot_x(angle_deg: f64) -> [f64; 9] {
    let a = angle_deg.to_radians();
    let (s, c) = (a.sin(), a.cos());
    [
        1.0, 0.0, 0.0,
        0.0, c,  -s,
        0.0, s,   c,
    ]
}

/// Rotation matrix around Z axis.
pub fn rot_z(angle_deg: f64) -> [f64; 9] {
    let a = angle_deg.to_radians();
    let (s, c) = (a.sin(), a.cos());
    [
        c,  -s,   0.0,
        s,   c,   0.0,
        0.0, 0.0, 1.0,
    ]
}

/// 3×3 matrix multiply (row-major).
pub fn mat3_mul(a: &[f64; 9], b: &[f64; 9]) -> [f64; 9] {
    let mut r = [0.0f64; 9];
    for i in 0..3 {
        for j in 0..3 {
            r[i * 3 + j] =
                a[i * 3]     * b[j]     +
                a[i * 3 + 1] * b[3 + j] +
                a[i * 3 + 2] * b[6 + j];
        }
    }
    r
}

/// 3×3 matrix × 3-vector.
pub fn mat3_vec3_mul(m: &[f64; 9], v: &[f64; 3]) -> [f64; 3] {
    [
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    ]
}

// ── 4×4 matrix helpers ───────────────────────────────────────────────

fn mat4_identity() -> [[f64; 4]; 4] {
    [
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ]
}

/// 4×4 matrix multiply.
pub fn mat4_mul(a: &[[f64; 4]; 4], b: &[[f64; 4]; 4]) -> [[f64; 4]; 4] {
    let mut r = [[0.0f64; 4]; 4];
    for i in 0..4 {
        for j in 0..4 {
            for k in 0..4 {
                r[i][j] += a[i][k] * b[k][j];
            }
        }
    }
    r
}

/// 4×4 matrix inverse (general, Gauss-Jordan elimination).
pub fn mat4_inv(m: &[[f64; 4]; 4]) -> [[f64; 4]; 4] {
    let mut aug = [[0.0f64; 8]; 4];
    for i in 0..4 {
        for j in 0..4 {
            aug[i][j] = m[i][j];
            aug[i][j + 4] = if i == j { 1.0 } else { 0.0 };
        }
    }

    for col in 0..4 {
        // Partial pivoting
        let mut max_row = col;
        let mut max_val = aug[col][col].abs();
        for row in (col + 1)..4 {
            let v = aug[row][col].abs();
            if v > max_val {
                max_val = v;
                max_row = row;
            }
        }
        aug.swap(col, max_row);

        let pivot = aug[col][col];
        if pivot.abs() < 1e-15 {
            // Singular matrix – return identity as fallback
            tracing::warn!("mat4_inv: singular matrix encountered, returning identity");
            return mat4_identity();
        }
        let inv_pivot = 1.0 / pivot;
        for j in 0..8 {
            aug[col][j] *= inv_pivot;
        }
        for row in 0..4 {
            if row == col {
                continue;
            }
            let factor = aug[row][col];
            for j in 0..8 {
                aug[row][j] -= factor * aug[col][j];
            }
        }
    }

    let mut inv = [[0.0f64; 4]; 4];
    for i in 0..4 {
        for j in 0..4 {
            inv[i][j] = aug[i][j + 4];
        }
    }
    inv
}

// ── Quaternion / rotation conversions ────────────────────────────────

/// Quaternion to 3×3 rotation matrix (row-major).
pub fn quat_to_rot(qw: f64, qx: f64, qy: f64, qz: f64) -> [f64; 9] {
    [
        1.0 - 2.0 * (qy * qy + qz * qz),
        2.0 * (qx * qy - qz * qw),
        2.0 * (qx * qz + qy * qw),

        2.0 * (qx * qy + qz * qw),
        1.0 - 2.0 * (qx * qx + qz * qz),
        2.0 * (qy * qz - qx * qw),

        2.0 * (qx * qz - qy * qw),
        2.0 * (qy * qz + qx * qw),
        1.0 - 2.0 * (qx * qx + qy * qy),
    ]
}

/// 3×3 rotation matrix to (roll, pitch, yaw) in degrees.
pub fn rot_to_euler(r: &[f64; 9]) -> (f64, f64, f64) {
    // r[6] = R[2,0]; clamp to [-1, 1] to guard against numerical precision
    // issues in rotation matrices that might slightly exceed the valid domain.
    let pitch = ((-r[6]).clamp(-1.0, 1.0)).asin().to_degrees();
    if r[6].abs() < 0.9999 {
        let roll = r[7].atan2(r[8]).to_degrees();  // R[2,1], R[2,2]
        let yaw  = r[3].atan2(r[0]).to_degrees();  // R[1,0], R[0,0]
        (roll, pitch, yaw)
    } else {
        let roll = 0.0;
        let yaw = (-r[1]).atan2(r[4]).to_degrees(); // -R[0,1], R[1,1]
        (roll, pitch, yaw)
    }
}

/// 3×3 rotation matrix to quaternion [w, x, y, z].
pub fn rot_to_quat(r: &[f64; 9]) -> [f64; 4] {
    let trace = r[0] + r[4] + r[8]; // R[0,0]+R[1,1]+R[2,2]
    if trace > 0.0 {
        let s = 0.5 / (trace + 1.0).sqrt();
        let w = 0.25 / s;
        let x = (r[7] - r[5]) * s; // R[2,1]-R[1,2]
        let y = (r[2] - r[6]) * s; // R[0,2]-R[2,0]
        let z = (r[3] - r[1]) * s; // R[1,0]-R[0,1]
        [w, x, y, z]
    } else if r[0] > r[4] && r[0] > r[8] {
        let s = 2.0 * (1.0 + r[0] - r[4] - r[8]).sqrt();
        let w = (r[7] - r[5]) / s;
        let x = 0.25 * s;
        let y = (r[1] + r[3]) / s; // R[0,1]+R[1,0]
        let z = (r[2] + r[6]) / s; // R[0,2]+R[2,0]
        [w, x, y, z]
    } else if r[4] > r[8] {
        let s = 2.0 * (1.0 + r[4] - r[0] - r[8]).sqrt();
        let w = (r[2] - r[6]) / s; // R[0,2]-R[2,0]
        let x = (r[1] + r[3]) / s;
        let y = 0.25 * s;
        let z = (r[5] + r[7]) / s; // R[1,2]+R[2,1]
        [w, x, y, z]
    } else {
        let s = 2.0 * (1.0 + r[8] - r[0] - r[4]).sqrt();
        let w = (r[3] - r[1]) / s; // R[1,0]-R[0,1]
        let x = (r[2] + r[6]) / s;
        let y = (r[5] + r[7]) / s;
        let z = 0.25 * s;
        [w, x, y, z]
    }
}

// ── Rodrigues formula ────────────────────────────────────────────────

/// Rodrigues formula: rotation vector (3,) → 3×3 rotation matrix.
pub fn rodrigues(rvec: &[f64]) -> [f64; 9] {
    let theta = (rvec[0] * rvec[0] + rvec[1] * rvec[1] + rvec[2] * rvec[2]).sqrt();
    if theta < 1e-12 {
        // Near-zero rotation → identity
        return [
            1.0, 0.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 1.0,
        ];
    }
    let inv_theta = 1.0 / theta;
    let kx = rvec[0] * inv_theta;
    let ky = rvec[1] * inv_theta;
    let kz = rvec[2] * inv_theta;

    let c = theta.cos();
    let s = theta.sin();
    let one_c = 1.0 - c;

    [
        c + kx * kx * one_c,       kx * ky * one_c - kz * s,  kx * kz * one_c + ky * s,
        ky * kx * one_c + kz * s,  c + ky * ky * one_c,       ky * kz * one_c - kx * s,
        kz * kx * one_c - ky * s,  kz * ky * one_c + kx * s,  c + kz * kz * one_c,
    ]
}

/// Inverse Rodrigues: 3×3 rotation matrix → rotation vector (3,).
fn rot_to_rvec(r: &[f64; 9]) -> [f64; 3] {
    let trace = r[0] + r[4] + r[8];
    let cos_angle = ((trace - 1.0) / 2.0).clamp(-1.0, 1.0);
    let theta = cos_angle.acos();

    if theta.abs() < 1e-12 {
        return [0.0, 0.0, 0.0];
    }

    let inv_2sin = 1.0 / (2.0 * theta.sin());
    let kx = (r[7] - r[5]) * inv_2sin; // R[2,1]-R[1,2]
    let ky = (r[2] - r[6]) * inv_2sin; // R[0,2]-R[2,0]
    let kz = (r[3] - r[1]) * inv_2sin; // R[1,0]-R[0,1]
    [kx * theta, ky * theta, kz * theta]
}

// ── Camera-to-robot transform ────────────────────────────────────────

/// Build 4×4 camera-to-robot transform from mount config.
pub fn build_camera_to_robot(mount_cfg: &serde_json::Value) -> [[f64; 4]; 4] {
    let rx = mount_cfg.get("roll").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let ry = mount_cfg.get("pitch").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let rz = mount_cfg.get("yaw").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let tx = mount_cfg.get("x_offset").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let ty = mount_cfg.get("y_offset").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let tz = mount_cfg.get("z_offset").and_then(|v| v.as_f64()).unwrap_or(0.0);

    // R = Rz(rz) @ Ry(ry) @ Rx(rx)
    let r = mat3_mul(&mat3_mul(&rot_z(rz), &rot_y(ry)), &rot_x(rx));

    let mut t = mat4_identity();
    // Copy 3×3 rotation into top-left of 4×4
    for i in 0..3 {
        for j in 0..3 {
            t[i][j] = r[i * 3 + j];
        }
    }
    t[0][3] = tx;
    t[1][3] = ty;
    t[2][3] = tz;
    t
}

// ── Helper: rvec → euler (simple) ────────────────────────────────────

fn rvec_to_euler_simple(rvec: &[f64]) -> (f64, f64, f64) {
    let r = rodrigues(rvec);
    let roll  = r[7].atan2(r[8]).to_degrees();      // R[2,1], R[2,2]
    let pitch = (-r[6]).atan2((r[7] * r[7] + r[8] * r[8]).sqrt()).to_degrees();
    let yaw   = r[3].atan2(r[0]).to_degrees();       // R[1,0], R[0,0]
    (roll, pitch, yaw)
}

// ── Helper: build 4×4 from 3×3 rotation + translation ────────────────

fn build_4x4(rot: &[f64; 9], tvec: &[f64]) -> [[f64; 4]; 4] {
    let mut m = mat4_identity();
    for i in 0..3 {
        for j in 0..3 {
            m[i][j] = rot[i * 3 + j];
        }
        m[i][3] = tvec[i];
    }
    m
}

/// Extract 3×3 rotation (row-major) from 4×4 matrix.
fn extract_rot(m: &[[f64; 4]; 4]) -> [f64; 9] {
    [
        m[0][0], m[0][1], m[0][2],
        m[1][0], m[1][1], m[1][2],
        m[2][0], m[2][1], m[2][2],
    ]
}

fn vec3_norm(v: &[f64; 3]) -> f64 {
    (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
}

fn dot4(a: &[f64; 4], b: &[f64; 4]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
}

// ── PoseCalculator ───────────────────────────────────────────────────

/// Handles all pose calculations.
pub struct PoseCalculator {
    cfg: ConfigManager,
    field_map: Option<FieldMap>,
}

impl PoseCalculator {
    pub fn new(cfg: ConfigManager) -> Self {
        Self {
            cfg,
            field_map: None,
        }
    }

    pub fn set_field_map(&mut self, field_map: Option<FieldMap>) {
        self.field_map = field_map;
    }

    // ── Turret compensation ──────────────────────────────────────────

    /// Rotate tag positions by turret angle (around Y axis).
    pub fn apply_turret(
        &self,
        detections: &[TagDetection],
        turret_angle_deg: f64,
    ) -> Vec<TagDetection> {
        if turret_angle_deg.abs() < 1e-6 {
            return detections.to_vec();
        }

        let r = rot_y(turret_angle_deg);
        let mut result = Vec::with_capacity(detections.len());

        for tag in detections {
            if tag.tvec.is_none() {
                result.push(tag.clone());
                continue;
            }

            let mut t = tag.clone();
            let tvec = tag.tvec.as_ref().unwrap();
            let v = [tvec[0], tvec[1], tvec[2]];
            let tvec_rot = mat3_vec3_mul(&r, &v);

            t.x = tvec_rot[0];
            t.y = tvec_rot[1];
            t.z = tvec_rot[2];
            t.distance = vec3_norm(&tvec_rot);
            t.tx = tvec_rot[0].atan2(tvec_rot[2]).to_degrees();
            t.ty = -tvec_rot[1].atan2(tvec_rot[2]).to_degrees();

            // Rotate rvec
            if let Some(ref rv) = tag.rvec {
                let r_tag = rodrigues(rv);
                let r_new = mat3_mul(&r, &r_tag);
                let rvec_new = rot_to_rvec(&r_new);
                let (roll, pitch, yaw) = rvec_to_euler_simple(&rvec_new);
                t.roll = roll;
                t.pitch = pitch;
                t.yaw = yaw;
                t.rvec = Some(vec![rvec_new[0], rvec_new[1], rvec_new[2]]);
            }

            t.tvec = Some(vec![tvec_rot[0], tvec_rot[1], tvec_rot[2]]);
            result.push(t);
        }

        result
    }

    // ── Robot pose (field-centric) ───────────────────────────────────

    /// Estimate robot field pose using detected tags and the field map.
    pub fn compute_robot_pose(&self, detections: &[TagDetection]) -> Option<RobotPose> {
        let fmap = self.field_map.as_ref()?;
        if fmap.tags.is_empty() {
            return None;
        }

        let mount = self
            .cfg
            .get(&["camera_mount"])
            .unwrap_or(serde_json::Value::Object(serde_json::Map::new()));
        let t_cam_to_robot = build_camera_to_robot(&mount);

        let mut poses: Vec<[[f64; 4]; 4]> = Vec::new();
        let mut tag_ids: Vec<i32> = Vec::new();

        for tag in detections {
            let tvec = match tag.tvec.as_ref() {
                Some(v) => v,
                None => continue,
            };
            let rvec = match tag.rvec.as_ref() {
                Some(v) => v,
                None => continue,
            };
            let field_tag: &TagPose = match fmap.tags.get(&tag.id) {
                Some(ft) => ft,
                None => continue,
            };

            // Camera pose in tag frame
            let r_cam_tag = rodrigues(rvec);
            let t_cam_in_tag = build_4x4(&r_cam_tag, tvec);

            // Tag pose in field frame
            let r_tag_field = quat_to_rot(field_tag.qw, field_tag.qx, field_tag.qy, field_tag.qz);
            let t_tag_in_field = build_4x4(&r_tag_field, &[field_tag.x, field_tag.y, field_tag.z]);

            // Camera in field = tag_in_field * inv(cam_in_tag)
            let t_cam_in_field = mat4_mul(&t_tag_in_field, &mat4_inv(&t_cam_in_tag));

            // Robot in field = camera_in_field * inv(cam_to_robot)
            let t_robot_in_field = mat4_mul(&t_cam_in_field, &mat4_inv(&t_cam_to_robot));

            poses.push(t_robot_in_field);
            tag_ids.push(tag.id);
        }

        if poses.is_empty() {
            return None;
        }

        // Average translation
        let n = poses.len() as f64;
        let mut t_avg = [0.0f64; 3];
        for p in &poses {
            t_avg[0] += p[0][3];
            t_avg[1] += p[1][3];
            t_avg[2] += p[2][3];
        }
        t_avg[0] /= n;
        t_avg[1] /= n;
        t_avg[2] /= n;

        // Average quaternions (normalized sum method)
        let mut quats: Vec<[f64; 4]> = poses
            .iter()
            .map(|p| rot_to_quat(&extract_rot(p)))
            .collect();

        // Ensure all quaternions are in the same hemisphere
        for i in 1..quats.len() {
            if dot4(&quats[0], &quats[i]) < 0.0 {
                quats[i] = [-quats[i][0], -quats[i][1], -quats[i][2], -quats[i][3]];
            }
        }

        let mut q_avg = [0.0f64; 4];
        for q in &quats {
            q_avg[0] += q[0];
            q_avg[1] += q[1];
            q_avg[2] += q[2];
            q_avg[3] += q[3];
        }
        q_avg[0] /= n;
        q_avg[1] /= n;
        q_avg[2] /= n;
        q_avg[3] /= n;

        let norm = (q_avg[0] * q_avg[0]
            + q_avg[1] * q_avg[1]
            + q_avg[2] * q_avg[2]
            + q_avg[3] * q_avg[3])
            .sqrt();
        if norm < 1e-9 {
            q_avg = [1.0, 0.0, 0.0, 0.0];
        } else {
            let inv = 1.0 / norm;
            q_avg[0] *= inv;
            q_avg[1] *= inv;
            q_avg[2] *= inv;
            q_avg[3] *= inv;
        }

        let r_avg = quat_to_rot(q_avg[0], q_avg[1], q_avg[2], q_avg[3]);
        let (roll, pitch, yaw) = rot_to_euler(&r_avg);

        Some(RobotPose {
            x: t_avg[0],
            y: t_avg[1],
            z: t_avg[2],
            roll,
            pitch,
            yaw,
            valid: true,
            source_tag_ids: tag_ids,
        })
    }

    // ── Offset point calculation ─────────────────────────────────────

    /// Compute distance and angles to an offset point relative to a tag.
    pub fn compute_offset_point(
        &self,
        detections: &[TagDetection],
        cfg_offset: &serde_json::Value,
    ) -> Option<OffsetResult> {
        if !cfg_offset
            .get("enabled")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            return None;
        }

        let tag_id = cfg_offset
            .get("tag_id")
            .and_then(|v| v.as_i64())
            .unwrap_or(0) as i32;
        let ox = cfg_offset
            .get("x")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        let oy = cfg_offset
            .get("y")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        let oz = cfg_offset
            .get("z")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);

        // Find the target tag
        let target_tag = detections.iter().find(|t| {
            t.id == tag_id && t.tvec.is_some() && t.rvec.is_some()
        })?;

        let tvec = target_tag.tvec.as_ref().unwrap();
        let rvec = target_tag.rvec.as_ref().unwrap();

        // Transform offset from tag frame to camera frame
        let r_cam_tag = rodrigues(rvec);
        let offset_tag = [ox, oy, oz];
        let rotated = mat3_vec3_mul(&r_cam_tag, &offset_tag);

        // Offset point in camera frame = tag_translation + R * offset
        let dx = tvec[0] + rotated[0];
        let dy = tvec[1] + rotated[1];
        let dz = tvec[2] + rotated[2];
        let direct = (dx * dx + dy * dy + dz * dz).sqrt();
        let tx = dx.atan2(dz).to_degrees();
        let ty = -dy.atan2(dz).to_degrees();

        Some(OffsetResult {
            tag_id,
            x: dx,
            y: dy,
            z: dz,
            distance_x: dx.abs(),
            distance_y: dy.abs(),
            distance_z: dz.abs(),
            direct_distance: direct,
            tx,
            ty,
            valid: true,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rot_y_identity() {
        let r = rot_y(0.0);
        assert!((r[0] - 1.0).abs() < 1e-12);
        assert!((r[4] - 1.0).abs() < 1e-12);
        assert!((r[8] - 1.0).abs() < 1e-12);
    }

    #[test]
    fn test_rot_x_identity() {
        let r = rot_x(0.0);
        assert!((r[0] - 1.0).abs() < 1e-12);
        assert!((r[4] - 1.0).abs() < 1e-12);
        assert!((r[8] - 1.0).abs() < 1e-12);
    }

    #[test]
    fn test_rot_z_identity() {
        let r = rot_z(0.0);
        assert!((r[0] - 1.0).abs() < 1e-12);
        assert!((r[4] - 1.0).abs() < 1e-12);
        assert!((r[8] - 1.0).abs() < 1e-12);
    }

    #[test]
    fn test_mat3_mul_identity() {
        let id = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
        let r = rot_y(45.0);
        let res = mat3_mul(&id, &r);
        for i in 0..9 {
            assert!((res[i] - r[i]).abs() < 1e-12);
        }
    }

    #[test]
    fn test_mat4_inv_identity() {
        let id = mat4_identity();
        let inv = mat4_inv(&id);
        for i in 0..4 {
            for j in 0..4 {
                let expected = if i == j { 1.0 } else { 0.0 };
                assert!((inv[i][j] - expected).abs() < 1e-12);
            }
        }
    }

    #[test]
    fn test_mat4_inv_roundtrip() {
        let r = rot_y(30.0);
        let m = build_4x4(&r, &[1.0, 2.0, 3.0]);
        let inv = mat4_inv(&m);
        let product = mat4_mul(&m, &inv);
        for i in 0..4 {
            for j in 0..4 {
                let expected = if i == j { 1.0 } else { 0.0 };
                assert!(
                    (product[i][j] - expected).abs() < 1e-9,
                    "product[{i}][{j}] = {} expected {expected}",
                    product[i][j]
                );
            }
        }
    }

    #[test]
    fn test_quat_to_rot_identity() {
        let r = quat_to_rot(1.0, 0.0, 0.0, 0.0);
        let id = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
        for i in 0..9 {
            assert!((r[i] - id[i]).abs() < 1e-12);
        }
    }

    #[test]
    fn test_rot_to_euler_identity() {
        let id = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
        let (roll, pitch, yaw) = rot_to_euler(&id);
        assert!(roll.abs() < 1e-12);
        assert!(pitch.abs() < 1e-12);
        assert!(yaw.abs() < 1e-12);
    }

    #[test]
    fn test_rot_to_quat_identity() {
        let id = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
        let q = rot_to_quat(&id);
        assert!((q[0] - 1.0).abs() < 1e-9);
        assert!(q[1].abs() < 1e-9);
        assert!(q[2].abs() < 1e-9);
        assert!(q[3].abs() < 1e-9);
    }

    #[test]
    fn test_rodrigues_zero() {
        let r = rodrigues(&[0.0, 0.0, 0.0]);
        let id = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
        for i in 0..9 {
            assert!((r[i] - id[i]).abs() < 1e-12);
        }
    }

    #[test]
    fn test_rodrigues_90_y() {
        let angle = std::f64::consts::FRAC_PI_2;
        let r = rodrigues(&[0.0, angle, 0.0]);
        let expected = rot_y(90.0);
        for i in 0..9 {
            assert!(
                (r[i] - expected[i]).abs() < 1e-9,
                "rodrigues[{i}] = {} expected {}",
                r[i],
                expected[i]
            );
        }
    }

    #[test]
    fn test_rot_euler_roundtrip() {
        let r = mat3_mul(&mat3_mul(&rot_z(25.0), &rot_y(35.0)), &rot_x(15.0));
        let (roll, pitch, yaw) = rot_to_euler(&r);
        // Reconstruct
        let r2 = mat3_mul(&mat3_mul(&rot_z(yaw), &rot_y(pitch)), &rot_x(roll));
        for i in 0..9 {
            assert!(
                (r[i] - r2[i]).abs() < 1e-9,
                "mismatch at {i}: {} vs {}",
                r[i],
                r2[i]
            );
        }
    }

    #[test]
    fn test_quat_rot_roundtrip() {
        let r = mat3_mul(&rot_z(45.0), &rot_x(30.0));
        let q = rot_to_quat(&r);
        let r2 = quat_to_rot(q[0], q[1], q[2], q[3]);
        for i in 0..9 {
            assert!(
                (r[i] - r2[i]).abs() < 1e-9,
                "mismatch at {i}: {} vs {}",
                r[i],
                r2[i]
            );
        }
    }
}
