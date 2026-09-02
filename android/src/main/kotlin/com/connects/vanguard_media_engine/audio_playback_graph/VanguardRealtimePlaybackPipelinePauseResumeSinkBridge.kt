package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioAttributes
import android.media.AudioFormat
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

// ── VanguardRealtimePlaybackPipelinePauseResumeSinkBridge (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-PAUSE-RESUME, Y6b) ─
//
// Phase-controlled variant of the Y6a AudioTrack sink bridge. One NON-ZERO-
// GAIN android.media.AudioTrack (MODE_STREAM, PCM16) runs on ITS OWN sink
// thread and pulls mixed PCM16 from a caller-owned
// [VanguardRealtimePlaybackTransportStateMachine] through `drain()` ONLY.
// It never issues a transport command (load/prepare/start/pause/resume/
// seek/stop/dispose); the coordinator owns every transport command and
// this bridge only starts after the coordinator started the transport.
//
// Sink phase protocol (the only Y6b addition over Y6a):
//
//   RUNNING --requestPark()--> PARK_REQUESTED --(sink thread)--> PARKED
//   PARKED  --unpark()------> (sink thread: AudioTrack.play) --> RUNNING
//
// - [requestPark] (any thread) only flips RUNNING -> PARK_REQUESTED. The
//   sink thread observes the request at the TOP of its drain loop, i.e.
//   after the current drain window was fully written to the AudioTrack,
//   then calls AudioTrack.pause() ON THE SINK THREAD, records the play
//   state, publishes PARKED and releases the park-ack latch.
// - While PARKED the sink thread waits (bounded by the shared deadline, a
//   hard park cap and the cancel flag) for [unpark]; it never drains, never
//   writes and keeps observing the AudioTrack play state so the
//   coordinator can read [observedPlayState] without touching AudioTrack.
// - [unpark] (any thread) wakes the sink thread, which calls
//   AudioTrack.play() ON THE SINK THREAD, records the play state, resets its
//   stall/progress clock, publishes RUNNING, releases the unpark-ack latch
//   and resumes draining to EOS.
//
// Every AudioTrack method (create/setVolume/play/pause/write/
// playbackHeadPosition/playState/stop/release) executes on the sink thread;
// coordinators only read published volatiles. The AudioTrack is stopped and
// released exactly once, on the sink thread, on every exit path (eos,
// cancel, deadline, failure, park timeout). No seek, no AudioTrack flush,
// no feed re-anchor, no focus/noisy/route/dead-object handling lives here.
class VanguardRealtimePlaybackPipelinePauseResumeSinkBridge(private val config: Config) {

    data class Config(
        val stateMachine: VanguardRealtimePlaybackTransportStateMachine,
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val declaredFrameCount: Long,
        // Non-zero linear gain applied with AudioTrack.setVolume; (0, 1].
        val baseVolume: Float = DEFAULT_BASE_VOLUME,
        // Absolute SystemClock.elapsedRealtime() deadline shared by the whole pipeline.
        val deadlineAtMs: Long,
        val threadName: String = "VanguardY6bSinkBridge",
        val externallyCancelled: () -> Boolean = { false },
    )

    enum class Phase { RUNNING, PARK_REQUESTED, PARKED }

