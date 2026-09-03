// P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE (Y1): production True-DAG
// realtime audio graph transport core session.
//
// This is NOT a diagnostic TU. It owns the native side of the Android
// realtime playback transport: a worker-owned std::chrono::steady_clock
// media timebase driving N (1..8) node-owned synthetic PCM16 source tracks
// through GraphAudioScheduler -> AudioMixBusNode into one SPSC PCM16 output
// ring that the Kotlin owner thread drains. ClockedAudioTransportCoordinator
// owns the AudioClock transitions and the output ring's seek epochs
// (start/pause/resume/seek); the worker renders and pushes every window
// itself (see the dispatch loop). Kotlin's transport state machine
// (VanguardRealtimePlaybackTransportStateMachine) is the authoritative
// state; the `state` token published here is DERIVED from the worker's own
// view so Kotlin can fail closed on divergence.
//
// Thread / SPSC role map:
// - Owner thread (pinned at create; every non-destroy entry point): enqueues
//   exactly one command at a time and blocks (bounded) for the worker ack;
//   is the output ring's sole CONSUMER (seek-ack consume, discard, pop via
//   the drain entry point); reads the worker-published mirror.
// - Worker thread: sole reader of steady_clock for media time, sole caller
//   of every AudioClock / ClockedAudioTransportCoordinator mutator, and
//   BOTH roles of every SYNTHETIC node-owned source ring (synthetic
//   generator -> AudioDecoderRingWriter as producer; GraphAudioScheduler ->
//   RingBufferAudioSampleProvider as consumer), plus the output ring's
//   PRODUCER role. A single thread holding both SPSC roles of one ring is
//   trivially race-free. The worker never touches JNIEnv and never logs.
// - Y5a EXTERNAL-INGEST tracks (opted in per track by externalIngestTrackMask
//   at create; default none): the worker keeps only the CONSUMER role of
//   that source ring. The PRODUCER role (AudioDecoderRingWriter::write)
//   belongs to the owner thread through the ingest entry point, EXCEPT
//   inside command execution, where the worker re-anchors every ring
//   (writer.requestSeek + provider ack probe) exactly as before. The two
//   producers never overlap: the owner enqueues/acks commands under mutex_
//   and the ingest entry point refuses (command_in_flight) unless the
//   command slot is empty and every enqueued command has been acked, so
//   every owner write happens-after the worker's last re-anchor and
//   happens-before the next enqueue. The worker never generates PCM for,
//   never reads writer.nextWriteFrame() of, an external track outside
//   command execution; its readiness probe is the ring's atomic
//   availableReadFrames(), and a short external ring is a nonterminal
//   underrun (counter + skipped dispatch iteration), not source_starved.
//
// Y1 contract highlights:
// - Synthetic PCM only, generated on the worker by a deterministic integer
//   formula (see GenerateSyntheticPcm) that the Kotlin wrapper reproduces
//   verbatim as the reference identity for later harness checks.
// - Every window (full or the partial EOS tail) is rendered by the worker
//   through GraphAudioScheduler::renderWindow() into TU-owned scratch and
//   pushed with tryPushFrames(), never through coordinator dispatchUntil():
//   the coordinator has no notion of a declared length (it would overshoot
//   the tail during catch-up) and does not expose its scratch PCM, whereas
//   pushedChecksum must be the same cumulative sample-wise checksum the
//   owner's drain accumulates so a harness can prove pushed == drained PCM
//   identity. Exactly declaredFrameCount frames are rendered and pushed.
// - Re-entrant transport on one live session: prepare, start, pause,
//   resume, seek forward/backward (active or paused), stop, start, EOS.
//   Stop tears down the clock/coordinator pair (AudioClock has no stop
//   transition) and a later start/prepare rebuilds it.
// - No one-second timing gate, no proof-boundary token, no fixed track
//   count, no envelope proof tables, no diagnostic marker coupling.
// - No AudioTrack/AAudio/OpenSL/Oboe/MediaCodec, no audible output, no
//   file IO, no product/editor wiring. C++ audio primitives are unchanged.
//
// Y5a EXTERNAL-INGEST-SEAM (this is NOT the decoder slice):
// - Kotlin owns every Android codec/media API (V4.3 strict boundary); this
//   TU only accepts already-decoded interleaved PCM16 from a direct
//   ByteBuffer on the owner thread and hands it to the track's own
//   AudioDecoderRingWriter. No MediaCodec/MediaExtractor, no presentation
//   clock, no A/V sync, no decoder lifecycle live here.
// - Ingest contract (ingest entry point): owner thread only; direct buffer
//   with capacity >= frameCount * 2 * channelCount; trackIndex must be an
//   external track; sampleRate/channelCount must equal the session's
//   (format_mismatch); expectedStartFrame must equal the writer's
//   nextWriteFrame() (expected_start_mismatch; the reply carries the real
//   nextWriteFrame so the producer re-anchors after seek/prepare/stop);
//   a ring whose seek epoch is not yet acked answers awaiting_seek_ack
//   (never expected after a command ack, guarded anyway). Accepted frames
//   are clamped to min(frameCount, freeFrames, 8192, declared -
//   nextWriteFrame): full accept = ok, shorter = partial_write, zero free
//   = ring_full, cursor at declared end = eos_reached. All rejections
//   mutate nothing.
// - Command gate: command_in_flight is returned (no mutation) while the
//   command slot is occupied or any enqueued command is unacked.
//
// Android-only TU, added through the Android target_sources block in
// src/CMakeLists.txt. Its handle registry is disjoint from every
// diagnostic session TU.
//
// JNI entry points (VanguardRealtimePlaybackNativeBridge.kt, Kotlin object):
//   createRealtimePlaybackGraphSession            -> jlong handle (0 on failure)
//   prepare/start/pause/resume/seek/stop...Session -> jstring key=value
//   drainRealtimePlaybackGraphSessionOutputPcm16  -> jstring key=value
//   ingestRealtimePlaybackGraphSessionExternalPcm16 -> jstring key=value (Y5a)
//   snapshotRealtimePlaybackGraphSession          -> jstring key=value
//   destroyRealtimePlaybackGraphSession           -> jstring key=value

#include <jni.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "android_phase4_realtime_playback_graph_session_helpers.h"
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

using vanguard::audio::AudioClock;
using vanguard::audio::AudioDecoderRingWriter;
using vanguard::audio::AudioMixBusNode;
using vanguard::audio::AudioSpscAudioRingBuffer;
using vanguard::audio::AudioWindowBuffer;
using vanguard::audio::AudioWindowRequest;
using vanguard::audio::AutoDiscoverSourceProviders;
using vanguard::audio::ClockedAudioTransportCoordinator;
using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::audio::GraphAudioScheduler;
using vanguard::audio::RingBufferAudioSampleProvider;
using vanguard::core::Status;
using vanguard::graph::Graph;
using WriterStatus   = AudioDecoderRingWriter::Status;
// Header-only helpers extracted in Y5a (pure functions / plain records).
using namespace vanguard::platform::android::realtime_playback_detail;

