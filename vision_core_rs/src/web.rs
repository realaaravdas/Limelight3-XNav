//! XNav Web Dashboard – Axum-based replacement for the Python Flask/SocketIO dashboard.
//!
//! Serves on port 5800 and provides:
//! - Static file serving (embedded via rust-embed)
//! - REST API endpoints under `/api`
//! - WebSocket endpoint for real-time state updates (`/ws`)
//! - MJPEG camera streams (`/stream.mjpg`, `/calib-stream.mjpg`)

use std::sync::Arc;

use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Multipart, Path, State,
    },
    http::{header, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use rust_embed::RustEmbed;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::{broadcast, Mutex};
use tokio_stream::StreamExt;
use tracing::{error, info, warn};

use crate::calibration::CalibrationManager;
use crate::camera::CameraManager;
use crate::config::ConfigManager;
use crate::detector::AprilTagDetector;
use crate::lights::LightsManager;
use crate::nt_client::NTPublisher;
use crate::pose::{OffsetResult, PoseCalculator, RobotPose};
use crate::thermal::ThermalManager;

// ---------------------------------------------------------------------------
// Embedded assets
// ---------------------------------------------------------------------------

#[derive(RustEmbed)]
#[folder = "../web_dashboard/static/"]
struct StaticAssets;

#[derive(RustEmbed)]
#[folder = "../web_dashboard/templates/"]
struct TemplateAssets;

// ---------------------------------------------------------------------------
// Shared application state
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct AppState {
    pub cfg: ConfigManager,
    pub camera: CameraManager,
    pub detector: Arc<Mutex<AprilTagDetector>>,
    pub pose_calc: Arc<Mutex<PoseCalculator>>,
    pub calibration: CalibrationManager,
    pub lights: LightsManager,
    pub thermal: ThermalManager,
    pub nt: NTPublisher,
    pub shared: Arc<Mutex<SharedVisionState>>,
    pub ws_tx: broadcast::Sender<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct SharedVisionState {
    pub detections: Vec<crate::detector::TagDetection>,
    pub robot_pose: Option<RobotPose>,
    pub offset_result: Option<OffsetResult>,
    pub fps: f64,
    pub latency_ms: f64,
    pub status: String,
    pub temperature_c: f64,
    pub thermal_state: String,
    pub throttle_fps: f64,
}

// ---------------------------------------------------------------------------
// Router construction & server entry-point
// ---------------------------------------------------------------------------

/// Build the full [`axum::Router`] and start the HTTP server on port 5800.
pub async fn run_dashboard(state: AppState) {
    let port: u16 = state
        .cfg
        .get(&["web_port"])
        .and_then(|v| v.as_u64())
        .unwrap_or(5800) as u16;

    let app = build_router(state);

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    info!("XNav Dashboard starting on http://0.0.0.0:{port}");

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("failed to bind dashboard port");

    axum::serve(listener, app)
        .await
        .expect("dashboard server error");
}

fn build_router(state: AppState) -> Router {
    Router::new()
        // Index
        .route("/", get(index_handler))
        // Static files
        .route("/static/{*path}", get(static_handler))
        // MJPEG streams
        .route("/stream.mjpg", get(mjpeg_stream))
        .route("/calib-stream.mjpg", get(calib_stream))
        // WebSocket
        .route("/ws", get(ws_handler))
        // REST API
        .route("/api/status", get(api_status))
        .route("/api/config", get(api_config_get).post(api_config_post))
        .route(
            "/api/config/{section}",
            get(api_config_section_get).post(api_config_section_post),
        )
        .route("/api/lights", get(api_lights_get).post(api_lights_post))
        .route("/api/matchmode", post(api_matchmode))
        .route("/api/fmap", get(api_fmap_get).post(api_fmap_upload))
        .route("/api/calibration/start", post(api_cal_start))
        .route("/api/calibration/stop", post(api_cal_stop))
        .route("/api/calibration/compute", post(api_cal_compute))
        .route("/api/calibration/status", get(api_cal_status))
        .route("/api/calibration/result", get(api_cal_result))
        .route("/api/thermal", get(api_thermal))
        .route("/api/throttle", get(api_throttle_get).post(api_throttle_post))
        .route("/api/system/reboot", post(api_reboot))
        .route("/api/system/shutdown", post(api_shutdown))
        .route("/api/system/restart-vision", post(api_restart_vision))
        .with_state(state)
}

// ---------------------------------------------------------------------------
// Index & static file handlers
// ---------------------------------------------------------------------------

async fn index_handler() -> impl IntoResponse {
    match TemplateAssets::get("index.html") {
        Some(asset) => Html(
            std::str::from_utf8(asset.data.as_ref())
                .unwrap_or("")
                .to_string(),
        )
        .into_response(),
        None => (StatusCode::NOT_FOUND, "index.html not found").into_response(),
    }
}

async fn static_handler(Path(path): Path<String>) -> impl IntoResponse {
    match StaticAssets::get(&path) {
        Some(asset) => {
            let mime = mime_guess::from_path(&path).first_or_octet_stream();
            Response::builder()
                .header(header::CONTENT_TYPE, mime.as_ref())
                .body(Body::from(asset.data.into_owned()))
                .unwrap()
                .into_response()
        }
        None => (StatusCode::NOT_FOUND, "not found").into_response(),
    }
}

// ---------------------------------------------------------------------------
// REST API – status
// ---------------------------------------------------------------------------

async fn api_status(State(state): State<AppState>) -> Json<Value> {
    let shared = state.shared.lock().await;
    let targets: Vec<Value> = shared.detections.iter().map(tag_to_json).collect();
    Json(json!({
        "status": shared.status,
        "fps": shared.fps,
        "latency_ms": shared.latency_ms,
        "nt_connected": state.nt.is_connected(),
        "num_targets": targets.len(),
        "targets": targets,
        "robot_pose": robot_pose_to_json(shared.robot_pose.as_ref()),
        "offset_result": offset_to_json(shared.offset_result.as_ref()),
    }))
}

// ---------------------------------------------------------------------------
// REST API – config
// ---------------------------------------------------------------------------

async fn api_config_get(State(state): State<AppState>) -> Json<Value> {
    Json(state.cfg.all())
}

async fn api_config_post(
    State(state): State<AppState>,
    Json(data): Json<Value>,
) -> impl IntoResponse {
    let obj = match data.as_object() {
        Some(o) => o,
        None => return (StatusCode::BAD_REQUEST, Json(json!({"error": "Invalid JSON"}))).into_response(),
    };
    for (section, values) in obj {
        if values.is_object() {
            state.cfg.update_section(section, values.clone());
        } else {
            state.cfg.set(&[section.as_str()], values.clone());
        }
    }
    {
        let mut det = state.detector.lock().await;
        det.reload_config();
    }
    Json(json!({"ok": true})).into_response()
}

async fn api_config_section_get(
    State(state): State<AppState>,
    Path(section): Path<String>,
) -> impl IntoResponse {
    match state.cfg.get(&[&section]) {
        Some(val) => Json(val).into_response(),
        None => (StatusCode::NOT_FOUND, Json(json!({"error": "Not found"}))).into_response(),
    }
}

async fn api_config_section_post(
    State(state): State<AppState>,
    Path(section): Path<String>,
    Json(data): Json<Value>,
) -> Json<Value> {
    state.cfg.update_section(&section, data);
    Json(json!({"ok": true}))
}

// ---------------------------------------------------------------------------
// REST API – lights
// ---------------------------------------------------------------------------

async fn api_lights_get(State(state): State<AppState>) -> Json<Value> {
    let ls = state.lights.get_state();
    Json(serde_json::to_value(ls).unwrap_or(json!({})))
}

async fn api_lights_post(
    State(state): State<AppState>,
    Json(data): Json<Value>,
) -> Json<Value> {
    if let Some(enabled) = data.get("enabled").and_then(|v| v.as_bool()) {
        state.lights.set_enabled(enabled);
    }
    if let Some(brightness) = data.get("brightness").and_then(|v| v.as_u64()) {
        state.lights.set_brightness(brightness as u8);
    }
    if let Some(mode) = data.get("mode").and_then(|v| v.as_str()) {
        state.lights.set_mode(mode);
    }
    state.cfg.update_section("lights", data);
    Json(json!({"ok": true}))
}

// ---------------------------------------------------------------------------
// REST API – match mode
// ---------------------------------------------------------------------------

async fn api_matchmode(
    State(state): State<AppState>,
    Json(data): Json<Value>,
) -> Json<Value> {
    let enabled = data
        .get("enabled")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    state.cfg.set(&["match_mode"], Value::Bool(enabled));
    Json(json!({"ok": true, "match_mode": enabled}))
}

// ---------------------------------------------------------------------------
// REST API – field map
// ---------------------------------------------------------------------------

async fn api_fmap_upload(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> impl IntoResponse {
    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();
        if name != "file" {
            continue;
        }
        let filename = field.file_name().unwrap_or("").to_string();
        if !filename.ends_with(".fmap") {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"error": "File must be a .fmap file"})),
            )
                .into_response();
        }

        let data = match field.bytes().await {
            Ok(d) => d,
            Err(e) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"error": e.to_string()})),
                )
                    .into_response();
            }
        };

        let save_path = "/etc/xnav/field.fmap";
        if let Err(e) = tokio::fs::create_dir_all("/etc/xnav").await {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": e.to_string()})),
            )
                .into_response();
        }
        if let Err(e) = tokio::fs::write(save_path, &data).await {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": e.to_string()})),
            )
                .into_response();
        }

        state
            .cfg
            .set(&["field_map", "fmap_file"], Value::String(save_path.into()));
        state
            .cfg
            .set(&["field_map", "enabled"], Value::Bool(true));

        return Json(json!({"ok": true, "path": save_path})).into_response();
    }

    (
        StatusCode::BAD_REQUEST,
        Json(json!({"error": "No file part"})),
    )
        .into_response()
}

