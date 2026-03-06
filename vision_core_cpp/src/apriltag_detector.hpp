#pragma once
/**
 * XNav AprilTag Detector
 * Detects AprilTags and computes 3D pose using libapriltag + OpenCV.
 */

#include <vector>
#include <optional>
#include <array>
#include <mutex>
#include <opencv2/core.hpp>
#include "config_manager.hpp"

struct TagDetection {
    int id{0};
    // Camera-frame translation (meters)
    double x{0.0}, y{0.0}, z{0.0};
    double distance{0.0};
    // Angles from camera center (degrees)
    double tx{0.0}, ty{0.0};
    // Orientation (degrees)
    double yaw{0.0}, pitch{0.0}, roll{0.0};
    // Image-space center
    double cx{0.0}, cy{0.0};
    // 4 corner points
    std::array<std::array<double,2>,4> corners{};
    // Rotation and translation vectors (for pose transforms)
    cv::Vec3d rvec{0,0,0};
    cv::Vec3d tvec{0,0,0};
    bool has_pose{false};
    // Tag quality metrics
    int hamming{0};
    double decision_margin{0.0};
    double timestamp{0.0};
};

class AprilTagDetector {
public:
    explicit AprilTagDetector(ConfigManager& cfg);
    ~AprilTagDetector();

    std::vector<TagDetection> detect(const cv::Mat& gray, double timestamp);
    void reloadConfig();
    void setCalibration(const cv::Mat& camera_matrix, const cv::Mat& dist_coeffs);

    bool hasCalibration() const { return !m_cameraMatrix.empty(); }

private:
    void initDetector();
    void loadCalibration();
    void getCameraParams(int w, int h, double& fx, double& fy, double& cx, double& cy) const;

    ConfigManager& m_cfg;
    mutable std::mutex m_mutex;

    // libapriltag opaque handle (void* to avoid including C headers in header)
    void* m_detector{nullptr};
    void* m_family{nullptr};
    std::string m_familyName;

    cv::Mat m_cameraMatrix;
    cv::Mat m_distCoeffs;
    double m_tagSize{0.1524};
};
