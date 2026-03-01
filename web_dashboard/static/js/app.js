/**
 * XNav Dashboard - Frontend Logic
 */

"use strict";

// ── Socket.IO ────────────────────────────────────────────────────────────────
const socket = io();
let _matchMode = false;

socket.on("connect", () => console.log("WS connected"));
socket.on("state_update", updateState);
socket.on("calibration_result", onCalibrationResult);

// ── Tab navigation ────────────────────────────────────────────────────────────
document.querySelectorAll("[data-tab]").forEach(link => {
  link.addEventListener("click", e => {
    e.preventDefault();
    const tab = link.dataset.tab;
    document.querySelectorAll(".tab-content").forEach(el => el.classList.add("d-none"));
    document.getElementById("tab-" + tab).classList.remove("d-none");
    document.querySelectorAll("[data-tab]").forEach(l => l.classList.remove("active"));
    link.classList.add("active");
    onTabActivated(tab);
  });
});

function onTabActivated(tab) {
  if (tab === "camera") loadSection("camera", "form-camera");
  if (tab === "network") loadSection("network", "form-network");
  if (tab === "apriltag") loadSection("apriltag", "form-apriltag");
  if (tab === "lights") loadLights();
  if (tab === "fieldmap") loadFmapInfo();
  if (tab === "offset") loadOffset();
  if (tab === "turret") loadTurret();
  if (tab === "system") { loadMount(); loadThrottle(); }
  if (tab === "calibration") startCalibrationPoll();
}

