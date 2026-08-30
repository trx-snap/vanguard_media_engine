package com.connects.vanguard_media_engine.export

import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File

// ── AndroidAudioFoundationSmokeHarness (Export/Audio Unit B) ──────────────────
//
// Diagnostic two-pass audio foundation proof against a fixture video. Runs two
// scenarios end-to-end against the same fixture file:
//
//   directCopy — one original unity-gain AAC track. The direct-copy validator
//   must report eligible; the fixture's video + audio are then stream-copied
//   into <outputDir>/direct_copy.mp4 (videoSamples > 0, audioSamples > 0,
//   output size > 0).
//
//   pcmMixdown — one non-direct-eligible track whose volumeKeyframes exercise
//   the clamp / sub-ms merge / synthesized-start / synthesized-terminal rules,
//   plus one invalid track map that the parser must skip with evidence. The
//   validator must report NOT eligible; the track is decoded to PCM, mixed
//   through the volume envelope and the P4-AUDIO-MIXBUS native chunked mix
//   bus (AndroidNativeAudioMixBusChunkMixer) -- this scenario requires
//   nativeMixBusUsed, a non-zero native chunk count, and a native "success"
//   reason, never a Kotlin-only fallback -- AAC-encoded to
//   <outputDir>/mixdown_audio.m4a and remuxed with the fixture video into
//   <outputDir>/mixdown.mp4.
//
// The harness never deletes the input fixture; partial generated outputs are
// deleted on failure. Every run logs exactly one
// ANDROID_DAG_AUDIO_FOUNDATION_SMOKE_RESULT <raw> marker.

object AndroidAudioFoundationSmokeHarness {

    private const val TAG = "VanguardAudioSmoke"
    private const val RESULT_MARKER = "ANDROID_DAG_AUDIO_FOUNDATION_SMOKE_RESULT"

    private const val DIRECT_COPY_FILE = "direct_copy.mp4"
    private const val MIXDOWN_AUDIO_FILE = "mixdown_audio.m4a"
    private const val MIXDOWN_FILE = "mixdown.mp4"

    fun run(videoPath: String, audioPath: String, outputDir: String): Map<String, Any?> {
        var raw = "status=FAIL;reason=not_run"
        try {
            if (!File(videoPath).exists() || !File(audioPath).exists()) {
                raw = "status=FAIL;reason=input_fixture_missing;" +
                    "videoPath=$videoPath;audioPath=$audioPath"
                return overallResult(false, raw, null, null)
            }
            val outDir = File(outputDir)
            if (!outDir.isDirectory) {
                raw = "status=FAIL;reason=output_dir_missing;outputDir=$outputDir"
                return overallResult(false, raw, null, null)
            }

            val audioDurationSec = probeAudioDurationSeconds(audioPath)
            if (audioDurationSec < 1.0) {
                raw = "status=FAIL;reason=fixture_audio_too_short;" +
                    "durationSec=$audioDurationSec"
                return overallResult(false, raw, null, null)
            }

            // Remove stale generated outputs from previous runs; the input
            // fixture is never touched.
            deleteGenerated(outDir, DIRECT_COPY_FILE, MIXDOWN_AUDIO_FILE, MIXDOWN_FILE)

            val directCopy = runDirectCopyScenario(videoPath, audioPath, audioDurationSec, outDir)
            val pcmMixdown = runPcmMixdownScenario(videoPath, audioPath, audioDurationSec, outDir)

            val directCopyPass = directCopy["pass"] == true
            val pcmMixdownPass = pcmMixdown["pass"] == true
            val pass = directCopyPass && pcmMixdownPass
            raw = (if (pass) "status=PASS;" else "status=FAIL;") +
                "directCopy=${directCopy["raw"]};pcmMixdown=${pcmMixdown["raw"]};" +
                "fixtureAudioDurationSec=$audioDurationSec"
            return overallResult(pass, raw, directCopy, pcmMixdown)
        } catch (t: Throwable) {
            val reason = t.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = "status=FAIL;reason=exception:$reason"
            Log.e(TAG, "$RESULT_MARKER exception=$reason", t)
            deleteGenerated(File(outputDir), DIRECT_COPY_FILE, MIXDOWN_AUDIO_FILE, MIXDOWN_FILE)
            return overallResult(false, raw, null, null)
        } finally {
            Log.i(TAG, "$RESULT_MARKER $raw")
        }
    }

    // ── Scenario 1: direct copy ───────────────────────────────────────────────

