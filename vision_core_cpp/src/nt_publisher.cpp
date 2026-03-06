#include "nt_publisher.hpp"

#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <cstring>
#include <cstdint>
#include <cstdio>
#include <cerrno>
#include <chrono>
#include <syslog.h>
#include <random>
#include <iomanip>
#include <sstream>
#include <algorithm>
#include "json.hpp"

using json = nlohmann::json;

// ── NT4 data type constants ───────────────────────────────────────────────
static constexpr int NT_TYPE_BOOL    = 0;
static constexpr int NT_TYPE_DOUBLE  = 1;
static constexpr int NT_TYPE_INT     = 2;
static constexpr int NT_TYPE_FLOAT   = 3;
static constexpr int NT_TYPE_STRING  = 4;
static constexpr int NT_TYPE_BOOL_ARR   = 16;
static constexpr int NT_TYPE_DOUBLE_ARR = 17;
static constexpr int NT_TYPE_INT_ARR    = 18;

// ── Base64 encoding for WebSocket handshake ────────────────────────────────
static const char* B64_CHARS =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static std::string base64Encode(const uint8_t* data, size_t len) {
    std::string out;
    out.reserve(((len + 2) / 3) * 4);
    for (size_t i = 0; i < len; i += 3) {
        uint32_t b = (data[i] << 16);
        if (i+1 < len) b |= (data[i+1] << 8);
        if (i+2 < len) b |= data[i+2];
        out += B64_CHARS[(b >> 18) & 0x3F];
        out += B64_CHARS[(b >> 12) & 0x3F];
        out += (i+1 < len) ? B64_CHARS[(b >> 6) & 0x3F] : '=';
        out += (i+2 < len) ? B64_CHARS[b & 0x3F] : '=';
    }
    return out;
}

// ── msgpack helpers ────────────────────────────────────────────────────────
static void appendU16BE(std::vector<uint8_t>& v, uint16_t x) {
    v.push_back(x >> 8); v.push_back(x & 0xFF);
}
static void appendU32BE(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back((x>>24)&0xFF); v.push_back((x>>16)&0xFF);
    v.push_back((x>>8)&0xFF);  v.push_back(x&0xFF);
}
static void appendU64BE(std::vector<uint8_t>& v, uint64_t x) {
    for (int s = 56; s >= 0; s -= 8) v.push_back((x>>s)&0xFF);
}

std::vector<uint8_t> NTPublisher::packNull() { return {0xC0}; }
std::vector<uint8_t> NTPublisher::packBool(bool val) { return {val ? uint8_t(0xC3) : uint8_t(0xC2)}; }

std::vector<uint8_t> NTPublisher::packInt64(int64_t val) {
    std::vector<uint8_t> v; v.reserve(9);
    v.push_back(0xD3);
    appendU64BE(v, static_cast<uint64_t>(val));
    return v;
}

std::vector<uint8_t> NTPublisher::packDouble(double val) {
    std::vector<uint8_t> v; v.reserve(9);
    v.push_back(0xCB);
    uint64_t bits;
    memcpy(&bits, &val, 8);
    appendU64BE(v, bits);
    return v;
}

std::vector<uint8_t> NTPublisher::packString(const std::string& s) {
    std::vector<uint8_t> v;
    size_t len = s.size();
    if (len <= 31) {
        v.push_back(static_cast<uint8_t>(0xA0 | len));
    } else if (len <= 0xFFFF) {
        v.push_back(0xDA);
        appendU16BE(v, static_cast<uint16_t>(len));
    } else {
        v.push_back(0xDB);
        appendU32BE(v, static_cast<uint32_t>(len));
    }
    v.insert(v.end(), s.begin(), s.end());
    return v;
}

std::vector<uint8_t> NTPublisher::packDoubleArray(const std::vector<double>& arr) {
    // Encode as msgpack array of doubles
    std::vector<uint8_t> v;
    size_t n = arr.size();
    if (n <= 15) {
        v.push_back(static_cast<uint8_t>(0x90 | n));
    } else {
        v.push_back(0xDC);
        appendU16BE(v, static_cast<uint16_t>(n));
    }
    for (double d : arr) {
        auto dv = packDouble(d);
        v.insert(v.end(), dv.begin(), dv.end());
    }
    return v;
}

