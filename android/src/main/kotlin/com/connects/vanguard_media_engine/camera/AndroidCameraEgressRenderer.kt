package com.connects.vanguard_media_engine.camera

// ── AndroidCameraEgressRenderer ──────────────────────────────────────────────
//
// Owns the optional second EGL window surface ("egress") of
// AndroidCameraBeautySurfaceProcessor and draws the processed frame into it
// upright, center-cropped to the egress aspect and uniformly scaled (see
// AndroidCameraEgressTransform). It shares the processor's EGLDisplay /
// EGLConfig / EGLContext and its fullscreen quad VAO, and knows nothing about
// who consumes the Surface.
//
// Threading: GPU thread only (the processor's "VGCameraGpuThread").
// Ownership: the Surface belongs to the caller and is never released here;
// only the EGLSurface created from it is destroyed in release().

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES30
import android.util.Log
import android.view.Surface

internal class AndroidCameraEgressRenderer(
    private val eglDisplay: EGLDisplay,
    private val eglConfig: EGLConfig,
    private val eglContext: EGLContext,
) {
    companion object {
        private const val TAG = "VGCameraEgress"
    }

    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    var width: Int = 0
        private set
    var height: Int = 0
        private set
    var mirror: Boolean = false
        private set
    var framesRendered: Long = 0L
        private set

    val isBound: Boolean
        get() = eglSurface != EGL14.EGL_NO_SURFACE

    // Uniform locations and the transform matrix are cached by the inputs that
    // produce them so the per-frame path allocates nothing.
    private var cachedProgram: Int = 0
    private var texMatrixLoc: Int = -1
    private var texLoc: Int = -1
    private var cachedMatrixKey: Long = Long.MIN_VALUE
    private var cachedMatrix: FloatArray = FloatArray(16)

    /**
     * Creates the EGL window surface for [surface]. Replaces any previous
     * binding. Returns false (with nothing bound) if the surface is invalid or
     * EGL refuses it; the caller then drops the egress request.
     */
    fun bind(surface: Surface, width: Int, height: Int, mirror: Boolean): Boolean {
        release()
        if (!surface.isValid) {
            Log.e(TAG, "bind failed: surface is not valid")
            return false
        }
        val created: EGLSurface? = try {
            EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, surface, intArrayOf(EGL14.EGL_NONE), 0)
        } catch (e: Exception) {
            // EGL14 throws IllegalArgumentException for unsupported native windows.
            Log.e(TAG, "bind failed: eglCreateWindowSurface threw ${e.message}")
            null
        }
        if (created == null || created == EGL14.EGL_NO_SURFACE) {
            Log.e(TAG, "bind failed: eglCreateWindowSurface error 0x${Integer.toHexString(EGL14.eglGetError())}")
            return false
        }
        eglSurface = created
        this.width = width
        this.height = height
        this.mirror = mirror
        framesRendered = 0L
        cachedMatrixKey = Long.MIN_VALUE
        Log.i(TAG, "bound egress surface ${width}×${height} mirror=$mirror")
        return true
    }

    /**
     * Draws [sourceTexture] (a GL_TEXTURE_2D of sourceWidth×sourceHeight) into
     * the egress surface rotated upright by [rotationDegrees], mirrored if
     * requested at bind, center-cropped to the egress aspect and uniformly
     * scaled to width×height, then swaps with [timestampNs] as the presentation
     * time (0 = let the compositor stamp it).
     *
     * Leaves the egress surface current on return; the caller restores its own
     * surface. Returns false on any EGL/GL failure, after which the caller must
     * detach the egress.
     */
    fun draw(
        program: Int,
        quadVao: Int,
        sourceTexture: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        rotationDegrees: Int,
        timestampNs: Long,
    ): Boolean {
        if (!isBound) return false
        if (program == 0 || quadVao == 0 || sourceTexture == 0 || sourceWidth <= 0 || sourceHeight <= 0) {
            Log.e(
                TAG,
                "draw failed: invalid GL inputs (program=$program vao=$quadVao " +
                    "texture=$sourceTexture source=${sourceWidth}×${sourceHeight})",
            )
            return false
        }
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            Log.e(TAG, "draw failed: eglMakeCurrent error 0x${Integer.toHexString(EGL14.eglGetError())}")
            return false
        }

        if (program != cachedProgram) {
            cachedProgram = program
            texMatrixLoc = GLES30.glGetUniformLocation(program, "uTexMatrix")
            texLoc = GLES30.glGetUniformLocation(program, "uTex")
        }
        val key = matrixKey(sourceWidth, sourceHeight, rotationDegrees)
        if (key != cachedMatrixKey) {
            cachedMatrix = AndroidCameraEgressTransform.textureMatrix(
                sourceWidth, sourceHeight, rotationDegrees, mirror, width, height,
            )
            cachedMatrixKey = key
            val scale = AndroidCameraEgressTransform.scaleFactors(
                sourceWidth, sourceHeight, rotationDegrees, width, height,
            )
            Log.d(
                TAG,
                "egress transform: source=${sourceWidth}×${sourceHeight} rotation=$rotationDegrees " +
                    "mirror=$mirror → ${width}×${height} scale=${scale[0]}/${scale[1]}",
            )
        }

        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glViewport(0, 0, width, height)

        GLES30.glUseProgram(program)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, sourceTexture)
        // This pass downscales, so sample linearly. The processor's 1:1 preview
        // blit sets nearest sampling back on the same texture every frame.
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glUniformMatrix4fv(texMatrixLoc, 1, false, cachedMatrix, 0)
        GLES30.glUniform1i(texLoc, 0)

        GLES30.glBindVertexArray(quadVao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glBindVertexArray(0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)

        if (timestampNs > 0L) {
            EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, timestampNs)
        }
        if (!EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
            Log.e(TAG, "draw failed: eglSwapBuffers error 0x${Integer.toHexString(EGL14.eglGetError())}")
            return false
        }
        framesRendered++
        if (framesRendered == 1L) {
            Log.i(TAG, "first egress frame rendered")
        }
        return true
    }

    /**
     * Destroys the EGL surface (never the caller's Surface). Idempotent. The
     * caller must make sure the egress surface is not current beforehand.
     */
    fun release() {
        if (eglSurface == EGL14.EGL_NO_SURFACE) return
        if (!EGL14.eglDestroySurface(eglDisplay, eglSurface)) {
            Log.w(TAG, "eglDestroySurface error 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
        eglSurface = EGL14.EGL_NO_SURFACE
        Log.i(TAG, "released egress surface after $framesRendered frames")
    }

    private fun matrixKey(sourceWidth: Int, sourceHeight: Int, rotationDegrees: Int): Long =
        (sourceWidth.toLong() shl 40) or (sourceHeight.toLong() shl 16) or rotationDegrees.toLong()
}
