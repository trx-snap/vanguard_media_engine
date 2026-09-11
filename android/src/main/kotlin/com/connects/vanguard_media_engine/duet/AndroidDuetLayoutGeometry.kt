package com.connects.vanguard_media_engine.duet

// VG-DUET-SLICE-4A: Native geometry helpers mirroring VGDuetLayoutMath.dart.
//
// Pure, stateless, renderer-independent. Mirrors the Dart layout math for:
//   - splitLeftRight (50/50 horizontal)
//   - splitTopBottom (50/50 vertical)
//   - pip (normalizedRect → pixel rects)
//   - greenScreen (full-background source, camera overlay placeholder)
//
// No Android framework, View, or media dependencies.

/**
 * Immutable pixel-space rect returned by geometry helpers.
 */
data class VGDuetPixelRect(
    val left:   Double,
    val top:    Double,
    val width:  Double,
    val height: Double,
) {
    /** Serializes to a flat map for MethodChannel transport. */
    fun toMap(): Map<String, Double> = mapOf(
        "left"   to left,
        "top"    to top,
        "width"  to width,
        "height" to height,
    )
}

/** Return type for layout helpers; [source] and [camera] rects in canvas-pixel coordinates. */
data class VGDuetLayoutRects(val source: VGDuetPixelRect, val camera: VGDuetPixelRect)

/**
 * Pure static helpers for Duet spatial layout geometry.
 *
 * Matches the semantics of `VGDuetLayoutMath` in Dart.
 * All returned rects are in canvas-pixel coordinates.
 */
object AndroidDuetLayoutGeometry {

    // ── Split Left/Right ─────────────────────────────────────────────────────

    /**
     * Returns [source, camera] rects for a 50/50 horizontal split.
     *
     * Default (not swapped): source occupies the left half, camera the right.
     * Swapped: camera on left, source on right.
     */
    fun splitLeftRight(
        canvasWidth:  Double,
        canvasHeight: Double,
        isSwapped:    Boolean,
    ): VGDuetLayoutRects {
        val halfW  = canvasWidth / 2.0
        val left   = VGDuetPixelRect(0.0, 0.0, halfW, canvasHeight)
        val right  = VGDuetPixelRect(halfW, 0.0, halfW, canvasHeight)
        return if (isSwapped) VGDuetLayoutRects(source = right, camera = left)
        else                  VGDuetLayoutRects(source = left,  camera = right)
    }

    // ── Split Top/Bottom ─────────────────────────────────────────────────────

    /**
     * Returns [source, camera] rects for a 50/50 vertical split.
     *
     * Default (not swapped): source on top, camera on bottom.
     * Swapped: camera on top, source on bottom.
     */
    fun splitTopBottom(
        canvasWidth:  Double,
        canvasHeight: Double,
        isSwapped:    Boolean,
    ): VGDuetLayoutRects {
        val halfH  = canvasHeight / 2.0
        val top    = VGDuetPixelRect(0.0, 0.0,   canvasWidth, halfH)
        val bottom = VGDuetPixelRect(0.0, halfH,  canvasWidth, halfH)
        return if (isSwapped) VGDuetLayoutRects(source = bottom, camera = top)
        else                  VGDuetLayoutRects(source = top,    camera = bottom)
    }

    // ── PiP ─────────────────────────────────────────────────────────────────

    /** Returns the full-canvas source rect used in PiP mode. */
    fun pipSourceRect(canvasWidth: Double, canvasHeight: Double) =
        VGDuetPixelRect(0.0, 0.0, canvasWidth, canvasHeight)

    /**
     * Converts a normalised PiP rect (0–1 fraction of canvas) to pixel rect.
     * The normalised rect is anchored relative to the canvas origin (top-left).
     */
    fun pipCameraRect(
        canvasWidth:      Double,
        canvasHeight:     Double,
        normalizedLeft:   Double,
        normalizedTop:    Double,
        normalizedWidth:  Double,
        normalizedHeight: Double,
    ) = VGDuetPixelRect(
        left   = normalizedLeft   * canvasWidth,
        top    = normalizedTop    * canvasHeight,
        width  = normalizedWidth  * canvasWidth,
        height = normalizedHeight * canvasHeight,
    )

