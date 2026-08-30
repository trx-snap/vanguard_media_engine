package com.connects.vanguard_media_engine.diagnostics

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import com.connects.vanguard_media_engine.export.AndroidAudioRemuxResult
import com.connects.vanguard_media_engine.export.AndroidAudioRemuxer
import com.connects.vanguard_media_engine.export.AndroidAudioTrackSpec
import com.connects.vanguard_media_engine.export.AndroidTimelineAudioPass2Muxer
import java.io.File

// ── AndroidAudioDirectCopyFallbackSmokeHarness (Diagnostics only) ─────────────
//
// Diagnostic-only physical proof for AndroidTimelineAudioPass2Muxer's V4.3
// direct-copy failure graceful fallback to PCM mixdown. Copies the caller-
// supplied fixture (expected to carry both video and AAC audio, e.g.
// clip_B.mov) once into an owned "video temp" file and reuses that same file
// as the direct-copy audio source -- matching the production shape where
// AndroidTimelineExportSession's owned pass-1 video temp and the sidecar
// track's source file are independent, but here collapsed into one fixture
// for a lightweight harness.
//
// Four lanes, each exercising [AndroidTimelineAudioPass2Muxer.run] directly:
//   A. eligibleDirectCopySuccess       -- one unity-gain "original" track,
//      eligible for direct copy; asserts the real remux succeeds without any
//      forced failure.
//   B. ineligiblePcmMixdownSuccess     -- one "music"-role track (ineligible),
//      asserts the real PCM mixdown -> AAC encode -> remux path succeeds.
//   C. forcedDirectCopyFailureRecovery -- same eligible track as lane A, but
//      constructed with a [remuxFn] that fails only its first invocation
//      (the direct-copy attempt) and delegates to the real remuxer afterward;
//      asserts the muxer recovers via the PCM mixdown fallback
//      (`recoveredViaMixdown`) rather than surfacing the direct-copy failure.
//   D. noAudioVideoOnlyRemux           -- empty track list, asserts the
//      empty-sidecar video-only remux path succeeds with no audio track.
//
// The harness never mutates or deletes the caller-supplied [sourcePath]; only
// its own generated video-temp copy and per-lane outputs are cleaned up.
object AndroidAudioDirectCopyFallbackSmokeHarness {

    private const val TAG = "VGAudioFallbackSmoke"
    private const val RESULT_MARKER = "ANDROID_AUDIO_DIRECT_COPY_FALLBACK_SMOKE_RESULT"
    private const val VIDEO_TEMP_FILE = "vg_audio_fallback_smoke_video_temp.mov"

