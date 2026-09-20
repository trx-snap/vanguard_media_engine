package com.connects.vanguard_media_engine.export

import android.content.Context
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
//   - Output sample rate is chosen deterministically AFTER every admitted
//     track has decoded: the HIGHEST decoded sample rate wins (so 48 kHz
//     original video audio is preserved when mixed with 44.1 kHz music/VO).
//     Any admitted track at a lower rate is converted to the output rate by
//     AndroidAudioPcmResampler (bounded, deterministic PCM16 linear
//     interpolation, source channel count preserved) before it becomes a
//     GraphTrackInput. Same-rate tracks keep their decoded buffer untouched.
//     A track whose resample fails is skipped with structured evidence,
//     never mixed at the wrong rate.
//   - Mono/stereo only. Mono → stereo duplicates the sample into both
//     channels; stereo → mono averages. More than 2 channels is unsupported.
//   - Tracks that fail parsing/decoding are skipped with evidence in
//     [AndroidAudioMixdownResult.skippedTracks]; at least one track must mix.
//   - More than 8 total decoded tracks is an explicit non-claim: the graph
//     session admits at most 8 sources, so mixing fails closed with reason
//     "native_audio_graph_export:total_track_count_exceeded:<n>".
//   - Long-timeline admission (not unlimited duration): the output timeline
//     is capped at MAX_TIMELINE_SECONDS (3600 s, a practical long-editor
//     limit), and because this route still holds every placed input PCM
//     buffer plus the full output ShortArray in the Java heap at once, the
//     mix is admitted only after an explicit Long-math PCM memory check
//     (placed input bytes + output bytes against a per-process budget) and
//     an Int-overflow guard on the output frame/sample count. Over-budget
//     timelines fail closed with "pcm_memory_budget_exceeded:<est>/<budget>"
//     BEFORE the graph session or the output buffer is created. A streaming
//     (windowed decode -> mix -> encode) mixdown that removes the
//     whole-buffer residency is explicitly future work.

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

    /// Practical long-editor output-timeline limit. This is NOT an unlimited
    /// duration claim: the whole-buffer mixdown below still has to pass
    /// PCM memory admission, which is what actually bounds a 3600 s
    /// timeline on a real device heap.
    private const val MAX_TIMELINE_SECONDS = 3600.0

    /// Upper bound of the whole-buffer PCM budget (placed input PCM bytes +
    /// output PCM bytes). 512 MiB admits a 16 min 48 kHz stereo original
    /// audio track (~176 MiB in + ~176 MiB out) plus short VO/music with
    /// margin; it is lowered per process from Runtime.maxMemory() below.
    private const val PCM_MEMORY_BUDGET_MAX_BYTES = 512L * 1024L * 1024L

    /// Heap headroom kept free for the codec/muxer, graph ingest buffers,
    /// and the rest of the app when the budget is derived from maxMemory.
    private const val PCM_MEMORY_HEAP_HEADROOM_BYTES = 64L * 1024L * 1024L

    /// Floor of the derived budget so a small/unknown heap report never
    /// rejects the short exports that already work today (a 600 s 48 kHz
    /// stereo single-track mix is ~220 MiB in + out).
    private const val PCM_MEMORY_BUDGET_MIN_BYTES = 256L * 1024L * 1024L

    /// Largest JVM array length we are willing to allocate for output PCM
    /// (Int.MAX_VALUE - 8, the conventional JVM max array size).
    private const val MAX_PCM_ARRAY_LENGTH = 2_147_483_639L

    /// [context] is an optional Context forwarded to AndroidAudioPcmDecoder
    /// so a track whose url is a `content://` URI can be opened through the
    /// ContentResolver; POSIX urls never touch it, and a `content://` url
    /// with a null Context is skipped as `decode_failed:exception:...` like
    /// any other undecodable track.
    fun mix(tracks: List<AndroidAudioTrackSpec>, context: Context? = null): AndroidAudioMixdownResult {
        if (tracks.isEmpty()) {
            return failure("no_tracks")
        }

        // Decode every valid track first so the output geometry (sample rate,
        // channel count, timeline length) is known before summation.
        data class DecodedTrack(
            val spec: AndroidAudioTrackSpec,
            val decode: AndroidAudioPcmDecodeResult,
        )

        // Post-resample view of a decoded track at the chosen output rate.
        // [pcm]/[frameCount] are the buffer actually handed to the graph;
        // for same-rate tracks they are the decode buffer itself.
        data class PlacedTrack(
            val spec: AndroidAudioTrackSpec,
            val pcm: ShortArray,
            val channelCount: Int,
            val frameCount: Int,
        )

        val decoded = mutableListOf<DecodedTrack>()
        val skipped = mutableListOf<String>()

        for (spec in tracks) {
            if (spec.startTime < 0.0) {
                skipped.add("${spec.trackId}:negative_start_time")
                continue
            }
            val decode = AndroidAudioPcmDecoder.decode(
                sourcePath = spec.url,
                sourceTrimStartSec = spec.sourceTrimStart,
                durationSec = spec.duration,
                context = context,
            )
            if (!decode.success || decode.pcm == null) {
                skipped.add("${spec.trackId}:decode_failed:${decode.reason}")
                continue
            }
            if (decode.channelCount !in 1..2) {
                skipped.add("${spec.trackId}:unsupported_channel_count:${decode.channelCount}")
                continue
            }
            if (decode.sampleRate <= 0) {
                // A non-positive rate can neither anchor the output rate nor
                // be resampled; skip with evidence instead of dividing by it.
                skipped.add("${spec.trackId}:invalid_sample_rate:${decode.sampleRate}")
                continue
            }
            decoded.add(DecodedTrack(spec, decode))
        }

        if (decoded.isEmpty()) {
            return failure("no_tracks_decoded", skipped)
        }

        // Deterministic output rate: highest rate among all admitted decodes.
        // Chosen only once every decode is known, so ordering of the input
        // list cannot change the result.
        val outputSampleRate = decoded.maxOf { it.decode.sampleRate }

        // Convert every lower-rate track to the output rate before placement.
        // Same-rate tracks pass through with their decode buffer untouched.
        val placed = mutableListOf<PlacedTrack>()
        for (d in decoded) {
            val decode = d.decode
            val pcm = decode.pcm!!
            if (decode.sampleRate == outputSampleRate) {
                placed.add(PlacedTrack(d.spec, pcm, decode.channelCount, decode.frameCount))
                continue
            }
            val resampled = AndroidAudioPcmResampler.resample(
                pcm = pcm,
                frameCount = decode.frameCount,
                channelCount = decode.channelCount,
                fromRate = decode.sampleRate,
                toRate = outputSampleRate,
            )
            if (!resampled.success || resampled.pcm == null) {
                Log.w(
                    TAG,
                    "resample FAILED — track=${d.spec.trackId} " +
                        "from=${decode.sampleRate} to=$outputSampleRate " +
                        "frames=${decode.frameCount} ch=${decode.channelCount} " +
                        "reason=${resampled.reason}",
                )
                skipped.add("${d.spec.trackId}:resample_failed:${resampled.reason}")
                continue
            }
            Log.i(
                TAG,
                "resample OK — track=${d.spec.trackId} " +
                    "fromRate=${decode.sampleRate} toRate=$outputSampleRate " +
                    "originalFrames=${decode.frameCount} " +
                    "resampledFrames=${resampled.frameCount} " +
                    "ch=${resampled.channelCount} mode=${resampled.reason}",
            )
            placed.add(
                PlacedTrack(d.spec, resampled.pcm, resampled.channelCount, resampled.frameCount),
            )
        }

        if (placed.isEmpty()) {
            return failure("no_tracks_decoded", skipped)
        }
        // The pre-resample decode buffers are no longer referenced; drop
        // them so a resampled track's original does not stay resident
        // alongside its placed copy through the mix and the AAC encode.
        decoded.clear()

        val outputChannels = placed.maxOf { it.channelCount }
        val timelineEndSec = placed.maxOf { d ->
            d.spec.startTime + d.frameCount.toDouble() / outputSampleRate
        }
        if (timelineEndSec <= 0.0) {
            return failure("empty_timeline", skipped)
        }
        if (timelineEndSec > MAX_TIMELINE_SECONDS) {
            return failure("timeline_too_long:${timelineEndSec}s", skipped)
        }

        // ── Long-timeline admission (Long math, before any allocation) ──
        // Output geometry is computed in Long first: the graph mixer
        // allocates ShortArray(totalFrames * outputChannels) and the AAC
        // encoder consumes that whole buffer, so both the frame count and
        // the sample count must fit an Int/JVM array BEFORE totalFrames is
        // narrowed. Then the whole-buffer residency (every placed input PCM
        // buffer + the output PCM buffer) is admitted against the
        // per-process budget; over budget fails closed with a stable reason
        // instead of an OutOfMemoryError inside the graph route.
        val totalFramesLong = Math.ceil(timelineEndSec * outputSampleRate).toLong()
        if (totalFramesLong <= 0L || totalFramesLong > MAX_PCM_ARRAY_LENGTH) {
            return failure("timeline_frame_count_overflow:$totalFramesLong", skipped)
        }
        val outputSamplesLong = totalFramesLong * outputChannels.toLong()
        if (outputSamplesLong > MAX_PCM_ARRAY_LENGTH) {
            return failure("timeline_sample_count_overflow:$outputSamplesLong", skipped)
        }
        val inputPcmBytes = placed.sumOf { it.pcm.size.toLong() * 2L }
        val outputPcmBytes = outputSamplesLong * 2L
        val estimatedPcmBytes = inputPcmBytes + outputPcmBytes
        val pcmBudgetBytes = pcmMemoryBudgetBytes()
        if (estimatedPcmBytes > pcmBudgetBytes) {
            Log.w(
                TAG,
                "VG_AUDIO_MIX_ADMISSION rejected — timelineEndSec=$timelineEndSec " +
                    "rate=$outputSampleRate ch=$outputChannels tracks=${placed.size} " +
                    "inputBytes=$inputPcmBytes outputBytes=$outputPcmBytes " +
                    "estimatedBytes=$estimatedPcmBytes budgetBytes=$pcmBudgetBytes",
            )
            return failure(
                "pcm_memory_budget_exceeded:$estimatedPcmBytes/$pcmBudgetBytes",
                skipped,
            )
        }
        Log.i(
            TAG,
            "VG_AUDIO_MIX_ADMISSION ok — timelineEndSec=$timelineEndSec " +
                "frames=$totalFramesLong rate=$outputSampleRate ch=$outputChannels " +
                "tracks=${placed.size} estimatedBytes=$estimatedPcmBytes " +
                "budgetBytes=$pcmBudgetBytes",
        )

        val totalFrames = totalFramesLong.toInt()

        val graphTrackInputs = placed.map { d ->
            val spec = d.spec
            val startFrame = Math.round(spec.startTime * outputSampleRate).toInt()
            val trackStartSec = spec.startTime
            val trackEndSec = spec.startTime + d.frameCount.toDouble() / outputSampleRate
            // Raw spec params only: the native graph owns envelope build and
            // per-frame evaluation. Kotlin converts seconds to integer
            // microseconds here; trackStartUs is rounded independently from
            // startFrame (frame and microsecond axes each round once from
            // the same seconds value).
            AndroidNativeAudioGraphExportMixer.GraphTrackInput(
                trackId = spec.trackId,
                startFrame = startFrame,
                pcm = d.pcm,
                srcChannelCount = d.channelCount,
                frameCount = d.frameCount,
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
                nativeMixTotalTrackCount = placed.size,
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
            "mix OK — tracks=${placed.size} skipped=${skipped.size} " +
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
            mixedTrackCount = placed.size,
            skippedTracks = skipped,
            nativeMixBusUsed = true,
            nativeChunkCount = graphResult.windowCount,
            nativeSilentChunks = graphResult.silentWindowCount,
            nativeMixReason = "success",
            nativeGainClamped = graphResult.gainClamped,
            nativeMixRoute = "graph",
            nativeMixRouteReason = graphResult.reason,
            nativeMixTotalTrackCount = placed.size,
            nativeGraphRoutedSourceCount = graphResult.routedSourceCount,
            nativeGraphWindowCount = graphResult.windowCount,
            nativeEnvelopeApplied = graphResult.nativeEnvelopeApplied,
            nativeEnvelopeEvaluations = graphResult.nativeEnvelopeEvaluations,
            nativeMinEffectiveGain = graphResult.nativeMinEffectiveGain,
            nativeMaxEffectiveGain = graphResult.nativeMaxEffectiveGain,
        )
    }

    /// Per-process whole-buffer PCM budget in bytes:
    /// min(512 MiB, maxMemory - 64 MiB headroom), floored at 256 MiB. The
    /// Java heap ceiling is what actually bounds the ShortArrays this route
    /// holds, so a process whose heap is smaller than the 512 MiB ceiling
    /// gets a lower budget; an unbounded/unknown maxMemory report uses the
    /// ceiling as-is.
    private fun pcmMemoryBudgetBytes(): Long {
        val maxHeap = try {
            Runtime.getRuntime().maxMemory()
        } catch (_: Throwable) {
            Long.MAX_VALUE
        }
        if (maxHeap <= 0L || maxHeap == Long.MAX_VALUE) {
            return PCM_MEMORY_BUDGET_MAX_BYTES
        }
        val heapDerived = maxHeap - PCM_MEMORY_HEAP_HEADROOM_BYTES
        return heapDerived.coerceIn(PCM_MEMORY_BUDGET_MIN_BYTES, PCM_MEMORY_BUDGET_MAX_BYTES)
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
