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

// ── VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-TIMESTAMP-STABILIZATION, Y6f) ─
//
// Timestamp-stabilization variant of the Y6e sink bridge: the X13
// AudioTrack.getTimestamp() poll-cadence / per-epoch frame-monotonicity
// diagnostic lifted into the real Y6a/Y6b pipeline shape. One NON-ZERO-GAIN
// android.media.AudioTrack (MODE_STREAM, PCM16) runs on ITS OWN sink
// thread, pulls mixed PCM16 from the caller-owned
// [VanguardRealtimePlaybackTransportStateMachine] through `drain()` ONLY
// and is the ONLY thread that:
//   - creates / recreates / releases the AudioTrack and calls setVolume,
//     play, write, playbackHeadPosition, playState and getTimestamp;
//   - arms and recovers the ONE synthetic ERROR_DEAD_OBJECT (dead-object
//     scenario only; the Y6e recovery shape is preserved exactly, minus the
//     routing listener handoff that Y6f does not carry).
// It never issues a transport command; the coordinator owns those and
// reads the published volatiles / counters to sequence them.
//
// Timestamp policy (sink thread, inert telemetry / gate only):
//   - ONE poll point per drain pass: after `writeAllToAudioTrack` returned
//     (and after the first pass's play()), never inside the write retry
//     loop, never while holding on the start gate, never inside the
//     dead-object recovery window (between release of the old instance and
//     play() of the recreated one), never during the head catch-up or the
//     teardown. Every poll asserts the sink activity token; a poll outside
//     the legal point is counted per bucket AND fails closed.
//   - an epoch opens only once PLAYSTATE_PLAYING was observed: epoch 0 on
//     the initial play(), epoch 1 on the recreated instance's play(). The
//     old epoch closes when the dead instance is released. The baseline
//     (last framePosition / last head) is reset at every epoch open and
//     NEVER compared across epochs (each sample carries its epoch id; a
//     comparison across ids is counted, never performed).
//   - AudioTimestamp.framePosition is normalized unsigned-32; per epoch it
//     must be non-decreasing: equal allowed, exactly one positive wrap
//     tolerated, strict backward movement fails closed
//     (timestamp_frame_regression). No drift window exists.
//   - getTimestamp() returning false is telemetry only (attempt counted,
//     success floor zero): it never fails a lane and never gates anything.
//   - nothing derived from a timestamp or the head feeds back into write
//     size, sleeps, drain gating, transport commands, pacing, the checksum
//     or native state: the write request is always `buf.remaining()`, the
//     sleeps are fixed constants, drain is called on every iteration and
//     the checksum accumulates over the drained PCM only.
//
// Teardown on the sink thread on every exit path (eos, cancel, deadline,
// failure): the current AudioTrack stopped and released exactly once. No
// seek, no flush, no pause, no focus, no routing, no real OS fault forcing,
// no seamless hot-swap, no presentation-clock or A/V-sync claim lives here.
class VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge(private val config: Config) {

    enum class Scenario { FORWARD_PLAYTHROUGH_TIMESTAMP, DEAD_OBJECT_EPOCH_RESET_TIMESTAMP }

    data class Config(
        val stateMachine: VanguardRealtimePlaybackTransportStateMachine,
        val scenario: Scenario,
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val declaredFrameCount: Long,
        // The dead object arms once DEAD_OBJECT_INJECT_AFTER_PHASES * phaseFrames were written.
        val phaseFrames: Long,
        // Non-zero linear gain applied with AudioTrack.setVolume; (0, 1].
        val baseVolume: Float = DEFAULT_BASE_VOLUME,
        // Absolute SystemClock.elapsedRealtime() deadline shared by the whole pipeline.
        val deadlineAtMs: Long,
        val threadName: String = "VanguardY6fSinkBridge",
        val externallyCancelled: () -> Boolean = { false },
    )

    // Sink-thread activity token. The single timestamp poll point is legal
    // ONLY in DRAIN_PASS_POST_WRITE; every other token is a violation bucket.
    enum class Activity {
        SETUP, START_GATE_HOLD, DRAIN_PASS, WRITE_LOOP, DRAIN_PASS_POST_WRITE,
        DEAD_OBJECT_RECOVERY, HEAD_CATCHUP, TEARDOWN,
    }

