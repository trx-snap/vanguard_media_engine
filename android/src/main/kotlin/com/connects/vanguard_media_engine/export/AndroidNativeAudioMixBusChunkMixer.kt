package com.connects.vanguard_media_engine.export

import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidNativeAudioMixBusChunkMixer (Export/Audio Unit B — P4-AUDIO-MIXBUS) ──
//
// Chunked bridge from AndroidAudioMixdownEngine's decoded-track output-timeline
// placement to the native vanguard::audio::AudioMixBusNode PCM16 mix bus
// (up to eight inputs, maxFramesPerMix<=8192, append-only addTrack, explicit
// session destroy per VanguardNativeBridge's P4-AUDIO-MIXBUS externs). Kotlin
// remains the sole owner of decode/AAC/envelope evaluation; this object only
// slices already-decoded PCM16 spans into kChunkFrames windows, evaluates
// AndroidAudioVolumeEnvelope gain per output frame, and hands each non-silent
// chunk to one short-lived native mix-bus session that owns channel mapping,
// summation, int16 clamp, and checksum/clipped metrics.
//
// Stateless: every mix() call allocates its own VanguardNativeBridge and
// reuses exactly MAX_ACTIVE_TRACKS direct track buffers plus one direct
// output buffer (ByteOrder.nativeOrder()) across every chunk of that call;
// nothing is retained across calls or across JNI boundaries (JNI addTrack
// copies the buffer contents internally, so Kotlin is free to overwrite it
// on the next chunk once the call returns).
//
// A chunk with more than MAX_ACTIVE_TRACKS simultaneously active tracks fails
// closed with "overlap_depth_exceeded:<n>" before any native session is
// created -- an explicit non-claim, never a silent drop.
//
// Because Kotlin now applies the per-output-frame volume envelope BEFORE
// handing PCM16 to native for stereo<->mono channel mapping/downmix (instead
// of the old Kotlin summation applying gain post-downmix), a stereo-to-mono
// or mono-to-stereo mix can differ by up to +/-1 LSB from the previous
// all-Kotlin path's rounding order. This is expected and is not a claim of
// byte-identical output with the old Kotlin summation.
object AndroidNativeAudioMixBusChunkMixer {

    private const val CHUNK_FRAMES = 4096
    private const val MAX_ACTIVE_TRACKS = 8

    /// One decoded track's placement on the output timeline, ready for native
    /// chunked mixing. [startFrame] and [frameCount] are output-timeline
    /// frames (already resolved by the caller from spec.startTime /
    /// decode.frameCount at outputSampleRate).
    data class ChunkTrackInput(
        val trackId: String,
        val startFrame: Int,
        val pcm: ShortArray,
        val srcChannelCount: Int,
        val frameCount: Int,
        val envelope: AndroidAudioVolumeEnvelope,
    )

    data class NativeMixResult(
        val success: Boolean,
        val reason: String,
        val pcm: ShortArray?,
        val chunkCount: Int,
        val silentChunks: Int,
        val gainClamped: Boolean,
    )

    private data class ChunkPlan(
        val chunkStartFrame: Int,
        val framesToMix: Int,
        val activeTracks: List<ChunkTrackInput>,
    )