constexpr size_t  kMaxLiveSessions       = 4;
constexpr int32_t kMinTrackCount         = 1;
constexpr int32_t kMaxTrackCount         = static_cast<int32_t>(AudioMixBusNode::kMaxTrackCount); // 8
constexpr int64_t kMaxFramesPerMixCap    = AudioMixBusNode::kMaxMaxFramesPerMix;                // 8192
constexpr int64_t kMaxWriteFrames        = AudioDecoderRingWriter::kMaxWriteFrames;             // 8192
constexpr int64_t kMaxRingCapacityFrames = AudioSpscAudioRingBuffer::kMaxCapacityFrames;        // 65536
constexpr int     kMaxDispatchesPerWake  = 8;
constexpr int64_t kMaxWaitNs             = 5'000'000LL;      // 5ms cv clamp
constexpr int64_t kCommandAckTimeoutMs   = 1'000LL;          // owner-side bounded ack wait
constexpr size_t  kReplyCapacity         = 2048; // Y15a: widened for nativeClock* telemetry
constexpr int64_t kMaxIngestFrames       = kMaxWriteFrames;                                    // 8192

// ---------------------------------------------------------------------------
// Session. Member declaration order is construction order: the graph is
// populated before the scheduler snapshots it; the worker thread is
// declared last and started only after the fully validated session exists.
// shutdownWorker() joins (never detaches) before any rig member is
// destroyed.
// ---------------------------------------------------------------------------
struct RealtimePlaybackGraphSession {
    const int32_t sampleRate;
    const int32_t channelCount;
    const int64_t maxFramesPerMix;
    const int32_t trackCount;
    const int64_t declaredFrames;
    // Y5a: bit t set => track t is EXTERNAL-INGEST (owner-thread producer).
    const uint32_t externalIngestMask;
    int64_t       handle{0}; // assigned under the registry mutex before publication

    Graph                                                   graphTopology;
    std::shared_ptr<AudioMixBusNode>                        mixBus;
    std::vector<std::shared_ptr<DecodedAudioPcmSourceNode>> sources;
    AudioSpscAudioRingBuffer                                outputRing;
    GraphAudioScheduler                                     scheduler;
    std::thread::id                                         ownerThreadId;

    // Worker-private transport pair, rebuilt by prepare / start-after-stop
    // and torn down by stop (coordinator first: it references the clock).
    std::unique_ptr<AudioClock>                       clock;
    std::unique_ptr<ClockedAudioTransportCoordinator> coordinator;

    // Worker-private scratch, allocated once at create.
    std::vector<int16_t> genScratch;
    std::vector<int16_t> windowScratch;

    // Owner-private accounting (owner thread enforced on every entry point
    // that touches these).
    int64_t  drainedFrames{0};
    int64_t  discardedFrames{0};
    uint64_t drainedChecksum{0};
    bool     eosDrained{false};

    // Cross-thread flags.
    std::atomic<bool>     stopFlag{false};
    std::atomic<uint32_t> joinCount{0};
    std::atomic<uint32_t> destroyCalls{0};

    // Command slot + published mirror (mutex_). Exactly one command may be
    // in flight because the owner blocks for its ack.
    std::mutex              mutex_;
    std::condition_variable cv_;    // worker wake
    std::condition_variable ackCv_; // owner ack wait
    bool                    commandPending{false};
    Command                 pendingCommand{};
    uint64_t                commandsEnqueued{0};
    PublishedState          published_;

    std::mutex  joinMutex_;
    std::thread worker_; // declared last; joined before members destroy

    RealtimePlaybackGraphSession(int32_t sampleRateIn, int32_t channelCountIn,
                                 int64_t maxFramesPerMixIn, int32_t trackCountIn,
                                 int64_t declaredFramesIn,
                                 uint32_t externalIngestMaskIn,
                                 int64_t sourceRingCapacityFrames,
                                 int64_t outputRingCapacityFrames)
        : sampleRate(sampleRateIn),
          channelCount(channelCountIn),
          maxFramesPerMix(maxFramesPerMixIn),
          trackCount(trackCountIn),
          declaredFrames(declaredFramesIn),
          externalIngestMask(externalIngestMaskIn),
          graphTopology(),
          mixBus(std::make_shared<AudioMixBusNode>(kMixNodeId, sampleRateIn, channelCountIn,
                                                   maxFramesPerMixIn)),
          sources(MakeSources(trackCountIn, sampleRateIn, channelCountIn, declaredFramesIn,
                              sourceRingCapacityFrames)),
          outputRing(sampleRateIn, channelCountIn, outputRingCapacityFrames),
          scheduler(PrepareTopology(graphTopology, mixBus, sources), kMixNodeId,
                    AutoDiscoverSourceProviders{}),
          ownerThreadId(std::this_thread::get_id()),
          genScratch(static_cast<size_t>(kMaxWriteFrames) * static_cast<size_t>(channelCountIn), 0),
          windowScratch(static_cast<size_t>(maxFramesPerMixIn) * static_cast<size_t>(channelCountIn), 0) {}

    ~RealtimePlaybackGraphSession() { shutdownWorker(); }

    bool isExternalTrack(int t) const { return ((externalIngestMask >> t) & 1u) != 0u; }
    AudioSpscAudioRingBuffer& sourceRingAt(int t) { return *sources[static_cast<size_t>(t)]->ring(); }
    AudioDecoderRingWriter&   writerAt(int t)     { return *sources[static_cast<size_t>(t)]->ringWriter(); }
    // The 6-arg node constructor always owns a RingBufferAudioSampleProvider,
    // so this downcast of the base-typed accessor is exact.
    RingBufferAudioSampleProvider& providerAt(int t) {
        return *static_cast<RingBufferAudioSampleProvider*>(
            sources[static_cast<size_t>(t)]->audioSampleProvider());
    }

    bool startWorker() {
        try {
            worker_ = std::thread([this]() { workerMain(); });
        } catch (...) {
            return false;
        }
        return true;
    }

    // Idempotent: sets the stop flag, wakes the worker, joins exactly once.
    void shutdownWorker() {
        stopFlag.store(true, std::memory_order_release);
        cv_.notify_all();
        std::lock_guard<std::mutex> lock(joinMutex_);
        if (worker_.joinable()) {
            worker_.join();
            joinCount.fetch_add(1, std::memory_order_acq_rel);
        }
    }

    // Owner-thread: places the single command slot; returns seq or 0 when
    // a previous (timed-out) command still occupies the slot.
    uint64_t enqueueCommand(CommandType type, int64_t arg) {
        uint64_t seq = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (commandPending) return 0;
            seq = ++commandsEnqueued;
            pendingCommand = Command{type, arg, seq};
            commandPending = true;
        }
        cv_.notify_all();
        return seq;
    }

    // Owner-thread: bounded wait for the worker ack of `seq`.
    bool waitForAck(uint64_t seq, PublishedState* out) {
        std::unique_lock<std::mutex> lock(mutex_);
        const bool acked = ackCv_.wait_for(
            lock, std::chrono::milliseconds(kCommandAckTimeoutMs),
            [&]() { return published_.ackedSeq >= seq || published_.workerExited; });
        *out = published_;
        return acked && published_.ackedSeq >= seq;
    }

    PublishedState copyPublished() {
        std::lock_guard<std::mutex> lock(mutex_);
        return published_;
    }

    // Owner-thread (Y5a ingest gate): true only when the command slot is
    // empty AND every enqueued command has been acked, i.e. the worker
    // cannot be inside executeCommand() (the only place it touches an
    // external track's writer). Copies the mirror under the same lock.
    bool ownerQuiescentForIngest(PublishedState* out) {
        std::lock_guard<std::mutex> lock(mutex_);
        *out = published_;
        return !commandPending && published_.ackedSeq == commandsEnqueued;
    }

    // Owner-thread (output ring CONSUMER role): consumes a pending
    // start/seek epoch and/or discards every unread frame, folding the
    // count into discardedFrames.
    void ownerFlushOutput(bool discardAll) {
        const int64_t unread = outputRing.availableReadFrames();
        int64_t ackFrame = -1;
        if (outputRing.consumePendingSeekOnReaderThread(&ackFrame)) {
            discardedFrames += unread;
            cv_.notify_all(); // ack consumed: worker may dispatch
            return;
        }
        if (discardAll && unread > 0) {
            outputRing.discardAllOnReaderThread();
            discardedFrames += unread;
        }
    }

