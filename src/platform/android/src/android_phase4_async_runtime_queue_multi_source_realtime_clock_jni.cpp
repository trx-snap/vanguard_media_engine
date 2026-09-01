// P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-REALTIME-CLOCK (sub-slice X4,
// under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): diagnostic async
// runtime queue session that composes the X3 worker-owned
// std::chrono::steady_clock render/dispatch timebase
// (android_phase4_async_runtime_queue_realtime_clock_jni.cpp, untouched and
// behaviorally reproducible) with the two-source NODE-OWNED topology of the
// multi-source node-owned pipeline TU
// (android_phase4_multi_source_node_owned_pipeline_session_jni.cpp,
// untouched): two DecodedAudioPcmSourceNode instances (6-arg constructor,
// each owning its ring/writer/provider triple) are routed
// src0 -> primary_audio_in and src1 -> secondary_audio_in into one
// AudioMixBusNode, with the GraphAudioScheduler discovering both providers
// from graph topology via the AutoDiscoverSourceProviders tag constructor
// only (no external provider map, no hybrid routing). This is X4 framed as
// X3's async worker plus the node-owned multi-source topology — NOT as
// X3 + the step-driven external-provider sub-slice K shape: no step entry
// point exists and Kotlin can never dispatch.
//
// Modularity note: this file exceeds the usual review size thresholds but
// remains ONE cohesive diagnostic session TU by design — the session
// registry, session struct, worker body, and owner-thread-private state
// must remain disjoint from every other diagnostic TU while being shared
// across all eight entry points of this one, so splitting it would force
// cross-TU coupling of what must stay private. Growth over the one-source
// X3 TU is capped by INDEXED two-track state (track arrays + loops) instead
// of duplicated per-track lifecycle code.
//
// Thread/role map (SPSC roles preserved from X3):
// - Owner thread (session creator; every non-destroy JNI entry point):
//   producer of BOTH node-owned source rings via each track's
//   AudioDecoderRingWriter (ingest/seek-request/EOS) and output-ring
//   CONSUMER (consumePendingSeekOnReaderThread + tryPopFrames via the read
//   entry point). It also enqueues commands and reads the worker-published
//   snapshot mirror.
// - Worker thread: sole reader of steady_clock for media time, sole caller
//   of every AudioClock mutator (including recordDriftSample), every
//   coordinator control/dispatch method, and the output ring's producer
//   role (plus the explicit per-track source seek-ack consumes while
//   executing a Seek command).
//
// Realtime pacing contract (constants frozen at the X3 values):
// - FULL maxFramesPerMix windows only; expectedFrameCount must be
//   window-aligned at create (fail closed), so no joint tail flush and no
//   partial-window dispatch can ever exist.
// - Joint dispatch gate: the worker renders only when
//   min(sourceRing0.availableReadFrames(), sourceRing1.availableReadFrames())
//   >= maxFramesPerMix; otherwise it starves/waits, so provider zero-fill
//   is structurally impossible while Kotlin keeps both rings fed.
// - Bounded catch-up: at most kMaxDispatchesPerWake (8) dispatches per
//   wake; condition_variable waits derived from the clock/render cursor,
//   clamped to at most 5ms.
// - Native per-epoch one-second timing gate [980ms, 1350ms] and
//   render-cursor backlog bound < 250000us, identical to X3.
// - The native frame axis is the SHARED ACCEPTED FRAME COUNT, not media
//   pts: the one forward seek re-anchors BOTH tracks at a single accepted
//   frame cursor (owner publishes both writer seek requests; the worker
//   verifies both ring acks are pending, then consumes both and requires
//   both ack frames to equal the target, with distinct per-track status
//   tokens on missing/mismatch).
// - Joint EOS entry point only: one call sets BOTH writers EOS after the
//   exact expected timeline completed. No per-track EOS route exists.
//
// Honest non-claims:
// - Muted diagnostic realtime-pacing proof only: the steady_clock timebase
//   is a render/dispatch timebase, NOT a presentation clock and NOT an
//   A/V-sync or latency claim. No AudioTrack/AAudio/OpenSL/Oboe in native,
//   no audible output, no OS audio callback, no realtime priority, no
//   SCHED_FIFO, no affinity, no fleet claim. No second OS decoder and no
//   C++ OS decoder or file IO anywhere. No product export route, no
//   product/editor/app wiring, no streaming/cache, no iOS, no C++ audio /
//   graph primitive changes.
// - The coordinator silenceCount telemetry is expected to be zero only
//   because the joint dispatch gate never lets a window render without
//   full source coverage; zero silence is generator/ingest-dependent, not
//   structural, and the Kotlin driver asserts it as part of the identity.
// - The worker never touches JNIEnv, never attaches to the JVM, never
//   calls back into Kotlin, and never logs. The TU-local mutex guards only
//   the command queue + published snapshot mirror; a second tiny mutex
//   serializes join; the registry mutex guards the lifecycle map.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt. Its session registry and handle counter are disjoint
// from every other diagnostic session TU (including the X3 realtime-clock
// TU and both step-driven multi-source TUs).
//
// P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-DYNAMIC-GAIN-ENVELOPE (X5):
// an envelope-enabled create entry point layers deterministic per-track
// dynamic AudioGainEnvelope mix params (built atomically BEFORE the
// scheduler snapshots the topology, owned by the session for the full
// scheduler lifetime) onto the otherwise-identical X4 rig. The default
// (X4) create keeps unit gain with null envelopes and is bit-identical to
// the pre-X5 behavior; every other entry point, constant, and timing
// invariant is shared verbatim between both modes. The snapshot publishes
// envelopeProofEnabled/envelopeApplied/envelopeEvaluations and the min/max
// effective gain folded by the worker from DispatchOutput (all false/0 in
// X4 mode). The kProofBoundary constant stays shared verbatim as the
// TU-identity proof for both modes; its unit-gain token describes the
// default (X4) configuration and the snapshot's envelopeProofEnabled key
// is the authoritative per-session mode disclosure.
//
// JNI entry points (VanguardNativeBridge.kt companion object):
//   createAsyncRuntimeQueueMultiSourceRealtimeClockSession   -> jlong handle (0 on failure)
//   createAsyncRuntimeQueueMultiSourceRealtimeClockEnvelopeSession -> jlong handle (0 on failure)
//   startAsyncRuntimeQueueMultiSourceRealtimeClock           -> jstring key=value (no time arg)
//   seekAsyncRuntimeQueueMultiSourceRealtimeClock            -> jstring key=value (no time arg)
//   ingestAsyncRuntimeQueueMultiSourceRealtimeClockPcm16     -> jstring key=value (per track)
//   setAsyncRuntimeQueueMultiSourceRealtimeClockEos          -> jstring key=value (joint)
//   readAsyncRuntimeQueueMultiSourceRealtimeClockOutputPcm16 -> jstring key=value
//   snapshotAsyncRuntimeQueueMultiSourceRealtimeClock        -> jstring key=value
//   destroyAsyncRuntimeQueueMultiSourceRealtimeClockSession  -> jstring key=value

#include <jni.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "vanguard/audio/audio_clock.h"
#include "vanguard/audio/audio_decoder_ring_writer.h"
#include "vanguard/audio/audio_gain_envelope.h"
#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/audio_ring_buffer.h"
#include "vanguard/audio/audio_sample_provider.h"
#include "vanguard/audio/clocked_audio_transport_coordinator.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/audio/ring_buffer_audio_sample_provider.h"
#include "vanguard/graph/graph.h"

