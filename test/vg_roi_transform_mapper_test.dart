// vg_roi_transform_mapper_test.dart

import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  const double epsilon = 1e-9;

  void expectBoxCloseTo(VGROIBox? actual, VGROIBox? expected) {
    if (expected == null) {
      expect(actual, isNull);
      return;
    }
    expect(actual, isNotNull);
    expect(actual!.x, closeTo(expected.x, epsilon));
    expect(actual.y, closeTo(expected.y, epsilon));
    expect(actual.w, closeTo(expected.w, epsilon));
    expect(actual.h, closeTo(expected.h, epsilon));
  }

  group('VGROITransformMapper mapBox Tests', () {
    test('1. Identity same-aspect', () {
      final captureBox = VGROIBox(x: 0.25, y: 0.10, w: 0.50, h: 0.30);
      final result = VGROITransformMapper.mapBox(
        captureBox: captureBox,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
      );
      expectBoxCloseTo(result, VGROIBox(x: 0.25, y: 0.10, w: 0.50, h: 0.30));
    });

    test('2. Identity different-aspect / portrait source into square canvas', () {
      final captureBox = VGROIBox(x: 0.0, y: 0.0, w: 1.0, h: 1.0);
      final result = VGROITransformMapper.mapBox(
        captureBox: captureBox,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1080,
      );
      expectBoxCloseTo(result, VGROIBox(x: 0.21875, y: 0.0, w: 0.5625, h: 1.0));
    });

    test('3. Center 2x zoom same-aspect', () {
      final captureBox = VGROIBox(x: 0.25, y: 0.25, w: 0.50, h: 0.50);
      final result = VGROITransformMapper.mapBox(
        captureBox: captureBox,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        scaleX: 2.0,
        scaleY: 2.0,
      );
      expectBoxCloseTo(result, VGROIBox(x: 0.0, y: 0.0, w: 1.0, h: 1.0));
    });

    test('4. Translation only', () {
      final captureBox = VGROIBox(x: 0.25, y: 0.25, w: 0.50, h: 0.50);
      final result = VGROITransformMapper.mapBox(
        captureBox: captureBox,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        translationX: 100.0,
        translationY: 50.0,
      );
      expectBoxCloseTo(
        result,
        VGROIBox(
          x: 370 / 1080,
          y: 530 / 1920,
          w: 540 / 1080,
          h: 960 / 1920,
        ),
      );
    });

    test('5. Corrected 90-degree clockwise rotation', () {
      final captureBox = VGROIBox(x: 0.0, y: 0.0, w: 0.25, h: 0.25);
      final result = VGROITransformMapper.mapBox(
        captureBox: captureBox,
        sourceWidth: 1000,
        sourceHeight: 1000,
        canvasWidth: 1000,
        canvasHeight: 1000,
        rotation: math.pi / 2,
      );
      expectBoxCloseTo(result, VGROIBox(x: 0.75, y: 0.0, w: 0.25, h: 0.25));
    });

    test('6. 180-degree rotation', () {
      final captureBox = VGROIBox(x: 0.0, y: 0.0, w: 0.25, h: 0.25);
      final result = VGROITransformMapper.mapBox(
        captureBox: captureBox,
        sourceWidth: 1000,
        sourceHeight: 1000,
        canvasWidth: 1000,
        canvasHeight: 1000,
        rotation: math.pi,
      );
      expectBoxCloseTo(result, VGROIBox(x: 0.75, y: 0.75, w: 0.25, h: 0.25));
    });

    test('7. Fully outside canvas returns null', () {
      final captureBox = VGROIBox(x: 0.0, y: 0.0, w: 0.10, h: 0.10);
      final result = VGROITransformMapper.mapBox(
        captureBox: captureBox,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        translationX: -200.0,
        translationY: -400.0,
      );
      expect(result, isNull);
    });

    test('8. Partial clipping', () {
      final captureBox = VGROIBox(x: 0.0, y: 0.0, w: 0.50, h: 0.50);
      final result = VGROITransformMapper.mapBox(
        captureBox: captureBox,
        sourceWidth: 1000,
        sourceHeight: 1000,
        canvasWidth: 1000,
        canvasHeight: 1000,
        translationX: -300.0,
        translationY: 0.0,
      );
      expectBoxCloseTo(result, VGROIBox(x: 0.0, y: 0.0, w: 0.2, h: 0.5));
    });

    test('9. Invalid dimensions throw ArgumentError', () {
      final box = VGROIBox(x: 0.0, y: 0.0, w: 0.1, h: 0.1);
      // <= 0
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 0, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100), throwsArgumentError);
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 0, canvasWidth: 100, canvasHeight: 100), throwsArgumentError);
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: -5, canvasHeight: 100), throwsArgumentError);
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: -10), throwsArgumentError);
      // NaN
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: double.nan, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100), throwsArgumentError);
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: double.nan, canvasWidth: 100, canvasHeight: 100), throwsArgumentError);
      // Infinity
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: double.infinity, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100), throwsArgumentError);
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: double.infinity, canvasWidth: 100, canvasHeight: 100), throwsArgumentError);
    });

    test('10. Invalid transform values throw ArgumentError', () {
      final box = VGROIBox(x: 0.0, y: 0.0, w: 0.1, h: 0.1);
      // <= 0 scale
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, scaleX: 0), throwsArgumentError);
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, scaleY: -1), throwsArgumentError);
      // NaN scale
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, scaleX: double.nan), throwsArgumentError);
      // Infinite scale
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, scaleY: double.infinity), throwsArgumentError);
      // NaN rotation
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, rotation: double.nan), throwsArgumentError);
      // Infinite rotation
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, rotation: double.infinity), throwsArgumentError);
      // NaN translations
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, translationX: double.nan), throwsArgumentError);
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, translationY: double.nan), throwsArgumentError);
      // Infinite translations
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, translationX: double.infinity), throwsArgumentError);
      expect(() => VGROITransformMapper.mapBox(captureBox: box, sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, translationY: double.infinity), throwsArgumentError);
    });

    test('11. Output never violates VGROIBox validation', () {
      final captureBox = VGROIBox(x: 0.10, y: 0.10, w: 0.80, h: 0.80);
      final result = VGROITransformMapper.mapBox(
        captureBox: captureBox,
        sourceWidth: 1000,
        sourceHeight: 1000,
        canvasWidth: 1000,
        canvasHeight: 1000,
        scaleX: 1.5,
        scaleY: 1.5,
        rotation: 0.35, // Some arbitrary angle
        translationX: 100.0,
        translationY: -100.0,
      );

      if (result != null) {
        expect(result.x, greaterThanOrEqualTo(0.0));
        expect(result.y, greaterThanOrEqualTo(0.0));
        expect(result.w, greaterThan(0.0));
        expect(result.h, greaterThan(0.0));
        expect(result.x + result.w, lessThanOrEqualTo(1.0 + epsilon));
        expect(result.y + result.h, lessThanOrEqualTo(1.0 + epsilon));
      }
    });
  });
}
