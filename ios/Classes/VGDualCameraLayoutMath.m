// VGDualCameraLayoutMath.m
// vanguard_media_engine — MC-1A: Layout geometry extraction
//
// Pure geometry / layout math for dual-camera PiP and split-screen composition.
//
// All three functions (VGDCLayoutComputePiPGeometry, VGDCLayoutComputeSplitRects,
// VGDCLayoutComputeAspectFill) are extracted verbatim from the arithmetic that
// was proven in VGDualCameraCompositorNode phases 7.x-H, 7.x-J, 7.x-K.
//
// Extraction rules:
//   • No behaviour change — every clamp, every branch, every fallback is
//     identical to the original inline code.
//   • No CoreImage / CVPixelBuffer / AVFoundation — pure math only.
//   • No side effects — no NSLog, no atomic counters, no allocations.
//     Callers retain responsibility for their own logging.
//   • No UMF dependencies.
//
// ── CONSTRAINTS ──────────────────────────────────────────────────────────────
//
//   DO NOT add AVFoundation / CoreImage / UMF imports.
//   DO NOT add live-capture logic.
//   DO NOT add session or mode management.
//

#import "VGDualCameraLayoutMath.h"
#include <math.h>  // floor, fmin (MIN macro)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - VGDCLayoutComputePiPGeometry
// ─────────────────────────────────────────────────────────────────────────────
//
// Extracted from VGDualCameraCompositorNode._compositeWithPrimary:secondary:
// Phase 7.x-H / 7.x-J, steps 2 and 3 (lines 1936–2002 of the source file).
//
// Step 2: widthFraction/marginFraction → pipW, pipH, margin with clamping.
// Step 3: anchor → pipOriginX, pipOriginY with origin clamping.
// Phase 7.x-J: cornerRadius clamped to [0, MIN(pipW,pipH)/2].
// Phase 7.x-J: opacity clamped to [0.0, 1.0].
//
// Every branch is preserved exactly, including the cascade:
//   wf clamp → pipW → pipH → margin → maxPipW → pipW clamp
//   → pipH recompute → pipH clamp → maxPipH → pipH clamp → pipW adjust.

