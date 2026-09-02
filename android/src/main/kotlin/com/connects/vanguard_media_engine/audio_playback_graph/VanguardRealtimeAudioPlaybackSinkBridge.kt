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
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

// ── VanguardRealtimeAudioPlaybackSinkBridge (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK, Y8a) ─
//
// Production-owned AudioTrack sink of the realtime audio playback engine.
// One NON-ZERO-GAIN android.media.AudioTrack (MODE_STREAM, PCM16) lives on
// ITS OWN sink thread, which owns EVERY AudioTrack call (create, setVolume,
// play, pause, write, getTimestamp, playbackHeadPosition, playState, stop,
// release) and EVERY write into the owned
// [VanguardRealtimePlaybackPresentationClock]. PCM16 is pulled from the
// caller-owned [VanguardRealtimePlaybackTransportStateMachine] through
// `drain()` ONLY; this bridge never issues a transport command.
//
// Phase protocol (sink thread executes, any thread requests):
//   SETUP -> READY (AudioTrack created, gain set) --allowDrain()--> RUNNING
//   RUNNING --requestPark()--> PARK_REQUESTED --(sink thread)--> PARKED
//   PARKED  --unpark()-------> (sink thread: AudioTrack.play) --> RUNNING
//   any     --exit-----------> EXITED (AudioTrack released exactly once)
//
// Presentation clock rules:
//   - epoch 0 opens only after the first productive post-start drain was
//     written and AudioTrack.play() returned PLAYSTATE_PLAYING.
//   - getTimestamp() is polled at most once per productive drain pass,
//     after the write returned; observeTimestamp / observeTimestampUnavailable
//     are called at that point and playbackHeadPosition is sampled there.
//   - bounded pause: AudioTrack.pause() on the sink thread, the last
//     published clock position is snapshotted, epochClosed(current) freezes
//     it. While PARKED nothing is drained, written or polled. On unpark
//     AudioTrack.play() runs on the same instance and epochOpened(epoch+1,
//     baseFrame = last published position) opens a new epoch. Because the
//     AudioTrack instance (and its framePosition) survive the pause, the
//     raw frame handed to the clock is rebased per epoch (instance frames
//     minus the published position at park, clamped at 0) so continuity
//     comes from the base offset only and no advancement is fabricated.
//   - the clock NEVER feeds back: drain size, sleeps, drain gating,
//     checksum and (absent) transport commands never depend on a timestamp
//     or clock outcome. A rejected clock write is counted, never acted on.
//     The sink reads the clock (snapshot) only at park, to take the base
//     of the next epoch; that read is counted.
// A parked hold longer than [Config.maxPauseHoldMs] (default well below the
// decoder feed's ingest stall budget) fails closed. No seek.
//
// Dead object (Y8b, P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-DEAD-OBJECT):
//   - Default off. When [Config.syntheticDeadObjectInjectAfterFrames] > 0
//     the sink thread arms EXACTLY ONE synthetic AudioTrack.ERROR_DEAD_OBJECT
//     once that many frames were written: the write is skipped and the
//     error substituted, so no byte of the slice is consumed.
//   - Only that armed synthetic dead object is recovered, on the sink
//     thread, inside the write loop: current epoch closed (accepted), old
//     instance released exactly once (own counter, never [releaseCounter]),
//     one same-parameter replacement built (STATE_INITIALIZED, same buffer
//     geometry), gain reapplied, play() -> PLAYSTATE_PLAYING, instance
//     unwrap/rebase reset, epoch+1 opened at baseFrame = frames written so
//     far (accepted). The unwritten remainder is then written to the new
//     instance. No timestamp poll happens inside the recovery window.
//   - The base step (baseFrame - last published position) fails closed on
//     sign only (step < 0). Its magnitude is NOT a production bound: it is
//     decomposed for the proof lane into frames lost with the dead instance
//     (written - head consumed at the dead object) and publication lag
//     (head consumed - last published position), from the same single clock
//     snapshot plus the dead instance's playbackHeadPosition.
//   - Any unarmed (real) ERROR_DEAD_OBJECT and any second ERROR_DEAD_OBJECT
//     fail closed. The final release of the replacement instance still goes
//     through [releaseAudioTrackOnce] exactly once.
class VanguardRealtimeAudioPlaybackSinkBridge(private val config: Config) {

    data class Config(
        val stateMachine: VanguardRealtimePlaybackTransportStateMachine,
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val declaredFrameCount: Long,
        // Non-zero linear gain applied with AudioTrack.setVolume; (0, 1].
        val gain: Float = DEFAULT_GAIN,
        // Hard cap on one parked hold; must stay below the decoder feed's
        // ingest stall budget, which keeps running while the transport pauses.
        val maxPauseHoldMs: Long = DEFAULT_MAX_PAUSE_HOLD_MS,
        // Absolute SystemClock.elapsedRealtime() deadline shared by the session.
        val deadlineAtMs: Long,
        val threadName: String = "VanguardRealtimeAudioSink",
        val externallyCancelled: () -> Boolean = { false },
        // Invoked once on the sink thread after the AudioTrack was released.
        val onExited: ((String) -> Unit)? = null,
        // Y8b diagnostic seam, default OFF (0). When > 0, exactly one
        // synthetic ERROR_DEAD_OBJECT is armed on the sink thread once this
        // many frames were written; see the class comment.
        val syntheticDeadObjectInjectAfterFrames: Long = 0L,
    )