// ── State update ─────────────────────────────────────────────────────────────
function updateState(data) {
  // Top bar
  setStatus(data.status);
  document.getElementById("badge-fps").textContent = data.fps + " FPS";
  document.getElementById("badge-latency").textContent = data.latency_ms + " ms";
  document.getElementById("stat-fps").textContent = data.fps;
  document.getElementById("stat-latency").textContent = data.latency_ms;
  document.getElementById("stat-ntargets").textContent = data.num_targets;

  // Temperature badge
  if (data.temperature_c !== undefined) {
    const tempBadge = document.getElementById("badge-temp");
    const tempVal = data.temperature_c > 0 ? data.temperature_c.toFixed(1) + " °C" : "-- °C";
    tempBadge.textContent = tempVal;
    const state = data.thermal_state || "unknown";
    tempBadge.className = "badge border " + (
      state === "critical" ? "bg-danger border-danger" :
      state === "hot"      ? "bg-warning text-dark border-warning" :
      state === "warm"     ? "bg-warning text-dark border-warning" :
      state === "ok"       ? "bg-dark border-secondary" :
      "bg-dark border-secondary"
    );
    // Also update system tab thermal badge if visible
    const sysBadge = document.getElementById("sys-thermal-badge");
    if (sysBadge) {
      sysBadge.textContent = tempVal + " [" + state + "]";
      sysBadge.className = "badge " + (
        state === "critical" ? "bg-danger" :
        state === "hot"      ? "bg-warning text-dark" :
        state === "warm"     ? "bg-warning text-dark" :
        "bg-success"
      );
    }
  }

  const ntBadge = document.getElementById("badge-nt");
  ntBadge.textContent = data.nt_connected ? "NT: ●" : "NT: ○";
  ntBadge.className = "badge " + (data.nt_connected ? "bg-primary connected" : "bg-secondary disconnected");
  document.getElementById("stat-nt").textContent = data.nt_connected ? "Connected" : "Disconnected";
  document.getElementById("stat-nt").className = "stat-val " + (data.nt_connected ? "text-primary" : "text-secondary");

  // Tags table
  const tbody = document.getElementById("tags-table-body");
  if (data.targets && data.targets.length > 0) {
    tbody.innerHTML = data.targets.map(t =>
      `<tr>
        <td><span class="badge bg-warning text-dark">${t.id}</span></td>
        <td>${t.distance.toFixed(3)}</td>
        <td>${t.tx.toFixed(1)}</td>
        <td>${t.ty.toFixed(1)}</td>
        <td>${t.yaw.toFixed(1)}</td>
      </tr>`
    ).join("");
  } else {
    tbody.innerHTML = `<tr><td colspan="5" class="text-center text-muted">No targets</td></tr>`;
  }

  // Robot pose
  const rp = data.robot_pose;
  const rpEl = document.getElementById("robot-pose-display");
  if (rp) {
    rpEl.innerHTML = `
      <div class="row text-center g-2">
        <div class="col-4"><div class="small text-muted">X</div><div class="fw-bold">${rp.x.toFixed(3)} m</div></div>
        <div class="col-4"><div class="small text-muted">Y</div><div class="fw-bold">${rp.y.toFixed(3)} m</div></div>
        <div class="col-4"><div class="small text-muted">Yaw</div><div class="fw-bold">${rp.yaw.toFixed(1)}°</div></div>
      </div>
      <div class="text-muted small mt-1">From tags: [${rp.source_tags.join(", ")}]</div>`;
  } else {
    rpEl.innerHTML = `<span class="text-muted">No field map or no visible tags.</span>`;
  }

  // Offset result
  const off = data.offset_result;
  const offEl = document.getElementById("offset-display");
  if (off) {
    offEl.innerHTML = `
      <div class="row text-center g-2">
        <div class="col-3"><div class="small text-muted">Tag ID</div><div class="fw-bold text-warning">${off.tag_id}</div></div>
        <div class="col-3"><div class="small text-muted">Distance</div><div class="fw-bold">${off.direct_distance.toFixed(3)} m</div></div>
        <div class="col-3"><div class="small text-muted">TX</div><div class="fw-bold">${off.tx.toFixed(1)}°</div></div>
        <div class="col-3"><div class="small text-muted">TY</div><div class="fw-bold">${off.ty.toFixed(1)}°</div></div>
      </div>
      <div class="row text-center g-2 mt-1">
        <div class="col-4"><div class="small text-muted">dX</div><div>${off.x.toFixed(3)} m</div></div>
        <div class="col-4"><div class="small text-muted">dY</div><div>${off.y.toFixed(3)} m</div></div>
        <div class="col-4"><div class="small text-muted">dZ</div><div>${off.z.toFixed(3)} m</div></div>
      </div>`;
    // Live update on offset tab
    document.getElementById("offset-result-live").innerHTML = offEl.innerHTML;
  } else {
    offEl.innerHTML = `<span class="text-muted">Offset point not configured or no target visible.</span>`;
  }
}

function setStatus(status) {
  const el = document.getElementById("badge-status");
  el.textContent = "● " + status.charAt(0).toUpperCase() + status.slice(1);
  el.className = "badge " + (status === "running" ? "bg-success running" :
                              status === "error"   ? "bg-danger error" :
                              "bg-secondary");
}

// ── Match Mode ───────────────────────────────────────────────────────────────
function toggleMatchMode() {
  _matchMode = !_matchMode;
  setMatchMode(_matchMode);
}

function setMatchModeFromCheckbox(val) {
  _matchMode = val;
  setMatchMode(val);
}

function setMatchMode(val) {
  fetch("/api/matchmode", {method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify({enabled: val})})
    .then(() => {
      document.getElementById("matchmode-label").textContent = "Match Mode: " + (val ? "ON" : "OFF");
      document.getElementById("sys-matchmode").checked = val;
      showToast(val ? "Match Mode ENABLED 🚀" : "Match Mode disabled", val ? "warning" : "secondary");
    });
}

// ── Generic section loader ────────────────────────────────────────────────────
function loadSection(section, formId) {
  fetch("/api/config/" + section)
    .then(r => r.json())
    .then(data => {
      const form = document.getElementById(formId);
      if (!form) return;
      Object.entries(data).forEach(([k, v]) => {
        const el = form.querySelector(`[name="${k}"]`);
        if (!el) return;
        if (el.type === "checkbox") el.checked = !!v;
        else el.value = v;
      });
    });
}

