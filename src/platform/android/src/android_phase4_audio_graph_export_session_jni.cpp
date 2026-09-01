// P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION: parameterized N-source (up to 8)
// True-DAG audio graph EXPORT session diagnostic seam. One session = one
// C++ Graph holding one AudioMixBusNode ("graph_export_mix") plus up to
// eight DecodedAudioPcmSourceNode instances built with the 6-arg
// node-owned-transport constructor (each node owns its
// AudioSpscAudioRingBuffer + AudioDecoderRingWriter +
// RingBufferAudioSampleProvider triple by composition). prepare() freezes
// the topology and constructs a GraphAudioScheduler via the tag-dispatched
// AutoDiscoverSourceProviders constructor with a null mix-params map
// (static unit gain, null envelope only). Windows are rendered
// synchronously, contiguously, and export-style: startFrame must equal the
// session's own nextRenderFrame cursor (no skips, retries, or reorders),
// and any provider zero-fill underrun during a window fails that window
// closed (zero-filled audio is corruption for an export session, never a
// silent-success).
//
// Every graph export source node uses timelineStartPtsUs=0 and
// expectedFrameCount=totalFrames so all providers are called in lockstep
// (native per-node timeline gating is an explicit non-claim here).
//
// Honest non-claims: diagnostic foundation only. No production route swap
// (AndroidAudioMixdownEngine and AndroidNativeAudioMixBusChunkMixer are
// untouched), no runtime/realtime sink, no AudioTrack/AAudio/OpenSL/Oboe,
// no MediaCodec/MediaExtractor, no file IO, no native worker threads, no
// gain/envelope production use, no app/editor/product, no streaming/cache,
// no iOS.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt. Its session registry is disjoint from every other
// diagnostic session registry.
//
// JNI entry points (VanguardNativeBridge.kt instance declarations):
//   createAndroidDagPhase4AudioGraphExportSession   -> jstring
//   addAndroidDagPhase4AudioGraphExportTrack        -> jstring
//   prepareAndroidDagPhase4AudioGraphExportSession  -> jstring
//   ingestAndroidDagPhase4AudioGraphExportTrackPcm  -> jstring
//   renderAndroidDagPhase4AudioGraphExportWindow    -> jstring
//   destroyAndroidDagPhase4AudioGraphExportSession  -> jstring

#include <jni.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "vanguard/audio/audio_decoder_ring_writer.h"
#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/audio/ring_buffer_audio_sample_provider.h"
#include "vanguard/graph/graph.h"

