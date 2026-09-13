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
//   - raw_tflite_gpu is in the debug ladder before mediapipe_cpu so that a
//     session explicitly started on it (via debugSegmentationBackend) degrades
//     to CPU on failure. It is NEVER in the default production primary path.
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
    /**
     * Debug-only GPU delegate mode for [DuetSegmentationBackend.RAW_TFLITE_GPU].
     * Validated against the backend's allowlist by [AndroidDuetSessionCoordinator]
     * before this selector is constructed. `null` → backend default
     * (`compat_best_or_default`). Ignored for all other backends.
     */
    private val rawGpuDelegateMode: String? = null,
    /**
     * Debug-only model asset path for [DuetSegmentationBackend.RAW_TFLITE_GPU].
     * Must be a member of [RAW_TFLITE_GPU_MODEL_ALLOWLIST]; validated by
     * [AndroidDuetSessionCoordinator] before the selector is constructed.
     * `null` → default ([TFLITE_GPU_MODEL_ASSET_PATH]). Ignored for all other backends.
     */
    private val rawGpuModelAssetPath: String? = null,
    /**
     * Debug-only model asset path for [DuetSegmentationBackend.MEDIAPIPE_CPU].
     * Must be allowlisted by [MEDIAPIPE_MODEL_ALLOWLIST] before it reaches this
     * selector. `null` keeps the production default [MODEL_ASSET_PATH].
     */
    private val mediaPipeCpuModelAssetPath: String? = null,
) {

    /** Context this selector was constructed with, exposed so the adapter can build its adaptive-quality policy. */
    val hostContext: Context? get() = context

    companion object {
        private const val TAG = "DuetSegSelector"

        /**
         * Asset-relative path of the bundled MediaPipe selfie segmenter model
         * used by the production CPU rung.
         *
         * SM A566B physical evidence: the landscape variant sustained 651 masks
         * over 44.077s with no skips/failures/degrade and nominal thermal state,
         * outperforming the previous `selfie_segmenter.tflite` baseline.
         */
        const val MODEL_ASSET_PATH = "selfie_segmentation_landscape.tflite"

        /**
         * Allowlist of asset-relative model paths accepted by the debug-only
         * MediaPipe CPU model override.
         */
        val MEDIAPIPE_MODEL_ALLOWLIST: Set<String> = setOf(
            MODEL_ASSET_PATH,
            "selfie_segmentation.tflite",
            "selfie_segmentation_landscape.tflite",
        )

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
         * Extended ladder including the debug opt-in [DuetSegmentationBackend.RAW_TFLITE_GPU]
         * rung before MEDIAPIPE_CPU. Runtime [nextBackendId] special-cases RAW_TFLITE_GPU
         * so it degrades directly to mediapipe_cpu.
         */
        val EXTENDED_LADDER: List<String> = listOf(
            DuetSegmentationBackend.RAW_TFLITE_GPU,
            DuetSegmentationBackend.MEDIAPIPE_CPU,
            DuetSegmentationBackend.MLKIT,
        )

        /**
         * Allowlist of asset-relative model paths accepted by the raw_tflite_gpu
         * debug backend. Validated by [AndroidDuetSessionCoordinator] before the
         * selector is constructed; invalid paths fall back to [TFLITE_GPU_MODEL_ASSET_PATH].
         * [MODEL_ASSET_PATH] is included as an opt-in degrade/negative lane; if
         * the raw interpreter cannot open it due to a custom op, the existing
         * adapter open-failure fallback handles degradation.
         */
        val RAW_TFLITE_GPU_MODEL_ALLOWLIST: Set<String> = setOf(
            TFLITE_GPU_MODEL_ASSET_PATH,
            MODEL_ASSET_PATH,
            "selfie_segmenter.tflite",
            "selfie_segmentation.tflite",
            "selfie_segmentation_landscape.tflite",
        )
    }

    /**
     * True when the MediaPipe model asset can be opened from the app's merged
     * assets. Evaluated once per selector; a missing asset makes ML Kit the
     * primary rung without any event (there is nothing to degrade from).
     */
    val isMediaPipeModelBundled: Boolean by lazy {
        val ctx = context ?: return@lazy false
        val assetPath = mediaPipeCpuModelAssetPath ?: MODEL_ASSET_PATH
        try {
            ctx.assets.open(assetPath).use { }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "MediaPipe model asset '$assetPath' not readable (${t.message}); " +
                "starting ladder at ${DuetSegmentationBackend.MLKIT}")
            false
        }
    }

    /**
     * True when the raw TFLite model asset to use is readable from the app's
     * merged assets. Checks [rawGpuModelAssetPath] if provided and allowlisted,
     * otherwise falls back to [TFLITE_GPU_MODEL_ASSET_PATH].
     * Checked lazily; used by [supports] for raw_tflite_gpu.
     */
    val isTfliteGpuModelBundled: Boolean by lazy {
        val ctx = context ?: return@lazy false
        val assetPath = rawGpuModelAssetPath ?: TFLITE_GPU_MODEL_ASSET_PATH
        try {
            ctx.assets.open(assetPath).use { }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "TFLite GPU model asset '$assetPath' not readable " +
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
     * segmentation rung (terminal -> safe PiP). The [DuetSegmentationBackend.RAW_TFLITE_GPU]
     * debug rung degrades directly to mediapipe_cpu.
     */
    fun nextBackendId(backendId: String): String? {
        if (backendId == DuetSegmentationBackend.RAW_TFLITE_GPU) {
            return DuetSegmentationBackend.MEDIAPIPE_CPU
        }
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
     *
     * For [DuetSegmentationBackend.RAW_TFLITE_GPU], the delegate mode and model
     * asset path are taken from [rawGpuDelegateMode] and [rawGpuModelAssetPath]
     * stored at selector construction time (both validated by
     * [AndroidDuetSessionCoordinator]). All other backends ignore them.
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
            AndroidDuetMediaPipeSegmentationBackend.cpu(
                ctx.applicationContext ?: ctx,
                mediaPipeCpuModelAssetPath ?: MODEL_ASSET_PATH,
            )
        }
        DuetSegmentationBackend.MLKIT -> AndroidDuetMlKitSegmentationBackend()
        DuetSegmentationBackend.RAW_TFLITE_GPU -> {
            val ctx = context
                ?: throw IllegalArgumentException("raw_tflite_gpu backend requires a Context")
            val mode = rawGpuDelegateMode ?: "compat_best_or_default"
            val modelPath = rawGpuModelAssetPath ?: TFLITE_GPU_MODEL_ASSET_PATH
            AndroidDuetRawTfliteGpuSegmentationBackend(ctx.applicationContext ?: ctx, mode, modelPath)
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