// Register form submit handlers
["form-camera", "form-network", "form-apriltag", "form-mount"].forEach(formId => {
  const form = document.getElementById(formId);
  if (!form) return;
  form.addEventListener("submit", e => {
    e.preventDefault();
    const sectionMap = {
      "form-camera": "camera", "form-network": "network",
      "form-apriltag": "apriltag", "form-mount": "camera_mount"
    };
    const section = sectionMap[formId];
    const data = formToObject(form);
    fetch("/api/config/" + section, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify(data)
    }).then(r => r.json()).then(() => showToast("Saved!", "success"));
  });
});

function formToObject(form) {
  const obj = {};
  new FormData(form).forEach((v, k) => {
    const el = form.querySelector(`[name="${k}"]`);
    if (el && el.type === "checkbox") obj[k] = el.checked;
    else if (v !== "" && !isNaN(Number(v))) obj[k] = Number(v);
    else obj[k] = v;
  });
  // Also handle checkboxes not checked (FormData omits them)
  form.querySelectorAll('input[type="checkbox"]').forEach(el => {
    if (!(el.name in obj)) obj[el.name] = false;
  });
  return obj;
}

// ── Lights ───────────────────────────────────────────────────────────────────
function loadLights() {
  fetch("/api/lights").then(r => r.json()).then(d => {
    document.getElementById("lights-enabled").checked = !!d.enabled;
    document.getElementById("lights-mode").value = d.mode || "on";
    document.getElementById("lights-brightness").value = d.brightness ?? 100;
    document.getElementById("lights-bright-val").textContent = d.brightness ?? 100;
    document.getElementById("lights-gpio").value = d.gpio_pin ?? 18;
  });
}

function setLights() {
  const payload = {
    enabled: document.getElementById("lights-enabled").checked,
    mode: document.getElementById("lights-mode").value,
    brightness: parseInt(document.getElementById("lights-brightness").value)
  };
  fetch("/api/lights", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(payload)});
}

function saveLightsGpio() {
  const pin = parseInt(document.getElementById("lights-gpio").value);
  fetch("/api/config/lights", {
    method:"POST", headers:{"Content-Type":"application/json"},
    body: JSON.stringify({gpio_pin: pin})
  }).then(() => showToast("GPIO pin saved. Reboot to apply.", "info"));
}

// ── Field Map ─────────────────────────────────────────────────────────────────
function loadFmapInfo() {
  fetch("/api/fmap").then(r => r.json()).then(d => {
    const el = document.getElementById("fmap-info");
    if (d.loaded) {
      const tags = d.data?.tags || [];
      el.innerHTML = `<div class="alert alert-success py-2 small">
        <i class="bi bi-check-circle me-1"></i>Field map loaded: <strong>${tags.length} tags</strong>
        (${d.data?.field?.length?.toFixed(2) || '?'}m × ${d.data?.field?.width?.toFixed(2) || '?'}m)
        <br><span class="text-muted">${d.file}</span>
      </div>`;
    } else {
      el.innerHTML = `<div class="alert alert-secondary py-2 small">No field map loaded.</div>`;
    }
  });
}

function uploadFmap() {
  const file = document.getElementById("fmap-file").files[0];
  if (!file) { showToast("Select a .fmap file first", "warning"); return; }
  const fd = new FormData();
  fd.append("file", file);
  document.getElementById("fmap-status").innerHTML = `<div class="spinner-border spinner-border-sm text-warning"></div> Uploading...`;
  fetch("/api/fmap", {method: "POST", body: fd})
    .then(r => r.json())
    .then(d => {
      if (d.ok) {
        document.getElementById("fmap-status").innerHTML = `<div class="alert alert-success py-2 small"><i class="bi bi-check-circle me-1"></i>Upload successful!</div>`;
        loadFmapInfo();
      } else {
        document.getElementById("fmap-status").innerHTML = `<div class="alert alert-danger py-2 small">${d.error}</div>`;
      }
    });
}