std::vector<uint8_t> NTPublisher::packIntArray(const std::vector<int64_t>& arr) {
    std::vector<uint8_t> v;
    size_t n = arr.size();
    if (n <= 15) {
        v.push_back(static_cast<uint8_t>(0x90 | n));
    } else {
        v.push_back(0xDC);
        appendU16BE(v, static_cast<uint16_t>(n));
    }
    for (int64_t i : arr) {
        auto iv = packInt64(i);
        v.insert(v.end(), iv.begin(), iv.end());
    }
    return v;
}

// Encode: [topicId, timestamp_us, type, value_bytes]
// Returns msgpack fixarray(4) containing the 4 elements
std::vector<uint8_t> NTPublisher::encodeValue(int32_t topic_id, int64_t ts_us,
                                               int type, const std::vector<uint8_t>& val_bytes) {
    std::vector<uint8_t> v;
    v.push_back(0x94);  // fixarray(4)
    auto tid = packInt64(topic_id);
    v.insert(v.end(), tid.begin(), tid.end());
    auto ts  = packInt64(ts_us);
    v.insert(v.end(), ts.begin(), ts.end());
    auto tp  = packInt64(type);
    v.insert(v.end(), tp.begin(), tp.end());
    v.insert(v.end(), val_bytes.begin(), val_bytes.end());
    return v;
}

// ── Constructor / Destructor ───────────────────────────────────────────────

NTPublisher::NTPublisher(ConfigManager& cfg) : m_cfg(cfg) {}

NTPublisher::~NTPublisher() { stop(); }

void NTPublisher::start() {
    m_running = true;
    m_thread = std::thread(&NTPublisher::connectLoop, this);
    syslog(LOG_INFO, "NT Publisher started");
}

void NTPublisher::stop() {
    m_running = false;
    disconnect();
    if (m_thread.joinable()) m_thread.join();
    syslog(LOG_INFO, "NT Publisher stopped");
}

// ── Connection loop ────────────────────────────────────────────────────────

void NTPublisher::connectLoop() {
    while (m_running) {
        m_state = State::CONNECTING;
        if (doConnect()) {
            m_state = State::CONNECTED;
            m_topicsAnnounced = false;
            announceTopics();
            subscribeInputs();
            m_state = State::PUBLISHING;
            syslog(LOG_INFO, "NT4 connected and publishing");
            handleIncoming();  // blocks until disconnected
        }
        disconnect();
        m_state = State::DISCONNECTED;
        if (m_running) {
            std::this_thread::sleep_for(std::chrono::seconds(3));
        }
    }
}

bool NTPublisher::doConnect() {
    auto net = m_cfg.getSection("network");
    std::string host = net.value("nt_server_ip", std::string(""));
    int team = net.value("team_number", 0);

    if (host.empty() && team > 0) {
        // Standard FRC address: 10.TE.AM.2
        int te = team / 100, am = team % 100;
        char buf[32];
        snprintf(buf, sizeof(buf), "10.%d.%d.2", te, am);
        host = buf;
    }
    if (host.empty()) {
        return false;
    }

    constexpr int PORT = 5810;
    struct addrinfo hints{}, *res = nullptr;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_INET;
    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%d", PORT);

    if (getaddrinfo(host.c_str(), port_str, &hints, &res) != 0) {
        syslog(LOG_DEBUG, "NT4: DNS lookup failed for %s", host.c_str());
        return false;
    }

    int s = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (s < 0) { freeaddrinfo(res); return false; }

    // Non-blocking connect with timeout
    struct timeval tv{3, 0};
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    if (connect(s, res->ai_addr, res->ai_addrlen) < 0) {
        freeaddrinfo(res);
        ::close(s);
        return false;
    }
    freeaddrinfo(res);

    {
        std::lock_guard<std::mutex> lock(m_sockMutex);
        m_sock = s;
    }

    // WebSocket upgrade handshake
    if (!wsHandshake()) {
        disconnect();
        return false;
    }
    syslog(LOG_INFO, "NT4: WebSocket connected to %s:%d", host.c_str(), PORT);
    return true;
}

