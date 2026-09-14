package com.connects.vanguard_media_engine.greenscreen

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Generic, caller-agnostic Android green-screen export engine (Duet, live
 * meeting/calling, going live, and camera are all expected callers).
 *
 * Composites two offline video inputs (opaque background + foreground masked by
 * a caller-supplied per-frame mask) into AVC/MP4 on a fixed output clock:
 * output frame `i` has `outputPtsUs = i * 1_000_000 / fps`; each lane selects
 * the newest decoded frame with pts <= outputPtsUs; frames superseded before
 * being rendered count as dropped; after input EOS the last frame is held and
 * every reuse counts as held; a lane with no frame at or before an output pts
 * (including pts 0) fails the export closed.
 *
 * Each lane owns a MediaExtractor, hardware MediaCodec decoder, ImageReader
 * (PRIVATE, GPU_SAMPLED_IMAGE), HandlerThread, and up to two open Images
 * (current + lookahead). Per render, HardwareBuffers are closed after native
 * returns while Images stay open until the lane replaces or closes them.
 * Output goes to `outputPath.tmp` and is renamed only after verified success;
 * failure and cancellation release the same resources idempotently and delete
 * the tmp. The native seam `renderAndroidTimelineVulkanExportDuetGreenScreenFrame`
 * is a legacy native name hidden behind this generic boundary.
 */
object AndroidGreenScreenExportEngine {
    private const val TAG = "VanguardGreenScreenExport"
    const val ENGINE_BOUNDARY = "android_greenscreen_export_engine_offline_two_input_fixed_clock"

    private const val IMAGE_READER_MAX_IMAGES = 4
    private const val DECODER_DEQUEUE_TIMEOUT_US = 10_000L
    private const val ENCODER_DEQUEUE_TIMEOUT_US = 10_000L
    private const val IMAGE_ACQUIRE_TIMEOUT_MS = 2_000L
    private const val MAX_NO_OUTPUT_ATTEMPTS = 400
    private const val FENCE_WAIT_MS = 1_000L
    private const val ENCODER_DRAIN_BUDGET_MS = 200L
    private const val ENCODER_EOS_DRAIN_BUDGET_MS = 5_000L
    private const val NATIVE_DEBUG_MODE_NORMAL = 0
    private const val I_FRAME_INTERVAL_SECONDS = 1
    private val CARDINAL_ROTATIONS = intArrayOf(0, 90, 180, 270)

    private val NON_CLAIMS = listOf(
        "no_live_camera",
        "no_ml_matte",
        "no_gpu_resident_mask_path",
        "no_audio",
        "no_av_sync",
        "no_realtime_clock",
        "no_container_rotation_auto_apply",
        "no_production_duet_wiring",
        "no_connectsapp_or_universal_editor_wiring",
        "fixed_offline_frame_clock_only",
    )

    /** Destination rect in output-canvas pixels. */
    data class CanvasRect(val x: Int, val y: Int, val width: Int, val height: Int) {
        fun fitsInside(canvasWidth: Int, canvasHeight: Int): Boolean =
            width > 0 && height > 0 && x >= 0 && y >= 0 && x + width <= canvasWidth && y + height <= canvasHeight
    }

    /**
     * One mask frame. Only [CpuR8] is supported today; the sealed shape lets a
     * future GPU-resident variant be added without changing callers, and any
     * unsupported variant fails closed at runtime. [CpuR8] is an 8-bit alpha
     * mask (255 = foreground, 0 = background) in a DIRECT ByteBuffer read from
     * byte index 0; [CpuR8.rowStrideBytes] of 0 means `width` bytes per row.
     */
    sealed class MaskFrame {
        abstract val width: Int
        abstract val height: Int

        class CpuR8(
            val buffer: ByteBuffer,
            override val width: Int,
            override val height: Int,
            val rowStrideBytes: Int = 0,
        ) : MaskFrame()
    }

    fun interface MaskProvider {
        /** Returns the mask for output frame [frameIndex] or null when unavailable (fails closed). */
        fun maskForOutputFrame(frameIndex: Int, outputPtsUs: Long): MaskFrame?
    }

