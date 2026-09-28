package com.connects.vanguard_media_engine.livestream

// ── AndroidLivestreamImagePump ───────────────────────────────────────────────
//
// I1 (livestream live media source switching, Option A): a self-contained
// 720x1280 @ 30 fps producer that renders ONE decoded still image, with the
// active livestream text/sticker overlays burned in, into the flutter_webrtc
// Surface the virtual camera track retains — so the same LocalVideoTrack keeps
// publishing while the camera hardware is suspended.
//
// Ownership / threading:
//   * One dedicated HandlerThread ("VGLivestreamImagePump") owns an
//     independent EGL display/context (ES 3.0), a fullscreen quad, the image
//     texture, an AndroidCameraOverlayProcessor and an
//     AndroidCameraEgressRenderer bound to the caller's Surface. Nothing here
//     touches the camera processor's context or thread.
//   * The Surface belongs to flutter_webrtc (retained, not owned, by
//     AndroidVanguardLiveKitBridge for the track lifetime); it is never
//     released here. A BufferQueue accepts one connected producer at a time, so
//     the camera egress must be detached BEFORE bind() can succeed. The camera
//     GPU thread destroys its EGL surface asynchronously, so bind() is retried a
//     bounded number of times before the pump fails closed.
//   * start()/replaceImage()/setOverlay() are safe from any thread (they post to
//     the pump thread). stop() blocks (bounded) until every GL resource is
//     released, so when it returns the Surface is disconnected and the camera
//     egress can bind it again. Listener callbacks fire on the pump thread; the
//     coordinator re-posts to the main thread.
//
// Frame path per tick: image texture (already center-cropped/scaled to the
// output size at decode time, GL row order) → AndroidCameraOverlayProcessor
// (rotation 0, no mirror; the same centered 720x1280 canvas window the camera
// path uses) → AndroidCameraEgressRenderer.draw (identity window, no stretch)
// → eglSwapBuffers. Failures fail closed: onFailed fires once, ticking stops,
// the coordinator restores the camera producer.

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.media.ExifInterface
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES30
import android.opengl.GLUtils
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.camera.AndroidCameraEgressRenderer
import com.connects.vanguard_media_engine.camera.AndroidCameraOverlayProcessor
import com.connects.vanguard_media_engine.camera.CameraOverlayState
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