async fn api_fmap_get(State(state): State<AppState>) -> Json<Value> {
    let fmap_cfg = state.cfg.get(&["field_map"]).unwrap_or(json!({}));
    let fmap_file = fmap_cfg
        .get("fmap_file")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let enabled = fmap_cfg
        .get("enabled")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    if !fmap_file.is_empty() {
        if let Ok(contents) = tokio::fs::read_to_string(&fmap_file).await {
            if let Ok(data) = serde_json::from_str::<Value>(&contents) {
                return Json(json!({
                    "loaded": true,
                    "enabled": enabled,
                    "file": fmap_file,
                    "data": data,
                }));
            }
        }
    }
    Json(json!({
        "loaded": false,
        "enabled": enabled,
        "file": fmap_file,
    }))
}

// ---------------------------------------------------------------------------
// REST API – calibration
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct CalStartRequest {
    #[serde(default = "default_target_frames")]
    target_frames: usize,
}

fn default_target_frames() -> usize {
    20
}

async fn api_cal_start(
    State(state): State<AppState>,
    Json(data): Json<CalStartRequest>,
) -> Json<Value> {
    state.calibration.start_collection(data.target_frames);
    Json(json!({"ok": true}))
}

async fn api_cal_stop(State(state): State<AppState>) -> Json<Value> {
    state.calibration.stop_collection();
    Json(json!({"ok": true}))
}

