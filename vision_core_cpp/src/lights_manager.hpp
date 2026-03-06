#pragma once
/**
 * XNav Lights Manager
 * Controls LED ring light via libgpiod (on/off + software PWM).
 */

#include <string>
#include <thread>
#include <mutex>
#include <atomic>
#include "config_manager.hpp"

struct LightsState {
    bool enabled{true};
    int  brightness{100};  // 0-100
    std::string mode{"on"};
    bool gpio_available{false};
};

class LightsManager {
public:
    explicit LightsManager(ConfigManager& cfg);
    ~LightsManager();

    void setEnabled(bool enabled);
    void setBrightness(int brightness);
    void setMode(const std::string& mode);
    LightsState getState() const;
    void cleanup();

private:
    void init();
    void apply();
    void pwmThread();

    ConfigManager& m_cfg;
    mutable std::mutex m_mutex;
    LightsState m_state;

    // libgpiod opaque handles (void* to avoid header inclusion)
    void* m_chip{nullptr};
    void* m_line{nullptr};
    bool  m_gpioAvailable{false};

    // Software PWM
    std::thread m_pwmThread;
    std::atomic<bool> m_pwmRunning{false};
    std::atomic<int>  m_dutyCycle{0};
};