    enum class Phase { SETUP, READY, RUNNING, PARK_REQUESTED, PARKED, EXITED }

    companion object {
        const val DEFAULT_GAIN = 1.0f
        const val DEFAULT_MAX_PAUSE_HOLD_MS = 1_500L
        const val EPOCH_NONE = VanguardRealtimePlaybackPresentationClock.EPOCH_NONE
        const val PLAY_STATE_UNKNOWN = -1

        const val EXIT_RUNNING = ""
        const val EXIT_EOS = "eos"
        const val EXIT_CANCELLED = "cancelled"
        const val EXIT_DEADLINE = "deadline_exceeded"
        const val EXIT_NOT_STARTED = "not_started"
        const val EXIT_PAUSE_HOLD_EXCEEDED = "bounded_pause_hold_exceeded"
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
        private const val FRAME_WRAP_MODULUS = VanguardRealtimePlaybackPresentationClock.FRAME_WRAP_MODULUS
        private const val FRAME_WRAP_FORWARD_MAX = VanguardRealtimePlaybackPresentationClock.FRAME_WRAP_FORWARD_MAX

        fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class FailClosed(val reason: String) : Exception(reason)

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

    // Guarded by parkLock.
    private var unparkRequested = false

    @Volatile private var parkAckLatch = CountDownLatch(1)
    @Volatile private var unparkAckLatch = CountDownLatch(1)
    @Volatile private var thread: Thread? = null

    // The owned clock. Written by the sink thread only; any thread snapshots.
    private val presentationClock = VanguardRealtimePlaybackPresentationClock(config.sampleRate)

    // ── Published telemetry (sink thread writes) ───────────────────────────

    @Volatile private var exitReason: String = EXIT_NOT_STARTED
    @Volatile private var threadId: Long = -1L
    @Volatile private var threadIsTransportOwner = false
    @Volatile private var clockWriterBoundOnSinkThread = false
    @Volatile private var audioTrackInitOk = false
    @Volatile private var gainSetOk = false
    @Volatile private var gainValue = 0f
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
    @Volatile private var timestampPollAttempts = 0L
    @Volatile private var timestampPollSuccesses = 0L
    @Volatile private var timestampPollUnavailable = 0L
    @Volatile private var timestampPollsWhileParked = 0L
    @Volatile private var timestampMaxPollsInOnePass = 0L
    @Volatile private var clockEpochOpenCalls = 0
    @Volatile private var clockEpochCloseCalls = 0
    @Volatile private var clockRejectedCount = 0L
    @Volatile private var clockSnapshotsAtPark = 0L
    @Volatile private var rebasedClampCount = 0L
    @Volatile private var currentEpoch = EPOCH_NONE
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
    @Volatile private var deadObjectInjectedCount = 0L
    @Volatile private var deadObjectObservedCount = 0L
    @Volatile private var deadObjectRecoveryCount = 0
    @Volatile private var deadObjectOldTrackReleaseCount = 0
    @Volatile private var deadObjectRecoveryExecutedOnSinkThread = false
    @Volatile private var deadObjectNewTrackInitOk = false
    @Volatile private var deadObjectNewTrackVolumeOk = false
    @Volatile private var deadObjectNewTrackPlayOk = false
    @Volatile private var deadObjectNewTrackPlayState = PLAY_STATE_UNKNOWN
    @Volatile private var deadObjectNewTrackSameBuffer = false
    @Volatile private var audioTrackBufferFrames = 0
    @Volatile private var deadObjectNewTrackBufferFrames = 0
    @Volatile private var deadObjectRecoveryWallMs = -1L
    @Volatile private var deadObjectEpochBeforeRecovery = EPOCH_NONE
    @Volatile private var deadObjectEpochOpenedAfterRecovery = EPOCH_NONE
    @Volatile private var deadObjectEpochCloseAccepted = false
    @Volatile private var deadObjectEpochOpenAccepted = false
    @Volatile private var deadObjectPositionBeforeRecovery = -1L
    @Volatile private var deadObjectBaseFrameAfterRecovery = -1L
    @Volatile private var deadObjectBaseStepFrames = -1L
    @Volatile private var deadObjectBaseStepBounded = false
    @Volatile private var deadObjectContentHeadAtDeadObject = -1L
    @Volatile private var deadObjectWrittenAheadOfHeadFrames = -1L
    @Volatile private var deadObjectPublicationLagFrames = -1L
    @Volatile private var deadObjectBaseStepDecompositionOk = false
    @Volatile private var deadObjectClockProvenanceAtRecovery = ""
    @Volatile private var deadObjectClockLastAgeNsAtRecovery = -1L
    @Volatile private var deadObjectSliceBytesAtRecovery = -1L
    @Volatile private var deadObjectUnwrittenBytesAtRecovery = -1L
    @Volatile private var deadObjectBufferPositionAtRecovery = -1L
    @Volatile private var deadObjectFramesReadAtRecovery = -1L
    @Volatile private var deadObjectFramesWrittenBeforeRecovery = -1L
    @Volatile private var deadObjectRemainderFramesExpected = -1L
    @Volatile private var deadObjectRemainderFramesWrittenOnNewTrack = -1L
    @Volatile private var deadObjectRemainderAccountingOk = false
    @Volatile private var deadObjectTimestampPollsDuringRecovery = -1L
    @Volatile private var clockSnapshotsAtDeadObjectRecovery = 0L
    @Volatile private var playbackHeadAtDeadObject = -1L

    // ── Sink-thread-confined state ─────────────────────────────────────────

    private var audioTrack: AudioTrack? = null
    private val audioTimestamp = AudioTimestamp()
    private var lastProgressMs = 0L
    private var pollsThisPass = 0L
    // Set by the write loop between the armed dead object and the end of
    // the slice whose remainder the replacement instance must absorb.
    private var deadObjectResumePending = false
    // Instance-frame unwrap of AudioTimestamp.framePosition (one forward
    // wrap tolerated) and the per-epoch rebase origin in instance frames.
    private var lastRaw32 = -1L
    private var wrapOffset = 0L
    private var epochRawOrigin = 0L

    val phase: Phase get() = phaseRef.get()
    val isAlive: Boolean get() = thread?.isAlive == true
    val currentExitReason: String get() = exitReason
    val framesWritten: Long get() = framesWrittenToSink
    val hasPlayed: Boolean get() = played
    val sinkThreadId: Long get() = threadId

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

    // Flips RUNNING -> PARK_REQUESTED; the sink parks at the top of its
    // next drain iteration. False when not RUNNING.
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

    // Wakes a PARKED sink thread; it plays the AudioTrack on its own thread
    // and publishes RUNNING. False when not PARKED.
    fun unpark(): Boolean {
        parkLock.withLock {
            if (phaseRef.get() != Phase.PARKED) return false
            unparkRequested = true
            parkCondition.signalAll()
        }
        return true
    }

    fun awaitRunning(timeoutMs: Long): Boolean =
        unparkAckLatch.await(timeoutMs, TimeUnit.MILLISECONDS) &&
            phaseRef.get() == Phase.RUNNING && unparkCount > 0

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

    fun clockSnapshot(): VanguardRealtimePlaybackPresentationClock.Snapshot = presentationClock.snapshot()

    fun telemetry(): VanguardRealtimeAudioPlaybackSinkTelemetry = VanguardRealtimeAudioPlaybackSinkTelemetry(
        phase = phaseRef.get(),
        exitReason = exitReason,
        threadId = threadId,
        threadIsTransportOwner = threadIsTransportOwner,
        clockWriterBoundOnSinkThread = clockWriterBoundOnSinkThread,
        audioTrackInitOk = audioTrackInitOk,
        gainSetOk = gainSetOk,
        gainValue = gainValue,
        audioTrackBufferBytes = audioTrackBufferBytes,
        audioTracksCreated = audioTracksCreated,
        releaseCount = releaseCounter.get(),
        releaseExecutedOnSinkThread = releaseExecutedOnSinkThread,
        audioTrackCallsOffSinkThread = audioTrackCallsOffSinkThread,
        played = played,
        initialPlayState = initialPlayState,
        framesReadFromTransport = framesReadFromTransport,
        framesWrittenToSink = framesWrittenToSink,
        partialWriteCount = partialWriteCount,
        zeroWriteCount = zeroWriteCount,
        drainCalls = drainCalls,
        drainCallsBeforeAllow = drainCallsBeforeAllow,
        drainRequestSizeChanges = drainRequestSizeChanges,
        emptyDrainCount = emptyDrainCount,
        productiveDrainPasses = productiveDrainPasses,
        eosDrainedObserved = eosDrainedObserved,
        timestampPollAttempts = timestampPollAttempts,
        timestampPollSuccesses = timestampPollSuccesses,
        timestampPollUnavailable = timestampPollUnavailable,
        timestampPollsWhileParked = timestampPollsWhileParked,
        timestampMaxPollsInOnePass = timestampMaxPollsInOnePass,
        clockEpochOpenCalls = clockEpochOpenCalls,
        clockEpochCloseCalls = clockEpochCloseCalls,
        clockRejectedCount = clockRejectedCount,
        clockSnapshotsAtPark = clockSnapshotsAtPark,
        rebasedClampCount = rebasedClampCount,
        currentEpoch = currentEpoch,
        parkCount = parkCount,
        unparkCount = unparkCount,
        playStateAtPark = playStateAtPark,
        playStateAfterUnpark = playStateAfterUnpark,
        parkedPlayStateViolations = parkedPlayStateViolations,
        parkExecutedOnSinkThread = parkExecutedOnSinkThread,
        unparkExecutedOnSinkThread = unparkExecutedOnSinkThread,
        positionAtPark = positionAtPark,
        epochClosedAtPark = epochClosedAtPark,
        epochOpenedAtUnpark = epochOpenedAtUnpark,
        parkAckLatencyMs = parkAckLatencyMs,
        parkedHoldMs = parkedHoldMs,
        playbackHeadAtPark = playbackHeadAtPark,
        playbackHeadAtUnpark = playbackHeadAtUnpark,
        playbackHeadFinal = playbackHeadFinal,
        readyAtMs = readyAtMs,
        drainAllowedAtMs = drainAllowedAtMs,
        firstDrainAtMs = firstDrainAtMs,
        firstWriteAtMs = firstWriteAtMs,
        sinkThreadWallMs = sinkThreadWallMs,
        checksumHex = hex16(checksum),
        lastReply = lastReply,
        syntheticDeadObjectInjectAfterFrames = config.syntheticDeadObjectInjectAfterFrames,
        deadObjectInjectedCount = deadObjectInjectedCount,
        deadObjectObservedCount = deadObjectObservedCount,
        deadObjectRecoveryCount = deadObjectRecoveryCount,
        deadObjectOldTrackReleaseCount = deadObjectOldTrackReleaseCount,
        deadObjectRecoveryExecutedOnSinkThread = deadObjectRecoveryExecutedOnSinkThread,
        deadObjectNewTrackInitOk = deadObjectNewTrackInitOk,
        deadObjectNewTrackVolumeOk = deadObjectNewTrackVolumeOk,
        deadObjectNewTrackPlayOk = deadObjectNewTrackPlayOk,
        deadObjectNewTrackPlayState = deadObjectNewTrackPlayState,
        deadObjectNewTrackSameBuffer = deadObjectNewTrackSameBuffer,
        audioTrackBufferFrames = audioTrackBufferFrames,
        deadObjectNewTrackBufferFrames = deadObjectNewTrackBufferFrames,
        deadObjectRecoveryWallMs = deadObjectRecoveryWallMs,
        deadObjectEpochBeforeRecovery = deadObjectEpochBeforeRecovery,
        deadObjectEpochOpenedAfterRecovery = deadObjectEpochOpenedAfterRecovery,
        deadObjectEpochCloseAccepted = deadObjectEpochCloseAccepted,
        deadObjectEpochOpenAccepted = deadObjectEpochOpenAccepted,
        deadObjectPositionBeforeRecovery = deadObjectPositionBeforeRecovery,
        deadObjectBaseFrameAfterRecovery = deadObjectBaseFrameAfterRecovery,
        deadObjectBaseStepFrames = deadObjectBaseStepFrames,
        deadObjectBaseStepBounded = deadObjectBaseStepBounded,
        deadObjectContentHeadAtDeadObject = deadObjectContentHeadAtDeadObject,
        deadObjectWrittenAheadOfHeadFrames = deadObjectWrittenAheadOfHeadFrames,
        deadObjectPublicationLagFrames = deadObjectPublicationLagFrames,
        deadObjectBaseStepDecompositionOk = deadObjectBaseStepDecompositionOk,
        deadObjectClockProvenanceAtRecovery = deadObjectClockProvenanceAtRecovery,
        deadObjectClockLastAgeNsAtRecovery = deadObjectClockLastAgeNsAtRecovery,
        deadObjectSliceBytesAtRecovery = deadObjectSliceBytesAtRecovery,
        deadObjectUnwrittenBytesAtRecovery = deadObjectUnwrittenBytesAtRecovery,
        deadObjectBufferPositionAtRecovery = deadObjectBufferPositionAtRecovery,
        deadObjectFramesReadAtRecovery = deadObjectFramesReadAtRecovery,
        deadObjectFramesWrittenBeforeRecovery = deadObjectFramesWrittenBeforeRecovery,
        deadObjectRemainderFramesExpected = deadObjectRemainderFramesExpected,
        deadObjectRemainderFramesWrittenOnNewTrack = deadObjectRemainderFramesWrittenOnNewTrack,
        deadObjectRemainderAccountingOk = deadObjectRemainderAccountingOk,
        deadObjectTimestampPollsDuringRecovery = deadObjectTimestampPollsDuringRecovery,
        clockSnapshotsAtDeadObjectRecovery = clockSnapshotsAtDeadObjectRecovery,
        playbackHeadAtDeadObject = playbackHeadAtDeadObject,
    )

    // ── Sink thread body ───────────────────────────────────────────────────

    private fun runOnSinkThread() {
        val wallStart = SystemClock.elapsedRealtime()
        threadId = Thread.currentThread().id
        clockWriterBoundOnSinkThread = presentationClock.bindWriterThread() &&
            presentationClock.boundWriterThreadId == threadId
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
            closeEpochIfOpen()
            releaseAudioTrackOnce()
            phaseRef.set(Phase.EXITED)
            sinkThreadWallMs = SystemClock.elapsedRealtime() - wallStart
            // Waiters must never block on a dead sink; they re-check phase.
            readyLatch.countDown()
            parkAckLatch.countDown()
            unparkAckLatch.countDown()
            exitLatch.countDown()
            try {
                config.onExited?.invoke(exitReason)
            } catch (_: Throwable) {}
        }
    }

