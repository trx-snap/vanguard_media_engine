// P4-AUDIO-ASYNC-RUNTIME-QUEUE-REALTIME-CLOCK-PACING (sub-slice X3, under
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): diagnostic async
// runtime queue session whose native worker thread OWNS a real monotonic
// wall-clock render/dispatch timebase. Unlike the X1/X2 scheduler TU
// (android_phase4_async_runtime_queue_scheduler_session_jni.cpp, untouched
// and behaviorally reproducible), every AudioClock /
// ClockedAudioTransportCoordinator time value here is read by the worker
// itself from std::chrono::steady_clock at the moment of the call. No JNI
// entry point accepts a sysTimeNs/syntheticSysTimeNs argument: Kotlin can
// never inject a time value into a native control command.
//
// Thread/role map (SPSC roles preserved, identical to X1/X2):
// - Owner thread (session creator; every non-destroy JNI entry point):
//   source-ring PRODUCER via the node-owned AudioDecoderRingWriter
//   (ingest/seek-request/EOS) and output-ring CONSUMER
//   (consumePendingSeekOnReaderThread + tryPopFrames via the read entry
//   point). It also enqueues commands and reads the worker-published
//   snapshot mirror.
// - Worker thread: sole reader of steady_clock for media time, sole caller
//   of every AudioClock mutator (including recordDriftSample), every
//   coordinator control/dispatch method, and the output ring's producer
//   role (plus the explicit source seek-ack consume while executing a Seek
//   command).
//
// Realtime pacing contract:
// - The worker dispatches FULL maxFramesPerMix windows only, so the render
//   cursor stays window-aligned inside each epoch and the wall clock can
//   never force a final short window that overshoots the expected timeline
//   into provider zero-fill. framesDue below a full window is the normal
//   kNoFramesDue steady state (counted, never an anomaly, never progress).
// - Bounded catch-up: at most kMaxDispatchesPerWake (8) dispatches per
//   wake, stopping early on no-frames-due, backpressure (normal telemetry
//   in X3), awaiting-seek-ack, source starvation, or terminal.
// - Each condition_variable wait derives its duration from the clock /
//   render cursor (time until the next full window is due) clamped to at
//   most 5ms, and wakes on stop or a queued command.
// - Native per-epoch timing gate excluding start pre-roll: t0 is the
//   steady_clock read of the dispatch that advances the render cursor past
//   F0 (first window boundary >= 8192 frames); t1 the dispatch that
//   advances past F0 + sampleRate frames. elapsed must land in
//   [980ms, 1350ms]. A Seek executed before t1 exists fails closed with
//   timing_window_unavailable.
// - Backlog gate: at every counted dispatch past the per-epoch warmup
//   (8192 frames past the epoch start frame) the worker records
//   backlog = clockPositionUs - renderCursorPtsUs via
//   AudioClock::recordDriftSample and folds the max; the bound is
//   < 250000us. Sampling only at dispatch points naturally excludes the
//   start handshake and the seek pause/flush/re-anchor stalls.
//
// Honest non-claims:
// - Muted diagnostic realtime-pacing proof only: the steady_clock timebase
//   is a render/dispatch timebase, NOT a presentation clock and NOT an
//   A/V-sync or latency claim. No AudioTrack/AAudio/OpenSL/Oboe in native,
//   no audible output, no OS audio callback, no realtime priority, no
//   SCHED_FIFO, no affinity. No product export route, no
//   product/editor/app wiring, no streaming/cache, no iOS, no C++ audio /
//   graph primitive changes.
// - The worker never touches JNIEnv, never attaches to the JVM, never
//   calls back into Kotlin, and never logs. The TU-local mutex guards only
//   the command queue + published snapshot mirror; a second tiny mutex
//   serializes join; the registry mutex guards the lifecycle map.
// - Forward-only seek (quiescent rings required, fail closed otherwise).
//   Writer-local EOS only, set by the owner after the exact expected
//   timeline completed, so provider zero-fill can never enter the identity
//   checksums.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt. Its session registry and handle counter are disjoint
// from every other diagnostic session TU (including the X1/X2 scheduler
// TU).
//
// JNI entry points (VanguardNativeBridge.kt companion object):
//   createAsyncRuntimeQueueRealtimeClockSession   -> jlong handle (0 on failure)
//   startAsyncRuntimeQueueRealtimeClock           -> jstring key=value (no time arg)
//   seekAsyncRuntimeQueueRealtimeClock            -> jstring key=value (no time arg)
//   ingestAsyncRuntimeQueueRealtimeClockPcm16     -> jstring key=value
//   setAsyncRuntimeQueueRealtimeClockEos          -> jstring key=value
//   readAsyncRuntimeQueueRealtimeClockOutputPcm16 -> jstring key=value
//   snapshotAsyncRuntimeQueueRealtimeClock        -> jstring key=value
//   destroyAsyncRuntimeQueueRealtimeClockSession  -> jstring key=value

