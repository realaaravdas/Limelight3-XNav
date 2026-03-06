#include "apriltag_detector.hpp"

#include <cmath>
#include <cstdlib>
#include <syslog.h>
#include <filesystem>
#include <fstream>
#include <opencv2/imgproc.hpp>
#include <opencv2/calib3d.hpp>

extern "C" {
#include <apriltag/apriltag.h>
#include <apriltag/tag36h11.h>
#include <apriltag/tag16h5.h>
#include <apriltag/tag25h9.h>
#include <apriltag/tagStandard41h12.h>
#include <apriltag/apriltag_pose.h>
#include <apriltag/common/matd.h>
}

// matd_destroy may not be exported from the shared library; free() is safe
// because matd_t is a single allocation (flexible array member)
static inline void matd_free(matd_t* m) { if (m) std::free(m); }

namespace fs = std::filesystem;

// Helper: degrees
static inline double rad2deg(double r) { return r * (180.0 / M_PI); }

static std::tuple<double,double,double> rvecToEulerDeg(const cv::Vec3d& rvec) {
    cv::Mat R;
    cv::Rodrigues(rvec, R);
    double roll  = rad2deg(std::atan2(R.at<double>(2,1), R.at<double>(2,2)));
    double pitch = rad2deg(std::atan2(-R.at<double>(2,0),
                                      std::sqrt(R.at<double>(2,1)*R.at<double>(2,1) +
                                                R.at<double>(2,2)*R.at<double>(2,2))));
    double yaw   = rad2deg(std::atan2(R.at<double>(1,0), R.at<double>(0,0)));
    return {roll, pitch, yaw};
}

AprilTagDetector::AprilTagDetector(ConfigManager& cfg)
    : m_cfg(cfg)
{
    initDetector();
    loadCalibration();
}

AprilTagDetector::~AprilTagDetector() {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_detector) {
        apriltag_detector_t* td = reinterpret_cast<apriltag_detector_t*>(m_detector);
        if (m_family) {
            apriltag_detector_remove_family(td, reinterpret_cast<apriltag_family_t*>(m_family));
            // Destroy family based on name
            if (m_familyName == "tag36h11")         tag36h11_destroy(reinterpret_cast<apriltag_family_t*>(m_family));
            else if (m_familyName == "tag16h5")      tag16h5_destroy(reinterpret_cast<apriltag_family_t*>(m_family));
            else if (m_familyName == "tag25h9")      tag25h9_destroy(reinterpret_cast<apriltag_family_t*>(m_family));
            else if (m_familyName == "tagStandard41h12") tagStandard41h12_destroy(reinterpret_cast<apriltag_family_t*>(m_family));
        }
        apriltag_detector_destroy(td);
    }
}

void AprilTagDetector::initDetector() {
    std::lock_guard<std::mutex> lock(m_mutex);

    // Destroy existing detector
    if (m_detector) {
        apriltag_detector_t* td = reinterpret_cast<apriltag_detector_t*>(m_detector);
        if (m_family) {
            apriltag_detector_remove_family(td, reinterpret_cast<apriltag_family_t*>(m_family));
            if (m_familyName == "tag36h11")             tag36h11_destroy(reinterpret_cast<apriltag_family_t*>(m_family));
            else if (m_familyName == "tag16h5")          tag16h5_destroy(reinterpret_cast<apriltag_family_t*>(m_family));
            else if (m_familyName == "tag25h9")          tag25h9_destroy(reinterpret_cast<apriltag_family_t*>(m_family));
            else if (m_familyName == "tagStandard41h12") tagStandard41h12_destroy(reinterpret_cast<apriltag_family_t*>(m_family));
            m_family = nullptr;
        }
        apriltag_detector_destroy(td);
        m_detector = nullptr;
    }

    auto at_cfg = m_cfg.getSection("apriltag");
    m_tagSize = at_cfg.value("tag_size", 0.1524);
    m_familyName = at_cfg.value("family", std::string("tag36h11"));

    apriltag_family_t* tf = nullptr;
    if (m_familyName == "tag36h11")             tf = tag36h11_create();
    else if (m_familyName == "tag16h5")          tf = tag16h5_create();
    else if (m_familyName == "tag25h9")          tf = tag25h9_create();
    else if (m_familyName == "tagStandard41h12") tf = tagStandard41h12_create();
    else {
        syslog(LOG_WARNING, "Unknown apriltag family '%s', defaulting to tag36h11", m_familyName.c_str());
        m_familyName = "tag36h11";
        tf = tag36h11_create();
    }

    apriltag_detector_t* td = apriltag_detector_create();
    apriltag_detector_add_family(td, tf);
    td->nthreads        = at_cfg.value("nthreads", 4);
    td->quad_decimate   = at_cfg.value("quad_decimate", 2.0f);
    td->decode_sharpening = at_cfg.value("decode_sharpening", 0.25);
    td->refine_edges    = at_cfg.value("refine_edges", true) ? 1 : 0;

    m_detector = td;
    m_family   = tf;

    syslog(LOG_INFO, "AprilTag detector initialized: family=%s nthreads=%d",
           m_familyName.c_str(), td->nthreads);
}

