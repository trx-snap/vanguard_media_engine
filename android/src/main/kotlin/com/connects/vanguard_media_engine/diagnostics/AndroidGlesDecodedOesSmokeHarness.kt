package com.connects.vanguard_media_engine.diagnostics

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.view.TextureRegistry
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Phase 1-Unit AW-OES: diagnostic-only Android GLES decoded
 * SurfaceTexture/OES DAG render foundation harness.
 *
 * Decodes up to [maxFramesDefault] frames of a caller-supplied fixture with
 * MediaCodec onto a `SurfaceTexture` bound to a native-allocated
 * `GL_TEXTURE_EXTERNAL_OES` texture name, and for each decoded frame calls
 * into native code (create/render/destroy session) to make the GLES context
 * current, call `SurfaceTexture.updateTexImage()`, evaluate a minimal
 * diagnostic Graph using the decoded frame's
 * `MediaCodec.BufferInfo.presentationTimeUs`, and present the OES texture on
 * the attached `TextureRegistry.SurfaceProducer` surface.
 *
 * The entire create-session -> SurfaceTexture(oesTextureId) -> codec loop ->
 * destroy-session sequence runs on whichever thread calls [run] -- this
 * class performs no threading of its own; the coordinator invokes [run] on a
 * single background worker thread, matching the requirement that the GL
 * context (made current during native session creation) and the
 * `SurfaceTexture` bound to it are only ever touched from that one thread.
 *
 * [cancel] lets a caller (the owning coordinator, on a dispose() call that
 * arrives while [run] is still active) request early loop exit; the decode
 * loop checks it between frames and always finishes cleanup before
 * returning, matching the Unit AY/BC active-dispose pattern.
 *
 * Non-claims: does not fix or touch the still-DEFERRED Phase 1-Unit AW
 * ImageReader.PRIVATE/AHardwareBuffer import failure
 * (`ahb_import_unsupported_format`); no color-correct YUV->RGB conversion
 * beyond what the native GlesTextureFrameRenderer already performs for other
 * GL_TEXTURE_EXTERNAL_OES draws, no product UI, no ConnectsApp wiring.
 */
class AndroidGlesDecodedOesSmokeHarness {

    companion object {
        private const val TAG = "VGDecodedOesSmoke"
        private const val RESULT_MARKER = "ANDROID_DAG_PHASE1AWOES_NATIVE_RESULT"
        private const val PROOF_BOUNDARY =
            "gles_decoded_surfacetexture_oes_dag_render_no_ahb_import_no_product_ui"
        private const val DEFAULT_MAX_FRAMES = 10
        private const val DEFAULT_ROTATION_DEGREES = 0
        private const val DEFAULT_MIRROR_HORIZONTAL = false
        private const val DEQUEUE_INPUT_TIMEOUT_US = 10_000L
        private const val FRAME_AVAILABLE_TIMEOUT_MS = 2_000L
        private const val TOTAL_DECODE_TIMEOUT_MS = 30_000L

        /** Failure result map for exceptions raised outside [run] itself (e.g. thread crash). */
        fun exceptionResult(throwable: Throwable): Map<String, Any?> {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            return buildResult(
                pass = false,
                width = 0,
                height = 0,
                textureId = -1,
                frameCount = DEFAULT_MAX_FRAMES,
                renderedFrames = 0,
                decodedPtsUsList = emptyList(),
                lastError = "harness_exception:$reason",
            )
        }

        private fun buildResult(
            pass: Boolean,
            width: Int,
            height: Int,
            textureId: Int,
            frameCount: Int,
            renderedFrames: Int,
            decodedPtsUsList: List<Long>,
            lastError: String,
        ): Map<String, Any?> {
            val raw = "status=${if (pass) "PASS" else "FAIL"};" +
                "renderedFrames=$renderedFrames;frameCount=$frameCount;" +
                "width=$width;height=$height;textureId=$textureId;" +
                "proofBoundary=$PROOF_BOUNDARY;" +
                "lastError=${if (lastError.isEmpty()) "none" else lastError}"
            return mapOf(
                "pass" to pass,
                "raw" to raw,
                "width" to width,
                "height" to height,
                "textureId" to textureId,
                "frameCount" to frameCount,
                "renderedFrames" to renderedFrames,
                "decodedPtsUsList" to decodedPtsUsList,
                "proofBoundary" to PROOF_BOUNDARY,
                "lastError" to (if (lastError.isEmpty()) "none" else lastError),
            )
        }
    }

