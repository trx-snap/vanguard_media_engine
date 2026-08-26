package com.connects.vanguard_media_engine.export

import android.util.Log

// ── AndroidAudioMixdownEngine (Export/Audio Unit B) ───────────────────────────
//
// Diagnostic PCM mixdown: decodes each valid sidecar track, places it at its
// startTime on an output-timeline buffer, applies the per-track
// AndroidAudioVolumeEnvelope gain per sample frame, sums into an integer
// accumulator, and clamps to 16-bit.
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

/// Structured mixdown outcome. [pcm] is 16-bit interleaved output-timeline
/// samples on success.
data class AndroidAudioMixdownResult(
    val success: Boolean,
    val reason: String,
    val pcm: ShortArray?,
    val sampleRate: Int,
    val channelCount: Int,
    val frameCount: Int,
    val mixedTrackCount: Int,
    val skippedTracks: List<String>,
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
        val accumulator = IntArray(totalFrames * outputChannels)

        for (d in decoded) {
            val spec = d.spec
            val decode = d.decode
            val pcm = decode.pcm!!
            val srcChannels = decode.channelCount
            val placedFrames = decode.frameCount
            val startFrame = Math.round(spec.startTime * outputSampleRate).toInt()
            val trackStartSec = spec.startTime
            val trackEndSec = spec.startTime + placedFrames.toDouble() / outputSampleRate
            val envelope = AndroidAudioVolumeEnvelope.forTrack(spec, trackStartSec, trackEndSec)

            for (frame in 0 until placedFrames) {
                val outFrame = startFrame + frame
                if (outFrame >= totalFrames) break
                val timeSec = outFrame.toDouble() / outputSampleRate
                val gain = envelope.evaluate(timeSec)
                if (gain == 0.0) continue

                val srcBase = frame * srcChannels
                val outBase = outFrame * outputChannels
                if (srcChannels == outputChannels) {
                    for (ch in 0 until outputChannels) {
                        accumulator[outBase + ch] += (pcm[srcBase + ch] * gain).toInt()
                    }
                } else if (srcChannels == 1) {
                    // Mono source → duplicate into each output channel.
                    val scaled = (pcm[srcBase] * gain).toInt()
                    for (ch in 0 until outputChannels) {
                        accumulator[outBase + ch] += scaled
                    }
                } else {
                    // Stereo source → mono output: simple average downmix.
                    val avg = (pcm[srcBase].toInt() + pcm[srcBase + 1].toInt()) / 2
                    accumulator[outBase] += (avg * gain).toInt()
                }
            }
        }

        val mixedPcm = ShortArray(accumulator.size) { i ->
            accumulator[i].coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }

        Log.i(
            TAG,
            "mix OK — tracks=${decoded.size} skipped=${skipped.size} " +
                "frames=$totalFrames rate=$outputSampleRate ch=$outputChannels",
        )
        return AndroidAudioMixdownResult(
            success = true,
            reason = "success",
            pcm = mixedPcm,
            sampleRate = outputSampleRate,
            channelCount = outputChannels,
            frameCount = totalFrames,
            mixedTrackCount = decoded.size,
            skippedTracks = skipped,
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