    // ── Green Screen ─────────────────────────────────────────────────────────

    /**
     * Returns rects for the Green Screen layout.
     * - [source] fills the full canvas (background video).
     * - [camera] is a placeholder equal to the full canvas; the compositor
     *   slice that performs keying will crop/overlay as needed.
     */
    fun greenScreen(canvasWidth: Double, canvasHeight: Double): VGDuetLayoutRects {
        val full = VGDuetPixelRect(0.0, 0.0, canvasWidth, canvasHeight)
        return VGDuetLayoutRects(source = full, camera = full)
    }

    /**
     * Returns rects for the Green Screen layout with an optional foreground transform.
     *
     * When [transform] is null or has scale == 1.0, returns the full-canvas identity
     * (backwards compatible with existing green-screen sessions without a transform).
     *
     * Transform semantics (v1 — shrink/reposition only):
     * - scale is clamped to [0.25, 1.0] before rect math.
     * - offset is a normalized canvas-center translation, clamped to [-1.0, 1.0].
     * - anchor is the point within the scaled rect that maps to canvas-center + offset,
     *   clamped to [0.0, 1.0].
     *
     * Rect math:
     *   scaledW = canvasWidth  * clampedScale
     *   scaledH = canvasHeight * clampedScale
     *   canvasCx = canvasWidth  / 2.0
     *   canvasCy = canvasHeight / 2.0
     *   targetX  = canvasCx + clampedOffsetX * canvasCx  // anchor maps here
     *   targetY  = canvasCy + clampedOffsetY * canvasCy
     *   left     = targetX - clampedAnchorX * scaledW
     *   top      = targetY - clampedAnchorY * scaledH
     *   then clamp rect fully inside [0, canvasWidth] x [0, canvasHeight].
     */
    fun greenScreen(
        canvasWidth:  Double,
        canvasHeight: Double,
        transform:    NativeForegroundTransform?,
    ): VGDuetLayoutRects {
        val full = VGDuetPixelRect(0.0, 0.0, canvasWidth, canvasHeight)
        val source = full

        if (transform == null) {
            return VGDuetLayoutRects(source = source, camera = full)
        }

        // Clamp inputs.
        val scale   = transform.scale.coerceIn(0.25, 1.0)
        val offsetX = transform.offsetX.coerceIn(-1.0, 1.0)
        val offsetY = transform.offsetY.coerceIn(-1.0, 1.0)
        val anchorX = transform.anchorX.coerceIn(0.0, 1.0)
        val anchorY = transform.anchorY.coerceIn(0.0, 1.0)

        // Identity short-circuit: scale 1.0 with centered anchor and no offset
        // returns full canvas without any rect math.
        if (scale >= 1.0 && offsetX == 0.0 && offsetY == 0.0) {
            return VGDuetLayoutRects(source = source, camera = full)
        }

        val scaledW = canvasWidth  * scale
        val scaledH = canvasHeight * scale

        // Canvas center and target point in canvas coordinates.
        val canvasCx = canvasWidth  / 2.0
        val canvasCy = canvasHeight / 2.0
        val targetX  = canvasCx + offsetX * canvasCx
        val targetY  = canvasCy + offsetY * canvasCy

        // Unclamped rect with anchor mapping to target.
        var left = targetX - anchorX * scaledW
        var top  = targetY - anchorY * scaledH

        // Clamp rect fully inside canvas; size is fixed by scale.
        left = left.coerceIn(0.0, canvasWidth  - scaledW)
        top  = top.coerceIn(0.0, canvasHeight - scaledH)

        val camera = VGDuetPixelRect(left, top, scaledW, scaledH)
        return VGDuetLayoutRects(source = source, camera = camera)
    }
}

/**
 * Parsed foreground camera-layer transform for native geometry computation.
 *
 * All fields are raw (pre-clamp) values from the layout config map;
 * clamping is performed inside [AndroidDuetLayoutGeometry.greenScreen].
 */
data class NativeForegroundTransform(
    val scale:   Double,
    val offsetX: Double,
    val offsetY: Double,
    val anchorX: Double,
    val anchorY: Double,
)
