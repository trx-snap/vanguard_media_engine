#include "vanguard_media_engine.h"
#include <vector>
#include <string>
#include <memory>
#include <algorithm>
#include <mutex>
#include <stdexcept>

// Phase 0 changes:
//   T10 – All FFI exports are noexcept with try/catch to prevent C++ exceptions
//          from crossing the JNI/FFI boundary on Android (causes silent crash).
//          vanguard_engine_last_error() exposes the last error code to Dart.
//   T12 – std::mutex on RenderGraph read/write paths eliminates the data race
//          between Dart isolate thread (addNode) and native render thread (nodesAt).

// Use printf instead of std::cout to avoid the std::ios_base::Init global
// constructor that std::cout generates. When this file is compiled as
// Objective-C++ via VanguardFFIBridge.mm, that global constructor can
// conflict with Dart's C++ runtime and cause a pre-main SIGABRT.

// ── Error codes ────────────────────────────────────────────────────────────────
// 0  = OK
// 1  = NULL argument (engine_ptr or path is null)
// 2  = std::bad_alloc (OOM — vector push_back or string copy failed)
// 99 = Unknown exception
//
// Use thread_local so concurrent FFI calls from different isolates don't clobber
// each other's error state.
static thread_local int32_t s_lastError = 0;

// ── Core Models ───────────────────────────────────────────────────────────────

enum class VanguardMode {
    NLE_OFFLINE = 0,
    LIVESTREAM  = 1,
};

enum class RenderNodeType {
    VIDEO  = 0,
    IMAGE  = 1,
    AUDIO  = 2,
    BITMAP = 3,   // Flutter UI captured via RepaintBoundary
};

struct RenderNode {
    std::string    path;
    double         startTime;
    double         duration;   // Actual probed duration (set after media is loaded)
    int            layerId;
    RenderNodeType type;

    RenderNode(std::string p, double st, int l, RenderNodeType t)
        : path(std::move(p)), startTime(st), duration(0.0), layerId(l), type(t) {}

    double endTime() const { return startTime + duration; }
};

class RenderGraph {
    // T12: Protects nodes against concurrent access between the Dart isolate
    // thread (addNode / setNodeDuration) and the native render thread (nodesAt).
    // Without this mutex, addNode's push_back (which may reallocate the vector)
    // racing against nodesAt's iteration is undefined behaviour.
    mutable std::mutex _mu;

public:
    std::vector<std::shared_ptr<RenderNode>> nodes;

    void addNode(std::shared_ptr<RenderNode> node) {
        std::lock_guard<std::mutex> lock(_mu);
        nodes.push_back(std::move(node));
        // Sort ascending by layerId (layer 0 = background, higher = foreground)
        std::sort(nodes.begin(), nodes.end(),
                  [](const std::shared_ptr<RenderNode>& a,
                     const std::shared_ptr<RenderNode>& b) {
                      return a->layerId < b->layerId;
                  });
    }

    // Returns nodes active at a specific playhead position.
    // Returns by value (copy under lock) so the caller can iterate safely.
    std::vector<std::shared_ptr<RenderNode>> nodesAt(double timeSec) const {
        std::lock_guard<std::mutex> lock(_mu);
        std::vector<std::shared_ptr<RenderNode>> active;
        for (const auto& node : nodes) {
            if (timeSec >= node->startTime && timeSec < node->endTime()) {
                active.push_back(node);
            }
        }
        return active;
    }

    double totalDuration() const {
        std::lock_guard<std::mutex> lock(_mu);
        double maxEnd = 0.0;
        for (const auto& node : nodes) {
            if (node->endTime() > maxEnd) maxEnd = node->endTime();
        }
        return maxEnd;
    }

    // Safe path-based lookup used by setNodeDuration
    bool setDuration(const std::string& path, double duration) {
        std::lock_guard<std::mutex> lock(_mu);
        for (auto& node : nodes) {
            if (node->path == path) {
                node->duration = duration;
                return true;
            }
        }
        return false;
    }
};

class TimelineManager {
public:
    RenderGraph videoGraph;  // Video + image + bitmap overlay tracks
    RenderGraph audioGraph;  // Audio tracks (music, clip audio)
    double      currentPlayhead = 0.0;

    void addVideoClip(const std::string& path, double startTime, int layerId) {
        auto node = std::make_shared<RenderNode>(path, startTime, layerId, RenderNodeType::VIDEO);
        videoGraph.addNode(node);
        printf("[Vanguard C++] Video node added: %s layer=%d\n", path.c_str(), layerId);
    }

    void addBitmapOverlay(const std::string& id, double startTime, double duration, int layerId) {
        auto node = std::make_shared<RenderNode>(id, startTime, layerId, RenderNodeType::BITMAP);
        node->duration = duration;
        videoGraph.addNode(node);
        printf("[Vanguard C++] Bitmap overlay added: %s layer=%d\n", id.c_str(), layerId);
    }

    void addAudioClip(const std::string& path, double startTime) {
        auto node = std::make_shared<RenderNode>(path, startTime, -1, RenderNodeType::AUDIO);
        audioGraph.addNode(node);
        printf("[Vanguard C++] Audio node added: %s\n", path.c_str());
    }

    void setNodeDuration(const std::string& path, double duration) {
        if (!videoGraph.setDuration(path, duration)) {
            audioGraph.setDuration(path, duration);
        }
        printf("[Vanguard C++] Duration set for %s: %.2fs\n", path.c_str(), duration);
    }