// ── Offset Point ──────────────────────────────────────────────────────────────
function loadOffset() {
  fetch("/api/config/offset_point").then(r => r.json()).then(d => {
    document.getElementById("offset-enabled").checked = !!d.enabled;
    document.getElementById("offset-tag-id").value = d.tag_id ?? 1;
    document.getElementById("offset-x").value = d.x ?? 0;
    document.getElementById("offset-y").value = d.y ?? 0;
    document.getElementById("offset-z").value = d.z ?? 0;
  });
}

function saveOffset() {
  const payload = {
    enabled: document.getElementById("offset-enabled").checked,
    tag_id: parseInt(document.getElementById("offset-tag-id").value),
    x: parseFloat(document.getElementById("offset-x").value),
    y: parseFloat(document.getElementById("offset-y").value),
    z: parseFloat(document.getElementById("offset-z").value),
  };
  fetch("/api/config/offset_point", {
    method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(payload)
  }).then(() => showToast("Offset point saved!", "success"));
}

// ── Turret ────────────────────────────────────────────────────────────────────
function loadTurret() {
  fetch("/api/config/turret").then(r => r.json()).then(d => {
    document.getElementById("turret-enabled").checked = !!d.enabled;
    document.getElementById("turret-offset").value = d.mount_angle_offset ?? 0;
  });
}

function saveTurret() {
  const payload = {
    enabled: document.getElementById("turret-enabled").checked,
    mount_angle_offset: parseFloat(document.getElementById("turret-offset").value),
    nt_topic: "/XNav/input/turretAngle"
  };
  fetch("/api/config/turret", {
    method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(payload)
  }).then(() => showToast("Turret settings saved!", "success"));
}

// ── Mount ─────────────────────────────────────────────────────────────────────
function loadMount() {
  fetch("/api/config/camera_mount").then(r => r.json()).then(d => {
    const form = document.getElementById("form-mount");
    if (!form) return;
    Object.entries(d).forEach(([k, v]) => {
      const el = form.querySelector(`[name="${k}"]`);
      if (el) el.value = v;
    });
  });
}

// ── Calibration ───────────────────────────────────────────────────────────────
let _calPollTimer = null;

function startCalibrationPoll() {
  if (_calPollTimer) return;
  _calPollTimer = setInterval(pollCalibrationStatus, 500);
}

function pollCalibrationStatus() {
  fetch("/api/calibration/status").then(r => r.json()).then(d => {
    const pct = d.target > 0 ? Math.round(d.progress / d.target * 100) : 0;
    document.getElementById("cal-progress-bar").style.width = pct + "%";
    document.getElementById("cal-progress-text").textContent = d.progress + "/" + d.target;
    document.getElementById("cal-status-text").textContent = d.status;
    document.getElementById("btn-compute-cal").disabled = !(d.progress >= 5);
  });
}

function startCalibration() {
  // Save settings first
  const rows = parseInt(document.getElementById("cal-rows").value);
  const cols = parseInt(document.getElementById("cal-cols").value);
  const sq = parseFloat(document.getElementById("cal-square").value);
  const tgt = parseInt(document.getElementById("cal-target").value);
  fetch("/api/config/calibration", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({checkerboard_rows: rows, checkerboard_cols: cols, checkerboard_square_size: sq})
  }).then(() => {
    fetch("/api/calibration/start", {
      method: "POST", headers: {"Content-Type": "application/json"},
      body: JSON.stringify({target_frames: tgt})
    }).then(() => {
      // Show calibration stream
      document.getElementById("calib-stream").src = "/calib-stream.mjpg?" + Date.now();
      document.getElementById("calib-stream").style.display = "";
      document.getElementById("calib-no-stream").style.display = "none";
      showToast("Calibration collection started!", "info");
    });
  });
}

