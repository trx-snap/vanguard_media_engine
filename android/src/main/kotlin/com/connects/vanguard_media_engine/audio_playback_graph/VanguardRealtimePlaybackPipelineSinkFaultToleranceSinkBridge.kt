package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackRoutingController.Event
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackRoutingController.Source
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackRoutingController.Tag
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

// ── VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SINK-FAULT-TOLERANCE, Y6e) ─
//
// Sink-fault-tolerant variant of the Y6d sink bridge: the Y4b AudioTrack
// fault-tolerance response table lifted into the real Y6a/Y6b pipeline
// shape. One NON-ZERO-GAIN android.media.AudioTrack (MODE_STREAM, PCM16)
// runs on ITS OWN sink thread, pulls mixed PCM16 from the caller-owned
// [VanguardRealtimePlaybackTransportStateMachine] through `drain()` ONLY
// and is the ONLY thread that:
//   - creates / recreates / releases the AudioTrack and calls setVolume,
//     play, pause, write, playbackHeadPosition, playState, routedDevice;
//   - attaches / detaches the one Y4b routing listener (through the
//     caller-owned [VanguardRealtimePlaybackRoutingController]) and pops
//     routing events from its single bounded queue at the top of every
//     drain iteration and at every parked poll slice;
//   - arms and recovers the ONE synthetic ERROR_DEAD_OBJECT.
// It never issues a transport command; the coordinator owns those and
// reads the published volatiles / counters to sequence them.
//
// Setup happens on the sink thread BEFORE the transport starts: create
// the track (freezing the buffer geometry), setVolume(baseVolume), attach
// the routing listener, and prove the pre-start drain point is empty.
// The thread then publishes `setupComplete` and blocks on the start gate
// until the coordinator has started the transport ([allowDrain]).
//
// Response table (sink thread, event seq order):
//   ROUTE_CHANGED             : AudioTrack.getRoutedDevice() sampled
//                               (telemetry only; no recreation, no play-
//                               state change). After the terminal
//                               disconnect: recorded no-op.
//   ROUTE_DISCONNECT          : terminal fail-closed park, sink first:
//                               AudioTrack.pause() -> PARKED(ROUTE_DISCONNECT),
//                               autoResumeAllowed=false, parked metrics
//                               published (the coordinator then pauses the
//                               transport). A duplicate fails closed.
//   ERROR_DEAD_OBJECT (write) : EOS scenario only, exactly once, synthetic
//                               (substituted for an in-flight write result
//                               with ZERO bytes consumed, once the
//                               synthetic ROUTE_CHANGED was applied and
//                               >= 2 * phaseFrames were written):
//                               detach listener -> release old track once
//                               -> create same-parameter track ->
//                               STATE_INITIALIZED -> setVolume(baseVolume)
//                               -> attach listener -> play()
//                               (PLAYSTATE_PLAYING) -> write the SAME
//                               ByteBuffer remainder. A second dead object,
//                               or a real (un-armed) one, fails closed.
//
// Teardown on the sink thread on every exit path (eos, terminal exit
// request, cancel, deadline, failure, park timeout): routing controller
// released (listener detached once, BEFORE the track release), then the
// current AudioTrack stopped and released exactly once. No seek, no
// flush, no focus, no real OS fault forcing, no seamless hot-swap claim
// lives here.
class VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge(private val config: Config) {

    enum class Scenario { EOS_WITH_DEAD_OBJECT_RECOVERY, ROUTE_DISCONNECT_TERMINAL }

    data class Config(
        val stateMachine: VanguardRealtimePlaybackTransportStateMachine,
        val routingController: VanguardRealtimePlaybackRoutingController,
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
        val threadName: String = "VanguardY6eSinkBridge",
        val externallyCancelled: () -> Boolean = { false },
    )

    enum class Phase { RUNNING, PARKED }

    enum class ParkReason { NONE, ROUTE_DISCONNECT }

