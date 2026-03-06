#include "web_server.hpp"

// httplib.h is included below; CPPHTTPLIB_NO_EXCEPTIONS is set via CMake
#include "httplib.h"

#include <syslog.h>
#include <fstream>
#include <filesystem>
#include <cstdio>

namespace fs = std::filesystem;

static const char* STATIC_ROOT = "/opt/xnav/web_dashboard/static";
static const char* INDEX_HTML  = "/opt/xnav/web_dashboard/templates/index.html";
static const char* FMAP_PATH   = "/etc/xnav/field.fmap";

// ── Impl (holds httplib::Server) ───────────────────────────────────────────

struct WebServer::Impl {
    httplib::Server svr;
};

// ── Constructor / Destructor ───────────────────────────────────────────────

WebServer::WebServer(ConfigManager& cfg, CameraManager& camera,
                     CalibrationManager& calibration, LightsManager& lights,
                     ThermalManager& thermal, SharedState& state,
                     std::optional<FieldMap>* field_map_ptr)
    : m_cfg(cfg), m_camera(camera), m_calibration(calibration),
      m_lights(lights), m_thermal(thermal), m_state(state),
      m_fieldMap(field_map_ptr),
      m_impl(std::make_unique<Impl>())
{
    setupRoutes();
}

WebServer::~WebServer() { stop(); }

void WebServer::start(int port) {
    m_running = true;
    m_thread = std::thread([this, port]() {
        syslog(LOG_INFO, "Web server listening on port %d", port);
        m_impl->svr.listen("0.0.0.0", port);
        m_running = false;
    });
}

void WebServer::stop() {
    m_impl->svr.stop();
    if (m_thread.joinable()) m_thread.join();
}

// ── State JSON builder ─────────────────────────────────────────────────────

json WebServer::buildStatusJson(const PipelineState& s) const {
    json j;
    j["status"]       = s.status;
    j["fps"]          = s.fps;
    j["latency_ms"]   = s.latency_ms;
    j["has_target"]   = !s.detections.empty();
    j["num_targets"]  = (int)s.detections.size();
    j["nt_connected"] = s.nt_connected;
    j["temperature_c"] = s.temperature_c;
    j["thermal_state"] = s.thermal_state;
    j["throttle_fps"]  = s.throttle_fps;

    json targets = json::array();
    for (const auto& tag : s.detections) {
        json t;
        t["id"]       = tag.id;
        t["tx"]       = tag.tx;
        t["ty"]       = tag.ty;
        t["x"]        = tag.x;
        t["y"]        = tag.y;
        t["z"]        = tag.z;
        t["distance"] = tag.distance;
        t["yaw"]      = tag.yaw;
        t["pitch"]    = tag.pitch;
        t["roll"]     = tag.roll;
        targets.push_back(t);
    }
    j["targets"] = targets;

    if (s.robot_pose && s.robot_pose->valid) {
        auto& rp = *s.robot_pose;
        j["robot_pose"] = {rp.x, rp.y, rp.z, rp.roll, rp.pitch, rp.yaw};
    } else {
        j["robot_pose"] = json::array();
    }

    if (s.offset_result && s.offset_result->valid) {
        auto& op = *s.offset_result;
        j["offset_point"] = {
            {"valid", true}, {"x", op.x}, {"y", op.y}, {"z", op.z},
            {"directDistance", op.directDistance}, {"tx", op.tx}, {"ty", op.ty}
        };
    } else {
        j["offset_point"] = {{"valid", false}};
    }

    return j;
}

// ── SSE broadcast ──────────────────────────────────────────────────────────

void WebServer::broadcastState(const PipelineState& s) {
    json j;
    j["type"] = "state_update";
    j["data"] = buildStatusJson(s);
    std::string msg = "data: " + j.dump() + "\n\n";

    std::lock_guard<std::mutex> lock(m_sseMutex);
    for (auto it = m_sseClients.begin(); it != m_sseClients.end(); ) {
        if (!it->sink(msg)) {
            it = m_sseClients.erase(it);
        } else {
            ++it;
        }
    }
}

// ── Route setup ───────────────────────────────────────────────────────────