    double getDuration() const {
        return std::max(videoGraph.totalDuration(), audioGraph.totalDuration());
    }
};

// ── Vanguard Engine ──────────────────────────────────────────────────────────

class VanguardEngine {
public:
    VanguardMode    mode;
    TimelineManager timeline;

    explicit VanguardEngine(VanguardMode m) : mode(m) {
        printf("[Vanguard C++] Engine initialized in mode: %d\n", static_cast<int>(mode));
    }

    ~VanguardEngine() {
        printf("[Vanguard C++] Engine destroyed.\n");
    }
};

// ── FFI Bridge (C-Compatible Exports) ────────────────────────────────────────
// T10: All functions are noexcept. C++ exceptions must never cross the FFI/JNI
// boundary — on Android NDK, an uncaught C++ exception terminates the process
// with no Java stack trace and no crash reporter payload.
//
// Error classification:
//   s_lastError = 0  → success
//   s_lastError = 1  → NULL argument
//   s_lastError = 2  → std::bad_alloc (OOM)
//   s_lastError = 99 → unexpected exception

FFI_PLUGIN_EXPORT void* vanguard_engine_create(int mode) noexcept {
    try {
        s_lastError = 0;
        auto* engine = new VanguardEngine(static_cast<VanguardMode>(mode));
        return reinterpret_cast<void*>(engine);
    } catch (const std::bad_alloc&) {
        s_lastError = 2;
        return nullptr;
    } catch (...) {
        s_lastError = 99;
        return nullptr;
    }
}

FFI_PLUGIN_EXPORT void vanguard_engine_destroy(void* engine_ptr) noexcept {
    try {
        s_lastError = 0;
        if (engine_ptr) {
            delete reinterpret_cast<VanguardEngine*>(engine_ptr);
        }
    } catch (...) {
        s_lastError = 99;
    }
}

FFI_PLUGIN_EXPORT void vanguard_engine_add_video_node(
        void* engine_ptr, const char* path, double start_time, int layer_id) noexcept {
    try {
        if (!engine_ptr || !path) { s_lastError = 1; return; }
        s_lastError = 0;
        reinterpret_cast<VanguardEngine*>(engine_ptr)
            ->timeline.addVideoClip(std::string(path), start_time, layer_id);
    } catch (const std::bad_alloc&) {
        s_lastError = 2;
    } catch (...) {
        s_lastError = 99;
    }
}

FFI_PLUGIN_EXPORT void vanguard_engine_add_bitmap_overlay(
        void* engine_ptr, const char* overlay_id,
        double start_time, double duration, int layer_id) noexcept {
    try {
        if (!engine_ptr || !overlay_id) { s_lastError = 1; return; }
        s_lastError = 0;
        reinterpret_cast<VanguardEngine*>(engine_ptr)
            ->timeline.addBitmapOverlay(std::string(overlay_id), start_time, duration, layer_id);
    } catch (const std::bad_alloc&) {
        s_lastError = 2;
    } catch (...) {
        s_lastError = 99;
    }
}

FFI_PLUGIN_EXPORT void vanguard_engine_add_audio_node(
        void* engine_ptr, const char* path, double start_time) noexcept {
    try {
        if (!engine_ptr || !path) { s_lastError = 1; return; }
        s_lastError = 0;
        reinterpret_cast<VanguardEngine*>(engine_ptr)
            ->timeline.addAudioClip(std::string(path), start_time);
    } catch (const std::bad_alloc&) {
        s_lastError = 2;
    } catch (...) {
        s_lastError = 99;
    }
}

FFI_PLUGIN_EXPORT void vanguard_engine_set_node_duration(
        void* engine_ptr, const char* path, double duration) noexcept {
    try {
        if (!engine_ptr || !path) { s_lastError = 1; return; }
        s_lastError = 0;
        reinterpret_cast<VanguardEngine*>(engine_ptr)
            ->timeline.setNodeDuration(std::string(path), duration);
    } catch (const std::bad_alloc&) {
        s_lastError = 2;
    } catch (...) {
        s_lastError = 99;
    }
}

FFI_PLUGIN_EXPORT void vanguard_engine_set_playhead(void* engine_ptr, double time_sec) noexcept {
    try {
        if (!engine_ptr) { s_lastError = 1; return; }
        s_lastError = 0;
        reinterpret_cast<VanguardEngine*>(engine_ptr)->timeline.currentPlayhead = time_sec;
    } catch (...) {
        s_lastError = 99;
    }
}

FFI_PLUGIN_EXPORT double vanguard_engine_get_duration(void* engine_ptr) noexcept {
    try {
        if (!engine_ptr) { s_lastError = 1; return 0.0; }
        s_lastError = 0;
        return reinterpret_cast<VanguardEngine*>(engine_ptr)->timeline.getDuration();
    } catch (const std::bad_alloc&) {
        s_lastError = 2;
        return 0.0;
    } catch (...) {
        s_lastError = 99;
        return 0.0;
    }
}

/// T10: Error introspection for Dart — check after any FFI call to detect silent failures.
/// Returns 0 on success, non-zero on error (see codes above).
/// Thread-local: safe to query from any isolate.
FFI_PLUGIN_EXPORT int32_t vanguard_engine_last_error(void* /*unused*/) noexcept {
    return s_lastError;
}
