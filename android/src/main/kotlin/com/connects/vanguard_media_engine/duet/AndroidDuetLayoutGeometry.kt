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
}
