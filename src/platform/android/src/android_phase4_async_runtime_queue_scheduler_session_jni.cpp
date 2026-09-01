// P4-AUDIO-RUNTIME-QUEUE-SCHEDULER (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK /
// P4-AUDIO-MIXBUS): diagnostic async runtime queue/backpressure scheduler
// integration seam. One session owns the full diagnostic rig
// (DecodedAudioPcmSourceNode 6-arg node-owned source ring/writer/provider,
// GraphAudioScheduler auto-discovery, AudioMixBusNode, AudioClock,
// ClockedAudioTransportCoordinator, output AudioSpscAudioRingBuffer) PLUS
// one native worker thread that is the SOLE caller of every AudioClock
// mutator, every coordinator control/dispatch method, and the output ring's
// producer role. The Kotlin owner thread never dispatches: control commands
// (start/pause/resume/seek) are posted into a TU-local bounded command
// queue drained by the worker at the top of its loop, so
// ClockedAudioTransportCoordinator stays single-threaded exactly per its
// contract.
//
// Thread/role map (SPSC roles preserved):
// - Owner thread (session creator; every non-destroy JNI entry point):
//   source-ring PRODUCER via the node-owned AudioDecoderRingWriter
//   (ingest/seek-request/EOS) and output-ring CONSUMER
//   (consumePendingSeekOnReaderThread + tryPopFrames via the read entry
//   point). It also enqueues commands and reads the worker-published
//   snapshot mirror.
// - Worker thread: source-ring CONSUMER (GraphAudioScheduler ->
//   RingBufferAudioSampleProvider, plus the explicit source seek-ack
//   consume while executing a Seek command) and output-ring PRODUCER
//   (coordinator tryPushFrames/requestSeek). It alone calls
//   clock/coordinator methods and coordinator.snapshot(); the owner reads
//   only the mutex-published mirror.
//
// Honest non-claims:
// - Diagnostic async runtime queue/backpressure scheduler integration proof
//   only: no production export route, no product/editor/app wiring, no
//   streaming/cache, no iOS, no export route changes.
// - No AudioTrack/AAudio/OpenSL/Oboe, no audible output, no OS audio
//   callback, no realtime claim.
// - No native media timebase: every media-time tick fed into the
//   coordinator is caller-derived / frame-axis deterministic (synthetic
//   sysTimeNs advanced from the accepted frame axis via integer math).
//   std::chrono is used only as the bounded condition_variable wait_for
//   (1ms) pacing timeout plus the atomic stop flag -- steady-clock pacing
//   only, never media time. No priority elevation, no SCHED_FIFO.
// - No locks inside the vanguard audio primitives. The TU-local mutex
//   guards only the command queue + published snapshot mirror; a second
//   tiny mutex serializes join; the registry mutex guards the lifecycle
//   map.
// - The worker never touches JNIEnv, never attaches to the JVM, never
//   calls back into Kotlin, and never logs.
// - Forward-only seek (quiescent rings required, fail closed otherwise).
//   Writer-local EOS only. After EOS the worker may dispatch short/empty
//   source windows so RingBufferAudioSampleProvider zero-fills; that
//   zero-fill is reported honestly via the provider counters and the
//   workerZeroFillProbeWindows count, never hidden as recovery.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds; it is added via the Android-only target_sources block in
// src/CMakeLists.txt. Its session registry and handle counter are disjoint
// from every other diagnostic session TU.
//
// JNI entry points (VanguardNativeBridge.kt companion object):
//   createAsyncRuntimeQueueSchedulerSession      -> jlong handle (0 on failure)
//   startAsyncRuntimeQueueScheduler              -> jstring key=value
//   pauseAsyncRuntimeQueueScheduler              -> jstring key=value
//   resumeAsyncRuntimeQueueScheduler             -> jstring key=value
//   seekAsyncRuntimeQueueScheduler               -> jstring key=value
//   ingestAsyncRuntimeQueueSchedulerPcm16        -> jstring key=value
//   setAsyncRuntimeQueueSchedulerEos             -> jstring key=value
//   readAsyncRuntimeQueueSchedulerOutputPcm16    -> jstring key=value
//   snapshotAsyncRuntimeQueueScheduler           -> jstring key=value
//   destroyAsyncRuntimeQueueSchedulerSession     -> jstring key=value

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

