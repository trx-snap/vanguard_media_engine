package com.connects.vanguard_media_engine

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.NonNull
import com.connects.vanguard_media_engine.diagnostics.AndroidDagRenderSmokeHarness
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

class VanguardMediaEnginePlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding

    // ── Video editor renderers (existing, keyed by textureId) ─────────────────
    private val renderers = mutableMapOf<Long, VanguardGLRenderer>()

    // ── Camera session state (B2: single camera instance invariant) ───────────
    // Mirrors iOS plugin: cameraSource + renderer stored at plugin level.
    // Exactly one VanguardCameraSource may exist at a time.
    private var cameraSource: VanguardCameraSource? = null
    private var cameraTexture: TextureRegistry.SurfaceTextureEntry? = null

    // ── Image texture loaders (B3: keyed by textureId) ────────────────────────
    private val imageLoaders = mutableMapOf<Long, VanguardImageTextureLoader>()

    // ── Main thread handler (B3: for posting background-thread results) ─────────
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── B4-S5: active export encoder — plugin-level ref for cancelExport ─────────
    // Cleared in encoder.finish{} callback and on cancelExport.
    @Volatile private var activeEncoder: VanguardMediaCodecEncoder? = null

    companion object {
        private const val TAG = "VanguardPlugin"
    }

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        this.context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "vanguard_media_engine")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        val args = call.arguments as? Map<*, *>

        when (call.method) {

            "runAndroidDagPhase2O2B3PhysicalSmoke" -> {
                val width = (args?.get("width") as? Number)?.toInt() ?: 64
                val height = (args?.get("height") as? Number)?.toInt() ?: 64
                Thread {
                    val smokeResult = AndroidDagRenderSmokeHarness.run(width, height)
                    mainHandler.post { result.success(smokeResult) }
                }.start()
            }

            "runAndroidDagPhase2O2B4MultiFrameSmoke" -> {
                val width = (args?.get("width") as? Number)?.toInt() ?: 64
                val height = (args?.get("height") as? Number)?.toInt() ?: 64
                val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 30
                Thread {
                    val smokeResult = AndroidDagRenderSmokeHarness.runMultiFrame(width, height, frameCount)
                    mainHandler.post { result.success(smokeResult) }
                }.start()
            }

            "runAndroidDagPhase2QCapabilityProbe" -> {
                Thread {
                    val probeResult = AndroidDagRenderSmokeHarness.runCapabilityProbe()
                    mainHandler.post { result.success(probeResult) }
                }.start()
            }

            "runAndroidDagPhase3CEvalRenderSmoke" -> {
                val width          = (args?.get("width")          as? Number)?.toInt()  ?: 64
                val height         = (args?.get("height")         as? Number)?.toInt()  ?: 64
                val frameCount     = (args?.get("frameCount")     as? Number)?.toInt()  ?: 30
                val frameDurationUs = (args?.get("frameDurationUs") as? Number)?.toLong() ?: 33333L
                Thread {
                    val smokeResult = AndroidDagRenderSmokeHarness.runDagEvaluationSmoke(
                        width, height, frameCount, frameDurationUs,
                    )
                    mainHandler.post { result.success(smokeResult) }
                }.start()
            }

            "createTexture" -> {
                val path = args?.get("path") as? String
                    ?: return result.error("INVALID_ARG", "path required", null)

                val renderer = VanguardGLRenderer(
                    context         = context,
                    videoPath       = path,
                    textureRegistry = binding.textureRegistry,
                    methodChannel   = channel
                )
                renderers[renderer.textureId] = renderer
                result.success(renderer.textureId)
            }

            "play" -> {
                val textureId = (args?.get("textureId") as? Number)?.toLong() ?: return
                renderers[textureId]?.play()
                result.success(null)
            }

            "pause" -> {
                val textureId = (args?.get("textureId") as? Number)?.toLong() ?: return
                renderers[textureId]?.pause()
                result.success(null)
            }

            "seekTo" -> {
                // Phase 3: seekTo hook — MediaExtractor seekTo implementation
                // will be wired in Phase 4 alongside scrubber UI
                result.success(null)
            }

            "dispose" -> {
                val textureId = (args?.get("textureId") as? Number)?.toLong() ?: return
                // B3: dispose covers both GL video renderers and image texture loaders.
                renderers[textureId]?.dispose()
                renderers.remove(textureId)
                imageLoaders[textureId]?.dispose()
                imageLoaders.remove(textureId)
                result.success(null)
            }

            // ─── B3: Media fundamentals ─────────────────────────────────────────────────

            "probeVideoDuration" -> {
                // Mirrors iOS: AVURLAsset.duration — returns seconds as Double, -1.0 on failure.
                // Off main thread: setDataSource can block on I/O.
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "probeVideoDuration: path required", null)
                    return
                }
                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(path)
                        val ms = retriever
                            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                            ?.toLongOrNull() ?: -1L
                        val seconds = if (ms >= 0L) ms / 1000.0 else -1.0
                        mainHandler.post { result.success(seconds) }
                    } catch (e: Exception) {
                        Log.e(TAG, "probeVideoDuration: $e")
                        mainHandler.post { result.success(-1.0) } // matches iOS null→null contract
                    } finally {
                        try { retriever.release() } catch (_: Exception) {}
                    }
                }.start()
            }

            // ─── Phase-1 metadata: probeVideoInfo (returns duration + dimensions) ────────
            "probeVideoInfo" -> {
                // Returns {duration: Double, width: Int, height: Int} for a video file.
                // Used by story_export_service to replace FFmpegKit metadata probes.
                // Android: MediaMetadataRetriever (same retriever used by probeVideoDuration).
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "probeVideoInfo: path required", null)
                    return
                }
                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(path)
                        val ms      = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: -1L
                        val wStr    = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                        val hStr    = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                        val seconds = if (ms >= 0L) ms / 1000.0 else -1.0
                        val w       = wStr?.toIntOrNull() ?: 0
                        val h       = hStr?.toIntOrNull() ?: 0
                        mainHandler.post {
                            result.success(mapOf("duration" to seconds, "width" to w, "height" to h))
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "probeVideoInfo: $e")
                        mainHandler.post {
                            result.success(mapOf("duration" to -1.0, "width" to 0, "height" to 0))
                        }
                    } finally {
                        try { retriever.release() } catch (_: Exception) {}
                    }
                }.start()
            }

            // ── inspectMedia ──────────────────────────────────────────────────────────
            // Extended media probe (superset of probeVideoInfo). Returns full MediaInfo
            // map needed by VanguardMediaPreparer decision logic.
            // probeVideoInfo is kept unchanged — do not remove it.
            "inspectMedia" -> {
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "inspectMedia: path required", null)
                    return
                }
                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(path)

                        // Duration
                        val ms      = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: -1L
                        val seconds = if (ms >= 0L) ms / 1000.0 else -1.0

                        // Dimensions
                        val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                        val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0

                        // Bitrate (container-level; acceptable for decision logic)
                        val bitrateRaw = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull() ?: 0L
                        val bitrateKbps = (bitrateRaw / 1000L).toInt()

                        // FPS
                        val fpsStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
                        val fps = fpsStr?.toDoubleOrNull() ?: 0.0

                        // Track presence
                        val hasVideo = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
                        val hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"

                        // Rotation (non-zero means rotation metadata is present as transform, not baked)
                        val rotationStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                        val hasRotationTransform = (rotationStr?.toIntOrNull() ?: 0) != 0

                        // ROI-5A.1 — Orientation evidence from integer rotation metadata.
                        // Android MediaMetadataRetriever returns rotation as 0/90/180/270 or null.
                        // Mirroring is not exposed via this API; validMirrored is iOS-only.
                        val rotationDeg = rotationStr?.toIntOrNull()
                        val isCardinal = rotationDeg != null &&
                            (rotationDeg == 0 || rotationDeg == 90 || rotationDeg == 180 || rotationDeg == 270)

                        val hasVideoTrack = w > 0 && h > 0
                        val orientationStatus = when {
                            !hasVideoTrack -> "noVideoTrack"
                            isCardinal     -> "valid"
                            else           -> "ambiguous"
                        }

                        // Display dimensions: swap for 90°/270°.
                        val displayW: Int
                        val displayH: Int
                        if (hasVideoTrack && isCardinal &&
                            (rotationDeg == 90 || rotationDeg == 270)) {
                            displayW = h
                            displayH = w
                        } else {
                            displayW = w
                            displayH = h
                        }

                        // Synthesize matrix values from integer rotation for cross-platform parity.
                        // Camera-produced clips are 0° (identity); gallery clips may differ.
                        val tA: Double; val tB: Double; val tC: Double; val tD: Double
                        when (if (isCardinal) rotationDeg else 0) {
                            90  -> { tA =  0.0; tB =  1.0; tC = -1.0; tD =  0.0 }
                            180 -> { tA = -1.0; tB =  0.0; tC =  0.0; tD = -1.0 }
                            270 -> { tA =  0.0; tB = -1.0; tC =  1.0; tD =  0.0 }
                            else -> { tA =  1.0; tB =  0.0; tC =  0.0; tD =  1.0 }
                        }


                        // Embedded GPS metadata
                        val location = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)
                        val hasEmbeddedMetadata = location != null

                        // Codec — derive from MIME type (most reliable approach on Android)
                        // METADATA_KEY_MIMETYPE returns container MIME e.g. "video/mp4".
                        // We need to use MediaExtractor to get per-track codec MIME.
                        // For the decision policy, we only need to distinguish h264 / hevc / other.
                        val mimeType = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE) ?: ""
                        // Use MediaExtractor for accurate per-track codec detection
                        var videoCodec = ""
                        var audioCodec = ""
                        try {
                            val extractor = android.media.MediaExtractor()
                            extractor.setDataSource(path)
                            for (i in 0 until extractor.trackCount) {
                                val fmt  = extractor.getTrackFormat(i)
                                val mime = fmt.getString(android.media.MediaFormat.KEY_MIME) ?: ""
                                when {
                                    mime.startsWith("video/") && videoCodec.isEmpty() -> {
                                        videoCodec = when (mime) {
                                            "video/avc",    // H.264 / AVC
                                            "video/AVE"     -> "h264"
                                            "video/hevc"    -> "hevc"
                                            "video/x-vnd.on2.vp9",
                                            "video/vp9"     -> "vp9"
                                            "video/av01"    -> "av1"
                                            "video/mp4v-es" -> "mpeg4"
                                            else            -> mime
                                        }
                                    }
                                    mime.startsWith("audio/") && audioCodec.isEmpty() -> {
                                        audioCodec = when (mime) {
                                            "audio/mp4a-latm" -> "aac"
                                            "audio/ac3"       -> "ac3"
                                            "audio/eac3"      -> "ac3"
                                            "audio/mpeg"      -> "mp3"
                                            "audio/opus"      -> "opus"
                                            "audio/raw"       -> "pcm"
                                            else              -> mime
                                        }
                                    }
                                }
                            }
                            extractor.release()
                        } catch (_: Exception) {
                            // MediaExtractor codec detection failed — fall back to container MIME
                            // "unknown" audioCodec treated as safe (aac assumed) in Dart policy
                        }

                        // File size
                        val fileSizeBytes = java.io.File(path).length()

                        // Container (extension-based fast path)
                        val ext = path.substringAfterLast('.', "").lowercase()
                        val container = when (ext) {
                            "mp4", "m4v"   -> "mp4"
                            "mov"          -> "mov"
                            "mkv"          -> "mkv"
                            "webm"         -> "webm"
                            "avi"          -> "avi"
                            "jpg", "jpeg"  -> "jpeg"
                            "png"          -> "png"
                            "heic"         -> "heic"
                            "webp"         -> "webp"
                            "m4a"          -> "m4a"
                            "mp3"          -> "mp3"
                            "aac"          -> "aac"
                            else           -> ext
                        }

                        // MediaKind
                        val imageExts = setOf("jpg","jpeg","png","heic","webp","gif","bmp","tiff")
                        val audioExts = setOf("m4a","aac","mp3","wav","flac","ogg")
                        val kind = when {
                            imageExts.contains(ext)  -> "image"
                            audioExts.contains(ext)  -> "audio"
                            hasVideo || listOf("mp4","mov","mkv","webm","avi","m4v").contains(ext) -> "video"
                            else -> "unknown"
                        }

                        // isHDR: METADATA_KEY_COLOR_TRANSFER requires API 30+; conservative false below.
                        val isHDR = false

                        // hasMoovAtFront: conservatively false by default (see implementation plan §B2).
                        val hasMoovAtFront = false

                        mainHandler.post {
                            // Build result map. Existing keys are preserved unchanged.
                            val resultMap = mutableMapOf<String, Any?>(
                                "kind"                 to kind,
                                "container"            to container,
                                "videoCodec"           to videoCodec,
                                "audioCodec"           to audioCodec,
                                "width"                to w,
                                "height"               to h,
                                "durationSeconds"      to seconds,
                                "bitrateKbps"          to bitrateKbps,
                                "fps"                  to fps,
                                "fileSizeBytes"        to fileSizeBytes,
                                "hasVideo"             to hasVideo,
                                "hasAudio"             to hasAudio,
                                "isHDR"                to isHDR,
                                "hasMoovAtFront"       to hasMoovAtFront,
                                "hasRotationTransform" to hasRotationTransform,
                                "hasEmbeddedMetadata"  to hasEmbeddedMetadata,
                                // ROI-5A.1 orientation evidence (additive).
                                "encodedWidth"         to w,
                                "encodedHeight"        to h,
                                "displayWidth"         to displayW,
                                "displayHeight"        to displayH,
                                // rotationDegrees: null when non-cardinal or no track.
                                "rotationDegrees"      to if (isCardinal) rotationDeg else null,
                                "transformA"           to tA,
                                "transformB"           to tB,
                                "transformC"           to tC,
                                "transformD"           to tD,
                                "transformTx"          to 0.0,
                                "transformTy"          to 0.0,
                                "orientationStatus"    to orientationStatus,
                            )
                            result.success(resultMap)
                        }

                    } catch (e: Exception) {
                        Log.e(TAG, "inspectMedia: $e")
                        mainHandler.post {
                            result.error("INSPECT_FAILED", "inspectMedia: ${e.message}", null)
                        }
                    } finally {
                        try { retriever.release() } catch (_: Exception) {}
                    }
                }.start()
            }

            // ── compressImage ─────────────────────────────────────────────────────────
            // Resizes and JPEG-encodes an image file.
            // Bitmap.compress(JPEG) strips all EXIF metadata by design — safe by default.
            "compressImage" -> {
                val inputPath  = args?.get("inputPath")  as? String
                val outputPath = args?.get("outputPath") as? String
                val maxWidthPx = (args?.get("maxWidthPx") as? Number)?.toInt() ?: 1080
                val quality    = ((args?.get("jpegQuality") as? Number)?.toDouble() ?: 0.82)
                    .let { (it * 100).toInt().coerceIn(1, 100) }

                if (inputPath == null || outputPath == null) {
                    result.error("INVALID_ARG",
                        "compressImage: inputPath and outputPath required", null)
                    return
                }
                Thread {
                    try {
                        val opts = android.graphics.BitmapFactory.Options().apply {
                            inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
                        }
                        val src = android.graphics.BitmapFactory.decodeFile(inputPath, opts)
                            ?: throw IllegalArgumentException("Cannot decode: $inputPath")

                        val srcW = src.width
                        val srcH = src.height
                        val scaled: android.graphics.Bitmap = if (srcW > maxWidthPx) {
                            val scale = maxWidthPx.toFloat() / srcW.toFloat()
                            val targetH = (srcH * scale).toInt().coerceAtLeast(1)
                            android.graphics.Bitmap.createScaledBitmap(src, maxWidthPx, targetH, true)
                        } else {
                            src
                        }

                        java.io.FileOutputStream(outputPath).use { out ->
                            // Bitmap.compress JPEG never writes EXIF — metadata stripped
                            scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, quality, out)
                        }

                        if (scaled !== src) src.recycle()
                        scaled.recycle()

                        mainHandler.post { result.success(mapOf("outputPath" to outputPath)) }
                    } catch (e: Exception) {
                        Log.e(TAG, "compressImage: $e")
                        mainHandler.post { result.error("COMPRESS_FAILED", e.message, null) }
                    }
                }.start()
            }

            "generateThumbnails" -> {
                // Mirrors iOS: AVAssetImageGenerator — returns List<ByteArray> (JPEG frames).
                // Dart side: List<Uint8List> — ByteArray maps directly.
                val videoPath = args?.get("videoPath") as? String
                val count     = (args?.get("count")    as? Number)?.toInt()    ?: 8
                val duration  = (args?.get("duration") as? Number)?.toDouble() ?: 0.0
                val maxWidth  = (args?.get("maxWidth") as? Number)?.toInt()
                val maxHeight = (args?.get("maxHeight") as? Number)?.toInt()
                val jpegQuality = (args?.get("jpegQuality") as? Number)?.toDouble()
                if (videoPath == null) {
                    result.error("INVALID_ARG", "generateThumbnails: videoPath required", null)
                    return
                }
                Thread {
                    val frames = VanguardThumbnailExtractor.extract(
                        videoPath, count, duration, maxWidth, maxHeight, jpegQuality
                    )
                    mainHandler.post { result.success(frames) }
                }.start()
            }

            // ── ROI-5B.1: Display-Oriented Frame Extraction Evidence ──────────
            // Diagnostic-only. Decodes the first frame via MediaMetadataRetriever
            // and returns its Bitmap dimensions. The Bitmap is recycled immediately
            // — no JPEG encoding, no file writes, no face detection.
            //
            // rotationHandling = "platformDecoderUnverified": Android API 29+
            // getFrameAtTime() auto-rotates by METADATA_KEY_VIDEO_ROTATION, but
            // behaviour on older APIs is not guaranteed. ROI-5B.2 physical smoke
            // will compare these dimensions against inspectMedia.displayWidth/
            // displayHeight on real devices to verify correctness.
            "extractDisplayOrientedFrameEvidence" -> {
                val videoPath = args?.get("videoPath") as? String
                if (videoPath.isNullOrEmpty()) {
                    result.error("INVALID_ARG",
                        "extractDisplayOrientedFrameEvidence: videoPath required", null)
                    return
                }
                Thread {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(videoPath)
                        val bitmap = retriever.getFrameAtTime(
                            0L,
                            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        )
                        if (bitmap != null) {
                            val w = bitmap.width
                            val h = bitmap.height
                            bitmap.recycle() // release immediately — no further use
                            mainHandler.post {
                                result.success(mapOf(
                                    "extractedFrameWidth"     to w,
                                    "extractedFrameHeight"    to h,
                                    "method"                  to "MediaMetadataRetriever.getFrameAtTime",
                                    "rotationHandling"        to "platformDecoderUnverified",
                                    "displayTransformApplied" to null,
                                    "requestedTimeSeconds"    to 0.0,
                                ))
                            }
                        } else {
                            mainHandler.post {
                                result.error("DECODE_FAILED",
                                    "extractDisplayOrientedFrameEvidence: getFrameAtTime returned null",
                                    null)
                            }
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "extractDisplayOrientedFrameEvidence: $e")
                        mainHandler.post {
                            result.error("DECODE_FAILED",
                                "extractDisplayOrientedFrameEvidence: ${e.message}", null)
                        }
                    } finally {
                        try { retriever.release() } catch (_: Exception) {}
                    }
                }.start()
            }

            // ROI-5C.1 Android stub — blocked until ROI-5B Android smoke passes.
            // Android face detection is NOT implemented in this slice.
            // Returns UNSUPPORTED_PLATFORM so Dart can handle it gracefully.
            "extractImportedFaceScanEvidence" -> {
                result.error(
                    "UNSUPPORTED_PLATFORM",
                    "ROI-5C Android face scan evidence is blocked until " +
                        "ROI-5B Android smoke passes",
                    null,
                )
            }


            "createImageTexture" -> {

                // Mirrors iOS: CVPixelBuffer → Metal Texture — returns textureId.
                // Android: BitmapFactory → Surface.lockCanvas() → Flutter SurfaceTexture.
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "createImageTexture: path required", null)
                    return
                }
                if (!java.io.File(path).exists()) {
                    result.error("FILE_NOT_FOUND", "createImageTexture: not found: $path", null)
                    return
                }
                val loader = VanguardImageTextureLoader(path, binding.textureRegistry)
                loader.load(
                    onLoaded = { id ->
                        imageLoaders[id] = loader
                        result.success(id)
                    },
                    onError = { e ->
                        // textureEntry already released inside VanguardImageTextureLoader.load()
                        result.error("ENCODE_FAIL", e.message, null)
                    }
                )
            }

            "startExport" -> {
                // B3: Dart sends List<Map<String,dynamic>> {path, trimStart, trimEnd}.
                // B4-S2: per-clip trim seek + EOS boundary.
                // B4-S4: if audioPath provided, encoder writes video-only to a temp path;
                //        after finish, remuxVideoWithAudio() merges video + audio into
                //        outputPath via a fresh MediaMuxer (2-pass, no encoder changes).
                @Suppress("UNCHECKED_CAST")
                val clipMaps   = (args?.get("clips") as? List<*>)?.filterIsInstance<Map<*, *>>()
                val outputPath = args?.get("outputPath") as? String
                val audioPath  = args?.get("audioPath")  as? String   // B4-S4
                val bitrate    = (args?.get("bitrate")    as? Number)?.toInt()    ?: 1_200_000
                val maxSeconds = (args?.get("maxSeconds") as? Number)?.toDouble() ?: 30.0

                // B4-S2: per-clip trim spec.
                data class ClipSpec(val path: String, val trimStart: Double, val trimEnd: Double?)
                val clipSpecs = clipMaps?.mapNotNull { m ->
                    val path = m["path"] as? String ?: return@mapNotNull null
                    ClipSpec(
                        path      = path,
                        trimStart = (m["trimStart"] as? Number)?.toDouble() ?: 0.0,
                        trimEnd   = (m["trimEnd"]   as? Number)?.toDouble(),
                    )
                } ?: emptyList()

                if (clipSpecs.isEmpty() || outputPath == null) {
                    result.error("INVALID_ARG", "clips (non-empty) and outputPath required", null)
                    return
                }

                // B4-S4: encoder writes to a temp file when audio must be merged afterwards.
                val needAudioMux = audioPath != null && java.io.File(audioPath).exists()
                val encoderOutputPath = if (needAudioMux) "$outputPath.vtmp" else outputPath

                val encoder = VanguardMediaCodecEncoder(
                    outputPath    = encoderOutputPath,
                    bitrate       = bitrate,
                    maxSeconds    = maxSeconds,
                    methodChannel = channel
                )
                encoder.prepare()
                activeEncoder = encoder  // B4-S5: store for cancelExport

                // Decode each clip through the encoder.
                // B4-S2: each clip is seeked to trimStart; input stops at trimEnd.
                Thread {
                    for (spec in clipSpecs) {
                        if (encoder.cancelled) break  // B4-S5: stop between clips on cancel
                        val extractor = MediaExtractor()
                        extractor.setDataSource(spec.path)

                        var trackIndex = -1
                        for (i in 0 until extractor.trackCount) {
                            val format = extractor.getTrackFormat(i)
                            if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                                trackIndex = i; break
                            }
                        }
                        if (trackIndex < 0) { extractor.release(); continue }
                        extractor.selectTrack(trackIndex)

                        // B4-S2: seek to trimStart before decoding
                        val trimStartUs = (spec.trimStart * 1_000_000L).toLong()
                        if (trimStartUs > 0L) {
                            extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                        }
                        // Long.MAX_VALUE = no trimEnd constraint (full clip after trimStart)
                        val trimEndUs = spec.trimEnd?.let { (it * 1_000_000L).toLong() } ?: Long.MAX_VALUE

                        val decoder = MediaCodec.createDecoderByType(
                            extractor.getTrackFormat(trackIndex).getString(MediaFormat.KEY_MIME)!!
                        )
                        decoder.configure(extractor.getTrackFormat(trackIndex), null, null, 0)
                        decoder.start()

                        val info = MediaCodec.BufferInfo()
                        var inputDone = false
                        while (true) {
                            // B4-S5 (fix): on cancel, queue decoder EOS exactly once so the
                            // decoder drain loop can break naturally. Without this, the decoder
                            // never sees EOS and the while(true) hangs indefinitely.
                            if (encoder.cancelled && !inputDone) {
                                val inIdx = decoder.dequeueInputBuffer(10_000)
                                if (inIdx >= 0) {
                                    decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                    inputDone = true
                                }
                                // If no buffer slot yet, loop — EOS queued on next iteration.
                            }
                            if (!inputDone) {
                                val inIdx = decoder.dequeueInputBuffer(10_000)
                                if (inIdx >= 0) {
                                    val buf  = decoder.getInputBuffer(inIdx)!!
                                    val size = extractor.readSampleData(buf, 0)
                                    // B4-S2: stop feeding at natural EOS or trimEnd boundary
                                    if (size < 0 || extractor.sampleTime > trimEndUs) {
                                        decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                        inputDone = true
                                    } else {
                                        decoder.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                                        extractor.advance()
                                    }
                                }
                            }
                            val outIdx = decoder.dequeueOutputBuffer(info, 10_000)
                            if (outIdx >= 0) {
                                // render=true → frame goes to encoder input surface via GL
                                decoder.releaseOutputBuffer(outIdx, true)
                                encoder.submitFrame()
                                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                            }
                        }
                        decoder.stop(); decoder.release(); extractor.release()
                    }
                    encoder.finish { success ->
                        activeEncoder = null  // B4-S5: clear plugin-level ref

                        // B4-S5 (fix): cancelled — clean up output files, resolve startExport as failed.
                        // Both output paths must be cleaned:
                        //   needAudioMux=true  → encoderOutputPath (.vtmp) is the partial file
                        //   needAudioMux=false → outputPath itself is the partial/corrupt file
                        if (encoder.cancelled) {
                            if (needAudioMux) {
                                java.io.File(encoderOutputPath).delete()
                            } else {
                                java.io.File(outputPath).delete()
                            }
                            result.success(mapOf("outputPath" to outputPath, "success" to false))
                            return@finish
                        }

                        if (!success) {
                            // Encode failed — clean up temp and return failure.
                            if (needAudioMux) java.io.File(encoderOutputPath).delete()
                            result.success(mapOf("outputPath" to outputPath, "success" to false))
                            return@finish
                        }
                        if (needAudioMux) {
                            // B4-S4: remux video-only temp + audio into final output.
                            try {
                                remuxVideoWithAudio(encoderOutputPath, audioPath!!, outputPath)
                                java.io.File(encoderOutputPath).delete()
                                result.success(mapOf("outputPath" to outputPath, "success" to true))
                            } catch (e: Exception) {
                                Log.e(TAG, "remuxVideoWithAudio: $e")
                                // Fall back to video-only: rename temp to final
                                java.io.File(encoderOutputPath).renameTo(java.io.File(outputPath))
                                result.success(mapOf("outputPath" to outputPath, "success" to true))
                            }
                        } else {
                            result.success(mapOf("outputPath" to outputPath, "success" to true))
                        }
                    }
                }.start()
            }

            // ─── Camera pipeline (B2) ────────────────────────────────────────────────

            "startCamera" -> {
                // Extract Dart args — mirrors iOS: position (1=back, 2=front), fps.
                val positionInt = (args?.get("position") as? Number)?.toInt() ?: 1
                val fps         = (args?.get("fps")      as? Number)?.toInt() ?: 30
                val lensFacing  = if (positionInt == 2)
                    androidx.camera.core.CameraSelector.LENS_FACING_FRONT
                else
                    androidx.camera.core.CameraSelector.LENS_FACING_BACK

                // I-2 HARD RESET: stop any existing camera session before creating
                // a new one. Mirrors iOS: teardownCameraAsync → cameraSource?.stop().
                val prev = cameraSource
                if (prev != null) {
                    Log.w(TAG, "startCamera: previous session still active — stopping first")
                    prev.stop()
                    cameraSource = null
                    val prevTex = cameraTexture
                    if (prevTex != null) {
                        Log.i("VanguardTex", "[RELEASE/reset] textureId=${prevTex.id()}")
                        prevTex.release()
                    }
                    cameraTexture = null
                }

                val textureEntry = binding.textureRegistry.createSurfaceTexture()
                Log.i("VanguardTex", "[CREATE] textureId=${textureEntry.id()}")
                val source = VanguardCameraSource(
                    context      = context,
                    textureEntry = textureEntry,
                    lensFacing   = lensFacing,
                    frameRate    = fps,
                )
                cameraTexture = textureEntry
                cameraSource  = source

                source.start(
                    onStarted = {
                        Log.d(TAG, "startCamera: live, textureId=${textureEntry.id()}")
                        result.success(textureEntry.id())
                    },
                    onError = { e ->
                        Log.e(TAG, "startCamera: failed — ${e.message}")
                        cameraSource = null
                        val errTex = cameraTexture
                        if (errTex != null) {
                            Log.i("VanguardTex", "[RELEASE/error] textureId=${errTex.id()}")
                            errTex.release()
                        }
                        cameraTexture = null
                        result.error("CAMERA_ERROR", e.message, null)
                    }
                )
            }

            "stopCamera" -> {
                // Idempotent: safe to call even if no camera is running.
                Log.d(TAG, "stopCamera")
                cameraSource?.stop()
                cameraSource = null
                val tex = cameraTexture
                if (tex != null) {
                    Log.i("VanguardTex", "[RELEASE] textureId=${tex.id()}")
                    tex.release()
                }
                cameraTexture = null
                result.success(null)
            }

            "switchCamera" -> {
                val src = cameraSource
                if (src == null) {
                    result.error("NO_CAMERA", "Camera not started", null)
                    return
                }
                if (src.isRecording) {
                    // Mirror iOS: reject switch while recording is active.
                    result.error("RECORDING_ACTIVE",
                        "Cannot switch camera while recording", null)
                    return
                }
                src.switchCamera(
                    onStarted = { result.success(null) },
                    onError   = { e -> result.error("CAMERA_ERROR", e.message, null) }
                )
            }

            "takePhoto" -> {
                val src = cameraSource
                if (src == null) {
                    result.error("NO_CAMERA", "Camera not started", null)
                    return
                }
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "takePhoto: path required", null)
                    return
                }
                src.takePhoto(
                    outputPath = path,
                    onResult   = { savedPath -> result.success(savedPath) },
                    onError    = { e -> result.error("CAPTURE_ERROR", e.message, null) }
                )
            }

            "startRecording" -> {
                val src = cameraSource
                if (src == null) {
                    result.error("NO_CAMERA", "Camera not started", null)
                    return
                }
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("INVALID_ARG", "startRecording: path required", null)
                    return
                }
                src.startRecording(
                    outputPath = path,
                    onStarted  = { result.success(null) },
                    onError    = { e -> result.error("REC_FAIL", e.message, null) }
                )
            }

            "stopRecording" -> {
                val src = cameraSource
                if (src == null) {
                    // Camera already gone — return an empty result to match iOS no-op path.
                    result.success(mapOf(
                        "filePath"      to "",
                        "droppedFrames" to 0,
                        "totalFrames"   to 0,
                        "dropRate"      to 0.0
                    ))
                    return
                }
                src.stopRecording(
                    onFinalized = { filePath, droppedFrames, totalFrames ->
                        // Mirror iOS result map shape exactly so Dart
                        // VanguardEngine.stopRecording() parses without change.
                        result.success(mapOf(
                            "filePath"      to filePath,
                            "droppedFrames" to droppedFrames,
                            "totalFrames"   to totalFrames,
                            "dropRate"      to if (totalFrames > 0)
                                droppedFrames.toDouble() / totalFrames.toDouble()
                            else 0.0
                        ))
                    },
                    onError = { e -> result.error("STOP_FAIL", e.message, null) }
                )
            }

            "setZoom" -> {
                val level = (args?.get("level") as? Number)?.toFloat() ?: 1.0f
                cameraSource?.setZoom(level)
                result.success(null)
            }

            "setTorchMode" -> {
                // Dart passes mode as String ("on"/"off") — mirrors iOS contract.
                val mode    = args?.get("mode") as? String ?: "off"
                val enabled = mode == "on"
                cameraSource?.setTorchMode(enabled)
                result.success(null)
            }

            "setFocusPoint" -> {
                val x = (args?.get("x") as? Number)?.toFloat() ?: 0.5f
                val y = (args?.get("y") as? Number)?.toFloat() ?: 0.5f
                cameraSource?.setFocusPoint(x, y)
                result.success(null)
            }


            // ─── B4-S5: cancelExport ──────────────────────────────────────────────────
            // Stops the active encoder by setting its cancelled flag.
            // The encode thread will see the flag on next submitFrame() or loop iteration,
            // stop feeding input, let the decoder drain to EOS, then call encoder.finish()
            // which cleans up temp files and resolves the pending startExport Future.
            "cancelExport" -> {
                val enc = activeEncoder
                if (enc != null) {
                    enc.cancel()
                    activeEncoder = null
                    Log.i(TAG, "cancelExport: cancellation signalled")
                } else {
                    Log.d(TAG, "cancelExport: no active export")
                }
                result.success(null)
            }

            // ─── B4-S1: extractAudio ──────────────────────────────────────────────────
            // Mirrors iOS AVAssetExportSession audio-only preset.
            // Dart sends trimEnd: double.infinity for no-trim; isFinite() guard → null.
            "extractAudio" -> {
                val videoPath  = args?.get("videoPath")  as? String
                val outputPath = args?.get("outputPath") as? String
                val trimStart  = (args?.get("trimStart") as? Number)?.toDouble() ?: 0.0
                val trimEndRaw = (args?.get("trimEnd")   as? Number)?.toDouble()
                val trimEnd    = if (trimEndRaw != null && trimEndRaw.isFinite()) trimEndRaw else null

                if (videoPath == null || outputPath == null) {
                    result.error("INVALID_ARG", "extractAudio: videoPath and outputPath required", null)
                    return
                }
                Thread {
                    try {
                        val path = VanguardAudioExtractor.extract(
                            videoPath    = videoPath,
                            outputPath   = outputPath,
                            trimStartSec = trimStart,
                            trimEndSec   = trimEnd,
                        )
                        mainHandler.post { result.success(path) }
                    } catch (e: Exception) {
                        Log.e(TAG, "extractAudio: $e")
                        mainHandler.post { result.error("EXTRACT_FAIL", e.message, null) }
                    }
                }.start()
            }

            else -> result.notImplemented()
        }
    }

    // ─── B4-S4: remuxVideoWithAudio ──────────────────────────────────────────────
    //
    // 2-pass audio mux strategy:
    //   1. VanguardMediaCodecEncoder writes video-only to a temp .vtmp path.
    //   2. This function stream-copies video from temp + audio from audioPath
    //      into the final output using a fresh MediaMuxer.
    //
    // Why 2-pass instead of modifying the encoder's internal muxer:
    //   MediaMuxer requires addTrack() for ALL tracks before muxer.start().
    //   The encoder's video track format is only known after INFO_OUTPUT_FORMAT_CHANGED
    //   fires asynchronously during the first encode frame. Adding audio before
    //   that event fires is not possible without a major encoder refactor.
    //   The 2-pass approach is the minimal-risk solution: it reuses proven stream-copy
    //   code (same pattern as VanguardAudioExtractor) and leaves the encoder intact.
    //
    // Falls back gracefully: if this throws, startExport renames the temp to final
    // (video-only output) rather than crashing.
    //
    private fun remuxVideoWithAudio(videoOnlyPath: String, audioPath: String, finalPath: String) {
        val videoEx = MediaExtractor()
        val audioEx = MediaExtractor()
        try {
            videoEx.setDataSource(videoOnlyPath)
            audioEx.setDataSource(audioPath)

            // Find video track
            var videoTrack = -1
            var videoFormat: android.media.MediaFormat? = null
            for (i in 0 until videoEx.trackCount) {
                val f = videoEx.getTrackFormat(i)
                if (f.getString(android.media.MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                    videoTrack = i; videoFormat = f; break
                }
            }

            // Find audio track
            var audioTrack = -1
            var audioFormat: android.media.MediaFormat? = null
            for (i in 0 until audioEx.trackCount) {
                val f = audioEx.getTrackFormat(i)
                if (f.getString(android.media.MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    audioTrack = i; audioFormat = f; break
                }
            }

            if (videoTrack < 0 || videoFormat == null) {
                throw IllegalStateException("remuxVideoWithAudio: no video track in $videoOnlyPath")
            }

            videoEx.selectTrack(videoTrack)

            // Muxer: add video first, then audio (if present), before start()
            val muxer = android.media.MediaMuxer(finalPath, android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val muxVideoTrack = muxer.addTrack(videoFormat)
            val muxAudioTrack = if (audioTrack >= 0 && audioFormat != null) {
                audioEx.selectTrack(audioTrack)
                muxer.addTrack(audioFormat)
            } else -1
            muxer.start()

            val buf  = java.nio.ByteBuffer.allocate(1024 * 1024)  // 1MB handles any video NAL unit
            val info = android.media.MediaCodec.BufferInfo()

            // Stream-copy video
            while (true) {
                val size = videoEx.readSampleData(buf, 0)
                if (size < 0) break
                info.offset             = 0
                info.size               = size
                info.presentationTimeUs = videoEx.sampleTime
                info.flags              = videoEx.sampleFlags
                muxer.writeSampleData(muxVideoTrack, buf, info)
                videoEx.advance()
            }

            // Stream-copy audio (if available)
            if (muxAudioTrack >= 0) {
                while (true) {
                    val size = audioEx.readSampleData(buf, 0)
                    if (size < 0) break
                    info.offset             = 0
                    info.size               = size
                    info.presentationTimeUs = audioEx.sampleTime
                    info.flags              = audioEx.sampleFlags
                    muxer.writeSampleData(muxAudioTrack, buf, info)
                    audioEx.advance()
                }
            }

            muxer.stop()
            muxer.release()
            Log.i(TAG, "remuxVideoWithAudio OK → $finalPath")
        } finally {
            try { videoEx.release() } catch (_: Exception) {}
            try { audioEx.release() } catch (_: Exception) {}
        }
    }

        override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // B2: Tear down camera session first — prevents leaked CameraX session
        // on hot-restart (Flutter re-attaches the engine to a new surface).
        cameraSource?.stop()
        cameraSource = null
        val detachTex = cameraTexture
        if (detachTex != null) {
            Log.i("VanguardTex", "[RELEASE/detach] textureId=${detachTex.id()}")
            detachTex.release()
        }
        cameraTexture = null
        // Tear down editor renderers.
        renderers.values.forEach { it.dispose() }
        renderers.clear()
    }
}
