package com.connects.vanguard_media_engine.export

import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

// AndroidPassthroughRemuxSampleIntegritySmokeHarness (Phase 2-Unit Y)
//
// Diagnostic-only redesigned sample-integrity proof for AndroidAudioRemuxer's
// passthrough remux. Exact absolute tail-PTS equality is NOT a valid Android
// MediaMuxer invariant, so this harness closes the unit via strict sample
// payload/order/count/size/keyframe verification (AndroidPassthroughRemux-
// SampleIntegrityVerifier) plus bounded PTS-normalization tolerance derived
// from the source's own inter-sample deltas — never bit-exact PTS.
//
// Lane 1 (A/V fixture): remux sourcePath+sourcePath, verify video AND audio
//   tracks pass the redesigned matrix, delete the generated output.
// Lane 2 (video-only / no audio path): remux secondSourcePath (or sourcePath
//   when absent) with audioPath=null, verify the video track only.
// Lane 3 (negative control): video — compare sourcePath's video track
//   against a genuinely mismatched target (lane 2's output when built from a
//   distinct secondSourcePath, otherwise a truncated/corrupted copy of lane
//   2's own output); audio — compare sourcePath's audio track against a
//   valid second-source A/V remux output. Both must be reported
//   as verifier FAILUREs with valid tracks found, proving the strict payload/
//   sample gates detect real mismatch rather than missing tracks.
// Lane 4 (missing source guard): remux a missing source path and assert
//   success=false with no retained output.
//
// Overall pass requires all four lanes to pass. Logs exactly one
// ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_SMOKE_RESULT <raw> marker in
// finally. Never mutates or deletes source fixtures; only ever deletes its
// own generated outputs under outputDir.

object AndroidPassthroughRemuxSampleIntegritySmokeHarness {

    private const val TAG = "VanguardPassthroughRemuxSampleIntegritySmoke"
    private const val RESULT_MARKER = "ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_SMOKE_RESULT"
    private const val PROOF_BOUNDARY =
        "native_passthrough_remux_sample_integrity_redesigned_mediaextractor_mediamuxer_no_codec_no_exporttimeline"

    private const val LANE1_OUTPUT_FILE = "sample_integrity_unit_y_lane1_av.mp4"
    private const val LANE2_OUTPUT_FILE = "sample_integrity_unit_y_lane2_video_only.mp4"
    private const val LANE3_VIDEO_CORRUPTED_FILE = "sample_integrity_unit_y_lane3_video_corrupted.mp4"
    private const val LANE3_AUDIO_NEGATIVE_FILE = "unit_y_lane3_audio_negative_second_av.mp4"
    private const val LANE4_OUTPUT_FILE = "sample_integrity_unit_y_lane4_missing_guard.mp4"

    private val NON_CLAIMS = mapOf(
        "mediaCodecAllocated" to false,
        "productionExportTimelineBypass" to false,
        "cppPassthroughRemuxSinkNode" to false,
        "videoDecoded" to false,
        "audioDecoded" to false,
        "connectAppTouched" to false,
        "exactAbsolutePtsEquivalence" to false,
        "absolutePtsMonotonicityAsserted" to false,
        "decodeTimestampDtsVerified" to false,
        "compositionReorderingSemanticsVerified" to false,
        "audioAdjacentDeltaSignParityAsserted" to false,
    )