private:
    // ── Worker thread body ─────────────────────────────────────────────────
    void workerMain() {
        NativeState state          = NativeState::kIdle;
        bool        eosPushed      = false;
        int64_t     cursorFrame    = 0;
        int64_t     pendingStart   = 0;
        int64_t     lastNowNs      = 0;
        int64_t     rendered       = 0;
        int64_t     pushed         = 0;
        uint64_t    dispatchCount  = 0;
        uint64_t    backpressure   = 0;
        uint64_t    commandsDone   = 0;
        uint64_t    commandErrors  = 0;
        uint64_t    ackedSeq       = 0;
        uint64_t    underruns      = 0; // Y5a external-ingest underruns (nonterminal)
        uint64_t    pushedChecksum = 0;
        const char* lastResult     = "none";
        const char* lastError      = "none";
        // Provider poisoning baselines (any growth = identity loss).
        std::vector<uint64_t> zeroFillBase(static_cast<size_t>(trackCount), 0);
        std::vector<uint64_t> skipBase(static_cast<size_t>(trackCount), 0);
        std::vector<uint64_t> rewindBase(static_cast<size_t>(trackCount), 0);

        auto publish = [&](bool exited) {
            std::lock_guard<std::mutex> lock(mutex_);
            PublishedState& ps   = published_;
            ps.state             = state;
            ps.workerStarted     = true;
            ps.workerExited      = exited;
            ps.eosPushed         = eosPushed;
            ps.renderedFrames    = rendered;
            ps.pushedFrames      = pushed;
            ps.positionFrame     = cursorFrame;
            ps.dispatchCount     = dispatchCount;
            ps.backpressureCount = backpressure;
            ps.commandsProcessed = commandsDone;
            ps.commandErrors     = commandErrors;
            ps.ackedSeq          = ackedSeq;
            ps.underrunCount     = underruns;
            ps.lastCommandResult = lastResult;
            ps.lastError         = lastError;
            ps.pushedChecksum    = pushedChecksum;
            // Y15a: read-only native AudioClock telemetry refresh. Worker
            // thread only (sole AudioClock mutator/steady-clock reader);
            // this is an EXTRA, independent currentPositionUs() read purely
            // for publication and never feeds dispatchPlaying's own posUs
            // (computed separately there for pacing). Safe defaults when no
            // clock instance currently exists.
            if (clock) {
                const AudioClock::Snapshot cs = clock->snapshot();
                const int64_t clockPosUs = clock->currentPositionUs(SteadyNowNs());
                ps.nativeClockState              = AudioClockStateToken(cs.state);
                ps.nativeClockPositionUs         = clockPosUs;
                ps.nativeClockPositionFrame      =
                    ClockedAudioTransportCoordinator::frameOfPositionUs(clockPosUs, sampleRate);
                ps.nativeClockAnchorMediaPtsUs   = cs.anchorMediaPtsUs;
                ps.nativeClockAnchorSystemTimeNs = cs.anchorSystemTimeNs;
                ps.nativeClockSpeedNumerator     = cs.speedNumerator;
                ps.nativeClockSpeedDenominator   = cs.speedDenominator;
                ps.nativeClockDriftSampleCount   = cs.driftSampleCount;
                ps.nativeClockLastDriftDeltaUs   = cs.lastDriftDeltaUs;
            } else {
                ps.nativeClockState              = "none";
                ps.nativeClockPositionUs         = 0;
                ps.nativeClockPositionFrame      = 0;
                ps.nativeClockAnchorMediaPtsUs   = 0;
                ps.nativeClockAnchorSystemTimeNs = 0;
                ps.nativeClockSpeedNumerator     = 1;
                ps.nativeClockSpeedDenominator   = 1;
                ps.nativeClockDriftSampleCount   = 0;
                ps.nativeClockLastDriftDeltaUs   = 0;
            }
        };

        auto fail = [&](const char* token) {
            state     = NativeState::kFailed;
            lastError = token;
        };

        auto snapshotProviderBaselines = [&]() {
            for (int t = 0; t < trackCount; ++t) {
                RingBufferAudioSampleProvider& p = providerAt(t);
                zeroFillBase[static_cast<size_t>(t)] = p.framesZeroFilled();
                skipBase[static_cast<size_t>(t)]     = p.forwardSkipFrames();
                rewindBase[static_cast<size_t>(t)]   = p.rewindRejects();
            }
        };

        auto providersClean = [&]() -> bool {
            for (int t = 0; t < trackCount; ++t) {
                RingBufferAudioSampleProvider& p = providerAt(t);
                if (p.framesZeroFilled() != zeroFillBase[static_cast<size_t>(t)] ||
                    p.forwardSkipFrames() != skipBase[static_cast<size_t>(t)] ||
                    p.rewindRejects() != rewindBase[static_cast<size_t>(t)]) {
                    return false;
                }
            }
            return true;
        };

        // Re-anchors every node-owned source ring at `target` using the
        // existing seek-epoch handshake: the writer publishes the request
        // (producer role), then the provider consumes the ack at the top of
        // its next provide() call (its documented repositioning path). The
        // probe below is a provide() with a null output buffer: the adapter
        // consumes the pending epoch first and then rejects the request
        // before popping or touching any counter, which re-seats its cursor
        // at `target` and drains the ring without consuming a frame.
        auto reanchorSources = [&](int64_t target) -> const char* {
            for (int t = 0; t < trackCount; ++t) {
                if (writerAt(t).requestSeek(target) != WriterStatus::kOk) {
                    return "source_seek_rejected";
                }
                AudioWindowRequest probeReq{};
                AudioWindowBuffer  probeBuf{};
                (void)providerAt(t).provide(probeReq, probeBuf);
                if (sourceRingAt(t).seekRequest() != sourceRingAt(t).seekAck()) {
                    return "source_seek_ack_missing";
                }
                if (providerAt(t).expectedNextFrame() != target ||
                    sourceRingAt(t).availableReadFrames() != 0) {
                    return "source_cursor_divergence";
                }
            }
            snapshotProviderBaselines();
            return nullptr;
        };

        // Producer role (SYNTHETIC tracks only): fills every synthetic source
        // ring with synthetic PCM from the writer's own cursor up to the
        // declared end / free space. External tracks are never touched here;
        // their producer is the owner-thread ingest entry point.
        auto topUpSources = [&]() -> const char* {
            for (int t = 0; t < trackCount; ++t) {
                if (isExternalTrack(t)) continue;
                AudioDecoderRingWriter&   w    = writerAt(t);
                AudioSpscAudioRingBuffer& ring = sourceRingAt(t);
                while (w.nextWriteFrame() < declaredFrames) {
                    const int64_t freeFrames = ring.availableWriteFrames();
                    if (freeFrames <= 0) break;
                    const int64_t chunk = std::min<int64_t>(
                        {kMaxWriteFrames, declaredFrames - w.nextWriteFrame(), freeFrames});
                    GenerateSyntheticPcm(t, w.nextWriteFrame(), chunk, channelCount,
                                         genScratch.data());
                    int64_t written = 0;
                    const WriterStatus ws =
                        w.write(genScratch.data(), chunk, sampleRate, channelCount, &written);
                    if (ws != WriterStatus::kOk || written != chunk) {
                        return "source_write_rejected";
                    }
                }
            }
            return nullptr;
        };

        auto buildTransport = [&]() -> const char* {
            coordinator.reset();
            clock.reset();
            clock       = std::make_unique<AudioClock>();
            coordinator = std::make_unique<ClockedAudioTransportCoordinator>(
                *clock, scheduler, outputRing);
            return nullptr;
        };

        auto resetEpoch = [&](int64_t startFrame) -> const char* {
            rendered       = 0;
            pushed         = 0;
            dispatchCount  = 0;
            backpressure   = 0;
            pushedChecksum = 0;
            eosPushed      = false;
            cursorFrame    = startFrame;
            pendingStart   = startFrame;
            if (const char* e = reanchorSources(startFrame)) return e;
            if (const char* e = topUpSources()) return e;
            return nullptr;
        };

        auto executeCommand = [&](const Command& cmd) {
            const char* err = nullptr;
            if (!CommandAllowed(cmd.type, state)) {
                lastResult = "invalid_state";
                ++commandErrors;
                return;
            }
            switch (cmd.type) {
                case CommandType::kPrepare: {
                    buildTransport();
                    err = resetEpoch(0);
                    if (!err) state = NativeState::kPrepared;
                    break;
                }
                case CommandType::kStart: {
                    if (!coordinator) {
                        // start after stop: implicit prepare at the pending
                        // (seeked or reset) start frame.
                        buildTransport();
                        err = resetEpoch(pendingStart);
                        if (err) break;
                    }
                    const int64_t now = SteadyNowNs();
                    const Status st = coordinator->start(
                        CeilPtsUsOfFrame(pendingStart, sampleRate), now);
                    if (!st.ok()) { err = "clock_error"; break; }
                    if (coordinator->snapshot().nextDispatchFrame != cursorFrame) {
                        err = "cursor_divergence";
                        break;
                    }
                    lastNowNs = std::max<int64_t>(lastNowNs, now);
                    eosPushed = false;
                    state     = NativeState::kPlaying;
                    break;
                }
                case CommandType::kPause: {
                    const int64_t now = std::max<int64_t>(SteadyNowNs(), lastNowNs);
                    const Status st = coordinator->pause(now);
                    if (!st.ok()) { err = "clock_error"; break; }
                    lastNowNs = now;
                    state     = NativeState::kPaused;
                    break;
                }
                case CommandType::kResume: {
                    const int64_t now = std::max<int64_t>(SteadyNowNs(), lastNowNs);
                    const Status st = coordinator->resume(now);
                    if (!st.ok()) { err = "clock_error"; break; }
                    lastNowNs = now;
                    state     = NativeState::kPlaying;
                    break;
                }
                case CommandType::kSeek: {
                    const int64_t target = cmd.arg;
                    if (target < 0 || target >= declaredFrames) {
                        lastResult = "invalid_args";
                        ++commandErrors;
                        return;
                    }
                    if (state == NativeState::kPlaying || state == NativeState::kPaused) {
                        const int64_t now = std::max<int64_t>(SteadyNowNs(), lastNowNs);
                        const Status st = coordinator->seek(
                            CeilPtsUsOfFrame(target, sampleRate), now);
                        if (!st.ok()) { err = "clock_error"; break; }
                        lastNowNs = now;
                        if (coordinator->snapshot().nextDispatchFrame != target) {
                            err = "cursor_divergence";
                            break;
                        }
                    }
                    cursorFrame  = target;
                    pendingStart = target;
                    eosPushed    = false;
                    if (const char* e = reanchorSources(target)) { err = e; break; }
                    if (const char* e = topUpSources()) { err = e; break; }
                    break; // paused stays paused; playing stays playing
                }
                case CommandType::kStop: {
                    coordinator.reset();
                    clock.reset();
                    err = resetEpoch(0);
                    if (!err) state = NativeState::kStopped;
                    break;
                }
            }
            if (err) {
                fail(err);
                lastResult = err;
                ++commandErrors;
            } else {
                lastResult = "ok";
            }
        };

        // Dispatch loop: bounded catch-up. Every due window (full, or the
        // partial tail when fewer than maxFramesPerMix frames remain) is
        // rendered through the scheduler and pushed by this producer, so
        // pushedChecksum accumulates sample-wise over exactly the PCM the
        // owner will drain. The coordinator's cursor is only re-seated by
        // start/seek (checked there); it never dispatches.
        auto dispatchPlaying = [&](int64_t& waitNs) -> bool {
            bool progressed = false;
            for (int i = 0; i < kMaxDispatchesPerWake; ++i) {
                const int64_t remaining = declaredFrames - cursorFrame;
                if (remaining <= 0) { eosPushed = true; break; }
                if (outputRing.seekRequest() != outputRing.seekAck()) break; // owner ack gate
                const int64_t now = SteadyNowNs();
                if (now < lastNowNs) { fail("non_monotonic_time"); break; }
                const int64_t posUs    = clock->currentPositionUs(now);
                const int64_t dueFrame = ClockedAudioTransportCoordinator::frameOfPositionUs(
                    posUs, sampleRate);
                const int64_t framesDue = dueFrame - cursorFrame;
                const int64_t window    = std::min<int64_t>(maxFramesPerMix, remaining);
                if (framesDue < window) {
                    const int64_t duePtsUs = CeilPtsUsOfFrame(cursorFrame + window, sampleRate);
                    int64_t untilNs = (duePtsUs - posUs) * 1000;
                    if (untilNs < 1) untilNs = 1;
                    waitNs = std::min<int64_t>(waitNs, untilNs);
                    break;
                }
                if (const char* e = topUpSources()) { fail(e); break; }
                // Readiness: synthetic tracks keep the fail-closed writer-cursor
                // probe (the worker is their producer, so a shortfall is a
                // bug). External tracks use only the ring's atomic
                // availableReadFrames() (never the owner-private writer
                // cursor); a shortfall is a nonterminal underrun that skips
                // this iteration and lets the clock catch up later.
                bool externalShort = false;
                for (int t = 0; t < trackCount; ++t) {
                    if (isExternalTrack(t)) {
                        if (sourceRingAt(t).availableReadFrames() < window) {
                            externalShort = true;
                            break;
                        }
                    } else if (writerAt(t).nextWriteFrame() - cursorFrame < window) {
                        fail("source_starved");
                        break;
                    }
                }
                if (state == NativeState::kFailed) break;
                if (externalShort) { ++underruns; break; }
                if (outputRing.availableWriteFrames() < window) { ++backpressure; break; }

                GraphAudioScheduler::SchedulerOutput so{};
                const GraphAudioScheduler::SchedulerResult sr = scheduler.renderWindow(
                    cursorFrame, window, windowScratch.data(),
                    static_cast<int64_t>(windowScratch.size()), &so);
                if (sr != GraphAudioScheduler::SchedulerResult::kOk &&
                    sr != GraphAudioScheduler::SchedulerResult::kSilence) {
                    fail("scheduler_error");
                    break;
                }
                if (so.framesRendered != window) { fail("window_render_shortfall"); break; }
                if (outputRing.tryPushFrames(windowScratch.data(), window) != window) {
                    fail("ring_push_shortfall");
                    break;
                }
                pushedChecksum = AccumulateChecksum(pushedChecksum, windowScratch.data(),
                                                    window * channelCount);
                cursorFrame += window;
                rendered    += window;
                pushed      += window;
                ++dispatchCount;
                lastNowNs  = now;
                progressed = true;
                if (!providersClean()) { fail("source_identity_poisoned"); break; }
                if (cursorFrame >= declaredFrames) { eosPushed = true; break; }
            }
            return progressed;
        };

        publish(false);

        while (!stopFlag.load(std::memory_order_acquire)) {
            bool    haveCmd = false;
            Command cmd{};
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (commandPending) {
                    cmd            = pendingCommand;
                    haveCmd        = true;
                    commandPending = false;
                }
            }
            bool progressed = false;
            if (haveCmd) {
                executeCommand(cmd);
                ++commandsDone;
                ackedSeq   = cmd.seq;
                progressed = true;
                publish(false);
                ackCv_.notify_all();
            }

            int64_t waitNs = kMaxWaitNs;
            if (state == NativeState::kPlaying && !eosPushed && coordinator) {
                if (dispatchPlaying(waitNs)) progressed = true;
                publish(false);
            }

            if (!progressed) {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait_for(lock, std::chrono::nanoseconds(std::min<int64_t>(waitNs, kMaxWaitNs)),
                             [this]() {
                                 return stopFlag.load(std::memory_order_acquire) || commandPending;
                             });
            }
        }

        // Fail closed for any owner still blocked on an ack.
        publish(true);
        ackCv_.notify_all();
    }
};

