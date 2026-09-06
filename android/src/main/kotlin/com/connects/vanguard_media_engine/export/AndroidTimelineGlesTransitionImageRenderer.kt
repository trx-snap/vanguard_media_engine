package com.connects.vanguard_media_engine.export

import android.graphics.Bitmap
import android.opengl.GLES20
import android.opengl.GLUtils
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.min

// ── AndroidTimelineGlesTransitionImageRenderer (P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS) ──
//
// Still-image bitmap decode/orient/clamp/upload-to-GL_TEXTURE_2D helper for
// AndroidTimelineGlesTransitionVideoEncoder's narrow GLES transition route,
// used ONLY for a clip that is [AndroidTimelineVideoEncoder.ClipInput.mediaKind]
// == "image" and has already passed that encoder's own `validateClipShape`
// (positive stillFrameCount, rotationDegrees == 0, not reversed, no
// colorMatrix, no Beauty). Reuses [AndroidStillImageDecoder]'s decode/EXIF/
// sample-size/clamp policy -- the same policy
// AndroidTimelineVideoEncoder's frozen hard-cut still-image route
// (`renderStillClipIntoEncoder`) uses -- rather than duplicating it. Holds
// its own plain 2D GLES program (no uSTMatrix, no colorMatrix uniform --
// colorMatrix-bearing clips are rejected upstream of this route) but owns no
// EGL/codec/muxer lifecycle: every method here assumes the caller
// (AndroidTimelineGlesTransitionVideoEncoder) has already made its own EGL
// context current, and must be called only from that context.
//
// [loadTexture] uploads exactly one new GL_TEXTURE_2D per call; the caller
// owns that texture id afterward and is responsible for deleting it (via
// [deleteTexture]) once its segment is done with it -- this helper never
// holds a texture id across calls. [release] only tears down the shared 2D
// program, called once from AndroidTimelineGlesTransitionVideoEncoder's
// `releaseAll` while its EGL context is still current.
internal class AndroidTimelineGlesTransitionImageRenderer {

    sealed class LoadResult {
        /** [quad] is a centered, aspect-fit BL/BR/TL/TR NDC quad for the canvas size passed to [loadTexture]. */
        data class Success(val textureId: Int, val quad: FloatArray) : LoadResult()
        data class Failure(val reason: String) : LoadResult()
    }

    private var program = 0
    private var aPositionLoc = 0
    private var aTexCoordLoc = 0

