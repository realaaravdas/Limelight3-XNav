#pragma once
/**
 * XNav Calibration Manager
 * Camera calibration using checkerboard pattern via OpenCV.
 */

#include <vector>
#include <string>
#include <mutex>
#include <atomic>
#include <optional>
#include <thread>
#include <opencv2/core.hpp>
#include "config_manager.hpp"
#include "apriltag_detector.hpp"

struct CalibrationResult {
    cv::Mat cameraMatrix;
    cv::Mat distCoeffs;
    double rmsError{0.0};
    bool valid{false};
};

struct CalibrationStatus {
    bool collecting{false};
    int  progress{0};
    int  target{20};
    std::string status{"idle"};  // idle / collecting / ready_to_calibrate / computing / done / failed
    bool has_result{false};
};

class CalibrationManager {
public:
    explicit CalibrationManager(ConfigManager& cfg);

    // Collection control
    void startCollection(int target_frames = 20);
    void stopCollection();

    // Add a grayscale frame; tries to find checkerboard corners; returns true if accepted
    bool addFrame(const cv::Mat& gray);

    // Returns current calibration preview image as JPEG
    std::optional<std::vector<uint8_t>> getPreviewJpeg(const cv::Mat& gray) const;

    CalibrationStatus getStatus() const;

    // Run calibration on collected frames; returns (success, message)
    std::pair<bool, std::string> computeCalibration();

    // Get the most recent calibration result
    std::optional<CalibrationResult> getResult() const;

    // Get result as JSON (for API)
    json getResultJson() const;

    // Set the AprilTag detector to notify on new calibration
    void setDetector(AprilTagDetector* detector) { m_detector = detector; }

private:
    ConfigManager& m_cfg;
    mutable std::mutex m_lock;
    std::vector<cv::Mat> m_frames;
    bool m_collecting{false};
    int  m_progress{0};
    int  m_target{20};
    std::string m_status{"idle"};
    std::optional<CalibrationResult> m_result;
    AprilTagDetector* m_detector{nullptr};
};
