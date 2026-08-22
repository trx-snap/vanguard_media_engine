package com.connects.vanguard_media_engine.codec

import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Phase 4A: Bounded diagnostic smoke adapter.
 *
 * Decodes up to [maxFrames] decoded video frames from [videoPath] using
 * MediaCodec + ImageReader (PRIVATE format, USAGE_GPU_SAMPLED_IMAGE, API 29+).
 * For each acquired [Image], it:
 *   1. Retrieves the non-null [HardwareBuffer] via [Image.getHardwareBuffer].
 *   2. If API >= 33, waits the image's SyncFence with a bounded timeout.
 *   3. Calls [VanguardNativeBridge.renderAndroidDagPhase4ADecoderSmokeFrame].
 *   4. Closes [HardwareBuffer] first, then [Image].
 *
 * Returns a result map suitable for MethodChannel.Result.success().
 *
 * Design constraints:
 * - Never synchronously assumes an image is immediately available after
 *   releaseOutputBuffer(index, true); uses an [ImageReader] listener that
 *   posts to [imageQueue].
 * - Session (VulkanBackend + Graph) lives for all frames; one lifecycle.
 * - API below 29 returns structured failure "api_below_29".
 */
@Suppress("MemberVisibilityCanBePrivate")
class AndroidMediaCodecDecodedFrameSmokeAdapter(
    private val videoPath: String,
    private val maxFrames: Int = 10,
) {

    companion object {
        private const val TAG = "Phase4ADecoder"
        private const val RESULT_MARKER = "ANDROID_DAG_PHASE4A_NATIVE_RESULT"

        // Timeouts
        private const val DEQUEUE_INPUT_TIMEOUT_US = 10_000L   // 10 ms
        private const val IMAGE_ACQUIRE_TIMEOUT_MS = 2_000L    // 2 s per frame
        private const val TOTAL_DECODE_TIMEOUT_MS  = 30_000L   // 30 s total
        private const val FENCE_WAIT_TIMEOUT_MS    = 1_000L    // 1 s (API 33+)

        // ImageReader capacity
        private const val IMAGE_READER_MAX_IMAGES = 3
    }

    // ── Public entry point ────────────────────────────────────────────────────

    fun run(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // API 29 required for ImageReader.newInstance PRIVATE + HardwareBuffer usage flags.
            val raw = buildFailureRaw("api_below_29", 0, 0, maxFrames)
            Log.i(TAG, "$RESULT_MARKER $raw")
            return buildResult(raw, 0, 0, maxFrames, 0)
        }

        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        var imageReader: ImageReader? = null
        var handlerThread: HandlerThread? = null
        var previewSurfaceTexture: SurfaceTexture? = null
        var previewSurface: Surface? = null
        var sessionId: String? = null
        var nativeBridge: VanguardNativeBridge? = null

        // Image queue: listener posts available images here.
        val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES + 2)

        var videoWidth  = 0
        var videoHeight = 0
        var renderedFrames = 0
        var decoderStatus = "not_run"
        var sessionStatus = "not_run"
        var raw: String

        try {
            // ── 1. Select first video track ────────────────────────────────────
            extractor = MediaExtractor()
            extractor.setDataSource(videoPath)

            var videoTrackIndex = -1
            var videoFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val fmt = extractor.getTrackFormat(i)
                val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    videoTrackIndex = i
                    videoFormat = fmt
                    break
                }
            }

            if (videoTrackIndex < 0 || videoFormat == null) {
                raw = buildFailureRaw("no_video_track", 0, 0, maxFrames)
                Log.i(TAG, "$RESULT_MARKER $raw")
                return buildResult(raw, 0, 0, maxFrames, 0)
            }

            extractor.selectTrack(videoTrackIndex)

            videoWidth  = videoFormat.getInteger(MediaFormat.KEY_WIDTH,  64)
            videoHeight = videoFormat.getInteger(MediaFormat.KEY_HEIGHT, 64)
            if (videoWidth  <= 0) videoWidth  = 64
            if (videoHeight <= 0) videoHeight = 64

            val mime = videoFormat.getString(MediaFormat.KEY_MIME)!!

            // ── 2. Start HandlerThread for ImageReader listener ────────────────
            handlerThread = HandlerThread("Phase4AImageReader").also { it.start() }
            val handler = Handler(handlerThread.looper)

            // ── 3. Create ImageReader (PRIVATE, GPU_SAMPLED_IMAGE, API 29+) ────
            imageReader = ImageReader.newInstance(
                videoWidth,
                videoHeight,
                ImageFormat.PRIVATE,
                IMAGE_READER_MAX_IMAGES,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )

            // Listener: enqueue images; never block — drop if queue full.
            imageReader.setOnImageAvailableListener(
                { reader ->
                    try {
                        val img = reader.acquireNextImage()
                        if (img != null) {
                            val offered = imageQueue.offer(img)
                            if (!offered) {
                                Log.w(TAG, "ImageQueue full; dropping frame")
                                img.close()
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "acquireNextImage failed: $e")
                    }
                },
                handler,
            )

            // ── 4. Configure and start MediaCodec ──────────────────────────────
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(videoFormat, imageReader.surface, null, 0)
            codec.start()
            decoderStatus = "started"

            // ── 5. Create preview surface for native session ───────────────────
            previewSurfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(videoWidth, videoHeight)
            }
            previewSurface = Surface(previewSurfaceTexture)

            // ── 6. Create native session (VulkanBackend + DAG) ─────────────────
            val diagnostics = VanguardDiagnostics()
            nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )

            val createResult = nativeBridge.createAndroidDagPhase4ADecoderSmokeSession(
                previewSurface,
                videoWidth,
                videoHeight,
            )
            sessionStatus = if (createResult.startsWith("status=OK;")) "success" else "failed"
            if (sessionStatus != "success") {
                raw = buildFailureRaw(
                    "session_create_failed;nativeResult=${createResult.take(80)}",
                    videoWidth, videoHeight, maxFrames,
                )
                Log.i(TAG, "$RESULT_MARKER $raw")
                return buildResult(raw, videoWidth, videoHeight, maxFrames, 0)
            }

            // Parse sessionId from native result.
            sessionId = createResult.substringAfter("sessionId=").substringBefore(";")
                .ifEmpty { null }
            if (sessionId == null) {
                raw = buildFailureRaw("session_id_parse_failed", videoWidth, videoHeight, maxFrames)
                Log.i(TAG, "$RESULT_MARKER $raw")
                return buildResult(raw, videoWidth, videoHeight, maxFrames, 0)
            }

            // ── 7. Decode-and-render loop ──────────────────────────────────────
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var frameRenderError: String? = null
            val deadline = System.currentTimeMillis() + TOTAL_DECODE_TIMEOUT_MS

            while (renderedFrames < maxFrames && !outputDone && frameRenderError == null) {
                if (System.currentTimeMillis() > deadline) {
                    Log.w(TAG, "Decode loop timed out after ${TOTAL_DECODE_TIMEOUT_MS}ms")
                    break
                }

                // Feed input buffers.
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(DEQUEUE_INPUT_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)
                        if (buf != null) {
                            val sampleSize = extractor.readSampleData(buf, 0)
                            if (sampleSize < 0) {
                                codec.queueInputBuffer(
                                    inIdx, 0, 0, 0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                inputDone = true
                            } else {
                                val pts = extractor.sampleTime
                                codec.queueInputBuffer(inIdx, 0, sampleSize, pts, 0)
                                extractor.advance()
                            }
                        }
                    }
                }

                // Drain output buffers.
                val outIdx = codec.dequeueOutputBuffer(info, DEQUEUE_INPUT_TIMEOUT_US)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { /* ignore */ }
                    outIdx == MediaCodec.INFO_TRY_AGAIN_LATER       -> { /* spin */ }
                    outIdx >= 0 -> {
                        val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        // P1 EOS fix: only render buffers that carry real decoded data.
                        // An EOS-only buffer (size == 0) produces no Image in the
                        // ImageReader, so never pass it to the surface with render=true.
                        val renderable = info.size > 0 && !isEos

                        when {
                            renderable && renderedFrames < maxFrames -> {
                                // Release to surface — triggers ImageReader listener asynchronously.
                                codec.releaseOutputBuffer(outIdx, true)

                                // Wait (bounded) for the Image to appear in the queue.
                                val image: Image? = imageQueue.poll(
                                    IMAGE_ACQUIRE_TIMEOUT_MS, TimeUnit.MILLISECONDS,
                                )

                                if (image == null) {
                                    Log.w(TAG, "Timed out waiting for Image at frameIndex=$renderedFrames")
                                    continue
                                }

                                // Per-frame rendering section.
                                var hwBuf: HardwareBuffer? = null
                                try {
                                    hwBuf = image.hardwareBuffer
                                    if (hwBuf == null) {
                                        Log.w(TAG, "hardwareBuffer was null at frameIndex=$renderedFrames")
                                        continue
                                    }

                                    // Wait SyncFence on API >= 33 with bounded timeout.
                                    // P2: fence.close() is in a finally so it always runs.
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                        val fence = image.fence
                                        try {
                                            if (fence.isValid) {
                                                val waited = fence.await(
                                                    java.time.Duration.ofMillis(FENCE_WAIT_TIMEOUT_MS),
                                                )
                                                if (!waited) {
                                                    Log.w(TAG, "SyncFence wait timed out at frame=$renderedFrames")
                                                }
                                            }
                                        } catch (e: Exception) {
                                            Log.w(TAG, "SyncFence exception: $e")
                                        } finally {
                                            try { fence.close() } catch (_: Throwable) {}
                                        }
                                    }

                                    // Native DAG evaluation + Vulkan render.
                                    val renderStr = nativeBridge.renderAndroidDagPhase4ADecoderSmokeFrame(
                                        sessionId!!,
                                        hwBuf,
                                        videoWidth,
                                        videoHeight,
                                        info.presentationTimeUs,
                                        renderedFrames,
                                    )

                                    if (renderStr.startsWith("status=PASS;")) {
                                        renderedFrames++
                                    } else {
                                        Log.w(TAG, "renderFrame FAIL frame=$renderedFrames: $renderStr")
                                        frameRenderError = renderStr
                                    }
                                } finally {
                                    // Close HardwareBuffer first, then Image.
                                    try { hwBuf?.close() } catch (_: Throwable) {}
                                    try { image.close()  } catch (_: Throwable) {}
                                }
                            }
                            isEos -> {
                                // EOS-only or EOS coinciding with a real frame we've already
                                // counted: release without rendering, mark loop done.
                                codec.releaseOutputBuffer(outIdx, false)
                                outputDone = true
                            }
                            else -> {
                                // Non-EOS but already at maxFrames (or size == 0 non-EOS).
                                codec.releaseOutputBuffer(outIdx, false)
                            }
                        }

                        if (isEos) outputDone = true
                    }
                }
            }

            // ── 8. Build final result ──────────────────────────────────────────
            val pass = renderedFrames == maxFrames && frameRenderError == null
            raw = buildRaw(
                pass           = pass,
                decoderStatus  = decoderStatus,
                sessionStatus  = sessionStatus,
                renderedFrames = renderedFrames,
                frameCount     = maxFrames,
                errorDetail    = frameRenderError,
                width          = videoWidth,
                height         = videoHeight,
            )
            Log.i(TAG, "$RESULT_MARKER $raw")
            return buildResult(raw, videoWidth, videoHeight, maxFrames, renderedFrames)

        } catch (t: Throwable) {
            val reason = t.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = buildFailureRaw("exception:$reason", videoWidth, videoHeight, maxFrames)
            Log.e(TAG, "$RESULT_MARKER exception", t)
            return buildResult(raw, videoWidth, videoHeight, maxFrames, renderedFrames)
        } finally {
            // Drain and close any images remaining in the queue.
            while (true) {
                val img = imageQueue.poll() ?: break
                try { img.close() } catch (_: Throwable) {}
            }

            // Destroy native session (always, if created).
            val bridge = nativeBridge
            val sid    = sessionId
            if (bridge != null && sid != null) {
                try { bridge.destroyAndroidDagPhase4ADecoderSmokeSession(sid) } catch (_: Throwable) {}
            }

            // Stop and release codec.
            try { codec?.stop()    } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}

            // Release ImageReader.
            try { imageReader?.close() } catch (_: Throwable) {}

            // Release preview surface.
            try { previewSurface?.release()        } catch (_: Throwable) {}
            try { previewSurfaceTexture?.release() } catch (_: Throwable) {}

            // Release extractor.
            try { extractor?.release() } catch (_: Throwable) {}

            // Stop handler thread.
            try { handlerThread?.quitSafely() } catch (_: Throwable) {}
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private fun buildRaw(
        pass: Boolean,
        decoderStatus: String,
        sessionStatus: String,
        renderedFrames: Int,
        frameCount: Int,
        errorDetail: String?,
        width: Int,
        height: Int,
    ): String {
        val sb = StringBuilder()
        sb.append("status=${if (pass) "PASS" else "FAIL"};")
        sb.append("decoder=$decoderStatus;")
        sb.append("session=$sessionStatus;")
        sb.append("renderedFrames=$renderedFrames;")
        sb.append("frameCount=$frameCount;")
        if (errorDetail != null) sb.append("errorDetail=${errorDetail.take(80)};")
        sb.append("width=$width;")
        sb.append("height=$height")
        return sb.toString()
    }

    private fun buildFailureRaw(
        reason: String,
        width: Int,
        height: Int,
        frameCount: Int,
    ): String =
        "status=FAIL;decoder=$reason;session=not_run;" +
            "renderedFrames=0;frameCount=$frameCount;" +
            "width=$width;height=$height"

    private fun buildResult(
        raw: String,
        width: Int,
        height: Int,
        frameCount: Int,
        renderedFrames: Int,
    ): Map<String, Any?> = mapOf(
        "pass"           to raw.startsWith("status=PASS;"),
        "raw"            to raw,
        "width"          to width,
        "height"         to height,
        "frameCount"     to frameCount,
        "renderedFrames" to renderedFrames,
    )
}
