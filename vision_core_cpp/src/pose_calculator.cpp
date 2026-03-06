#include "pose_calculator.hpp"

#include <cmath>
#include <syslog.h>
#include <opencv2/calib3d.hpp>

// ─── Math helpers ──────────────────────────────────────────────────────────

static inline double deg2rad(double d) { return d * M_PI / 180.0; }
static inline double rad2deg(double r) { return r * 180.0 / M_PI; }

// 3x3 rotation matrices
static cv::Matx33d rotX(double deg) {
    double a = deg2rad(deg);
    return {1, 0, 0, 0, std::cos(a), -std::sin(a), 0, std::sin(a), std::cos(a)};
}
static cv::Matx33d rotY(double deg) {
    double a = deg2rad(deg);
    return {std::cos(a), 0, std::sin(a), 0, 1, 0, -std::sin(a), 0, std::cos(a)};
}
static cv::Matx33d rotZ(double deg) {
    double a = deg2rad(deg);
    return {std::cos(a), -std::sin(a), 0, std::sin(a), std::cos(a), 0, 0, 0, 1};
}

static cv::Matx44d makeTf(const cv::Matx33d& R, const cv::Vec3d& t) {
    cv::Matx44d T = cv::Matx44d::eye();
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            T(r,c) = R(r,c);
    T(0,3) = t[0]; T(1,3) = t[1]; T(2,3) = t[2];
    return T;
}

static cv::Matx33d quatToRot(double qw, double qx, double qy, double qz) {
    return {
        1-2*(qy*qy+qz*qz), 2*(qx*qy-qz*qw),   2*(qx*qz+qy*qw),
        2*(qx*qy+qz*qw),   1-2*(qx*qx+qz*qz), 2*(qy*qz-qx*qw),
        2*(qx*qz-qy*qw),   2*(qy*qz+qx*qw),   1-2*(qx*qx+qy*qy)
    };
}

static cv::Vec4d rotToQuat(const cv::Matx33d& R) {
    double trace = R(0,0) + R(1,1) + R(2,2);
    double qw, qx, qy, qz;
    if (trace > 0) {
        double s = 0.5 / std::sqrt(trace + 1.0);
        qw = 0.25 / s;
        qx = (R(2,1) - R(1,2)) * s;
        qy = (R(0,2) - R(2,0)) * s;
        qz = (R(1,0) - R(0,1)) * s;
    } else if (R(0,0) > R(1,1) && R(0,0) > R(2,2)) {
        double s = 2.0 * std::sqrt(1.0 + R(0,0) - R(1,1) - R(2,2));
        qw = (R(2,1) - R(1,2)) / s;
        qx = 0.25 * s;
        qy = (R(0,1) + R(1,0)) / s;
        qz = (R(0,2) + R(2,0)) / s;
    } else if (R(1,1) > R(2,2)) {
        double s = 2.0 * std::sqrt(1.0 + R(1,1) - R(0,0) - R(2,2));
        qw = (R(0,2) - R(2,0)) / s;
        qx = (R(0,1) + R(1,0)) / s;
        qy = 0.25 * s;
        qz = (R(1,2) + R(2,1)) / s;
    } else {
        double s = 2.0 * std::sqrt(1.0 + R(2,2) - R(0,0) - R(1,1));
        qw = (R(1,0) - R(0,1)) / s;
        qx = (R(0,2) + R(2,0)) / s;
        qy = (R(1,2) + R(2,1)) / s;
        qz = 0.25 * s;
    }
    return {qw, qx, qy, qz};
}

static std::tuple<double,double,double> rotToEuler(const cv::Matx33d& R) {
    double pitch = rad2deg(std::asin(std::max(-1.0, std::min(1.0, -R(2,0)))));
    double roll, yaw;
    if (std::abs(R(2,0)) < 0.9999) {
        roll = rad2deg(std::atan2(R(2,1), R(2,2)));
        yaw  = rad2deg(std::atan2(R(1,0), R(0,0)));
    } else {
        roll = 0.0;
        yaw  = rad2deg(std::atan2(-R(0,1), R(1,1)));
    }
    return {roll, pitch, yaw};
}