internal class AndroidLivestreamImagePump(
    private val surface: Surface,
    private val outputWidth: Int,
    private val outputHeight: Int,
    private val fps: Int,
    private val listener: Listener,
) {
    /** Pump-thread callbacks. Each fires at most once per pump instance. */
    interface Listener {
        /** The first frame reached the Surface: the pump is ticking. */
        fun onFirstFrameRendered(pump: AndroidLivestreamImagePump)

        /** Unrecoverable failure; the pump has stopped ticking (call [stop] to release). */
        fun onFailed(pump: AndroidLivestreamImagePump, reason: String)
    }

    /**
     * A still image decoded off the hot path by [decode]: exactly
     * outputWidth x outputHeight ARGB_8888, aspect-filled (center-cropped,
     * never stretched), EXIF-upright, and stored in GL row order (bottom row
     * first) so it uploads straight into a texture the egress renderer samples
     * with GL UV conventions. Owned by the pump once handed to [start] /
     * [replaceImage]; callers that drop it earlier call [recycle].
     */
    class DecodedImage internal constructor(
        val path: String,
        val bitmap: Bitmap,
        val sourceWidth: Int,
        val sourceHeight: Int,
    ) {
        fun recycle() {
            if (!bitmap.isRecycled) bitmap.recycle()
        }
    }

    companion object {
        private const val TAG = "VGLivestreamImagePump"

        private const val FRAME_LOG_INTERVAL = 300L
        private const val BIND_RETRY_DELAY_MS = 25L
        private const val MAX_BIND_ATTEMPTS = 40
        private const val STOP_TIMEOUT_MS = 1500L
        private const val MAX_DECODE_DIMENSION = 4096

        // Same egress program as AndroidCameraBeautySurfaceProcessor: uTexMatrix
        // vertex over a 2D sampler, which AndroidCameraEgressRenderer.draw expects.
        private const val EGRESS_VERTEX_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "layout(location = 0) in vec4 aPosition;\n" +
            "layout(location = 1) in vec4 aTexCoord;\n" +
            "uniform mat4 uTexMatrix;\n" +
            "out vec2 vTexCoord;\n" +
            "void main() {\n" +
            "    gl_Position = aPosition;\n" +
            "    vTexCoord = (uTexMatrix * aTexCoord).xy;\n" +
            "}\n"

        private const val EGRESS_FRAGMENT_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform sampler2D uTex;\n" +
            "in vec2 vTexCoord;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "    fragColor = texture(uTex, vTexCoord);\n" +
            "}\n"

        private val FULLSCREEN_QUAD = floatArrayOf(
            // x, y, u, v
            -1f, -1f, 0f, 0f,
            1f, -1f, 1f, 0f,
            -1f, 1f, 0f, 1f,
            1f, 1f, 1f, 1f,
        )

        /**
         * Decodes [path] into a [DecodedImage] for an [outputWidth] x
         * [outputHeight] pump. Blocking; call off the main thread. Throws
         * [IllegalArgumentException] when the file is missing/unreadable and
         * [IllegalStateException] when it cannot be decoded. Never touches GL.
         */
        fun decode(path: String, outputWidth: Int, outputHeight: Int): DecodedImage {
            require(outputWidth > 0 && outputHeight > 0) { "output size must be positive" }
            val file = File(path)
            if (!file.isFile || !file.canRead()) {
                throw IllegalArgumentException("image file is missing or unreadable: $path")
            }

            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                throw IllegalStateException("image bounds unreadable: $path")
            }

            val orientation = readExifOrientation(path)
            val rotation = orientation[0]
            val flipHorizontal = orientation[1] == 1
            val swapAxes = rotation == 90 || rotation == 270
            val orientedWidth = if (swapAxes) bounds.outHeight else bounds.outWidth
            val orientedHeight = if (swapAxes) bounds.outWidth else bounds.outHeight

            // Sample down while the ORIENTED decode still covers the output on
            // both axes (aspect fill never upsamples more than necessary), and
            // never decode a side above MAX_DECODE_DIMENSION.
            var sample = 1
            while (orientedWidth / (sample * 2) >= outputWidth && orientedHeight / (sample * 2) >= outputHeight) {
                sample *= 2
            }
            while (bounds.outWidth / sample > MAX_DECODE_DIMENSION || bounds.outHeight / sample > MAX_DECODE_DIMENSION) {
                sample *= 2
            }
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inScaled = false
            }
            val decoded = BitmapFactory.decodeFile(path, opts)
                ?: throw IllegalStateException("image decode failed: $path")
            try {
                if (decoded.config == Bitmap.Config.HARDWARE) {
                    throw IllegalStateException("hardware bitmap cannot be drawn: $path")
                }
                val output = Bitmap.createBitmap(outputWidth, outputHeight, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(output)
                canvas.drawColor(Color.BLACK)

                val decodedWidth = decoded.width.toFloat()
                val decodedHeight = decoded.height.toFloat()
                val coverWidth = if (swapAxes) decodedHeight else decodedWidth
                val coverHeight = if (swapAxes) decodedWidth else decodedHeight
                val scale = max(outputWidth / coverWidth, outputHeight / coverHeight)

                // Source pixels → upright (EXIF) → aspect-fill scale → centered
                // in the output → flipped once so row 0 becomes the BOTTOM row
                // (GL texture v=0), matching the egress renderer's UV convention.
                val matrix = Matrix()
                matrix.postTranslate(-decodedWidth / 2f, -decodedHeight / 2f)
                if (flipHorizontal) matrix.postScale(-1f, 1f)
                matrix.postRotate(rotation.toFloat())
                matrix.postScale(scale, scale)
                matrix.postTranslate(outputWidth / 2f, outputHeight / 2f)
                matrix.postScale(1f, -1f, outputWidth / 2f, outputHeight / 2f)

                val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
                canvas.drawBitmap(decoded, matrix, paint)
                return DecodedImage(path, output, bounds.outWidth, bounds.outHeight)
            } finally {
                decoded.recycle()
            }
        }

        /** [rotationDegrees, flipHorizontal(0/1)] from EXIF; [0, 0] when absent or unreadable. */
        private fun readExifOrientation(path: String): IntArray {
            return try {
                when (ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> intArrayOf(90, 0)
                    ExifInterface.ORIENTATION_ROTATE_180 -> intArrayOf(180, 0)
                    ExifInterface.ORIENTATION_ROTATE_270 -> intArrayOf(270, 0)
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> intArrayOf(0, 1)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> intArrayOf(180, 1)
                    ExifInterface.ORIENTATION_TRANSPOSE -> intArrayOf(90, 1)
                    ExifInterface.ORIENTATION_TRANSVERSE -> intArrayOf(270, 1)
                    else -> intArrayOf(0, 0)
                }
            } catch (e: Exception) {
                // Non-JPEG/unsupported containers: no EXIF, treat as upright.
                intArrayOf(0, 0)
            }
        }
    }

    // ── Pump thread ──────────────────────────────────────────────────────────
    private val thread = HandlerThread("VGLivestreamImagePump").also { it.start() }
    private val handler = Handler(thread.looper)
    private val released = AtomicBoolean(false)
    private val tickRunnable = Runnable { tick() }
    private val bindRunnable = Runnable { attemptBind() }

    /** Frames swapped into the Surface so far. Any thread. */
    @Volatile var framesRendered: Long = 0L
        private set

    /** True once at least one frame reached the Surface. Any thread. */
    val isTicking: Boolean get() = framesRendered > 0L

    /**
     * Path of the image the pump actually renders: the start image, then each
     * replacement only once its upload succeeded (a failed replacement leaves
     * the previous image, and this path, in place). Any thread.
     */
    @Volatile var imagePath: String = ""
        private set

    // Requested overlay list; read once per tick on the pump thread.
    @Volatile private var requestedOverlay: CameraOverlayState? = null

    // ── EGL / GL state (pump thread only) ────────────────────────────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null
    private var pbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var egressProgram = 0
    private var quadVao = 0
    private var quadVbo = 0
    private var imageTexture = 0
    private var imageWidth = 0
    private var imageHeight = 0

    private var renderer: AndroidCameraEgressRenderer? = null
    private var overlayProcessor: AndroidCameraOverlayProcessor? = null
    private var bindAttempts = 0
    private var failed = false
    private var nextTickNs = 0L
    private val periodNs: Long = 1_000_000_000L / fps.coerceAtLeast(1)

    // ── Public API (any thread) ──────────────────────────────────────────────

    /** Initializes GL, uploads [image], binds the Surface (with retries) and starts ticking. */
    fun start(image: DecodedImage) {
        imagePath = image.path
        handler.post { startOnThread(image) }
    }

    /**
     * Hot-swaps the rendered image. The previous image keeps rendering until
     * the new texture is fully uploaded; only then is it swapped in and
     * presented on the next tick. [onComplete] fires exactly once on the pump
     * thread (inline when the pump thread is already gone): `true` once the
     * new image is renderable, `false` with a reason when the upload failed or
     * the pump is released/failed — in every `false` case the previous image is
     * still what the Surface receives. Never blocks the caller.
     */
    fun replaceImage(image: DecodedImage, onComplete: (success: Boolean, reason: String?) -> Unit) {
        val posted = handler.post { replaceOnThread(image, onComplete) }
        if (!posted) {
            image.recycle()
            onComplete(false, "pump_thread_gone")
        }
    }

    /** Replaces the overlay list burned into every frame (null/inactive clears it). */
    fun setOverlay(state: CameraOverlayState?) {
        requestedOverlay = state
    }

    /**
     * Stops ticking and releases every GL resource, blocking (bounded) until
     * the EGL window surface is destroyed so the Surface is free for another
     * producer. Idempotent.
     */
    fun stop() {
        if (!released.compareAndSet(false, true)) return
        val latch = CountDownLatch(1)
        // Only the periodic work is dropped. Queued start/replace runnables
        // still run ahead of the release below and, seeing `released`, recycle
        // their bitmap and report `pump_released` through their callback, so
        // no replace request is left unanswered.
        handler.removeCallbacks(tickRunnable)
        handler.removeCallbacks(bindRunnable)
        val posted = handler.post {
            try {
                releaseOnThread()
            } finally {
                latch.countDown()
                thread.quitSafely()
            }
        }
        if (!posted) {
            Log.w(TAG, "stop: pump thread already gone")
            return
        }
        if (!latch.await(STOP_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            Log.e(TAG, "stop: GL release did not finish within ${STOP_TIMEOUT_MS}ms; Surface may still be connected")
        }
    }

    // ── Pump thread: lifecycle ───────────────────────────────────────────────

    private fun startOnThread(image: DecodedImage) {
        if (released.get()) {
            image.recycle()
            return
        }
        try {
            initEgl()
            initGlResources()
            uploadImage(image)
        } catch (t: Throwable) {
            image.recycle()
            fail("gl_init_failed:${t.javaClass.simpleName}:${t.message}")
            return
        }
        bindAttempts = 0
        attemptBind()
    }

    // A replacement never fails the pump: on any error the previous texture is
    // untouched and keeps rendering; only the caller's request fails.
    private fun replaceOnThread(image: DecodedImage, onComplete: (Boolean, String?) -> Unit) {
        if (released.get()) {
            image.recycle()
            onComplete(false, "pump_released")
            return
        }
        if (failed || eglDisplay == EGL14.EGL_NO_DISPLAY) {
            image.recycle()
            onComplete(false, if (failed) "pump_failed" else "gl_not_initialized")
            return
        }
        val path = image.path
        val sourceWidth = image.sourceWidth
        val sourceHeight = image.sourceHeight
        try {
            if (!EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)) {
                throw RuntimeException("eglMakeCurrent failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            }
            uploadImage(image)   // swaps the texture only after a clean upload; recycles the bitmap
            imagePath = path
            Log.i(TAG, "ANDROID_LIVESTREAM_IMAGE_PUMP_IMAGE_REPLACED path=$path source=${sourceWidth}x$sourceHeight")
            onComplete(true, null)
        } catch (t: Throwable) {
            val reason = "image_upload_failed:${t.javaClass.simpleName}:${t.message}"
            Log.e(TAG, "image replacement failed ($reason); previous image keeps rendering ($imagePath)")
            onComplete(false, reason)
        }
    }

    // Retries while the camera GPU thread is still disconnecting from the Surface.
    private fun attemptBind() {
        if (released.get() || failed) return
        bindAttempts++
        val active = renderer ?: AndroidCameraEgressRenderer(eglDisplay, eglConfig!!, eglContext).also { renderer = it }
        if (active.bind(surface, outputWidth, outputHeight, mirror = false)) {
            Log.i(TAG, "surface bound after $bindAttempts attempt(s)")
            nextTickNs = System.nanoTime()
            tick()
            return
        }
        if (!surface.isValid) {
            fail("surface_invalid")
            return
        }
        if (bindAttempts >= MAX_BIND_ATTEMPTS) {
            fail("surface_bind_failed_after_${bindAttempts}_attempts")
            return
        }
        handler.postDelayed(bindRunnable, BIND_RETRY_DELAY_MS)
    }

    private fun tick() {
        if (released.get() || failed) return
        renderFrame()
        if (released.get() || failed) return
        // Drift-free cadence; resync after a stall longer than two periods.
        val now = System.nanoTime()
        nextTickNs += periodNs
        if (nextTickNs < now - 2 * periodNs) nextTickNs = now + periodNs
        val delayMs = ((nextTickNs - now) / 1_000_000L).coerceAtLeast(0L)
        handler.postDelayed(tickRunnable, delayMs)
    }

    // ── Pump thread: rendering ───────────────────────────────────────────────

    private fun renderFrame() {
        val active = renderer ?: return
        try {
            // Overlay compositing renders into the overlay's own FBO; the pbuffer
            // keeps the context current without touching the window surface.
            EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)

            var sourceTexture = imageTexture
            val overlay = requestedOverlay?.takeIf { it.isActive }
            if (overlay != null) {
                val processor = overlayProcessor ?: AndroidCameraOverlayProcessor().also { overlayProcessor = it }
                processor.setState(overlay)
                val overlaid = processor.composite(
                    processedTexture = imageTexture,
                    width = imageWidth,
                    height = imageHeight,
                    rotationDegrees = 0,
                    rotationKnown = true,
                    mirror = false,
                    quadVao = quadVao,
                )
                // 0 = bypass (already logged by the processor): present the bare image.
                if (overlaid != 0) sourceTexture = overlaid
            } else if (overlayProcessor != null) {
                overlayProcessor?.release()
                overlayProcessor = null
            }

            // Source is already output-sized and upright: identity window, no stretch.
            // timestampNs 0 lets the producer stamp CLOCK_MONOTONIC at queue time.
            val ok = active.draw(egressProgram, quadVao, sourceTexture, imageWidth, imageHeight, 0, 0L)
            // Never leave the window surface current between ticks so stop()
            // can destroy it without racing the context.
            EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)
            if (!ok) {
                fail("egress_draw_failed")
                return
            }
            val count = ++framesRendered
            if (count == 1L) {
                Log.i(
                    TAG,
                    "ANDROID_LIVESTREAM_IMAGE_PUMP_READY output=${outputWidth}x$outputHeight fps=$fps " +
                        "path=$imagePath overlayItems=${overlay?.items?.size ?: 0} bindAttempts=$bindAttempts",
                )
                listener.onFirstFrameRendered(this)
            } else if (count % FRAME_LOG_INTERVAL == 0L) {
                Log.i(TAG, "ANDROID_LIVESTREAM_IMAGE_PUMP_FRAME frame=$count overlayItems=${overlay?.items?.size ?: 0}")
            }
        } catch (t: Throwable) {
            fail("render_exception:${t.javaClass.simpleName}:${t.message}")
        }
    }

    private fun fail(reason: String) {
        if (failed) return
        failed = true
        handler.removeCallbacks(tickRunnable)
        handler.removeCallbacks(bindRunnable)
        Log.e(TAG, "ANDROID_LIVESTREAM_IMAGE_PUMP_FAILED reason=$reason frames=$framesRendered")
        listener.onFailed(this, reason)
    }

    // ── Pump thread: GL setup / teardown ─────────────────────────────────────

    private fun initEgl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) throw RuntimeException("eglGetDisplay failed")
        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            eglDisplay = EGL14.EGL_NO_DISPLAY
            throw RuntimeException("eglInitialize failed")
        }
        val configAttribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0)
        if (numConfigs[0] == 0) throw RuntimeException("eglChooseConfig found no ES3 config")
        eglConfig = configs[0]!!

        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw RuntimeException("eglCreateContext failed")

        val pbufferAttribs = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
        pbufferSurface = EGL14.eglCreatePbufferSurface(eglDisplay, eglConfig, pbufferAttribs, 0)
        if (pbufferSurface == EGL14.EGL_NO_SURFACE) throw RuntimeException("eglCreatePbufferSurface failed")
        if (!EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)) {
            throw RuntimeException("eglMakeCurrent(pbuffer) failed")
        }
    }

    private fun initGlResources() {
        egressProgram = buildProgram(EGRESS_VERTEX_SHADER, EGRESS_FRAGMENT_SHADER)

        val vaos = IntArray(1)
        GLES30.glGenVertexArrays(1, vaos, 0)
        quadVao = vaos[0]
        val vbos = IntArray(1)
        GLES30.glGenBuffers(1, vbos, 0)
        quadVbo = vbos[0]

        val quadBuffer = ByteBuffer.allocateDirect(FULLSCREEN_QUAD.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .put(FULLSCREEN_QUAD)
            .also { it.position(0) }
        GLES30.glBindVertexArray(quadVao)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, quadVbo)
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, FULLSCREEN_QUAD.size * 4, quadBuffer, GLES30.GL_STATIC_DRAW)
        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 16, 0)
        GLES30.glEnableVertexAttribArray(1)
        GLES30.glVertexAttribPointer(1, 2, GLES30.GL_FLOAT, false, 16, 8)
        GLES30.glBindVertexArray(0)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, 0)
    }

    // Context must be current. Uploads into a NEW texture and swaps it in only
    // after a clean upload, so a failed upload leaves the previous image (and
    // imageWidth/imageHeight) exactly as they were. Always recycles the bitmap.
    // Throws on any failure.
    private fun uploadImage(image: DecodedImage) {
        val width = image.bitmap.width
        val height = image.bitmap.height
        val textures = IntArray(1)
        GLES30.glGenTextures(1, textures, 0)
        val newTexture = textures[0]
        try {
            if (newTexture == 0) throw RuntimeException("glGenTextures returned 0")
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, newTexture)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
            GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, image.bitmap, 0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
            val err = GLES30.glGetError()
            if (err != GLES30.GL_NO_ERROR) {
                throw RuntimeException("texture upload failed: 0x${Integer.toHexString(err)}")
            }
            val previous = imageTexture
            imageTexture = newTexture
            imageWidth = width
            imageHeight = height
            if (previous != 0) GLES30.glDeleteTextures(1, intArrayOf(previous), 0)
        } catch (t: Throwable) {
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
            if (newTexture != 0) GLES30.glDeleteTextures(1, intArrayOf(newTexture), 0)
            throw t
        } finally {
            image.recycle()
        }
    }

    private fun releaseOnThread() {
        try {
            if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT &&
                pbufferSurface != EGL14.EGL_NO_SURFACE
            ) {
                // The window surface must not be current when it is destroyed.
                EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)
            }
            renderer?.release()
            renderer = null
            overlayProcessor?.release()
            overlayProcessor = null
            if (imageTexture != 0) {
                GLES30.glDeleteTextures(1, intArrayOf(imageTexture), 0)
                imageTexture = 0
            }
            if (egressProgram != 0) {
                GLES30.glDeleteProgram(egressProgram)
                egressProgram = 0
            }
            if (quadVbo != 0) {
                GLES30.glDeleteBuffers(1, intArrayOf(quadVbo), 0)
                quadVbo = 0
            }
            if (quadVao != 0) {
                GLES30.glDeleteVertexArrays(1, intArrayOf(quadVao), 0)
                quadVao = 0
            }
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                if (pbufferSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglDestroySurface(eglDisplay, pbufferSurface)
                    pbufferSurface = EGL14.EGL_NO_SURFACE
                }
                EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (eglContext != EGL14.EGL_NO_CONTEXT) {
                    EGL14.eglDestroyContext(eglDisplay, eglContext)
                    eglContext = EGL14.EGL_NO_CONTEXT
                }
                EGL14.eglTerminate(eglDisplay)
                eglDisplay = EGL14.EGL_NO_DISPLAY
            }
            Log.i(TAG, "ANDROID_LIVESTREAM_IMAGE_PUMP_STOPPED frames=$framesRendered path=$imagePath")
        } catch (t: Throwable) {
            Log.e(TAG, "release failed: ${t.message}", t)
        }
    }

    // ── Shader helpers ───────────────────────────────────────────────────────

    private fun buildProgram(vertexSrc: String, fragmentSrc: String): Int {
        val vs = compileShader(GLES30.GL_VERTEX_SHADER, vertexSrc)
        val fs = try {
            compileShader(GLES30.GL_FRAGMENT_SHADER, fragmentSrc)
        } catch (t: Throwable) {
            GLES30.glDeleteShader(vs)
            throw t
        }
        val program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vs)
        GLES30.glAttachShader(program, fs)
        GLES30.glLinkProgram(program)
        val status = IntArray(1)
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, status, 0)
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        if (status[0] != GLES30.GL_TRUE) {
            val log = GLES30.glGetProgramInfoLog(program)
            GLES30.glDeleteProgram(program)
            throw RuntimeException("program link failed: $log")
        }
        return program
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, source)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] != GLES30.GL_TRUE) {
            val log = GLES30.glGetShaderInfoLog(shader)
            GLES30.glDeleteShader(shader)
            throw RuntimeException("shader compile failed: $log")
        }
        return shader
    }
}
