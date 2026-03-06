#include "calibration_manager.hpp"

#include <syslog.h>
#include <fstream>
#include <filesystem>
#include <opencv2/calib3d.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>

namespace fs = std::filesystem;

CalibrationManager::CalibrationManager(ConfigManager& cfg) : m_cfg(cfg) {}

void CalibrationManager::startCollection(int target_frames) {
    std::lock_guard<std::mutex> lock(m_lock);
    m_frames.clear();
    m_collecting = true;
    m_progress   = 0;
    m_target     = target_frames;
    m_status     = "collecting";
    syslog(LOG_INFO, "Calibration collection started (target %d frames)", target_frames);
}

void CalibrationManager::stopCollection() {
    std::lock_guard<std::mutex> lock(m_lock);
    m_collecting = false;
    m_status = "stopped";
}

bool CalibrationManager::addFrame(const cv::Mat& gray) {
    {
        std::lock_guard<std::mutex> lock(m_lock);
        if (!m_collecting || m_progress >= m_target) return false;
    }

    auto cal = m_cfg.getSection("calibration");
    int rows  = cal.value("checkerboard_rows", 6);
    int cols  = cal.value("checkerboard_cols", 9);
    cv::Size pattern(cols, rows);

    int flags = cv::CALIB_CB_ADAPTIVE_THRESH | cv::CALIB_CB_NORMALIZE_IMAGE | cv::CALIB_CB_FAST_CHECK;
    std::vector<cv::Point2f> corners;
    bool found = cv::findChessboardCorners(gray, pattern, corners, flags);

    if (found) {
        // Refine corners
        cv::cornerSubPix(gray, corners, cv::Size(11,11), cv::Size(-1,-1),
            cv::TermCriteria(cv::TermCriteria::EPS + cv::TermCriteria::COUNT, 30, 0.001));

        std::lock_guard<std::mutex> lock(m_lock);
        if (m_collecting && m_progress < m_target) {
            m_frames.push_back(gray.clone());
            m_progress++;
            if (m_progress >= m_target) {
                m_collecting = false;
                m_status = "ready_to_calibrate";
            }
            return true;
        }
    }
    return false;
}

std::optional<std::vector<uint8_t>> CalibrationManager::getPreviewJpeg(const cv::Mat& gray) const {
    if (gray.empty()) return std::nullopt;
    auto cal = m_cfg.getSection("calibration");
    int rows = cal.value("checkerboard_rows", 6);
    int cols = cal.value("checkerboard_cols", 9);
    cv::Size pattern(cols, rows);

    cv::Mat preview;
    cv::cvtColor(gray, preview, cv::COLOR_GRAY2BGR);

    std::vector<cv::Point2f> corners;
    int flags = cv::CALIB_CB_ADAPTIVE_THRESH | cv::CALIB_CB_NORMALIZE_IMAGE | cv::CALIB_CB_FAST_CHECK;
    bool found = cv::findChessboardCorners(gray, pattern, corners, flags);
    if (found) {
        cv::drawChessboardCorners(preview, pattern, corners, found);
    }

    std::vector<uint8_t> buf;
    std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, 70};
    if (cv::imencode(".jpg", preview, buf, params)) return buf;
    return std::nullopt;
}

CalibrationStatus CalibrationManager::getStatus() const {
    std::lock_guard<std::mutex> lock(m_lock);
    return {m_collecting, m_progress, m_target, m_status, m_result.has_value()};
}