    companion object {
        const val DEFAULT_BASE_VOLUME = 0.5f

        const val EXIT_RUNNING = ""
        const val EXIT_EOS = "eos"
        const val EXIT_CANCELLED = "cancelled"
        const val EXIT_DEADLINE = "deadline_exceeded"
        const val EXIT_NOT_STARTED = "not_started"

        // Play state published before any AudioTrack observation exists.
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
        // Hard cap on one parked hold, independent of the shared deadline.
        private const val PARK_MAX_HOLD_MS = 10_000L

        fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class FailClosed(val reason: String) : Exception(reason)

    // ── Cross-thread control ───────────────────────────────────────────────

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val exitLatch = CountDownLatch(1)
    val releaseCount = AtomicInteger(0)

    private val phaseRef = AtomicReference(Phase.RUNNING)
    private val parkLock = ReentrantLock()
    private val parkCondition = parkLock.newCondition()

    // Guarded by parkLock.
    private var unparkRequested = false

    @Volatile
    private var parkAckLatch = CountDownLatch(1)

    @Volatile
    private var unparkAckLatch = CountDownLatch(1)

    @Volatile
    private var thread: Thread? = null

    // ── Published telemetry (volatile: written by the sink thread) ─────────

    val phase: Phase get() = phaseRef.get()

    @Volatile
    var exitReason: String = EXIT_NOT_STARTED
        private set

    @Volatile
    var threadId: Long = -1L
        private set

    @Volatile
    var threadIsTransportOwner: Boolean = false
        private set

    @Volatile
    var audioTrackInitOk: Boolean = false
        private set

    @Volatile
    var gainSetOk: Boolean = false
        private set

    @Volatile
    var gainValue: Float = 0f
        private set

    @Volatile
    var audioTrackBufferBytes: Int = 0
        private set

    @Volatile
    var played: Boolean = false
        private set

    @Volatile
    var framesReadFromTransport: Long = 0L
        private set

    @Volatile
    var framesWrittenToSink: Long = 0L
        private set

    @Volatile
    var partialWriteCount: Long = 0L
        private set

    @Volatile
    var zeroWriteCount: Long = 0L
        private set

    @Volatile
    var drainCalls: Long = 0L
        private set

    @Volatile
    var emptyDrainCount: Long = 0L
        private set

    @Volatile
    var eosDrainedObserved: Boolean = false
        private set

    @Volatile
    var playbackHeadFinal: Long = 0L
        private set

    @Volatile
    var playbackHeadCaughtUp: Boolean = false
        private set

    @Volatile
    var sinkThreadWallMs: Long = 0L
        private set

    @Volatile
    var firstWriteAtMs: Long = -1L
        private set

    @Volatile
    var lastReply: Reply? = null
        private set

    // Park / unpark telemetry (sink thread writes; coordinator reads).

    @Volatile
    var parkRequestCount: Int = 0
        private set

    @Volatile
    var parkCount: Int = 0
        private set

    @Volatile
    var unparkCount: Int = 0
        private set

    // Play state observed on the sink thread: at park, then every park
    // poll slice while PARKED, then right after AudioTrack.play() on unpark.
    @Volatile
    var observedPlayState: Int = PLAY_STATE_UNKNOWN
        private set

    @Volatile
    var playStateAtPark: Int = PLAY_STATE_UNKNOWN
        private set

    @Volatile
    var playStateAfterUnpark: Int = PLAY_STATE_UNKNOWN
        private set

    @Volatile
    var parkedPlayStateObservations: Long = 0L
        private set

    @Volatile
    var parkedPlayStateViolations: Long = 0L
        private set

    @Volatile
    var parkExecutedOnSinkThread: Boolean = false
        private set

    @Volatile
    var unparkExecutedOnSinkThread: Boolean = false
        private set

    @Volatile
    var framesWrittenAtPark: Long = 0L
        private set

    @Volatile
    var drainCallsAtPark: Long = 0L
        private set

    @Volatile
    var playbackHeadAtPark: Long = 0L
        private set

    @Volatile
    var playbackHeadAtUnpark: Long = 0L
        private set

    @Volatile
    var parkAckLatencyMs: Long = -1L
        private set

    @Volatile
    var parkedHoldMs: Long = -1L
        private set

    @Volatile
    private var parkRequestedAtMs: Long = -1L

    @Volatile
    private var checksum: Long = 0L

    val checksumHex: String get() = hex16(checksum)
    val isAlive: Boolean get() = thread?.isAlive == true

    // ── Sink-thread-confined state ─────────────────────────────────────────

    private var audioTrack: AudioTrack? = null
    private var lastProgressMs: Long = 0L

    // ── Public API ─────────────────────────────────────────────────────────

    // Starts the sink thread. Single use; false when already started.
    fun start(): Boolean {
        if (!started.compareAndSet(false, true)) return false
        exitReason = EXIT_RUNNING
        val t = Thread({ runOnSinkThread() }, config.threadName)
        thread = t
        t.start()
        return true
    }

    // Any thread. Flips RUNNING -> PARK_REQUESTED; the sink thread parks at
    // the top of its next drain iteration. False when not RUNNING.
    fun requestPark(): Boolean {
        if (!started.get()) return false
        parkAckLatch = CountDownLatch(1)
        unparkAckLatch = CountDownLatch(1)
        if (!phaseRef.compareAndSet(Phase.RUNNING, Phase.PARK_REQUESTED)) return false
        parkRequestedAtMs = SystemClock.elapsedRealtime()
        parkRequestCount++
        return true
    }

    // Bounded wait for the sink thread's park ack; true only when the sink
    // really is PARKED (the latch is also released on sink exit).
    fun awaitParked(timeoutMs: Long): Boolean =
        parkAckLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && phaseRef.get() == Phase.PARKED

    // Any thread. Wakes a PARKED sink thread; it calls AudioTrack.play() on
    // its own thread and publishes RUNNING. False when not PARKED.
    fun unpark(): Boolean {
        parkLock.withLock {
            if (phaseRef.get() != Phase.PARKED) return false
            unparkRequested = true
            parkCondition.signalAll()
        }
        return true
    }

    // Bounded wait for the sink thread's unpark ack; true only when the
    // sink is RUNNING again with a play() executed on the sink thread.
    fun awaitRunning(timeoutMs: Long): Boolean =
        unparkAckLatch.await(timeoutMs, TimeUnit.MILLISECONDS) &&
            phaseRef.get() == Phase.RUNNING && unparkCount > 0

    // Any thread. The sink thread observes the flag at its next bounded
    // wait (including a parked wait) and releases the AudioTrack on its
    // own thread.
    fun cancel() {
        cancelled.set(true)
        parkLock.withLock { parkCondition.signalAll() }
    }

    // Bounded join; true when the sink thread has exited (or never ran).
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
            // A coordinator waiting for a park/unpark ack must never block on
            // a dead sink; it re-checks [phase] / counts after the latch.
            parkAckLatch.countDown()
            unparkAckLatch.countDown()
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
    }