bool NTPublisher::wsHandshake() {
    // Generate random key
    uint8_t key_bytes[16];
    std::mt19937 rng(std::chrono::steady_clock::now().time_since_epoch().count());
    std::uniform_int_distribution<uint32_t> dist(0, 255);
    for (auto& b : key_bytes) b = dist(rng);
    std::string ws_key = base64Encode(key_bytes, 16);

    auto net = m_cfg.getSection("network");
    std::string host = net.value("nt_server_ip", std::string("roborio"));
    if (host.empty()) host = "roborio";

    std::string req =
        "GET /nt/xnav HTTP/1.1\r\n"
        "Host: " + host + ":5810\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: " + ws_key + "\r\n"
        "Sec-WebSocket-Protocol: v4.1.networktables.first.wpi.edu\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n";

    std::lock_guard<std::mutex> lock(m_sockMutex);
    ssize_t sent = ::send(m_sock, req.c_str(), req.size(), 0);
    if (sent != (ssize_t)req.size()) return false;

    // Read response until \r\n\r\n
    std::string resp;
    resp.reserve(512);
    char c;
    while (resp.size() < 4096) {
        ssize_t n = ::recv(m_sock, &c, 1, 0);
        if (n <= 0) return false;
        resp += c;
        if (resp.size() >= 4 &&
            resp[resp.size()-4] == '\r' && resp[resp.size()-3] == '\n' &&
            resp[resp.size()-2] == '\r' && resp[resp.size()-1] == '\n') break;
    }

    return resp.find("101") != std::string::npos;
}

void NTPublisher::disconnect() {
    std::lock_guard<std::mutex> lock(m_sockMutex);
    if (m_sock >= 0) {
        ::shutdown(m_sock, SHUT_RDWR);
        ::close(m_sock);
        m_sock = -1;
    }
}

// ── WebSocket framing ──────────────────────────────────────────────────────

bool NTPublisher::wsSendFrame(bool binary, const uint8_t* data, size_t len) {
    std::lock_guard<std::mutex> lock(m_sockMutex);
    if (m_sock < 0) return false;

    std::vector<uint8_t> frame;
    frame.reserve(len + 14);
    frame.push_back(binary ? 0x82 : 0x81);  // FIN + opcode

    uint8_t mask[4];
    std::mt19937 rng(std::chrono::steady_clock::now().time_since_epoch().count());
    std::uniform_int_distribution<uint32_t> dist(0,255);
    for (auto& b : mask) b = dist(rng);

    if (len <= 125) {
        frame.push_back(0x80 | static_cast<uint8_t>(len));
    } else if (len <= 65535) {
        frame.push_back(0x80 | 126);
        frame.push_back((len >> 8) & 0xFF);
        frame.push_back(len & 0xFF);
    } else {
        frame.push_back(0x80 | 127);
        for (int i = 7; i >= 0; i--) frame.push_back((len >> (i*8)) & 0xFF);
    }
    frame.insert(frame.end(), mask, mask+4);
    for (size_t i = 0; i < len; i++) {
        frame.push_back(data[i] ^ mask[i % 4]);
    }

    return ::send(m_sock, frame.data(), frame.size(), MSG_NOSIGNAL) == (ssize_t)frame.size();
}

bool NTPublisher::wsSendText(const std::string& payload) {
    return wsSendFrame(false, reinterpret_cast<const uint8_t*>(payload.c_str()), payload.size());
}

bool NTPublisher::wsSendBinary(const std::vector<uint8_t>& data) {
    return wsSendFrame(true, data.data(), data.size());
}

bool NTPublisher::tcpRecvN(uint8_t* buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = ::recv(m_sock, buf + got, n - got, 0);
        if (r <= 0) return false;
        got += r;
    }
    return true;
}

bool NTPublisher::wsRecvFrame(bool& binary, std::vector<uint8_t>& payload) {
    uint8_t hdr[2];
    if (!tcpRecvN(hdr, 2)) return false;

    uint8_t opcode = hdr[0] & 0x0F;
    bool masked    = (hdr[1] & 0x80) != 0;
    uint64_t length = hdr[1] & 0x7F;

    if (length == 126) {
        uint8_t ext[2]; if (!tcpRecvN(ext, 2)) return false;
        length = (ext[0]<<8) | ext[1];
    } else if (length == 127) {
        uint8_t ext[8]; if (!tcpRecvN(ext, 8)) return false;
        length = 0;
        for (int i = 0; i < 8; i++) length = (length<<8)|ext[i];
    }

    uint8_t mask[4] = {};
    if (masked && !tcpRecvN(mask, 4)) return false;

    payload.resize(length);
    if (length > 0 && !tcpRecvN(payload.data(), length)) return false;

    if (masked) {
        for (size_t i = 0; i < length; i++) payload[i] ^= mask[i%4];
    }

    binary = (opcode == 2);
    if (opcode == 8) return false;  // Close frame
    return true;
}