// ---------------------------------------------------------------------------
// Registry (disjoint handle space).
// ---------------------------------------------------------------------------
std::mutex gRtPlaybackRegistryMutex;
std::unordered_map<int64_t, std::shared_ptr<RealtimePlaybackGraphSession>> gRtPlaybackSessions;
int64_t gNextRtPlaybackHandle = 1; // guarded by the registry mutex

std::shared_ptr<RealtimePlaybackGraphSession> FindRtPlaybackSession(jlong handle) {
    std::lock_guard<std::mutex> lock(gRtPlaybackRegistryMutex);
    auto it = gRtPlaybackSessions.find(static_cast<int64_t>(handle));
    return it == gRtPlaybackSessions.end() ? nullptr : it->second;
}

const char* DerivedStateToken(const PublishedState& ps, bool eosDrained) {
    if (eosDrained && (ps.state == NativeState::kPlaying || ps.state == NativeState::kPaused)) {
        return "completed";
    }
    return NativeStateToken(ps.state);
}

// Owner-thread: refreshes the sticky eosDrained fact (all pushed frames
// consumed after the worker published the declared end).
void OwnerRefreshEosDrained(RealtimePlaybackGraphSession& s, const PublishedState& ps) {
    if (!s.eosDrained && ps.eosPushed && ps.state != NativeState::kFailed &&
        s.outputRing.availableReadFrames() == 0) {
        s.eosDrained = true;
    }
}