    /**
     * Null rects mean full canvas. Rotations are cardinal only (0/90/180/270)
     * and applied explicitly; container rotation is NOT auto-applied.
     */
    class Request(
        val backgroundVideoPath: String,
        val foregroundVideoPath: String,
        val outputPath: String,
        val width: Int,
        val height: Int,
        val fps: Int,
        val bitrate: Int,
        val outputFrameCount: Int,
        val maskProvider: MaskProvider,
        val cancelFlag: AtomicBoolean = AtomicBoolean(false),
        val backgroundRect: CanvasRect? = null,
        val foregroundRect: CanvasRect? = null,
        val backgroundRotationDegrees: Int = 0,
        val foregroundRotationDegrees: Int = 0,
        val backgroundMirrorHorizontal: Boolean = false,
        val foregroundMirrorHorizontal: Boolean = false,
    )

    enum class TerminalState { SUCCESS, FAILED, CANCELLED }

    data class LaneTelemetry(
        val decoderName: String?,
        val contentWidth: Int,
        val contentHeight: Int,
        val containerRotationDegrees: Int,
        val decodedFrames: Int,
        val heldFrames: Int,
        val heldAfterEosFrames: Int,
        val droppedFrames: Int,
        val eosReached: Boolean,
    ) {
        fun toMap(prefix: String): Map<String, Any?> = mapOf(
            "${prefix}DecoderName" to decoderName, "${prefix}ContentWidth" to contentWidth,
            "${prefix}ContentHeight" to contentHeight, "${prefix}ContainerRotationDegrees" to containerRotationDegrees,
            "${prefix}DecodedFrames" to decodedFrames, "${prefix}HeldFrames" to heldFrames,
            "${prefix}HeldAfterEosFrames" to heldAfterEosFrames, "${prefix}DroppedFrames" to droppedFrames,
            "${prefix}EosReached" to eosReached,
        )

        companion object {
            val EMPTY = LaneTelemetry(null, 0, 0, 0, 0, 0, 0, 0, false)
        }
    }

    data class Result(
        val pass: Boolean,
        val terminalState: TerminalState,
        val reason: String,
        val outputPath: String,
        val outputSize: Long,
        val outputExists: Boolean,
        val tmpExists: Boolean,
        val outputFrameCount: Int,
        val renderedFrames: Int,
        val writtenVideoSamples: Int,
        val background: LaneTelemetry,
        val foreground: LaneTelemetry,
        val maskWidth: Int,
        val maskHeight: Int,
    ) {
        val renderedEqualsWritten: Boolean get() = renderedFrames == writtenVideoSamples

        val claims: List<String>
            get() = buildList {
                add("generic_green_screen_export_engine_boundary")
                add("cancellation_ready_terminal_state")
                if (pass) {
                    add("fixed_output_clock_two_input_frame_pairing")
                    add("newest_input_frame_at_or_before_output_pts_selection")
                    add("input_eos_hold_last_frame_telemetry")
                    add("superseded_input_frame_drop_telemetry")
                    add("hardware_decoded_private_gpu_sampled_inputs")
                    add("cpu_r8_mask_frozen_dimensions")
                    add("rendered_equals_written_samples")
                    add("atomic_tmp_rename_output")
                }
                if (!tmpExists) add("clean_tmp_cleanup")
            }

        val nonClaims: List<String> get() = NON_CLAIMS

        fun toMap(): Map<String, Any?> = buildMap {
            put("pass", pass)
            put("terminalState", terminalState.name.lowercase())
            put("reason", reason)
            put("engineBoundary", ENGINE_BOUNDARY)
            put("outputPath", outputPath)
            put("outputSize", outputSize)
            put("outputExists", outputExists)
            put("tmpExists", tmpExists)
            put("outputFrameCount", outputFrameCount)
            put("renderedFrames", renderedFrames)
            put("writtenVideoSamples", writtenVideoSamples)
            put("renderedEqualsWritten", renderedEqualsWritten)
            putAll(background.toMap("background"))
            putAll(foreground.toMap("foreground"))
            put("maskWidth", maskWidth)
            put("maskHeight", maskHeight)
            put("claims", claims)
            put("nonClaims", nonClaims)
        }
    }

