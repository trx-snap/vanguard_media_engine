package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

// ── VanguardRealtimeAudioPlaybackSinkBridge (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK, Y8a) ─
//
// Production-owned AudioTrack sink of the realtime audio playback engine.
// One NON-ZERO-GAIN android.media.AudioTrack (MODE_STREAM, PCM16) lives on
// ITS OWN sink thread, which owns EVERY AudioTrack call (create, setVolume,
// play, pause, flush, write, getTimestamp, playbackHeadPosition, playState,
// stop, release) and EVERY write into the owned
// [VanguardRealtimePlaybackPresentationClock]. PCM16 is pulled from the
// caller-owned [VanguardRealtimePlaybackTransportStateMachine] through
// `drain()` ONLY; this bridge never issues a transport command.
//
// Phase protocol (sink thread executes, any thread requests):
//   SETUP -> READY (AudioTrack created, gain set) --allowDrain()--> RUNNING
//   RUNNING --requestPark() / requestSeekPark()--> PARK_REQUESTED --> PARKED
//   PARKED  --[seek park only: requestFlush(n, T) -> flush acked]--
//           --unpark()--> (sink thread: AudioTrack.play) --> RUNNING
//   any     --exit--> EXITED (AudioTrack released exactly once)
//
// Presentation clock rules:
//   - epoch 0 opens only after the first productive post-start drain was
//     written and AudioTrack.play() returned PLAYSTATE_PLAYING.
//   - getTimestamp() is polled at most once per productive drain pass, after
//     the write returned; observeTimestamp / observeTimestampUnavailable and
//     the playbackHeadPosition sample happen there.
//   - bounded pause: AudioTrack.pause() on the sink thread; the last
//     published position is snapshotted and epochClosed(current) freezes it.
//     While PARKED nothing is drained, written or polled. Unpark: play() on
//     the same instance, epochOpened(epoch+1, baseFrame = that position);
//     the instance frame is rebased per epoch (minus the published position
//     at park, clamped at 0) so continuity comes from the base offset only
//     and no advancement is fabricated. A hold longer than
//     [Config.maxPauseHoldMs] (below the feed's ingest stall budget) fails closed.
//   - the clock NEVER feeds back: drain size, sleeps, gating, checksum and
//     (absent) transport commands never depend on a timestamp or clock
//     outcome; a rejected clock write is counted, never acted on. The sink
//     reads the clock at park (next epoch base; that read is counted) AND,
//     as of Y13 (P4-AUDIO-REALTIME-PLAYBACK-PRESENTATION-CLOCK-QUERY-
//     SURFACE), at the existing post-write timestamp poll point, where a
//     bounded, epoch-relative production-clock lag sample is recorded as
//     diagnostic telemetry only -- a bounded query surface, not a claim
//     that P4-AUDIO-MIXBUS or P4-AUDIO-GRAPH-TRANSPORT-CLOCK are complete.
//   - Y16 (P4-AUDIO-REALTIME-PLAYBACK-CLOCK-DRIFT-SAMPLE-OWNERSHIP): at
//     that SAME post-write poll point, and only when the poll produced an
//     honest position, the sink thread posts the presentation clock's
//     (us, frame) position to the transport owner thread through the
//     generation-pinned [VanguardRealtimePlaybackTransportStateMachine.
//     postDriftSample] (expectedGeneration = currentGeneration at sample
//     creation); the native worker alone stamps its steady clock, computes
//     the expected position and records the drift sample on its
//     AudioClock. No Kotlin timebase crosses that seam, no monitor thread
//     exists, the sink thread never blocks on the callback (owner thread,
//     counters only), and the result NEVER feeds back: drain size, sleeps,
//     gating, checksum, park/unpark, epoch decisions, transport commands
//     and currentPositionFrames()/Us() authority are untouched. Stale /
//     invalid-state / disposed rejections are counted, never acted on.
//
// Seek (Y9, P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK): one forward seek
// reuses the park protocol as a seek park capped by [Config.maxSeekHoldMs]
// (covers the session's whole seek sequence; the pause cap is untouched).
// While PARKED the ONE requestFlush(n, T) runs AudioTrack.flush on the sink
// thread with PLAYSTATE_PAUSED before and after: read budget = read-at-flush
// + n (C6), instance unwrap/rebase origin reset because flush restarts the
// instance frame position (C4). Unpark of a seek park is rejected until the
// flush was acked, so epoch+1 opens on a flushed instance at baseFrame = T:
// a deliberate discontinuity of T - positionAtPark frames, published as
// telemetry. For a forward seek T >= positionAtPark always holds
// (positionAtPark <= written == H < T), so the clock never clamps the base.
// Y17 (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-BACKWARD-SEEK): a requestFlush
// may DECLARE its seek backward (T < written-at-flush == H); the unpark then
// opens epoch+1 at T through the clock writer's declared-backward entry
// point, the only path that may publish a base below the last published
// position (counted as a declared backward base, never as a clamp). The
// clock-domain step T - positionAtPark may still be zero or forward because
// the published position lags the written count by up to the output
// buffer; only the content-domain claim T < H is asserted here. Everything
// else (park, single flush, read budget H + declared - T, unpark order,
// no-feedback rule) is direction-agnostic.
//
// Dead object (Y8b, P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-DEAD-OBJECT),
// default off: with [Config.syntheticDeadObjectInjectAfterFrames] > 0 the
// sink thread arms EXACTLY ONE synthetic AudioTrack.ERROR_DEAD_OBJECT once
// that many frames were written (write skipped, error substituted, no byte
// consumed). Only that armed dead object is recovered, on the sink thread
// inside the write loop ([recoverFromSyntheticDeadObject], steps 1-6: close
// epoch, release old once, ONE same-parameter replacement, gain, play,
// unwrap reset, epoch+1 at frames written) and the unwritten remainder
// lands on the new instance; no timestamp poll happens inside the recovery
// window. The base step fails closed on sign only; its magnitude is
// decomposed into lost frames + publication lag for the proof lane only.
// Any unarmed (real) or second ERROR_DEAD_OBJECT fails closed; the
// replacement's final release still goes through [releaseAudioTrackOnce].
//
// Routing (Y12, P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-ROUTE-CHANGE), default
// off ([Config.routingController] absent): this bridge owns ONLY the
// android.media.AudioTrack listener attach/detach lifecycle of an optional
// caller-owned [VanguardRealtimePlaybackRoutingController] -- attach once
// gain is applied on a newly created AudioTrack (fail closed on attach
// failure), detach/release before this bridge's own final AudioTrack
// release, and detach-then-reattach across a Y8b dead-object replacement
// (attach before that replacement's play() / remainder resume, fail closed
// on attach failure). This bridge never polls, drains or reacts to a
// routing event; the caller-owned monitor consuming the SAME controller's
// queue is the only consumer (see [VanguardRealtimeAudioPlaybackSession]).
class VanguardRealtimeAudioPlaybackSinkBridge(private val config: Config) {

    data class Config(
        val stateMachine: VanguardRealtimePlaybackTransportStateMachine,
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val declaredFrameCount: Long,
        // Non-zero linear gain applied with AudioTrack.setVolume; (0, 1].
        val gain: Float = DEFAULT_GAIN,
        // Cap on one bounded-pause hold; below the decoder feed's ingest stall budget.
        val maxPauseHoldMs: Long = DEFAULT_MAX_PAUSE_HOLD_MS,
        // Y9: cap on one seek park (requestSeekPark), distinct from the pause cap;
        // the feed never stalls while held / PAUSED after its re-anchor.
        val maxSeekHoldMs: Long = DEFAULT_MAX_SEEK_HOLD_MS,
        // Absolute SystemClock.elapsedRealtime() deadline shared by the session.
        val deadlineAtMs: Long,
        val threadName: String = "VanguardRealtimeAudioSink",
        val externallyCancelled: () -> Boolean = { false },
        // Invoked once on the sink thread after the AudioTrack was released.
        val onExited: ((String) -> Unit)? = null,
        // Y8b diagnostic seam, default OFF (0): arms exactly one synthetic
        // ERROR_DEAD_OBJECT once this many frames were written (class comment).
        val syntheticDeadObjectInjectAfterFrames: Long = 0L,
        // Y12 production route-change/disconnect response, default OFF
        // (absent): when present, this bridge attaches/detaches its
        // OnRoutingChangedListener lifecycle (class comment); it never
        // consumes a routing event itself.
        val routingController: VanguardRealtimePlaybackRoutingController? = null,
    )

    enum class Phase { SETUP, READY, RUNNING, PARK_REQUESTED, PARKED, EXITED }

