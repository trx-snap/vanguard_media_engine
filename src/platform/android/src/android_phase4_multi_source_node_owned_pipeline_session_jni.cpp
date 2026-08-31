// P4-AUDIO-MULTI-SOURCE-NODE-OWNED-PIPELINE (Android Phase 4 foundation
// under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): session-scoped,
// step-driven, TWO-SOURCE closed-loop native audio graph pipeline JNI seam
// whose per-track decoded-audio source ring/writer/provider triples are
// OWNED BY the two DecodedAudioPcmSourceNode instances (6-arg constructor)
// and whose GraphAudioScheduler routes are resolved by the tag-dispatched
// auto-discovery constructor from graph topology alone (no external
// provider map, no hybrid routing).
//
// One session = one rig, all owner-thread-only:
//   track0: sourceNode0->ringWriter() -> sourceNode0->ring()
//             -> sourceNode0->audioSampleProvider() ─┐
//   track1: sourceNode1->ringWriter() -> sourceNode1->ring()   │
//             -> sourceNode1->audioSampleProvider() ─┤
//               (both auto-discovered by GraphAudioScheduler   │
//                from Graph::inputConnections)                 │
//                                                    ├-> GraphAudioScheduler
//                                                    │     -> AudioMixBusNode
//   ClockedAudioTransportCoordinator <───────────────┘
//     -> output AudioSpscAudioRingBuffer -> consumer drain.
// Topology: multi_source_node_owned_src0 -> primary_audio_in and
// multi_source_node_owned_src1 -> secondary_audio_in, exactly two routed
// tracks at unit gain, bus channelCount == source channelCount (1 or 2).
//
// The native frame axis is the SHARED ACCEPTED FRAME COUNT (full overlap
// only): the joint dispatch gate requires a full window on BOTH source
// rings, the joint tail flush requires BOTH writers EOS with byte-identical
// per-track availability, and the one forward seek re-anchors BOTH tracks
// at a single accepted frame cursor. No independent EOS (the single EOS
// entry point sets both writers together), no ragged tail, no post-EOS
// intentional silence.
//
// Honest non-claims:
// - Not a decoder: no MediaCodec/MediaExtractor/AMediaCodec ownership in
//   C++ and no second OS decoder anywhere; Kotlin hands already-decoded
//   (track0) and Kotlin-synthesized (track1) interleaved little-endian
//   signed PCM16 chunks across direct java.nio.ByteBuffers.
// - No AudioTrack/AAudio/OpenSL/Oboe, no sink-clocked transport, no
//   realtime or audible playback, no audio-focus/route/dead-object/speaker/
//   latency/glitch claims, no OS callbacks, no C++->Kotlin callbacks.
// - Spawns no native worker threads; each session records its creating
//   std::thread::id and every non-destroy entry point fails closed with
//   status=wrong_owner_thread when driven from any other thread.
// - No file IO and no wall-clock reads: every clock/coordinator call is fed
//   a caller-derived sysTimeNs tick; the only sysTimeNs native ever derives
//   itself is the tail-flush clamp, computed purely from the caller-supplied
//   start/seek anchor via integer math.
// - No locks inside the vanguard audio primitives; the only mutex here
//   guards the session registry map lifecycle.
// - Zero native steady-state allocation: every status string is a fixed
//   stack char[] appended via bounded snprintf; drain pops through a fixed
//   stack scratch.
// - Writer-local EOS only. Forward-only seek.
// - No export or pass-2 graph reroute, no streaming/cache, no iOS, no
//   product/editor UI.
//
// This translation unit owns its own anonymous-namespace session registry,
// registry mutex, and handle space: handles minted here are NOT
// interchangeable with the external-provider-map multi-source TU
// (android_phase4_multi_source_graph_pipeline_session_jni.cpp), the
// one-source node-owned TU
// (android_phase4_node_owned_source_graph_pipeline_session_jni.cpp), or any
// other diagnostic session registry.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (VanguardNativeBridge.kt companion object):
//   createMultiSourceNodeOwnedAudioGraphPipelineSmokeSession  -> jlong handle (0 on failure)
//   ingestMultiSourceNodeOwnedAudioGraphPipelinePcm16         -> jstring key=value
//   startMultiSourceNodeOwnedAudioGraphPipeline               -> jstring key=value
//   stepMultiSourceNodeOwnedAudioGraphPipeline                -> jstring key=value
//   drainMultiSourceNodeOwnedAudioGraphPipelineOutput         -> jstring key=value
//   seekMultiSourceNodeOwnedAudioGraphPipeline                -> jstring key=value
//   setMultiSourceNodeOwnedAudioGraphPipelineEos              -> jstring key=value
//   snapshotMultiSourceNodeOwnedAudioGraphPipeline            -> jstring key=value
//   destroyMultiSourceNodeOwnedAudioGraphPipelineSmokeSession -> jstring key=value

#include <jni.h>