static std::tuple<double,double,double> rvecToEuler(const cv::Vec3d& rvec) {
    cv::Mat R_mat;
    cv::Rodrigues(cv::Mat(rvec), R_mat);
    cv::Matx33d R(R_mat);
    return rotToEuler(R);
}

// ─── PoseCalculator ────────────────────────────────────────────────────────

PoseCalculator::PoseCalculator(ConfigManager& cfg) : m_cfg(cfg) {}

void PoseCalculator::setFieldMap(std::optional<FieldMap> field_map) {
    std::lock_guard<std::mutex> lock(m_mapMutex);
    m_fieldMap = std::move(field_map);
}

cv::Matx44d PoseCalculator::buildCameraToRobot(const json& mount) const {
    double rx = mount.value("roll", 0.0);
    double ry = mount.value("pitch", 0.0);
    double rz = mount.value("yaw", 0.0);
    double tx = mount.value("x_offset", 0.0);
    double ty = mount.value("y_offset", 0.0);
    double tz = mount.value("z_offset", 0.0);
    cv::Matx33d R = rotZ(rz) * rotY(ry) * rotX(rx);
    return makeTf(R, cv::Vec3d(tx, ty, tz));
}

std::vector<TagDetection> PoseCalculator::applyTurret(
    const std::vector<TagDetection>& dets, double turret_deg)
{
    if (std::abs(turret_deg) < 1e-6) return dets;

    cv::Matx33d R = rotY(turret_deg);
    std::vector<TagDetection> result;
    result.reserve(dets.size());

    for (auto tag : dets) {
        if (!tag.has_pose) { result.push_back(tag); continue; }

        cv::Vec3d tv_rot = R * tag.tvec;
        tag.x = tv_rot[0];
        tag.y = tv_rot[1];
        tag.z = tv_rot[2];
        tag.distance = cv::norm(tv_rot);
        tag.tx = rad2deg(std::atan2(tag.x, tag.z));
        tag.ty = -rad2deg(std::atan2(tag.y, tag.z));
        tag.tvec = tv_rot;

        // Rotate rvec
        cv::Mat R_tag_mat;
        cv::Rodrigues(cv::Mat(tag.rvec), R_tag_mat);
        cv::Matx33d R_new = R * cv::Matx33d(R_tag_mat);
        cv::Mat rvec_new_mat;
        cv::Rodrigues(cv::Mat(R_new), rvec_new_mat);
        tag.rvec = cv::Vec3d(rvec_new_mat.at<double>(0),
                             rvec_new_mat.at<double>(1),
                             rvec_new_mat.at<double>(2));
        auto [roll, pitch, yaw] = rvecToEuler(tag.rvec);
        tag.roll = roll; tag.pitch = pitch; tag.yaw = yaw;

        result.push_back(tag);
    }
    return result;
}