    companion object {
        const val DEFAULT_GAIN = 1.0f
        const val DEFAULT_MAX_PAUSE_HOLD_MS = 1_500L
        const val DEFAULT_MAX_SEEK_HOLD_MS = 15_000L
        // Y10b-1a: two serial seek parks are supported (each with its own flush); a
        // third requestSeekPark() is rejected the same way a second one was in Y9.
        const val MAX_SEEK_PARKS = 2
        const val EPOCH_NONE = VanguardRealtimePlaybackPresentationClock.EPOCH_NONE
        const val PLAY_STATE_UNKNOWN = -1

        const val EXIT_RUNNING = ""
        const val EXIT_EOS = "eos"
        const val EXIT_CANCELLED = "cancelled"
        const val EXIT_DEADLINE = "deadline_exceeded"
        const val EXIT_NOT_STARTED = "not_started"
        const val EXIT_PAUSE_HOLD_EXCEEDED = "bounded_pause_hold_exceeded"
        const val EXIT_SEEK_HOLD_EXCEEDED = "bounded_seek_hold_exceeded"
        const val EXIT_DEAD_OBJECT = "audio_track_dead_object"
        const val EXIT_DEAD_OBJECT_REPEATED = "audio_track_dead_object_repeated"

        private const val TRACK_BUFFER_MARGIN_WINDOWS = 4L
        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val DRAIN_STALL_SLEEP_MS = 2L
        private const val DRAIN_STALL_TIMEOUT_MS = 3_000L
        private const val DRAIN_ITERATION_MARGIN = 64L
        private const val DRAIN_ITERATION_SLACK = 4L
        private const val GATE_POLL_MS = 5L
        private const val PARK_POLL_MS = 5L
        // Y11a-prep: any-thread volume request queue (requestGain / awaitGainApplied).
        private const val GAIN_AWAIT_POLL_MS = 5L
        private const val GAIN_REQUEST_QUEUE_CAPACITY = 8
        private const val FRAME_WRAP_MODULUS = VanguardRealtimePlaybackPresentationClock.FRAME_WRAP_MODULUS
        // Y16: bound on drift samples posted but not yet called back; extras are dropped (counted).
        private const val MAX_DRIFT_SAMPLES_IN_FLIGHT = 4

        fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class FailClosed(val reason: String) : Exception(reason)

    // Y11a-prep: one queued any-thread volume target, applied on the sink thread in FIFO order.
    private data class GainRequest(val seq: Long, val gain: Float)

    // ── Cross-thread control ───────────────────────────────────────────────

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val readyLatch = CountDownLatch(1)
    private val drainGate = CountDownLatch(1)
    private val exitLatch = CountDownLatch(1)
    private val releaseCounter = AtomicInteger(0)
    private val phaseRef = AtomicReference(Phase.SETUP)
    private val parkLock = ReentrantLock()
    private val parkCondition = parkLock.newCondition()
    // Y10b-1a: reset per requestFlush() so a second serial seek's flush ack can be awaited independently.
    @Volatile private var flushAckLatch = CountDownLatch(1)

    // Guarded by parkLock.
    private var unparkRequested = false
    private var flushRequested = false
    private var flushRequestedAtMs = -1L

    // Y9: set by requestSeekPark() before the phase flip; read by the sink thread at PARK_REQUESTED.
    @Volatile private var seekParkRequested = false

    @Volatile private var parkAckLatch = CountDownLatch(1)
    @Volatile private var unparkAckLatch = CountDownLatch(1)
    @Volatile private var thread: Thread? = null

    // Y11a-prep: bounded any-thread volume request queue; request-side state guarded by this lock, drained only on the sink thread.
    private val gainRequestLock = ReentrantLock()
    private var gainRequestSeqCounter = 0L
    private val pendingGainRequests = ArrayDeque<GainRequest>()

    // The owned clock's writer (Y10a extraction). Written by the sink thread
    // only; any thread snapshots.
    private val clockWriter = VanguardRealtimeAudioPlaybackSinkClockWriter(config.sampleRate)

    // ── Published telemetry (sink thread writes) ───────────────────────────

    @Volatile private var exitReason: String = EXIT_NOT_STARTED
    @Volatile private var threadId: Long = -1L
    @Volatile private var threadIsTransportOwner = false
    @Volatile private var clockWriterBoundOnSinkThread = false
    @Volatile private var audioTrackInitOk = false
    @Volatile private var gainSetOk = false
    @Volatile private var gainValue = 0f
    // Y11a-prep: volume request queue telemetry (sink thread writes the applied-side counters;
    // requestGain writes the request-side counters under [gainRequestLock]).
    @Volatile private var gainRequestCount = 0L
    @Volatile private var gainAppliedCount = 0L
    @Volatile private var gainRejectedCount = 0L
    @Volatile private var gainQueueFullCount = 0L
    @Volatile private var lastGainRequestSeq = 0L
    @Volatile private var lastGainAppliedSeq = 0L
    @Volatile private var gainAppliedOnSinkThread = false
    @Volatile private var audioTrackBufferBytes = 0
    @Volatile private var audioTracksCreated = 0
    @Volatile private var releaseExecutedOnSinkThread = false
    @Volatile private var audioTrackCallsOffSinkThread = 0L
    @Volatile private var played = false
    @Volatile private var initialPlayState = PLAY_STATE_UNKNOWN
    @Volatile private var framesReadFromTransport = 0L
    @Volatile private var framesWrittenToSink = 0L
    @Volatile private var partialWriteCount = 0L
    @Volatile private var zeroWriteCount = 0L
    @Volatile private var drainCalls = 0L
    @Volatile private var drainCallsBeforeAllow = 0L
    @Volatile private var drainRequestSizeChanges = 0L
    @Volatile private var emptyDrainCount = 0L
    @Volatile private var productiveDrainPasses = 0L
    @Volatile private var eosDrainedObserved = false
    @Volatile private var parkCount = 0
    @Volatile private var unparkCount = 0
    @Volatile private var playStateAtPark = PLAY_STATE_UNKNOWN
    @Volatile private var playStateAfterUnpark = PLAY_STATE_UNKNOWN
    @Volatile private var parkedPlayStateViolations = 0L
    @Volatile private var parkExecutedOnSinkThread = false
    @Volatile private var unparkExecutedOnSinkThread = false
    @Volatile private var positionAtPark = -1L
    @Volatile private var epochClosedAtPark = EPOCH_NONE
    @Volatile private var epochOpenedAtUnpark = EPOCH_NONE
    @Volatile private var parkAckLatencyMs = -1L
    @Volatile private var parkedHoldMs = -1L
    @Volatile private var playbackHeadAtPark = 0L
    @Volatile private var playbackHeadAtUnpark = 0L
    @Volatile private var playbackHeadFinal = 0L
    @Volatile private var readyAtMs = -1L
    @Volatile private var drainAllowedAtMs = -1L
    @Volatile private var firstDrainAtMs = -1L
    @Volatile private var firstWriteAtMs = -1L
    @Volatile private var sinkThreadWallMs = 0L
    @Volatile private var checksum = 0L
    @Volatile private var lastReply: Reply? = null
    @Volatile private var parkRequestedAtMs = -1L

    // Y8b synthetic dead-object recovery telemetry (sink thread writes).
    // Every other dead-object field lives on [clockWriter] (Y10a extraction):
    // storage only, this bridge still makes every AudioTrack call and still
    // orders the recovery steps (class comment; [recoverFromSyntheticDeadObject]).
    @Volatile private var audioTrackBufferFrames = 0

    // Y9 seek park / flush / seek epoch telemetry (sink thread writes; request-side counters under parkLock).
    @Volatile private var seekParkCount = 0
    @Volatile private var parkHoldCapMs = -1L
    @Volatile private var flushRequestCount = 0
    @Volatile private var flushCount = 0
    @Volatile private var flushExecutedOnSinkThread = false
    @Volatile private var flushAckLatencyMs = -1L
    @Volatile private var playStateBeforeFlush = PLAY_STATE_UNKNOWN
    @Volatile private var playStateAfterFlush = PLAY_STATE_UNKNOWN
    @Volatile private var playbackHeadBeforeFlush = -1L
    @Volatile private var playbackHeadAfterFlush = -1L
    @Volatile private var framesWrittenAtFlush = -1L
    @Volatile private var framesReadAtFlush = -1L
    @Volatile private var drainCallsAtFlush = -1L
    @Volatile private var timestampPollsDuringFlush = -1L
    @Volatile private var postSeekExpectedFrames = -1L
    // Read budget (C6): declared before a flush, framesReadAtFlush + postSeekExpectedFrames after.
    @Volatile private var readBudgetFrames = 0L
    @Volatile private var seekTargetFrame = -1L
    @Volatile private var seekEpochOpenedAtUnpark = EPOCH_NONE
    @Volatile private var seekEpochBaseFrame = -1L
    @Volatile private var seekDiscontinuityFrames = -1L
    @Volatile private var seekEpochOpenAccepted = false
    @Volatile private var seekUnwrapResetAtFlush = false
    @Volatile private var epochRawOriginAtUnpark = -1L
    @Volatile private var playbackHeadAtSeekUnpark = -1L
    // Y17: set by requestFlush() under parkLock; read by the sink thread at unpark.
    @Volatile private var seekDeclaredBackward = false

    // Y16 drift-sample ingestion telemetry (class comment). Sink thread
    // writes the post-side fields; the owner-thread callback (or an inline
    // post-dispose rejection on the sink thread) updates the atomic
    // callback-side tallies. Diagnostic only: nothing reads them back.
    @Volatile private var driftSamplesPosted = 0L
    @Volatile private var driftSamplesSkipped = 0L
    @Volatile private var driftSamplesDropped = 0L
    @Volatile private var driftLastPostedGeneration = -1L
    private val driftInFlight = AtomicInteger(0)
    private val driftCallbackCount = AtomicLong(0L)
    private val driftSamplesRecorded = AtomicLong(0L)
    private val driftSamplesStaleRejected = AtomicLong(0L)
    private val driftSamplesOtherRejected = AtomicLong(0L)
    private val driftMaxQueueLatencyNs = AtomicLong(-1L)
    @Volatile private var driftLastRejectReason = ""
    @Volatile private var lastDriftReply: Reply? = null

    // ── Sink-thread-confined state ─────────────────────────────────────────

    private var audioTrack: AudioTrack? = null
    private val audioTimestamp = AudioTimestamp()
    private var lastProgressMs = 0L
    // Set by the write loop from the armed dead object to the end of the slice the new instance absorbs.
    private var deadObjectResumePending = false

    val phase: Phase get() = phaseRef.get()
    val isAlive: Boolean get() = thread?.isAlive == true
    val currentExitReason: String get() = exitReason
    val framesWritten: Long get() = framesWrittenToSink
    val framesRead: Long get() = framesReadFromTransport
    val hasPlayed: Boolean get() = played
    val sinkThreadId: Long get() = threadId
    val currentFlushCount: Int get() = flushCount

    // ── Public API (any thread) ────────────────────────────────────────────

    // Starts the sink thread. Single use; false when already started.
    fun start(): Boolean {
        if (!started.compareAndSet(false, true)) return false
        exitReason = EXIT_RUNNING
        val t = Thread({ runOnSinkThread() }, config.threadName)
        thread = t
        t.start()
        return true
    }

    // True once the AudioTrack exists with its gain applied (phase READY).
    fun awaitReady(timeoutMs: Long): Boolean =
        readyLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && phaseRef.get() == Phase.READY

    // Releases the drain gate; the sink drains only after this.
    fun allowDrain() {
        drainGate.countDown()
    }

    // Flips RUNNING -> PARK_REQUESTED; the sink parks at its next drain iteration. False when not RUNNING.
    fun requestPark(): Boolean {
        if (!started.get()) return false
        parkAckLatch = CountDownLatch(1)
        unparkAckLatch = CountDownLatch(1)
        if (!phaseRef.compareAndSet(Phase.RUNNING, Phase.PARK_REQUESTED)) return false
        parkRequestedAtMs = SystemClock.elapsedRealtime()
        return true
    }

    fun awaitParked(timeoutMs: Long): Boolean =
        parkAckLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && phaseRef.get() == Phase.PARKED

    // Y9 / Y10b-1a: [requestPark] as a seek park: capped by [Config.maxSeekHoldMs],
    // takes exactly one [requestFlush] per use, unparks only after its ack.
    // Allowed up to [MAX_SEEK_PARKS] times, serially: the previous seek park's
    // flush must already be acked (seekParkCount == flushCount) before the next.
    fun requestSeekPark(): Boolean {
        if (!started.get() || phaseRef.get() != Phase.RUNNING) return false
        parkLock.withLock {
            if (seekParkRequested || flushRequested) return false
            if (seekParkCount >= MAX_SEEK_PARKS || seekParkCount != flushCount) return false
            seekParkRequested = true
        }
        if (!requestPark()) {
            parkLock.withLock { seekParkRequested = false }
            return false
        }
        return true
    }

    // Y9 / Y10b-1a, any thread: the PARKED seek-park sink thread flushes exactly
    // once per use, bounds further reads to `postSeekFrames` (C6) and opens the
    // next epoch at `targetFrame` on unpark. False unless PARKED on a seek park
    // whose flush for this use has not run yet. Y17: `declaredBackward` declares
    // the seek backward in content frames (class comment); the unpark then
    // asserts T < written-at-flush and opens the epoch through the clock's
    // declared-backward entry point instead of the forward one.
    fun requestFlush(postSeekFrames: Long, targetFrame: Long, declaredBackward: Boolean = false): Boolean {
        if (postSeekFrames <= 0L || targetFrame < 0L) return false
        parkLock.withLock {
            if (phaseRef.get() != Phase.PARKED) return false
            if (!seekParkRequested) return false
            if (flushRequested) return false
            if (flushCount != seekParkCount - 1) return false
            flushAckLatch = CountDownLatch(1)
            flushRequested = true
            flushRequestedAtMs = SystemClock.elapsedRealtime()
            postSeekExpectedFrames = postSeekFrames
            seekTargetFrame = targetFrame
            seekDeclaredBackward = declaredBackward
            flushRequestCount++
            parkCondition.signalAll()
        }
        return true
    }

    // Y9 compatibility: bounded wait for the ONE flush ack (expectedCount=1).
    fun awaitFlushed(timeoutMs: Long): Boolean = awaitFlushed(timeoutMs, 1)

    // Y10b-1a: bounded wait for the flush ack of a specific serial seek park,
    // keyed by the cumulative flush count it should reach (latch reset per requestFlush()).
    fun awaitFlushed(timeoutMs: Long, expectedCount: Int): Boolean =
        flushAckLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && flushCount == expectedCount

    // Wakes a PARKED sink thread (AudioTrack.play there, then RUNNING). False
    // when not PARKED, a flush is still pending, or (seek park) its flush has not yet acked.
    fun unpark(): Boolean {
        parkLock.withLock {
            if (phaseRef.get() != Phase.PARKED) return false
            if (flushRequested) return false
            if (seekParkRequested && flushCount != seekParkCount) return false
            unparkRequested = true
            parkCondition.signalAll()
        }
        return true
    }

    fun awaitRunning(timeoutMs: Long): Boolean =
        unparkAckLatch.await(timeoutMs, TimeUnit.MILLISECONDS) &&
            phaseRef.get() == Phase.RUNNING && unparkCount > 0

    // Y11a-prep: any-thread request for a target linear gain in [0, config.gain]; queued and
    // applied only on the sink thread (top of each drain-loop iteration and inside a parked
    // wait), never by an AudioTrack call off that thread. Returns a positive sequence number to
    // pass to [awaitGainApplied], or -1 when the gain is non-finite/out of range, the queue is
    // full, or the sink already exited; a rejection is never thrown back to the caller, only
    // counted in telemetry.
    fun requestGain(gain: Float): Long {
        gainRequestLock.withLock {
            if (!gain.isFinite() || gain < 0f || gain > config.gain) {
                gainRejectedCount++
                return -1L
            }
            if (phaseRef.get() == Phase.EXITED) {
                gainRejectedCount++
                return -1L
            }
            if (pendingGainRequests.size >= GAIN_REQUEST_QUEUE_CAPACITY) {
                gainQueueFullCount++
                gainRejectedCount++
                return -1L
            }
            val seq = ++gainRequestSeqCounter
            pendingGainRequests.addLast(GainRequest(seq, gain))
            gainRequestCount++
            lastGainRequestSeq = seq
            return seq
        }
    }

    // Y11a-prep: bounded, any-thread wait for [requestGain]'s seq to be applied on the sink
    // thread. False on timeout, or if the sink exits before reaching it (never throws).
    fun awaitGainApplied(seq: Long, timeoutMs: Long): Boolean {
        if (seq <= 0L) return false
        val deadlineAtMs = SystemClock.elapsedRealtime() + timeoutMs
        while (lastGainAppliedSeq < seq) {
            if (phaseRef.get() == Phase.EXITED) return lastGainAppliedSeq >= seq
            if (SystemClock.elapsedRealtime() >= deadlineAtMs) return false
            SystemClock.sleep(GAIN_AWAIT_POLL_MS)
        }
        return true
    }

    // Observed by every bounded wait (gate, park, write retries, stalls).
    fun cancel() {
        cancelled.set(true)
        parkLock.withLock { parkCondition.signalAll() }
    }

    fun join(timeoutMs: Long): Boolean {
        val t = thread ?: return true
        if (Thread.currentThread() === t) return false
        try {
            t.join(timeoutMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return !t.isAlive
    }

    fun awaitExit(timeoutMs: Long): Boolean = exitLatch.await(timeoutMs, TimeUnit.MILLISECONDS)

    fun clockSnapshot(): VanguardRealtimePlaybackPresentationClock.Snapshot = clockWriter.snapshot()

    // Y13: any-thread, non-allocating forwarders onto the owned clock (class comment).
    fun currentPositionFrames(): Long = clockWriter.currentPositionFrames()
    fun currentPositionUs(): Long = clockWriter.currentPositionUs()

    // Built section-by-section (each constructor call kept well under the
    // Android verifier's argument-register budget; see the telemetry file's
    // header) rather than one flat ~165-parameter invocation.
    fun telemetry(): VanguardRealtimeAudioPlaybackSinkTelemetry {
        val core = VanguardRealtimeAudioPlaybackSinkTelemetryCore(
            phase = phaseRef.get(),
            exitReason = exitReason,
            threadId = threadId,
            threadIsTransportOwner = threadIsTransportOwner,
            clockWriterBoundOnSinkThread = clockWriterBoundOnSinkThread,
            audioTrackInitOk = audioTrackInitOk,
            gainSetOk = gainSetOk,
            gainValue = gainValue,
        )
        val gainQueue = VanguardRealtimeAudioPlaybackSinkTelemetryGainQueue(
            gainRequestCount = gainRequestCount,
            gainAppliedCount = gainAppliedCount,
            gainRejectedCount = gainRejectedCount,
            gainQueueFullCount = gainQueueFullCount,
            lastGainRequestSeq = lastGainRequestSeq,
            lastGainAppliedSeq = lastGainAppliedSeq,
            gainAppliedOnSinkThread = gainAppliedOnSinkThread,
            effectiveGain = gainValue,
        )
        val trackLifecycle = VanguardRealtimeAudioPlaybackSinkTelemetryTrackLifecycle(
            audioTrackBufferBytes = audioTrackBufferBytes,
            audioTracksCreated = audioTracksCreated,
            releaseCount = releaseCounter.get(),
            releaseExecutedOnSinkThread = releaseExecutedOnSinkThread,
            audioTrackCallsOffSinkThread = audioTrackCallsOffSinkThread,
            played = played,
            initialPlayState = initialPlayState,
        )
        val writePath = VanguardRealtimeAudioPlaybackSinkTelemetryWritePath(
            framesReadFromTransport = framesReadFromTransport,
            framesWrittenToSink = framesWrittenToSink,
            partialWriteCount = partialWriteCount,
            zeroWriteCount = zeroWriteCount,
            drainCalls = drainCalls,
            drainCallsBeforeAllow = drainCallsBeforeAllow,
            drainRequestSizeChanges = drainRequestSizeChanges,
        )
        val drainSummary = VanguardRealtimeAudioPlaybackSinkTelemetryDrainSummary(
            emptyDrainCount = emptyDrainCount,
            productiveDrainPasses = productiveDrainPasses,
            eosDrainedObserved = eosDrainedObserved,
        )
        val clockPollA = VanguardRealtimeAudioPlaybackSinkTelemetryClockPollA(
            timestampPollAttempts = clockWriter.timestampPollAttempts,
            timestampPollSuccesses = clockWriter.timestampPollSuccesses,
            timestampPollUnavailable = clockWriter.timestampPollUnavailable,
            timestampPollsWhileParked = clockWriter.timestampPollsWhileParked,
            timestampMaxPollsInOnePass = clockWriter.timestampMaxPollsInOnePass,
            clockEpochOpenCalls = clockWriter.clockEpochOpenCalls,
        )
        val clockPollB = VanguardRealtimeAudioPlaybackSinkTelemetryClockPollB(
            clockEpochCloseCalls = clockWriter.clockEpochCloseCalls,
            clockRejectedCount = clockWriter.clockRejectedCount,
            clockSnapshotsAtPark = clockWriter.clockSnapshotsAtPark,
            rebasedClampCount = clockWriter.rebasedClampCount,
            currentEpoch = clockWriter.currentEpoch,
            clockDeclaredBackwardOpenCalls = clockWriter.clockDeclaredBackwardOpenCalls,
        )
        val parkA = VanguardRealtimeAudioPlaybackSinkTelemetryParkA(
            parkCount = parkCount,
            unparkCount = unparkCount,
            playStateAtPark = playStateAtPark,
            playStateAfterUnpark = playStateAfterUnpark,
            parkedPlayStateViolations = parkedPlayStateViolations,
            parkExecutedOnSinkThread = parkExecutedOnSinkThread,
            unparkExecutedOnSinkThread = unparkExecutedOnSinkThread,
            positionAtPark = positionAtPark,
        )
        val parkB = VanguardRealtimeAudioPlaybackSinkTelemetryParkB(
            epochClosedAtPark = epochClosedAtPark,
            epochOpenedAtUnpark = epochOpenedAtUnpark,
            parkAckLatencyMs = parkAckLatencyMs,
            parkedHoldMs = parkedHoldMs,
            playbackHeadAtPark = playbackHeadAtPark,
            playbackHeadAtUnpark = playbackHeadAtUnpark,
            playbackHeadFinal = playbackHeadFinal,
        )
        val parkC = VanguardRealtimeAudioPlaybackSinkTelemetryParkC(
            readyAtMs = readyAtMs,
            drainAllowedAtMs = drainAllowedAtMs,
            firstDrainAtMs = firstDrainAtMs,
            firstWriteAtMs = firstWriteAtMs,
            sinkThreadWallMs = sinkThreadWallMs,
            checksumHex = hex16(checksum),
            lastReply = lastReply,
        )
        val deadObjectA = VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectA(
            syntheticDeadObjectInjectAfterFrames = config.syntheticDeadObjectInjectAfterFrames,
            deadObjectInjectedCount = clockWriter.deadObjectInjectedCount,
            deadObjectObservedCount = clockWriter.deadObjectObservedCount,
            deadObjectRecoveryCount = clockWriter.deadObjectRecoveryCount,
            deadObjectOldTrackReleaseCount = clockWriter.deadObjectOldTrackReleaseCount,
            deadObjectRecoveryExecutedOnSinkThread = clockWriter.deadObjectRecoveryExecutedOnSinkThread,
            deadObjectNewTrackInitOk = clockWriter.deadObjectNewTrackInitOk,
            deadObjectNewTrackVolumeOk = clockWriter.deadObjectNewTrackVolumeOk,
        )
        val deadObjectB = VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectB(
            deadObjectNewTrackPlayOk = clockWriter.deadObjectNewTrackPlayOk,
            deadObjectNewTrackPlayState = clockWriter.deadObjectNewTrackPlayState,
            deadObjectNewTrackSameBuffer = clockWriter.deadObjectNewTrackSameBuffer,
            audioTrackBufferFrames = audioTrackBufferFrames,
            deadObjectNewTrackBufferFrames = clockWriter.deadObjectNewTrackBufferFrames,
            deadObjectRecoveryWallMs = clockWriter.deadObjectRecoveryWallMs,
            deadObjectEpochBeforeRecovery = clockWriter.deadObjectEpochBeforeRecovery,
            deadObjectEpochOpenedAfterRecovery = clockWriter.deadObjectEpochOpenedAfterRecovery,
        )
        val deadObjectC = VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectC(
            deadObjectEpochCloseAccepted = clockWriter.deadObjectEpochCloseAccepted,
            deadObjectEpochOpenAccepted = clockWriter.deadObjectEpochOpenAccepted,
            deadObjectPositionBeforeRecovery = clockWriter.deadObjectPositionBeforeRecovery,
            deadObjectBaseFrameAfterRecovery = clockWriter.deadObjectBaseFrameAfterRecovery,
            deadObjectBaseStepFrames = clockWriter.deadObjectBaseStepFrames,
            deadObjectBaseStepBounded = clockWriter.deadObjectBaseStepBounded,
            deadObjectContentHeadAtDeadObject = clockWriter.deadObjectContentHeadAtDeadObject,
            deadObjectWrittenAheadOfHeadFrames = clockWriter.deadObjectWrittenAheadOfHeadFrames,
        )
        val deadObjectD = VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectD(
            deadObjectPublicationLagFrames = clockWriter.deadObjectPublicationLagFrames,
            deadObjectBaseStepDecompositionOk = clockWriter.deadObjectBaseStepDecompositionOk,
            deadObjectClockProvenanceAtRecovery = clockWriter.deadObjectClockProvenanceAtRecovery,
            deadObjectClockLastAgeNsAtRecovery = clockWriter.deadObjectClockLastAgeNsAtRecovery,
            deadObjectSliceBytesAtRecovery = clockWriter.deadObjectSliceBytesAtRecovery,
            deadObjectUnwrittenBytesAtRecovery = clockWriter.deadObjectUnwrittenBytesAtRecovery,
            deadObjectBufferPositionAtRecovery = clockWriter.deadObjectBufferPositionAtRecovery,
            deadObjectFramesReadAtRecovery = clockWriter.deadObjectFramesReadAtRecovery,
        )
        val deadObjectE = VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectE(
            deadObjectFramesWrittenBeforeRecovery = clockWriter.deadObjectFramesWrittenBeforeRecovery,
            deadObjectRemainderFramesExpected = clockWriter.deadObjectRemainderFramesExpected,
            deadObjectRemainderFramesWrittenOnNewTrack = clockWriter.deadObjectRemainderFramesWrittenOnNewTrack,
            deadObjectRemainderAccountingOk = clockWriter.deadObjectRemainderAccountingOk,
            deadObjectTimestampPollsDuringRecovery = clockWriter.deadObjectTimestampPollsDuringRecovery,
            clockSnapshotsAtDeadObjectRecovery = clockWriter.clockSnapshotsAtDeadObjectRecovery,
            playbackHeadAtDeadObject = clockWriter.playbackHeadAtDeadObject,
        )
        val seekFlushA = VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushA(
            maxSeekHoldMs = config.maxSeekHoldMs,
            seekParkCount = seekParkCount,
            parkHoldCapMs = parkHoldCapMs,
            flushRequestCount = flushRequestCount,
            flushCount = flushCount,
            flushExecutedOnSinkThread = flushExecutedOnSinkThread,
            flushAckLatencyMs = flushAckLatencyMs,
        )
        val seekFlushB = VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushB(
            playStateBeforeFlush = playStateBeforeFlush,
            playStateAfterFlush = playStateAfterFlush,
            playbackHeadBeforeFlush = playbackHeadBeforeFlush,
            playbackHeadAfterFlush = playbackHeadAfterFlush,
            framesWrittenAtFlush = framesWrittenAtFlush,
            framesReadAtFlush = framesReadAtFlush,
            drainCallsAtFlush = drainCallsAtFlush,
        )
        val seekFlushC = VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushC(
            timestampPollsDuringFlush = timestampPollsDuringFlush,
            postSeekExpectedFrames = postSeekExpectedFrames,
            readBudgetFrames = readBudgetFrames,
            seekTargetFrame = seekTargetFrame,
            seekEpochOpenedAtUnpark = seekEpochOpenedAtUnpark,
            seekEpochBaseFrame = seekEpochBaseFrame,
        )
        val seekFlushD = VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushD(
            seekDiscontinuityFrames = seekDiscontinuityFrames,
            seekEpochOpenAccepted = seekEpochOpenAccepted,
            seekUnwrapResetAtFlush = seekUnwrapResetAtFlush,
            epochRawOriginAtUnpark = epochRawOriginAtUnpark,
            playbackHeadAtSeekUnpark = playbackHeadAtSeekUnpark,
            postSeekFramesWritten = if (flushCount > 0) framesWrittenToSink - framesWrittenAtFlush else 0L,
            seekDeclaredBackward = seekDeclaredBackward,
        )
        val presentationLagA = VanguardRealtimeAudioPlaybackSinkTelemetryPresentationLagA(
            epochBaseFrame = clockWriter.epochBaseFrame,
            framesWrittenAtEpochOpen = clockWriter.framesWrittenAtEpochOpen,
            framesReadAtEpochOpen = clockWriter.framesReadAtEpochOpen,
            presentationLagSampleCount = clockWriter.presentationLagSampleCount,
            presentationLagBoundedSampleCount = clockWriter.presentationLagBoundedSampleCount,
            presentationLagExcludedSampleCount = clockWriter.presentationLagExcludedSampleCount,
        )
        val presentationLagB = VanguardRealtimeAudioPlaybackSinkTelemetryPresentationLagB(
            lastPresentationLagFrames = clockWriter.lastPresentationLagFrames,
            minPresentationLagFrames = clockWriter.minPresentationLagFrames,
            maxPresentationLagFrames = clockWriter.maxPresentationLagFrames,
            presentationLagLowerBoundFrames = clockWriter.presentationLagLowerBoundFrames,
            presentationLagUpperBoundFrames = clockWriter.presentationLagUpperBoundFrames,
            lastPositionFramesAtPoll = clockWriter.lastPositionFramesAtPoll,
        )
        val presentationLagC = VanguardRealtimeAudioPlaybackSinkTelemetryPresentationLagC(
            lastPositionUsAtPoll = clockWriter.lastPositionUsAtPoll,
            positionAtEosFrames = clockWriter.positionAtEosFrames,
            positionAtEosUs = clockWriter.positionAtEosUs,
            currentPositionReadsFromWriterThread = clockWriter.currentPositionReadsFromWriterThread,
            currentPositionReadsFromOtherThreads = clockWriter.currentPositionReadsFromOtherThreads,
        )
        val driftA = VanguardRealtimeAudioPlaybackSinkTelemetryDriftA(
            driftSamplesPosted = driftSamplesPosted,
            driftSamplesSkipped = driftSamplesSkipped,
            driftSamplesDropped = driftSamplesDropped,
            driftCallbackCount = driftCallbackCount.get(),
            driftSamplesRecorded = driftSamplesRecorded.get(),
            driftSamplesStaleRejected = driftSamplesStaleRejected.get(),
        )
        val driftB = VanguardRealtimeAudioPlaybackSinkTelemetryDriftB(
            driftSamplesOtherRejected = driftSamplesOtherRejected.get(),
            driftLastRejectReason = driftLastRejectReason,
            driftMaxQueueLatencyNs = driftMaxQueueLatencyNs.get(),
            driftLastPostedGeneration = driftLastPostedGeneration,
            driftLastExpectedPtsUs = lastDriftReply?.nativeClockLastDriftExpectedPtsUs ?: -1L,
            driftLastReportedPtsUs = lastDriftReply?.nativeClockLastDriftReportedPtsUs ?: -1L,
        )
        val driftC = VanguardRealtimeAudioPlaybackSinkTelemetryDriftC(
            driftLastDeltaUs = lastDriftReply?.nativeClockLastDriftDeltaUs ?: 0L,
            driftLastReportedFrame = lastDriftReply?.nativeDriftLastReportedFrame ?: -1L,
            driftNativeSampleCount = lastDriftReply?.nativeClockDriftSampleCount ?: 0L,
            driftNativeSamplesRecorded = lastDriftReply?.nativeDriftSamplesRecorded ?: 0L,
            driftNativeSamplesRejected = lastDriftReply?.nativeDriftSamplesRejected ?: 0L,
        )
        val coreBundle = VanguardRealtimeAudioPlaybackSinkTelemetryCoreBundle(
            core = core,
            gainQueue = gainQueue,
            trackLifecycle = trackLifecycle,
            writePath = writePath,
            drainSummary = drainSummary,
        )
        val clockParkBundle = VanguardRealtimeAudioPlaybackSinkTelemetryClockParkBundle(
            clockPollA = clockPollA,
            clockPollB = clockPollB,
            parkA = parkA,
            parkB = parkB,
            parkC = parkC,
        )
        val deadObjectBundle = VanguardRealtimeAudioPlaybackSinkTelemetryDeadObjectBundle(
            deadObjectA = deadObjectA,
            deadObjectB = deadObjectB,
            deadObjectC = deadObjectC,
            deadObjectD = deadObjectD,
            deadObjectE = deadObjectE,
        )
        val seekFlushBundle = VanguardRealtimeAudioPlaybackSinkTelemetrySeekFlushBundle(
            seekFlushA = seekFlushA,
            seekFlushB = seekFlushB,
            seekFlushC = seekFlushC,
            seekFlushD = seekFlushD,
        )
        val lagDriftBundle = VanguardRealtimeAudioPlaybackSinkTelemetryLagDriftBundle(
            presentationLagA = presentationLagA,
            presentationLagB = presentationLagB,
            presentationLagC = presentationLagC,
            driftA = driftA,
            driftB = driftB,
            driftC = driftC,
        )
        return VanguardRealtimeAudioPlaybackSinkTelemetry(
            coreBundle = coreBundle,
            clockParkBundle = clockParkBundle,
            deadObjectBundle = deadObjectBundle,
            seekFlushBundle = seekFlushBundle,
            lagDriftBundle = lagDriftBundle,
        )
    }

    // ── Sink thread body ───────────────────────────────────────────────────

    private fun runOnSinkThread() {
        val wallStart = SystemClock.elapsedRealtime()
        threadId = Thread.currentThread().id
        clockWriterBoundOnSinkThread = clockWriter.bindWriterThread() &&
            clockWriter.boundWriterThreadId == threadId
        try {
            threadIsTransportOwner = config.stateMachine.isOwnerThread
            if (threadIsTransportOwner) throw FailClosed("sink_thread_is_transport_owner")
            checkDeadlineAndCancel()
            validateConfig()
            createAudioTrack()
            phaseRef.set(Phase.READY)
            readyAtMs = SystemClock.elapsedRealtime()
            readyLatch.countDown()
            awaitDrainGate()
            phaseRef.set(Phase.RUNNING)
            drainAllowedAtMs = SystemClock.elapsedRealtime()
            drainLoop()
            exitReason = EXIT_EOS
        } catch (f: FailClosed) {
            exitReason = f.reason
        } catch (t: Throwable) {
            exitReason = "exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            clockWriter.closeIfOpen()
            releaseAudioTrackOnce()
            phaseRef.set(Phase.EXITED)
            sinkThreadWallMs = SystemClock.elapsedRealtime() - wallStart
            // Waiters must never block on a dead sink; they re-check phase.
            readyLatch.countDown()
            parkAckLatch.countDown()
            unparkAckLatch.countDown()
            flushAckLatch.countDown()
            exitLatch.countDown()
            try {
                config.onExited?.invoke(exitReason)
            } catch (_: Throwable) {}
        }
    }

    private fun validateConfig() {
        if (config.channelCount != 1 && config.channelCount != 2) throw FailClosed("invalid_channel_count")
        if (config.maxFramesPerMix <= 0 || config.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP) {
            throw FailClosed("invalid_max_frames_per_mix")
        }
        if (config.sampleRate < VanguardRealtimePlaybackNativeSession.MIN_SAMPLE_RATE || config.sampleRate > VanguardRealtimePlaybackNativeSession.MAX_SAMPLE_RATE) {
            throw FailClosed("invalid_sample_rate")
        }
        if (config.declaredFrameCount <= 0L) throw FailClosed("invalid_declared_frame_count")
        if (!(config.gain > 0f) || config.gain > 1f) throw FailClosed("invalid_gain")
        if (config.maxPauseHoldMs <= 0L) throw FailClosed("invalid_max_pause_hold")
        if (config.maxSeekHoldMs <= 0L) throw FailClosed("invalid_max_seek_hold")
        if (config.syntheticDeadObjectInjectAfterFrames < 0L) throw FailClosed("invalid_dead_object_inject_after_frames")
    }

    private fun isCancelled(): Boolean = cancelled.get() || config.externallyCancelled()

    private fun checkDeadlineAndCancel() {
        if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
        if (SystemClock.elapsedRealtime() > config.deadlineAtMs) throw FailClosed(EXIT_DEADLINE)
    }

    private fun noteTrackCall() {
        if (Thread.currentThread().id != threadId) audioTrackCallsOffSinkThread++
    }

    private fun requireTrack(): AudioTrack {
        noteTrackCall()
        return audioTrack ?: throw FailClosed("audio_track_missing")
    }

    // Builds one AudioTrack from the frozen config; returns the buffer request
    // so a Y8b replacement can be checked against the original geometry.
    private fun buildAudioTrack(): Pair<AudioTrack, Int> {
        val bytesPerFrame = 2 * config.channelCount
        val channelMask = if (config.channelCount == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minBytes = AudioTrack.getMinBufferSize(config.sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
        if (minBytes <= 0) throw FailClosed("audio_track_min_buffer_invalid:$minBytes")
        val floorBytes = (TRACK_BUFFER_MARGIN_WINDOWS * config.maxFramesPerMix * bytesPerFrame).toInt()
        val bufferBytes = maxOf(minBytes, floorBytes)
        noteTrackCall()
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(config.sampleRate).setChannelMask(channelMask).build()
        val track = AudioTrack.Builder().setAudioAttributes(attributes).setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(bufferBytes).build()
        audioTracksCreated++
        return Pair(track, bufferBytes)
    }

    private fun createAudioTrack() {
        val (track, bufferBytes) = buildAudioTrack()
        audioTrack = track
        audioTrackBufferBytes = bufferBytes
        if (track.state != AudioTrack.STATE_INITIALIZED) throw FailClosed("audio_track_not_initialized")
        audioTrackInitOk = true
        audioTrackBufferFrames = track.bufferSizeInFrames
        if (track.setVolume(config.gain) != AudioTrack.SUCCESS) throw FailClosed("audio_track_set_volume_failed")
        gainValue = config.gain
        gainSetOk = config.gain > 0f
        // Y12: attach only after the AudioTrack is initialized and its gain
        // applied (class comment); fail closed before anything is drained.
        config.routingController?.let { routing ->
            if (!routing.attach(track)) throw FailClosed("routing_listener_attach_failed:${routing.lastAttachError}")
        }
    }

    // Bounded, cancel-aware wait for the session's allowDrain().
    private fun awaitDrainGate() {
        while (!drainGate.await(GATE_POLL_MS, TimeUnit.MILLISECONDS)) {
            checkDeadlineAndCancel()
        }
        checkDeadlineAndCancel()
        drainCallsBeforeAllow = drainCalls
    }

    private fun rawHead(): Long = requireTrack().playbackHeadPosition.toLong() and 0xFFFFFFFFL

    // Mirrors the native drain checksum over exactly the frames handed to AudioTrack.write.
    private fun accumulateChecksum(buf: ByteBuffer, frames: Int) {
        var c = checksum
        val sampleCount = frames * config.channelCount
        for (i in 0 until sampleCount) c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
        checksum = c
    }

    // ── Write path (WRITE_NON_BLOCKING, in-place bounded retries) ──────────

    // Arms the ONE synthetic dead object (seam > 0, never injected, playing
    // with an open epoch, >= injectAfterFrames written): true exactly once per
    // run; the caller substitutes ERROR_DEAD_OBJECT WITHOUT calling write().
    // Deterministic; timestamp/clock outcomes play no part.
    private fun armSyntheticDeadObject(unwrittenBytes: Int): Boolean {
        val after = config.syntheticDeadObjectInjectAfterFrames
        if (after <= 0L) return false
        if (clockWriter.deadObjectInjectedCount != 0L) return false
        if (!played || clockWriter.currentEpoch == EPOCH_NONE) return false
        if (phaseRef.get() != Phase.RUNNING) return false
        if (framesWrittenToSink < after) return false
        if (unwrittenBytes <= 0) return false
        clockWriter.deadObjectInjectedCount = 1L
        return true
    }

    private fun writeAllToAudioTrack(buf: ByteBuffer, bytes: Int, bytesPerFrame: Int) {
        var track = requireTrack()
        var framesThisCall = 0L
        buf.position(0)
        buf.limit(bytes)
        var consecutiveZero = 0
        while (buf.hasRemaining()) {
            checkDeadlineAndCancel()
            val requested = buf.remaining()
            val positionBefore = buf.position()
            val wrote =
                if (armSyntheticDeadObject(requested)) AudioTrack.ERROR_DEAD_OBJECT else track.write(buf, requested, AudioTrack.WRITE_NON_BLOCKING)
            val errorPrefix = if (clockWriter.deadObjectRecoveryCount > 0) "recreated_audio_track" else "audio_track"
            when {
                wrote > 0 -> {
                    consecutiveZero = 0
                    if (wrote % bytesPerFrame != 0) throw FailClosed("${errorPrefix}_write_frame_misaligned:$wrote")
                    val frames = (wrote / bytesPerFrame).toLong()
                    framesThisCall += frames
                    framesWrittenToSink += frames
                    if (firstWriteAtMs < 0L) firstWriteAtMs = SystemClock.elapsedRealtime()
                    if (wrote < requested) {
                        partialWriteCount++
                        buf.compact()
                        buf.flip()
                    }
                }
                wrote == 0 -> {
                    zeroWriteCount++
                    if (++consecutiveZero > MAX_CONSECUTIVE_ZERO_WRITES) throw FailClosed("${errorPrefix}_write_stalled")
                    SystemClock.sleep(ZERO_WRITE_SLEEP_MS)
                }
                wrote == AudioTrack.ERROR_INVALID_OPERATION -> throw FailClosed("${errorPrefix}_invalid_operation")
                wrote == AudioTrack.ERROR_BAD_VALUE -> throw FailClosed("${errorPrefix}_bad_value")
                wrote == AudioTrack.ERROR_DEAD_OBJECT -> {
                    clockWriter.deadObjectObservedCount++
                    if (clockWriter.deadObjectObservedCount != 1L) {
                        throw FailClosed("$EXIT_DEAD_OBJECT_REPEATED:${clockWriter.deadObjectObservedCount}")
                    }
                    // Only the armed synthetic dead object is recovered; a real one fails closed.
                    if (clockWriter.deadObjectInjectedCount != 1L) throw FailClosed(EXIT_DEAD_OBJECT)
                    if (buf.position() != positionBefore || buf.remaining() != requested) {
                        throw FailClosed("dead_object_consumed_bytes")
                    }
                    clockWriter.deadObjectSliceBytesAtRecovery = bytes.toLong()
                    clockWriter.deadObjectUnwrittenBytesAtRecovery = requested.toLong()
                    clockWriter.deadObjectBufferPositionAtRecovery = positionBefore.toLong()
                    clockWriter.deadObjectFramesReadAtRecovery = framesReadFromTransport
                    clockWriter.deadObjectFramesWrittenBeforeRecovery = framesWrittenToSink
                    clockWriter.deadObjectRemainderFramesExpected = (requested / bytesPerFrame).toLong()
                    // Recovery on this thread; buffer position/limit untouched, same remainder resumes.
                    track = recoverFromSyntheticDeadObject(track)
                    deadObjectResumePending = true
                    consecutiveZero = 0
                }
                else -> throw FailClosed("${errorPrefix}_generic_error:$wrote")
            }
        }
        if (deadObjectResumePending) {
            // Exactly the remainder at injection landed on the new instance; slice total intact.
            deadObjectResumePending = false
            clockWriter.deadObjectRemainderFramesWrittenOnNewTrack = framesWrittenToSink - clockWriter.deadObjectFramesWrittenBeforeRecovery
            clockWriter.deadObjectRemainderAccountingOk =
                clockWriter.deadObjectRemainderFramesWrittenOnNewTrack == clockWriter.deadObjectRemainderFramesExpected &&
                    framesThisCall == (bytes / bytesPerFrame).toLong()
            if (!clockWriter.deadObjectRemainderAccountingOk) {
                throw FailClosed(
                    "dead_object_remainder_accounting:${clockWriter.deadObjectRemainderFramesWrittenOnNewTrack}:${clockWriter.deadObjectRemainderFramesExpected}",
                )
            }
        }
        buf.clear()
    }

    // ── Y8b: synthetic dead-object recovery (sink thread only) ─────────────

    // Recovery after the armed ERROR_DEAD_OBJECT on [oldTrack], entirely on
    // this sink thread inside the write loop with the drain buffer untouched;
    // the step order is in the class comment. No timestamp poll and no
    // transport command happen here.
    private fun recoverFromSyntheticDeadObject(oldTrack: AudioTrack): AudioTrack {
        val recoveryStart = SystemClock.elapsedRealtime()
        clockWriter.deadObjectRecoveryExecutedOnSinkThread = Thread.currentThread().id == threadId
        if (!clockWriter.deadObjectRecoveryExecutedOnSinkThread) throw FailClosed("dead_object_recovery_off_sink_thread")
        if (clockWriter.deadObjectRecoveryCount != 0 || clockWriter.deadObjectOldTrackReleaseCount != 0) {
            throw FailClosed("dead_object_recovery_repeated")
        }
        if (releaseCounter.get() > 0) throw FailClosed("dead_object_after_final_release")
        if (phaseRef.get() != Phase.RUNNING) throw FailClosed("dead_object_outside_running:${phaseRef.get().name.lowercase()}")
        val epochBeforeRecovery = clockWriter.currentEpoch
        if (epochBeforeRecovery == EPOCH_NONE) throw FailClosed("dead_object_without_open_epoch")
        clockWriter.deadObjectEpochBeforeRecovery = epochBeforeRecovery
        val pollAttemptsAtStart = clockWriter.timestampPollAttempts

        // Step 1: freeze from ONE (counted) snapshot, telemetry only; the
        // epoch closes with the dead instance.
        val snap = clockWriter.snapshotAtDeadObjectRecovery()
        val positionBeforeRecovery = snap.positionFrames
        clockWriter.deadObjectPositionBeforeRecovery = positionBeforeRecovery
        clockWriter.deadObjectClockProvenanceAtRecovery = snap.provenance.name
        clockWriter.deadObjectClockLastAgeNsAtRecovery = snap.lastAgeNs
        val framesWrittenAtDeadObject = framesWrittenToSink
        // Head consumed by the dead instance as a content frame of the closing
        // epoch (poll-path unwrap/rebase); -1 if unanswered or negative.
        var contentHead = -1L
        try {
            val rawHeadAtDeadObject = oldTrack.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            clockWriter.playbackHeadAtDeadObject = rawHeadAtDeadObject
            val rebasedHead = clockWriter.peekContentFrame(rawHeadAtDeadObject, snap.lastHead)
            if (rebasedHead >= 0L && rebasedHead < FRAME_WRAP_MODULUS) contentHead = snap.epochBaseOffsetFrames + rebasedHead
        } catch (_: Throwable) {}
        clockWriter.deadObjectContentHeadAtDeadObject = contentHead
        val closeOutcome = clockWriter.closeEpoch(epochBeforeRecovery)
        clockWriter.deadObjectEpochCloseAccepted = closeOutcome.accepted
        if (!closeOutcome.accepted) throw FailClosed("dead_object_epoch_close_rejected:${closeOutcome.name.lowercase()}")

        // Step 1.5 (Y12): detach the routing listener from the dying
        // instance before it is released, mirroring [releaseAudioTrackOnce].
        // A genuine detach failure (something was attached and the removal
        // itself threw) fails closed rather than releasing a track a
        // listener may still reference.
        val routing = config.routingController
        if (routing != null && routing.isAttached && !routing.detach()) {
            throw FailClosed("routing_listener_detach_failed_before_dead_object_release:${routing.lastDetachError}")
        }

        // Step 2: release the old instance once (never the final releaseCounter);
        // a dead object accepts no control calls, so no stop/flush precedes it.
        audioTrack = null
        noteTrackCall()
        try {
            oldTrack.release()
        } catch (t: Throwable) {
            throw FailClosed("dead_object_old_track_release_failed:${t.javaClass.simpleName}")
        }
        clockWriter.deadObjectOldTrackReleaseCount = 1

        // Step 3: same-parameter replacement.
        val (newTrack, bufferBytes) = try {
            buildAudioTrack()
        } catch (f: FailClosed) {
            throw FailClosed("recreated_${f.reason}")
        } catch (t: Throwable) {
            throw FailClosed("recreated_audio_track_build_failed:${t.javaClass.simpleName}")
        }
        audioTrack = newTrack
        if (newTrack.state != AudioTrack.STATE_INITIALIZED) throw FailClosed("recreated_audio_track_not_initialized")
        clockWriter.deadObjectNewTrackInitOk = true
        clockWriter.deadObjectNewTrackBufferFrames = newTrack.bufferSizeInFrames
        clockWriter.deadObjectNewTrackSameBuffer = bufferBytes == audioTrackBufferBytes &&
            clockWriter.deadObjectNewTrackBufferFrames == audioTrackBufferFrames
        if (!clockWriter.deadObjectNewTrackSameBuffer) {
            throw FailClosed(
                "recreated_audio_track_buffer_geometry_mismatch:$bufferBytes:$audioTrackBufferBytes:" +
                    "${clockWriter.deadObjectNewTrackBufferFrames}:$audioTrackBufferFrames",
            )
        }

        // Step 4 (Y11a-prep): reapply the CURRENT EFFECTIVE gain, not config.gain — recovering
        // while ducked/silenced by a queued [requestGain] must not restore full volume.
        val recoveryGain = gainValue
        if (newTrack.setVolume(recoveryGain) != AudioTrack.SUCCESS) throw FailClosed("recreated_audio_track_set_volume_failed")
        clockWriter.deadObjectNewTrackVolumeOk = true
        gainValue = recoveryGain

        // Step 4.5 (Y12): attach the routing listener to the replacement
        // instance before play()/remainder resume, so no routing callback
        // can ever target a track without a listener across the handoff;
        // fail closed if the replacement attach itself fails.
        if (routing != null) {
            if (!routing.attach(newTrack)) {
                throw FailClosed("routing_listener_attach_failed_after_dead_object:${routing.lastAttachError}")
            }
        }

        // Step 5: play; MODE_STREAM consumes once the remainder lands.
        newTrack.play()
        val playState = newTrack.playState
        clockWriter.deadObjectNewTrackPlayState = playState
        if (playState != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("recreated_audio_track_play_failed:$playState")
        clockWriter.deadObjectNewTrackPlayOk = true

        // Step 6: the new instance's framePosition starts from 0: reset unwrap/
        // rebase, open epoch+1 at frames written so far (>= published, no clamp).
        clockWriter.resetUnwrap(0L)
        val baseFrame = framesWrittenToSink
        val nextEpoch = epochBeforeRecovery + 1
        val openOutcome = clockWriter.openEpoch(nextEpoch, baseFrame, framesWrittenToSink, framesReadFromTransport)
        clockWriter.deadObjectEpochOpenAccepted = openOutcome.accepted
        if (!openOutcome.accepted) throw FailClosed("dead_object_epoch_open_rejected:${openOutcome.name.lowercase()}")
        clockWriter.deadObjectEpochOpenedAfterRecovery = nextEpoch
        clockWriter.deadObjectBaseFrameAfterRecovery = baseFrame
        val step = baseFrame - positionBeforeRecovery
        clockWriter.deadObjectBaseStepFrames = step
        // Fails closed on sign only: the new base never falls below the last
        // published position; the magnitude (lag + lost frames) is no sink fault.
        clockWriter.deadObjectBaseStepBounded = step >= 0L
        if (!clockWriter.deadObjectBaseStepBounded) throw FailClosed("dead_object_base_below_published:$baseFrame:$positionBeforeRecovery")
        // Proof decomposition (telemetry only): step = (W - H) + (H - P); W - H
        // <= one track buffer + one mix window, H - P is the lane's lag budget.
        if (contentHead >= 0L) {
            val writtenAhead = framesWrittenAtDeadObject - contentHead
            clockWriter.deadObjectWrittenAheadOfHeadFrames = writtenAhead
            clockWriter.deadObjectPublicationLagFrames = contentHead - positionBeforeRecovery
            val lossBound = audioTrackBufferFrames.toLong() + config.maxFramesPerMix.toLong()
            clockWriter.deadObjectBaseStepDecompositionOk = writtenAhead in 0L..lossBound
        } else {
            clockWriter.deadObjectWrittenAheadOfHeadFrames = -1L
            clockWriter.deadObjectPublicationLagFrames = -1L
            clockWriter.deadObjectBaseStepDecompositionOk = false
        }

        clockWriter.deadObjectTimestampPollsDuringRecovery = clockWriter.timestampPollAttempts - pollAttemptsAtStart
        if (clockWriter.deadObjectTimestampPollsDuringRecovery != 0L) throw FailClosed("dead_object_timestamp_polled_in_recovery")
        clockWriter.deadObjectRecoveryCount = 1
        val now = SystemClock.elapsedRealtime()
        clockWriter.deadObjectRecoveryWallMs = now - recoveryStart
        lastProgressMs = now
        return newTrack
    }

    // ── Presentation clock writes (sink thread only; never fed back) ───────
    //
    // Epoch open/close, instance-frame unwrap and timestamp-poll accounting
    // live in [clockWriter] (Y10a extraction); this bridge still makes every
    // AudioTrack call and hands it only the resulting raw values.

    // The ONE poll point of a productive drain pass, after the write returned.
    // Telemetry and clock writes only; nothing downstream depends on the result.
    private fun pollTimestampOnce() {
        val parked = phaseRef.get() == Phase.PARKED
        if (!clockWriter.beginPoll(parked)) return
        val track = requireTrack()
        val available = try {
            track.getTimestamp(audioTimestamp)
        } catch (_: Throwable) {
            false
        }
        val head = rawHead()
        val honestPosition = clockWriter.recordTimestampPoll(
            available,
            audioTimestamp.framePosition and 0xFFFF_FFFFL,
            audioTimestamp.nanoTime,
            head,
            framesWrittenToSink,
            framesReadFromTransport,
            audioTrackBufferFrames,
            config.maxFramesPerMix,
        )
        // Y16: the ONLY drift-sample emission point (class comment).
        if (honestPosition) emitDriftSample() else driftSamplesSkipped++
    }

    // Y16 (sink thread only): hands the presentation clock's position just
    // published by this poll to the transport owner thread as a
    // generation-pinned drift sample. Fire-and-forget: never blocks, never
    // throws back into the drain loop, never reads the result for any
    // decision. The callback runs on the owner thread (inline only on a
    // post-dispose rejection) and only updates the atomic tallies.
    private fun emitDriftSample() {
        val reportedFrame = clockWriter.lastPositionFramesAtPoll
        val reportedPtsUs = clockWriter.lastPositionUsAtPoll
        if (reportedFrame < 0L || reportedPtsUs < 0L) {
            driftSamplesSkipped++
            return
        }
        if (driftInFlight.get() >= MAX_DRIFT_SAMPLES_IN_FLIGHT) {
            driftSamplesDropped++
            return
        }
        val machine = config.stateMachine
        val generation = machine.currentGeneration
        val postedAtNs = SystemClock.elapsedRealtimeNanos() // Kotlin-only queue latency diagnostic
        driftInFlight.incrementAndGet()
        driftLastPostedGeneration = generation
        driftSamplesPosted++
        machine.postDriftSample(
            VanguardRealtimePlaybackTransportStateMachine.DriftSampleRequest(reportedPtsUs, reportedFrame),
            expectedGeneration = generation,
        ) { result ->
            driftInFlight.decrementAndGet()
            driftCallbackCount.incrementAndGet()
            val latencyNs = SystemClock.elapsedRealtimeNanos() - postedAtNs
            driftMaxQueueLatencyNs.accumulateAndGet(latencyNs) { a, b -> if (a >= b) a else b }
            if (result.accepted) {
                driftSamplesRecorded.incrementAndGet()
                result.reply?.let { lastDriftReply = it }
            } else {
                if (result.reason == VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION) {
                    driftSamplesStaleRejected.incrementAndGet()
                } else {
                    driftSamplesOtherRejected.incrementAndGet()
                }
                driftLastRejectReason = result.reason
            }
        }
    }

    // ── Y9 flush (sink thread only, while PARKED on a seek park, once) ─────

    // Runs inside the parked wait under parkLock (request-side fields read
    // consistently). AudioTrack PAUSED before and after (flush is a no-op
    // otherwise); unwrap/rebase reset here (C4), read budget rebased (C6).
    // No timestamp poll and no clock write happen here. Y10b-1a: runs once per
    // serial seek park use (flushCount must trail seekParkCount by exactly one).
    private fun flushOnSinkThread(track: AudioTrack) {
        if (!flushRequested || flushCount != seekParkCount - 1) throw FailClosed("audio_track_flush_repeated")
        if (phaseRef.get() != Phase.PARKED) throw FailClosed("audio_track_flush_outside_parked:${phaseRef.get().name.lowercase()}")
        if (clockWriter.currentEpoch != EPOCH_NONE) throw FailClosed("audio_track_flush_with_open_epoch")
        val pollAttemptsAtStart = clockWriter.timestampPollAttempts
        val before = track.playState
        playStateBeforeFlush = before
        if (before != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("audio_track_flush_not_paused:$before")
        playbackHeadBeforeFlush = rawHead()
        noteTrackCall()
        track.flush()
        playbackHeadAfterFlush = rawHead()
        val after = track.playState
        playStateAfterFlush = after
        if (after != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("audio_track_flush_changed_play_state:$after")
        framesWrittenAtFlush = framesWrittenToSink
        framesReadAtFlush = framesReadFromTransport
        drainCallsAtFlush = drainCalls
        readBudgetFrames = framesReadAtFlush + postSeekExpectedFrames
        // The flushed instance restarts its frame position from 0.
        clockWriter.resetUnwrap(0L)
        seekUnwrapResetAtFlush = true
        flushExecutedOnSinkThread = Thread.currentThread().id == threadId
        timestampPollsDuringFlush = clockWriter.timestampPollAttempts - pollAttemptsAtStart
        val requestedAt = flushRequestedAtMs
        flushAckLatencyMs = if (requestedAt >= 0L) SystemClock.elapsedRealtime() - requestedAt else -1L
        flushCount++
        // Reset so a second serial seek park's requestFlush() is accepted (still under parkLock, called from parkOnSinkThread's loop).
        flushRequested = false
        flushAckLatch.countDown()
    }

    // ── Volume request queue application (Y11a-prep, sink thread only) ─────

    // Drains every queued [requestGain] in FIFO order, applying each with AudioTrack.setVolume
    // on this thread only: top of every drain-loop iteration and inside the parked wait, so a
    // future focus monitor can duck/restore without this bridge ever touching AudioTrack
    // off-thread. A setVolume failure fails the sink closed with a typed reason; it is never
    // thrown back to a requesting caller thread.
    private fun applyPendingGainRequests(track: AudioTrack) {
        while (true) {
            val request = gainRequestLock.withLock {
                if (pendingGainRequests.isEmpty()) null else pendingGainRequests.removeFirst()
            } ?: return
            if (track.setVolume(request.gain) != AudioTrack.SUCCESS) {
                throw FailClosed("audio_track_set_volume_request_failed:${request.seq}")
            }
            gainValue = request.gain
            gainAppliedOnSinkThread = Thread.currentThread().id == threadId
            gainAppliedCount++
            lastGainAppliedSeq = request.seq
        }
    }

    // ── Park / unpark (sink thread only) ───────────────────────────────────

    // Bounded pause park: AudioTrack.pause, ack, wait (maxPauseHoldMs) for
    // unpark, AudioTrack.play, epoch+1 at the frozen position (instance origin
    // there). Seek park (Y9 / Y10b-1a): same to the ack; wait capped by
    // maxSeekHoldMs, one flush runs inside it (up to [MAX_SEEK_PARKS] serial
    // uses), unpark opens epoch+1 at T (origin 0).
    private fun parkOnSinkThread() {
        val track = requireTrack()
        if (!played) throw FailClosed("park_before_first_play")
        parkExecutedOnSinkThread = Thread.currentThread().id == threadId
        val seekPark = seekParkRequested
        if (seekPark) {
            if (seekParkCount != flushCount || seekParkCount >= MAX_SEEK_PARKS) throw FailClosed("seek_park_repeated")
            seekParkCount++
        }

        track.pause()
        val pausedState = track.playState
        playStateAtPark = pausedState
        if (pausedState != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("audio_track_pause_failed:$pausedState")
        playbackHeadAtPark = rawHead()

        // Freeze: the published position is the next epoch's base/origin; the epoch closes.
        val snap = clockWriter.snapshotAtPark()
        positionAtPark = snap.positionFrames
        epochClosedAtPark = clockWriter.currentEpoch
        clockWriter.closeIfOpen()

        val parkedAtMs = SystemClock.elapsedRealtime()
        val requestedAt = parkRequestedAtMs
        parkAckLatencyMs = if (requestedAt >= 0L) parkedAtMs - requestedAt else -1L
        parkCount++
        phaseRef.set(Phase.PARKED)
        parkAckLatch.countDown()

        val holdCapMs = if (seekPark) config.maxSeekHoldMs else config.maxPauseHoldMs
        parkHoldCapMs = holdCapMs
        val holdCapAtMs = parkedAtMs + holdCapMs
        val holdExceededReason = if (seekPark) EXIT_SEEK_HOLD_EXCEEDED else EXIT_PAUSE_HOLD_EXCEEDED
        parkLock.withLock {
            while (true) {
                // Y11a-prep: queued volume targets apply even while parked.
                applyPendingGainRequests(track)
                // A requested flush always executes before an unpark is honoured.
                if (flushRequested && flushCount == seekParkCount - 1) flushOnSinkThread(track)
                if (unparkRequested) break
                if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
                val now = SystemClock.elapsedRealtime()
                if (now > config.deadlineAtMs) throw FailClosed(EXIT_DEADLINE)
                if (now > holdCapAtMs) throw FailClosed("$holdExceededReason:${now - parkedAtMs}")
                try {
                    parkCondition.await(PARK_POLL_MS, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw FailClosed("interrupted_while_parked")
                }
                if (track.playState != AudioTrack.PLAYSTATE_PAUSED) parkedPlayStateViolations++
            }
            unparkRequested = false
            // This use's flush already acked (unpark() guard); free the flag for a possible next serial seek park.
            if (seekPark) seekParkRequested = false
        }

        playbackHeadAtUnpark = rawHead()
        track.play()
        val playingState = track.playState
        playStateAfterUnpark = playingState
        unparkExecutedOnSinkThread = Thread.currentThread().id == threadId
        if (playingState != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("audio_track_resume_play_failed:$playingState")
        val nextEpoch = epochClosedAtPark + 1
        if (seekPark) {
            // Same instance, flushed: epoch+1 opens at T, a deliberate
            // discontinuity from the frozen position, over instance origin 0.
            if (flushCount != seekParkCount) throw FailClosed("seek_unpark_without_flush:$flushCount:$seekParkCount")
            val target = seekTargetFrame
            if (target < 0L) throw FailClosed("seek_unpark_without_target")
            val backward = seekDeclaredBackward
            if (backward) {
                // Y17: the content-domain backward claim (class comment); the
                // clock-domain step against positionAtPark may have either sign.
                if (target >= framesWrittenAtFlush) throw FailClosed("backward_seek_target_not_below_written:$target:$framesWrittenAtFlush")
            } else if (target < positionAtPark) {
                throw FailClosed("seek_target_below_position_at_park:$target:$positionAtPark")
            }
            playbackHeadAtSeekUnpark = playbackHeadAtUnpark
            clockWriter.setOrigin(0L)
            val outcome = if (backward) {
                clockWriter.openEpochDeclaredBackward(nextEpoch, target, framesWrittenToSink, framesReadFromTransport)
            } else {
                clockWriter.openEpoch(nextEpoch, target, framesWrittenToSink, framesReadFromTransport)
            }
            seekEpochOpenAccepted = outcome.accepted
            seekEpochOpenedAtUnpark = nextEpoch
            seekEpochBaseFrame = target
            seekDiscontinuityFrames = target - positionAtPark
        } else {
            // Same AudioTrack instance, new clock epoch based at the frozen position.
            clockWriter.setOrigin(positionAtPark)
            clockWriter.openEpoch(nextEpoch, positionAtPark, framesWrittenToSink, framesReadFromTransport)
        }
        epochRawOriginAtUnpark = if (seekPark) 0L else positionAtPark
        epochOpenedAtUnpark = nextEpoch
        val now = SystemClock.elapsedRealtime()
        parkedHoldMs = now - parkedAtMs
        unparkCount++
        lastProgressMs = now
        phaseRef.set(Phase.RUNNING)
        unparkAckLatch.countDown()
    }

    // ── Drain loop ─────────────────────────────────────────────────────────

    private fun drainLoop() {
        val bytesPerFrame = 2 * config.channelCount
        val drainFrames = config.maxFramesPerMix
        val drainBuffer = ByteBuffer.allocateDirect(drainFrames * bytesPerFrame).order(ByteOrder.nativeOrder())
        val maxProductiveDrains = (config.declaredFrameCount / drainFrames + 1L) * DRAIN_ITERATION_SLACK +
            DRAIN_ITERATION_MARGIN
        // C6: read budget = declared until a seek flush rebases it.
        readBudgetFrames = config.declaredFrameCount
        lastProgressMs = SystemClock.elapsedRealtime()
        while (true) {
            checkDeadlineAndCancel()
            // Y11a-prep: apply any queued volume targets before this pass drains/writes.
            applyPendingGainRequests(requireTrack())
            if (phaseRef.get() == Phase.PARK_REQUESTED) parkOnSinkThread()
            clockWriter.resetPassCounter()
            if (drainFrames != config.maxFramesPerMix) drainRequestSizeChanges++
            if (firstDrainAtMs < 0L) firstDrainAtMs = SystemClock.elapsedRealtime()
            val res = config.stateMachine.drain(drainBuffer, drainFrames)
            drainCalls++
            if (!res.accepted) throw FailClosed("drain_rejected:${res.reason}")
            val reply = res.reply ?: throw FailClosed("drain_null_reply")
            lastReply = reply
            val framesRead = reply.framesRead.toInt()
            if (framesRead > 0) {
                if (framesRead > drainFrames) throw FailClosed("drain_overflow:$framesRead")
                if (reply.bytesRead != framesRead.toLong() * bytesPerFrame) throw FailClosed("drain_bytes_read_mismatch:${reply.bytesRead}")
                if (++productiveDrainPasses > maxProductiveDrains) throw FailClosed("drain_iteration_budget_exhausted")
                if (framesReadFromTransport + framesRead > readBudgetFrames) {
                    throw FailClosed("drain_exceeds_read_budget:${framesReadFromTransport + framesRead}:$readBudgetFrames")
                }
                accumulateChecksum(drainBuffer, framesRead)
                framesReadFromTransport += framesRead
                writeAllToAudioTrack(drainBuffer, framesRead * bytesPerFrame, bytesPerFrame)
                if (!played) {
                    val track = requireTrack()
                    track.play()
                    val state = track.playState
                    initialPlayState = state
                    if (state != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("audio_track_initial_play_failed:$state")
                    played = true
                    // Epoch 0 opens only now: play succeeded on the first productive write.
                    clockWriter.setOrigin(0L)
                    clockWriter.openEpoch(0, 0L, framesWrittenToSink, framesReadFromTransport)
                }
                pollTimestampOnce()
                lastProgressMs = SystemClock.elapsedRealtime()
            } else {
                if (reply.eosDrained) {
                    eosDrainedObserved = true
                    clockWriter.recordPositionAtEos()
                    break
                }
                emptyDrainCount++
                if (SystemClock.elapsedRealtime() - lastProgressMs > DRAIN_STALL_TIMEOUT_MS) {
                    throw FailClosed("drain_stalled:${config.stateMachine.currentState.name.lowercase()}")
                }
                SystemClock.sleep(DRAIN_STALL_SLEEP_MS)
                continue
            }
            if (reply.eosDrained) {
                eosDrainedObserved = true
                clockWriter.recordPositionAtEos()
                break
            }
        }
        if (!played) throw FailClosed("no_frames_written_to_sink")
    }

    // Sink thread; exactly once on every exit path. Nulled first so a throwing release is never retried.
    private fun releaseAudioTrackOnce() {
        val track = audioTrack ?: return
        audioTrack = null
        if (releaseCounter.get() > 0) return
        // Y12: release/detach the routing controller before this AudioTrack
        // is stopped/released (class comment); idempotent even if the
        // owning session already released the SAME controller.
        config.routingController?.release()
        releaseExecutedOnSinkThread = Thread.currentThread().id == threadId
        try {
            playbackHeadFinal = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        } catch (_: Throwable) {}
        try { track.stop() } catch (_: Throwable) {}
        try { track.release() } catch (_: Throwable) {}
        releaseCounter.incrementAndGet()
    }
}
