#!/usr/bin/env python3
"""
XNav Web Dashboard
Configuration portal for the XNav vision system.
Runs on port 5800 (same as Limelight convention).
"""

import sys
import os
import json
import threading
import time
import logging

# Allow importing vision core modules
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../vision_core/src"))

from flask import Flask, render_template, request, jsonify, Response, redirect, url_for
from flask_socketio import SocketIO, emit

import numpy as np

# ─── App setup ───────────────────────────────────────────────────────────────

app = Flask(__name__, template_folder="templates", static_folder="static")
app.secret_key = "xnav_dashboard_key_2024"
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="threading")

# ─── Import pipeline (if running as part of main.py) ─────────────────────────

_pipeline = None

def _get_pipeline():
    global _pipeline
    if _pipeline is not None:
        return _pipeline
    try:
        import main as main_module
        _pipeline = main_module.get_pipeline()
    except Exception:
        pass
    return _pipeline

def _get_config():
    p = _get_pipeline()
    if p:
        return p.config
    # Standalone mode: create own config manager
    from config_manager import ConfigManager
    return ConfigManager()

_cfg_standalone = None
def get_cfg():
    global _cfg_standalone
    p = _get_pipeline()
    if p:
        return p.config
    if _cfg_standalone is None:
        from config_manager import ConfigManager
        _cfg_standalone = ConfigManager()
    return _cfg_standalone

# ─── REST API ────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/status")
def api_status():
    p = _get_pipeline()
    if p:
        from main import get_shared_state
        state = get_shared_state()
        dets = state.get("detections", [])
        robot_pose = state.get("robot_pose")
        offset = state.get("offset_result")
        return jsonify({
            "status": state.get("status", "unknown"),
            "fps": state.get("fps", 0),
            "latency_ms": state.get("latency_ms", 0),
            "nt_connected": p.nt.is_connected(),
            "num_targets": len(dets),
            "targets": [_tag_to_dict(d) for d in dets],
            "robot_pose": _robot_pose_to_dict(robot_pose),
            "offset_result": _offset_to_dict(offset),
        })
    return jsonify({"status": "dashboard-only", "fps": 0, "latency_ms": 0,
                    "nt_connected": False, "num_targets": 0, "targets": [],
                    "robot_pose": None, "offset_result": None})

@app.route("/api/config", methods=["GET"])
def api_config_get():
    return jsonify(get_cfg().all())

@app.route("/api/config", methods=["POST"])
def api_config_post():
    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON"}), 400
    cfg = get_cfg()
    for section, values in data.items():
        if isinstance(values, dict):
            cfg.update_section(section, values)
        else:
            cfg.set(section, values)
    # Reload pipeline if running
    p = _get_pipeline()
    if p:
        p.detector.reload_config()
    return jsonify({"ok": True})

@app.route("/api/config/<section>", methods=["GET"])
def api_config_section_get(section):
    val = get_cfg().get(section)
    if val is None:
        return jsonify({"error": "Not found"}), 404
    return jsonify(val)

@app.route("/api/config/<section>", methods=["POST"])
def api_config_section_post(section):
    data = request.get_json(force=True)
    get_cfg().update_section(section, data)
    return jsonify({"ok": True})

# ─── Lights ───────────────────────────────────────────────────────────────────

@app.route("/api/lights", methods=["GET"])
def api_lights_get():
    p = _get_pipeline()
    if p:
        return jsonify(p.lights.get_state())
    return jsonify(get_cfg().get("lights") or {})

@app.route("/api/lights", methods=["POST"])
def api_lights_post():
    data = request.get_json(force=True)
    p = _get_pipeline()
    if p:
        if "enabled" in data:
            p.lights.set_enabled(bool(data["enabled"]))
        if "brightness" in data:
            p.lights.set_brightness(int(data["brightness"]))
        if "mode" in data:
            p.lights.set_mode(str(data["mode"]))
    get_cfg().update_section("lights", data)
    return jsonify({"ok": True})

# ─── Match mode ──────────────────────────────────────────────────────────────