namespace {

// Canonical proof boundary for this native TU; the Kotlin session wrapper
// carries the identical verbatim constant, and the snapshot entry point
// embeds it so a physical run proves this exact two-source realtime-clock
// TU executed. Deliberately makes no AudioTrack/native-sink claim: the
// muted AudioTrack sink is Kotlin-owned and carried only by the Kotlin
// driver's separate proof boundary.
constexpr const char* kProofBoundary =
    "diagnostic_async_runtime_queue_multi_source_realtime_clock_native_worker_proof_only_real_decoder_plus_synthetic_track_node_owned_source_rings_to_graph_scheduler_audio_mix_bus_to_output_ring_worker_owned_std_chrono_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_on_any_control_command_two_routed_tracks_unit_gain_lockstep_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_native_audio_sink_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes";

using vanguard::audio::AudioClock;
using vanguard::audio::AudioDecoderRingWriter;
using vanguard::audio::AudioGainEnvelope;
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

constexpr int     kTrackCount             = 2;
constexpr size_t  kMaxLiveSessions        = 4;
constexpr int64_t kMaxIngestFramesPerCall = AudioDecoderRingWriter::kMaxWriteFrames;      // 8192
constexpr int64_t kMaxRingCapacityFrames  = AudioSpscAudioRingBuffer::kMaxCapacityFrames; // 65536
constexpr int64_t kMicrosPerSecond        = 1'000'000LL;
constexpr size_t  kCommandQueueCapacity   = 8;

// Frozen X3 realtime constants (unchanged in X4).
constexpr int     kMaxDispatchesPerWake   = 8;
constexpr int64_t kMaxWaitNs              = 5'000'000LL;   // 5ms cv clamp
constexpr int64_t kTimingWarmupFrames     = 8192;          // F0 floor
constexpr int64_t kBacklogWarmupFrames    = 8192;          // per-epoch
constexpr int64_t kTimingMinElapsedNs     = 980'000'000LL;
constexpr int64_t kTimingMaxElapsedNs     = 1'350'000'000LL;
constexpr int64_t kMaxBacklogBoundUs      = 250'000LL;

constexpr const char* kMixNodeId     = "async_rtclock_ms_mix";
constexpr const char* kSource0NodeId = "async_rtclock_ms_src0";
constexpr const char* kSource1NodeId = "async_rtclock_ms_src1";

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

// Same signed-sample accumulation shape as the sibling audio seams:
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

// Smallest ptsUs whose frameOfPositionUs floor lands exactly on `frame`
// (valid because create enforces sampleRate <= 192000 < 1e6).
int64_t CeilPtsUsOfFrame(int64_t frame, int32_t sampleRate) {
    if (frame <= 0) return 0;
    return (frame * kMicrosPerSecond + sampleRate - 1) / sampleRate;
}

// Bounded stack-buffer appender used to build the wide two-track snapshot
// string from several snprintf pieces without heap allocation. Overflow is
// latched instead of silently truncating; callers must check overflowed()
// and fail closed.
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

// Populates the one-mix/two-source diagnostic topology before the
// scheduler member snapshots and walks the graph; called from the
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

// X5 deterministic dynamic proof envelopes, one per routed track, built
// from exactly three finite [0,1] keyframes at {0, trackEndUs/2,
// trackEndUs} with trackEndUs = CeilPtsUsOfFrame(expectedFrames). The
// Kotlin driver reproduces this table (and the AudioMixBusNode per-frame
// integer-us floor pts / truncation math) verbatim for the reference mix
// checksum, so any keyframe change must land on both sides at once.
constexpr double kEnvelopeGainsTrack0[3] = {0.25, 1.0, 0.5};
constexpr double kEnvelopeGainsTrack1[3] = {1.0, 0.25, 0.75};

// Populates the session-owned per-track envelopes + mix-params map BEFORE
// the scheduler member snapshots them; called from the session's member
// initializer list only (all touched members are declared before the
// scheduler, so their storage outlives every renderWindow() call). Returns
// the map pointer for the scheduler constructor (nullptr keeps the exact
// X4 unit-gain/no-envelope behavior); buildOk latches false on any
// normalization failure and the create entry point fails closed on it.
const std::unordered_map<std::string, GraphAudioScheduler::SourceMixParams>*
PrepareEnvelopeMixParams(
    bool     envelopeProofEnabled,
    int64_t  expectedFrames,
    int32_t  sampleRate,
    std::array<AudioGainEnvelope, kTrackCount>& envelopes,
    std::unordered_map<std::string, GraphAudioScheduler::SourceMixParams>& mixParams,
    bool&    buildOk) {
    if (!envelopeProofEnabled) {
        buildOk = true;
        return nullptr;
    }
    buildOk = false;
    const int64_t trackEndUs = CeilPtsUsOfFrame(expectedFrames, sampleRate);
    // The three-keyframe table must survive Normalize verbatim (no
    // sub-millisecond merge, no synthesized head/tail), so the timeline
    // must comfortably exceed the merge epsilon on both segments.
    if (trackEndUs < 4 * AudioGainEnvelope::kMergeEpsilonUs) {
        return nullptr;
    }
    const int64_t trackMidUs = trackEndUs / 2;
    const double* gains[kTrackCount] = {kEnvelopeGainsTrack0, kEnvelopeGainsTrack1};
    for (int t = 0; t < kTrackCount; ++t) {
        const AudioGainEnvelope::Keyframe raw[3] = {
            {0,          gains[t][0], AudioGainEnvelope::Interpolation::kLinear},
            {trackMidUs, gains[t][1], AudioGainEnvelope::Interpolation::kLinear},
            {trackEndUs, gains[t][2], AudioGainEnvelope::Interpolation::kLinear},
        };
        if (AudioGainEnvelope::Normalize(raw, 3, /*trackStartUs=*/0, trackEndUs,
                                         /*mixGain=*/1.0, &envelopes[t]) !=
            AudioGainEnvelope::BuildResult::kOk) {
            return nullptr;
        }
        if (envelopes[t].keyframeCount() != 3) {
            return nullptr; // synthesized/merged keyframes would break parity
        }
    }
    mixParams[kSource0NodeId] = GraphAudioScheduler::SourceMixParams{1.0, &envelopes[0]};
    mixParams[kSource1NodeId] = GraphAudioScheduler::SourceMixParams{1.0, &envelopes[1]};
    buildOk = true;
    return &mixParams;
}

// No control command carries a time value: the worker reads steady_clock
// itself at execution.
enum class CommandType : int32_t {
    kStart = 1, // no payload (media pts 0)
    kSeek  = 2, // a = targetPtsUs
};

struct Command {
    CommandType type{CommandType::kStart};
    int64_t     a{0};
    uint64_t    seq{0};
};

// Worker-published mirror of every coordinator/provider/worker/timing fact
// the owner thread may read. Written only by the worker under the session
// mutex; the owner copies it under the same mutex. All tokens are string
// literals so publishing never allocates. Per-track provider facts are
// indexed arrays, never duplicated fields.
struct PublishedState {
    bool     workerStarted{false};
    bool     workerExited{false};
    bool     started{false};
    bool     timelineComplete{false};
    bool     terminal{false};
    uint64_t workerThreadIdHash{0};
    bool     workerThreadDistinct{false};

    uint64_t commandsProcessed{0};
    uint64_t commandErrors{0};
    uint64_t lastCommandSeq{0};
    const char* lastCommandResult{"none"};
    const char* lastDispatchToken{"none"};

    int64_t  nextDispatchFrame{0};
    int64_t  lastMediaPositionUs{0};
    int64_t  totalFramesRendered{0};
    int64_t  totalFramesPushed{0};
    uint64_t dispatchCount{0};
    uint64_t okCount{0};
    uint64_t silenceCount{0};
    uint64_t backpressureCount{0};
    uint64_t schedulerErrorCount{0};

    uint64_t workerLoopCount{0};
    uint64_t workerSleepCount{0};
    uint64_t workerNoFramesDueWaits{0};
    uint64_t workerStarvedWaits{0};
    uint64_t workerAwaitingOutputAckWaits{0};
    uint64_t workerAwaitingSourceAckWaits{0};
    uint64_t workerDispatchAnomalies{0};
    uint64_t nonMonotonicTimeAnomalies{0};

    int64_t  epochStartFrame{0};
    int64_t  timingF0Frame{0};
    int64_t  timingF1Frame{0};
    int64_t  timingT0Ns{-1};
    int64_t  timingT1Ns{-1};
    int64_t  realtimeElapsedNs{-1};
    bool     realtimeElapsedOk{false};
    uint64_t backlogSampleCount{0};
    int64_t  maxRenderCursorBacklogUs{0};
    bool     realtimeBacklogBoundOk{true};
    uint64_t clockDriftSampleCount{0};

    int64_t  providerExpectedNextFrame[kTrackCount]{0, 0};
    uint64_t providerUnderrunEvents[kTrackCount]{0, 0};
    uint64_t providerFramesZeroFilled[kTrackCount]{0, 0};
    uint64_t providerForwardSkipFrames[kTrackCount]{0, 0};
    uint64_t providerRewindRejects[kTrackCount]{0, 0};

    // X5 envelope telemetry folded by the worker from DispatchOutput; all
    // false/0 for the X4 unit-gain/no-envelope mode.
    bool     envelopeApplied{false};
    uint64_t envelopeEvaluations{0};
    double   minEffectiveGain{0.0};
    double   maxEffectiveGain{0.0};
};

// ---------------------------------------------------------------------------
// Async runtime queue multi-source realtime-clock session. Member
// declaration order is construction order: the graph is populated
// (PrepareTopology) before the scheduler snapshots it, and the worker
// thread is declared LAST and started only after the fully-validated
// session exists, so no worker can ever observe a partially-constructed
// rig. shutdownWorker() joins (never detaches) before any rig member is
// destroyed.
// ---------------------------------------------------------------------------
struct AsyncRuntimeQueueMultiSourceRealtimeClockSession {
    Graph                                      graphTopology;
    std::shared_ptr<AudioMixBusNode>           mixBus;
    std::shared_ptr<DecodedAudioPcmSourceNode> sourceNode0;
    std::shared_ptr<DecodedAudioPcmSourceNode> sourceNode1;
    AudioSpscAudioRingBuffer                   outputRing;
    // X5 envelope owner storage, declared (and thus constructed) BEFORE the
    // scheduler so the non-owning envelope pointers the scheduler resolves
    // at construction stay valid for its whole lifetime and destruction
    // order is safe. Built atomically in PrepareEnvelopeMixParams before
    // the scheduler snapshots the graph; never mutated mid-flight.
    bool                                       envelopeProofEnabled;
    bool                                       envelopeBuildOk;
    std::array<AudioGainEnvelope, kTrackCount> trackEnvelopes;
    std::unordered_map<std::string, GraphAudioScheduler::SourceMixParams>
                                               trackMixParams;
    GraphAudioScheduler                        scheduler;
    AudioClock                                 clock;
    ClockedAudioTransportCoordinator           coordinator;
    std::thread::id                            ownerThreadId;

