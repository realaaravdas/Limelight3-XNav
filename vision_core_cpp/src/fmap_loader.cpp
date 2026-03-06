#include "fmap_loader.hpp"

#include <fstream>
#include <cmath>
#include <syslog.h>
#include <filesystem>

namespace fs = std::filesystem;

static std::tuple<double,double,double> quatToEuler(double w, double x, double y, double z) {
    // Roll (x-axis)
    double sinr = 2.0 * (w*x + y*z);
    double cosr = 1.0 - 2.0*(x*x + y*y);
    double roll = std::atan2(sinr, cosr);

    // Pitch (y-axis)
    double sinp = 2.0 * (w*y - z*x);
    double pitch = std::abs(sinp) >= 1.0
                 ? std::copysign(M_PI/2.0, sinp)
                 : std::asin(sinp);

    // Yaw (z-axis)
    double siny = 2.0 * (w*z + x*y);
    double cosy = 1.0 - 2.0*(y*y + z*z);
    double yaw = std::atan2(siny, cosy);

    const double r2d = 180.0 / M_PI;
    return {roll*r2d, pitch*r2d, yaw*r2d};
}

std::optional<FieldMap> loadFmap(const std::string& path) {
    if (!fs::exists(path)) {
        syslog(LOG_WARNING, "FMap file not found: %s", path.c_str());
        return std::nullopt;
    }

    json data;
    try {
        std::ifstream f(path);
        data = json::parse(f);
    } catch (const std::exception& e) {
        syslog(LOG_ERR, "Failed to parse fmap %s: %s", path.c_str(), e.what());
        return std::nullopt;
    }

    FieldMap fm;
    if (data.contains("field")) {
        auto& field = data["field"];
        fm.length = field.value("length", 0.0);
        fm.width  = field.value("width",  0.0);
    }

    // Support both "tags" and "fiducials" keys
    json tags_data = json::array();
    if (data.contains("tags"))      tags_data = data["tags"];
    else if (data.contains("fiducials")) tags_data = data["fiducials"];

    for (auto& tag_data : tags_data) {
        int tag_id = -1;
        if (tag_data.contains("ID"))         tag_id = tag_data["ID"].get<int>();
        else if (tag_data.contains("id"))    tag_id = tag_data["id"].get<int>();
        else if (tag_data.contains("fiducialId")) tag_id = tag_data["fiducialId"].get<int>();
        if (tag_id < 0) continue;

        auto& pose = tag_data["pose"];
        auto& trans = pose["translation"];
        auto& rot   = pose["rotation"];
        auto& quat  = rot["quaternion"];

        TagPose tp;
        tp.id = tag_id;
        tp.x  = trans.value("x", 0.0);
        tp.y  = trans.value("y", 0.0);
        tp.z  = trans.value("z", 0.0);
        tp.qw = quat.value("W", 1.0);
        tp.qx = quat.value("X", 0.0);
        tp.qy = quat.value("Y", 0.0);
        tp.qz = quat.value("Z", 0.0);

        auto [roll, pitch, yaw] = quatToEuler(tp.qw, tp.qx, tp.qy, tp.qz);
        tp.roll = roll; tp.pitch = pitch; tp.yaw = yaw;

        fm.tags[tag_id] = tp;
    }

    syslog(LOG_INFO, "Loaded fmap with %zu tags (field %.1fx%.1fm)",
           fm.tags.size(), fm.length, fm.width);
    return fm;
}
