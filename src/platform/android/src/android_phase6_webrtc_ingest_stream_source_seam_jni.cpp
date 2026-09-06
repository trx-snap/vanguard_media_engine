// P6-WEBRTC-INGEST-STREAM-SOURCE-SEAM-A: diagnostic, video-only RTC ingest
// seam proving that Kotlin's generic RealtimeVideoInputAdapter/
// RtcVideoFrameSink boundary can forward incoming remote video frame
// metadata into a real vanguard::sources::StreamSourceNode-backed native
// session.
//
// Session-based route: Kotlin (NativeStreamSourceRtcVideoFrameSink) owns the
// RealtimeVideoFrame/HardwareBuffer entirely and calls this seam once per
// frame with primitive metadata only (width, height, ptsUs,
// rotationDegrees, mirrored, frameIndex). This translation unit instantiates
// one real vanguard::sources::StreamSourceNode per session (proving node
// construction/identity) and keeps a small bounded metadata-only queue; it
// never receives or retains a jobject, AHardwareBuffer, JNI global ref,
// Surface, texture, SDK/session handle, or network state.
//
// Honest non-claims:
// - Not a WebRTC/LiveKit integration: no real WebRTC/LiveKit SDK, no network
//   room/session, no signaling, no participant roster, no connection token.
// - Video-only: zero audio track/session/routing ownership.
// - No rendering, no product/editor/app/ConnectsApp wiring.
// - No HardwareBuffer ownership: the caller (Kotlin sink) never passes a
//   buffer/jobject across this seam, only primitive frame metadata.
// - Spawns no native worker threads; each session's mutable state (state,
//   queue, counters) is guarded by a per-session mutex so calls from any
//   Kotlin thread stay race-free. A second mutex guards only the session
//   registry map lifecycle (create/lookup/destroy).
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (VanguardNativeBridge.kt companion object):
//   createStreamSourceRtcIngestSession  -> jlong handle (0 on failure)
//   startStreamSourceRtcIngestSession   -> jstring key=value
//   pauseStreamSourceRtcIngestSession   -> jstring key=value
//   ingestStreamSourceRtcIngestMetadata -> jstring key=value
//   drainStreamSourceRtcIngestSession   -> jstring key=value
//   snapshotStreamSourceRtcIngestSession -> jstring key=value
//   destroyStreamSourceRtcIngestSession -> jstring key=value

#include <jni.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include "vanguard/sources/stream_source_node.h"

namespace {

using vanguard::graph::NodeKind;
using vanguard::graph::NodeType;
using vanguard::sources::StreamSourceNode;

constexpr int32_t kMinQueueCapacity       = 1;
constexpr int32_t kMaxQueueCapacity       = 32;
constexpr size_t  kMaxLiveSessions        = 4;
constexpr int32_t kMaxDrainEntriesPerCall = kMaxQueueCapacity;

constexpr const char* kProofBoundary =
    "diagnostic_video_only_rtc_ingest_seam_real_stream_source_node_metadata_queue_"
    "no_webrtc_livekit_sdk_no_network_room_session_no_audio_no_rendering_"
    "no_product_app_editor_wiring_no_hardware_buffer_ownership";

bool IsValidRotationDegrees(int32_t deg) {
    return deg == 0 || deg == 90 || deg == 180 || deg == 270;
}

bool IsBlank(const std::string& s) {
    return s.find_first_not_of(" \t\n\r") == std::string::npos;
}

enum class SessionState { kIdle, kStarted, kPaused };

const char* SessionStateName(SessionState s) {
    switch (s) {
        case SessionState::kIdle:    return "IDLE";
        case SessionState::kStarted: return "STARTED";
        case SessionState::kPaused:  return "PAUSED";
    }
    return "UNKNOWN";
}

// Primitive-only queued entry: no pixel buffer, no jobject, no OS resource.
struct QueuedFrameMetadata {
    int32_t width;
    int32_t height;
    int64_t ptsUs;
    int32_t rotationDegrees;
    bool    mirrored;
    int64_t frameIndex;
};

// ---------------------------------------------------------------------------
// Session. Owns exactly one real StreamSourceNode plus a bounded metadata
// queue. `mutex` guards this session's own mutable state (state, queue,
// counters); it never guards the registry map.
// ---------------------------------------------------------------------------
struct StreamSourceRtcIngestSession {
    std::unique_ptr<StreamSourceNode> node;
    int32_t width;
    int32_t height;
    int32_t maxQueueCapacity;
    SessionState state{SessionState::kIdle};
    std::deque<QueuedFrameMetadata> queue;
    int64_t acceptedCount{0};
    int64_t droppedBackpressureCount{0};
    int64_t droppedNotReadyCount{0};
    int64_t unsupportedFormatCount{0};
    int64_t failedCount{0};
    int64_t lastAcceptedFrameIndex{-1};
    std::mutex mutex;

