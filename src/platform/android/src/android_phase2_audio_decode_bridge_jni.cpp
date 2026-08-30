// P2-AUDIO-DEC-BRIDGE: bounded native decoded-PCM audio source bridge
// diagnostic. Kotlin owns MediaExtractor/MediaCodec OS audio decoding; this
// translation unit only receives already-decoded 16-bit interleaved PCM
// chunks handed across a direct java.nio.ByteBuffer and validates/accumulates
// them through vanguard::audio::DecodedAudioPcmSourceNode as a DAG audio
// source boundary. No MediaExtractor/MediaCodec/AMediaCodec/MediaMuxer, no
// file IO, no render/DAG graph evaluation, no production mixdown/export
// route changes.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (matching VanguardNativeBridge.kt P2-AUDIO-DEC-BRIDGE
// declarations):
//   createAndroidDagPhase2AudioDecodeBridgeSession   -> jstring
//   ingestAndroidDagPhase2AudioDecodeBridgePcm        -> jstring
//   validateAndroidDagPhase2AudioDecodeBridgeSession  -> jstring
//   destroyAndroidDagPhase2AudioDecodeBridgeSession   -> jstring

#include <jni.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include "vanguard/audio/decoded_audio_pcm_source_node.h"

namespace {

std::string JStringToStdString(JNIEnv* env, jstring str) {
    if (str == nullptr) return "";
    const char* chars = env->GetStringUTFChars(str, nullptr);
    if (chars == nullptr) return "";
    std::string result(chars);
    env->ReleaseStringUTFChars(str, chars);
    return result;
}

const char* IngestResultReason(vanguard::audio::DecodedAudioPcmSourceNode::IngestResult r) {
    using R = vanguard::audio::DecodedAudioPcmSourceNode::IngestResult;
    switch (r) {
        case R::kOk:                     return "ok";
        case R::kAlreadyEndOfStream:     return "already_end_of_stream";
        case R::kInvalidFrameCount:      return "invalid_frame_count";
        case R::kSampleCountMismatch:    return "sample_count_mismatch";
        case R::kNonMonotonicPts:        return "non_monotonic_pts";
        case R::kExceedsExpectedFrames:  return "exceeds_expected_frames";
        case R::kNullBuffer:             return "null_buffer";
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Phase2 audio-decode-bridge diagnostic session
// ---------------------------------------------------------------------------

struct Phase2AudioDecodeBridgeSession {
    // Guards ingest/validate/counters for this session, matching the P2
    // frozen convention: native enforces a per-session mutex even though a
    // single Kotlin coordinator thread pumps chunks serially.
    std::mutex                                             mutex;
    std::unique_ptr<vanguard::audio::DecodedAudioPcmSourceNode> node;
    // Set under `mutex` by destroy while still holding the registry's last
    // shared_ptr reference; checked under `mutex` by ingest/validate so an
    // in-flight call that raced the registry erase fails closed instead of
    // touching a session mid/post-shutdown.
    bool                                                    destroyed{false};
    std::string                                             sessionId;
};

// ---------------------------------------------------------------------------
// Session registry (guarded by its own mutex; distinct from the per-session
// mutex above, which guards only ingest/validate/counters).
//
// Values are shared_ptr so a session looked up here and handed to
// ingest/validate stays alive even if destroy() concurrently erases it from
// the map: each call holds its own reference for the duration of the call,
// and the object is only freed once every such reference (plus the map's) is
// gone.
// ---------------------------------------------------------------------------

std::mutex                                                                          gPhase2AudioSessionRegistryMutex;
std::unordered_map<std::string, std::shared_ptr<Phase2AudioDecodeBridgeSession>>   gPhase2AudioSessions;
std::atomic<uint64_t>                                                               gNextPhase2AudioSessionId{1};

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAndroidDagPhase2AudioDecodeBridgeSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDagPhase2AudioDecodeBridgeSession(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sourceNodeIdJ,
    jint     sampleRate,
    jint     channelCount,
    jint     expectedFrameCount,
    jlong    timelineStartPtsUs) {

    char status[512];

    if (!sourceNodeIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_source_node_id;sessionId=none");
        return env->NewStringUTF(status);
    }
    if (timelineStartPtsUs < 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=negative_timeline_start_pts_us;sessionId=none");
        return env->NewStringUTF(status);
    }

    const std::string sourceNodeId = JStringToStdString(env, sourceNodeIdJ);

    std::unique_ptr<vanguard::audio::DecodedAudioPcmSourceNode> node;
    try {
        node = std::make_unique<vanguard::audio::DecodedAudioPcmSourceNode>(
            sourceNodeId,
            static_cast<int32_t>(sampleRate),
            static_cast<int32_t>(channelCount),
            static_cast<int64_t>(expectedFrameCount),
            static_cast<uint64_t>(timelineStartPtsUs));
    } catch (const std::exception& e) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=%s;sessionId=none", e.what());
        return env->NewStringUTF(status);
    }

    auto session = std::make_shared<Phase2AudioDecodeBridgeSession>();
    session->node = std::move(node);

    const uint64_t sid = gNextPhase2AudioSessionId.fetch_add(1, std::memory_order_relaxed);
    char sidBuf[32];
    std::snprintf(sidBuf, sizeof(sidBuf), "p2adb_%llu",
        static_cast<unsigned long long>(sid));
    session->sessionId = sidBuf;

    {
        std::lock_guard<std::mutex> lock(gPhase2AudioSessionRegistryMutex);
        gPhase2AudioSessions[session->sessionId] = session;
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;sampleRate=%d;channelCount=%d;expectedFrameCount=%d",
        session->sessionId.c_str(),
        static_cast<int>(sampleRate),
        static_cast<int>(channelCount),
        static_cast<int>(expectedFrameCount));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: ingestAndroidDagPhase2AudioDecodeBridgePcm
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_ingestAndroidDagPhase2AudioDecodeBridgePcm(
    JNIEnv*   env,
    jobject   /* this */,
    jstring   sessionIdJ,
    jobject   pcm16BufferJ,
    jint      frameCount,
    jlong     bufferPtsUs,
    jboolean  isEndOfStream) {

    char status[512];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_session_id");
        return env->NewStringUTF(status);
    }

    const std::string sid = JStringToStdString(env, sessionIdJ);

    if (!pcm16BufferJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_pcm_buffer;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }
    if (frameCount <= 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_frame_count;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }
    if (bufferPtsUs < 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=negative_buffer_pts_us;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    const jlong bufferCapacity = env->GetDirectBufferCapacity(pcm16BufferJ);
    if (bufferCapacity < 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=non_direct_buffer;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    void* rawAddr = env->GetDirectBufferAddress(pcm16BufferJ);
    if (!rawAddr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=direct_buffer_address_unavailable;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    std::shared_ptr<Phase2AudioDecodeBridgeSession> session;
    {
        std::lock_guard<std::mutex> lock(gPhase2AudioSessionRegistryMutex);
        auto it = gPhase2AudioSessions.find(sid);
        if (it != gPhase2AudioSessions.end()) session = it->second;
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    // Per-session mutex around admission check, buffer-size validation
    // against this session's channel count, ingest, and counters. Holding
    // this shared_ptr keeps the session alive even if destroy() erases it
    // from the registry between the lookup above and this lock.
    std::lock_guard<std::mutex> sessionLock(session->mutex);

    if (session->destroyed) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_destroyed;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    vanguard::audio::DecodedAudioPcmSourceNode* node = session->node.get();

    const int64_t requiredSamples =
        static_cast<int64_t>(frameCount) * static_cast<int64_t>(node->channelCount());
    const int64_t requiredBytes = requiredSamples * static_cast<int64_t>(sizeof(int16_t));
    if (bufferCapacity < requiredBytes) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=insufficient_buffer_capacity;sessionId=%s;required=%lld;capacity=%lld",
            sid.c_str(), static_cast<long long>(requiredBytes), static_cast<long long>(bufferCapacity));
        return env->NewStringUTF(status);
    }

    const int16_t* pcm = reinterpret_cast<const int16_t*>(rawAddr);
    const auto result = node->ingestChunk(
        pcm,
        static_cast<int64_t>(frameCount),
        static_cast<int64_t>(bufferPtsUs),
        isEndOfStream == JNI_TRUE);

    if (result != vanguard::audio::DecodedAudioPcmSourceNode::IngestResult::kOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=%s;sessionId=%s;ingestedFrameCount=%lld",
            IngestResultReason(result), sid.c_str(),
            static_cast<long long>(node->ingestedFrameCount()));
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;ingestedFrameCount=%lld;chunkCount=%lld;"
        "isEndOfStream=%s;nonZeroSamples=%s;peakAbs=%d",
        sid.c_str(),
        static_cast<long long>(node->ingestedFrameCount()),
        static_cast<long long>(node->chunkCount()),
        node->isEndOfStream() ? "true" : "false",
        node->hasNonZeroSamples() ? "true" : "false",
        node->peakAbs());
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: validateAndroidDagPhase2AudioDecodeBridgeSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_validateAndroidDagPhase2AudioDecodeBridgeSession(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ) {

    char status[512];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_session_id");
        return env->NewStringUTF(status);
    }

    const std::string sid = JStringToStdString(env, sessionIdJ);

    std::shared_ptr<Phase2AudioDecodeBridgeSession> session;
    {
        std::lock_guard<std::mutex> lock(gPhase2AudioSessionRegistryMutex);
        auto it = gPhase2AudioSessions.find(sid);
        if (it != gPhase2AudioSessions.end()) session = it->second;
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> sessionLock(session->mutex);

    if (session->destroyed) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_destroyed;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    vanguard::audio::DecodedAudioPcmSourceNode* node = session->node.get();

    if (!node->validateComplete()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=expected_frame_count_mismatch;sessionId=%s;"
            "isEndOfStream=%s;ingestedFrameCount=%lld;expectedFrameCount=%lld",
            sid.c_str(),
            node->isEndOfStream() ? "true" : "false",
            static_cast<long long>(node->ingestedFrameCount()),
            static_cast<long long>(node->expectedFrameCount()));
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;ingestedFrameCount=%lld;expectedFrameCount=%lld;"
        "chunkCount=%lld;nonZeroSamples=%s;peakAbs=%d;checksum=%llu",
        sid.c_str(),
        static_cast<long long>(node->ingestedFrameCount()),
        static_cast<long long>(node->expectedFrameCount()),
        static_cast<long long>(node->chunkCount()),
        node->hasNonZeroSamples() ? "true" : "false",
        node->peakAbs(),
        static_cast<unsigned long long>(node->checksum()));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAndroidDagPhase2AudioDecodeBridgeSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDagPhase2AudioDecodeBridgeSession(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ) {

    char status[256];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_session_id");
        return env->NewStringUTF(status);
    }

    const std::string sid = JStringToStdString(env, sessionIdJ);

    // Erasing under the registry lock guarantees destroy runs exactly once
    // per session: a concurrent/duplicate destroy call finds nothing and
    // fails closed. Any ingest/validate call that already copied the
    // shared_ptr before this erase keeps the session object alive until that
    // call releases its reference; the `destroyed` flag (set below under
    // `mutex`) makes such a racing call fail closed instead of touching a
    // session mid/post-shutdown.
    std::shared_ptr<Phase2AudioDecodeBridgeSession> session;
    {
        std::lock_guard<std::mutex> lock(gPhase2AudioSessionRegistryMutex);
        auto it = gPhase2AudioSessions.find(sid);
        if (it != gPhase2AudioSessions.end()) {
            session = it->second;
            gPhase2AudioSessions.erase(it);
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    int64_t ingestedFrameCount = 0;
    {
        std::lock_guard<std::mutex> sessionLock(session->mutex);
        ingestedFrameCount = session->node->ingestedFrameCount();
        session->destroyed = true;
    }

    // `session` (this function's shared_ptr) goes out of scope after this
    // point; the object is freed once no in-flight ingest/validate call
    // still holds a reference.
    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;ingestedFrameCount=%lld",
        sid.c_str(), static_cast<long long>(ingestedFrameCount));
    return env->NewStringUTF(status);
}