    private fun runDirectCopyScenario(
        videoPath: String,
        audioPath: String,
        audioDurationSec: Double,
        outDir: File,
    ): Map<String, Any?> {
        val outputPath = File(outDir, DIRECT_COPY_FILE).path
        val trackMap = mapOf(
            "trackId" to "unitB_direct_original",
            "url" to audioPath,
            "startTime" to 0.0,
            "duration" to audioDurationSec,
            "volume" to 1.0,
            "role" to "original",
        )
        val spec = AndroidAudioTrackSpec.fromMap(trackMap)
            ?: return scenarioFailure("directCopy", "track_parse_failed", outputPath)

        val verdict = AndroidAudioDirectCopyValidator.validate(listOf(spec))
        if (!verdict.eligible) {
            return scenarioFailure(
                "directCopy",
                "validator_not_eligible:${verdict.reason}",
                outputPath,
                extra = mapOf("eligible" to false, "eligibilityReason" to verdict.reason),
            )
        }

        val remux = AndroidAudioRemuxer.remux(
            videoPath = videoPath,
            audioPath = audioPath,
            finalPath = outputPath,
        )
        val pass = remux.success &&
            remux.videoSamples > 0 &&
            remux.audioSamples > 0 &&
            remux.outputSizeBytes > 0L
        if (!pass) {
            deleteGenerated(outDir, DIRECT_COPY_FILE)
        }
        val raw = if (pass) {
            "ok(video=${remux.videoSamples},audio=${remux.audioSamples}," +
                "bytes=${remux.outputSizeBytes})"
        } else {
            "fail(${remux.reason};video=${remux.videoSamples};audio=${remux.audioSamples})"
        }
        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "eligible" to true,
            "eligibilityReason" to verdict.reason,
            "outputPath" to outputPath,
            "outputSize" to remux.outputSizeBytes,
            "videoSamples" to remux.videoSamples,
            "audioSamples" to remux.audioSamples,
        )
    }

    // ── Scenario 2: PCM mixdown ───────────────────────────────────────────────

    private fun runPcmMixdownScenario(
        videoPath: String,
        audioPath: String,
        audioDurationSec: Double,
        outDir: File,
    ): Map<String, Any?> {
        val mixedAudioPath = File(outDir, MIXDOWN_AUDIO_FILE).path
        val outputPath = File(outDir, MIXDOWN_FILE).path
        val mixDurationSec = minOf(audioDurationSec, 3.0)

        // Keyframes chosen to exercise every normalisation rule:
        //   time -1.0            → outside track range, discarded;
        //   time 0.5 vol 1.4     → volume clamped to 1.0;
        //   time 0.5004 vol 0.8  → < 1 ms after previous, merged (keeps 0.8);
        //   time 75% vol 0.3     → interior point before the synthesized end;
        //   first surviving keyframe > start + 1 ms → silent start synthesized;
        //   last keyframe < end - 1 ms → terminal keyframe holds 0.3.
        val keyframeMaps = listOf(
            mapOf("time" to -1.0, "volume" to 0.5),
            mapOf("time" to 0.5, "volume" to 1.4),
            mapOf("time" to 0.5004, "volume" to 0.8),
            mapOf("time" to mixDurationSec * 0.75, "volume" to 0.3),
        )
        val validTrackMap = mapOf(
            "trackId" to "unitB_mixdown_keyframed",
            "url" to audioPath,
            "startTime" to 0.0,
            "duration" to mixDurationSec,
            "volume" to 1.0,
            "role" to "music",
            "volumeKeyframes" to keyframeMaps,
            "mixGain" to 0.9,
        )
        // Invalid on purpose (missing url): the parser must skip it with
        // evidence, not crash.
        val invalidTrackMap = mapOf(
            "trackId" to "unitB_invalid_missing_url",
            "startTime" to 0.0,
            "duration" to 1.0,
        )

        val (specs, skippedIndices) =
            AndroidAudioTrackSpec.parseList(listOf(validTrackMap, invalidTrackMap))
        if (specs.size != 1 || skippedIndices.size != 1) {
            return scenarioFailure(
                "pcmMixdown",
                "parser_evidence_mismatch:parsed=${specs.size};skipped=${skippedIndices.size}",
                outputPath,
            )
        }
        val spec = specs.first()

        val verdict = AndroidAudioDirectCopyValidator.validate(specs)
        if (verdict.eligible) {
            return scenarioFailure(
                "pcmMixdown", "validator_unexpectedly_eligible", outputPath,
                extra = mapOf("eligible" to true, "eligibilityReason" to verdict.reason),
            )
        }

        // Envelope evidence: the four raw keyframes must normalise to
        // [synth start 0.0, merged 0.5004, interior, synth terminal].
        val normalized = AndroidAudioVolumeEnvelope.normalize(
            rawKeyframes = spec.volumeKeyframes!!,
            trackStartSec = 0.0,
            trackEndSec = mixDurationSec,
            mixGain = spec.mixGain,
        )
        val envelopeEvidenceOk = normalized.size == 4 &&
            normalized.first().time == 0.0 &&
            normalized.first().volume == 0.0 &&
            normalized.last().time == mixDurationSec &&
            normalized.last().volume == normalized[normalized.size - 2].volume
        if (!envelopeEvidenceOk) {
            return scenarioFailure(
                "pcmMixdown",
                "envelope_normalize_mismatch:count=${normalized.size}",
                outputPath,
            )
        }

        val mix = AndroidAudioMixdownEngine.mix(specs)
        if (!mix.success || mix.pcm == null) {
            return scenarioFailure("pcmMixdown", "mixdown_failed:${mix.reason}", outputPath)
        }
        // P4-AUDIO-MIXBUS: the PCM mixdown route must go through the native
        // chunked mix bus (AndroidNativeAudioMixBusChunkMixer), not a Kotlin
        // fallback -- this is not a byte-equality check against the old
        // all-Kotlin summation, only evidence that native mixing actually ran
        // and reported success for at least one chunk.
        if (!mix.nativeMixBusUsed || mix.nativeChunkCount <= 0 || mix.nativeMixReason != "success") {
            return scenarioFailure(
                "pcmMixdown",
                "native_mix_bus_evidence_missing:used=${mix.nativeMixBusUsed};" +
                    "chunks=${mix.nativeChunkCount};nativeReason=${mix.nativeMixReason}",
                outputPath,
            )
        }

        val encode = AndroidAacEncoder.encodePcm16ToM4a(
            pcm = mix.pcm,
            sampleRate = mix.sampleRate,
            channelCount = mix.channelCount,
            outputPath = mixedAudioPath,
        )
        if (!encode.success || encode.outputSizeBytes <= 0L) {
            deleteGenerated(outDir, MIXDOWN_AUDIO_FILE)
            return scenarioFailure("pcmMixdown", "aac_encode_failed:${encode.reason}", outputPath)
        }

        val remux = AndroidAudioRemuxer.remux(
            videoPath = videoPath,
            audioPath = mixedAudioPath,
            finalPath = outputPath,
        )
        val pass = remux.success &&
            remux.videoSamples > 0 &&
            remux.audioSamples > 0 &&
            remux.outputSizeBytes > 0L
        if (!pass) {
            deleteGenerated(outDir, MIXDOWN_AUDIO_FILE, MIXDOWN_FILE)
        }
        val raw = if (pass) {
            "ok(normalizedKf=${normalized.size},mixedTracks=${mix.mixedTrackCount}," +
                "invalidSkipped=${skippedIndices.size},aacSamples=${encode.encodedSamples}," +
                "video=${remux.videoSamples},audio=${remux.audioSamples}," +
                "bytes=${remux.outputSizeBytes},nativeMixBusUsed=${mix.nativeMixBusUsed}," +
                "nativeChunkCount=${mix.nativeChunkCount},nativeSilentChunks=${mix.nativeSilentChunks}," +
                "nativeGainClamped=${mix.nativeGainClamped})"
        } else {
            "fail(pass2_remux:${remux.reason};video=${remux.videoSamples};" +
                "audio=${remux.audioSamples})"
        }
        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "eligible" to false,
            "eligibilityReason" to verdict.reason,
            "normalizedKeyframes" to normalized.size,
            "mixedTrackCount" to mix.mixedTrackCount,
            "skippedInvalidTracks" to skippedIndices.size,
            "skippedDecodeTracks" to mix.skippedTracks,
            "sampleRate" to mix.sampleRate,
            "channelCount" to mix.channelCount,
            "frameCount" to mix.frameCount,
            "nativeMixBusUsed" to mix.nativeMixBusUsed,
            "nativeChunkCount" to mix.nativeChunkCount,
            "nativeSilentChunks" to mix.nativeSilentChunks,
            "nativeMixReason" to mix.nativeMixReason,
            "nativeGainClamped" to mix.nativeGainClamped,
            "encodedSamples" to encode.encodedSamples,
            "mixedAudioPath" to mixedAudioPath,
            "mixedAudioSize" to encode.outputSizeBytes,
            "outputPath" to outputPath,
            "outputSize" to remux.outputSizeBytes,
            "videoSamples" to remux.videoSamples,
            "audioSamples" to remux.audioSamples,
        )
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun probeAudioDurationSeconds(path: String): Double {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            var durationUs = -1L
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                if (format.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    if (format.containsKey(MediaFormat.KEY_DURATION)) {
                        durationUs = format.getLong(MediaFormat.KEY_DURATION)
                    }
                    break
                }
            }
            if (durationUs > 0L) durationUs / 1_000_000.0 else -1.0
        } catch (_: Exception) {
            -1.0
        } finally {
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    private fun scenarioFailure(
        scenario: String,
        reason: String,
        outputPath: String,
        extra: Map<String, Any?> = emptyMap(),
    ): Map<String, Any?> {
        Log.e(TAG, "$scenario scenario failed: $reason")
        val base = mutableMapOf<String, Any?>(
            "pass" to false,
            "raw" to "fail($reason)",
            "outputPath" to outputPath,
            "outputSize" to 0L,
            "videoSamples" to 0,
            "audioSamples" to 0,
        )
        base.putAll(extra)
        return base
    }

    private fun deleteGenerated(outDir: File, vararg names: String) {
        for (name in names) {
            try {
                val f = File(outDir, name)
                if (f.exists()) f.delete()
            } catch (_: Throwable) {}
        }
    }

    private fun overallResult(
        pass: Boolean,
        raw: String,
        directCopy: Map<String, Any?>?,
        pcmMixdown: Map<String, Any?>?,
    ): Map<String, Any?> = mapOf(
        "pass" to pass,
        "raw" to raw,
        "directCopy" to directCopy,
        "pcmMixdown" to pcmMixdown,
    )
}
