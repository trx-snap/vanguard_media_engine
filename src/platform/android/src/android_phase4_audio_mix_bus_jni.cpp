// P4-AUDIO-MIXBUS: bounded native PCM16 mix-bus diagnostic. This translation
// unit only exposes vanguard::audio::AudioMixBusNode's pure in-memory
// interleaved-PCM16 mix math across JNI over direct java.nio.ByteBuffers.
// Kotlin remains the sole owner of MediaExtractor/MediaCodec/AudioTrack; no
// decode, no AAC, no export/mixdown route, no realtime playback here.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (matching VanguardNativeBridge.kt P4-AUDIO-MIXBUS
// declarations):
//   createAndroidDagPhase4AudioMixBusSession  -> jstring
//   addAndroidDagPhase4AudioMixBusTrack        -> jstring
//   mixAndroidDagPhase4AudioMixBusSession      -> jstring
//   destroyAndroidDagPhase4AudioMixBusSession  -> jstring

#include <jni.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <vector>

#include "vanguard/audio/audio_mix_bus_node.h"

namespace {

std::string JStringToStdString(JNIEnv* env, jstring str) {
    if (str == nullptr) return "";
    const char* chars = env->GetStringUTFChars(str, nullptr);
    if (chars == nullptr) return "";
    std::string result(chars);
    env->ReleaseStringUTFChars(str, chars);
    return result;
}

const char* MixResultReason(vanguard::audio::AudioMixBusNode::MixResult r) {
    using R = vanguard::audio::AudioMixBusNode::MixResult;
    switch (r) {
        case R::kOk:                          return "ok";
        case R::kInvalidGain:                 return "invalid_gain";
        case R::kInvalidTrackCount:           return "invalid_track_count";
        case R::kInvalidChannelCount:         return "invalid_channel_count";
        case R::kSampleRateMismatch:          return "sample_rate_mismatch";
        case R::kInvalidFrameCount:           return "invalid_frame_count";
        case R::kNullBuffer:                  return "null_buffer";
        case R::kInsufficientOutputCapacity:  return "insufficient_output_capacity";
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Phase4 audio-mix-bus diagnostic session
// ---------------------------------------------------------------------------

// One track admitted into a session via addTrack. `pcm` is a copy owned by
// this session (JNI never retains a pointer into a Java ByteBuffer beyond a
// single call), so it remains valid for every later mix() call.
struct Phase4AudioMixBusTrack {
    std::vector<int16_t> pcm;
    int64_t               frameCount;
    int32_t               sampleRate;
    int32_t               channelCount;
    double                gain;
};

struct Phase4AudioMixBusSession {
    // Guards node/tracks/counters for this session, matching the P2
    // frozen convention: native enforces a per-session mutex even though a
    // single Kotlin coordinator thread drives calls serially.
    std::mutex                                            mutex;
    std::unique_ptr<vanguard::audio::AudioMixBusNode>      node;
    std::vector<Phase4AudioMixBusTrack>                    tracks;
    int64_t                                                totalSamples{0};
    // Set under `mutex` by destroy while still holding the registry's last
    // shared_ptr reference; checked under `mutex` by add/mix so an in-flight
    // call that raced the registry erase fails closed instead of touching a
    // session mid/post-shutdown.
    bool                                                    destroyed{false};
    std::string                                             sessionId;
};

// ---------------------------------------------------------------------------
// Session registry (guarded by its own mutex; distinct from the per-session
// mutex above, which guards only node/tracks/counters).
//
// Values are shared_ptr so a session looked up here and handed to
// add/mix stays alive even if destroy() concurrently erases it from the map:
// each call holds its own reference for the duration of the call, and the
// object is only freed once every such reference (plus the map's) is gone.
// ---------------------------------------------------------------------------

std::mutex                                                                       gPhase4MixBusSessionRegistryMutex;
std::unordered_map<std::string, std::shared_ptr<Phase4AudioMixBusSession>>       gPhase4MixBusSessions;
std::atomic<uint64_t>                                                            gNextPhase4MixBusSessionId{1};

// Structural safety bound on how many samples a single session may hold
// across all admitted tracks (8 tracks * 8192 frames * 2 channels, doubled
// for headroom).
constexpr int64_t kMaxSessionTotalSamples = 8192LL * 2LL * 8LL * 2LL;
constexpr int32_t kMaxAdmittedFrameCount  = 8192;

std::shared_ptr<Phase4AudioMixBusSession> FindSession(const std::string& sessionId) {
    std::lock_guard<std::mutex> lock(gPhase4MixBusSessionRegistryMutex);
    auto it = gPhase4MixBusSessions.find(sessionId);
    if (it != gPhase4MixBusSessions.end()) return it->second;
    return nullptr;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAndroidDagPhase4AudioMixBusSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDagPhase4AudioMixBusSession(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  nodeIdJ,
    jint     sampleRate,
    jint     channelCount,
    jint     maxFramesPerMix) {

    char status[512];

    if (!nodeIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_node_id;sessionId=none");
        return env->NewStringUTF(status);
    }

    const std::string nodeId = JStringToStdString(env, nodeIdJ);

    std::unique_ptr<vanguard::audio::AudioMixBusNode> node;
    try {
        node = std::make_unique<vanguard::audio::AudioMixBusNode>(
            nodeId,
            static_cast<int32_t>(sampleRate),
            static_cast<int32_t>(channelCount),
            static_cast<int64_t>(maxFramesPerMix));
    } catch (const std::bad_alloc&) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=bad_alloc;sessionId=none");
        return env->NewStringUTF(status);
    } catch (const std::exception& e) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=%s;sessionId=none", e.what());
        return env->NewStringUTF(status);
    }

    std::shared_ptr<Phase4AudioMixBusSession> session;
    try {
        session = std::make_shared<Phase4AudioMixBusSession>();
        session->node = std::move(node);

        const uint64_t sid = gNextPhase4MixBusSessionId.fetch_add(1, std::memory_order_relaxed);
        char sidBuf[32];
        std::snprintf(sidBuf, sizeof(sidBuf), "p4amb_%llu",
            static_cast<unsigned long long>(sid));
        session->sessionId = sidBuf;

        std::lock_guard<std::mutex> lock(gPhase4MixBusSessionRegistryMutex);
        gPhase4MixBusSessions[session->sessionId] = session;
    } catch (const std::bad_alloc&) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=bad_alloc;sessionId=none");
        return env->NewStringUTF(status);
    } catch (const std::exception& e) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=%s;sessionId=none", e.what());
        return env->NewStringUTF(status);
    }