// Minimal reply for not_found / wrong_owner_thread: reads nothing that is
// owner-thread-private (the state token comes from the mutex-guarded
// mirror), so it is safe to build from any thread.
jstring ReplyMinimal(JNIEnv* env, const char* status, jlong handle, const char* stateToken) {
    char buf[192];
    std::snprintf(buf, sizeof(buf),
        "status=%s;state=%s;handle=%lld;commandSeq=0;lastError=none;"
        "wrongOwnerThread=%s;workerJoined=false",
        status, stateToken, static_cast<long long>(handle),
        std::strcmp(status, "wrong_owner_thread") == 0 ? "true" : "false");
    return env->NewStringUTF(buf);
}

jstring ReplyWrongOwner(JNIEnv* env, RealtimePlaybackGraphSession& s) {
    return ReplyMinimal(env, "wrong_owner_thread", static_cast<jlong>(s.handle),
                        NativeStateToken(s.copyPublished().state));
}

// Y5a ingest-only reply fields; every non-ingest reply carries the
// defaults (ingestTrack=-1, counts 0) so the reply shape stays stable.
struct IngestExtras {
    int32_t track{-1};
    int64_t acceptedFrames{0};
    int64_t nextWriteFrame{0};
    int64_t freeFrames{0};
};

// Full stable reply shape shared by every owner-thread entry point.
jstring ReplyFull(JNIEnv* env, RealtimePlaybackGraphSession& s, const char* status,
                  const PublishedState& ps, uint64_t seq, int64_t framesRead,
                  const IngestExtras& ingest = IngestExtras{}) {
    char buf[kReplyCapacity];
    ReplyBuilder out(buf, sizeof(buf));
    out.appendf(
        "status=%s;state=%s;handle=%lld;trackCount=%d;declaredFrameCount=%lld;"
        "maxFramesPerMix=%lld;sampleRate=%d;channelCount=%d;"
        "renderedFrames=%lld;pushedFrames=%lld;drainedFrames=%lld;discardedFrames=%lld;"
        "positionFrame=%lld;eosPushed=%s;eosDrained=%s;"
        "commandSeq=%llu;commandResult=%s;lastError=%s;"
        "wrongOwnerThread=%s;workerJoined=%s;workerExited=%s;"
        "dispatchCount=%llu;backpressureCount=%llu;commandsProcessed=%llu;commandErrors=%llu;"
        "outputAvailableReadFrames=%lld;pushedChecksumHex=%016llx;drainedChecksumHex=%016llx;"
        "framesRead=%lld;bytesRead=%lld;"
        "externalIngestTrackMask=%u;underrunCount=%llu;ingestTrack=%d;"
        "acceptedFrames=%lld;nextWriteFrame=%lld;freeFrames=%lld",
        status, DerivedStateToken(ps, s.eosDrained),
        static_cast<long long>(s.handle), static_cast<int>(s.trackCount),
        static_cast<long long>(s.declaredFrames), static_cast<long long>(s.maxFramesPerMix),
        static_cast<int>(s.sampleRate), static_cast<int>(s.channelCount),
        static_cast<long long>(ps.renderedFrames), static_cast<long long>(ps.pushedFrames),
        static_cast<long long>(s.drainedFrames), static_cast<long long>(s.discardedFrames),
        static_cast<long long>(ps.positionFrame),
        ps.eosPushed ? "true" : "false", s.eosDrained ? "true" : "false",
        static_cast<unsigned long long>(seq), ps.lastCommandResult, ps.lastError,
        std::strcmp(status, "wrong_owner_thread") == 0 ? "true" : "false",
        s.joinCount.load(std::memory_order_acquire) > 0 ? "true" : "false",
        ps.workerExited ? "true" : "false",
        static_cast<unsigned long long>(ps.dispatchCount),
        static_cast<unsigned long long>(ps.backpressureCount),
        static_cast<unsigned long long>(ps.commandsProcessed),
        static_cast<unsigned long long>(ps.commandErrors),
        static_cast<long long>(s.outputRing.availableReadFrames()),
        static_cast<unsigned long long>(ps.pushedChecksum),
        static_cast<unsigned long long>(s.drainedChecksum),
        static_cast<long long>(framesRead),
        static_cast<long long>(framesRead * 2 * s.channelCount),
        static_cast<unsigned>(s.externalIngestMask),
        static_cast<unsigned long long>(ps.underrunCount),
        static_cast<int>(ingest.track),
        static_cast<long long>(ingest.acceptedFrames),
        static_cast<long long>(ingest.nextWriteFrame),
        static_cast<long long>(ingest.freeFrames));
    // Y15a: read-only native AudioClock telemetry, appended as its own
    // segment so the primary reply shape above stays untouched.
    out.appendf(
        ";nativeClockState=%s;nativeClockPositionUs=%lld;nativeClockPositionFrame=%lld;"
        "nativeClockAnchorMediaPtsUs=%lld;nativeClockAnchorSystemTimeNs=%lld;"
        "nativeClockSpeedNumerator=%d;nativeClockSpeedDenominator=%d;"
        "nativeClockDriftSampleCount=%llu;nativeClockLastDriftDeltaUs=%lld",
        ps.nativeClockState,
        static_cast<long long>(ps.nativeClockPositionUs),
        static_cast<long long>(ps.nativeClockPositionFrame),
        static_cast<long long>(ps.nativeClockAnchorMediaPtsUs),
        static_cast<long long>(ps.nativeClockAnchorSystemTimeNs),
        static_cast<int>(ps.nativeClockSpeedNumerator),
        static_cast<int>(ps.nativeClockSpeedDenominator),
        static_cast<unsigned long long>(ps.nativeClockDriftSampleCount),
        static_cast<long long>(ps.nativeClockLastDriftDeltaUs));
    if (out.overflowed()) {
        std::snprintf(buf, sizeof(buf), "status=reply_overflow;state=unknown;handle=%lld",
                      static_cast<long long>(s.handle));
    }
    return env->NewStringUTF(buf);
}