    int32_t sampleRate;
    int32_t channelCount;
    int64_t maxFramesPerMix;
    int64_t expectedFrames;

    // Owner-thread-private accounting (single owner thread enforced on
    // every non-destroy entry point). Indexed per-track, never duplicated.
    uint64_t nativeAcceptedChecksum[kTrackCount]{0, 0};
    int64_t  totalFramesAccepted[kTrackCount]{0, 0};
    uint64_t nativeOutputReadChecksum{0};
    int64_t  totalOutputFramesRead{0};
    bool     startEnqueued{false};

    // Cross-thread flags (lock-free reads on the worker's hot path).
    std::atomic<bool>     eosPublished{false};
    std::atomic<bool>     stopFlag{false};
    std::atomic<uint32_t> joinCount{0};
    std::atomic<uint32_t> destroyCalls{0};

    // TU-local mutex: command queue + published snapshot mirror only.
    std::mutex              mutex_;
    std::condition_variable cv_;
    std::array<Command, kCommandQueueCapacity> queue_{};
    size_t   queueHead{0};
    size_t   queueCount{0};
    uint64_t commandsEnqueued{0}; // guarded by mutex_
    PublishedState published_;    // guarded by mutex_

    std::mutex  joinMutex_;
    std::thread worker_; // declared last; joined before members destroy

    AsyncRuntimeQueueMultiSourceRealtimeClockSession(int32_t sampleRateIn,
                                                     int32_t channelCountIn,
                                                     int64_t expectedFrameCountIn,
                                                     int64_t sourceRingCapacityFrames,
                                                     int64_t outputRingCapacityFrames,
                                                     int64_t maxFramesPerMixIn,
                                                     bool    envelopeProofEnabledIn)
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
          envelopeProofEnabled(envelopeProofEnabledIn),
          envelopeBuildOk(false),
          trackEnvelopes(),
          trackMixParams(),
          scheduler(PrepareTopology(graphTopology, mixBus, sourceNode0, sourceNode1),
                    kMixNodeId, AutoDiscoverSourceProviders{},
                    PrepareEnvelopeMixParams(envelopeProofEnabledIn,
                                             expectedFrameCountIn, sampleRateIn,
                                             trackEnvelopes, trackMixParams,
                                             envelopeBuildOk)),
          clock(),
          coordinator(clock, scheduler, outputRing),
          ownerThreadId(std::this_thread::get_id()),
          sampleRate(sampleRateIn),
          channelCount(channelCountIn),
          maxFramesPerMix(maxFramesPerMixIn),
          expectedFrames(expectedFrameCountIn) {}

    ~AsyncRuntimeQueueMultiSourceRealtimeClockSession() { shutdownWorker(); }

    std::shared_ptr<DecodedAudioPcmSourceNode>& sourceNodeAt(int t) {
        return t == 0 ? sourceNode0 : sourceNode1;
    }

    // The 6-arg node constructor is the only way this session is built, so
    // both node-owned triples are always present after a successful create
    // (the create entry point fails closed on !ownsRing() before
    // registering the handle).
    AudioSpscAudioRingBuffer& sourceRingAt(int t) { return *sourceNodeAt(t)->ring(); }
    AudioDecoderRingWriter&   writerAt(int t)     { return *sourceNodeAt(t)->ringWriter(); }
    // The 6-arg constructor's owned provider is always a
    // RingBufferAudioSampleProvider, so this downcast of the node's
    // base-typed accessor is exact (diagnostics-only metric access).
    RingBufferAudioSampleProvider& providerAt(int t) {
        return *static_cast<RingBufferAudioSampleProvider*>(
            sourceNodeAt(t)->audioSampleProvider());
    }

    // True while either node-owned source ring has a published-but-not-yet
    // consumed seek handshake.
    bool anySourceAckPending() {
        for (int t = 0; t < kTrackCount; ++t) {
            if (sourceRingAt(t).seekRequest() != sourceRingAt(t).seekAck()) {
                return true;
            }
        }
        return false;
    }

    // Joint availability: the worker may render only full windows both
    // rings can satisfy.
    int64_t jointSourceAvailable() {
        return std::min<int64_t>(sourceRingAt(0).availableReadFrames(),
                                 sourceRingAt(1).availableReadFrames());
    }

    // Fail-closed: std::thread construction can throw (e.g. resource
    // exhaustion); report false instead of letting the exception escape
    // through the JNI boundary. On failure worker_ stays non-joinable, so
    // shutdownWorker() in the destructor remains a safe no-op join.
    bool startWorker() {
        try {
            worker_ = std::thread([this]() { workerMain(); });
        } catch (...) {
            return false;
        }
        return true;
    }

    // Idempotent: sets the stop flag, wakes the worker, joins exactly once.
    // Never detaches. The worker never calls JNI/destroy, so this can never
    // be invoked from the worker thread itself.
    void shutdownWorker() {
        stopFlag.store(true, std::memory_order_release);
        cv_.notify_all();
        std::lock_guard<std::mutex> lock(joinMutex_);
        if (worker_.joinable()) {
            worker_.join();
            joinCount.fetch_add(1, std::memory_order_acq_rel);
        }
    }

