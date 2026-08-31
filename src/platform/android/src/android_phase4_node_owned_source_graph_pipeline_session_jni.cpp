// P4-AUDIO-DECODER-SOURCE-NODE-WIRING: session-scoped, step-driven
// closed-loop native audio graph pipeline JNI seam whose decoded-audio
// source ring/writer/provider triple is OWNED BY the DecodedAudioPcmSourceNode
// (6-arg constructor) and whose GraphAudioScheduler route is resolved by the
// tag-dispatched auto-discovery constructor from graph topology alone (no
// external provider map).
//
// One session = one rig, all owner-thread-only:
//   sourceNode->ringWriter() -> sourceNode->ring()
//     -> sourceNode->audioSampleProvider() (auto-discovered by
//     GraphAudioScheduler from Graph::inputConnections)
//     -> AudioMixBusNode -> ClockedAudioTransportCoordinator
//     -> output AudioSpscAudioRingBuffer -> consumer drain.
// Exactly one routed source, unit gain, bus channelCount == source
// channelCount (1 or 2).
//
// Honest non-claims:
// - Diagnostic node-owned decoded audio source ring/provider wiring proof
//   only: no production export or pass-2 graph reroute, no product/editor
//   UI, no ConnectsApp integration, no streaming/cache, no iOS.
// - Not a decoder: no MediaCodec/MediaExtractor/AMediaCodec ownership in
//   C++; Kotlin hands already-decoded synthetic interleaved little-endian
//   signed PCM16 chunks across a direct java.nio.ByteBuffer.
// - No AudioTrack/AAudio/OpenSL/Oboe, no realtime/audio-focus/route/
//   dead-object/audible/speaker/latency/glitch claims, no OS callbacks, no
//   C++->Kotlin callbacks.
// - Spawns no native worker threads; each session records its creating
//   std::thread::id and every non-destroy entry point fails closed with
//   status=wrong_owner_thread when driven from any other thread, so one
//   caller thread plays every producer/consumer ring role sequentially.
// - No file IO and no wall-clock reads: every clock/coordinator call is fed
//   a caller-derived sysTimeNs tick; the only sysTimeNs native ever derives
//   itself is the tail-flush clamp, computed purely from the caller-supplied
//   start/seek anchor via integer math.
// - No locks inside the vanguard audio primitives; the only mutex here
//   guards the session registry map lifecycle. Destroy is idempotent and
//   callable from any thread.
// - Zero native steady-state allocation: every status string is a fixed
//   stack char[] + snprintf; drain pops through a fixed stack scratch.
// - Writer-local EOS only. Forward-only seek.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt. Its session registry and handle counter are disjoint
// from every H1/J/K session TU: handles minted here are NOT interchangeable
// with any other pipeline session registry.
//
// JNI entry points (VanguardNativeBridge.kt companion object):
//   createNodeOwnedAudioSourceGraphPipelineSmokeSession  -> jlong handle (0 on failure)
//   ingestNodeOwnedAudioSourceGraphPipelinePcm16         -> jstring key=value
//   startNodeOwnedAudioSourceGraphPipeline               -> jstring key=value
//   stepNodeOwnedAudioSourceGraphPipeline                -> jstring key=value
//   drainNodeOwnedAudioSourceGraphPipelineOutput         -> jstring key=value
//   seekNodeOwnedAudioSourceGraphPipeline                -> jstring key=value
//   setNodeOwnedAudioSourceGraphPipelineEos              -> jstring key=value
//   snapshotNodeOwnedAudioSourceGraphPipeline            -> jstring key=value
//   destroyNodeOwnedAudioSourceGraphPipelineSmokeSession -> jstring key=value

#include <jni.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "vanguard/audio/audio_clock.h"
#include "vanguard/audio/audio_decoder_ring_writer.h"
#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/audio_ring_buffer.h"
#include "vanguard/audio/audio_sample_provider.h"
#include "vanguard/audio/clocked_audio_transport_coordinator.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/audio/ring_buffer_audio_sample_provider.h"
#include "vanguard/graph/graph.h"