// Shared owner-thread command path: precheck, enqueue, bounded ack wait,
// owner-side output-ring epoch handling, reply.
jstring RunCommand(JNIEnv* env, jlong handle, CommandType type, int64_t arg) {
    const auto session = FindRtPlaybackSession(handle);
    if (!session) return ReplyMinimal(env, "not_found", handle, "unknown");
    RealtimePlaybackGraphSession& s = *session;
    if (std::this_thread::get_id() != s.ownerThreadId) return ReplyWrongOwner(env, s);

    PublishedState ps = s.copyPublished();
    OwnerRefreshEosDrained(s, ps);
    if (ps.workerExited) return ReplyFull(env, s, "worker_exited", ps, 0, 0);
    // Kotlin is authoritative: a derived "completed" (declared end pushed
    // and fully drained) never blocks a command Kotlin still allows; seek
    // and start reset the epoch below, pause/resume only touch the clock.
    if (!CommandAllowed(type, ps.state)) return ReplyFull(env, s, "invalid_state", ps, 0, 0);
    if (type == CommandType::kSeek && (arg < 0 || arg >= s.declaredFrames)) {
        return ReplyFull(env, s, "invalid_args", ps, 0, 0);
    }

    const uint64_t seq = s.enqueueCommand(type, arg);
    if (seq == 0) return ReplyFull(env, s, "command_busy", ps, 0, 0);
    if (!s.waitForAck(seq, &ps)) {
        return ReplyFull(env, s, ps.workerExited ? "worker_exited" : "command_timeout", ps, seq, 0);
    }

    const bool ok = std::strcmp(ps.lastCommandResult, "ok") == 0;
    if (ok) {
        switch (type) {
            case CommandType::kPrepare:
            case CommandType::kStop:
                s.ownerFlushOutput(/*discardAll=*/true);
                s.drainedFrames   = 0;
                s.discardedFrames = 0;
                s.drainedChecksum = 0;
                s.eosDrained      = false;
                break;
            case CommandType::kStart:
            case CommandType::kSeek:
                s.ownerFlushOutput(/*discardAll=*/true);
                s.eosDrained = false;
                break;
            case CommandType::kPause:
            case CommandType::kResume:
                break;
        }
    }
    return ReplyFull(env, s, ok ? "ok" : ps.lastCommandResult, ps, seq, 0);
}

} // namespace