    // Owner-thread enqueue. Returns the assigned sequence (>0) or 0 when
    // the bounded queue is full (caller reports queue_full; nothing raced).
    uint64_t enqueueCommand(CommandType type, int64_t a) {
        uint64_t seq = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (queueCount >= kCommandQueueCapacity) {
                return 0;
            }
            seq = ++commandsEnqueued;
            queue_[(queueHead + queueCount) % kCommandQueueCapacity] =
                Command{type, a, seq};
            ++queueCount;
        }
        cv_.notify_all();
        return seq;
    }

private:
    // ── Worker thread body ─────────────────────────────────────────────────
    // Sole reader of steady_clock for media time; sole caller of AudioClock
    // mutators (start/seek/recordDriftSample), coordinator
    // control/dispatch, and the output ring's producer role. Never touches
    // JNIEnv, never attaches to the JVM, never calls back to Kotlin, never
    // logs, never elevates priority.
    void workerMain() {
        bool startedLocal = false;

        uint64_t commandsProcessed = 0;
        uint64_t commandErrors     = 0;
        uint64_t lastCommandSeq    = 0;
        const char* lastCommandResult = "none";
        const char* lastDispatchToken = "none";
        uint64_t loopCount = 0, sleepCount = 0;
        uint64_t noFramesDueWaits = 0, starvedWaits = 0;
        uint64_t awaitingOutputAckWaits = 0, awaitingSourceAckWaits = 0;
        uint64_t dispatchAnomalies = 0, nonMonotonicAnomalies = 0;
        uint64_t backlogSamples = 0;

        // X5 envelope telemetry folded from every ok/silence DispatchOutput
        // (structurally all-false/0 in X4 mode: the scheduler mixes no
        // envelope-bearing track without mix params).
        bool     envelopeAppliedSeen   = false;
        uint64_t envelopeEvaluations   = 0;
        double   minEffectiveGain      = 0.0;
        double   maxEffectiveGain      = 0.0;

        // Realtime timebase state: every value below is derived from the
        // worker's own steady_clock reads, never from a caller.
        int64_t lastNowNs       = 0;
        int64_t epochStartFrame = 0;
        int64_t timingT0Ns      = -1;
        int64_t timingT1Ns      = -1;
        int64_t maxBacklogUs    = 0;
        // First full-window boundary at or past the warmup floor; the
        // one-second gate spans [F0, F0 + sampleRate] frames.
        const int64_t timingF0 =
            ((kTimingWarmupFrames + maxFramesPerMix - 1) / maxFramesPerMix) *
            maxFramesPerMix;
        const int64_t timingF1 = timingF0 + static_cast<int64_t>(sampleRate);

        const uint64_t workerIdHash =
            std::hash<std::thread::id>{}(std::this_thread::get_id());
        const bool workerDistinct =
            std::this_thread::get_id() != ownerThreadId;

        auto steadyNowNs = []() -> int64_t {
            return std::chrono::duration_cast<std::chrono::nanoseconds>(
                       std::chrono::steady_clock::now().time_since_epoch())
                .count();
        };

        auto publish = [&](bool exited) {
            const auto csnap = coordinator.snapshot();
            const auto ksnap = clock.snapshot();
            const int64_t elapsedNs =
                (timingT0Ns >= 0 && timingT1Ns >= 0) ? timingT1Ns - timingT0Ns
                                                     : -1;
            std::lock_guard<std::mutex> lock(mutex_);
            PublishedState& ps = published_;
            ps.workerStarted        = true;
            ps.workerExited         = exited;
            ps.started              = startedLocal;
            ps.timelineComplete     = csnap.nextDispatchFrame >= expectedFrames;
            ps.terminal             = csnap.terminal;
            ps.workerThreadIdHash   = workerIdHash;
            ps.workerThreadDistinct = workerDistinct;
            ps.commandsProcessed    = commandsProcessed;
            ps.commandErrors        = commandErrors;
            ps.lastCommandSeq       = lastCommandSeq;
            ps.lastCommandResult    = lastCommandResult;
            ps.lastDispatchToken    = lastDispatchToken;
            ps.nextDispatchFrame    = csnap.nextDispatchFrame;
            ps.lastMediaPositionUs  = csnap.lastMediaPositionUs;
            ps.totalFramesRendered  = csnap.totalFramesRendered;
            ps.totalFramesPushed    = csnap.totalFramesPushed;
            ps.dispatchCount        = csnap.dispatchCount;
            ps.okCount              = csnap.okCount;
            ps.silenceCount         = csnap.silenceCount;
            ps.backpressureCount    = csnap.backpressureCount;
            ps.schedulerErrorCount  = csnap.schedulerErrorCount;
            ps.workerLoopCount      = loopCount;
            ps.workerSleepCount     = sleepCount;
            ps.workerNoFramesDueWaits     = noFramesDueWaits;
            ps.workerStarvedWaits         = starvedWaits;
            ps.workerAwaitingOutputAckWaits = awaitingOutputAckWaits;
            ps.workerAwaitingSourceAckWaits = awaitingSourceAckWaits;
            ps.workerDispatchAnomalies    = dispatchAnomalies;
            ps.nonMonotonicTimeAnomalies  = nonMonotonicAnomalies;
            ps.epochStartFrame      = epochStartFrame;
            ps.timingF0Frame        = timingF0;
            ps.timingF1Frame        = timingF1;
            ps.timingT0Ns           = timingT0Ns;
            ps.timingT1Ns           = timingT1Ns;
            ps.realtimeElapsedNs    = elapsedNs;
            ps.realtimeElapsedOk    = elapsedNs >= kTimingMinElapsedNs &&
                                      elapsedNs <= kTimingMaxElapsedNs;
            ps.backlogSampleCount   = backlogSamples;
            ps.maxRenderCursorBacklogUs = maxBacklogUs;
            ps.realtimeBacklogBoundOk   = maxBacklogUs < kMaxBacklogBoundUs;
            ps.clockDriftSampleCount    = ksnap.driftSampleCount;
            ps.envelopeApplied          = envelopeAppliedSeen;
            ps.envelopeEvaluations      = envelopeEvaluations;
            ps.minEffectiveGain         = minEffectiveGain;
            ps.maxEffectiveGain         = maxEffectiveGain;
            for (int t = 0; t < kTrackCount; ++t) {
                RingBufferAudioSampleProvider& p = providerAt(t);
                ps.providerExpectedNextFrame[t] = p.expectedNextFrame();
                ps.providerUnderrunEvents[t]    = p.underrunEvents();
                ps.providerFramesZeroFilled[t]  = p.framesZeroFilled();
                ps.providerForwardSkipFrames[t] = p.forwardSkipFrames();
                ps.providerRewindRejects[t]     = p.rewindRejects();
            }
        };

        auto executeCommand = [&](const Command& cmd) {
            lastCommandSeq = cmd.seq;
            switch (cmd.type) {
                case CommandType::kStart: {
                    if (startedLocal) {
                        lastCommandResult = "already_started";
                        ++commandErrors;
                        break;
                    }
                    const int64_t now = steadyNowNs();
                    const Status st = coordinator.start(/*mediaPtsUs=*/0, now);
                    if (st.ok()) {
                        startedLocal    = true;
                        epochStartFrame = 0;
                        lastNowNs       = std::max<int64_t>(lastNowNs, now);
                        lastCommandResult = "ok";
                    } else {
                        lastCommandResult = "clock_error";
                        ++commandErrors;
                    }
                    break;
                }
                case CommandType::kSeek: {
                    // The one-second timing window must have completed
                    // inside the pre-seek epoch; a seek before t1 exists
                    // would invalidate the primary realtime gate.
                    if (timingT1Ns < 0) {
                        lastCommandResult = "timing_window_unavailable";
                        ++commandErrors;
                        break;
                    }
                    const int64_t targetFrame =
                        ClockedAudioTransportCoordinator::frameOfPositionUs(
                            cmd.a, sampleRate);
                    // The owner already published BOTH source-ring seek
                    // requests (producer role) over verified-empty rings.
                    // Verify both handshakes are pending BEFORE consuming
                    // either ack (distinct per-track tokens), then consume
                    // both on this ring-consumer thread; both ack frames
                    // must equal the shared accepted-frame target.
                    if (sourceRingAt(0).seekRequest() == sourceRingAt(0).seekAck()) {
                        lastCommandResult = "source_ack_missing_track0";
                        ++commandErrors;
                        break;
                    }
                    if (sourceRingAt(1).seekRequest() == sourceRingAt(1).seekAck()) {
                        lastCommandResult = "source_ack_missing_track1";
                        ++commandErrors;
                        break;
                    }
                    bool ackFailed = false;
                    for (int t = 0; t < kTrackCount && !ackFailed; ++t) {
                        int64_t srcAckFrame = -1;
                        if (!sourceRingAt(t).consumePendingSeekOnReaderThread(&srcAckFrame)) {
                            lastCommandResult = t == 0 ? "source_ack_missing_track0"
                                                       : "source_ack_missing_track1";
                            ackFailed = true;
                        } else if (srcAckFrame != targetFrame) {
                            lastCommandResult = t == 0 ? "source_ack_mismatch_track0"
                                                       : "source_ack_mismatch_track1";
                            ackFailed = true;
                        }
                    }
                    if (ackFailed) {
                        ++commandErrors;
                        break;
                    }
                    const int64_t now = steadyNowNs();
                    if (now < lastNowNs) {
                        lastCommandResult = "non_monotonic_time";
                        ++nonMonotonicAnomalies;
                        ++commandErrors;
                        break;
                    }
                    const Status st = coordinator.seek(cmd.a, now);
                    if (st.ok()) {
                        epochStartFrame = targetFrame;
                        lastNowNs       = now;
                        lastCommandResult = "ok";
                    } else {
                        lastCommandResult = "clock_error";
                        ++commandErrors;
                    }
                    break;
                }
            }
            ++commandsProcessed;
        };

        publish(false);

        while (!stopFlag.load(std::memory_order_acquire)) {
            ++loopCount;

            // 1. Drain every pending command at the top of the loop.
            std::array<Command, kCommandQueueCapacity> localCmds{};
            size_t localCount = 0;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                while (queueCount > 0) {
                    localCmds[localCount++] = queue_[queueHead];
                    queueHead = (queueHead + 1) % kCommandQueueCapacity;
                    --queueCount;
                }
            }
            for (size_t i = 0; i < localCount; ++i) {
                executeCommand(localCmds[i]);
            }

            // 2. Bounded realtime catch-up: dispatch full windows until
            // no-frames-due, backpressure, ack gate, joint starvation,
            // terminal, or the per-wake cap.
            bool progressed = localCount > 0;
            int64_t waitNs = kMaxWaitNs;
            if (startedLocal) {
                auto csnap = coordinator.snapshot();
                if (!csnap.terminal &&
                    outputRing.seekRequest() != outputRing.seekAck()) {
                    // Start/seek requires the owner to consume the output
                    // ack via the read path before the worker may render.
                    ++awaitingOutputAckWaits;
                } else if (!csnap.terminal && anySourceAckPending()) {
                    // Seek requests published, Seek command not yet
                    // drained: no dispatch during the pending source ack
                    // gate (checked across BOTH rings).
                    ++awaitingSourceAckWaits;
                } else if (!csnap.terminal) {
                    for (int i = 0; i < kMaxDispatchesPerWake; ++i) {
                        csnap = coordinator.snapshot();
                        const int64_t cursor    = csnap.nextDispatchFrame;
                        const int64_t remaining = expectedFrames - cursor;
                        if (remaining <= 0) break; // timeline complete
                        // expectedFrames is window-aligned at create, so
                        // this is always a FULL maxFramesPerMix window.
                        const int64_t windowFrames =
                            std::min<int64_t>(maxFramesPerMix, remaining);
                        const int64_t nowNs = steadyNowNs();
                        if (nowNs < lastNowNs) {
                            ++nonMonotonicAnomalies;
                            break;
                        }
                        const int64_t posUs = clock.currentPositionUs(nowNs);
                        const int64_t dueFrame =
                            ClockedAudioTransportCoordinator::frameOfPositionUs(
                                posUs, sampleRate);
                        const int64_t framesDue = dueFrame - cursor;
                        if (framesDue < windowFrames) {
                            // Normal steady state: the next full window is
                            // not yet due. Derive the wait from the clock /
                            // render cursor, clamped below to kMaxWaitNs.
                            ++noFramesDueWaits;
                            lastDispatchToken = "no_frames_due";
                            const int64_t duePtsUs = CeilPtsUsOfFrame(
                                cursor + windowFrames, sampleRate);
                            int64_t untilNs = (duePtsUs - posUs) * 1000;
                            if (untilNs < 1) untilNs = 1;
                            waitNs = std::min<int64_t>(waitNs, untilNs);
                            break;
                        }
                        if (jointSourceAvailable() < windowFrames) {
                            // Joint realtime source starvation: never
                            // dispatch a window EITHER ring cannot fully
                            // satisfy (zero-fill would poison the
                            // identity). Kotlin keeps both decodes ahead.
                            ++starvedWaits;
                            lastDispatchToken = "source_starved";
                            break;
                        }
                        DispatchOutput out;
                        const DispatchResult r =
                            coordinator.dispatchUntil(nowNs, &out);
                        lastNowNs = nowNs;
                        lastDispatchToken = DispatchResultName(r);
                        if (r == DispatchResult::kOk ||
                            r == DispatchResult::kSilence) {
                            progressed = true;
                            if (out.envelopeApplied) {
                                if (!envelopeAppliedSeen ||
                                    out.minEffectiveGain < minEffectiveGain) {
                                    minEffectiveGain = out.minEffectiveGain;
                                }
                                if (!envelopeAppliedSeen ||
                                    out.maxEffectiveGain > maxEffectiveGain) {
                                    maxEffectiveGain = out.maxEffectiveGain;
                                }
                                envelopeAppliedSeen = true;
                                envelopeEvaluations +=
                                    static_cast<uint64_t>(out.envelopeEvaluations);
                            }
                            const int64_t cursorAfter = out.nextDispatchFrame;
                            if (timingT0Ns < 0 && cursorAfter > timingF0) {
                                timingT0Ns = nowNs;
                            }
                            if (timingT1Ns < 0 && cursorAfter > timingF1) {
                                timingT1Ns = nowNs;
                            }
                            // Backlog sample past the per-epoch warmup:
                            // clock position vs render cursor, recorded via
                            // the clock's drift telemetry (worker only).
                            if (cursorAfter - epochStartFrame >=
                                kBacklogWarmupFrames) {
                                const int64_t cursorPtsUs =
                                    CeilPtsUsOfFrame(cursorAfter, sampleRate);
                                int64_t backlogUs = posUs - cursorPtsUs;
                                if (backlogUs < 0) backlogUs = 0;
                                if (backlogUs > maxBacklogUs) {
                                    maxBacklogUs = backlogUs;
                                }
                                ++backlogSamples;
                                (void)clock.recordDriftSample(
                                    cursorPtsUs, posUs, nowNs);
                            }
                            continue;
                        }
                        if (r == DispatchResult::kBackpressure) {
                            // Normal telemetry (coordinator counted it);
                            // wait for the owner to drain.
                            break;
                        }
                        if (r == DispatchResult::kNoFramesDue) {
                            ++noFramesDueWaits;
                            break;
                        }
                        if (r == DispatchResult::kAwaitingSeekAck) {
                            ++awaitingOutputAckWaits;
                            break;
                        }
                        ++dispatchAnomalies;
                        break;
                    }
                }
            }

            publish(false);

            // 3. Clock-derived pacing wait, clamped to 5ms; wakes on stop
            // or a queued command (ingest also notifies the cv).
            if (!progressed) {
                std::unique_lock<std::mutex> lock(mutex_);
                ++sleepCount;
                cv_.wait_for(
                    lock,
                    std::chrono::nanoseconds(
                        std::min<int64_t>(waitNs, kMaxWaitNs)),
                    [this]() {
                        return stopFlag.load(std::memory_order_acquire) ||
                               queueCount > 0;
                    });
            }
        }

