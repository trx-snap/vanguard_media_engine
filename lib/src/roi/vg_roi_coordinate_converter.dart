// vg_roi_coordinate_converter.dart
// UMF V2 ROI Coordinate Conversion Utilities (ROI-1A)

import 'vg_roi_models.dart';

/// Coordinate converter helper class for ROI boxes.
class VGROICoordinateConverter {
  /// Converts an Apple Vision normalized bottom-left / Y-up rectangle
  /// into a shared top-left / Y-down normalized [VGROIBox].
  static VGROIBox fromVision({
    required double x,
    required double y,
    required double w,
    required double h,
  }) {
    if (x.isNaN || x.isInfinite || y.isNaN || y.isInfinite || w.isNaN || w.isInfinite || h.isNaN || h.isInfinite) {
      throw ArgumentError('Inputs must be finite numbers.');
    }
    if (x < 0.0 || x > 1.0 || y < 0.0 || y > 1.0 || w < 0.0 || w > 1.0 || h < 0.0 || h > 1.0) {
      throw ArgumentError('Input coordinates must be in normalized [0.0, 1.0] range.');
    }
    if (w < 0.0 || h < 0.0) {
      throw ArgumentError('Width and height must be non-negative.');
    }
    if (x + w > 1.0 + 1e-9 || y + h > 1.0 + 1e-9) {
      throw ArgumentError('Input box overflows normalized bounds (x+w > 1.0 or y+h > 1.0).');
    }

    final double xShared = x;
    final double yShared = 1.0 - (y + h);
    final double wShared = w;
    final double hShared = h;

    // Delegate to VGROIBox constructor which performs final bounds check and validation.
    return VGROIBox(
      x: xShared,
      y: yShared,
      w: wShared,
      h: hShared,
    );
  }

  /// Converts an Android ML Kit pixel top-left rectangle
  /// into a shared top-left / Y-down normalized [VGROIBox].
  static VGROIBox fromMLKit({
    required double left,
    required double top,
    required double right,
    required double bottom,
    required double frameWidth,
    required double frameHeight,
  }) {
    if (left.isNaN ||
        left.isInfinite ||
        top.isNaN ||
        top.isInfinite ||
        right.isNaN ||
        right.isInfinite ||
        bottom.isNaN ||
        bottom.isInfinite ||
        frameWidth.isNaN ||
        frameWidth.isInfinite ||
        frameHeight.isNaN ||
        frameHeight.isInfinite) {
      throw ArgumentError('Inputs must be finite numbers.');
    }
    if (frameWidth <= 0.0 || frameHeight <= 0.0) {
      throw ArgumentError('Frame dimensions must be positive.');
    }
    if (right < left) {
      throw ArgumentError('right must be greater than or equal to left.');
    }
    if (bottom < top) {
      throw ArgumentError('bottom must be greater than or equal to top.');
    }

    final double xNorm = left / frameWidth;
    final double yNorm = top / frameHeight;
    final double wNorm = (right - left) / frameWidth;
    final double hNorm = (bottom - top) / frameHeight;

    if (xNorm < 0.0 || xNorm > 1.0 || yNorm < 0.0 || yNorm > 1.0 || wNorm < 0.0 || wNorm > 1.0 || hNorm < 0.0 || hNorm > 1.0) {
      throw ArgumentError('Converted coordinates must fall within [0.0, 1.0] range.');
    }
    if (xNorm + wNorm > 1.0 + 1e-9 || yNorm + hNorm > 1.0 + 1e-9) {
      throw ArgumentError('Converted box overflows normalized bounds (x+w > 1.0 or y+h > 1.0).');
    }

    return VGROIBox(
      x: xNorm,
      y: yNorm,
      w: wNorm,
      h: hNorm,
    );
  }
}