namespace {

using vanguard::audio::AudioDecoderRingWriter;
using vanguard::audio::AudioMixBusNode;
using vanguard::audio::AutoDiscoverSourceProviders;
using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::audio::GraphAudioScheduler;
using vanguard::audio::RingBufferAudioSampleProvider;
using vanguard::graph::Graph;
using WriterStatus    = AudioDecoderRingWriter::Status;
using SchedulerResult = GraphAudioScheduler::SchedulerResult;

// Must stay byte-identical to PROOF_BOUNDARY in
// AndroidAudioGraphExportSessionDriver.kt.
constexpr const char* kProofBoundary =
    "native_true_dag_pass2_graph_export_session_diagnostic_only_n_source_node_owned_ring_graph_"
    "scheduler_mixbus_unit_gain_no_production_route_swap_no_android_mixdown_engine_change_no_"
    "legacy_chunk_mixer_change_no_runtime_realtime_sink_no_audiotrack_no_aaudio_no_opensl_no_"
    "oboe_no_mediacodec_no_mediaextractor_no_file_io_no_native_worker_threads_no_app_no_editor_"
    "no_product_no_streaming_no_cache_no_ios";

constexpr const char* kMixNodeId = "graph_export_mix";

constexpr size_t  kMaxLiveSessions          = 8;
constexpr size_t  kMaxTrackCount            = AudioMixBusNode::kMaxTrackCount; // 8
constexpr int64_t kSourceRingCapacityFrames = 8192;
constexpr int32_t kMaxIngestFrames          = 8192;

std::string JStringToStdString(JNIEnv* env, jstring str) {
    if (str == nullptr) return "";
    const char* chars = env->GetStringUTFChars(str, nullptr);
    if (chars == nullptr) return "";
    std::string result(chars);
    env->ReleaseStringUTFChars(str, chars);
    return result;
}

const char* WriterStatusName(WriterStatus s) {
    switch (s) {
        case WriterStatus::kOk:              return "ok";
        case WriterStatus::kPartialWrite:    return "partial_write";
        case WriterStatus::kRingFull:        return "ring_full";
        case WriterStatus::kFormatMismatch:  return "format_mismatch";
        case WriterStatus::kInvalidArgument: return "invalid_argument";
        case WriterStatus::kAlreadyEos:      return "already_eos";
        case WriterStatus::kAwaitingSeekAck: return "awaiting_seek_ack";
    }
    return "unknown";
}

const char* SchedulerResultName(SchedulerResult r) {
    switch (r) {
        case SchedulerResult::kOk:                   return "ok";
        case SchedulerResult::kSilence:              return "silence";
        case SchedulerResult::kStaleGeneration:      return "stale_generation";
        case SchedulerResult::kInvalidTarget:        return "invalid_target";
        case SchedulerResult::kInvalidFrameCount:    return "invalid_frame_count";
        case SchedulerResult::kInsufficientCapacity: return "insufficient_capacity";
        case SchedulerResult::kSampleRateMismatch:   return "sample_rate_mismatch";
        case SchedulerResult::kProviderMissing:      return "provider_missing";
        case SchedulerResult::kProviderError:        return "provider_error";
        case SchedulerResult::kMixFailure:           return "mix_failure";
        case SchedulerResult::kWindowPtsOverflow:    return "window_pts_overflow";
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Graph export session. The per-session mutex guards every member below
// (the Kotlin driver runs one worker thread, but the native seam still
// enforces the frozen per-session-mutex convention). The graph must be
// fully populated before prepare() constructs the scheduler, which
// snapshots the graph generation; addTrack after prepare is rejected so
// the snapshot can never go stale within a session's own lifecycle.
// ---------------------------------------------------------------------------
struct GraphExportSession {
    std::mutex mutex;

    Graph                            graphTopology;
    std::shared_ptr<AudioMixBusNode> mixBus;

    // Insertion order == mix-bus input-port order; the map is the id index.
    std::vector<std::string> trackOrder;
    std::unordered_map<std::string, std::shared_ptr<DecodedAudioPcmSourceNode>> tracks;

    std::unique_ptr<GraphAudioScheduler> scheduler;
    bool     prepared{false};
    bool     destroyed{false};
    uint64_t snapshotGeneration{0};

    int32_t sampleRate{0};
    int32_t channelCount{0};
    int64_t maxFramesPerMix{0};

    // Export window cursor/metrics; mutated only on a PASS render.
    int64_t nextRenderFrame{0};
    int64_t windowCount{0};
    int64_t silentWindowCount{0};

    std::string sessionId;
};

// ---------------------------------------------------------------------------
// Session registry (own mutex, disjoint from every other diagnostic seam).
// Values are shared_ptr so an entry point that looked a session up stays
// safe even if destroy concurrently erases the map entry.
// ---------------------------------------------------------------------------
std::mutex gGraphExportRegistryMutex;
std::unordered_map<std::string, std::shared_ptr<GraphExportSession>> gGraphExportSessions;
std::atomic<uint64_t> gNextGraphExportSessionId{1};

std::shared_ptr<GraphExportSession> FindGraphExportSession(const std::string& sessionId) {
    std::lock_guard<std::mutex> lock(gGraphExportRegistryMutex);
    auto it = gGraphExportSessions.find(sessionId);
    return it == gGraphExportSessions.end() ? nullptr : it->second;
}

// The 6-arg node constructor always composes a RingBufferAudioSampleProvider,
// so this downcast of the base-typed accessor is exact (diagnostics-only
// underrun metric access, same justification as the node-owned pipeline TU).
RingBufferAudioSampleProvider* TrackProvider(DecodedAudioPcmSourceNode& node) {
    return static_cast<RingBufferAudioSampleProvider*>(node.audioSampleProvider());
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAndroidDagPhase4AudioGraphExportSession
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDagPhase4AudioGraphExportSession(
    JNIEnv* env,
    jobject /* this */,
    jint    sampleRate,
    jint    channelCount,
    jint    maxFramesPerMix) {

    char status[768];

    if (sampleRate < DecodedAudioPcmSourceNode::kMinSampleRate ||
        sampleRate > DecodedAudioPcmSourceNode::kMaxSampleRate) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_sample_rate");
        return env->NewStringUTF(status);
    }
    if (channelCount < DecodedAudioPcmSourceNode::kMinChannelCount ||
        channelCount > DecodedAudioPcmSourceNode::kMaxChannelCount) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_channel_count");
        return env->NewStringUTF(status);
    }
    if (maxFramesPerMix < AudioMixBusNode::kMinMaxFramesPerMix ||
        maxFramesPerMix > AudioMixBusNode::kMaxMaxFramesPerMix) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_max_frames_per_mix");
        return env->NewStringUTF(status);
    }

    std::shared_ptr<GraphExportSession> session;
    try {
        session = std::make_shared<GraphExportSession>();
        session->mixBus = std::make_shared<AudioMixBusNode>(
            kMixNodeId,
            static_cast<int32_t>(sampleRate),
            static_cast<int32_t>(channelCount),
            static_cast<int64_t>(maxFramesPerMix));
        if (!session->graphTopology.addNode(session->mixBus).ok()) {
            std::snprintf(status, sizeof(status), "status=FAIL;reason=graph_add_mix_node_failed");
            return env->NewStringUTF(status);
        }
        session->sampleRate      = static_cast<int32_t>(sampleRate);
        session->channelCount    = static_cast<int32_t>(channelCount);
        session->maxFramesPerMix = static_cast<int64_t>(maxFramesPerMix);

        const uint64_t sid = gNextGraphExportSessionId.fetch_add(1, std::memory_order_relaxed);
        char sidBuf[32];
        std::snprintf(sidBuf, sizeof(sidBuf), "p4agx_%llu", static_cast<unsigned long long>(sid));
        session->sessionId = sidBuf;
    } catch (const std::exception& e) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=%s", e.what());
        return env->NewStringUTF(status);
    } catch (...) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_construction_failed");
        return env->NewStringUTF(status);
    }

    {
        std::lock_guard<std::mutex> lock(gGraphExportRegistryMutex);
        if (gGraphExportSessions.size() >= kMaxLiveSessions) {
            std::snprintf(status, sizeof(status), "status=FAIL;reason=session_capacity_exceeded");
            return env->NewStringUTF(status);
        }
        gGraphExportSessions[session->sessionId] = session;
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;sessionId=%s;proofBoundary=%s;sampleRate=%d;channelCount=%d;"
        "maxFramesPerMix=%d;mixNodeId=%s;inputPortCount=%zu",
        session->sessionId.c_str(),
        kProofBoundary,
        static_cast<int>(sampleRate),
        static_cast<int>(channelCount),
        static_cast<int>(maxFramesPerMix),
        kMixNodeId,
        session->mixBus->inputPorts().size());
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: addAndroidDagPhase4AudioGraphExportTrack
// Rejected after prepare() so the scheduler's generation snapshot stays
// authoritative. Every track uses timelineStartPtsUs=0 and
// expectedFrameCount=totalFrames (lockstep providers, no per-node timeline
// gating claim) and the 6-arg node-owned-transport constructor.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_addAndroidDagPhase4AudioGraphExportTrack(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ,
    jstring trackIdJ,
    jlong   totalFrames) {

    char status[512];

    const std::string sid = JStringToStdString(env, sessionIdJ);
    const std::shared_ptr<GraphExportSession> session = FindGraphExportSession(sid);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_not_found");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->destroyed) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_destroyed");
        return env->NewStringUTF(status);
    }
    if (session->prepared) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_already_prepared");
        return env->NewStringUTF(status);
    }

    const std::string trackId = JStringToStdString(env, trackIdJ);
    if (trackId.empty()) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=empty_track_id");
        return env->NewStringUTF(status);
    }
    if (session->tracks.count(trackId) != 0) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=duplicate_track_id");
        return env->NewStringUTF(status);
    }
    if (session->trackOrder.size() >= kMaxTrackCount) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=total_track_count_exceeded:%zu",
            session->trackOrder.size() + 1);
        return env->NewStringUTF(status);
    }
    const int64_t frames = static_cast<int64_t>(totalFrames);
    if (frames <= 0 ||
        frames > static_cast<int64_t>(session->sampleRate) *
                     DecodedAudioPcmSourceNode::kMaxExpectedSeconds) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_total_frames");
        return env->NewStringUTF(status);
    }

    std::shared_ptr<DecodedAudioPcmSourceNode> node;
    try {
        node = std::make_shared<DecodedAudioPcmSourceNode>(
            trackId,
            session->sampleRate,
            session->channelCount,
            frames,
            /*timelineStartPtsUs=*/0,
            kSourceRingCapacityFrames);
    } catch (const std::exception& e) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=%s", e.what());
        return env->NewStringUTF(status);
    } catch (...) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=node_construction_failed");
        return env->NewStringUTF(status);
    }
    if (!node->ownsRing()) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=node_transport_missing");
        return env->NewStringUTF(status);
    }

    if (!session->graphTopology.addNode(node).ok()) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=graph_add_node_failed");
        return env->NewStringUTF(status);
    }

    const size_t trackIndex = session->trackOrder.size();
    const std::string& inputPortId = session->mixBus->inputPorts()[trackIndex].id;
    if (!session->graphTopology.connect(trackId, "audio_out", kMixNodeId, inputPortId).ok()) {
        // Fail closed and keep the graph consistent: the orphan node must
        // not be discoverable by a later prepare().
        (void)session->graphTopology.removeNode(trackId);
        std::snprintf(status, sizeof(status), "status=FAIL;reason=graph_connect_failed");
        return env->NewStringUTF(status);
    }

    session->trackOrder.push_back(trackId);
    session->tracks[trackId] = std::move(node);

    std::snprintf(status, sizeof(status),
        "status=PASS;trackId=%s;trackIndex=%zu;inputPort=%s;totalFrames=%lld;trackCount=%zu",
        trackId.c_str(),
        trackIndex,
        inputPortId.c_str(),
        static_cast<long long>(frames),
        session->trackOrder.size());
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: prepareAndroidDagPhase4AudioGraphExportSession
// One-way prepare barrier: freezes the topology and constructs the
// auto-discovery GraphAudioScheduler. Fails closed (session stays
// unprepared, scheduler discarded) unless the target is valid and every
// added track routed.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_prepareAndroidDagPhase4AudioGraphExportSession(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ) {

    char status[512];

    const std::string sid = JStringToStdString(env, sessionIdJ);
    const std::shared_ptr<GraphExportSession> session = FindGraphExportSession(sid);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_not_found");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->destroyed) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_destroyed");
        return env->NewStringUTF(status);
    }
    if (session->prepared) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_already_prepared");
        return env->NewStringUTF(status);
    }
    if (session->trackOrder.empty()) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=no_tracks_added");
        return env->NewStringUTF(status);
    }

    try {
        session->scheduler = std::make_unique<GraphAudioScheduler>(
            session->graphTopology, kMixNodeId, AutoDiscoverSourceProviders{},
            /*mixParams=*/nullptr);
    } catch (const std::exception& e) {
        session->scheduler.reset();
        std::snprintf(status, sizeof(status), "status=FAIL;reason=%s", e.what());
        return env->NewStringUTF(status);
    } catch (...) {
        session->scheduler.reset();
        std::snprintf(status, sizeof(status), "status=FAIL;reason=scheduler_construction_failed");
        return env->NewStringUTF(status);
    }

    if (!session->scheduler->targetValid()) {
        session->scheduler.reset();
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_target");
        return env->NewStringUTF(status);
    }
    if (session->scheduler->routedSourceCount() != session->trackOrder.size()) {
        const size_t routed = session->scheduler->routedSourceCount();
        session->scheduler.reset();
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=routed_source_count_mismatch:%zu/%zu",
            routed, session->trackOrder.size());
        return env->NewStringUTF(status);
    }

    session->snapshotGeneration = session->scheduler->snapshotGeneration();
    session->prepared = true;

    std::snprintf(status, sizeof(status),
        "status=PASS;routedSourceCount=%zu;requestedTrackCount=%zu;snapshotGeneration=%llu",
        session->scheduler->routedSourceCount(),
        session->trackOrder.size(),
        static_cast<unsigned long long>(session->snapshotGeneration));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: ingestAndroidDagPhase4AudioGraphExportTrackPcm