    companion object {
        const val DEFAULT_BASE_VOLUME = 0.5f

        const val EXIT_RUNNING = ""
        const val EXIT_EOS = "eos"
        const val EXIT_TERMINAL = "terminal_exit"
        const val EXIT_CANCELLED = "cancelled"
        const val EXIT_DEADLINE = "deadline_exceeded"
        const val EXIT_NOT_STARTED = "not_started"

        const val PLAY_STATE_UNKNOWN = -1

        const val DEAD_OBJECT_INJECT_AFTER_PHASES = 2L

        private const val TRACK_BUFFER_MARGIN_WINDOWS = 4L
        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val DRAIN_STALL_SLEEP_MS = 2L
        private const val DRAIN_STALL_TIMEOUT_MS = 3_000L
        private const val DRAIN_ITERATION_MARGIN = 64L
        private const val DRAIN_ITERATION_SLACK = 4L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_CATCHUP_MARGIN_MS = 3_000L
        private const val PARK_POLL_MS = 5L
        private const val START_GATE_POLL_MS = 2L
        private const val AWAIT_POLL_MS = 2L
        private const val MAX_EVENTS_PER_DRAIN_POINT = 64
        // Hard cap on one parked hold, independent of the shared deadline.
        private const val PARK_MAX_HOLD_MS = 10_000L

        fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class FailClosed(val reason: String) : Exception(reason)

    // ── Cross-thread control ───────────────────────────────────────────────

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val exitRequested = AtomicBoolean(false)
    private val drainAllowed = AtomicBoolean(false)
    private val exitLatch = CountDownLatch(1)
    // Final release of the CURRENT instance (exactly once, sink thread).
    val releaseCount = AtomicInteger(0)
    private val phaseRef = AtomicReference(Phase.RUNNING)

    @Volatile
    private var thread: Thread? = null

    // ── Published telemetry (volatile: written by the sink thread) ─────────

    val phase: Phase get() = phaseRef.get()

    @Volatile var exitReason: String = EXIT_NOT_STARTED; private set
    @Volatile var threadId: Long = -1L; private set
    @Volatile var threadIsTransportOwner: Boolean = false; private set

    // Setup (before the start gate).
    @Volatile var setupComplete: Boolean = false; private set
    @Volatile var audioTrackInitOk: Boolean = false; private set
    @Volatile var gainSetOk: Boolean = false; private set
    @Volatile var gainValue: Float = 0f; private set
    @Volatile var setVolumeCalls: Long = 0L; private set
    @Volatile var audioTrackBufferBytes: Int = 0; private set
    @Volatile var frozenBufferSizeInFrames: Long = -1L; private set
    @Volatile var routingListenerAttachedOk: Boolean = false; private set
    @Volatile var preStartDrainEmptyOk: Boolean = false; private set
    @Volatile var preStartPendingCount: Int = -1; private set
    @Volatile var startGateWaitMs: Long = -1L; private set

    // Drain / write accounting.
    @Volatile var played: Boolean = false; private set
    @Volatile var framesReadFromTransport: Long = 0L; private set
    @Volatile var framesWrittenToSink: Long = 0L; private set
    @Volatile var partialWriteCount: Long = 0L; private set
    @Volatile var zeroWriteCount: Long = 0L; private set
    @Volatile var drainCalls: Long = 0L; private set
    @Volatile var emptyDrainCount: Long = 0L; private set
    @Volatile var eosDrainedObserved: Boolean = false; private set
    @Volatile var playbackHeadFinal: Long = 0L; private set
    @Volatile var playbackHeadCaughtUp: Boolean = false; private set
    @Volatile var sinkThreadWallMs: Long = 0L; private set
    @Volatile var lastReply: Reply? = null; private set
    @Volatile var observedPlayState: Int = PLAY_STATE_UNKNOWN; private set

    // AudioTrack instance accounting (sink thread writes).
    @Volatile var audioTracksCreated: Int = 0; private set
    @Volatile var audioTracksReleased: Int = 0; private set
    // Every AudioTrack-touching helper asserts the sink thread; a violation
    // is counted here (never expected: the class confines all calls).
    @Volatile var audioTrackOpsOffSinkThread: Long = 0L; private set

    // Routing response telemetry.
    @Volatile var autoResumeAllowed: Boolean = true; private set
    @Volatile var parkReason: ParkReason = ParkReason.NONE; private set
    @Volatile var parkCount: Int = 0; private set
    @Volatile var routeChangedAppliedCount: Long = 0L; private set
    @Volatile var syntheticRouteChangedAppliedCount: Long = 0L; private set
    @Volatile var realRouteChangedAppliedCount: Long = 0L; private set
    @Volatile var routeChangedAfterDisconnectCount: Long = 0L; private set
    @Volatile var routeChangedApplySeq: Long = -1L; private set
    @Volatile var syntheticRouteChangedApplySeq: Long = -1L; private set
    @Volatile var routedDeviceTypeAtRouteChanged: Int = -1; private set
    @Volatile var routedDeviceSampleOk: Boolean = false; private set
    @Volatile var routeChangeObserved: Boolean = false; private set
    @Volatile var routeDisconnectAppliedCount: Long = 0L; private set
    @Volatile var routeDisconnectApplySeq: Long = -1L; private set
    @Volatile var eventsAppliedOnSinkThread: Long = 0L; private set
    @Volatile var eventsAppliedOffSinkThread: Long = 0L; private set
    @Volatile var lastAppliedSeq: Long = -1L; private set
    @Volatile var lastAppliedTag: String = "none"; private set
    @Volatile var playStateAtPark: Int = PLAY_STATE_UNKNOWN; private set
    @Volatile var parkedPlayStateObservations: Long = 0L; private set
    @Volatile var parkedPlayStateViolations: Long = 0L; private set
    @Volatile var framesWrittenAtPark: Long = 0L; private set
    @Volatile var framesReadAtPark: Long = 0L; private set
    @Volatile var drainCallsAtPark: Long = 0L; private set
    @Volatile var playbackHeadAtPark: Long = 0L; private set
    @Volatile var checksumAtPark: Long = 0L; private set
    @Volatile var replyAtPark: Reply? = null; private set
    @Volatile var parkAppliedOnSinkThread: Boolean = false; private set
    @Volatile var parkedHoldMs: Long = -1L; private set
    @Volatile var terminalExitOnSinkThread: Boolean = false; private set
    // Events still queued at teardown (late telemetry, drained on the sink
    // thread before the controller is released so nothing stays pending).
    @Volatile var lateEventsAtTeardown: Long = 0L; private set

    // Dead-object recovery telemetry.
    val deadObjectInjectAfterFrames: Long get() = config.phaseFrames * DEAD_OBJECT_INJECT_AFTER_PHASES
    @Volatile var syntheticDeadObjectInjectedCount: Long = 0L; private set
    @Volatile var deadObjectObservedCount: Long = 0L; private set
    @Volatile var deadObjectOldTrackReleaseCount: Long = 0L; private set
    @Volatile var deadObjectOldTrackListenerDetachOk: Boolean = false; private set
    @Volatile var deadObjectNewTrackStateInitialized: Boolean = false; private set
    @Volatile var deadObjectNewTrackBufferSizeInFrames: Long = -1L; private set
    @Volatile var deadObjectNewTrackVolumeSet: Boolean = false; private set
    @Volatile var deadObjectListenerHandoffOk: Boolean = false; private set
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

    @Volatile
    private var checksum: Long = 0L

    val checksumHex: String get() = hex16(checksum)
    val checksumAtParkHex: String get() = hex16(checksumAtPark)
    val isAlive: Boolean get() = thread?.isAlive == true

    // ── Sink-thread-confined state ─────────────────────────────────────────

    private var audioTrack: AudioTrack? = null
    private var lastProgressMs: Long = 0L
    private var parkedAtMs: Long = -1L
    private var frozenBufferSizeInBytes = 0
    private var frozenChannelMask = AudioFormat.CHANNEL_OUT_STEREO
    private var deadObjectResumePending = false

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

    // Any thread. Terminal scenarios end here: the sink thread observes the
    // flag at its next parked poll slice (or drain iteration), exits with
    // [EXIT_TERMINAL] and releases the AudioTrack on its own thread.
    fun requestExit() {
        exitRequested.set(true)
    }

    // Any thread. Observed at the next bounded wait (including a parked wait).
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

    // ── Sink thread body ───────────────────────────────────────────────────

    private fun runOnSinkThread() {
        val wallStart = SystemClock.elapsedRealtime()
        threadId = Thread.currentThread().id
        try {
            threadIsTransportOwner = config.stateMachine.isOwnerThread
            if (threadIsTransportOwner) throw FailClosed("sink_thread_is_transport_owner")
            checkDeadlineAndCancel()
            validateConfig()
            createFirstAudioTrack()
            attachListenerAndProvePreStartEmpty()
            setupComplete = true
            awaitStartGate()
            drainLoop()
            catchUpPlaybackHead()
            exitReason = EXIT_EOS
        } catch (f: FailClosed) {
            exitReason = f.reason
        } catch (t: Throwable) {
            exitReason = "exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            // Late events drained (telemetry only), listener off the track
            // (controller release is idempotent), then the current
            // AudioTrack exactly once.
            try {
                lateEventsAtTeardown = config.routingController.drainAll().size.toLong()
                config.routingController.release()
            } catch (_: Throwable) {}
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
        val controller = config.routingController
        if (controller.isReleased) throw FailClosed("routing_controller_released")
        if (controller.isAttached || controller.attachCount != 0) throw FailClosed("routing_controller_already_used")
    }

    private fun isCancelled(): Boolean = cancelled.get() || config.externallyCancelled()

    private fun checkDeadlineAndCancel() {
        if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
        if (SystemClock.elapsedRealtime() > config.deadlineAtMs) throw FailClosed(EXIT_DEADLINE)
    }

    private fun checkTerminalExit() {
        if (exitRequested.get()) {
            terminalExitOnSinkThread = Thread.currentThread().id == threadId
            throw FailClosed(EXIT_TERMINAL)
        }
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

    // Listener attached to the first instance BEFORE the transport starts;
    // the pre-start drain point must be empty (a real OS routing callback
    // fires only after play(), so nothing may be queued yet).
    private fun attachListenerAndProvePreStartEmpty() {
        checkDeadlineAndCancel()
        val controller = config.routingController
        if (!controller.attach(requireTrack())) {
            throw FailClosed("routing_listener_register_failed:${controller.lastAttachError}")
        }
        routingListenerAttachedOk = true
        val preStart = controller.drainAll()
        preStartPendingCount = preStart.size
        if (preStart.isNotEmpty()) {
            val first = preStart.first()
            throw FailClosed("unexpected_pre_start_event:${first.tag.name.lowercase()}:${first.source.name.lowercase()}")
        }
        preStartDrainEmptyOk = true
    }

    private fun awaitStartGate() {
        val waitStart = SystemClock.elapsedRealtime()
        while (!drainAllowed.get()) {
            checkDeadlineAndCancel()
            checkTerminalExit()
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

    // ── Dead-object arming + recovery (sink thread only) ───────────────────

    // Arms the ONE synthetic dead object: EOS scenario only, never injected
    // before, sink playing, the synthetic ROUTE_CHANGED already applied and
    // at least deadObjectInjectAfterFrames written. Returns true exactly
    // once per run; the caller then substitutes ERROR_DEAD_OBJECT for the
    // write result WITHOUT calling AudioTrack.write(). Synthetic and
    // deterministic by construction; this is not a forced OS dead object.
    private fun armSyntheticDeadObject(sliceBytes: Int, unwrittenBytes: Int): Boolean {
        if (config.scenario != Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY) return false
        if (syntheticDeadObjectInjectedCount != 0L) return false
        if (!played || !routeChangeObserved || syntheticRouteChangedAppliedCount == 0L) return false
        if (phaseRef.get() != Phase.RUNNING) return false
        if (framesWrittenToSink < deadObjectInjectAfterFrames) return false
        if (sliceBytes <= 0 || unwrittenBytes <= 0) return false
        syntheticDeadObjectInjectedCount = 1L
        return true
    }

    // Recovery after ERROR_DEAD_OBJECT was observed on [oldTrack], all on
    // this sink thread: listener handoff off the dead instance, release()
    // it exactly once (no pause/flush: a dead object accepts no further
    // control calls), build ONE same-parameter instance, assert
    // STATE_INITIALIZED and identical buffer geometry, reapply the base
    // gain, hand the listener over, play() and assert PLAYSTATE_PLAYING.
    // The native worker is never involved: it keeps rendering into the
    // output ring and at most sees normal ring backpressure.
    private fun recreateAudioTrackAfterDeadObject(oldTrack: AudioTrack): AudioTrack {
        assertSinkThread()
        val recoveryStart = SystemClock.elapsedRealtime()
        deadObjectRecoveryOnSinkThread = Thread.currentThread().id == threadId
        if (deadObjectOldTrackReleaseCount != 0L) throw FailClosed("dead_object_old_track_already_released")
        if (releaseCount.get() > 0) throw FailClosed("dead_object_after_final_release")
        val controller = config.routingController

        // Handoff step 1: the listener leaves the dead instance before its
        // release (same order as the final teardown).
        deadObjectOldTrackListenerDetachOk = controller.detach()
        if (!deadObjectOldTrackListenerDetachOk) {
            throw FailClosed("dead_object_listener_detach_failed:${controller.lastDetachError}")
        }

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

        // Handoff step 2: the same listener joins the new instance.
        if (!controller.attach(newTrack)) {
            throw FailClosed("recreated_audio_track_listener_attach_failed:${controller.lastAttachError}")
        }
        deadObjectListenerHandoffOk = deadObjectOldTrackListenerDetachOk && controller.isAttached

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
        deadObjectRecoveryWallMs = SystemClock.elapsedRealtime() - recoveryStart
        lastProgressMs = SystemClock.elapsedRealtime()
        return newTrack
    }

    // ── Write path ─────────────────────────────────────────────────────────

    private fun writeAllToAudioTrack(buf: ByteBuffer, bytes: Int, bytesPerFrame: Int) {
        assertSinkThread()
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
                    // closed exactly like Y6d.
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
    }

    // ── Routing event application (sink thread only) ───────────────────────

    private fun applyPendingEvents(phase: String) {
        var applied = 0
        while (true) {
            val event = config.routingController.pollEvent() ?: break
            applyEvent(event)
            if (++applied > MAX_EVENTS_PER_DRAIN_POINT) throw FailClosed("routing_drain_unbounded_$phase")
        }
    }

    private fun applyEvent(event: Event) {
        val track = requireTrack()
        if (Thread.currentThread().id == threadId) eventsAppliedOnSinkThread++ else eventsAppliedOffSinkThread++
        lastAppliedSeq = event.seq
        lastAppliedTag = event.tag.name
        when (event.tag) {
            Tag.ROUTE_CHANGED -> {
                if (routeDisconnectAppliedCount > 0L) {
                    // Terminal park already applied: recorded no-op.
                    routeChangedAfterDisconnectCount++
                    return
                }
                assertSinkThread()
                val device = try {
                    track.routedDevice
                } catch (t: Throwable) {
                    throw FailClosed("routed_device_sample_failed:${t.javaClass.simpleName}")
                }
                if (routeChangedAppliedCount == 0L) {
                    routeChangedApplySeq = event.seq
                    routedDeviceTypeAtRouteChanged = device?.type ?: -1
                    routedDeviceSampleOk = true
                }
                routeChangedAppliedCount++
                if (event.source == Source.SYNTHETIC) {
                    if (syntheticRouteChangedAppliedCount == 0L) syntheticRouteChangedApplySeq = event.seq
                    syntheticRouteChangedAppliedCount++
                    routeChangeObserved = true
                } else {
                    realRouteChangedAppliedCount++
                }
            }
            Tag.ROUTE_DISCONNECT -> {
                if (routeDisconnectAppliedCount > 0L || phaseRef.get() == Phase.PARKED) {
                    throw FailClosed("duplicate_route_disconnect")
                }
                if (config.scenario != Scenario.ROUTE_DISCONNECT_TERMINAL) throw FailClosed("route_disconnect_in_eos_scenario")
                if (routeChangedAppliedCount == 0L) throw FailClosed("route_disconnect_before_route_changed")
                if (deadObjectObservedCount != 0L) throw FailClosed("route_disconnect_after_dead_object")
                // Terminal fail-closed park, sink first; never auto-resumed.
                // No flush/stop, no recreate, no play(). The coordinator
                // pauses the transport once it observes PARKED.
                autoResumeAllowed = false
                parkOnSinkThread(track, ParkReason.ROUTE_DISCONNECT)
                routeDisconnectAppliedCount = 1L
                routeDisconnectApplySeq = event.seq
            }
        }
    }

    // AudioTrack.pause() here, after the current window was fully written;
    // publishes PARKED plus the prefix snapshot (checksum, last drain reply)
    // the coordinator uses for prefix identity on the terminal scenario.
    private fun parkOnSinkThread(track: AudioTrack, reason: ParkReason) {
        assertSinkThread()
        if (!played) throw FailClosed("park_before_first_play:${reason.name.lowercase()}")
        val playingState = track.playState
        if (playingState != AudioTrack.PLAYSTATE_PLAYING) {
            throw FailClosed("route_disconnect_from_non_playing_state:$playingState")
        }
        parkAppliedOnSinkThread = Thread.currentThread().id == threadId
        track.pause()
        val pausedState = track.playState
        playStateAtPark = pausedState
        observedPlayState = pausedState
        if (pausedState != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("audio_track_pause_failed:$pausedState")
        framesWrittenAtPark = framesWrittenToSink
        framesReadAtPark = framesReadFromTransport
        drainCallsAtPark = drainCalls
        playbackHeadAtPark = rawHead()
        checksumAtPark = checksum
        replyAtPark = lastReply
        parkedAtMs = SystemClock.elapsedRealtime()
        parkReason = reason
        parkCount++
        phaseRef.set(Phase.PARKED)
    }

    // While PARKED the sink thread never drains or writes; it keeps the
    // published play state fresh and applies queued events (a late
    // ROUTE_CHANGED is a recorded no-op; there is no auto-resume). Exits on
    // requestExit, cancel, deadline, cap.
    private fun parkedWait(track: AudioTrack) {
        val capAtMs = parkedAtMs + PARK_MAX_HOLD_MS
        while (phaseRef.get() == Phase.PARKED) {
            if (exitRequested.get()) parkedHoldMs = SystemClock.elapsedRealtime() - parkedAtMs
            checkTerminalExit()
            if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
            val now = SystemClock.elapsedRealtime()
            if (now > config.deadlineAtMs) throw FailClosed(EXIT_DEADLINE)
            if (now > capAtMs) throw FailClosed("park_hold_timeout:${parkReason.name.lowercase()}")
            SystemClock.sleep(PARK_POLL_MS)
            val observed = track.playState
            observedPlayState = observed
            parkedPlayStateObservations++
            if (observed != AudioTrack.PLAYSTATE_PAUSED) parkedPlayStateViolations++
            applyPendingEvents("parked")
        }
    }

    // ── Drain loop ─────────────────────────────────────────────────────────

    private fun drainLoop() {
        val bytesPerFrame = 2 * config.channelCount
        val drainBuffer = ByteBuffer.allocateDirect(config.maxFramesPerMix * bytesPerFrame).order(ByteOrder.nativeOrder())
        val maxProductiveDrains = (config.declaredFrameCount / config.maxFramesPerMix + 1L) * DRAIN_ITERATION_SLACK +
            DRAIN_ITERATION_MARGIN
        var productiveDrains = 0L
        lastProgressMs = SystemClock.elapsedRealtime()
        while (true) {
            checkDeadlineAndCancel()
            checkTerminalExit()
            // Every drain iteration is a routing drain point first: real
            // ROUTE_CHANGED callbacks are observed as they arrive.
            applyPendingEvents("drain")
            if (phaseRef.get() == Phase.PARKED) {
                parkedWait(requireTrack())
                continue
            }
            val res = config.stateMachine.drain(drainBuffer, config.maxFramesPerMix)
            drainCalls++
            if (!res.accepted) throw FailClosed("drain_rejected:${res.reason}")
            val reply = res.reply ?: throw FailClosed("drain_null_reply")
            lastReply = reply
            val framesRead = reply.framesRead.toInt()
            if (framesRead > 0) {
                if (framesRead > config.maxFramesPerMix) throw FailClosed("drain_overflow:$framesRead")
                if (reply.bytesRead != framesRead.toLong() * bytesPerFrame) throw FailClosed("drain_bytes_read_mismatch:${reply.bytesRead}")
                if (++productiveDrains > maxProductiveDrains) throw FailClosed("drain_iteration_budget_exhausted")
                if (framesReadFromTransport + framesRead > config.declaredFrameCount) {
                    throw FailClosed("drain_exceeds_declared:${framesReadFromTransport + framesRead}")
                }
                accumulateChecksum(drainBuffer, framesRead)
                framesReadFromTransport += framesRead
                writeAllToAudioTrack(drainBuffer, framesRead * bytesPerFrame, bytesPerFrame)
                if (!played) {
                    val track = requireTrack()
                    track.play()
                    played = true
                    observedPlayState = track.playState
                    if (observedPlayState != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("audio_track_initial_play_failed:$observedPlayState")
                }
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
        // Final drain point before the head catch-up.
        applyPendingEvents("post_eos")
    }

    // The playback head of the CURRENT instance only covers frames written
    // to it: after a dead-object recreate that is the remainder written on
    // the new instance, not the run total.
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