// Canonical proof boundary for this slice; the Kotlin coordinator and Dart
// wrapper carry the identical verbatim constant, and the snapshot entry
// point embeds it so the physical run proves this exact TU executed.
constexpr const char* kProofBoundary =
    "diagnostic_async_runtime_queue_scheduler_integration_proof_only_worker_owned_clock_and_coordinator_command_serialized_source_ring_spsc_output_ring_spsc_caller_derived_systime_ticks_only_steady_clock_pacing_only_no_native_media_timebase_no_audible_output_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_product_editor_app_wiring_no_streaming_cache_no_ios_no_export_route_changes";

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
constexpr int64_t kInt64Max               = std::numeric_limits<int64_t>::max();
constexpr size_t  kCommandQueueCapacity   = 8;

constexpr const char* kMixNodeId    = "async_runtime_queue_mix";
constexpr const char* kSourceNodeId = "async_runtime_queue_src";

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

enum class CommandType : int32_t {
    kStart  = 1, // a = mediaPtsUs, b = syntheticSysTimeNs
    kPause  = 2, // b = syntheticSysTimeNs
    kResume = 3, // b = syntheticSysTimeNs
    kSeek   = 4, // a = targetPtsUs, b = syntheticSysTimeNs
};

struct Command {
    CommandType type{CommandType::kStart};
    int64_t     a{0};
    int64_t     b{0};
    uint64_t    seq{0};
};

// Worker-published mirror of every coordinator/provider/worker fact the
// owner thread may read. Written only by the worker under the session
// mutex; the owner copies it under the same mutex. All tokens are string
// literals so publishing never allocates.
struct PublishedState {
    bool     workerStarted{false};
    bool     workerExited{false};
    bool     started{false};
    bool     paused{false};
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
    uint64_t workerStarvedWaits{0};
    uint64_t workerAwaitingOutputAckWaits{0};
    uint64_t workerZeroFillProbeWindows{0};
    uint64_t workerBackpressureProbes{0};
    uint64_t workerDispatchAnomalies{0};

    int64_t  workerLastTickNs{0};
    int64_t  anchorMediaPtsUs{0};
    int64_t  anchorSysTimeNs{0};

    int64_t  providerExpectedNextFrame{0};
    uint64_t providerUnderrunEvents{0};
    uint64_t providerFramesZeroFilled{0};
    uint64_t providerForwardSkipFrames{0};
    uint64_t providerRewindRejects{0};
};

// ---------------------------------------------------------------------------
// Async runtime queue/backpressure scheduler session. Member declaration
// order is construction order: the graph is populated (PrepareTopology)
// before the scheduler snapshots it, and the worker thread is declared
// LAST and started only after the fully-validated session exists, so no
// worker can ever observe a partially-constructed rig. shutdownWorker()
// joins (never detaches) before any rig member is destroyed.
// ---------------------------------------------------------------------------
struct AsyncRuntimeQueueSchedulerSession {
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