// ── NT4 topic management ───────────────────────────────────────────────────

struct TopicDef {
    std::string name;
    std::string type;
};

static const std::vector<TopicDef> PUBLISH_TOPICS = {
    {"/XNav/status",          "string"},
    {"/XNav/fps",             "double"},
    {"/XNav/latencyMs",       "double"},
    {"/XNav/hasTarget",       "boolean"},
    {"/XNav/numTargets",      "int"},
    {"/XNav/tagIds",          "int[]"},
    {"/XNav/primaryTagId",    "int"},
    {"/XNav/robotPose",       "double[]"},
    {"/XNav/offsetPoint/valid", "boolean"},
    {"/XNav/offsetPoint/x",   "double"},
    {"/XNav/offsetPoint/y",   "double"},
    {"/XNav/offsetPoint/z",   "double"},
    {"/XNav/offsetPoint/directDistance", "double"},
    {"/XNav/offsetPoint/tx",  "double"},
    {"/XNav/offsetPoint/ty",  "double"},
};

void NTPublisher::announceTopics() {
    std::lock_guard<std::mutex> lock(m_topicMutex);
    m_topics.clear();
    m_nextPubuid = 1;

    json announce_array = json::array();
    for (const auto& td : PUBLISH_TOPICS) {
        int32_t uid = m_nextPubuid++;
        m_topics[td.name] = {uid, td.type, true};
        announce_array.push_back({
            {"method", "publish"},
            {"params", {
                {"name", td.name},
                {"type", td.type},
                {"pubuid", uid}
            }}
        });
    }

    // Per-tag topics are announced dynamically as tags are detected
    wsSendText(announce_array.dump());
}

void NTPublisher::subscribeInputs() {
    json sub = json::array();
    sub.push_back({
        {"method", "subscribe"},
        {"params", {
            {"topics", {{{"name", "/XNav/input"}, {"prefix", true}}}},
            {"subuid", 100},
            {"options", {{"periodic", 0.1}}}
        }}
    });
    wsSendText(sub.dump());
}

void NTPublisher::handleIncoming() {
    while (m_running && m_state == State::PUBLISHING) {
        bool binary;
        std::vector<uint8_t> payload;
        if (!wsRecvFrame(binary, payload)) break;

        if (!binary && !payload.empty()) {
            std::string text(payload.begin(), payload.end());
            processTextFrame(text);
        }
        // Binary frames carry server-to-client value updates
    }
}

void NTPublisher::processTextFrame(const std::string& text) {
    try {
        auto j = json::parse(text);
        if (!j.is_array()) return;
        for (auto& msg : j) {
            std::string method = msg.value("method", "");
            if (method == "announce") {
                // Server acknowledged a topic; record topicId
                auto& p = msg["params"];
                std::string name = p.value("name", "");
                // server-assigned topicId for incoming value updates (future use)
                // For input topics, store the server-assigned id
                // (we don't need to track these for publishing)
            } else if (method == "properties") {
                // ignore
            }
        }
    } catch (...) {}
}

// ── Timestamp ─────────────────────────────────────────────────────────────

int64_t NTPublisher::nowUs() const {
    using namespace std::chrono;
    return duration_cast<microseconds>(system_clock::now().time_since_epoch()).count();
}

// ── Publish helpers ────────────────────────────────────────────────────────

int32_t NTPublisher::getTopicId(const std::string& name) const {
    std::lock_guard<std::mutex> lock(m_topicMutex);
    auto it = m_topics.find(name);
    if (it != m_topics.end()) return it->second.pubuid;
    return -1;
}

bool NTPublisher::publishValue(const std::string& name, int type,
                                const std::vector<uint8_t>& val) {
    if (m_state != State::PUBLISHING) return false;

    int32_t tid = getTopicId(name);
    if (tid < 0) {
        // Dynamically register unknown topic (per-tag topics)
        std::lock_guard<std::mutex> lock(m_topicMutex);
        tid = m_nextPubuid++;
        std::string type_str;
        switch (type) {
            case NT_TYPE_BOOL:       type_str = "boolean"; break;
            case NT_TYPE_DOUBLE:     type_str = "double"; break;
            case NT_TYPE_INT:        type_str = "int"; break;
            case NT_TYPE_STRING:     type_str = "string"; break;
            case NT_TYPE_DOUBLE_ARR: type_str = "double[]"; break;
            case NT_TYPE_INT_ARR:    type_str = "int[]"; break;
            default: type_str = "double"; break;
        }
        m_topics[name] = {tid, type_str, true};
        json ann = json::array();
        ann.push_back({{"method","publish"},{"params",{{"name",name},{"type",type_str},{"pubuid",tid}}}});
        wsSendText(ann.dump());
    }

    auto frame = encodeValue(tid, nowUs(), type, val);
    return wsSendBinary(frame);
}

