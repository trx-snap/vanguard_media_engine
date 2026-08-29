package com.connects.vanguard_media_engine.export

import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteBuffer
import java.security.MessageDigest

// ── AndroidPassthroughRemuxSampleIntegrityVerifier (Phase 2-Unit Y) ──────────
//
// Diagnostic-only source-vs-output sample integrity comparator for a single
// MediaExtractor-selected track (first video or first audio track by MIME
// prefix). Exact absolute tail-PTS equality is NOT a valid MediaMuxer
// invariant on Android — MediaMuxer is free to normalize/rebase per-track
// timestamps on write. MediaExtractor sample read order is decode order,
// not presentation order, and sampleTime is a presentation timestamp (PTS);
// B-frame content can therefore have non-monotonic PTS in a fully valid
// sample sequence. Non-decreasing output PTS is only meaningful, and only
// gated, when the source itself is non-decreasing (conditional
// monotonicity) — it is not asserted unconditionally. This verifier
// instead gates on:
//   - strict (track-type-aware): equal sample count, equal SHA-256 payload
//     digest (bytes as returned by readSampleData, in read order), equal
//     ordered sample-size sequence, and equal ordered keyframe-flag
//     sequence always apply. For video (and any non-audio track type),
//     matching source/output PTS ordering parity (adjacent-delta sign
//     sequence) and non-decreasing output PTS whenever source PTS is
//     non-decreasing are also required. For audio, when source PTS is
//     non-decreasing, adjacent-delta sign parity is diagnostic-only rather
//     than strict — AAC encode/remux paths are free to re-quantize
//     adjacent sample spacing without breaking monotonicity, so exact
//     sign-parity at every index is not a reliable passthrough invariant
//     for audio. When source PTS is NOT non-decreasing, audio falls back
//     to the same fail-closed parity-required gate as video.
//   - bounded: |firstPtsDelta|, |lastPtsDelta|, and the max per-index
//     |ptsDelta| between source and output are each <= a tolerance derived
//     from the source's own inter-sample deltas (median positive delta,
//     floored at 1000us).
//
// ptsOrderingParityEqual and its supporting diagnostic fields
// (ptsOrderingParityMismatchCount, ptsOrderingParityFirstMismatchIndex)
// are always computed and reported for every track type, even when the
// strict gate above does not require parity for that track type — they
// remain available as diagnostic signal regardless of gating.
//
// Non-claims: this comparator does NOT assert exact absolute PTS
// equivalence, does NOT assert unconditional absolute PTS monotonicity
// (only conditional, source-gated monotonicity), does NOT verify DTS
// (decode timestamp) or composition/reordering semantics, and — for audio
// specifically, when source PTS is non-decreasing — does NOT assert
// adjacent-delta PTS sign parity as a strict pass/fail condition.
//
// Read-only: only ever opens MediaExtractor instances against existing
// files; never mutates source or output bytes.

private const val COPY_BUFFER_BYTES = 1024 * 1024
private const val DEFAULT_TOLERANCE_US = 1000L

/// Raw per-track sample walk of one file.
private data class TrackSampleWalk(
    val sampleCount: Int,
    val digestHex: String,
    val sampleSizes: List<Int>,
    val keyframeFlags: List<Boolean>,
    val ptsListUs: List<Long>,
    val firstPtsUs: Long,
    val lastPtsUs: Long,
)