    companion object {
        const val DEFAULT_BASE_VOLUME = 0.5f

        const val EXIT_RUNNING = ""
        const val EXIT_EOS = "eos"
        const val EXIT_CANCELLED = "cancelled"
        const val EXIT_DEADLINE = "deadline_exceeded"
        const val EXIT_NOT_STARTED = "not_started"

        const val PLAY_STATE_UNKNOWN = -1

        const val DEAD_OBJECT_INJECT_AFTER_PHASES = 2L

        // Epoch 0 = initial instance, epoch 1 = recreated instance.
        const val MAX_EPOCHS = 2
        const val EPOCH_NONE = -1

        const val FRAME_WRAP_MODULUS = 0x1_0000_0000L
        // A tolerated wrap must land strictly less than half the modulus
        // ahead of the previous sample; anything else is a regression.
        const val FRAME_WRAP_FORWARD_MAX = 0x8000_0000L

        private const val TRACK_BUFFER_MARGIN_WINDOWS = 4L
        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val DRAIN_STALL_SLEEP_MS = 2L
        private const val DRAIN_STALL_TIMEOUT_MS = 3_000L
        private const val DRAIN_ITERATION_MARGIN = 64L
        private const val DRAIN_ITERATION_SLACK = 4L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_CATCHUP_MARGIN_MS = 3_000L
        private const val START_GATE_POLL_MS = 2L
        private const val AWAIT_POLL_MS = 2L

        fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class FailClosed(val reason: String) : Exception(reason)

    // ── Cross-thread control ───────────────────────────────────────────────

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val drainAllowed = AtomicBoolean(false)
    // Coordinator-sequenced arming of the one synthetic dead object (dead-
    // object scenario only). Not a transport command and not timestamp-
    // derived: it only orders the injection after the coordinator captured
    // its phase observations, like the Y6e route-changed gate did.
    private val deadObjectInjectionEnabled = AtomicBoolean(false)
    private val exitLatch = CountDownLatch(1)
    // Final release of the CURRENT instance (exactly once, sink thread).
    val releaseCount = AtomicInteger(0)

    @Volatile
    private var thread: Thread? = null

    // ── Published telemetry (volatile: written by the sink thread) ─────────

    @Volatile var exitReason: String = EXIT_NOT_STARTED; private set
    @Volatile var threadId: Long = -1L; private set
    @Volatile var threadIsTransportOwner: Boolean = false; private set
    @Volatile var activity: Activity = Activity.SETUP; private set

    // Setup (before the start gate).
    @Volatile var setupComplete: Boolean = false; private set
    @Volatile var audioTrackInitOk: Boolean = false; private set
    @Volatile var gainSetOk: Boolean = false; private set
    @Volatile var gainValue: Float = 0f; private set
    @Volatile var setVolumeCalls: Long = 0L; private set
    @Volatile var audioTrackBufferBytes: Int = 0; private set
    @Volatile var frozenBufferSizeInFrames: Long = -1L; private set
    @Volatile var preStartDrainEmptyOk: Boolean = false; private set
    @Volatile var preStartPlayState: Int = PLAY_STATE_UNKNOWN; private set
    @Volatile var startGateWaitMs: Long = -1L; private set

    // Drain / write accounting.
    @Volatile var played: Boolean = false; private set
    @Volatile var framesReadFromTransport: Long = 0L; private set
    @Volatile var framesWrittenToSink: Long = 0L; private set
    @Volatile var partialWriteCount: Long = 0L; private set
    @Volatile var zeroWriteCount: Long = 0L; private set
    @Volatile var drainCalls: Long = 0L; private set
    @Volatile var productiveDrainPasses: Long = 0L; private set
    @Volatile var emptyDrainCount: Long = 0L; private set
    @Volatile var eosDrainedObserved: Boolean = false; private set
    @Volatile var playbackHeadFinal: Long = 0L; private set
    @Volatile var playbackHeadCaughtUp: Boolean = false; private set
    @Volatile var sinkThreadWallMs: Long = 0L; private set
    @Volatile var lastReply: Reply? = null; private set
    @Volatile var observedPlayState: Int = PLAY_STATE_UNKNOWN; private set
    @Volatile var initialPlayOnSinkThread: Boolean = false; private set

    // AudioTrack instance accounting (sink thread writes).
    @Volatile var audioTracksCreated: Int = 0; private set
    @Volatile var audioTracksReleased: Int = 0; private set
    // Every AudioTrack-touching helper asserts the sink thread; a violation
    // is counted here (never expected: the class confines all calls).
    @Volatile var audioTrackOpsOffSinkThread: Long = 0L; private set

    // Dead-object recovery telemetry (Y6e shape preserved).
    val deadObjectInjectAfterFrames: Long get() = config.phaseFrames * DEAD_OBJECT_INJECT_AFTER_PHASES
    @Volatile var syntheticDeadObjectInjectedCount: Long = 0L; private set
    @Volatile var deadObjectObservedCount: Long = 0L; private set
    @Volatile var deadObjectOldTrackReleaseCount: Long = 0L; private set
    @Volatile var deadObjectNewTrackStateInitialized: Boolean = false; private set
    @Volatile var deadObjectNewTrackBufferSizeInFrames: Long = -1L; private set
    @Volatile var deadObjectNewTrackVolumeSet: Boolean = false; private set
    @Volatile var deadObjectNewTrackPlayState: Int = PLAY_STATE_UNKNOWN; private set
    @Volatile var deadObjectNewTrackPlayOk: Boolean = false; private set
    @Volatile var deadObjectSliceBytesAtRecovery: Long = -1L; private set
    @Volatile var deadObjectUnwrittenBytesAtRecovery: Long = -1L; private set
    @Volatile var deadObjectBufferPositionAtRecovery: Long = -1L; private set
    @Volatile var deadObjectSinkFramesWrittenBeforeRecovery: Long = -1L; private set
    @Volatile var deadObjectSinkFramesWrittenAfterRecoveryCall: Long = -1L; private set
    @Volatile var deadObjectRemainderFramesWrittenOnNewTrack: Long = -1L; private set
    @Volatile var deadObjectFramesReadAtRecovery: Long = -1L; private set
    @Volatile var deadObjectRemainderResumedOk: Boolean = false; private set
    @Volatile var deadObjectRecoveryOnSinkThread: Boolean = false; private set
    @Volatile var deadObjectRecoveryWallMs: Long = -1L; private set
    @Volatile var deadObjectPollsInsideRecoveryWindow: Long = 0L; private set

    // ── Timestamp telemetry (sink thread writes; inert) ────────────────────

    // Poll accounting: attempts = successes + unavailable, success floor 0.
    @Volatile var timestampPollAttempts: Long = 0L; private set
    @Volatile var timestampPollSuccesses: Long = 0L; private set
    @Volatile var timestampPollUnavailable: Long = 0L; private set
    @Volatile var timestampPollExceptions: Long = 0L; private set
    @Volatile var timestampPollsOnSinkThread: Long = 0L; private set
    @Volatile var timestampPollsOffSinkThread: Long = 0L; private set
    // Cadence: passes that reached the poll point, passes that polled, max
    // polls observed in any single pass (must stay <= 1).
    @Volatile var timestampPollPointReachedCount: Long = 0L; private set
    @Volatile var timestampPassesPolled: Long = 0L; private set
    @Volatile var timestampMaxPollsInOnePass: Long = 0L; private set
    @Volatile var timestampPollsAfterWriteReturned: Long = 0L; private set
    // Violation buckets (each also fails closed at the poll site).
    @Volatile var timestampPollsInsideWriteLoop: Long = 0L; private set
    @Volatile var timestampPollsWhileHolding: Long = 0L; private set
    @Volatile var timestampPollsBetweenReleaseAndPlay: Long = 0L; private set
    @Volatile var timestampPollsBeforePlaying: Long = 0L; private set
    @Volatile var timestampPollsWithoutOpenEpoch: Long = 0L; private set
    @Volatile var timestampPollsDuplicateInPass: Long = 0L; private set
    @Volatile var timestampPollsDuringCatchupOrTeardown: Long = 0L; private set
    @Volatile var timestampPollsBeforeStartGate: Long = 0L; private set
    // Per-epoch monotonicity.
    @Volatile var timestampFrameAdvanceCount: Long = 0L; private set
    @Volatile var timestampFrameEqualCount: Long = 0L; private set
    @Volatile var timestampFrameRegressionCount: Long = 0L; private set
    @Volatile var timestampWrapCount: Long = 0L; private set
    @Volatile var timestampNanoTimeAdvanceCount: Long = 0L; private set
    @Volatile var timestampNanoTimeEqualCount: Long = 0L; private set
    @Volatile var timestampNanoTimeNonMonotonicCount: Long = 0L; private set
    @Volatile var timestampCrossEpochComparisonCount: Long = 0L; private set
    @Volatile var timestampEpochOpenCount: Int = 0; private set
    @Volatile var timestampEpochCloseCount: Int = 0; private set
    @Volatile var timestampEpochBaselineResetCount: Int = 0; private set
    @Volatile var timestampCurrentEpoch: Int = EPOCH_NONE; private set
    @Volatile var timestampEpochOpenedAfterPlaying: Boolean = true; private set
    // Playback head sampled at the same poll point (per epoch).
    @Volatile var headSampleCount: Long = 0L; private set
    @Volatile var headAdvanceCount: Long = 0L; private set
    @Volatile var headEqualCount: Long = 0L; private set
    @Volatile var headRegressionCount: Long = 0L; private set
    @Volatile var headWrapCount: Long = 0L; private set
    @Volatile var headCrossEpochComparisonCount: Long = 0L; private set
    // Inertness: decisions that a timestamp/head sample would have had to
    // drive. They exist so the lane can assert them and are never incremented.
    @Volatile var timestampDerivedWriteSizeAdjustments: Long = 0L; private set
    @Volatile var timestampDerivedSleeps: Long = 0L; private set
    @Volatile var timestampDerivedDrainSkips: Long = 0L; private set
    @Volatile var timestampDerivedTransportCommands: Long = 0L; private set

    // Per-epoch arrays (index = epoch id; sink thread writes, published by copy).
    val epochOpenedAtMs = LongArray(MAX_EPOCHS) { -1L }
    val epochClosedAtMs = LongArray(MAX_EPOCHS) { -1L }
    val epochOpenPlayState = IntArray(MAX_EPOCHS) { PLAY_STATE_UNKNOWN }
    val epochFramesWrittenAtOpen = LongArray(MAX_EPOCHS) { -1L }
    val epochPollAttempts = LongArray(MAX_EPOCHS)
    val epochPollSuccesses = LongArray(MAX_EPOCHS)
    val epochPollUnavailable = LongArray(MAX_EPOCHS)
    val epochFirstFramePosition = LongArray(MAX_EPOCHS) { -1L }
    val epochLastFramePosition = LongArray(MAX_EPOCHS) { -1L }
    val epochFrameAdvanceCount = LongArray(MAX_EPOCHS)
    val epochFrameEqualCount = LongArray(MAX_EPOCHS)
    val epochWrapCount = LongArray(MAX_EPOCHS)
    val epochRegressionCount = LongArray(MAX_EPOCHS)
    val epochHeadSamples = LongArray(MAX_EPOCHS)
    val epochFirstHead = LongArray(MAX_EPOCHS) { -1L }
    val epochLastHead = LongArray(MAX_EPOCHS) { -1L }
    val epochHeadRegressionCount = LongArray(MAX_EPOCHS)
    val epochHeadWrapCount = LongArray(MAX_EPOCHS)
    val epochBaselineWasResetAtOpen = BooleanArray(MAX_EPOCHS)
    val epochFirstSampleWasBaseline = BooleanArray(MAX_EPOCHS)
    val epochFirstPollAtMs = LongArray(MAX_EPOCHS) { -1L }

    @Volatile
    private var checksum: Long = 0L

    val checksumHex: String get() = hex16(checksum)
    val isAlive: Boolean get() = thread?.isAlive == true

    // ── Sink-thread-confined state ─────────────────────────────────────────

    private var audioTrack: AudioTrack? = null
    private var lastProgressMs: Long = 0L
    private var frozenBufferSizeInBytes = 0
    private var frozenChannelMask = AudioFormat.CHANNEL_OUT_STEREO
    private var deadObjectResumePending = false
    private val audioTimestamp = AudioTimestamp()
    // Baseline for the OPEN epoch only (reset at every open).
    private var baselineEpoch = EPOCH_NONE
    private var baselineFramePosition = -1L
    private var baselineNanoTime = -1L
    private var baselineWrapSeen = false
    private var baselineHead = -1L
    private var baselineHeadEpoch = EPOCH_NONE
    private var baselineHeadWrapSeen = false
    // Per-pass poll bookkeeping.
    private var writeReturnedThisPass = false
    private var pollsThisPass = 0L

    // ── Public API ─────────────────────────────────────────────────────────

    fun start(): Boolean {
        if (!started.compareAndSet(false, true)) return false
        exitReason = EXIT_RUNNING
        val t = Thread({ runOnSinkThread() }, config.threadName)
        thread = t
        t.start()
        return true
    }

    // Any thread. Releases the start gate once the coordinator has started
    // the transport; the sink thread then enters its drain loop.
    fun allowDrain() {
        drainAllowed.set(true)
    }

    // Any thread (coordinator). Dead-object scenario only: the sink may arm
    // the synthetic dead object from now on (once the frame threshold holds).
    fun enableDeadObjectInjection() {
        if (config.scenario == Scenario.DEAD_OBJECT_EPOCH_RESET_TIMESTAMP) deadObjectInjectionEnabled.set(true)
    }

    val deadObjectInjectionArmed: Boolean get() = deadObjectInjectionEnabled.get()

    // Any thread. Observed at the next bounded wait.
    fun cancel() {
        cancelled.set(true)
    }

    // Bounded poll for a sink-published condition; false on timeout or once
    // the sink thread has exited (the caller re-checks the counters).
    fun await(timeoutMs: Long, condition: () -> Boolean): Boolean {
        val deadline = SystemClock.elapsedRealtime() + maxOf(0L, timeoutMs)
        while (true) {
            if (condition()) return true
            if (!isAlive || SystemClock.elapsedRealtime() > deadline) return condition()
            try {
                Thread.sleep(AWAIT_POLL_MS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return condition()
            }
        }
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

    // Sum of every violation bucket (any non-zero value also failed closed).
    val timestampPollViolations: Long
        get() = timestampPollsInsideWriteLoop + timestampPollsWhileHolding + timestampPollsBetweenReleaseAndPlay +
            timestampPollsBeforePlaying + timestampPollsWithoutOpenEpoch + timestampPollsDuplicateInPass +
            timestampPollsDuringCatchupOrTeardown + timestampPollsBeforeStartGate + timestampPollsOffSinkThread

    // ── Sink thread body ───────────────────────────────────────────────────

    private fun runOnSinkThread() {
        val wallStart = SystemClock.elapsedRealtime()
        threadId = Thread.currentThread().id
        try {
            threadIsTransportOwner = config.stateMachine.isOwnerThread
            if (threadIsTransportOwner) throw FailClosed("sink_thread_is_transport_owner")
            checkDeadlineAndCancel()
            validateConfig()
            activity = Activity.SETUP
            createFirstAudioTrack()
            provePreStartEmpty()
            setupComplete = true
            activity = Activity.START_GATE_HOLD
            awaitStartGate()
            drainLoop()
            activity = Activity.HEAD_CATCHUP
            catchUpPlaybackHead()
            exitReason = EXIT_EOS
        } catch (f: FailClosed) {
            exitReason = f.reason
        } catch (t: Throwable) {
            exitReason = "exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            activity = Activity.TEARDOWN
            closeEpochIfOpen()
            releaseAudioTrackOnce()
            sinkThreadWallMs = SystemClock.elapsedRealtime() - wallStart
            exitLatch.countDown()
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
        if (config.phaseFrames <= 0L) throw FailClosed("invalid_phase_frames")
        if (!(config.baseVolume > 0f) || config.baseVolume > 1f) throw FailClosed("invalid_base_volume")
    }

    private fun isCancelled(): Boolean = cancelled.get() || config.externallyCancelled()

    private fun checkDeadlineAndCancel() {
        if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
        if (SystemClock.elapsedRealtime() > config.deadlineAtMs) throw FailClosed(EXIT_DEADLINE)
    }

    private fun assertSinkThread() {
        if (Thread.currentThread().id != threadId) audioTrackOpsOffSinkThread++
    }

    private fun requireTrack(): AudioTrack = audioTrack ?: throw FailClosed("audio_track_missing")

    // Builds the diagnostic sink with the parameters frozen at the first
    // build (format, channel mask, buffer bytes, MODE_STREAM), so the
    // recreated instance is a same-parameter instance by construction.
    private fun buildDiagnosticAudioTrack(): AudioTrack {
        assertSinkThread()
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
                    .setChannelMask(frozenChannelMask)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(frozenBufferSizeInBytes)
            .build()
        audioTracksCreated++
        return track
    }

    private fun createFirstAudioTrack() {
        val bytesPerFrame = 2 * config.channelCount
        frozenChannelMask = if (config.channelCount == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minBytes = AudioTrack.getMinBufferSize(config.sampleRate, frozenChannelMask, AudioFormat.ENCODING_PCM_16BIT)
        if (minBytes <= 0) throw FailClosed("audio_track_min_buffer_invalid:$minBytes")
        val floorBytes = (TRACK_BUFFER_MARGIN_WINDOWS * config.maxFramesPerMix * bytesPerFrame).toInt()
        frozenBufferSizeInBytes = maxOf(minBytes, floorBytes)
        val track = buildDiagnosticAudioTrack()
        audioTrack = track
        audioTrackBufferBytes = frozenBufferSizeInBytes
        if (track.state != AudioTrack.STATE_INITIALIZED) throw FailClosed("audio_track_not_initialized")
        frozenBufferSizeInFrames = track.bufferSizeInFrames.toLong()
        audioTrackInitOk = true
        setGain(config.baseVolume, "base")
        gainSetOk = config.baseVolume > 0f
    }

    // Pre-start drain point: nothing was drained, written or polled yet, no
    // epoch is open and the track is still STOPPED (play() has not run).
    private fun provePreStartEmpty() {
        checkDeadlineAndCancel()
        assertSinkThread()
        preStartPlayState = requireTrack().playState
        observedPlayState = preStartPlayState
        preStartDrainEmptyOk = drainCalls == 0L && framesWrittenToSink == 0L && framesReadFromTransport == 0L &&
            timestampPollAttempts == 0L && timestampEpochOpenCount == 0 && !played &&
            preStartPlayState == AudioTrack.PLAYSTATE_STOPPED
        if (!preStartDrainEmptyOk) throw FailClosed("pre_start_drain_not_empty:$preStartPlayState")
    }

    private fun awaitStartGate() {
        val waitStart = SystemClock.elapsedRealtime()
        while (!drainAllowed.get()) {
            checkDeadlineAndCancel()
            SystemClock.sleep(START_GATE_POLL_MS)
        }
        startGateWaitMs = SystemClock.elapsedRealtime() - waitStart
    }

    // setVolume is linear gain; it never touches the PCM handed to write()
    // nor the checksum accumulated over it.
    private fun setGain(gain: Float, phase: String) {
        assertSinkThread()
        val track = requireTrack()
        setVolumeCalls++
        if (track.setVolume(gain) != AudioTrack.SUCCESS) throw FailClosed("audio_track_set_volume_failed_$phase")
        gainValue = gain
    }

    private fun rawHead(): Long {
        assertSinkThread()
        val track = audioTrack ?: return 0L
        return try {
            track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        } catch (_: Throwable) {
            0L
        }
    }

    private fun accumulateChecksum(buf: ByteBuffer, frames: Int) {
        var c = checksum
        val sampleCount = frames * config.channelCount
        for (i in 0 until sampleCount) c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
        checksum = c
    }

    // ── Epoch lifecycle (sink thread only) ─────────────────────────────────

    // Opens the next epoch. Legal only right after PLAYSTATE_PLAYING was
    // observed on the CURRENT instance; the baseline is discarded so the
    // first sample of the new epoch is a fresh baseline, never a comparison.
    private fun openEpoch(playStateObserved: Int) {
        assertSinkThread()
        val next = timestampEpochOpenCount
        if (next >= MAX_EPOCHS) throw FailClosed("timestamp_epoch_overflow:$next")
        if (timestampCurrentEpoch != EPOCH_NONE) throw FailClosed("timestamp_epoch_already_open:$timestampCurrentEpoch")
        if (playStateObserved != AudioTrack.PLAYSTATE_PLAYING) {
            timestampEpochOpenedAfterPlaying = false
            throw FailClosed("timestamp_epoch_open_before_playing:$playStateObserved")
        }
        timestampCurrentEpoch = next
        timestampEpochOpenCount = next + 1
        epochOpenedAtMs[next] = SystemClock.elapsedRealtime()
        epochOpenPlayState[next] = playStateObserved
        epochFramesWrittenAtOpen[next] = framesWrittenToSink
        // Baseline reset: nothing from a previous epoch survives.
        val hadBaseline = baselineFramePosition >= 0L || baselineHead >= 0L || baselineEpoch != EPOCH_NONE
        baselineEpoch = next
        baselineFramePosition = -1L
        baselineNanoTime = -1L
        baselineWrapSeen = false
        baselineHead = -1L
        baselineHeadEpoch = next
        baselineHeadWrapSeen = false
        epochBaselineWasResetAtOpen[next] = true
        if (next > 0 || hadBaseline) timestampEpochBaselineResetCount++
    }

    private fun closeEpochIfOpen() {
        val epoch = timestampCurrentEpoch
        if (epoch == EPOCH_NONE) return
        epochClosedAtMs[epoch] = SystemClock.elapsedRealtime()
        timestampEpochCloseCount++
        timestampCurrentEpoch = EPOCH_NONE
        // The baseline of a closed epoch is unreachable by construction.
        baselineEpoch = EPOCH_NONE
        baselineFramePosition = -1L
        baselineNanoTime = -1L
        baselineHead = -1L
        baselineHeadEpoch = EPOCH_NONE
    }

    // ── Timestamp poll point (sink thread only; inert) ─────────────────────

    // The ONE poll point of a drain pass. Every precondition violation is
    // counted in its bucket and fails closed; the poll itself never gates
    // anything: an unavailable timestamp is telemetry and the loop
    // continues unchanged.
    private fun pollTimestampOnce() {
        val onSink = Thread.currentThread().id == threadId
        if (onSink) timestampPollsOnSinkThread++ else timestampPollsOffSinkThread++
        assertSinkThread()
        timestampPollPointReachedCount++
        when (activity) {
            Activity.WRITE_LOOP -> { timestampPollsInsideWriteLoop++; throw FailClosed("timestamp_poll_inside_write_loop") }
            Activity.START_GATE_HOLD -> { timestampPollsWhileHolding++; timestampPollsBeforeStartGate++; throw FailClosed("timestamp_poll_while_holding") }
            Activity.SETUP -> { timestampPollsBeforeStartGate++; throw FailClosed("timestamp_poll_before_start_gate") }
            Activity.DEAD_OBJECT_RECOVERY -> {
                timestampPollsBetweenReleaseAndPlay++
                deadObjectPollsInsideRecoveryWindow++
                throw FailClosed("timestamp_poll_inside_recovery_window")
            }
            Activity.HEAD_CATCHUP, Activity.TEARDOWN -> { timestampPollsDuringCatchupOrTeardown++; throw FailClosed("timestamp_poll_during_catchup_or_teardown") }
            Activity.DRAIN_PASS -> { timestampPollsWhileHolding++; throw FailClosed("timestamp_poll_before_write_returned") }
            Activity.DRAIN_PASS_POST_WRITE -> Unit
        }
        if (!writeReturnedThisPass) { timestampPollsWhileHolding++; throw FailClosed("timestamp_poll_without_write") }
        if (pollsThisPass != 0L) { timestampPollsDuplicateInPass++; throw FailClosed("timestamp_poll_duplicate_in_pass") }
        if (!played || observedPlayState != AudioTrack.PLAYSTATE_PLAYING) { timestampPollsBeforePlaying++; throw FailClosed("timestamp_poll_before_playing") }
        val epoch = timestampCurrentEpoch
        if (epoch == EPOCH_NONE || epoch != baselineEpoch) { timestampPollsWithoutOpenEpoch++; throw FailClosed("timestamp_poll_without_open_epoch") }
        val track = requireTrack()

        pollsThisPass++
        timestampPassesPolled++
        timestampPollsAfterWriteReturned++
        if (pollsThisPass > timestampMaxPollsInOnePass) timestampMaxPollsInOnePass = pollsThisPass
        timestampPollAttempts++
        epochPollAttempts[epoch]++
        if (epochFirstPollAtMs[epoch] < 0L) epochFirstPollAtMs[epoch] = SystemClock.elapsedRealtime()

        val available = try {
            track.getTimestamp(audioTimestamp)
        } catch (_: Throwable) {
            timestampPollExceptions++
            false
        }
        if (available) {
            timestampPollSuccesses++
            epochPollSuccesses[epoch]++
            observeFramePosition(epoch, audioTimestamp.framePosition and 0xFFFF_FFFFL, audioTimestamp.nanoTime)
        } else {
            // Success floor zero: telemetry only, nothing else changes.
            timestampPollUnavailable++
            epochPollUnavailable[epoch]++
        }
        observeHead(epoch, rawHead())
    }

    // Per-epoch framePosition state machine: first sample is the baseline;
    // later samples must not move strictly backward (equal allowed, one
    // positive unsigned-32 wrap tolerated per epoch). nanoTime order is
    // counted only. The baseline is never compared across epochs.
    private fun observeFramePosition(epoch: Int, pos: Long, nano: Long) {
        if (baselineEpoch != epoch) {
            timestampCrossEpochComparisonCount++
            throw FailClosed("timestamp_cross_epoch_comparison:$baselineEpoch:$epoch")
        }
        if (baselineFramePosition < 0L) {
            baselineFramePosition = pos
            baselineNanoTime = nano
            epochFirstFramePosition[epoch] = pos
            epochLastFramePosition[epoch] = pos
            epochFirstSampleWasBaseline[epoch] = true
            return
        }
        val last = baselineFramePosition
        val delta = pos - last
        when {
            delta > 0L -> {
                timestampFrameAdvanceCount++
                epochFrameAdvanceCount[epoch]++
            }
            delta == 0L -> {
                timestampFrameEqualCount++
                epochFrameEqualCount[epoch]++
            }
            else -> {
                val forward = pos + FRAME_WRAP_MODULUS - last
                if (!baselineWrapSeen && forward > 0L && forward < FRAME_WRAP_FORWARD_MAX) {
                    baselineWrapSeen = true
                    timestampWrapCount++
                    epochWrapCount[epoch]++
                    timestampFrameAdvanceCount++
                    epochFrameAdvanceCount[epoch]++
                } else {
                    timestampFrameRegressionCount++
                    epochRegressionCount[epoch]++
                    throw FailClosed("timestamp_frame_regression:epoch$epoch:$last->$pos")
                }
            }
        }
        when {
            nano > baselineNanoTime -> timestampNanoTimeAdvanceCount++
            nano == baselineNanoTime -> timestampNanoTimeEqualCount++
            else -> timestampNanoTimeNonMonotonicCount++
        }
        baselineFramePosition = pos
        baselineNanoTime = nano
        epochLastFramePosition[epoch] = pos
    }

    // Playback head of the CURRENT instance at the same poll point: per-epoch
    // non-decreasing (equal allowed, one wrap tolerated); a regression is
    // counted (lane-evaluated by the coordinator), never fed back.
    private fun observeHead(epoch: Int, head: Long) {
        if (baselineHeadEpoch != epoch) {
            headCrossEpochComparisonCount++
            throw FailClosed("head_cross_epoch_comparison:$baselineHeadEpoch:$epoch")
        }
        headSampleCount++
        epochHeadSamples[epoch]++
        if (baselineHead < 0L) {
            baselineHead = head
            epochFirstHead[epoch] = head
            epochLastHead[epoch] = head
            return
        }
        val delta = head - baselineHead
        when {
            delta > 0L -> headAdvanceCount++
            delta == 0L -> headEqualCount++
            else -> {
                val forward = head + FRAME_WRAP_MODULUS - baselineHead
                if (!baselineHeadWrapSeen && forward > 0L && forward < FRAME_WRAP_FORWARD_MAX) {
                    baselineHeadWrapSeen = true
                    headWrapCount++
                    epochHeadWrapCount[epoch]++
                    headAdvanceCount++
                } else {
                    headRegressionCount++
                    epochHeadRegressionCount[epoch]++
                }
            }
        }
        baselineHead = head
        epochLastHead[epoch] = head
    }

    // ── Dead-object arming + recovery (sink thread only) ───────────────────

    // Arms the ONE synthetic dead object: dead-object scenario only, enabled
    // by the coordinator, never injected before, sink playing, epoch 0 open
    // and at least deadObjectInjectAfterFrames written. Returns true exactly once per
    // run; the caller then substitutes ERROR_DEAD_OBJECT for the write
    // result WITHOUT calling AudioTrack.write(). Synthetic and deterministic
    // by construction; this is not a forced OS dead object. Timestamp
    // availability plays no part in the decision.
    private fun armSyntheticDeadObject(sliceBytes: Int, unwrittenBytes: Int): Boolean {
        if (config.scenario != Scenario.DEAD_OBJECT_EPOCH_RESET_TIMESTAMP) return false
        if (!deadObjectInjectionEnabled.get()) return false
        if (syntheticDeadObjectInjectedCount != 0L) return false
        if (!played || timestampCurrentEpoch != 0) return false
        if (framesWrittenToSink < deadObjectInjectAfterFrames) return false
        if (sliceBytes <= 0 || unwrittenBytes <= 0) return false
        syntheticDeadObjectInjectedCount = 1L
        return true
    }

    // Recovery after ERROR_DEAD_OBJECT was observed on [oldTrack], all on
    // this sink thread: close epoch 0, release() the dead instance exactly
    // once (no pause/flush: a dead object accepts no further control
    // calls), build ONE same-parameter instance, assert STATE_INITIALIZED
    // and identical buffer geometry, reapply the base gain, play(), assert
    // PLAYSTATE_PLAYING and only then open epoch 1 with a fresh baseline.
    // No timestamp poll happens anywhere inside this window. The native
    // worker is never involved: it keeps rendering into the output ring and
    // at most sees normal ring backpressure.
    private fun recreateAudioTrackAfterDeadObject(oldTrack: AudioTrack): AudioTrack {
        assertSinkThread()
        val previousActivity = activity
        activity = Activity.DEAD_OBJECT_RECOVERY
        val recoveryStart = SystemClock.elapsedRealtime()
        deadObjectRecoveryOnSinkThread = Thread.currentThread().id == threadId
        if (deadObjectOldTrackReleaseCount != 0L) throw FailClosed("dead_object_old_track_already_released")
        if (releaseCount.get() > 0) throw FailClosed("dead_object_after_final_release")
        if (timestampCurrentEpoch != 0) throw FailClosed("dead_object_outside_epoch_0:$timestampCurrentEpoch")

        // Step 1: epoch 0 closes with the dead instance; its baseline dies here.
        closeEpochIfOpen()

        // Step 2: release the old instance exactly once.
        audioTrack = null
        try {
            oldTrack.release()
        } catch (t: Throwable) {
            throw FailClosed("dead_object_old_track_release_failed:${t.javaClass.simpleName}")
        }
        audioTracksReleased++
        deadObjectOldTrackReleaseCount = 1L

        // Step 3: same-parameter recreate.
        val newTrack = try {
            buildDiagnosticAudioTrack()
        } catch (t: Throwable) {
            throw FailClosed("recreated_audio_track_build_failed:${t.javaClass.simpleName}")
        }
        audioTrack = newTrack

        // Step 4: the recreated instance must be initialized with the
        // frozen buffer geometry.
        if (newTrack.state != AudioTrack.STATE_INITIALIZED) throw FailClosed("recreated_audio_track_not_initialized")
        deadObjectNewTrackStateInitialized = true
        deadObjectNewTrackBufferSizeInFrames = newTrack.bufferSizeInFrames.toLong()
        if (deadObjectNewTrackBufferSizeInFrames != frozenBufferSizeInFrames) {
            throw FailClosed(
                "recreated_audio_track_buffer_geometry_mismatch:$deadObjectNewTrackBufferSizeInFrames:$frozenBufferSizeInFrames",
            )
        }

        // Step 5: reapply the base gain (telemetry only).
        setGain(config.baseVolume, "dead_object_reapply")
        deadObjectNewTrackVolumeSet = gainValue == config.baseVolume

        // Step 6: start the recreated instance; MODE_STREAM consumes once the
        // resumed writes land.
        newTrack.play()
        deadObjectNewTrackPlayState = newTrack.playState
        observedPlayState = deadObjectNewTrackPlayState
        if (deadObjectNewTrackPlayState != AudioTrack.PLAYSTATE_PLAYING) {
            throw FailClosed("recreated_audio_track_not_playing_after_play:$deadObjectNewTrackPlayState")
        }
        deadObjectNewTrackPlayOk = true
        played = true

        // Step 7: epoch 1 opens only now, after PLAYSTATE_PLAYING, with a
        // fresh baseline.
        openEpoch(deadObjectNewTrackPlayState)
        deadObjectRecoveryWallMs = SystemClock.elapsedRealtime() - recoveryStart
        lastProgressMs = SystemClock.elapsedRealtime()
        activity = previousActivity
        return newTrack
    }

    // ── Write path ─────────────────────────────────────────────────────────

    // The write request is always the full remainder; nothing here reads a
    // timestamp or the head. Returns once the whole slice landed.
    private fun writeAllToAudioTrack(buf: ByteBuffer, bytes: Int, bytesPerFrame: Int) {
        assertSinkThread()
        activity = Activity.WRITE_LOOP
        var track = requireTrack()
        var framesThisCall = 0L
        buf.position(0)
        buf.limit(bytes)
        var consecutiveZero = 0
        while (buf.hasRemaining()) {
            checkDeadlineAndCancel()
            val requested = buf.remaining()
            val positionBefore = buf.position()
            val wrote = if (armSyntheticDeadObject(bytes, requested)) {
                AudioTrack.ERROR_DEAD_OBJECT
            } else {
                track.write(buf, requested, AudioTrack.WRITE_NON_BLOCKING)
            }
            val errorPrefix = if (deadObjectObservedCount > 0L) "recreated_audio_track" else "audio_track"
            when {
                wrote > 0 -> {
                    consecutiveZero = 0
                    if (wrote % bytesPerFrame != 0) throw FailClosed("${errorPrefix}_write_frame_misaligned:$wrote")
                    val frames = (wrote / bytesPerFrame).toLong()
                    framesThisCall += frames
                    framesWrittenToSink += frames
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
                        throw FailClosed("audio_track_dead_object_repeated:$deadObjectObservedCount")
                    }
                    // Only the armed synthetic dead object is recovered; a
                    // real OS dead object is outside this proof and fails
                    // closed exactly like Y6d/Y6e.
                    if (syntheticDeadObjectInjectedCount != 1L) throw FailClosed("audio_track_dead_object")
                    if (buf.position() != positionBefore || buf.remaining() != requested) {
                        throw FailClosed("dead_object_consumed_bytes")
                    }
                    deadObjectSliceBytesAtRecovery = bytes.toLong()
                    deadObjectUnwrittenBytesAtRecovery = requested.toLong()
                    deadObjectBufferPositionAtRecovery = positionBefore.toLong()
                    deadObjectSinkFramesWrittenBeforeRecovery = framesWrittenToSink
                    deadObjectFramesReadAtRecovery = framesReadFromTransport
                    // Recovery on this thread; the buffer position/limit are
                    // untouched, so the loop resumes on the same unwritten
                    // remainder.
                    track = recreateAudioTrackAfterDeadObject(track)
                    activity = Activity.WRITE_LOOP
                    deadObjectResumePending = true
                    consecutiveZero = 0
                }
                else -> throw FailClosed("${errorPrefix}_generic_error:$wrote")
            }
        }
        if (deadObjectResumePending) {
            // The remainder present at injection was written by the new
            // instance: exactly those frames, no more, no less, and the
            // slice total is intact.
            deadObjectResumePending = false
            deadObjectSinkFramesWrittenAfterRecoveryCall = framesWrittenToSink
            deadObjectRemainderFramesWrittenOnNewTrack = framesWrittenToSink - deadObjectSinkFramesWrittenBeforeRecovery
            val remainderFrames = deadObjectUnwrittenBytesAtRecovery / bytesPerFrame
            deadObjectRemainderResumedOk = deadObjectRemainderFramesWrittenOnNewTrack == remainderFrames &&
                framesThisCall == (bytes / bytesPerFrame).toLong()
            if (!deadObjectRemainderResumedOk) {
                throw FailClosed("dead_object_remainder_accounting:$deadObjectRemainderFramesWrittenOnNewTrack:$remainderFrames")
            }
        }
        buf.clear()
        activity = Activity.DRAIN_PASS_POST_WRITE
        writeReturnedThisPass = true
    }

    // ── Drain loop ─────────────────────────────────────────────────────────

    private fun drainLoop() {
        val bytesPerFrame = 2 * config.channelCount
        val drainBuffer = ByteBuffer.allocateDirect(config.maxFramesPerMix * bytesPerFrame).order(ByteOrder.nativeOrder())
        val maxProductiveDrains = (config.declaredFrameCount / config.maxFramesPerMix + 1L) * DRAIN_ITERATION_SLACK +
            DRAIN_ITERATION_MARGIN
        lastProgressMs = SystemClock.elapsedRealtime()
        while (true) {
            activity = Activity.DRAIN_PASS
            writeReturnedThisPass = false
            pollsThisPass = 0L
            checkDeadlineAndCancel()
            // drain() is called on every iteration; no timestamp state gates it.
            val res = config.stateMachine.drain(drainBuffer, config.maxFramesPerMix)
            drainCalls++
            if (!res.accepted) throw FailClosed("drain_rejected:${res.reason}")
            val reply = res.reply ?: throw FailClosed("drain_null_reply")
            lastReply = reply
            val framesRead = reply.framesRead.toInt()
            if (framesRead > 0) {
                if (framesRead > config.maxFramesPerMix) throw FailClosed("drain_overflow:$framesRead")
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
                    initialPlayOnSinkThread = Thread.currentThread().id == threadId
                    track.play()
                    played = true
                    observedPlayState = track.playState
                    if (observedPlayState != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("audio_track_initial_play_failed:$observedPlayState")
                    // Epoch 0 opens only now, after PLAYSTATE_PLAYING.
                    openEpoch(observedPlayState)
                }
                // The ONE poll point of this pass: after the write returned
                // (and after this pass's play() if it was the first).
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

    // The playback head of the CURRENT instance only covers frames written
    // to it: after a dead-object recreate that is the remainder written on
    // the new instance, not the run total. No timestamp poll happens here.
    private fun catchUpPlaybackHead() {
        val currentInstanceFrames = if (deadObjectObservedCount > 0L) {
            framesWrittenToSink - deadObjectSinkFramesWrittenBeforeRecovery
        } else {
            framesWrittenToSink
        }
        val catchUpDeadline = SystemClock.elapsedRealtime() + HEAD_CATCHUP_MARGIN_MS
        while (rawHead() < currentInstanceFrames) {
            checkDeadlineAndCancel()
            if (SystemClock.elapsedRealtime() > catchUpDeadline) break
            SystemClock.sleep(HEAD_POLL_SLEEP_MS)
        }
        playbackHeadFinal = rawHead()
        playbackHeadCaughtUp = playbackHeadFinal >= currentInstanceFrames
        if (playbackHeadFinal <= 0L) throw FailClosed("playback_head_not_advanced")
    }

    // Sink thread; exactly once. Fields are nulled first so a throwing
    // release is never retried on a dead object.
    private fun releaseAudioTrackOnce() {
        val track = audioTrack ?: return
        audioTrack = null
        if (releaseCount.get() > 0) return
        assertSinkThread()
        if (playbackHeadFinal == 0L) {
            try {
                playbackHeadFinal = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            } catch (_: Throwable) {}
        }
        try { track.stop() } catch (_: Throwable) {}
        try { track.release() } catch (_: Throwable) {}
        releaseCount.incrementAndGet()
        audioTracksReleased++
    }
}
