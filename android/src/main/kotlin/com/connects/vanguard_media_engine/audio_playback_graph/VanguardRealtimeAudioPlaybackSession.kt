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
//
//   MediaExtractor/MediaCodec ([VanguardRealtimePlaybackDecoderFeed], decode
//   thread) -> Y5a external ingest -> Y1 native transport (owner
//   HandlerThread inside [VanguardRealtimePlaybackTransportStateMachine]) ->
//   [VanguardRealtimeAudioPlaybackSinkBridge] (sink thread: AudioTrack +
//   presentation clock).
//
// Ownership: the decoder feed thread only posts generation-pinned ingest;
// the transport HandlerThread only owns the native session; the sink thread
// only owns the AudioTrack and the clock writes; THIS session (on the
// caller's thread, serialized by one lock) is the only transport command
// issuer. No MethodChannel, product, editor or app code lives here.
//
// Lifecycle: IDLE -start-> STARTING -> PLAYING <-> PAUSED (bounded) ->
// COMPLETED (sink drained EOS) / STOPPED (stop) / FAILED (first failure
// wins) -> DISPOSED (idempotent). Start sequence: format probe, load,
// prepare, attach feed, pre-roll while PREPARED, sink created and READY
// before transport start, transport start, then sink drain allowed.
// Bounded pause: sink park -> ack (AudioTrack paused, clock epoch closed at
// the last published position) -> transport.pause. Resume: transport.resume
// -> sink unpark -> ack (AudioTrack.play on the same instance, new clock
// epoch). A hold longer than [Config.maxPauseHoldMs] fails closed inside
// the sink (AudioTrack released, decoder cancelled through [onSinkExited]);
// the decoder feed's own ingest stall budget is therefore never reached.
// Stop/dispose: sink cancel, decoder cancel, bounded joins, transport stop
// (only after both threads exited), terminal snapshot, transport dispose
// exactly once. No seek, no dead-object recovery.
class VanguardRealtimeAudioPlaybackSession(private val config: Config) {

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 3.0,
        val maxFramesPerMix: Int = 256,
        val gain: Float = VanguardRealtimeAudioPlaybackSinkBridge.DEFAULT_GAIN,
        val deadlineMs: Long = 30_000L,
        val maxPauseHoldMs: Long = DEFAULT_MAX_PAUSE_HOLD_MS,
        val threadNamePrefix: String = "VanguardRealtimeAudio",
    )

    enum class State { IDLE, STARTING, PLAYING, PAUSED, COMPLETED, STOPPED, FAILED, DISPOSED }

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
        val sink: VanguardRealtimeAudioPlaybackSinkBridge.Telemetry?,
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
    )

    companion object {
        const val DEFAULT_MAX_PAUSE_HOLD_MS = VanguardRealtimeAudioPlaybackSinkBridge.DEFAULT_MAX_PAUSE_HOLD_MS
        const val REASON_OK = "ok"
        private const val WAIT_SLICE_MS = 5L
        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val SINK_READY_TIMEOUT_MS = 5_000L
        private const val PARK_ACK_TIMEOUT_MS = 2_000L
        private const val UNPARK_ACK_TIMEOUT_MS = 2_000L
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

    // Probe -> load/prepare -> attach -> pre-roll -> sink READY -> transport
    // start -> sink drain allowed. Any failure tears down and reports it.
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
                deadlineAtMs = deadlineAtMs,
                threadName = "${config.threadNamePrefix}Sink",
                externallyCancelled = { cancelled.get() },
                onExited = { reason -> onSinkExited(reason) },
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
        if (state == State.STARTING || state == State.PLAYING || state == State.PAUSED) state = State.FAILED
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
