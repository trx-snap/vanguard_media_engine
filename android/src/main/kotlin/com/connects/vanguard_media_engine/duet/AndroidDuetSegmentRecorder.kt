package com.connects.vanguard_media_engine.duet

// -----------------------------------------------------------------------------
// ANDROID-DUET-SLICE-1A: Per-take live segment recorder for the Duet preview
// (H.264 surface-input video + best-effort AAC microphone audio -> MP4).
// -----------------------------------------------------------------------------
//
// One instance == one take == one MP4 file. The GLES preview compositor draws
// the upright live camera frame it has ALREADY latched for the preview into
// [inputSurface] on its own render thread (AndroidDuetPreviewCompositor.
// setSegmentRecorderTarget); this class never touches GL, never reads pixels
// back, never sees a Bitmap and never binds a CameraX ImageAnalysis stream.
// It owns:
//   - the AVC MediaCodec (COLOR_FormatSurface) and its input Surface,
//   - a best-effort AudioRecord -> AAC MediaCodec microphone lane,
//   - the MediaMuxer writing "<output>.tmp", atomically renamed on success,
//   - one worker thread ("vg.duet.rec.video") that drains the video encoder,
//     arbitrates muxer start and runs finalize, plus one audio thread
//     ("vg.duet.rec.audio").
//
// Muxer start policy (never deadlocks waiting for a track): the muxer starts
// once the video output format exists AND the audio lane is either disabled,
// has produced its output format, or has been given up on after a bounded
// grace window (AUDIO_TRACK_GRACE_MS) / at finish. Pre-start samples of both
// tracks are buffered (bounded) so the IDR frame at PTS 0 is never lost.
//
// Timing policy:
//   - The take timeline origin is the wall-clock instant of the FIRST camera
//     frame the compositor submits; that frame carries PTS 0.
//   - Video PTS = wall elapsed since origin * [speedMultiplier] (the Duet
//     preview clock's "T_out = S * T_wall" policy), so the file's video
//     duration equals the clock segment's output duration for this take.
//   - Mic audio is time-stretched to match: for |speedMultiplier - 1| above a
//     small epsilon, captured PCM is run through AndroidDuetWsolaFilter (a
//     self-contained WSOLA time-domain stretcher) before AAC encoding, so the
//     emitted sample count approximates inputSamples * speedMultiplier and
//     pitch is preserved. Speeds within the epsilon of 1.0 bypass the filter
//     (direct passthrough) as a low-risk path. The filter is instantiated once
//     per take from the speed frozen before [originNanos] is set (a take never
//     changes rate mid-file — see [setSpeedMultiplier]), so one constant speed
//     per take is assumed. Audio encoder PTS is derived from
//     [audioSamplesFed], which counts samples actually submitted to the AAC
//     encoder (post-WSOLA output samples for non-1.0 speed), not raw mic
//     samples read, so it stays continuous and the audio track's duration now
//     matches the retimed video track within about one frame.
//   - [micGain] is descriptor metadata applied at export; the mic lane records
//     unity gain so the descriptor's gain is never baked in twice.
//
// Threading / contract:
//   - start() is called once on the caller's thread (the coordinator's main
//     thread); it does the bounded codec/muxer configuration inline (needed
//     to hand out [inputSurface] synchronously) and spawns the workers.
//   - nextFramePresentationTimeNs()/onFrameSubmitted() are render-thread only.
//   - finishAsync()/cancel() are safe from any thread, idempotent, and never
//     block the caller. Exactly one completion result is ever produced; a
//     finishAsync() after completion re-delivers that same result.

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs

