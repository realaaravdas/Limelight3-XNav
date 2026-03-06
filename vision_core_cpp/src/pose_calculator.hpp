#pragma once
/**
 * XNav Pose Calculator
 * Robot-to-target, field-centric pose, and offset-point calculations.
 */

#include <vector>
#include <optional>
#include <mutex>
#include "apriltag_detector.hpp"
#include "fmap_loader.hpp"
#include "config_manager.hpp"

struct RobotPose {
    double x{0.0}, y{0.0}, z{0.0};    // meters, field-centric
    double roll{0.0}, pitch{0.0}, yaw{0.0};  // degrees
    bool valid{false};
    std::vector<int> sourceTagIds;
};

struct OffsetResult {
    int tagId{0};
    double x{0.0}, y{0.0}, z{0.0};
    double directDistance{0.0};
    double tx{0.0}, ty{0.0};  // angles, degrees
    bool valid{false};
};

class PoseCalculator {
public:
    explicit PoseCalculator(ConfigManager& cfg);

    void setFieldMap(std::optional<FieldMap> field_map);

    // Apply turret rotation to detections (Y-axis rotation)
    std::vector<TagDetection> applyTurret(const std::vector<TagDetection>& dets, double turret_deg);

    // Compute field-centric robot pose from detections
    std::optional<RobotPose> computeRobotPose(const std::vector<TagDetection>& dets);

    // Compute offset point result
    std::optional<OffsetResult> computeOffsetPoint(const std::vector<TagDetection>& dets, const json& cfg_offset);

private:
    cv::Matx44d buildCameraToRobot(const json& mount) const;

    ConfigManager& m_cfg;
    mutable std::mutex m_mapMutex;
    std::optional<FieldMap> m_fieldMap;
};
