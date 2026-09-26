package com.connects.vanguard_media_engine.camera

// ── AndroidCameraEgressTransform ─────────────────────────────────────────────
//
// Pure-Kotlin geometry for the optional processed-frame egress surface of
// AndroidCameraBeautySurfaceProcessor. Deliberately free of android.* types so
// it can be exercised on a plain JVM.
//
// Conventions:
//   * Texture coordinates are GL UV: (0,0) is the bottom-left texel, (1,1) the
//     top-right. Both the processed source texture (an FBO-rendered
//     GL_TEXTURE_2D) and the egress window surface use this convention, so no
//     y-flip is applied anywhere here.
//   * `rotationDegrees` is the clockwise rotation (0/90/180/270) that turns the
//     source image upright, i.e. the value CameraX reports through
//     SurfaceRequest.TransformationInfo.getRotationDegrees() for the
//     processor's input.
//   * The output is always drawn edge-to-edge: the upright source is
//     center-cropped to the output aspect ratio and then scaled uniformly, so
//     no axis is ever stretched.

object AndroidCameraEgressTransform {

    const val DEFAULT_OUTPUT_WIDTH = 720
    const val DEFAULT_OUTPUT_HEIGHT = 1280

    fun isSupportedRotation(rotationDegrees: Int): Boolean =
        rotationDegrees == 0 || rotationDegrees == 90 || rotationDegrees == 180 || rotationDegrees == 270

    /** Width/height of the source once rotated upright by [rotationDegrees]. */
    fun uprightSize(sourceWidth: Int, sourceHeight: Int, rotationDegrees: Int): IntArray {
        requireSupported(rotationDegrees)
        return if (rotationDegrees == 90 || rotationDegrees == 270) {
            intArrayOf(sourceHeight, sourceWidth)
        } else {
            intArrayOf(sourceWidth, sourceHeight)
        }
    }

    /**
     * The largest centered window of the upright source that has the output
     * aspect ratio, as normalized [scaleX, scaleY, offsetX, offsetY]: a point
     * (u, v) of the output maps to (offsetX + u * scaleX, offsetY + v * scaleY)
     * of the upright source. Exactly one axis is cropped (or none when the
     * aspects already match).
     */
    fun centeredWindow(
        uprightWidth: Int,
        uprightHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
    ): FloatArray {
        require(uprightWidth > 0 && uprightHeight > 0) { "upright size must be positive" }
        require(outputWidth > 0 && outputHeight > 0) { "output size must be positive" }
        val sourceAspect = uprightWidth.toFloat() / uprightHeight.toFloat()
        val outputAspect = outputWidth.toFloat() / outputHeight.toFloat()
        return if (sourceAspect > outputAspect) {
            // Source is wider than the output: crop the sides.
            val scaleX = outputAspect / sourceAspect
            floatArrayOf(scaleX, 1f, (1f - scaleX) / 2f, 0f)
        } else {
            // Source is taller than (or equal to) the output: crop top/bottom.
            val scaleY = sourceAspect / outputAspect
            floatArrayOf(1f, scaleY, 0f, (1f - scaleY) / 2f)
        }
    }

    /**
     * Source pixels consumed per output pixel along x and y. Equal by
     * construction — a difference would mean stretching.
     */
    fun scaleFactors(
        sourceWidth: Int,
        sourceHeight: Int,
        rotationDegrees: Int,
        outputWidth: Int,
        outputHeight: Int,
    ): FloatArray {
        val upright = uprightSize(sourceWidth, sourceHeight, rotationDegrees)
        val window = centeredWindow(upright[0], upright[1], outputWidth, outputHeight)
        return floatArrayOf(
            (window[0] * upright[0]) / outputWidth.toFloat(),
            (window[1] * upright[1]) / outputHeight.toFloat(),
        )
    }

    /**
     * Column-major 4x4 matrix for a `uniform mat4 uTexMatrix` that maps an
     * output-quad texcoord (u, v, 0, 1) to the source UV to sample:
     *
     *     source = inverseRotation( mirror( centeredWindow( output ) ) )
     *
     * [mirror] flips horizontally in upright (viewer) space.
     */
    fun textureMatrix(
        sourceWidth: Int,
        sourceHeight: Int,
        rotationDegrees: Int,
        mirror: Boolean,
        outputWidth: Int,
        outputHeight: Int,
    ): FloatArray {
        val upright = uprightSize(sourceWidth, sourceHeight, rotationDegrees)
        val window = centeredWindow(upright[0], upright[1], outputWidth, outputHeight)

        // Affine steps in row form (a, b, tx, c, d, ty): u' = a*u + b*v + tx, v' = c*u + d*v + ty.
        var m = floatArrayOf(window[0], 0f, window[2], 0f, window[1], window[3])
        if (mirror) {
            m = compose(floatArrayOf(-1f, 0f, 1f, 0f, 1f, 0f), m)
        }
        val inverseRotation = when (rotationDegrees) {
            90 -> floatArrayOf(0f, -1f, 1f, 1f, 0f, 0f)   // (u, v) -> (1 - v, u)
            180 -> floatArrayOf(-1f, 0f, 1f, 0f, -1f, 1f) // (u, v) -> (1 - u, 1 - v)
            270 -> floatArrayOf(0f, 1f, 0f, -1f, 0f, 1f)  // (u, v) -> (v, 1 - u)
            else -> floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f)
        }
        m = compose(inverseRotation, m)

        val out = FloatArray(16)
        out[0] = m[0]; out[4] = m[1]; out[12] = m[2]
        out[1] = m[3]; out[5] = m[4]; out[13] = m[5]
        out[10] = 1f
        out[15] = 1f
        return out
    }

    /** Applies [textureMatrix] to one output UV; handy for verification. */
    fun mapOutputUv(
        u: Float,
        v: Float,
        sourceWidth: Int,
        sourceHeight: Int,
        rotationDegrees: Int,
        mirror: Boolean,
        outputWidth: Int,
        outputHeight: Int,
    ): FloatArray {
        val m = textureMatrix(sourceWidth, sourceHeight, rotationDegrees, mirror, outputWidth, outputHeight)
        return floatArrayOf(
            m[0] * u + m[4] * v + m[12],
            m[1] * u + m[5] * v + m[13],
        )
    }

    /** Returns `second ∘ first` (apply [first], then [second]) in row form. */
    private fun compose(second: FloatArray, first: FloatArray): FloatArray {
        val a1 = first[0]
        val b1 = first[1]
        val tx1 = first[2]
        val c1 = first[3]
        val d1 = first[4]
        val ty1 = first[5]
        val a2 = second[0]
        val b2 = second[1]
        val tx2 = second[2]
        val c2 = second[3]
        val d2 = second[4]
        val ty2 = second[5]
        return floatArrayOf(
            a2 * a1 + b2 * c1,
            a2 * b1 + b2 * d1,
            a2 * tx1 + b2 * ty1 + tx2,
            c2 * a1 + d2 * c1,
            c2 * b1 + d2 * d1,
            c2 * tx1 + d2 * ty1 + ty2,
        )
    }

    private fun requireSupported(rotationDegrees: Int) {
        require(isSupportedRotation(rotationDegrees)) {
            "rotationDegrees must be 0, 90, 180 or 270, got $rotationDegrees"
        }
    }
}