        publish(true);
    }
};

// ---------------------------------------------------------------------------
// Session registry. Disjoint handle space from every other diagnostic
// session TU (including the X3 realtime-clock TU). The mutex guards only
// this lifecycle map; values are shared_ptr so an in-flight entry point
// stays safe if destroy erases the map entry concurrently.
// ---------------------------------------------------------------------------
std::mutex gMsRealtimeClockRegistryMutex;
std::unordered_map<int64_t,
                   std::shared_ptr<AsyncRuntimeQueueMultiSourceRealtimeClockSession>>
    gMsRealtimeClockSessions;
int64_t gNextMsRealtimeClockHandle = 1; // guarded by the registry mutex

std::shared_ptr<AsyncRuntimeQueueMultiSourceRealtimeClockSession>
FindMsRealtimeClockSession(jlong handle) {
    std::lock_guard<std::mutex> lock(gMsRealtimeClockRegistryMutex);
    auto it = gMsRealtimeClockSessions.find(static_cast<int64_t>(handle));
    return it == gMsRealtimeClockSessions.end() ? nullptr : it->second;
}

} // namespace

namespace {

// Shared fail-closed create path for both the X4 (unit-gain, no-envelope)
// and X5 (envelope-enabled) entry points: construction validation runs
// first and the worker thread starts only after the rig validated (BOTH
// nodes own their transport, the auto-discovered route resolved to exactly
// the two intended tracks in edge order, every node/ring carries the
// session's channel/sample-rate geometry, and — in envelope mode — the
// deterministic proof envelopes built cleanly before the scheduler
// snapshot). expectedFrameCount must be window-aligned because the
// realtime worker dispatches full windows only (no joint tail flush
// exists).
jlong CreateMsRealtimeClockSession(
    jint  sampleRate,
    jint  channelCount,
    jlong expectedFrameCount,
    jint  sourceRingCapacityFrames,
    jint  outputRingCapacityFrames,
    jint  maxFramesPerMix,
    bool  envelopeProofEnabled) {

    const int64_t expFrames = static_cast<int64_t>(expectedFrameCount);
    const int64_t srcCap    = static_cast<int64_t>(sourceRingCapacityFrames);
    const int64_t outCap    = static_cast<int64_t>(outputRingCapacityFrames);
    const int64_t mfpm      = static_cast<int64_t>(maxFramesPerMix);

    if (sampleRate < 8000 || sampleRate > 192000) return 0;
    if (channelCount != 1 && channelCount != 2) return 0;
    // Mirrors DecodedAudioPcmSourceNode's own (0, 600*sampleRate] bound so
    // an out-of-range expected frame count fails closed as handle=0 here.
    if (expFrames < 1 ||
        expFrames > DecodedAudioPcmSourceNode::kMaxExpectedSeconds *
                        static_cast<int64_t>(sampleRate)) {
        return 0;
    }
    if (mfpm < 1 || mfpm > 8192) return 0;
    if (expFrames % mfpm != 0) return 0;
    if (!IsPowerOfTwoInRingRange(srcCap)) return 0;
    if (!IsPowerOfTwoInRingRange(outCap)) return 0;
    if (outCap < mfpm) return 0;
    // Frozen X3 geometry, applied to EACH node-owned source ring: it must
    // absorb a full output ring of decoded lead plus two mix windows of
    // slack.
    if (srcCap < outCap + 2 * mfpm) return 0;

    std::shared_ptr<AsyncRuntimeQueueMultiSourceRealtimeClockSession> session;
    try {
        session = std::make_shared<AsyncRuntimeQueueMultiSourceRealtimeClockSession>(
            static_cast<int32_t>(sampleRate),
            static_cast<int32_t>(channelCount),
            expFrames, srcCap, outCap, mfpm,
            envelopeProofEnabled);
    } catch (...) {
        return 0;
    }

    if (!session->envelopeBuildOk) {
        return 0; // envelope-mode proof envelopes failed to build atomically
    }
    if (!session->sourceNode0->ownsRing() ||
        !session->sourceNode1->ownsRing() ||
        !session->scheduler.targetValid() ||
        session->scheduler.routedSourceCount() != 2 ||
        session->scheduler.routedSourceIdAt(0) != kSource0NodeId ||
        session->scheduler.routedSourceIdAt(1) != kSource1NodeId) {
        return 0;
    }
    // Channel/sample-rate invariants across the whole indexed rig.
    for (int t = 0; t < kTrackCount; ++t) {
        if (session->sourceNodeAt(t)->sampleRate() != session->sampleRate ||
            session->sourceNodeAt(t)->channelCount() != session->channelCount ||
            session->sourceRingAt(t).sampleRate() != session->sampleRate ||
            session->sourceRingAt(t).channelCount() != session->channelCount) {
            return 0;
        }
    }
    if (session->mixBus->sampleRate() != session->sampleRate ||
        session->mixBus->channelCount() != session->channelCount ||
        session->outputRing.sampleRate() != session->sampleRate ||
        session->outputRing.channelCount() != session->channelCount) {
        return 0;
    }

    {
        std::lock_guard<std::mutex> lock(gMsRealtimeClockRegistryMutex);
        if (gMsRealtimeClockSessions.size() >= kMaxLiveSessions) return 0;
        if (!session->startWorker()) return 0;
        const int64_t handle = gNextMsRealtimeClockHandle++;
        gMsRealtimeClockSessions[handle] = std::move(session);
        return static_cast<jlong>(handle);
    }
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAsyncRuntimeQueueMultiSourceRealtimeClockSession
// X4 default mode: unit gain, no envelopes; bit-identical to the pre-X5
// behavior of this TU.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createAsyncRuntimeQueueMultiSourceRealtimeClockSession(
    JNIEnv* /* env */,
    jobject /* companion */,
    jint sampleRate,
    jint channelCount,
    jlong expectedFrameCount,
    jint sourceRingCapacityFrames,
    jint outputRingCapacityFrames,
    jint maxFramesPerMix) {
    return CreateMsRealtimeClockSession(
        sampleRate, channelCount, expectedFrameCount,
        sourceRingCapacityFrames, outputRingCapacityFrames, maxFramesPerMix,
        /*envelopeProofEnabled=*/false);
}

// ---------------------------------------------------------------------------
// JNI: createAsyncRuntimeQueueMultiSourceRealtimeClockEnvelopeSession
// X5 envelope-enabled mode: identical rig plus the session-owned
// deterministic per-track dynamic AudioGainEnvelope mix params resolved by
// the scheduler at construction. Envelope configuration is atomic before
// the worker starts and before the handle registers; no mid-flight
// envelope mutation path exists.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createAsyncRuntimeQueueMultiSourceRealtimeClockEnvelopeSession(
    JNIEnv* /* env */,
    jobject /* companion */,
    jint sampleRate,
    jint channelCount,
    jlong expectedFrameCount,
    jint sourceRingCapacityFrames,
    jint outputRingCapacityFrames,
    jint maxFramesPerMix) {
    return CreateMsRealtimeClockSession(
        sampleRate, channelCount, expectedFrameCount,
        sourceRingCapacityFrames, outputRingCapacityFrames, maxFramesPerMix,
        /*envelopeProofEnabled=*/true);
}