/// Structured source-vs-output comparison outcome for one track type.
data class AndroidPassthroughRemuxTrackIntegrityResult(
    val trackType: String,
    val sourceTrackFound: Boolean,
    val outputTrackFound: Boolean,
    val sourceSampleCount: Int,
    val outputSampleCount: Int,
    val sampleCountEqual: Boolean,
    val digestEqual: Boolean,
    val sampleSizeSequenceEqual: Boolean,
    val keyframeSequenceEqual: Boolean,
    val sourcePtsNonDecreasing: Boolean,
    val outputPtsNonDecreasing: Boolean,
    val ptsOrderingParityEqual: Boolean,
    val ptsOrderingParityMismatchCount: Int,
    val ptsOrderingParityFirstMismatchIndex: Int,
    val toleranceUs: Long,
    val firstPtsDeltaUs: Long,
    val lastPtsDeltaUs: Long,
    val maxAbsPtsDeltaUs: Long,
    val muxerTimestampNormalizationObserved: Boolean,
    val strictPass: Boolean,
    val boundedPass: Boolean,
    val pass: Boolean,
    val reason: String,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "trackType" to trackType,
        "sourceTrackFound" to sourceTrackFound,
        "outputTrackFound" to outputTrackFound,
        "sourceSampleCount" to sourceSampleCount,
        "outputSampleCount" to outputSampleCount,
        "sampleCountEqual" to sampleCountEqual,
        "digestEqual" to digestEqual,
        "sampleSizeSequenceEqual" to sampleSizeSequenceEqual,
        "keyframeSequenceEqual" to keyframeSequenceEqual,
        "sourcePtsNonDecreasing" to sourcePtsNonDecreasing,
        "outputPtsNonDecreasing" to outputPtsNonDecreasing,
        "ptsOrderingParityEqual" to ptsOrderingParityEqual,
        "ptsOrderingParityMismatchCount" to ptsOrderingParityMismatchCount,
        "ptsOrderingParityFirstMismatchIndex" to ptsOrderingParityFirstMismatchIndex,
        "toleranceUs" to toleranceUs,
        "firstPtsDeltaUs" to firstPtsDeltaUs,
        "lastPtsDeltaUs" to lastPtsDeltaUs,
        "maxAbsPtsDeltaUs" to maxAbsPtsDeltaUs,
        "muxerTimestampNormalizationObserved" to muxerTimestampNormalizationObserved,
        "strictPass" to strictPass,
        "boundedPass" to boundedPass,
        "pass" to pass,
        "reason" to reason,
    )
}

object AndroidPassthroughRemuxSampleIntegrityVerifier {

    /// Compares the first track whose MIME starts with [mimePrefix] in
    /// [sourcePath] against the same in [outputPath]. Fails closed (pass =
    /// false, non-empty reason) on any exception or missing track.
    fun compareTrack(
        sourcePath: String,
        outputPath: String,
        mimePrefix: String,
        trackType: String,
    ): AndroidPassthroughRemuxTrackIntegrityResult {
        return try {
            val source = walkTrack(sourcePath, mimePrefix)
            val output = walkTrack(outputPath, mimePrefix)

            if (source == null || output == null) {
                val reason = when {
                    source == null && output == null -> "source_and_output_track_missing"
                    source == null -> "source_track_missing"
                    else -> "output_track_missing"
                }
                return failed(trackType, source != null, output != null, source, output, reason)
            }

            val toleranceUs = toleranceFromSourceDeltas(source.ptsListUs)
            val sampleCountEqual = source.sampleCount == output.sampleCount
            val digestEqual = source.digestHex == output.digestHex
            val sampleSizeSequenceEqual = source.sampleSizes == output.sampleSizes
            val keyframeSequenceEqual = source.keyframeFlags == output.keyframeFlags
            val sourcePtsNonDecreasing = isNonDecreasing(source.ptsListUs)
            val outputPtsNonDecreasing = isNonDecreasing(output.ptsListUs)
            val ptsOrderingParityStats = ptsOrderingParityStats(source.ptsListUs, output.ptsListUs)
            val ptsOrderingParityEqual = ptsOrderingParityStats.mismatchCount == 0

            val firstPtsDeltaUs = output.firstPtsUs - source.firstPtsUs
            val lastPtsDeltaUs = output.lastPtsUs - source.lastPtsUs
            val alignedLen = minOf(source.ptsListUs.size, output.ptsListUs.size)
            var maxAbsPtsDeltaUs = 0L
            for (i in 0 until alignedLen) {
                val d = Math.abs(output.ptsListUs[i] - source.ptsListUs[i])
                if (d > maxAbsPtsDeltaUs) maxAbsPtsDeltaUs = d
            }

            val firstPtsWithinTolerance = Math.abs(firstPtsDeltaUs) <= toleranceUs
            val lastPtsWithinTolerance = Math.abs(lastPtsDeltaUs) <= toleranceUs
            val maxAbsWithinTolerance = maxAbsPtsDeltaUs <= toleranceUs

            val payloadGatesPass = sampleCountEqual && digestEqual && sampleSizeSequenceEqual &&
                keyframeSequenceEqual
            val strictPass = when {
                trackType == "audio" && sourcePtsNonDecreasing ->
                    payloadGatesPass && outputPtsNonDecreasing
                else ->
                    payloadGatesPass && ptsOrderingParityEqual &&
                        (!sourcePtsNonDecreasing || outputPtsNonDecreasing)
            }
            val boundedPass = firstPtsWithinTolerance && lastPtsWithinTolerance && maxAbsWithinTolerance
            val pass = strictPass && boundedPass
            val muxerTimestampNormalizationObserved =
                firstPtsDeltaUs != 0L || lastPtsDeltaUs != 0L || maxAbsPtsDeltaUs != 0L

            AndroidPassthroughRemuxTrackIntegrityResult(
                trackType = trackType,
                sourceTrackFound = true,
                outputTrackFound = true,
                sourceSampleCount = source.sampleCount,
                outputSampleCount = output.sampleCount,
                sampleCountEqual = sampleCountEqual,
                digestEqual = digestEqual,
                sampleSizeSequenceEqual = sampleSizeSequenceEqual,
                keyframeSequenceEqual = keyframeSequenceEqual,
                sourcePtsNonDecreasing = sourcePtsNonDecreasing,
                outputPtsNonDecreasing = outputPtsNonDecreasing,
                ptsOrderingParityEqual = ptsOrderingParityEqual,
                ptsOrderingParityMismatchCount = ptsOrderingParityStats.mismatchCount,
                ptsOrderingParityFirstMismatchIndex = ptsOrderingParityStats.firstMismatchIndex,
                toleranceUs = toleranceUs,
                firstPtsDeltaUs = firstPtsDeltaUs,
                lastPtsDeltaUs = lastPtsDeltaUs,
                maxAbsPtsDeltaUs = maxAbsPtsDeltaUs,
                muxerTimestampNormalizationObserved = muxerTimestampNormalizationObserved,
                strictPass = strictPass,
                boundedPass = boundedPass,
                pass = pass,
                reason = if (pass) "success" else "strict_or_bounded_gate_failed",
            )
        } catch (t: Throwable) {
            failed(
                trackType, sourceTrackFound = false, outputTrackFound = false,
                source = null, output = null,
                reason = "exception:${t.javaClass.simpleName}",
            )
        }
    }

