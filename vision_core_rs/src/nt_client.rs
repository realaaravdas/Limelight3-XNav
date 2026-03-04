//! NT4 client – publishes XNav vision data to a roboRIO over NetworkTables 4.
//!
//! Rust port of `vision_core/src/nt_publisher.py`.
//!
//! Protocol overview:
//!   - WebSocket connection to `ws://<server>:5810/nt/XNav`
//!   - Text frames carry JSON arrays of control messages (publish / subscribe / announce)
//!   - Binary frames carry MessagePack-encoded data: `[topic_id, timestamp_us, type_id, value]`
//!
//! NT4 type IDs:
//!   boolean=0, double=1, int=2, float=3, string=4,
//!   boolean[]=16, double[]=17, int[]=18

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use futures_util::{SinkExt, StreamExt};
use parking_lot::Mutex;
use serde_json::json;
use tokio_tungstenite::tungstenite::Message;
use tracing::{debug, info, warn};

use crate::config::ConfigManager;
use crate::detector::TagDetection;
use crate::pose::{OffsetResult, RobotPose};

// ── NT4 type identifiers ────────────────────────────────────────────

const NT_BOOL: u8 = 0;
const NT_DOUBLE: u8 = 1;
const NT_INT: u8 = 2;
const NT_STRING: u8 = 4;
const NT_DOUBLE_ARRAY: u8 = 17;
const NT_INT_ARRAY: u8 = 18;

// ── Value wrapper ───────────────────────────────────────────────────

#[derive(Clone, Debug)]
enum NTValue {
    Boolean(bool),
    Double(f64),
    Int(i64),
    Str(String),
    DoubleArray(Vec<f64>),
    IntArray(Vec<i64>),
}

impl NTValue {
    fn type_id(&self) -> u8 {
        match self {
            NTValue::Boolean(_) => NT_BOOL,
            NTValue::Double(_) => NT_DOUBLE,
            NTValue::Int(_) => NT_INT,
            NTValue::Str(_) => NT_STRING,
            NTValue::DoubleArray(_) => NT_DOUBLE_ARRAY,
            NTValue::IntArray(_) => NT_INT_ARRAY,
        }
    }

    fn type_str(&self) -> &'static str {
        match self {
            NTValue::Boolean(_) => "boolean",
            NTValue::Double(_) => "double",
            NTValue::Int(_) => "int",
            NTValue::Str(_) => "string",
            NTValue::DoubleArray(_) => "double[]",
            NTValue::IntArray(_) => "int[]",
        }
    }

    fn to_msgpack(&self) -> rmpv::Value {
        match self {
            NTValue::Boolean(v) => rmpv::Value::Boolean(*v),
            NTValue::Double(v) => rmpv::Value::F64(*v),
            NTValue::Int(v) => rmpv::Value::Integer((*v).into()),
            NTValue::Str(v) => rmpv::Value::String(v.clone().into()),
            NTValue::DoubleArray(v) => {
                rmpv::Value::Array(v.iter().map(|x| rmpv::Value::F64(*x)).collect())
            }
            NTValue::IntArray(v) => {
                rmpv::Value::Array(v.iter().map(|x| rmpv::Value::Integer((*x).into())).collect())
            }
        }
    }
}

// ── Public types ────────────────────────────────────────────────────

/// Values read back from the roboRIO via NT4 subscriptions.
#[derive(Clone, Debug, Default)]
pub struct NTInputs {
    pub turret_angle: f64,
    pub turret_enabled: bool,
    pub match_mode: bool,
}

// ── NTPublisher ─────────────────────────────────────────────────────

struct Inner {
    cfg: ConfigManager,
    running: AtomicBool,
    connected: AtomicBool,
    /// Buffered values written by the camera thread, consumed by the WS task.
    buffer: Mutex<HashMap<String, NTValue>>,
    /// Latest input values received from the roboRIO.
    inputs: Mutex<NTInputs>,
}

#[derive(Clone)]
pub struct NTPublisher {
    inner: Arc<Inner>,
}

