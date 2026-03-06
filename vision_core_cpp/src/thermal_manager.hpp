#pragma once
/**
 * XNav Thermal Manager
 * Monitors CPU temperature and provides auto-throttle FPS recommendations.
 * Temperature events NEVER trigger shutdown - only processing load reduction.
 */

#include <atomic>
#include <thread>
#include <mutex>
#include <string>
#include "config_manager.hpp"

struct ThermalStatus {
    float temperature_c{0.0f};
    std::string state{"unknown"};  // unknown / ok / warm / hot / critical
};

class ThermalManager {
public:
    explicit ThermalManager(ConfigManager& cfg);
    ~ThermalManager();

    void start();
    void stop();

    float temperatureC() const;
    std::string thermalState() const;
    ThermalStatus getStatus() const;

    // Returns non-zero throttle FPS when auto-throttle should apply
    float getAutoThrottleFps() const;

private:
    void monitorLoop();
    static float readCpuTemp();

    ConfigManager& m_cfg;
    mutable std::mutex m_mutex;
    float m_tempC{0.0f};
    std::string m_state{"unknown"};
    std::atomic<bool> m_running{false};
    std::thread m_thread;
};
