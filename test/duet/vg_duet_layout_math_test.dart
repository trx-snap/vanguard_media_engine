// Copyright 2026, Connects. All rights reserved.
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_models.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_layout_math.dart';

const _canvas = VGDuetSize(1080.0, 1920.0);
const _eps = 0.01; // 1 % tolerance

void main() {
  group('VGDuetLayoutMath.computeLeftRightSplitRects', () {
    test('default (not swapped): source=left, camera=right', () {
      final rects = VGDuetLayoutMath.computeLeftRightSplitRects(
        canvasSize: _canvas,
        isSwapped: false,
      );
      final sourceRect = rects[0];
      final cameraRect = rects[1];

      // Source: left half
      expect(sourceRect.left, closeTo(0.0, _eps));
      expect(sourceRect.width, closeTo(_canvas.width / 2, _eps));
      expect(sourceRect.height, closeTo(_canvas.height, _eps));

      // Camera: right half
      expect(cameraRect.left, closeTo(_canvas.width / 2, _eps));
      expect(cameraRect.width, closeTo(_canvas.width / 2, _eps));
    });

    test('swapped: source=right, camera=left', () {
      final rects = VGDuetLayoutMath.computeLeftRightSplitRects(
        canvasSize: _canvas,
        isSwapped: true,
      );
      final sourceRect = rects[0];
      final cameraRect = rects[1];

      // Source is now the right half
      expect(sourceRect.left, closeTo(_canvas.width / 2, _eps));
      // Camera is now the left half
      expect(cameraRect.left, closeTo(0.0, _eps));
    });

    test('50/50 split: left+right widths = canvas width', () {
      final rects = VGDuetLayoutMath.computeLeftRightSplitRects(
        canvasSize: _canvas,
        isSwapped: false,
      );
      expect(rects[0].width + rects[1].width, closeTo(_canvas.width, _eps));
    });

    test('delta within 1 % of canvas width', () {
      final rects = VGDuetLayoutMath.computeLeftRightSplitRects(
        canvasSize: _canvas,
        isSwapped: false,
      );
      final delta = (rects[0].width - _canvas.width / 2).abs();
      expect(delta, lessThanOrEqualTo(_canvas.width * 0.01));
    });
  });

  group('VGDuetLayoutMath.computeTopBottomSplitRects', () {
    test('default (not swapped): source=top, camera=bottom', () {
      final rects = VGDuetLayoutMath.computeTopBottomSplitRects(
        canvasSize: _canvas,
        isSwapped: false,
      );
      final sourceRect = rects[0];
      final cameraRect = rects[1];

      expect(sourceRect.top, closeTo(0.0, _eps));
      expect(sourceRect.height, closeTo(_canvas.height / 2, _eps));
      expect(cameraRect.top, closeTo(_canvas.height / 2, _eps));
    });

    test('swapped: source=bottom, camera=top', () {
      final rects = VGDuetLayoutMath.computeTopBottomSplitRects(
        canvasSize: _canvas,
        isSwapped: true,
      );
      final sourceRect = rects[0];
      final cameraRect = rects[1];

      // Source is now the bottom half
      expect(sourceRect.top, closeTo(_canvas.height / 2, _eps));
      // Camera is now the top half
      expect(cameraRect.top, closeTo(0.0, _eps));
    });

    test('50/50: top+bottom heights = canvas height', () {
      final rects = VGDuetLayoutMath.computeTopBottomSplitRects(
        canvasSize: _canvas,
        isSwapped: false,
      );
      expect(rects[0].height + rects[1].height, closeTo(_canvas.height, _eps));
    });
  });

  group('VGDuetLayoutMath.computePiPRect', () {
    const anchor = VGDuetPiPAnchor.topRight;

    test('width matches widthFraction of canvas', () {
      final pip = VGDuetLayoutMath.computePiPRect(
        canvasSize: _canvas,
        anchor: anchor,
        widthFraction: 0.35,
      );
      expect(pip.width, closeTo(_canvas.width * 0.35, _eps));
    });

    test('PiP stays within canvas for all four anchors', () {
      for (final a in VGDuetPiPAnchor.values) {
        final pip = VGDuetLayoutMath.computePiPRect(
          canvasSize: _canvas,
          anchor: a,
          widthFraction: 0.35,
          marginFraction: 0.018,
        );
        expect(pip.left, greaterThanOrEqualTo(0.0));
        expect(pip.top, greaterThanOrEqualTo(0.0));
        expect(pip.right, lessThanOrEqualTo(_canvas.width));
        expect(pip.bottom, lessThanOrEqualTo(_canvas.height));
      }
    });

    test('topLeft anchor has small left and top', () {
      final pip = VGDuetLayoutMath.computePiPRect(
        canvasSize: _canvas,
        anchor: VGDuetPiPAnchor.topLeft,
        widthFraction: 0.35,
        marginFraction: 0.018,
      );
      final margin = _canvas.width * 0.018;
      expect(pip.left, closeTo(margin, _eps));
      expect(pip.top, closeTo(margin, _eps));
    });

    test('bottomRight anchor has right and bottom near canvas edges', () {
      final pip = VGDuetLayoutMath.computePiPRect(
        canvasSize: _canvas,
        anchor: VGDuetPiPAnchor.bottomRight,
        widthFraction: 0.35,
        marginFraction: 0.018,
      );
      final margin = _canvas.width * 0.018;
      expect(pip.right, closeTo(_canvas.width - margin, _eps));
      expect(pip.bottom, closeTo(_canvas.height - margin, _eps));
    });
  });

  group('VGDuetLayoutMath.snapPiPToAnchor', () {
    test('top-left quadrant snaps to topLeft', () {
      final anchor = VGDuetLayoutMath.snapPiPToAnchor(
        currentOffset: const VGDuetPoint(10.0, 10.0),
        canvasSize: _canvas,
        pipSize: const VGDuetSize(100.0, 180.0),
      );
      expect(anchor, VGDuetPiPAnchor.topLeft);
    });

    test('top-right quadrant snaps to topRight', () {
      final anchor = VGDuetLayoutMath.snapPiPToAnchor(
        currentOffset: VGDuetPoint(_canvas.width - 200.0, 10.0),
        canvasSize: _canvas,
        pipSize: const VGDuetSize(100.0, 180.0),
      );
      expect(anchor, VGDuetPiPAnchor.topRight);
    });

    test('bottom-left quadrant snaps to bottomLeft', () {
      final anchor = VGDuetLayoutMath.snapPiPToAnchor(
        currentOffset: VGDuetPoint(10.0, _canvas.height - 300.0),
        canvasSize: _canvas,
        pipSize: const VGDuetSize(100.0, 180.0),
      );
      expect(anchor, VGDuetPiPAnchor.bottomLeft);
    });

    test('bottom-right quadrant snaps to bottomRight', () {
      final anchor = VGDuetLayoutMath.snapPiPToAnchor(
        currentOffset: VGDuetPoint(
          _canvas.width - 200.0,
          _canvas.height - 300.0,
        ),
        canvasSize: _canvas,
        pipSize: const VGDuetSize(100.0, 180.0),
      );
      expect(anchor, VGDuetPiPAnchor.bottomRight);
    });
  });

  group('VGDuetLayoutMath.clampPiPOffset', () {
    const pipSize = VGDuetSize(378.0, 672.0); // 35 % of 1080x1920

    test('clamps negative offset to (0, 0) with zero safe area', () {
      final clamped = VGDuetLayoutMath.clampPiPOffset(
        offset: const VGDuetPoint(-50.0, -50.0),
        canvasSize: _canvas,
        pipSize: pipSize,
      );
      expect(clamped.x, closeTo(0.0, _eps));
      expect(clamped.y, closeTo(0.0, _eps));
    });

    test('clamps past-right-edge offset', () {
      final clamped = VGDuetLayoutMath.clampPiPOffset(
        offset: VGDuetPoint(_canvas.width + 100.0, 100.0),
        canvasSize: _canvas,
        pipSize: pipSize,
      );
      expect(clamped.x, lessThanOrEqualTo(_canvas.width - pipSize.width));
    });

    test('respects safe area insets', () {
      const safeArea = VGDuetInsets(left: 20.0, top: 40.0);
      final clamped = VGDuetLayoutMath.clampPiPOffset(
        offset: const VGDuetPoint(0.0, 0.0),
        canvasSize: _canvas,
        pipSize: pipSize,
        safeArea: safeArea,
      );
      expect(clamped.x, closeTo(20.0, _eps));
      expect(clamped.y, closeTo(40.0, _eps));
    });
  });

  group('VGDuetLayoutMath.computeAspectFillCrop', () {
    test('no crop needed when aspect ratios match', () {
      const source = VGDuetSize(540.0, 960.0); // 9:16
      const target = VGDuetSize(540.0, 960.0); // same
      final crop = VGDuetLayoutMath.computeAspectFillCrop(source, target);
      expect(crop.left, closeTo(0.0, _eps));
      expect(crop.top, closeTo(0.0, _eps));
      expect(crop.width, closeTo(540.0, _eps));
      expect(crop.height, closeTo(960.0, _eps));
    });

    test('wide source is cropped symmetrically for tall target', () {
      // Landscape source (16:9), portrait target (9:16)
      const source = VGDuetSize(1920.0, 1080.0);
      const target = VGDuetSize(540.0, 960.0);
      final crop = VGDuetLayoutMath.computeAspectFillCrop(source, target);

      // Crop is symmetric (centered)
      expect(crop.left, closeTo(crop.left, _eps));
      // Source height used fully; width cropped
      expect(crop.height, closeTo(1080.0, _eps));
      expect(crop.left, greaterThan(0.0));
      expect(crop.width, lessThan(1920.0));
    });

    test('tall source is cropped symmetrically for wide target', () {
      // Portrait source (9:16), landscape target (16:9)
      const source = VGDuetSize(1080.0, 1920.0);
      const target = VGDuetSize(960.0, 540.0);
      final crop = VGDuetLayoutMath.computeAspectFillCrop(source, target);

      // Source width used fully; height cropped
      expect(crop.width, closeTo(1080.0, _eps));
      expect(crop.top, greaterThan(0.0));
      expect(crop.height, lessThan(1920.0));
    });

    test('crop aspect ratio matches target (within 1 %)', () {
      const source = VGDuetSize(1920.0, 1080.0);
      const target = VGDuetSize(540.0, 960.0);
      final crop = VGDuetLayoutMath.computeAspectFillCrop(source, target);
      final cropAR = crop.width / crop.height;
      final targetAR = target.width / target.height;
      expect(cropAR, closeTo(targetAR, 0.01));
    });

    test('handles zero-dimension source gracefully', () {
      const source = VGDuetSize(0.0, 0.0);
      const target = VGDuetSize(540.0, 960.0);
      // Should not throw
      expect(
        () => VGDuetLayoutMath.computeAspectFillCrop(source, target),
        returnsNormally,
      );
    });
  });

  group('VGDuetLayoutMath.normalizedToCanvasPiPRect', () {
    test('converts correctly', () {
      const normalized = VGDuetRect(
        left: 0.63,
        top: 0.05,
        width: 0.35,
        height: 0.35,
      );
      final canvas = VGDuetLayoutMath.normalizedToCanvasPiPRect(
        normalized,
        _canvas,
      );
      expect(canvas.left, closeTo(0.63 * _canvas.width, _eps));
      expect(canvas.top, closeTo(0.05 * _canvas.height, _eps));
    });
  });

  group('VGDuetLayoutMath.canvasToNormalizedPiPRect', () {
    test('round-trip with normalizedToCanvasPiPRect', () {
      const normalized = VGDuetRect(
        left: 0.63,
        top: 0.05,
        width: 0.35,
        height: 0.35,
      );
      final canvas = VGDuetLayoutMath.normalizedToCanvasPiPRect(
        normalized,
        _canvas,
      );
      final restored = VGDuetLayoutMath.canvasToNormalizedPiPRect(
        canvas,
        _canvas,
      );
      expect(restored.left, closeTo(normalized.left, _eps));
      expect(restored.top, closeTo(normalized.top, _eps));
      expect(restored.width, closeTo(normalized.width, _eps));
      expect(restored.height, closeTo(normalized.height, _eps));
    });
  });

  group('VGDuetLayoutMath.computeGreenScreenRects', () {
    test('null transform => full source and camera rect', () {
      final rects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: null,
      );
      final sourceRect = rects[0];
      final cameraRect = rects[1];

      expect(sourceRect.left, closeTo(0.0, _eps));
      expect(sourceRect.top, closeTo(0.0, _eps));
      expect(sourceRect.width, closeTo(_canvas.width, _eps));
      expect(sourceRect.height, closeTo(_canvas.height, _eps));

      expect(cameraRect.left, closeTo(0.0, _eps));
      expect(cameraRect.top, closeTo(0.0, _eps));
      expect(cameraRect.width, closeTo(_canvas.width, _eps));
      expect(cameraRect.height, closeTo(_canvas.height, _eps));
    });

    test('creatorOverlay preset on 1080x1920 canvas', () {
      final rects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: VGDuetForegroundTransform.creatorOverlay,
      );
      final sourceRect = rects[0];
      final cameraRect = rects[1];

      // Source is full canvas
      expect(sourceRect.left, closeTo(0.0, _eps));
      expect(sourceRect.top, closeTo(0.0, _eps));
      expect(sourceRect.width, closeTo(1080.0, _eps));
      expect(sourceRect.height, closeTo(1920.0, _eps));

      // Camera: left 205.2, top 576.0, width 669.6, height 1190.4
      expect(cameraRect.left, closeTo(205.2, _eps));
      expect(cameraRect.top, closeTo(576.0, _eps));
      expect(cameraRect.width, closeTo(669.6, _eps));
      expect(cameraRect.height, closeTo(1190.4, _eps));
    });

    test('offset x/y within [-2, 2] is not clamped and produces free, '
        'beyond-canvas placement for scale 0.62 anchor center', () {
      // offset x = 2.0 is within the new [-2, 2] range (no clamping):
      // targetX = 540 + 2.0*540 = 1620; left = 1620 - 0.5*669.6 = 1285.2
      // (right edge 1954.8 is far beyond the 1080-wide canvas).
      final rightRects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: 0.62,
          offset: VGDuetPoint(2.0, 0.0),
          anchor: VGDuetPoint(0.5, 0.5),
        ),
      );
      expect(rightRects[1].left, closeTo(1285.2, _eps));
      expect(rightRects[1].width, closeTo(669.6, _eps));
      expect(rightRects[1].right, greaterThan(_canvas.width));

      // offset x = -2.0: targetX = 540 - 1080 = -540;
      // left = -540 - 334.8 = -874.8 (negative — off-canvas to the left).
      final leftRects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: 0.62,
          offset: VGDuetPoint(-2.0, 0.0),
          anchor: VGDuetPoint(0.5, 0.5),
        ),
      );
      expect(leftRects[1].left, closeTo(-874.8, _eps));
      expect(leftRects[1].width, closeTo(669.6, _eps));
      expect(leftRects[1].left, lessThan(0.0));

      // offset y beyond the new range (3.0) clamps to 2.0:
      // targetY = 960 + 2.0*960 = 2880; top = 2880 - 0.5*1190.4 = 2284.8.
      final bottomRects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: 0.62,
          offset: VGDuetPoint(0.0, 3.0),
          anchor: VGDuetPoint(0.5, 0.5),
        ),
      );
      expect(bottomRects[1].top, closeTo(2284.8, _eps));
      expect(bottomRects[1].top, greaterThan(_canvas.height));

      // offset y beyond the new range (-3.0) clamps to -2.0:
      // targetY = 960 - 1920 = -960; top = -960 - 595.2 = -1555.2.
      final topRects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: 0.62,
          offset: VGDuetPoint(0.0, -3.0),
          anchor: VGDuetPoint(0.5, 0.5),
        ),
      );
      expect(topRects[1].top, closeTo(-1555.2, _eps));
      expect(topRects[1].top, lessThan(0.0));
    });

    test('scale below 0.10 clamps to 0.10 => width 108, height 192', () {
      final rects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: 0.02,
          offset: VGDuetPoint.zero,
          anchor: VGDuetPoint(0.5, 0.5),
        ),
      );
      final cameraRect = rects[1];
      expect(cameraRect.width, closeTo(108.0, _eps));
      expect(cameraRect.height, closeTo(192.0, _eps));
    });

    test('scale exactly at min 0.10 is not clamped further', () {
      final rects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: 0.10,
          offset: VGDuetPoint.zero,
          anchor: VGDuetPoint(0.5, 0.5),
        ),
      );
      final cameraRect = rects[1];
      expect(cameraRect.width, closeTo(108.0, _eps));
      expect(cameraRect.height, closeTo(192.0, _eps));
    });

    test('scale above 4.0 clamps to 4.0 => width 4320, height 7680', () {
      final rects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: 9.0,
          offset: VGDuetPoint.zero,
          anchor: VGDuetPoint(0.5, 0.5),
        ),
      );
      final cameraRect = rects[1];
      expect(cameraRect.width, closeTo(4320.0, _eps));
      expect(cameraRect.height, closeTo(7680.0, _eps));
    });

    test('scale identity short-circuit for exactly 1.0 offset zero centered '
        'anchor => full canvas', () {
      final rects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: VGDuetForegroundTransform.identity,
      );
      expect(rects[1].left, closeTo(0.0, _eps));
      expect(rects[1].top, closeTo(0.0, _eps));
      expect(rects[1].width, closeTo(_canvas.width, _eps));
      expect(rects[1].height, closeTo(_canvas.height, _eps));
    });

    test('scale > 1.0 is no longer clamped to full canvas: camera rect is '
        'larger than the canvas and extends off-canvas on all sides', () {
      // scale = 1.5, offset zero, anchor centered:
      // scaledW = 1620, scaledH = 2880; left = 540 - 810 = -270;
      // top = 960 - 1440 = -480; right = 1350; bottom = 2400.
      final rects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: 1.5,
          offset: VGDuetPoint.zero,
          anchor: VGDuetPoint(0.5, 0.5),
        ),
      );
      final cameraRect = rects[1];
      expect(cameraRect.width, closeTo(1620.0, _eps));
      expect(cameraRect.height, closeTo(2880.0, _eps));
      expect(cameraRect.left, closeTo(-270.0, _eps));
      expect(cameraRect.top, closeTo(-480.0, _eps));
      expect(cameraRect.right, greaterThan(_canvas.width));
      expect(cameraRect.bottom, greaterThan(_canvas.height));
    });

    test('rotationDegrees on the transform does not affect the axis-aligned '
        'camera rect returned by computeGreenScreenRects', () {
      const base = VGDuetForegroundTransform(
        scale: 0.62,
        offset: VGDuetPoint(0.0, 0.22),
        anchor: VGDuetPoint(0.5, 0.5),
      );
      final unrotated = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: base,
      );
      final rotated = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: 0.62,
          offset: VGDuetPoint(0.0, 0.22),
          anchor: VGDuetPoint(0.5, 0.5),
          rotationDegrees: 45.0,
        ),
      );
      expect(rotated[1].left, closeTo(unrotated[1].left, _eps));
      expect(rotated[1].top, closeTo(unrotated[1].top, _eps));
      expect(rotated[1].width, closeTo(unrotated[1].width, _eps));
      expect(rotated[1].height, closeTo(unrotated[1].height, _eps));
    });

    test('non-finite offset/anchor fallback and invalid scale identity', () {
      // Invalid scale: non-finite (infinity) degrades to identity full canvas
      final infScaleRects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: double.infinity,
          offset: VGDuetPoint.zero,
          anchor: VGDuetPoint(0.5, 0.5),
        ),
      );
      expect(infScaleRects[1].left, closeTo(0.0, _eps));
      expect(infScaleRects[1].top, closeTo(0.0, _eps));
      expect(infScaleRects[1].width, closeTo(_canvas.width, _eps));
      expect(infScaleRects[1].height, closeTo(_canvas.height, _eps));

      // Non-positive/NaN scale is covered separately via
      // VGDuetForegroundTransform.fromMap in the composition descriptor
      // tests, since the const constructor here asserts scale > 0 (which
      // NaN also fails, as NaN comparisons are always false).

      // Non-finite offset (NaN) defaults to 0.0
      // Non-finite anchor (NaN) defaults to 0.5
      // With scale 0.62, centered: left 205.2, top 364.8, width 669.6, height 1190.4
      final nanTransformRects = VGDuetLayoutMath.computeGreenScreenRects(
        canvasSize: _canvas,
        transform: const VGDuetForegroundTransform(
          scale: 0.62,
          offset: VGDuetPoint(double.nan, double.nan),
          anchor: VGDuetPoint(double.nan, double.nan),
        ),
      );
      final cameraRect = nanTransformRects[1];
      expect(cameraRect.left, closeTo(205.2, _eps));
      expect(cameraRect.top, closeTo(364.8, _eps));
      expect(cameraRect.width, closeTo(669.6, _eps));
      expect(cameraRect.height, closeTo(1190.4, _eps));
    });
  });
}
