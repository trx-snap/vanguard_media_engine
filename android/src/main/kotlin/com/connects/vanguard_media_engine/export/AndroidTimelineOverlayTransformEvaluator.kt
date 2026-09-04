package com.connects.vanguard_media_engine.export

/**
 * Static evaluator for dynamic overlay keyframe interpolation in Android export.
 *
 * Ports authoritative behavior from Dart `vg_overlay_transform_evaluator.dart`.
 * Evaluates dynamic spatial transforms at any overlay-local elapsed time or
 * timeline playhead in seconds.
 */
object AndroidTimelineOverlayTransformEvaluator {

    data class EvaluatedTransform(
        val translationX: Double,
        val translationY: Double,
        val width: Double,
        val height: Double,
        val rotation: Double,
        val scale: Double,
        val opacity: Double,
    )

    private fun lerp(a: Double, b: Double, t: Double): Double = a + (b - a) * t

    /**
     * Evaluates the overlay's spatial transform at absolute [ptsSeconds].
     *
     * If [descriptor.keyframes] is empty, returns the descriptor's static transform.
     * Otherwise evaluates the keyframes at local time `ptsSeconds - descriptor.startTimeSeconds`.
     */
    fun evaluate(
        descriptor: AndroidTimelineOverlayDescriptor,
        ptsSeconds: Double,
    ): EvaluatedTransform {
        val keyframes = descriptor.keyframes
        if (keyframes.isEmpty()) {
            return EvaluatedTransform(
                translationX = descriptor.translationX,
                translationY = descriptor.translationY,
                width = descriptor.width,
                height = descriptor.height,
                rotation = descriptor.rotation,
                scale = descriptor.scale,
                opacity = descriptor.opacity,
            )
        }
        val localTime = ptsSeconds - descriptor.startTimeSeconds
        return evaluateKeyframes(keyframes, localTime)
    }

    /**
     * Evaluates keyframes at overlay-local [localTimeSeconds].
     *
     * - Clamps before first keyframe to the first keyframe values.
     * - Clamps at or after last keyframe to the last keyframe values.
     * - Single keyframe returns exact keyframe values.
     * - Segment interpolation uses start keyframe interpolation mode:
     *   - linear: standard linear interpolation.
     *   - easeInOut / smoothstep: cubic smoothstep f(t) = 3t^2 - 2t^3.
     *   - hold: holds start keyframe transform until next timestamp.
     * - Post-lerp clamps width >= 0, height >= 0, scale >= 1e-6, opacity in [0, 1].
     */
    fun evaluateKeyframes(
        keyframes: List<AndroidTimelineOverlayKeyframe>,
        localTimeSeconds: Double,
    ): EvaluatedTransform {
        require(keyframes.isNotEmpty()) { "keyframes must not be empty" }

        if (keyframes.size == 1 || localTimeSeconds <= keyframes.first().timeSeconds) {
            val k = keyframes.first()
            return EvaluatedTransform(
                translationX = k.translationX,
                translationY = k.translationY,
                width = k.width,
                height = k.height,
                rotation = k.rotation,
                scale = k.scale,
                opacity = k.opacity,
            )
        }

        if (localTimeSeconds >= keyframes.last().timeSeconds) {
            val k = keyframes.last()
            return EvaluatedTransform(
                translationX = k.translationX,
                translationY = k.translationY,
                width = k.width,
                height = k.height,
                rotation = k.rotation,
                scale = k.scale,
                opacity = k.opacity,
            )
        }

        var lo = 0
        var hi = keyframes.size - 1
        while (hi - lo > 1) {
            val mid = (lo + hi) ushr 1
            if (keyframes[mid].timeSeconds <= localTimeSeconds) {
                lo = mid
            } else {
                hi = mid
            }
        }

        val kA = keyframes[lo]
        val kB = keyframes[hi]

        if (kA.interpolation == AndroidTimelineOverlayKeyframe.Interpolation.HOLD) {
            return EvaluatedTransform(
                translationX = kA.translationX,
                translationY = kA.translationY,
                width = kA.width,
                height = kA.height,
                rotation = kA.rotation,
                scale = kA.scale,
                opacity = kA.opacity,
            )
        }

        val span = kB.timeSeconds - kA.timeSeconds
        val progress = if (span == 0.0) 0.0 else (localTimeSeconds - kA.timeSeconds) / span

        val p = when (kA.interpolation) {
            AndroidTimelineOverlayKeyframe.Interpolation.LINEAR -> progress
            AndroidTimelineOverlayKeyframe.Interpolation.EASE_IN_OUT,
            AndroidTimelineOverlayKeyframe.Interpolation.SMOOTHSTEP -> {
                progress * progress * (3.0 - 2.0 * progress)
            }
            AndroidTimelineOverlayKeyframe.Interpolation.HOLD -> 0.0
        }

        val translationX = lerp(kA.translationX, kB.translationX, p)
        val translationY = lerp(kA.translationY, kB.translationY, p)
        val width = lerp(kA.width, kB.width, p).coerceAtLeast(0.0)
        val height = lerp(kA.height, kB.height, p).coerceAtLeast(0.0)
        val rotation = lerp(kA.rotation, kB.rotation, p)
        val scale = lerp(kA.scale, kB.scale, p).coerceAtLeast(1e-6)
        val opacity = lerp(kA.opacity, kB.opacity, p).coerceIn(0.0, 1.0)

        return EvaluatedTransform(
            translationX = translationX,
            translationY = translationY,
            width = width,
            height = height,
            rotation = rotation,
            scale = scale,
            opacity = opacity,
        )
    }
}
