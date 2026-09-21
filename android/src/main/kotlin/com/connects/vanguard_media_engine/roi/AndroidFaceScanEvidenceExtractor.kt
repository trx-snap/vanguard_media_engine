package com.connects.vanguard_media_engine.roi

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.RectF
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.ImageProcessingOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facedetector.FaceDetector
import com.google.mediapipe.tasks.vision.facedetector.FaceDetector.FaceDetectorOptions
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * AndroidFaceScanEvidenceExtractor
 *
 * Extracts display-oriented keyframe evidence from a video source (POSIX or content:// URI)
 * using Google MediaPipe Tasks Vision FaceDetector (blaze_face_short_range.tflite).
 *
 * High-Performance Pipeline:
 * - Persistent warm FaceDetector singleton on background daemon thread (zero graph re-parsing).
 * - Hardware scaled keyframe decode (getScaledFrameAtTime) targeting 256px base dimension
 *   (18x smaller memory footprint than 1080p, sub-25ms decode on modern hardware).
 * - Fast-path: 0° upright probe accepts immediately when confidence >= 0.75 (~8 ms inference).
 * - Otherwise probes 90°, 180°, 270° via zero-copy MediaPipe ImageProcessingOptions.
 * - Remaps output bounding boxes back to display coordinates and clamps to [0.0, 1.0].
 */
object AndroidFaceScanEvidenceExtractor {

    private const val TAG = "FaceScanExtractor"
    private const val MODEL_ASSET_PATH = "blaze_face_short_range.tflite"
    private const val CONFIDENCE_FAST_ACCEPT = 0.75f
    private const val MIN_DETECTION_CONFIDENCE = 0.50f
    private const val BASE_TARGET_DIMENSION = 256

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "VG-FaceScanExtractor").apply { isDaemon = true }
    }

    @Volatile
    private var cachedDetector: FaceDetector? = null

    private fun getOrCreateDetector(context: Context): FaceDetector {
        val existing = cachedDetector
        if (existing != null) return existing
        return synchronized(this) {
            cachedDetector ?: run {
                val baseOptions = BaseOptions.builder()
                    .setModelAssetPath(MODEL_ASSET_PATH)
                    .setDelegate(Delegate.CPU)
                    .build()

                val options = FaceDetectorOptions.builder()
                    .setBaseOptions(baseOptions)
                    .setRunningMode(RunningMode.IMAGE)
                    .setMinDetectionConfidence(MIN_DETECTION_CONFIDENCE)
                    .build()

                FaceDetector.createFromOptions(context, options).also {
                    cachedDetector = it
                    Log.d(TAG, "Initialized persistent warm FaceDetector")
                }
            }
        }
    }

    fun release() {
        synchronized(this) {
            try {
                cachedDetector?.close()
                Log.d(TAG, "Released cached FaceDetector")
            } catch (t: Throwable) {
                Log.w(TAG, "Error closing cached FaceDetector: ${t.message}")
            }
            cachedDetector = null
        }
    }

    private data class RemappedBox(
        val visionX: Double,
        val visionY: Double,
        val visionWidth: Double,
        val visionHeight: Double,
        val wasClamped: Boolean,
    )

    private data class ProbeResult(
        val angle: Int,
        val maxScore: Float,
        val detections: List<com.google.mediapipe.tasks.components.containers.Detection>,
        val frameWidth: Int,
        val frameHeight: Int,
        val sampleTimeUs: Long,
    )

    fun extract(
        context: Context?,
        videoPath: String,
        mainHandler: Handler,
        result: MethodChannel.Result,
    ) {
        executor.execute {
            var retriever: MediaMetadataRetriever? = null

            try {
                if (context == null) {
                    mainHandler.post {
                        result.error(
                            "CONTEXT_NULL",
                            "extractImportedFaceScanEvidence: Context is null",
                            null,
                        )
                    }
                    return@execute
                }

                retriever = MediaMetadataRetriever()
                AndroidUriDataSourceHelper.setRetrieverDataSource(retriever, videoPath, context)

                val hasVideo = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO,
                )

                val metaW = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
                )?.toIntOrNull() ?: 0

                val metaH = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
                )?.toIntOrNull() ?: 0

                // Early exit for audio-only or non-video assets:
                // If hasVideo is explicitly not "yes", or if video dimensions are 0x0,
                // return an empty face response without decoding or model execution.
                if ((hasVideo != null && hasVideo != "yes") || (metaW <= 0 && metaH <= 0)) {
                    val emptyResponse = mapOf(
                        "frameWidth" to 0,
                        "frameHeight" to 0,
                        "method" to "MediaPipeTasksVisionFaceDetector",
                        "frameExtractionMethod" to "MediaMetadataRetriever",
                        "visionOrientation" to "up",
                        "coordinateSpace" to "displayTopLeftNormalizedAndPixels",
                        "probeOrientationDegrees" to 0,
                        "faceCount" to 0,
                        "faces" to emptyList<Map<String, Any>>(),
                        "requestedTimeSeconds" to 0.0,
                        "actualTimeSeconds" to 0.0,
                    )
                    mainHandler.post {
                        result.success(emptyResponse)
                    }
                    return@execute
                }

                // Read video metadata
                val durationMs = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION,
                )?.toLongOrNull() ?: 0L

                val candidateTimestampsUs = mutableListOf<Long>(0L)
                if (durationMs >= 1500L) {
                    candidateTimestampsUs.add(1_000_000L)
                }
                if (durationMs >= 2500L) {
                    candidateTimestampsUs.add(2_000_000L)
                }

                val rotationDeg = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
                )?.toIntOrNull() ?: 0

                val displayW = if (rotationDeg == 90 || rotationDeg == 270) metaH else metaW
                val displayH = if (rotationDeg == 90 || rotationDeg == 270) metaW else metaH

                // Warm/cached MediaPipe FaceDetector instance
                val detector = getOrCreateDetector(context)

                var bestProbe: ProbeResult? = null
                var fallbackWidth = 0
                var fallbackHeight = 0

                for (timeUs in candidateTimestampsUs) {
                    var rawBitmap: Bitmap? = null
                    var uprightBitmap: Bitmap? = null
                    var mpImage: MPImage? = null

                    try {
                        val startDecode = SystemClock.elapsedRealtimeNanos()

                        // Optimization B: hardware scaled decode preserving aspect ratio with 256px base
                        rawBitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1 && metaW > 0 && metaH > 0) {
                            val scale = BASE_TARGET_DIMENSION.toDouble() / minOf(metaW, metaH).toDouble()
                            val targetW = ((metaW * scale).toInt() / 2) * 2
                            val targetH = ((metaH * scale).toInt() / 2) * 2
                            try {
                                retriever.getScaledFrameAtTime(
                                    timeUs,
                                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                                    targetW,
                                    targetH,
                                ) ?: retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                            } catch (_: Throwable) {
                                retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                            }
                        } else {
                            retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                        }

                        if (rawBitmap == null) {
                            continue
                        }

                        val decodeMs = (SystemClock.elapsedRealtimeNanos() - startDecode) / 1_000_000.0
                        Log.d(TAG, "Frame decode (${rawBitmap.width}x${rawBitmap.height}) latency: ${String.format("%.2f", decodeMs)} ms")

                        val rawW = rawBitmap.width
                        val rawH = rawBitmap.height

                        // MediaMetadataRetriever on modern Android (API 27+) typically auto-rotates
                        // frames to display orientation. If rawW > rawH but rotation is 90° or 270°,
                        // the platform decoder did not rotate it, so apply Matrix rotation explicitly.
                        val needsManualRotation = (rotationDeg == 90 || rotationDeg == 270) && rawW > rawH
                        val finalBitmap = if (needsManualRotation) {
                            val matrix = Matrix().apply { postRotate(rotationDeg.toFloat()) }
                            Bitmap.createBitmap(rawBitmap, 0, 0, rawW, rawH, matrix, true).also {
                                uprightBitmap = it
                            }
                        } else {
                            rawBitmap
                        }

                        val frameW = finalBitmap.width
                        val frameH = finalBitmap.height
                        fallbackWidth = frameW
                        fallbackHeight = frameH

                        mpImage = BitmapImageBuilder(finalBitmap).build()

                        // Fast-path: probe 0° first with timing
                        val startProbe0 = SystemClock.elapsedRealtimeNanos()
                        val probe0Options = ImageProcessingOptions.builder()
                            .setRotationDegrees(0)
                            .build()
                        val result0 = detector.detect(mpImage, probe0Options)
                        val probe0LatencyMs = (SystemClock.elapsedRealtimeNanos() - startProbe0) / 1_000_000.0
                        val detections0 = result0.detections()
                        val maxScore0 = detections0.maxOfOrNull {
                            it.categories().firstOrNull()?.score() ?: 0f
                        } ?: 0f

                        Log.d(TAG, "Probe 0° latency: ${String.format("%.2f", probe0LatencyMs)} ms, detections: ${detections0.size}, maxScore: $maxScore0")

                        if (maxScore0 >= CONFIDENCE_FAST_ACCEPT) {
                            bestProbe = ProbeResult(
                                angle = 0,
                                maxScore = maxScore0,
                                detections = detections0,
                                frameWidth = frameW,
                                frameHeight = frameH,
                                sampleTimeUs = timeUs,
                            )
                            break // High-confidence face locked at 0°!
                        }

                        // Otherwise, probe remaining cardinal angles (90°, 180°, 270°)
                        var currentBestAngle = 0
                        var currentBestScore = maxScore0
                        var currentBestDetections = detections0

                        for (angle in intArrayOf(90, 180, 270)) {
                            val startProbe = SystemClock.elapsedRealtimeNanos()
                            val probeOptions = ImageProcessingOptions.builder()
                                .setRotationDegrees(angle)
                                .build()
                            val probeResult = detector.detect(mpImage, probeOptions)
                            val probeLatencyMs = (SystemClock.elapsedRealtimeNanos() - startProbe) / 1_000_000.0
                            val probeDetections = probeResult.detections()
                            val probeScore = probeDetections.maxOfOrNull {
                                it.categories().firstOrNull()?.score() ?: 0f
                            } ?: 0f

                            Log.d(TAG, "Probe $angle° latency: ${String.format("%.2f", probeLatencyMs)} ms, detections: ${probeDetections.size}, maxScore: $probeScore")

                            if (probeScore > currentBestScore) {
                                currentBestScore = probeScore
                                currentBestAngle = angle
                                currentBestDetections = probeDetections
                            }
                        }

                        if (bestProbe == null || currentBestScore > bestProbe.maxScore) {
                            bestProbe = ProbeResult(
                                angle = currentBestAngle,
                                maxScore = currentBestScore,
                                detections = currentBestDetections,
                                frameWidth = frameW,
                                frameHeight = frameH,
                                sampleTimeUs = timeUs,
                            )
                        }

                        // If we achieved confident detection at any angle, lock it in
                        if (currentBestScore >= CONFIDENCE_FAST_ACCEPT) {
                            break
                        }
                    } finally {
                        try { mpImage?.close() } catch (_: Throwable) {}
                        try { uprightBitmap?.recycle() } catch (_: Throwable) {}
                        try { rawBitmap?.recycle() } catch (_: Throwable) {}
                    }
                }

                val finalProbe = bestProbe
                val finalDisplayW = if (displayW > 0) displayW else (finalProbe?.frameWidth ?: fallbackWidth)
                val finalDisplayH = if (displayH > 0) displayH else (finalProbe?.frameHeight ?: fallbackHeight)
                val finalInternalW = finalProbe?.frameWidth ?: fallbackWidth
                val finalInternalH = finalProbe?.frameHeight ?: fallbackHeight
                val finalAngle = finalProbe?.angle ?: 0
                val finalSampleTimeUs = finalProbe?.sampleTimeUs ?: 0L

                val faceMaps = mutableListOf<Map<String, Any>>()

                if (finalProbe != null && finalProbe.maxScore >= MIN_DETECTION_CONFIDENCE) {
                    for ((idx, detection) in finalProbe.detections.withIndex()) {
                        val remapped = remapCoordinates(
                            box = detection.boundingBox(),
                            rotationDeg = finalAngle,
                            frameW = finalInternalW,
                            frameH = finalInternalH,
                        )

                        val confidence = detection.categories().firstOrNull()?.score()?.toDouble() ?: 1.0

                        faceMaps.add(
                            mapOf(
                                "index" to idx,
                                "visionX" to remapped.visionX,
                                "visionY" to remapped.visionY,
                                "visionWidth" to remapped.visionWidth,
                                "visionHeight" to remapped.visionHeight,
                                "normalizedX" to remapped.visionX,
                                "normalizedY" to remapped.visionY,
                                "normalizedWidth" to remapped.visionWidth,
                                "normalizedHeight" to remapped.visionHeight,
                                "pixelX" to remapped.visionX * finalDisplayW,
                                "pixelY" to remapped.visionY * finalDisplayH,
                                "pixelWidth" to remapped.visionWidth * finalDisplayW,
                                "pixelHeight" to remapped.visionHeight * finalDisplayH,
                                "clamped" to remapped.wasClamped,
                                "confidence" to confidence,
                            )
                        )
                    }
                }

                val responseMap = mapOf(
                    "frameWidth" to finalDisplayW,
                    "frameHeight" to finalDisplayH,
                    "method" to "MediaPipeTasksVisionFaceDetector",
                    "frameExtractionMethod" to "MediaMetadataRetriever",
                    "visionOrientation" to "up",
                    "coordinateSpace" to "displayTopLeftNormalizedAndPixels",
                    "probeOrientationDegrees" to finalAngle,
                    "faceCount" to faceMaps.size,
                    "faces" to faceMaps,
                    "requestedTimeSeconds" to finalSampleTimeUs / 1_000_000.0,
                    "actualTimeSeconds" to finalSampleTimeUs / 1_000_000.0,
                )

                mainHandler.post {
                    result.success(responseMap)
                }
            } catch (e: Exception) {
                Log.e(TAG, "extractImportedFaceScanEvidence failed: $e", e)
                mainHandler.post {
                    result.error(
                        "FACE_SCAN_FAILED",
                        "extractImportedFaceScanEvidence error: ${e.message}",
                        null,
                    )
                }
            } finally {
                try { retriever?.release() } catch (_: Throwable) {}
            }
        }
    }

    /**
     * Remaps normalized coordinates from the rotated inference space back to
     * the original unrotated display frame buffer coordinates.
     *
     * Transformation table:
     * - 0°:      x' = x, y' = y
     * - 90° CW:  x' = y, y' = 1 - (x + width)
     * - 180°:    x' = 1 - (x + width), y' = 1 - (y + height)
     * - 270° CW: x' = 1 - (y + height), y' = x
     */
    private fun remapCoordinates(
        box: RectF,
        rotationDeg: Int,
        frameW: Int,
        frameH: Int,
    ): RemappedBox {
        val normX: Double
        val normY: Double
        val normW: Double
        val normH: Double

        when (rotationDeg) {
            90 -> {
                // Rotated buffer dimensions: width = frameH, height = frameW
                val rx = box.left.toDouble() / frameH.toDouble()
                val ry = box.top.toDouble() / frameW.toDouble()
                val rw = box.width().toDouble() / frameH.toDouble()
                val rh = box.height().toDouble() / frameW.toDouble()

                // 90° CW: x' = y, y' = 1 - (x + width)
                normX = ry
                normY = 1.0 - (rx + rw)
                normW = rh
                normH = rw
            }
            180 -> {
                // Rotated buffer dimensions: width = frameW, height = frameH
                val rx = box.left.toDouble() / frameW.toDouble()
                val ry = box.top.toDouble() / frameH.toDouble()
                val rw = box.width().toDouble() / frameW.toDouble()
                val rh = box.height().toDouble() / frameH.toDouble()

                // 180°: x' = 1 - (x + width), y' = 1 - (y + height)
                normX = 1.0 - (rx + rw)
                normY = 1.0 - (ry + rh)
                normW = rw
                normH = rh
            }
            270 -> {
                // Rotated buffer dimensions: width = frameH, height = frameW
                val rx = box.left.toDouble() / frameH.toDouble()
                val ry = box.top.toDouble() / frameW.toDouble()
                val rw = box.width().toDouble() / frameH.toDouble()
                val rh = box.height().toDouble() / frameW.toDouble()

                // 270° CW: x' = 1 - (y + height), y' = x
                normX = 1.0 - (ry + rh)
                normY = rx
                normW = rh
                normH = rw
            }
            else -> { // 0°
                // Rotated buffer dimensions: width = frameW, height = frameH
                normX = box.left.toDouble() / frameW.toDouble()
                normY = box.top.toDouble() / frameH.toDouble()
                normW = box.width().toDouble() / frameW.toDouble()
                normH = box.height().toDouble() / frameH.toDouble()
            }
        }

        val clampedX = normX.coerceIn(0.0, 1.0)
        val clampedY = normY.coerceIn(0.0, 1.0)
        val clampedW = normW.coerceIn(0.0, 1.0 - clampedX)
        val clampedH = normH.coerceIn(0.0, 1.0 - clampedY)
        val wasClamped = (clampedX != normX || clampedY != normY ||
                clampedW != normW || clampedH != normH)

        return RemappedBox(
            visionX = clampedX,
            visionY = clampedY,
            visionWidth = clampedW,
            visionHeight = clampedH,
            wasClamped = wasClamped,
        )
    }
}

