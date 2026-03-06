cmake_minimum_required(VERSION 3.16)
project(xnav VERSION 1.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Build type
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(CMAKE_CXX_FLAGS_RELEASE "-O2 -DNDEBUG")
set(CMAKE_CXX_FLAGS_DEBUG "-g -O0")

# Dependencies
find_package(OpenCV 4 REQUIRED COMPONENTS core imgproc videoio calib3d imgcodecs)
find_package(PkgConfig REQUIRED)
pkg_check_modules(APRILTAG REQUIRED apriltag)
pkg_check_modules(GPIOD REQUIRED libgpiod)

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
    ${OpenCV_INCLUDE_DIRS}
    ${APRILTAG_INCLUDE_DIRS}
    ${GPIOD_INCLUDE_DIRS}
)

target_link_libraries(xnav
    ${OpenCV_LIBS}
    ${APRILTAG_LIBRARIES}
    ${GPIOD_LIBRARIES}
    pthread
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
