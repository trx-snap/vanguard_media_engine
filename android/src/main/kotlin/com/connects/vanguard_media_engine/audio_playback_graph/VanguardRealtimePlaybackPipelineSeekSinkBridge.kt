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

// ── VanguardRealtimePlaybackPipelineSeekSinkBridge (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SEEK, Y6c) ─
//
// Seek-capable variant of the Y6b phase-controlled AudioTrack sink bridge.
// One NON-ZERO-GAIN android.media.AudioTrack (MODE_STREAM, PCM16) runs on
// ITS OWN sink thread and pulls mixed PCM16 from a caller-owned
// [VanguardRealtimePlaybackTransportStateMachine] through `drain()` ONLY.
// It never issues a transport command; the coordinator owns every
// transport command and this bridge only starts after the transport did.
//
// Sink phase protocol (Y6b) plus the Y6c flush step:
//
//   RUNNING --requestPark()--> PARK_REQUESTED --(sink thread)--> PARKED
//   PARKED  --requestFlush(n)-> (sink thread: AudioTrack.flush, exactly once)
//   PARKED  --unpark()-------> (sink thread: AudioTrack.play) --> RUNNING
//
// - [requestFlush] is honoured only while PARKED (AudioTrack PAUSED). The
//   sink thread executes AudioTrack.flush() ON THE SINK THREAD exactly
//   once, records the pre/post flush playback head and play state, and
//   opens the second accounting epoch: the read budget becomes
//   framesReadAtFlush + postSeekExpectedFrames and every later drain is
//   checked against it (two-epoch accounting: pre-seek + post-seek).
// - On unpark the sink thread calls AudioTrack.play() and captures the
//   post-flush playback head as the epoch base; the playback-head proof is
//   epoch-relative (head - base), never a cumulative catch-up across the
//   flush, because a flushed MODE_STREAM track restarts its head.
//
// Every AudioTrack method executes on the sink thread; coordinators only
// read published volatiles. The AudioTrack is stopped and released exactly
// once, on the sink thread, on every exit path. No seek command, no feed
// re-anchor, no focus/noisy/route/dead-object handling lives here.
class VanguardRealtimePlaybackPipelineSeekSinkBridge(private val config: Config) {

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
        val threadName: String = "VanguardY6cSeekSinkBridge",
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
        // Hard cap on one parked hold (covers pause, flush, seek, decoder
        // re-seek and post-seek pre-roll), independent of the shared deadline.
        private const val PARK_MAX_HOLD_MS = 15_000L

        fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class FailClosed(val reason: String) : Exception(reason)

    // ── Cross-thread control ───────────────────────────────────────────────

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val exitLatch = CountDownLatch(1)
    private val flushAckLatch = CountDownLatch(1)
    val releaseCount = AtomicInteger(0)

    private val phaseRef = AtomicReference(Phase.RUNNING)
    private val parkLock = ReentrantLock()
    private val parkCondition = parkLock.newCondition()

    // Guarded by parkLock.
    private var unparkRequested = false
    private var flushRequested = false
    private var flushRequestedAtMs = -1L

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

    // Flush / two-epoch telemetry.

    @Volatile
    var flushRequestCount: Int = 0
        private set

    @Volatile
    var flushCount: Int = 0
        private set

    @Volatile
    var flushExecutedOnSinkThread: Boolean = false
        private set

    @Volatile
    var flushAckLatencyMs: Long = -1L
        private set

    @Volatile
    var playStateBeforeFlush: Int = PLAY_STATE_UNKNOWN
        private set

    @Volatile
    var playStateAfterFlush: Int = PLAY_STATE_UNKNOWN
        private set

    @Volatile
    var playbackHeadBeforeFlush: Long = -1L
        private set

    @Volatile
    var playbackHeadAfterFlush: Long = -1L
        private set

    @Volatile
    var framesWrittenAtFlush: Long = -1L
        private set

    @Volatile
    var framesReadAtFlush: Long = -1L
        private set

    @Volatile
    var drainCallsAtFlush: Long = -1L
        private set

    @Volatile
    var postSeekExpectedFrames: Long = -1L
        private set

    // Upper bound on framesReadFromTransport: declared before the flush,
    // framesReadAtFlush + postSeekExpectedFrames after it.
    @Volatile
    var readBudgetFrames: Long = 0L
        private set

    // Raw playback head right after the post-flush AudioTrack.play().
    @Volatile
    var playbackHeadEpochBase: Long = -1L
        private set

    @Volatile
    var epochBaseCaptured: Boolean = false
        private set

    // Epoch-relative head at exit (raw final head - epoch base).
    @Volatile
    var postSeekPlaybackHeadFrames: Long = -1L
        private set

    @Volatile
    private var parkRequestedAtMs: Long = -1L

    @Volatile
    private var checksum: Long = 0L

    val checksumHex: String get() = hex16(checksum)
    val isAlive: Boolean get() = thread?.isAlive == true

    // Frames written to the AudioTrack after the flush (second epoch).
    val postSeekFramesWritten: Long
        get() = if (flushCount > 0) framesWrittenToSink - framesWrittenAtFlush else 0L

    // ── Sink-thread-confined state ─────────────────────────────────────────

    private var audioTrack: AudioTrack? = null
    private var lastProgressMs: Long = 0L

    // ── Public API ─────────────────────────────────────────────────────────

