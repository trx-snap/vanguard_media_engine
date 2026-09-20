package com.connects.vanguard_media_engine.greenscreen

import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder

// -----------------------------------------------------------------------------
// VG-GREEN-SCREEN: Deterministic temporal mask smoother between a segmentation
// backend output and a compositor upload.
// -----------------------------------------------------------------------------
//
// Byte-for-byte port of
// `com.connects.vanguard_media_engine.duet.AndroidDuetMaskTemporalSmoother`
// (only the package, class name, and referenced mask-frame/format types
// changed) — GreenScreen segmentation/smoothing is an independent, reusable
// capability and must not be owned by the Duet compositor package. The duet
// class is kept as a source-compatible type alias onto this one.
//
// Owns exactly one previous-output buffer. Every call normalizes the incoming
// mask (either format) to UINT8_ALPHA and either blends it with the previous
// output (steady state) or bypasses blending and stores it as a fresh
// reference (first frame / discontinuity). Never touches the render thread;
// the caller invokes [smooth] from the analysis/backend-completion thread.
//
// [smooth] and [reset] may be invoked from different threads (a backend may
// complete on its own analysis thread, another backend may complete on the
// main thread, and a caller's stop() may call [reset] from the main thread)
// even when a completion is already inside [smooth]. All state access is
// serialized under [lock] so a concurrent [reset] can never observe or leave
// behind partially updated temporal state.