#include <jni.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
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
// embeds it so a physical run proves this exact realtime-clock TU
// executed.
constexpr const char* kProofBoundary =
    "diagnostic_async_runtime_queue_realtime_clock_proof_only_worker_owned_std_chrono_steady_clock_render_dispatch_timebase_no_caller_supplied_native_time_on_any_control_command_command_serialized_source_ring_spsc_output_ring_spsc_full_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_not_a_presentation_clock_no_audible_output_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_realtime_priority_no_sched_fifo_no_affinity_no_product_editor_app_wiring_no_streaming_cache_no_ios_no_export_route_changes";

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
constexpr int64_t kMicrosPerSecond        = 1'000'000LL;
constexpr size_t  kCommandQueueCapacity   = 8;

// Frozen X3 realtime constants.
constexpr int     kMaxDispatchesPerWake   = 8;
constexpr int64_t kMaxWaitNs              = 5'000'000LL;   // 5ms cv clamp
constexpr int64_t kTimingWarmupFrames     = 8192;          // F0 floor
constexpr int64_t kBacklogWarmupFrames    = 8192;          // per-epoch
constexpr int64_t kTimingMinElapsedNs     = 980'000'000LL;
constexpr int64_t kTimingMaxElapsedNs     = 1'350'000'000LL;
constexpr int64_t kMaxBacklogBoundUs      = 250'000LL;

constexpr const char* kMixNodeId    = "async_rtclock_mix";
constexpr const char* kSourceNodeId = "async_rtclock_src";

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

const Graph& PrepareTopology(Graph& g,
                             const std::shared_ptr<AudioMixBusNode>& mixBus,
                             const std::shared_ptr<DecodedAudioPcmSourceNode>& sourceNode) {
    (void)g.addNode(mixBus);
    (void)g.addNode(sourceNode);
    (void)g.connect(kSourceNodeId, "audio_out", kMixNodeId, "primary_audio_in");
    return g;
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
// literals so publishing never allocates.
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

    int64_t  providerExpectedNextFrame{0};
    uint64_t providerUnderrunEvents{0};
    uint64_t providerFramesZeroFilled{0};
    uint64_t providerForwardSkipFrames{0};
    uint64_t providerRewindRejects{0};
};

// ---------------------------------------------------------------------------
// Async runtime queue realtime-clock session. Member declaration order is
// construction order: the graph is populated (PrepareTopology) before the
// scheduler snapshots it, and the worker thread is declared LAST and
// started only after the fully-validated session exists, so no worker can
// ever observe a partially-constructed rig. shutdownWorker() joins (never
// detaches) before any rig member is destroyed.
// ---------------------------------------------------------------------------
struct AsyncRuntimeQueueRealtimeClockSession {
    Graph                                      graphTopology;
    std::shared_ptr<AudioMixBusNode>           mixBus;
    std::shared_ptr<DecodedAudioPcmSourceNode> sourceNode;
    AudioSpscAudioRingBuffer                   outputRing;
    GraphAudioScheduler                        scheduler;
    AudioClock                                 clock;
    ClockedAudioTransportCoordinator           coordinator;
    std::thread::id                            ownerThreadId;

    int32_t sampleRate;
    int32_t channelCount;
    int64_t maxFramesPerMix;
    int64_t expectedFrames;

    // Owner-thread-private accounting (single owner thread enforced on
    // every non-destroy entry point).
    uint64_t nativeAcceptedChecksum{0};
    int64_t  totalFramesAccepted{0};
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

