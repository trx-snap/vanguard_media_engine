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

// ── VanguardRealtimePlaybackAudioTrackSinkBridge (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-INTEGRATION-A, Y6a) ─
//
// One NON-ZERO-GAIN android.media.AudioTrack (MODE_STREAM, PCM16) sink
// that runs on ITS OWN sink thread and pulls mixed PCM16 from a caller-
// owned [VanguardRealtimePlaybackTransportStateMachine] through `drain()`
// and `snapshot()` ONLY. It never calls load/prepare/start/pause/resume/
// seek/stop/dispose: the coordinator owns every transport command, and
// this bridge only starts after the coordinator started the transport.
//
// Per drain window: the popped frames are checksummed (checksum =
// checksum * 31 + uint16(sample), the native drainedChecksum identity),
// then written to the AudioTrack with WRITE_NON_BLOCKING; a partial write
// is retried in place from the unwritten remainder, a zero write is parked
// and retried under a bounded consecutive budget, and any AudioTrack error
// fails closed. Empty drains while the transport is not yet EOS are
// nonterminal (the native worker may be backpressured or the external
// track starved); a time-based stall bound and the shared deadline keep
// the loop finite. The loop exits when a drain reply reports eosDrained;
// a bounded playback-head catch-up wait then records the final head.
//
// The AudioTrack is stopped and released exactly once, on the sink
// thread, on every exit path (eos, cancel, deadline, failure). Y2 sink
// write-accounting ideas are reused; the Y2 sink itself is not, because
// it owns load/prepare/start.
class VanguardRealtimePlaybackAudioTrackSinkBridge(private val config: Config) {

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
        val threadName: String = "VanguardY6aSinkBridge",
        val externallyCancelled: () -> Boolean = { false },
    )

    companion object {
        const val DEFAULT_BASE_VOLUME = 0.5f

        const val EXIT_RUNNING = ""
        const val EXIT_EOS = "eos"
        const val EXIT_CANCELLED = "cancelled"
        const val EXIT_DEADLINE = "deadline_exceeded"
        const val EXIT_NOT_STARTED = "not_started"

        private const val TRACK_BUFFER_MARGIN_WINDOWS = 4L
        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val DRAIN_STALL_SLEEP_MS = 2L
        private const val DRAIN_STALL_TIMEOUT_MS = 3_000L
        private const val DRAIN_ITERATION_MARGIN = 64L
        private const val DRAIN_ITERATION_SLACK = 4L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_CATCHUP_MARGIN_MS = 3_000L

        fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class FailClosed(val reason: String) : Exception(reason)

    // ── Cross-thread control ───────────────────────────────────────────────

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val exitLatch = CountDownLatch(1)
    val releaseCount = AtomicInteger(0)

    @Volatile
    private var thread: Thread? = null

    // ── Published telemetry (volatile: written by the sink thread) ─────────

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

    @Volatile
    private var checksum: Long = 0L

    val checksumHex: String get() = hex16(checksum)
    val isAlive: Boolean get() = thread?.isAlive == true

    // ── Sink-thread-confined state ─────────────────────────────────────────

    private var audioTrack: AudioTrack? = null

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

    // Any thread. The sink thread observes the flag at its next bounded
    // wait and releases the AudioTrack on its own thread.
    fun cancel() {
        cancelled.set(true)
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

    private fun drainLoop() {
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        val bytesPerFrame = 2 * config.channelCount
        val drainBuffer = ByteBuffer.allocateDirect(config.maxFramesPerMix * bytesPerFrame).order(ByteOrder.nativeOrder())
        // Partial windows are legal, so the productive-drain budget is loose;
        // the hard invariant is that reads never exceed the declared count.
        val maxProductiveDrains = (config.declaredFrameCount / config.maxFramesPerMix + 1L) * DRAIN_ITERATION_SLACK +
            DRAIN_ITERATION_MARGIN
        var productiveDrains = 0L
        var lastProgressMs = SystemClock.elapsedRealtime()
        while (true) {
            checkDeadlineAndCancel()
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