#include <algorithm>
#include <cstdarg>
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

// Canonical proof boundary, embedded verbatim in the snapshot status and
// carried identically by the Kotlin driver/coordinator payload.
constexpr const char* kProofBoundary =
    "kotlin_owned_real_decoder_plus_synthetic_second_track_step_driven_multi_source_node_owned_closed_loop_native_audio_graph_pipeline_session_proof_only_source_nodes_own_ring_writer_provider_by_composition_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_no_hybrid_routing_no_second_os_decoder_no_cpp_os_decoder_no_mediacodec_no_mediaextractor_ownership_in_cpp_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_sink_clocked_transport_no_audible_or_realtime_playback_no_audio_focus_no_route_no_dead_object_no_speaker_no_latency_no_glitch_claims_diagnostic_graph_topology_only_two_routed_tracks_unit_gain_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_streaming_no_cache_no_ios_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim";

using vanguard::audio::AudioClock;
using vanguard::audio::AudioDecoderRingWriter;
using vanguard::audio::AudioMixBusNode;
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

constexpr const char* kMixNodeId     = "multi_source_node_owned_pipeline_mix";
constexpr const char* kSource0NodeId = "multi_source_node_owned_src0";
constexpr const char* kSource1NodeId = "multi_source_node_owned_src1";

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

// Same simple signed-sample accumulation shape as the adjacent pipeline
// seams: checksum = checksum * 31 + uint16(sample).
uint64_t AccumulateChecksum(uint64_t checksum, const int16_t* samples, int64_t count) {
    for (int64_t i = 0; i < count; ++i) {
        checksum = checksum * 31u + static_cast<uint64_t>(static_cast<uint16_t>(samples[i]));
    }
    return checksum;
}

bool IsPowerOfTwoInRingRange(int64_t v) {
    return v >= 64 && v <= kMaxRingCapacityFrames && (v & (v - 1)) == 0;
}

// Bounded stack-buffer appender used to build the wider two-track status
// strings from several snprintf pieces without any heap allocation.
// Overflow is latched instead of silently truncating; callers must check
// overflowed() and fail closed.
class StatusAppender {
public:
    StatusAppender(char* buf, size_t cap) : buf_(buf), cap_(cap) {
        if (cap_ > 0) buf_[0] = '\0';
    }

    void appendf(const char* fmt, ...) {
        if (overflow_ || len_ >= cap_) { overflow_ = true; return; }
        va_list args;
        va_start(args, fmt);
        const int written = std::vsnprintf(buf_ + len_, cap_ - len_, fmt, args);
        va_end(args);
        if (written < 0 || static_cast<size_t>(written) >= cap_ - len_) {
            overflow_ = true;
            return;
        }
        len_ += static_cast<size_t>(written);
    }

    bool overflowed() const { return overflow_; }

private:
    char*  buf_;
    size_t cap_;
    size_t len_{0};
    bool   overflow_{false};
};

// Populates the one-mix/two-source diagnostic topology before the scheduler
// member snapshots and walks the graph generation; called from the
// session's member initializer list only. Edge-insertion order is the
// auto-discovery routed order: src0 -> primary_audio_in first,
// src1 -> secondary_audio_in second.
const Graph& PrepareTopology(Graph& g,
                             const std::shared_ptr<AudioMixBusNode>& mixBus,
                             const std::shared_ptr<DecodedAudioPcmSourceNode>& sourceNode0,
                             const std::shared_ptr<DecodedAudioPcmSourceNode>& sourceNode1) {
    (void)g.addNode(mixBus);
    (void)g.addNode(sourceNode0);
    (void)g.addNode(sourceNode1);
    (void)g.connect(kSource0NodeId, "audio_out", kMixNodeId, "primary_audio_in");
    (void)g.connect(kSource1NodeId, "audio_out", kMixNodeId, "secondary_audio_in");
    return g;
}

// ---------------------------------------------------------------------------
// Diagnostic two-source node-owned graph-pipeline session. Unlike the
// external-provider-map multi-source seam, the session itself owns NO
// source ring, writer, or provider members: each DecodedAudioPcmSourceNode
// (6-arg constructor) owns its own triple, and the GraphAudioScheduler
// discovers both providers from graph topology via the
// AutoDiscoverSourceProviders tag constructor. All non-destroy calls are
// owner-thread-only, so the per-session counters below are plain
// (non-atomic) owner-thread-private state. Member declaration order is
// construction order: the graph is populated (PrepareTopology) before the
// scheduler snapshots and walks it.
// ---------------------------------------------------------------------------
struct MultiSourceNodeOwnedPipelineSession {
    Graph                                       graphTopology;
    std::shared_ptr<AudioMixBusNode>            mixBus;
    std::shared_ptr<DecodedAudioPcmSourceNode>  sourceNode0;
    std::shared_ptr<DecodedAudioPcmSourceNode>  sourceNode1;
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