VGDCPiPGeometry VGDCLayoutComputePiPGeometry(size_t primW,
                                              size_t primH,
                                              size_t secW,
                                              size_t secH,
                                              VGPiPLayoutConfig config) {
    VGDCPiPGeometry result;
    result.pipOriginX          = 0.0;
    result.pipOriginY          = 0.0;
    result.pipW                = 1.0;
    result.pipH                = 1.0;
    result.clampedCornerRadius = 0.0;
    result.clampedOpacity      = 1.0;

    // ── Degenerate guard ────────────────────────────────────────────────────
    // If primary canvas is zero we cannot do anything meaningful.
    // Return a 1×1 degenerate result — caller should also guard before calling.
    if (primW == 0 || primH == 0) {
        return result;
    }

    // ── 2. PiP geometry ─────────────────────────────────────────────────────
    // (Preserves Phase 7.x-H arithmetic exactly.)

    double wf = config.widthFraction;
    double mf = config.marginFraction;

    // Clamp widthFraction: must produce a non-zero, bounded PiP width.
    if (wf < 0.01) { wf = 0.01; }
    if (wf > 0.95) { wf = 0.95; }

    double pipW = (double)primW * wf;
    double pipH = (secH > 0 && secW > 0)
                  ? pipW * (double)secH / (double)secW
                  : pipW; // fallback: square
    double margin = (double)primW * mf;

    // Clamp: PiP must fit within primary bounds after margin.
    // Maximum pipW such that pipW + 2*margin <= primW.
    double maxPipW = (double)primW - 2.0 * margin;
    if (maxPipW < 1.0) { maxPipW = 1.0; margin = 0.0; }
    if (pipW > maxPipW) { pipW = maxPipW; }

    // Recompute pipH after pipW clamp.
    if (secW > 0) { pipH = pipW * (double)secH / (double)secW; }
    if (pipH < 1.0) { pipH = 1.0; }

    // Clamp pipH so PiP fits vertically.
    double maxPipH = (double)primH - 2.0 * margin;
    if (maxPipH < 1.0) { maxPipH = 1.0; }
    if (pipH > maxPipH) {
        pipH = maxPipH;
        // Preserve aspect ratio: scale pipW down proportionally.
        if (secH > 0) { pipW = pipH * (double)secW / (double)secH; }
    }

    // ── 3. Anchor → CIImage Y-up origin ─────────────────────────────────────
    // CIImage coordinate system: Y=0 at bottom, Y=primH at top.
    // margin from the edge:
    //   bottom anchors: pipOriginY = margin
    //   top anchors:    pipOriginY = primH - pipH - margin

    double pipOriginX = 0.0;
    double pipOriginY = 0.0;

    switch (config.anchor) {
        case VGPiPAnchorTopLeft:
            pipOriginX = margin;
            pipOriginY = (double)primH - pipH - margin;
            break;
        case VGPiPAnchorTopRight:
            pipOriginX = (double)primW - pipW - margin;
            pipOriginY = (double)primH - pipH - margin;
            break;
        case VGPiPAnchorBottomLeft:
            pipOriginX = margin;
            pipOriginY = margin;
            break;
        case VGPiPAnchorBottomRight:
        default:
            pipOriginX = (double)primW - pipW - margin;
            pipOriginY = margin;
            break;
    }

    // Clamp origin so PiP stays within primary bounds.
    if (pipOriginX < 0.0) { pipOriginX = 0.0; }
    if (pipOriginY < 0.0) { pipOriginY = 0.0; }
    if (pipOriginX + pipW > (double)primW) { pipOriginX = (double)primW - pipW; }
    if (pipOriginY + pipH > (double)primH) { pipOriginY = (double)primH - pipH; }

    // ── Phase 7.x-J: Corner radius clamping ─────────────────────────────────
    // clampedCornerRadius must be in [0, MIN(pipW, pipH)/2].
    double cr = config.cornerRadius;
    if (cr < 0.0) { cr = 0.0; }
    double pipShortSide = (pipW < pipH) ? pipW : pipH;  // MIN without macro ambiguity
    double maxCR = pipShortSide * 0.5;
    if (cr > maxCR) { cr = maxCR; }

    // ── Phase 7.x-J: Opacity clamping ───────────────────────────────────────
    double op = config.opacity;
    if (op < 0.0) { op = 0.0; }
    if (op > 1.0) { op = 1.0; }

    result.pipOriginX          = pipOriginX;
    result.pipOriginY          = pipOriginY;
    result.pipW                = pipW;
    result.pipH                = pipH;
    result.clampedCornerRadius = cr;
    result.clampedOpacity      = op;
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - VGDCLayoutComputeSplitRects
// ─────────────────────────────────────────────────────────────────────────────
//
// Extracted from VGDualCameraCompositorNode._compositeWithSplitScreen:secondary:
// Phase 7.x-K, step 2 (lines 1760–1804 of the source file).
//
// splitRatio clamped to [0.2, 0.8].
// topH = floor(canvasH * clampedRatio); bottomH = canvasH - topH.
// topRect (primary):   {x=0, y=bottomH, w=canvasW, h=topH}   (Y-up: upper band)
// bottomRect (secondary): {x=0, y=0,    w=canvasW, h=bottomH} (Y-up: lower band)
// isValid = NO if either band < 1 pixel.

VGDCSplitRects VGDCLayoutComputeSplitRects(size_t canvasW,
                                            size_t canvasH,
                                            VGSplitScreenLayoutConfig config) {
    VGDCSplitRects result;
    result.topRect    = CGRectZero;
    result.bottomRect = CGRectZero;
    result.isValid    = NO;

    if (canvasW == 0 || canvasH == 0) {
        return result;
    }

    // ── Split geometry ───────────────────────────────────────────────────────
    // (Preserves Phase 7.x-K arithmetic exactly.)

    double sr = config.splitRatio;
    // Clamp to safe range.
    if (sr < 0.2) { sr = 0.2; }
    if (sr > 0.8) { sr = 0.8; }

    // topH: height of the primary (top) band (CoreImage Y-up: upper y values).
    // bottomH: height of the secondary (bottom) band (y=0 at bottom-left).
    double topH    = floor((double)canvasH * sr);
    double bottomH = (double)canvasH - topH;

    // Guard: both bands must be at least 1 pixel.
    if (topH < 1.0 || bottomH < 1.0) {
        return result; // isValid = NO already set
    }

    double cW = (double)canvasW;

    // CoreImage Y-up:
    //   top band (primary):    origin Y = bottomH, height = topH
    //   bottom band (secondary): origin Y = 0,       height = bottomH
    result.topRect    = CGRectMake(0.0, bottomH, cW, topH);
    result.bottomRect = CGRectMake(0.0, 0.0,     cW, bottomH);
    result.isValid    = YES;
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - VGDCLayoutComputeAspectFill
// ─────────────────────────────────────────────────────────────────────────────
//
// Extracted from the `aspectFillIntoRect` Obj-C block inside
// VGDualCameraCompositorNode._compositeWithSplitScreen:secondary:
// Phase 7.x-K, step 4 (lines 1807–1838 of the source file).
//
// Returns the scale and center offsets.
// The caller is responsible for:
//   1. Normalizing the source CIImage origin to (0,0) before applying the result.
//   2. Applying the scale transform.
//   3. Applying the translation by (offsetX, offsetY).
//   4. Cropping to targetRect to prevent bleed.
//
// This separation is intentional: the function stays pure (no CIImage dependency).

VGDCAspectFillResult VGDCLayoutComputeAspectFill(size_t srcW,
                                                   size_t srcH,
                                                   CGRect targetRect) {
    VGDCAspectFillResult result;
    result.scale   = 1.0;
    result.offsetX = 0.0;
    result.offsetY = 0.0;

    if (srcW == 0 || srcH == 0) {
        // Safe no-op: scale=1, offsets=0. Caller should guard before calling.
        return result;
    }

    // ── Aspect-fill scale ────────────────────────────────────────────────────
    // (Preserves Phase 7.x-K arithmetic exactly.)
    //
    // scale = MAX(targetW / srcW, targetH / srcH).
    // If targetW or targetH is zero, the corresponding scale is 0; MAX handles it.
    double scaleX = CGRectGetWidth(targetRect)  / (double)srcW;
    double scaleY = CGRectGetHeight(targetRect) / (double)srcH;
    double scale  = (scaleX > scaleY) ? scaleX : scaleY;  // MAX
    if (scale <= 0.0) { scale = 1.0; }

    // ── Center offsets ───────────────────────────────────────────────────────
    // After scaling: scaled image is (srcW*scale) × (srcH*scale).
    // Center it over targetRect:
    //   offsetX = targetRect.minX + (targetRect.width  - scaledW) * 0.5
    //   offsetY = targetRect.minY + (targetRect.height - scaledH) * 0.5
    double scaledW  = (double)srcW * scale;
    double scaledH  = (double)srcH * scale;
    double offsetX  = CGRectGetMinX(targetRect) + (CGRectGetWidth(targetRect)  - scaledW) * 0.5;
    double offsetY  = CGRectGetMinY(targetRect) + (CGRectGetHeight(targetRect) - scaledH) * 0.5;

    result.scale   = scale;
    result.offsetX = offsetX;
    result.offsetY = offsetY;
    return result;
}
