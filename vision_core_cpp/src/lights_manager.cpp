#include "lights_manager.hpp"

#include <syslog.h>
#include <thread>
#include <chrono>

extern "C" {
#include <gpiod.h>
}

LightsManager::LightsManager(ConfigManager& cfg) : m_cfg(cfg) {
    init();
}

LightsManager::~LightsManager() {
    cleanup();
}

void LightsManager::init() {
    auto lights = m_cfg.getSection("lights");
    m_state.enabled    = lights.value("enabled",    true);
    m_state.brightness = lights.value("brightness", 100);
    m_state.mode       = lights.value("mode",       std::string("on"));
    int gpio_pin       = lights.value("gpio_pin",   18);

    struct gpiod_chip* chip = gpiod_chip_open("/dev/gpiochip0");
    if (!chip) {
        syslog(LOG_WARNING, "Lights: cannot open /dev/gpiochip0 - GPIO unavailable");
        m_gpioAvailable = false;
        m_state.gpio_available = false;
        return;
    }

    struct gpiod_line* line = gpiod_chip_get_line(chip, gpio_pin);
    if (!line) {
        syslog(LOG_WARNING, "Lights: cannot get GPIO line %d", gpio_pin);
        gpiod_chip_close(chip);
        m_gpioAvailable = false;
        m_state.gpio_available = false;
        return;
    }

    if (gpiod_line_request_output(line, "xnav-lights", 0) < 0) {
        syslog(LOG_WARNING, "Lights: cannot request GPIO line %d as output", gpio_pin);
        gpiod_chip_close(chip);
        m_gpioAvailable = false;
        m_state.gpio_available = false;
        return;
    }

    m_chip = chip;
    m_line = line;
    m_gpioAvailable = true;
    m_state.gpio_available = true;

    // Start software PWM thread
    m_pwmRunning = true;
    m_pwmThread = std::thread(&LightsManager::pwmThread, this);

    apply();
    syslog(LOG_INFO, "Lights initialized on GPIO pin %d", gpio_pin);
}

void LightsManager::cleanup() {
    m_pwmRunning = false;
    if (m_pwmThread.joinable()) m_pwmThread.join();

    if (m_line) {
        gpiod_line_set_value(reinterpret_cast<struct gpiod_line*>(m_line), 0);
        gpiod_line_release(reinterpret_cast<struct gpiod_line*>(m_line));
        m_line = nullptr;
    }
    if (m_chip) {
        gpiod_chip_close(reinterpret_cast<struct gpiod_chip*>(m_chip));
        m_chip = nullptr;
    }
}

void LightsManager::apply() {
    if (!m_gpioAvailable) return;

    int duty;
    if (!m_state.enabled || m_state.mode == "off") {
        duty = 0;
    } else {
        duty = m_state.brightness;  // 0-100
    }
    m_dutyCycle = duty;
}

void LightsManager::pwmThread() {
    // Software PWM at ~1kHz (1ms period)
    const int period_us = 1000;
    while (m_pwmRunning) {
        int duty = m_dutyCycle.load();
        if (!m_line) { std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue; }

        struct gpiod_line* line = reinterpret_cast<struct gpiod_line*>(m_line);

        if (duty <= 0) {
            gpiod_line_set_value(line, 0);
            std::this_thread::sleep_for(std::chrono::microseconds(period_us));
        } else if (duty >= 100) {
            gpiod_line_set_value(line, 1);
            std::this_thread::sleep_for(std::chrono::microseconds(period_us));
        } else {
            int on_us  = period_us * duty / 100;
            int off_us = period_us - on_us;
            gpiod_line_set_value(line, 1);
            std::this_thread::sleep_for(std::chrono::microseconds(on_us));
            gpiod_line_set_value(line, 0);
            std::this_thread::sleep_for(std::chrono::microseconds(off_us));
        }
    }
}

void LightsManager::setEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_state.enabled = enabled;
    m_cfg.setInSection("lights", "enabled", enabled);
    apply();
}

void LightsManager::setBrightness(int brightness) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_state.brightness = std::max(0, std::min(100, brightness));
    m_cfg.setInSection("lights", "brightness", m_state.brightness);
    apply();
}

void LightsManager::setMode(const std::string& mode) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_state.mode = mode;
    m_cfg.setInSection("lights", "mode", mode);
    apply();
}

LightsState LightsManager::getState() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_state;
}