    const auto& inputPorts  = session->node->inputPorts();
    const auto& outputPorts = session->node->outputPorts();

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;sampleRate=%d;channelCount=%d;maxFramesPerMix=%d;"
        "kind=processing;type=audio_mix_bus;inputPortCount=%zu;inputPort0=%s;"
        "inputPort1=%s;inputPort2=%s;inputPort3=%s;inputPort4=%s;inputPort5=%s;"
        "inputPort6=%s;inputPort7=%s;outputPortCount=%zu;outputPort0=%s",
        session->sessionId.c_str(),
        static_cast<int>(sampleRate),
        static_cast<int>(channelCount),
        static_cast<int>(maxFramesPerMix),
        inputPorts.size(),
        inputPorts.size() > 0 ? inputPorts[0].id.c_str() : "",
        inputPorts.size() > 1 ? inputPorts[1].id.c_str() : "",
        inputPorts.size() > 2 ? inputPorts[2].id.c_str() : "",
        inputPorts.size() > 3 ? inputPorts[3].id.c_str() : "",
        inputPorts.size() > 4 ? inputPorts[4].id.c_str() : "",
        inputPorts.size() > 5 ? inputPorts[5].id.c_str() : "",
        inputPorts.size() > 6 ? inputPorts[6].id.c_str() : "",
        inputPorts.size() > 7 ? inputPorts[7].id.c_str() : "",
        outputPorts.size(),
        outputPorts.size() > 0 ? outputPorts[0].id.c_str() : "");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: addAndroidDagPhase4AudioMixBusTrack
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_addAndroidDagPhase4AudioMixBusTrack(
    JNIEnv*   env,
    jobject   /* this */,
    jstring   sessionIdJ,
    jobject   pcm16BufferJ,
    jint      frameCount,
    jint      sampleRate,
    jint      channelCount,
    jdouble   gain) {

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
    if (frameCount <= 0 || frameCount > kMaxAdmittedFrameCount) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_frame_count;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }
    if (channelCount < vanguard::audio::AudioMixBusNode::kMinChannelCount ||
        channelCount > vanguard::audio::AudioMixBusNode::kMaxChannelCount) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_channel_count;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    const jlong bufferCapacity = env->GetDirectBufferCapacity(pcm16BufferJ);
    if (bufferCapacity < 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=non_direct_buffer;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    const int64_t requiredSamples =
        static_cast<int64_t>(frameCount) * static_cast<int64_t>(channelCount);
    const int64_t requiredBytes = requiredSamples * static_cast<int64_t>(sizeof(int16_t));
    if (bufferCapacity < requiredBytes) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=insufficient_buffer_capacity;sessionId=%s;required=%lld;capacity=%lld",
            sid.c_str(), static_cast<long long>(requiredBytes), static_cast<long long>(bufferCapacity));
        return env->NewStringUTF(status);
    }

    void* rawAddr = env->GetDirectBufferAddress(pcm16BufferJ);
    if (!rawAddr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=direct_buffer_address_unavailable;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    std::shared_ptr<Phase4AudioMixBusSession> session = FindSession(sid);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    // Per-session mutex around admission check, buffer-size validation,
    // sample-bound accounting, and the track vector itself. Holding this
    // shared_ptr keeps the session alive even if destroy() erases it from
    // the registry between the lookup above and this lock.
    std::lock_guard<std::mutex> sessionLock(session->mutex);

    if (session->destroyed) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_destroyed;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    if (session->tracks.size() >= vanguard::audio::AudioMixBusNode::kMaxTrackCount) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=track_limit_exceeded;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    if (session->totalSamples + requiredSamples > kMaxSessionTotalSamples) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_sample_bound_exceeded;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    const int16_t* pcm = reinterpret_cast<const int16_t*>(rawAddr);

    try {
        Phase4AudioMixBusTrack track;
        track.pcm.assign(pcm, pcm + requiredSamples);
        track.frameCount   = static_cast<int64_t>(frameCount);
        track.sampleRate   = static_cast<int32_t>(sampleRate);
        track.channelCount = static_cast<int32_t>(channelCount);
        track.gain         = static_cast<double>(gain);
        session->tracks.push_back(std::move(track));
    } catch (const std::bad_alloc&) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=bad_alloc;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    } catch (const std::exception& e) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=%s;sessionId=%s", e.what(), sid.c_str());
        return env->NewStringUTF(status);
    }

    session->totalSamples += requiredSamples;

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;trackIndex=%zu;trackCount=%zu",
        sid.c_str(), session->tracks.size() - 1, session->tracks.size());
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: mixAndroidDagPhase4AudioMixBusSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_mixAndroidDagPhase4AudioMixBusSession(
    JNIEnv*  env,
    jobject  /* this */,
    jstring  sessionIdJ,
    jint     framesToMix,
    jobject  outBufferJ) {

    char status[512];

    if (!sessionIdJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_session_id");
        return env->NewStringUTF(status);
    }

    const std::string sid = JStringToStdString(env, sessionIdJ);

    if (!outBufferJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_out_buffer;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    const jlong outBufferCapacityBytes = env->GetDirectBufferCapacity(outBufferJ);
    if (outBufferCapacityBytes < 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=non_direct_buffer;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    void* outAddr = env->GetDirectBufferAddress(outBufferJ);
    if (!outAddr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=direct_buffer_address_unavailable;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    std::shared_ptr<Phase4AudioMixBusSession> session = FindSession(sid);
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

    // Fixed-size array (never heap-allocates) since a session admits at most
    // kMaxTrackCount tracks; avoids any throwing container operation on the
    // JNI boundary.
    vanguard::audio::AudioMixBusNode::MixTrack
        mixTracksArr[vanguard::audio::AudioMixBusNode::kMaxTrackCount];
    size_t mixTrackCount = 0;
    for (const Phase4AudioMixBusTrack& t : session->tracks) {
        if (mixTrackCount >= vanguard::audio::AudioMixBusNode::kMaxTrackCount) {
            break;
        }
        vanguard::audio::AudioMixBusNode::MixTrack& mt = mixTracksArr[mixTrackCount++];
        mt.pcm          = t.pcm.data();
        mt.frameCount   = t.frameCount;
        mt.sampleRate   = t.sampleRate;
        mt.channelCount = t.channelCount;
        mt.gain         = t.gain;
    }

    const int64_t outCapacitySamples = outBufferCapacityBytes / static_cast<int64_t>(sizeof(int16_t));

    vanguard::audio::AudioMixBusNode::MixOutput mixOutput;
    const auto result = session->node->mix(
        mixTracksArr,
        mixTrackCount,
        static_cast<int64_t>(framesToMix),
        reinterpret_cast<int16_t*>(outAddr),
        outCapacitySamples,
        &mixOutput);

    if (result != vanguard::audio::AudioMixBusNode::MixResult::kOk) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=%s;sessionId=%s;trackCount=%zu",
            MixResultReason(result), sid.c_str(), mixTrackCount);
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;trackCount=%zu;framesMixed=%lld;checksum=%llu;"
        "clipped=%s;maxAccumulatorAbs=%d",
        sid.c_str(),
        mixTrackCount,
        static_cast<long long>(mixOutput.framesMixed),
        static_cast<unsigned long long>(mixOutput.checksum),
        mixOutput.clipped ? "true" : "false",
        mixOutput.maxAccumulatorAbs);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAndroidDagPhase4AudioMixBusSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDagPhase4AudioMixBusSession(
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
    // fails closed. Any add/mix call that already copied the shared_ptr
    // before this erase keeps the session object alive until that call
    // releases its reference; the `destroyed` flag (set below under
    // `mutex`) makes such a racing call fail closed instead of touching a
    // session mid/post-shutdown.
    std::shared_ptr<Phase4AudioMixBusSession> session;
    {
        std::lock_guard<std::mutex> lock(gPhase4MixBusSessionRegistryMutex);
        auto it = gPhase4MixBusSessions.find(sid);
        if (it != gPhase4MixBusSessions.end()) {
            session = it->second;
            gPhase4MixBusSessions.erase(it);
        }
    }

    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;sessionId=%s", sid.c_str());
        return env->NewStringUTF(status);
    }

    size_t trackCount = 0;
    {
        std::lock_guard<std::mutex> sessionLock(session->mutex);
        trackCount = session->tracks.size();
        session->destroyed = true;
    }

    // `session` (this function's shared_ptr) goes out of scope after this
    // point; the object is freed once no in-flight add/mix call still holds
    // a reference.
    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;trackCount=%zu",
        sid.c_str(), trackCount);
    return env->NewStringUTF(status);
}
