package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.util.Log

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Backend ladder policy for the Duet green-screen adapter.
// -----------------------------------------------------------------------------
//
// Production ladder: mediapipe_cpu -> mlkit -> none (safe PiP).
//   - mediapipe_gpu is DELIBERATELY EXCLUDED from the production ladder. A
//     physical smoke test on SM-A566B (Android 16) showed MediaPipe Tasks
//     ImageSegmenter with Delegate.GPU + outputConfidenceMasks(true) can
//     `open()` successfully and then SIGABRT natively inside the result
//     converter on the very first frame (image_frame.cc:291 "Format UNKNOWN
//     = 0"). That abort happens in native code below the JVM, so it cannot be
//     caught as a Kotlin exception/backend failure and would crash the whole
//     process instead of degrading the ladder. Until a non-crashing GPU mask
//     extraction path is proven, [supports] returns false for mediapipe_gpu
//     and neither [primaryBackendId] nor [LADDER] ever route a production
//     session to it. This is not a device-specific blacklist: GPU is simply
//     not offered to any device yet. The GPU backend implementation itself
//     (AndroidDuetMediaPipeSegmentationBackend.gpu) is kept latent/experimental
//     for future investigation.
//   - MediaPipe CPU is primary whenever the bundled model asset is readable
//     from the merged app assets. True CPU delegate support can only be
//     proven by actually opening the ImageSegmenter (createFromOptions with
//     Delegate.CPU); there is no static device blacklist or allowlist here,
//     so an unsupported device simply fails open() and the adapter's existing
//     open-failure loop walks the ladder down to mlkit.
//   - ML Kit is always the last live rung and is itself terminal:
//     nextBackendId(mlkit) == null, which the adapter maps to the existing
//     `green_screen_fallback` + safe PiP path.
//   - Degradation is one-way: the ladder only walks downwards, and the session
//     coordinator latches the reached rung so later adapters in the same
//     session start there instead of re-trying a higher rung (no oscillation).
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

        /**
         * Ordered production ladder, highest proven-safe quality first. `none`
         * is implicit after the last entry. mediapipe_gpu is intentionally
         * absent — see the file header for the physical-crash rationale.
         */
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

    /**
     * First rung to try for a fresh adapter (no session latch). CPU is
     * preferred whenever the bundled model asset exists; whether the device
     * actually supports the CPU delegate is proven only by opening it, so a
     * device that can't run MediaPipe CPU simply falls through to mlkit via
     * the adapter's ordinary open-failure ladder walk. mediapipe_gpu is never
     * returned here — see the file header for why GPU is not a production rung.
     */
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

    /**
     * True when [backendId] is a rung this selector can construct. Always
     * false for mediapipe_gpu: it is not a production rung (see file header),
     * so no production session may construct or open it through this selector.
     */
    fun supports(backendId: String): Boolean = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_GPU -> false
        DuetSegmentationBackend.MEDIAPIPE_CPU -> context != null
        DuetSegmentationBackend.MLKIT         -> true
        else                                  -> false
    }

    /**
     * Constructs (but does not open) the backend for [backendId].
     * Throws IllegalArgumentException for unsupported ids. mediapipe_gpu is
     * kept here only as a latent/experimental construction path for manual
     * investigation; [supports] returns false for it, so the adapter's
     * production ladder walk never calls this branch.
     */
    fun createBackend(backendId: String): AndroidDuetSegmentationBackend = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_GPU -> {
            val ctx = context
                ?: throw IllegalArgumentException("MediaPipe backend requires a Context")
            AndroidDuetMediaPipeSegmentationBackend.gpu(ctx.applicationContext ?: ctx, MODEL_ASSET_PATH)
        }
        DuetSegmentationBackend.MEDIAPIPE_CPU -> {
            val ctx = context
                ?: throw IllegalArgumentException("MediaPipe backend requires a Context")
            AndroidDuetMediaPipeSegmentationBackend.cpu(ctx.applicationContext ?: ctx, MODEL_ASSET_PATH)
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
