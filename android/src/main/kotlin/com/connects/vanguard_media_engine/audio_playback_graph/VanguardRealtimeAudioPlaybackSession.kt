package com.connects.vanguard_media_engine.audio_playback_graph

import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State as TransportState
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

// ── VanguardRealtimeAudioPlaybackSession (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK, Y8a) ─
//
// Production engine owner of one realtime audio playback:
//   MediaExtractor/MediaCodec ([VanguardRealtimePlaybackDecoderFeed], decode
//   thread) -> Y5a external ingest -> Y1 native transport (owner
//   HandlerThread inside [VanguardRealtimePlaybackTransportStateMachine]) ->
//   [VanguardRealtimeAudioPlaybackSinkBridge] (sink thread: AudioTrack +
//   presentation clock).
// Ownership: the decoder feed thread only posts generation-pinned ingest;
// the transport HandlerThread only owns the native session; the sink thread
// only owns the AudioTrack and the clock writes; THIS session (caller's
// thread, serialized by one lock) is the only transport command issuer. No
// MethodChannel, product, editor or app code lives here.
//
// Lifecycle: IDLE -start-> STARTING -> PLAYING <-> PAUSED (bounded) ->
// COMPLETED (sink drained EOS) / STOPPED (stop) / FAILED (first failure
// wins) -> DISPOSED (idempotent). Start: format probe, load, prepare, attach
// feed, pre-roll while PREPARED, sink READY before transport start,
// transport start, then sink drain allowed. Bounded pause: sink park -> ack
// (AudioTrack paused, clock epoch closed at the last published position) ->
// transport.pause; resume: transport.resume -> sink unpark -> ack (same
// instance, new clock epoch). A hold longer than [Config.maxPauseHoldMs]
// fails closed inside the sink (AudioTrack released, decoder cancelled via
// [onSinkExited]), below the decoder feed's own ingest stall budget.
// Stop/dispose: sink cancel, decoder cancel, bounded joins, transport stop
// (only after both threads exited), terminal snapshot, transport dispose
// exactly once. Dead object (Y8b): only the sink's ONE armed synthetic
// ERROR_DEAD_OBJECT ([Config.syntheticDeadObjectInjectAfterFrames] > 0,
// default off) is recovered, inside the sink thread's write loop; a real
// or second dead object exits the sink non-EOS and fails closed here.
//
// Seek (Y9, P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK), default OFF: with
// [Config.seekTargetSec] > 0, start admits ONE forward seek (C10: preRoll <
// H < T < declared - 2 windows, H = first window boundary at least
// [Config.preSeekHoldWindows] windows past the pre-roll) and pins H on the
// feed before the transport starts. [seek] runs PLAYING -> SEEKING ->
// PLAYING under the command lock in this fixed order (one *Locked step
// each): initial writes -> quiescence at H (feed held, sink read H,
// transport PLAYING, sink RUNNING) -> sink seek park -> pre-seek native
// snapshot (sink PARKED, transport PLAYING, position == pushed == drained
// == H, discarded 0, output ring empty) -> transport.pause + PAUSED
// recheck -> AudioTrack.flush once on the sink thread (read budget H +
// declared - T) -> transport.seek(T) (stays PAUSED, generation + 1, cursor
// T, nothing discarded) -> feed re-anchor on the decode thread with the
// deliberate stale-generation probe rejected before JNI -> post-seek
// pre-roll while still PAUSED (pushed unchanged at H) -> sink unpark
// (AudioTrack.play, clock epoch+1 based at T) -> transport.resume. Any
// rejection, timeout, exited thread, cancel or accounting divergence fails
// closed through the common teardown; cancel/dispose mid-seek use the
// existing bounded-wait wake-ups; a second seek is rejected without teardown.
// The seek bookkeeping is published as [VanguardRealtimeAudioPlaybackSeekObservation].
class VanguardRealtimeAudioPlaybackSession(private val config: Config) {

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 3.0,
        val maxFramesPerMix: Int = 256,
        val gain: Float = VanguardRealtimeAudioPlaybackSinkBridge.DEFAULT_GAIN,
        val deadlineMs: Long = 30_000L,
        val maxPauseHoldMs: Long = DEFAULT_MAX_PAUSE_HOLD_MS,
        val threadNamePrefix: String = "VanguardRealtimeAudio",
        // Y8b diagnostic seam, default OFF (0): forwarded to the sink; see
        // [VanguardRealtimeAudioPlaybackSinkBridge.Config].
        val syntheticDeadObjectInjectAfterFrames: Long = 0L,
        // Y9 seek arming, default OFF (0.0): the ONE forward seek target in
        // seconds; must stay below maxDurationSec. Admitted against the
        // probed format at start.
        val seekTargetSec: Double = 0.0,
        // Y9: windows fed after the pre-roll before the feed holds at H.
        val preSeekHoldWindows: Int = DEFAULT_PRE_SEEK_HOLD_WINDOWS,
        // Y9: hard cap on the sink's seek park (distinct from the pause cap).
        val maxSeekHoldMs: Long = DEFAULT_MAX_SEEK_HOLD_MS,
    )

    enum class State { IDLE, STARTING, PLAYING, PAUSED, SEEKING, COMPLETED, STOPPED, FAILED, DISPOSED }

    data class CommandResult(val accepted: Boolean, val state: State, val reason: String)

    // Any-thread, immutable view for diagnostics/reporting.
    data class Snapshot(
        val state: State,
        val generation: Long,
        val failureReason: String,
        val cancelled: Boolean,
        val format: VanguardRealtimePlaybackDecoderFeed.Format?,
        val transportState: TransportState?,
        val transportGeneration: Long,
        val transportTransitions: String,
        val transportCompletedCallbacks: Int,
        val transportFailedCallbacks: Int,
        val listenerCallbacksOnOwner: Long,
        val listenerCallbacksOffOwner: Long,
        val commandsIssued: Int,
        val prepareGeneration: Long,
        val startGeneration: Long,
        val pauseGeneration: Long,
        val resumeGeneration: Long,
        val startAccepted: Boolean,
        val pauseAccepted: Boolean,
        val resumeAccepted: Boolean,
        val transportStopAccepted: Boolean,
        val transportStateBeforeDispose: TransportState?,
        val transportStateAfterDispose: TransportState?,
        val transportDisposeCalls: Int,
        val preRollFrames: Long,
        val preRollRingFullObserved: Boolean,
        val preRollStatePrepared: Boolean,
        val sinkReadyBeforeTransportStart: Boolean,
        val drainAllowedAfterTransportStart: Boolean,
        val sinkReadyAtMs: Long,
        val transportStartAtMs: Long,
        val drainAllowedAtMs: Long,
        val pauseRequestedAtMs: Long,
        val pauseAckedAtMs: Long,
        val resumedAtMs: Long,
        val pauseHoldObservedMs: Long,
        val clockAtPauseAck: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        val clockBeforeResume: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        val clockAfterResume: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        val clock: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        val sink: VanguardRealtimeAudioPlaybackSinkTelemetry?,
        val decoderExitReason: String,
        val decoderThreadId: Long,
        val decoderThreadIsTransportOwner: Boolean,
        val decoderAcceptedFrames: Long,
        val decoderPaddedFrames: Long,
        val decoderChecksumHex: String,
        val decoderMediaReleaseCount: Long,
        val decoderMediaReleaseClean: Boolean,
        val decoderIngestCallbacksOnOwner: Long,
        val decoderIngestCallbacksOffOwner: Long,
        val decoderIngestCalls: Long,
        val decoderCancelRequested: Boolean,
        val decoderJoined: Boolean,
        val sinkJoined: Boolean,
        val terminalReply: Reply?,
        val sessionWallMs: Long,
        val seek: VanguardRealtimeAudioPlaybackSeekObservation,
    )

    companion object {
        const val DEFAULT_MAX_PAUSE_HOLD_MS = VanguardRealtimeAudioPlaybackSinkBridge.DEFAULT_MAX_PAUSE_HOLD_MS
        const val DEFAULT_MAX_SEEK_HOLD_MS = VanguardRealtimeAudioPlaybackSinkBridge.DEFAULT_MAX_SEEK_HOLD_MS
        const val DEFAULT_PRE_SEEK_HOLD_WINDOWS = 64
        const val MAX_PRE_SEEK_HOLD_WINDOWS = 1_024
        const val REASON_OK = "ok"
        private const val WAIT_SLICE_MS = 5L
        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val SINK_READY_TIMEOUT_MS = 5_000L
        private const val PARK_ACK_TIMEOUT_MS = 2_000L
        private const val UNPARK_ACK_TIMEOUT_MS = 2_000L

        private fun alignUp(frame: Long, window: Long): Long = ((frame + window - 1L) / window) * window
    }

    private class FailClosed(val reason: String) : Exception(reason)

    private val commandLock = ReentrantLock()
    private val cancelled = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)
    private val teardownDone = AtomicBoolean(false)
    private val failure = AtomicReference<String?>(null)
    private val completedCount = AtomicInteger(0)
    private val failedCount = AtomicInteger(0)
    private val listenerOnOwner = AtomicLong(0L)
    private val listenerOffOwner = AtomicLong(0L)
    private val transitions = StringBuilder()

    @Volatile private var state = State.IDLE
    @Volatile private var generation = 0L
    @Volatile private var transport: VanguardRealtimePlaybackTransportStateMachine? = null
    @Volatile private var feed: VanguardRealtimePlaybackDecoderFeed? = null
    @Volatile private var sink: VanguardRealtimeAudioPlaybackSinkBridge? = null
    @Volatile private var format: VanguardRealtimePlaybackDecoderFeed.Format? = null
    @Volatile private var deadlineAtMs = Long.MAX_VALUE
    @Volatile private var decoderCancelRequested = false

    // Command-lock-confined bookkeeping (published through snapshot()).
    @Volatile private var commandsIssued = 0
    @Volatile private var prepareGeneration = -1L
    @Volatile private var startGeneration = -1L
    @Volatile private var pauseGeneration = -1L
    @Volatile private var resumeGeneration = -1L
    @Volatile private var startAccepted = false
    @Volatile private var pauseAccepted = false
    @Volatile private var resumeAccepted = false
    @Volatile private var transportStopAccepted = false
    @Volatile private var transportStateBeforeDispose: TransportState? = null
    @Volatile private var transportStateAfterDispose: TransportState? = null
    @Volatile private var transportDisposeCalls = 0
    @Volatile private var preRollFrames = 0L
    @Volatile private var preRollRingFullObserved = false
    @Volatile private var preRollStatePrepared = false
    @Volatile private var sinkReadyAtMs = -1L
    @Volatile private var transportStartAtMs = -1L
    @Volatile private var drainAllowedAtMs = -1L
    @Volatile private var pauseRequestedAtMs = -1L
    @Volatile private var pauseAckedAtMs = -1L
    @Volatile private var resumedAtMs = -1L
    @Volatile private var pauseHoldObservedMs = -1L
    @Volatile private var clockAtPauseAck: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
    @Volatile private var clockBeforeResume: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
    @Volatile private var clockAfterResume: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
    @Volatile private var decoderJoined = false
    @Volatile private var sinkJoined = false
    @Volatile private var terminalReply: Reply? = null
    @Volatile private var sessionStartedAtMs = -1L
    @Volatile private var sessionWallMs = 0L

    // Y9 seek admission bookkeeping (command-lock holder writes); the step
    // sequence and its own bookkeeping live in [seekSequencer].
    @Volatile private var seekArmed = false
    @Volatile private var seekTargetFrame = -1L
    @Volatile private var preSeekHoldFrame = -1L
    @Volatile private var seekAdmissionOk = false
    @Volatile private var seekHoldPinned = false
    @Volatile private var seekCount = 0

    // Y10a: extracted Y9 seek step sequence; runs synchronously under this
    // session's command lock, on the caller's thread (see [seek]).
    private val seekSequencer = VanguardRealtimeAudioPlaybackSeekSequencer(
        VanguardRealtimeAudioPlaybackSeekSequencer.Config(maxFramesPerMix = config.maxFramesPerMix),
        object : VanguardRealtimeAudioPlaybackSeekSequencer.Host {
            override fun pollSeekWaitReason(): String? {
                if (cancelled.get()) return "cancelled"
                if (SystemClock.elapsedRealtime() > deadlineAtMs) return "deadline_exceeded"
                return failure.get()
            }

            override fun noteCommandIssued() {
                commandsIssued++
            }

            override val startGeneration: Long get() = this@VanguardRealtimeAudioPlaybackSession.startGeneration
        },
    )

    val currentState: State get() = state
    val failureReason: String get() = failure.get() ?: ""

    private val listener = object : VanguardRealtimePlaybackTransportStateMachine.Listener {
        override fun onStateChanged(previous: TransportState, current: TransportState, generation: Long) {
            countListener()
            synchronized(transitions) {
                if (transitions.isEmpty()) transitions.append(previous.name)
                transitions.append('>').append(current.name)
            }
        }

        override fun onCompleted(generation: Long) {
            countListener()
            completedCount.incrementAndGet()
        }

        override fun onFailed(reason: String, generation: Long) {
            countListener()
            failedCount.incrementAndGet()
            recordFailure("transport:$reason")
        }

        private fun countListener() {
            val t = transport
            if (t != null && t.isOwnerThread) listenerOnOwner.incrementAndGet() else listenerOffOwner.incrementAndGet()
        }
    }

    // ── Commands (caller thread, serialized) ───────────────────────────────

    // Probe -> load/prepare -> attach -> pre-roll -> (seek armed: admit and
    // pin the hold frame) -> sink READY -> transport start -> sink drain
    // allowed. Any failure tears down and reports it.
    fun start(): CommandResult = commandLock.withLock {
        if (state != State.IDLE) return reject("invalid_state_${state.name.lowercase()}")
        if (config.sourcePath.isBlank()) return failClosed("source_path_required")
        if (config.maxDurationSec <= 0.0 ||
            config.maxDurationSec > VanguardRealtimePlaybackDecoderFeed.HARD_MAX_DURATION_SEC
        ) {
            return failClosed("invalid_max_duration")
        }
        if (config.maxFramesPerMix <= 0 ||
            config.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP
        ) {
            return failClosed("invalid_max_frames_per_mix")
        }
        if (!(config.gain > 0f) || config.gain > 1f) return failClosed("invalid_gain")
        if (config.deadlineMs <= 0L) return failClosed("invalid_deadline")
        if (config.maxPauseHoldMs <= 0L) return failClosed("invalid_max_pause_hold")
        if (config.maxSeekHoldMs <= 0L) return failClosed("invalid_max_seek_hold")
        if (config.syntheticDeadObjectInjectAfterFrames < 0L) return failClosed("invalid_dead_object_inject_after_frames")
        if (config.seekTargetSec < 0.0 || config.seekTargetSec.isNaN() || config.seekTargetSec >= config.maxDurationSec) {
            return failClosed("invalid_seek_target")
        }
        if (config.preSeekHoldWindows <= 0 || config.preSeekHoldWindows > MAX_PRE_SEEK_HOLD_WINDOWS) {
            return failClosed("invalid_pre_seek_hold_windows")
        }
        state = State.STARTING
        generation++
        sessionStartedAtMs = SystemClock.elapsedRealtime()
        deadlineAtMs = sessionStartedAtMs + config.deadlineMs
        try {
            openAndStartLocked()
            state = State.PLAYING
            accept()
        } catch (f: FailClosed) {
            failClosed(f.reason)
        } catch (t: Throwable) {
            failClosed("exception:${t.javaClass.simpleName}:${t.message}")
        }
    }

    private fun openAndStartLocked() {
        val f = VanguardRealtimePlaybackDecoderFeed(
            VanguardRealtimePlaybackDecoderFeed.Config(
                sourcePath = config.sourcePath,
                maxDurationSec = config.maxDurationSec,
                maxFramesPerMix = config.maxFramesPerMix,
                deadlineAtMs = deadlineAtMs,
                threadName = "${config.threadNamePrefix}DecoderFeed",
                externallyCancelled = { cancelled.get() },
            ),
        )
        feed = f
        if (!f.start()) throw FailClosed("feed_start_rejected")
        val fmt = f.awaitFormat(remainingMs()) ?: throw FailClosed("format_probe_failed:${f.exitReason}")
        format = fmt
        checkDeadlineAndCancel()

        val sessionConfig = VanguardRealtimePlaybackNativeSession.Config(
            sampleRate = fmt.sampleRate,
            channelCount = fmt.channelCount,
            maxFramesPerMix = config.maxFramesPerMix,
            trackCount = VanguardRealtimePlaybackDecoderFeed.TRACK_COUNT,
            declaredFrameCount = fmt.declaredFrameCount,
            externalIngestTrackMask = VanguardRealtimePlaybackDecoderFeed.EXTERNAL_INGEST_TRACK_MASK,
        )
        VanguardRealtimePlaybackNativeSession.validate(sessionConfig)?.let {
            throw FailClosed("session_config_invalid:${it.name.lowercase()}")
        }
        val machine = VanguardRealtimePlaybackTransportStateMachine(
            sessionConfig, listener, threadName = "${config.threadNamePrefix}Transport",
        )
        transport = machine

        val loadRes = machine.load()
        commandsIssued++
        if (!loadRes.accepted) throw FailClosed("load_rejected:${loadRes.reason}")
        val prepareRes = machine.prepare()
        commandsIssued++
        if (!prepareRes.accepted || prepareRes.state != TransportState.PREPARED) {
            throw FailClosed("prepare_rejected:${prepareRes.reason}")
        }
        prepareGeneration = machine.currentGeneration
        f.attachTransport(machine, prepareGeneration)

        while (!f.awaitPreRoll(WAIT_SLICE_MS)) {
            checkDeadlineAndCancel()
            failure.get()?.let { throw FailClosed(it) }
            if (!f.isAlive) throw FailClosed("feed_exited_during_preroll:${f.exitReason}")
        }
        preRollFrames = f.preRollFrames
        preRollRingFullObserved = f.preRollRingFullObserved
        preRollStatePrepared = machine.currentState == TransportState.PREPARED
        if (preRollFrames <= 0L) throw FailClosed("preroll_empty:${f.exitReason}")

        // Y9 seek admission (C10) and hold pin before the transport starts:
        // H = first window-aligned frame >= preRoll + preSeekHoldWindows windows.
        if (config.seekTargetSec > 0.0) {
            val window = config.maxFramesPerMix.toLong()
            val declared = fmt.declaredFrameCount
            val target = (config.seekTargetSec * fmt.sampleRate).toLong()
            val hold = alignUp(preRollFrames + config.preSeekHoldWindows.toLong() * window, window)
            seekArmed = true
            seekTargetFrame = target
            preSeekHoldFrame = hold
            seekAdmissionOk = hold % window == 0L && hold > preRollFrames && hold < target &&
                target < declared - 2L * window
            if (!seekAdmissionOk) {
                throw FailClosed("seek_admission:preroll=$preRollFrames:hold=$hold:target=$target:declared=$declared")
            }
            seekHoldPinned = f.setPreSeekHoldFrame(hold)
            if (!seekHoldPinned) throw FailClosed("seek_hold_pin_rejected:$hold")
        }

        // Sink exists and is READY (AudioTrack created, gain set) before the
        // transport starts; it only drains after allowDrain().
        val s = VanguardRealtimeAudioPlaybackSinkBridge(
            VanguardRealtimeAudioPlaybackSinkBridge.Config(
                stateMachine = machine,
                sampleRate = fmt.sampleRate,
                channelCount = fmt.channelCount,
                maxFramesPerMix = config.maxFramesPerMix,
                declaredFrameCount = fmt.declaredFrameCount,
                gain = config.gain,
                maxPauseHoldMs = config.maxPauseHoldMs,
                maxSeekHoldMs = config.maxSeekHoldMs,
                deadlineAtMs = deadlineAtMs,
                threadName = "${config.threadNamePrefix}Sink",
                externallyCancelled = { cancelled.get() },
                onExited = { reason -> onSinkExited(reason) },
                syntheticDeadObjectInjectAfterFrames = config.syntheticDeadObjectInjectAfterFrames,
            ),
        )
        sink = s
        if (!s.start()) throw FailClosed("sink_start_rejected")
        val readyDeadline = SystemClock.elapsedRealtime() + SINK_READY_TIMEOUT_MS
        while (!s.awaitReady(WAIT_SLICE_MS)) {
            checkDeadlineAndCancel()
            failure.get()?.let { throw FailClosed(it) }
            if (!s.isAlive) throw FailClosed("sink_exited_before_ready:${s.currentExitReason}")
            if (SystemClock.elapsedRealtime() > readyDeadline) throw FailClosed("sink_ready_timeout")
        }
        sinkReadyAtMs = SystemClock.elapsedRealtime()

        val startRes = machine.start()
        commandsIssued++
        transportStartAtMs = SystemClock.elapsedRealtime()
        startAccepted = startRes.accepted && startRes.state == TransportState.PLAYING
        if (!startAccepted) throw FailClosed("start_rejected:${startRes.reason}")
        startGeneration = machine.currentGeneration
        f.updateGeneration(startGeneration)
        f.markTransportStarted()
        s.allowDrain()
        drainAllowedAtMs = SystemClock.elapsedRealtime()
    }

    // Sink park -> ack -> transport.pause. The hold is bounded by the sink.
    fun pauseBounded(): CommandResult = commandLock.withLock {
        if (state != State.PLAYING) return reject("invalid_state_${state.name.lowercase()}")
        failure.get()?.let { return failClosed(it) }
        val s = sink ?: return failClosed("sink_missing")
        val machine = transport ?: return failClosed("transport_missing")
        try {
            pauseRequestedAtMs = SystemClock.elapsedRealtime()
            if (!s.requestPark()) throw FailClosed("sink_park_rejected:${s.phase.name.lowercase()}")
            val ackDeadline = pauseRequestedAtMs + PARK_ACK_TIMEOUT_MS
            while (!s.awaitParked(WAIT_SLICE_MS)) {
                checkDeadlineAndCancel()
                failure.get()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_park_ack:${s.currentExitReason}")
                if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_park_ack_timeout")
            }
            pauseAckedAtMs = SystemClock.elapsedRealtime()
            clockAtPauseAck = s.clockSnapshot()
            val res = machine.pause()
            commandsIssued++
            pauseAccepted = res.accepted && res.state == TransportState.PAUSED
            pauseGeneration = machine.currentGeneration
            if (!pauseAccepted) throw FailClosed("pause_rejected:${res.reason}")
            state = State.PAUSED
            accept()
        } catch (f: FailClosed) {
            failClosed(f.reason)
        } catch (t: Throwable) {
            failClosed("exception:${t.javaClass.simpleName}:${t.message}")
        }
    }

    // transport.resume -> sink unpark -> ack (AudioTrack.play, new epoch).
    fun resume(): CommandResult = commandLock.withLock {
        if (state != State.PAUSED) return reject("invalid_state_${state.name.lowercase()}")
        failure.get()?.let { return failClosed(it) }
        val s = sink ?: return failClosed("sink_missing")
        val machine = transport ?: return failClosed("transport_missing")
        try {
            if (!s.isAlive) throw FailClosed("sink_exited_during_pause:${s.currentExitReason}")
            clockBeforeResume = s.clockSnapshot()
            val res = machine.resume()
            commandsIssued++
            resumeAccepted = res.accepted && res.state == TransportState.PLAYING
            resumeGeneration = machine.currentGeneration
            if (!resumeAccepted) throw FailClosed("resume_rejected:${res.reason}")
            val unparkAt = SystemClock.elapsedRealtime()
            if (!s.unpark()) throw FailClosed("sink_unpark_rejected:${s.phase.name.lowercase()}")
            val ackDeadline = unparkAt + UNPARK_ACK_TIMEOUT_MS
            while (!s.awaitRunning(WAIT_SLICE_MS)) {
                checkDeadlineAndCancel()
                failure.get()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_unpark_ack:${s.currentExitReason}")
                if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_unpark_ack_timeout")
            }
            resumedAtMs = SystemClock.elapsedRealtime()
            pauseHoldObservedMs = resumedAtMs - pauseAckedAtMs
            clockAfterResume = s.clockSnapshot()
            state = State.PLAYING
            accept()
        } catch (f: FailClosed) {
            failClosed(f.reason)
        } catch (t: Throwable) {
            failClosed("exception:${t.javaClass.simpleName}:${t.message}")
        }
    }

    // Y9: the ONE armed forward seek (targetFrame must equal the armed target),
    // PLAYING -> SEEKING -> PLAYING in the class-comment order. Not PLAYING, not
    // armed, repeated or foreign target: rejected without teardown.
    fun seek(targetFrame: Long): CommandResult = commandLock.withLock {
        if (state != State.PLAYING) return reject("invalid_state_${state.name.lowercase()}")
        if (!seekArmed || !seekHoldPinned) return reject("seek_not_armed")
        if (seekCount != 0) return reject("seek_repeated")
        if (targetFrame != seekTargetFrame) return reject("seek_target_mismatch:$targetFrame:$seekTargetFrame")
        failure.get()?.let { return failClosed(it) }
        val s = sink ?: return failClosed("sink_missing")
        val f = feed ?: return failClosed("feed_missing")
        val machine = transport ?: return failClosed("transport_missing")
        val fmt = format ?: return failClosed("format_missing")
        seekCount = 1
        state = State.SEEKING
        val reason = seekSequencer.run(s, f, machine, fmt.declaredFrameCount, preSeekHoldFrame, seekTargetFrame)
        if (reason == null) {
            state = State.PLAYING
            accept()
        } else {
            failClosed(reason)
        }
    }

    // Any state. Tears the pipeline down (sink, decoder, transport) once.
    fun stop(): CommandResult = commandLock.withLock {
        if (state == State.DISPOSED) return reject("disposed")
        if (state == State.IDLE) {
            state = State.STOPPED
            return accept()
        }
        teardownLocked()
        state = if (failure.get() != null) State.FAILED else State.STOPPED
        CommandResult(failure.get() == null, state, failure.get() ?: REASON_OK)
    }

    // Idempotent; any state.
    fun dispose() {
        commandLock.withLock {
            if (!disposed.compareAndSet(false, true)) return
            if (state != State.IDLE) teardownLocked()
            state = State.DISPOSED
        }
    }

    // Lock-free, any thread: every bounded wait (decoder, sink, command
    // loops) observes the flag; the command in flight fails closed with
    // "cancelled" and tears down on its own thread. Never blocks.
    fun cancel() {
        cancelled.set(true)
        sink?.cancel()
        feed?.cancel()
    }

    // ── Waits (any thread; lock-free) ──────────────────────────────────────

    // True once the AudioTrack played real frames and clock epoch 0 is open.
    fun awaitFirstAudio(timeoutMs: Long): Boolean {
        val until = SystemClock.elapsedRealtime() + timeoutMs
        while (true) {
            val s = sink ?: return false
            if (s.hasPlayed && s.framesWritten > 0L && s.clockSnapshot().epochOpen) return true
            if (pollFailure() != null || !s.isAlive) return false
            if (SystemClock.elapsedRealtime() > until) return false
            sleepSlice()
        }
    }

    // True when the sink drained EOS and the decoder exited at EOS; the
    // session then publishes COMPLETED (transport left alive until stop).
    fun awaitCompletion(timeoutMs: Long): Boolean {
        val until = SystemClock.elapsedRealtime() + timeoutMs
        val s = sink ?: return false
        val f = feed ?: return false
        while (!s.awaitExit(WAIT_SLICE_MS)) {
            if (pollFailure() != null) return false
            if (SystemClock.elapsedRealtime() > until) return false
        }
        if (s.currentExitReason != VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS) return false
        if (!f.awaitExit(maxOf(1L, until - SystemClock.elapsedRealtime()))) return false
        if (f.exitReason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS) {
            recordFailure("decoder:${f.exitReason}")
            return false
        }
        if (pollFailure() != null) return false
        commandLock.withLock {
            if (state == State.PLAYING || state == State.PAUSED) state = State.COMPLETED
        }
        return state == State.COMPLETED
    }

    // ── Snapshot / metrics (any thread) ────────────────────────────────────

    fun snapshot(): Snapshot {
        pollFailure()
        val f = feed
        val s = sink
        val machine = transport
        val wall = if (sessionStartedAtMs < 0L) 0L else if (sessionWallMs > 0L) sessionWallMs else SystemClock.elapsedRealtime() - sessionStartedAtMs
        return Snapshot(
            state = state,
            generation = generation,
            failureReason = failure.get() ?: "",
            cancelled = cancelled.get(),
            format = format,
            transportState = machine?.currentState,
            transportGeneration = machine?.currentGeneration ?: -1L,
            transportTransitions = synchronized(transitions) { transitions.toString() },
            transportCompletedCallbacks = completedCount.get(),
            transportFailedCallbacks = failedCount.get(),
            listenerCallbacksOnOwner = listenerOnOwner.get(),
            listenerCallbacksOffOwner = listenerOffOwner.get(),
            commandsIssued = commandsIssued,
            prepareGeneration = prepareGeneration,
            startGeneration = startGeneration,
            pauseGeneration = pauseGeneration,
            resumeGeneration = resumeGeneration,
            startAccepted = startAccepted,
            pauseAccepted = pauseAccepted,
            resumeAccepted = resumeAccepted,
            transportStopAccepted = transportStopAccepted,
            transportStateBeforeDispose = transportStateBeforeDispose,
            transportStateAfterDispose = transportStateAfterDispose,
            transportDisposeCalls = transportDisposeCalls,
            preRollFrames = preRollFrames,
            preRollRingFullObserved = preRollRingFullObserved,
            preRollStatePrepared = preRollStatePrepared,
            sinkReadyBeforeTransportStart = sinkReadyAtMs >= 0L && transportStartAtMs >= sinkReadyAtMs,
            drainAllowedAfterTransportStart = drainAllowedAtMs >= 0L && drainAllowedAtMs >= transportStartAtMs,
            sinkReadyAtMs = sinkReadyAtMs,
            transportStartAtMs = transportStartAtMs,
            drainAllowedAtMs = drainAllowedAtMs,
            pauseRequestedAtMs = pauseRequestedAtMs,
            pauseAckedAtMs = pauseAckedAtMs,
            resumedAtMs = resumedAtMs,
            pauseHoldObservedMs = pauseHoldObservedMs,
            clockAtPauseAck = clockAtPauseAck,
            clockBeforeResume = clockBeforeResume,
            clockAfterResume = clockAfterResume,
            clock = s?.clockSnapshot(),
            sink = s?.telemetry(),
            decoderExitReason = f?.exitReason ?: VanguardRealtimePlaybackDecoderFeed.EXIT_NOT_STARTED,
            decoderThreadId = f?.threadId ?: -1L,
            decoderThreadIsTransportOwner = f?.threadIsTransportOwner ?: false,
            decoderAcceptedFrames = f?.acceptedFrames ?: 0L,
            decoderPaddedFrames = f?.paddedFrames ?: 0L,
            decoderChecksumHex = f?.checksumHex ?: "",
            decoderMediaReleaseCount = f?.mediaReleaseCount?.get() ?: 0L,
            decoderMediaReleaseClean = f?.mediaReleaseClean ?: false,
            decoderIngestCallbacksOnOwner = f?.ingestCallbacksOnOwner?.get() ?: 0L,
            decoderIngestCallbacksOffOwner = f?.ingestCallbacksOffOwner?.get() ?: 0L,
            decoderIngestCalls = f?.ingestCalls ?: 0L,
            decoderCancelRequested = decoderCancelRequested,
            decoderJoined = decoderJoined,
            sinkJoined = sinkJoined,
            terminalReply = terminalReply,
            sessionWallMs = wall,
            seek = VanguardRealtimeAudioPlaybackSeekObservation(
                armed = seekArmed,
                targetFrame = seekTargetFrame,
                holdFrame = preSeekHoldFrame,
                admissionOk = seekAdmissionOk,
                holdPinned = seekHoldPinned,
                seekCount = seekCount,
                seekAccepted = seekSequencer.seekAccepted,
                staleGeneration = seekSequencer.seekStaleGeneration,
                seekGeneration = seekSequencer.seekGeneration,
                pauseAccepted = seekSequencer.seekPauseAccepted,
                pauseGeneration = seekSequencer.seekPauseGeneration,
                resumeAccepted = seekSequencer.seekResumeAccepted,
                resumeGeneration = seekSequencer.seekResumeGeneration,
                initialWriteWaitMs = seekSequencer.seekInitialWriteWaitMs,
                quiesceWaitMs = seekSequencer.seekQuiesceWaitMs,
                quiesceFeedHeld = seekSequencer.seekQuiesceFeedHeld,
                quiesceSinkReadFrames = seekSequencer.seekQuiesceSinkReadFrames,
                quiesceSinkWrittenFrames = seekSequencer.seekQuiesceSinkWrittenFrames,
                quiesceAccountingOk = seekSequencer.seekQuiesceAccountingOk,
                preSeekSettleMs = seekSequencer.seekPreSeekSettleMs,
                preSeekReply = seekSequencer.seekPreSeekReply,
                preSeekTransportState = seekSequencer.seekPreSeekTransportState,
                postPauseReply = seekSequencer.seekPostPauseReply,
                flushRequestedWhilePaused = seekSequencer.seekFlushRequestedWhilePaused,
                flushAckWaitMs = seekSequencer.seekFlushAckWaitMs,
                flushAckedBeforeSeek = seekSequencer.seekFlushAckedBeforeSeek,
                sinkPhaseAtSeek = seekSequencer.seekSinkPhaseAtSeek,
                postSeekReply = seekSequencer.seekPostSeekReply,
                postSeekTransportState = seekSequencer.seekPostSeekTransportState,
                reanchorWaitMs = seekSequencer.seekReanchorWaitMs,
                postSeekPreRollWaitMs = seekSequencer.seekPostSeekPreRollWaitMs,
                postSeekPreRollReply = seekSequencer.seekPostSeekPreRollReply,
                postSeekPreRollTransportState = seekSequencer.seekPostSeekPreRollTransportState,
                transportStateAtUnpark = seekSequencer.seekTransportStateAtUnpark,
                parkRequestedAtMs = seekSequencer.seekParkRequestedAtMs,
                parkAckedAtMs = seekSequencer.seekParkAckedAtMs,
                unparkedAtMs = seekSequencer.seekUnparkedAtMs,
                resumedAtMs = seekSequencer.seekResumedAtMs,
                holdObservedMs = seekSequencer.seekHoldObservedMs,
                seekWallMs = seekSequencer.seekWallMs,
                clockAtPark = seekSequencer.seekClockAtPark,
                clockBeforeUnpark = seekSequencer.seekClockBeforeUnpark,
                clockAfterUnpark = seekSequencer.seekClockAfterUnpark,
                decoder = f?.seekTelemetry(),
            ),
        )
    }

    // ── Internals ──────────────────────────────────────────────────────────

    private fun accept(): CommandResult = CommandResult(true, state, REASON_OK)
    private fun reject(reason: String): CommandResult = CommandResult(false, state, reason)

    // Command-lock holder only: records the failure, tears down, FAILED.
    private fun failClosed(reason: String): CommandResult {
        recordFailure(reason)
        if (state != State.DISPOSED) {
            if (state != State.IDLE) teardownLocked()
            state = State.FAILED
        }
        return CommandResult(false, state, failure.get() ?: reason)
    }

    private fun recordFailure(reason: String) {
        failure.compareAndSet(null, reason)
    }

    // Sink thread callback after its AudioTrack was released. A non-EOS
    // exit fails closed: the decoder is cancelled so it never stalls
    // against a transport nobody drains; the transport is disposed by the
    // next stop()/dispose() on the caller's thread.
    private fun onSinkExited(reason: String) {
        if (reason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS) return
        if (reason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_CANCELLED && cancelled.get()) return
        recordFailure("sink:$reason")
        cancelDecoder()
        if (state == State.STARTING || state == State.PLAYING || state == State.PAUSED || state == State.SEEKING) state = State.FAILED
    }

    private fun cancelDecoder() {
        val f = feed ?: return
        decoderCancelRequested = true
        f.cancel()
    }

    // Polls the failure sources once; returns the first failure if any.
    private fun pollFailure(): String? {
        failure.get()?.let { return it }
        val machine = transport
        if (machine != null && machine.currentState == TransportState.FAILED) recordFailure("transport_failed")
        val f = feed
        if (f != null && !f.isAlive) {
            val reason = f.exitReason
            if (reason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS &&
                reason != VanguardRealtimePlaybackDecoderFeed.EXIT_RUNNING &&
                !(reason == VanguardRealtimePlaybackDecoderFeed.EXIT_CANCELLED && (cancelled.get() || decoderCancelRequested))
            ) {
                recordFailure("decoder:$reason")
            }
        }
        val s = sink
        if (s != null && !s.isAlive) {
            val reason = s.currentExitReason
            if (reason != VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS &&
                reason != VanguardRealtimeAudioPlaybackSinkBridge.EXIT_RUNNING &&
                reason != VanguardRealtimeAudioPlaybackSinkBridge.EXIT_NOT_STARTED &&
                !(reason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_CANCELLED && cancelled.get())
            ) {
                recordFailure("sink:$reason")
            }
        }
        if (sessionStartedAtMs >= 0L && !teardownDone.get() && SystemClock.elapsedRealtime() > deadlineAtMs) {
            recordFailure("deadline_exceeded")
        }
        return failure.get()
    }

    // Command-lock holder only; exactly once. Order: sink cancel, decoder
    // cancel, bounded joins, transport stop (only once both producer and
    // consumer threads are gone, so no late ingest/drain races the stop),
    // terminal snapshot, transport dispose once.
    private fun teardownLocked() {
        if (!teardownDone.compareAndSet(false, true)) return
        cancelled.set(true)
        val s = sink
        val f = feed
        s?.cancel()
        if (f != null) cancelDecoder()
        sinkJoined = s?.join(JOIN_TIMEOUT_MS) ?: true
        decoderJoined = f?.join(JOIN_TIMEOUT_MS) ?: true
        val machine = transport
        if (machine != null) {
            val before = machine.currentState
            // Native stop discards the output ring and zeroes drained/EOS
            // accounting. For a completed playthrough the terminal reply is
            // the pre-stop EOS drain (sink's last reply, else a pre-stop
            // snapshot); it must be captured before stop() can reset it.
            val preStopReply: Reply? =
                if (before == TransportState.COMPLETED || state == State.COMPLETED) {
                    s?.telemetry()?.lastReply?.takeIf { it.eosDrained } ?: machine.snapshot().reply
                } else {
                    null
                }
            if (sinkJoined && decoderJoined &&
                (before == TransportState.PREPARED || before == TransportState.PLAYING ||
                    before == TransportState.PAUSED || before == TransportState.COMPLETED)
            ) {
                val res = machine.stop()
                commandsIssued++
                transportStopAccepted = res.accepted && res.state == TransportState.STOPPED
            }
            val snap = machine.snapshot()
            terminalReply = preStopReply ?: snap.reply ?: s?.telemetry()?.lastReply
            transportStateBeforeDispose = machine.currentState
            machine.dispose()
            transportDisposeCalls++
            transportStateAfterDispose = machine.currentState
        }
        if (sessionStartedAtMs >= 0L) sessionWallMs = SystemClock.elapsedRealtime() - sessionStartedAtMs
    }

    private fun remainingMs(): Long = maxOf(1L, deadlineAtMs - SystemClock.elapsedRealtime())

    private fun checkDeadlineAndCancel() {
        if (cancelled.get()) throw FailClosed("cancelled")
        if (SystemClock.elapsedRealtime() > deadlineAtMs) throw FailClosed("deadline_exceeded")
    }

    private fun sleepSlice() {
        try {
            Thread.sleep(WAIT_SLICE_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }
}