// Allowed only after prepare() (topology frozen). Pushes interleaved
// little-endian signed PCM16 from a direct ByteBuffer (byte offset 0)
// through the NODE-OWNED ring writer. Only a full write is accepted; any
// partial/rejected write fails closed with the writer's status token and
// the accepted count. Never calls setEos, ingestChunk, or requestSeek.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_ingestAndroidDagPhase4AudioGraphExportTrackPcm(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ,
    jstring trackIdJ,
    jobject pcmBufferJ,
    jint    frameCount) {

    char status[512];

    const std::string sid = JStringToStdString(env, sessionIdJ);
    const std::shared_ptr<GraphExportSession> session = FindGraphExportSession(sid);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_found;acceptedFrames=0");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->destroyed) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_destroyed;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    if (!session->prepared) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=session_not_prepared;acceptedFrames=0");
        return env->NewStringUTF(status);
    }

    const std::string trackId = JStringToStdString(env, trackIdJ);
    auto it = session->tracks.find(trackId);
    if (it == session->tracks.end()) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=track_not_found;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    if (frameCount < 1 || frameCount > kMaxIngestFrames) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=invalid_frame_count;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    if (!pcmBufferJ) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=null_pcm_buffer;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    const jlong bufferCapacityBytes = env->GetDirectBufferCapacity(pcmBufferJ);
    if (bufferCapacityBytes < 0) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=non_direct_buffer;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    void* rawAddr = env->GetDirectBufferAddress(pcmBufferJ);
    if (!rawAddr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=direct_buffer_address_unavailable;acceptedFrames=0");
        return env->NewStringUTF(status);
    }
    const int64_t requiredBytes =
        static_cast<int64_t>(frameCount) * session->channelCount * 2ll;
    if (static_cast<int64_t>(bufferCapacityBytes) < requiredBytes) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=insufficient_buffer_capacity;acceptedFrames=0");
        return env->NewStringUTF(status);
    }

    DecodedAudioPcmSourceNode& node = *it->second;
    int64_t accepted = 0;
    const WriterStatus writerStatus = node.ringWriter()->write(
        static_cast<const int16_t*>(rawAddr),
        static_cast<int64_t>(frameCount),
        session->sampleRate,
        session->channelCount,
        &accepted);

    if (writerStatus != WriterStatus::kOk || accepted != static_cast<int64_t>(frameCount)) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=ring_write_%s;acceptedFrames=%lld;framesRequested=%d",
            WriterStatusName(writerStatus),
            static_cast<long long>(accepted),
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;trackId=%s;acceptedFrames=%lld;ringAvailableReadFrames=%lld",
        trackId.c_str(),
        static_cast<long long>(accepted),
        static_cast<long long>(node.ring()->availableReadFrames()));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: renderAndroidDagPhase4AudioGraphExportWindow
