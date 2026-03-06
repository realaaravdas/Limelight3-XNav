/**
 * XNav Vision Core - Main Entry Point (C++ port)
 * Headless AprilTag vision system for FRC robots.
 */

#include <csignal>
#include <atomic>
#include <chrono>
#include <thread>
#include <mutex>
#include <syslog.h>
#include <cstdlib>

#include "config_manager.hpp"
#include "camera_manager.hpp"
#include "apriltag_detector.hpp"
#include "pose_calculator.hpp"
#include "fmap_loader.hpp"
#include "nt_publisher.hpp"
#include "lights_manager.hpp"
#include "thermal_manager.hpp"
#include "calibration_manager.hpp"
#include "web_server.hpp"

static std::atomic<bool> g_running{true};

static void signalHandler(int /*sig*/) {
    g_running = false;
}

int main(int argc, char* argv[]) {
    openlog("xnav", LOG_PID | LOG_CONS, LOG_DAEMON);
    syslog(LOG_INFO, "XNav Vision System (C++) starting");

    std::string config_path = "/etc/xnav/config.json";
    if (const char* env = std::getenv("XNAV_CONFIG")) config_path = env;
    if (argc > 1) config_path = argv[1];
    syslog(LOG_INFO, "Config: %s", config_path.c_str());

    std::signal(SIGINT,  signalHandler);
    std::signal(SIGTERM, signalHandler);
    std::signal(SIGPIPE, SIG_IGN);

    // ── Shared state ─────────────────────────────────────────────────
    SharedState shared_state;

    // ── Subsystem construction ────────────────────────────────────────
    ConfigManager      cfg(config_path);
    CameraManager      camera(cfg);
    AprilTagDetector   detector(cfg);
    PoseCalculator     pose_calc(cfg);
    NTPublisher        nt(cfg);
    LightsManager      lights(cfg);
    ThermalManager     thermal(cfg);
    CalibrationManager calibration(cfg);
    calibration.setDetector(&detector);

    // ── Field map ─────────────────────────────────────────────────────
    std::optional<FieldMap> field_map;
    auto reloadFmap = [&]() {
        auto fm_cfg = cfg.getSection("field_map");
        if (fm_cfg.value("enabled", false)) {
            std::string path = fm_cfg.value("fmap_file", std::string(""));
            if (!path.empty()) field_map = loadFmap(path);
            else field_map = std::nullopt;
        } else {
            field_map = std::nullopt;
        }
        pose_calc.setFieldMap(field_map);
    };
    reloadFmap();

    // ── Web server ────────────────────────────────────────────────────
    WebServer web_server(cfg, camera, calibration, lights, thermal,
                         shared_state, &field_map);

    // ── Config change callbacks ───────────────────────────────────────
    cfg.registerCallback([&](const std::vector<std::string>& keys, const json&) {
        if (keys.empty()) return;
        const std::string& s = keys[0];
        if (s == "field_map") reloadFmap();
        else if (s == "camera" || s == "apriltag") detector.reloadConfig();
    });

    // ── Throttle state ────────────────────────────────────────────────
    std::mutex throttle_mutex;
    std::chrono::steady_clock::time_point last_process;

    auto getThrottleFps = [&]() -> float {
        float manual = cfg.getSection("throttle").value("fps", 0.0f);
        float autofps = thermal.getAutoThrottleFps();
        if (manual > 0 && autofps > 0) return std::min(manual, autofps);
        return manual > 0 ? manual : autofps;
    };

    // ── Frame processing callback ─────────────────────────────────────
    camera.registerFrameCallback([&](const cv::Mat& /*frame*/, const cv::Mat& gray, double ts) {
        float eff_fps = getThrottleFps();
        if (eff_fps > 0.0f) {
            auto now = std::chrono::steady_clock::now();
            std::lock_guard<std::mutex> lock(throttle_mutex);
            if (std::chrono::duration<double>(now - last_process).count() < 1.0/eff_fps) return;
            last_process = now;
        }

        auto t0 = std::chrono::steady_clock::now();

        NTInputs inputs = nt.readInputs();

        auto detections = detector.detect(gray, ts);

        auto turret_cfg = cfg.getSection("turret");
        double turret_angle = (turret_cfg.value("enabled", false) && inputs.turretEnabled)
                            ? inputs.turretAngle : 0.0;
        turret_angle += turret_cfg.value("mount_angle_offset", 0.0);
        if (std::abs(turret_angle) > 0.001)
            detections = pose_calc.applyTurret(detections, turret_angle);

        std::optional<RobotPose> robot_pose;
        if (field_map.has_value())
            robot_pose = pose_calc.computeRobotPose(detections);

        auto offset_result = pose_calc.computeOffsetPoint(
            detections, cfg.getSection("offset_point"));

        float latency_ms = static_cast<float>(
            std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() * 1000.0);

        if (calibration.getStatus().collecting)
            calibration.addFrame(gray);

        auto thermal_status = thermal.getStatus();

        PipelineState ps;
        ps.detections    = detections;
        ps.robot_pose    = robot_pose;
        ps.offset_result = offset_result;
        ps.fps           = camera.getFps();
        ps.latency_ms    = latency_ms;
        ps.status        = "running";
        ps.temperature_c = thermal_status.temperature_c;
        ps.thermal_state = thermal_status.state;
        ps.throttle_fps  = eff_fps;
        ps.nt_connected  = nt.isConnected();
        shared_state.update(ps);

        web_server.broadcastState(ps);
        nt.publishFrame(detections, robot_pose, offset_result, ps.fps, latency_ms);
    });

    // ── Start subsystems ──────────────────────────────────────────────
    syslog(LOG_INFO, "Starting subsystems...");
    nt.start();
    thermal.start();
    camera.start();

    int web_port = cfg.get("web_port", json(5800)).get<int>();
    web_server.start(web_port);

    nt.publishStatus("running");
    syslog(LOG_INFO, "XNav running (port=%d, pid=%d)", web_port, getpid());

    // ── Main loop ─────────────────────────────────────────────────────
    while (g_running) {
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }

    // ── Shutdown ──────────────────────────────────────────────────────
    syslog(LOG_INFO, "Shutting down...");
    camera.stop();
    nt.stop();
    thermal.stop();
    web_server.stop();
    lights.cleanup();
    syslog(LOG_INFO, "XNav stopped");
    closelog();
    return 0;
}