class AndroidDuetSegmentRecorder(
    private val context: Context,
    val outputFile: File,
    override val widthPx: Int = DEFAULT_WIDTH_PX,
    override val heightPx: Int = DEFAULT_HEIGHT_PX,
    private val bitRate: Int = DEFAULT_BIT_RATE,
    private val fps: Int = DEFAULT_FPS,
    speedMultiplier: Double = 1.0,
    private val micGain: Double = 1.0,
) : AndroidDuetSegmentRecorderSurfaceTarget {

    companion object {
        private const val TAG = "DuetSegmentRecorder"

        const val DEFAULT_WIDTH_PX = 1080
        const val DEFAULT_HEIGHT_PX = 1920
        const val DEFAULT_BIT_RATE = 10_000_000
        const val DEFAULT_FPS = 30

        /** GOP of one second at [DEFAULT_FPS] (<= 30 frames). */
        private const val I_FRAME_INTERVAL_SEC = 1

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val EOS_DRAIN_DEADLINE_MS = 4_000L
        private const val WORKER_JOIN_TIMEOUT_MS = 3_000L

        private const val AUDIO_SAMPLE_RATE = 44_100
        private const val AUDIO_BIT_RATE = 128_000
        private const val AUDIO_CHANNELS = 1

        /** Video-only fallback if the AAC lane produced no format this long after the video format. */
        private const val AUDIO_TRACK_GRACE_MS = 1_500L

        /** Bounded pre-muxer sample buffering per track (~4 s of video at 30 fps). */
        private const val MAX_PENDING_SAMPLES = 120

        /** Speeds within this of 1.0 bypass WSOLA entirely (direct/low-risk passthrough). */
        private const val WSOLA_BYPASS_EPSILON = 0.001
    }

    // -- Public state ---------------------------------------------------------------

    /** Positive speed multiplier applied to video PTS; adjustable until the first frame is stamped. */
    @Volatile
    private var speedMultiplier: Double = sanitizeSpeed(speedMultiplier)

    /**
     * Updates the video PTS speed policy. Takes effect only while no frame has
     * been stamped yet (the coordinator calls this right before the clock's
     * segment opens, after the async encoder-surface attach); later calls are
     * ignored so a take never changes rate mid-file.
     */
    fun setSpeedMultiplier(speed: Double) {
        if (originNanos >= 0L) return
        speedMultiplier = sanitizeSpeed(speed)
    }

    private fun sanitizeSpeed(speed: Double): Double =
        if (speed.isFinite() && speed > 0.0) speed else 1.0

    private val tmpFile = File(outputFile.path + ".tmp")

    @Volatile
    private var _inputSurface: Surface? = null

    /** Encoder input surface; non-null between a successful [start] and release. */
    override val inputSurface: Surface? get() = _inputSurface

    // -- Lifecycle flags ------------------------------------------------------------

    private val started = AtomicBoolean(false)
    private val finishRequested = AtomicBoolean(false)
    private val canceled = AtomicBoolean(false)

    /** Set once the worker thread has been started; cleanup then belongs to it. */
    @Volatile
    private var workerOwnsCleanup = false

    private val completionLock = Any()
    private var completion: ((Result<File>) -> Unit)? = null
    private var finalResult: Result<File>? = null

    // -- Timeline ---------------------------------------------------------------------

    /** Wall-clock (System.nanoTime) origin = first submitted video frame; -1 until then. */
    @Volatile
    private var originNanos = -1L

    private var lastVideoPtsNs = -1L
    private val framesSubmitted = AtomicInteger(0)

    // -- Video encoder (worker-owned after start) ----------------------------------------

    private var videoEncoder: MediaCodec? = null
    private var workerThread: Thread? = null
    private val videoWrittenSamples = AtomicInteger(0)

    /** Set when the AVC encoder entered an error state; the worker then aborts the take. */
    @Volatile private var videoEncoderFailed = false

    // -- Audio lane (best-effort) ---------------------------------------------------------

    private var audioThread: Thread? = null
    private var audioRecord: AudioRecord? = null
    private var audioEncoder: MediaCodec? = null
    private var audioReadBufferShorts = 0
    @Volatile private var audioConfigured = false
    @Volatile private var audioActive = false
    @Volatile private var audioFormatReady = false
    @Volatile private var audioPermanentlyDisabled = false
    private var audioSamplesFed = 0L
    private var audioBasePtsUs = 0L
    private var audioDisabledReason: String? = null

    // -- Muxer (shared by both lanes under muxerLock) -------------------------------------

    private class PendingSample(val data: ByteArray, val info: MediaCodec.BufferInfo)

    private val muxerLock = Any()
    private var muxer: MediaMuxer? = null
    @Volatile private var muxerStarted = false
    private var videoTrackIndex = -1
    private var audioTrackIndex = -1
    @Volatile private var videoFormatReady = false
    @Volatile private var videoFormatArrivedAtNanos = 0L
    private val pendingVideoSamples = ArrayDeque<PendingSample>()
    private val pendingAudioSamples = ArrayDeque<PendingSample>()

    // ── start ───────────────────────────────────────────────────────────────────

    /**
     * Configures the AVC encoder + input surface, the muxer (to the .tmp path)
     * and the best-effort audio lane, then starts the workers. Returns false
     * (with everything released and no file left behind) on any video/muxer
     * failure; an audio failure only logs and continues video-only. Call once.
     */
    fun start(): Boolean {
        if (!started.compareAndSet(false, true)) {
            Log.w(TAG, "start() called twice — ignored")
            return false
        }
        if (canceled.get()) return false
        if (widthPx <= 0 || heightPx <= 0) {
            Log.e(TAG, "start: invalid take size ${widthPx}x$heightPx")
            deliver(Result.failure(IllegalArgumentException("invalid take size")))
            return false
        }
        try {
            val parent = outputFile.parentFile
            if (parent != null && !parent.exists() && !parent.mkdirs() && !parent.exists()) {
                Log.e(TAG, "start: cannot create ${parent.absolutePath}")
                deliver(Result.failure(IllegalStateException("segment directory unavailable")))
                return false
            }
            if (tmpFile.exists()) tmpFile.delete()
        } catch (t: Throwable) {
            Log.e(TAG, "start: output path preparation failed: ${t.javaClass.simpleName}: ${t.message}")
            deliver(Result.failure(t))
            return false
        }

        var encoder: MediaCodec? = null
        var surface: Surface? = null
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, widthPx, heightPx).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_SEC)
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            encoder = enc
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            surface = enc.createInputSurface()
            enc.start()
        } catch (t: Throwable) {
            Log.e(TAG, "ANDROID_DUET_SEGMENT_RECORDER_START_FAILED stage=video_encoder ${t.javaClass.simpleName}: ${t.message}")
            try { encoder?.stop() } catch (_: Throwable) {}
            try { encoder?.release() } catch (_: Throwable) {}
            try { surface?.release() } catch (_: Throwable) {}
            deliver(Result.failure(t))
            return false
        }
        videoEncoder = encoder
        _inputSurface = surface

        try {
            muxer = MediaMuxer(tmpFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } catch (t: Throwable) {
            Log.e(TAG, "ANDROID_DUET_SEGMENT_RECORDER_START_FAILED stage=muxer ${t.javaClass.simpleName}: ${t.message}")
            releaseVideoResourcesQuietly()
            deleteQuietly(tmpFile)
            deliver(Result.failure(t))
            return false
        }

        setupAudioBestEffort()

        val worker = Thread({ runWorker() }, "vg.duet.rec.video")
        workerThread = worker
        workerOwnsCleanup = true
        worker.start()
        Log.i(
            TAG,
            "ANDROID_DUET_SEGMENT_RECORDER_STARTED file=${outputFile.name} size=${widthPx}x$heightPx " +
                "bitRate=$bitRate fps=$fps speed=$speedMultiplier micGain=$micGain " +
                "audio=${if (audioConfigured) "aac_${AUDIO_SAMPLE_RATE}_mono" else "disabled:${audioDisabledReason ?: "unknown"}"}",
        )
        return true
    }

    // ── Render-thread frame timing (AndroidDuetSegmentRecorderSurfaceTarget) ────

    override fun nextFramePresentationTimeNs(): Long {
        if (!started.get() || finishRequested.get() || canceled.get()) return -1L
        val now = System.nanoTime()
        var origin = originNanos
        if (origin < 0L) {
            origin = now
            originNanos = now
        }
        val wallNs = (now - origin).coerceAtLeast(0L)
        var pts = (wallNs.toDouble() * speedMultiplier).toLong()
        // Strictly monotonic container timestamps (two swaps can never share a PTS).
        if (pts <= lastVideoPtsNs) pts = lastVideoPtsNs + 1_000L
        lastVideoPtsNs = pts
        return pts
    }

    override fun onFrameSubmitted(presentationTimeNs: Long) {
        framesSubmitted.incrementAndGet()
    }

    // ── finish / cancel ───────────────────────────────────────────────────────────

    /**
     * Stops capture, drains both encoders to end-of-stream, stops the muxer
     * and atomically renames the .tmp file to [outputFile]. Never blocks the
     * caller: [completion] is invoked exactly once on the recorder worker (or
     * synchronously here when the take never ran / already completed) with the
     * final file, or a failure whose message is a stable reason token.
     */
    fun finishAsync(completion: (Result<File>) -> Unit) {
        val immediate: Result<File>?
        synchronized(completionLock) {
            val existing = finalResult
            if (existing != null) {
                immediate = existing
            } else {
                immediate = null
                val prior = this.completion
                this.completion = if (prior == null) {
                    completion
                } else {
                    { r -> prior(r); completion(r) }
                }
            }
        }
        if (immediate != null) {
            completion(immediate)
            return
        }
        if (!started.get() || !workerOwnsCleanup) {
            // Never started (or start failed before the worker existed): nothing
            // to finalize; release whatever exists and fail deterministically.
            releaseAllQuietly()
            deleteQuietly(tmpFile)
            deliver(Result.failure(IllegalStateException("not_started")))
            return
        }
        finishRequested.set(true)
    }

    /**
     * Discards the take: stops capture, releases every codec/muxer resource
     * and deletes the .tmp file. Idempotent; never blocks. A pending
     * [finishAsync] completion (if any) is delivered with a "canceled" failure.
     */
    fun cancel() {
        if (!canceled.compareAndSet(false, true)) return
        if (!workerOwnsCleanup) {
            releaseAllQuietly()
            deleteQuietly(tmpFile)
            deliver(Result.failure(IllegalStateException("canceled")))
        }
        // else: the worker observes `canceled` and aborts + delivers.
    }

    // ── Worker (vg.duet.rec.video) ─────────────────────────────────────────────

    private fun runWorker() {
        try {
            while (!finishRequested.get() && !canceled.get() && !videoEncoderFailed) {
                // dequeueOutputBuffer's 10 ms timeout paces this loop while idle.
                drainVideoEncoder(endOfStream = false)
                checkAudioGraceTimeout()
            }
            if (canceled.get()) {
                abortAndDeliver("canceled")
                return
            }
            if (videoEncoderFailed) {
                abortAndDeliver("video_encoder_error")
                return
            }
            finishInternal()
        } catch (t: Throwable) {
            Log.w(TAG, "worker failed: ${t.javaClass.simpleName}: ${t.message}")
            abortAndDeliver("worker_exception:${t.javaClass.simpleName}")
        }
    }

    private fun finishInternal() {
        // 1. Audio lane: stop capture, feed EOS, drain to EOS (bounded, on the audio thread).
        stopAudioLaneAndJoin()
        if (canceled.get()) { abortAndDeliver("canceled"); return }

        // 2. Video EOS. A take without a single submitted frame has nothing to keep.
        val frames = framesSubmitted.get()
        if (frames == 0) {
            abortAndDeliver("no_video_frames")
            return
        }
        try {
            videoEncoder?.signalEndOfInputStream()
        } catch (t: Throwable) {
            Log.w(TAG, "signalEndOfInputStream failed: ${t.message}")
        }
        drainVideoEncoder(endOfStream = true)

        // 3. If the muxer still never started because the audio lane produced
        //    no format, give up on audio now so the video track is kept.
        synchronized(muxerLock) {
            if (!muxerStarted && videoFormatReady && audioConfigured && !audioFormatReady) {
                audioPermanentlyDisabled = true
                audioDisabledReason = "no_audio_format_at_finish"
                maybeStartMuxerLocked()
            }
        }
        if (canceled.get()) { abortAndDeliver("canceled"); return }

        // 4. Stop + release the muxer, then the codecs.
        var stopOk = muxerStarted
        if (stopOk) {
            try {
                muxer?.stop()
            } catch (t: Throwable) {
                Log.w(TAG, "muxer.stop failed: ${t.javaClass.simpleName}: ${t.message}")
                stopOk = false
            }
        }
        try { muxer?.release() } catch (_: Throwable) {}
        muxer = null
        synchronized(muxerLock) {
            pendingVideoSamples.clear()
            pendingAudioSamples.clear()
        }
        releaseVideoResourcesQuietly()
        if (!stopOk) {
            deleteQuietly(tmpFile)
            Log.w(TAG, "ANDROID_DUET_SEGMENT_TAKE_FAILED reason=muxer_not_finalized frames=$frames written=${videoWrittenSamples.get()}")
            deliver(Result.failure(IllegalStateException("muxer_not_finalized")))
            return
        }

        // 5. Atomic rename to the final path; verify the result is non-empty.
        try {
            if (outputFile.exists()) outputFile.delete()
        } catch (_: Throwable) {}
        val renamed = try { tmpFile.renameTo(outputFile) } catch (_: Throwable) { false }
        val finalLength = try { outputFile.length() } catch (_: Throwable) { 0L }
        if (!renamed || !outputFile.exists() || finalLength <= 0L) {
            deleteQuietly(tmpFile)
            deleteQuietly(outputFile)
            Log.w(TAG, "ANDROID_DUET_SEGMENT_TAKE_FAILED reason=rename_failed renamed=$renamed length=$finalLength")
            deliver(Result.failure(IllegalStateException("rename_failed")))
            return
        }
        val origin = originNanos
        val wallMs = if (origin > 0L) (System.nanoTime() - origin) / 1_000_000L else 0L
        Log.i(
            TAG,
            "ANDROID_DUET_SEGMENT_TAKE_FINALIZED file=${outputFile.name} bytes=$finalLength " +
                "framesSubmitted=$frames videoSamples=${videoWrittenSamples.get()} " +
                "lastVideoPtsMs=${lastVideoPtsNs / 1_000_000L} wallMs=$wallMs speed=$speedMultiplier " +
                "audioTrack=${audioTrackIndex >= 0 && !audioPermanentlyDisabled} " +
                "audioSamplesFed=$audioSamplesFed audioDisabled=${audioDisabledReason ?: "none"}",
        )
        deliver(Result.success(outputFile))
    }

    private fun abortAndDeliver(reason: String) {
        stopAudioLaneAndJoin()
        try { if (muxerStarted) muxer?.stop() } catch (_: Throwable) {}
        try { muxer?.release() } catch (_: Throwable) {}
        muxer = null
        synchronized(muxerLock) {
            pendingVideoSamples.clear()
            pendingAudioSamples.clear()
        }
        releaseVideoResourcesQuietly()
        deleteQuietly(tmpFile)
        Log.i(TAG, "ANDROID_DUET_SEGMENT_TAKE_DISCARDED file=${outputFile.name} reason=$reason frames=${framesSubmitted.get()}")
        deliver(Result.failure(IllegalStateException(reason)))
    }

    private fun deliver(result: Result<File>) {
        val cb: ((Result<File>) -> Unit)?
        synchronized(completionLock) {
            if (finalResult != null) return
            finalResult = result
            cb = completion
            completion = null
        }
        if (cb != null) {
            try { cb(result) } catch (t: Throwable) { Log.w(TAG, "completion threw: ${t.message}") }
        }
    }

    // ── Video drain ───────────────────────────────────────────────────────────────

    private fun drainVideoEncoder(endOfStream: Boolean) {
        val enc = videoEncoder ?: return
        val info = MediaCodec.BufferInfo()
        val deadline = if (endOfStream) System.currentTimeMillis() + EOS_DRAIN_DEADLINE_MS else 0L
        while (true) {
            if (endOfStream && System.currentTimeMillis() > deadline) {
                Log.w(TAG, "video EOS drain deadline exceeded")
                return
            }
            if (endOfStream && canceled.get()) return
            val outIdx = try {
                enc.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            } catch (t: Throwable) {
                // Codec error state: stop the lane instead of spinning on it.
                Log.w(TAG, "video dequeueOutputBuffer threw: ${t.javaClass.simpleName}: ${t.message}")
                videoEncoderFailed = true
                return
            }
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(muxerLock) {
                        val mx = muxer
                        if (videoTrackIndex < 0 && mx != null) {
                            videoTrackIndex = mx.addTrack(enc.outputFormat)
                            videoFormatReady = true
                            videoFormatArrivedAtNanos = System.nanoTime()
                            maybeStartMuxerLocked()
                        }
                    }
                }
                outIdx >= 0 -> {
                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (!isConfig && info.size > 0) {
                        val buf = enc.getOutputBuffer(outIdx)
                        if (buf != null) {
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            writeOrBufferSample(isVideo = true, buf = buf, info = info)
                        }
                    }
                    try { enc.releaseOutputBuffer(outIdx, false) } catch (_: Throwable) {}
                    if (isEos) return
                }
            }
        }
    }

    /** Writes a sample when the muxer runs, else buffers it (bounded) until [maybeStartMuxerLocked]. */
    private fun writeOrBufferSample(isVideo: Boolean, buf: ByteBuffer, info: MediaCodec.BufferInfo) {
        synchronized(muxerLock) {
            val mx = muxer ?: return
            val track = if (isVideo) videoTrackIndex else audioTrackIndex
            if (muxerStarted && track >= 0) {
                try {
                    mx.writeSampleData(track, buf, info)
                    if (isVideo) videoWrittenSamples.incrementAndGet()
                } catch (t: Throwable) {
                    Log.w(TAG, "writeSampleData(${if (isVideo) "video" else "audio"}) failed: ${t.message}")
                }
                return
            }
            if (!isVideo && audioPermanentlyDisabled) return
            val queue = if (isVideo) pendingVideoSamples else pendingAudioSamples
            if (queue.size >= MAX_PENDING_SAMPLES) return
            val data = ByteArray(info.size)
            buf.get(data)
            val copy = MediaCodec.BufferInfo().apply { set(0, info.size, info.presentationTimeUs, info.flags) }
            queue.add(PendingSample(data, copy))
        }
    }

    /** Worker-side bounded wait for the audio format; falls back to video-only. */
    private fun checkAudioGraceTimeout() {
        if (muxerStarted || !videoFormatReady || !audioConfigured || audioFormatReady || audioPermanentlyDisabled) return
        val arrivedAt = videoFormatArrivedAtNanos
        if (arrivedAt == 0L) return
        if ((System.nanoTime() - arrivedAt) / 1_000_000L < AUDIO_TRACK_GRACE_MS) return
        Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_AUDIO_DISABLED reason=audio_format_timeout graceMs=$AUDIO_TRACK_GRACE_MS")
        audioPermanentlyDisabled = true
        audioDisabledReason = "audio_format_timeout"
        audioActive = false
        synchronized(muxerLock) { maybeStartMuxerLocked() }
    }

    /** Must be called holding [muxerLock]. */
    private fun maybeStartMuxerLocked() {
        if (muxerStarted) return
        if (!videoFormatReady) return
        val audioSatisfied = !audioConfigured || audioFormatReady || audioPermanentlyDisabled
        if (!audioSatisfied) return
        val mx = muxer ?: return
        try {
            mx.start()
            muxerStarted = true
            Log.i(
                TAG,
                "ANDROID_DUET_SEGMENT_RECORDER_MUXER_STARTED audioTrack=${audioTrackIndex >= 0 && !audioPermanentlyDisabled} " +
                    "pendingVideo=${pendingVideoSamples.size} pendingAudio=${pendingAudioSamples.size}",
            )
            flushPendingLocked(mx, videoTrackIndex, pendingVideoSamples, countVideo = true)
            if (audioTrackIndex >= 0 && !audioPermanentlyDisabled) {
                flushPendingLocked(mx, audioTrackIndex, pendingAudioSamples, countVideo = false)
            } else {
                pendingAudioSamples.clear()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "muxer.start failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun flushPendingLocked(mx: MediaMuxer, track: Int, queue: ArrayDeque<PendingSample>, countVideo: Boolean) {
        while (queue.isNotEmpty()) {
            val sample = queue.removeFirst()
            try {
                val bb = ByteBuffer.allocateDirect(sample.data.size).apply {
                    put(sample.data)
                    position(0)
                    limit(sample.data.size)
                }
                mx.writeSampleData(track, bb, sample.info)
                if (countVideo) videoWrittenSamples.incrementAndGet()
            } catch (t: Throwable) {
                Log.w(TAG, "flush pending sample failed: ${t.message}")
            }
        }
    }

    // ── Audio lane (best-effort mic capture + AAC) ─────────────────────────────

    private fun setupAudioBestEffort() {
        try {
            if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                audioDisabledReason = "record_audio_not_granted"
                Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_AUDIO_DISABLED reason=record_audio_not_granted")
                return
            }
            val minBuf = AudioRecord.getMinBufferSize(
                AUDIO_SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuf <= 0) {
                audioDisabledReason = "min_buffer_size_$minBuf"
                Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_AUDIO_DISABLED reason=min_buffer_size value=$minBuf")
                return
            }
            val record = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuf * 2,
            )
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                try { record.release() } catch (_: Throwable) {}
                audioDisabledReason = "audio_record_uninitialized"
                Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_AUDIO_DISABLED reason=audio_record_uninitialized")
                return
            }
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, AUDIO_SAMPLE_RATE, AUDIO_CHANNELS).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
            }
            var enc: MediaCodec? = null
            try {
                enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                enc.start()
            } catch (t: Throwable) {
                try { enc?.release() } catch (_: Throwable) {}
                try { record.release() } catch (_: Throwable) {}
                audioDisabledReason = "aac_encoder_failed"
                Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_AUDIO_DISABLED reason=aac_encoder_failed ${t.javaClass.simpleName}: ${t.message}")
                return
            }
            audioRecord = record
            audioEncoder = enc
            audioReadBufferShorts = maxOf(256, minBuf / 2)
            audioConfigured = true
            audioActive = true
            val thread = Thread({ runAudioLoop() }, "vg.duet.rec.audio")
            audioThread = thread
            thread.start()
        } catch (t: Throwable) {
            audioDisabledReason = "audio_setup_exception"
            Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_AUDIO_DISABLED reason=audio_setup_exception ${t.javaClass.simpleName}: ${t.message}")
            audioConfigured = false
            audioActive = false
            try { audioEncoder?.release() } catch (_: Throwable) {}
            try { audioRecord?.release() } catch (_: Throwable) {}
            audioEncoder = null
            audioRecord = null
        }
    }

    private fun runAudioLoop() {
        val record = audioRecord ?: return
        try {
            record.startRecording()
        } catch (t: Throwable) {
            Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_AUDIO_DISABLED reason=start_recording_failed ${t.message}")
            audioActive = false
            audioPermanentlyDisabled = true
            audioDisabledReason = "start_recording_failed"
            synchronized(muxerLock) { maybeStartMuxerLocked() }
            return
        }
        val pcm = ShortArray(audioReadBufferShorts)
        // Decided lazily on the first post-origin chunk, once [speedMultiplier]
        // is frozen (setSpeedMultiplier is a no-op once originNanos is set, and
        // the coordinator always sets the final speed before the first frame).
        var wsolaDecided = false
        var wsola: AndroidDuetWsolaFilter? = null
        while (audioActive && !canceled.get()) {
            val n = try {
                record.read(pcm, 0, pcm.size)
            } catch (t: Throwable) {
                Log.w(TAG, "audio read failed: ${t.message}")
                break
            }
            if (n <= 0) {
                // Blocking read returned nothing: error code, or the record was
                // stopped underneath us. Never spin on it.
                Log.w(TAG, "audio read returned $n — ending audio lane")
                break
            }
            // Drop microphone audio captured before the first video frame; the
            // take timeline starts there (PTS 0) for both tracks.
            val origin = originNanos
            if (origin < 0L) continue
            if (!wsolaDecided) {
                wsolaDecided = true
                val speed = speedMultiplier
                if (abs(speed - 1.0) > WSOLA_BYPASS_EPSILON) {
                    wsola = AndroidDuetWsolaFilter(speed)
                    Log.i(TAG, "ANDROID_DUET_SEGMENT_RECORDER_AUDIO_WSOLA_ENABLED speed=$speed")
                }
            }
            val filter = wsola
            if (filter != null) {
                val transformed = filter.process(pcm, n)
                feedTransformedAudioChunk(transformed, transformed.size, origin)
            } else {
                feedTransformedAudioChunk(pcm, n, origin)
            }
        }
        if (!canceled.get()) {
            val filter = wsola
            if (filter != null) {
                // We only reach here after stopAudioLaneAndJoin() cleared
                // `audioActive`, so the WSOLA tail must bypass that guard or it
                // is silently dropped before EOS. Cancellation still aborts it.
                val tail = filter.flush()
                feedTransformedAudioChunk(tail, tail.size, originNanos, allowAfterStopForFlush = true)
            }
            feedAudioEncoderEos()
            drainAudioEncoder(endOfStream = true)
        }
        try { record.stop() } catch (_: Throwable) {}
    }

    /**
     * Feeds [count] already-output-rate samples (raw mic PCM for the ~1.0
     * speed bypass, or WSOLA-transformed PCM otherwise) to the AAC encoder.
     * The first non-empty chunk of the take back-dates [audioBasePtsUs] by
     * its own duration so audio starts near PTS 0 and stays gap-free from
     * [audioSamplesFed] afterwards.
     *
     * [allowAfterStopForFlush] is set only for the WSOLA tail flushed right
     * before [feedAudioEncoderEos]; that tail is produced after [audioActive]
     * has already been cleared by stop, so it must not be gated on it.
     */
    private fun feedTransformedAudioChunk(
        samples: ShortArray,
        count: Int,
        origin: Long,
        allowAfterStopForFlush: Boolean = false,
    ) {
        if (count <= 0) return
        if (audioSamplesFed == 0L) {
            val chunkUs = count.toLong() * 1_000_000L / AUDIO_SAMPLE_RATE
            audioBasePtsUs = ((System.nanoTime() - origin) / 1_000L - chunkUs).coerceAtLeast(0L)
        }
        feedAudioEncoder(samples, count, allowAfterStopForFlush)
        drainAudioEncoder(endOfStream = false)
    }

    /**
     * PTS derived from [audioSamplesFed]: a continuous counter of samples actually submitted to the encoder.
     * Normal chunks stop submitting once [audioActive] is cleared; the pre-EOS
     * flush tail passes [allowAfterStopForFlush] so it is still submitted.
     * Cancellation always aborts submission regardless.
     */
    private fun feedAudioEncoder(pcm: ShortArray, count: Int, allowAfterStopForFlush: Boolean = false) {
        val enc = audioEncoder ?: return
        var offset = 0
        var stalls = 0
        while (offset < count && (audioActive || allowAfterStopForFlush) && !canceled.get()) {
            try {
                val inIdx = enc.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                if (inIdx >= 0) {
                    val buf = enc.getInputBuffer(inIdx) ?: break
                    buf.clear()
                    buf.order(ByteOrder.nativeOrder())
                    val capacityShorts = buf.remaining() / 2
                    val toWrite = minOf(capacityShorts, count - offset)
                    buf.asShortBuffer().put(pcm, offset, toWrite)
                    val ptsUs = audioBasePtsUs + audioSamplesFed * 1_000_000L / AUDIO_SAMPLE_RATE
                    enc.queueInputBuffer(inIdx, 0, toWrite * 2, ptsUs, 0)
                    audioSamplesFed += toWrite
                    offset += toWrite
                } else {
                    drainAudioEncoder(endOfStream = false)
                    if (++stalls > 50) break
                }
            } catch (t: Throwable) {
                Log.w(TAG, "feedAudioEncoder failed: ${t.message}")
                break
            }
        }
    }

    private fun feedAudioEncoderEos() {
        val enc = audioEncoder ?: return
        try {
            val inIdx = enc.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
            if (inIdx >= 0) {
                val ptsUs = audioBasePtsUs + audioSamplesFed * 1_000_000L / AUDIO_SAMPLE_RATE
                enc.queueInputBuffer(inIdx, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "feedAudioEncoderEos failed: ${t.message}")
        }
    }

    private fun drainAudioEncoder(endOfStream: Boolean) {
        val enc = audioEncoder ?: return
        val info = MediaCodec.BufferInfo()
        val deadline = if (endOfStream) System.currentTimeMillis() + EOS_DRAIN_DEADLINE_MS else 0L
        while (true) {
            if (endOfStream && System.currentTimeMillis() > deadline) return
            if (canceled.get()) return
            val outIdx = try {
                enc.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            } catch (_: Throwable) {
                return
            }
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(muxerLock) {
                        val mx = muxer
                        if (audioTrackIndex < 0 && !audioPermanentlyDisabled && mx != null) {
                            audioTrackIndex = mx.addTrack(enc.outputFormat)
                            audioFormatReady = true
                            maybeStartMuxerLocked()
                        }
                    }
                }
                outIdx >= 0 -> {
                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (!isConfig && info.size > 0) {
                        val buf = enc.getOutputBuffer(outIdx)
                        if (buf != null) {
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            writeOrBufferSample(isVideo = false, buf = buf, info = info)
                        }
                    }
                    try { enc.releaseOutputBuffer(outIdx, false) } catch (_: Throwable) {}
                    if (isEos) return
                }
            }
        }
    }

    /** Stops capture, lets the audio thread flush EOS (bounded join), then releases the lane. */
    private fun stopAudioLaneAndJoin() {
        audioActive = false
        val thread = audioThread
        if (thread != null && thread !== Thread.currentThread()) {
            try { thread.join(WORKER_JOIN_TIMEOUT_MS) } catch (_: InterruptedException) { Thread.currentThread().interrupt() }
        }
        audioThread = null
        releaseAudioResourcesQuietly()
    }

    // ── Cleanup ───────────────────────────────────────────────────────────────────

    private fun releaseVideoResourcesQuietly() {
        try { videoEncoder?.stop() } catch (_: Throwable) {}
        try { videoEncoder?.release() } catch (_: Throwable) {}
        videoEncoder = null
        try { _inputSurface?.release() } catch (_: Throwable) {}
        _inputSurface = null
    }

    private fun releaseAudioResourcesQuietly() {
        try { audioRecord?.release() } catch (_: Throwable) {}
        try { audioEncoder?.stop() } catch (_: Throwable) {}
        try { audioEncoder?.release() } catch (_: Throwable) {}
        audioRecord = null
        audioEncoder = null
    }

    /** Non-worker cleanup for the never-started / failed-start cases only. */
    private fun releaseAllQuietly() {
        audioActive = false
        releaseAudioResourcesQuietly()
        try { muxer?.release() } catch (_: Throwable) {}
        muxer = null
        releaseVideoResourcesQuietly()
        synchronized(muxerLock) {
            pendingVideoSamples.clear()
            pendingAudioSamples.clear()
        }
    }

    private fun deleteQuietly(f: File) {
        try { if (f.exists()) f.delete() } catch (_: Throwable) {}
    }
}
