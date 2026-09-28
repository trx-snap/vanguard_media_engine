package com.connects.vanguard_media_engine.camera

// ── AndroidCameraOverlayProcessor ────────────────────────────────────────────
//
// G1-B (Android livestream text/sticker overlay): composites the static
// CameraOverlayState items over the processed live camera frame, hosted INSIDE
// AndroidCameraBeautySurfaceProcessor's own ES 3.x context on VGCameraGpuThread
// (same hosting model as AndroidCameraGreenScreenProcessor). No second camera,
// no second EGL context, no Flutter widget capture.
//
// Per frame (GPU thread, context current):
//   1. The post-beauty/green-screen texture (width x height, "quad space") is
//      copied 1:1 into this processor's own output texture of the SAME size
//      and space, so preview and egress keep consuming one texture.
//   2. Every drawable item is blended on top (SRC_ALPHA, ONE_MINUS_SRC_ALPHA)
//      in CameraOverlayState paint order (ascending z, stable).
//
// Geometry: item x/y/w/h are normalized against the pinned 720x1280 portrait
// canvas with a top-left origin. The canvas is anchored to the SAME centered
// 720:1280 window of the upright frame that AndroidCameraEgressRenderer streams
// (AndroidCameraEgressTransform.centeredWindow), then mapped back into quad
// space with the inverse-rotation table AndroidCameraGreenScreenProcessor and
// AndroidCameraEgressTransform already use for CameraX's
// TransformationInfo.rotationDegrees. Nothing is hardcoded per device/vendor.
// Mirroring: CameraX front-camera preview applies horizontal mirroring to the
// quad space (TransformationInfo.isMirroring). To keep text and sticker overlays
// reading normally in canonical viewer/output space and placed correctly on the
// 720x1280 portrait canvas, fromUpright mirrors the upright coordinate (p.x = 1 - p.x)
// when mirror is true so the texture content and placement do not inherit front-camera reversal.
//
// Resources: sticker files are decoded and text is rasterized ONCE per
// full-list replacement (setState with a new instance) into straight-alpha
// RGBA8 textures; entries whose content key is unchanged are reused and
// entries no longer present are deleted. The per-frame path allocates nothing.
//
// Fail-closed: a broken item is skipped (ANDROID_LIVESTREAM_OVERLAY_ITEM_SKIPPED)
// and the rest still draw; a processor-level failure logs
// ANDROID_LIVESTREAM_OVERLAY_BYPASS and composite() returns 0, so the caller
// presents the un-overlaid frame. Failures stick until the state changes.

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.opengl.GLES30
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class AndroidCameraOverlayProcessor {
    companion object {
        private const val TAG = "VGCameraOverlay"

        private const val FRAME_LOG_INTERVAL = 300L
        private const val MAX_DECODED_STICKER_DIMENSION = 2048
        private const val MIN_TEXT_SIZE_PX = 8f
        private const val TEXT_BACKGROUND_ALPHA = 140

        private const val COPY_VERTEX_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "layout(location = 0) in vec4 aPosition;\n" +
            "layout(location = 1) in vec4 aTexCoord;\n" +
            "out vec2 vTexCoord;\n" +
            "void main() {\n" +
            "    gl_Position = aPosition;\n" +
            "    vTexCoord = aTexCoord.xy;\n" +
            "}\n"

        private const val COPY_FRAGMENT_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform sampler2D uTex;\n" +
            "in vec2 vTexCoord;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "    fragColor = texture(uTex, vTexCoord);\n" +
            "}\n"

        // The caller's fullscreen quad VAO supplies canonical corners
        // (aTexCoord in {0,1}^2, v up). uRect is the item rectangle in upright
        // UV space (v up) already anchored to the streamed window; fromUpright
        // is the same inverse-rotation table as the green-screen shader and
        // AndroidCameraEgressTransform. Bitmap row 0 (top) sits at texture v=0,
        // so the item texture v is flipped relative to the upright corner.
        private const val ITEM_VERTEX_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "layout(location = 0) in vec4 aPosition;\n" +
            "layout(location = 1) in vec4 aTexCoord;\n" +
            "uniform vec4 uRect;\n" +
            "uniform int uRotation;\n" +
            "uniform int uMirror;\n" +
            "out vec2 vItemTex;\n" +
            "vec2 fromUpright(vec2 p) {\n" +
            "    vec2 up = p;\n" +
            "    if (uMirror == 1) up.x = 1.0 - up.x;\n" +
            "    if (uRotation == 90) return vec2(1.0 - up.y, up.x);\n" +
            "    if (uRotation == 180) return vec2(1.0 - up.x, 1.0 - up.y);\n" +
            "    if (uRotation == 270) return vec2(up.y, 1.0 - up.x);\n" +
            "    return up;\n" +
            "}\n" +
            "void main() {\n" +
            "    vec2 c = aTexCoord.xy;\n" +
            "    vec2 upright = mix(uRect.xy, uRect.zw, c);\n" +
            "    vec2 q = fromUpright(upright);\n" +
            "    gl_Position = vec4(q * 2.0 - 1.0, 0.0, 1.0);\n" +
            "    vItemTex = vec2(c.x, 1.0 - c.y);\n" +
            "}\n"

        private const val ITEM_FRAGMENT_SHADER =
            "#version 300 es\n" +
            "precision mediump float;\n" +
            "in vec2 vItemTex;\n" +
            "uniform sampler2D uItem;\n" +
            "uniform float uOpacity;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "    vec4 s = texture(uItem, vItemTex);\n" +
            "    fragColor = vec4(s.rgb, s.a * uOpacity);\n" +
            "}\n"
    }

    /** One uploaded straight-alpha RGBA8 texture, keyed by item content. */
    private class ItemTexture(val texture: Int, val width: Int, val height: Int)

    /** Per-frame draw record for one drawable item (null slot = skipped item). */
    private class DrawItem(
        val id: String,
        val texture: Int,
        val x: Float,
        val y: Float,
        val w: Float,
        val h: Float,
        val opacity: Float,
    )

    // ── Requested state (any thread) ─────────────────────────────────────────
    @Volatile private var requestedState: CameraOverlayState? = null

    /** True when a composite is wanted for the next frame. Any thread. */
    val isRequested: Boolean get() = requestedState?.isActive == true

    /** Any thread. A new instance triggers a resource rebuild and clears a sticky failure. */
    fun setState(state: CameraOverlayState?) {
        requestedState = state
    }

    // ── GPU-thread state ─────────────────────────────────────────────────────
    private var released = false
    private var programsReady = false
    private var failedForState: CameraOverlayState? = null

    private var copyProgram = 0
    private var uCopyTexLoc = -1
    private var itemProgram = 0
    private var uRectLoc = -1
    private var uRotationLoc = -1
    private var uMirrorLoc = -1
    private var uItemLoc = -1
    private var uOpacityLoc = -1

    private var outputTexture = 0
    private var outputFbo = 0
    private var outputWidth = 0
    private var outputHeight = 0

    // Item textures keyed by content; rebuilt only when the requested state
    // instance changes. drawItems is aligned with builtState.items.
    private val textures = HashMap<String, ItemTexture>()
    private var builtState: CameraOverlayState? = null
    private var drawItems: Array<DrawItem?> = emptyArray()
    private var drawableCount = 0

    // Upright rects (u0, v0, u1, v1 per item) for the current geometry only.
    private var rects = FloatArray(0)
    private var rectsWidth = 0
    private var rectsHeight = 0
    private var rectsRotation = -1

    private var readyLogged = false
    private var rotationWaitLogged = false
    private var frameCount = 0L

    /**
     * GPU thread, context current. Blends the requested overlay items over
     * [processedTexture] ([width] x [height], quad space) and returns the output
     * texture (same size, same space), or 0 to bypass — the caller then keeps
     * [processedTexture].
     *
     * [rotationDegrees] / [mirror] come from CameraX TransformationInfo.
     * Before the info arrived ([rotationKnown] false) the overlay is bypassed
     * (not a sticky failure) because item placement depends on the rotation.
     */
    fun composite(
        processedTexture: Int,
        width: Int,
        height: Int,
        rotationDegrees: Int,
        rotationKnown: Boolean,
        mirror: Boolean,
        quadVao: Int,
    ): Int {
        if (released) return 0
        val state = requestedState ?: return 0
        if (!state.isActive) return 0
        if (failedForState === state) return 0
        if (width <= 0 || height <= 0 || processedTexture == 0 || quadVao == 0) return 0
        if (!rotationKnown) {
            if (!rotationWaitLogged) {
                rotationWaitLogged = true
                Log.i(TAG, "ANDROID_LIVESTREAM_OVERLAY_BYPASS reason=rotation_unknown")
            }
            return 0
        }
        rotationWaitLogged = false
        val rotation = if (AndroidCameraEgressTransform.isSupportedRotation(rotationDegrees)) rotationDegrees else 0

        try {
            if (!ensurePrograms(state)) return 0
            if (!ensureOutputTarget(width, height, state)) return 0
            if (!ensureItems(state)) return 0
            ensureRects(state, width, height, rotation)
            if (!draw(processedTexture, width, height, rotation, mirror, quadVao, state)) return 0
        } catch (t: Throwable) {
            fail(state, "exception:${t.javaClass.simpleName}:${t.message}")
            return 0
        }

        frameCount++
        if (!readyLogged) {
            readyLogged = true
            Log.i(
                TAG,
                "ANDROID_LIVESTREAM_OVERLAY_READY items=$drawableCount " +
                    "canvas=${CameraOverlayState.CANVAS_WIDTH}x${CameraOverlayState.CANVAS_HEIGHT} " +
                    "target=${width}x$height rotation=$rotation mirror=$mirror",
            )
        }
        if (frameCount == 1L || frameCount % FRAME_LOG_INTERVAL == 0L) {
            Log.i(
                TAG,
                "ANDROID_LIVESTREAM_OVERLAY_FRAME items=$drawableCount target=${width}x$height " +
                    "rotation=$rotation frame=$frameCount",
            )
        }
        return outputTexture
    }

    /** GPU thread, context current. Idempotent; releases every GL resource. */
    fun release() {
        if (released) return
        released = true
        deleteAllItemTextures()
        drawItems = emptyArray()
        drawableCount = 0
        builtState = null
        deleteOutputTarget()
        if (copyProgram != 0) {
            GLES30.glDeleteProgram(copyProgram)
            copyProgram = 0
        }
        if (itemProgram != 0) {
            GLES30.glDeleteProgram(itemProgram)
            itemProgram = 0
        }
        programsReady = false
        Log.d(TAG, "released")
    }

    private fun fail(state: CameraOverlayState, reason: String): Boolean {
        failedForState = state
        Log.w(TAG, "ANDROID_LIVESTREAM_OVERLAY_BYPASS reason=$reason")
        return false
    }

    // ── Programs ─────────────────────────────────────────────────────────────

    private fun ensurePrograms(state: CameraOverlayState): Boolean {
        if (programsReady) return true
        try {
            copyProgram = buildProgram(COPY_VERTEX_SHADER, COPY_FRAGMENT_SHADER)
            itemProgram = buildProgram(ITEM_VERTEX_SHADER, ITEM_FRAGMENT_SHADER)
        } catch (t: Throwable) {
            if (copyProgram != 0) {
                GLES30.glDeleteProgram(copyProgram)
                copyProgram = 0
            }
            return fail(state, "program_failed:${t.message}")
        }
        uCopyTexLoc = GLES30.glGetUniformLocation(copyProgram, "uTex")
        uRectLoc = GLES30.glGetUniformLocation(itemProgram, "uRect")
        uRotationLoc = GLES30.glGetUniformLocation(itemProgram, "uRotation")
        uMirrorLoc = GLES30.glGetUniformLocation(itemProgram, "uMirror")
        uItemLoc = GLES30.glGetUniformLocation(itemProgram, "uItem")
        uOpacityLoc = GLES30.glGetUniformLocation(itemProgram, "uOpacity")
        programsReady = true
        return true
    }

    // ── Output target (same size as the input; NEAREST like finalTexture) ────

    private fun ensureOutputTarget(width: Int, height: Int, state: CameraOverlayState): Boolean {
        if (outputFbo != 0 && width == outputWidth && height == outputHeight) return true
        if (outputFbo != 0) {
            Log.i(TAG, "input size changed → output ${width}x$height")
            readyLogged = false
        }
        deleteOutputTarget()

        val texturesOut = IntArray(1)
        GLES30.glGenTextures(1, texturesOut, 0)
        outputTexture = texturesOut[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, outputTexture)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexImage2D(
            GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, width, height, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null,
        )
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)

        val fbos = IntArray(1)
        GLES30.glGenFramebuffers(1, fbos, 0)
        outputFbo = fbos[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, outputFbo)
        GLES30.glFramebufferTexture2D(
            GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, outputTexture, 0,
        )
        val status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        if (status != GLES30.GL_FRAMEBUFFER_COMPLETE) {
            deleteOutputTarget()
            return fail(state, "output_fbo_incomplete:$status")
        }
        outputWidth = width
        outputHeight = height
        return true
    }

    private fun deleteOutputTarget() {
        if (outputFbo != 0) {
            GLES30.glDeleteFramebuffers(1, intArrayOf(outputFbo), 0)
            outputFbo = 0
        }
        if (outputTexture != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(outputTexture), 0)
            outputTexture = 0
        }
        outputWidth = 0
        outputHeight = 0
    }

    // ── Item textures (rebuilt once per full-list replacement) ───────────────

    private fun ensureItems(state: CameraOverlayState): Boolean {
        if (builtState === state) {
            return if (drawableCount > 0) true else fail(state, "no_drawable_items")
        }

        val items = state.items
        val newDraws = arrayOfNulls<DrawItem>(items.size)
        val wanted = HashSet<String>(items.size)
        var drawable = 0
        for (i in items.indices) {
            val item = items[i]
            val pixelW = max(1, (item.w * CameraOverlayState.CANVAS_WIDTH).roundToInt())
            val pixelH = max(1, (item.h * CameraOverlayState.CANVAS_HEIGHT).roundToInt())
            val key = contentKey(item, pixelW, pixelH)
            var entry = textures[key]
            if (entry == null) {
                entry = buildItemTexture(item, pixelW, pixelH)
                if (entry == null) continue
                textures[key] = entry
            }
            wanted.add(key)
            newDraws[i] = DrawItem(
                id = item.id,
                texture = entry.texture,
                x = item.x,
                y = item.y,
                w = item.w,
                h = item.h,
                opacity = item.opacity,
            )
            drawable++
        }

        // Prune textures the new list no longer references.
        val stale = ArrayList<String>()
        for ((key, entry) in textures) {
            if (key !in wanted) {
                GLES30.glDeleteTextures(1, intArrayOf(entry.texture), 0)
                stale.add(key)
            }
        }
        for (key in stale) textures.remove(key)

        drawItems = newDraws
        drawableCount = drawable
        builtState = state
        rectsRotation = -1 // force rect recompute for the new item list
        readyLogged = false
        frameCount = 0
        Log.i(TAG, "items rebuilt: requested=${items.size} drawable=$drawable textures=${textures.size}")

        val err = GLES30.glGetError()
        if (err != GLES30.GL_NO_ERROR) return fail(state, "item_upload_gl_error:0x${Integer.toHexString(err)}")
        if (drawable == 0) return fail(state, "no_drawable_items")
        return true
    }

    private fun contentKey(item: CameraOverlayState.Item, pixelW: Int, pixelH: Int): String =
        when (item.kind) {
            CameraOverlayState.Kind.TEXT ->
                "t|${item.id}|$pixelW|$pixelH|${item.text}"
            CameraOverlayState.Kind.STICKER -> {
                val path = item.assetPath ?: ""
                val file = File(path)
                "s|${item.id}|$pixelW|$pixelH|$path|${file.lastModified()}|${file.length()}"
            }
        }

    private fun buildItemTexture(item: CameraOverlayState.Item, pixelW: Int, pixelH: Int): ItemTexture? {
        val rgba: RgbaImage = when (item.kind) {
            CameraOverlayState.Kind.TEXT -> rasterizeText(item, pixelW, pixelH)
            CameraOverlayState.Kind.STICKER -> decodeSticker(item, pixelW, pixelH)
        } ?: return null

        val texturesOut = IntArray(1)
        GLES30.glGenTextures(1, texturesOut, 0)
        val tex = texturesOut[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        rgba.buffer.rewind()
        GLES30.glTexImage2D(
            GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, rgba.width, rgba.height, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, rgba.buffer,
        )
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
        val err = GLES30.glGetError()
        if (err != GLES30.GL_NO_ERROR) {
            GLES30.glDeleteTextures(1, intArrayOf(tex), 0)
            skip(item, "texture_upload_failed:0x${Integer.toHexString(err)}")
            return null
        }
        return ItemTexture(tex, rgba.width, rgba.height)
    }

    private fun deleteAllItemTextures() {
        if (textures.isEmpty()) return
        val ids = IntArray(textures.size)
        var i = 0
        for (entry in textures.values) ids[i++] = entry.texture
        GLES30.glDeleteTextures(ids.size, ids, 0)
        textures.clear()
    }

    private fun skip(item: CameraOverlayState.Item, reason: String) {
        Log.w(TAG, "ANDROID_LIVESTREAM_OVERLAY_ITEM_SKIPPED id=${item.id} reason=$reason")
    }

    // ── Straight-alpha RGBA sources ──────────────────────────────────────────

    private class RgbaImage(val buffer: ByteBuffer, val width: Int, val height: Int)

    /**
     * Rasterizes the item's text into a [pixelW] x [pixelH] straight-alpha RGBA
     * image: white bold centered text over a translucent rounded box, shrunk
     * until it fits the box (same style as AndroidTimelineOverlayTextRasterizer).
     * Returns null (after logging ITEM_SKIPPED) on any failure.
     */
    private fun rasterizeText(item: CameraOverlayState.Item, pixelW: Int, pixelH: Int): RgbaImage? {
        val text = item.text
        if (text.isNullOrEmpty()) {
            skip(item, "text_empty")
            return null
        }
        var bitmap: Bitmap? = null
        try {
            bitmap = Bitmap.createBitmap(pixelW, pixelH, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)

            val padding = (min(pixelW, pixelH) * 0.06f).coerceIn(2f, 16f)
            val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.BLACK
                alpha = TEXT_BACKGROUND_ALPHA
            }
            val radius = (min(pixelW, pixelH) * 0.1f).coerceIn(4f, 16f)
            canvas.drawRoundRect(RectF(0f, 0f, pixelW.toFloat(), pixelH.toFloat()), radius, radius, backgroundPaint)

            val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                typeface = Typeface.DEFAULT_BOLD
            }
            val layoutWidth = max(1, (pixelW - 2f * padding).toInt())
            val maxLayoutHeight = max(1f, pixelH - 2f * padding)
            var textSize = max(MIN_TEXT_SIZE_PX, pixelH * 0.6f)
            textPaint.textSize = textSize
            var layout = buildTextLayout(text, textPaint, layoutWidth)
            // Shrink until the wrapped text fits the box (once per rebuild, not per frame).
            while (layout.height > maxLayoutHeight && textSize > MIN_TEXT_SIZE_PX) {
                textSize = max(MIN_TEXT_SIZE_PX, textSize * 0.85f)
                textPaint.textSize = textSize
                layout = buildTextLayout(text, textPaint, layoutWidth)
            }

            val offsetY = max(padding, (pixelH - layout.height) / 2f)
            canvas.save()
            canvas.clipRect(0, 0, pixelW, pixelH)
            canvas.translate(padding, offsetY)
            layout.draw(canvas)
            canvas.restore()

            return repackStraightAlpha(bitmap)
        } catch (oom: OutOfMemoryError) {
            skip(item, "text_out_of_memory")
            return null
        } catch (t: Throwable) {
            skip(item, "text_rasterize_failed:${t.javaClass.simpleName}")
            return null
        } finally {
            bitmap?.recycle()
        }
    }

    private fun buildTextLayout(text: String, paint: TextPaint, width: Int): StaticLayout =
        StaticLayout.Builder
            .obtain(text, 0, text.length, paint, width)
            .setAlignment(Layout.Alignment.ALIGN_CENTER)
            .setIncludePad(false)
            .setMaxLines(Int.MAX_VALUE)
            .build()

    /**
     * Decodes the sticker file once (straight alpha, sampled down toward the
     * target rect and capped at [MAX_DECODED_STICKER_DIMENSION]). Returns null
     * (after logging ITEM_SKIPPED) if the file is missing or undecodable.
     */
    private fun decodeSticker(item: CameraOverlayState.Item, targetW: Int, targetH: Int): RgbaImage? {
        val path = item.assetPath
        if (path.isNullOrBlank()) {
            skip(item, "asset_path_missing")
            return null
        }
        val file = File(path)
        if (!file.isFile || !file.canRead()) {
            skip(item, "asset_file_unreadable")
            return null
        }
        var bitmap: Bitmap? = null
        try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                skip(item, "asset_bounds_unreadable")
                return null
            }
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= targetW && bounds.outHeight / (sample * 2) >= targetH) {
                sample *= 2
            }
            while (bounds.outWidth / sample > MAX_DECODED_STICKER_DIMENSION ||
                bounds.outHeight / sample > MAX_DECODED_STICKER_DIMENSION
            ) {
                sample *= 2
            }
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inPremultiplied = false
                inScaled = false
            }
            bitmap = BitmapFactory.decodeFile(path, opts)
            val decoded = bitmap
            if (decoded == null) {
                skip(item, "asset_decode_failed")
                return null
            }
            if (decoded.config == Bitmap.Config.HARDWARE) {
                skip(item, "asset_hardware_bitmap")
                return null
            }
            if (decoded.width <= 0 || decoded.height <= 0) {
                skip(item, "asset_invalid_dimensions")
                return null
            }
            return repackStraightAlpha(decoded)
        } catch (oom: OutOfMemoryError) {
            skip(item, "asset_out_of_memory")
            return null
        } catch (t: Throwable) {
            skip(item, "asset_decode_exception:${t.javaClass.simpleName}")
            return null
        } finally {
            bitmap?.recycle()
        }
    }

    // Bitmap.getPixels returns un-premultiplied ARGB ints; repacking to RGBA
    // bytes yields a straight-alpha texture, which is what the
    // SRC_ALPHA / ONE_MINUS_SRC_ALPHA blend below expects (same approach as the
    // timeline overlay rasterizer/decoder; GLUtils.texImage2D would upload the
    // premultiplied pixels of a Canvas-drawn bitmap instead).
    private fun repackStraightAlpha(bitmap: Bitmap): RgbaImage {
        val width = bitmap.width
        val height = bitmap.height
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        val buffer = ByteBuffer.allocateDirect(pixels.size * 4).order(ByteOrder.nativeOrder())
        for (argb in pixels) {
            buffer.put(((argb ushr 16) and 0xFF).toByte())
            buffer.put(((argb ushr 8) and 0xFF).toByte())
            buffer.put((argb and 0xFF).toByte())
            buffer.put(((argb ushr 24) and 0xFF).toByte())
        }
        buffer.rewind()
        return RgbaImage(buffer, width, height)
    }

    // ── Geometry (recomputed only when size/rotation/item list change) ───────

    private fun ensureRects(state: CameraOverlayState, width: Int, height: Int, rotation: Int) {
        if (rectsWidth == width && rectsHeight == height && rectsRotation == rotation &&
            rects.size == drawItems.size * 4
        ) {
            return
        }
        if (rects.size != drawItems.size * 4) rects = FloatArray(drawItems.size * 4)

        // The canvas is anchored to the centered 720:1280 window of the upright
        // frame — exactly the region AndroidCameraEgressRenderer streams — so
        // preview and egress place every item identically relative to the
        // streamed picture.
        val upright = AndroidCameraEgressTransform.uprightSize(width, height, rotation)
        val window = AndroidCameraEgressTransform.centeredWindow(
            upright[0], upright[1], CameraOverlayState.CANVAS_WIDTH, CameraOverlayState.CANVAS_HEIGHT,
        )
        val scaleX = window[0]
        val scaleY = window[1]
        val offsetX = window[2]
        val offsetY = window[3]

        for (i in drawItems.indices) {
            val item = drawItems[i] ?: continue
            // Canvas is top-left / +y down; upright UV is +v up.
            val u0 = item.x
            val u1 = item.x + item.w
            val v1 = 1f - item.y
            val v0 = 1f - (item.y + item.h)
            val base = i * 4
            rects[base] = offsetX + u0 * scaleX
            rects[base + 1] = offsetY + v0 * scaleY
            rects[base + 2] = offsetX + u1 * scaleX
            rects[base + 3] = offsetY + v1 * scaleY
        }
        rectsWidth = width
        rectsHeight = height
        rectsRotation = rotation
        Log.d(
            TAG,
            "geometry: target=${width}x$height rotation=$rotation upright=${upright[0]}x${upright[1]} " +
                "window=[$scaleX,$scaleY,$offsetX,$offsetY] items=${state.items.size}",
        )
    }

    // ── Composite ────────────────────────────────────────────────────────────

    private fun draw(
        processedTexture: Int,
        width: Int,
        height: Int,
        rotation: Int,
        mirror: Boolean,
        quadVao: Int,
        state: CameraOverlayState,
    ): Boolean {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, outputFbo)
        GLES30.glViewport(0, 0, width, height)

        // 1. Copy the processed frame 1:1 into the output (nearest, no blend).
        GLES30.glDisable(GLES30.GL_BLEND)
        GLES30.glUseProgram(copyProgram)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, processedTexture)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
        GLES30.glUniform1i(uCopyTexLoc, 0)
        GLES30.glBindVertexArray(quadVao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

        // 2. Blend every drawable item in paint order.
        GLES30.glEnable(GLES30.GL_BLEND)
        GLES30.glBlendFunc(GLES30.GL_SRC_ALPHA, GLES30.GL_ONE_MINUS_SRC_ALPHA)
        GLES30.glUseProgram(itemProgram)
        GLES30.glUniform1i(uRotationLoc, rotation)
        GLES30.glUniform1i(uMirrorLoc, if (mirror) 1 else 0)
        GLES30.glUniform1i(uItemLoc, 0)
        for (i in drawItems.indices) {
            val item = drawItems[i] ?: continue
            if (item.opacity <= 0f) continue
            val base = i * 4
            GLES30.glUniform4f(uRectLoc, rects[base], rects[base + 1], rects[base + 2], rects[base + 3])
            GLES30.glUniform1f(uOpacityLoc, item.opacity)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, item.texture)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        }
        GLES30.glDisable(GLES30.GL_BLEND)

        GLES30.glBindVertexArray(0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        val err = GLES30.glGetError()
        if (err != GLES30.GL_NO_ERROR) {
            return fail(state, "composite_gl_error:0x${Integer.toHexString(err)}")
        }
        return true
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
        val prog = GLES30.glCreateProgram()
        GLES30.glAttachShader(prog, vs)
        GLES30.glAttachShader(prog, fs)
        GLES30.glLinkProgram(prog)
        val status = IntArray(1)
        GLES30.glGetProgramiv(prog, GLES30.GL_LINK_STATUS, status, 0)
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        if (status[0] != GLES30.GL_TRUE) {
            val log = GLES30.glGetProgramInfoLog(prog)
            GLES30.glDeleteProgram(prog)
            throw RuntimeException("overlay program link failed: $log")
        }
        return prog
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
            throw RuntimeException("overlay shader compile failed: $log")
        }
        return shader
    }
}