namespace {

// Common reply shape for the command entry points, formatted into a
// caller-provided stack buffer.
jstring ReplyCommand(JNIEnv* env, char* buf, size_t bufLen,
                     const char* token, uint64_t seq) {
    std::snprintf(buf, bufLen, "status=%s;commandSeq=%llu",
                  token, static_cast<unsigned long long>(seq));
    return env->NewStringUTF(buf);
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: startAsyncRuntimeQueueMultiSourceRealtimeClock
// Owner-thread-only, enqueue-only, NO time argument: the WORKER reads
// steady_clock itself and executes coordinator.start(0, now). After the
// worker reports the command processed, the owner must consume the
// output-ring seek ack via the read entry point before the worker can
// render its first window.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_startAsyncRuntimeQueueMultiSourceRealtimeClock(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[192];
    const auto session = FindMsRealtimeClockSession(handle);
    if (!session) return ReplyCommand(env, status, sizeof(status), "not_found", 0);
    if (std::this_thread::get_id() != session->ownerThreadId) {
        return ReplyCommand(env, status, sizeof(status), "wrong_owner_thread", 0);
    }
    if (session->startEnqueued) {
        return ReplyCommand(env, status, sizeof(status), "already_started", 0);
    }
    const uint64_t seq = session->enqueueCommand(CommandType::kStart, 0);
    if (seq == 0) {
        return ReplyCommand(env, status, sizeof(status), "queue_full", 0);
    }
    session->startEnqueued = true;
    return ReplyCommand(env, status, sizeof(status), "enqueued", seq);
}

// ---------------------------------------------------------------------------
// JNI: seekAsyncRuntimeQueueMultiSourceRealtimeClock
// Owner-thread-only, forward-only, quiescent-only, NO time argument, fail
// closed with distinct per-track tokens otherwise. The owner-side
// quiescence precondition before issuing EITHER writer request is: every
// command processed, nextDispatchFrame == totalFramesAccepted[0] ==
// totalFramesAccepted[1] (shared accepted-frame axis), both source rings
// empty with settled acks, output ring drained with a settled ack, and
// targetFrame >= each writer's nextWriteFrame(). On success the OWNER
// publishes BOTH source writer seek requests (producer role) in track
// order, then enqueues the Seek command; the WORKER verifies + consumes
// both source acks and calls coordinator.seek(targetPtsUs, fresh
// steady_clock now); the owner must then consume the output ack via read.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_seekAsyncRuntimeQueueMultiSourceRealtimeClock(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
    jlong targetPtsUs) {

    char status[320];
    const auto session = FindMsRealtimeClockSession(handle);

    auto reply = [&](const char* token, uint64_t seq, int64_t targetFrame) -> jstring {
        std::snprintf(status, sizeof(status),
            "status=%s;commandSeq=%llu;targetPtsUs=%lld;targetFrame=%lld",
            token,
            static_cast<unsigned long long>(seq),
            static_cast<long long>(targetPtsUs),
            static_cast<long long>(targetFrame));
        return env->NewStringUTF(status);
    };

    if (!session) return reply("not_found", 0, -1);
    if (std::this_thread::get_id() != session->ownerThreadId) {
        return reply("wrong_owner_thread", 0, -1);
    }
    if (targetPtsUs < 0) {
        return reply("invalid_args", 0, -1);
    }
    if (!session->startEnqueued) return reply("not_started", 0, -1);
    if (session->eosPublished.load(std::memory_order_acquire)) {
        return reply("seek_rejected_eos", 0, -1);
    }

    AsyncRuntimeQueueMultiSourceRealtimeClockSession& s = *session;
    const int64_t targetFrame = ClockedAudioTransportCoordinator::frameOfPositionUs(
        static_cast<int64_t>(targetPtsUs), s.sampleRate);

    // Quiescence: with both source rings empty and no EOS the worker is
    // provably starved (it cannot advance nextDispatchFrame even though
    // the wall clock keeps running), so the published values read under
    // the mutex below are exact, not stale.
    {
        std::lock_guard<std::mutex> lock(s.mutex_);
        if (s.queueCount > 0 ||
            s.published_.commandsProcessed != s.commandsEnqueued) {
            return reply("seek_pending_commands", 0, targetFrame);
        }
        if (targetFrame < s.published_.nextDispatchFrame) {
            return reply("seek_target_behind_cursor", 0, targetFrame);
        }
        // Shared accepted-frame axis: both accepted totals and the
        // dispatch cursor must sit on the same accepted frame.
        if (s.totalFramesAccepted[0] != s.totalFramesAccepted[1] ||
            s.published_.nextDispatchFrame != s.totalFramesAccepted[0]) {
            return reply("seek_track_frame_axis_divergence", 0, targetFrame);
        }
    }
    if (s.sourceRingAt(0).availableReadFrames() != 0) {
        return reply("seek_source_ring_not_empty_track0", 0, targetFrame);
    }
    if (s.sourceRingAt(1).availableReadFrames() != 0) {
        return reply("seek_source_ring_not_empty_track1", 0, targetFrame);
    }
    if (s.sourceRingAt(0).seekRequest() != s.sourceRingAt(0).seekAck()) {
        return reply("seek_source_ack_pending_track0", 0, targetFrame);
    }
    if (s.sourceRingAt(1).seekRequest() != s.sourceRingAt(1).seekAck()) {
        return reply("seek_source_ack_pending_track1", 0, targetFrame);
    }
    if (s.outputRing.availableReadFrames() != 0) {
        return reply("seek_output_ring_not_drained", 0, targetFrame);
    }
    if (s.outputRing.seekRequest() != s.outputRing.seekAck()) {
        return reply("seek_output_ack_pending", 0, targetFrame);
    }
    if (targetFrame < s.writerAt(0).nextWriteFrame()) {
        return reply("seek_target_behind_writer_track0", 0, targetFrame);
    }
    if (targetFrame < s.writerAt(1).nextWriteFrame()) {
        return reply("seek_target_behind_writer_track1", 0, targetFrame);
    }

    // Both tracks re-anchor at the same accepted frame A = targetFrame.
    // Every precondition above already passed, so a rejection here leaves
    // the session unusable by design (fail closed, run aborts).
    for (int t = 0; t < kTrackCount; ++t) {
        if (s.writerAt(t).requestSeek(targetFrame) != WriterStatus::kOk) {
            return reply(t == 0 ? "writer_seek_rejected_track0"
                                : "writer_seek_rejected_track1",
                         0, targetFrame);
        }
    }

    // The queue was verified empty above, so this enqueue cannot fail.
    const uint64_t seq = s.enqueueCommand(
        CommandType::kSeek, static_cast<int64_t>(targetPtsUs));
    if (seq == 0) {
        return reply("queue_full", 0, targetFrame);
    }
    return reply("enqueued", seq, targetFrame);
}

