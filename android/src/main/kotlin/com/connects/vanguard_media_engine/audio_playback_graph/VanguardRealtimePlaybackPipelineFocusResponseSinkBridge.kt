package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackAudioFocusController.Event
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackAudioFocusController.Tag
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

// ── VanguardRealtimePlaybackPipelineFocusResponseSinkBridge (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-FOCUS-RESPONSE, Y6d) ─
//
// Focus-aware variant of the Y6b phase-controlled AudioTrack sink bridge.
// One NON-ZERO-GAIN android.media.AudioTrack (MODE_STREAM, PCM16) runs on
// ITS OWN sink thread, pulls mixed PCM16 from the caller-owned
// [VanguardRealtimePlaybackTransportStateMachine] through `drain()` ONLY
// and is the ONLY thread that applies focus / becoming-noisy events: it
// pops them from the Y4a [VanguardRealtimePlaybackAudioFocusController]
// queue (OS and synthetic callbacks only enqueue there) at the top of
// every drain iteration and at every parked poll slice. It never issues a
// transport command; the coordinator owns those and reads the published
// volatiles / counters to sequence them.
//
// Response table (sink thread, event seq order):
//   LOSS_TRANSIENT_CAN_DUCK : setVolume(duckVolume); checksum untouched
//   GAIN while ducked       : setVolume(baseVolume)
//   LOSS_TRANSIENT          : AudioTrack.pause() -> PARKED(FOCUS_TRANSIENT)
//                             (coordinator then pauses the transport);
//                             duplicate while parked = recorded no-op
//   GAIN while focus-parked : AudioTrack.play() -> RUNNING (coordinator
//                             then resumes the transport)
//   BECOMING_NOISY          : AudioTrack.pause() -> PARKED(BECOMING_NOISY),
//                             autoResumeAllowed=false (terminal)
//   LOSS (permanent)        : AudioTrack.pause() -> PARKED(PERMANENT_LOSS),
//                             autoResumeAllowed=false (coordinator then
//                             stops the transport)
//   GAIN after terminal     : recorded + rejected; no play(), no setVolume
//
// Every AudioTrack method (create/setVolume/play/pause/write/
// playbackHeadPosition/playState/stop/release) executes on the sink
// thread. The AudioTrack is stopped and released exactly once, on the sink
// thread, on every exit path (eos, terminal exit request, cancel,
// deadline, failure, park timeout). No seek, no flush, no route-change,
// no dead-object recovery lives here.
class VanguardRealtimePlaybackPipelineFocusResponseSinkBridge(private val config: Config) {

    data class Config(
        val stateMachine: VanguardRealtimePlaybackTransportStateMachine,
        val focusController: VanguardRealtimePlaybackAudioFocusController,
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val declaredFrameCount: Long,
        // Non-zero linear gain applied with AudioTrack.setVolume; (0, 1].
        val baseVolume: Float = DEFAULT_BASE_VOLUME,
        // Duck gain; (0, baseVolume).
        val duckVolume: Float = DEFAULT_DUCK_VOLUME,
        // Absolute SystemClock.elapsedRealtime() deadline shared by the whole pipeline.
        val deadlineAtMs: Long,
        val threadName: String = "VanguardY6dSinkBridge",
        val externallyCancelled: () -> Boolean = { false },
    )

    enum class Phase { RUNNING, PARKED }

    enum class ParkReason { NONE, FOCUS_TRANSIENT, BECOMING_NOISY, PERMANENT_LOSS }