async fn api_cal_compute(State(state): State<AppState>) -> Json<Value> {
    let cal = state.calibration.clone();
    let detector = state.detector.clone();
    let ws_tx = state.ws_tx.clone();

    tokio::task::spawn_blocking(move || {
        let (ok, msg) = cal.compute_calibration();
        if ok {
            if let Some(result) = cal.get_result() {
                // Try to apply calibration to the detector (best-effort).
                if let Ok(mut det) = detector.try_lock() {
                    // Convert nested vecs to opencv Mats if the detector API requires them.
                    // The detector's set_calibration expects opencv Mats; we store the
                    // result and let the detector reload from config on next cycle.
                    let _ = &result;
                    det.reload_config();
                }
            }
        }

        let payload = json!({
            "type": "calibration_result",
            "data": {"ok": ok, "message": msg}
        });
        let _ = ws_tx.send(payload.to_string());
    });

    Json(json!({"ok": true, "message": "Computing calibration..."}))
}

async fn api_cal_status(State(state): State<AppState>) -> Json<Value> {
    let status = state.calibration.get_status();
    Json(serde_json::to_value(status).unwrap_or(json!({
        "collecting": false,
        "progress": 0,
        "target": 20,
        "status": "idle",
        "has_result": false,
    })))
}

async fn api_cal_result(State(state): State<AppState>) -> Json<Value> {
    match state.calibration.get_result() {
        Some(result) => Json(json!({
            "rms_error": result.rms_error,
            "image_size": result.image_size,
            "num_frames": result.num_frames,
            "has_calibration": true,
        })),
        None => Json(json!({"has_calibration": false})),
    }
}

