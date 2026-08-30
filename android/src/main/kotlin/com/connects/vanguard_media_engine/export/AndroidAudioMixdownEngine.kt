package com.connects.vanguard_media_engine.export

import android.util.Log

// ── AndroidAudioMixdownEngine (Export/Audio Unit B) ───────────────────────────
//
// Diagnostic PCM mixdown: decodes each valid sidecar track, places it at its
// startTime on an output-timeline, and routes the placement to
// AndroidNativeAudioMixBusChunkMixer, which slices the timeline into
// kChunkFrames windows and mixes each non-silent window through the native
// vanguard::audio::AudioMixBusNode PCM16 mix bus (per-frame
// AndroidAudioVolumeEnvelope gain is still evaluated in Kotlin; native owns
// channel mapping, summation, and the 16-bit clamp). See
// AndroidNativeAudioMixBusChunkMixer's header for the +/-1 LSB rounding-order
// note versus the old all-Kotlin summation.
//
// Constraints in this slice:
//   - Output sample rate follows the FIRST successfully decoded track
//     (typically 44.1 kHz or 48 kHz). No resampler: a later track with a
//     different sample rate is a structured "sample_rate_mismatch" failure,
//     never a guess.
//   - Mono/stereo only. Mono → stereo duplicates the sample into both
//     channels; stereo → mono averages. More than 2 channels is unsupported.
//   - Tracks that fail parsing/decoding are skipped with evidence in
//     [AndroidAudioMixdownResult.skippedTracks]; at least one track must mix.
//   - More than 2 simultaneously active tracks in any output chunk is an
//     explicit non-claim left to P4-MULTITRACK-EXPORT: mixing fails closed
//     with reason "native_audio_mix_bus:overlap_depth_exceeded:<n>".

/// Structured mixdown outcome. [pcm] is 16-bit interleaved output-timeline
/// samples on success. The native* fields are diagnostic evidence of the
/// P4-AUDIO-MIXBUS chunked native routing and default to their "not used"
/// values for failures that occur before native mixing is attempted.
data class AndroidAudioMixdownResult(
    val success: Boolean,
    val reason: String,
    val pcm: ShortArray?,
    val sampleRate: Int,
    val channelCount: Int,
    val frameCount: Int,
    val mixedTrackCount: Int,
    val skippedTracks: List<String>,
    val nativeMixBusUsed: Boolean = false,
    val nativeChunkCount: Int = 0,
    val nativeSilentChunks: Int = 0,
    val nativeMixReason: String = "",
    val nativeGainClamped: Boolean = false,
) {
    override fun equals(other: Any?): Boolean = this === other
    override fun hashCode(): Int = System.identityHashCode(this)
}

object AndroidAudioMixdownEngine {

    private const val TAG = "VanguardAudioMix"
    private const val MAX_TIMELINE_SECONDS = 600.0