    private fun isCancelled(): Boolean = cancelled.get() || config.externallyCancelled()

    private fun checkDeadlineAndCancel() {
        if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
        if (SystemClock.elapsedRealtime() > config.deadlineAtMs) throw FailClosed(EXIT_DEADLINE)
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
        if (track.setVolume(config.baseVolume) != AudioTrack.SUCCESS) throw FailClosed("audio_track_set_volume_failed")
        gainValue = config.baseVolume
        gainSetOk = config.baseVolume > 0f
    }

    private fun rawHead(): Long {
        val track = audioTrack ?: return 0L
        return track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
    }

    // Mirrors the native drain checksum accumulation over exactly the frames
    // this call is about to hand to AudioTrack.write; a failure anywhere in
    // that write aborts the run, so a checksum counted here is always one
    // this bridge fully accepted.
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
                    if (firstWriteAtMs < 0L) firstWriteAtMs = SystemClock.elapsedRealtime()
                    if (wrote < requested) {
                        partialWriteCount++
                        // Retry in place from the unwritten remainder.
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

    // ── Park / unpark (sink thread only) ───────────────────────────────────

    // Runs at the top of the drain loop once PARK_REQUESTED was observed,
    // i.e. after the previous window was fully written. Pauses the
    // AudioTrack here, acks, then waits (bounded, cancel-aware) for unpark
    // and plays the AudioTrack here again before returning to the drains.
    private fun parkOnSinkThread() {
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        if (!played) throw FailClosed("park_before_first_play")
        val onSinkThread = Thread.currentThread().id == threadId

        track.pause()
        val pausedState = track.playState
        playStateAtPark = pausedState
        observedPlayState = pausedState
        if (pausedState != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("audio_track_pause_failed:$pausedState")
        framesWrittenAtPark = framesWrittenToSink
        drainCallsAtPark = drainCalls
        playbackHeadAtPark = rawHead()
        parkExecutedOnSinkThread = onSinkThread
        val parkedAtMs = SystemClock.elapsedRealtime()
        val requestedAt = parkRequestedAtMs
        parkAckLatencyMs = if (requestedAt >= 0L) parkedAtMs - requestedAt else -1L
        parkCount++
        phaseRef.set(Phase.PARKED)
        parkAckLatch.countDown()

        val parkCapAtMs = parkedAtMs + PARK_MAX_HOLD_MS
        parkLock.withLock {
            while (!unparkRequested) {
                if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
                val now = SystemClock.elapsedRealtime()
                if (now > config.deadlineAtMs) throw FailClosed(EXIT_DEADLINE)
                if (now > parkCapAtMs) throw FailClosed("park_hold_timeout")
                try {
                    parkCondition.await(PARK_POLL_MS, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw FailClosed("interrupted_while_parked")
                }
                // Keep the published play state fresh while parked so the
                // coordinator never has to touch the AudioTrack itself.
                val observed = track.playState
                observedPlayState = observed
                parkedPlayStateObservations++
                if (observed != AudioTrack.PLAYSTATE_PAUSED) parkedPlayStateViolations++
            }
            unparkRequested = false
        }

        playbackHeadAtUnpark = rawHead()
        track.play()
        val playingState = track.playState
        playStateAfterUnpark = playingState
        observedPlayState = playingState
        unparkExecutedOnSinkThread = Thread.currentThread().id == threadId
        if (playingState != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("audio_track_resume_play_failed:$playingState")
        val now = SystemClock.elapsedRealtime()
        parkedHoldMs = now - parkedAtMs
        unparkCount++
        // The parked interval is not a stall.
        lastProgressMs = now
        phaseRef.set(Phase.RUNNING)
        unparkAckLatch.countDown()
    }

    // ── Drain loop ─────────────────────────────────────────────────────────

    private fun drainLoop() {
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        val bytesPerFrame = 2 * config.channelCount
        val drainBuffer = ByteBuffer.allocateDirect(config.maxFramesPerMix * bytesPerFrame).order(ByteOrder.nativeOrder())
        // Partial windows are legal, so the productive-drain budget is loose;
        // the hard invariant is that reads never exceed the declared count.
        val maxProductiveDrains = (config.declaredFrameCount / config.maxFramesPerMix + 1L) * DRAIN_ITERATION_SLACK +
            DRAIN_ITERATION_MARGIN
        var productiveDrains = 0L
        lastProgressMs = SystemClock.elapsedRealtime()
        while (true) {
            checkDeadlineAndCancel()
            if (phaseRef.get() == Phase.PARK_REQUESTED) parkOnSinkThread()
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
                // Nonterminal: worker backpressure or a starved external
                // track; the transport records it, the sink only waits.
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