// ---------------------------------------------------------------------------
// REST API – thermal & throttle
// ---------------------------------------------------------------------------

async fn api_thermal(State(state): State<AppState>) -> Json<Value> {
    let status = state.thermal.get_status();
    Json(json!({
        "temperature_c": status.temperature_c,
        "state": status.state,
    }))
}

async fn api_throttle_get(State(state): State<AppState>) -> Json<Value> {
    let val = state.cfg.get(&["throttle"]).unwrap_or(json!({"fps": 0}));
    Json(val)
}

async fn api_throttle_post(
    State(state): State<AppState>,
    Json(data): Json<Value>,
) -> Json<Value> {
    let fps = data
        .get("fps")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    state.cfg.update_section("throttle", json!({"fps": fps}));
    Json(json!({"ok": true, "fps": fps}))
}

// ---------------------------------------------------------------------------
// REST API – system commands
// ---------------------------------------------------------------------------

async fn api_reboot() -> Json<Value> {
    tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        if let Err(e) = tokio::process::Command::new("/sbin/reboot")
            .status()
            .await
        {
            error!("reboot failed: {e}");
        }
    });
    Json(json!({"ok": true}))
}

async fn api_shutdown() -> Json<Value> {
    tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        if let Err(e) = tokio::process::Command::new("/sbin/shutdown")
            .args(["-h", "now"])
            .status()
            .await
        {
            error!("shutdown failed: {e}");
        }
    });
    Json(json!({"ok": true}))
}

async fn api_restart_vision(State(state): State<AppState>) -> Json<Value> {
    let camera = state.camera.clone();
    tokio::task::spawn_blocking(move || {
        camera.stop();
        std::thread::sleep(std::time::Duration::from_secs(1));
        camera.start();
    });
    Json(json!({"ok": true}))
}

// ---------------------------------------------------------------------------
// MJPEG streams
// ---------------------------------------------------------------------------