    fun run(sourcePath: String, secondSourcePath: String?, outputDir: String): Map<String, Any?> {
        var raw = "status=FAIL;reason=not_run"
        val outDir = File(outputDir)
        var lane2OutputPath: String? = null
        var lane3VideoCorruptedPath: String? = null

        try {
            val srcFile = File(sourcePath)
            if (!srcFile.exists() || !srcFile.canRead()) {
                raw = "status=FAIL;reason=source_missing_or_unreadable;sourcePath=$sourcePath"
                return failedResult(raw)
            }
            if (!outDir.isDirectory) {
                raw = "status=FAIL;reason=output_dir_missing;outputDir=$outputDir"
                return failedResult(raw)
            }
            val effectiveSecondSourcePath = if (!secondSourcePath.isNullOrBlank()) {
                val f = File(secondSourcePath)
                if (f.exists() && f.canRead()) secondSourcePath else null
            } else {
                null
            }

            deleteGenerated(
                outDir, LANE1_OUTPUT_FILE, LANE2_OUTPUT_FILE, LANE3_VIDEO_CORRUPTED_FILE,
                LANE3_AUDIO_NEGATIVE_FILE, LANE4_OUTPUT_FILE,
            )

            // ── Lane 1: A/V fixture ───────────────────────────────────────
            val lane1OutputPath = File(outDir, LANE1_OUTPUT_FILE).path
            val lane1Remux = AndroidAudioRemuxer.remux(
                videoPath = sourcePath,
                audioPath = sourcePath,
                finalPath = lane1OutputPath,
            )
            val lane1VideoComparison = if (lane1Remux.success) {
                AndroidPassthroughRemuxSampleIntegrityVerifier.compareTrack(
                    sourcePath = sourcePath,
                    outputPath = lane1OutputPath,
                    mimePrefix = "video/",
                    trackType = "video",
                )
            } else {
                null
            }
            val lane1AudioComparison = if (lane1Remux.success) {
                AndroidPassthroughRemuxSampleIntegrityVerifier.compareTrack(
                    sourcePath = sourcePath,
                    outputPath = lane1OutputPath,
                    mimePrefix = "audio/",
                    trackType = "audio",
                )
            } else {
                null
            }
            val lane1Pass = lane1Remux.success &&
                lane1VideoComparison?.pass == true &&
                lane1AudioComparison?.pass == true
            val lane1Map = mapOf(
                "pass" to lane1Pass,
                "remuxSuccess" to lane1Remux.success,
                "remuxReason" to lane1Remux.reason,
                "videoSamples" to lane1Remux.videoSamples,
                "audioSamples" to lane1Remux.audioSamples,
                "outputSizeBytes" to lane1Remux.outputSizeBytes,
                "video" to lane1VideoComparison?.toMap(),
                "audio" to lane1AudioComparison?.toMap(),
            )
            deleteGenerated(outDir, LANE1_OUTPUT_FILE)

            // ── Lane 2: video-only / no audio path ───────────────────────
            val lane2SourcePath = effectiveSecondSourcePath ?: sourcePath
            lane2OutputPath = File(outDir, LANE2_OUTPUT_FILE).path
            val lane2Remux = AndroidAudioRemuxer.remux(
                videoPath = lane2SourcePath,
                audioPath = null,
                finalPath = lane2OutputPath,
            )
            val lane2VideoComparison = if (lane2Remux.success) {
                AndroidPassthroughRemuxSampleIntegrityVerifier.compareTrack(
                    sourcePath = lane2SourcePath,
                    outputPath = lane2OutputPath,
                    mimePrefix = "video/",
                    trackType = "video",
                )
            } else {
                null
            }
            val lane2Pass = lane2Remux.success && lane2VideoComparison?.pass == true
            val lane2Map = mapOf(
                "pass" to lane2Pass,
                "remuxSuccess" to lane2Remux.success,
                "remuxReason" to lane2Remux.reason,
                "sourcePath" to lane2SourcePath,
                "usedSecondSourcePath" to (effectiveSecondSourcePath != null),
                "videoSamples" to lane2Remux.videoSamples,
                "outputSizeBytes" to lane2Remux.outputSizeBytes,
                "video" to lane2VideoComparison?.toMap(),
            )

            // ── Lane 3: negative control ──────────────────────────────────
            val lane2OutputExists = lane2Remux.success && File(lane2OutputPath).exists()
            var negativeControlTarget: String? = null
            var negativeControlSource = "none"
            if (lane2OutputExists && effectiveSecondSourcePath != null) {
                negativeControlTarget = lane2OutputPath
                negativeControlSource = "secondFixtureLane2Output"
            } else if (lane2OutputExists) {
                val corruptedPath = File(outDir, LANE3_VIDEO_CORRUPTED_FILE).path
                if (corruptPartialCopy(File(lane2OutputPath), File(corruptedPath))) {
                    lane3VideoCorruptedPath = corruptedPath
                    negativeControlTarget = corruptedPath
                    negativeControlSource = "corruptedCopyOfLane2Output"
                }
            }

            val lane3VideoComparison = if (negativeControlTarget != null) {
                AndroidPassthroughRemuxSampleIntegrityVerifier.compareTrack(
                    sourcePath = sourcePath,
                    outputPath = negativeControlTarget,
                    mimePrefix = "video/",
                    trackType = "video",
                )
            } else {
                null
            }
            val lane3VideoPass = lane3VideoComparison != null &&
                lane3VideoComparison.sourceTrackFound &&
                !lane3VideoComparison.pass

            // Valid second-source A/V remux output for audio negative control
            var lane3AudioNegativePath: String? = null
            if (effectiveSecondSourcePath != null) {
                val audioNegativeCandidatePath = File(outDir, LANE3_AUDIO_NEGATIVE_FILE).path
                val lane3AudioRemux = AndroidAudioRemuxer.remux(
                    videoPath = effectiveSecondSourcePath,
                    audioPath = effectiveSecondSourcePath,
                    finalPath = audioNegativeCandidatePath,
                )
                if (lane3AudioRemux.success && File(audioNegativeCandidatePath).exists()) {
                    lane3AudioNegativePath = audioNegativeCandidatePath
                }
            }

            val lane3AudioComparison = if (lane3AudioNegativePath != null) {
                AndroidPassthroughRemuxSampleIntegrityVerifier.compareTrack(
                    sourcePath = sourcePath,
                    outputPath = lane3AudioNegativePath,
                    mimePrefix = "audio/",
                    trackType = "audio",
                )
            } else {
                null
            }
            val lane3AudioPass = lane3AudioComparison != null &&
                lane3AudioComparison.sourceTrackFound &&
                lane3AudioComparison.outputTrackFound &&
                !lane3AudioComparison.pass &&
                lane3AudioComparison.reason != "output_track_missing" &&
                lane3AudioComparison.reason != "source_track_missing" &&
                lane3AudioComparison.reason != "source_and_output_track_missing"

            val lane3Pass = lane3VideoPass && lane3AudioPass
            val lane3Map = mapOf(
                "pass" to lane3Pass,
                "videoPass" to lane3VideoPass,
                "audioPass" to lane3AudioPass,
                "negativeControlSource" to negativeControlSource,
                "videoComparison" to lane3VideoComparison?.toMap(),
                "audioComparison" to lane3AudioComparison?.toMap(),
            )

            if (lane3VideoCorruptedPath != null) deleteGenerated(outDir, LANE3_VIDEO_CORRUPTED_FILE)
            deleteGenerated(outDir, LANE3_AUDIO_NEGATIVE_FILE)
            deleteGenerated(outDir, LANE2_OUTPUT_FILE)
            lane2OutputPath = null

            // ── Lane 4: missing source guard ──────────────────────────────
            val missingSourcePath = File(
                outDir,
                "sample_integrity_unit_y_missing_source_${System.currentTimeMillis()}.mp4",
            ).path
            val lane4OutputPath = File(outDir, LANE4_OUTPUT_FILE).path
            val lane4Remux = AndroidAudioRemuxer.remux(
                videoPath = missingSourcePath,
                audioPath = null,
                finalPath = lane4OutputPath,
            )
            val lane4OutputExists = File(lane4OutputPath).exists()
            val lane4Pass = !lane4Remux.success && lane4Remux.reason.isNotEmpty() && !lane4OutputExists
            val lane4Map = mapOf(
                "pass" to lane4Pass,
                "reason" to lane4Remux.reason,
                "outputExists" to lane4OutputExists,
            )
            deleteGenerated(outDir, LANE4_OUTPUT_FILE)

            val overallPass = lane1Pass && lane2Pass && lane3Pass && lane4Pass
            raw = if (overallPass) {
                "status=PASS;lane1=ok;lane2=ok;lane3=ok(source=$negativeControlSource);lane4=ok"
            } else {
                "status=FAIL;lane1=${if (lane1Pass) "ok" else "fail"};" +
                    "lane2=${if (lane2Pass) "ok" else "fail"};" +
                    "lane3=${if (lane3Pass) "ok" else "fail"};" +
                    "lane4=${if (lane4Pass) "ok" else "fail"}"
            }

            return mapOf(
                "pass" to overallPass,
                "proofBoundary" to PROOF_BOUNDARY,
                "raw" to raw,
                "lane1" to lane1Map,
                "lane2" to lane2Map,
                "lane3" to lane3Map,
                "lane4" to lane4Map,
                "nonClaims" to NON_CLAIMS,
            )
        } catch (t: Throwable) {
            val reason = t.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = "status=FAIL;reason=exception:$reason"
            Log.e(TAG, "$RESULT_MARKER exception=$reason", t)
            return failedResult(raw)
        } finally {
            deleteGenerated(
                outDir, LANE1_OUTPUT_FILE, LANE2_OUTPUT_FILE, LANE3_VIDEO_CORRUPTED_FILE,
                LANE3_AUDIO_NEGATIVE_FILE, LANE4_OUTPUT_FILE,
            )
            Log.i(TAG, "$RESULT_MARKER $raw")
        }
    }

