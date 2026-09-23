package com.connects.vanguard_media_engine.duet

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

// -----------------------------------------------------------------------------
// ANDROID-DUET-GSD-08: Time-domain WSOLA (Waveform Similarity Overlap-Add)
// time-stretcher for the Duet live segment recorder's mono 16-bit mic PCM.
// -----------------------------------------------------------------------------
//
// Consumes input PCM16 mono samples incrementally via [process] and returns
// however many pitch-preserved output samples are ready; [flush] drains the
// remainder at end-of-stream, zero-padding the final analysis window if the
// buffered input runs out mid-window. Over a whole take, the total emitted
// output sample count approximates inputSamples * [speedMultiplier] (output
// duration matches [AndroidDuetSegmentRecorder]'s video PTS policy of
// `T_out = speedMultiplier * T_wall`).
//
// Algorithm: fixed WINDOW=1024 / SYNTHESIS_HOP=512 (50% overlap, exact COLA
// with a periodic Hann window) Hann-windowed overlap-add at the synthesis
// side; the analysis (input read) position advances by SYNTHESIS_HOP /
// speedMultiplier per frame and is nudged by up to +/-SEARCH_RADIUS samples
// per frame — chosen by an AMDF/SAD similarity search against the previous
// frame's raw tail — to keep the waveform continuous across the splice and
// avoid phase-cancellation artifacts.
//
// Not thread-safe: one instance is owned by one take's audio thread
// (AndroidDuetSegmentRecorder.runAudioLoop) for that take's lifetime only.
class AndroidDuetWsolaFilter(speedMultiplier: Double) {

    companion object {
        private const val WINDOW = 1024
        private const val SYNTHESIS_HOP = 512
        private const val OVERLAP = WINDOW - SYNTHESIS_HOP
        private const val SEARCH_RADIUS = 256

        /** Below this many samples of buffer growth, don't bother compacting yet. */
        private const val COMPACT_THRESHOLD = 8_192

        /** Periodic (DFT-even) Hann window: exact unity-gain COLA at 50% overlap. */
        private val HANN = FloatArray(WINDOW) { i -> (0.5 - 0.5 * cos(2.0 * PI * i / WINDOW)).toFloat() }
    }

    // Floored at 1.0 sample/frame so a pathological speed can never stall the
    // analysis position (which would otherwise spin flush()'s drain loop forever).
    private val analysisHop: Double =
        (SYNTHESIS_HOP / (if (speedMultiplier.isFinite() && speedMultiplier > 0.0) speedMultiplier else 1.0))
            .coerceAtLeast(1.0)

    // -- Growable/compacting input buffer (bulk-copied; never grown per-sample) ------
    private var inBuf = ShortArray(16_384)
    private var inLen = 0
    private var inBase = 0L

    /** Absolute count of real (non-padded) samples ever appended via [process]. */
    private var totalRealAppended = 0L

    private var analysisPosD = 0.0
    private var haveFirstFrame = false

    /** Sliding OLA accumulator; always WINDOW long, shifted left by SYNTHESIS_HOP per frame. */
    private val acc = FloatArray(WINDOW)

    /** Raw (unwindowed) tail of the last chosen analysis window, for the next similarity search. */
    private val prevTail = FloatArray(OVERLAP)

    // -- Reused output scratch (grown, not reallocated per sample) -------------------
    private var outBuf = ShortArray(4_096)
    private var outLen = 0

    /** Appends [count] input samples from [pcm] and returns whatever transformed output is now ready. */
    fun process(pcm: ShortArray, count: Int): ShortArray {
        appendInput(pcm, count)
        outLen = 0
        while (tryProduceFrame(allowPad = false)) { /* keep draining ready frames */ }
        compact()
        return outBuf.copyOf(outLen)
    }

    /**
     * Signals end-of-input: drains every remaining real sample (zero-padding
     * the final analysis window if it runs past the buffered input) plus the
     * last window's un-overlapped OLA tail, then returns the whole remainder.
     */
    fun flush(): ShortArray {
        outLen = 0
        while (true) {
            val nominalAbs = if (haveFirstFrame) analysisPosD.roundToLong() else 0L
            if (nominalAbs >= totalRealAppended) break
            if (!tryProduceFrame(allowPad = true)) break
        }
        if (haveFirstFrame) {
            // Only one window ever contributed to this tail (natural fade-out).
            appendOutput(acc, 0, OVERLAP)
        }
        return outBuf.copyOf(outLen)
    }

    // -- Input buffer -----------------------------------------------------------------

    private fun appendInput(pcm: ShortArray, count: Int) {
        if (count <= 0) return
        ensureInCapacity(inLen + count)
        System.arraycopy(pcm, 0, inBuf, inLen, count)
        inLen += count
        totalRealAppended += count
    }

