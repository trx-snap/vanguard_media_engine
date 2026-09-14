package com.connects.vanguard_media_engine.diagnostics

import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenExportEngine
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * ANDROID-GREENSCREEN-PRODUCTION-EXPORT (diagnostic only).
 *
 * Physical proof of the generic [AndroidGreenScreenExportEngine] boundary on
 * unequal input timing:
 *   1. Generates two deterministic solid-color MP4 fixtures at runtime. The
 *      background runs FASTER than the output clock (21 ms frames vs 33.3 ms)
 *      so the engine must drop superseded frames; the foreground runs SLOWER
 *      and is SHORTER (45 ms frames, 3 frames) so the engine must hold frames
 *      both between inputs and after EOS.
 *   2. Runs the engine with a procedural CPU R8 mask ladder alternating
 *      background (alpha 0) / foreground (alpha 255) per output frame.
 *   3. Decodes the produced MP4 with MediaMetadataRetriever and asserts each
 *      output frame's center pixel against the color expected from the fixed
 *      output clock + pairing policy + mask ladder.
 *   4. Asserts renderedFrames == writtenVideoSamples == outputFrameCount, no tmp
 *      leftover, output exists with size > 0, backgroundDroppedFrames > 0 and
 *      foregroundHeldFrames > 0. Fixtures are deleted in finally; output/tmp are
 *      deleted best-effort on failure.
 *
 * Never wires into Duet sessions, ConnectsApp, or the Universal Editor.
 */
object AndroidGreenScreenProductionExportSmokeHarness {
    private const val TAG = "VanguardGreenScreenProdExportSmoke"
    const val PROOF_BOUNDARY = "android_greenscreen_export_engine_unequal_input_timing_decoded_pixel_proof"

    private const val OUTPUT_FPS = 30
    private const val OUTPUT_FRAME_COUNT = 6
    private const val OUTPUT_FRAME_DURATION_US = 1_000_000L / OUTPUT_FPS
    private const val BACKGROUND_FRAME_DURATION_US = 21_000L
    private const val FOREGROUND_FRAME_DURATION_US = 45_000L
    private const val MASK_WIDTH = 63
    private const val MASK_HEIGHT = 63
    private const val PIXEL_TOLERANCE = 64
    private const val FIXTURE_FRAME_SLEEP_MS = 40L

    // Every color uses channel levels {20, 130, 240} so any two distinct
    // ladder entries differ by >= 110 in at least one channel: a wrong frame
    // pick is always detectable above PIXEL_TOLERANCE.
    private val BACKGROUND_COLORS = intArrayOf(
        Color.rgb(20, 20, 240), Color.rgb(240, 20, 20), Color.rgb(20, 240, 20),
        Color.rgb(240, 240, 20), Color.rgb(20, 240, 240), Color.rgb(240, 20, 240),
        Color.rgb(130, 130, 130), Color.rgb(240, 130, 20), Color.rgb(130, 20, 240),
    )
    private val FOREGROUND_COLORS = intArrayOf(
        Color.rgb(130, 20, 20), Color.rgb(20, 130, 20), Color.rgb(20, 20, 130),
    )

