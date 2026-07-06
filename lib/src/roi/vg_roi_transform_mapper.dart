// vg_roi_transform_mapper.dart
// UMF V2 ROI Signal / Server-Ready Sidecar Coordinate Mapper (ROI-1B.1)

import 'dart:math' as math;
import 'vg_roi_models.dart';

class _Point {
  final double x;
  final double y;
  const _Point(this.x, this.y);
}

class VGROITransformMapper {
  /// Transforms capture-space normalized coordinates to export-output-normalized coordinates.
  /// Returns null if the transformed box is entirely outside the canvas bounds.
  static VGROIBox? mapBox({
    required VGROIBox captureBox,
    required double sourceWidth,
    required double sourceHeight,
    required double canvasWidth,
    required double canvasHeight,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double rotation = 0.0,
    double translationX = 0.0,
    double translationY = 0.0,
  }) {
    // 1. Input validations
    if (sourceWidth.isNaN || sourceWidth.isInfinite || sourceWidth <= 0.0 ||
        sourceHeight.isNaN || sourceHeight.isInfinite || sourceHeight <= 0.0 ||
        canvasWidth.isNaN || canvasWidth.isInfinite || canvasWidth <= 0.0 ||
        canvasHeight.isNaN || canvasHeight.isInfinite || canvasHeight <= 0.0) {
      throw ArgumentError('Source and canvas dimensions must be finite and greater than 0.');
    }
    if (scaleX.isNaN || scaleX.isInfinite || scaleX <= 0.0 ||
        scaleY.isNaN || scaleY.isInfinite || scaleY <= 0.0) {
      throw ArgumentError('Scale factors must be finite and greater than 0.');
    }
    if (rotation.isNaN || rotation.isInfinite ||
        translationX.isNaN || translationX.isInfinite ||
        translationY.isNaN || translationY.isInfinite) {
      throw ArgumentError('Rotation and translations must be finite.');
    }

    // 2. Convert captureBox from normalized source coordinates to source pixel corners
    final double sx0 = captureBox.x * sourceWidth;
    final double sy0 = captureBox.y * sourceHeight;
    final double sx1 = (captureBox.x + captureBox.w) * sourceWidth;
    final double sy1 = (captureBox.y + captureBox.h) * sourceHeight;

    final corners = [
      _Point(sx0, sy0), // TL
      _Point(sx1, sy0), // TR
      _Point(sx1, sy1), // BR
      _Point(sx0, sy1), // BL
    ];

    // 3. Aspect-fit source into canvas
    final double fitScale = math.min(canvasWidth / sourceWidth, canvasHeight / sourceHeight);
    final double fittedWidth = sourceWidth * fitScale;
    final double fittedHeight = sourceHeight * fitScale;
    final double offsetX = (canvasWidth - fittedWidth) / 2.0;
    final double offsetY = (canvasHeight - fittedHeight) / 2.0;

    final List<_Point> fittedCorners = [];
    for (final corner in corners) {
      final double cx = corner.x * fitScale + offsetX;
      final double cy = corner.y * fitScale + offsetY;
      fittedCorners.add(_Point(cx, cy));
    }

    // 4. Apply center-anchor transform
    final double anchorX = canvasWidth * 0.5;
    final double anchorY = canvasHeight * 0.5;

    final double cosR = math.cos(rotation);
    final double sinR = math.sin(rotation);

    final List<_Point> transformedCorners = [];
    for (final corner in fittedCorners) {
      // 4a. Translate to anchor origin
      final double rx = corner.x - anchorX;
      final double ry = corner.y - anchorY;

      // 4b. Scale
      final double sx = rx * scaleX;
      final double sy = ry * scaleY;

      // 4c. Rotate (clockwise positive in top-left/Y-down coordinates)
      final double nx = sx * cosR - sy * sinR;
      final double ny = sx * sinR + sy * cosR;

      // 4d. Translate back and apply user translation
      final double tx = nx + anchorX + translationX;
      final double ty = ny + anchorY + translationY;

      transformedCorners.add(_Point(tx, ty));
    }

    // 5. Compute AABB from transformed corners
    double minX = transformedCorners[0].x;
    double maxX = transformedCorners[0].x;
    double minY = transformedCorners[0].y;
    double maxY = transformedCorners[0].y;

    for (int i = 1; i < 4; i++) {
      final double x = transformedCorners[i].x;
      final double y = transformedCorners[i].y;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    // 6. Intersect AABB with canvas bounds
    final double clampMinX = math.max(0.0, minX);
    final double clampMinY = math.max(0.0, minY);
    final double clampMaxX = math.min(canvasWidth, maxX);
    final double clampMaxY = math.min(canvasHeight, maxY);

    if (clampMinX >= clampMaxX || clampMinY >= clampMaxY) {
      return null;
    }

    // 7. Normalize
    double outX = clampMinX / canvasWidth;
    double outY = clampMinY / canvasHeight;
    double outW = (clampMaxX - clampMinX) / canvasWidth;
    double outH = (clampMaxY - clampMinY) / canvasHeight;

    // 8. Apply float-drift cleanup after normalization
    outX = outX.clamp(0.0, 1.0);
    outY = outY.clamp(0.0, 1.0);
    outW = outW.clamp(0.0, 1.0 - outX);
    outH = outH.clamp(0.0, 1.0 - outY);

    if (outW <= 0.0 || outH <= 0.0) {
      return null;
    }

    return VGROIBox(x: outX, y: outY, w: outW, h: outH);
  }
}