    private fun ensureInCapacity(needed: Int) {
        if (needed <= inBuf.size) return
        var newSize = inBuf.size * 2
        while (newSize < needed) newSize *= 2
        inBuf = inBuf.copyOf(newSize)
    }

    /** Zero-pads [inBuf] up to local length `uptoAbs - inBase` (EOS-only helper). */
    private fun padInputTo(uptoAbs: Long) {
        val uptoLocal = (uptoAbs - inBase).toInt()
        if (uptoLocal <= inLen) return
        ensureInCapacity(uptoLocal)
        for (i in inLen until uptoLocal) inBuf[i] = 0
        inLen = uptoLocal
    }

    /** Drops already-consumed prefix once it grows past [COMPACT_THRESHOLD]; keeps the search margin intact. */
    private fun compact() {
        val safeAbs = analysisPosD.roundToLong() - SEARCH_RADIUS - 1
        val dropAbs = min(safeAbs, inBase + inLen) - inBase
        if (dropAbs < COMPACT_THRESHOLD) return
        val drop = dropAbs.toInt().coerceIn(0, inLen)
        if (drop <= 0) return
        System.arraycopy(inBuf, drop, inBuf, 0, inLen - drop)
        inLen -= drop
        inBase += drop
    }

    // -- Output scratch -----------------------------------------------------------------

    private fun ensureOutCapacity(needed: Int) {
        if (needed <= outBuf.size) return
        var newSize = outBuf.size * 2
        while (newSize < needed) newSize *= 2
        outBuf = outBuf.copyOf(newSize)
    }

    private fun appendOutput(src: FloatArray, offset: Int, length: Int) {
        if (length <= 0) return
        ensureOutCapacity(outLen + length)
        var i = 0
        while (i < length) {
            val v = src[offset + i]
            outBuf[outLen + i] = when {
                v >= Short.MAX_VALUE.toFloat() -> Short.MAX_VALUE
                v <= Short.MIN_VALUE.toFloat() -> Short.MIN_VALUE
                else -> v.toInt().toShort()
            }
            i++
        }
        outLen += length
    }

    // -- WSOLA core ------------------------------------------------------------------

    /** Attempts to produce exactly one synthesis frame; false means "wait for more input" (or, at EOS, "nothing left"). */
    private fun tryProduceFrame(allowPad: Boolean): Boolean {
        val nominalAbs = if (haveFirstFrame) analysisPosD.roundToLong() else 0L
        var availableAbsEnd = inBase + inLen

        if (!haveFirstFrame) {
            if (nominalAbs + WINDOW > availableAbsEnd) {
                if (!allowPad) return false
                padInputTo(nominalAbs + WINDOW)
            }
            if (totalRealAppended == 0L) return false
            emitFrame(nominalAbs)
            return true
        }

        if (nominalAbs >= availableAbsEnd) return false

        var searchMaxStart = availableAbsEnd - WINDOW
        if (nominalAbs > searchMaxStart) {
            if (!allowPad) return false
            padInputTo(nominalAbs + SEARCH_RADIUS + WINDOW)
            availableAbsEnd = inBase + inLen
            searchMaxStart = availableAbsEnd - WINDOW
        }

        val loBound = max(inBase, nominalAbs - SEARCH_RADIUS)
        val hiBound = min(searchMaxStart, nominalAbs + SEARCH_RADIUS)
        var bestStart = nominalAbs.coerceIn(loBound, max(loBound, hiBound))
        if (hiBound >= loBound) {
            var bestScore = Long.MAX_VALUE
            var c = loBound
            while (c <= hiBound) {
                val local = (c - inBase).toInt()
                var score = 0L
                var j = 0
                while (j < OVERLAP) {
                    score += abs(inBuf[local + j].toInt() - prevTail[j].toInt())
                    j++
                }
                if (score < bestScore) {
                    bestScore = score
                    bestStart = c
                }
                c++
            }
        }
        emitFrame(bestStart)
        return true
    }

    /** Windows+OLA-accumulates the WINDOW-length segment at [startAbs], emits its ready hop, advances analysis position. */
    private fun emitFrame(startAbs: Long) {
        val local = (startAbs - inBase).toInt()
        var j = 0
        while (j < WINDOW) {
            acc[j] += inBuf[local + j] * HANN[j]
            j++
        }
        j = 0
        while (j < OVERLAP) {
            prevTail[j] = inBuf[local + SYNTHESIS_HOP + j].toFloat()
            j++
        }
        haveFirstFrame = true
        appendOutput(acc, 0, SYNTHESIS_HOP)
        System.arraycopy(acc, SYNTHESIS_HOP, acc, 0, OVERLAP)
        acc.fill(0f, OVERLAP, WINDOW)
        analysisPosD += analysisHop
    }
}
