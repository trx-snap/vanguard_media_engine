// Copyright 2026, Connects. All rights reserved.
// Pure Dart — no dart:io, no dart:ui, no Flutter geometry types.

import 'vg_duet_models.dart';

/// Pure, stateless layout math for Duet compositions.
///
/// All methods are static and operate exclusively on package-owned geometry
/// types ([VGDuetRect], [VGDuetSize], [VGDuetPoint], [VGDuetInsets]).
/// No Flutter [Rect]/[Size]/[Offset] or [dart:ui] types are used.
abstract final class VGDuetLayoutMath {
  VGDuetLayoutMath._();

  // ── Split layout rects ─────────────────────────────────────────────────────

  /// Returns `[sourceRect, cameraRect]` for a left-right 50/50 split.
  ///
  /// Default (not swapped): source occupies the left half, camera the right.
  /// When [isSwapped] is `true`: camera on left, source on right.
  ///
  /// Each half is exactly half the canvas width at full canvas height.
  static List<VGDuetRect> computeLeftRightSplitRects({
    required VGDuetSize canvasSize,
    required bool isSwapped,
  }) {
    final halfW = canvasSize.width / 2.0;
    final h = canvasSize.height;

    final leftRect = VGDuetRect(left: 0.0, top: 0.0, width: halfW, height: h);
    final rightRect = VGDuetRect(
      left: halfW,
      top: 0.0,
      width: halfW,
      height: h,
    );

    // Default: source=left, camera=right
    // Swapped: camera=left, source=right
    return isSwapped
        ? [rightRect, leftRect] // [sourceRect, cameraRect]
        : [leftRect, rightRect];
  }

  /// Returns `[sourceRect, cameraRect]` for a top-bottom 50/50 split.
  ///
  /// Default (not swapped): source on top, camera on bottom.
  /// When [isSwapped] is `true`: camera on top, source on bottom.
  static List<VGDuetRect> computeTopBottomSplitRects({
    required VGDuetSize canvasSize,
    required bool isSwapped,
  }) {
    final w = canvasSize.width;
    final halfH = canvasSize.height / 2.0;

    final topRect = VGDuetRect(left: 0.0, top: 0.0, width: w, height: halfH);
    final botRect = VGDuetRect(left: 0.0, top: halfH, width: w, height: halfH);

    return isSwapped
        ? [botRect, topRect] // [sourceRect, cameraRect]
        : [topRect, botRect];
  }

  // ── Green screen layout rects ──────────────────────────────────────────────