    companion object {
        const val DEFAULT_BASE_VOLUME = 0.5f
        const val DEFAULT_DUCK_VOLUME = 0.1f

        const val EXIT_RUNNING = ""
        const val EXIT_EOS = "eos"
        const val EXIT_TERMINAL = "terminal_exit"
        const val EXIT_CANCELLED = "cancelled"
        const val EXIT_DEADLINE = "deadline_exceeded"
        const val EXIT_NOT_STARTED = "not_started"

        const val PLAY_STATE_UNKNOWN = -1

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
        private const val AWAIT_POLL_MS = 2L
        // Hard cap on one parked hold, independent of the shared deadline.
        private const val PARK_MAX_HOLD_MS = 10_000L

        fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class FailClosed(val reason: String) : Exception(reason)

    // ── Cross-thread control ───────────────────────────────────────────────

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val exitRequested = AtomicBoolean(false)
    private val exitLatch = CountDownLatch(1)
    val releaseCount = AtomicInteger(0)
    private val phaseRef = AtomicReference(Phase.RUNNING)

    @Volatile
    private var thread: Thread? = null

    // ── Published telemetry (volatile: written by the sink thread) ─────────

    val phase: Phase get() = phaseRef.get()

    @Volatile var exitReason: String = EXIT_NOT_STARTED; private set
    @Volatile var threadId: Long = -1L; private set
    @Volatile var threadIsTransportOwner: Boolean = false; private set
    @Volatile var audioTrackInitOk: Boolean = false; private set
    @Volatile var gainSetOk: Boolean = false; private set
    @Volatile var gainValue: Float = 0f; private set
    @Volatile var setVolumeCalls: Long = 0L; private set
    @Volatile var audioTrackBufferBytes: Int = 0; private set
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

    // Focus response telemetry (sink thread writes; coordinator reads).
    @Volatile var autoResumeAllowed: Boolean = true; private set
    @Volatile var parkReason: ParkReason = ParkReason.NONE; private set
    @Volatile var parkCount: Int = 0; private set
    @Volatile var unparkCount: Int = 0; private set
    @Volatile var ducked: Boolean = false; private set
    @Volatile var duckAppliedCount: Long = 0L; private set
    @Volatile var restoreAppliedCount: Long = 0L; private set
    @Volatile var transientPauseAppliedCount: Long = 0L; private set
    @Volatile var duplicateTransientNoOpCount: Long = 0L; private set
    @Volatile var focusGainResumeAppliedCount: Long = 0L; private set
    @Volatile var focusGainNoOpCount: Long = 0L; private set
    @Volatile var noisyPauseAppliedCount: Long = 0L; private set
    @Volatile var noisyDuplicateNoOpCount: Long = 0L; private set
    @Volatile var permanentStopAppliedCount: Long = 0L; private set
    @Volatile var gainAttemptRejectedCount: Long = 0L; private set
    @Volatile var unknownEventCount: Long = 0L; private set
    @Volatile var eventsAppliedOnSinkThread: Long = 0L; private set
    @Volatile var eventsAppliedOffSinkThread: Long = 0L; private set
    @Volatile var lastAppliedSeq: Long = -1L; private set
    @Volatile var lastAppliedTag: String = "none"; private set
    @Volatile var observedPlayState: Int = PLAY_STATE_UNKNOWN; private set
    @Volatile var playStateAtPark: Int = PLAY_STATE_UNKNOWN; private set
    @Volatile var playStateAfterUnpark: Int = PLAY_STATE_UNKNOWN; private set
    @Volatile var parkedPlayStateObservations: Long = 0L; private set
    @Volatile var parkedPlayStateViolations: Long = 0L; private set
    @Volatile var framesWrittenAtPark: Long = 0L; private set
    @Volatile var drainCallsAtPark: Long = 0L; private set
    @Volatile var playbackHeadAtPark: Long = 0L; private set
    @Volatile var playbackHeadAtUnpark: Long = 0L; private set
    @Volatile var checksumAtPark: Long = 0L; private set
    @Volatile var replyAtPark: Reply? = null; private set
    @Volatile var parkedHoldMs: Long = -1L; private set
    @Volatile var terminalExitOnSinkThread: Boolean = false; private set

    @Volatile
    private var checksum: Long = 0L

    val checksumHex: String get() = hex16(checksum)
    val checksumAtParkHex: String get() = hex16(checksumAtPark)
    val isAlive: Boolean get() = thread?.isAlive == true

    // ── Sink-thread-confined state ─────────────────────────────────────────

    private var audioTrack: AudioTrack? = null
    private var lastProgressMs: Long = 0L
    private var parkedAtMs: Long = -1L

    // ── Public API ─────────────────────────────────────────────────────────

    fun start(): Boolean {
        if (!started.compareAndSet(false, true)) return false
        exitReason = EXIT_RUNNING
        val t = Thread({ runOnSinkThread() }, config.threadName)
        thread = t
        t.start()
        return true
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
            createAudioTrack()
            drainLoop()
            catchUpPlaybackHead()
            exitReason = EXIT_EOS
        } catch (f: FailClosed) {
            exitReason = f.reason
        } catch (t: Throwable) {
            exitReason = "exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
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
        if (!(config.baseVolume > 0f) || config.baseVolume > 1f) throw FailClosed("invalid_base_volume")
        if (!(config.duckVolume > 0f) || config.duckVolume >= config.baseVolume) throw FailClosed("invalid_duck_volume")
        if (config.focusController.isReleased) throw FailClosed("focus_controller_released")
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

    private fun createAudioTrack() {
        val bytesPerFrame = 2 * config.channelCount
        val channelMask = if (config.channelCount == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minBytes = AudioTrack.getMinBufferSize(config.sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
        if (minBytes <= 0) throw FailClosed("audio_track_min_buffer_invalid:$minBytes")
        val floorBytes = (TRACK_BUFFER_MARGIN_WINDOWS * config.maxFramesPerMix * bytesPerFrame).toInt()
        val bufferBytes = maxOf(minBytes, floorBytes)
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
        audioTrack = track
        audioTrackBufferBytes = bufferBytes
        if (track.state != AudioTrack.STATE_INITIALIZED) throw FailClosed("audio_track_not_initialized")
        audioTrackInitOk = true
        setGain(config.baseVolume, "base")
        gainSetOk = config.baseVolume > 0f
    }

    // setVolume is linear gain; it never touches the PCM handed to write()
    // nor the checksum accumulated over it.
    private fun setGain(gain: Float, phase: String) {
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        setVolumeCalls++
        if (track.setVolume(gain) != AudioTrack.SUCCESS) throw FailClosed("audio_track_set_volume_failed_$phase")
        gainValue = gain
    }

    private fun rawHead(): Long {
        val track = audioTrack ?: return 0L
        return track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
    }

    private fun accumulateChecksum(buf: ByteBuffer, frames: Int) {
        var c = checksum
        val sampleCount = frames * config.channelCount
        for (i in 0 until sampleCount) c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
        checksum = c
    }

    private fun writeAllToAudioTrack(buf: ByteBuffer, bytes: Int, bytesPerFrame: Int) {
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        buf.position(0)
        buf.limit(bytes)
        var consecutiveZero = 0
        while (buf.hasRemaining()) {
            checkDeadlineAndCancel()
            val requested = buf.remaining()
            val wrote = track.write(buf, requested, AudioTrack.WRITE_NON_BLOCKING)
            when {
                wrote > 0 -> {
                    consecutiveZero = 0
                    if (wrote % bytesPerFrame != 0) throw FailClosed("audio_track_write_frame_misaligned:$wrote")
                    framesWrittenToSink += (wrote / bytesPerFrame).toLong()
                    if (wrote < requested) {
                        partialWriteCount++
                        buf.compact()
                        buf.flip()
                    }
                }
                wrote == 0 -> {
                    zeroWriteCount++
                    if (++consecutiveZero > MAX_CONSECUTIVE_ZERO_WRITES) throw FailClosed("audio_track_write_stalled")
                    SystemClock.sleep(ZERO_WRITE_SLEEP_MS)
                }
                wrote == AudioTrack.ERROR_INVALID_OPERATION -> throw FailClosed("audio_track_invalid_operation")
                wrote == AudioTrack.ERROR_BAD_VALUE -> throw FailClosed("audio_track_bad_value")
                wrote == AudioTrack.ERROR_DEAD_OBJECT -> throw FailClosed("audio_track_dead_object")
                else -> throw FailClosed("audio_track_generic_error:$wrote")
            }
        }
        buf.clear()
    }

    // ── Focus event application (sink thread only) ─────────────────────────

    private fun applyPendingEvents() {
        while (true) {
            val event = config.focusController.pollEvent() ?: break
            applyEvent(event)
        }
    }

    private fun applyEvent(event: Event) {
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        if (Thread.currentThread().id == threadId) eventsAppliedOnSinkThread++ else eventsAppliedOffSinkThread++
        lastAppliedSeq = event.seq
        lastAppliedTag = event.tag.name
        when (event.tag) {
            Tag.FOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                if (!autoResumeAllowed || phaseRef.get() == Phase.PARKED) {
                    gainAttemptRejectedCount++
                } else {
                    setGain(config.duckVolume, "duck")
                    ducked = true
                    duckAppliedCount++
                }
            }
            Tag.FOCUS_LOSS_TRANSIENT -> {
                if (phaseRef.get() == Phase.PARKED) {
                    duplicateTransientNoOpCount++
                } else {
                    parkOnSinkThread(track, ParkReason.FOCUS_TRANSIENT)
                    transientPauseAppliedCount++
                }
            }
            Tag.FOCUS_GAIN -> {
                if (!autoResumeAllowed) {
                    gainAttemptRejectedCount++
                } else if (phaseRef.get() == Phase.PARKED) {
                    unparkOnSinkThread(track)
                    focusGainResumeAppliedCount++
                } else if (ducked) {
                    setGain(config.baseVolume, "restore")
                    ducked = false
                    restoreAppliedCount++
                } else {
                    focusGainNoOpCount++
                }
            }
            Tag.BECOMING_NOISY -> {
                autoResumeAllowed = false
                if (phaseRef.get() == Phase.PARKED) {
                    noisyDuplicateNoOpCount++
                } else {
                    parkOnSinkThread(track, ParkReason.BECOMING_NOISY)
                    noisyPauseAppliedCount++
                }
            }
            Tag.FOCUS_LOSS_PERMANENT -> {
                autoResumeAllowed = false
                if (phaseRef.get() == Phase.PARKED) {
                    parkReason = ParkReason.PERMANENT_LOSS
                } else {
                    parkOnSinkThread(track, ParkReason.PERMANENT_LOSS)
                }
                permanentStopAppliedCount++
            }
            Tag.FOCUS_UNKNOWN -> {
                unknownEventCount++
                throw FailClosed("unknown_focus_event:${event.rawFocusChange}")
            }
        }
    }

    // AudioTrack.pause() here, after the current window was fully written;
    // publishes PARKED plus the prefix snapshot (checksum, last drain reply)
    // the coordinator uses for prefix identity on terminal scenarios.
    private fun parkOnSinkThread(track: AudioTrack, reason: ParkReason) {
        if (!played) throw FailClosed("park_before_first_play:${reason.name.lowercase()}")
        track.pause()
        val pausedState = track.playState
        playStateAtPark = pausedState
        observedPlayState = pausedState
        if (pausedState != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("audio_track_pause_failed:$pausedState")
        framesWrittenAtPark = framesWrittenToSink
        drainCallsAtPark = drainCalls
        playbackHeadAtPark = rawHead()
        checksumAtPark = checksum
        replyAtPark = lastReply
        parkedAtMs = SystemClock.elapsedRealtime()
        parkReason = reason
        parkCount++
        phaseRef.set(Phase.PARKED)
    }

    private fun unparkOnSinkThread(track: AudioTrack) {
        playbackHeadAtUnpark = rawHead()
        track.play()
        val playingState = track.playState
        playStateAfterUnpark = playingState
        observedPlayState = playingState
        if (playingState != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("audio_track_resume_play_failed:$playingState")
        val now = SystemClock.elapsedRealtime()
        parkedHoldMs = if (parkedAtMs >= 0L) now - parkedAtMs else -1L
        unparkCount++
        lastProgressMs = now
        parkReason = ParkReason.NONE
        phaseRef.set(Phase.RUNNING)
    }

    // While PARKED the sink thread never drains or writes; it keeps the
    // published play state fresh and applies queued events (a GAIN unparks
    // when auto-resume is still allowed; after a terminal event it is
    // recorded and rejected). Exits on requestExit, cancel, deadline, cap.
    private fun parkedWait(track: AudioTrack) {
        val capAtMs = parkedAtMs + PARK_MAX_HOLD_MS
        while (phaseRef.get() == Phase.PARKED) {
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
            applyPendingEvents()
        }
    }

    // ── Drain loop ─────────────────────────────────────────────────────────

    private fun drainLoop() {
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        val bytesPerFrame = 2 * config.channelCount
        val drainBuffer = ByteBuffer.allocateDirect(config.maxFramesPerMix * bytesPerFrame).order(ByteOrder.nativeOrder())
        val maxProductiveDrains = (config.declaredFrameCount / config.maxFramesPerMix + 1L) * DRAIN_ITERATION_SLACK +
            DRAIN_ITERATION_MARGIN
        var productiveDrains = 0L
        lastProgressMs = SystemClock.elapsedRealtime()
        while (true) {
            checkDeadlineAndCancel()
            checkTerminalExit()
            applyPendingEvents()
            if (phaseRef.get() == Phase.PARKED) {
                parkedWait(track)
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
                if (++productiveDrains > maxProductiveDrains) throw FailClosed("drain_iteration_budget_exhausted")
                if (framesReadFromTransport + framesRead > config.declaredFrameCount) {
                    throw FailClosed("drain_exceeds_declared:${framesReadFromTransport + framesRead}")
                }
                accumulateChecksum(drainBuffer, framesRead)
                framesReadFromTransport += framesRead
                writeAllToAudioTrack(drainBuffer, framesRead * bytesPerFrame, bytesPerFrame)
                if (!played) {
                    track.play()
                    played = true
                    observedPlayState = track.playState
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
    }

    private fun catchUpPlaybackHead() {
        val catchUpDeadline = SystemClock.elapsedRealtime() + HEAD_CATCHUP_MARGIN_MS
        while (rawHead() < framesWrittenToSink) {
            checkDeadlineAndCancel()
            if (SystemClock.elapsedRealtime() > catchUpDeadline) break
            SystemClock.sleep(HEAD_POLL_SLEEP_MS)
        }
        playbackHeadFinal = rawHead()
        playbackHeadCaughtUp = playbackHeadFinal >= framesWrittenToSink
        if (playbackHeadFinal <= 0L) throw FailClosed("playback_head_not_advanced")
    }

    // Sink thread; exactly once. Fields are nulled first so a throwing
    // release is never retried on a dead object.
    private fun releaseAudioTrackOnce() {
        val track = audioTrack ?: return
        audioTrack = null
        if (releaseCount.get() > 0) return
        if (playbackHeadFinal == 0L) {
            try {
                playbackHeadFinal = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            } catch (_: Throwable) {}
        }
        try { track.stop() } catch (_: Throwable) {}
        try { track.release() } catch (_: Throwable) {}
        releaseCount.incrementAndGet()
    }
}
