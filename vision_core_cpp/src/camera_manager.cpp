#include "camera_manager.hpp"

#include <syslog.h>
#include <chrono>
#include <thread>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/videoio.hpp>

// V4L2 auto-exposure control values (CAP_PROP_AUTO_EXPOSURE)
static constexpr double V4L2_EXPOSURE_MANUAL = 1.0;
static constexpr double V4L2_EXPOSURE_AUTO   = 3.0;

CameraManager::CameraManager(ConfigManager& cfg)
    : m_cfg(cfg)
{
    m_fpsT0 = std::chrono::steady_clock::now();
}

CameraManager::~CameraManager() {
    stop();
}

void CameraManager::start() {
    m_running = true;
    m_thread = std::thread(&CameraManager::captureLoop, this);
    syslog(LOG_INFO, "Camera manager started");
}

void CameraManager::stop() {
    m_running = false;
    if (m_thread.joinable()) {
        m_thread.join();
    }
    if (m_cap.isOpened()) {
        m_cap.release();
    }
    syslog(LOG_INFO, "Camera manager stopped");
}

void CameraManager::restart() {
    stop();
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    start();
}

void CameraManager::registerFrameCallback(FrameCallback cb) {
    m_callbacks.push_back(std::move(cb));
}

bool CameraManager::getFrame(cv::Mat& frame, cv::Mat& gray, double& timestamp) const {
    std::lock_guard<std::mutex> lock(m_frameLock);
    if (m_latestFrame.empty()) return false;
    frame = m_latestFrame.clone();
    gray = m_latestGray.clone();
    timestamp = m_frameTime;
    return true;
}

std::optional<std::vector<uint8_t>> CameraManager::getJpegFrame(int quality) const {
    std::lock_guard<std::mutex> lock(m_frameLock);
    if (m_latestFrame.empty()) return std::nullopt;
    cv::Mat frame = m_latestFrame.clone();

    std::vector<uint8_t> buf;
    std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, quality};
    if (cv::imencode(".jpg", frame, buf, params)) {
        return buf;
    }
    return std::nullopt;
}

void CameraManager::applySettings() {
    if (!m_cap.isOpened()) return;
    auto cam = m_cfg.getSection("camera");

    bool auto_exp = cam.value("auto_exposure", false);
    // V4L2: 1 = manual, 3 = auto
    m_cap.set(cv::CAP_PROP_AUTO_EXPOSURE, auto_exp ? V4L2_EXPOSURE_AUTO : V4L2_EXPOSURE_MANUAL);
    if (!auto_exp) {
        m_cap.set(cv::CAP_PROP_EXPOSURE, cam.value("exposure", 100));
    }
    m_cap.set(cv::CAP_PROP_GAIN,       cam.value("gain", 50));
    m_cap.set(cv::CAP_PROP_BRIGHTNESS, cam.value("brightness", 50));
    m_cap.set(cv::CAP_PROP_CONTRAST,   cam.value("contrast", 50));
    syslog(LOG_INFO, "Camera settings applied");
}

bool CameraManager::openCamera() {
    auto cam = m_cfg.getSection("camera");
    std::string device = cam.value("device", "/dev/video0");
    int width  = cam.value("width",  1280);
    int height = cam.value("height", 720);
    int fps    = cam.value("fps",    90);

    if (m_cap.isOpened()) m_cap.release();

    m_cap.open(device, cv::CAP_V4L2);
    if (!m_cap.isOpened()) {
        // Fallback: try by index 0
        m_cap.open(0, cv::CAP_V4L2);
    }
    if (!m_cap.isOpened()) {
        syslog(LOG_ERR, "Failed to open camera: %s", device.c_str());
        return false;
    }

    m_cap.set(cv::CAP_PROP_FOURCC, cv::VideoWriter::fourcc('M','J','P','G'));
    m_cap.set(cv::CAP_PROP_FRAME_WIDTH,  width);
    m_cap.set(cv::CAP_PROP_FRAME_HEIGHT, height);
    m_cap.set(cv::CAP_PROP_FPS,          fps);
    m_cap.set(cv::CAP_PROP_BUFFERSIZE,   1);

    applySettings();
    syslog(LOG_INFO, "Camera opened: %s %dx%d @%dfps", device.c_str(), width, height, fps);
    return true;
}

void CameraManager::captureLoop() {
    m_fpsT0 = std::chrono::steady_clock::now();
    m_frameCount = 0;

    while (m_running) {
        if (!m_cap.isOpened()) {
            if (!openCamera()) {
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }
        }

        cv::Mat frame;
        if (!m_cap.read(frame) || frame.empty()) {
            syslog(LOG_WARNING, "Camera read failed, retrying...");
            m_cap.release();
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }

        double ts = std::chrono::duration<double>(
            std::chrono::steady_clock::now().time_since_epoch()).count();

        cv::Mat gray;
        cv::cvtColor(frame, gray, cv::COLOR_BGR2GRAY);

        {
            std::lock_guard<std::mutex> lock(m_frameLock);
            m_latestFrame = frame;
            m_latestGray  = gray;
            m_frameTime   = ts;
        }

        // FPS calculation
        m_frameCount++;
        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - m_fpsT0).count();
        if (elapsed >= 1.0) {
            m_fps = static_cast<float>(m_frameCount / elapsed);
            m_frameCount = 0;
            m_fpsT0 = now;
        }

        // Fire callbacks
        for (auto& cb : m_callbacks) {
            cb(frame, gray, ts);
        }
    }
}