void WebServer::setupRoutes() {
    auto& svr = m_impl->svr;

    // Helper to set CORS / JSON headers
    auto jsonResp = [](httplib::Response& res, const json& j, int status = 200) {
        res.status = status;
        res.set_content(j.dump(), "application/json");
        res.set_header("Access-Control-Allow-Origin", "*");
    };

    // ── Index ────────────────────────────────────────────────────────
    svr.Get("/", [](const httplib::Request&, httplib::Response& res) {
        std::ifstream f(INDEX_HTML);
        if (f.is_open()) {
            std::string content((std::istreambuf_iterator<char>(f)),
                                std::istreambuf_iterator<char>());
            res.set_content(content, "text/html");
        } else {
            res.status = 404;
            res.set_content("Dashboard not found", "text/plain");
        }
    });

    // ── Static files ─────────────────────────────────────────────────
    svr.set_base_dir(STATIC_ROOT);
    svr.Get("/static/.*", [](const httplib::Request& req, httplib::Response& res) {
        std::string rel = req.path.substr(8);  // remove "/static/"
        std::string path = std::string(STATIC_ROOT) + "/" + rel;
        if (!fs::exists(path)) { res.status = 404; return; }
        std::ifstream f(path, std::ios::binary);
        std::string content((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
        // Simple MIME detection (C++17 compatible suffix check)
        std::string mime = "application/octet-stream";
        auto endsWith = [](const std::string& s, const std::string& suf) {
            return s.size() >= suf.size() && s.compare(s.size()-suf.size(), suf.size(), suf) == 0;
        };
        if (endsWith(path, ".css"))  mime = "text/css";
        else if (endsWith(path, ".js"))  mime = "application/javascript";
        else if (endsWith(path, ".png")) mime = "image/png";
        else if (endsWith(path, ".ico")) mime = "image/x-icon";
        res.set_content(content, mime.c_str());
    });

    // ── GET /api/status ───────────────────────────────────────────────
    svr.Get("/api/status", [this, jsonResp](const httplib::Request&, httplib::Response& res) {
        jsonResp(res, buildStatusJson(m_state.get()));
    });

    // ── GET /api/config ───────────────────────────────────────────────
    svr.Get("/api/config", [this, jsonResp](const httplib::Request&, httplib::Response& res) {
        jsonResp(res, m_cfg.all());
    });

    // ── POST /api/config ──────────────────────────────────────────────
    svr.Post("/api/config", [this, jsonResp](const httplib::Request& req, httplib::Response& res) {
        try {
            auto j = json::parse(req.body);
            for (auto& [key, val] : j.items()) {
                m_cfg.set(key, val);
            }
            jsonResp(res, {{"ok", true}});
        } catch (const std::exception& e) {
            jsonResp(res, {{"error", e.what()}}, 400);
        }
    });

    // ── GET /api/config/<section> ─────────────────────────────────────
    svr.Get(R"(/api/config/(\w+))", [this, jsonResp](const httplib::Request& req, httplib::Response& res) {
        std::string section = req.matches[1];
        jsonResp(res, m_cfg.getSection(section));
    });

    // ── POST /api/config/<section> ────────────────────────────────────
    svr.Post(R"(/api/config/(\w+))", [this, jsonResp](const httplib::Request& req, httplib::Response& res) {
        std::string section = req.matches[1];
        try {
            auto j = json::parse(req.body);
            m_cfg.updateSection(section, j);
            jsonResp(res, {{"ok", true}});
        } catch (const std::exception& e) {
            jsonResp(res, {{"error", e.what()}}, 400);
        }
    });

    // ── GET /api/lights ───────────────────────────────────────────────
    svr.Get("/api/lights", [this, jsonResp](const httplib::Request&, httplib::Response& res) {
        auto s = m_lights.getState();
        jsonResp(res, {{"enabled", s.enabled}, {"brightness", s.brightness},
                       {"mode", s.mode}, {"gpio_available", s.gpio_available}});
    });

    // ── POST /api/lights ──────────────────────────────────────────────
    svr.Post("/api/lights", [this, jsonResp](const httplib::Request& req, httplib::Response& res) {
        try {
            auto j = json::parse(req.body);
            if (j.contains("enabled"))    m_lights.setEnabled(j["enabled"].get<bool>());
            if (j.contains("brightness")) m_lights.setBrightness(j["brightness"].get<int>());
            if (j.contains("mode"))       m_lights.setMode(j["mode"].get<std::string>());
            jsonResp(res, {{"ok", true}});
        } catch (const std::exception& e) {
            jsonResp(res, {{"error", e.what()}}, 400);
        }
    });

    // ── POST /api/matchmode ───────────────────────────────────────────
    svr.Post("/api/matchmode", [this, jsonResp](const httplib::Request& req, httplib::Response& res) {
        try {
            auto j = json::parse(req.body);
            bool mm = j.value("match_mode", false);
            m_cfg.set("match_mode", mm);
            jsonResp(res, {{"ok", true}, {"match_mode", mm}});
        } catch (const std::exception& e) {
            jsonResp(res, {{"error", e.what()}}, 400);
        }
    });

    // ── GET /api/fmap ─────────────────────────────────────────────────
    svr.Get("/api/fmap", [this, jsonResp](const httplib::Request&, httplib::Response& res) {
        auto fm_cfg = m_cfg.getSection("field_map");
        bool enabled = fm_cfg.value("enabled", false);
        std::string fmap_file = fm_cfg.value("fmap_file", std::string(""));
        json j;
        j["enabled"] = enabled;
        j["fmap_file"] = fmap_file;
        j["loaded"] = (m_fieldMap && m_fieldMap->has_value());
        if (m_fieldMap && m_fieldMap->has_value()) {
            j["num_tags"] = (int)(*m_fieldMap)->tags.size();
        }
        jsonResp(res, j);
    });

    // ── POST /api/fmap ────────────────────────────────────────────────
    svr.Post("/api/fmap", [this, jsonResp](const httplib::Request& req, httplib::Response& res) {
        try {
            // Accept raw fmap JSON body
            std::ofstream f(FMAP_PATH);
            f << req.body;
            f.close();
            // Update config to point to this file
            m_cfg.setInSection("field_map", "fmap_file", std::string(FMAP_PATH));
            jsonResp(res, {{"ok", true}, {"path", FMAP_PATH}});
        } catch (const std::exception& e) {
            jsonResp(res, {{"error", e.what()}}, 500);
        }
    });

    // ── GET /api/calibration/status ───────────────────────────────────
    svr.Get("/api/calibration/status", [this, jsonResp](const httplib::Request&, httplib::Response& res) {
        auto s = m_calibration.getStatus();
        jsonResp(res, {{"collecting", s.collecting}, {"progress", s.progress},
                       {"target", s.target}, {"status", s.status},
                       {"has_result", s.has_result}});
    });

    // ── POST /api/calibration/start ───────────────────────────────────
    svr.Post("/api/calibration/start", [this, jsonResp](const httplib::Request& req, httplib::Response& res) {
        int target = 20;
        try { auto j = json::parse(req.body); target = j.value("target_frames", 20); } catch(...) {}
        m_calibration.startCollection(target);
        jsonResp(res, {{"ok", true}, {"target", target}});
    });

    // ── POST /api/calibration/stop ────────────────────────────────────
    svr.Post("/api/calibration/stop", [this, jsonResp](const httplib::Request&, httplib::Response& res) {
        m_calibration.stopCollection();
        jsonResp(res, {{"ok", true}});
    });

    // ── POST /api/calibration/compute ─────────────────────────────────
    svr.Post("/api/calibration/compute", [this, jsonResp](const httplib::Request&, httplib::Response& res) {
        auto [ok, msg] = m_calibration.computeCalibration();
        jsonResp(res, {{"ok", ok}, {"message", msg}});
    });

    // ── GET /api/calibration/result ───────────────────────────────────
    svr.Get("/api/calibration/result", [this, jsonResp](const httplib::Request&, httplib::Response& res) {
        jsonResp(res, m_calibration.getResultJson());
    });

    // ── GET /api/thermal ──────────────────────────────────────────────
    svr.Get("/api/thermal", [this, jsonResp](const httplib::Request&, httplib::Response& res) {
        auto ts = m_thermal.getStatus();
        jsonResp(res, {{"temperature_c", ts.temperature_c}, {"state", ts.state}});
    });

    // ── GET /api/throttle ─────────────────────────────────────────────
    svr.Get("/api/throttle", [this, jsonResp](const httplib::Request&, httplib::Response& res) {
        auto t = m_cfg.getSection("throttle");
        jsonResp(res, {{"fps", t.value("fps", 0)}});
    });

    // ── POST /api/throttle ────────────────────────────────────────────
    svr.Post("/api/throttle", [this, jsonResp](const httplib::Request& req, httplib::Response& res) {
        try {
            auto j = json::parse(req.body);
            double fps = j.value("fps", 0.0);
            m_cfg.setInSection("throttle", "fps", fps);
            jsonResp(res, {{"ok", true}, {"fps", fps}});
        } catch (const std::exception& e) {
            jsonResp(res, {{"error", e.what()}}, 400);
        }
    });

    // ── POST /api/system/reboot ───────────────────────────────────────
    svr.Post("/api/system/reboot", [jsonResp](const httplib::Request&, httplib::Response& res) {
        jsonResp(res, {{"ok", true}});
        std::thread([]{ int r __attribute__((unused)) = std::system("reboot"); }).detach();
    });

    // ── POST /api/system/shutdown ─────────────────────────────────────
    svr.Post("/api/system/shutdown", [jsonResp](const httplib::Request&, httplib::Response& res) {
        jsonResp(res, {{"ok", true}});
        std::thread([]{ int r __attribute__((unused)) = std::system("shutdown -h now"); }).detach();
    });

    // ── POST /api/system/restart-vision ──────────────────────────────
    svr.Post("/api/system/restart-vision", [jsonResp](const httplib::Request&, httplib::Response& res) {
        jsonResp(res, {{"ok", true}});
        std::thread([]{ int r __attribute__((unused)) = std::system("systemctl restart xnav-vision"); }).detach();
    });

    // ── GET /stream.mjpg ─────────────────────────────────────────────
    svr.Get("/stream.mjpg", [this](const httplib::Request&, httplib::Response& res) {
        res.set_header("Access-Control-Allow-Origin", "*");
        res.set_chunked_content_provider("multipart/x-mixed-replace; boundary=frame",
            [this](size_t /*offset*/, httplib::DataSink& sink) -> bool {
                auto jpeg = m_camera.getJpegFrame(70);
                if (!jpeg) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(33));
                    return true;
                }
                std::string header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                   + std::to_string(jpeg->size()) + "\r\n\r\n";
                sink.write(header.c_str(), header.size());
                sink.write(reinterpret_cast<const char*>(jpeg->data()), jpeg->size());
                sink.write("\r\n", 2);
                std::this_thread::sleep_for(std::chrono::milliseconds(33));
                return true;
            });
    });

    // ── GET /calib-stream.mjpg ────────────────────────────────────────
    svr.Get("/calib-stream.mjpg", [this](const httplib::Request&, httplib::Response& res) {
        res.set_header("Access-Control-Allow-Origin", "*");
        res.set_chunked_content_provider("multipart/x-mixed-replace; boundary=frame",
            [this](size_t /*offset*/, httplib::DataSink& sink) -> bool {
                cv::Mat frame, gray; double ts;
                if (!m_camera.getFrame(frame, gray, ts)) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    return true;
                }
                auto jpeg = m_calibration.getPreviewJpeg(gray);
                if (!jpeg) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    return true;
                }
                std::string header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                   + std::to_string(jpeg->size()) + "\r\n\r\n";
                sink.write(header.c_str(), header.size());
                sink.write(reinterpret_cast<const char*>(jpeg->data()), jpeg->size());
                sink.write("\r\n", 2);
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                return true;
            });
    });

    // ── GET /api/stream (SSE) ─────────────────────────────────────────
    svr.Get("/api/stream", [this](const httplib::Request&, httplib::Response& res) {
        res.set_header("Access-Control-Allow-Origin", "*");
        res.set_header("Cache-Control", "no-cache");
        res.set_header("X-Accel-Buffering", "no");

        // Send initial state immediately
        json init;
        init["type"] = "state_update";
        init["data"] = buildStatusJson(m_state.get());
        std::string init_msg = "data: " + init.dump() + "\n\n";

        res.set_chunked_content_provider("text/event-stream",
            [this, init_msg](size_t offset, httplib::DataSink& sink) mutable -> bool {
                if (offset == 0) {
                    sink.write(init_msg.c_str(), init_msg.size());
                }
                // Keep-alive: send a comment every 15 seconds
                std::this_thread::sleep_for(std::chrono::seconds(15));
                std::string ka = ": keepalive\n\n";
                return sink.write(ka.c_str(), ka.size());
            });
    });
}