    fun mix(
        tracks: List<ChunkTrackInput>,
        outputSampleRate: Int,
        outputChannelCount: Int,
        totalFrames: Int,
    ): NativeMixResult {
        if (outputSampleRate <= 0 || outputChannelCount <= 0 || totalFrames <= 0) {
            return NativeMixResult(false, "invalid_output_geometry", null, 0, 0, false)
        }

        // Preflight the full chunk grid's overlap depth before allocating any
        // buffers/bridge or creating a single native session -- otherwise a
        // violation discovered only on a later chunk would leak the native
        // sessions already created (and destroyed) for earlier chunks.
        val chunkPlans = mutableListOf<ChunkPlan>()
        var planCursor = 0
        while (planCursor < totalFrames) {
            val framesToMix = minOf(CHUNK_FRAMES, totalFrames - planCursor)
            val chunkStartFrame = planCursor
            val chunkEndFrameExclusive = planCursor + framesToMix
            val activeTracks = tracks.filter { t ->
                val trackEndFrame = t.startFrame + t.frameCount
                t.startFrame < chunkEndFrameExclusive && trackEndFrame > chunkStartFrame
            }
            if (activeTracks.size > MAX_ACTIVE_TRACKS) {
                return NativeMixResult(
                    false,
                    "overlap_depth_exceeded:${activeTracks.size}",
                    null, 0, 0, false,
                )
            }
            chunkPlans.add(ChunkPlan(chunkStartFrame, framesToMix, activeTracks))
            planCursor += framesToMix
        }

        val diagnostics = VanguardDiagnostics()
        val bridge = VanguardNativeBridge(
            lifecycleObserver = VanguardLifecycleObserver(diagnostics),
            diagnostics = diagnostics,
            codecAdapter = null,
        )

        val outputPcm = ShortArray(totalFrames * outputChannelCount)
        var chunkCount = 0
        var silentChunks = 0
        var gainClamped = false

        // Reused for every chunk of this call -- MAX_ACTIVE_TRACKS track
        // buffers plus one output buffer, all sized for the largest possible
        // chunk (kChunkFrames * outputChannelCount); every track's
        // srcChannelCount <= outputChannelCount by construction
        // (outputChannelCount is the max channel count across decoded
        // tracks), so these sizes are always sufficient.
        val trackBuffers = Array(MAX_ACTIVE_TRACKS) {
            ByteBuffer.allocateDirect(CHUNK_FRAMES * outputChannelCount * 2)
                .order(ByteOrder.nativeOrder())
        }
        val outBuffer = ByteBuffer.allocateDirect(CHUNK_FRAMES * outputChannelCount * 2)
            .order(ByteOrder.nativeOrder())

        for (plan in chunkPlans) {
            val framesToMix = plan.framesToMix
            val chunkStartFrame = plan.chunkStartFrame
            val activeTracks = plan.activeTracks

            if (activeTracks.isEmpty()) {
                // outputPcm is already zero-initialized for this span.
                silentChunks++
                continue
            }

            var sessionId: String? = null
            var chunkFailureResult: NativeMixResult? = null
            try {
                val createRaw = bridge.createAndroidDagPhase4AudioMixBusSession(
                    nodeId = "p4_audio_mixdown_chunk_$chunkCount",
                    sampleRate = outputSampleRate,
                    channelCount = outputChannelCount,
                    maxFramesPerMix = CHUNK_FRAMES,
                )
                val createdId = extractField(createRaw, "sessionId")
                if (!createRaw.startsWith("status=PASS") || createdId == null) {
                    val result = NativeMixResult(
                        false,
                        "create_failed:${extractField(createRaw, "reason") ?: createRaw}",
                        null, chunkCount, silentChunks, gainClamped,
                    )
                    chunkFailureResult = result
                    return result
                }
                sessionId = createdId

                for ((trackIndex, track) in activeTracks.withIndex()) {
                    val buffer = trackBuffers[trackIndex]
                    buffer.clear()
                    val chunkSamples = ShortArray(framesToMix * track.srcChannelCount)
                    for (frame in 0 until framesToMix) {
                        val outFrame = chunkStartFrame + frame
                        val srcFrame = outFrame - track.startFrame
                        if (srcFrame < 0 || srcFrame >= track.frameCount) continue
                        val timeSec = outFrame.toDouble() / outputSampleRate
                        val rawGain = track.envelope.evaluate(timeSec)
                        val gain = rawGain.coerceIn(0.0, 1.0)
                        if (gain != rawGain) gainClamped = true
                        val srcBase = srcFrame * track.srcChannelCount
                        val dstBase = frame * track.srcChannelCount
                        for (ch in 0 until track.srcChannelCount) {
                            val scaled = (track.pcm[srcBase + ch] * gain).toInt()
                                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                            chunkSamples[dstBase + ch] = scaled.toShort()
                        }
                    }
                    buffer.asShortBuffer().put(chunkSamples)

                    val addRaw = bridge.addAndroidDagPhase4AudioMixBusTrack(
                        sessionId = sessionId,
                        pcm16Buffer = buffer,
                        frameCount = framesToMix,
                        sampleRate = outputSampleRate,
                        channelCount = track.srcChannelCount,
                        gain = 1.0,
                    )
                    if (!addRaw.startsWith("status=PASS")) {
                        val result = NativeMixResult(
                            false,
                            "add_failed:${extractField(addRaw, "reason") ?: addRaw}",
                            null, chunkCount, silentChunks, gainClamped,
                        )
                        chunkFailureResult = result
                        return result
                    }
                }

                outBuffer.clear()
                val mixRaw = bridge.mixAndroidDagPhase4AudioMixBusSession(sessionId, framesToMix, outBuffer)
                if (!mixRaw.startsWith("status=PASS")) {
                    val result = NativeMixResult(
                        false,
                        "mix_failed:${extractField(mixRaw, "reason") ?: mixRaw}",
                        null, chunkCount, silentChunks, gainClamped,
                    )
                    chunkFailureResult = result
                    return result
                }

                val outShortBuf = outBuffer.asShortBuffer()
                val dstBase = chunkStartFrame * outputChannelCount
                val sampleCount = framesToMix * outputChannelCount
                for (i in 0 until sampleCount) {
                    outputPcm[dstBase + i] = outShortBuf.get(i)
                }
                chunkCount++
            } finally {
                // Exactly-once destroy for the session created above. If an
                // earlier native call already failed this chunk, that
                // failure is what must propagate -- do not return from here
                // and obscure it. Only a destroy failure on an otherwise
                // successful chunk fails the whole mix closed.
                sessionId?.let {
                    val destroyRaw = bridge.destroyAndroidDagPhase4AudioMixBusSession(it)
                    if (chunkFailureResult == null && !destroyRaw.startsWith("status=PASS")) {
                        return NativeMixResult(
                            false,
                            "destroy_failed:${extractField(destroyRaw, "reason") ?: destroyRaw}",
                            null, chunkCount, silentChunks, gainClamped,
                        )
                    }
                }
            }
        }

        return NativeMixResult(true, "success", outputPcm, chunkCount, silentChunks, gainClamped)
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