    AsyncRuntimeQueueSchedulerSession(int32_t sampleRateIn,
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

    ~AsyncRuntimeQueueSchedulerSession() { shutdownWorker(); }

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
    uint64_t enqueueCommand(CommandType type, int64_t a, int64_t b) {
        uint64_t seq = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (queueCount >= kCommandQueueCapacity) {
                return 0;
            }
            seq = ++commandsEnqueued;
            queue_[(queueHead + queueCount) % kCommandQueueCapacity] =
                Command{type, a, b, seq};
            ++queueCount;
        }
        cv_.notify_all();
        return seq;
    }

private:
    // ── Worker thread body ─────────────────────────────────────────────────
    // Sole caller of AudioClock mutators, coordinator control/dispatch, and
    // the output ring's producer role. Never touches JNIEnv, never attaches
    // to the JVM, never calls back to Kotlin, never logs, never reads a
    // wall clock: media ticks are derived from the frame axis and the
    // caller-supplied synthetic anchors only.
    void workerMain() {
        // Worker-local deterministic tick anchor, mirroring the AudioClock
        // anchor exactly (updated on every executed start/pause/resume/seek).
        int64_t anchorPtsUs = 0;
        int64_t anchorSysNs = 0;
        int64_t lastTickNs  = 0;
        bool    startedLocal = false;
        bool    pausedLocal  = false;
        bool    bpProbeDone  = false;

        uint64_t commandsProcessed = 0;
        uint64_t commandErrors     = 0;
        uint64_t lastCommandSeq    = 0;
        const char* lastCommandResult = "none";
        const char* lastDispatchToken = "none";
        uint64_t loopCount = 0, sleepCount = 0, starvedWaits = 0;
        uint64_t awaitingOutputAckWaits = 0, zeroFillProbeWindows = 0;
        uint64_t backpressureProbes = 0, dispatchAnomalies = 0;

        const uint64_t workerIdHash =
            std::hash<std::thread::id>{}(std::this_thread::get_id());
        const bool workerDistinct =
            std::this_thread::get_id() != ownerThreadId;

        auto tickForFrame = [&](int64_t frame) -> int64_t {
            const int64_t ptsUs = CeilPtsUsOfFrame(frame, sampleRate);
            int64_t deltaUs = ptsUs - anchorPtsUs;
            if (deltaUs < 0) deltaUs = 0;
            if (deltaUs > (kInt64Max - anchorSysNs) / 1000) return kInt64Max;
            const int64_t tick = anchorSysNs + deltaUs * 1000;
            return tick < lastTickNs ? lastTickNs : tick;
        };

        auto publish = [&](bool exited) {
            const auto csnap = coordinator.snapshot();
            RingBufferAudioSampleProvider& p = provider();
            std::lock_guard<std::mutex> lock(mutex_);
            PublishedState& ps = published_;
            ps.workerStarted        = true;
            ps.workerExited         = exited;
            ps.started              = startedLocal;
            ps.paused               = pausedLocal;
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
            ps.workerStarvedWaits   = starvedWaits;
            ps.workerAwaitingOutputAckWaits = awaitingOutputAckWaits;
            ps.workerZeroFillProbeWindows   = zeroFillProbeWindows;
            ps.workerBackpressureProbes     = backpressureProbes;
            ps.workerDispatchAnomalies      = dispatchAnomalies;
            ps.workerLastTickNs     = lastTickNs;
            ps.anchorMediaPtsUs     = anchorPtsUs;
            ps.anchorSysTimeNs      = anchorSysNs;
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
                    const Status st = coordinator.start(cmd.a, cmd.b);
                    if (st.ok()) {
                        startedLocal = true;
                        anchorPtsUs  = cmd.a;
                        anchorSysNs  = cmd.b;
                        lastTickNs   = cmd.b;
                        lastCommandResult = "ok";
                    } else {
                        lastCommandResult = "clock_error";
                        ++commandErrors;
                    }
                    break;
                }
                case CommandType::kPause: {
                    const int64_t eff = std::max<int64_t>(cmd.b, lastTickNs);
                    const Status st = coordinator.pause(eff);
                    if (st.ok()) {
                        if (!pausedLocal) {
                            // Mirror the clock's freeze re-anchor exactly:
                            // frozen pts = anchorPts + floor(deltaNs/1000).
                            anchorPtsUs += (eff - anchorSysNs) / 1000;
                            anchorSysNs  = eff;
                        }
                        pausedLocal = true;
                        lastTickNs  = std::max<int64_t>(lastTickNs, eff);
                        lastCommandResult = "ok";
                    } else {
                        lastCommandResult = "clock_error";
                        ++commandErrors;
                    }
                    break;
                }
                case CommandType::kResume: {
                    const int64_t eff = std::max<int64_t>(cmd.b, lastTickNs);
                    const Status st = coordinator.resume(eff);
                    if (st.ok()) {
                        if (pausedLocal) {
                            anchorSysNs = eff; // position unchanged
                        }
                        pausedLocal = false;
                        lastTickNs  = std::max<int64_t>(lastTickNs, eff);
                        lastCommandResult = "ok";
                    } else {
                        lastCommandResult = "clock_error";
                        ++commandErrors;
                    }
                    break;
                }
                case CommandType::kSeek: {
                    // The owner already published the source-ring seek
                    // request (producer role) over a verified-empty ring;
                    // consume the ack here on the ring's consumer thread so
                    // the writer unblocks even though no provide() runs
                    // while the source is empty. The provider's cursor then
                    // forward-jumps at its next provide() with nothing to
                    // discard (no spurious skip/underrun counters).
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
                    const int64_t eff = std::max<int64_t>(cmd.b, lastTickNs);
                    const Status st = coordinator.seek(cmd.a, eff);
                    if (st.ok()) {
                        anchorPtsUs = cmd.a;
                        anchorSysNs = eff;
                        lastTickNs  = eff;
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

            // 2. Bounded dispatch attempt on the deterministic frame axis.
            bool progressed = localCount > 0;
            if (startedLocal && !pausedLocal) {
                const auto csnap = coordinator.snapshot();
                if (!csnap.terminal &&
                    outputRing.seekRequest() != outputRing.seekAck()) {
                    // Start/seek requires the owner to consume the output
                    // ack via the read path before the worker may render.
                    ++awaitingOutputAckWaits;
                } else if (!csnap.terminal &&
                           sourceRing().seekRequest() == sourceRing().seekAck()) {
                    const int64_t remaining =
                        expectedFrames - csnap.nextDispatchFrame;
                    if (remaining > 0) {
                        const int64_t windowFrames =
                            std::min<int64_t>(maxFramesPerMix, remaining);
                        const int64_t srcAvail =
                            sourceRing().availableReadFrames();
                        const bool haveData = srcAvail >= windowFrames;
                        const bool eos =
                            eosPublished.load(std::memory_order_acquire);
                        if (!haveData && !eos) {
                            // No deterministic media-time advance without a
                            // full source window unless the EOS-gated
                            // zero-fill probe lane is active.
                            ++starvedWaits;
                        } else {
                            const bool outFull =
                                outputRing.availableWriteFrames() < windowFrames;
                            if (outFull && bpProbeDone) {
                                // One backpressure record per full episode;
                                // then idle until the reader frees space.
                            } else {
                                const int64_t tick = tickForFrame(
                                    csnap.nextDispatchFrame + windowFrames);
                                DispatchOutput out;
                                const DispatchResult r =
                                    coordinator.dispatchUntil(tick, &out);
                                lastTickNs = std::max<int64_t>(lastTickNs, tick);
                                lastDispatchToken = DispatchResultName(r);
                                switch (r) {
                                    case DispatchResult::kOk:
                                    case DispatchResult::kSilence:
                                        progressed  = true;
                                        bpProbeDone = false;
                                        if (!haveData && eos) {
                                            ++zeroFillProbeWindows;
                                        }
                                        break;
                                    case DispatchResult::kBackpressure:
                                        bpProbeDone = true;
                                        ++backpressureProbes;
                                        break;
                                    case DispatchResult::kAwaitingSeekAck:
                                        ++awaitingOutputAckWaits;
                                        break;
                                    default:
                                        ++dispatchAnomalies;
                                        break;
                                }
                            }
                        }
                    }
                }
            }

            publish(false);

            // 3. Bounded pacing wait (no steady_clock media time; this is
            // pure scheduling backoff): wake on stop or a new command.
            if (!progressed) {
                std::unique_lock<std::mutex> lock(mutex_);
                ++sleepCount;
                cv_.wait_for(lock, std::chrono::milliseconds(1), [this]() {
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
std::mutex gAsyncRuntimeQueueRegistryMutex;
std::unordered_map<int64_t, std::shared_ptr<AsyncRuntimeQueueSchedulerSession>>
    gAsyncRuntimeQueueSessions;
int64_t gNextAsyncRuntimeQueueHandle = 1; // guarded by the registry mutex

std::shared_ptr<AsyncRuntimeQueueSchedulerSession> FindAsyncRuntimeQueueSession(
    jlong handle) {
    std::lock_guard<std::mutex> lock(gAsyncRuntimeQueueRegistryMutex);
    auto it = gAsyncRuntimeQueueSessions.find(static_cast<int64_t>(handle));
    return it == gAsyncRuntimeQueueSessions.end() ? nullptr : it->second;
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createAsyncRuntimeQueueSchedulerSession
// Fail-closed construction validation; the worker thread starts only after
// the rig validated (node owns its transport, route resolved to exactly the
// one source) and is joined again before any failed session is destroyed.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createAsyncRuntimeQueueSchedulerSession(
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
    if (!IsPowerOfTwoInRingRange(srcCap)) return 0;
    if (!IsPowerOfTwoInRingRange(outCap)) return 0;
    if (outCap < mfpm) return 0;
    if (srcCap < 2 * mfpm) return 0;

    std::shared_ptr<AsyncRuntimeQueueSchedulerSession> session;
    try {
        session = std::make_shared<AsyncRuntimeQueueSchedulerSession>(
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
        std::lock_guard<std::mutex> lock(gAsyncRuntimeQueueRegistryMutex);
        if (gAsyncRuntimeQueueSessions.size() >= kMaxLiveSessions) return 0;
        if (!session->startWorker()) return 0;
        const int64_t handle = gNextAsyncRuntimeQueueHandle++;
        gAsyncRuntimeQueueSessions[handle] = std::move(session);
        return static_cast<jlong>(handle);
    }
}

namespace {

// Common reply shape for the four command entry points, formatted into a
// caller-provided stack buffer.
jstring ReplyCommand(JNIEnv* env, char* buf, size_t bufLen,
                     const char* token, uint64_t seq) {
    std::snprintf(buf, bufLen, "status=%s;commandSeq=%llu",
                  token, static_cast<unsigned long long>(seq));
    return env->NewStringUTF(buf);
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: startAsyncRuntimeQueueScheduler
// Owner-thread-only, enqueue-only: the WORKER executes coordinator.start
// (clock start + output-ring seek request). After the worker reports the
// command processed, the owner must consume the output-ring seek ack via
// the read entry point before the worker can render its first window.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_startAsyncRuntimeQueueScheduler(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
    jlong mediaPtsUs,
    jlong syntheticSysTimeNs) {

    char status[192];
    const auto session = FindAsyncRuntimeQueueSession(handle);
    if (!session) return ReplyCommand(env, status, sizeof(status), "not_found", 0);
    if (std::this_thread::get_id() != session->ownerThreadId) {
        return ReplyCommand(env, status, sizeof(status), "wrong_owner_thread", 0);
    }
    if (mediaPtsUs < 0 || syntheticSysTimeNs < 0) {
        return ReplyCommand(env, status, sizeof(status), "invalid_args", 0);
    }
    if (session->startEnqueued) {
        return ReplyCommand(env, status, sizeof(status), "already_started", 0);
    }
    const uint64_t seq = session->enqueueCommand(
        CommandType::kStart, static_cast<int64_t>(mediaPtsUs),
        static_cast<int64_t>(syntheticSysTimeNs));
    if (seq == 0) {
        return ReplyCommand(env, status, sizeof(status), "queue_full", 0);
    }
    session->startEnqueued = true;
    return ReplyCommand(env, status, sizeof(status), "enqueued", seq);
}

// ---------------------------------------------------------------------------
// JNI: pauseAsyncRuntimeQueueScheduler / resumeAsyncRuntimeQueueScheduler
// Owner-thread-only, enqueue-only. The worker clamps the caller-supplied
// synthetic tick to its own last tick (never a regression) and calls the
// coordinator; per-command results surface through the snapshot mirror.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_pauseAsyncRuntimeQueueScheduler(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
    jlong syntheticSysTimeNs) {

    char status[192];
    const auto session = FindAsyncRuntimeQueueSession(handle);
    if (!session) return ReplyCommand(env, status, sizeof(status), "not_found", 0);
    if (std::this_thread::get_id() != session->ownerThreadId) {
        return ReplyCommand(env, status, sizeof(status), "wrong_owner_thread", 0);
    }
    if (syntheticSysTimeNs < 0) {
        return ReplyCommand(env, status, sizeof(status), "invalid_args", 0);
    }
    if (!session->startEnqueued) {
        return ReplyCommand(env, status, sizeof(status), "not_started", 0);
    }
    const uint64_t seq = session->enqueueCommand(
        CommandType::kPause, 0, static_cast<int64_t>(syntheticSysTimeNs));
    return ReplyCommand(env, status, sizeof(status),
                        seq == 0 ? "queue_full" : "enqueued", seq);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_resumeAsyncRuntimeQueueScheduler(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
    jlong syntheticSysTimeNs) {

    char status[192];
    const auto session = FindAsyncRuntimeQueueSession(handle);
    if (!session) return ReplyCommand(env, status, sizeof(status), "not_found", 0);
    if (std::this_thread::get_id() != session->ownerThreadId) {
        return ReplyCommand(env, status, sizeof(status), "wrong_owner_thread", 0);
    }
    if (syntheticSysTimeNs < 0) {
        return ReplyCommand(env, status, sizeof(status), "invalid_args", 0);
    }
    if (!session->startEnqueued) {
        return ReplyCommand(env, status, sizeof(status), "not_started", 0);
    }
    const uint64_t seq = session->enqueueCommand(
        CommandType::kResume, 0, static_cast<int64_t>(syntheticSysTimeNs));
    return ReplyCommand(env, status, sizeof(status),
                        seq == 0 ? "queue_full" : "enqueued", seq);
}

// ---------------------------------------------------------------------------
// JNI: seekAsyncRuntimeQueueScheduler
// Owner-thread-only, forward-only, quiescent-only, fail closed otherwise:
// requires every prior command processed (checked exactly under the same
// mutex the worker publishes through), no EOS, an empty source ring, a
// fully-drained output ring, and no pending seek handshakes. On success the
// OWNER publishes the source writer seek request (producer role), then
// enqueues the Seek command; the WORKER consumes the source ack and calls
// coordinator.seek; the owner must then consume the output ack via read.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_seekAsyncRuntimeQueueScheduler(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle,
    jlong targetPtsUs,
    jlong syntheticSysTimeNs) {

    char status[320];
    const auto session = FindAsyncRuntimeQueueSession(handle);

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
    if (targetPtsUs < 0 || syntheticSysTimeNs < 0) {
        return reply("invalid_args", 0, -1);
    }
    if (!session->startEnqueued) return reply("not_started", 0, -1);
    if (session->eosPublished.load(std::memory_order_acquire)) {
        return reply("seek_rejected_eos", 0, -1);
    }

    AsyncRuntimeQueueSchedulerSession& s = *session;
    const int64_t targetFrame = ClockedAudioTransportCoordinator::frameOfPositionUs(
        static_cast<int64_t>(targetPtsUs), s.sampleRate);

    // Quiescence: with the source ring empty and no EOS the worker is
    // provably starved (it cannot advance nextDispatchFrame), so the
    // published values read under the mutex below are exact, not stale.
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
        CommandType::kSeek, static_cast<int64_t>(targetPtsUs),
        static_cast<int64_t>(syntheticSysTimeNs));
    if (seq == 0) {
        return reply("queue_full", 0, targetFrame);
    }
    return reply("enqueued", seq, targetFrame);
}

// ---------------------------------------------------------------------------
// JNI: ingestAsyncRuntimeQueueSchedulerPcm16
// Owner-thread-only source-ring producer via the NODE-OWNED writer. Treats
// `pcm` as interleaved little-endian signed PCM16 at byte offset 0 and
// clamps the accepted frame count to min(frameCount, 8192,
// capacityFramesFromBuffer). Writer backpressure (ring_full/partial_write)
// is a reported outcome, not an error.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_ingestAsyncRuntimeQueueSchedulerPcm16(
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

    const auto session = FindAsyncRuntimeQueueSession(handle);
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
// JNI: setAsyncRuntimeQueueSchedulerEos
// Owner-thread-only. Writer-local EOS plus the atomic worker-visible flag
// that arms the bounded zero-fill probe lane (the worker may then dispatch
// short/empty source windows until the timeline frame axis completes,
// reporting the provider's zero-fill accounting honestly).
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_setAsyncRuntimeQueueSchedulerEos(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[128];
    const auto session = FindAsyncRuntimeQueueSession(handle);
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
// JNI: readAsyncRuntimeQueueSchedulerOutputPcm16
// Owner-thread-only output-ring CONSUMER: consumes a pending start/seek
// output ack first (reporting frames discarded at the boundary), then pops
// mixed PCM16 into the caller's direct ByteBuffer at byte offset 0.
// maxFrames == 0 is a legal ack-only call.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_readAsyncRuntimeQueueSchedulerOutputPcm16(
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

    const auto session = FindAsyncRuntimeQueueSession(handle);
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
// JNI: snapshotAsyncRuntimeQueueScheduler
// Owner-thread-only. Coordinator/provider/worker facts come exclusively
// from the worker-published mirror (copied under the TU-local mutex); the
// owner never touches the coordinator or provider directly.
// ownerDispatchCalls is structurally 0: this TU exposes no owner-side
// dispatch entry point at all.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_snapshotAsyncRuntimeQueueScheduler(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[4096];

    const auto session = FindAsyncRuntimeQueueSession(handle);
    if (!session) {
        std::snprintf(status, sizeof(status), "status=not_found");
        return env->NewStringUTF(status);
    }
    if (std::this_thread::get_id() != session->ownerThreadId) {
        std::snprintf(status, sizeof(status), "status=wrong_owner_thread");
        return env->NewStringUTF(status);
    }

    AsyncRuntimeQueueSchedulerSession& s = *session;
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

    std::snprintf(status, sizeof(status),
        "status=ok;"
        "workerStarted=%s;workerExited=%s;workerThreadDistinct=%s;"
        "ownerThreadIdHash=%llu;workerThreadIdHash=%llu;"
        "started=%s;paused=%s;timelineComplete=%s;terminal=%s;"
        "commandsEnqueued=%llu;commandsProcessed=%llu;commandErrors=%llu;"
        "lastCommandSeq=%llu;lastCommandResult=%s;queueDepth=%zu;"
        "ownerDispatchCalls=0;"
        "lastDispatchResult=%s;nextDispatchFrame=%lld;lastMediaPositionUs=%lld;"
        "totalFramesRendered=%lld;totalFramesPushed=%lld;dispatchCount=%llu;"
        "okCount=%llu;silenceCount=%llu;backpressureCount=%llu;"
        "schedulerErrorCount=%llu;"
        "workerLoopCount=%llu;workerSleepCount=%llu;workerStarvedWaits=%llu;"
        "workerAwaitingOutputAckWaits=%llu;workerZeroFillProbeWindows=%llu;"
        "workerBackpressureProbes=%llu;workerDispatchAnomalies=%llu;"
        "workerLastTickNs=%lld;anchorMediaPtsUs=%lld;anchorSysTimeNs=%lld;"
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
        ps.paused ? "true" : "false",
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
        static_cast<unsigned long long>(ps.workerStarvedWaits),
        static_cast<unsigned long long>(ps.workerAwaitingOutputAckWaits),
        static_cast<unsigned long long>(ps.workerZeroFillProbeWindows),
        static_cast<unsigned long long>(ps.workerBackpressureProbes),
        static_cast<unsigned long long>(ps.workerDispatchAnomalies),
        static_cast<long long>(ps.workerLastTickNs),
        static_cast<long long>(ps.anchorMediaPtsUs),
        static_cast<long long>(ps.anchorSysTimeNs),
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
// JNI: destroyAsyncRuntimeQueueSchedulerSession
// Callable from any thread; idempotent erase-once under the registry
// mutex. Sets the stop flag, wakes the worker, and JOINS (never detaches)
// before replying, so the reply's final counters are race-free. A second
// call (or unknown handle) returns status=not_found.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_destroyAsyncRuntimeQueueSchedulerSession(
    JNIEnv* env,
    jobject /* companion */,
    jlong handle) {

    char status[384];

    std::shared_ptr<AsyncRuntimeQueueSchedulerSession> session;
    {
        std::lock_guard<std::mutex> lock(gAsyncRuntimeQueueRegistryMutex);
        auto it = gAsyncRuntimeQueueSessions.find(static_cast<int64_t>(handle));
        if (it != gAsyncRuntimeQueueSessions.end()) {
            session = std::move(it->second);
            gAsyncRuntimeQueueSessions.erase(it);
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
