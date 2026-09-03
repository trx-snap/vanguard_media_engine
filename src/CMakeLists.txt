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

add_library(vanguard_sinks STATIC "sinks/src/passthrough_remux_sink_node.cpp")
target_include_directories(vanguard_sinks PUBLIC "sinks/include")
target_link_libraries(vanguard_sinks PRIVATE vanguard_graph vanguard_core)

add_library(vanguard_audio STATIC
    "audio/src/decoded_audio_pcm_source_node.cpp"
    "audio/src/audio_gain_envelope.cpp"
    "audio/src/audio_mix_bus_node.cpp"
    "audio/src/graph_audio_scheduler.cpp"
    "audio/src/audio_ring_buffer.cpp"
    "audio/src/ring_buffer_audio_sample_provider.cpp"
    "audio/src/audio_clock.cpp"
    "audio/src/clocked_audio_transport_coordinator.cpp"
    "audio/src/audio_decoder_ring_writer.cpp"
)
target_include_directories(vanguard_audio PUBLIC "audio/include")
target_link_libraries(vanguard_audio PRIVATE vanguard_graph vanguard_core)

add_library(vanguard_compositors STATIC
    "compositors/src/multi_cam_compositor_node.cpp"
    "compositors/src/vg_timeline_compositor_node.cpp"
)
target_include_directories(vanguard_compositors PUBLIC "compositors/include")
target_link_libraries(vanguard_compositors PRIVATE vanguard_graph vanguard_core)

add_library(vanguard_render_shared STATIC "render/shared/src/backend_capability.cpp")
target_include_directories(vanguard_render_shared PUBLIC "render/shared/include")
target_link_libraries(vanguard_render_shared PRIVATE vanguard_core)