namespace {

// Kept verbatim in this TU as the canonical native-side proof boundary; the
// Kotlin driver/coordinator carry the identical string and surface it over
// the MethodChannel, so it is not re-embedded in any fixed-size status
// buffer here.
[[maybe_unused]] constexpr const char* kProofBoundary =
    "diagnostic_node_owned_decoded_audio_source_ring_provider_wiring_proof_only_source_node_owns_ring_writer_provider_by_composition_scheduler_auto_discovers_provider_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_no_hybrid_routing_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_mediacodec_no_mediaextractor_no_cpp_os_decoder_ownership_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_no_audio_focus_no_route_no_dead_object_no_audible_no_speaker_no_latency_no_glitch_claims_no_streaming_no_cache_no_ios_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim";

using vanguard::audio::AudioClock;
using vanguard::audio::AudioDecoderRingWriter;
using vanguard::audio::AudioMixBusNode;
using vanguard::audio::AudioSampleProvider;
using vanguard::audio::AudioSpscAudioRingBuffer;
using vanguard::audio::AutoDiscoverSourceProviders;
using vanguard::audio::ClockedAudioTransportCoordinator;
using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::audio::GraphAudioScheduler;
using vanguard::audio::RingBufferAudioSampleProvider;
using vanguard::core::Status;
using vanguard::graph::Graph;
using DispatchResult = ClockedAudioTransportCoordinator::DispatchResult;
using DispatchOutput = ClockedAudioTransportCoordinator::DispatchOutput;
using WriterStatus   = AudioDecoderRingWriter::Status;

constexpr size_t  kMaxLiveSessions        = 4;
constexpr int64_t kMaxIngestFramesPerCall = AudioDecoderRingWriter::kMaxWriteFrames;      // 8192
constexpr int64_t kMaxRingCapacityFrames  = AudioSpscAudioRingBuffer::kMaxCapacityFrames; // 65536
constexpr int64_t kDrainChunkFrames       = 512;
// 128 chunks * 512 frames covers the largest legal ring in one call while
// keeping the pop loop strictly bounded.
constexpr int     kMaxDrainIterations     = 128;
constexpr int64_t kMicrosPerSecond        = 1'000'000LL;
constexpr int64_t kInt64Max               = std::numeric_limits<int64_t>::max();

constexpr const char* kMixNodeId    = "node_owned_pipeline_mix";
constexpr const char* kSourceNodeId = "node_owned_pipeline_src";

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

// 1:1 mapping of all 13 ClockedAudioTransportCoordinator::DispatchResult
// values to distinct status tokens.
const char* DispatchResultName(DispatchResult r) {
    switch (r) {
        case DispatchResult::kOk:                   return "dispatch_ok";
        case DispatchResult::kSilence:              return "dispatch_silence";
        case DispatchResult::kNoFramesDue:          return "no_frames_due";
        case DispatchResult::kBackpressure:         return "output_backpressure";
        case DispatchResult::kAwaitingSeekAck:      return "awaiting_seek_ack";
        case DispatchResult::kNotStarted:           return "not_started";
        case DispatchResult::kPaused:               return "paused";
        case DispatchResult::kNonMonotonicTime:     return "non_monotonic_time";
        case DispatchResult::kNonUnitySpeed:        return "non_unity_speed";
        case DispatchResult::kSchedulerError:       return "scheduler_error";
        case DispatchResult::kRingPushShortfall:    return "ring_push_shortfall";
        case DispatchResult::kClockError:           return "clock_error";
        case DispatchResult::kInvalidConfiguration: return "invalid_configuration";
    }
    return "unknown";
}

// Same simple signed-sample accumulation shape as the H1/J/K seams:
// checksum = checksum * 31 + uint16(sample).
uint64_t AccumulateChecksum(uint64_t checksum, const int16_t* samples, int64_t count) {
    for (int64_t i = 0; i < count; ++i) {
        checksum = checksum * 31u + static_cast<uint64_t>(static_cast<uint16_t>(samples[i]));
    }
    return checksum;
}

bool IsPowerOfTwoInRingRange(int64_t v) {
    return v >= 64 && v <= kMaxRingCapacityFrames && (v & (v - 1)) == 0;
}

// Populates the one-mix/one-source diagnostic topology before the scheduler
// member snapshots the graph generation; called from the session's member
// initializer list only.
const Graph& PrepareTopology(Graph& g,
                             const std::shared_ptr<AudioMixBusNode>& mixBus,
                             const std::shared_ptr<DecodedAudioPcmSourceNode>& sourceNode) {
    (void)g.addNode(mixBus);
    (void)g.addNode(sourceNode);
    (void)g.connect(kSourceNodeId, "audio_out", kMixNodeId, "primary_audio_in");
    return g;
}

// ---------------------------------------------------------------------------
// Diagnostic node-owned-source graph-pipeline session. Unlike the H1 seam,
// the session itself owns NO source ring, writer, or provider members: the
// DecodedAudioPcmSourceNode (6-arg constructor) owns that triple, and the
// GraphAudioScheduler discovers the provider from graph topology via the
// AutoDiscoverSourceProviders tag constructor. All non-destroy calls are
// owner-thread-only, so the per-session counters below are plain
// (non-atomic) owner-thread-private state. Member declaration order is
// construction order: the graph is populated (PrepareTopology) before the
// scheduler snapshots and walks it.
// ---------------------------------------------------------------------------
struct NodeOwnedPipelineSession {
    Graph                                       graphTopology;
    std::shared_ptr<AudioMixBusNode>            mixBus;
    std::shared_ptr<DecodedAudioPcmSourceNode>  sourceNode;
    AudioSpscAudioRingBuffer                    outputRing;
    GraphAudioScheduler                         scheduler;
    AudioClock                                  clock;
    ClockedAudioTransportCoordinator            coordinator;
    std::thread::id                             ownerThreadId;

    int32_t sampleRate;
    int32_t channelCount;
    int64_t maxFramesPerMix;

    // Caller-supplied clock anchor from the last successful start/seek; the
    // tail-flush sysTimeNs clamp is derived from this pair only (never a
    // wall clock).
    int64_t anchorMediaPtsUs{0};
    int64_t anchorSysTimeNs{0};
    bool    started{false};