class AndroidGreenScreenMaskTemporalSmoother(
    val currentWeightQ8: Int = DEFAULT_CURRENT_WEIGHT_Q8,
    val maxGapMs: Long = DEFAULT_MAX_GAP_MS,
) {

    companion object {
        private const val TAG = "GreenScreenMaskTemporalSmoother"

        /** Fixed-point (Q8) blend weights approximating current=0.65 / previous=0.35. */
        const val DEFAULT_CURRENT_WEIGHT_Q8 = 166
        const val DEFAULT_MAX_GAP_MS = 250L
    }

    private val effectiveCurrentWeightQ8 = currentWeightQ8.coerceIn(0, 256)
    private val effectivePreviousWeightQ8 = 256 - effectiveCurrentWeightQ8
    private val effectiveMaxGapMs = maxGapMs.coerceAtLeast(0L)

    private val lock = Any()

    // ── State guarded by [lock] ────────────────────────────────────────────────

    /** Pooled previous-output storage; only [0, previousWidth * previousHeight) is valid. */
    private var previousStorage: ByteBuffer? = null
    private var hasPrevious: Boolean = false
    private var previousWidth: Int = -1
    private var previousHeight: Int = -1
    private var previousBackend: String? = null
    private var previousTimestampMs: Long = Long.MIN_VALUE

    /** Pooled scratch buffer for FLOAT32_CONFIDENCE -> UINT8_ALPHA conversion. */
    private var conversionScratch: ByteBuffer? = null

    private var loggedFirst = false

    /** Clears all temporal state; the next [smooth] call will bypass blending. */
    fun reset() {
        synchronized(lock) { resetLocked() }
    }

    private fun resetLocked() {
        hasPrevious = false
        previousWidth = -1
        previousHeight = -1
        previousBackend = null
        previousTimestampMs = Long.MIN_VALUE
    }

    /**
     * Normalizes [frame] to UINT8_ALPHA and blends it with the previous output
     * when the sequence is continuous. Falls back to returning [frame]
     * unmodified (after resetting state) if it cannot be safely normalized.
     * Never throws.
     */
    fun smooth(frame: AndroidGreenScreenSegmentationFrame): AndroidGreenScreenSegmentationFrame {
        return try {
            synchronized(lock) { smoothInternal(frame) }
        } catch (t: Throwable) {
            Log.w(TAG, "smooth() threw, resetting temporal state: ${t.message}")
            reset()
            frame
        }
    }

    /** Must be called with [lock] held. */
    private fun smoothInternal(frame: AndroidGreenScreenSegmentationFrame): AndroidGreenScreenSegmentationFrame {
        if (frame.width <= 0 || frame.height <= 0) {
            resetLocked()
            return frame
        }
        val pixelCount = frame.width * frame.height

        val normalized = normalizeToUint8(frame, pixelCount) ?: run {
            resetLocked()
            return frame
        }

        val continuous = hasPrevious &&
            (previousStorage?.capacity() ?: 0) >= pixelCount &&
            previousWidth == frame.width &&
            previousHeight == frame.height &&
            previousBackend == frame.backend &&
            frame.timestampMs > previousTimestampMs &&
            (frame.timestampMs - previousTimestampMs) <= effectiveMaxGapMs

        // Adopted by the returned frame; must stay a fresh, uniquely-owned
        // allocation on every call (never pooled, never aliased with
        // [previousStorage] or [conversionScratch]).
        val output = ByteBuffer.allocateDirect(pixelCount)
        if (continuous) {
            val previous = previousStorage!!
            for (i in 0 until pixelCount) {
                val cur = normalized.get(i).toInt() and 0xFF
                val old = previous.get(i).toInt() and 0xFF
                val blended = (cur * effectiveCurrentWeightQ8 + old * effectivePreviousWeightQ8) shr 8
                output.put(i, blended.toByte())
            }
        } else {
            for (i in 0 until pixelCount) {
                output.put(i, normalized.get(i))
            }
        }
        output.rewind()

        val stored = ensureCapacity(previousStorage, pixelCount)
        for (i in 0 until pixelCount) {
            stored.put(i, output.get(i))
        }
        previousStorage = stored
        hasPrevious = true
        previousWidth = frame.width
        previousHeight = frame.height
        previousBackend = frame.backend
        previousTimestampMs = frame.timestampMs

        if (!loggedFirst) {
            loggedFirst = true
            val weightFloat = String.format(java.util.Locale.US, "%.2f", effectiveCurrentWeightQ8.toFloat() / 256f)
            Log.i(
                TAG,
                "ANDROID_DUET_GREENSCREEN_TEMPORAL_SMOOTHING_FIRST width=${frame.width} " +
                    "height=${frame.height} backend=${frame.backend} format=uint8_alpha " +
                    "currentWeight=$weightFloat maxGapMs=$effectiveMaxGapMs",
            )
        }

        return AndroidGreenScreenSegmentationFrame.adoptOwned(
            output,
            frame.width,
            frame.height,
            frame.timestampMs,
            frame.backend,
            GreenScreenSegmentationMaskFormat.UINT8_ALPHA,
        )
    }

    /**
     * Returns a UINT8_ALPHA view/copy of [frame]'s mask ([pixelCount] bytes,
     * position 0), or null when the buffer cannot hold a complete mask. Never
     * mutates [frame.maskBytes]'s position/limit. The FLOAT32_CONFIDENCE path
     * converts into the pooled [conversionScratch] buffer rather than
     * allocating a fresh one each call. Must be called with [lock] held.
     */
    private fun normalizeToUint8(frame: AndroidGreenScreenSegmentationFrame, pixelCount: Int): ByteBuffer? {
        return when (frame.format) {
            GreenScreenSegmentationMaskFormat.UINT8_ALPHA -> {
                val source = frame.maskBytes
                if (source.capacity() < pixelCount) return null
                source.duplicate().apply { rewind() }
            }
            GreenScreenSegmentationMaskFormat.FLOAT32_CONFIDENCE -> {
                val source = frame.maskBytes
                if (source.capacity() < pixelCount.toLong() * 4L) return null
                val floats = source.duplicate().order(ByteOrder.nativeOrder()).asFloatBuffer()
                floats.rewind()
                if (floats.remaining() < pixelCount) return null
                val converted = ensureCapacity(conversionScratch, pixelCount)
                for (i in 0 until pixelCount) {
                    val f = floats.get(i)
                    val clamped = if (f.isNaN()) 0f else f.coerceIn(0f, 1f)
                    converted.put(i, (clamped * 255f).toInt().toByte())
                }
                converted.rewind()
                conversionScratch = converted
                converted
            }
        }
    }

    /** Returns [existing] if it already holds [requiredCapacity] bytes, else a fresh direct buffer. */
    private fun ensureCapacity(existing: ByteBuffer?, requiredCapacity: Int): ByteBuffer {
        if (existing != null && existing.capacity() >= requiredCapacity) return existing
        return ByteBuffer.allocateDirect(requiredCapacity)
    }
}