function stopCalibration() {
  fetch("/api/calibration/stop", {method:"POST"});
  showToast("Collection stopped", "secondary");
}

function computeCalibration() {
  document.getElementById("cal-result").innerHTML = `<div class="spinner-border spinner-border-sm text-warning me-2"></div> Computing calibration...`;
  fetch("/api/calibration/compute", {method: "POST"});
}

function onCalibrationResult(data) {
  const el = document.getElementById("cal-result");
  if (data.ok) {
    el.innerHTML = `<div class="alert alert-success py-2 small"><i class="bi bi-check-circle me-1"></i>${data.message}</div>`;
  } else {
    el.innerHTML = `<div class="alert alert-danger py-2 small"><i class="bi bi-x-circle me-1"></i>${data.message}</div>`;
  }
}

// ── Throttle & Thermal ────────────────────────────────────────────────────────
function loadThrottle() {
  fetch("/api/throttle").then(r => r.json()).then(d => {
    const fps = d.fps ?? 0;
    document.getElementById("throttle-fps-range").value = fps;
    document.getElementById("throttle-fps-val").textContent = fps;
  });
  fetch("/api/config/thermal").then(r => r.json()).then(d => {
    if (!d || d.error) return;
    const hotEl  = document.getElementById("sys-throttle-fps-hot");
    const critEl = document.getElementById("sys-throttle-fps-crit");
    const warnTEl = document.getElementById("sys-temp-warn");
    const critTEl = document.getElementById("sys-temp-crit");
    if (hotEl)   hotEl.textContent  = d.throttle_fps_hot  ?? "--";
    if (critEl)  critEl.textContent = d.throttle_fps_crit ?? "--";
    if (warnTEl) warnTEl.textContent = d.temp_warn_c ?? "--";
    if (critTEl) critTEl.textContent = d.temp_crit_c ?? "--";
  });
}

function saveThrottle() {
  const fps = parseInt(document.getElementById("throttle-fps-range").value) || 0;
  fetch("/api/throttle", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({fps})
  }).then(() => showToast(fps > 0 ? `Throttle set to ${fps} FPS` : "Throttle disabled", "info"));
}

// ── System actions ────────────────────────────────────────────────────────────
function sysAction(action) {
  fetch("/api/system/" + action, {method:"POST"})
    .then(() => showToast("Command sent: " + action, "info"));
}

// ── Toast notifications ───────────────────────────────────────────────────────
function showToast(msg, type = "success") {
  const colorMap = {success:"#198754", warning:"#ffc107", danger:"#dc3545", info:"#0d6efd", secondary:"#6c757d"};
  const id = "toast-" + Date.now();
  const html = `
    <div id="${id}" class="toast show align-items-center mb-2" style="border-left: 4px solid ${colorMap[type] || '#aaa'};">
      <div class="d-flex">
        <div class="toast-body">${msg}</div>
        <button type="button" class="btn-close btn-close-white me-2 m-auto" onclick="document.getElementById('${id}').remove()"></button>
      </div>
    </div>`;
  document.getElementById("toast-container").insertAdjacentHTML("beforeend", html);
  setTimeout(() => { const el = document.getElementById(id); if (el) el.remove(); }, 3000);
}

// ── Initial load ──────────────────────────────────────────────────────────────
window.addEventListener("DOMContentLoaded", () => {
  // Load initial status
  fetch("/api/status").then(r => r.json()).then(updateState).catch(() => {});
  // Load match mode state
  fetch("/api/config").then(r => r.json()).then(cfg => {
    _matchMode = !!cfg.match_mode;
    document.getElementById("matchmode-label").textContent = "Match Mode: " + (_matchMode ? "ON" : "OFF");
    document.getElementById("sys-matchmode").checked = _matchMode;
  });
});