    // Flipped vertically relative to a plain OES texCoord set, matching
    // AndroidTimelineVideoEncoder's texCoords2D -- BitmapFactory's top-down
    // row order must land right-side-up in the encoder's bottom-up NDC
    // output space.
    private val texCoords = floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f)
    private val quadBuffer: FloatBuffer = ByteBuffer.allocateDirect(8 * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer()
    private val texBuffer: FloatBuffer = ByteBuffer.allocateDirect(texCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(texCoords)
            position(0)
        }

    /**
     * Compiles this helper's plain 2D program. Must be called once, with the
     * caller's EGL context current, before [loadTexture]/[drawToFramebuffer].
     */
    fun setup() {
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = aTextureCoord.xy;
            }
        """.trimIndent()
        val fragmentSrc = """
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform sampler2D sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTextureCoord);
            }
        """.trimIndent()

        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val builtProgram = GLES20.glCreateProgram()
        GLES20.glAttachShader(builtProgram, vertexShader)
        GLES20.glAttachShader(builtProgram, fragmentShader)
        GLES20.glLinkProgram(builtProgram)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(builtProgram, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(builtProgram)
            GLES20.glDeleteProgram(builtProgram)
            throw IllegalStateException("GL image program link failed: $log")
        }
        program = builtProgram
        aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
    }

    /**
     * Decodes [clip]'s local still-image file (sample-size clamped to the
     * current EGL context's GL_MAX_TEXTURE_SIZE, EXIF orientation applied to
     * pixels, final clamp to GL_MAX_TEXTURE_SIZE), uploads it as a new plain
     * GL_TEXTURE_2D, and returns that texture id plus its centered
     * aspect-fit quad against [canvasWidth]x[canvasHeight] -- mirroring
     * AndroidTimelineVideoEncoder's `renderStillClipIntoEncoder` decode
     * pipeline and `updateClipGeometry`'s image display-bounds handling.
     * [clip] must already satisfy AndroidTimelineGlesTransitionVideoEncoder's
     * `validateClipShape` image branch (mediaKind == "image", rotationDegrees
     * == 0, no colorMatrix, no Beauty) -- this method itself does not
     * re-check those.
     */
    fun loadTexture(clip: AndroidTimelineVideoEncoder.ClipInput, canvasWidth: Int, canvasHeight: Int): LoadResult {
        val displayBounds = AndroidStillImageDecoder.getDisplayBounds(
            clip.decodedWidth, clip.decodedHeight, clip.exifOrientation,
        )
        val quad = computeFitQuad(displayBounds.width, displayBounds.height, canvasWidth, canvasHeight)
            ?: return LoadResult.Failure("gles_transition_invalid_geometry:${clip.sourcePath}")

        var bitmapToRecycle: Bitmap? = null
        var textureId = 0
        try {
            val maxTextureSize = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, maxTextureSize, 0)

            val inSampleSize = AndroidStillImageDecoder.computeInSampleSize(
                clip.decodedWidth, clip.decodedHeight, canvasWidth, canvasHeight, maxTextureSize[0], clip.exifOrientation,
            )
            val decoded = AndroidStillImageDecoder.decodeBitmap(clip.sourcePath, inSampleSize)
                ?: return LoadResult.Failure("still_image_decode_failed:${clip.sourcePath}")
            bitmapToRecycle = decoded
            val oriented = AndroidStillImageDecoder.applyExifOrientation(decoded, clip.exifOrientation)
            bitmapToRecycle = oriented
            val bitmap = AndroidStillImageDecoder.clampToMaxTextureSize(oriented, maxTextureSize[0])
            bitmapToRecycle = bitmap

            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            textureId = textures[0]
            if (textureId == 0) return LoadResult.Failure("still_texture_gen_failed:${clip.sourcePath}")
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            val texUploadError = GLES20.glGetError()
            bitmap.recycle()
            bitmapToRecycle = null
            if (texUploadError != GLES20.GL_NO_ERROR) {
                deleteTexture(textureId)
                textureId = 0
                return LoadResult.Failure("still_texture_upload_failed:$texUploadError:${clip.sourcePath}")
            }
            return LoadResult.Success(textureId, quad)
        } catch (t: Throwable) {
            if (textureId != 0) deleteTexture(textureId)
            return LoadResult.Failure("still_image_render_exception:${t.javaClass.simpleName}:${clip.sourcePath}")
        } finally {
            try { bitmapToRecycle?.recycle() } catch (_: Throwable) {}
        }
    }

    /**
     * Draws [textureId] through [quad]'s fit geometry into [fboId] (0 for the
     * caller's own default framebuffer; a canvas-sized GL_TEXTURE_2D-backed
     * FBO otherwise), clearing it to black first. Leaves the default
     * framebuffer bound on return. Returns a machine-readable failure reason
     * on any GL error, or null on success.
     */
    fun drawToFramebuffer(textureId: Int, quad: FloatArray, fboId: Int, canvasWidth: Int, canvasHeight: Int): String? {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
        GLES20.glViewport(0, 0, canvasWidth, canvasHeight)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)

        quadBuffer.position(0)
        quadBuffer.put(quad)
        quadBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadBuffer)

        texBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texBuffer)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glUseProgram(0)

        val err = GLES20.glGetError()
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        return if (err == GLES20.GL_NO_ERROR) null else "gl_error:$err"
    }

    /** Deletes a texture id previously returned by [loadTexture]. A no-op for id 0. */
    fun deleteTexture(textureId: Int) {
        if (textureId == 0) return
        try { GLES20.glDeleteTextures(1, intArrayOf(textureId), 0) } catch (_: Throwable) {}
    }

    /** Tears down this helper's shared 2D program. Must be called with the caller's EGL context still current. */
    fun release() {
        if (program != 0) {
            try { GLES20.glDeleteProgram(program) } catch (_: Throwable) {}
            program = 0
        }
    }

    /** Centered, aspect-preserving "fit" BL/BR/TL/TR NDC quad -- still-image clips never rotate in vertex space (rotationDegrees == 0 is enforced upstream). */
    private fun computeFitQuad(displayWidth: Int, displayHeight: Int, canvasWidth: Int, canvasHeight: Int): FloatArray? {
        if (displayWidth <= 0 || displayHeight <= 0 || canvasWidth <= 0 || canvasHeight <= 0) return null
        val scale = min(canvasWidth.toFloat() / displayWidth, canvasHeight.toFloat() / displayHeight)
        val halfWidthNdc = (displayWidth.toFloat() * scale / 2f) / (canvasWidth.toFloat() / 2f)
        val halfHeightNdc = (displayHeight.toFloat() * scale / 2f) / (canvasHeight.toFloat() / 2f)
        return floatArrayOf(
            -halfWidthNdc, -halfHeightNdc,
            halfWidthNdc, -halfHeightNdc,
            -halfWidthNdc, halfHeightNdc,
            halfWidthNdc, halfHeightNdc,
        )
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw IllegalStateException("GL image shader compile failed: $log")
        }
        return shader
    }
}