    fun run(sourcePath: String, outputDir: String): Map<String, Any?> {
        var raw = "status=FAIL;reason=not_run"
        val videoTempPath = File(outputDir, VIDEO_TEMP_FILE).path
        try {
            val sourceFile = File(sourcePath)
            if (!sourceFile.exists()) {
                raw = "status=FAIL;reason=source_missing;sourcePath=$sourcePath"
                return mapOf("pass" to false, "raw" to raw)
            }
            val outDir = File(outputDir)
            if (!outDir.isDirectory) {
                raw = "status=FAIL;reason=output_dir_missing;outputDir=$outputDir"
                return mapOf("pass" to false, "raw" to raw)
            }

            sourceFile.copyTo(File(videoTempPath), overwrite = true)
            val sourceDurationSec = probeMediaDurationSeconds(videoTempPath)
            if (sourceDurationSec == null || sourceDurationSec < 0.5) {
                raw = "status=FAIL;reason=fixture_duration_invalid;durationSec=$sourceDurationSec"
                return mapOf("pass" to false, "raw" to raw)
            }

            val laneA = runEligibleDirectCopySuccessLane(videoTempPath, outDir, sourceDurationSec)
            val laneB = runIneligiblePcmMixdownSuccessLane(videoTempPath, outDir, sourceDurationSec)
            val laneC = runForcedDirectCopyFailureRecoveryLane(videoTempPath, outDir, sourceDurationSec)
            val videoTempPreservedAfterFallback = File(videoTempPath).exists()
            val laneD = runNoAudioVideoOnlyLane(videoTempPath, outDir)

            val pass = listOf(laneA, laneB, laneC, laneD).all { it["pass"] == true } &&
                videoTempPreservedAfterFallback

            raw = (if (pass) "status=PASS;" else "status=FAIL;") +
                "laneA=${laneA["raw"]};laneB=${laneB["raw"]};laneC=${laneC["raw"]};laneD=${laneD["raw"]};" +
                "videoTempPreserved=$videoTempPreservedAfterFallback"

            return mapOf(
                "pass" to pass,
                "raw" to raw,
                "eligibleDirectCopySuccess" to laneA,
                "ineligiblePcmMixdownSuccess" to laneB,
                "forcedDirectCopyFailureRecovery" to laneC,
                "noAudioVideoOnlyRemux" to laneD,
                "videoTempPreservedAfterFallback" to videoTempPreservedAfterFallback,
            )
        } catch (t: Throwable) {
            val reason = t.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = "status=FAIL;reason=exception:$reason"
            Log.e(TAG, "$RESULT_MARKER exception=$reason", t)
            return mapOf("pass" to false, "raw" to raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER $raw")
            deleteIfExists(videoTempPath)
        }
    }

    // ── Lane A: eligible direct-copy success ─────────────────────────────────

    private fun runEligibleDirectCopySuccessLane(
        videoTempPath: String,
        outDir: File,
        sourceDurationSec: Double,
    ): Map<String, Any?> {
        val finalPath = File(outDir, "lane_a_direct_copy_final.mp4").path
        deleteIfExists(finalPath)

        val spec = AndroidAudioTrackSpec.fromMap(
            eligibleOriginalTrackMap("fallback_smoke_lane_a_original", videoTempPath, sourceDurationSec),
        ) ?: return laneFailure("track_parse_failed", finalPath)

        val muxer = AndroidTimelineAudioPass2Muxer()
        val audioTempPath = File(outDir, "lane_a_audio_temp.m4a").path
        val failureReason = muxer.run(
            specs = listOf(spec),
            videoTempPath = videoTempPath,
            audioTempPath = audioTempPath,
            finalTmpPath = finalPath,
        )
        val (hasVideo, hasAudio) = probeHasVideoAndAudio(finalPath)
        val pass = failureReason == null && hasVideo && hasAudio
        if (!pass) deleteIfExists(finalPath)
        return mapOf(
            "pass" to pass,
            "raw" to laneRaw(pass, failureReason, hasVideo, hasAudio),
            "failureReason" to failureReason,
            "hasVideo" to hasVideo,
            "hasAudio" to hasAudio,
            "outputPath" to finalPath,
        )
    }

    // ── Lane B: ineligible PCM mixdown success ───────────────────────────────

    private fun runIneligiblePcmMixdownSuccessLane(
        videoTempPath: String,
        outDir: File,
        sourceDurationSec: Double,
    ): Map<String, Any?> {
        val finalPath = File(outDir, "lane_b_pcm_mixdown_final.mp4").path
        deleteIfExists(finalPath)

        val trackMap = mapOf(
            "trackId" to "fallback_smoke_lane_b_music",
            "url" to videoTempPath,
            "startTime" to 0.0,
            "duration" to sourceDurationSec,
            "volume" to 1.0,
            "role" to "music",
        )
        val spec = AndroidAudioTrackSpec.fromMap(trackMap)
            ?: return laneFailure("track_parse_failed", finalPath)

        val muxer = AndroidTimelineAudioPass2Muxer()
        val audioTempPath = File(outDir, "lane_b_audio_temp.m4a").path
        val failureReason = muxer.run(
            specs = listOf(spec),
            videoTempPath = videoTempPath,
            audioTempPath = audioTempPath,
            finalTmpPath = finalPath,
        )
        val (hasVideo, hasAudio) = probeHasVideoAndAudio(finalPath)
        val pass = failureReason == null && hasVideo && hasAudio
        if (!pass) deleteIfExists(finalPath)
        return mapOf(
            "pass" to pass,
            "raw" to laneRaw(pass, failureReason, hasVideo, hasAudio),
            "failureReason" to failureReason,
            "hasVideo" to hasVideo,
            "hasAudio" to hasAudio,
            "outputPath" to finalPath,
        )
    }

    // ── Lane C: forced first direct-copy remux failure, recovered via PCM mixdown ──

    private fun runForcedDirectCopyFailureRecoveryLane(
        videoTempPath: String,
        outDir: File,
        sourceDurationSec: Double,
    ): Map<String, Any?> {
        val finalPath = File(outDir, "lane_c_forced_fallback_final.mp4").path
        deleteIfExists(finalPath)

        val spec = AndroidAudioTrackSpec.fromMap(
            eligibleOriginalTrackMap("fallback_smoke_lane_c_original", videoTempPath, sourceDurationSec),
        ) ?: return laneFailure("track_parse_failed", finalPath, extra = mapOf("recoveredViaMixdown" to false))

        var remuxCallCount = 0
        val forcingRemux: (String, String?, String) -> AndroidAudioRemuxResult = { video, audio, out ->
            remuxCallCount++
            if (remuxCallCount == 1) {
                AndroidAudioRemuxResult(
                    success = false,
                    reason = "forced_smoke_direct_copy_failure",
                    videoSamples = 0,
                    audioSamples = 0,
                    outputSizeBytes = 0L,
                )
            } else {
                AndroidAudioRemuxer.remux(video, audio, out)
            }
        }

        val muxer = AndroidTimelineAudioPass2Muxer(remuxFn = forcingRemux)
        val audioTempPath = File(outDir, "lane_c_audio_temp.m4a").path
        val failureReason = muxer.run(
            specs = listOf(spec),
            videoTempPath = videoTempPath,
            audioTempPath = audioTempPath,
            finalTmpPath = finalPath,
        )
        val (hasVideo, hasAudio) = probeHasVideoAndAudio(finalPath)
        // Recovery evidence: the muxer reported overall success, at least a
        // second remux call happened (the mixdown-path final remux, since the
        // first call was forced to fail), and the recovered output actually
        // carries both tracks.
        val recoveredViaMixdown = failureReason == null && remuxCallCount >= 2 && hasVideo && hasAudio
        val pass = recoveredViaMixdown
        if (!pass) deleteIfExists(finalPath)
        return mapOf(
            "pass" to pass,
            "raw" to "${laneRaw(pass, failureReason, hasVideo, hasAudio)};remuxCalls=$remuxCallCount",
            "failureReason" to failureReason,
            "remuxCallCount" to remuxCallCount,
            "hasVideo" to hasVideo,
            "hasAudio" to hasAudio,
            "recoveredViaMixdown" to recoveredViaMixdown,
            "outputPath" to finalPath,
        )
    }

    // ── Lane D: empty sidecar, video-only remux ──────────────────────────────

    private fun runNoAudioVideoOnlyLane(videoTempPath: String, outDir: File): Map<String, Any?> {
        val finalPath = File(outDir, "lane_d_video_only_final.mp4").path
        deleteIfExists(finalPath)

        val muxer = AndroidTimelineAudioPass2Muxer()
        val audioTempPath = File(outDir, "lane_d_audio_temp.m4a").path
        val failureReason = muxer.run(
            specs = emptyList(),
            videoTempPath = videoTempPath,
            audioTempPath = audioTempPath,
            finalTmpPath = finalPath,
        )
        val (hasVideo, hasAudio) = probeHasVideoAndAudio(finalPath)
        val pass = failureReason == null && hasVideo && !hasAudio
        if (!pass) deleteIfExists(finalPath)
        return mapOf(
            "pass" to pass,
            "raw" to laneRaw(pass, failureReason, hasVideo, hasAudio),
            "failureReason" to failureReason,
            "hasVideo" to hasVideo,
            "hasAudio" to hasAudio,
            "outputPath" to finalPath,
        )
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun eligibleOriginalTrackMap(
        trackId: String,
        url: String,
        durationSec: Double,
    ): Map<String, Any?> = mapOf(
        "trackId" to trackId,
        "url" to url,
        "startTime" to 0.0,
        "duration" to durationSec,
        "volume" to 1.0,
        "role" to "original",
    )

    private fun probeHasVideoAndAudio(path: String): Pair<Boolean, Boolean> {
        val file = File(path)
        if (!file.exists() || file.length() <= 0L) return Pair(false, false)
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            var hasVideo = false
            var hasAudio = false
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/")) hasVideo = true
                if (mime.startsWith("audio/")) hasAudio = true
            }
            Pair(hasVideo, hasAudio)
        } catch (_: Throwable) {
            Pair(false, false)
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    private fun probeMediaDurationSeconds(path: String): Double? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val ms = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: return null
            ms / 1000.0
        } catch (_: Throwable) {
            null
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    private fun laneRaw(pass: Boolean, failureReason: String?, hasVideo: Boolean, hasAudio: Boolean): String =
        if (pass) {
            "ok(hasVideo=$hasVideo,hasAudio=$hasAudio)"
        } else {
            "fail(reason=$failureReason,hasVideo=$hasVideo,hasAudio=$hasAudio)"
        }

    private fun laneFailure(
        reason: String,
        outputPath: String,
        extra: Map<String, Any?> = emptyMap(),
    ): Map<String, Any?> {
        Log.e(TAG, "lane failed: $reason")
        val base = mutableMapOf<String, Any?>(
            "pass" to false,
            "raw" to "fail($reason)",
            "failureReason" to reason,
            "hasVideo" to false,
            "hasAudio" to false,
            "outputPath" to outputPath,
        )
        base.putAll(extra)
        return base
    }

    private fun deleteIfExists(path: String) {
        try { File(path).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
    }
}
