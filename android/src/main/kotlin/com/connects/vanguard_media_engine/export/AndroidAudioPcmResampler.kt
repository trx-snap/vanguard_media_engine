package com.connects.vanguard_media_engine.export

// ── AndroidAudioPcmResampler (Export/Audio Unit B helper) ─────────────────────
//
// Deterministic, bounded PCM16 sample-rate conversion used by
// AndroidAudioMixdownEngine before a decoded sidecar track is handed to
// AndroidNativeAudioGraphExportMixer. Pure Kotlin integer/long arithmetic,
// linear interpolation between adjacent source frames, no OS resampler,
// no allocation beyond the output buffer, no I/O, no threads.
//
// Contract:
//   - Input is interleaved PCM16 with [channelCount] samples per frame.
//   - Channel count is preserved; channel conversion stays owned by the
//     native graph path.
//   - Output frame count is ceil(inputFrames * toRate / fromRate) computed in
//     Long arithmetic, and the returned buffer always holds exactly
//     outputFrames * channelCount samples so downstream frame indexing is
//     safe.
//   - Malformed input (non-positive rates, channel count outside 1..2,
//     pcm shorter than the claimed frame count) is clamped or rejected
//     with a structured reason; the helper never throws on such input.

/// Structured resample outcome. On success [pcm] is non-null and sized
/// exactly frameCount * channelCount.
data class AndroidAudioPcmResampleResult(
    val success: Boolean,
    val reason: String,
    val pcm: ShortArray?,
    val sampleRate: Int,
    val channelCount: Int,
    val frameCount: Int,
) {
    override fun equals(other: Any?): Boolean = this === other
    override fun hashCode(): Int = System.identityHashCode(this)
}

object AndroidAudioPcmResampler {

    /// Upper bound on produced frames; keeps the output allocation bounded
    /// even for malformed rate pairs. 600 s at 192 kHz is ~115 M frames,
    /// comfortably above any timeline this engine admits.
    private const val MAX_OUTPUT_FRAMES = 600L * 192_000L

    /// Linear-interpolation resample of [pcm] from [fromRate] to [toRate].
    /// When the rates are equal the input buffer is returned untouched
    /// (no copy) so same-rate tracks keep their exact byte path.
    fun resample(
        pcm: ShortArray,
        frameCount: Int,
        channelCount: Int,
        fromRate: Int,
        toRate: Int,
    ): AndroidAudioPcmResampleResult {
        if (fromRate <= 0 || toRate <= 0) {
            return failure("invalid_rate:$fromRate->$toRate", channelCount)
        }
        if (channelCount !in 1..2) {
            return failure("unsupported_channel_count:$channelCount", channelCount)
        }
        if (frameCount < 0) {
            return failure("invalid_frame_count:$frameCount", channelCount)
        }
        // Never trust the claimed frame count past the buffer actually held.
        val availableFrames = pcm.size / channelCount
        val inputFrames = minOf(frameCount, availableFrames)

        if (fromRate == toRate) {
            return AndroidAudioPcmResampleResult(
                success = true,
                reason = "passthrough",
                pcm = pcm,
                sampleRate = toRate,
                channelCount = channelCount,
                frameCount = inputFrames,
            )
        }
        if (inputFrames == 0) {
            return AndroidAudioPcmResampleResult(
                success = true,
                reason = "empty",
                pcm = ShortArray(0),
                sampleRate = toRate,
                channelCount = channelCount,
                frameCount = 0,
            )
        }

        // ceil(inputFrames * toRate / fromRate) in Long so 48000 * 44100-ish
        // products never overflow Int.
        val outputFramesLong =
            (inputFrames.toLong() * toRate.toLong() + fromRate.toLong() - 1L) / fromRate.toLong()
        if (outputFramesLong <= 0L || outputFramesLong > MAX_OUTPUT_FRAMES) {
            return failure("output_frames_out_of_range:$outputFramesLong", channelCount)
        }
        val outputFrames = outputFramesLong.toInt()
        val outputSampleCount = outputFramesLong * channelCount.toLong()
        if (outputSampleCount > Int.MAX_VALUE.toLong()) {
            return failure("output_samples_out_of_range:$outputSampleCount", channelCount)
        }

        val out = ShortArray(outputSampleCount.toInt())
        val lastFrame = inputFrames - 1
        val toRateL = toRate.toLong()
        val fromRateL = fromRate.toLong()

        // Exact rational source position for output frame i:
        //   srcPos = i * fromRate / toRate
        //   index  = floor(srcPos), frac = (i * fromRate) mod toRate / toRate
        // All in Long; per-sample interpolation done in Long then clamped to
        // int16 (clamp is defensive only — lerp of two int16 values can't
        // leave the range, but rounding is explicit).
        for (i in 0 until outputFrames) {
            val numerator = i.toLong() * fromRateL
            var index = (numerator / toRateL).toInt()
            var fracNum = numerator % toRateL
            if (index >= lastFrame) {
                index = lastFrame
                fracNum = 0L
            }
            val nextIndex = if (index < lastFrame) index + 1 else index
            val srcBase = index * channelCount
            val nextBase = nextIndex * channelCount
            val dstBase = i * channelCount
            for (ch in 0 until channelCount) {
                val a = pcm[srcBase + ch].toLong()
                val b = pcm[nextBase + ch].toLong()
                // a + (b - a) * frac, rounded half away from zero on the
                // fractional numerator to stay deterministic.
                val delta = (b - a) * fracNum
                val rounded = if (delta >= 0L) {
                    (delta + toRateL / 2L) / toRateL
                } else {
                    -((-delta + toRateL / 2L) / toRateL)
                }
                val value = a + rounded
                out[dstBase + ch] = when {
                    value > Short.MAX_VALUE.toLong() -> Short.MAX_VALUE
                    value < Short.MIN_VALUE.toLong() -> Short.MIN_VALUE
                    else -> value.toShort()
                }
            }
        }

        return AndroidAudioPcmResampleResult(
            success = true,
            reason = "linear",
            pcm = out,
            sampleRate = toRate,
            channelCount = channelCount,
            frameCount = outputFrames,
        )
    }

    private fun failure(reason: String, channelCount: Int): AndroidAudioPcmResampleResult =
        AndroidAudioPcmResampleResult(
            success = false,
            reason = reason,
            pcm = null,
            sampleRate = 0,
            channelCount = channelCount,
            frameCount = 0,
        )
}