std::optional<RobotPose> PoseCalculator::computeRobotPose(const std::vector<TagDetection>& dets) {
    std::lock_guard<std::mutex> lock(m_mapMutex);
    if (!m_fieldMap || m_fieldMap->tags.empty()) return std::nullopt;

    auto mount = m_cfg.getSection("camera_mount");
    cv::Matx44d T_cam_to_robot = buildCameraToRobot(mount);
    cv::Matx44d T_robot_to_cam = T_cam_to_robot.inv();

    std::vector<cv::Matx44d> poses;
    std::vector<int> tag_ids;

    for (const auto& tag : dets) {
        if (!tag.has_pose) continue;
        auto it = m_fieldMap->tags.find(tag.id);
        if (it == m_fieldMap->tags.end()) continue;

        const TagPose& fp = it->second;

        // Camera-in-tag transform
        cv::Mat R_mat;
        cv::Rodrigues(cv::Mat(tag.rvec), R_mat);
        cv::Matx33d R_cam_tag(R_mat);
        cv::Matx44d T_cam_in_tag = makeTf(R_cam_tag, tag.tvec);

        // Tag-in-field transform
        cv::Matx33d R_tag_field = quatToRot(fp.qw, fp.qx, fp.qy, fp.qz);
        cv::Matx44d T_tag_in_field = makeTf(R_tag_field, cv::Vec3d(fp.x, fp.y, fp.z));

        // Camera in field = tag_in_field * inv(cam_in_tag)
        cv::Matx44d T_cam_in_field = T_tag_in_field * T_cam_in_tag.inv();

        // Robot in field = cam_in_field * inv(cam_to_robot) = cam_in_field * robot_to_cam
        cv::Matx44d T_robot_in_field = T_cam_in_field * T_robot_to_cam;

        poses.push_back(T_robot_in_field);
        tag_ids.push_back(tag.id);
    }

    if (poses.empty()) return std::nullopt;

    // Average translations
    cv::Vec3d t_avg(0, 0, 0);
    for (auto& T : poses) {
        t_avg[0] += T(0,3);
        t_avg[1] += T(1,3);
        t_avg[2] += T(2,3);
    }
    t_avg *= (1.0 / poses.size());

    // Average quaternions (normalized sum)
    cv::Vec4d q_sum(0, 0, 0, 0);
    cv::Vec4d q_ref = rotToQuat(cv::Matx33d(
        poses[0](0,0), poses[0](0,1), poses[0](0,2),
        poses[0](1,0), poses[0](1,1), poses[0](1,2),
        poses[0](2,0), poses[0](2,1), poses[0](2,2)));

    for (auto& T : poses) {
        cv::Matx33d R(T(0,0), T(0,1), T(0,2),
                      T(1,0), T(1,1), T(1,2),
                      T(2,0), T(2,1), T(2,2));
        cv::Vec4d q = rotToQuat(R);
        if (q.dot(q_ref) < 0) q = -q;
        q_sum += q;
    }

    double norm = cv::norm(q_sum);
    if (norm < 1e-9) q_sum = {1,0,0,0};
    else q_sum *= (1.0 / norm);

    cv::Matx33d R_avg = quatToRot(q_sum[0], q_sum[1], q_sum[2], q_sum[3]);
    auto [roll, pitch, yaw] = rotToEuler(R_avg);

    RobotPose rp;
    rp.x = t_avg[0]; rp.y = t_avg[1]; rp.z = t_avg[2];
    rp.roll = roll; rp.pitch = pitch; rp.yaw = yaw;
    rp.valid = true;
    rp.sourceTagIds = tag_ids;
    return rp;
}

std::optional<OffsetResult> PoseCalculator::computeOffsetPoint(
    const std::vector<TagDetection>& dets, const json& cfg_offset)
{
    if (!cfg_offset.value("enabled", false)) return std::nullopt;

    int tag_id = cfg_offset.value("tag_id", 0);
    double ox = cfg_offset.value("x", 0.0);
    double oy = cfg_offset.value("y", 0.0);
    double oz = cfg_offset.value("z", 0.0);

    const TagDetection* target_tag = nullptr;
    for (const auto& tag : dets) {
        if (tag.id == tag_id && tag.has_pose) {
            target_tag = &tag;
            break;
        }
    }
    if (!target_tag) return std::nullopt;

    // Transform offset from tag frame to camera frame
    cv::Mat R_mat;
    cv::Rodrigues(cv::Mat(target_tag->rvec), R_mat);
    cv::Matx33d R_cam_tag(R_mat);

    cv::Vec3d offset_tag(ox, oy, oz);
    cv::Vec3d offset_cam = target_tag->tvec + R_cam_tag * offset_tag;

    double dx = offset_cam[0], dy = offset_cam[1], dz = offset_cam[2];
    double direct = cv::norm(offset_cam);
    double tx = rad2deg(std::atan2(dx, dz));
    double ty = -rad2deg(std::atan2(dy, dz));

    return OffsetResult{tag_id, dx, dy, dz, direct, tx, ty, true};
}
