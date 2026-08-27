# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(vanguard_media_engine_library VERSION 0.0.1 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Modular Targets
add_library(vanguard_core STATIC "core/src/status.cpp")
target_include_directories(vanguard_core PUBLIC "core/include")

add_library(vanguard_graph STATIC "graph/src/graph.cpp")
target_include_directories(vanguard_graph PUBLIC "graph/include")
target_link_libraries(vanguard_graph PRIVATE vanguard_core)

add_library(vanguard_render_shared STATIC "render/shared/src/backend_capability.cpp")
target_include_directories(vanguard_render_shared PUBLIC "render/shared/include")
target_link_libraries(vanguard_render_shared PRIVATE vanguard_core)

add_library(vanguard_render_vulkan STATIC
    "render/vulkan/src/vulkan_backend.cpp"
    "render/vulkan/src/vulkan_frame_renderer.cpp"
    "render/vulkan/src/vulkan_shader_module.cpp"
    "render/vulkan/src/vulkan_surface_swapchain.cpp"
    "render/vulkan/src/vulkan_swapchain_render_targets.cpp"
    "render/vulkan/src/vulkan_hardware_buffer_imports.cpp"
    "render/vulkan/src/vulkan_hardware_buffer_image.cpp"
    "render/vulkan/src/vulkan_descriptor_resources.cpp"
    "render/vulkan/src/vulkan_graphics_pipeline.cpp"
    "render/vulkan/src/vulkan_graphics_command_recorder.cpp"
    "render/vulkan/src/vulkan_frame_synchronization.cpp"
)
target_include_directories(vanguard_render_vulkan PUBLIC "render/vulkan/include"
    # Phase 2K: private Vulkan src dir exposed so vulkan_surface_swapchain.cpp
    # can find vulkan_swapchain_render_targets.h without a broad include path.
    PRIVATE "render/vulkan/src"
)
target_link_libraries(vanguard_render_vulkan PRIVATE vanguard_render_shared vanguard_core)

add_library(vanguard_render_gles STATIC
    "render/gles/src/gles_backend.cpp"
    "render/gles/src/gles_hardware_buffer_imports.cpp"
    "render/gles/src/gles_texture_frame_renderer.cpp"
)
target_include_directories(vanguard_render_gles PUBLIC "render/gles/include")
target_link_libraries(vanguard_render_gles PRIVATE vanguard_render_shared vanguard_core)



# Final Shared Library (Preserving C ABI compatibility)
add_library(vanguard_media_engine SHARED
  "vanguard_media_engine.cpp"
)

set_target_properties(vanguard_media_engine PROPERTIES
  PUBLIC_HEADER vanguard_media_engine.h
  OUTPUT_NAME "vanguard_media_engine"
)

target_compile_definitions(vanguard_media_engine PUBLIC DART_SHARED_LIB)

if (ANDROID)
  target_sources(vanguard_media_engine PRIVATE
    "platform/android/src/jni_bridge.cpp"
    "platform/android/src/android_backend_probe.cpp"
    "platform/android/src/android_phase4a_decoder_smoke_jni.cpp"
    "platform/android/src/android_phase4b1_texture_playback_jni.cpp"
    "platform/android/src/android_phase5_encoder_smoke_jni.cpp"
    "platform/android/src/android_gles_backend_smoke_jni.cpp"
    "platform/android/src/android_gles_import_smoke_jni.cpp"
    "platform/android/src/android_gles_render_frame_smoke_jni.cpp"
    "platform/android/src/android_gles_read_pixels_smoke_jni.cpp"
    "platform/android/src/android_gles_render_frame_content_smoke_jni.cpp"
  )
  target_include_directories(vanguard_media_engine PRIVATE "platform/android/include")

  # Support Android 15 16 KB page size
  target_link_options(vanguard_media_engine PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384"
  )
  # Link modular targets and Android native libraries
  target_link_libraries(vanguard_media_engine
    PRIVATE
    vanguard_core
    vanguard_graph
    vanguard_render_shared
    vanguard_render_vulkan
    vanguard_render_gles
    android
    log
    GLESv3
    EGL
    mediandk
    vulkan
  )
endif()