    private fun validateConfig() {
        if (config.channelCount != 1 && config.channelCount != 2) throw FailClosed("invalid_channel_count")
        if (config.maxFramesPerMix <= 0 ||
            config.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP
        ) {
            throw FailClosed("invalid_max_frames_per_mix")
        }
        if (config.sampleRate < VanguardRealtimePlaybackNativeSession.MIN_SAMPLE_RATE ||
            config.sampleRate > VanguardRealtimePlaybackNativeSession.MAX_SAMPLE_RATE
        ) {
            throw FailClosed("invalid_sample_rate")
        }
        if (config.declaredFrameCount <= 0L) throw FailClosed("invalid_declared_frame_count")
        if (!(config.gain > 0f) || config.gain > 1f) throw FailClosed("invalid_gain")
        if (config.maxPauseHoldMs <= 0L) throw FailClosed("invalid_max_pause_hold")
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

    // Builds one AudioTrack from the frozen config parameters; the buffer
    // request is returned so a replacement can be checked against the
    // original geometry. Shared by the initial create and the Y8b recreate.
    private fun buildAudioTrack(): Pair<AudioTrack, Int> {
        val bytesPerFrame = 2 * config.channelCount
        val channelMask = if (config.channelCount == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minBytes = AudioTrack.getMinBufferSize(config.sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
        if (minBytes <= 0) throw FailClosed("audio_track_min_buffer_invalid:$minBytes")
        val floorBytes = (TRACK_BUFFER_MARGIN_WINDOWS * config.maxFramesPerMix * bytesPerFrame).toInt()
        val bufferBytes = maxOf(minBytes, floorBytes)
        noteTrackCall()
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(config.sampleRate)
                    .setChannelMask(channelMask)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(bufferBytes)
            .build()
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

    // Mirrors the native drain checksum over exactly the frames handed to
    // AudioTrack.write; a failed write aborts the run.
    private fun accumulateChecksum(buf: ByteBuffer, frames: Int) {
        var c = checksum
        val sampleCount = frames * config.channelCount
        for (i in 0 until sampleCount) c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
        checksum = c
    }

    // ── Write path (WRITE_NON_BLOCKING, in-place bounded retries) ──────────

    // Arms the ONE synthetic dead object: config seam > 0, never injected
    // before, sink playing with an open epoch, and at least
    // syntheticDeadObjectInjectAfterFrames written. Returns true exactly once
    // per run; the caller then substitutes ERROR_DEAD_OBJECT for the write
    // result WITHOUT calling AudioTrack.write(). Deterministic by
    // construction; timestamp/clock outcomes play no part in the decision.
    private fun armSyntheticDeadObject(unwrittenBytes: Int): Boolean {
        val after = config.syntheticDeadObjectInjectAfterFrames
        if (after <= 0L) return false
        if (deadObjectInjectedCount != 0L) return false
        if (!played || currentEpoch == EPOCH_NONE) return false
        if (phaseRef.get() != Phase.RUNNING) return false
        if (framesWrittenToSink < after) return false
        if (unwrittenBytes <= 0) return false
        deadObjectInjectedCount = 1L
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
            val wrote = if (armSyntheticDeadObject(requested)) {
                AudioTrack.ERROR_DEAD_OBJECT
            } else {
                track.write(buf, requested, AudioTrack.WRITE_NON_BLOCKING)
            }
            val errorPrefix = if (deadObjectRecoveryCount > 0) "recreated_audio_track" else "audio_track"
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
                    deadObjectObservedCount++
                    if (deadObjectObservedCount != 1L) {
                        throw FailClosed("$EXIT_DEAD_OBJECT_REPEATED:$deadObjectObservedCount")
                    }
                    // Only the armed synthetic dead object is recovered; an
                    // unarmed (real) dead object fails closed as before.
                    if (deadObjectInjectedCount != 1L) throw FailClosed(EXIT_DEAD_OBJECT)
                    if (buf.position() != positionBefore || buf.remaining() != requested) {
                        throw FailClosed("dead_object_consumed_bytes")
                    }
                    deadObjectSliceBytesAtRecovery = bytes.toLong()
                    deadObjectUnwrittenBytesAtRecovery = requested.toLong()
                    deadObjectBufferPositionAtRecovery = positionBefore.toLong()
                    deadObjectFramesReadAtRecovery = framesReadFromTransport
                    deadObjectFramesWrittenBeforeRecovery = framesWrittenToSink
                    deadObjectRemainderFramesExpected = (requested / bytesPerFrame).toLong()
                    // Recovery on this thread; buffer position/limit are
                    // untouched so the loop resumes on the same remainder.
                    track = recoverFromSyntheticDeadObject(track)
                    deadObjectResumePending = true
                    consecutiveZero = 0
                }
                else -> throw FailClosed("${errorPrefix}_generic_error:$wrote")
            }
        }
        if (deadObjectResumePending) {
            // Exactly the remainder present at injection landed on the new
            // instance and the slice total is intact.
            deadObjectResumePending = false
            deadObjectRemainderFramesWrittenOnNewTrack = framesWrittenToSink - deadObjectFramesWrittenBeforeRecovery
            deadObjectRemainderAccountingOk =
                deadObjectRemainderFramesWrittenOnNewTrack == deadObjectRemainderFramesExpected &&
                    framesThisCall == (bytes / bytesPerFrame).toLong()
            if (!deadObjectRemainderAccountingOk) {
                throw FailClosed(
                    "dead_object_remainder_accounting:$deadObjectRemainderFramesWrittenOnNewTrack:$deadObjectRemainderFramesExpected",
                )
            }
        }
        buf.clear()
    }

    // ── Y8b: synthetic dead-object recovery (sink thread only) ─────────────

    // Recovery after the armed ERROR_DEAD_OBJECT on [oldTrack]. Everything
    // runs on this sink thread, inside the write loop, with the drain buffer
    // untouched. Order: capture epoch/position, close the epoch (accepted),
    // release the old instance exactly once (own counter), build ONE
    // same-parameter replacement (STATE_INITIALIZED, same buffer geometry),
    // reapply gain, play() -> PLAYSTATE_PLAYING, reset the instance
    // unwrap/rebase state, open epoch+1 at baseFrame = frames written so far
    // (accepted). No timestamp poll and no transport command happen here.
    private fun recoverFromSyntheticDeadObject(oldTrack: AudioTrack): AudioTrack {
        val recoveryStart = SystemClock.elapsedRealtime()
        deadObjectRecoveryExecutedOnSinkThread = Thread.currentThread().id == threadId
        if (!deadObjectRecoveryExecutedOnSinkThread) throw FailClosed("dead_object_recovery_off_sink_thread")
        if (deadObjectRecoveryCount != 0 || deadObjectOldTrackReleaseCount != 0) {
            throw FailClosed("dead_object_recovery_repeated")
        }
        if (releaseCounter.get() > 0) throw FailClosed("dead_object_after_final_release")
        if (phaseRef.get() != Phase.RUNNING) throw FailClosed("dead_object_outside_running:${phaseRef.get().name.lowercase()}")
        val epochBeforeRecovery = currentEpoch
        if (epochBeforeRecovery == EPOCH_NONE) throw FailClosed("dead_object_without_open_epoch")
        deadObjectEpochBeforeRecovery = epochBeforeRecovery
        val pollAttemptsAtStart = timestampPollAttempts

        // Step 1: freeze. The last published position, provenance, anchor
        // age and epoch base are read from ONE (counted) snapshot for
        // telemetry only; the epoch closes with the dead instance.
        val snap = presentationClock.snapshot()
        clockSnapshotsAtDeadObjectRecovery++
        val positionBeforeRecovery = snap.positionFrames
        deadObjectPositionBeforeRecovery = positionBeforeRecovery
        deadObjectClockProvenanceAtRecovery = snap.provenance.name
        deadObjectClockLastAgeNsAtRecovery = snap.lastAgeNs
        val framesWrittenAtDeadObject = framesWrittenToSink
        // Head consumed by the dead instance, converted to a content frame of
        // the closing epoch with the poll path's unwrap/rebase assumptions
        // (instance frames minus the epoch origin, on the epoch base). -1 when
        // the dead instance no longer answers or the conversion is negative.
        var contentHead = -1L
        try {
            val rawHeadAtDeadObject = oldTrack.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            playbackHeadAtDeadObject = rawHeadAtDeadObject
            val rebasedHead = peekUnwrappedInstanceFrame(rawHeadAtDeadObject, snap.lastHead) - epochRawOrigin
            if (rebasedHead >= 0L && rebasedHead < FRAME_WRAP_MODULUS) contentHead = snap.epochBaseOffsetFrames + rebasedHead
        } catch (_: Throwable) {}
        deadObjectContentHeadAtDeadObject = contentHead
        currentEpoch = EPOCH_NONE
        clockEpochCloseCalls++
        val closeOutcome = presentationClock.epochClosed(epochBeforeRecovery, System.nanoTime())
        countClockOutcome(closeOutcome)
        deadObjectEpochCloseAccepted = closeOutcome.accepted
        if (!closeOutcome.accepted) throw FailClosed("dead_object_epoch_close_rejected:${closeOutcome.name.lowercase()}")

        // Step 2: release the old instance exactly once (never the final
        // releaseCounter). A dead object accepts no control calls, so no
        // stop/flush precedes release.
        audioTrack = null
        noteTrackCall()
        try {
            oldTrack.release()
        } catch (t: Throwable) {
            throw FailClosed("dead_object_old_track_release_failed:${t.javaClass.simpleName}")
        }
        deadObjectOldTrackReleaseCount = 1

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
        deadObjectNewTrackInitOk = true
        deadObjectNewTrackBufferFrames = newTrack.bufferSizeInFrames
        deadObjectNewTrackSameBuffer = bufferBytes == audioTrackBufferBytes &&
            deadObjectNewTrackBufferFrames == audioTrackBufferFrames
        if (!deadObjectNewTrackSameBuffer) {
            throw FailClosed(
                "recreated_audio_track_buffer_geometry_mismatch:$bufferBytes:$audioTrackBufferBytes:" +
                    "$deadObjectNewTrackBufferFrames:$audioTrackBufferFrames",
            )
        }

        // Step 4: reapply the configured gain.
        if (newTrack.setVolume(config.gain) != AudioTrack.SUCCESS) throw FailClosed("recreated_audio_track_set_volume_failed")
        deadObjectNewTrackVolumeOk = true
        gainValue = config.gain

        // Step 5: play; MODE_STREAM consumes once the remainder lands.
        newTrack.play()
        val playState = newTrack.playState
        deadObjectNewTrackPlayState = playState
        if (playState != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("recreated_audio_track_play_failed:$playState")
        deadObjectNewTrackPlayOk = true

        // Step 6: the new instance's framePosition starts from 0: reset the
        // unwrap/rebase state, then open epoch+1 based at the frames
        // written so far (>= last published position, so no clamp).
        lastRaw32 = -1L
        wrapOffset = 0L
        epochRawOrigin = 0L
        val baseFrame = framesWrittenToSink
        val nextEpoch = epochBeforeRecovery + 1
        val openOutcome = openClockEpoch(nextEpoch, baseFrame)
        deadObjectEpochOpenAccepted = openOutcome.accepted
        if (!openOutcome.accepted) throw FailClosed("dead_object_epoch_open_rejected:${openOutcome.name.lowercase()}")
        deadObjectEpochOpenedAfterRecovery = nextEpoch
        deadObjectBaseFrameAfterRecovery = baseFrame
        val step = baseFrame - positionBeforeRecovery
        deadObjectBaseStepFrames = step
        // Production fails closed on sign only: the new base may never fall
        // below the last published position. The step magnitude is publication
        // lag plus frames lost with the dead instance; neither is a sink fault.
        deadObjectBaseStepBounded = step >= 0L
        if (!deadObjectBaseStepBounded) throw FailClosed("dead_object_base_below_published:$baseFrame:$positionBeforeRecovery")
        // Proof decomposition (telemetry only): step = (W - H) + (H - P).
        // W - H is bounded by one track buffer plus one mix window; H - P is
        // reported for the proof lane's provenance-dependent budget.
        if (contentHead >= 0L) {
            val writtenAhead = framesWrittenAtDeadObject - contentHead
            deadObjectWrittenAheadOfHeadFrames = writtenAhead
            deadObjectPublicationLagFrames = contentHead - positionBeforeRecovery
            val lossBound = audioTrackBufferFrames.toLong() + config.maxFramesPerMix.toLong()
            deadObjectBaseStepDecompositionOk = writtenAhead in 0L..lossBound
        } else {
            deadObjectWrittenAheadOfHeadFrames = -1L
            deadObjectPublicationLagFrames = -1L
            deadObjectBaseStepDecompositionOk = false
        }

        deadObjectTimestampPollsDuringRecovery = timestampPollAttempts - pollAttemptsAtStart
        if (deadObjectTimestampPollsDuringRecovery != 0L) throw FailClosed("dead_object_timestamp_polled_in_recovery")
        deadObjectRecoveryCount = 1
        val now = SystemClock.elapsedRealtime()
        deadObjectRecoveryWallMs = now - recoveryStart
        lastProgressMs = now
        return newTrack
    }

    // ── Presentation clock writes (sink thread only; never fed back) ───────

    private fun countClockOutcome(outcome: VanguardRealtimePlaybackPresentationClock.Outcome) {
        if (!outcome.accepted) clockRejectedCount++
    }

    private fun openClockEpoch(epoch: Int, baseFrame: Long): VanguardRealtimePlaybackPresentationClock.Outcome {
        currentEpoch = epoch
        clockEpochOpenCalls++
        val outcome = presentationClock.epochOpened(epoch, baseFrame, System.nanoTime())
        countClockOutcome(outcome)
        return outcome
    }

    private fun closeEpochIfOpen() {
        val epoch = currentEpoch
        if (epoch == EPOCH_NONE) return
        currentEpoch = EPOCH_NONE
        clockEpochCloseCalls++
        countClockOutcome(presentationClock.epochClosed(epoch, System.nanoTime()))
    }

    // Non-mutating variant for the dead instance's head: applies the wrap
    // offset already accumulated by the timestamp path and tolerates the
    // same single forward wrap relative to the last raw frame seen (the last
    // timestamp raw frame, else [fallbackLastRaw32]). Unwrap state is untouched.
    private fun peekUnwrappedInstanceFrame(raw32: Long, fallbackLastRaw32: Long): Long {
        val last = if (lastRaw32 >= 0L) lastRaw32 else fallbackLastRaw32
        var offset = wrapOffset
        if (last >= 0L && raw32 < last) {
            val forward = raw32 + FRAME_WRAP_MODULUS - last
            if (forward > 0L && forward < FRAME_WRAP_FORWARD_MAX) offset += FRAME_WRAP_MODULUS
        }
        return raw32 + offset
    }

    private fun unwrapInstanceFrame(raw32: Long): Long {
        val last = lastRaw32
        if (last >= 0L && raw32 < last) {
            val forward = raw32 + FRAME_WRAP_MODULUS - last
            if (forward > 0L && forward < FRAME_WRAP_FORWARD_MAX) wrapOffset += FRAME_WRAP_MODULUS
        }
        lastRaw32 = raw32
        return raw32 + wrapOffset
    }

    // The ONE poll point of a productive drain pass, after the write
    // returned. Telemetry and clock writes only; nothing downstream of this
    // sink changes because of the result.
    private fun pollTimestampOnce() {
        val epoch = currentEpoch
        if (phaseRef.get() == Phase.PARKED) timestampPollsWhileParked++
        if (epoch == EPOCH_NONE) return
        pollsThisPass++
        if (pollsThisPass > timestampMaxPollsInOnePass) timestampMaxPollsInOnePass = pollsThisPass
        timestampPollAttempts++
        val track = requireTrack()
        val available = try {
            track.getTimestamp(audioTimestamp)
        } catch (_: Throwable) {
            false
        }
        val head = rawHead()
        if (available) {
            timestampPollSuccesses++
            val instance = unwrapInstanceFrame(audioTimestamp.framePosition and 0xFFFF_FFFFL)
            var rebased = instance - epochRawOrigin
            if (rebased < 0L) {
                rebasedClampCount++
                rebased = 0L
            }
            if (rebased >= FRAME_WRAP_MODULUS) {
                clockRejectedCount++
                return
            }
            countClockOutcome(presentationClock.observeTimestamp(epoch, rebased, audioTimestamp.nanoTime))
        } else {
            timestampPollUnavailable++
            countClockOutcome(presentationClock.observeTimestampUnavailable(epoch, head, System.nanoTime()))
        }
    }

    // ── Park / unpark (sink thread only) ───────────────────────────────────

    private fun parkOnSinkThread() {
        val track = requireTrack()
        if (!played) throw FailClosed("park_before_first_play")
        parkExecutedOnSinkThread = Thread.currentThread().id == threadId

        track.pause()
        val pausedState = track.playState
        playStateAtPark = pausedState
        if (pausedState != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("audio_track_pause_failed:$pausedState")
        playbackHeadAtPark = rawHead()

        // Freeze: the last published position becomes the next epoch's base
        // and its instance-frame origin; the current epoch closes.
        val snap = presentationClock.snapshot()
        clockSnapshotsAtPark++
        positionAtPark = snap.positionFrames
        epochClosedAtPark = currentEpoch
        closeEpochIfOpen()

        val parkedAtMs = SystemClock.elapsedRealtime()
        val requestedAt = parkRequestedAtMs
        parkAckLatencyMs = if (requestedAt >= 0L) parkedAtMs - requestedAt else -1L
        parkCount++
        phaseRef.set(Phase.PARKED)
        parkAckLatch.countDown()

        val holdCapAtMs = parkedAtMs + config.maxPauseHoldMs
        parkLock.withLock {
            while (!unparkRequested) {
                if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
                val now = SystemClock.elapsedRealtime()
                if (now > config.deadlineAtMs) throw FailClosed(EXIT_DEADLINE)
                if (now > holdCapAtMs) throw FailClosed("$EXIT_PAUSE_HOLD_EXCEEDED:${now - parkedAtMs}")
                try {
                    parkCondition.await(PARK_POLL_MS, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw FailClosed("interrupted_while_parked")
                }
                if (track.playState != AudioTrack.PLAYSTATE_PAUSED) parkedPlayStateViolations++
            }
            unparkRequested = false
        }

        playbackHeadAtUnpark = rawHead()
        track.play()
        val playingState = track.playState
        playStateAfterUnpark = playingState
        unparkExecutedOnSinkThread = Thread.currentThread().id == threadId
        if (playingState != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("audio_track_resume_play_failed:$playingState")
        // Same AudioTrack instance, new clock epoch based at the frozen position.
        val nextEpoch = epochClosedAtPark + 1
        epochRawOrigin = positionAtPark
        openClockEpoch(nextEpoch, positionAtPark)
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
        lastProgressMs = SystemClock.elapsedRealtime()
        while (true) {
            checkDeadlineAndCancel()
            if (phaseRef.get() == Phase.PARK_REQUESTED) parkOnSinkThread()
            pollsThisPass = 0L
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
                if (framesReadFromTransport + framesRead > config.declaredFrameCount) {
                    throw FailClosed("drain_exceeds_declared:${framesReadFromTransport + framesRead}")
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
                    // Epoch 0 opens only now: play succeeded on the first
                    // productive post-start write.
                    epochRawOrigin = 0L
                    openClockEpoch(0, 0L)
                }
                pollTimestampOnce()
                lastProgressMs = SystemClock.elapsedRealtime()
            } else {
                if (reply.eosDrained) {
                    eosDrainedObserved = true
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
                break
            }
        }
        if (!played) throw FailClosed("no_frames_written_to_sink")
    }

    // Sink thread; exactly once on every exit path. The field is nulled
    // first so a throwing release is never retried.
    private fun releaseAudioTrackOnce() {
        val track = audioTrack ?: return
        audioTrack = null
        if (releaseCounter.get() > 0) return
        releaseExecutedOnSinkThread = Thread.currentThread().id == threadId
        try {
            playbackHeadFinal = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        } catch (_: Throwable) {}
        try { track.stop() } catch (_: Throwable) {}
        try { track.release() } catch (_: Throwable) {}
        releaseCounter.incrementAndGet()
    }
}