async fn mjpeg_stream(State(state): State<AppState>) -> impl IntoResponse {
    let stream = async_stream::stream! {
        loop {
            let frame = state.camera.get_jpeg_frame(60);
            match frame {
                Some(jpeg) => {
                    let mut buf = Vec::with_capacity(jpeg.len() + 64);
                    buf.extend_from_slice(b"--frame\r\nContent-Type: image/jpeg\r\n\r\n");
                    buf.extend_from_slice(&jpeg);
                    buf.extend_from_slice(b"\r\n");
                    yield Ok::<_, std::io::Error>(buf);
                }
                None => {
                    // No frame available; wait a bit before retrying.
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(33)).await;
        }
    };

    Response::builder()
        .header(
            header::CONTENT_TYPE,
            "multipart/x-mixed-replace; boundary=frame",
        )
        .body(Body::from_stream(stream))
        .unwrap()
}

async fn calib_stream(State(state): State<AppState>) -> impl IntoResponse {
    let stream = async_stream::stream! {
        loop {
            let frame_data = {
                let (frame_opt, _gray, _ts) = state.camera.get_frame();
                if let Some(frame) = frame_opt {
                    let overlay = state.calibration.draw_preview(&frame);
                    // Encode overlay to JPEG – reuse the camera's encoding approach.
                    encode_mat_jpeg(&overlay, 60)
                } else {
                    None
                }
            };
            if let Some(jpeg) = frame_data {
                let mut buf = Vec::with_capacity(jpeg.len() + 64);
                buf.extend_from_slice(b"--frame\r\nContent-Type: image/jpeg\r\n\r\n");
                buf.extend_from_slice(&jpeg);
                buf.extend_from_slice(b"\r\n");
                yield Ok::<_, std::io::Error>(buf);
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
    };

    Response::builder()
        .header(
            header::CONTENT_TYPE,
            "multipart/x-mixed-replace; boundary=frame",
        )
        .body(Body::from_stream(stream))
        .unwrap()
}

/// Encode an OpenCV `Mat` to JPEG bytes (best-effort helper).
fn encode_mat_jpeg(mat: &opencv::core::Mat, quality: i32) -> Option<Vec<u8>> {
    use opencv::{core::Vector, imgcodecs};
    let mut buf = Vector::<u8>::new();
    let params = Vector::from_slice(&[imgcodecs::IMWRITE_JPEG_QUALITY, quality]);
    imgcodecs::imencode(".jpg", mat, &mut buf, &params).ok()?;
    Some(buf.to_vec())
}

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> impl IntoResponse {
    ws.on_upgrade(|socket| handle_ws(socket, state))
}

async fn handle_ws(mut socket: WebSocket, state: AppState) {
    // Send initial connected message.
    let hello = json!({"type": "connected", "data": {"message": "Connected to XNav dashboard"}});
    if socket
        .send(Message::Text(hello.to_string().into()))
        .await
        .is_err()
    {
        return;
    }

    let mut rx = state.ws_tx.subscribe();

    // Push state updates at ~10 Hz and forward any broadcast messages.
    let mut interval = tokio::time::interval(std::time::Duration::from_millis(100));
    loop {
        tokio::select! {
            _ = interval.tick() => {
                let payload = {
                    let shared = state.shared.lock().await;
                    let targets: Vec<Value> = shared.detections.iter().map(tag_to_json).collect();
                    json!({
                        "type": "state_update",
                        "data": {
                            "status": shared.status,
                            "fps": (shared.fps * 10.0).round() / 10.0,
                            "latency_ms": (shared.latency_ms * 100.0).round() / 100.0,
                            "nt_connected": state.nt.is_connected(),
                            "num_targets": targets.len(),
                            "targets": targets,
                            "robot_pose": robot_pose_to_json(shared.robot_pose.as_ref()),
                            "offset_result": offset_to_json(shared.offset_result.as_ref()),
                            "temperature_c": shared.temperature_c,
                            "thermal_state": shared.thermal_state,
                            "throttle_fps": shared.throttle_fps,
                        }
                    })
                };
                if socket
                    .send(Message::Text(payload.to_string().into()))
                    .await
                    .is_err()
                {
                    break;
                }
            }
            result = rx.recv() => {
                match result {
                    Ok(msg) => {
                        if socket.send(Message::Text(msg.into())).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!("ws client lagged {n} messages");
                    }
                    Err(_) => break,
                }
            }
            msg = socket.recv() => {
                match msg {
                    Some(Ok(Message::Close(_))) | None => break,
                    _ => {} // ignore other incoming messages
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// JSON serialization helpers (mirrors Python _tag_to_dict etc.)
// ---------------------------------------------------------------------------

fn tag_to_json(tag: &crate::detector::TagDetection) -> Value {
    json!({
        "id": tag.id,
        "tx": round3(tag.tx),
        "ty": round3(tag.ty),
        "x": round4(tag.x),
        "y": round4(tag.y),
        "z": round4(tag.z),
        "distance": round4(tag.distance),
        "yaw": round2(tag.yaw),
        "pitch": round2(tag.pitch),
        "roll": round2(tag.roll),
    })
}

fn robot_pose_to_json(rp: Option<&RobotPose>) -> Value {
    match rp {
        Some(p) if p.valid => json!({
            "x": round4(p.x),
            "y": round4(p.y),
            "z": round4(p.z),
            "roll": round2(p.roll),
            "pitch": round2(p.pitch),
            "yaw": round2(p.yaw),
            "source_tags": p.source_tag_ids,
        }),
        _ => Value::Null,
    }
}

fn offset_to_json(o: Option<&OffsetResult>) -> Value {
    match o {
        Some(o) if o.valid => json!({
            "tag_id": o.tag_id,
            "x": round4(o.x),
            "y": round4(o.y),
            "z": round4(o.z),
            "direct_distance": round4(o.direct_distance),
            "tx": round3(o.tx),
            "ty": round3(o.ty),
        }),
        _ => Value::Null,
    }
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}

fn round4(v: f64) -> f64 {
    (v * 10000.0).round() / 10000.0
}