    AsyncRuntimeQueueRealtimeClockSession(int32_t sampleRateIn,
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
          maxFramesPerMix(maxFramesPerMixIn),
          expectedFrames(expectedFrameCountIn) {}

    ~AsyncRuntimeQueueRealtimeClockSession() { shutdownWorker(); }

    AudioSpscAudioRingBuffer& sourceRing() { return *sourceNode->ring(); }
    AudioDecoderRingWriter&   writer()     { return *sourceNode->ringWriter(); }
    RingBufferAudioSampleProvider& provider() {
        return *static_cast<RingBufferAudioSampleProvider*>(
            sourceNode->audioSampleProvider());
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
            RingBufferAudioSampleProvider& p = provider();
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
            ps.providerExpectedNextFrame  = p.expectedNextFrame();
            ps.providerUnderrunEvents     = p.underrunEvents();
            ps.providerFramesZeroFilled   = p.framesZeroFilled();
            ps.providerForwardSkipFrames  = p.forwardSkipFrames();
            ps.providerRewindRejects      = p.rewindRejects();
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
                    // The owner already published the source-ring seek
                    // request (producer role) over a verified-empty ring;
                    // consume the ack here on the ring's consumer thread.
                    const int64_t targetFrame =
                        ClockedAudioTransportCoordinator::frameOfPositionUs(
                            cmd.a, sampleRate);
                    int64_t srcAckFrame = -1;
                    if (!sourceRing().consumePendingSeekOnReaderThread(&srcAckFrame)) {
                        lastCommandResult = "source_ack_missing";
                        ++commandErrors;
                        break;
                    }
                    if (srcAckFrame != targetFrame) {
                        lastCommandResult = "source_ack_mismatch";
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
            // no-frames-due, backpressure, ack gate, starvation, terminal,
            // or the per-wake cap.
            bool progressed = localCount > 0;
            int64_t waitNs = kMaxWaitNs;
            if (startedLocal) {
                auto csnap = coordinator.snapshot();
                if (!csnap.terminal &&
                    outputRing.seekRequest() != outputRing.seekAck()) {
                    // Start/seek requires the owner to consume the output
                    // ack via the read path before the worker may render.
                    ++awaitingOutputAckWaits;
                } else if (!csnap.terminal &&
                           sourceRing().seekRequest() != sourceRing().seekAck()) {
                    // Seek request published, Seek command not yet drained:
                    // no dispatch during the pending source ack gate.
                    ++awaitingSourceAckWaits;
                } else if (!csnap.terminal) {
                    for (int i = 0; i < kMaxDispatchesPerWake; ++i) {
                        csnap = coordinator.snapshot();
                        const int64_t cursor    = csnap.nextDispatchFrame;
                        const int64_t remaining = expectedFrames - cursor;
                        if (remaining <= 0) break; // timeline complete
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
                        const int64_t srcAvail =
                            sourceRing().availableReadFrames();
                        if (srcAvail < windowFrames) {
                            // Realtime source starvation: never dispatch a
                            // short source window (zero-fill would poison
                            // the identity). Kotlin keeps decode ahead.
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
                            // Normal telemetry in X3 (coordinator counted
                            // it); wait for the owner to drain.
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
// session TU. The mutex guards only this lifecycle map; values are
// shared_ptr so an in-flight entry point stays safe if destroy erases the
// map entry concurrently.
// ---------------------------------------------------------------------------
std::mutex gRealtimeClockRegistryMutex;
std::unordered_map<int64_t, std::shared_ptr<AsyncRuntimeQueueRealtimeClockSession>>
    gRealtimeClockSessions;
int64_t gNextRealtimeClockHandle = 1; // guarded by the registry mutex

std::shared_ptr<AsyncRuntimeQueueRealtimeClockSession> FindRealtimeClockSession(
    jlong handle) {
    std::lock_guard<std::mutex> lock(gRealtimeClockRegistryMutex);
    auto it = gRealtimeClockSessions.find(static_cast<int64_t>(handle));
    return it == gRealtimeClockSessions.end() ? nullptr : it->second;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAsyncRuntimeQueueRealtimeClockSession
// Fail-closed construction validation; the worker thread starts only after
// the rig validated (node owns its transport, route resolved to exactly the
// one source). expectedFrameCount must be window-aligned because the
// realtime worker dispatches full windows only.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createAsyncRuntimeQueueRealtimeClockSession(
    JNIEnv* /* env */,
    jobject /* companion */,
    jint sampleRate,
    jint channelCount,
    jlong expectedFrameCount,
    jint sourceRingCapacityFrames,
    jint outputRingCapacityFrames,
    jint maxFramesPerMix) {

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
    // Frozen X3 geometry: the source ring must absorb a full output ring
    // of decoded lead plus two mix windows of slack.
    if (srcCap < outCap + 2 * mfpm) return 0;

    std::shared_ptr<AsyncRuntimeQueueRealtimeClockSession> session;
    try {
        session = std::make_shared<AsyncRuntimeQueueRealtimeClockSession>(
            static_cast<int32_t>(sampleRate),
            static_cast<int32_t>(channelCount),
            expFrames, srcCap, outCap, mfpm);
    } catch (...) {
        return 0;
    }

    if (!session->sourceNode->ownsRing() ||
        !session->scheduler.targetValid() ||
        session->scheduler.routedSourceCount() != 1 ||
        session->scheduler.routedSourceIdAt(0) != kSourceNodeId) {
        return 0;
    }

    {
        std::lock_guard<std::mutex> lock(gRealtimeClockRegistryMutex);
        if (gRealtimeClockSessions.size() >= kMaxLiveSessions) return 0;
        if (!session->startWorker()) return 0;
        const int64_t handle = gNextRealtimeClockHandle++;
        gRealtimeClockSessions[handle] = std::move(session);
        return static_cast<jlong>(handle);
    }
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
// JNI: startAsyncRuntimeQueueRealtimeClock
// Owner-thread-only, enqueue-only, NO time argument: the WORKER reads
// steady_clock itself and executes coordinator.start(0, now). After the
// worker reports the command processed, the owner must consume the
// output-ring seek ack via the read entry point before the worker can
// render its first window.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_startAsyncRuntimeQueueRealtimeClock(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[192];
    const auto session = FindRealtimeClockSession(handle);
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
// JNI: seekAsyncRuntimeQueueRealtimeClock
// Owner-thread-only, forward-only, quiescent-only, NO time argument, fail
// closed otherwise: requires every prior command processed (checked exactly
// under the same mutex the worker publishes through), no EOS, an empty
// source ring, a fully-drained output ring, and no pending seek
// handshakes. On success the OWNER publishes the source writer seek
// request (producer role), then enqueues the Seek command; the WORKER
// consumes the source ack and calls coordinator.seek(targetPtsUs, fresh
// steady_clock now); the owner must then consume the output ack via read.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_seekAsyncRuntimeQueueRealtimeClock(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
    jlong targetPtsUs) {

    char status[320];
    const auto session = FindRealtimeClockSession(handle);

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

    AsyncRuntimeQueueRealtimeClockSession& s = *session;
    const int64_t targetFrame = ClockedAudioTransportCoordinator::frameOfPositionUs(
        static_cast<int64_t>(targetPtsUs), s.sampleRate);

    // Quiescence: with the source ring empty and no EOS the worker is
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
    }
    if (s.sourceRing().availableReadFrames() != 0) {
        return reply("seek_source_ring_not_empty", 0, targetFrame);
    }
    if (s.sourceRing().seekRequest() != s.sourceRing().seekAck()) {
        return reply("seek_source_ack_pending", 0, targetFrame);
    }
    if (s.outputRing.availableReadFrames() != 0) {
        return reply("seek_output_ring_not_drained", 0, targetFrame);
    }
    if (s.outputRing.seekRequest() != s.outputRing.seekAck()) {
        return reply("seek_output_ack_pending", 0, targetFrame);
    }
    if (targetFrame < s.writer().nextWriteFrame()) {
        return reply("seek_target_behind_writer", 0, targetFrame);
    }

    if (s.writer().requestSeek(targetFrame) != WriterStatus::kOk) {
        return reply("writer_seek_rejected", 0, targetFrame);
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
// JNI: ingestAsyncRuntimeQueueRealtimeClockPcm16
// Owner-thread-only source-ring producer via the NODE-OWNED writer. Treats
// `pcm` as interleaved little-endian signed PCM16 at byte offset 0 and
// clamps the accepted frame count to min(frameCount, 8192,
// capacityFramesFromBuffer). Writer backpressure (ring_full/partial_write)
// is a reported outcome, not an error.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_ingestAsyncRuntimeQueueRealtimeClockPcm16(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
    jobject pcmBufferJ,
    jint frameCount) {

    char status[768];

    auto replyReject = [&](const char* token) -> jstring {
        std::snprintf(status, sizeof(status),
            "status=%s;framesRequested=%d;framesAccepted=0",
            token, static_cast<int>(frameCount));
        return env->NewStringUTF(status);
    };

    const auto session = FindRealtimeClockSession(handle);
    if (!session) return replyReject("not_found");
    if (std::this_thread::get_id() != session->ownerThreadId) {
        return replyReject("wrong_owner_thread");
    }
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

    const int64_t framesToWrite = std::min<int64_t>(
        {static_cast<int64_t>(frameCount), kMaxIngestFramesPerCall,
         capacityFramesFromBuffer});

    const int16_t* pcm = static_cast<const int16_t*>(rawAddr);
    int64_t framesAccepted = 0;
    const WriterStatus writerStatus = session->writer().write(
        pcm, framesToWrite, session->sampleRate, session->channelCount,
        &framesAccepted);

    if (framesAccepted > 0) {
        session->nativeAcceptedChecksum = AccumulateChecksum(
            session->nativeAcceptedChecksum, pcm,
            framesAccepted * session->channelCount);
        session->totalFramesAccepted += framesAccepted;
        session->cv_.notify_all(); // wake the worker: new source frames
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
// JNI: setAsyncRuntimeQueueRealtimeClockEos
// Owner-thread-only. Writer-local EOS plus the atomic worker-visible flag.
// The X3 driver sets EOS only after the exact expected timeline completed,
// so the worker never has a remaining window to zero-fill.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_setAsyncRuntimeQueueRealtimeClockEos(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[128];
    const auto session = FindRealtimeClockSession(handle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found;eos=false");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread;eos=false");
        return env->NewStringUTF(status);
    }

    session->writer().setEos();
    session->eosPublished.store(true, std::memory_order_release);
    session->cv_.notify_all();
    std::snprintf(status, sizeof(status), "status=ok;eos=%s",
        session->writer().isEos() ? "true" : "false");
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: readAsyncRuntimeQueueRealtimeClockOutputPcm16
// Owner-thread-only output-ring CONSUMER: consumes a pending start/seek
// output ack first (reporting frames discarded at the boundary), then pops
// mixed PCM16 into the caller's direct ByteBuffer at byte offset 0.
// maxFrames == 0 is a legal ack-only call.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_readAsyncRuntimeQueueRealtimeClockOutputPcm16(
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

    const auto session = FindRealtimeClockSession(handle);
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
// JNI: snapshotAsyncRuntimeQueueRealtimeClock
// Owner-thread-only. Coordinator/provider/worker/timing facts come
// exclusively from the worker-published mirror (copied under the TU-local
// mutex); the owner never touches the clock, coordinator, or provider
// directly. ownerDispatchCalls is structurally 0 (no owner-side dispatch
// entry point exists) and noCallerSuppliedNativeTime is structurally true
// (no entry point of this TU accepts a time argument).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_snapshotAsyncRuntimeQueueRealtimeClock(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[4096];

    const auto session = FindRealtimeClockSession(handle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread");
        return env->NewStringUTF(status);
    }

    AsyncRuntimeQueueRealtimeClockSession& s = *session;
    PublishedState ps;
    uint64_t commandsEnqueued = 0;
    size_t   queueDepth       = 0;
    {
        std::lock_guard<std::mutex> lock(s.mutex_);
        ps               = s.published_;
        commandsEnqueued = s.commandsEnqueued;
        queueDepth       = s.queueCount;
    }
    const AudioDecoderRingWriter::Metrics& wm = s.writer().metrics();
    const uint64_t ownerIdHash = std::hash<std::thread::id>{}(s.ownerThreadId);
    const int64_t realtimeElapsedMs =
        ps.realtimeElapsedNs >= 0 ? ps.realtimeElapsedNs / 1'000'000LL : -1;

    std::snprintf(status, sizeof(status),
        "status=ok;"
        "workerStarted=%s;workerExited=%s;workerThreadDistinct=%s;"
        "ownerThreadIdHash=%llu;workerThreadIdHash=%llu;"
        "started=%s;timelineComplete=%s;terminal=%s;"
        "commandsEnqueued=%llu;commandsProcessed=%llu;commandErrors=%llu;"
        "lastCommandSeq=%llu;lastCommandResult=%s;queueDepth=%zu;"
        "ownerDispatchCalls=0;noCallerSuppliedNativeTime=true;"
        "workerOwnsMonotonicClock=true;"
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
        "realtimeBacklogBoundOk=%s;clockDriftSampleCount=%llu;"
        "providerExpectedNextFrame=%lld;providerUnderrunEvents=%llu;"
        "providerFramesZeroFilled=%llu;providerForwardSkipFrames=%llu;"
        "providerRewindRejects=%llu;"
        "sourceAvailableReadFrames=%lld;outputAvailableReadFrames=%lld;"
        "sourceSeekRequest=%u;sourceSeekAck=%u;"
        "outputSeekRequest=%u;outputSeekAck=%u;"
        "writerEos=%s;writerNextWriteFrame=%lld;writerTotalFramesWritten=%llu;"
        "writerPartialWriteEvents=%llu;writerBackpressureRejects=%llu;"
        "writerSeekRequests=%llu;"
        "totalFramesAccepted=%lld;nativeAcceptedChecksumHex=%016llx;"
        "totalOutputFramesRead=%lld;nativeOutputReadChecksumHex=%016llx;"
        "joinCount=%u;destroyCalls=%u;"
        "sampleRate=%d;channelCount=%d;maxFramesPerMix=%lld;"
        "expectedFrameCount=%lld;"
        "proofBoundary=%s",
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
        static_cast<unsigned long long>(ps.clockDriftSampleCount),
        static_cast<long long>(ps.providerExpectedNextFrame),
        static_cast<unsigned long long>(ps.providerUnderrunEvents),
        static_cast<unsigned long long>(ps.providerFramesZeroFilled),
        static_cast<unsigned long long>(ps.providerForwardSkipFrames),
        static_cast<unsigned long long>(ps.providerRewindRejects),
        static_cast<long long>(s.sourceRing().availableReadFrames()),
        static_cast<long long>(s.outputRing.availableReadFrames()),
        s.sourceRing().seekRequest(),
        s.sourceRing().seekAck(),
        s.outputRing.seekRequest(),
        s.outputRing.seekAck(),
        s.writer().isEos() ? "true" : "false",
        static_cast<long long>(s.writer().nextWriteFrame()),
        static_cast<unsigned long long>(wm.totalFramesWritten),
        static_cast<unsigned long long>(wm.partialWriteEvents),
        static_cast<unsigned long long>(wm.backpressureRejects),
        static_cast<unsigned long long>(wm.seekRequests),
        static_cast<long long>(s.totalFramesAccepted),
        static_cast<unsigned long long>(s.nativeAcceptedChecksum),
        static_cast<long long>(s.totalOutputFramesRead),
        static_cast<unsigned long long>(s.nativeOutputReadChecksum),
        s.joinCount.load(std::memory_order_acquire),
        s.destroyCalls.load(std::memory_order_acquire),
        static_cast<int>(s.sampleRate),
        static_cast<int>(s.channelCount),
        static_cast<long long>(s.maxFramesPerMix),
        static_cast<long long>(s.expectedFrames),
        kProofBoundary);
    return env->NewStringUTF(status);
}

// ---------------------------------------------------------------------------
// JNI: destroyAsyncRuntimeQueueRealtimeClockSession
// Callable from any thread; idempotent erase-once under the registry
// mutex. Sets the stop flag, wakes the worker, and JOINS (never detaches)
// before replying, so the reply's final counters are race-free. A second
// call (or unknown handle) returns status=not_found.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_destroyAsyncRuntimeQueueRealtimeClockSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[384];

    std::shared_ptr<AsyncRuntimeQueueRealtimeClockSession> session;
    {
        std::lock_guard<std::mutex> lock(gRealtimeClockRegistryMutex);
        auto it = gRealtimeClockSessions.find(static_cast<int64_t>(handle));
        if (it != gRealtimeClockSessions.end()) {
            session = std::move(it->second);
            gRealtimeClockSessions.erase(it);
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
