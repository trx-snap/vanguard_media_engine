package com.connects.vanguard_media_engine.export

import android.util.Log

// ── AndroidAudioMixdownEngine (Export/Audio Unit B) ───────────────────────────
//
// Production Pass-2 PCM mixdown: decodes each valid sidecar track, places it
// at its startTime on an output-timeline, and routes the placement through
// AndroidNativeAudioGraphExportMixer — ONE native True-DAG audio graph
// export session (Graph + AudioMixBusNode + N node-owned
// DecodedAudioPcmSourceNode rings routed by GraphAudioScheduler) that owns
// per-frame gain/envelope evaluation (native AudioGainEnvelope, built from
// the raw spec params), cross-source summation, and the final int16 clamp
// (P4-AUDIO-PASS2-NATIVE-GAIN-ENVELOPE). Kotlin keeps decode, timeline
// placement, and source-channel conversion (mono<->stereo) only; this
// engine passes the raw volume/mixGain/fade/keyframe spec values with
// seconds converted to integer microseconds and does no envelope
// evaluation itself. AndroidAudioVolumeEnvelope remains untouched for
// legacy/harness users. The legacy AndroidNativeAudioMixBusChunkMixer
// remains available for rollback/harness comparison but is no longer the
// production route.
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
//   - More than 8 total decoded tracks is an explicit non-claim: the graph
//     session admits at most 8 sources, so mixing fails closed with reason
//     "native_audio_graph_export:total_track_count_exceeded:<n>".

/// Structured mixdown outcome. [pcm] is 16-bit interleaved output-timeline
/// samples on success. The native* fields are evidence of the native graph
/// routing and default to their "not used" values for failures that occur
/// before native mixing is attempted. nativeChunkCount/nativeSilentChunks/
/// nativeMixReason/nativeGainClamped are kept for caller compatibility and
/// now carry the graph route's windowCount/silentWindowCount/reason/
/// gainClamped ([nativeGainClamped] is native envelope-build evidence, not
/// Kotlin clamping). The nativeEnvelope* fields carry the
/// P4-AUDIO-PASS2-NATIVE-GAIN-ENVELOPE scheduler telemetry aggregated
/// across render windows (applied OR-ed, evaluations summed, min/max over
/// envelope-applied windows).
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
    val nativeMixRoute: String = "",
    val nativeMixRouteReason: String = "",
    val nativeMixTotalTrackCount: Int = 0,
    val nativeGraphRoutedSourceCount: Int = 0,
    val nativeGraphWindowCount: Int = 0,
    val nativeEnvelopeApplied: Boolean = false,
    val nativeEnvelopeEvaluations: Long = 0L,
    val nativeMinEffectiveGain: Double = 0.0,
    val nativeMaxEffectiveGain: Double = 0.0,
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

        val graphTrackInputs = decoded.map { d ->
            val spec = d.spec
            val decode = d.decode
            val startFrame = Math.round(spec.startTime * outputSampleRate).toInt()
            val trackStartSec = spec.startTime
            val trackEndSec = spec.startTime + decode.frameCount.toDouble() / outputSampleRate
            // Raw spec params only: the native graph owns envelope build and
            // per-frame evaluation. Kotlin converts seconds to integer
            // microseconds here; trackStartUs is rounded independently from
            // startFrame (frame and microsecond axes each round once from
            // the same seconds value).
            AndroidNativeAudioGraphExportMixer.GraphTrackInput(
                trackId = spec.trackId,
                startFrame = startFrame,
                pcm = decode.pcm!!,
                srcChannelCount = decode.channelCount,
                frameCount = decode.frameCount,
                volume = spec.volume,
                mixGain = spec.mixGain,
                fadeInUs = Math.round(spec.fadeInSeconds * 1_000_000.0),
                fadeOutUs = Math.round(spec.fadeOutSeconds * 1_000_000.0),
                trackStartUs = Math.round(trackStartSec * 1_000_000.0),
                trackEndUs = Math.round(trackEndSec * 1_000_000.0),
                keyframeTimesUs = spec.volumeKeyframes
                    ?.map { Math.round(it.time * 1_000_000.0) }
                    ?.toLongArray(),
                keyframeGains = spec.volumeKeyframes
                    ?.map { it.volume }
                    ?.toDoubleArray(),
            )
        }

        val graphResult = AndroidNativeAudioGraphExportMixer.mix(
            tracks = graphTrackInputs,
            outputSampleRate = outputSampleRate,
            outputChannelCount = outputChannels,
            totalFrames = totalFrames,
        )
        if (!graphResult.success || graphResult.pcm == null) {
            Log.e(TAG, "native graph export mix failed — reason=${graphResult.reason}")
            return AndroidAudioMixdownResult(
                success = false,
                reason = "native_audio_graph_export:${graphResult.reason}",
                pcm = null,
                sampleRate = 0,
                channelCount = 0,
                frameCount = 0,
                mixedTrackCount = 0,
                skippedTracks = skipped,
                nativeMixBusUsed = true,
                nativeChunkCount = graphResult.windowCount,
                nativeSilentChunks = graphResult.silentWindowCount,
                nativeMixReason = graphResult.reason,
                nativeGainClamped = graphResult.gainClamped,
                nativeMixRoute = "graph",
                nativeMixRouteReason = graphResult.reason,
                nativeMixTotalTrackCount = decoded.size,
                nativeGraphRoutedSourceCount = graphResult.routedSourceCount,
                nativeGraphWindowCount = graphResult.windowCount,
                nativeEnvelopeApplied = graphResult.nativeEnvelopeApplied,
                nativeEnvelopeEvaluations = graphResult.nativeEnvelopeEvaluations,
                nativeMinEffectiveGain = graphResult.nativeMinEffectiveGain,
                nativeMaxEffectiveGain = graphResult.nativeMaxEffectiveGain,
            )
        }

        Log.i(
            TAG,
            "mix OK — tracks=${decoded.size} skipped=${skipped.size} " +
                "frames=$totalFrames rate=$outputSampleRate ch=$outputChannels " +
                "graphWindows=${graphResult.windowCount} " +
                "graphSilentWindows=${graphResult.silentWindowCount} " +
                "graphRoutedSources=${graphResult.routedSourceCount}",
        )
        return AndroidAudioMixdownResult(
            success = true,
            reason = "success",
            pcm = graphResult.pcm,
            sampleRate = outputSampleRate,
            channelCount = outputChannels,
            frameCount = totalFrames,
            mixedTrackCount = decoded.size,
            skippedTracks = skipped,
            nativeMixBusUsed = true,
            nativeChunkCount = graphResult.windowCount,
            nativeSilentChunks = graphResult.silentWindowCount,
            nativeMixReason = "success",
            nativeGainClamped = graphResult.gainClamped,
            nativeMixRoute = "graph",
            nativeMixRouteReason = graphResult.reason,
            nativeMixTotalTrackCount = decoded.size,
            nativeGraphRoutedSourceCount = graphResult.routedSourceCount,
            nativeGraphWindowCount = graphResult.windowCount,
            nativeEnvelopeApplied = graphResult.nativeEnvelopeApplied,
            nativeEnvelopeEvaluations = graphResult.nativeEnvelopeEvaluations,
            nativeMinEffectiveGain = graphResult.nativeMinEffectiveGain,
            nativeMaxEffectiveGain = graphResult.nativeMaxEffectiveGain,
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
