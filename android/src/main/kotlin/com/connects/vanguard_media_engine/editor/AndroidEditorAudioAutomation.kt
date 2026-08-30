package com.connects.vanguard_media_engine.editor

/**
 * A single volume automation point for [AndroidEditorAddedAudioTrackConfig.volumeKeyframes].
 *
 * [timeUs] is a global editor-timeline PTS in microseconds — the same basis as
 * [AndroidEditorAddedAudioTrackConfig.trackStartUs] (matches the wire VGAudioSidecarTrack
 * contract: keyframe `time` is output-timeline seconds, same basis as `startTime`). [volume] is
 * linear envelope gain in `[0.0, 1.0]`.
 */
data class AndroidEditorVolumeKeyframe(
    val timeUs: Long,
    val volume: Float,
)

/**
 * Pure math for Android editor-preview single-clip added-audio volume automation
 * (Phase 7.8M-Android): computes the linear gain [AndroidEditorAddedAudioPreviewRuntime] applies
 * to its `MediaPlayer` at a given global editor-timeline PTS. No MediaPlayer/Handler/AudioManager
 * access; safe to call from any thread.
 *
 * Mirrors the wire VGAudioSidecarTrack contract
 * (packages/vanguard_media_engine/lib/vg_audio_sidecar_plan.dart): a non-empty
 * [AndroidEditorAddedAudioTrackConfig.volumeKeyframes] completely overrides static
 * volume/fadeInUs/fadeOutUs and is linearly interpolated (holding the first/last value outside
 * the keyframe span); otherwise a fade envelope is synthesized from
 * [AndroidEditorAddedAudioTrackConfig.trackStartUs], [AndroidEditorAddedAudioTrackConfig
 * .durationUs], [AndroidEditorAddedAudioTrackConfig.volume],
 * [AndroidEditorAddedAudioTrackConfig.fadeInUs], and [AndroidEditorAddedAudioTrackConfig
 * .fadeOutUs]. Either way the envelope value is multiplied by
 * [AndroidEditorAddedAudioTrackConfig.mixGain] and the final result is clamped to `[0.0, 1.0]`.
 */
object AndroidEditorAudioAutomation {

    /**
     * Effective linear gain, clamped to `[0.0, 1.0]`, to apply at [timelinePtsUs] (a global
     * editor-timeline PTS, microseconds) for [config].
     */
    fun computeEffectiveGain(config: AndroidEditorAddedAudioTrackConfig, timelinePtsUs: Long): Float {
        val envelope = if (config.volumeKeyframes.isNotEmpty()) {
            envelopeFromKeyframes(config.volumeKeyframes, timelinePtsUs)
        } else {
            envelopeFromFades(config, timelinePtsUs)
        }
        return (envelope * config.mixGain).coerceIn(0.0f, 1.0f)
    }

    /**
     * Sorts [keyframes] by [AndroidEditorVolumeKeyframe.timeUs] ascending and deduplicates equal
     * timestamps, keeping the last occurrence for each timestamp. Safe to call with an
     * already-sorted/deduplicated list (idempotent).
     */
    fun normalizeKeyframes(keyframes: List<AndroidEditorVolumeKeyframe>): List<AndroidEditorVolumeKeyframe> {
        if (keyframes.size <= 1) return keyframes
        val sorted = keyframes.sortedBy { it.timeUs }
        val deduped = mutableListOf<AndroidEditorVolumeKeyframe>()
        for (kf in sorted) {
            if (deduped.isNotEmpty() && deduped.last().timeUs == kf.timeUs) {
                deduped[deduped.size - 1] = kf
            } else {
                deduped.add(kf)
            }
        }
        return deduped
    }

    private fun envelopeFromKeyframes(keyframes: List<AndroidEditorVolumeKeyframe>, timelinePtsUs: Long): Float {
        val normalized = normalizeKeyframes(keyframes)
        val first = normalized.first()
        val last = normalized.last()
        if (timelinePtsUs <= first.timeUs) return first.volume
        if (timelinePtsUs >= last.timeUs) return last.volume
        for (i in 0 until normalized.size - 1) {
            val a = normalized[i]
            val b = normalized[i + 1]
            if (timelinePtsUs in a.timeUs..b.timeUs) {
                if (b.timeUs == a.timeUs) return b.volume
                val fraction = (timelinePtsUs - a.timeUs).toFloat() / (b.timeUs - a.timeUs).toFloat()
                return a.volume + (b.volume - a.volume) * fraction
            }
        }
        return last.volume
    }

    /** Ramp `0 -> volume` over the fade-in, hold `volume`, ramp `volume -> 0` over the fade-out. */
    private fun envelopeFromFades(config: AndroidEditorAddedAudioTrackConfig, timelinePtsUs: Long): Float {
        val durationUs = config.durationUs
        if (durationUs <= 0L) return 0f

        var fadeInUs = config.fadeInUs.coerceIn(0L, durationUs)
        var fadeOutUs = config.fadeOutUs.coerceIn(0L, durationUs)
        val fadeSumUs = fadeInUs + fadeOutUs
        if (fadeSumUs > durationUs) {
            val scale = durationUs.toDouble() / fadeSumUs.toDouble()
            fadeInUs = (fadeInUs * scale).toLong()
            fadeOutUs = (fadeOutUs * scale).toLong()
        }

        val posUs = (timelinePtsUs - config.trackStartUs).coerceIn(0L, durationUs)
        val fadeOutStartUs = durationUs - fadeOutUs
        return when {
            fadeInUs > 0L && posUs < fadeInUs ->
                config.volume * (posUs.toFloat() / fadeInUs.toFloat())
            fadeOutUs > 0L && posUs >= fadeOutStartUs ->
                config.volume * ((durationUs - posUs).toFloat() / fadeOutUs.toFloat())
            else -> config.volume
        }
    }
}