    private val cancelled = AtomicBoolean(false)

    /** Requests early exit of an active [run] loop; safe to call at any time, including after completion. */
    fun cancel() {
        cancelled.set(true)
    }

    fun run(surfaceProducer: TextureRegistry.SurfaceProducer, args: Map<*, *>?): Map<String, Any?> {
        val videoPath = args?.get("videoPath") as? String
        val maxFrames = (args?.get("maxFrames") as? Number)?.toInt()?.takeIf { it > 0 } ?: DEFAULT_MAX_FRAMES
        val rotationDegrees = (args?.get("rotationDegrees") as? Number)?.toInt() ?: DEFAULT_ROTATION_DEGREES
        val mirrorHorizontal = (args?.get("mirrorHorizontal") as? Boolean) ?: DEFAULT_MIRROR_HORIZONTAL

        if (videoPath.isNullOrEmpty()) {
            val result = buildResult(false, 0, 0, -1, maxFrames, 0, emptyList(), "invalid_arguments_video_path_required")
            Log.i(TAG, "$RESULT_MARKER ${result["raw"]}")
            return result
        }

        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        var handlerThread: HandlerThread? = null
        var surfaceTexture: SurfaceTexture? = null
        var codecInputSurface: Surface? = null
        var producerSurface: Surface? = null
        var sessionId: String? = null
        var oesTextureId = -1
        var nativeBridge: VanguardNativeBridge? = null

        val frameAvailable = Semaphore(0)

        var videoWidth = 0
        var videoHeight = 0
        var renderedFrames = 0
        val decodedPtsUsList = mutableListOf<Long>()
        var lastError = "not_run"

        try {
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
                lastError = "no_video_track"
                return buildResult(false, 0, 0, -1, maxFrames, 0, decodedPtsUsList, lastError)
            }
            extractor.selectTrack(videoTrackIndex)

            videoWidth = videoFormat.getInteger(MediaFormat.KEY_WIDTH, 64).let { if (it > 0) it else 64 }
            videoHeight = videoFormat.getInteger(MediaFormat.KEY_HEIGHT, 64).let { if (it > 0) it else 64 }
            val mime = videoFormat.getString(MediaFormat.KEY_MIME)!!

            // ── Native session: initializes GlesBackend, attaches the
            //    SurfaceProducer surface, and allocates the OES texture. ────
            surfaceProducer.setSize(videoWidth, videoHeight)
            producerSurface = surfaceProducer.getSurface()

            val diagnostics = VanguardDiagnostics()
            nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )

            val createResult = nativeBridge.createAndroidDagPhase1AWOESSession(
                producerSurface, videoWidth, videoHeight,
            )
            if (!createResult.startsWith("status=OK;")) {
                lastError = "session_create_failed;nativeResult=${createResult.take(120)}"
                return buildResult(false, videoWidth, videoHeight, -1, maxFrames, 0, decodedPtsUsList, lastError)
            }
            sessionId = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
            oesTextureId = createResult.substringAfter("textureId=").substringBefore(";").toIntOrNull() ?: -1
            if (sessionId == null || oesTextureId <= 0) {
                lastError = "session_id_or_texture_id_parse_failed"
                return buildResult(false, videoWidth, videoHeight, oesTextureId, maxFrames, 0, decodedPtsUsList, lastError)
            }

            // SurfaceTexture(int texName) requires a current GL context on
            // this thread; the native createSession call above just left the
            // backend's context current on this same calling thread.
            surfaceTexture = SurfaceTexture(oesTextureId)
            surfaceTexture.setDefaultBufferSize(videoWidth, videoHeight)

            handlerThread = HandlerThread("Phase1AWOesFrameListener").also { it.start() }
            val listenerHandler = Handler(handlerThread.looper)
            surfaceTexture.setOnFrameAvailableListener(
                { frameAvailable.release() },
                listenerHandler,
            )