add_library(vanguard_render_vulkan STATIC
    "render/vulkan/src/vulkan_backend.cpp"
    "render/vulkan/src/vulkan_frame_renderer.cpp"
    # P5-COMPOSITOR-TRANS: transition-only helpers (draw model, placement,
    # draw-list, blend pipeline) split out of vulkan_frame_renderer.cpp.
    "render/vulkan/src/vulkan_transition_frame_renderer.cpp"
    "render/vulkan/src/vulkan_shader_module.cpp"
    "render/vulkan/src/vulkan_surface_swapchain.cpp"
    "render/vulkan/src/vulkan_swapchain_render_targets.cpp"
    "render/vulkan/src/vulkan_hardware_buffer_imports.cpp"
    "render/vulkan/src/vulkan_hardware_buffer_image.cpp"
    "render/vulkan/src/vulkan_descriptor_resources.cpp"
    "render/vulkan/src/vulkan_graphics_pipeline.cpp"
    "render/vulkan/src/vulkan_graphics_command_recorder.cpp"
    "render/vulkan/src/vulkan_frame_synchronization.cpp"
    "render/vulkan/src/vulkan_timeline_transition_compositor.cpp"
    # P3-MULTICAM-NODE (SPATIAL-VULKAN-RENDER): private two-texture spatial
    # layout helper (opaque primary rect + opaque secondary rect, readback).
    "render/vulkan/src/vulkan_multicam_spatial_compositor.cpp"
    # P5-OVERLAYS-TRANS (VULKAN-RENDER): private multi-layer overlay helper
    # (inverse-UV push-constant placement, per-layer opacity in colour-matrix
    # row 3, fixed-function straight-alpha source-over blend, readback).
    "render/vulkan/src/vulkan_overlay_compositor.cpp"
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
    "render/gles/src/gles_two_texture_compositor.cpp"
    "render/gles/src/gles_multicam_spatial_compositor.cpp"
    "render/gles/src/gles_timeline_transition_compositor.cpp"
    # P5-OVERLAYS-TRANS (GLES-RENDER): private multi-layer overlay helper
    # (mat3 transform, per-layer opacity, source-over blend, state restore).
    "render/gles/src/gles_overlay_compositor.cpp"
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
    "platform/android/src/android_phase2_concurrent_decode_jni.cpp"
    "platform/android/src/android_phase3_camera_concurrent_ingest_jni.cpp"
    "platform/android/src/android_passthrough_remux_sink_jni.cpp"
    "platform/android/src/android_phase5_encoder_smoke_jni.cpp"
    "platform/android/src/android_vulkan_export_jni.cpp"
    "platform/android/src/android_gles_backend_smoke_jni.cpp"
    "platform/android/src/android_gles_import_smoke_jni.cpp"
    "platform/android/src/android_gles_render_frame_smoke_jni.cpp"
    "platform/android/src/android_gles_read_pixels_smoke_jni.cpp"
    "platform/android/src/android_gles_render_frame_content_smoke_jni.cpp"
    "platform/android/src/android_gles_render_frame_transform_mapping_smoke_jni.cpp"
    "platform/android/src/android_gles_acquire_fence_smoke_jni.cpp"
    "platform/android/src/android_gles_rgbx_render_frame_content_smoke_jni.cpp"
    "platform/android/src/android_gles_import_guard_smoke_jni.cpp"
    "platform/android/src/android_gles_ycbcr_import_guard_smoke_jni.cpp"
    "platform/android/src/android_gles_extension_capability_smoke_jni.cpp"
    "platform/android/src/android_gles_native_fence_fd_smoke_jni.cpp"
    "platform/android/src/android_gles_release_null_fence_smoke_jni.cpp"
    "platform/android/src/android_gles_render_fence_chain_smoke_jni.cpp"
    "platform/android/src/android_gles_acquire_fence_render_content_smoke_jni.cpp"
    "platform/android/src/android_gles_release_fence_production_smoke_jni.cpp"
    "platform/android/src/android_gles_external_texture_smoke_jni.cpp"
    "platform/android/src/android_gles_two_texture_compositor_smoke_jni.cpp"
    "platform/android/src/android_gles_mixed_texture_compositor_smoke_jni.cpp"
    "platform/android/src/android_gles_eval_render_smoke_jni.cpp"
    "platform/android/src/android_gles_texture_render_smoke_jni.cpp"
    "platform/android/src/android_gles_texture_composition_dag_smoke_jni.cpp"
    "platform/android/src/android_gles_decoded_oes_smoke_jni.cpp"
    "platform/android/src/android_phase2_audio_decode_bridge_jni.cpp"
    "platform/android/src/android_phase4_audio_mix_bus_jni.cpp"
    "platform/android/src/android_phase4_audio_mixbus_timeline_jni.cpp"
    "platform/android/src/android_phase4_audio_scheduler_envelope_jni.cpp"
    "platform/android/src/android_phase4_audio_graph_export_session_jni.cpp"
    "platform/android/src/android_phase4_audio_graph_topology_jni.cpp"
    "platform/android/src/android_phase4_audio_graph_transport_jni.cpp"
    "platform/android/src/android_phase4_audio_ring_buffer_transport_jni.cpp"
    "platform/android/src/android_phase4_audio_clock_jni.cpp"
    "platform/android/src/android_phase4_audio_transport_coordinator_jni.cpp"
    "platform/android/src/android_phase4_audio_decoder_ring_writer_jni.cpp"
    "platform/android/src/android_phase4_audio_pipeline_integration_jni.cpp"
    "platform/android/src/android_phase4_audio_decoder_ring_ingest_jni.cpp"
    "platform/android/src/android_phase4_audio_graph_pipeline_session_jni.cpp"
    "platform/android/src/android_phase4_multi_source_graph_pipeline_session_jni.cpp"
    "platform/android/src/android_phase4_node_owned_source_graph_pipeline_session_jni.cpp"
    "platform/android/src/android_phase4_multi_source_node_owned_pipeline_session_jni.cpp"
    "platform/android/src/android_phase4_aaudio_node_owned_sink_session_jni.cpp"
    "platform/android/src/android_phase4_async_runtime_queue_scheduler_session_jni.cpp"
    "platform/android/src/android_phase4_async_runtime_queue_realtime_clock_jni.cpp"
    "platform/android/src/android_phase4_async_runtime_queue_multi_source_realtime_clock_jni.cpp"
    # P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE (Y1): production realtime
    # playback graph transport session (own handle registry, non-diagnostic).
    "platform/android/src/android_phase4_realtime_playback_graph_session_jni.cpp"
    "platform/android/src/android_phase3_multicam_compositor_jni.cpp"
    "platform/android/src/android_phase3_multicam_spatial_render_jni.cpp"
    "platform/android/src/android_phase3_multicam_spatial_vulkan_render_jni.cpp"
    "platform/android/src/android_phase5_timeline_compositor_jni.cpp"
    "platform/android/src/android_phase5_timeline_transition_gles_render_jni.cpp"
    "platform/android/src/android_phase5_timeline_overlay_gles_render_jni.cpp"
    "platform/android/src/android_phase5_timeline_transition_vulkan_render_jni.cpp"
    "platform/android/src/android_phase5_timeline_overlay_vulkan_render_jni.cpp"
    "platform/android/src/android_phase5_timeline_dual_decoder_sync_jni.cpp"
    "platform/android/src/android_phase5_timeline_dual_decoder_sync_vulkan_support.cpp"
  )
  target_include_directories(vanguard_media_engine PRIVATE "platform/android/include")
  # P5-COMPOSITOR-TRANS (GLES-RENDER): the diagnostic JNI drives the private
  # GlesTimelineTransitionCompositor helper directly against its own temporary
  # pbuffer context (no GlesBackend seam yet), so it needs the private GLES
  # helper source dir on its include path. Diagnostic-only; the helper header
  # stays out of the public gles_backend.h.
  target_include_directories(vanguard_media_engine PRIVATE "render/gles/src")
  # P5-COMPOSITOR-TRANS (VULKAN-RENDER): the diagnostic JNI drives the private
  # VulkanTimelineTransitionCompositor helper directly against its own temporary
  # VkDevice / offscreen attachment (no VulkanBackend seam yet), so it needs the
  # private Vulkan helper source dir on its include path. Diagnostic-only; the
  # helper header stays out of the public vulkan_backend.h.
  target_include_directories(vanguard_media_engine PRIVATE "render/vulkan/src")
  # P5-COMPOSITOR-TRANS (DUAL-DECODER-SYNC): the dual MediaCodec -> AHardwareBuffer
  # -> Vulkan crossfade diagnostic JNI and its private support translation unit
  # (android_phase5_timeline_dual_decoder_sync_vulkan_support.cpp) reuse the
  # private VulkanHardwareBufferImage / VulkanGraphicsPipeline /
  # VulkanShaderModule helpers and the AOT passthrough SPIR-V headers from the
  # same private Vulkan source dir already added above. Diagnostic-only; no
  # production route or public header change.

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
    vanguard_sinks
    vanguard_audio
    vanguard_compositors
    vanguard_render_shared
    vanguard_render_vulkan
    vanguard_render_gles
    android
    log
    GLESv3
    EGL
    mediandk
    vulkan
    # dl only: AAudio (API 26) is reached exclusively via runtime
    # dlopen("libaaudio.so")/dlsym behind an android_get_device_api_level()
    # gate so the minSdk 24 load path never needs libaaudio; never add
    # `aaudio` here.
    dl
  )
endif()