@app.route("/api/matchmode", methods=["POST"])
def api_matchmode():
    data = request.get_json(force=True)
    enabled = bool(data.get("enabled", False))
    get_cfg().set("match_mode", enabled)
    return jsonify({"ok": True, "match_mode": enabled})

# ─── Field map ───────────────────────────────────────────────────────────────

@app.route("/api/fmap", methods=["POST"])
def api_fmap_upload():
    if "file" not in request.files:
        return jsonify({"error": "No file part"}), 400
    f = request.files["file"]
    if not f.filename.endswith(".fmap"):
        return jsonify({"error": "File must be a .fmap file"}), 400

    save_path = "/etc/xnav/field.fmap"
    try:
        os.makedirs("/etc/xnav", exist_ok=True)
        f.save(save_path)
        get_cfg().set("field_map", "fmap_file", save_path)
        get_cfg().set("field_map", "enabled", True)
        p = _get_pipeline()
        if p:
            p._reload_fmap()
        return jsonify({"ok": True, "path": save_path})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/fmap", methods=["GET"])
def api_fmap_get():
    cfg = get_cfg()
    fmap_cfg = cfg.get("field_map") or {}
    fmap_file = fmap_cfg.get("fmap_file", "")
    enabled = fmap_cfg.get("enabled", False)
    if fmap_file and os.path.exists(fmap_file):
        try:
            with open(fmap_file) as f:
                data = json.load(f)
            return jsonify({"loaded": True, "enabled": enabled, "file": fmap_file, "data": data})
        except Exception:
            pass
    return jsonify({"loaded": False, "enabled": enabled, "file": fmap_file})

# ─── Calibration ─────────────────────────────────────────────────────────────

@app.route("/api/calibration/start", methods=["POST"])
def api_cal_start():
    data = request.get_json(force=True) or {}
    target = int(data.get("target_frames", 20))
    p = _get_pipeline()
    if p:
        p.calibration.start_collection(target)
        return jsonify({"ok": True})
    return jsonify({"error": "Vision pipeline not running"}), 503

@app.route("/api/calibration/stop", methods=["POST"])
def api_cal_stop():
    p = _get_pipeline()
    if p:
        p.calibration.stop_collection()
    return jsonify({"ok": True})

@app.route("/api/calibration/compute", methods=["POST"])
def api_cal_compute():
    p = _get_pipeline()
    if not p:
        return jsonify({"error": "Vision pipeline not running"}), 503

    def _run():
        ok, msg = p.calibration.compute_calibration()
        if ok:
            result = p.calibration.get_result()
            if result:
                p.detector.set_calibration(
                    np.array(result["camera_matrix"]),
                    np.array(result["dist_coeffs"])
                )
        socketio.emit("calibration_result", {"ok": ok, "message": msg})

    threading.Thread(target=_run, daemon=True).start()
    return jsonify({"ok": True, "message": "Computing calibration..."})

@app.route("/api/calibration/status")
def api_cal_status():
    p = _get_pipeline()
    if p:
        return jsonify(p.calibration.get_status())
    return jsonify({"collecting": False, "progress": 0, "target": 20, "status": "idle"})

@app.route("/api/calibration/result")
def api_cal_result():
    p = _get_pipeline()
    if p:
        result = p.calibration.get_result()
        if result:
            # Remove full matrix to keep response small
            return jsonify({
                "rms_error": result.get("rms_error"),
                "image_size": result.get("image_size"),
                "num_frames": result.get("num_frames"),
                "has_calibration": True
            })
    return jsonify({"has_calibration": False})

# ─── MJPEG stream ────────────────────────────────────────────────────────────

@app.route("/stream.mjpg")
def mjpeg_stream():
    def gen():
        while True:
            p = _get_pipeline()
            frame_bytes = None
            if p:
                frame_bytes = p.camera.get_jpeg_frame(quality=60)
            if frame_bytes is None:
                time.sleep(0.033)
                continue
            yield (b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + frame_bytes + b"\r\n")
            time.sleep(0.033)
    return Response(gen(), mimetype="multipart/x-mixed-replace; boundary=frame")

