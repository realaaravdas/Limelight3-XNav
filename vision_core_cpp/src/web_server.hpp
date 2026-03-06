#pragma once
/**
 * XNav Web Server
 * HTTP REST API + MJPEG stream + SSE state stream via cpp-httplib.
 */

#include <memory>
#include <mutex>
#include <vector>
#include <string>
#include <optional>
#include <functional>
#include <thread>
#include <atomic>
#include <list>
#include "config_manager.hpp"
#include "camera_manager.hpp"
#include "calibration_manager.hpp"
#include "lights_manager.hpp"
#include "thermal_manager.hpp"
#include "apriltag_detector.hpp"
#include "pose_calculator.hpp"

// ── Shared pipeline state (thread-safe snapshot updated by pipeline) ──────
struct PipelineState {
    std::vector<TagDetection> detections;
    std::optional<RobotPose>  robot_pose;
    std::optional<OffsetResult> offset_result;
    float fps{0.0f};
    float latency_ms{0.0f};
    std::string status{"starting"};
    float temperature_c{0.0f};
    std::string thermal_state{"unknown"};
    float throttle_fps{0.0f};
    bool  nt_connected{false};
};

class SharedState {
public:
    void update(const PipelineState& s) {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_state = s;
    }
    PipelineState get() const {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_state;
    }
private:
    mutable std::mutex m_mutex;
    PipelineState m_state;
};

class WebServer {
public:
    WebServer(ConfigManager& cfg,
              CameraManager& camera,
              CalibrationManager& calibration,
              LightsManager& lights,
              ThermalManager& thermal,
              SharedState& state,
              std::optional<FieldMap>* field_map_ptr);
    ~WebServer();

    void start(int port = 5800);
    void stop();

    bool isRunning() const { return m_running; }

    // Called by the pipeline to trigger SSE state broadcasts
    void broadcastState(const PipelineState& s);

private:
    void setupRoutes();

    // Route handlers (returns response body / sets status)
    json buildStatusJson(const PipelineState& s) const;

    ConfigManager&      m_cfg;
    CameraManager&      m_camera;
    CalibrationManager& m_calibration;
    LightsManager&      m_lights;
    ThermalManager&     m_thermal;
    SharedState&        m_state;
    std::optional<FieldMap>* m_fieldMap;

    // httplib server (opaque pointer to avoid pulling httplib.h into every TU)
    struct Impl;
    std::unique_ptr<Impl> m_impl;

    std::atomic<bool> m_running{false};
    std::thread m_thread;

    // SSE connections
    mutable std::mutex m_sseMutex;
    struct SseClient {
        std::function<bool(const std::string&)> sink;
    };
    std::list<SseClient> m_sseClients;
};