    StreamSourceRtcIngestSession(const std::string& streamId,
                                  int32_t w,
                                  int32_t h,
                                  int64_t durationUs,
                                  int32_t queueCapacity)
        : width(w), height(h), maxQueueCapacity(queueCapacity) {
        node = std::make_unique<StreamSourceNode>(
            "stream_source_rtc_ingest:" + streamId,
            streamId,
            /*timelineStartPtsUs=*/0,
            static_cast<uint64_t>(durationUs),
            w,
            h,
            /*live=*/true);
    }
};

// ---------------------------------------------------------------------------
// Session registry. The mutex guards only this lifecycle map (create/lookup/
// destroy). Values are shared_ptr so an entry point that looked a session up
// stays safe even if destroy concurrently erases the map entry.
// ---------------------------------------------------------------------------
std::mutex gRegistryMutex;
std::unordered_map<int64_t, std::shared_ptr<StreamSourceRtcIngestSession>> gSessions;
int64_t gNextHandle = 1; // guarded by gRegistryMutex

std::shared_ptr<StreamSourceRtcIngestSession> FindSession(jlong handle) {
    std::lock_guard<std::mutex> lock(gRegistryMutex);
    auto it = gSessions.find(static_cast<int64_t>(handle));
    return it == gSessions.end() ? nullptr : it->second;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createStreamSourceRtcIngestSession
// Returns 0 on any invalid input (blank streamId, non-positive width/height,
// durationUs <= 0, maxQueueCapacity outside [kMinQueueCapacity,
// kMaxQueueCapacity]) or when the live-session cap is reached.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createStreamSourceRtcIngestSession(
    JNIEnv* env,
    jobject /* companion */,
    jstring streamIdJ,
    jint width,
    jint height,
    jlong durationUs,
    jint maxQueueCapacity) {

    if (!streamIdJ) return 0;
    const char* streamIdChars = env->GetStringUTFChars(streamIdJ, nullptr);
    if (!streamIdChars) return 0;
    const std::string streamId(streamIdChars);
    env->ReleaseStringUTFChars(streamIdJ, streamIdChars);

    if (IsBlank(streamId)) return 0;
    if (width <= 0 || height <= 0) return 0;
    if (durationUs <= 0) return 0;
    if (maxQueueCapacity < kMinQueueCapacity || maxQueueCapacity > kMaxQueueCapacity) return 0;

    std::shared_ptr<StreamSourceRtcIngestSession> session;
    try {
        session = std::make_shared<StreamSourceRtcIngestSession>(
            streamId,
            static_cast<int32_t>(width),
            static_cast<int32_t>(height),
            static_cast<int64_t>(durationUs),
            static_cast<int32_t>(maxQueueCapacity));
    } catch (...) {
        return 0;
    }

    std::lock_guard<std::mutex> lock(gRegistryMutex);
    if (gSessions.size() >= kMaxLiveSessions) return 0;
    const int64_t handle = gNextHandle++;
    gSessions[handle] = std::move(session);
    return static_cast<jlong>(handle);
}

// ---------------------------------------------------------------------------
// JNI: startStreamSourceRtcIngestSession
// Transitions IDLE/PAUSED -> STARTED (idempotent if already STARTED).
// Unknown handle returns status=not_found.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_startStreamSourceRtcIngestSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    const std::shared_ptr<StreamSourceRtcIngestSession> session = FindSession(handle);
    if (!session) return env->NewStringUTF("status=not_found");

