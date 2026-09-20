package com.connects.vanguard_media_engine.export

import android.content.Context
import android.media.ExifInterface
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File
import kotlin.math.abs

// ── AndroidTimelineReverseNormalizationPrepass (P5-REVERSE-COMPOSITION-NORMALIZATION-A) ──
//
// Pass-0 helper owned by AndroidTimelineExportSession. When the committed
// pass-1 backend is GLES and the scope combines a reversed video clip with a
// non-hard-cut transition and/or clip-level Beauty V2
// (AndroidExportRenderBackendSelector.ExportRenderScope
// .glesReverseNormalizationRequired), neither GLES pass-1 encoder has a
// reversed render route for that shape (AndroidTimelineGlesTransitionVideoEncoder
// and AndroidTimelineVideoEncoder's Beauty path both fail closed on
// ClipInput.isReversed). This prepass normalizes each reversed clip into an
// owned, forward, video-only temp MP4 first, using the existing
// AndroidTimelineVideoEncoder reverse renderer (renderReversedClipIntoEncoder)
// as the normalizer -- no Beauty, no overlays, no transitions, no audio --
// and returns a replacement pass-1 clip list where every reversed clip is
// replaced by a forward clip over its temp:
//   sourcePath = temp, isReversed = false, rotationDegrees = 0,
//   trimStartSeconds = 0.0, trimEndSeconds = measured temp duration,
//   mediaKind = "video", colorMatrix = null, beautyIntensity preserved.
// Clip order and count are unchanged, so index-bound transitions still bind
// the same adjacent pair.
//
// Lifecycle contract:
//   - Every temp path is registered in [ownedTempPaths] BEFORE its encoder
//     starts, so a temp that only partially exists at abort time is still
//     covered by [deleteOwnedTemps]. The session folds [deleteOwnedTemps]
//     into its own owned-temp cleanup, which runs on every terminal exit
//     (success, cancel, pass-0/1/2 failure, finalize failure, thrown
//     exception). A failed/cancelled normalization additionally deletes its
//     own partial temp immediately.
//   - The normalizer encoder is handed to [trackActiveEncoder] for the
//     duration of its encode call so the session's requestCancel() reaches
//     it exactly like a pass-1 encoder; the cancellation flag is re-checked
//     after registration so a cancel that lands in the registration gap is
//     forwarded rather than lost.
//   - Audio non-claim: the temp carries no audio track and nothing here ever
//     reads audio from it; pass-2 mux/mixdown keeps using the draft's own
//     audio specs unchanged.
//
// Fail-closed shape checks (defensive re-validation of what the selector's
// reversedClipNormalizationIneligibleReason already gates upstream): a
// reversed clip must be a video clip with zero rotation metadata, no
// colorMatrix, and positive decoded dimensions. After encoding, the temp must
// expose a readable video track with positive dimensions and a positive
// duration that differs from the original trim span by at most one frame
// period (plus a small container-quantization tolerance); anything else
// fails the whole export rather than silently producing wrong timing.
internal class AndroidTimelineReverseNormalizationPrepass(
    private val cacheDir: File,
    private val exportId: String,
    private val fps: Int,
    private val requestedWidth: Int,
    private val requestedHeight: Int,
    private val requestedBitrateBps: Int,
    // Android reference-video export: optional Context threaded into the
    // normalizer AndroidTimelineVideoEncoder so a reversed clip whose
    // sourcePath is a `content://` URI can be opened through the
    // ContentResolver. The forward temp this prepass writes is always a
    // POSIX cache file, so [probeTemp] stays File-based.
    private val context: Context? = null,
) {
    sealed class Result {
        /// [clips] is the replacement pass-1 clip list (same order/size as
        /// the input); [normalizedClipCount] is how many temps were produced.
        data class Normalized(
            val clips: List<AndroidTimelineVideoEncoder.ClipInput>,
            val normalizedClipCount: Int,
        ) : Result()

        /// [cancelled] is true when the failure is a cancellation (the
        /// session reports EXPORT_CANCELLED instead of EXPORT_FAILED).
        data class Failed(val reason: String, val cancelled: Boolean) : Result()
    }

    private data class TempProbe(val width: Int, val height: Int, val durationSeconds: Double)

    private val ownedTempPaths = ArrayList<String>()

    /// Deletes every temp this prepass has allocated so far (complete or
    /// partial). Idempotent; never throws.
    fun deleteOwnedTemps() {
        for (path in ownedTempPaths) {
            try { File(path).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
        }
    }

    /// Normalizes every reversed clip in [clips]. Returns the input list
    /// unchanged (count 0) when no clip is reversed. Never throws: encoder
    /// failures and probe exceptions are folded into [Result.Failed].
    fun run(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        isCancelled: () -> Boolean,
        trackActiveEncoder: (AndroidTimelineVideoPassEncoder?) -> Unit,
        onProgress: ((Double) -> Unit)?,
    ): Result {
        val reversedIndices = clips.indices.filter { clips[it].isReversed }
        if (reversedIndices.isEmpty()) return Result.Normalized(clips, 0)
        if (fps <= 0) return Result.Failed("reverse_normalization_invalid_fps:$fps", false)

        val replaced = clips.toMutableList()
        val reversedCount = reversedIndices.size
        for ((ordinal, clipIndex) in reversedIndices.withIndex()) {
            if (isCancelled()) return Result.Failed("cancelled", true)
            val clip = clips[clipIndex]
            val shapeFailure = normalizationIneligibleReason(clip)
            if (shapeFailure != null) {
                return Result.Failed("reverse_normalization_ineligible:$shapeFailure:${clip.sourcePath}", false)
            }

            val tempPath = File(cacheDir, "vg_timeline_export_reverse_${exportId}_$clipIndex.mp4").absolutePath
            // Registered before the encoder is even constructed so an abort
            // at any later point leaves this path covered by cleanup.
            ownedTempPaths.add(tempPath)
            try { File(tempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}

            // AVC hardware encoders require even dimensions; a (rare) odd
            // decoded dimension is floored to even and the reverse renderer's
            // own aspect-preserving fit absorbs the sub-pixel difference.
            val tempWidth = (clip.decodedWidth and 1.inv()).coerceAtLeast(2)
            val tempHeight = (clip.decodedHeight and 1.inv()).coerceAtLeast(2)
            val tempBitrateBps = intermediateBitrateBps(tempWidth, tempHeight)

            // The normalizer clip: the original reversed trim window, with
            // Beauty and colorMatrix stripped (colorMatrix is already null
            // by the shape check above; Beauty is re-applied by pass-1 on
            // the forward temp instead). No overlays/transitions are passed.
            val normalizerClip = clip.copy(
                beautyIntensity = null,
                colorMatrix = null,
                stillFrameCount = 0,
            )
            val encoder = AndroidTimelineVideoEncoder(
                outputPath = tempPath,
                width = tempWidth,
                height = tempHeight,
                fps = fps,
                bitrateBps = tempBitrateBps,
                nativeBridge = null,
                context = context,
            )
            val encodeResult = try {
                trackActiveEncoder(encoder)
                // Close the registration gap: a requestCancel() that ran
                // between the loop-top check and registration had no
                // encoder to signal, so forward it explicitly now.
                if (isCancelled()) encoder.cancel()
                encoder.encode(listOf(normalizerClip)) { sampleRatio ->
                    val ratio = ((ordinal + sampleRatio.coerceIn(0.0, 1.0)) / reversedCount).coerceIn(0.0, 1.0)
                    onProgress?.invoke(ratio)
                }
            } catch (t: Throwable) {
                Log.e(TAG, "reverse normalization threw for ${clip.sourcePath}: $t", t)
                AndroidTimelineVideoEncoder.EncodeResult(false, "exception:${t.javaClass.simpleName}", 0, 0L)
            } finally {
                trackActiveEncoder(null)
            }

            if (!encodeResult.success) {
                deletePartialTemp(tempPath)
                val cancelled = isCancelled() || encodeResult.reason == "cancelled"
                return if (cancelled) {
                    Result.Failed("cancelled", true)
                } else {
                    Result.Failed("reverse_normalization_encode_failed:${encodeResult.reason}:${clip.sourcePath}", false)
                }
            }
            if (isCancelled()) {
                deletePartialTemp(tempPath)
                return Result.Failed("cancelled", true)
            }

            val probe = probeTemp(tempPath)
            if (probe == null) {
                deletePartialTemp(tempPath)
                return Result.Failed("reverse_normalization_temp_unreadable:${clip.sourcePath}", false)
            }
            if (probe.width <= 0 || probe.height <= 0) {
                deletePartialTemp(tempPath)
                return Result.Failed(
                    "reverse_normalization_temp_invalid_dimensions:${probe.width}x${probe.height}:${clip.sourcePath}",
                    false,
                )
            }
            if (!probe.durationSeconds.isFinite() || probe.durationSeconds <= 0.0) {
                deletePartialTemp(tempPath)
                return Result.Failed("reverse_normalization_temp_duration_missing:${clip.sourcePath}", false)
            }
            val originalSpanSeconds = clip.trimEndSeconds - clip.trimStartSeconds
            val toleranceSeconds = (1.0 / fps) + DURATION_QUANTIZATION_TOLERANCE_SECONDS
            if (abs(probe.durationSeconds - originalSpanSeconds) > toleranceSeconds) {
                deletePartialTemp(tempPath)
                return Result.Failed(
                    "reverse_normalization_duration_mismatch:expected=$originalSpanSeconds:" +
                        "measured=${probe.durationSeconds}:tolerance=$toleranceSeconds:${clip.sourcePath}",
                    false,
                )
            }

            replaced[clipIndex] = clip.copy(
                sourcePath = tempPath,
                trimStartSeconds = 0.0,
                trimEndSeconds = probe.durationSeconds,
                decodedWidth = probe.width,
                decodedHeight = probe.height,
                rotationDegrees = 0,
                mediaKind = "video",
                stillFrameCount = 0,
                exifOrientation = ExifInterface.ORIENTATION_NORMAL,
                colorMatrix = null,
                beautyIntensity = clip.beautyIntensity,
                isReversed = false,
            )
            Log.i(
                TAG,
                "VG_EXPORT_REVERSE_NORMALIZED clip=$clipIndex span=$originalSpanSeconds " +
                    "measured=${probe.durationSeconds} temp=${probe.width}x${probe.height} " +
                    "samples=${encodeResult.writtenVideoSamples} beauty=${clip.beautyIntensity != null}",
            )
        }
        return Result.Normalized(replaced, reversedCount)
    }

    /// Mirrors AndroidExportRenderBackendSelector.ExportRenderScope
    /// .reversedClipNormalizationIneligibleReason as an encoder-side defense.
    private fun normalizationIneligibleReason(clip: AndroidTimelineVideoEncoder.ClipInput): String? {
        if (!clip.isReversed) return "not_reversed"
        if (clip.mediaKind != "video") return "non_video_media_kind:${clip.mediaKind}"
        if (clip.rotationDegrees != 0) return "non_zero_rotation:${clip.rotationDegrees}"
        if (clip.colorMatrix != null) return "color_matrix_present"
        if (clip.decodedWidth <= 0 || clip.decodedHeight <= 0) {
            return "invalid_decoded_dimensions:${clip.decodedWidth}x${clip.decodedHeight}"
        }
        if (!clip.trimStartSeconds.isFinite() || !clip.trimEndSeconds.isFinite() ||
            clip.trimEndSeconds <= clip.trimStartSeconds
        ) {
            return "invalid_trim_window"
        }
        return null
    }

    /// Intermediate bitrate: never below the requested output bitrate, and
    /// scaled up by pixel-area ratio when the temp is larger than the
    /// requested output so the intermediate does not become the quality
    /// bottleneck of the final render. Capped to a sane hardware ceiling.
    private fun intermediateBitrateBps(tempWidth: Int, tempHeight: Int): Int {
        val requestedArea = requestedWidth.toLong() * requestedHeight.toLong()
        val tempArea = tempWidth.toLong() * tempHeight.toLong()
        val base = requestedBitrateBps.toLong().coerceAtLeast(1L)
        val scaled = if (requestedArea > 0L) base * tempArea / requestedArea else base
        return scaled.coerceAtLeast(base).coerceAtMost(MAX_INTERMEDIATE_BITRATE_BPS).toInt()
    }

    private fun deletePartialTemp(path: String) {
        try { File(path).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
    }

    /// Reads the temp's first video track: coded dimensions and the track
    /// duration in microseconds (MediaFormat.KEY_DURATION), which -- unlike
    /// MediaMetadataRetriever's millisecond rounding -- never rounds the
    /// duration up past the last written sample and therefore never makes
    /// pass-1 expect one more frame than the temp contains.
    private fun probeTemp(path: String): TempProbe? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") != true) continue
                val width = if (format.containsKey(MediaFormat.KEY_WIDTH)) format.getInteger(MediaFormat.KEY_WIDTH) else 0
                val height = if (format.containsKey(MediaFormat.KEY_HEIGHT)) format.getInteger(MediaFormat.KEY_HEIGHT) else 0
                val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
                return TempProbe(width, height, durationUs / 1_000_000.0)
            }
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "probeTemp failed for $path: $t")
            return null
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    companion object {
        private const val TAG = "VGReverseNormalization"

        /// Allowance on top of one frame period for MP4 timescale rounding of
        /// the fixed-frame-clock sample timestamps the normalizer writes.
        private const val DURATION_QUANTIZATION_TOLERANCE_SECONDS = 0.002

        private const val MAX_INTERMEDIATE_BITRATE_BPS = 100_000_000L
    }
}
