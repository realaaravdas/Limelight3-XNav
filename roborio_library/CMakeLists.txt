cmake_minimum_required(VERSION 3.16)
project(XNavLib VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Library ───────────────────────────────────────────────────────────────────
add_library(xnavlib STATIC
  src/XNavLib.cpp
)

target_include_directories(xnavlib
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)

# WPILib integration (set WPILIB_ROOT if not using standard FRC toolchain)
if(DEFINED WPILIB_ROOT OR DEFINED ENV{WPILIB_ROOT})
  set(WL_ROOT "${WPILIB_ROOT}$ENV{WPILIB_ROOT}")
  target_include_directories(xnavlib PRIVATE "${WL_ROOT}/include")
  target_link_directories(xnavlib PRIVATE "${WL_ROOT}/lib")
  target_link_libraries(xnavlib PRIVATE ntcore wpiutil)
  target_compile_definitions(xnavlib PUBLIC WPILIB_AVAILABLE)
else()
  message(WARNING "WPILIB_ROOT not set. XNavLib compiled without WPILib (stub mode). Set -DWPILIB_ROOT=/path/to/wpilib.")
endif()

# ── Examples ──────────────────────────────────────────────────────────────────
option(BUILD_EXAMPLES "Build example programs" OFF)
if(BUILD_EXAMPLES)
  add_subdirectory(examples)
endif()

# ── Install ───────────────────────────────────────────────────────────────────
include(GNUInstallDirs)
install(TARGETS xnavlib
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(FILES include/XNavLib.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
