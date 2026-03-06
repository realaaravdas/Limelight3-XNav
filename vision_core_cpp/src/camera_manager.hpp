#pragma once
/**
 * XNav Camera Manager
 * V4L2 camera capture via OpenCV with frame callback delivery.
 */

#include <string>
#include <functional>
#include <thread>
#include <mutex>
#include <atomic>
#include <vector>
#include <optional>
#include <chrono>
#include <opencv2/videoio.hpp>
#include <opencv2/core.hpp>
#include "config_manager.hpp"

using FrameCallback = std::function<void(const cv::Mat& frame, const cv::Mat& gray, double timestamp)>;

class CameraManager {
public:
    explicit CameraManager(ConfigManager& cfg);
    ~CameraManager();

    void start();
    void stop();
    void restart();

    // Get latest frame (thread-safe copies)
    bool getFrame(cv::Mat& frame, cv::Mat& gray, double& timestamp) const;
    float getFps() const { return m_fps.load(); }

    // Register frame callback (called from capture thread)
    void registerFrameCallback(FrameCallback cb);

    // Return latest frame encoded as JPEG bytes
    std::optional<std::vector<uint8_t>> getJpegFrame(int quality = 70) const;

    void applySettings();

private:
    void captureLoop();
    bool openCamera();

    ConfigManager& m_cfg;
    cv::VideoCapture m_cap;
    mutable std::mutex m_frameLock;
    cv::Mat m_latestFrame;
    cv::Mat m_latestGray;
    double m_frameTime{0.0};
    std::atomic<bool> m_running{false};
    std::thread m_thread;
    std::atomic<float> m_fps{0.0f};
    std::vector<FrameCallback> m_callbacks;

    // FPS calculation
    int m_frameCount{0};
    std::chrono::steady_clock::time_point m_fpsT0;
};