    // Starts the sink thread. Single use; false when already started.
    fun start(): Boolean {
        if (!started.compareAndSet(false, true)) return false
        exitReason = EXIT_RUNNING
        readBudgetFrames = config.declaredFrameCount
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

    // Any thread. Asks the PARKED sink thread to AudioTrack.flush() exactly
    // once and to open the post-seek accounting epoch of `postSeekFrames`
    // expected transport reads. False when not PARKED, already requested,
    // or the count is not positive.
    fun requestFlush(postSeekFrames: Long): Boolean {
        if (postSeekFrames <= 0L) return false
        parkLock.withLock {
            if (phaseRef.get() != Phase.PARKED) return false
            if (flushRequested || flushCount > 0) return false
            flushRequested = true
            flushRequestedAtMs = SystemClock.elapsedRealtime()
            postSeekExpectedFrames = postSeekFrames
            flushRequestCount++
            parkCondition.signalAll()
        }
        return true
    }

    // Bounded wait for the sink thread's flush ack; true only when the
    // flush executed exactly once (the latch is also released on sink exit).
    fun awaitFlushed(timeoutMs: Long): Boolean =
        flushAckLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && flushCount == 1

    // Any thread. Wakes a PARKED sink thread; it calls AudioTrack.play() on
    // its own thread and publishes RUNNING. False when not PARKED or when a
    // requested flush has not executed yet.
    fun unpark(): Boolean {
        parkLock.withLock {
            if (phaseRef.get() != Phase.PARKED) return false
            if (flushRequested && flushCount == 0) return false
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
            // A coordinator waiting for a park/flush/unpark ack must never
            // block on a dead sink; it re-checks phase / counts after the latch.
            parkAckLatch.countDown()
            flushAckLatch.countDown()
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
    // this call is about to hand to AudioTrack.write.
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

    // ── Flush (sink thread only, while PARKED, exactly once) ───────────────

    // Runs inside the parked wait under parkLock. The AudioTrack must be
    // PAUSED (flush is a no-op otherwise); afterwards the second accounting
    // epoch is open and the play state must still read PAUSED.
    private fun flushOnSinkThread(track: AudioTrack) {
        val before = track.playState
        playStateBeforeFlush = before
        if (before != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("audio_track_flush_not_paused:$before")
        playbackHeadBeforeFlush = rawHead()
        track.flush()
        playbackHeadAfterFlush = rawHead()
        val after = track.playState
        playStateAfterFlush = after
        observedPlayState = after
        if (after != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("audio_track_flush_changed_play_state:$after")
        framesWrittenAtFlush = framesWrittenToSink
        framesReadAtFlush = framesReadFromTransport
        drainCallsAtFlush = drainCalls
        readBudgetFrames = framesReadAtFlush + postSeekExpectedFrames
        flushExecutedOnSinkThread = Thread.currentThread().id == threadId
        val requestedAt = flushRequestedAtMs
        flushAckLatencyMs = if (requestedAt >= 0L) SystemClock.elapsedRealtime() - requestedAt else -1L
        flushCount++
        flushAckLatch.countDown()
    }

    // ── Park / unpark (sink thread only) ───────────────────────────────────

    // Runs at the top of the drain loop once PARK_REQUESTED was observed,
    // i.e. after the previous window was fully written. Pauses the
    // AudioTrack here, acks, then waits (bounded, cancel-aware) for a flush
    // request and/or unpark, and plays the AudioTrack here again before
    // returning to the drains.
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
            while (true) {
                // A requested flush always executes before an unpark is honoured.
                if (flushRequested && flushCount == 0) flushOnSinkThread(track)
                if (unparkRequested) break
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
        if (flushCount > 0) {
            // Post-flush epoch base: the head proof is measured from here.
            playbackHeadEpochBase = rawHead()
            epochBaseCaptured = true
        }
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
        // the hard invariant is that reads never exceed the epoch budget.
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
                if (framesReadFromTransport + framesRead > readBudgetFrames) {
                    throw FailClosed("drain_exceeds_expected:${framesReadFromTransport + framesRead}:$readBudgetFrames")
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
                // Nonterminal: worker backpressure or a starved/held external
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

    // Epoch-relative catch-up: after a flush the head is measured from the
    // post-flush play() base against the frames written since the flush;
    // without a flush it degrades to the Y6b cumulative check.
    private fun catchUpPlaybackHead() {
        val flushed = flushCount > 0
        val base = if (flushed && epochBaseCaptured) playbackHeadEpochBase else 0L
        val epochWritten = if (flushed) framesWrittenToSink - framesWrittenAtFlush else framesWrittenToSink
        val catchUpDeadline = SystemClock.elapsedRealtime() + HEAD_CATCHUP_MARGIN_MS
        while (rawHead() - base < epochWritten) {
            checkDeadlineAndCancel()
            if (SystemClock.elapsedRealtime() > catchUpDeadline) break
            SystemClock.sleep(HEAD_POLL_SLEEP_MS)
        }
        playbackHeadFinal = rawHead()
        val relative = playbackHeadFinal - base
        postSeekPlaybackHeadFrames = if (flushed) relative else -1L
        playbackHeadCaughtUp = relative >= epochWritten
        if (relative <= 0L) throw FailClosed(if (flushed) "post_seek_playback_head_not_advanced" else "playback_head_not_advanced")
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
