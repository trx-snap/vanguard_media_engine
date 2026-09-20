package com.connects.vanguard_media_engine.greenscreen

import android.content.Context
import android.util.Log

// -----------------------------------------------------------------------------
// VG-GREEN-SCREEN: Backend ladder policy for the independent, neutral
// green-screen Camera2 clean segmentation path
// ([AndroidGreenScreenCleanSegmentationPipeline]).
// -----------------------------------------------------------------------------
//
// Mirrors the production-ladder decision half of
// `com.connects.vanguard_media_engine.duet.AndroidDuetSegmentationBackendSelector`
// (mediapipe_cpu -> mlkit -> none / safe fallback), scoped to exactly what the
// clean Camera2 path uses: which rung to try first, and which rung to degrade
// to next. It deliberately does NOT port that selector's `supports()` /
// `createBackend()` surface — those construct backends implementing the
// ImageProxy-based `AndroidDuetSegmentationBackend` interface, which belongs to
// the Duet adapter, not this Camera2-`Image`-based clean path. Porting them
// here would pull a duet-owned backend-construction dependency into the
// green-screen package, which is the inverted direction this slice removes.
// [AndroidGreenScreenCleanSegmentationPipeline] constructs its own Camera2
// `Image`-based backends directly and only needs the ladder decision below.
//
// raw_tflite_gpu / mediapipe_gpu are not offered by this selector: the clean
// Camera2 path only ever opens mediapipe_cpu or mlkit (see the pipeline's
// `openRungLocked`), matching the duet selector's production (non-debug)
// ladder.

class AndroidGreenScreenBackendSelector(
    private val context: Context?,
) {

    companion object {
        private const val TAG = "GreenScreenSegSelector"

        /**
         * Asset-relative path of the bundled MediaPipe selfie segmenter model
         * used by the production CPU rung. Identical value to
         * `AndroidDuetSegmentationBackendSelector.MODEL_ASSET_PATH`.
         */
        const val MODEL_ASSET_PATH = "selfie_segmentation_landscape.tflite"

        /**
         * Ordered production ladder, highest proven-safe quality first. `none`
         * is implicit after the last entry.
         */
        val LADDER: List<String> = listOf(
            AndroidGreenScreenSegmentationBackend.MEDIAPIPE_CPU,
            AndroidGreenScreenSegmentationBackend.MLKIT,
        )
    }

    /**
     * True when the MediaPipe model asset can be opened from the app's merged
     * assets. Evaluated once per selector; a missing asset makes ML Kit the
     * primary rung without any event (there is nothing to degrade from).
     */
    val isMediaPipeModelBundled: Boolean by lazy {
        val ctx = context ?: return@lazy false
        try {
            ctx.assets.open(MODEL_ASSET_PATH).use { }
            true
        } catch (t: Throwable) {
            Log.w(
                TAG,
                "MediaPipe model asset '$MODEL_ASSET_PATH' not readable (${t.message}); " +
                    "starting ladder at ${AndroidGreenScreenSegmentationBackend.MLKIT}",
            )
            false
        }
    }

    /**
     * First rung to try for a fresh pipeline. CPU is preferred whenever the
     * bundled model asset exists; whether the device actually supports the CPU
     * delegate is proven only by opening it, so a device that can't run
     * MediaPipe CPU simply falls through to mlkit via the pipeline's ordinary
     * open-failure ladder walk.
     */
    fun primaryBackendId(): String =
        if (context != null && isMediaPipeModelBundled) AndroidGreenScreenSegmentationBackend.MEDIAPIPE_CPU
        else AndroidGreenScreenSegmentationBackend.MLKIT

    /**
     * Next rung below [backendId], or null when [backendId] is the last
     * segmentation rung (terminal -> none).
     */
    fun nextBackendId(backendId: String): String? {
        val idx = LADDER.indexOf(backendId)
        if (idx < 0) return null
        return LADDER.getOrNull(idx + 1)
    }
}
