#include "thermal_manager.hpp"

#include <fstream>
#include <syslog.h>
#include <chrono>
#include <thread>
#include <cstdio>

static const char* THERMAL_PATHS[] = {
    "/sys/class/thermal/thermal_zone0/temp",
    "/sys/class/thermal/thermal_zone1/temp",
    nullptr
};

float ThermalManager::readCpuTemp() {
    for (int i = 0; THERMAL_PATHS[i]; i++) {
        std::ifstream f(THERMAL_PATHS[i]);
        if (f.is_open()) {
            int raw = 0;
            f >> raw;
            if (f) return raw / 1000.0f;
        }
    }
    return 0.0f;
}

ThermalManager::ThermalManager(ConfigManager& cfg) : m_cfg(cfg) {}

ThermalManager::~ThermalManager() { stop(); }

void ThermalManager::start() {
    m_running = true;
    m_thread = std::thread(&ThermalManager::monitorLoop, this);
    syslog(LOG_INFO, "Thermal monitor started");
}

void ThermalManager::stop() {
    m_running = false;
    if (m_thread.joinable()) m_thread.join();
}

float ThermalManager::temperatureC() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_tempC;
}

std::string ThermalManager::thermalState() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_state;
}

ThermalStatus ThermalManager::getStatus() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return {m_tempC, m_state};
}

float ThermalManager::getAutoThrottleFps() const {
    auto thermal_cfg = m_cfg.getSection("thermal");
    float temp_hot   = thermal_cfg.value("temp_hot_c",  75.0f);
    float temp_crit  = thermal_cfg.value("temp_crit_c", 80.0f);
    float fps_hot    = thermal_cfg.value("throttle_fps_hot",  15.0f);
    float fps_crit   = thermal_cfg.value("throttle_fps_crit",  5.0f);

    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_tempC >= temp_crit) return fps_crit;
    if (m_tempC >= temp_hot)  return fps_hot;
    return 0.0f;
}

void ThermalManager::monitorLoop() {
    while (m_running) {
        float temp = readCpuTemp();

        auto thermal_cfg = m_cfg.getSection("thermal");
        float warn_c = thermal_cfg.value("temp_warn_c", 70.0f);
        float hot_c  = thermal_cfg.value("temp_hot_c",  75.0f);
        float crit_c = thermal_cfg.value("temp_crit_c", 80.0f);

        std::string state;
        if (temp == 0.0f)       state = "unknown";
        else if (temp >= crit_c) state = "critical";
        else if (temp >= hot_c)  state = "hot";
        else if (temp >= warn_c) state = "warm";
        else                     state = "ok";

        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_tempC = temp;
            m_state = state;
        }

        if (state == "critical") {
            syslog(LOG_WARNING, "CPU temperature CRITICAL: %.1fC - throttling to minimum", temp);
        } else if (state == "hot") {
            syslog(LOG_WARNING, "CPU temperature HOT: %.1fC - auto-throttling", temp);
        }

        std::this_thread::sleep_for(std::chrono::seconds(2));
    }
}
