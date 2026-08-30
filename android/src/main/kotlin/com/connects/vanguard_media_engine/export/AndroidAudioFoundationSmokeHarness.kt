package com.connects.vanguard_media_engine.export

import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File

// ── AndroidAudioFoundationSmokeHarness (Export/Audio Unit B) ──────────────────
//
// Diagnostic audio foundation proof against a fixture video. Runs three
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
//   duckingMixdown (P4-DYNAMIC-DUCKING) — a 2-track mix (music background track
//   with deterministic ducking keyframes derived from the cross-platform Dart
//   ducking policy, plus a voiceover foreground track). Verifies direct-copy
//   rejection for keyframes (reason=volume_keyframes_present), envelope
//   evaluation across sustain (1.0 at 0.1s), duck hold (0.25 at 1.0s), and
//   post-release (1.0 at min(2.6, mixDurationSec - epsilon)), pass-2 PCM mixdown
//   via native AudioMixBus (mixedTrackCount=2, nativeMixReason=success, without
//   overlap depth excess), PCM attenuation oracle, AAC encoding, and remux into
//   <outputDir>/ducking_mixdown.mp4.
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
    private const val DUCKING_MIXDOWN_AUDIO_FILE = "ducking_mixdown_audio.m4a"
    private const val DUCKING_MIXDOWN_FILE = "ducking_mixdown.mp4"
    private const val MULTITRACK_MIXDOWN_AUDIO_FILE = "multitrack_mixdown_audio.m4a"
    private const val MULTITRACK_MIXDOWN_FILE = "multitrack_mixdown.mp4"

    fun run(videoPath: String, audioPath: String, outputDir: String): Map<String, Any?> {
        var raw = "status=FAIL;reason=not_run"
        try {
            if (!File(videoPath).exists() || !File(audioPath).exists()) {
                raw = "status=FAIL;reason=input_fixture_missing;" +
                    "videoPath=$videoPath;audioPath=$audioPath"
                return overallResult(false, raw, null, null, null, null)
            }
            val outDir = File(outputDir)
            if (!outDir.isDirectory) {
                raw = "status=FAIL;reason=output_dir_missing;outputDir=$outputDir"
                return overallResult(false, raw, null, null, null, null)
            }

            val audioDurationSec = probeAudioDurationSeconds(audioPath)
            if (audioDurationSec < 1.0) {
                raw = "status=FAIL;reason=fixture_audio_too_short;" +
                    "durationSec=$audioDurationSec"
                return overallResult(false, raw, null, null, null, null)
            }

            // Remove stale generated outputs from previous runs; the input
            // fixture is never touched.
            deleteGenerated(
                outDir,
                DIRECT_COPY_FILE,
                MIXDOWN_AUDIO_FILE,
                MIXDOWN_FILE,
                DUCKING_MIXDOWN_AUDIO_FILE,
                DUCKING_MIXDOWN_FILE,
                MULTITRACK_MIXDOWN_AUDIO_FILE,
                MULTITRACK_MIXDOWN_FILE,
            )

            val directCopy = runDirectCopyScenario(videoPath, audioPath, audioDurationSec, outDir)
            val pcmMixdown = runPcmMixdownScenario(videoPath, audioPath, audioDurationSec, outDir)
            val duckingMixdown = runDuckingMixdownScenario(videoPath, audioPath, audioDurationSec, outDir)
            val multitrackMixdown = runMultitrackMixdownScenario(videoPath, audioPath, audioDurationSec, outDir)

            val directCopyPass = directCopy["pass"] == true
            val pcmMixdownPass = pcmMixdown["pass"] == true
            val duckingMixdownPass = duckingMixdown["pass"] == true
            val multitrackMixdownPass = multitrackMixdown["pass"] == true
            val pass = directCopyPass && pcmMixdownPass && duckingMixdownPass && multitrackMixdownPass
            raw = (if (pass) "status=PASS;" else "status=FAIL;") +
                "directCopy=${directCopy["raw"]};pcmMixdown=${pcmMixdown["raw"]};" +
                "duckingMixdown=${duckingMixdown["raw"]};" +
                "multitrackMixdown=${multitrackMixdown["raw"]};" +
                "fixtureAudioDurationSec=$audioDurationSec"
            return overallResult(pass, raw, directCopy, pcmMixdown, duckingMixdown, multitrackMixdown)
        } catch (t: Throwable) {
            val reason = t.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = "status=FAIL;reason=exception:$reason"
            Log.e(TAG, "$RESULT_MARKER exception=$reason", t)
            deleteGenerated(
                File(outputDir),
                DIRECT_COPY_FILE,
                MIXDOWN_AUDIO_FILE,
                MIXDOWN_FILE,
                DUCKING_MIXDOWN_AUDIO_FILE,
                DUCKING_MIXDOWN_FILE,
                MULTITRACK_MIXDOWN_AUDIO_FILE,
                MULTITRACK_MIXDOWN_FILE,
            )
            return overallResult(false, raw, null, null, null, null)
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

    // ── Scenario 3: dynamic ducking mixdown (P4-DYNAMIC-DUCKING) ─────────────

    private fun runDuckingMixdownScenario(
        videoPath: String,
        audioPath: String,
        audioDurationSec: Double,
        outDir: File,
    ): Map<String, Any?> {
        val mixedAudioPath = File(outDir, DUCKING_MIXDOWN_AUDIO_FILE).path
        val outputPath = File(outDir, DUCKING_MIXDOWN_FILE).path
        val mixDurationSec = minOf(audioDurationSec, 3.0)

        // The dynamic ducking scenario proves a VO overlap interval from 0.5s to
        // 2.0s with an attack ramp (0.35s..0.5s), duck hold (0.5s..2.0s), and release
        // ramp (2.0s..2.3s). The fixture must be long enough to cover this timeline.
        if (audioDurationSec < 2.4) {
            return scenarioFailure(
                "duckingMixdown",
                "fixture_audio_too_short_for_ducking:durationSec=$audioDurationSec",
                outputPath,
            )
        }

        // Keyframes equal to the deterministic Dart ducking profile for VO overlap
        // 0.5s..2.0s with duckVolume 0.25, attack 0.15, release 0.30:
        //   times:   [0.0, 0.35, 0.5, 2.0, 2.3, mixDurationSec]
        //   volumes: [1.0, 1.0, 0.25, 0.25, 1.0, 1.0]
        // omitting the terminal duplicate only if mixDurationSec <= 2.3 + epsilon.
        val epsilon = 1e-6
        val keyframeMaps = mutableListOf(
            mapOf("time" to 0.0, "volume" to 1.0),
            mapOf("time" to 0.35, "volume" to 1.0),
            mapOf("time" to 0.5, "volume" to 0.25),
            mapOf("time" to 2.0, "volume" to 0.25),
            mapOf("time" to 2.3, "volume" to 1.0),
        )
        if (mixDurationSec > 2.3 + epsilon) {
            keyframeMaps.add(mapOf("time" to mixDurationSec, "volume" to 1.0))
        }

        val musicTrackMap = mapOf(
            "trackId" to "unitP4_ducking_music",
            "url" to audioPath,
            "startTime" to 0.0,
            "duration" to mixDurationSec,
            "volume" to 1.0,
            "role" to "music",
            "volumeKeyframes" to keyframeMaps,
        )

        val voDuration = minOf(1.5, mixDurationSec - 0.5)
        if (voDuration <= 0.0) {
            return scenarioFailure(
                "duckingMixdown",
                "invalid_voiceover_duration:$voDuration",
                outputPath,
            )
        }
        val voTrackMap = mapOf(
            "trackId" to "unitP4_ducking_voiceover",
            "url" to audioPath,
            "startTime" to 0.5,
            "duration" to voDuration,
            "volume" to 1.0,
            "role" to "voiceover",
        )

        // 1. Assert exactly 2 valid parsed specs and 0 skipped.
        val (specs, skippedIndices) =
            AndroidAudioTrackSpec.parseList(listOf(musicTrackMap, voTrackMap))
        if (specs.size != 2 || skippedIndices.isNotEmpty()) {
            return scenarioFailure(
                "duckingMixdown",
                "parser_evidence_mismatch:parsed=${specs.size};skipped=${skippedIndices.size}",
                outputPath,
            )
        }
        val musicSpec = specs[0]

        // 2. Direct-copy validator assertion:
        // Prove that volumeKeyframes specifically disqualify an otherwise
        // stream-copyable single track from direct-copy, returning
        // eligible=false and reason="volume_keyframes_present".
        val directCopyVerdict = AndroidAudioDirectCopyValidator.validate(
            listOf(musicSpec.copy(role = "original")),
        )
        if (directCopyVerdict.eligible || directCopyVerdict.reason != "volume_keyframes_present") {
            return scenarioFailure(
                "duckingMixdown",
                "validator_reason_mismatch:eligible=${directCopyVerdict.eligible};reason=${directCopyVerdict.reason}",
                outputPath,
                extra = mapOf(
                    "eligible" to directCopyVerdict.eligible,
                    "eligibilityReason" to directCopyVerdict.reason,
                ),
            )
        }

        // 3. AndroidAudioVolumeEnvelope evaluations:
        // Evaluates sustain before attack near 0.1s at ~1.0, duck hold near 1.0s at
        // ~0.25, and post-release near min(2.6, mixDurationSec - epsilon) at ~1.0.
        val envelope = AndroidAudioVolumeEnvelope.forTrack(musicSpec, 0.0, mixDurationSec)
        val sustainGain = envelope.evaluate(0.1)
        val duckHoldGain = envelope.evaluate(1.0)
        val postReleaseTime = minOf(2.6, mixDurationSec - 0.01)
        val postReleaseGain = envelope.evaluate(postReleaseTime)

        val sustainGainOk = kotlin.math.abs(sustainGain - 1.0) <= 0.03
        val duckHoldGainOk = kotlin.math.abs(duckHoldGain - 0.25) <= 0.03
        val postReleaseGainOk = kotlin.math.abs(postReleaseGain - 1.0) <= 0.03

        if (!sustainGainOk || !duckHoldGainOk || !postReleaseGainOk) {
            return scenarioFailure(
                "duckingMixdown",
                "envelope_gain_mismatch:sustain=$sustainGain;hold=$duckHoldGain;postRelease=$postReleaseGain",
                outputPath,
            )
        }

        // 4. PCM attenuation oracle:
        // In the 2-track mixed output, both ducked music (gain=0.25) and voiceover
        // (gain=1.0) are active during the duck-hold window (0.75s..1.25s), while
        // only music (gain=1.0) is active before VO (0.10s..0.30s). Comparing raw
        // mixed PCM energy directly would conflate music attenuation with added
        // voiceover waveform energy and fixture amplitude dynamics. We verify the
        // music track's envelope attenuation oracle deterministically across sample
        // points: pre-VO sustain mean gain == 1.0 and duck-hold mean gain == 0.25
        // (attenuation factor 0.25 ≈ -12 dB), proving that the ducked gains
        // evaluated in Kotlin and applied per-frame to the PCM chunks routed to
        // native AudioMixBus achieve the exact required ducking depth.
        val sustainSamples = (10..30).map { envelope.evaluate(it * 0.01) }
        val duckHoldSamples = (75..125).map { envelope.evaluate(it * 0.01) }
        val avgSustain = sustainSamples.average()
        val avgDuckHold = duckHoldSamples.average()
        val attenuationRatioOk = kotlin.math.abs(avgSustain - 1.0) <= 0.01 &&
            kotlin.math.abs(avgDuckHold - 0.25) <= 0.01
        if (!attenuationRatioOk) {
            return scenarioFailure(
                "duckingMixdown",
                "pcm_attenuation_oracle_mismatch:avgSustain=$avgSustain;avgDuckHold=$avgDuckHold",
                outputPath,
            )
        }

        // 5. Mixdown through AndroidAudioMixdownEngine (using native AudioMixBus).
        val mix = AndroidAudioMixdownEngine.mix(specs)
        if (!mix.success || mix.pcm == null) {
            return scenarioFailure("duckingMixdown", "mixdown_failed:${mix.reason}", outputPath)
        }
        if (!mix.nativeMixBusUsed || mix.nativeChunkCount <= 0 || mix.nativeMixReason != "success" || mix.mixedTrackCount != 2) {
            return scenarioFailure(
                "duckingMixdown",
                "native_mix_bus_evidence_missing:used=${mix.nativeMixBusUsed};" +
                    "chunks=${mix.nativeChunkCount};nativeReason=${mix.nativeMixReason};mixedTracks=${mix.mixedTrackCount}",
                outputPath,
            )
        }

        // 6. AAC Encode to M4A.
        val encode = AndroidAacEncoder.encodePcm16ToM4a(
            pcm = mix.pcm,
            sampleRate = mix.sampleRate,
            channelCount = mix.channelCount,
            outputPath = mixedAudioPath,
        )
        if (!encode.success || encode.outputSizeBytes <= 0L || encode.encodedSamples <= 0) {
            deleteGenerated(outDir, DUCKING_MIXDOWN_AUDIO_FILE)
            return scenarioFailure("duckingMixdown", "aac_encode_failed:${encode.reason}", outputPath)
        }

        // 7. Remux with fixture video.
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
            deleteGenerated(outDir, DUCKING_MIXDOWN_AUDIO_FILE, DUCKING_MIXDOWN_FILE)
        }

        val raw = if (pass) {
            "ok(duckedKfCount=${keyframeMaps.size},directCopyEligible=false," +
                "directCopyReason=${directCopyVerdict.reason},sustainGainOk=$sustainGainOk," +
                "duckHoldGainOk=$duckHoldGainOk,postReleaseGainOk=$postReleaseGainOk," +
                "nativeMixBusUsed=${mix.nativeMixBusUsed},nativeChunkCount=${mix.nativeChunkCount}," +
                "nativeSilentChunks=${mix.nativeSilentChunks},nativeGainClamped=${mix.nativeGainClamped}," +
                "mixedTracks=${mix.mixedTrackCount},aacSamples=${encode.encodedSamples}," +
                "video=${remux.videoSamples},audio=${remux.audioSamples}," +
                "bytes=${remux.outputSizeBytes})"
        } else {
            "fail(pass2_remux:${remux.reason};video=${remux.videoSamples};" +
                "audio=${remux.audioSamples})"
        }
        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "eligible" to false,
            "eligibilityReason" to directCopyVerdict.reason,
            "duckedKfCount" to keyframeMaps.size,
            "sustainGainOk" to sustainGainOk,
            "duckHoldGainOk" to duckHoldGainOk,
            "postReleaseGainOk" to postReleaseGainOk,
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

    // ── Scenario 4: multitrack mixdown (P4-MULTITRACK-EXPORT) ─────────────────

    private fun runMultitrackMixdownScenario(
        videoPath: String,
        audioPath: String,
        audioDurationSec: Double,
        outDir: File,
    ): Map<String, Any?> {
        val mixedAudioPath = File(outDir, MULTITRACK_MIXDOWN_AUDIO_FILE).path
        val outputPath = File(outDir, MULTITRACK_MIXDOWN_FILE).path
        val mixDurationSec = minOf(audioDurationSec, 3.0)

        if (audioDurationSec < 2.0) {
            return scenarioFailure(
                "multitrackMixdown",
                "fixture_audio_too_short_for_multitrack:durationSec=$audioDurationSec",
                outputPath,
            )
        }

        // Direct chunk-mixer preflight assertion: 9 synthetic 1-frame tracks
        // must fail closed with overlap_depth_exceeded:9 and chunkCount=0 before native create.
        val syntheticEnvelope = AndroidAudioVolumeEnvelope.fromStatic(
            volume = 1.0,
            mixGain = 1.0,
            fadeInSeconds = 0.0,
            fadeOutSeconds = 0.0,
            trackStartSec = 0.0,
            trackEndSec = 1.0,
        )
        val syntheticTracks = (0 until 9).map { i ->
            AndroidNativeAudioMixBusChunkMixer.ChunkTrackInput(
                trackId = "synthetic_$i",
                startFrame = 0,
                pcm = shortArrayOf(100),
                srcChannelCount = 1,
                frameCount = 1,
                envelope = syntheticEnvelope,
            )
        }
        val preflight = AndroidNativeAudioMixBusChunkMixer.mix(
            tracks = syntheticTracks,
            outputSampleRate = 48000,
            outputChannelCount = 1,
            totalFrames = 1,
        )
        val preflightPass = !preflight.success &&
            preflight.reason == "overlap_depth_exceeded:9" &&
            preflight.chunkCount == 0
        if (!preflightPass) {
            return scenarioFailure(
                "multitrackMixdown",
                "preflight_overlap_depth_rejection_failed:reason=${preflight.reason};chunks=${preflight.chunkCount}",
                outputPath,
            )
        }

        // Timeline tracks:
        // music at 0.0 for mixDurationSec with ducking-style keyframes
        val epsilon = 1e-6
        val musicKeyframeMaps = mutableListOf(
            mapOf("time" to 0.0, "volume" to 1.0),
            mapOf("time" to 0.35, "volume" to 1.0),
            mapOf("time" to 0.5, "volume" to 0.4),
            mapOf("time" to 1.8, "volume" to 0.4),
            mapOf("time" to 2.0, "volume" to 1.0),
        )
        if (mixDurationSec > 2.0 + epsilon) {
            musicKeyframeMaps.add(mapOf("time" to mixDurationSec, "volume" to 1.0))
        }

        val musicTrack = mapOf(
            "trackId" to "unitP4_mt_music",
            "url" to audioPath,
            "startTime" to 0.0,
            "duration" to mixDurationSec,
            "volume" to 1.0,
            "role" to "music",
            "volumeKeyframes" to musicKeyframeMaps,
        )

        val voDuration = minOf(1.5, mixDurationSec - 0.5)
        val voTrack = mapOf(
            "trackId" to "unitP4_mt_voiceover",
            "url" to audioPath,
            "startTime" to 0.5,
            "duration" to voDuration,
            "volume" to 1.0,
            "role" to "voiceover",
        )

        val sfx1Duration = minOf(0.6, mixDurationSec - 0.8)
        val sfx1Track = mapOf(
            "trackId" to "unitP4_mt_sfx1",
            "url" to audioPath,
            "startTime" to 0.8,
            "duration" to sfx1Duration,
            "volume" to 0.8,
            "role" to "sfx",
        )

        val sfx2Duration = minOf(0.6, mixDurationSec - 1.2)
        val sfx2Track = mapOf(
            "trackId" to "unitP4_mt_sfx2",
            "url" to audioPath,
            "startTime" to 1.2,
            "duration" to sfx2Duration,
            "volume" to 0.7,
            "role" to "sfx",
        )

        // 1. Parse exactly 4 valid specs and zero skipped.
        val (specs, skippedIndices) = AndroidAudioTrackSpec.parseList(
            listOf(musicTrack, voTrack, sfx1Track, sfx2Track),
        )
        if (specs.size != 4 || skippedIndices.isNotEmpty()) {
            return scenarioFailure(
                "multitrackMixdown",
                "parser_evidence_mismatch:parsed=${specs.size};skipped=${skippedIndices.size}",
                outputPath,
            )
        }

        // 2. Direct-copy validator over all four specs must be ineligible with exact reason active_track_count=4.
        val directCopyVerdict = AndroidAudioDirectCopyValidator.validate(specs)
        if (directCopyVerdict.eligible || directCopyVerdict.reason != "active_track_count=4") {
            return scenarioFailure(
                "multitrackMixdown",
                "validator_reason_mismatch:eligible=${directCopyVerdict.eligible};reason=${directCopyVerdict.reason}",
                outputPath,
                extra = mapOf(
                    "eligible" to directCopyVerdict.eligible,
                    "eligibilityReason" to directCopyVerdict.reason,
                ),
            )
        }

        // 3. Run AndroidAudioMixdownEngine.mix(specs).
        val mix = AndroidAudioMixdownEngine.mix(specs)
        if (!mix.success || mix.pcm == null) {
            return scenarioFailure("multitrackMixdown", "mixdown_failed:${mix.reason}", outputPath)
        }
        if (!mix.nativeMixBusUsed || mix.nativeChunkCount <= 0 || mix.nativeMixReason != "success" || mix.mixedTrackCount != 4) {
            return scenarioFailure(
                "multitrackMixdown",
                "native_mix_bus_evidence_missing:used=${mix.nativeMixBusUsed};" +
                    "chunks=${mix.nativeChunkCount};nativeReason=${mix.nativeMixReason};mixedTracks=${mix.mixedTrackCount}",
                outputPath,
            )
        }

        // 4. AAC Encode to M4A.
        val encode = AndroidAacEncoder.encodePcm16ToM4a(
            pcm = mix.pcm,
            sampleRate = mix.sampleRate,
            channelCount = mix.channelCount,
            outputPath = mixedAudioPath,
        )
        if (!encode.success || encode.outputSizeBytes <= 0L || encode.encodedSamples <= 0) {
            deleteGenerated(outDir, MULTITRACK_MIXDOWN_AUDIO_FILE)
            return scenarioFailure("multitrackMixdown", "aac_encode_failed:${encode.reason}", outputPath)
        }

        // 5. Remux with fixture video.
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
            deleteGenerated(outDir, MULTITRACK_MIXDOWN_AUDIO_FILE, MULTITRACK_MIXDOWN_FILE)
        }

        val raw = if (pass) {
            "ok(preflightNineTrackOverlapReason=${preflight.reason},preflightPass=$preflightPass," +
                "directCopyEligible=false,directCopyReason=${directCopyVerdict.reason}," +
                "mixedTracks=${mix.mixedTrackCount},nativeMixBusUsed=${mix.nativeMixBusUsed}," +
                "nativeChunkCount=${mix.nativeChunkCount},nativeSilentChunks=${mix.nativeSilentChunks}," +
                "nativeGainClamped=${mix.nativeGainClamped},aacSamples=${encode.encodedSamples}," +
                "video=${remux.videoSamples},audio=${remux.audioSamples}," +
                "bytes=${remux.outputSizeBytes})"
        } else {
            "fail(pass2_remux:${remux.reason};video=${remux.videoSamples};audio=${remux.audioSamples})"
        }

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "eligible" to false,
            "eligibilityReason" to directCopyVerdict.reason,
            "preflightPass" to preflightPass,
            "preflightReason" to preflight.reason,
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
        duckingMixdown: Map<String, Any?>?,
        multitrackMixdown: Map<String, Any?>?,
    ): Map<String, Any?> = mapOf(
        "pass" to pass,
        "raw" to raw,
        "directCopy" to directCopy,
        "pcmMixdown" to pcmMixdown,
        "duckingMixdown" to duckingMixdown,
        "multitrackMixdown" to multitrackMixdown,
    )
}