    uint64_t nativeAcceptedChecksum{0};
    int64_t  totalFramesAccepted{0};
    uint64_t nativeOutputDrainChecksum{0};
    int64_t  totalOutputFramesDrained{0};

    NodeOwnedPipelineSession(int32_t sampleRateIn,
                             int32_t channelCountIn,
                             int64_t expectedFrameCountIn,
                             int64_t sourceRingCapacityFrames,
                             int64_t outputRingCapacityFrames,
                             int64_t maxFramesPerMixIn)
        : graphTopology(),
          mixBus(std::make_shared<AudioMixBusNode>(
              kMixNodeId, sampleRateIn, channelCountIn, maxFramesPerMixIn)),
          sourceNode(std::make_shared<DecodedAudioPcmSourceNode>(
              kSourceNodeId, sampleRateIn, channelCountIn, expectedFrameCountIn,
              /*timelineStartPtsUs=*/0, sourceRingCapacityFrames)),
          outputRing(sampleRateIn, channelCountIn, outputRingCapacityFrames),
          scheduler(PrepareTopology(graphTopology, mixBus, sourceNode),
                    kMixNodeId, AutoDiscoverSourceProviders{}),
          clock(),
          coordinator(clock, scheduler, outputRing),
          ownerThreadId(std::this_thread::get_id()),
          sampleRate(sampleRateIn),
          channelCount(channelCountIn),
          maxFramesPerMix(maxFramesPerMixIn) {}

