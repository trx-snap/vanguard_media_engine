package com.connects.vanguard_media_engine.diagnostics

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.util.Log
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * ANDROID-GREENSCREEN-EXPORT-API decoded-pixel proof diagnostic coordinator.
 *
 * Provides deterministic native fixture generation and decoded-pixel validation
 * helpers for the public green-screen export API physical smoke test.
 *
 * Routes owned:
 *  - [METHOD_PREPARE]: generates deterministic foreground MP4, background PNG,
 *    and R8 mask frame files.
 *  - [METHOD_ASSERT]: decodes exported MP4 via MediaMetadataRetriever and
 *    asserts expected pixel values per frame.
 *
 * Diagnostic only: not wired into production export, Duet, or product UI.
 */
class AndroidGreenScreenExportApiPixelProofSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardGSPixelProof"
        const val METHOD_PREPARE = "prepareAndroidGreenScreenExportApiPixelProofFixtures"
        const val METHOD_ASSERT = "assertAndroidGreenScreenExportApiPixelProofOutput"
        private val OWNED_METHODS = setOf(METHOD_PREPARE, METHOD_ASSERT)

        private const val DEFAULT_WIDTH = 360
        private const val DEFAULT_HEIGHT = 640
        private const val DEFAULT_FPS = 30
        private const val DEFAULT_FRAME_COUNT = 6
        private const val DEFAULT_BITRATE = 1_500_000
        private const val DEFAULT_PIXEL_TOLERANCE = 80
        private const val FIXTURE_FRAME_SLEEP_MS = 40L

        val DEFAULT_FOREGROUND_RGB = intArrayOf(240, 20, 20)
        val DEFAULT_SOLID_BACKGROUND_RGB = intArrayOf(20, 20, 240)
        val DEFAULT_IMAGE_CENTER_RGB = intArrayOf(20, 240, 20)
        val DEFAULT_LETTERBOX_RGB = intArrayOf(0, 0, 0)

        fun ownsMethod(method: String): Boolean = OWNED_METHODS.contains(method)
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-gs-pixel-proof-coordinator").apply { isDaemon = true }
    }
    private val disposed = AtomicBoolean(false)

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        when (method) {
            METHOD_PREPARE -> handlePrepare(args, result)
            METHOD_ASSERT -> handleAssert(args, result)
            else -> result.notImplemented()
        }
    }

    fun disposeAll() {
        if (disposed.compareAndSet(false, true)) {
            executor.shutdown()
        }
    }

    // ── Fixture preparation ──────────────────────────────────────────────────

    private fun handlePrepare(args: Map<*, *>?, result: MethodChannel.Result) {
        if (disposed.get()) {
            result.error("DISPOSED", "Coordinator disposed", null)
            return
        }
        val workDirPath = args?.get("workDir") as? String
        if (workDirPath.isNullOrBlank()) {
            result.error("INVALID_ARG", "$METHOD_PREPARE: 'workDir' required", null)
            return
        }
        val width = (args["width"] as? Number)?.toInt() ?: DEFAULT_WIDTH
        val height = (args["height"] as? Number)?.toInt() ?: DEFAULT_HEIGHT
        val fps = (args["fps"] as? Number)?.toInt() ?: DEFAULT_FPS
        val frameCount = (args["frameCount"] as? Number)?.toInt() ?: DEFAULT_FRAME_COUNT
        val bitrate = (args["bitrate"] as? Number)?.toInt() ?: DEFAULT_BITRATE

        try {
            executor.execute {
                try {
                    val payload = prepareFixtures(
                        workDirPath = workDirPath,
                        width = width,
                        height = height,
                        fps = fps,
                        frameCount = frameCount,
                        bitrate = bitrate,
                    )
                    mainHandler.post { result.success(payload) }
                } catch (t: Throwable) {
                    Log.e(TAG, "$METHOD_PREPARE failed", t)
                    mainHandler.post {
                        result.success(
                            mapOf(
                                "pass" to false,
                                "reason" to "exception:${t.javaClass.simpleName}:${t.message}",
                            ),
                        )
                    }
                }
            }
        } catch (t: Throwable) {
            result.error("REJECTED", "$METHOD_PREPARE rejected: ${t.message}", null)
        }
    }

    private fun prepareFixtures(
        workDirPath: String,
        width: Int,
        height: Int,
        fps: Int,
        frameCount: Int,
        bitrate: Int,
    ): Map<String, Any?> {
        val workDir = File(workDirPath)
        if (!workDir.exists() && !workDir.mkdirs()) {
            return mapOf("pass" to false, "reason" to "work_dir_creation_failed")
        }

        val fgFixturePath = File(workDir, "gs_proof_fg_fixture.mp4").absolutePath
        val bgImagePath = File(workDir, "gs_proof_bg_image.png").absolutePath

        // 1. Generate deterministic foreground MP4 (solid red)
        val fgError = generateSolidColorFixtureVideo(
            outputPath = fgFixturePath,
            width = width,
            height = height,
            color = Color.rgb(DEFAULT_FOREGROUND_RGB[0], DEFAULT_FOREGROUND_RGB[1], DEFAULT_FOREGROUND_RGB[2]),
            frameCount = frameCount,
            fps = fps,
            bitrate = bitrate,
        )
        if (fgError != null) {
            return mapOf("pass" to false, "reason" to "foreground_fixture_failed:$fgError")
        }

        // 2. Generate deterministic landscape PNG background (320x160, stable center green)
        val pngError = generateLandscapePng(bgImagePath)
        if (pngError != null) {
            return mapOf("pass" to false, "reason" to "background_png_failed:$pngError")
        }

        // 3. Generate alternating R8 mask files (frame 0 = 0/bg, frame 1 = 255/fg)
        val (maskPaths, maskError) = generateR8MaskFiles(workDir, frameCount)
        if (maskError != null) {
            return mapOf("pass" to false, "reason" to "r8_masks_failed:$maskError")
        }

        return mapOf(
            "pass" to true,
            "reason" to "pass",
            "foregroundVideoPath" to fgFixturePath,
            "backgroundImagePath" to bgImagePath,
            "maskFramePaths" to maskPaths,
            "maskWidth" to 64,
            "maskHeight" to 64,
            "expectedForegroundRgb" to DEFAULT_FOREGROUND_RGB.toList(),
            "expectedSolidBackgroundRgb" to DEFAULT_SOLID_BACKGROUND_RGB.toList(),
            "expectedImageCenterRgb" to DEFAULT_IMAGE_CENTER_RGB.toList(),
            "expectedLetterboxRgb" to DEFAULT_LETTERBOX_RGB.toList(),
        )
    }

    private fun generateSolidColorFixtureVideo(
        outputPath: String,
        width: Int,
        height: Int,
        color: Int,
        frameCount: Int,
        fps: Int,
        bitrate: Int,
    ): String? {
        val frameDurationUs = 1_000_000L / fps.coerceAtLeast(1)
        var codec: MediaCodec? = null
        var encoderSurface: Surface? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var videoTrackIndex = -1
        var writtenVideoSamples = 0
        var muxerStoppedCleanly = false

        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderSurface = codec.createInputSurface()
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            codec.start()

            val bufferInfo = MediaCodec.BufferInfo()
            val nonNullCodec = codec
            val nonNullMuxer = muxer

            fun drainOutput(endOfStream: Boolean, timeoutMs: Long) {
                val deadline = System.currentTimeMillis() + timeoutMs
                var draining = true
                while (draining && System.currentTimeMillis() <= deadline) {
                    val outIdx = nonNullCodec.dequeueOutputBuffer(bufferInfo, 10_000L)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            if (!endOfStream) draining = false
                        }
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (videoTrackIndex < 0) {
                                videoTrackIndex = nonNullMuxer.addTrack(nonNullCodec.outputFormat)
                                nonNullMuxer.start()
                                muxerStarted = true
                            }
                        }
                        outIdx >= 0 -> {
                            val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                            val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            if (!isConfig && bufferInfo.size > 0 && muxerStarted && videoTrackIndex >= 0) {
                                val encodedData = nonNullCodec.getOutputBuffer(outIdx)
                                if (encodedData != null) {
                                    encodedData.position(bufferInfo.offset)
                                    encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                    bufferInfo.presentationTimeUs = writtenVideoSamples * frameDurationUs
                                    nonNullMuxer.writeSampleData(videoTrackIndex, encodedData, bufferInfo)
                                    writtenVideoSamples++
                                }
                            }
                            nonNullCodec.releaseOutputBuffer(outIdx, false)
                            if (isEos) draining = false
                        }
                    }
                }
            }

            for (frameIdx in 0 until frameCount) {
                val canvas = try {
                    encoderSurface.lockHardwareCanvas()
                } catch (_: Throwable) {
                    encoderSurface.lockCanvas(null)
                }
                canvas.drawColor(color)
                encoderSurface.unlockCanvasAndPost(canvas)
                drainOutput(endOfStream = false, timeoutMs = 200L)
                try { Thread.sleep(FIXTURE_FRAME_SLEEP_MS) } catch (_: Throwable) {}
            }

            codec.signalEndOfInputStream()
            drainOutput(endOfStream = true, timeoutMs = 5000L)

            if (muxerStarted && writtenVideoSamples > 0) {
                try {
                    muxer.stop()
                    muxerStoppedCleanly = true
                } catch (t: Throwable) {
                    Log.w(TAG, "generateSolidColorFixtureVideo: MediaMuxer.stop failed: $t")
                }
            }

            val file = File(outputPath)
            val success = muxerStoppedCleanly && file.exists() && file.length() > 0L && writtenVideoSamples == frameCount
            return if (success) null else "fixture_incomplete;written=$writtenVideoSamples;expected=$frameCount"
        } catch (t: Throwable) {
            Log.e(TAG, "generateSolidColorFixtureVideo failed", t)
            return "fixture_exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            try { encoderSurface?.release() } catch (_: Throwable) {}
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
        }
    }

    private fun generateLandscapePng(outputPath: String): String? {
        val imgWidth = 320
        val imgHeight = 160
        val bitmap = Bitmap.createBitmap(imgWidth, imgHeight, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            // Center and overall fill: green [20, 240, 20]
            val green = Color.rgb(DEFAULT_IMAGE_CENTER_RGB[0], DEFAULT_IMAGE_CENTER_RGB[1], DEFAULT_IMAGE_CENTER_RGB[2])
            canvas.drawColor(green)

            // Side decoration accents: cyan, yellow, magenta
            val paint = Paint()
            paint.color = Color.rgb(20, 240, 240) // cyan
            canvas.drawRect(Rect(0, 0, 40, imgHeight), paint)

            paint.color = Color.rgb(240, 240, 20) // yellow
            canvas.drawRect(Rect(imgWidth - 40, 0, imgWidth, imgHeight), paint)

            paint.color = Color.rgb(240, 20, 240) // magenta
            canvas.drawRect(Rect(0, 0, 30, 30), paint)
            canvas.drawRect(Rect(imgWidth - 30, 0, imgWidth, 30), paint)

            // Center vertical strip (x: 80..240) remains solid green [20, 240, 20]
            val file = File(outputPath)
            FileOutputStream(file).use { out ->
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
                    return "png_compress_failed"
                }
                out.flush()
            }
            return if (file.exists() && file.length() > 0L) null else "png_file_missing_or_empty"
        } catch (t: Throwable) {
            return "png_generation_exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            bitmap.recycle()
        }
    }

    private fun generateR8MaskFiles(
        workDir: File,
        frameCount: Int,
        maskDim: Int = 64,
    ): Pair<List<String>, String?> {
        val paths = mutableListOf<String>()
        val bufferSize = maskDim * maskDim
        val zeroBytes = ByteArray(bufferSize) { 0 }
        val fullBytes = ByteArray(bufferSize) { (255 and 0xFF).toByte() }

        for (i in 0 until frameCount) {
            val maskFile = File(workDir, "gs_proof_mask_frame_$i.r8")
            try {
                FileOutputStream(maskFile).use { fos ->
                    val bytes = if (i % 2 == 0) zeroBytes else fullBytes
                    fos.write(bytes)
                    fos.flush()
                }
                if (!maskFile.exists() || maskFile.length() < bufferSize.toLong()) {
                    return Pair(emptyList(), "mask_file_short_or_missing:$i")
                }
                paths.add(maskFile.absolutePath)
            } catch (t: Throwable) {
                return Pair(emptyList(), "mask_write_exception:$i:${t.javaClass.simpleName}:${t.message}")
            }
        }
        return Pair(paths, null)
    }

    // ── Decoded-pixel output assertion ───────────────────────────────────────

    private fun handleAssert(args: Map<*, *>?, result: MethodChannel.Result) {
        if (disposed.get()) {
            result.success(mapOf("pass" to false, "reason" to "coordinator_disposed"))
            return
        }
        val outputPath = args?.get("outputPath") as? String
        val lane = args?.get("lane") as? String
        if (outputPath.isNullOrBlank() || lane.isNullOrBlank()) {
            result.success(
                mapOf(
                    "pass" to false,
                    "reason" to "invalid_arguments: outputPath and lane required",
                ),
            )
            return
        }

        val width = (args["width"] as? Number)?.toInt() ?: DEFAULT_WIDTH
        val height = (args["height"] as? Number)?.toInt() ?: DEFAULT_HEIGHT
        val fps = (args["fps"] as? Number)?.toInt() ?: DEFAULT_FPS
        val frameCount = (args["frameCount"] as? Number)?.toInt() ?: DEFAULT_FRAME_COUNT
        val tolerance = (args["tolerance"] as? Number)?.toInt() ?: DEFAULT_PIXEL_TOLERANCE

        val expectedFg = parseRgbList(args["expectedForegroundRgb"], DEFAULT_FOREGROUND_RGB)
        val expectedBg = parseRgbList(args["expectedBackgroundRgb"], DEFAULT_SOLID_BACKGROUND_RGB)
        val expectedImgCenter = parseRgbList(args["expectedImageCenterRgb"], DEFAULT_IMAGE_CENTER_RGB)
        val expectedLetterbox = parseRgbList(args["expectedLetterboxRgb"], DEFAULT_LETTERBOX_RGB)

        try {
            executor.execute {
                val outcome = decodeAndAssert(
                    outputPath = outputPath,
                    lane = lane,
                    width = width,
                    height = height,
                    fps = fps,
                    frameCount = frameCount,
                    tolerance = tolerance,
                    expectedForegroundRgb = expectedFg,
                    expectedBackgroundRgb = expectedBg,
                    expectedImageCenterRgb = expectedImgCenter,
                    expectedLetterboxRgb = expectedLetterbox,
                )
                mainHandler.post { result.success(outcome) }
            }
        } catch (t: Throwable) {
            result.success(
                mapOf(
                    "pass" to false,
                    "reason" to "assertion_execution_rejected:${t.message}",
                ),
            )
        }
    }

    private fun decodeAndAssert(
        outputPath: String,
        lane: String,
        width: Int,
        height: Int,
        fps: Int,
        frameCount: Int,
        tolerance: Int,
        expectedForegroundRgb: IntArray,
        expectedBackgroundRgb: IntArray,
        expectedImageCenterRgb: IntArray,
        expectedLetterboxRgb: IntArray,
    ): Map<String, Any?> {
        val outputFile = File(outputPath)
        if (!outputFile.exists() || outputFile.length() == 0L) {
            return mapOf(
                "pass" to false,
                "reason" to "output_file_missing_or_empty",
                "lane" to lane,
                "outputPath" to outputPath,
            )
        }

        val frameDurationUs = 1_000_000L / fps.coerceAtLeast(1)
        val perFramePixelResults = mutableListOf<Map<String, Any?>>()
        var anySampleFailed = false

        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(outputPath)
            for (i in 0 until frameCount) {
                val timeUs = i * frameDurationUs + frameDurationUs / 4
                val bitmap = try {
                    retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                } catch (_: Throwable) {
                    null
                }
                if (bitmap == null) {
                    perFramePixelResults.add(
                        mapOf(
                            "frameIndex" to i,
                            "pass" to false,
                            "reason" to "decode_failed_null_bitmap",
                        ),
                    )
                    anySampleFailed = true
                    continue
                }

                val bw = bitmap.width
                val bh = bitmap.height
                val cx = (bw / 2).coerceIn(0, bw - 1)
                val cy = (bh / 2).coerceIn(0, bh - 1)

                when (lane) {
                    "solid_r8_ladder" -> {
                        val pixel = bitmap.getPixel(cx, cy)
                        val actual = intArrayOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel))
                        // Frame 0 = mask 0 (background = blue), Frame 1 = mask 255 (foreground = red)
                        val showsForeground = (i % 2 == 1)
                        val expected = if (showsForeground) expectedForegroundRgb else expectedBackgroundRgb
                        val diffs = IntArray(3) { c -> abs(actual[c] - expected[c]) }
                        val framePass = diffs.all { it <= tolerance }
                        if (!framePass) anySampleFailed = true
                        perFramePixelResults.add(
                            mapOf(
                                "frameIndex" to i,
                                "pass" to framePass,
                                "showsForeground" to showsForeground,
                                "expectedRgb" to expected.toList(),
                                "actualRgb" to actual.toList(),
                                "diffs" to diffs.toList(),
                            ),
                        )
                    }

                    "image_fit_background" -> {
                        // Top-center: sampled at y = bh / 10, must be black letterbox
                        val topX = cx
                        val topY = (bh / 10).coerceIn(0, bh - 1)
                        val topPixel = bitmap.getPixel(topX, topY)
                        val topActual = intArrayOf(Color.red(topPixel), Color.green(topPixel), Color.blue(topPixel))
                        val topExpected = expectedLetterboxRgb
                        val topDiffs = IntArray(3) { c -> abs(topActual[c] - topExpected[c]) }
                        val topPass = topDiffs.all { it <= tolerance }

                        // Center: sampled at (cx, cy), must match image center color
                        val centerPixel = bitmap.getPixel(cx, cy)
                        val centerActual = intArrayOf(Color.red(centerPixel), Color.green(centerPixel), Color.blue(centerPixel))
                        val centerExpected = expectedImageCenterRgb
                        val centerDiffs = IntArray(3) { c -> abs(centerActual[c] - centerExpected[c]) }
                        val centerPass = centerDiffs.all { it <= tolerance }

                        val framePass = topPass && centerPass
                        if (!framePass) anySampleFailed = true
                        perFramePixelResults.add(
                            mapOf(
                                "frameIndex" to i,
                                "pass" to framePass,
                                "topPass" to topPass,
                                "topActualRgb" to topActual.toList(),
                                "topExpectedRgb" to topExpected.toList(),
                                "topDiffs" to topDiffs.toList(),
                                "centerPass" to centerPass,
                                "centerActualRgb" to centerActual.toList(),
                                "centerExpectedRgb" to centerExpected.toList(),
                                "centerDiffs" to centerDiffs.toList(),
                            ),
                        )
                    }

                    "image_fill_background" -> {
                        // Top-center: sampled at y = bh / 10, must be non-black and match image color
                        val topX = cx
                        val topY = (bh / 10).coerceIn(0, bh - 1)
                        val topPixel = bitmap.getPixel(topX, topY)
                        val topActual = intArrayOf(Color.red(topPixel), Color.green(topPixel), Color.blue(topPixel))
                        val topExpected = expectedImageCenterRgb
                        val topDiffs = IntArray(3) { c -> abs(topActual[c] - topExpected[c]) }
                        val topMatchesImage = topDiffs.all { it <= tolerance }
                        val topIsNonBlack = topActual.any { it > 100 }
                        val topPass = topMatchesImage && topIsNonBlack

                        // Center: sampled at (cx, cy), must match image center color
                        val centerPixel = bitmap.getPixel(cx, cy)
                        val centerActual = intArrayOf(Color.red(centerPixel), Color.green(centerPixel), Color.blue(centerPixel))
                        val centerExpected = expectedImageCenterRgb
                        val centerDiffs = IntArray(3) { c -> abs(centerActual[c] - centerExpected[c]) }
                        val centerPass = centerDiffs.all { it <= tolerance }

                        val framePass = topPass && centerPass
                        if (!framePass) anySampleFailed = true
                        perFramePixelResults.add(
                            mapOf(
                                "frameIndex" to i,
                                "pass" to framePass,
                                "topPass" to topPass,
                                "topMatchesImage" to topMatchesImage,
                                "topIsNonBlack" to topIsNonBlack,
                                "topActualRgb" to topActual.toList(),
                                "topExpectedRgb" to topExpected.toList(),
                                "topDiffs" to topDiffs.toList(),
                                "centerPass" to centerPass,
                                "centerActualRgb" to centerActual.toList(),
                                "centerExpectedRgb" to centerExpected.toList(),
                                "centerDiffs" to centerDiffs.toList(),
                            ),
                        )
                    }

                    else -> {
                        perFramePixelResults.add(
                            mapOf(
                                "frameIndex" to i,
                                "pass" to false,
                                "reason" to "unknown_lane:$lane",
                            ),
                        )
                        anySampleFailed = true
                    }
                }
                bitmap.recycle()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "decodeAndAssert failed on $outputPath", t)
            return mapOf(
                "pass" to false,
                "reason" to "decode_exception:${t.javaClass.simpleName}:${t.message}",
                "lane" to lane,
                "outputPath" to outputPath,
                "perFramePixelResults" to perFramePixelResults,
            )
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }

        val isPass = perFramePixelResults.size == frameCount && !anySampleFailed
        val reason = if (isPass) "pass" else "pixel_assertion_failed_for_lane_$lane"
        return mapOf(
            "pass" to isPass,
            "reason" to reason,
            "lane" to lane,
            "outputPath" to outputPath,
            "frameCount" to frameCount,
            "decodedFrameCount" to perFramePixelResults.size,
            "pixelTolerance" to tolerance,
            "perFramePixelResults" to perFramePixelResults,
        )
    }

    private fun parseRgbList(raw: Any?, defaultVal: IntArray): IntArray {
        val list = raw as? List<*> ?: return defaultVal
        val ints = list.mapNotNull { (it as? Number)?.toInt() }
        return if (ints.size == 3) ints.toIntArray() else defaultVal
    }
}
