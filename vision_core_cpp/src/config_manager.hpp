#pragma once
/**
 * XNav Config Manager
 * Thread-safe configuration loading/saving from /etc/xnav/config.json
 */

#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <optional>
#include "json.hpp"

using json = nlohmann::json;

class ConfigManager {
public:
    using ChangeCallback = std::function<void(const std::vector<std::string>& keys, const json& value)>;

    explicit ConfigManager(const std::string& config_path = "");

    // Get a nested value by key path; returns default_val if not found
    json get(const std::string& key, const json& default_val = json{}) const;
    json getSection(const std::string& section) const;

    // Set a single top-level key
    void set(const std::string& key, const json& value);
    // Set a nested key within a section
    void setInSection(const std::string& section, const std::string& key, const json& value);
    // Replace an entire top-level section
    void updateSection(const std::string& section, const json& data);

    // Return full config snapshot
    json all() const;

    // Register a callback invoked on any change
    void registerCallback(ChangeCallback cb);

    const std::string& configPath() const { return m_path; }

private:
    void load();
    void save();
    void notify(const std::vector<std::string>& keys, const json& value);

    std::string m_path;
    mutable std::recursive_mutex m_mutex;
    json m_config;
    std::vector<ChangeCallback> m_callbacks;
};
