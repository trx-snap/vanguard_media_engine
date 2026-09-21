package com.connects.vanguard_media_engine.duet

// VG-DUET-SLICE-4A: Native geometry helpers mirroring VGDuetLayoutMath.dart.
//
// Pure, stateless, renderer-independent. Mirrors the Dart layout math for:
//   - splitLeftRight (50/50 horizontal)
//   - splitTopBottom (50/50 vertical)
//   - pip (normalizedRect → pixel rects)
//   - greenScreen (full-background source, camera overlay placeholder) —
//     ownership moved to greenscreen/AndroidGreenScreenLayoutGeometry.kt;
//     the overloads below delegate there for source compatibility.
//
// No Android framework, View, or media dependencies.

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenForegroundTransform
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenLayoutGeometry
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenLayoutRects
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenPixelRect

// Source-compatible aliases: the rect/transform models are owned by
// GreenScreen. Kept here so existing Duet call sites (split/PiP callers,
// AndroidDuetPreviewCompositor.kt, AndroidDuetPreviewRenderLoop.kt,
// AndroidDuetSessionCoordinator.kt, AndroidDuetExportSession.kt) keep
// compiling unchanged.
typealias VGDuetPixelRect = AndroidGreenScreenPixelRect
typealias VGDuetLayoutRects = AndroidGreenScreenLayoutRects
typealias NativeForegroundTransform = AndroidGreenScreenForegroundTransform

/**
 * Duet-only preview rotation metadata for the green-screen foreground/camera
 * layer: the free-rotation angle (visual clockwise degrees, Dart/top-left
 * space) plus the normalized pivot anchor within the camera rect that
 * [AndroidDuetPreviewCompositor] rotates the camera quad around. Never
 * serialized to Dart — [AndroidDuetLayoutGeometry.greenScreen] and the
 * MethodChannel layout-rect reply continue to carry only source/camera rects.
 */
data class VGDuetForegroundRotation(
    val rotationDegrees: Double,
    val anchorX: Double,
    val anchorY: Double,
) {
    companion object {
        val IDENTITY = VGDuetForegroundRotation(rotationDegrees = 0.0, anchorX = 0.5, anchorY = 0.5)
    }
}

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
    // Ownership moved to AndroidGreenScreenLayoutGeometry.greenScreen(...);
    // these overloads delegate for source compatibility with existing Duet
    // callers (AndroidDuetSessionCoordinator.kt, AndroidDuetExportSession.kt).

    /**
     * Returns rects for the Green Screen layout.
     * - [source] fills the full canvas (background video).
     * - [camera] is a placeholder equal to the full canvas; the compositor
     *   slice that performs keying will crop/overlay as needed.
     */
    fun greenScreen(canvasWidth: Double, canvasHeight: Double): VGDuetLayoutRects =
        AndroidGreenScreenLayoutGeometry.greenScreen(canvasWidth, canvasHeight)

    /**
     * Returns rects for the Green Screen layout with an optional foreground transform.
     * See [AndroidGreenScreenLayoutGeometry.greenScreen] for the exact math and semantics.
     */
    fun greenScreen(
        canvasWidth:  Double,
        canvasHeight: Double,
        transform:    NativeForegroundTransform?,
    ): VGDuetLayoutRects =
        AndroidGreenScreenLayoutGeometry.greenScreen(canvasWidth, canvasHeight, transform)

    // ── Foreground rotation (preview-only, Duet-owned) ─────────────────────────

    /**
     * Derives preview-only rotation metadata from a foreground transform.
     *
     * Mirrors the same finiteness rules [AndroidGreenScreenLayoutGeometry.greenScreen]
     * uses for the rect: a null [transform], or a non-finite/non-positive scale
     * (which forces that function to the full-canvas identity rect), also forces
     * identity rotation here (0 degrees, centered anchor). A valid transform's
     * rotationDegrees and anchor are carried through even when the unrotated rect
     * happens to equal the full canvas (scale 1.0, zero offset, centered anchor),
     * since rotation can still be visually meaningful in that case.
     */
    fun foregroundRotation(transform: NativeForegroundTransform?): VGDuetForegroundRotation {
        if (transform == null) return VGDuetForegroundRotation.IDENTITY

        val rawScale = transform.scale
        if (!rawScale.isFinite() || rawScale <= 0.0) return VGDuetForegroundRotation.IDENTITY

        val rawAnchorX = transform.anchorX
        val rawAnchorY = transform.anchorY
        val anchorX = (if (rawAnchorX.isFinite()) rawAnchorX else 0.5).coerceIn(0.0, 1.0)
        val anchorY = (if (rawAnchorY.isFinite()) rawAnchorY else 0.5).coerceIn(0.0, 1.0)

        val rawRotation = transform.rotationDegrees
        val rotationDegrees = if (rawRotation.isFinite()) rawRotation else 0.0

        return VGDuetForegroundRotation(rotationDegrees = rotationDegrees, anchorX = anchorX, anchorY = anchorY)
    }
}
