#include "config_manager.hpp"

#include <fstream>
#include <iostream>
#include <filesystem>
#include <syslog.h>

namespace fs = std::filesystem;

static const char* DEFAULT_CONFIG_PATH = "/etc/xnav/config.json";
static const char* BUILTIN_DEFAULT_CONFIG = R"({
  "network": {"team_number": 0, "nt_server_ip": "", "hostname": "xnav"},
  "camera": {"device": "/dev/video0", "width": 1280, "height": 720, "fps": 90,
              "exposure": 100, "gain": 50, "brightness": 50, "contrast": 50,
              "auto_exposure": false},
  "lights": {"enabled": true, "brightness": 100, "mode": "on", "gpio_pin": 18},
  "apriltag": {"family": "tag36h11", "quad_decimate": 2.0, "nthreads": 4,
               "decode_sharpening": 0.25, "refine_edges": true, "tag_size": 0.1524},
  "calibration": {"camera_matrix": null, "dist_coeffs": null,
                  "calibration_file": "/etc/xnav/calibration.json",
                  "checkerboard_rows": 6, "checkerboard_cols": 9,
                  "checkerboard_square_size": 0.025},
  "field_map": {"fmap_file": "/etc/xnav/field.fmap", "enabled": false},
  "turret": {"enabled": false, "mount_angle_offset": 0.0},
  "offset_point": {"enabled": false, "tag_id": 1, "x": 0.0, "y": 0.0, "z": 0.0},
  "match_mode": false,
  "web_port": 5800,
  "throttle": {"fps": 0},
  "thermal": {"temp_warn_c": 70.0, "temp_hot_c": 75.0, "temp_crit_c": 80.0,
              "throttle_fps_hot": 15.0, "throttle_fps_crit": 5.0},
  "camera_mount": {"x_offset": 0.0, "y_offset": 0.0, "z_offset": 0.0,
                   "roll": 0.0, "pitch": 0.0, "yaw": 0.0}
})";

ConfigManager::ConfigManager(const std::string& config_path)
    : m_path(config_path.empty() ? DEFAULT_CONFIG_PATH : config_path)
{
    load();
}

json ConfigManager::get(const std::string& key, const json& default_val) const {
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    if (m_config.contains(key)) {
        return m_config[key];
    }
    return default_val;
}

json ConfigManager::getSection(const std::string& section) const {
    return get(section, json::object());
}

void ConfigManager::set(const std::string& key, const json& value) {
    {
        std::lock_guard<std::recursive_mutex> lock(m_mutex);
        m_config[key] = value;
    }
    save();
    notify({key}, value);
}

void ConfigManager::setInSection(const std::string& section, const std::string& key, const json& value) {
    {
        std::lock_guard<std::recursive_mutex> lock(m_mutex);
        if (!m_config.contains(section) || !m_config[section].is_object()) {
            m_config[section] = json::object();
        }
        m_config[section][key] = value;
    }
    save();
    notify({section, key}, value);
}

void ConfigManager::updateSection(const std::string& section, const json& data) {
    {
        std::lock_guard<std::recursive_mutex> lock(m_mutex);
        m_config[section] = data;
    }
    save();
    notify({section}, data);
}

json ConfigManager::all() const {
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    return m_config;
}

void ConfigManager::registerCallback(ChangeCallback cb) {
    std::lock_guard<std::recursive_mutex> lock(m_mutex);
    m_callbacks.push_back(std::move(cb));
}

void ConfigManager::load() {
    if (fs::exists(m_path)) {
        try {
            std::ifstream f(m_path);
            m_config = json::parse(f);
            syslog(LOG_INFO, "Config loaded from %s", m_path.c_str());
            return;
        } catch (const std::exception& e) {
            syslog(LOG_WARNING, "Failed to load config %s: %s", m_path.c_str(), e.what());
        }
    }
    // Load built-in defaults
    try {
        m_config = json::parse(BUILTIN_DEFAULT_CONFIG);
        syslog(LOG_INFO, "Loaded built-in default config");
    } catch (const std::exception& e) {
        syslog(LOG_ERR, "Failed to parse built-in default config: %s", e.what());
        m_config = json::object();
    }
    save();
}

void ConfigManager::save() {
    try {
        fs::path p(m_path);
        fs::create_directories(p.parent_path());
        fs::path tmp_path = p.parent_path() / (p.filename().string() + ".tmp");
        {
            std::ofstream f(tmp_path);
            f << m_config.dump(2);
        }
        fs::rename(tmp_path, p);
    } catch (const std::exception& e) {
        syslog(LOG_ERR, "Failed to save config: %s", e.what());
    }
}

void ConfigManager::notify(const std::vector<std::string>& keys, const json& value) {
    std::vector<ChangeCallback> cbs;
    {
        std::lock_guard<std::recursive_mutex> lock(m_mutex);
        cbs = m_callbacks;
    }
    for (auto& cb : cbs) {
        try {
            cb(keys, value);
        } catch (const std::exception& e) {
            syslog(LOG_WARNING, "Config callback error: %s", e.what());
        }
    }
}