std::pair<bool, std::string> CalibrationManager::computeCalibration() {
    std::vector<cv::Mat> frames_copy;
    {
        std::lock_guard<std::mutex> lock(m_lock);
        frames_copy = m_frames;
        m_status = "computing";
    }

    if ((int)frames_copy.size() < 5) {
        std::lock_guard<std::mutex> lock(m_lock);
        m_status = "failed";
        return {false, "Need at least 5 frames, have " + std::to_string(frames_copy.size())};
    }

    auto cal = m_cfg.getSection("calibration");
    int rows = cal.value("checkerboard_rows", 6);
    int cols = cal.value("checkerboard_cols", 9);
    float square_size = cal.value("checkerboard_square_size", 0.025f);
    cv::Size pattern(cols, rows);

    // Build 3D object points
    std::vector<cv::Point3f> obj_pts;
    for (int r = 0; r < rows; r++)
        for (int c = 0; c < cols; c++)
            obj_pts.emplace_back(c * square_size, r * square_size, 0.0f);

    std::vector<std::vector<cv::Point3f>> object_points;
    std::vector<std::vector<cv::Point2f>> image_points;
    cv::Size img_size;

    int flags2d = cv::CALIB_CB_ADAPTIVE_THRESH | cv::CALIB_CB_NORMALIZE_IMAGE;
    for (const auto& gray : frames_copy) {
        std::vector<cv::Point2f> corners;
        bool found = cv::findChessboardCorners(gray, pattern, corners, flags2d);
        if (!found) continue;
        cv::cornerSubPix(gray, corners, cv::Size(11,11), cv::Size(-1,-1),
            cv::TermCriteria(cv::TermCriteria::EPS + cv::TermCriteria::COUNT, 30, 0.001));
        object_points.push_back(obj_pts);
        image_points.push_back(corners);
        img_size = gray.size();
    }

    if ((int)image_points.size() < 5) {
        std::lock_guard<std::mutex> lock(m_lock);
        m_status = "failed";
        return {false, "Not enough good frames for calibration"};
    }

    cv::Mat camera_matrix, dist_coeffs;
    std::vector<cv::Mat> rvecs, tvecs;
    double rms = cv::calibrateCamera(object_points, image_points, img_size,
                                      camera_matrix, dist_coeffs, rvecs, tvecs);

    CalibrationResult result;
    result.cameraMatrix = camera_matrix;
    result.distCoeffs   = dist_coeffs;
    result.rmsError     = rms;
    result.valid        = true;

    {
        std::lock_guard<std::mutex> lock(m_lock);
        m_result = result;
        m_status = "done";
    }

    // Save to file
    std::string cal_file = cal.value("calibration_file", std::string("/etc/xnav/calibration.json"));
    try {
        fs::create_directories(fs::path(cal_file).parent_path());

        // Build JSON
        json j;
        std::vector<std::vector<double>> mtx(3, std::vector<double>(3));
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++)
                mtx[r][c] = camera_matrix.at<double>(r,c);
        j["camera_matrix"] = mtx;

        std::vector<double> dist_vec;
        for (int i = 0; i < dist_coeffs.cols; i++)
            dist_vec.push_back(dist_coeffs.at<double>(0,i));
        j["dist_coeffs"]  = dist_vec;
        j["rms_error"]    = rms;
        j["image_width"]  = img_size.width;
        j["image_height"] = img_size.height;

        std::ofstream f(cal_file);
        f << j.dump(2);
        syslog(LOG_INFO, "Calibration saved to %s (rms=%.4f)", cal_file.c_str(), rms);
    } catch (const std::exception& e) {
        syslog(LOG_WARNING, "Could not save calibration: %s", e.what());
    }

    // Update detector with new calibration
    if (m_detector) {
        m_detector->setCalibration(camera_matrix, dist_coeffs);
    }

    return {true, "Calibration complete, RMS error = " + std::to_string(rms)};
}

std::optional<CalibrationResult> CalibrationManager::getResult() const {
    std::lock_guard<std::mutex> lock(m_lock);
    return m_result;
}

json CalibrationManager::getResultJson() const {
    std::lock_guard<std::mutex> lock(m_lock);
    if (!m_result) return json{{"has_result", false}};
    const auto& r = *m_result;
    json j;
    j["has_result"] = true;
    j["rms_error"]  = r.rmsError;
    std::vector<std::vector<double>> mtx(3, std::vector<double>(3));
    for (int row = 0; row < 3; row++)
        for (int col = 0; col < 3; col++)
            mtx[row][col] = r.cameraMatrix.at<double>(row,col);
    j["camera_matrix"] = mtx;
    std::vector<double> dist_vec;
    for (int i = 0; i < r.distCoeffs.cols; i++)
        dist_vec.push_back(r.distCoeffs.at<double>(0,i));
    j["dist_coeffs"] = dist_vec;
    return j;
}
