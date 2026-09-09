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
}
