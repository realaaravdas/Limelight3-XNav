#pragma once
/**
 * XNav NT4 Publisher
 * Minimal NT4 client via raw WebSocket (RFC 6455) + msgpack encoding.
 * Publishes vision data and subscribes to robot inputs.
 */

#include <string>
#include <thread>
#include <mutex>
#include <atomic>
#include <unordered_map>
#include <vector>
#include <functional>
#include <optional>
#include "config_manager.hpp"
#include "apriltag_detector.hpp"
#include "pose_calculator.hpp"

struct NTInputs {
    double turretAngle{0.0};
    bool   turretEnabled{false};
    bool   matchMode{false};
};

class NTPublisher {
public:
    explicit NTPublisher(ConfigManager& cfg);
    ~NTPublisher();

    void start();
    void stop();
    bool isConnected() const { return m_state == State::PUBLISHING; }

    void publishFrame(const std::vector<TagDetection>& dets,
                      const std::optional<RobotPose>& robot_pose,
                      const std::optional<OffsetResult>& offset,
                      float fps, float latency_ms);
    void publishStatus(const std::string& status);
    NTInputs readInputs() const;

private:
    // ── Connection state ─────────────────────────────────────────────
    enum class State { DISCONNECTED, CONNECTING, CONNECTED, PUBLISHING };

    void connectLoop();
    bool doConnect();
    bool wsHandshake();
    void handleIncoming();
    void disconnect();

    // ── WebSocket framing ─────────────────────────────────────────────
    bool wsSendText(const std::string& payload);
    bool wsSendBinary(const std::vector<uint8_t>& data);
    bool wsSendFrame(bool binary, const uint8_t* data, size_t len);
    bool wsRecvFrame(bool& binary, std::vector<uint8_t>& payload);
    bool tcpRecvN(uint8_t* buf, size_t n);

    // ── NT4 protocol ──────────────────────────────────────────────────
    void announceTopics();
    void subscribeInputs();
    void processTextFrame(const std::string& text);
    void processBinaryFrame(const std::vector<uint8_t>& data);

    // ── msgpack encoding ──────────────────────────────────────────────
    static std::vector<uint8_t> packNull();
    static std::vector<uint8_t> packBool(bool v);
    static std::vector<uint8_t> packInt64(int64_t v);
    static std::vector<uint8_t> packDouble(double v);
    static std::vector<uint8_t> packString(const std::string& s);
    static std::vector<uint8_t> packDoubleArray(const std::vector<double>& arr);
    static std::vector<uint8_t> packIntArray(const std::vector<int64_t>& arr);
    // Encode a full value update: [topicId, timestamp_us, type, value]
    std::vector<uint8_t> encodeValue(int32_t topic_id, int64_t ts_us,
                                     int type, const std::vector<uint8_t>& val_bytes);

    // ── Publish helpers ───────────────────────────────────────────────
    int64_t nowUs() const;
    // Returns pubuid assigned for topic; 0 if not yet acknowledged
    int32_t getTopicId(const std::string& name) const;
    bool publishValue(const std::string& name, int type, const std::vector<uint8_t>& val);
    bool publishBool(const std::string& name, bool v);
    bool publishDouble(const std::string& name, double v);
    bool publishInt(const std::string& name, int64_t v);
    bool publishString(const std::string& name, const std::string& v);
    bool publishDoubleArray(const std::string& name, const std::vector<double>& v);
    bool publishIntArray(const std::string& name, const std::vector<int64_t>& v);

    // ── State ─────────────────────────────────────────────────────────
    ConfigManager& m_cfg;
    std::atomic<State> m_state{State::DISCONNECTED};
    std::atomic<bool>  m_running{false};
    std::thread m_thread;
    int m_sock{-1};
    mutable std::mutex m_sockMutex;

    // Topic registry: name -> pubuid
    struct TopicInfo {
        int32_t pubuid{0};
        std::string type;
        bool acknowledged{false};
    };
    mutable std::mutex m_topicMutex;
    std::unordered_map<std::string, TopicInfo> m_topics;
    int32_t m_nextPubuid{1};

    // Input values (written by incoming handler, read by main pipeline)
    mutable std::mutex m_inputMutex;
    NTInputs m_inputs;

    // Announce-once guard
    bool m_topicsAnnounced{false};
};