    uint64_t nativeAcceptedChecksum[2]{0, 0};
    int64_t  totalFramesAccepted[2]{0, 0};
    uint64_t nativeOutputDrainChecksum{0};
    int64_t  totalOutputFramesDrained{0};

    MultiSourceNodeOwnedPipelineSession(int32_t sampleRateIn,
                                        int32_t channelCountIn,
                                        int64_t expectedFrameCountIn,
                                        int64_t sourceRingCapacityFrames,
                                        int64_t outputRingCapacityFrames,
                                        int64_t maxFramesPerMixIn)
        : graphTopology(),
          mixBus(std::make_shared<AudioMixBusNode>(
              kMixNodeId, sampleRateIn, channelCountIn, maxFramesPerMixIn)),
          sourceNode0(std::make_shared<DecodedAudioPcmSourceNode>(
              kSource0NodeId, sampleRateIn, channelCountIn, expectedFrameCountIn,
              /*timelineStartPtsUs=*/0, sourceRingCapacityFrames)),
          sourceNode1(std::make_shared<DecodedAudioPcmSourceNode>(
              kSource1NodeId, sampleRateIn, channelCountIn, expectedFrameCountIn,
              /*timelineStartPtsUs=*/0, sourceRingCapacityFrames)),
          outputRing(sampleRateIn, channelCountIn, outputRingCapacityFrames),
          scheduler(PrepareTopology(graphTopology, mixBus, sourceNode0, sourceNode1),
                    kMixNodeId, AutoDiscoverSourceProviders{}),
          clock(),
          coordinator(clock, scheduler, outputRing),
          ownerThreadId(std::this_thread::get_id()),
          sampleRate(sampleRateIn),
          channelCount(channelCountIn),
          maxFramesPerMix(maxFramesPerMixIn) {}

    std::shared_ptr<DecodedAudioPcmSourceNode>& sourceNodeAt(int t) {
        return t == 0 ? sourceNode0 : sourceNode1;
    }

    // The 6-arg node constructor is the only way this session is built, so
    // both node-owned triples are always present after a successful create
    // (createMultiSourceNodeOwnedAudioGraphPipelineSmokeSession fails
    // closed on !ownsRing() before registering the handle).
    AudioSpscAudioRingBuffer& sourceRingAt(int t) { return *sourceNodeAt(t)->ring(); }
    AudioDecoderRingWriter&   writerAt(int t)     { return *sourceNodeAt(t)->ringWriter(); }
    // The 6-arg constructor's owned provider is always a
    // RingBufferAudioSampleProvider, so this downcast of the node's
    // base-typed accessor is exact (diagnostics-only metric access).
    RingBufferAudioSampleProvider& providerAt(int t) {
        return *static_cast<RingBufferAudioSampleProvider*>(
            sourceNodeAt(t)->audioSampleProvider());
    }
};

// ---------------------------------------------------------------------------
// Session registry. Private to this TU: its mutex guards only this lifecycle
// map (create/lookup/destroy), never the audio primitives, and its handle
// space is disjoint from every other diagnostic session registry (handles
// are NOT interchangeable with the external-provider-map multi-source TU or
// the one-source node-owned TU). Values are shared_ptr so an entry point
// that looked a session up stays safe even if destroy concurrently erases
// the map entry.
// ---------------------------------------------------------------------------
std::mutex gMultiSourceNodeOwnedRegistryMutex;
std::unordered_map<int64_t, std::shared_ptr<MultiSourceNodeOwnedPipelineSession>>
    gMultiSourceNodeOwnedSessions;
int64_t gNextMultiSourceNodeOwnedHandle = 1; // guarded by gMultiSourceNodeOwnedRegistryMutex

std::shared_ptr<MultiSourceNodeOwnedPipelineSession> FindMultiSourceNodeOwnedSession(
    jlong handle) {
    std::lock_guard<std::mutex> lock(gMultiSourceNodeOwnedRegistryMutex);
    auto it = gMultiSourceNodeOwnedSessions.find(static_cast<int64_t>(handle));
    return it == gMultiSourceNodeOwnedSessions.end() ? nullptr : it->second;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createMultiSourceNodeOwnedAudioGraphPipelineSmokeSession
// Fail-closed construction validation: returns 0 on any invalid input, when
// either source node does not own its transport, when the auto-discovered
// two-track topology/route did not resolve exactly as intended, or when the
// live-session cap is reached.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createMultiSourceNodeOwnedAudioGraphPipelineSmokeSession(
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

    std::shared_ptr<MultiSourceNodeOwnedPipelineSession> session;
    try {
        session = std::make_shared<MultiSourceNodeOwnedPipelineSession>(
            static_cast<int32_t>(sampleRate),
            static_cast<int32_t>(channelCount),
            expFrames, srcCap, outCap, mfpm);
    } catch (...) {
        return 0;
    }

    // Fail closed unless BOTH nodes own their transport AND the
    // auto-discovery route resolved to exactly the two intended node-owned
    // source tracks in the intended edge order.
    if (!session->sourceNode0->ownsRing() ||
        !session->sourceNode1->ownsRing() ||
        !session->scheduler.targetValid() ||
        session->scheduler.routedSourceCount() != 2 ||
        session->scheduler.routedSourceIdAt(0) != kSource0NodeId ||
        session->scheduler.routedSourceIdAt(1) != kSource1NodeId) {
        return 0;
    }

    std::lock_guard<std::mutex> lock(gMultiSourceNodeOwnedRegistryMutex);
    if (gMultiSourceNodeOwnedSessions.size() >= kMaxLiveSessions) return 0;
    const int64_t handle = gNextMultiSourceNodeOwnedHandle++;
    gMultiSourceNodeOwnedSessions[handle] = std::move(session);
    return static_cast<jlong>(handle);
}