@app.route("/calib-stream.mjpg")
def calib_stream():
    """MJPEG stream with calibration overlay."""
    def gen():
        while True:
            p = _get_pipeline()
            if p:
                frame, gray, _ = p.camera.get_frame()
                if frame is not None:
                    import cv2
                    overlay = p.calibration.draw_preview(frame)
                    _, buf = cv2.imencode(".jpg", overlay, [cv2.IMWRITE_JPEG_QUALITY, 60])
                    yield (b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + buf.tobytes() + b"\r\n")
            time.sleep(0.1)
    return Response(gen(), mimetype="multipart/x-mixed-replace; boundary=frame")

# ─── Reboot / shutdown ────────────────────────────────────────────────────────

@app.route("/api/system/reboot", methods=["POST"])
def api_reboot():
    import subprocess
    threading.Thread(target=lambda: (time.sleep(2), subprocess.run(["/sbin/reboot"])), daemon=True).start()
    return jsonify({"ok": True})

@app.route("/api/system/shutdown", methods=["POST"])
def api_shutdown():
    import subprocess
    threading.Thread(target=lambda: (time.sleep(2), subprocess.run(["/sbin/shutdown", "-h", "now"])), daemon=True).start()
    return jsonify({"ok": True})

@app.route("/api/system/restart-vision", methods=["POST"])
def api_restart_vision():
    p = _get_pipeline()
    if p:
        threading.Thread(target=lambda: (p.stop(), time.sleep(1), p.start()), daemon=True).start()
    return jsonify({"ok": True})

# ─── SocketIO real-time updates ───────────────────────────────────────────────

@socketio.on("connect")
def on_connect():
    emit("connected", {"message": "Connected to XNav dashboard"})

def _push_state_loop():
    """Background thread: push status updates to all connected clients."""
    while True:
        try:
            p = _get_pipeline()
            if p:
                from main import get_shared_state
                state = get_shared_state()
                dets = state.get("detections", [])
                socketio.emit("state_update", {
                    "status": state.get("status", "unknown"),
                    "fps": round(state.get("fps", 0), 1),
                    "latency_ms": round(state.get("latency_ms", 0), 2),
                    "nt_connected": p.nt.is_connected(),
                    "num_targets": len(dets),
                    "targets": [_tag_to_dict(d) for d in dets],
                    "robot_pose": _robot_pose_to_dict(state.get("robot_pose")),
                    "offset_result": _offset_to_dict(state.get("offset_result")),
                })
        except Exception:
            pass
        time.sleep(0.1)  # 10Hz updates

# ─── Helper serializers ───────────────────────────────────────────────────────

def _tag_to_dict(tag) -> dict:
    return {
        "id": tag.id,
        "tx": round(tag.tx, 3),
        "ty": round(tag.ty, 3),
        "x": round(tag.x, 4),
        "y": round(tag.y, 4),
        "z": round(tag.z, 4),
        "distance": round(tag.distance, 4),
        "yaw": round(tag.yaw, 2),
        "pitch": round(tag.pitch, 2),
        "roll": round(tag.roll, 2),
    }

def _robot_pose_to_dict(rp) -> dict:
    if rp is None or not rp.valid:
        return None
    return {
        "x": round(rp.x, 4),
        "y": round(rp.y, 4),
        "z": round(rp.z, 4),
        "roll": round(rp.roll, 2),
        "pitch": round(rp.pitch, 2),
        "yaw": round(rp.yaw, 2),
        "source_tags": rp.source_tag_ids
    }

def _offset_to_dict(o) -> dict:
    if o is None or not o.valid:
        return None
    return {
        "tag_id": o.tag_id,
        "x": round(o.x, 4),
        "y": round(o.y, 4),
        "z": round(o.z, 4),
        "direct_distance": round(o.direct_distance, 4),
        "tx": round(o.tx, 3),
        "ty": round(o.ty, 3),
    }

# ─── Run ─────────────────────────────────────────────────────────────────────

def run(host="0.0.0.0", port=5800):
    """Start the web dashboard."""
    # Start background state push thread
    threading.Thread(target=_push_state_loop, daemon=True).start()
    port = get_cfg().get("web_port") or port
    logger.info("XNav Dashboard starting on http://0.0.0.0:%d", port)
    socketio.run(app, host=host, port=port, allow_unsafe_werkzeug=True)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    run()