    fun mix(tracks: List<AndroidAudioTrackSpec>): AndroidAudioMixdownResult {
        if (tracks.isEmpty()) {
            return failure("no_tracks")
        }

        // Decode every valid track first so the output geometry (sample rate,
        // channel count, timeline length) is known before summation.
        data class DecodedTrack(
            val spec: AndroidAudioTrackSpec,
            val decode: AndroidAudioPcmDecodeResult,
        )

        val decoded = mutableListOf<DecodedTrack>()
        val skipped = mutableListOf<String>()
        var outputSampleRate = 0

        for (spec in tracks) {
            if (spec.startTime < 0.0) {
                skipped.add("${spec.trackId}:negative_start_time")
                continue
            }
            val decode = AndroidAudioPcmDecoder.decode(
                sourcePath = spec.url,
                sourceTrimStartSec = spec.sourceTrimStart,
                durationSec = spec.duration,
            )
            if (!decode.success || decode.pcm == null) {
                skipped.add("${spec.trackId}:decode_failed:${decode.reason}")
                continue
            }
            if (decode.channelCount !in 1..2) {
                skipped.add("${spec.trackId}:unsupported_channel_count:${decode.channelCount}")
                continue
            }
            if (outputSampleRate == 0) {
                outputSampleRate = decode.sampleRate
            } else if (decode.sampleRate != outputSampleRate) {
                // No resampler in this slice — report, never guess.
                return failure(
                    "sample_rate_mismatch:${spec.trackId}:${decode.sampleRate}!=$outputSampleRate",
                    skipped,
                )
            }
            decoded.add(DecodedTrack(spec, decode))
        }

        if (decoded.isEmpty() || outputSampleRate <= 0) {
            return failure("no_tracks_decoded", skipped)
        }

        val outputChannels = decoded.maxOf { it.decode.channelCount }
        val timelineEndSec = decoded.maxOf { d ->
            d.spec.startTime + d.decode.frameCount.toDouble() / outputSampleRate
        }
        if (timelineEndSec <= 0.0) {
            return failure("empty_timeline", skipped)
        }
        if (timelineEndSec > MAX_TIMELINE_SECONDS) {
            return failure("timeline_too_long:${timelineEndSec}s", skipped)
        }

        val totalFrames = Math.ceil(timelineEndSec * outputSampleRate).toInt()

        val chunkTrackInputs = decoded.map { d ->
            val spec = d.spec
            val decode = d.decode
            val startFrame = Math.round(spec.startTime * outputSampleRate).toInt()
            val trackStartSec = spec.startTime
            val trackEndSec = spec.startTime + decode.frameCount.toDouble() / outputSampleRate
            val envelope = AndroidAudioVolumeEnvelope.forTrack(spec, trackStartSec, trackEndSec)
            AndroidNativeAudioMixBusChunkMixer.ChunkTrackInput(
                trackId = spec.trackId,
                startFrame = startFrame,
                pcm = decode.pcm!!,
                srcChannelCount = decode.channelCount,
                frameCount = decode.frameCount,
                envelope = envelope,
            )
        }

        val nativeResult = AndroidNativeAudioMixBusChunkMixer.mix(
            tracks = chunkTrackInputs,
            outputSampleRate = outputSampleRate,
            outputChannelCount = outputChannels,
            totalFrames = totalFrames,
        )
        if (!nativeResult.success || nativeResult.pcm == null) {
            Log.e(TAG, "native mix bus failed — reason=${nativeResult.reason}")
            return AndroidAudioMixdownResult(
                success = false,
                reason = "native_audio_mix_bus:${nativeResult.reason}",
                pcm = null,
                sampleRate = 0,
                channelCount = 0,
                frameCount = 0,
                mixedTrackCount = 0,
                skippedTracks = skipped,
                nativeMixBusUsed = true,
                nativeChunkCount = nativeResult.chunkCount,
                nativeSilentChunks = nativeResult.silentChunks,
                nativeMixReason = nativeResult.reason,
                nativeGainClamped = nativeResult.gainClamped,
            )
        }

        Log.i(
            TAG,
            "mix OK — tracks=${decoded.size} skipped=${skipped.size} " +
                "frames=$totalFrames rate=$outputSampleRate ch=$outputChannels " +
                "nativeChunks=${nativeResult.chunkCount} nativeSilentChunks=${nativeResult.silentChunks}",
        )
        return AndroidAudioMixdownResult(
            success = true,
            reason = "success",
            pcm = nativeResult.pcm,
            sampleRate = outputSampleRate,
            channelCount = outputChannels,
            frameCount = totalFrames,
            mixedTrackCount = decoded.size,
            skippedTracks = skipped,
            nativeMixBusUsed = true,
            nativeChunkCount = nativeResult.chunkCount,
            nativeSilentChunks = nativeResult.silentChunks,
            nativeMixReason = nativeResult.reason,
            nativeGainClamped = nativeResult.gainClamped,
        )
    }

    private fun failure(
        reason: String,
        skipped: List<String> = emptyList(),
    ): AndroidAudioMixdownResult =
        AndroidAudioMixdownResult(
            success = false,
            reason = reason,
            pcm = null,
            sampleRate = 0,
            channelCount = 0,
            frameCount = 0,
            mixedTrackCount = 0,
            skippedTracks = skipped,
        )
}