void AprilTagDetector::loadCalibration() {
    auto cal = m_cfg.getSection("calibration");

    // Check embedded calibration in config
    if (!cal["camera_matrix"].is_null() && !cal["dist_coeffs"].is_null()) {
        try {
            auto mtx = cal["camera_matrix"].get<std::vector<std::vector<double>>>();
            auto dst = cal["dist_coeffs"].get<std::vector<double>>();
            m_cameraMatrix = cv::Mat(3, 3, CV_64F);
            for (int r = 0; r < 3; r++)
                for (int c = 0; c < 3; c++)
                    m_cameraMatrix.at<double>(r,c) = mtx[r][c];
            m_distCoeffs = cv::Mat(dst).t();
            syslog(LOG_INFO, "Loaded calibration from config");
            return;
        } catch (...) {}
    }

    // Load from calibration file
    std::string cal_file = cal.value("calibration_file", std::string("/etc/xnav/calibration.json"));
    if (!cal_file.empty() && fs::exists(cal_file)) {
        try {
            std::ifstream f(cal_file);
            json j = json::parse(f);
            auto mtx = j["camera_matrix"].get<std::vector<std::vector<double>>>();
            auto dst = j["dist_coeffs"].get<std::vector<double>>();
            m_cameraMatrix = cv::Mat(3, 3, CV_64F);
            for (int r = 0; r < 3; r++)
                for (int c = 0; c < 3; c++)
                    m_cameraMatrix.at<double>(r,c) = mtx[r][c];
            m_distCoeffs = cv::Mat(1, (int)dst.size(), CV_64F);
            for (int i = 0; i < (int)dst.size(); i++)
                m_distCoeffs.at<double>(0,i) = dst[i];
            syslog(LOG_INFO, "Loaded calibration from file: %s", cal_file.c_str());
            return;
        } catch (const std::exception& e) {
            syslog(LOG_WARNING, "Could not load calibration file %s: %s", cal_file.c_str(), e.what());
        }
    }
    syslog(LOG_WARNING, "No calibration found - using default intrinsics. Accuracy reduced.");
    m_cameraMatrix = cv::Mat();
    m_distCoeffs   = cv::Mat();
}

void AprilTagDetector::setCalibration(const cv::Mat& camera_matrix, const cv::Mat& dist_coeffs) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_cameraMatrix = camera_matrix.clone();
    m_distCoeffs   = dist_coeffs.clone();
    syslog(LOG_INFO, "Calibration updated in detector");
}

void AprilTagDetector::reloadConfig() {
    initDetector();
    loadCalibration();
}

