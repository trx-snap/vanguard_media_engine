package com.connects.vanguard_media_engine.export

import android.opengl.GLES11Ext
import android.opengl.GLES20
import java.nio.FloatBuffer

/**
 * Android True-DAG V4.3 Phase 5 P5-GLES-EXPORT-BEAUTY-PRODUCTION-ROUTE-A.
 *
 * Owns only the intermediate RGBA8 `GL_TEXTURE_2D`/FBO and the OES-to-2D
 * resolve shader/program this narrow production GLES Beauty V2 route needs
 * -- the same OES-to-canvas pre-resolve shape
 * [AndroidTimelineGlesTransitionVideoEncoder] proved for its own dual-input
 * crossfade route, reused here for a single input ahead of the native Beauty
 * V2 seam ([com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
 * .drawAndroidDagPhase5GlesExportBeautySeam]).
 *
 * Every GL call in this class requires the caller's (encoder's) GLES export
 * EGL context/surface to already be current on the calling thread -- this
 * class never creates or destroys an EGL context or surface, never owns a
 * MediaCodec or SurfaceTexture, and never calls
 * `eglMakeCurrent`/`eglSwapBuffers`/`eglPresentationTimeANDROID`; the caller
 * (`AndroidTimelineVideoEncoder`) owns presentation of the frame this
 * session's resolved texture eventually contributes to.
 */
internal class AndroidTimelineGlesBeautyRenderSession private constructor(
    /** Resolved canvas-sized `GL_TEXTURE_2D` RGBA8 raster -- the Beauty V2 seam's input texture. */
    val resolvedTextureId: Int,
    private val resolveFboId: Int,
    private val oesProgram: Int,
    private val aPositionLoc: Int,
    private val aTexCoordLoc: Int,
    private val uSTMatrixLoc: Int,
) {

    /**
     * Resolves [oesTextureId]'s current frame (already `updateTexImage()`'d,
     * [stMatrix] already fetched via `SurfaceTexture.getTransformMatrix`)
     * into [resolvedTextureId]'s canvas-sized FBO, using [quad]'s fit
     * geometry and [texCoords] -- the identical shape
     * [AndroidTimelineVideoEncoder]'s own direct OES draw path uses for the
     * same clip/frame. Leaves the default framebuffer (0) bound on return.
     * Requires the caller's encoder EGL context/surface to already be
     * current. Returns a machine-readable failure reason on any GL error, or
     * null on success.
     */
    fun resolveOesFrameToTexture2d(
        oesTextureId: Int,
        quad: FloatBuffer,
        texCoords: FloatBuffer,
        stMatrix: FloatArray,
        width: Int,
        height: Int,
    ): String? {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, resolveFboId)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(oesProgram)

        quad.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quad)

        texCoords.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texCoords)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, stMatrix, 0)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glUseProgram(0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

        val err = GLES20.glGetError()
        return if (err == GLES20.GL_NO_ERROR) null else "resolve_gl_error:$err"
    }

    /**
     * Idempotent-by-construction teardown (called at most once by the owning
     * encoder). Deletes the resolve FBO/texture/program -- the caller's EGL
     * context/surface must still be current when this is called. Never
     * throws.
     */
    fun release() {
        try { if (resolveFboId != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(resolveFboId), 0) } catch (_: Throwable) {}
        try { if (resolvedTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(resolvedTextureId), 0) } catch (_: Throwable) {}
        try { if (oesProgram != 0) GLES20.glDeleteProgram(oesProgram) } catch (_: Throwable) {}
    }

    companion object {
        /**
         * Creates the intermediate RGBA8 `GL_TEXTURE_2D`/FBO and OES-to-2D
         * resolve shader program on the caller's already-current encoder
         * EGL context. Returns null on any GL setup failure -- the caller
         * must treat that as a fatal encode error, same as any other GL
         * setup failure on this route.
         */
        fun prepare(width: Int, height: Int): AndroidTimelineGlesBeautyRenderSession? {
            val textureId = createRgba8Texture(width, height)
            if (textureId == 0) return null
            val fboId = createFramebufferForTexture(textureId)
            if (fboId == 0) {
                GLES20.glDeleteTextures(1, intArrayOf(textureId), 0)
                return null
            }
            val program = buildOesResolveProgram()
            if (program == 0) {
                GLES20.glDeleteFramebuffers(1, intArrayOf(fboId), 0)
                GLES20.glDeleteTextures(1, intArrayOf(textureId), 0)
                return null
            }
            val aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
            val aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
            val uSTMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix")
            return AndroidTimelineGlesBeautyRenderSession(
                resolvedTextureId = textureId,
                resolveFboId = fboId,
                oesProgram = program,
                aPositionLoc = aPositionLoc,
                aTexCoordLoc = aTexCoordLoc,
                uSTMatrixLoc = uSTMatrixLoc,
            )
        }

        private fun buildOesResolveProgram(): Int {
            val vertexSrc = """
                attribute vec4 aPosition;
                attribute vec4 aTextureCoord;
                uniform mat4 uSTMatrix;
                varying vec2 vTextureCoord;
                void main() {
                    gl_Position = aPosition;
                    vTextureCoord = (uSTMatrix * aTextureCoord).xy;
                }
            """.trimIndent()
            val fragmentSrc = """
                #extension GL_OES_EGL_image_external : require
                precision mediump float;
                varying vec2 vTextureCoord;
                uniform samplerExternalOES sTexture;
                void main() {
                    gl_FragColor = texture2D(sTexture, vTextureCoord);
                }
            """.trimIndent()

            val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
            if (vertexShader == 0) return 0
            val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
            if (fragmentShader == 0) {
                GLES20.glDeleteShader(vertexShader)
                return 0
            }

            val program = GLES20.glCreateProgram()
            GLES20.glAttachShader(program, vertexShader)
            GLES20.glAttachShader(program, fragmentShader)
            GLES20.glLinkProgram(program)
            val linkStatus = IntArray(1)
            GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
            GLES20.glDeleteShader(vertexShader)
            GLES20.glDeleteShader(fragmentShader)
            if (linkStatus[0] == 0) {
                GLES20.glDeleteProgram(program)
                return 0
            }
            return program
        }

        private fun compileShader(type: Int, src: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, src)
            GLES20.glCompileShader(shader)
            val status = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
            if (status[0] == 0) {
                GLES20.glDeleteShader(shader)
                return 0
            }
            return shader
        }

        private fun createRgba8Texture(w: Int, h: Int): Int {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            val id = textures[0]
            if (id == 0) return 0
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
            return if (GLES20.glGetError() == GLES20.GL_NO_ERROR) id else 0
        }

        private fun createFramebufferForTexture(textureId: Int): Int {
            val fbos = IntArray(1)
            GLES20.glGenFramebuffers(1, fbos, 0)
            val fbo = fbos[0]
            if (fbo == 0) return 0
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
            GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, textureId, 0)
            val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            return if (status == GLES20.GL_FRAMEBUFFER_COMPLETE) fbo else 0
        }
    }
}
