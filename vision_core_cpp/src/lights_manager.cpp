#include "lights_manager.hpp"

#include <syslog.h>
#include <algorithm>
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
    m_gpioPin          = static_cast<unsigned int>(std::max(0, lights.value("gpio_pin", 18)));

    struct gpiod_chip* chip = gpiod_chip_open("/dev/gpiochip0");
    if (!chip) {
        syslog(LOG_WARNING, "Lights: cannot open /dev/gpiochip0 - GPIO unavailable");
        m_gpioAvailable = false;
        m_state.gpio_available = false;
        return;
    }

    // libgpiod v2 API: configure line settings
    struct gpiod_line_settings* settings = gpiod_line_settings_new();
    if (!settings) {
        syslog(LOG_WARNING, "Lights: cannot allocate line settings");
        gpiod_chip_close(chip);
        m_gpioAvailable = false;
        m_state.gpio_available = false;
        return;
    }
    gpiod_line_settings_set_direction(settings, GPIOD_LINE_DIRECTION_OUTPUT);
    gpiod_line_settings_set_output_value(settings, GPIOD_LINE_VALUE_INACTIVE);

    struct gpiod_line_config* line_cfg = gpiod_line_config_new();
    if (!line_cfg) {
        syslog(LOG_WARNING, "Lights: cannot allocate line config");
        gpiod_line_settings_free(settings);
        gpiod_chip_close(chip);
        m_gpioAvailable = false;
        m_state.gpio_available = false;
        return;
    }

    unsigned int offset = m_gpioPin;
    if (gpiod_line_config_add_line_settings(line_cfg, &offset, 1, settings) < 0) {
        syslog(LOG_WARNING, "Lights: cannot configure GPIO line %d", m_gpioPin);
        gpiod_line_config_free(line_cfg);
        gpiod_line_settings_free(settings);
        gpiod_chip_close(chip);
        m_gpioAvailable = false;
        m_state.gpio_available = false;
        return;
    }

    struct gpiod_request_config* req_cfg = gpiod_request_config_new();
    if (req_cfg) {
        gpiod_request_config_set_consumer(req_cfg, "xnav-lights");
    } else {
        syslog(LOG_WARNING, "Lights: cannot allocate request config, proceeding without consumer name");
    }

    struct gpiod_line_request* request = gpiod_chip_request_lines(chip, req_cfg, line_cfg);

    if (req_cfg) gpiod_request_config_free(req_cfg);
    gpiod_line_config_free(line_cfg);
    gpiod_line_settings_free(settings);

    if (!request) {
        syslog(LOG_WARNING, "Lights: cannot request GPIO line %d as output", m_gpioPin);
        gpiod_chip_close(chip);
        m_gpioAvailable = false;
        m_state.gpio_available = false;
        return;
    }

    m_chip = chip;
    m_request = request;
    m_gpioAvailable = true;
    m_state.gpio_available = true;

    // Start software PWM thread
    m_pwmRunning = true;
    m_pwmThread = std::thread(&LightsManager::pwmThread, this);

    apply();
    syslog(LOG_INFO, "Lights initialized on GPIO pin %d", m_gpioPin);
}

void LightsManager::cleanup() {
    m_pwmRunning = false;
    if (m_pwmThread.joinable()) m_pwmThread.join();

    if (m_request) {
        gpiod_line_request_set_value(
            reinterpret_cast<struct gpiod_line_request*>(m_request),
            m_gpioPin,
            GPIOD_LINE_VALUE_INACTIVE);
        gpiod_line_request_release(reinterpret_cast<struct gpiod_line_request*>(m_request));
        m_request = nullptr;
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

// Software PWM period in microseconds (~1 kHz)
static constexpr int PWM_PERIOD_US = 1000;

void LightsManager::pwmThread() {
    while (m_pwmRunning) {
        int duty = m_dutyCycle.load();
        if (!m_request) { std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue; }

        struct gpiod_line_request* request = reinterpret_cast<struct gpiod_line_request*>(m_request);
        unsigned int offset = m_gpioPin;

        if (duty <= 0) {
            gpiod_line_request_set_value(request, offset, GPIOD_LINE_VALUE_INACTIVE);
            std::this_thread::sleep_for(std::chrono::microseconds(PWM_PERIOD_US));
        } else if (duty >= 100) {
            gpiod_line_request_set_value(request, offset, GPIOD_LINE_VALUE_ACTIVE);
            std::this_thread::sleep_for(std::chrono::microseconds(PWM_PERIOD_US));
        } else {
            int on_us  = PWM_PERIOD_US * duty / 100;
            int off_us = PWM_PERIOD_US - on_us;
            gpiod_line_request_set_value(request, offset, GPIOD_LINE_VALUE_ACTIVE);
            std::this_thread::sleep_for(std::chrono::microseconds(on_us));
            gpiod_line_request_set_value(request, offset, GPIOD_LINE_VALUE_INACTIVE);
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