// ---------------------------------------------------------------------------
// JNI: ingestAsyncRuntimeQueueMultiSourceRealtimeClockPcm16
// Owner-thread-only source-ring producer for ONE track via that track's
// NODE-OWNED writer. Treats `pcm` as interleaved little-endian signed
// PCM16 at byte offset 0 and clamps the accepted frame count to
// min(frameCount, 8192, capacityFramesFromBuffer). Writer backpressure
// (ring_full/partial_write) is a reported outcome, not an error. The
// Kotlin pump keeps the two accepted totals in lockstep.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_ingestAsyncRuntimeQueueMultiSourceRealtimeClockPcm16(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
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

    const auto session = FindMsRealtimeClockSession(handle);
    if (!session) return replyReject("not_found");
    if (std::this_thread::get_id() != session->ownerThreadId) {
        return replyReject("wrong_owner_thread");
    }
    if (trackIndex != 0 && trackIndex != 1) return replyReject("invalid_track_index");
    if (frameCount <= 0) return replyReject("invalid_frame_count");
    if (!pcmBufferJ) return replyReject("null_pcm_buffer");

    const jlong bufferCapacityBytes = env->GetDirectBufferCapacity(pcmBufferJ);
    if (bufferCapacityBytes < 0) return replyReject("non_direct_buffer");
    void* rawAddr = env->GetDirectBufferAddress(pcmBufferJ);
    if (!rawAddr) return replyReject("direct_buffer_address_unavailable");

    const int64_t bytesPerFrame = 2ll * session->channelCount;
    const int64_t capacityFramesFromBuffer =
        static_cast<int64_t>(bufferCapacityBytes) / bytesPerFrame;
    if (capacityFramesFromBuffer <= 0) {
        return replyReject("insufficient_buffer_capacity");
    }

    const int     track = static_cast<int>(trackIndex);
    const int64_t framesToWrite = std::min<int64_t>(
        {static_cast<int64_t>(frameCount), kMaxIngestFramesPerCall,
         capacityFramesFromBuffer});

    AsyncRuntimeQueueMultiSourceRealtimeClockSession& s = *session;
    const int16_t* pcm = static_cast<const int16_t*>(rawAddr);
    int64_t framesAccepted = 0;
    const WriterStatus writerStatus = s.writerAt(track).write(
        pcm, framesToWrite, s.sampleRate, s.channelCount, &framesAccepted);

    if (framesAccepted > 0) {
        s.nativeAcceptedChecksum[track] = AccumulateChecksum(
            s.nativeAcceptedChecksum[track], pcm,
            framesAccepted * s.channelCount);
        s.totalFramesAccepted[track] += framesAccepted;
        s.cv_.notify_all(); // wake the worker: new source frames
    }

    const AudioDecoderRingWriter::Metrics& m = s.writerAt(track).metrics();
    std::snprintf(status, sizeof(status),
        "status=ok;trackIndex=%d;framesRequested=%d;framesAccepted=%lld;"
        "writerStatus=%s;"
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
// JNI: setAsyncRuntimeQueueMultiSourceRealtimeClockEos
// Owner-thread-only. JOINT writer-local EOS: the single entry point sets
// BOTH node-owned writers EOS together, plus the atomic worker-visible
// flag. There is deliberately no per-track EOS route (no independent-EOS
// proof, no ragged tail). The X4 driver sets EOS only after the exact
// expected timeline completed, so the worker never has a remaining window
// to zero-fill.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_setAsyncRuntimeQueueMultiSourceRealtimeClockEos(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[160];
    const auto session = FindMsRealtimeClockSession(handle);
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
    session->eosPublished.store(true, std::memory_order_release);
    session->cv_.notify_all();
    std::snprintf(status, sizeof(status),
        "status=ok;eosTrack0=%s;eosTrack1=%s",
        session->writerAt(0).isEos() ? "true" : "false",
        session->writerAt(1).isEos() ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: readAsyncRuntimeQueueMultiSourceRealtimeClockOutputPcm16
// Owner-thread-only output-ring CONSUMER: consumes a pending start/seek
// output ack first (reporting frames discarded at the boundary), then pops
// mixed PCM16 into the caller's direct ByteBuffer at byte offset 0.
// maxFrames == 0 is a legal ack-only call.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_readAsyncRuntimeQueueMultiSourceRealtimeClockOutputPcm16(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
    jobject pcmBufferJ,
    jint maxFrames) {

    char status[640];

    auto replyReject = [&](const char* token) -> jstring {
        std::snprintf(status, sizeof(status),
            "status=%s;framesRequested=%d;framesRead=0",
            token, static_cast<int>(maxFrames));
        return env->NewStringUTF(status);
    };

    const auto session = FindMsRealtimeClockSession(handle);
    if (!session) return replyReject("not_found");
    if (std::this_thread::get_id() != session->ownerThreadId) {
        return replyReject("wrong_owner_thread");
    }
    if (maxFrames < 0) return replyReject("invalid_max_frames");
    if (!pcmBufferJ) return replyReject("null_pcm_buffer");
    const jlong bufferCapacityBytes = env->GetDirectBufferCapacity(pcmBufferJ);
    if (bufferCapacityBytes < 0) return replyReject("non_direct_buffer");
    void* rawAddr = env->GetDirectBufferAddress(pcmBufferJ);
    if (!rawAddr) return replyReject("direct_buffer_address_unavailable");
    const int64_t bytesPerFrame = 2ll * session->channelCount;
    const int64_t capacityFramesFromBuffer =
        static_cast<int64_t>(bufferCapacityBytes) / bytesPerFrame;
    if (capacityFramesFromBuffer < static_cast<int64_t>(maxFrames)) {
        return replyReject("insufficient_buffer_capacity");
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
            session->cv_.notify_all(); // wake the worker: ack consumed
        }
    }

    int16_t* out = static_cast<int16_t*>(rawAddr);
    const int64_t framesToRead = std::min(
        {static_cast<int64_t>(maxFrames), capacityFramesFromBuffer,
         kMaxRingCapacityFrames});
    int64_t framesRead = 0;
    if (framesToRead > 0) {
        framesRead = session->outputRing.tryPopFrames(out, framesToRead);
        if (framesRead > 0) {
            session->nativeOutputReadChecksum = AccumulateChecksum(
                session->nativeOutputReadChecksum, out,
                framesRead * session->channelCount);
        }
    }
    session->totalOutputFramesRead += framesRead;

    std::snprintf(status, sizeof(status),
        "status=ok;framesRequested=%d;framesRead=%lld;bytesRead=%lld;"
        "channelCount=%d;outputAvailableReadFrames=%lld;"
        "nativeOutputReadChecksumHex=%016llx;totalOutputFramesRead=%lld;"
        "seekAckConsumed=%s;discardedFramesOnSeek=%lld;newStartFrame=%lld",
        static_cast<int>(maxFrames),
        static_cast<long long>(framesRead),
        static_cast<long long>(framesRead * bytesPerFrame),
        static_cast<int>(session->channelCount),
        static_cast<long long>(session->outputRing.availableReadFrames()),
        static_cast<unsigned long long>(session->nativeOutputReadChecksum),
        static_cast<long long>(session->totalOutputFramesRead),
        seekAckConsumed ? "true" : "false",
        static_cast<long long>(discardedFramesOnSeek),
        static_cast<long long>(newStartFrame));
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: snapshotAsyncRuntimeQueueMultiSourceRealtimeClock
// Owner-thread-only. Coordinator/provider/worker/timing facts come
// exclusively from the worker-published mirror (copied under the TU-local
// mutex); the owner never touches the clock, coordinator, or providers
// directly. ownerDispatchCalls is structurally 0 (no owner-side dispatch
// entry point exists) and noCallerSuppliedNativeTime is structurally true
// (no entry point of this TU accepts a time argument). Built through the
// bounded StatusAppender into an 8192-byte stack buffer so every key is
// explicit and never silently truncated (overflow latches and fails closed
// with status=snapshot_overflow).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_snapshotAsyncRuntimeQueueMultiSourceRealtimeClock(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[8192];

    const auto session = FindMsRealtimeClockSession(handle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread");
        return env->NewStringUTF(status);
    }

    AsyncRuntimeQueueMultiSourceRealtimeClockSession& s = *session;
    PublishedState ps;
    uint64_t commandsEnqueued = 0;
    size_t   queueDepth       = 0;
    {
        std::lock_guard<std::mutex> lock(s.mutex_);
        ps               = s.published_;
        commandsEnqueued = s.commandsEnqueued;
        queueDepth       = s.queueCount;
    }
    const uint64_t ownerIdHash = std::hash<std::thread::id>{}(s.ownerThreadId);
    const int64_t realtimeElapsedMs =
        ps.realtimeElapsedNs >= 0 ? ps.realtimeElapsedNs / 1'000'000LL : -1;

    StatusAppender out(status, sizeof(status));
    out.appendf(
        "status=ok;"
        "workerStarted=%s;workerExited=%s;workerThreadDistinct=%s;"
        "ownerThreadIdHash=%llu;workerThreadIdHash=%llu;"
        "started=%s;timelineComplete=%s;terminal=%s;"
        "commandsEnqueued=%llu;commandsProcessed=%llu;commandErrors=%llu;"
        "lastCommandSeq=%llu;lastCommandResult=%s;queueDepth=%zu;"
        "ownerDispatchCalls=0;noCallerSuppliedNativeTime=true;"
        "workerOwnsMonotonicClock=true;"
        "routedSourceCount=%zu;routedSourceId0=%s;routedSourceId1=%s;"
        "nodeOwnsRingTrack0=%s;nodeOwnsRingTrack1=%s;"
        "lastDispatchResult=%s;nextDispatchFrame=%lld;lastMediaPositionUs=%lld;"
        "totalFramesRendered=%lld;totalFramesPushed=%lld;dispatchCount=%llu;"
        "okCount=%llu;silenceCount=%llu;backpressureCount=%llu;"
        "schedulerErrorCount=%llu;"
        "workerLoopCount=%llu;workerSleepCount=%llu;"
        "workerNoFramesDueWaits=%llu;workerStarvedWaits=%llu;"
        "workerAwaitingOutputAckWaits=%llu;workerAwaitingSourceAckWaits=%llu;"
        "workerDispatchAnomalies=%llu;nonMonotonicTimeAnomalies=%llu;"
        "epochStartFrame=%lld;"
        "nativeTimingF0=%lld;nativeTimingF1=%lld;"
        "nativeTimingT0Ns=%lld;nativeTimingT1Ns=%lld;"
        "nativeRealtimeElapsedNs=%lld;nativeRealtimeElapsedMs=%lld;"
        "realtimeElapsedOk=%s;"
        "backlogSampleCount=%llu;maxRenderCursorBacklogUs=%lld;"
        "realtimeBacklogBoundOk=%s;clockDriftSampleCount=%llu;",
        ps.workerStarted ? "true" : "false",
        ps.workerExited ? "true" : "false",
        ps.workerThreadDistinct ? "true" : "false",
        static_cast<unsigned long long>(ownerIdHash),
        static_cast<unsigned long long>(ps.workerThreadIdHash),
        ps.started ? "true" : "false",
        ps.timelineComplete ? "true" : "false",
        ps.terminal ? "true" : "false",
        static_cast<unsigned long long>(commandsEnqueued),
        static_cast<unsigned long long>(ps.commandsProcessed),
        static_cast<unsigned long long>(ps.commandErrors),
        static_cast<unsigned long long>(ps.lastCommandSeq),
        ps.lastCommandResult,
        queueDepth,
        s.scheduler.routedSourceCount(),
        s.scheduler.routedSourceCount() > 0 ? s.scheduler.routedSourceIdAt(0).c_str() : "",
        s.scheduler.routedSourceCount() > 1 ? s.scheduler.routedSourceIdAt(1).c_str() : "",
        s.sourceNode0->ownsRing() ? "true" : "false",
        s.sourceNode1->ownsRing() ? "true" : "false",
        ps.lastDispatchToken,
        static_cast<long long>(ps.nextDispatchFrame),
        static_cast<long long>(ps.lastMediaPositionUs),
        static_cast<long long>(ps.totalFramesRendered),
        static_cast<long long>(ps.totalFramesPushed),
        static_cast<unsigned long long>(ps.dispatchCount),
        static_cast<unsigned long long>(ps.okCount),
        static_cast<unsigned long long>(ps.silenceCount),
        static_cast<unsigned long long>(ps.backpressureCount),
        static_cast<unsigned long long>(ps.schedulerErrorCount),
        static_cast<unsigned long long>(ps.workerLoopCount),
        static_cast<unsigned long long>(ps.workerSleepCount),
        static_cast<unsigned long long>(ps.workerNoFramesDueWaits),
        static_cast<unsigned long long>(ps.workerStarvedWaits),
        static_cast<unsigned long long>(ps.workerAwaitingOutputAckWaits),
        static_cast<unsigned long long>(ps.workerAwaitingSourceAckWaits),
        static_cast<unsigned long long>(ps.workerDispatchAnomalies),
        static_cast<unsigned long long>(ps.nonMonotonicTimeAnomalies),
        static_cast<long long>(ps.epochStartFrame),
        static_cast<long long>(ps.timingF0Frame),
        static_cast<long long>(ps.timingF1Frame),
        static_cast<long long>(ps.timingT0Ns),
        static_cast<long long>(ps.timingT1Ns),
        static_cast<long long>(ps.realtimeElapsedNs),
        static_cast<long long>(realtimeElapsedMs),
        ps.realtimeElapsedOk ? "true" : "false",
        static_cast<unsigned long long>(ps.backlogSampleCount),
        static_cast<long long>(ps.maxRenderCursorBacklogUs),
        ps.realtimeBacklogBoundOk ? "true" : "false",
        static_cast<unsigned long long>(ps.clockDriftSampleCount));

    for (int track = 0; track < kTrackCount; ++track) {
        const AudioDecoderRingWriter::Metrics& wm = s.writerAt(track).metrics();
        out.appendf(
            "providerExpectedNextFrameTrack%d=%lld;providerUnderrunEventsTrack%d=%llu;"
            "providerFramesZeroFilledTrack%d=%llu;providerForwardSkipFramesTrack%d=%llu;"
            "providerRewindRejectsTrack%d=%llu;"
            "sourceAvailableReadFramesTrack%d=%lld;"
            "sourceSeekRequestTrack%d=%u;sourceSeekAckTrack%d=%u;"
            "writerEosTrack%d=%s;writerNextWriteFrameTrack%d=%lld;"
            "writerTotalFramesWrittenTrack%d=%llu;"
            "writerPartialWriteEventsTrack%d=%llu;writerBackpressureRejectsTrack%d=%llu;"
            "writerSeekRequestsTrack%d=%llu;"
            "totalFramesAcceptedTrack%d=%lld;nativeAcceptedChecksumHexTrack%d=%016llx;",
            track, static_cast<long long>(ps.providerExpectedNextFrame[track]),
            track, static_cast<unsigned long long>(ps.providerUnderrunEvents[track]),
            track, static_cast<unsigned long long>(ps.providerFramesZeroFilled[track]),
            track, static_cast<unsigned long long>(ps.providerForwardSkipFrames[track]),
            track, static_cast<unsigned long long>(ps.providerRewindRejects[track]),
            track, static_cast<long long>(s.sourceRingAt(track).availableReadFrames()),
            track, s.sourceRingAt(track).seekRequest(),
            track, s.sourceRingAt(track).seekAck(),
            track, s.writerAt(track).isEos() ? "true" : "false",
            track, static_cast<long long>(s.writerAt(track).nextWriteFrame()),
            track, static_cast<unsigned long long>(wm.totalFramesWritten),
            track, static_cast<unsigned long long>(wm.partialWriteEvents),
            track, static_cast<unsigned long long>(wm.backpressureRejects),
            track, static_cast<unsigned long long>(wm.seekRequests),
            track, static_cast<long long>(s.totalFramesAccepted[track]),
            track, static_cast<unsigned long long>(s.nativeAcceptedChecksum[track]));
    }

    // X5 envelope telemetry: mode flag + owner-side keyframe counts read
    // directly (immutable after create), worker-folded application facts
    // from the published mirror. All false/0 in X4 mode.
    out.appendf(
        "envelopeProofEnabled=%s;envelopeApplied=%s;"
        "envelopeEvaluations=%llu;"
        "minEffectiveGain=%.9f;maxEffectiveGain=%.9f;"
        "envelopeKeyframeCountTrack0=%zu;envelopeKeyframeCountTrack1=%zu;",
        s.envelopeProofEnabled ? "true" : "false",
        ps.envelopeApplied ? "true" : "false",
        static_cast<unsigned long long>(ps.envelopeEvaluations),
        ps.minEffectiveGain,
        ps.maxEffectiveGain,
        s.trackEnvelopes[0].keyframeCount(),
        s.trackEnvelopes[1].keyframeCount());

    out.appendf(
        "outputAvailableReadFrames=%lld;"
        "outputSeekRequest=%u;outputSeekAck=%u;"
        "totalOutputFramesRead=%lld;nativeOutputReadChecksumHex=%016llx;"
        "joinCount=%u;destroyCalls=%u;"
        "sampleRate=%d;channelCount=%d;maxFramesPerMix=%lld;"
        "expectedFrameCount=%lld;"
        "proofBoundary=%s",
        static_cast<long long>(s.outputRing.availableReadFrames()),
        s.outputRing.seekRequest(),
        s.outputRing.seekAck(),
        static_cast<long long>(s.totalOutputFramesRead),
        static_cast<unsigned long long>(s.nativeOutputReadChecksum),
        s.joinCount.load(std::memory_order_acquire),
        s.destroyCalls.load(std::memory_order_acquire),
        static_cast<int>(s.sampleRate),
        static_cast<int>(s.channelCount),
        static_cast<long long>(s.maxFramesPerMix),
        static_cast<long long>(s.expectedFrames),
        kProofBoundary);

    if (out.overflowed()) {
        std::snprintf(status, sizeof(status), "status=snapshot_overflow");
    }
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAsyncRuntimeQueueMultiSourceRealtimeClockSession
// Callable from any thread; idempotent erase-once under the registry
// mutex. Sets the stop flag, wakes the worker, and JOINS (never detaches)
// before replying, so the reply's final counters are race-free. A second
// call (or unknown handle) returns status=not_found.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_destroyAsyncRuntimeQueueMultiSourceRealtimeClockSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[384];

    std::shared_ptr<AsyncRuntimeQueueMultiSourceRealtimeClockSession> session;
    {
        std::lock_guard<std::mutex> lock(gMsRealtimeClockRegistryMutex);
        auto it = gMsRealtimeClockSessions.find(static_cast<int64_t>(handle));
        if (it != gMsRealtimeClockSessions.end()) {
            session = std::move(it->second);
            gMsRealtimeClockSessions.erase(it);
        }
    }
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }

    session->destroyCalls.fetch_add(1, std::memory_order_acq_rel);
    session->shutdownWorker();

    // Post-join reads are race-free: the worker has exited.
    PublishedState ps;
    {
        std::lock_guard<std::mutex> lock(session->mutex_);
        ps = session->published_;
    }
    const bool joined = session->joinCount.load(std::memory_order_acquire) > 0;
    std::snprintf(status, sizeof(status),
        "status=ok;workerJoined=%s;workerExited=%s;joinCount=%u;"
        "destroyCalls=%u;finalCommandsProcessed=%llu;finalCommandErrors=%llu;"
        "finalDispatchCount=%llu;finalTotalFramesPushed=%lld",
        joined ? "true" : "false",
        ps.workerExited ? "true" : "false",
        session->joinCount.load(std::memory_order_acquire),
        session->destroyCalls.load(std::memory_order_acquire),
        static_cast<unsigned long long>(ps.commandsProcessed),
        static_cast<unsigned long long>(ps.commandErrors),
        static_cast<unsigned long long>(ps.dispatchCount),
        static_cast<long long>(ps.totalFramesPushed));
    return env->NewStringUTF(status);
}