bool NTPublisher::publishBool(const std::string& name, bool v) {
    return publishValue(name, NT_TYPE_BOOL, packBool(v));
}
bool NTPublisher::publishDouble(const std::string& name, double v) {
    return publishValue(name, NT_TYPE_DOUBLE, packDouble(v));
}
bool NTPublisher::publishInt(const std::string& name, int64_t v) {
    return publishValue(name, NT_TYPE_INT, packInt64(v));
}
bool NTPublisher::publishString(const std::string& name, const std::string& v) {
    return publishValue(name, NT_TYPE_STRING, packString(v));
}
bool NTPublisher::publishDoubleArray(const std::string& name, const std::vector<double>& v) {
    return publishValue(name, NT_TYPE_DOUBLE_ARR, packDoubleArray(v));
}
bool NTPublisher::publishIntArray(const std::string& name, const std::vector<int64_t>& v) {
    return publishValue(name, NT_TYPE_INT_ARR, packIntArray(v));
}

// ── Public API ─────────────────────────────────────────────────────────────

void NTPublisher::publishStatus(const std::string& status) {
    publishString("/XNav/status", status);
}

NTInputs NTPublisher::readInputs() const {
    std::lock_guard<std::mutex> lock(m_inputMutex);
    return m_inputs;
}

void NTPublisher::publishFrame(const std::vector<TagDetection>& dets,
                                const std::optional<RobotPose>& robot_pose,
                                const std::optional<OffsetResult>& offset,
                                float fps, float latency_ms)
{
    if (m_state != State::PUBLISHING) return;

    publishBool("/XNav/hasTarget", !dets.empty());
    publishInt("/XNav/numTargets", (int64_t)dets.size());
    publishDouble("/XNav/fps", fps);
    publishDouble("/XNav/latencyMs", latency_ms);

    std::vector<int64_t> tag_ids;
    for (const auto& d : dets) tag_ids.push_back(d.id);
    publishIntArray("/XNav/tagIds", tag_ids);

    if (!dets.empty()) {
        const auto& primary = *std::min_element(dets.begin(), dets.end(),
            [](const TagDetection& a, const TagDetection& b){ return a.distance < b.distance; });
        publishInt("/XNav/primaryTagId", primary.id);
    } else {
        publishInt("/XNav/primaryTagId", -1);
    }

    // Per-tag topics
    for (const auto& tag : dets) {
        std::string pfx = "/XNav/targets/" + std::to_string(tag.id);
        publishDouble(pfx+"/tx", tag.tx);
        publishDouble(pfx+"/ty", tag.ty);
        publishDouble(pfx+"/x", tag.x);
        publishDouble(pfx+"/y", tag.y);
        publishDouble(pfx+"/z", tag.z);
        publishDouble(pfx+"/distance", tag.distance);
        publishDouble(pfx+"/yaw", tag.yaw);
        publishDouble(pfx+"/pitch", tag.pitch);
        publishDouble(pfx+"/roll", tag.roll);
    }

    // Robot pose
    if (robot_pose && robot_pose->valid) {
        publishDoubleArray("/XNav/robotPose", {
            robot_pose->x, robot_pose->y, robot_pose->z,
            robot_pose->roll, robot_pose->pitch, robot_pose->yaw
        });
    } else {
        publishDoubleArray("/XNav/robotPose", {0,0,0,0,0,0});
    }

    // Offset point
    if (offset && offset->valid) {
        publishBool("/XNav/offsetPoint/valid", true);
        publishDouble("/XNav/offsetPoint/x", offset->x);
        publishDouble("/XNav/offsetPoint/y", offset->y);
        publishDouble("/XNav/offsetPoint/z", offset->z);
        publishDouble("/XNav/offsetPoint/directDistance", offset->directDistance);
        publishDouble("/XNav/offsetPoint/tx", offset->tx);
        publishDouble("/XNav/offsetPoint/ty", offset->ty);
    } else {
        publishBool("/XNav/offsetPoint/valid", false);
    }
}