// ---------------------------------------------------------------------------
// JNI: ingestMultiSourceNodeOwnedAudioGraphPipelinePcm16
// Owner-thread-only producer side for one track, writing through that
// track's NODE-OWNED sourceNode->ringWriter(). Precondition order:
// not_found, wrong_owner_thread, invalid_track_index, then the remaining
// argument validation. Treats `pcm` as interleaved little-endian signed
// PCM16 starting at byte offset 0 and clamps the accepted frame count to
// min(frameCount, 8192, capacityFramesFromBuffer).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_ingestMultiSourceNodeOwnedAudioGraphPipelinePcm16(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jint trackIndex,
    jobject pcmBufferJ,
    jint frameCount) {

    char status[896];

    auto replyReject = [&](const char* token) -> jstring {
        std::snprintf(status, sizeof(status),
            "status=%s;trackIndex=%d;framesRequested=%d;framesAccepted=0",
            token, static_cast<int>(trackIndex), static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    };

    const std::shared_ptr<MultiSourceNodeOwnedPipelineSession> session =
        FindMultiSourceNodeOwnedSession(sessionHandle);
    if (!session) {
        return replyReject("not_found");
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        return replyReject("wrong_owner_thread");
    }
    if (trackIndex != 0 && trackIndex != 1) {
        return replyReject("invalid_track_index");
    }
    if (frameCount <= 0) {
        return replyReject("invalid_frame_count");
    }
    if (!pcmBufferJ) {
        return replyReject("null_pcm_buffer");
    }

    const jlong bufferCapacityBytes = env->GetDirectBufferCapacity(pcmBufferJ);
    if (bufferCapacityBytes < 0) {
        return replyReject("non_direct_buffer");
    }
    void* rawAddr = env->GetDirectBufferAddress(pcmBufferJ);
    if (!rawAddr) {
        return replyReject("direct_buffer_address_unavailable");
    }

    const int64_t bytesPerFrame = 2ll * session->channelCount;
    const int64_t capacityFramesFromBuffer = static_cast<int64_t>(bufferCapacityBytes) / bytesPerFrame;
    if (capacityFramesFromBuffer <= 0) {
        return replyReject("insufficient_buffer_capacity");
    }

    const int     track = static_cast<int>(trackIndex);
    const int64_t framesToWrite = std::min<int64_t>(
        {static_cast<int64_t>(frameCount), kMaxIngestFramesPerCall, capacityFramesFromBuffer});

    MultiSourceNodeOwnedPipelineSession& s = *session;
    const int16_t* pcm = static_cast<const int16_t*>(rawAddr);
    int64_t framesAccepted = 0;
    const WriterStatus writerStatus = s.writerAt(track).write(
        pcm, framesToWrite, s.sampleRate, s.channelCount, &framesAccepted);

    if (framesAccepted > 0) {
        s.nativeAcceptedChecksum[track] = AccumulateChecksum(
            s.nativeAcceptedChecksum[track], pcm, framesAccepted * s.channelCount);
        s.totalFramesAccepted[track] += framesAccepted;
    }

    const AudioDecoderRingWriter::Metrics& m = s.writerAt(track).metrics();
    std::snprintf(status, sizeof(status),
        "status=ok;trackIndex=%d;framesRequested=%d;framesAccepted=%lld;writerStatus=%s;"
        "writerAvailableToWrite=%lld;sourceAvailableReadFrames=%lld;"
        "writerTotalFramesWritten=%llu;writerPartialWriteEvents=%llu;"
        "writerBackpressureRejects=%llu;"
        "nativeAcceptedChecksumHex=%016llx;totalFramesAccepted=%lld;"
        "totalFramesAcceptedTrack0=%lld;totalFramesAcceptedTrack1=%lld;"
        "sourceAvailableReadFramesTrack0=%lld;sourceAvailableReadFramesTrack1=%lld",
        track,
        static_cast<int>(frameCount),
        static_cast<long long>(framesAccepted),
        WriterStatusName(writerStatus),
        static_cast<long long>(s.sourceRingAt(track).availableWriteFrames()),
        static_cast<long long>(s.sourceRingAt(track).availableReadFrames()),
        static_cast<unsigned long long>(m.totalFramesWritten),
        static_cast<unsigned long long>(m.partialWriteEvents),
        static_cast<unsigned long long>(m.backpressureRejects),
        static_cast<unsigned long long>(s.nativeAcceptedChecksum[track]),
        static_cast<long long>(s.totalFramesAccepted[track]),
        static_cast<long long>(s.totalFramesAccepted[0]),
        static_cast<long long>(s.totalFramesAccepted[1]),
        static_cast<long long>(s.sourceRingAt(0).availableReadFrames()),
        static_cast<long long>(s.sourceRingAt(1).availableReadFrames()));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: startMultiSourceNodeOwnedAudioGraphPipeline
// Owner-thread-only. Starts the clock at (sysTimeNs, mediaPtsUs) via the
// coordinator, which also parks the dispatch cursor awaiting the output
// ring's seek ack -- the caller must drain that ack before the first
// dispatching step. Records the caller-supplied anchor for tail-flush ticks.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_startMultiSourceNodeOwnedAudioGraphPipeline(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jlong mediaPtsUs,
    jlong sysTimeNs) {

    char status[320];

    const std::shared_ptr<MultiSourceNodeOwnedPipelineSession> session =
        FindMultiSourceNodeOwnedSession(sessionHandle);
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
// JNI: stepMultiSourceNodeOwnedAudioGraphPipeline
// Owner-thread-only. One bounded dispatch attempt at the caller-derived
// sysTimeNs tick; the scheduler pulls from the two auto-discovered
// node-owned providers.
// - While the output ring's seek ack is pending, reports awaiting_seek_ack
//   without dispatching (no clock/cursor/ring mutation).
// - Joint underrun gate (flushTail=false): requires
//   min(sourceRing0.availableReadFrames(), sourceRing1.availableReadFrames())
//   >= maxFramesPerMix (no EOS term), else returns
//   status=deferred_insufficient_joint_source with no clock/cursor/ring
//   mutation.
// - Joint tail flush (flushTail=true): requires BOTH writers EOS. Both
//   source rings empty reports tail_flush_complete; differing per-track
//   availability (which covers exactly one ring empty) fails closed with
//   tail_flush_track_length_mismatch and dispatches nothing (no zero-fill).
//   Otherwise it clamps the dispatch tick (derived from the caller-supplied
//   start/seek anchor, never a wall clock) so exactly
//   min(avail0, avail1, maxFramesPerMix) frames advance; a short final
//   window reports tail_flush_partial_window.
// Every step status reports both per-track sourceAvailableReadFrames.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_stepMultiSourceNodeOwnedAudioGraphPipeline(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jlong sysTimeNs,
    jboolean flushTail) {

    char status[896];

    const std::shared_ptr<MultiSourceNodeOwnedPipelineSession> session =
        FindMultiSourceNodeOwnedSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;framesRendered=0;"
            "sourceAvailableReadFramesTrack0=-1;sourceAvailableReadFramesTrack1=-1");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;framesRendered=0;"
            "sourceAvailableReadFramesTrack0=-1;sourceAvailableReadFramesTrack1=-1");
        return env->NewStringUTF(status);
    }

    MultiSourceNodeOwnedPipelineSession& s = *session;
    const int64_t sourceAvail0 = s.sourceRingAt(0).availableReadFrames();
    const int64_t sourceAvail1 = s.sourceRingAt(1).availableReadFrames();
    const int64_t jointAvail   = std::min<int64_t>(sourceAvail0, sourceAvail1);

    // Fixed helper: formats the common no-dispatch reply shape.
    auto replyNoDispatch = [&](const char* token) -> jstring {
        const auto snap = s.coordinator.snapshot();
        std::snprintf(status, sizeof(status),
            "status=%s;framesDue=0;framesRendered=0;framesPushed=0;"
            "nextDispatchFrame=%lld;"
            "sourceAvailableReadFramesTrack0=%lld;sourceAvailableReadFramesTrack1=%lld;"
            "outputAvailableReadFrames=%lld;dispatchCount=%llu;silenceCount=%llu;terminal=%s",
            token,
            static_cast<long long>(snap.nextDispatchFrame),
            static_cast<long long>(s.sourceRingAt(0).availableReadFrames()),
            static_cast<long long>(s.sourceRingAt(1).availableReadFrames()),
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
        if (!s.writerAt(0).isEos() || !s.writerAt(1).isEos()) {
            return replyNoDispatch("tail_flush_requires_eos");
        }
        // Shared accepted-frame axis only: the joint tail is legal only when
        // both rings hold exactly the same residual frame count. A differing
        // availability (including exactly one empty ring) is a ragged tail,
        // which this slice fails closed on instead of zero-filling.
        if (sourceAvail0 != sourceAvail1) {
            return replyNoDispatch("tail_flush_track_length_mismatch");
        }
        if (sourceAvail0 <= 0) {
            return replyNoDispatch("tail_flush_complete");
        }
        const int64_t framesTarget = std::min<int64_t>(jointAvail, s.maxFramesPerMix);
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
        // Joint underrun gate: never dispatch a window either source ring
        // cannot fully satisfy; no clock/cursor/ring mutation on deferral.
        // Deliberately no EOS term (full-overlap axis only).
        if (jointAvail < s.maxFramesPerMix) {
            return replyNoDispatch("deferred_insufficient_joint_source");
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
        "nextDispatchFrame=%lld;"
        "sourceAvailableReadFramesTrack0=%lld;sourceAvailableReadFramesTrack1=%lld;"
        "outputAvailableReadFrames=%lld;dispatchCount=%llu;silenceCount=%llu;terminal=%s",
        token,
        static_cast<long long>(out.framesDue),
        static_cast<long long>(out.framesRendered),
        static_cast<long long>(out.framesPushed),
        static_cast<long long>(snap.nextDispatchFrame),
        static_cast<long long>(s.sourceRingAt(0).availableReadFrames()),
        static_cast<long long>(s.sourceRingAt(1).availableReadFrames()),
        static_cast<long long>(s.outputRing.availableReadFrames()),
        static_cast<unsigned long long>(snap.dispatchCount),
        static_cast<unsigned long long>(snap.silenceCount),
        snap.terminal ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: drainMultiSourceNodeOwnedAudioGraphPipelineOutput
// Owner-thread-only output-ring reader side. No per-call heap allocation:
// pops through a fixed stack scratch buffer with a strictly bounded
// iteration count. Consumes a pending output-ring seek ack (start/seek)
// first, reporting any frames it had to discard at the boundary.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_drainMultiSourceNodeOwnedAudioGraphPipelineOutput(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jint maxFrames) {

    char status[640];

    const std::shared_ptr<MultiSourceNodeOwnedPipelineSession> session =
        FindMultiSourceNodeOwnedSession(sessionHandle);
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
// JNI: seekMultiSourceNodeOwnedAudioGraphPipeline
// Owner-thread-only. Forward-only seek across the whole two-track rig at
// once, re-anchoring BOTH tracks at a single accepted frame cursor:
// requires a fully drained output ring, both node-owned source rings empty,
// and the shared frame axis intact
// (accepted0 == accepted1 == totalOutputFramesDrained == nextDispatchFrame,
// else track_frame_axis_divergence). Publishes writer0.requestSeek(A) then
// writer1.requestSeek(A), immediately consumes each source ring's ack on
// this owner thread (asserting zero discarded frames and ackFrame == A),
// then coordinator.seek(targetPtsUs, sysTimeNs). The caller must drain the
// output-ring ack next.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_seekMultiSourceNodeOwnedAudioGraphPipeline(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle,
    jlong targetPtsUs,
    jlong sysTimeNs) {

    char status[768];

    const std::shared_ptr<MultiSourceNodeOwnedPipelineSession> session =
        FindMultiSourceNodeOwnedSession(sessionHandle);
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

    MultiSourceNodeOwnedPipelineSession& s = *session;
    const int64_t targetFrame = ClockedAudioTransportCoordinator::frameOfPositionUs(
        static_cast<int64_t>(targetPtsUs), s.sampleRate);

    auto replySeek = [&](const char* token, int64_t discarded) -> jstring {
        std::snprintf(status, sizeof(status),
            "status=%s;targetPtsUs=%lld;targetFrame=%lld;discardedFramesOnSeek=%lld;"
            "providerExpectedNextFrameTrack0=%lld;providerExpectedNextFrameTrack1=%lld;"
            "writerNextWriteFrameTrack0=%lld;writerNextWriteFrameTrack1=%lld;"
            "sourceAvailableReadFramesTrack0=%lld;sourceAvailableReadFramesTrack1=%lld;"
            "outputAvailableReadFrames=%lld",
            token,
            static_cast<long long>(targetPtsUs),
            static_cast<long long>(targetFrame),
            static_cast<long long>(discarded),
            static_cast<long long>(s.providerAt(0).expectedNextFrame()),
            static_cast<long long>(s.providerAt(1).expectedNextFrame()),
            static_cast<long long>(s.writerAt(0).nextWriteFrame()),
            static_cast<long long>(s.writerAt(1).nextWriteFrame()),
            static_cast<long long>(s.sourceRingAt(0).availableReadFrames()),
            static_cast<long long>(s.sourceRingAt(1).availableReadFrames()),
            static_cast<long long>(s.outputRing.availableReadFrames()));
        return env->NewStringUTF(status);
    };

    if (s.outputRing.availableReadFrames() != 0) {
        return replySeek("output_ring_not_drained", 0);
    }
    if (s.sourceRingAt(0).availableReadFrames() != 0) {
        return replySeek("source_ring_not_empty_track0", 0);
    }
    if (s.sourceRingAt(1).availableReadFrames() != 0) {
        return replySeek("source_ring_not_empty_track1", 0);
    }
    // Shared frame axis check: both accepted totals, the drained output
    // total, and the dispatch cursor must sit on the same accepted frame.
    const int64_t nextDispatchFrame = s.coordinator.snapshot().nextDispatchFrame;
    if (s.totalFramesAccepted[0] != s.totalFramesAccepted[1] ||
        s.totalFramesAccepted[0] != s.totalOutputFramesDrained ||
        s.totalFramesAccepted[0] != nextDispatchFrame) {
        return replySeek("track_frame_axis_divergence", 0);
    }
    if (targetFrame < s.providerAt(0).expectedNextFrame() ||
        targetFrame < s.providerAt(1).expectedNextFrame()) {
        return replySeek("seek_target_behind_provider_cursor", 0);
    }

    // Both tracks reanchor at the same accepted frame A = targetFrame; each
    // node-owned ring's ack is consumed immediately on this owner thread
    // and, because both rings were verified empty above, nothing may be
    // discarded.
    for (int track = 0; track < 2; ++track) {
        const WriterStatus writerSeekStatus = s.writerAt(track).requestSeek(targetFrame);
        if (writerSeekStatus != WriterStatus::kOk) {
            return replySeek(track == 0 ? "writer0_seek_rejected" : "writer1_seek_rejected", 0);
        }
        const int64_t unreadBeforeAck = s.sourceRingAt(track).availableReadFrames();
        int64_t sourceAckFrame = -1;
        if (!s.sourceRingAt(track).consumePendingSeekOnReaderThread(&sourceAckFrame)) {
            return replySeek(
                track == 0 ? "source0_seek_ack_not_consumed" : "source1_seek_ack_not_consumed", 0);
        }
        if (unreadBeforeAck != 0 || sourceAckFrame != targetFrame) {
            return replySeek(
                track == 0 ? "source0_seek_boundary_mismatch" : "source1_seek_boundary_mismatch",
                unreadBeforeAck);
        }
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
// JNI: setMultiSourceNodeOwnedAudioGraphPipelineEos
// Owner-thread-only. JOINT writer-local EOS: one call sets BOTH node-owned
// writers EOS together (cleared by the next successful seek request inside
// each AudioDecoderRingWriter). There is deliberately no per-track EOS
// entry point in this slice (no independent-EOS proof, no ragged tail).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_setMultiSourceNodeOwnedAudioGraphPipelineEos(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    char status[160];

    const std::shared_ptr<MultiSourceNodeOwnedPipelineSession> session =
        FindMultiSourceNodeOwnedSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status),
            "status=not_found;eosTrack0=false;eosTrack1=false");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status),
            "status=wrong_owner_thread;eosTrack0=false;eosTrack1=false");
        return env->NewStringUTF(status);
    }

    session->writerAt(0).setEos();
    session->writerAt(1).setEos();
    std::snprintf(status, sizeof(status),
        "status=ok;eosTrack0=%s;eosTrack1=%s",
        session->writerAt(0).isEos() ? "true" : "false",
        session->writerAt(1).isEos() ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: snapshotMultiSourceNodeOwnedAudioGraphPipeline
// Owner-thread-only. Full diagnostic snapshot across the two-track rig,
// including the node-owned/auto-discovery evidence (routedSourceCount,
// routedSourceId0/1, nodeOwnsRingTrack0/1) and the fixed-at-construction
// scratch/storage capacities the Kotlin driver compares before/after >=50
// cycles to prove zero native steady-state allocation, plus the verbatim
// proof boundary. Built through the bounded StatusAppender so every key is
// explicit and never silently truncated (overflow fails closed with
// status=snapshot_overflow).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_snapshotMultiSourceNodeOwnedAudioGraphPipeline(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    char status[6144];

    const std::shared_ptr<MultiSourceNodeOwnedPipelineSession> session =
        FindMultiSourceNodeOwnedSession(sessionHandle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread");
        return env->NewStringUTF(status);
    }

    MultiSourceNodeOwnedPipelineSession& s = *session;
    const auto snap = s.coordinator.snapshot();

    StatusAppender out(status, sizeof(status));
    out.appendf(
        "status=ok;"
        "routedSourceCount=%zu;routedSourceId0=%s;routedSourceId1=%s;"
        "nodeOwnsRingTrack0=%s;nodeOwnsRingTrack1=%s;"
        "lastDispatchResult=%s;nextDispatchFrame=%lld;lastMediaPositionUs=%lld;"
        "totalFramesRendered=%lld;totalFramesPushed=%lld;dispatchCount=%llu;"
        "okCount=%llu;silenceCount=%llu;backpressureCount=%llu;schedulerErrorCount=%llu;"
        "awaitingSeekAck=%s;terminal=%s;",
        s.scheduler.routedSourceCount(),
        s.scheduler.routedSourceCount() > 0 ? s.scheduler.routedSourceIdAt(0).c_str() : "",
        s.scheduler.routedSourceCount() > 1 ? s.scheduler.routedSourceIdAt(1).c_str() : "",
        s.sourceNode0->ownsRing() ? "true" : "false",
        s.sourceNode1->ownsRing() ? "true" : "false",
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
        snap.terminal ? "true" : "false");

    for (int track = 0; track < 2; ++track) {
        const AudioDecoderRingWriter::Metrics& wm = s.writerAt(track).metrics();
        out.appendf(
            "providerExpectedNextFrameTrack%d=%lld;providerUnderrunEventsTrack%d=%llu;"
            "providerFramesZeroFilledTrack%d=%llu;providerForwardSkipFramesTrack%d=%llu;"
            "providerRewindRejectsTrack%d=%llu;"
            "writerEosTrack%d=%s;writerNextWriteFrameTrack%d=%lld;"
            "writerPartialWriteEventsTrack%d=%llu;writerBackpressureRejectsTrack%d=%llu;"
            "writerSeekRequestsTrack%d=%llu;"
            "sourceAvailableReadFramesTrack%d=%lld;sourceAvailableWriteFramesTrack%d=%lld;"
            "sourceRingStorageCapacitySamplesTrack%d=%lld;"
            "nativeAcceptedChecksumHexTrack%d=%016llx;totalFramesAcceptedTrack%d=%lld;",
            track, static_cast<long long>(s.providerAt(track).expectedNextFrame()),
            track, static_cast<unsigned long long>(s.providerAt(track).underrunEvents()),
            track, static_cast<unsigned long long>(s.providerAt(track).framesZeroFilled()),
            track, static_cast<unsigned long long>(s.providerAt(track).forwardSkipFrames()),
            track, static_cast<unsigned long long>(s.providerAt(track).rewindRejects()),
            track, s.writerAt(track).isEos() ? "true" : "false",
            track, static_cast<long long>(s.writerAt(track).nextWriteFrame()),
            track, static_cast<unsigned long long>(wm.partialWriteEvents),
            track, static_cast<unsigned long long>(wm.backpressureRejects),
            track, static_cast<unsigned long long>(wm.seekRequests),
            track, static_cast<long long>(s.sourceRingAt(track).availableReadFrames()),
            track, static_cast<long long>(s.sourceRingAt(track).availableWriteFrames()),
            track, static_cast<long long>(s.sourceRingAt(track).storageCapacitySamples()),
            track, static_cast<unsigned long long>(s.nativeAcceptedChecksum[track]),
            track, static_cast<long long>(s.totalFramesAccepted[track]));
    }

    out.appendf(
        "outputAvailableReadFrames=%lld;outputRingStorageCapacitySamples=%lld;"
        "schedulerTrackScratchCapacitySamples=%zu;schedulerTrackScratchCapacityTracks=%zu;"
        "schedulerRoutedSourceCount=%zu;"
        "nativeOutputDrainChecksumHex=%016llx;totalOutputFramesDrained=%lld;"
        "sampleRate=%d;channelCount=%d;maxFramesPerMix=%lld;"
        "proofBoundary=%s",
        static_cast<long long>(s.outputRing.availableReadFrames()),
        static_cast<long long>(s.outputRing.storageCapacitySamples()),
        s.scheduler.trackScratchCapacitySamples(),
        s.scheduler.trackScratchCapacityTracks(),
        s.scheduler.routedSourceCount(),
        static_cast<unsigned long long>(s.nativeOutputDrainChecksum),
        static_cast<long long>(s.totalOutputFramesDrained),
        static_cast<int>(s.sampleRate),
        static_cast<int>(s.channelCount),
        static_cast<long long>(s.maxFramesPerMix),
        kProofBoundary);

    if (out.overflowed()) {
        std::snprintf(status, sizeof(status), "status=snapshot_overflow");
    }
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyMultiSourceNodeOwnedAudioGraphPipelineSmokeSession
// Callable from any thread. Idempotent erase-once: handle 0/unknown returns
// status=not_found; a live handle is erased exactly once and returns
// status=ok. A concurrently in-flight call keeps its shared_ptr reference,
// so the session is freed only when the last reference drops (no leaks, no
// use-after-free).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_destroyMultiSourceNodeOwnedAudioGraphPipelineSmokeSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong sessionHandle) {

    bool erased = false;
    {
        std::lock_guard<std::mutex> lock(gMultiSourceNodeOwnedRegistryMutex);
        erased = gMultiSourceNodeOwnedSessions.erase(static_cast<int64_t>(sessionHandle)) > 0;
    }
    return env->NewStringUTF(erased ? "status=ok" : "status=not_found");
}