impl NTPublisher {
    pub fn new(cfg: ConfigManager) -> Self {
        Self {
            inner: Arc::new(Inner {
                cfg,
                running: AtomicBool::new(false),
                connected: AtomicBool::new(false),
                buffer: Mutex::new(HashMap::new()),
                inputs: Mutex::new(NTInputs::default()),
            }),
        }
    }

    /// Start the background WebSocket task that maintains the NT4 connection.
    pub async fn start(&self) {
        self.inner.running.store(true, Ordering::SeqCst);
        let inner = self.inner.clone();
        tokio::spawn(async move {
            connection_loop(inner).await;
        });
        info!("NT Publisher started");
    }

    pub fn stop(&self) {
        self.inner.running.store(false, Ordering::SeqCst);
        info!("NT Publisher stopped");
    }

    /// Buffer a complete frame of detection data for the background task to send.
    ///
    /// Safe to call from synchronous (camera-capture) threads.
    pub fn publish_frame(
        &self,
        detections: &[TagDetection],
        robot_pose: Option<&RobotPose>,
        offset_result: Option<&OffsetResult>,
        fps: f64,
        latency_ms: f64,
    ) {
        let mut buf = self.inner.buffer.lock();

        buf.insert("hasTarget".into(), NTValue::Boolean(!detections.is_empty()));
        buf.insert("numTargets".into(), NTValue::Int(detections.len() as i64));
        buf.insert("fps".into(), NTValue::Double(fps));
        buf.insert("latencyMs".into(), NTValue::Double(latency_ms));
        buf.insert(
            "tagIds".into(),
            NTValue::IntArray(detections.iter().map(|d| d.id as i64).collect()),
        );

        // Primary target – closest by distance
        if let Some(primary) = detections
            .iter()
            .min_by(|a, b| a.distance.partial_cmp(&b.distance).unwrap_or(std::cmp::Ordering::Equal))
        {
            buf.insert("primaryTagId".into(), NTValue::Int(primary.id as i64));
        } else {
            buf.insert("primaryTagId".into(), NTValue::Int(-1));
        }

        // Per-tag data
        for tag in detections {
            let p = format!("targets/{}", tag.id);
            buf.insert(format!("{p}/tx"), NTValue::Double(tag.tx));
            buf.insert(format!("{p}/ty"), NTValue::Double(tag.ty));
            buf.insert(format!("{p}/x"), NTValue::Double(tag.x));
            buf.insert(format!("{p}/y"), NTValue::Double(tag.y));
            buf.insert(format!("{p}/z"), NTValue::Double(tag.z));
            buf.insert(format!("{p}/distance"), NTValue::Double(tag.distance));
            buf.insert(format!("{p}/yaw"), NTValue::Double(tag.yaw));
            buf.insert(format!("{p}/pitch"), NTValue::Double(tag.pitch));
            buf.insert(format!("{p}/roll"), NTValue::Double(tag.roll));
        }

        // Robot pose
        if let Some(rp) = robot_pose.filter(|p| p.valid) {
            buf.insert(
                "robotPose".into(),
                NTValue::DoubleArray(vec![rp.x, rp.y, rp.z, rp.roll, rp.pitch, rp.yaw]),
            );
        } else {
            buf.insert("robotPose".into(), NTValue::DoubleArray(vec![0.0; 6]));
        }

        // Offset point
        if let Some(off) = offset_result.filter(|o| o.valid) {
            buf.insert("offsetPoint/valid".into(), NTValue::Boolean(true));
            buf.insert("offsetPoint/x".into(), NTValue::Double(off.x));
            buf.insert("offsetPoint/y".into(), NTValue::Double(off.y));
            buf.insert("offsetPoint/z".into(), NTValue::Double(off.z));
            buf.insert(
                "offsetPoint/directDistance".into(),
                NTValue::Double(off.direct_distance),
            );
            buf.insert("offsetPoint/tx".into(), NTValue::Double(off.tx));
            buf.insert("offsetPoint/ty".into(), NTValue::Double(off.ty));
        } else {
            buf.insert("offsetPoint/valid".into(), NTValue::Boolean(false));
        }
    }

    pub fn publish_status(&self, status: &str) {
        self.inner
            .buffer
            .lock()
            .insert("status".into(), NTValue::Str(status.to_string()));
    }