    std::lock_guard<std::mutex> lock(session->mutex);
    session->state = SessionState::kStarted;

    char status[64];
    std::snprintf(status, sizeof(status), "status=ok;state=%s", SessionStateName(session->state));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: pauseStreamSourceRtcIngestSession
// Transitions STARTED -> PAUSED; idempotent no-op from IDLE/PAUSED. Unknown
// handle returns status=not_found.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_pauseStreamSourceRtcIngestSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    const std::shared_ptr<StreamSourceRtcIngestSession> session = FindSession(handle);
    if (!session) return env->NewStringUTF("status=not_found");

    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->state == SessionState::kStarted) {
        session->state = SessionState::kPaused;
    }

    char status[64];
    std::snprintf(status, sizeof(status), "status=ok;state=%s", SessionStateName(session->state));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: ingestStreamSourceRtcIngestMetadata
// Accepts primitive video frame metadata only. Evaluation order: not_found ->
// not-ready (session != STARTED) -> dimension/rotation mismatch
// (UNSUPPORTED_FORMAT) -> backpressure (queue at maxQueueCapacity) -> accept.
// Backpressure never advances acceptedCount or lastAcceptedFrameIndex.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_ingestStreamSourceRtcIngestMetadata(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
    jint width,
    jint height,
    jlong ptsUs,
    jint rotationDegrees,
    jboolean mirrored,
    jlong frameIndex) {

    char status[256];

    const std::shared_ptr<StreamSourceRtcIngestSession> session = FindSession(handle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);

    try {
        if (session->state != SessionState::kStarted) {
            session->droppedNotReadyCount++;
            std::snprintf(status, sizeof(status),
                "status=DROPPED_NOT_READY;state=%s;acceptedCount=%lld;queueSize=%zu",
                SessionStateName(session->state),
                static_cast<long long>(session->acceptedCount),
                session->queue.size());
            return env->NewStringUTF(status);
        }

        if (width != session->width || height != session->height) {
            session->unsupportedFormatCount++;
            std::snprintf(status, sizeof(status),
                "status=UNSUPPORTED_FORMAT;reason=dimension_mismatch:width=%d,height=%d,"
                "sessionWidth=%d,sessionHeight=%d",
                static_cast<int>(width), static_cast<int>(height),
                session->width, session->height);
            return env->NewStringUTF(status);
        }

        if (!IsValidRotationDegrees(static_cast<int32_t>(rotationDegrees))) {
            session->unsupportedFormatCount++;
            std::snprintf(status, sizeof(status),
                "status=UNSUPPORTED_FORMAT;reason=invalid_rotation_degrees:%d",
                static_cast<int>(rotationDegrees));
            return env->NewStringUTF(status);
        }

        if (static_cast<int32_t>(session->queue.size()) >= session->maxQueueCapacity) {
            session->droppedBackpressureCount++;
            std::snprintf(status, sizeof(status),
                "status=DROPPED_BACKPRESSURE;queueSize=%zu;maxQueueCapacity=%d;acceptedCount=%lld",
                session->queue.size(), session->maxQueueCapacity,
                static_cast<long long>(session->acceptedCount));
            return env->NewStringUTF(status);
        }

        QueuedFrameMetadata entry;
        entry.width = static_cast<int32_t>(width);
        entry.height = static_cast<int32_t>(height);
        entry.ptsUs = static_cast<int64_t>(ptsUs);
        entry.rotationDegrees = static_cast<int32_t>(rotationDegrees);
        entry.mirrored = (mirrored == JNI_TRUE);
        entry.frameIndex = static_cast<int64_t>(frameIndex);

        session->queue.push_back(entry);
        session->acceptedCount++;
        session->lastAcceptedFrameIndex = entry.frameIndex;

        std::snprintf(status, sizeof(status),
            "status=ACCEPTED;acceptedCount=%lld;queueSize=%zu;lastAcceptedFrameIndex=%lld",
            static_cast<long long>(session->acceptedCount),
            session->queue.size(),
            static_cast<long long>(session->lastAcceptedFrameIndex));
        return env->NewStringUTF(status);
    } catch (...) {
        std::snprintf(status, sizeof(status), "status=FAILED;reason=exception");
        return env->NewStringUTF(status);
    }
}