void AprilTagDetector::getCameraParams(int w, int h, double& fx, double& fy, double& cx, double& cy) const {
    if (!m_cameraMatrix.empty()) {
        fx = m_cameraMatrix.at<double>(0,0);
        fy = m_cameraMatrix.at<double>(1,1);
        cx = m_cameraMatrix.at<double>(0,2);
        cy = m_cameraMatrix.at<double>(1,2);
    } else {
        fx = fy = std::max(w, h) * 1.2;
        cx = w / 2.0;
        cy = h / 2.0;
    }
}

std::vector<TagDetection> AprilTagDetector::detect(const cv::Mat& gray, double timestamp) {
    std::vector<TagDetection> results;
    if (gray.empty()) return results;

    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_detector) return results;

    apriltag_detector_t* td = reinterpret_cast<apriltag_detector_t*>(m_detector);

    // Convert cv::Mat to image_u8_t (must be contiguous)
    cv::Mat cont_gray = gray.isContinuous() ? gray : gray.clone();
    image_u8_t im{
        .width  = cont_gray.cols,
        .height = cont_gray.rows,
        .stride = static_cast<int32_t>(cont_gray.step),
        .buf    = cont_gray.data
    };

    zarray_t* detections = apriltag_detector_detect(td, &im);

    double fx, fy, cx_cam, cy_cam;
    getCameraParams(gray.cols, gray.rows, fx, fy, cx_cam, cy_cam);

    for (int i = 0; i < zarray_size(detections); i++) {
        apriltag_detection_t* det;
        zarray_get(detections, i, &det);

        TagDetection tag;
        tag.id              = det->id;
        tag.hamming         = det->hamming;
        tag.decision_margin = det->decision_margin;
        tag.timestamp       = timestamp;
        tag.cx              = det->c[0];
        tag.cy              = det->c[1];

        for (int j = 0; j < 4; j++) {
            tag.corners[j][0] = det->p[j][0];
            tag.corners[j][1] = det->p[j][1];
        }

        // Pixel angles from center
        tag.tx = rad2deg(std::atan2(tag.cx - cx_cam, fx));
        tag.ty = -rad2deg(std::atan2(tag.cy - cy_cam, fy));

        // 3D pose via libapriltag pose estimator
        apriltag_detection_info_t info;
        info.det     = det;
        info.tagsize = m_tagSize;
        info.fx = fx; info.fy = fy;
        info.cx = cx_cam; info.cy = cy_cam;

        apriltag_pose_t pose;
        double err = estimate_tag_pose(&info, &pose);

        if (err >= 0 && pose.t && pose.R) {
            double tx_m = pose.t->data[0];
            double ty_m = pose.t->data[1];
            double tz_m = pose.t->data[2];

            tag.x = tx_m;
            tag.y = ty_m;
            tag.z = tz_m;
            tag.distance = std::sqrt(tx_m*tx_m + ty_m*ty_m + tz_m*tz_m);

            // Refined angles from 3D position
            tag.tx = rad2deg(std::atan2(tx_m, tz_m));
            tag.ty = -rad2deg(std::atan2(ty_m, tz_m));

            // Convert rotation matrix to rvec
            cv::Mat R_mat(3, 3, CV_64F);
            for (int r = 0; r < 3; r++)
                for (int c = 0; c < 3; c++)
                    R_mat.at<double>(r,c) = pose.R->data[r*3+c];

            cv::Mat rvec_mat;
            cv::Rodrigues(R_mat, rvec_mat);
            tag.rvec = cv::Vec3d(rvec_mat.at<double>(0), rvec_mat.at<double>(1), rvec_mat.at<double>(2));
            tag.tvec = cv::Vec3d(tx_m, ty_m, tz_m);
            tag.has_pose = true;

            auto [roll, pitch, yaw] = rvecToEulerDeg(tag.rvec);
            tag.roll  = roll;
            tag.pitch = pitch;
            tag.yaw   = yaw;

            matd_free(pose.R);
            matd_free(pose.t);
        }

        results.push_back(tag);
    }

    apriltag_detections_destroy(detections);
    return results;
}