// ---------------------------------------------------------------------------
// JNI: createRealtimePlaybackGraphSession
// Returns handle > 0, or 0 on invalid arguments, rig validation failure,
// worker start failure, or when kMaxLiveSessions live sessions exist.
// externalIngestTrackMask (Y5a): bit t marks track t external-ingest; 0 =
// every track synthetic (Y1 behaviour). Bits at or above trackCount, or a
// negative mask, are invalid arguments.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_createRealtimePlaybackGraphSession(
    JNIEnv* /* env */,
    jobject /* bridge */,
    jint  sampleRate,
    jint  channelCount,
    jint  maxFramesPerMix,
    jint  trackCount,
    jlong declaredFrameCount,
    jint  externalIngestTrackMask) {

    const int64_t mfpm     = static_cast<int64_t>(maxFramesPerMix);
    const int64_t declared = static_cast<int64_t>(declaredFrameCount);

    if (sampleRate <= 0 || sampleRate < AudioMixBusNode::kMinSampleRate ||
        sampleRate > AudioMixBusNode::kMaxSampleRate) {
        return 0;
    }
    if (channelCount != 1 && channelCount != 2) return 0;
    if (mfpm <= 0 || mfpm > kMaxFramesPerMixCap) return 0;
    if (trackCount < kMinTrackCount || trackCount > kMaxTrackCount) return 0;
    if (declared <= 0 ||
        declared > DecodedAudioPcmSourceNode::kMaxExpectedSeconds * static_cast<int64_t>(sampleRate)) {
        return 0;
    }
    if (externalIngestTrackMask < 0) return 0;
    const uint32_t allowedMaskBits = (1u << static_cast<uint32_t>(trackCount)) - 1u;
    const uint32_t externalMask    = static_cast<uint32_t>(externalIngestTrackMask);
    if ((externalMask & ~allowedMaskBits) != 0u) return 0;

    const int64_t sourceCap = std::min<int64_t>(
        kMaxRingCapacityFrames, PowerOfTwoCeil(std::max<int64_t>(4 * mfpm, 4096)));
    const int64_t outputCap = std::min<int64_t>(
        kMaxRingCapacityFrames, PowerOfTwoCeil(std::max<int64_t>(8 * mfpm, 8192)));

    std::shared_ptr<RealtimePlaybackGraphSession> session;
    try {
        session = std::make_shared<RealtimePlaybackGraphSession>(
            static_cast<int32_t>(sampleRate), static_cast<int32_t>(channelCount), mfpm,
            static_cast<int32_t>(trackCount), declared, externalMask, sourceCap, outputCap);
    } catch (...) {
        return 0;
    }

    if (!session->scheduler.targetValid() ||
        session->scheduler.routedSourceCount() != static_cast<size_t>(trackCount)) {
        return 0;
    }
    for (int t = 0; t < trackCount; ++t) {
        const auto& node = session->sources[static_cast<size_t>(t)];
        if (!node->ownsRing() || node->audioSampleProvider() == nullptr ||
            node->ringWriter() == nullptr ||
            session->scheduler.routedSourceIdAt(static_cast<size_t>(t)) != node->id() ||
            node->ring()->sampleRate() != sampleRate ||
            node->ring()->channelCount() != channelCount) {
            return 0;
        }
    }

    {
        std::lock_guard<std::mutex> lock(gRtPlaybackRegistryMutex);
        if (gRtPlaybackSessions.size() >= kMaxLiveSessions) return 0;
        if (!session->startWorker()) return 0;
        const int64_t handle = gNextRtPlaybackHandle++;
        session->handle = handle;
        gRtPlaybackSessions[handle] = std::move(session);
        return static_cast<jlong>(handle);
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_prepareRealtimePlaybackGraphSession(
    JNIEnv* env, jobject /* bridge */, jlong handle) {
    return RunCommand(env, handle, CommandType::kPrepare, 0);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_startRealtimePlaybackGraphSession(
    JNIEnv* env, jobject /* bridge */, jlong handle) {
    return RunCommand(env, handle, CommandType::kStart, 0);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_pauseRealtimePlaybackGraphSession(
    JNIEnv* env, jobject /* bridge */, jlong handle) {
    return RunCommand(env, handle, CommandType::kPause, 0);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_resumeRealtimePlaybackGraphSession(
    JNIEnv* env, jobject /* bridge */, jlong handle) {
    return RunCommand(env, handle, CommandType::kResume, 0);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_seekRealtimePlaybackGraphSession(
    JNIEnv* env, jobject /* bridge */, jlong handle, jlong targetFrame) {
    return RunCommand(env, handle, CommandType::kSeek, static_cast<int64_t>(targetFrame));
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_stopRealtimePlaybackGraphSession(
    JNIEnv* env, jobject /* bridge */, jlong handle) {
    return RunCommand(env, handle, CommandType::kStop, 0);
}

// ---------------------------------------------------------------------------
// JNI: drainRealtimePlaybackGraphSessionOutputPcm16
// Owner-thread output-ring CONSUMER: consumes any pending epoch first, then
// pops up to maxFrames of mixed interleaved PCM16 into the direct buffer at
// byte offset 0. maxFrames == 0 is a legal epoch-only call. Refreshes the
// eosDrained fact after popping.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_drainRealtimePlaybackGraphSessionOutputPcm16(
    JNIEnv* env, jobject /* bridge */, jlong handle, jobject dstBuffer, jint maxFrames) {

    const auto session = FindRtPlaybackSession(handle);
    if (!session) return ReplyMinimal(env, "not_found", handle, "unknown");
    RealtimePlaybackGraphSession& s = *session;
    if (std::this_thread::get_id() != s.ownerThreadId) return ReplyWrongOwner(env, s);
    PublishedState ps = s.copyPublished();
    if (maxFrames < 0) return ReplyFull(env, s, "invalid_max_frames", ps, ps.ackedSeq, 0);
    if (!dstBuffer) return ReplyFull(env, s, "null_pcm_buffer", ps, ps.ackedSeq, 0);
    const jlong capacityBytes = env->GetDirectBufferCapacity(dstBuffer);
    if (capacityBytes < 0) return ReplyFull(env, s, "non_direct_buffer", ps, ps.ackedSeq, 0);
    void* rawAddr = env->GetDirectBufferAddress(dstBuffer);
    if (!rawAddr) return ReplyFull(env, s, "direct_buffer_address_unavailable", ps, ps.ackedSeq, 0);
    const int64_t bytesPerFrame = 2LL * s.channelCount;
    const int64_t capacityFrames = static_cast<int64_t>(capacityBytes) / bytesPerFrame;
    if (capacityFrames < static_cast<int64_t>(maxFrames)) {
        return ReplyFull(env, s, "insufficient_buffer_capacity", ps, ps.ackedSeq, 0);
    }

    s.ownerFlushOutput(/*discardAll=*/false);

    int16_t* out = static_cast<int16_t*>(rawAddr);
    const int64_t framesToRead = std::min<int64_t>(
        {static_cast<int64_t>(maxFrames), capacityFrames, kMaxRingCapacityFrames});
    int64_t framesRead = 0;
    if (framesToRead > 0) {
        framesRead = s.outputRing.tryPopFrames(out, framesToRead);
        if (framesRead > 0) {
            s.drainedChecksum = AccumulateChecksum(s.drainedChecksum, out,
                                                   framesRead * s.channelCount);
            s.drainedFrames += framesRead;
            s.cv_.notify_all(); // output space freed
        }
    }
    ps = s.copyPublished();
    OwnerRefreshEosDrained(s, ps);
    return ReplyFull(env, s, "ok", ps, ps.ackedSeq, framesRead);
}

// ---------------------------------------------------------------------------
// JNI: ingestRealtimePlaybackGraphSessionExternalPcm16 (Y5a)
// Owner-thread PRODUCER of one EXTERNAL track's source ring. Reads
// frameCount interleaved PCM16 frames from byte offset 0 of the direct
// buffer. Status tokens (all rejections mutate nothing):
//   not_found / wrong_owner_thread / worker_exited   registry / affinity
//   invalid_state          session already failed
//   invalid_track          trackIndex outside [0, trackCount)
//   track_not_external     trackIndex is a synthetic track
//   invalid_args           frameCount <= 0 or expectedStartFrame < 0
//   null_pcm_buffer / non_direct_buffer / direct_buffer_address_unavailable
//   insufficient_buffer_capacity   capacity < frameCount * 2 * channelCount
//   format_mismatch        sampleRate/channelCount != session format
//   command_in_flight      command slot busy or an enqueued command unacked
//   awaiting_seek_ack      ring seek epoch not yet acked by the worker
//   expected_start_mismatch expectedStartFrame != writer.nextWriteFrame()
//   eos_reached            writer cursor already at declaredFrameCount
//   ring_full              zero free frames (backpressure, retry later)
//   partial_write          0 < acceptedFrames < frameCount
//   ok                     acceptedFrames == frameCount
// Reply adds ingestTrack/acceptedFrames/nextWriteFrame/freeFrames to the
// common shape; nextWriteFrame/freeFrames are post-write values.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_ingestRealtimePlaybackGraphSessionExternalPcm16(
    JNIEnv* env, jobject /* bridge */, jlong handle, jint trackIndex, jobject srcBuffer,
    jint frameCount, jint sampleRate, jint channelCount, jlong expectedStartFrame) {

    const auto session = FindRtPlaybackSession(handle);
    if (!session) return ReplyMinimal(env, "not_found", handle, "unknown");
    RealtimePlaybackGraphSession& s = *session;
    if (std::this_thread::get_id() != s.ownerThreadId) return ReplyWrongOwner(env, s);

    PublishedState ps = s.copyPublished();
    OwnerRefreshEosDrained(s, ps);
    IngestExtras x{};
    x.track = static_cast<int32_t>(trackIndex);
    if (ps.workerExited) return ReplyFull(env, s, "worker_exited", ps, ps.ackedSeq, 0, x);
    if (ps.state == NativeState::kFailed) return ReplyFull(env, s, "invalid_state", ps, ps.ackedSeq, 0, x);
    if (trackIndex < 0 || trackIndex >= s.trackCount) {
        return ReplyFull(env, s, "invalid_track", ps, ps.ackedSeq, 0, x);
    }
    const int t = static_cast<int>(trackIndex);
    if (!s.isExternalTrack(t)) return ReplyFull(env, s, "track_not_external", ps, ps.ackedSeq, 0, x);
    if (frameCount <= 0 || expectedStartFrame < 0) {
        return ReplyFull(env, s, "invalid_args", ps, ps.ackedSeq, 0, x);
    }
    if (!srcBuffer) return ReplyFull(env, s, "null_pcm_buffer", ps, ps.ackedSeq, 0, x);
    const jlong capacityBytes = env->GetDirectBufferCapacity(srcBuffer);
    if (capacityBytes < 0) return ReplyFull(env, s, "non_direct_buffer", ps, ps.ackedSeq, 0, x);
    const void* rawAddr = env->GetDirectBufferAddress(srcBuffer);
    if (!rawAddr) return ReplyFull(env, s, "direct_buffer_address_unavailable", ps, ps.ackedSeq, 0, x);
    const int64_t bytesPerFrame = 2LL * s.channelCount;
    if (static_cast<int64_t>(capacityBytes) < static_cast<int64_t>(frameCount) * bytesPerFrame) {
        return ReplyFull(env, s, "insufficient_buffer_capacity", ps, ps.ackedSeq, 0, x);
    }
    if (sampleRate != s.sampleRate || channelCount != s.channelCount) {
        return ReplyFull(env, s, "format_mismatch", ps, ps.ackedSeq, 0, x);
    }

    // Command gate: only past this point may the owner touch the writer
    // (producer-private plain counters) without racing the worker's
    // command-time re-anchor. The gate cannot flip underneath us: this
    // owner thread is the only command enqueuer.
    if (!s.ownerQuiescentForIngest(&ps)) {
        return ReplyFull(env, s, "command_in_flight", ps, ps.ackedSeq, 0, x);
    }
    AudioDecoderRingWriter&   w    = s.writerAt(t);
    AudioSpscAudioRingBuffer& ring = s.sourceRingAt(t);
    x.nextWriteFrame = w.nextWriteFrame();
    x.freeFrames     = ring.availableWriteFrames();
    if (ring.seekRequest() != ring.seekAck()) {
        return ReplyFull(env, s, "awaiting_seek_ack", ps, ps.ackedSeq, 0, x);
    }
    if (static_cast<int64_t>(expectedStartFrame) != x.nextWriteFrame) {
        return ReplyFull(env, s, "expected_start_mismatch", ps, ps.ackedSeq, 0, x);
    }
    const int64_t remainingDeclared = s.declaredFrames - x.nextWriteFrame;
    if (remainingDeclared <= 0) return ReplyFull(env, s, "eos_reached", ps, ps.ackedSeq, 0, x);
    if (x.freeFrames <= 0) return ReplyFull(env, s, "ring_full", ps, ps.ackedSeq, 0, x);

    const int64_t toWrite = std::min<int64_t>(
        {static_cast<int64_t>(frameCount), x.freeFrames, kMaxIngestFrames, remainingDeclared});
    int64_t written = 0;
    const WriterStatus ws = w.write(static_cast<const int16_t*>(rawAddr), toWrite,
                                    s.sampleRate, s.channelCount, &written);
    x.acceptedFrames = written;
    x.nextWriteFrame = w.nextWriteFrame();
    x.freeFrames     = ring.availableWriteFrames();
    const char* status = "ok";
    switch (ws) {
        case WriterStatus::kOk:
            status = written == static_cast<int64_t>(frameCount) ? "ok" : "partial_write";
            break;
        case WriterStatus::kPartialWrite:   status = "partial_write";     break;
        case WriterStatus::kRingFull:       status = "ring_full";         break;
        case WriterStatus::kFormatMismatch: status = "format_mismatch";   break;
        case WriterStatus::kInvalidArgument:status = "invalid_args";      break;
        case WriterStatus::kAlreadyEos:     status = "eos_reached";       break;
        case WriterStatus::kAwaitingSeekAck:status = "awaiting_seek_ack"; break;
    }
    if (written > 0) s.cv_.notify_all(); // an underrun-paused worker may dispatch now
    return ReplyFull(env, s, status, ps, ps.ackedSeq, 0, x);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_snapshotRealtimePlaybackGraphSession(
    JNIEnv* env, jobject /* bridge */, jlong handle) {

    const auto session = FindRtPlaybackSession(handle);
    if (!session) return ReplyMinimal(env, "not_found", handle, "unknown");
    RealtimePlaybackGraphSession& s = *session;
    if (std::this_thread::get_id() != s.ownerThreadId) return ReplyWrongOwner(env, s);
    const PublishedState ps = s.copyPublished();
    OwnerRefreshEosDrained(s, ps);
    return ReplyFull(env, s, "ok", ps, ps.ackedSeq, 0);
}

// ---------------------------------------------------------------------------
// JNI: destroyRealtimePlaybackGraphSession
// Any thread; idempotent erase-once under the registry mutex; joins (never
// detaches) the worker before replying. Second call: status=not_found.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardRealtimePlaybackNativeBridge_destroyRealtimePlaybackGraphSession(
    JNIEnv* env, jobject /* bridge */, jlong handle) {

    std::shared_ptr<RealtimePlaybackGraphSession> session;
    {
        std::lock_guard<std::mutex> lock(gRtPlaybackRegistryMutex);
        auto it = gRtPlaybackSessions.find(static_cast<int64_t>(handle));
        if (it != gRtPlaybackSessions.end()) {
            session = std::move(it->second);
            gRtPlaybackSessions.erase(it);
        }
    }
    if (!session) return ReplyMinimal(env, "not_found", handle, "unknown");

    session->destroyCalls.fetch_add(1, std::memory_order_acq_rel);
    session->shutdownWorker();

    // Post-join reads are race-free: the worker has exited.
    const PublishedState ps = session->copyPublished();
    char buf[320];
    std::snprintf(buf, sizeof(buf),
        "status=ok;state=destroyed;handle=%lld;commandSeq=%llu;lastError=%s;"
        "wrongOwnerThread=false;workerJoined=%s;workerExited=%s;joinCount=%u;destroyCalls=%u;"
        "renderedFrames=%lld;pushedFrames=%lld;drainedFrames=%lld",
        static_cast<long long>(handle),
        static_cast<unsigned long long>(ps.ackedSeq),
        ps.lastError,
        session->joinCount.load(std::memory_order_acquire) > 0 ? "true" : "false",
        ps.workerExited ? "true" : "false",
        session->joinCount.load(std::memory_order_acquire),
        session->destroyCalls.load(std::memory_order_acquire),
        static_cast<long long>(ps.renderedFrames),
        static_cast<long long>(ps.pushedFrames),
        static_cast<long long>(session->drainedFrames));
    return env->NewStringUTF(buf);
}