    private fun failed(
        trackType: String,
        sourceTrackFound: Boolean,
        outputTrackFound: Boolean,
        source: TrackSampleWalk?,
        output: TrackSampleWalk?,
        reason: String,
    ): AndroidPassthroughRemuxTrackIntegrityResult = AndroidPassthroughRemuxTrackIntegrityResult(
        trackType = trackType,
        sourceTrackFound = sourceTrackFound,
        outputTrackFound = outputTrackFound,
        sourceSampleCount = source?.sampleCount ?: 0,
        outputSampleCount = output?.sampleCount ?: 0,
        sampleCountEqual = false,
        digestEqual = false,
        sampleSizeSequenceEqual = false,
        keyframeSequenceEqual = false,
        sourcePtsNonDecreasing = false,
        outputPtsNonDecreasing = false,
        ptsOrderingParityEqual = false,
        ptsOrderingParityMismatchCount = 0,
        ptsOrderingParityFirstMismatchIndex = -1,
        toleranceUs = DEFAULT_TOLERANCE_US,
        firstPtsDeltaUs = 0L,
        lastPtsDeltaUs = 0L,
        maxAbsPtsDeltaUs = 0L,
        muxerTimestampNormalizationObserved = false,
        strictPass = false,
        boundedPass = false,
        pass = false,
        reason = reason,
    )

    private fun isNonDecreasing(ptsListUs: List<Long>): Boolean {
        for (i in 1 until ptsListUs.size) {
            if (ptsListUs[i] < ptsListUs[i - 1]) return false
        }
        return true
    }

    /// Adjacent-delta sign parity diagnostic stats. [mismatchCount] is the
    /// number of adjacent-index positions where the source and output
    /// sign sequences diverge; [firstMismatchIndex] is the lowest such
    /// index, or -1 when [mismatchCount] is 0.
    private data class PtsOrderingParityStats(
        val mismatchCount: Int,
        val firstMismatchIndex: Int,
    )