  /// Returns `[sourceRect, cameraRect]` for a green-screen composition.
  ///
  /// The source rect is always full canvas.
  /// When [transform] is null, the camera rect is also full canvas (identity).
  ///
  /// When [transform] is non-null:
  /// - scale is clamped to `[0.25, 1.0]`. If scale is non-finite or `<= 0.0`,
  ///   it degrades to identity (full canvas camera rect).
  /// - offset is clamped to `[-1.0, 1.0]`. Non-finite offset components default to 0.0.
  /// - anchor is clamped to `[0.0, 1.0]`. Non-finite anchor components default to 0.5.
  /// - If clamped scale >= 1.0 and offset is (0.0, 0.0), camera rect is full canvas.
  /// - Otherwise, camera rect is scaled, positioned relative to canvas center + offset,
  ///   and clamped fully inside the canvas bounds.
  static List<VGDuetRect> computeGreenScreenRects({
    required VGDuetSize canvasSize,
    VGDuetForegroundTransform? transform,
  }) {
    final full = VGDuetRect(
      left: 0.0,
      top: 0.0,
      width: canvasSize.width,
      height: canvasSize.height,
    );
    final sourceRect = full;

    if (transform == null) {
      return [sourceRect, full];
    }

    final rawScale = transform.scale;
    if (!rawScale.isFinite || rawScale <= 0.0) {
      return [sourceRect, full];
    }

    final scale = rawScale.clamp(0.25, 1.0);

    final rawOffsetX = transform.offset.x;
    final rawOffsetY = transform.offset.y;
    final offsetX = (rawOffsetX.isFinite ? rawOffsetX : 0.0).clamp(-1.0, 1.0);
    final offsetY = (rawOffsetY.isFinite ? rawOffsetY : 0.0).clamp(-1.0, 1.0);

    final rawAnchorX = transform.anchor.x;
    final rawAnchorY = transform.anchor.y;
    final anchorX = (rawAnchorX.isFinite ? rawAnchorX : 0.5).clamp(0.0, 1.0);
    final anchorY = (rawAnchorY.isFinite ? rawAnchorY : 0.5).clamp(0.0, 1.0);

    if (scale >= 1.0 && offsetX == 0.0 && offsetY == 0.0) {
      return [sourceRect, full];
    }

    final scaledW = canvasSize.width * scale;
    final scaledH = canvasSize.height * scale;

    final cx = canvasSize.width / 2.0;
    final cy = canvasSize.height / 2.0;
    final targetX = cx + offsetX * cx;
    final targetY = cy + offsetY * cy;

    var left = targetX - anchorX * scaledW;
    var top = targetY - anchorY * scaledH;

    final maxLeft = (canvasSize.width - scaledW).clamp(0.0, double.infinity);
    final maxTop = (canvasSize.height - scaledH).clamp(0.0, double.infinity);
    left = left.clamp(0.0, maxLeft);
    top = top.clamp(0.0, maxTop);

    final cameraRect = VGDuetRect(
      left: left,
      top: top,
      width: scaledW,
      height: scaledH,
    );

    return [sourceRect, cameraRect];
  }

  // ── PiP layout ─────────────────────────────────────────────────────────────

  /// Computes the PiP window rect in canvas-pixel coordinates.
  ///
  /// [widthFraction] is the fraction of canvas width used for the PiP window
  /// (default 0.35 = 35 %).
  /// [heightFraction] is the fraction of canvas height used for the PiP window
  /// (default 0.35 = 35 %).  When null, width drives a 9:16 aspect ratio.
  /// [marginFraction] is the safety margin fraction of the canvas width from
  /// each edge (default 0.018 ≈ 24 pt at 1334 px canvas width).
  ///
  /// Returns the PiP [VGDuetRect] anchored to [anchor].
  static VGDuetRect computePiPRect({
    required VGDuetSize canvasSize,
    required VGDuetPiPAnchor anchor,
    double widthFraction = 0.35,
    double? heightFraction,
    double marginFraction = 0.018,
  }) {
    final pipW = canvasSize.width * widthFraction;
    // Default 9:16 portrait aspect for the PiP overlay.
    final pipH = heightFraction != null
        ? canvasSize.height * heightFraction
        : pipW * (16.0 / 9.0);
    final margin = canvasSize.width * marginFraction;

    double left;
    double top;

    switch (anchor) {
      case VGDuetPiPAnchor.topLeft:
        left = margin;
        top = margin;
      case VGDuetPiPAnchor.topRight:
        left = canvasSize.width - pipW - margin;
        top = margin;
      case VGDuetPiPAnchor.bottomLeft:
        left = margin;
        top = canvasSize.height - pipH - margin;
      case VGDuetPiPAnchor.bottomRight:
        left = canvasSize.width - pipW - margin;
        top = canvasSize.height - pipH - margin;
    }

    return VGDuetRect(left: left, top: top, width: pipW, height: pipH);
  }

  // ── PiP drag helpers ───────────────────────────────────────────────────────

  /// Clamps a PiP top-left [offset] so the PiP window stays within the canvas
  /// minus [safeArea] insets.
  ///
  /// Returns a clamped [VGDuetPoint].
  static VGDuetPoint clampPiPOffset({
    required VGDuetPoint offset,
    required VGDuetSize canvasSize,
    required VGDuetSize pipSize,
    VGDuetInsets safeArea = VGDuetInsets.zero,
  }) {
    final minX = safeArea.left;
    final minY = safeArea.top;
    final maxX = canvasSize.width - pipSize.width - safeArea.right;
    final maxY = canvasSize.height - pipSize.height - safeArea.bottom;

    return VGDuetPoint(
      offset.x.clamp(minX, maxX.clamp(minX, double.infinity)),
      offset.y.clamp(minY, maxY.clamp(minY, double.infinity)),
    );
  }

