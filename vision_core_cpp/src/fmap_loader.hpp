#pragma once
/**
 * XNav FMap Loader
 * Parses WPILib .fmap (field map) JSON files.
 */

#include <string>
#include <unordered_map>
#include <optional>
#include "json.hpp"

using json = nlohmann::json;

struct TagPose {
    int id{0};
    double x{0.0}, y{0.0}, z{0.0};  // field-centric meters
    double qw{1.0}, qx{0.0}, qy{0.0}, qz{0.0};  // quaternion
    double roll{0.0}, pitch{0.0}, yaw{0.0};  // derived Euler (degrees)
};

struct FieldMap {
    double length{0.0};
    double width{0.0};
    std::unordered_map<int, TagPose> tags;
};

std::optional<FieldMap> loadFmap(const std::string& path);