    /** Runs the export synchronously on the calling thread. */
    fun export(request: Request): Result {
        val validationError = validateRequest(request)
        if (validationError != null) {
            return Result(
                pass = false,
                terminalState = TerminalState.FAILED,
                reason = validationError,
                outputPath = request.outputPath,
                outputSize = 0L,
                outputExists = File(request.outputPath).exists(),
                tmpExists = File("${request.outputPath}.tmp").exists(),
                outputFrameCount = request.outputFrameCount,
                renderedFrames = 0,
                writtenVideoSamples = 0,
                background = LaneTelemetry.EMPTY,
                foreground = LaneTelemetry.EMPTY,
                maskWidth = 0,
                maskHeight = 0,
            )
        }
        return ExportRun(request).run()
    }

    fun outputPtsUs(frameIndex: Int, fps: Int): Long = frameIndex * 1_000_000L / fps

    private fun validateRequest(r: Request): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "api_below_29"
        if (r.backgroundVideoPath.isBlank() || r.foregroundVideoPath.isBlank() || r.outputPath.isBlank()) {
            return "invalid_args:blank_path"
        }
        if (!File(r.backgroundVideoPath).isFile) return "background_input_missing"
        if (!File(r.foregroundVideoPath).isFile) return "foreground_input_missing"
        if (r.width <= 0 || r.height <= 0) return "invalid_args:canvas"
        if (r.fps <= 0) return "invalid_args:fps"
        if (r.bitrate <= 0) return "invalid_args:bitrate"
        if (r.outputFrameCount <= 0) return "invalid_args:outputFrameCount"
        if (!CARDINAL_ROTATIONS.contains(r.backgroundRotationDegrees)) {
            return "rotation_not_cardinal:background:${r.backgroundRotationDegrees}"
        }
        if (!CARDINAL_ROTATIONS.contains(r.foregroundRotationDegrees)) {
            return "rotation_not_cardinal:foreground:${r.foregroundRotationDegrees}"
        }
        val bgRect = r.backgroundRect
        if (bgRect != null && !bgRect.fitsInside(r.width, r.height)) return "rect_invalid:background"
        val fgRect = r.foregroundRect
        if (fgRect != null && !fgRect.fitsInside(r.width, r.height)) return "rect_invalid:foreground"
        val outputFile = File(r.outputPath)
        val parent = outputFile.parentFile
        if (parent == null || !parent.isDirectory) return "output_directory_missing"
        if (outputFile.exists()) return "output_already_exists"
        return null
    }

    private fun closeQuietly(buffer: HardwareBuffer?) {
        try { buffer?.close() } catch (_: Throwable) {}
    }

    private fun deleteQuietly(file: File) {
        try { if (file.exists()) file.delete() } catch (_: Throwable) {}
    }

    private sealed class Outcome {
        object Success : Outcome()
        object Cancelled : Outcome()
        class Failed(val reason: String) : Outcome()
    }

    // ── One export run: owns every resource and the terminal-state transition ──

    private class ExportRun(private val req: Request) {
        private val tmpPath = "${req.outputPath}.tmp"

        private var encoder: MediaCodec? = null
        private var encoderSurface: Surface? = null
        private var muxer: MediaMuxer? = null
        private var muxerStarted = false
        private var muxerStoppedCleanly = false
        private var videoTrackIndex = -1
        private val encoderBufferInfo = MediaCodec.BufferInfo()

        private var nativeBridge: VanguardNativeBridge? = null
        private var sessionId: String? = null
        private var maskTextureHandle = 0L
        private var maskWidth = 0
        private var maskHeight = 0

        private var background: DecodeLane? = null
        private var foreground: DecodeLane? = null

        private var renderedFrames = 0
        private var writtenVideoSamples = 0
        private val released = AtomicBoolean(false)

        fun run(): Result {
            val outcome: Outcome = try {
                execute()
            } catch (t: Throwable) {
                Log.e(TAG, "green-screen export uncaught exception", t)
                Outcome.Failed("exception:${t.javaClass.simpleName}:${t.message}")
            } finally {
                releaseResources()
            }

            val tmpFile = File(tmpPath)
            val outputFile = File(req.outputPath)
            val terminalState: TerminalState
            val reason: String
            when (outcome) {
                is Outcome.Success -> {
                    val renamed = try { tmpFile.renameTo(outputFile) } catch (_: Throwable) { false }
                    if (!renamed) {
                        deleteQuietly(tmpFile)
                        terminalState = TerminalState.FAILED
                        reason = "output_rename_failed"
                    } else if (!outputFile.exists() || outputFile.length() <= 0L) {
                        deleteQuietly(outputFile)
                        terminalState = TerminalState.FAILED
                        reason = "output_missing_after_rename"
                    } else {
                        terminalState = TerminalState.SUCCESS
                        reason = "success"
                    }
                }
                is Outcome.Cancelled -> {
                    deleteQuietly(tmpFile)
                    terminalState = TerminalState.CANCELLED
                    reason = "cancelled"
                }
                is Outcome.Failed -> {
                    deleteQuietly(tmpFile)
                    terminalState = TerminalState.FAILED
                    reason = outcome.reason
                }
            }

            val outputExists = outputFile.exists()
            val pass = terminalState == TerminalState.SUCCESS
            return Result(
                pass = pass,
                terminalState = terminalState,
                reason = reason,
                outputPath = req.outputPath,
                outputSize = if (outputExists) outputFile.length() else 0L,
                outputExists = outputExists,
                tmpExists = tmpFile.exists(),
                outputFrameCount = req.outputFrameCount,
                renderedFrames = renderedFrames,
                writtenVideoSamples = writtenVideoSamples,
                background = background?.telemetry() ?: LaneTelemetry.EMPTY,
                foreground = foreground?.telemetry() ?: LaneTelemetry.EMPTY,
                maskWidth = maskWidth,
                maskHeight = maskHeight,
            )
        }

        private fun cancelled(): Boolean = req.cancelFlag.get()

        private fun execute(): Outcome {
            if (cancelled()) return Outcome.Cancelled
            val staleTmp = File(tmpPath)
            if (staleTmp.exists() && !staleTmp.delete()) return Outcome.Failed("stale_tmp_delete_failed")

            // Decoders first: bad inputs fail before any encoder/native allocation.
            val bg = DecodeLane("background", req.backgroundVideoPath, req.cancelFlag).also { background = it }
            bg.prepare()?.let { return Outcome.Failed("background_decoder_prepare_failed:$it") }
            val fg = DecodeLane("foreground", req.foregroundVideoPath, req.cancelFlag).also { foreground = it }
            fg.prepare()?.let { return Outcome.Failed("foreground_decoder_prepare_failed:$it") }
            if (cancelled()) return Outcome.Cancelled

            // Encoder + muxer (tmp path).
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, req.width, req.height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, req.bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, req.fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_SECONDS)
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).also { encoder = it }
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = enc.createInputSurface().also { encoderSurface = it }
            muxer = MediaMuxer(tmpPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            enc.start()

            // Native export session on the encoder surface.
            val diagnostics = VanguardDiagnostics()
            val bridge = VanguardNativeBridge(VanguardLifecycleObserver(diagnostics), diagnostics, null)
                .also { nativeBridge = it }
            val createRaw = bridge.createAndroidTimelineVulkanExportSession(surface, req.width, req.height)
            if (!createRaw.startsWith("status=OK;")) {
                return Outcome.Failed("native_session_create_failed:${createRaw.take(160)}")
            }
            val sid = createRaw.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
                ?: return Outcome.Failed("native_session_id_parse_failed")
            sessionId = sid

            val bgRect = req.backgroundRect ?: CanvasRect(0, 0, req.width, req.height)
            val fgRect = req.foregroundRect ?: CanvasRect(0, 0, req.width, req.height)

            for (frameIndex in 0 until req.outputFrameCount) {
                if (cancelled()) return Outcome.Cancelled
                val ptsUs = outputPtsUs(frameIndex, req.fps)

                val bgFrame = when (val sel = bg.selectFrameFor(ptsUs)) {
                    is LaneSelection.Selected -> sel.frame
                    is LaneSelection.Cancelled -> return Outcome.Cancelled
                    is LaneSelection.Failed -> return Outcome.Failed("background_pairing_failed:frame=$frameIndex:${sel.reason}")
                }
                val fgFrame = when (val sel = fg.selectFrameFor(ptsUs)) {
                    is LaneSelection.Selected -> sel.frame
                    is LaneSelection.Cancelled -> return Outcome.Cancelled
                    is LaneSelection.Failed -> return Outcome.Failed("foreground_pairing_failed:frame=$frameIndex:${sel.reason}")
                }

                val mask: MaskFrame = try {
                    req.maskProvider.maskForOutputFrame(frameIndex, ptsUs)
                        ?: return Outcome.Failed("mask_unavailable:frame=$frameIndex")
                } catch (t: Throwable) {
                    return Outcome.Failed("mask_provider_exception:frame=$frameIndex:${t.javaClass.simpleName}:${t.message}")
                }
                uploadMask(bridge, sid, mask, frameIndex)?.let { return Outcome.Failed(it) }
                if (cancelled()) return Outcome.Cancelled

                renderFrame(bridge, sid, frameIndex, ptsUs, bgFrame, fgFrame, bgRect, fgRect, bg, fg)
                    ?.let { return Outcome.Failed(it) }
                renderedFrames++
                drainEncoder(enc, endOfStream = false, budgetMs = ENCODER_DRAIN_BUDGET_MS)
            }

            if (cancelled()) return Outcome.Cancelled
            enc.signalEndOfInputStream()
            drainEncoder(enc, endOfStream = true, budgetMs = ENCODER_EOS_DRAIN_BUDGET_MS)

            if (renderedFrames != req.outputFrameCount || writtenVideoSamples != renderedFrames) {
                return Outcome.Failed(
                    "sample_count_mismatch;rendered=$renderedFrames;written=$writtenVideoSamples;expected=${req.outputFrameCount}",
                )
            }
            val mux = muxer ?: return Outcome.Failed("muxer_missing")
            if (!muxerStarted) return Outcome.Failed("muxer_never_started")
            try {
                mux.stop()
                muxerStoppedCleanly = true
            } catch (t: Throwable) {
                return Outcome.Failed("muxer_stop_failed:${t.javaClass.simpleName}:${t.message}")
            }
            return Outcome.Success
        }

        private fun uploadMask(bridge: VanguardNativeBridge, sid: String, mask: MaskFrame, frameIndex: Int): String? {
            val cpu = mask as? MaskFrame.CpuR8
                ?: return "mask_frame_type_unsupported:${mask.javaClass.simpleName}:frame=$frameIndex"
            if (cpu.width <= 0 || cpu.height <= 0) {
                return "mask_dimensions_invalid:frame=$frameIndex:${cpu.width}x${cpu.height}"
            }
            if (!cpu.buffer.isDirect) return "mask_buffer_not_direct:frame=$frameIndex"
            val firstUpload = maskTextureHandle == 0L
            if (!firstUpload && (cpu.width != maskWidth || cpu.height != maskHeight)) {
                return "mask_dimensions_changed:frame=$frameIndex:expected=${maskWidth}x$maskHeight:actual=${cpu.width}x${cpu.height}"
            }
            val raw = bridge.uploadAndroidTimelineVulkanExportMaskTextureR8(
                sid, maskTextureHandle, cpu.buffer, cpu.width, cpu.height, cpu.rowStrideBytes,
            )
            if (!raw.startsWith("status=OK;")) return "mask_upload_failed:frame=$frameIndex:${raw.take(160)}"
            if (firstUpload) {
                val handle = raw.substringAfter("textureHandle=").substringBefore(";").toLongOrNull() ?: 0L
                if (handle <= 0L) return "mask_handle_parse_failed:${raw.take(160)}"
                maskTextureHandle = handle
                maskWidth = cpu.width
                maskHeight = cpu.height
            }
            return null
        }

        private fun renderFrame(
            bridge: VanguardNativeBridge,
            sid: String,
            frameIndex: Int,
            ptsUs: Long,
            bgFrame: DecodedFrame,
            fgFrame: DecodedFrame,
            bgRect: CanvasRect,
            fgRect: CanvasRect,
            bg: DecodeLane,
            fg: DecodeLane,
        ): String? {
            var bgHwb: HardwareBuffer? = null
            var fgHwb: HardwareBuffer? = null
            try {
                bgHwb = bgFrame.image.hardwareBuffer ?: return "hardware_buffer_null:background:frame=$frameIndex"
                fgHwb = fgFrame.image.hardwareBuffer ?: return "hardware_buffer_null:foreground:frame=$frameIndex"
                val raw = bridge.renderAndroidTimelineVulkanExportDuetGreenScreenFrame(
                    sid,
                    bgHwb,
                    fgHwb,
                    req.width, req.height,
                    bgRect.x, bgRect.y, bgRect.width, bgRect.height,
                    fgRect.x, fgRect.y, fgRect.width, fgRect.height,
                    bg.contentWidth, bg.contentHeight,
                    fg.contentWidth, fg.contentHeight,
                    maskTextureHandle,
                    req.backgroundRotationDegrees, req.backgroundMirrorHorizontal,
                    req.foregroundRotationDegrees, req.foregroundMirrorHorizontal,
                    NATIVE_DEBUG_MODE_NORMAL,
                    ptsUs,
                    frameIndex,
                )
                if (!raw.startsWith("status=OK;")) return "native_render_failed:frame=$frameIndex:${raw.take(160)}"
                return null
            } finally {
                // HardwareBuffers close after native returns; the Images stay open in their lanes.
                closeQuietly(bgHwb)
                closeQuietly(fgHwb)
            }
        }

        private fun drainEncoder(enc: MediaCodec, endOfStream: Boolean, budgetMs: Long) {
            val deadline = System.currentTimeMillis() + budgetMs
            var draining = true
            while (draining && System.currentTimeMillis() <= deadline) {
                val outIdx = enc.dequeueOutputBuffer(encoderBufferInfo, ENCODER_DEQUEUE_TIMEOUT_US)
                when {
                    outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (!endOfStream) draining = false
                    }
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val mux = muxer
                        if (videoTrackIndex < 0 && mux != null) {
                            videoTrackIndex = mux.addTrack(enc.outputFormat)
                            mux.start()
                            muxerStarted = true
                        }
                    }
                    outIdx >= 0 -> {
                        val isConfig = (encoderBufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        val isEos = (encoderBufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        val mux = muxer
                        if (!isConfig && encoderBufferInfo.size > 0 && muxerStarted && videoTrackIndex >= 0 && mux != null) {
                            val encoded = enc.getOutputBuffer(outIdx)
                            if (encoded != null) {
                                encoded.position(encoderBufferInfo.offset)
                                encoded.limit(encoderBufferInfo.offset + encoderBufferInfo.size)
                                encoderBufferInfo.presentationTimeUs = outputPtsUs(writtenVideoSamples, req.fps)
                                mux.writeSampleData(videoTrackIndex, encoded, encoderBufferInfo)
                                writtenVideoSamples++
                            }
                        }
                        enc.releaseOutputBuffer(outIdx, false)
                        if (isEos) draining = false
                    }
                }
            }
        }

        /** Idempotent. Order: mask handle → native session → encoder/surface → muxer → lanes. */
        private fun releaseResources() {
            if (!released.compareAndSet(false, true)) return
            val bridge = nativeBridge
            val sid = sessionId
            if (bridge != null && sid != null) {
                if (maskTextureHandle > 0L) {
                    try { bridge.releaseAndroidTimelineVulkanExportOverlayTexture(sid, maskTextureHandle) } catch (_: Throwable) {}
                }
                try { bridge.destroyAndroidTimelineVulkanExportSession(sid) } catch (_: Throwable) {}
            }
            sessionId = null
            nativeBridge = null
            try { encoder?.stop() } catch (_: Throwable) {}
            try { encoder?.release() } catch (_: Throwable) {}
            encoder = null
            try { encoderSurface?.release() } catch (_: Throwable) {}
            encoderSurface = null
            val mux = muxer
            if (mux != null) {
                if (muxerStarted && !muxerStoppedCleanly) {
                    try { mux.stop() } catch (_: Throwable) {}
                }
                try { mux.release() } catch (_: Throwable) {}
            }
            muxer = null
            // Lanes are kept (closed) so their telemetry survives into the Result.
            try { background?.close() } catch (_: Throwable) {}
            try { foreground?.close() } catch (_: Throwable) {}
        }
    }

    // ── Decode lane: one input, hardware decoder → ImageReader.PRIVATE, pairing state ──

    private class DecodedFrame(val image: Image, val ptsUs: Long) {
        private var closed = false
        fun close() {
            if (closed) return
            closed = true
            try { image.close() } catch (_: Throwable) {}
        }
    }

    private sealed class DecodeStep {
        class Frame(val frame: DecodedFrame) : DecodeStep()
        object Eos : DecodeStep()
        object Cancelled : DecodeStep()
        class Failed(val reason: String) : DecodeStep()
    }

    private sealed class LaneSelection {
        class Selected(val frame: DecodedFrame, val reused: Boolean) : LaneSelection()
        object Cancelled : LaneSelection()
        class Failed(val reason: String) : LaneSelection()
    }

    private class DecodeLane(
        val label: String,
        private val videoPath: String,
        private val cancelFlag: AtomicBoolean,
    ) {
        var decoderName: String? = null; private set
        var contentWidth: Int = 0; private set
        var contentHeight: Int = 0; private set
        var containerRotationDegrees: Int = 0; private set
        var decodedFrames: Int = 0; private set
        var heldFrames: Int = 0; private set
        var heldAfterEosFrames: Int = 0; private set
        var droppedFrames: Int = 0; private set
        var eosReached: Boolean = false; private set

        private var extractor: MediaExtractor? = null
        private var codec: MediaCodec? = null
        private var imageReader: ImageReader? = null
        private var handlerThread: HandlerThread? = null
        private val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES)
        private var inputDone = false
        private var outputDone = false

        /** Frame selected for the latest output (open until replaced/closed) and its render count. */
        private var current: DecodedFrame? = null
        private var currentUseCount = 0
        /** Decoded lookahead whose pts is later than the last output pts. */
        private var pending: DecodedFrame? = null
        private val closed = AtomicBoolean(false)

        fun telemetry(): LaneTelemetry = LaneTelemetry(
            decoderName = decoderName,
            contentWidth = contentWidth,
            contentHeight = contentHeight,
            containerRotationDegrees = containerRotationDegrees,
            decodedFrames = decodedFrames,
            heldFrames = heldFrames,
            heldAfterEosFrames = heldAfterEosFrames,
            droppedFrames = droppedFrames,
            eosReached = eosReached,
        )

        fun prepare(): String? {
            return try {
                val ex = MediaExtractor().also { extractor = it }
                ex.setDataSource(videoPath)
                var trackIndex = -1
                var format: MediaFormat? = null
                for (i in 0 until ex.trackCount) {
                    val trackFormat = ex.getTrackFormat(i)
                    val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: ""
                    if (mime.startsWith("video/")) {
                        trackIndex = i
                        format = trackFormat
                        break
                    }
                }
                if (trackIndex < 0 || format == null) return "no_video_track"
                ex.selectTrack(trackIndex)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: return "track_mime_missing"
                contentWidth = format.getInteger(MediaFormat.KEY_WIDTH)
                contentHeight = format.getInteger(MediaFormat.KEY_HEIGHT)
                if (contentWidth <= 0 || contentHeight <= 0) {
                    return "track_dimensions_invalid:${contentWidth}x$contentHeight"
                }
                containerRotationDegrees = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                    format.getInteger(MediaFormat.KEY_ROTATION)
                } else {
                    0
                }
                val name = selectHardwareDecoderName(mime) ?: return "no_hardware_decoder_available;mime=$mime"
                decoderName = name

                val ht = HandlerThread("VgGreenScreenExport-$label").also {
                    handlerThread = it
                    it.start()
                }
                val reader = ImageReader.newInstance(
                    contentWidth,
                    contentHeight,
                    ImageFormat.PRIVATE,
                    IMAGE_READER_MAX_IMAGES,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                ).also { imageReader = it }
                reader.setOnImageAvailableListener(
                    { r ->
                        try {
                            val img = r.acquireNextImage()
                            if (img != null && !imageQueue.offer(img)) {
                                img.close()
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "acquireNextImage failed for $label: $e")
                        }
                    },
                    Handler(ht.looper),
                )
                // Never let the decoder auto-rotate; rotation is an explicit engine parameter.
                format.setInteger(MediaFormat.KEY_ROTATION, 0)
                val dec = MediaCodec.createByCodecName(name).also { codec = it }
                dec.configure(format, reader.surface, null, 0)
                dec.start()
                null
            } catch (t: Throwable) {
                Log.e(TAG, "DecodeLane.prepare failed for $label", t)
                "codec_configure_failed;reason=${t.javaClass.simpleName}:${t.message}"
            }
        }

        /** Newest decoded frame with pts <= [outputPtsUs]; counts drops (superseded, unrendered) and holds (reuse). */
        fun selectFrameFor(outputPtsUs: Long): LaneSelection {
            if (closed.get()) return LaneSelection.Failed("lane_closed")
            while (true) {
                if (cancelFlag.get()) return LaneSelection.Cancelled
                val candidate: DecodedFrame? = pending ?: if (eosReached) {
                    null
                } else {
                    when (val step = decodeNext()) {
                        is DecodeStep.Frame -> step.frame
                        is DecodeStep.Eos -> {
                            eosReached = true
                            null
                        }
                        is DecodeStep.Cancelled -> return LaneSelection.Cancelled
                        is DecodeStep.Failed -> return LaneSelection.Failed(step.reason)
                    }
                }
                if (candidate == null) break
                if (candidate.ptsUs <= outputPtsUs) {
                    val previous = current
                    if (previous != null) {
                        if (currentUseCount == 0) droppedFrames++
                        previous.close()
                    }
                    current = candidate
                    currentUseCount = 0
                    pending = null
                } else {
                    pending = candidate
                    break
                }
            }
            val selected = current ?: return LaneSelection.Failed("no_frame_at_or_before_pts:$outputPtsUs")
            val reused = currentUseCount > 0
            if (reused) {
                heldFrames++
                if (eosReached && pending == null) heldAfterEosFrames++
            }
            currentUseCount++
            return LaneSelection.Selected(selected, reused)
        }

        private fun decodeNext(): DecodeStep {
            val dec = codec ?: return DecodeStep.Failed("codec_missing")
            if (outputDone) return DecodeStep.Eos
            var noOutputAttempts = 0
            val info = MediaCodec.BufferInfo()
            while (true) {
                if (cancelFlag.get()) return DecodeStep.Cancelled
                feedInput(dec)
                val outIdx = dec.dequeueOutputBuffer(info, DECODER_DEQUEUE_TIMEOUT_US)
                if (outIdx >= 0) {
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    val renderable = info.size > 0
                    dec.releaseOutputBuffer(outIdx, renderable)
                    if (isEos) outputDone = true
                    if (renderable) {
                        val image = imageQueue.poll(IMAGE_ACQUIRE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                            ?: return DecodeStep.Failed("image_acquire_timeout")
                        awaitFence(image)
                        decodedFrames++
                        return DecodeStep.Frame(DecodedFrame(image, info.presentationTimeUs))
                    }
                    if (isEos) return DecodeStep.Eos
                    noOutputAttempts = 0
                    continue
                }
                noOutputAttempts++
                if (noOutputAttempts >= MAX_NO_OUTPUT_ATTEMPTS) {
                    return DecodeStep.Failed("decoder_stalled;attempts=$noOutputAttempts")
                }
            }
        }

        private fun feedInput(dec: MediaCodec) {
            val ex = extractor ?: return
            while (!inputDone) {
                val inIdx = dec.dequeueInputBuffer(0)
                if (inIdx < 0) return
                val buf = dec.getInputBuffer(inIdx)
                if (buf == null) {
                    dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                    return
                }
                val size = ex.readSampleData(buf, 0)
                if (size < 0) {
                    dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                } else {
                    dec.queueInputBuffer(inIdx, 0, size, ex.sampleTime, 0)
                    ex.advance()
                }
            }
        }

        private fun awaitFence(image: Image) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
            try {
                val fence = image.fence
                try {
                    if (fence.isValid) fence.await(java.time.Duration.ofMillis(FENCE_WAIT_MS))
                } finally {
                    try { fence.close() } catch (_: Throwable) {}
                }
            } catch (t: Throwable) {
                Log.w(TAG, "SyncFence exception for $label: $t")
            }
        }

        private fun selectHardwareDecoderName(mime: String): String? {
            return try {
                val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
                list.codecInfos.firstOrNull { info ->
                    !info.isEncoder &&
                        info.isHardwareAccelerated &&
                        info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
                }?.name
            } catch (t: Throwable) {
                Log.w(TAG, "selectHardwareDecoderName failed for mime=$mime: $t")
                null
            }
        }

        /** Idempotent. Held Images close first, then codec, reader, thread, extractor. */
        fun close() {
            if (!closed.compareAndSet(false, true)) return
            current?.close()
            current = null
            pending?.close()
            pending = null
            while (true) {
                val img = imageQueue.poll() ?: break
                try { img.close() } catch (_: Throwable) {}
            }
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            codec = null
            try { imageReader?.close() } catch (_: Throwable) {}
            imageReader = null
            try { handlerThread?.quitSafely() } catch (_: Throwable) {}
            handlerThread = null
            try { extractor?.release() } catch (_: Throwable) {}
            extractor = null
        }
    }
}