    pub fn read_inputs(&self) -> NTInputs {
        self.inner.inputs.lock().clone()
    }

    pub fn is_connected(&self) -> bool {
        self.inner.connected.load(Ordering::SeqCst)
    }
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Derive the NT4 server address from config.
fn resolve_server_address(cfg: &ConfigManager) -> Option<String> {
    let server_ip = cfg.get_str(&["network", "nt_server_ip"], "");
    if !server_ip.is_empty() {
        info!("NT4 connecting to server {}", server_ip);
        return Some(server_ip);
    }

    let team = cfg.get_i64(&["network", "team_number"], 0);
    if team > 0 {
        // 10.TE.AM.2  (e.g. team 1234 → 10.12.34.2)
        let high = team / 100;
        let low = team % 100;
        let ip = format!("10.{high}.{low}.2");
        info!("NT4 connecting via team number {} -> {}", team, ip);
        return Some(ip);
    }

    warn!("No NT server configured");
    None
}

fn now_micros() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as i64
}

/// Encode a single NT4 data frame as MessagePack binary.
fn encode_data_message(pubuid: i32, val: &NTValue) -> Vec<u8> {
    let msg = rmpv::Value::Array(vec![
        rmpv::Value::Integer(pubuid.into()),
        rmpv::Value::Integer(now_micros().into()),
        rmpv::Value::Integer(val.type_id().into()),
        val.to_msgpack(),
    ]);
    let mut out = Vec::new();
    rmpv::encode::write_value(&mut out, &msg).expect("msgpack encode failed");
    out
}

// ── Background connection loop ──────────────────────────────────────

async fn connection_loop(inner: Arc<Inner>) {
    while inner.running.load(Ordering::SeqCst) {
        let addr = match resolve_server_address(&inner.cfg) {
            Some(a) => a,
            None => {
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                continue;
            }
        };

        let url = format!("ws://{}:5810/nt/XNav", addr);
        info!("NT4 connecting to {}", url);

        match tokio_tungstenite::connect_async(&url).await {
            Ok((ws, _)) => {
                inner.connected.store(true, Ordering::SeqCst);
                info!("NT4 connected");
                run_session(ws, &inner).await;
                inner.connected.store(false, Ordering::SeqCst);
                info!("NT4 disconnected");
            }
            Err(e) => {
                debug!("NT4 connect failed: {}", e);
            }
        }

        if inner.running.load(Ordering::SeqCst) {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
    }
}

/// Drive a single WebSocket session until it drops.
async fn run_session<S>(ws: S, inner: &Arc<Inner>)
where
    S: futures_util::Stream<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>
        + futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error>
        + Unpin,
{
    let (mut sink, mut stream) = ws.split();

    // topic key → pubuid (client-assigned)
    let mut published: HashMap<String, i32> = HashMap::new();
    let mut next_pubuid: i32 = 1;

    // server-assigned topic id → topic name (for incoming subscription data)
    let mut sub_topics: HashMap<i32, String> = HashMap::new();

    // Subscribe to input topics
    let sub_msg = json!([{
        "method": "subscribe",
        "params": {
            "topics": [
                "/XNav/input/turretAngle",
                "/XNav/input/turretEnabled",
                "/XNav/input/matchMode"
            ],
            "subuid": 1,
            "options": { "periodic": 0.1 }
        }
    }]);
    if sink
        .send(Message::Text(sub_msg.to_string()))
        .await
        .is_err()
    {
        return;
    }

    let mut interval = tokio::time::interval(std::time::Duration::from_millis(20));

    loop {
        if !inner.running.load(Ordering::SeqCst) {
            break;
        }

        tokio::select! {
            _ = interval.tick() => {
                let snapshot: HashMap<String, NTValue> = {
                    let mut buf = inner.buffer.lock();
                    std::mem::take(&mut *buf)
                };
                if snapshot.is_empty() {
                    continue;
                }

                if send_snapshot(&mut sink, &snapshot, &mut published, &mut next_pubuid)
                    .await
                    .is_err()
                {
                    break;
                }
            }

            msg = stream.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        handle_text_message(&text, &mut sub_topics);
                    }
                    Some(Ok(Message::Binary(data))) => {
                        handle_binary_message(&data, &sub_topics, inner);
                    }
                    Some(Ok(Message::Ping(d))) => {
                        if sink.send(Message::Pong(d)).await.is_err() {
                            break;
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Err(e)) => {
                        debug!("NT4 ws error: {}", e);
                        break;
                    }
                    _ => {}
                }
            }
        }
    }
}

