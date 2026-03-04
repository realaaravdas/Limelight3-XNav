//! XNav FMap Loader
//! Parses WPILib .fmap (field map) JSON files containing AprilTag 3D poses.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// A single AprilTag 3D pose from the field map.
#[derive(Clone, Debug)]
pub struct TagPose {
    pub id: i32,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub qw: f64,
    pub qx: f64,
    pub qy: f64,
    pub qz: f64,
    pub roll: f64,
    pub pitch: f64,
    pub yaw: f64,
}

/// Parsed field map containing dimensions and tag poses.
#[derive(Clone, Debug)]
pub struct FieldMap {
    pub length: f64,
    pub width: f64,
    pub tags: HashMap<i32, TagPose>,
}

/// Convert quaternion to (roll, pitch, yaw) in degrees.
fn _quat_to_euler(w: f64, x: f64, y: f64, z: f64) -> (f64, f64, f64) {
    let sinr_cosp = 2.0 * (w * x + y * z);
    let cosr_cosp = 1.0 - 2.0 * (x * x + y * y);
    let roll = sinr_cosp.atan2(cosr_cosp);

    let sinp = 2.0 * (w * y - z * x);
    let pitch = if sinp.abs() >= 1.0 {
        std::f64::consts::FRAC_PI_2.copysign(sinp)
    } else {
        sinp.asin()
    };

    let siny_cosp = 2.0 * (w * z + x * y);
    let cosy_cosp = 1.0 - 2.0 * (y * y + z * z);
    let yaw = siny_cosp.atan2(cosy_cosp);

    (roll.to_degrees(), pitch.to_degrees(), yaw.to_degrees())
}

/// Load a WPILib .fmap file and return a [`FieldMap`].
pub fn load_fmap(path: &str) -> Option<FieldMap> {
    if !Path::new(path).exists() {
        tracing::warn!("FMap file not found: {}", path);
        return None;
    }

    let contents = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("Failed to read fmap {}: {}", path, e);
            return None;
        }
    };

    let data: serde_json::Value = match serde_json::from_str(&contents) {
        Ok(v) => v,
        Err(e) => {
            tracing::error!("Failed to parse fmap {}: {}", path, e);
            return None;
        }
    };

    let field_info = data.get("field").and_then(|f| f.as_object());
    let length = field_info
        .and_then(|f| f.get("length"))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let width = field_info
        .and_then(|f| f.get("width"))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);

    let tags_data = data
        .get("tags")
        .and_then(|v| v.as_array())
        .or_else(|| data.get("fiducials").and_then(|v| v.as_array()));

    let mut tags = HashMap::new();

    if let Some(arr) = tags_data {
        for tag_data in arr {
            let tag_id = tag_data
                .get("ID")
                .or_else(|| tag_data.get("id"))
                .or_else(|| tag_data.get("fiducialId"));

            let tag_id = match tag_id.and_then(|v| {
                v.as_i64().or_else(|| v.as_str().and_then(|s| s.parse::<i64>().ok()))
            }) {
                Some(id) => id as i32,
                None => continue,
            };

            let pose = tag_data.get("pose").unwrap_or(tag_data);
            let translation = pose.get("translation").unwrap_or(pose);
            let tx = translation.get("x").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let ty = translation.get("y").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let tz = translation.get("z").and_then(|v| v.as_f64()).unwrap_or(0.0);

            let quat = pose
                .get("rotation")
                .and_then(|r| r.get("quaternion"));

            let qw = quat.and_then(|q| q.get("W")).and_then(|v| v.as_f64()).unwrap_or(1.0);
            let qx = quat.and_then(|q| q.get("X")).and_then(|v| v.as_f64()).unwrap_or(0.0);
            let qy = quat.and_then(|q| q.get("Y")).and_then(|v| v.as_f64()).unwrap_or(0.0);
            let qz = quat.and_then(|q| q.get("Z")).and_then(|v| v.as_f64()).unwrap_or(0.0);

            let (roll, pitch, yaw) = _quat_to_euler(qw, qx, qy, qz);

            tags.insert(tag_id, TagPose {
                id: tag_id,
                x: tx,
                y: ty,
                z: tz,
                qw,
                qx,
                qy,
                qz,
                roll,
                pitch,
                yaw,
            });
        }
    }

    tracing::info!(
        "Loaded fmap with {} tags (field {}x{}m)",
        tags.len(),
        length,
        width
    );

    Some(FieldMap {
        length,
        width,
        tags,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_quat_to_euler_identity() {
        let (r, p, y) = _quat_to_euler(1.0, 0.0, 0.0, 0.0);
        assert!((r).abs() < 1e-9);
        assert!((p).abs() < 1e-9);
        assert!((y).abs() < 1e-9);
    }

    #[test]
    fn test_quat_to_euler_90_yaw() {
        // Quaternion for 90° rotation around Z-axis: w=cos(45°), z=sin(45°)
        let half = std::f64::consts::FRAC_PI_4;
        let (r, p, y) = _quat_to_euler(half.cos(), 0.0, 0.0, half.sin());
        assert!((r).abs() < 1e-9);
        assert!((p).abs() < 1e-9);
        assert!((y - 90.0).abs() < 1e-6);
    }

    #[test]
    fn test_load_fmap_missing_file() {
        assert!(load_fmap("/nonexistent/path.fmap").is_none());
    }
}
