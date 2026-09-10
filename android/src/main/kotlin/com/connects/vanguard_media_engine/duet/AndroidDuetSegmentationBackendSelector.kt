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
//   - raw_tflite_gpu is in EXTENDED_LADDER before mediapipe_cpu so that a
//     session explicitly started on it (via debugSegmentationBackend) degrades
//     to CPU on failure. It is NEVER in the default production primary path:
//     [supports] returns true only when context != null AND the Android asset is
//     readable; [primaryBackendId] never returns it.
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
         * Asset-relative path of the bundled raw TFLite multiclass selfie model.
         * Used by the raw_tflite_gpu backend (debug/smoke opt-in only).
         */
        const val TFLITE_GPU_MODEL_ASSET_PATH = "selfie_multiclass_256x256.tflite"

        /**
         * Ordered production ladder, highest proven-safe quality first. `none`
         * is implicit after the last entry. mediapipe_gpu is intentionally
         * absent — see the file header for the physical-crash rationale.
         * raw_tflite_gpu is also absent here; it is only in EXTENDED_LADDER.
         */
        val LADDER: List<String> = listOf(
            DuetSegmentationBackend.MEDIAPIPE_CPU,
            DuetSegmentationBackend.MLKIT,
        )

        /**
         * Extended ladder including [DuetSegmentationBackend.RAW_TFLITE_GPU]
         * before MEDIAPIPE_CPU. Used only when a session explicitly opts in to
         * raw_tflite_gpu via `debugSegmentationBackend`. Degradation follows:
         * raw_tflite_gpu -> mediapipe_cpu -> mlkit -> none (safe PiP).
         */
        val EXTENDED_LADDER: List<String> = listOf(
            DuetSegmentationBackend.RAW_TFLITE_GPU,
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
     * True when the raw TFLite multiclass model asset is readable from the
     * app's merged assets. Checked lazily; used by [supports] for raw_tflite_gpu.
     */
    val isTfliteGpuModelBundled: Boolean by lazy {
        val ctx = context ?: return@lazy false
        try {
            ctx.assets.open(TFLITE_GPU_MODEL_ASSET_PATH).use { }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "TFLite GPU model asset '$TFLITE_GPU_MODEL_ASSET_PATH' not readable " +
                "(${t.message}); raw_tflite_gpu unsupported")
            false
        }
    }

    /**
     * First rung to try for a fresh adapter (no session latch). CPU is
     * preferred whenever the bundled model asset exists; whether the device
     * actually supports the CPU delegate is proven only by opening it, so a
     * device that can't run MediaPipe CPU simply falls through to mlkit via
     * the adapter's ordinary open-failure ladder walk. raw_tflite_gpu and
     * mediapipe_gpu are never returned here — see the file header.
     */
    fun primaryBackendId(): String =
        if (context != null && isMediaPipeModelBundled) DuetSegmentationBackend.MEDIAPIPE_CPU
        else DuetSegmentationBackend.MLKIT

    /**
     * Next rung below [backendId], or null when [backendId] is the last
     * segmentation rung (terminal -> safe PiP). Searches EXTENDED_LADDER so
     * that raw_tflite_gpu degrades to mediapipe_cpu.
     */
    fun nextBackendId(backendId: String): String? {
        val idx = EXTENDED_LADDER.indexOf(backendId)
        if (idx < 0) return null
        return EXTENDED_LADDER.getOrNull(idx + 1)
    }

    /**
     * True when [backendId] is a rung this selector can construct.
     * - mediapipe_gpu: always false (SIGABRT risk; see file header).
     * - raw_tflite_gpu: true only when context != null AND the Android asset is
     *   readable. Debug/smoke opt-in only; never returned by [primaryBackendId].
     * - mediapipe_cpu: true when context != null.
     * - mlkit: always true.
     */
    fun supports(backendId: String): Boolean = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_GPU  -> false
        DuetSegmentationBackend.RAW_TFLITE_GPU -> context != null && isTfliteGpuModelBundled
        DuetSegmentationBackend.MEDIAPIPE_CPU  -> context != null
        DuetSegmentationBackend.MLKIT          -> true
        else                                   -> false
    }

    /**
     * Constructs (but does not open) the backend for [backendId].
     * Throws IllegalArgumentException for unsupported ids.
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
        DuetSegmentationBackend.RAW_TFLITE_GPU -> {
            val ctx = context
                ?: throw IllegalArgumentException("raw_tflite_gpu backend requires a Context")
            AndroidDuetRawTfliteGpuSegmentationBackend(ctx.applicationContext ?: ctx)
        }
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