// ---------------------------------------------------------------------------
// JNI: drainStreamSourceRtcIngestSession
// Drains up to min(maxEntries, kMaxDrainEntriesPerCall, queueSize) entries
// FIFO, freeing queue capacity for subsequent ingest calls. Unknown handle
// returns status=not_found.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_drainStreamSourceRtcIngestSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
    jint maxEntries) {

    char status[256];

    const std::shared_ptr<StreamSourceRtcIngestSession> session = FindSession(handle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);

    int32_t toDrain = std::max<int32_t>(static_cast<int32_t>(maxEntries), 0);
    toDrain = std::min<int32_t>(toDrain, kMaxDrainEntriesPerCall);
    toDrain = std::min<int32_t>(toDrain, static_cast<int32_t>(session->queue.size()));

    for (int32_t i = 0; i < toDrain; ++i) {
        session->queue.pop_front();
    }

    std::snprintf(status, sizeof(status),
        "status=ok;drained=%d;queueSize=%zu;maxQueueCapacity=%d",
        toDrain, session->queue.size(), session->maxQueueCapacity);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: snapshotStreamSourceRtcIngestSession
// Returns session state/counters plus the real StreamSourceNode's identity
// (id, streamId, kind==kSource, type==kStreamSource) as construction proof.
// Unknown handle returns status=not_found.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_snapshotStreamSourceRtcIngestSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    const std::shared_ptr<StreamSourceRtcIngestSession> session = FindSession(handle);
    if (!session) return env->NewStringUTF("status=not_found");

    std::lock_guard<std::mutex> lock(session->mutex);

    const bool nodeKindIsSource = session->node->kind() == NodeKind::kSource;
    const bool nodeTypeIsStreamSource = session->node->type() == NodeType::kStreamSource;

    char status[1024];
    std::snprintf(status, sizeof(status),
        "status=ok;state=%s;streamId=%s;width=%d;height=%d;maxQueueCapacity=%d;queueSize=%zu;"
        "acceptedCount=%lld;droppedBackpressureCount=%lld;droppedNotReadyCount=%lld;"
        "unsupportedFormatCount=%lld;failedCount=%lld;lastAcceptedFrameIndex=%lld;"
        "nodeId=%s;nodeKindIsSource=%s;nodeTypeIsStreamSource=%s;proofBoundary=%s",
        SessionStateName(session->state),
        session->node->streamId().c_str(),
        session->width, session->height, session->maxQueueCapacity, session->queue.size(),
        static_cast<long long>(session->acceptedCount),
        static_cast<long long>(session->droppedBackpressureCount),
        static_cast<long long>(session->droppedNotReadyCount),
        static_cast<long long>(session->unsupportedFormatCount),
        static_cast<long long>(session->failedCount),
        static_cast<long long>(session->lastAcceptedFrameIndex),
        session->node->id().c_str(),
        nodeKindIsSource ? "true" : "false",
        nodeTypeIsStreamSource ? "true" : "false",
        kProofBoundary);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyStreamSourceRtcIngestSession
// Callable from any thread. Idempotent erase-once: handle 0/unknown/
// already-destroyed returns status=not_found; a live handle is erased
// exactly once and returns status=ok.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_destroyStreamSourceRtcIngestSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    bool erased = false;
    {
        std::lock_guard<std::mutex> lock(gRegistryMutex);
        erased = gSessions.erase(static_cast<int64_t>(handle)) > 0;
    }
    return env->NewStringUTF(erased ? "status=ok" : "status=not_found");
}
