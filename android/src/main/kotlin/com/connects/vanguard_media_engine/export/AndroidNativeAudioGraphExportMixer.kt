package com.connects.vanguard_media_engine.export

import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidNativeAudioGraphExportMixer (Export/Audio Unit B — P4-AUDIO-PASS2-NATIVE-GAIN-ENVELOPE) ──
//
// Production offline Pass-2 PCM mixdown through ONE native True-DAG audio
// graph export session (android_phase4_audio_graph_export_session_jni.cpp
// via VanguardNativeBridge): create -> addTrackWithEnvelope xN
// (DecodedAudioPcmSourceNode node-owned ring/writer/provider,
// timelineStartPtsUs=0 inside native, native AudioGainEnvelope built
// atomically per track) -> prepare (GraphAudioScheduler
// AutoDiscoverSourceProviders over the session-owned mix-params map) ->
// per-window full ingest for EVERY track -> contiguous window render ->
// destroy exactly once.
//
// Ownership split: the NATIVE graph owns per-frame gain/envelope evaluation
// (AudioGainEnvelope + GraphAudioScheduler SourceMixParams + AudioMixBusNode
// effective-gain math), cross-source summation, and the final int16 clamp.
// Kotlin keeps decode, timeline placement, full-window zero-filled ingest,
// and source-channel conversion (mono<->stereo) only — PCM is ingested
// UNSCALED; there is no Kotlin envelope evaluation, gain clamping, or
// sample scaling in this route. Raw spec params travel to native with
// seconds already converted to integer microseconds by the caller; native
// reports gainClamped=true on the add PASS when it had to clamp an
// out-of-range built envelope keyframe (e.g. out-of-range static volume).
//
// Lockstep timeline invariant: every track is added with totalFrames equal
// to the FULL mixdown output timeline length (not the track's own span),
// and every window ingests a full window for every admitted track —
// zero-filled outside that track's overlap span — before rendering that
// same window. GraphAudioScheduler checks node activity at the window
// origin and pulls a full frameCount from each provider; skipping or
// partially ingesting any track in any window drops audio or fails closed
// with source_underrun.
//
// Stateless: every mix() call allocates its own VanguardNativeBridge, one
// native session, MAX_TRACKS direct ingest buffers and one direct output
// buffer (ByteOrder.nativeOrder()), all reused across every window of that
// call; nothing is retained across calls or across JNI boundaries (JNI
// ingest copies the buffer contents into the node-owned ring, so Kotlin is
// free to overwrite the buffer on the next window once the call returns).
//
// More than MAX_TRACKS total tracks fails closed with
// "total_track_count_exceeded:<n>" before any native session is created —
// an explicit non-claim, never a silent drop. There is no fallback to the
// legacy chunk mixer or to Kotlin summation inside this route.
object AndroidNativeAudioGraphExportMixer {

    const val WINDOW_FRAMES = 4096
    const val MAX_TRACKS = 8

    /// One decoded track's placement on the output timeline, ready for
    /// native graph mixing. [startFrame] and [frameCount] are
    /// output-timeline frames (already resolved by the caller from
    /// spec.startTime / decode.frameCount at outputSampleRate). The
    /// gain/envelope params are RAW spec values with seconds already
    /// converted to integer microseconds ([fadeInUs], [fadeOutUs],
    /// [trackStartUs], [trackEndUs], [keyframeTimesUs]); the native
    /// envelope builder owns normalisation, clamping, and evaluation.
    /// [keyframeTimesUs]/[keyframeGains] must both be null or both present
    /// with identical lengths.
    data class GraphTrackInput(
        val trackId: String,
        val startFrame: Int,
        val pcm: ShortArray,
        val srcChannelCount: Int,
        val frameCount: Int,
        val volume: Double,
        val mixGain: Double,
        val fadeInUs: Long,
        val fadeOutUs: Long,
        val trackStartUs: Long,
        val trackEndUs: Long,
        val keyframeTimesUs: LongArray?,
        val keyframeGains: DoubleArray?,
    )

    /// [gainClamped] is native evidence: true when any track's built native
    /// envelope carried an out-of-range keyframe that native clamped. The
    /// nativeEnvelope* fields aggregate the render-window scheduler
    /// telemetry: applied is OR-ed, evaluations summed, min/max span the
    /// envelope-applied windows only (0.0/0.0 when none).
    data class GraphMixResult(
        val success: Boolean,
        val reason: String,
        val pcm: ShortArray?,
        val windowCount: Int,
        val silentWindowCount: Int,
        val gainClamped: Boolean,
        val routedSourceCount: Int = 0,
        val nativeEnvelopeApplied: Boolean = false,
        val nativeEnvelopeEvaluations: Long = 0L,
        val nativeMinEffectiveGain: Double = 0.0,
        val nativeMaxEffectiveGain: Double = 0.0,
    )