    // The 6-arg node constructor is the only way this session is built, so
    // the node-owned triple is always present after a successful create
    // (createNodeOwnedAudioSourceGraphPipelineSmokeSession fails closed on
    // !ownsRing() before registering the handle).
    AudioSpscAudioRingBuffer& sourceRing() { return *sourceNode->ring(); }
    AudioDecoderRingWriter&   writer()     { return *sourceNode->ringWriter(); }
    // The 6-arg constructor's owned provider is always a
    // RingBufferAudioSampleProvider, so this downcast of the node's
    // base-typed accessor is exact (diagnostics-only metric access).
    RingBufferAudioSampleProvider& provider() {
        return *static_cast<RingBufferAudioSampleProvider*>(
            sourceNode->audioSampleProvider());
    }
};

// ---------------------------------------------------------------------------
// Session registry. Disjoint handle space from every other pipeline seam
// (own map, own counter). The mutex guards only this lifecycle map
// (create/lookup/destroy), never the audio primitives. Values are
// shared_ptr so an entry point that looked a session up stays safe even if
// destroy concurrently erases the map entry: the object is freed only when
// the last reference drops.
// ---------------------------------------------------------------------------
std::mutex gNodeOwnedPipelineRegistryMutex;
std::unordered_map<int64_t, std::shared_ptr<NodeOwnedPipelineSession>> gNodeOwnedPipelineSessions;
int64_t gNextNodeOwnedPipelineHandle = 1; // guarded by gNodeOwnedPipelineRegistryMutex

std::shared_ptr<NodeOwnedPipelineSession> FindNodeOwnedPipelineSession(jlong handle) {
    std::lock_guard<std::mutex> lock(gNodeOwnedPipelineRegistryMutex);
    auto it = gNodeOwnedPipelineSessions.find(static_cast<int64_t>(handle));
    return it == gNodeOwnedPipelineSessions.end() ? nullptr : it->second;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createNodeOwnedAudioSourceGraphPipelineSmokeSession
// Fail-closed construction validation: returns 0 on any invalid input, when
// the auto-discovered route did not resolve to exactly the one node-owned
// source track, or when the live-session cap is reached.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createNodeOwnedAudioSourceGraphPipelineSmokeSession(
    JNIEnv* /* env */,
    jobject /* companion */,
    jint sampleRate,
    jint channelCount,
    jint expectedFrameCount,
    jint sourceRingCapacityFrames,
    jint outputRingCapacityFrames,
    jint maxFramesPerMix) {

    const int64_t expFrames = static_cast<int64_t>(expectedFrameCount);
    const int64_t srcCap    = static_cast<int64_t>(sourceRingCapacityFrames);
    const int64_t outCap    = static_cast<int64_t>(outputRingCapacityFrames);
    const int64_t mfpm      = static_cast<int64_t>(maxFramesPerMix);

    if (sampleRate < 8000 || sampleRate > 192000) return 0;
    if (channelCount != 1 && channelCount != 2) return 0;
    // Mirrors DecodedAudioPcmSourceNode's own (0, 10*sampleRate] bound so an
    // out-of-range expected frame count fails closed as handle=0 here (the
    // node constructor would throw the same rejection); no new semantic cap
    // is introduced beyond the node's existing 10-second ceiling.
    if (expFrames < 1 || expFrames > 10ll * static_cast<int64_t>(sampleRate)) return 0;
    if (mfpm < 1 || mfpm > 8192) return 0;
    if (!IsPowerOfTwoInRingRange(srcCap)) return 0;
    if (!IsPowerOfTwoInRingRange(outCap)) return 0;
    if (outCap < mfpm) return 0;
    if (srcCap < 2 * mfpm) return 0;

    std::shared_ptr<NodeOwnedPipelineSession> session;
    try {
        session = std::make_shared<NodeOwnedPipelineSession>(
            static_cast<int32_t>(sampleRate),
            static_cast<int32_t>(channelCount),
            expFrames, srcCap, outCap, mfpm);
    } catch (...) {
        return 0;
    }

    // Fail closed unless the node owns its transport AND the auto-discovery
    // route resolved to exactly the one intended node-owned source track.
    if (!session->sourceNode->ownsRing() ||
        !session->scheduler.targetValid() ||
        session->scheduler.routedSourceCount() != 1 ||
        session->scheduler.routedSourceIdAt(0) != kSourceNodeId) {
        return 0;
    }

    std::lock_guard<std::mutex> lock(gNodeOwnedPipelineRegistryMutex);
    if (gNodeOwnedPipelineSessions.size() >= kMaxLiveSessions) return 0;
    const int64_t handle = gNextNodeOwnedPipelineHandle++;
    gNodeOwnedPipelineSessions[handle] = std::move(session);
    return static_cast<jlong>(handle);
}

// ---------------------------------------------------------------------------
// JNI: ingestNodeOwnedAudioSourceGraphPipelinePcm16
// Owner-thread-only producer side, writing through the NODE-OWNED
// sourceNode->ringWriter(). Treats `pcm` as interleaved little-endian signed
// PCM16 starting at byte offset 0 and clamps the accepted frame count to
// min(frameCount, 8192, capacityFramesFromBuffer).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_ingestNodeOwnedAudioSourceGraphPipelinePcm16(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jobject pcmBufferJ,
    jint frameCount) {

    char status[768];

    const std::shared_ptr<NodeOwnedPipelineSession> session =
        FindNodeOwnedPipelineSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;framesRequested=%d;framesAccepted=0", static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }
    if (frameCount <= 0) {
        std::snprintf(status, sizeof(status),
            "status=invalid_frame_count;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }
    if (!pcmBufferJ) {
        std::snprintf(status, sizeof(status),
            "status=null_pcm_buffer;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }

    const jlong bufferCapacityBytes = env->GetDirectBufferCapacity(pcmBufferJ);
    if (bufferCapacityBytes < 0) {
        std::snprintf(status, sizeof(status),
            "status=non_direct_buffer;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }
    void* rawAddr = env->GetDirectBufferAddress(pcmBufferJ);
    if (!rawAddr) {
        std::snprintf(status, sizeof(status),
            "status=direct_buffer_address_unavailable;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }

    const int64_t bytesPerFrame = 2ll * session->channelCount;
    const int64_t capacityFramesFromBuffer = static_cast<int64_t>(bufferCapacityBytes) / bytesPerFrame;
    if (capacityFramesFromBuffer <= 0) {
        std::snprintf(status, sizeof(status),
            "status=insufficient_buffer_capacity;framesRequested=%d;framesAccepted=0",
            static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    }

    const int64_t framesToWrite = std::min<int64_t>(
        {static_cast<int64_t>(frameCount), kMaxIngestFramesPerCall, capacityFramesFromBuffer});

    const int16_t* pcm = static_cast<const int16_t*>(rawAddr);
    int64_t framesAccepted = 0;
    const WriterStatus writerStatus = session->writer().write(
        pcm, framesToWrite, session->sampleRate, session->channelCount, &framesAccepted);

    if (framesAccepted > 0) {
        session->nativeAcceptedChecksum = AccumulateChecksum(
            session->nativeAcceptedChecksum, pcm, framesAccepted * session->channelCount);
        session->totalFramesAccepted += framesAccepted;
    }

    const AudioDecoderRingWriter::Metrics& m = session->writer().metrics();
    std::snprintf(status, sizeof(status),
        "status=ok;framesRequested=%d;framesAccepted=%lld;writerStatus=%s;"
        "writerAvailableToWrite=%lld;sourceAvailableReadFrames=%lld;"
        "writerTotalFramesWritten=%llu;writerPartialWriteEvents=%llu;"
        "writerBackpressureRejects=%llu;"
        "nativeAcceptedChecksumHex=%016llx;totalFramesAccepted=%lld",
        static_cast<int>(frameCount),
        static_cast<long long>(framesAccepted),
        WriterStatusName(writerStatus),
        static_cast<long long>(session->sourceRing().availableWriteFrames()),
        static_cast<long long>(session->sourceRing().availableReadFrames()),
        static_cast<unsigned long long>(m.totalFramesWritten),
        static_cast<unsigned long long>(m.partialWriteEvents),
        static_cast<unsigned long long>(m.backpressureRejects),
        static_cast<unsigned long long>(session->nativeAcceptedChecksum),
        static_cast<long long>(session->totalFramesAccepted));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: startNodeOwnedAudioSourceGraphPipeline
// Owner-thread-only. Starts the clock at (sysTimeNs, mediaPtsUs) via the
// coordinator, which also parks the dispatch cursor awaiting the output
// ring's seek ack -- the caller must drain that ack before the first
// dispatching step. Records the caller-supplied anchor for tail-flush ticks.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_startNodeOwnedAudioSourceGraphPipeline(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jlong mediaPtsUs,
    jlong sysTimeNs) {

    char status[320];

    const std::shared_ptr<NodeOwnedPipelineSession> session =
        FindNodeOwnedPipelineSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found;nextDispatchFrame=-1");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread;nextDispatchFrame=-1");
        return env->NewStringUTF(status);
    }

    const Status startStatus = session->coordinator.start(
        static_cast<int64_t>(mediaPtsUs), static_cast<int64_t>(sysTimeNs));
    if (!startStatus.ok()) {
        std::snprintf(status, sizeof(status),
            "status=start_failed;nextDispatchFrame=%lld",
            static_cast<long long>(session->coordinator.snapshot().nextDispatchFrame));
        return env->NewStringUTF(status);
    }

    session->anchorMediaPtsUs = static_cast<int64_t>(mediaPtsUs);
    session->anchorSysTimeNs  = static_cast<int64_t>(sysTimeNs);
    session->started          = true;

    const auto snap = session->coordinator.snapshot();
    std::snprintf(status, sizeof(status),
        "status=ok;nextDispatchFrame=%lld;awaitingSeekAck=%s",
        static_cast<long long>(snap.nextDispatchFrame),
        snap.awaitingSeekAck ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: stepNodeOwnedAudioSourceGraphPipeline
// Owner-thread-only. One bounded dispatch attempt at the caller-derived
// sysTimeNs tick; the scheduler pulls from the auto-discovered node-owned
// provider.
// - While the output ring's seek ack is pending, reports awaiting_seek_ack
//   without dispatching (no clock/cursor/ring mutation).
// - Underrun gate (flushTail=false): requires
//   sourceRing().availableReadFrames() >= maxFramesPerMix, else returns
//   status=deferred_insufficient_source with no clock/cursor/ring mutation.
// - Tail flush (flushTail=true, requires writer EOS): lowers the gate to
//   availableReadFrames() > 0 and clamps the dispatch tick (derived from the
//   caller-supplied start/seek anchor, never a wall clock) so exactly
//   min(available, maxFramesPerMix) frames advance; a short final window
//   reports tail_flush_partial_window, an empty source ring reports
//   tail_flush_complete.
// Every step status reports sourceAvailableReadFrames.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_stepNodeOwnedAudioSourceGraphPipeline(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jlong sysTimeNs,
    jboolean flushTail) {

    char status[768];

    const std::shared_ptr<NodeOwnedPipelineSession> session =
        FindNodeOwnedPipelineSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;framesRendered=0;sourceAvailableReadFrames=-1");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;framesRendered=0;sourceAvailableReadFrames=-1");
        return env->NewStringUTF(status);
    }

    NodeOwnedPipelineSession& s = *session;
    const int64_t sourceAvail = s.sourceRing().availableReadFrames();

    // Fixed helper: formats the common no-dispatch reply shape.
    auto replyNoDispatch = [&](const char* token) -> jstring {
        const auto snap = s.coordinator.snapshot();
        std::snprintf(status, sizeof(status),
            "status=%s;framesDue=0;framesRendered=0;framesPushed=0;"
            "nextDispatchFrame=%lld;sourceAvailableReadFrames=%lld;"
            "outputAvailableReadFrames=%lld;dispatchCount=%llu;silenceCount=%llu;terminal=%s",
            token,
            static_cast<long long>(snap.nextDispatchFrame),
            static_cast<long long>(s.sourceRing().availableReadFrames()),
            static_cast<long long>(s.outputRing.availableReadFrames()),
            static_cast<unsigned long long>(snap.dispatchCount),
            static_cast<unsigned long long>(snap.silenceCount),
            snap.terminal ? "true" : "false");
        return env->NewStringUTF(status);
    };

    // Output-ring seek ack still pending: report without dispatching so the
    // step performs no clock/cursor/ring mutation at all.
    if (s.outputRing.seekRequest() != s.outputRing.seekAck()) {
        return replyNoDispatch("awaiting_seek_ack");
    }

    int64_t dispatchSysTimeNs = static_cast<int64_t>(sysTimeNs);
    bool    tailWindow        = false;

    if (flushTail == JNI_TRUE) {
        if (!s.writer().isEos()) {
            return replyNoDispatch("tail_flush_requires_eos");
        }
        if (sourceAvail <= 0) {
            return replyNoDispatch("tail_flush_complete");
        }
        const int64_t framesTarget = std::min<int64_t>(sourceAvail, s.maxFramesPerMix);
        const int64_t targetFrame  = s.coordinator.snapshot().nextDispatchFrame + framesTarget;
        if (targetFrame > (kInt64Max - (kMicrosPerSecond - 1)) / kMicrosPerSecond) {
            return replyNoDispatch("tail_flush_overflow");
        }
        // Smallest ptsUs whose floor-frame is exactly targetFrame (valid for
        // sampleRate <= 1e6, enforced at construction).
        const int64_t targetPtsUs =
            (targetFrame * kMicrosPerSecond + s.sampleRate - 1) / s.sampleRate;
        if (targetPtsUs < s.anchorMediaPtsUs) {
            return replyNoDispatch("tail_flush_anchor_regression");
        }
        const int64_t deltaUs = targetPtsUs - s.anchorMediaPtsUs;
        if (deltaUs > (kInt64Max - s.anchorSysTimeNs) / 1000) {
            return replyNoDispatch("tail_flush_overflow");
        }
        const int64_t clampSysTimeNs = s.anchorSysTimeNs + deltaUs * 1000;
        dispatchSysTimeNs = std::min<int64_t>(dispatchSysTimeNs, clampSysTimeNs);
        tailWindow = true;
    } else {
        // Underrun gate: never dispatch a window the source ring cannot
        // fully satisfy; no clock/cursor/ring mutation on deferral.
        if (sourceAvail < s.maxFramesPerMix) {
            return replyNoDispatch("deferred_insufficient_source");
        }
    }

    DispatchOutput out;
    const DispatchResult result = s.coordinator.dispatchUntil(dispatchSysTimeNs, &out);

    const char* token = DispatchResultName(result);
    if (tailWindow && result == DispatchResult::kOk && out.framesRendered < s.maxFramesPerMix) {
        token = "tail_flush_partial_window";
    }

    const auto snap = s.coordinator.snapshot();
    std::snprintf(status, sizeof(status),
        "status=%s;framesDue=%lld;framesRendered=%lld;framesPushed=%lld;"
        "nextDispatchFrame=%lld;sourceAvailableReadFrames=%lld;"
        "outputAvailableReadFrames=%lld;dispatchCount=%llu;silenceCount=%llu;terminal=%s",
        token,
        static_cast<long long>(out.framesDue),
        static_cast<long long>(out.framesRendered),
        static_cast<long long>(out.framesPushed),
        static_cast<long long>(snap.nextDispatchFrame),
        static_cast<long long>(s.sourceRing().availableReadFrames()),
        static_cast<long long>(s.outputRing.availableReadFrames()),
        static_cast<unsigned long long>(snap.dispatchCount),
        static_cast<unsigned long long>(snap.silenceCount),
        snap.terminal ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: drainNodeOwnedAudioSourceGraphPipelineOutput
// Owner-thread-only output-ring reader side. No per-call heap allocation:
// pops through a fixed stack scratch buffer with a strictly bounded
// iteration count. Consumes a pending output-ring seek ack (start/seek)
// first, reporting any frames it had to discard at the boundary.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_drainNodeOwnedAudioSourceGraphPipelineOutput(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jint maxFrames) {

    char status[640];

    const std::shared_ptr<NodeOwnedPipelineSession> session =
        FindNodeOwnedPipelineSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;framesRequested=%d;framesDrained=0", static_cast<int>(maxFrames));
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;framesRequested=%d;framesDrained=0",
            static_cast<int>(maxFrames));
        return env->NewStringUTF(status);
    }
    if (maxFrames < 0) {
        std::snprintf(status, sizeof(status),
            "status=invalid_max_frames;framesRequested=%d;framesDrained=0",
            static_cast<int>(maxFrames));
        return env->NewStringUTF(status);
    }

    bool    seekAckConsumed       = false;
    int64_t discardedFramesOnSeek = 0;
    int64_t newStartFrame         = -1;
    {
        const int64_t unreadBeforeAck = session->outputRing.availableReadFrames();
        int64_t ackFrame = -1;
        if (session->outputRing.consumePendingSeekOnReaderThread(&ackFrame)) {
            seekAckConsumed       = true;
            discardedFramesOnSeek = unreadBeforeAck;
            newStartFrame         = ackFrame;
        }
    }

    // Stack-only scratch: kDrainChunkFrames frames at up to 2 channels.
    int16_t scratch[kDrainChunkFrames * 2];

    const int64_t framesToDrain = std::min<int64_t>(
        static_cast<int64_t>(maxFrames), kMaxRingCapacityFrames);
    const int32_t channels = session->channelCount;

    int64_t framesDrained = 0;
    int64_t remaining     = framesToDrain;
    for (int iter = 0; iter < kMaxDrainIterations && remaining > 0; ++iter) {
        const int64_t want = std::min<int64_t>(remaining, kDrainChunkFrames);
        const int64_t got  = session->outputRing.tryPopFrames(scratch, want);
        if (got <= 0) break;
        session->nativeOutputDrainChecksum = AccumulateChecksum(
            session->nativeOutputDrainChecksum, scratch, got * channels);
        framesDrained += got;
        remaining     -= got;
        if (got < want) break; // ring empty mid-chunk
    }
    session->totalOutputFramesDrained += framesDrained;

    std::snprintf(status, sizeof(status),
        "status=ok;framesRequested=%d;framesDrained=%lld;outputAvailableReadFrames=%lld;"
        "nativeOutputDrainChecksumHex=%016llx;totalOutputFramesDrained=%lld;"
        "seekAckConsumed=%s;discardedFramesOnSeek=%lld;newStartFrame=%lld",
        static_cast<int>(maxFrames),
        static_cast<long long>(framesDrained),
        static_cast<long long>(session->outputRing.availableReadFrames()),
        static_cast<unsigned long long>(session->nativeOutputDrainChecksum),
        static_cast<long long>(session->totalOutputFramesDrained),
        seekAckConsumed ? "true" : "false",
        static_cast<long long>(discardedFramesOnSeek),
        static_cast<long long>(newStartFrame));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: seekNodeOwnedAudioSourceGraphPipeline
// Owner-thread-only. Forward-only seek across the whole rig at once:
// requires a fully drained output ring and an empty node-owned source ring,
// requires targetFrame >= provider().expectedNextFrame() (backward seek is
// out of scope), publishes writer().requestSeek(targetFrame), immediately
// consumes the source-ring ack on this owner thread (asserting zero
// discarded frames), then coordinator.seek(targetPtsUs, sysTimeNs). The
// caller must drain the output-ring ack next.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_seekNodeOwnedAudioSourceGraphPipeline(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jlong targetPtsUs,
    jlong sysTimeNs) {

    char status[512];

    const std::shared_ptr<NodeOwnedPipelineSession> session =
        FindNodeOwnedPipelineSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;targetPtsUs=%lld;targetFrame=-1",
            static_cast<long long>(targetPtsUs));
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;targetPtsUs=%lld;targetFrame=-1",
            static_cast<long long>(targetPtsUs));
        return env->NewStringUTF(status);
    }

    NodeOwnedPipelineSession& s = *session;
    const int64_t targetFrame = ClockedAudioTransportCoordinator::frameOfPositionUs(
        static_cast<int64_t>(targetPtsUs), s.sampleRate);

    auto replySeek = [&](const char* token, int64_t discarded) -> jstring {
        std::snprintf(status, sizeof(status),
            "status=%s;targetPtsUs=%lld;targetFrame=%lld;discardedFramesOnSeek=%lld;"
            "providerExpectedNextFrame=%lld;writerNextWriteFrame=%lld;"
            "sourceAvailableReadFrames=%lld;outputAvailableReadFrames=%lld",
            token,
            static_cast<long long>(targetPtsUs),
            static_cast<long long>(targetFrame),
            static_cast<long long>(discarded),
            static_cast<long long>(s.provider().expectedNextFrame()),
            static_cast<long long>(s.writer().nextWriteFrame()),
            static_cast<long long>(s.sourceRing().availableReadFrames()),
            static_cast<long long>(s.outputRing.availableReadFrames()));
        return env->NewStringUTF(status);
    };

    if (s.outputRing.availableReadFrames() != 0) {
        return replySeek("output_ring_not_drained", 0);
    }
    if (s.sourceRing().availableReadFrames() != 0) {
        return replySeek("source_ring_not_empty", 0);
    }
    if (targetFrame < s.provider().expectedNextFrame()) {
        return replySeek("seek_target_behind_provider_cursor", 0);
    }

    const WriterStatus writerSeekStatus = s.writer().requestSeek(targetFrame);
    if (writerSeekStatus != WriterStatus::kOk) {
        return replySeek("writer_seek_rejected", 0);
    }

    // Consume the source-ring ack immediately on this owner thread; the ring
    // was verified empty above, so nothing may be discarded at the boundary.
    const int64_t unreadBeforeAck = s.sourceRing().availableReadFrames();
    int64_t sourceAckFrame = -1;
    if (!s.sourceRing().consumePendingSeekOnReaderThread(&sourceAckFrame)) {
        return replySeek("source_seek_ack_not_consumed", 0);
    }
    if (unreadBeforeAck != 0 || sourceAckFrame != targetFrame) {
        return replySeek("source_seek_boundary_mismatch", unreadBeforeAck);
    }

    const Status coordinatorSeekStatus = s.coordinator.seek(
        static_cast<int64_t>(targetPtsUs), static_cast<int64_t>(sysTimeNs));
    if (!coordinatorSeekStatus.ok()) {
        return replySeek("coordinator_seek_failed", 0);
    }

    s.anchorMediaPtsUs = static_cast<int64_t>(targetPtsUs);
    s.anchorSysTimeNs  = static_cast<int64_t>(sysTimeNs);

    return replySeek("ok", 0);
}

// ---------------------------------------------------------------------------
// JNI: setNodeOwnedAudioSourceGraphPipelineEos
// Owner-thread-only. Writer-local EOS only (cleared by the next successful
// seek request inside the node-owned AudioDecoderRingWriter).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_setNodeOwnedAudioSourceGraphPipelineEos(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    char status[128];

    const std::shared_ptr<NodeOwnedPipelineSession> session =
        FindNodeOwnedPipelineSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found;eos=false");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread;eos=false");
        return env->NewStringUTF(status);
    }

    session->writer().setEos();
    std::snprintf(status, sizeof(status), "status=ok;eos=%s",
        session->writer().isEos() ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: snapshotNodeOwnedAudioSourceGraphPipeline
// Owner-thread-only. Full diagnostic snapshot across the rig, including the
// node-owned-wiring facts (routedSourceCount/routedSourceId0/nodeOwnsRing)
// and the fixed-at-construction scratch/storage capacities the Kotlin
// driver compares before/after repeated cycles to prove zero native
// steady-state allocation.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_snapshotNodeOwnedAudioSourceGraphPipeline(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    char status[1920];

    const std::shared_ptr<NodeOwnedPipelineSession> session =
        FindNodeOwnedPipelineSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread");
        return env->NewStringUTF(status);
    }

    NodeOwnedPipelineSession& s = *session;
    const auto snap = s.coordinator.snapshot();
    const AudioDecoderRingWriter::Metrics& wm = s.writer().metrics();

    // Note: kProofBoundary is deliberately not embedded here; the Kotlin
    // driver carries the identical verbatim constant, and omitting it keeps
    // this status inside its fixed stack buffer.
    std::snprintf(status, sizeof(status),
        "status=ok;"
        "routedSourceCount=%zu;routedSourceId0=%s;nodeOwnsRing=%s;"
        "lastDispatchResult=%s;nextDispatchFrame=%lld;lastMediaPositionUs=%lld;"
        "totalFramesRendered=%lld;totalFramesPushed=%lld;dispatchCount=%llu;"
        "okCount=%llu;silenceCount=%llu;backpressureCount=%llu;schedulerErrorCount=%llu;"
        "awaitingSeekAck=%s;terminal=%s;"
        "providerExpectedNextFrame=%lld;providerUnderrunEvents=%llu;"
        "providerFramesZeroFilled=%llu;providerForwardSkipFrames=%llu;providerRewindRejects=%llu;"
        "writerEos=%s;writerNextWriteFrame=%lld;writerPartialWriteEvents=%llu;"
        "writerBackpressureRejects=%llu;writerSeekRequests=%llu;"
        "sourceAvailableReadFrames=%lld;outputAvailableReadFrames=%lld;"
        "sourceRingStorageCapacitySamples=%lld;outputRingStorageCapacitySamples=%lld;"
        "schedulerTrackScratchCapacitySamples=%zu;schedulerTrackScratchCapacityTracks=%zu;"
        "nativeAcceptedChecksumHex=%016llx;totalFramesAccepted=%lld;"
        "nativeOutputDrainChecksumHex=%016llx;totalOutputFramesDrained=%lld;"
        "sampleRate=%d;channelCount=%d;maxFramesPerMix=%lld",
        s.scheduler.routedSourceCount(),
        s.scheduler.routedSourceCount() > 0 ? s.scheduler.routedSourceIdAt(0).c_str() : "",
        s.sourceNode->ownsRing() ? "true" : "false",
        DispatchResultName(snap.lastResult),
        static_cast<long long>(snap.nextDispatchFrame),
        static_cast<long long>(snap.lastMediaPositionUs),
        static_cast<long long>(snap.totalFramesRendered),
        static_cast<long long>(snap.totalFramesPushed),
        static_cast<unsigned long long>(snap.dispatchCount),
        static_cast<unsigned long long>(snap.okCount),
        static_cast<unsigned long long>(snap.silenceCount),
        static_cast<unsigned long long>(snap.backpressureCount),
        static_cast<unsigned long long>(snap.schedulerErrorCount),
        snap.awaitingSeekAck ? "true" : "false",
        snap.terminal ? "true" : "false",
        static_cast<long long>(s.provider().expectedNextFrame()),
        static_cast<unsigned long long>(s.provider().underrunEvents()),
        static_cast<unsigned long long>(s.provider().framesZeroFilled()),
        static_cast<unsigned long long>(s.provider().forwardSkipFrames()),
        static_cast<unsigned long long>(s.provider().rewindRejects()),
        s.writer().isEos() ? "true" : "false",
        static_cast<long long>(s.writer().nextWriteFrame()),
        static_cast<unsigned long long>(wm.partialWriteEvents),
        static_cast<unsigned long long>(wm.backpressureRejects),
        static_cast<unsigned long long>(wm.seekRequests),
        static_cast<long long>(s.sourceRing().availableReadFrames()),
        static_cast<long long>(s.outputRing.availableReadFrames()),
        static_cast<long long>(s.sourceRing().storageCapacitySamples()),
        static_cast<long long>(s.outputRing.storageCapacitySamples()),
        s.scheduler.trackScratchCapacitySamples(),
        s.scheduler.trackScratchCapacityTracks(),
        static_cast<unsigned long long>(s.nativeAcceptedChecksum),
        static_cast<long long>(s.totalFramesAccepted),
        static_cast<unsigned long long>(s.nativeOutputDrainChecksum),
        static_cast<long long>(s.totalOutputFramesDrained),
        static_cast<int>(s.sampleRate),
        static_cast<int>(s.channelCount),
        static_cast<long long>(s.maxFramesPerMix));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyNodeOwnedAudioSourceGraphPipelineSmokeSession
// Callable from any thread. Idempotent erase-once: handle 0/unknown returns
// status=not_found; a live handle is erased exactly once and returns
// status=ok. A concurrently in-flight call keeps its shared_ptr reference,
// so the session is freed only when the last reference drops (no leaks, no
// use-after-free).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    bool erased = false;
    {
        std::lock_guard<std::mutex> lock(gNodeOwnedPipelineRegistryMutex);
        erased = gNodeOwnedPipelineSessions.erase(static_cast<int64_t>(sessionHandle)) > 0;
    }
    return env->NewStringUTF(erased ? "status=ok" : "status=not_found");
}