// Contiguous export windows only: startFrame must equal the session's
// nextRenderFrame cursor. Provider underrun metrics are snapshotted around
// renderWindow(); any zero-fill growth fails the window closed with
// source_underrun:<trackId> (never a PASS), because zero-filled audio is
// corruption for an export session. kOk and kSilence are the only PASS
// scheduler results; the cursor/metrics advance only on PASS.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidDagPhase4AudioGraphExportWindow(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ,
    jlong   startFrame,
    jint    frameCount,
    jobject outPcmBufferJ) {

    char status[640];

    const std::string sid = JStringToStdString(env, sessionIdJ);
    const std::shared_ptr<GraphExportSession> session = FindGraphExportSession(sid);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_not_found");
        return env->NewStringUTF(status);
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->destroyed) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_destroyed");
        return env->NewStringUTF(status);
    }
    if (!session->prepared) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=session_not_prepared");
        return env->NewStringUTF(status);
    }
    if (frameCount < 1 || static_cast<int64_t>(frameCount) > session->maxFramesPerMix) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=invalid_frame_count");
        return env->NewStringUTF(status);
    }
    if (static_cast<int64_t>(startFrame) != session->nextRenderFrame) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=non_contiguous_window:%lld/%lld",
            static_cast<long long>(session->nextRenderFrame),
            static_cast<long long>(startFrame));
        return env->NewStringUTF(status);
    }
    if (!outPcmBufferJ) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=null_out_buffer");
        return env->NewStringUTF(status);
    }
    const jlong outCapacityBytes = env->GetDirectBufferCapacity(outPcmBufferJ);
    if (outCapacityBytes < 0) {
        std::snprintf(status, sizeof(status), "status=FAIL;reason=non_direct_buffer");
        return env->NewStringUTF(status);
    }
    void* outAddr = env->GetDirectBufferAddress(outPcmBufferJ);
    if (!outAddr) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=direct_buffer_address_unavailable");
        return env->NewStringUTF(status);
    }
    const int64_t requiredSamples =
        static_cast<int64_t>(frameCount) * session->channelCount;
    if (static_cast<int64_t>(outCapacityBytes) < requiredSamples * 2ll) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=insufficient_buffer_capacity");
        return env->NewStringUTF(status);
    }

    // Per-track provider underrun snapshot (fixed arrays: max 8 tracks).
    uint64_t underrunBefore[kMaxTrackCount]   = {0};
    uint64_t zeroFilledBefore[kMaxTrackCount] = {0};
    for (size_t i = 0; i < session->trackOrder.size(); ++i) {
        RingBufferAudioSampleProvider* provider =
            TrackProvider(*session->tracks[session->trackOrder[i]]);
        underrunBefore[i]   = provider->underrunEvents();
        zeroFilledBefore[i] = provider->framesZeroFilled();
    }

    GraphAudioScheduler::SchedulerOutput out{};
    const SchedulerResult result = session->scheduler->renderWindow(
        static_cast<int64_t>(startFrame),
        static_cast<int64_t>(frameCount),
        static_cast<int16_t*>(outAddr),
        requiredSamples,
        &out);

    // Underrun check first: a zero-filled window is corruption for this
    // export session even when the scheduler itself reported kOk/kSilence.
    for (size_t i = 0; i < session->trackOrder.size(); ++i) {
        RingBufferAudioSampleProvider* provider =
            TrackProvider(*session->tracks[session->trackOrder[i]]);
        if (provider->underrunEvents() != underrunBefore[i] ||
            provider->framesZeroFilled() != zeroFilledBefore[i]) {
            std::snprintf(status, sizeof(status),
                "status=FAIL;reason=source_underrun:%s;schedulerResult=%s",
                session->trackOrder[i].c_str(),
                SchedulerResultName(result));
            return env->NewStringUTF(status);
        }
    }

    if (result != SchedulerResult::kOk && result != SchedulerResult::kSilence) {
        std::snprintf(status, sizeof(status),
            "status=FAIL;reason=scheduler_result:%s", SchedulerResultName(result));
        return env->NewStringUTF(status);
    }

    session->nextRenderFrame += static_cast<int64_t>(frameCount);
    session->windowCount += 1;
    if (out.silence) {
        session->silentWindowCount += 1;
    }

    std::snprintf(status, sizeof(status),
        "status=PASS;framesRendered=%lld;routedTrackCount=%zu;mixCalled=%s;silence=%s;"
        "checksum=%016llx;windowCount=%lld;silentWindowCount=%lld;nextRenderFrame=%lld",
        static_cast<long long>(out.framesRendered),
        out.routedTrackCount,
        out.mixCalled ? "true" : "false",
        out.silence ? "true" : "false",
        static_cast<unsigned long long>(out.checksum),
        static_cast<long long>(session->windowCount),
        static_cast<long long>(session->silentWindowCount),
        static_cast<long long>(session->nextRenderFrame));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAndroidDagPhase4AudioGraphExportSession
// Idempotent erase-once under the registry mutex; both the first and any
// repeated destroy report status=PASS (destroyed=true only on the erase).
// An in-flight call that raced the erase keeps its shared_ptr, so the
// session is freed only when the last reference drops.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDagPhase4AudioGraphExportSession(
    JNIEnv* env,
    jobject /* this */,
    jstring sessionIdJ) {

    const std::string sid = JStringToStdString(env, sessionIdJ);

    std::shared_ptr<GraphExportSession> session;
    {
        std::lock_guard<std::mutex> lock(gGraphExportRegistryMutex);
        auto it = gGraphExportSessions.find(sid);
        if (it != gGraphExportSessions.end()) {
            session = it->second;
            gGraphExportSessions.erase(it);
        }
    }
    if (session) {
        std::lock_guard<std::mutex> lock(session->mutex);
        session->destroyed = true;
        return env->NewStringUTF("status=PASS;destroyed=true");
    }
    return env->NewStringUTF("status=PASS;destroyed=false;reason=already_destroyed");
}
