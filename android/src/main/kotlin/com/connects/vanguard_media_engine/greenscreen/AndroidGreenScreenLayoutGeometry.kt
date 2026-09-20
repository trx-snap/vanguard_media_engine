package com.connects.vanguard_media_engine.greenscreen

// GreenScreen layout geometry: rect and foreground-transform concepts owned
// by the independent GreenScreen capability (not Duet). Moved out of
// duet/AndroidDuetLayoutGeometry.kt's `greenScreen(...)` helpers, which now
// delegate here for source compatibility.
//
// Pure, stateless, renderer-independent. No Android framework, View, or
// media dependencies.

/**
 * Immutable pixel-space rect returned by geometry helpers.
 */
data class AndroidGreenScreenPixelRect(
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
data class AndroidGreenScreenLayoutRects(
    val source: AndroidGreenScreenPixelRect,
    val camera: AndroidGreenScreenPixelRect,
)

/**
 * Parsed foreground camera-layer transform for native geometry computation.
 *
 * All fields are raw (pre-clamp) values from the layout config map;
 * clamping is performed inside [AndroidGreenScreenLayoutGeometry.greenScreen].
 */
data class AndroidGreenScreenForegroundTransform(
    val scale:   Double,
    val offsetX: Double,
    val offsetY: Double,
    val anchorX: Double,
    val anchorY: Double,
)

/**
 * Pure static helpers for GreenScreen spatial layout geometry.
 *
 * All returned rects are in canvas-pixel coordinates.
 */
object AndroidGreenScreenLayoutGeometry {

    /**
     * Returns rects for the Green Screen layout.
     * - [AndroidGreenScreenLayoutRects.source] fills the full canvas (background video).
     * - [AndroidGreenScreenLayoutRects.camera] is a placeholder equal to the full canvas; the
     *   compositor slice that performs keying will crop/overlay as needed.
     */
    fun greenScreen(canvasWidth: Double, canvasHeight: Double): AndroidGreenScreenLayoutRects {
        val full = AndroidGreenScreenPixelRect(0.0, 0.0, canvasWidth, canvasHeight)
        return AndroidGreenScreenLayoutRects(source = full, camera = full)
    }

    /**
     * Returns rects for the Green Screen layout with an optional foreground transform.
     *
     * When [transform] is null or has non-finite/non-positive scale, returns the
     * full-canvas identity (backwards compatible with existing green-screen sessions
     * without a transform).
     *
     * Transform semantics (v1 — shrink/reposition only):
     * - scale is clamped to [0.25, 1.0] before rect math; malformed scale degrades
     *   to the full-canvas identity.
     * - offset is a normalized canvas-center translation, defaulting non-finite
     *   values to 0.0 before clamping to [-1.0, 1.0].
     * - anchor is the point within the scaled rect that maps to canvas-center + offset,
     *   defaulting non-finite values to 0.5 before clamping to [0.0, 1.0].
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
        transform:    AndroidGreenScreenForegroundTransform?,
    ): AndroidGreenScreenLayoutRects {
        val full = AndroidGreenScreenPixelRect(0.0, 0.0, canvasWidth, canvasHeight)
        val source = full

        if (transform == null) {
            return AndroidGreenScreenLayoutRects(source = source, camera = full)
        }

        val rawScale = transform.scale
        if (!rawScale.isFinite() || rawScale <= 0.0) {
            return AndroidGreenScreenLayoutRects(source = source, camera = full)
        }

        // Normalize and clamp inputs.
        val scale = rawScale.coerceIn(0.25, 1.0)
        val rawOffsetX = transform.offsetX
        val rawOffsetY = transform.offsetY
        val offsetX = (if (rawOffsetX.isFinite()) rawOffsetX else 0.0).coerceIn(-1.0, 1.0)
        val offsetY = (if (rawOffsetY.isFinite()) rawOffsetY else 0.0).coerceIn(-1.0, 1.0)
        val rawAnchorX = transform.anchorX
        val rawAnchorY = transform.anchorY
        val anchorX = (if (rawAnchorX.isFinite()) rawAnchorX else 0.5).coerceIn(0.0, 1.0)
        val anchorY = (if (rawAnchorY.isFinite()) rawAnchorY else 0.5).coerceIn(0.0, 1.0)

        // Identity short-circuit: scale 1.0 with no offset returns full canvas
        // without any rect math.
        if (scale >= 1.0 && offsetX == 0.0 && offsetY == 0.0) {
            return AndroidGreenScreenLayoutRects(source = source, camera = full)
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

        val camera = AndroidGreenScreenPixelRect(left, top, scaledW, scaledH)
        return AndroidGreenScreenLayoutRects(source = source, camera = camera)
    }
}
