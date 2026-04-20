#ifndef VANGUARD_MEDIA_ENGINE_H_
#define VANGUARD_MEDIA_ENGINE_H_

#if _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
#define VANGUARD_NOEXCEPT noexcept
extern "C" {
#else
#define VANGUARD_NOEXCEPT
#endif

    // Engine Lifecycle
    FFI_PLUGIN_EXPORT void* vanguard_engine_create(int mode) VANGUARD_NOEXCEPT;
    FFI_PLUGIN_EXPORT void vanguard_engine_destroy(void* engine) VANGUARD_NOEXCEPT;

    // Timeline Management
    FFI_PLUGIN_EXPORT void vanguard_engine_add_video_node(void* engine, const char* path, double start_time, int layer_id) VANGUARD_NOEXCEPT;
    FFI_PLUGIN_EXPORT void vanguard_engine_add_bitmap_overlay(void* engine, const char* overlay_id, double start_time, double duration, int layer_id) VANGUARD_NOEXCEPT;
    FFI_PLUGIN_EXPORT void vanguard_engine_add_audio_node(void* engine, const char* path, double start_time) VANGUARD_NOEXCEPT;
    FFI_PLUGIN_EXPORT void vanguard_engine_set_node_duration(void* engine, const char* path, double duration) VANGUARD_NOEXCEPT;

    // Playhead / Sync
    FFI_PLUGIN_EXPORT void vanguard_engine_set_playhead(void* engine, double time_sec) VANGUARD_NOEXCEPT;
    FFI_PLUGIN_EXPORT double vanguard_engine_get_duration(void* engine) VANGUARD_NOEXCEPT;

    // Error Introspection (T10)
    FFI_PLUGIN_EXPORT int32_t vanguard_engine_last_error(void* unused) VANGUARD_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif // VANGUARD_MEDIA_ENGINE_H_