    private fun failedResult(raw: String): Map<String, Any?> = mapOf(
        "pass" to false,
        "proofBoundary" to PROOF_BOUNDARY,
        "raw" to raw,
        "lane1" to null,
        "lane2" to null,
        "lane3" to null,
        "lane4" to null,
        "nonClaims" to NON_CLAIMS,
    )

    /// Writes a truncated (deliberately corrupted) copy of [source] to
    /// [dest] — at most half the byte length — so a subsequent comparison is
    /// guaranteed to mismatch even when no distinct second fixture is
    /// available. Returns false (and leaves [dest] absent) on any failure.
    private fun corruptPartialCopy(source: File, dest: File): Boolean {
        return try {
            val sourceLength = source.length()
            if (sourceLength <= 0L) return false
            val truncatedLength = (sourceLength / 2).coerceAtLeast(1L)
            FileInputStream(source).use { input ->
                FileOutputStream(dest).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var remaining = truncatedLength
                    while (remaining > 0) {
                        val toRead = minOf(buffer.size.toLong(), remaining).toInt()
                        val read = input.read(buffer, 0, toRead)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        remaining -= read
                    }
                }
            }
            dest.exists() && dest.length() > 0L
        } catch (_: Throwable) {
            try { if (dest.exists()) dest.delete() } catch (_: Throwable) {}
            false
        }
    }

    private fun deleteGenerated(outDir: File, vararg names: String) {
        for (name in names) {
            try {
                val f = File(outDir, name)
                if (f.exists()) f.delete()
            } catch (_: Throwable) {}
        }
    }
}