            codecInputSurface = Surface(surfaceTexture)

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(videoFormat, codecInputSurface, null, 0)
            codec.start()

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var frameRenderError: String? = null
            val deadline = System.currentTimeMillis() + TOTAL_DECODE_TIMEOUT_MS

            while (renderedFrames < maxFrames && !outputDone && frameRenderError == null && !cancelled.get()) {
                if (System.currentTimeMillis() > deadline) {
                    frameRenderError = "decode_loop_timeout"
                    break
                }

                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(DEQUEUE_INPUT_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)
                        if (buf != null) {
                            val sampleSize = extractor.readSampleData(buf, 0)
                            if (sampleSize < 0) {
                                codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                val pts = extractor.sampleTime
                                codec.queueInputBuffer(inIdx, 0, sampleSize, pts, 0)
                                extractor.advance()
                            }
                        }
                    }
                }

                val outIdx = codec.dequeueOutputBuffer(info, DEQUEUE_INPUT_TIMEOUT_US)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { /* ignore */ }
                    outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> { /* spin */ }
                    outIdx >= 0 -> {
                        val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        val renderable = info.size > 0 && !isEos

                        if (renderable && renderedFrames < maxFrames) {
                            codec.releaseOutputBuffer(outIdx, true)

                            val available = frameAvailable.tryAcquire(FRAME_AVAILABLE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                            if (!available) {
                                frameRenderError = "frame_available_timeout;frameIndex=$renderedFrames"
                            } else {
                                val renderStr = nativeBridge.renderAndroidDagPhase1AWOESFrame(
                                    sessionId,
                                    surfaceTexture,
                                    info.presentationTimeUs,
                                    renderedFrames,
                                    rotationDegrees,
                                    mirrorHorizontal,
                                )
                                if (renderStr.startsWith("status=PASS;")) {
                                    decodedPtsUsList.add(info.presentationTimeUs)
                                    renderedFrames++
                                } else {
                                    Log.w(TAG, "renderFrame FAIL frame=$renderedFrames: $renderStr")
                                    frameRenderError = renderStr
                                }
                            }
                        } else if (isEos) {
                            codec.releaseOutputBuffer(outIdx, false)
                            outputDone = true
                        } else {
                            codec.releaseOutputBuffer(outIdx, false)
                        }

                        if (isEos) outputDone = true
                    }
                }
            }

            if (cancelled.get() && frameRenderError == null && renderedFrames < maxFrames) {
                frameRenderError = "cancelled"
            }

            val pass = renderedFrames == maxFrames && frameRenderError == null
            lastError = frameRenderError ?: ""
            return buildResult(pass, videoWidth, videoHeight, oesTextureId, maxFrames, renderedFrames, decodedPtsUsList, lastError)
        } catch (t: Throwable) {
            val reason = t.javaClass.simpleName.ifEmpty { "unknown_exception" }
            lastError = "exception:$reason"
            return buildResult(false, videoWidth, videoHeight, oesTextureId, maxFrames, renderedFrames, decodedPtsUsList, lastError)
        } finally {
            Log.i(TAG, "$RESULT_MARKER status=done;renderedFrames=$renderedFrames;lastError=$lastError")

            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}

            val bridge = nativeBridge
            val sid = sessionId
            if (bridge != null && sid != null) {
                try { bridge.destroyAndroidDagPhase1AWOESSession(sid) } catch (_: Throwable) {}
            }

            try { codecInputSurface?.release() } catch (_: Throwable) {}
            try { surfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
            try { surfaceTexture?.release() } catch (_: Throwable) {}
            try { extractor?.release() } catch (_: Throwable) {}
            try { handlerThread?.quitSafely() } catch (_: Throwable) {}

            // producerSurface is this harness's own Surface obtained from the
            // SurfaceProducer, distinct from the SurfaceProducer itself; the
            // SurfaceProducer's release() lifecycle remains owned by
            // AndroidGlesTextureSmokeCoordinator (see its dispose ownership
            // comments), matching the Unit BA lane pattern.
            try { producerSurface?.release() } catch (_: Throwable) {}
        }
    }
}
