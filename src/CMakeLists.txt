# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(vanguard_media_engine_library VERSION 0.0.1 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(vanguard_media_engine SHARED
  "vanguard_media_engine.cpp"
)

set_target_properties(vanguard_media_engine PROPERTIES
  PUBLIC_HEADER vanguard_media_engine.h
  OUTPUT_NAME "vanguard_media_engine"
)

target_compile_definitions(vanguard_media_engine PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(vanguard_media_engine PRIVATE "-Wl,-z,max-page-size=16384")
  # Link Android native libraries needed for GPU render pass
  target_link_libraries(vanguard_media_engine
    android
    log
    GLESv3
    EGL
    mediandk
  )
endif()