    fun mix(
        tracks: List<GraphTrackInput>,
        outputSampleRate: Int,
        outputChannelCount: Int,
        totalFrames: Int,
    ): GraphMixResult {
        if (outputSampleRate <= 0 || outputChannelCount !in 1..2 || totalFrames <= 0) {
            return GraphMixResult(false, "invalid_output_geometry", null, 0, 0, false)
        }
        if (tracks.isEmpty()) {
            return GraphMixResult(false, "no_tracks", null, 0, 0, false)
        }
        if (tracks.size > MAX_TRACKS) {
            return GraphMixResult(
                false, "total_track_count_exceeded:${tracks.size}", null, 0, 0, false,
            )
        }

        val diagnostics = VanguardDiagnostics()
        val bridge = VanguardNativeBridge(
            lifecycleObserver = VanguardLifecycleObserver(diagnostics),
            diagnostics = diagnostics,
            codecAdapter = null,
        )

        var sessionId: String? = null
        var failureResult: GraphMixResult? = null
        var windowCount = 0
        var silentWindowCount = 0
        var gainClamped = false
        var routedSourceCount = 0
        var envelopeApplied = false
        var envelopeEvaluations = 0L
        var minEffectiveGain = 0.0
        var maxEffectiveGain = 0.0

        fun fail(reason: String): GraphMixResult {
            val result = GraphMixResult(
                false, reason, null, windowCount, silentWindowCount, gainClamped,
                routedSourceCount, envelopeApplied, envelopeEvaluations,
                minEffectiveGain, maxEffectiveGain,
            )
            failureResult = result
            return result
        }

        try {
            val createRaw = bridge.createAndroidDagPhase4AudioGraphExportSession(
                sampleRate = outputSampleRate,
                channelCount = outputChannelCount,
                maxFramesPerMix = WINDOW_FRAMES,
            )
            val createdId = extractField(createRaw, "sessionId")
            if (!createRaw.startsWith("status=PASS") || createdId == null) {
                return fail("create_failed:${extractField(createRaw, "reason") ?: createRaw}")
            }
            sessionId = createdId
            val sid: String = createdId

            // Native ids src_0..src_N-1 avoid duplicate user track IDs;
            // failure messages still carry the original trackId. Each add
            // atomically builds the native envelope from the raw spec
            // params before any graph mutation.
            for ((index, track) in tracks.withIndex()) {
                val addRaw = bridge.addAndroidDagPhase4AudioGraphExportTrackWithEnvelope(
                    sessionId = sid,
                    trackId = "src_$index",
                    totalFrames = totalFrames.toLong(),
                    volume = track.volume,
                    mixGain = track.mixGain,
                    fadeInUs = track.fadeInUs,
                    fadeOutUs = track.fadeOutUs,
                    trackStartUs = track.trackStartUs,
                    trackEndUs = track.trackEndUs,
                    keyframeTimesUs = track.keyframeTimesUs,
                    keyframeGains = track.keyframeGains,
                )
                if (!addRaw.startsWith("status=PASS")) {
                    return fail(
                        "add_failed:${track.trackId}:" +
                            "${extractField(addRaw, "reason") ?: addRaw}"
                    )
                }
                if (extractField(addRaw, "gainClamped") == "true") {
                    gainClamped = true
                }
            }

            val prepareRaw = bridge.prepareAndroidDagPhase4AudioGraphExportSession(sid)
            if (!prepareRaw.startsWith("status=PASS")) {
                return fail("prepare_failed:${extractField(prepareRaw, "reason") ?: prepareRaw}")
            }
            routedSourceCount = extractField(prepareRaw, "routedSourceCount")?.toIntOrNull() ?: 0
            if (routedSourceCount != tracks.size) {
                return fail(
                    "prepare_failed:routed_source_count_mismatch:" +
                        "$routedSourceCount/${tracks.size}"
                )
            }

            // srcChannelCount != outputChannelCount only via the two frozen
            // conversions below; anything else fails closed before any
            // window is prepared (session destroy still runs in finally).
            for (track in tracks) {
                if (track.srcChannelCount !in 1..2) {
                    return fail(
                        "unsupported_channel_count:${track.trackId}:${track.srcChannelCount}"
                    )
                }
            }

            // Reused for every window of this call — MAX_TRACKS ingest
            // buffers plus one output buffer, all sized for a full window
            // at the OUTPUT channel count (conversion happens before
            // ingest, so every ingest buffer is output-shaped).
            val trackBuffers = Array(MAX_TRACKS) {
                ByteBuffer.allocateDirect(WINDOW_FRAMES * outputChannelCount * 2)
                    .order(ByteOrder.nativeOrder())
            }
            val outBuffer = ByteBuffer.allocateDirect(WINDOW_FRAMES * outputChannelCount * 2)
                .order(ByteOrder.nativeOrder())
            val windowSamples = ShortArray(WINDOW_FRAMES * outputChannelCount)
            val outputPcm = ShortArray(totalFrames * outputChannelCount)

            var windowStart = 0
            while (windowStart < totalFrames) {
                val framesToRender = minOf(WINDOW_FRAMES, totalFrames - windowStart)

                // Lockstep ingest: EVERY track gets a full window every
                // window, zero-filled outside its overlap span. Samples are
                // UNSCALED — the native graph owns all gain/envelope math —
                // so Kotlin only converts source channels to output
                // channels here.
                for ((index, track) in tracks.withIndex()) {
                    for (frame in 0 until framesToRender) {
                        val outFrame = windowStart + frame
                        val srcFrame = outFrame - track.startFrame
                        val dstBase = frame * outputChannelCount
                        if (srcFrame < 0 || srcFrame >= track.frameCount) {
                            for (ch in 0 until outputChannelCount) {
                                windowSamples[dstBase + ch] = 0
                            }
                            continue
                        }
                        val srcBase = srcFrame * track.srcChannelCount
                        when {
                            track.srcChannelCount == outputChannelCount -> {
                                for (ch in 0 until outputChannelCount) {
                                    windowSamples[dstBase + ch] = track.pcm[srcBase + ch]
                                }
                            }
                            track.srcChannelCount == 1 && outputChannelCount == 2 -> {
                                val sample = track.pcm[srcBase]
                                windowSamples[dstBase] = sample
                                windowSamples[dstBase + 1] = sample
                            }
                            else -> { // stereo source -> mono output
                                val left = track.pcm[srcBase].toInt()
                                val right = track.pcm[srcBase + 1].toInt()
                                windowSamples[dstBase] = ((left + right) / 2).toShort()
                            }
                        }
                    }

                    val buffer = trackBuffers[index]
                    buffer.clear()
                    buffer.asShortBuffer()
                        .put(windowSamples, 0, framesToRender * outputChannelCount)
                    val ingestRaw = bridge.ingestAndroidDagPhase4AudioGraphExportTrackPcm(
                        sessionId = sid,
                        trackId = "src_$index",
                        pcmBuffer = buffer,
                        frameCount = framesToRender,
                    )
                    if (!ingestRaw.startsWith("status=PASS")) {
                        return fail(
                            "ingest_failed:${track.trackId}:" +
                                "${extractField(ingestRaw, "reason") ?: ingestRaw}"
                        )
                    }
                }

                outBuffer.clear()
                val renderRaw = bridge.renderAndroidDagPhase4AudioGraphExportWindow(
                    sessionId = sid,
                    startFrame = windowStart.toLong(),
                    frameCount = framesToRender,
                    outPcmBuffer = outBuffer,
                )
                if (!renderRaw.startsWith("status=PASS")) {
                    // Preserves native reason tokens (source_underrun:<id>,
                    // non_contiguous_window:<expected>/<got>, ...).
                    return fail(
                        "render_failed:${extractField(renderRaw, "reason") ?: renderRaw}"
                    )
                }

                val outShortBuf = outBuffer.asShortBuffer()
                val dstBase = windowStart * outputChannelCount
                val sampleCount = framesToRender * outputChannelCount
                for (i in 0 until sampleCount) {
                    outputPcm[dstBase + i] = outShortBuf.get(i)
                }
                windowCount++
                if (extractField(renderRaw, "silence") == "true") {
                    silentWindowCount++
                }
                if (extractField(renderRaw, "envelopeApplied") == "true") {
                    val windowEvaluations =
                        extractField(renderRaw, "envelopeEvaluations")?.toLongOrNull() ?: 0L
                    val windowMin =
                        extractField(renderRaw, "minEffectiveGain")?.toDoubleOrNull() ?: 0.0
                    val windowMax =
                        extractField(renderRaw, "maxEffectiveGain")?.toDoubleOrNull() ?: 0.0
                    envelopeEvaluations += windowEvaluations
                    if (!envelopeApplied) {
                        minEffectiveGain = windowMin
                        maxEffectiveGain = windowMax
                    } else {
                        minEffectiveGain = minOf(minEffectiveGain, windowMin)
                        maxEffectiveGain = maxOf(maxEffectiveGain, windowMax)
                    }
                    envelopeApplied = true
                }
                windowStart += framesToRender
            }

            return GraphMixResult(
                true, "success", outputPcm, windowCount, silentWindowCount, gainClamped,
                routedSourceCount, envelopeApplied, envelopeEvaluations,
                minEffectiveGain, maxEffectiveGain,
            )
        } finally {
            // Exactly-once destroy for the session created above. A prior
            // failure must propagate — only a destroy failure on an
            // otherwise successful mix fails the whole mix closed.
            sessionId?.let {
                val destroyRaw = bridge.destroyAndroidDagPhase4AudioGraphExportSession(it)
                if (failureResult == null && !destroyRaw.startsWith("status=PASS")) {
                    return GraphMixResult(
                        false,
                        "destroy_failed:${extractField(destroyRaw, "reason") ?: destroyRaw}",
                        null, windowCount, silentWindowCount, gainClamped, routedSourceCount,
                        envelopeApplied, envelopeEvaluations,
                        minEffectiveGain, maxEffectiveGain,
                    )
                }
            }
        }
    }

    private fun extractField(raw: String, field: String): String? {
        for (part in raw.split(";")) {
            val idx = part.indexOf('=')
            if (idx <= 0) continue
            if (part.substring(0, idx) == field) return part.substring(idx + 1)
        }
        return null
    }
}