    /// Compares the adjacent-delta sign sequence (-1/0/1) of [sourcePtsListUs]
    /// against [outputPtsListUs]. Requires equal-length sequences — differing
    /// sample counts are reported as a single mismatch at index 0 — otherwise
    /// walks every adjacent pair, tolerating non-monotonic (e.g. B-frame) PTS
    /// as long as the output preserves the same ordering shape as the source.
    private fun ptsOrderingParityStats(
        sourcePtsListUs: List<Long>,
        outputPtsListUs: List<Long>,
    ): PtsOrderingParityStats {
        if (sourcePtsListUs.size != outputPtsListUs.size) {
            return PtsOrderingParityStats(mismatchCount = 1, firstMismatchIndex = 0)
        }
        var mismatchCount = 0
        var firstMismatchIndex = -1
        for (i in 1 until sourcePtsListUs.size) {
            val sourceSign = deltaSign(sourcePtsListUs[i] - sourcePtsListUs[i - 1])
            val outputSign = deltaSign(outputPtsListUs[i] - outputPtsListUs[i - 1])
            if (sourceSign != outputSign) {
                mismatchCount++
                if (firstMismatchIndex == -1) firstMismatchIndex = i
            }
        }
        return PtsOrderingParityStats(mismatchCount = mismatchCount, firstMismatchIndex = firstMismatchIndex)
    }

    private fun deltaSign(delta: Long): Int = when {
        delta > 0L -> 1
        delta < 0L -> -1
        else -> 0
    }

    /// toleranceUs = max(1000, median positive inter-sample delta). Falls
    /// back to 1000 when fewer than two samples or no positive delta exists.
    private fun toleranceFromSourceDeltas(ptsListUs: List<Long>): Long {
        if (ptsListUs.size < 2) return DEFAULT_TOLERANCE_US
        val positiveDeltas = mutableListOf<Long>()
        for (i in 1 until ptsListUs.size) {
            val d = ptsListUs[i] - ptsListUs[i - 1]
            if (d > 0) positiveDeltas.add(d)
        }
        if (positiveDeltas.isEmpty()) return DEFAULT_TOLERANCE_US
        positiveDeltas.sort()
        val mid = positiveDeltas.size / 2
        val median = if (positiveDeltas.size % 2 == 0) {
            (positiveDeltas[mid - 1] + positiveDeltas[mid]) / 2
        } else {
            positiveDeltas[mid]
        }
        return maxOf(DEFAULT_TOLERANCE_US, median)
    }

    /// Walks the first track whose MIME starts with [mimePrefix] in the file
    /// at [path]. Returns null when the file cannot be opened or has no
    /// matching track — never throws.
    private fun walkTrack(path: String, mimePrefix: String): TrackSampleWalk? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            var trackIndex = -1
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                if (format.getString(MediaFormat.KEY_MIME)?.startsWith(mimePrefix) == true) {
                    trackIndex = i
                    break
                }
            }
            if (trackIndex < 0) return null
            extractor.selectTrack(trackIndex)

            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteBuffer.allocate(COPY_BUFFER_BYTES)
            val sizes = mutableListOf<Int>()
            val keyframes = mutableListOf<Boolean>()
            val ptsList = mutableListOf<Long>()

            while (true) {
                buffer.clear()
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val pts = extractor.sampleTime.coerceAtLeast(0L)
                val isKeyFrame = (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0
                digest.update(buffer.array(), buffer.arrayOffset(), size)
                sizes.add(size)
                keyframes.add(isKeyFrame)
                ptsList.add(pts)
                extractor.advance()
            }

            TrackSampleWalk(
                sampleCount = sizes.size,
                digestHex = digest.digest().joinToString("") { "%02x".format(it) },
                sampleSizes = sizes,
                keyframeFlags = keyframes,
                ptsListUs = ptsList,
                firstPtsUs = ptsList.firstOrNull() ?: 0L,
                lastPtsUs = ptsList.lastOrNull() ?: 0L,
            )
        } catch (_: Throwable) {
            null
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }
    }
}