  /// Snaps a PiP [currentOffset] to the nearest of the four corner anchors.
  ///
  /// Returns the [VGDuetPiPAnchor] for the nearest corner. Use
  /// [computePiPRect] with the returned anchor to obtain the snapped rect.
  static VGDuetPiPAnchor snapPiPToAnchor({
    required VGDuetPoint currentOffset,
    required VGDuetSize canvasSize,
    required VGDuetSize pipSize,
  }) {
    final centerX = currentOffset.x + pipSize.width / 2.0;
    final centerY = currentOffset.y + pipSize.height / 2.0;

    final bool isRight = centerX >= canvasSize.width / 2.0;
    final bool isBottom = centerY >= canvasSize.height / 2.0;

    if (isRight && isBottom) return VGDuetPiPAnchor.bottomRight;
    if (isRight && !isBottom) return VGDuetPiPAnchor.topRight;
    if (!isRight && isBottom) return VGDuetPiPAnchor.bottomLeft;
    return VGDuetPiPAnchor.topLeft;
  }

  // ── Aspect-fill crop ───────────────────────────────────────────────────────

  /// Computes the center-crop source rect (in source pixels) required to
  /// aspect-fill [targetSize] without distortion.
  ///
  /// The returned [VGDuetRect] is in **source-pixel space** (left/top are the
  /// crop origin within the source frame; width/height are the crop size).
  ///
  /// Example: 1080×1920 source → 540×960 target (left half) = no cropping.
  /// Example: 1920×1080 source → 540×960 target = letterbox removed by
  /// centre-cropping the width.
  static VGDuetRect computeAspectFillCrop(
    VGDuetSize sourceSize,
    VGDuetSize targetSize,
  ) {
    if (sourceSize.width <= 0 ||
        sourceSize.height <= 0 ||
        targetSize.width <= 0 ||
        targetSize.height <= 0) {
      return VGDuetRect(
        left: 0,
        top: 0,
        width: sourceSize.width,
        height: sourceSize.height,
      );
    }

    final srcAr = sourceSize.aspectRatio;
    final tgtAr = targetSize.aspectRatio;

    double cropW, cropH;
    if (srcAr > tgtAr) {
      // Source is wider than target → crop width
      cropH = sourceSize.height;
      cropW = cropH * tgtAr;
    } else {
      // Source is taller than target → crop height
      cropW = sourceSize.width;
      cropH = cropW / tgtAr;
    }

    final cropLeft = (sourceSize.width - cropW) / 2.0;
    final cropTop = (sourceSize.height - cropH) / 2.0;

    return VGDuetRect(
      left: cropLeft,
      top: cropTop,
      width: cropW,
      height: cropH,
    );
  }

  // ── Normalized PiP helpers ─────────────────────────────────────────────────

  /// Converts a normalized PiP rect (0.0–1.0) to canvas-pixel coordinates.
  static VGDuetRect normalizedToCanvasPiPRect(
    VGDuetRect normalized,
    VGDuetSize canvasSize,
  ) {
    return VGDuetRect(
      left: normalized.left * canvasSize.width,
      top: normalized.top * canvasSize.height,
      width: normalized.width * canvasSize.width,
      height: normalized.height * canvasSize.height,
    );
  }

  /// Converts a canvas-pixel PiP rect to normalized coordinates (0.0–1.0).
  static VGDuetRect canvasToNormalizedPiPRect(
    VGDuetRect canvasRect,
    VGDuetSize canvasSize,
  ) {
    return VGDuetRect(
      left: canvasRect.left / canvasSize.width,
      top: canvasRect.top / canvasSize.height,
      width: canvasRect.width / canvasSize.width,
      height: canvasRect.height / canvasSize.height,
    );
  }
}