/// Publish new topics and send buffered data values.
async fn send_snapshot<Si>(
    sink: &mut Si,
    snapshot: &HashMap<String, NTValue>,
    published: &mut HashMap<String, i32>,
    next_pubuid: &mut i32,
) -> Result<(), tokio_tungstenite::tungstenite::Error>
where
    Si: futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    // Declare any newly-seen topics
    let mut new_topics = Vec::new();
    for (key, val) in snapshot {
        if !published.contains_key(key) {
            let pubuid = *next_pubuid;
            *next_pubuid += 1;
            published.insert(key.clone(), pubuid);
            new_topics.push(json!({
                "method": "publish",
                "params": {
                    "name": format!("/XNav/{}", key),
                    "pubuid": pubuid,
                    "type": val.type_str(),
                    "properties": {}
                }
            }));
        }
    }
    if !new_topics.is_empty() {
        let msg = serde_json::Value::Array(new_topics);
        sink.send(Message::Text(msg.to_string())).await?;
    }

    // Send data frames
    for (key, val) in snapshot {
        if let Some(&pubuid) = published.get(key) {
            let data = encode_data_message(pubuid, val);
            sink.send(Message::Binary(data)).await?;
        }
    }

    Ok(())
}

// ── Incoming message handlers ───────────────────────────────────────

fn handle_text_message(text: &str, sub_topics: &mut HashMap<i32, String>) {
    let msgs: Vec<serde_json::Value> = match serde_json::from_str(text) {
        Ok(m) => m,
        Err(e) => {
            debug!("NT4 JSON parse error: {}", e);
            return;
        }
    };

    for msg in &msgs {
        let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
        let params = msg.get("params");

        match method {
            "announce" => {
                if let Some(p) = params {
                    let name = p.get("name").and_then(|n| n.as_str()).unwrap_or("");
                    let id = p.get("id").and_then(|i| i.as_i64()).unwrap_or(-1) as i32;
                    if id >= 0 {
                        sub_topics.insert(id, name.to_string());
                        debug!("NT4 announce: {} -> id {}", name, id);
                    }
                }
            }
            "unannounce" => {
                if let Some(p) = params {
                    let id = p.get("id").and_then(|i| i.as_i64()).unwrap_or(-1) as i32;
                    sub_topics.remove(&id);
                }
            }
            _ => {}
        }
    }
}

fn handle_binary_message(
    data: &[u8],
    sub_topics: &HashMap<i32, String>,
    inner: &Arc<Inner>,
) {
    let mut cursor = std::io::Cursor::new(data);
    let val = match rmpv::decode::read_value(&mut cursor) {
        Ok(v) => v,
        Err(e) => {
            debug!("NT4 msgpack decode error: {}", e);
            return;
        }
    };

    let arr = match val {
        rmpv::Value::Array(a) if a.len() >= 4 => a,
        _ => return,
    };

    let topic_id = match &arr[0] {
        rmpv::Value::Integer(i) => i.as_i64().unwrap_or(-1) as i32,
        _ => return,
    };

    let topic_name = match sub_topics.get(&topic_id) {
        Some(n) => n.as_str(),
        None => return,
    };

    let value = &arr[3];
    let mut inputs = inner.inputs.lock();

    match topic_name {
        "/XNav/input/turretAngle" => {
            if let Some(v) = value.as_f64() {
                inputs.turret_angle = v;
            }
        }
        "/XNav/input/turretEnabled" => {
            if let Some(v) = value.as_bool() {
                inputs.turret_enabled = v;
            }
        }
        "/XNav/input/matchMode" => {
            if let Some(v) = value.as_bool() {
                inputs.match_mode = v;
            }
        }
        _ => {}
    }
}
