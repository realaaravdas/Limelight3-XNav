cmake_minimum_required(VERSION 3.16)
project(xnav VERSION 1.2.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Build type
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(CMAKE_CXX_FLAGS_RELEASE "-O2 -DNDEBUG")
set(CMAKE_CXX_FLAGS_DEBUG "-g -O0")

# ── Dependencies via pkg-config ───────────────────────────────────────────────
# Using pkg-config for all deps makes cross-compilation work correctly:
# when PKG_CONFIG_SYSROOT_DIR is set the sysroot is automatically prepended
# to all include/library paths, so the cross-compiler points at the ARM64
# rootfs headers instead of the host headers.
find_package(PkgConfig REQUIRED)
pkg_check_modules(OPENCV   REQUIRED IMPORTED_TARGET opencv4)
pkg_check_modules(APRILTAG REQUIRED IMPORTED_TARGET apriltag)
pkg_check_modules(GPIOD    REQUIRED IMPORTED_TARGET libgpiod)

# Source files
set(SOURCES
    src/main.cpp
    src/config_manager.cpp
    src/camera_manager.cpp
    src/apriltag_detector.cpp
    src/pose_calculator.cpp
    src/fmap_loader.cpp
    src/nt_publisher.cpp
    src/lights_manager.cpp
    src/thermal_manager.cpp
    src/calibration_manager.cpp
    src/web_server.cpp
)

add_executable(xnav ${SOURCES})

target_include_directories(xnav PRIVATE
    src/
    third_party/
)

target_link_libraries(xnav
    PkgConfig::OPENCV
    PkgConfig::APRILTAG
    PkgConfig::GPIOD
    pthread
    lapack
    blas
)

# cpp-httplib: HTTP only (no SSL needed)
target_compile_definitions(xnav PRIVATE
    CPPHTTPLIB_NO_EXCEPTIONS
    CPPHTTPLIB_THREAD_POOL_COUNT=8
)

# Warnings
target_compile_options(xnav PRIVATE -Wall -Wextra -Wno-unused-parameter)

# Install
include(GNUInstallDirs)
install(TARGETS xnav DESTINATION /opt/xnav/bin)