    fun runSmoke(
        outputPath: String,
        width: Int = 360,
        height: Int = 640,
        bitrate: Int = 1_500_000,
    ): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return failResult("api_below_29", outputPath, width, height, null, emptyList())
        }
        if (width <= 0 || height <= 0 || bitrate <= 0 || outputPath.isBlank()) {
            return failResult("invalid_args", outputPath, width, height, null, emptyList())
        }

        val timestamp = System.currentTimeMillis()
        val bgFixturePath = "${outputPath}_bg_fixture_$timestamp.mp4"
        val fgFixturePath = "${outputPath}_fg_fixture_$timestamp.mp4"
        val perFramePixelResults = mutableListOf<Map<String, Any?>>()
        var engineResult: AndroidGreenScreenExportEngine.Result? = null

        try {
            generateSolidColorFixtureVideo(
                bgFixturePath, width, height, BACKGROUND_COLORS, BACKGROUND_FRAME_DURATION_US, bitrate,
            )?.let {
                return failResult("background_fixture_generation_failed:$it", outputPath, width, height, null, perFramePixelResults)
            }
            generateSolidColorFixtureVideo(
                fgFixturePath, width, height, FOREGROUND_COLORS, FOREGROUND_FRAME_DURATION_US, bitrate,
            )?.let {
                return failResult("foreground_fixture_generation_failed:$it", outputPath, width, height, null, perFramePixelResults)
            }

            // Expected pairing from the fixed output clock, independent of the engine's lane state.
            val expectedBgIndex = IntArray(OUTPUT_FRAME_COUNT)
            val expectedFgIndex = IntArray(OUTPUT_FRAME_COUNT)
            val expectedShowsForeground = BooleanArray(OUTPUT_FRAME_COUNT)
            val expectedColors = IntArray(OUTPUT_FRAME_COUNT)
            var expectedBgDropped = 0
            var expectedBgHeld = 0
            var expectedFgDropped = 0
            var expectedFgHeld = 0
            for (i in 0 until OUTPUT_FRAME_COUNT) {
                val ptsUs = AndroidGreenScreenExportEngine.outputPtsUs(i, OUTPUT_FPS)
                expectedBgIndex[i] = expectedSourceIndex(ptsUs, BACKGROUND_FRAME_DURATION_US, BACKGROUND_COLORS.size)
                expectedFgIndex[i] = expectedSourceIndex(ptsUs, FOREGROUND_FRAME_DURATION_US, FOREGROUND_COLORS.size)
                expectedShowsForeground[i] = i % 2 == 1
                expectedColors[i] = if (expectedShowsForeground[i]) {
                    FOREGROUND_COLORS[expectedFgIndex[i]]
                } else {
                    BACKGROUND_COLORS[expectedBgIndex[i]]
                }
                if (i > 0) {
                    if (expectedBgIndex[i] == expectedBgIndex[i - 1]) expectedBgHeld++
                    else expectedBgDropped += expectedBgIndex[i] - expectedBgIndex[i - 1] - 1
                    if (expectedFgIndex[i] == expectedFgIndex[i - 1]) expectedFgHeld++
                    else expectedFgDropped += expectedFgIndex[i] - expectedFgIndex[i - 1] - 1
                }
            }

            val maskProvider = AndroidGreenScreenExportEngine.MaskProvider { frameIndex, _ ->
                buildMaskFrame(if (frameIndex % 2 == 1) 255 else 0)
            }
            val request = AndroidGreenScreenExportEngine.Request(
                backgroundVideoPath = bgFixturePath,
                foregroundVideoPath = fgFixturePath,
                outputPath = outputPath,
                width = width,
                height = height,
                fps = OUTPUT_FPS,
                bitrate = bitrate,
                outputFrameCount = OUTPUT_FRAME_COUNT,
                maskProvider = maskProvider,
                cancelFlag = AtomicBoolean(false),
            )
            val result = AndroidGreenScreenExportEngine.export(request)
            engineResult = result

            val outputFile = File(outputPath)
            val tmpFile = File("$outputPath.tmp")
            val engineOk = result.pass && result.terminalState == AndroidGreenScreenExportEngine.TerminalState.SUCCESS
            val countsOk = result.renderedFrames == OUTPUT_FRAME_COUNT &&
                result.writtenVideoSamples == OUTPUT_FRAME_COUNT &&
                result.renderedEqualsWritten
            val outputOk = outputFile.exists() && outputFile.length() > 0L
            val tmpOk = !tmpFile.exists() && !result.tmpExists
            val bgDroppedOk = result.background.droppedFrames > 0
            val fgHeldOk = result.foreground.heldFrames > 0
            val pairingCountsMatchExpected =
                result.background.droppedFrames == expectedBgDropped &&
                    result.background.heldFrames == expectedBgHeld &&
                    result.foreground.droppedFrames == expectedFgDropped &&
                    result.foreground.heldFrames == expectedFgHeld

            val decodeOk = if (engineOk && outputOk) {
                decodeAndAssertCenterPixels(outputPath, expectedColors, expectedShowsForeground, expectedBgIndex, expectedFgIndex, perFramePixelResults)
            } else {
                false
            }

            val isPass = engineOk && countsOk && outputOk && tmpOk && bgDroppedOk && fgHeldOk && decodeOk
            val reason = when {
                isPass -> "pass"
                !engineOk -> "engine_failed:${result.terminalState.name.lowercase()}:${result.reason}"
                !countsOk -> "sample_count_mismatch;rendered=${result.renderedFrames};written=${result.writtenVideoSamples};expected=$OUTPUT_FRAME_COUNT"
                !outputOk -> "output_missing_or_empty"
                !tmpOk -> "tmp_leftover"
                !bgDroppedOk -> "background_dropped_frames_not_observed"
                !fgHeldOk -> "foreground_held_frames_not_observed"
                !decodeOk -> "decoded_pixel_assertion_failed"
                else -> "unknown_failure"
            }
            if (!isPass) cleanupOutputArtifacts(outputPath)

            return buildMap {
                putAll(result.toMap())
                put("pass", isPass)
                put("reason", reason)
                put("engineReason", result.reason)
                put("proofBoundary", PROOF_BOUNDARY)
                put("width", width)
                put("height", height)
                put("outputFps", OUTPUT_FPS)
                put("backgroundFixtureFrames", BACKGROUND_COLORS.size)
                put("backgroundFixtureFrameDurationUs", BACKGROUND_FRAME_DURATION_US)
                put("foregroundFixtureFrames", FOREGROUND_COLORS.size)
                put("foregroundFixtureFrameDurationUs", FOREGROUND_FRAME_DURATION_US)
                put("expectedBackgroundIndexLadder", expectedBgIndex.toList())
                put("expectedForegroundIndexLadder", expectedFgIndex.toList())
                put("expectedBackgroundDroppedFrames", expectedBgDropped)
                put("expectedBackgroundHeldFrames", expectedBgHeld)
                put("expectedForegroundDroppedFrames", expectedFgDropped)
                put("expectedForegroundHeldFrames", expectedFgHeld)
                put("pairingCountsMatchExpected", pairingCountsMatchExpected)
                put("perFramePixelResults", perFramePixelResults)
                put("pixelToleranceExpected", PIXEL_TOLERANCE)
                put("claims", result.claims + harnessClaims(isPass))
                put("nonClaims", result.nonClaims + listOf("no_exact_pairing_count_gate", "no_rect_rotation_mirror_coverage"))
            }
        } catch (t: Throwable) {
            Log.e(TAG, "AndroidGreenScreenProductionExportSmokeHarness uncaught exception", t)
            cleanupOutputArtifacts(outputPath)
            return failResult(
                "exception:${t.javaClass.simpleName}:${t.message}",
                outputPath, width, height, engineResult, perFramePixelResults,
            )
        } finally {
            deleteQuietly(File(bgFixturePath))
            deleteQuietly(File(fgFixturePath))
        }
    }

    /** Newest fixture frame index whose nominal pts (index * duration) is <= outputPtsUs, held at the last index after EOS. */
    private fun expectedSourceIndex(outputPtsUs: Long, frameDurationUs: Long, frameCount: Int): Int {
        var idx = 0
        while (idx + 1 < frameCount && (idx + 1) * frameDurationUs <= outputPtsUs) idx++
        return idx
    }

    private fun harnessClaims(isPass: Boolean): List<String> = buildList {
        add("unequal_input_timing_fixtures")
        if (isPass) {
            add("background_faster_than_output_drop_observed")
            add("foreground_slower_and_shorter_hold_observed")
            add("deterministic_decoded_pixel_mp4_proof")
        }
    }

    private fun decodeAndAssertCenterPixels(
        path: String,
        expectedColors: IntArray,
        expectedShowsForeground: BooleanArray,
        expectedBgIndex: IntArray,
        expectedFgIndex: IntArray,
        results: MutableList<Map<String, Any?>>,
    ): Boolean {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            for (i in 0 until OUTPUT_FRAME_COUNT) {
                val timeUs = AndroidGreenScreenExportEngine.outputPtsUs(i, OUTPUT_FPS) + OUTPUT_FRAME_DURATION_US / 4
                val bitmap = try {
                    retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                } catch (_: Throwable) {
                    null
                }
                if (bitmap == null) {
                    results.add(mapOf("frameIndex" to i, "pass" to false, "reason" to "decode_failed"))
                    continue
                }
                val cx = (bitmap.width / 2).coerceIn(0, bitmap.width - 1)
                val cy = (bitmap.height / 2).coerceIn(0, bitmap.height - 1)
                val pixel = bitmap.getPixel(cx, cy)
                bitmap.recycle()
                val actual = intArrayOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel))
                val expectedColor = expectedColors[i]
                val expected = intArrayOf(Color.red(expectedColor), Color.green(expectedColor), Color.blue(expectedColor))
                val diffs = IntArray(3) { c -> abs(actual[c] - expected[c]) }
                val framePass = diffs.all { it <= PIXEL_TOLERANCE }
                results.add(
                    mapOf(
                        "frameIndex" to i,
                        "pass" to framePass,
                        "expectedShowsForeground" to expectedShowsForeground[i],
                        "expectedBackgroundIndex" to expectedBgIndex[i],
                        "expectedForegroundIndex" to expectedFgIndex[i],
                        "expectedRgb" to expected.toList(),
                        "actualRgb" to actual.toList(),
                        "diffs" to diffs.toList(),
                    ),
                )
            }
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
        return results.size == OUTPUT_FRAME_COUNT && results.all { it["pass"] == true }
    }

    private fun buildMaskFrame(alpha: Int): AndroidGreenScreenExportEngine.MaskFrame.CpuR8 {
        val buf = ByteBuffer.allocateDirect(MASK_WIDTH * MASK_HEIGHT)
        val byteVal = (alpha and 0xFF).toByte()
        for (i in 0 until MASK_WIDTH * MASK_HEIGHT) buf.put(i, byteVal)
        buf.position(0)
        return AndroidGreenScreenExportEngine.MaskFrame.CpuR8(buf, MASK_WIDTH, MASK_HEIGHT, 0)
    }

    private fun cleanupOutputArtifacts(outputPath: String) {
        deleteQuietly(File(outputPath))
        deleteQuietly(File("$outputPath.tmp"))
    }

    private fun deleteQuietly(file: File) {
        try { if (file.exists()) file.delete() } catch (_: Throwable) {}
    }

    /**
     * Writes one AVC/MP4 whose frame k is solid `colors[k]` at pts k * frameDurationUs
     * (the muxer pts is overwritten from the frame index so fixture timing is exact).
     */
    private fun generateSolidColorFixtureVideo(
        outputPath: String,
        width: Int,
        height: Int,
        colors: IntArray,
        frameDurationUs: Long,
        bitrate: Int,
    ): String? {
        val fps = (1_000_000L / frameDurationUs).toInt().coerceAtLeast(1)
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

            for (frameIdx in colors.indices) {
                val canvas = try {
                    encoderSurface.lockHardwareCanvas()
                } catch (_: Throwable) {
                    encoderSurface.lockCanvas(null)
                }
                canvas.drawColor(colors[frameIdx])
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
            val success = muxerStoppedCleanly && file.exists() && file.length() > 0L && writtenVideoSamples == colors.size
            return if (success) null else "fixture_generation_incomplete;samples=$writtenVideoSamples;expected=${colors.size}"
        } catch (t: Throwable) {
            Log.e(TAG, "generateSolidColorFixtureVideo failed", t)
            return "fixture_generation_exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            try { encoderSurface?.release() } catch (_: Throwable) {}
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
        }
    }

    private fun failResult(
        reason: String,
        outputPath: String,
        width: Int,
        height: Int,
        engineResult: AndroidGreenScreenExportEngine.Result?,
        perFramePixelResults: List<Map<String, Any?>>,
    ): Map<String, Any?> = buildMap {
        if (engineResult != null) putAll(engineResult.toMap())
        put("pass", false)
        put("reason", reason)
        put("engineReason", engineResult?.reason)
        put("proofBoundary", PROOF_BOUNDARY)
        put("outputPath", outputPath)
        put("outputSize", 0L)
        put("outputExists", File(outputPath).exists())
        put("tmpExists", File("$outputPath.tmp").exists())
        put("width", width)
        put("height", height)
        put("outputFps", OUTPUT_FPS)
        put("outputFrameCount", OUTPUT_FRAME_COUNT)
        put("renderedFrames", engineResult?.renderedFrames ?: 0)
        put("writtenVideoSamples", engineResult?.writtenVideoSamples ?: 0)
        put("renderedEqualsWritten", engineResult?.renderedEqualsWritten ?: false)
        put("perFramePixelResults", perFramePixelResults)
        put("pixelToleranceExpected", PIXEL_TOLERANCE)
        put("claims", emptyList<String>())
        put("nonClaims", emptyList<String>())
    }
}
