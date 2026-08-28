package com.connects.vanguard_media_engine.export

import android.util.Log
import java.io.File

// AndroidPassthroughRemuxSmokeHarness (Phase 2-Unit X)
//
// Diagnostic single-source passthrough remux proof against a fixture video.
// Proves MediaExtractor + MediaMuxer stream copy using AndroidAudioRemuxer
// without MediaCodec allocation and without production exportTimeline bypass.
//
// Primary lane:
//   Calls AndroidAudioRemuxer.remux(videoPath=sourcePath, audioPath=sourcePath,
//   finalPath=<outputDir>/passthrough_remux_native_unit_x.mp4).
//   PASS only if success=true, videoSamples>0, audioSamples>0, outputSizeBytes>0,
//   output file exists, and output file length equals reported outputSizeBytes.
//
// Guard lane:
//   Calls AndroidAudioRemuxer.remux(videoPath=<missing path under outputDir>,
//   audioPath=null, finalPath=<outputDir>/passthrough_remux_native_unit_x_missing.mp4).
//   PASS only if success=false, output does not exist, and reason is non-empty.
//
// The harness never deletes the input fixture; deterministic generated outputs
// inside outputDir are cleaned up before running and on failure.
// Logs exactly one ANDROID_PASSTHROUGH_REMUX_NATIVE_SMOKE_RESULT <raw> marker.

object AndroidPassthroughRemuxSmokeHarness {

    private const val TAG = "VanguardPassthroughRemuxSmoke"
    private const val RESULT_MARKER = "ANDROID_PASSTHROUGH_REMUX_NATIVE_SMOKE_RESULT"

    private const val PRIMARY_OUTPUT_FILE = "passthrough_remux_native_unit_x.mp4"
    private const val GUARD_OUTPUT_FILE = "passthrough_remux_native_unit_x_missing.mp4"

    fun run(sourcePath: String, outputDir: String): Map<String, Any?> {
        val nonClaimsMap = mapOf(
            "productionExportTimelineBypass" to false,
            "cppPassthroughRemuxSinkNode" to false,
            "codecAllocated" to false,
            "videoDecoded" to false,
            "audioDecoded" to false,
            "bitExactPayloadCompared" to false,
            "connectAppTouched" to false,
        )

        var raw = "status=FAIL;reason=not_run"
        try {
            val srcFile = File(sourcePath)
            if (!srcFile.exists() || !srcFile.canRead()) {
                raw = "status=FAIL;reason=source_missing_or_unreadable;sourcePath=$sourcePath"
                return mapOf(
                    "pass" to false,
                    "proofBoundary" to "native_passthrough_remux_diagnostic_mediaextractor_mediamuxer_no_codec_no_exporttimeline",
                    "raw" to raw,
                    "primary" to null,
                    "guard" to null,
                    "nonClaims" to nonClaimsMap,
                )
            }

            val outDir = File(outputDir)
            if (!outDir.isDirectory) {
                raw = "status=FAIL;reason=output_dir_missing;outputDir=$outputDir"
                return mapOf(
                    "pass" to false,
                    "proofBoundary" to "native_passthrough_remux_diagnostic_mediaextractor_mediamuxer_no_codec_no_exporttimeline",
                    "raw" to raw,
                    "primary" to null,
                    "guard" to null,
                    "nonClaims" to nonClaimsMap,
                )
            }

            // Remove stale generated outputs from previous runs; source is never deleted.
            deleteGenerated(outDir, PRIMARY_OUTPUT_FILE, GUARD_OUTPUT_FILE)

            val primaryOutputPath = File(outDir, PRIMARY_OUTPUT_FILE).path
            val primaryRemux = AndroidAudioRemuxer.remux(
                videoPath = sourcePath,
                audioPath = sourcePath,
                finalPath = primaryOutputPath,
            )

            val primaryOutputFile = File(primaryOutputPath)
            val outputExists = primaryOutputFile.exists()
            val actualOutputSizeBytes = if (outputExists) primaryOutputFile.length() else 0L
            val reportedOutputSizeBytes = primaryRemux.outputSizeBytes

            val primaryPass = primaryRemux.success &&
                primaryRemux.videoSamples > 0 &&
                primaryRemux.audioSamples > 0 &&
                primaryRemux.outputSizeBytes > 0L &&
                outputExists &&
                actualOutputSizeBytes == reportedOutputSizeBytes

            val primaryMap = mapOf(
                "pass" to primaryPass,
                "outputPath" to primaryOutputPath,
                "outputExists" to outputExists,
                "outputSizeBytes" to actualOutputSizeBytes,
                "reportedOutputSizeBytes" to reportedOutputSizeBytes,
                "videoSamples" to primaryRemux.videoSamples,
                "audioSamples" to primaryRemux.audioSamples,
                "extractorOpened" to primaryRemux.success,
                "muxerStarted" to primaryRemux.success,
                "sourceFileRead" to (primaryRemux.videoSamples > 0 && primaryRemux.audioSamples > 0),
                "outputFileWritten" to (outputExists && actualOutputSizeBytes > 0L),
                "codecAllocated" to false,
                "reason" to primaryRemux.reason,
            )

            // Guard lane: missing input file under outputDir
            val missingSourcePath = File(outDir, "passthrough_remux_native_missing_source_${System.currentTimeMillis()}.mp4").path
            val guardOutputPath = File(outDir, GUARD_OUTPUT_FILE).path
            val guardRemux = AndroidAudioRemuxer.remux(
                videoPath = missingSourcePath,
                audioPath = null,
                finalPath = guardOutputPath,
            )

            val guardOutputFile = File(guardOutputPath)
            val guardOutputExists = guardOutputFile.exists()
            val guardPass = !guardRemux.success && !guardOutputExists && guardRemux.reason.isNotEmpty()

            val guardMap = mapOf(
                "pass" to guardPass,
                "reason" to guardRemux.reason,
                "outputPath" to guardOutputPath,
                "outputExists" to guardOutputExists,
            )

            val overallPass = primaryPass && guardPass
            raw = if (overallPass) {
                "status=PASS;primary=ok(video=${primaryRemux.videoSamples},audio=${primaryRemux.audioSamples},bytes=$actualOutputSizeBytes);guard=ok(reason=${guardRemux.reason})"
            } else {
                "status=FAIL;primary=${if (primaryPass) "ok" else "fail(${primaryRemux.reason})"};guard=${if (guardPass) "ok" else "fail(${guardRemux.reason})"}"
            }

            if (!overallPass) {
                deleteGenerated(outDir, PRIMARY_OUTPUT_FILE, GUARD_OUTPUT_FILE)
            }

            return mapOf(
                "pass" to overallPass,
                "proofBoundary" to "native_passthrough_remux_diagnostic_mediaextractor_mediamuxer_no_codec_no_exporttimeline",
                "raw" to raw,
                "primary" to primaryMap,
                "guard" to guardMap,
                "nonClaims" to nonClaimsMap,
            )
        } catch (t: Throwable) {
            val reason = t.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = "status=FAIL;reason=exception:$reason"
            Log.e(TAG, "$RESULT_MARKER exception=$reason", t)
            deleteGenerated(File(outputDir), PRIMARY_OUTPUT_FILE, GUARD_OUTPUT_FILE)
            return mapOf(
                "pass" to false,
                "proofBoundary" to "native_passthrough_remux_diagnostic_mediaextractor_mediamuxer_no_codec_no_exporttimeline",
                "raw" to raw,
                "primary" to null,
                "guard" to null,
                "nonClaims" to nonClaimsMap,
            )
        } finally {
            Log.i(TAG, "$RESULT_MARKER $raw")
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
