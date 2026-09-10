package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.util.Log

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Backend ladder policy for the Duet green-screen adapter.
// -----------------------------------------------------------------------------
//
// Frozen ladder (slice 1): mediapipe_cpu -> mlkit -> none (safe PiP).
//   - MediaPipe CPU is primary whenever the bundled model asset is readable
//     from the merged app assets. GPU (`mediapipe_gpu`) is deferred and never
//     selected here.
//   - ML Kit is always the next rung after MediaPipe and is itself terminal:
//     nextBackendId(mlkit) == null, which the adapter maps to the existing
//     `green_screen_fallback` + safe PiP path.
//   - Degradation is one-way: the ladder only walks downwards, and the session
//     coordinator latches the reached rung so later adapters in the same
//     session start there instead of re-trying MediaPipe (no oscillation).
//
// The selector holds no segmenter state; it only decides and constructs.

class AndroidDuetSegmentationBackendSelector(
    private val context: Context?,
) {

    /** Context this selector was constructed with, exposed so the adapter can build its adaptive-quality policy. */
    val hostContext: Context? get() = context

    companion object {
        private const val TAG = "DuetSegSelector"

        /** Asset-relative path of the bundled MediaPipe selfie segmenter model. */
        const val MODEL_ASSET_PATH = "selfie_segmenter.tflite"

        /** Ordered ladder, highest quality first. `none` is implicit after the last entry. */
        val LADDER: List<String> = listOf(
            DuetSegmentationBackend.MEDIAPIPE_CPU,
            DuetSegmentationBackend.MLKIT,
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
            Log.w(TAG, "MediaPipe model asset '$MODEL_ASSET_PATH' not readable (${t.message}); " +
                "starting ladder at ${DuetSegmentationBackend.MLKIT}")
            false
        }
    }

    /** First rung to try for a fresh adapter (no session latch). */
    fun primaryBackendId(): String =
        if (context != null && isMediaPipeModelBundled) DuetSegmentationBackend.MEDIAPIPE_CPU
        else DuetSegmentationBackend.MLKIT

    /**
     * Next rung below [backendId], or null when [backendId] is the last
     * segmentation rung (terminal -> safe PiP).
     */
    fun nextBackendId(backendId: String): String? {
        val idx = LADDER.indexOf(backendId)
        if (idx < 0) return null
        return LADDER.getOrNull(idx + 1)
    }

    /** True when [backendId] is a rung this selector can construct. */
    fun supports(backendId: String): Boolean = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_CPU -> context != null
        DuetSegmentationBackend.MLKIT         -> true
        else                                  -> false
    }

    /**
     * Constructs (but does not open) the backend for [backendId].
     * Throws IllegalArgumentException for unsupported ids.
     */
    fun createBackend(backendId: String): AndroidDuetSegmentationBackend = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_CPU -> {
            val ctx = context
                ?: throw IllegalArgumentException("MediaPipe backend requires a Context")
            AndroidDuetMediaPipeSegmentationBackend(ctx.applicationContext ?: ctx, MODEL_ASSET_PATH)
        }
        DuetSegmentationBackend.MLKIT -> AndroidDuetMlKitSegmentationBackend()
        else -> throw IllegalArgumentException("Unsupported segmentation backend '$backendId'")
    }

    /**
     * Capability probe describing the rung [primaryBackendId] would start on.
     * Delegates to the dynamic probe so [DuetSegmentationProbe.thermalTier]
     * reflects the live OS thermal status instead of a static default.
     */
    fun probe(): DuetSegmentationProbe {
        val backendId = primaryBackendId()
        val quality = if (backendId == DuetSegmentationBackend.MEDIAPIPE_CPU) {
            DuetSegmentationQuality.QUALITY
        } else {
            DuetSegmentationQuality.BALANCED
        }
        return DuetSegmentationProbe.probe(context, backendId, quality)
    }
}
