// vg_roi_coordinate_converter_test.dart
// UMF V2 ROI Coordinate Conversion Tests (ROI-1A)

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGROICoordinateConverter - Vision', () {
    test('Vision conversion matches expected output values', () {
      final box = VGROICoordinateConverter.fromVision(
        x: 0.25,
        y: 0.10,
        w: 0.50,
        h: 0.30,
      );

      expect(box.x, equals(0.25));
      expect(box.y, equals(0.60)); // 1.0 - (0.10 + 0.30)
      expect(box.w, equals(0.50));
      expect(box.h, equals(0.30));
    });

    test('Vision conversion rejects NaN input', () {
      expect(
        () => VGROICoordinateConverter.fromVision(x: double.nan, y: 0.1, w: 0.5, h: 0.3),
        throwsArgumentError,
      );
      expect(
        () => VGROICoordinateConverter.fromVision(x: 0.2, y: double.nan, w: 0.5, h: 0.3),
        throwsArgumentError,
      );
      expect(
        () => VGROICoordinateConverter.fromVision(x: 0.2, y: 0.1, w: double.nan, h: 0.3),
        throwsArgumentError,
      );
      expect(
        () => VGROICoordinateConverter.fromVision(x: 0.2, y: 0.1, w: 0.5, h: double.nan),
        throwsArgumentError,
      );
    });

    test('Vision conversion rejects infinite input', () {
      expect(
        () => VGROICoordinateConverter.fromVision(x: double.infinity, y: 0.1, w: 0.5, h: 0.3),
        throwsArgumentError,
      );
    });

    test('Vision conversion rejects coordinates outside [0.0, 1.0]', () {
      expect(
        () => VGROICoordinateConverter.fromVision(x: -0.01, y: 0.1, w: 0.5, h: 0.3),
        throwsArgumentError,
      );
      expect(
        () => VGROICoordinateConverter.fromVision(x: 1.05, y: 0.1, w: 0.5, h: 0.3),
        throwsArgumentError,
      );
    });

    test('Vision conversion rejects negative width or height', () {
      expect(
        () => VGROICoordinateConverter.fromVision(x: 0.2, y: 0.1, w: -0.1, h: 0.3),
        throwsArgumentError,
      );
      expect(
        () => VGROICoordinateConverter.fromVision(x: 0.2, y: 0.1, w: 0.5, h: -0.3),
        throwsArgumentError,
      );
    });

    test('Vision conversion rejects boxes overflowing normalized bounds', () {
      // x + w = 1.1 > 1.0
      expect(
        () => VGROICoordinateConverter.fromVision(x: 0.6, y: 0.1, w: 0.5, h: 0.3),
        throwsArgumentError,
      );
      // y + h = 1.05 > 1.0
      expect(
        () => VGROICoordinateConverter.fromVision(x: 0.2, y: 0.8, w: 0.5, h: 0.25),
        throwsArgumentError,
      );
    });
  });

  group('VGROICoordinateConverter - ML Kit', () {
    test('ML Kit conversion matches expected output values', () {
      final box = VGROICoordinateConverter.fromMLKit(
        left: 100,
        top: 200,
        right: 300,
        bottom: 500,
        frameWidth: 1000,
        frameHeight: 2000,
      );

      expect(box.x, equals(0.10));
      expect(box.y, equals(0.10));
      expect(box.w, equals(0.20));
      expect(box.h, equals(0.15));
    });

    test('ML Kit rejects zero or negative frame dimensions', () {
      expect(
        () => VGROICoordinateConverter.fromMLKit(
          left: 10, top: 10, right: 20, bottom: 20,
          frameWidth: 0, frameHeight: 100,
        ),
        throwsArgumentError,
      );
      expect(
        () => VGROICoordinateConverter.fromMLKit(
          left: 10, top: 10, right: 20, bottom: 20,
          frameWidth: 100, frameHeight: -10,
        ),
        throwsArgumentError,
      );
    });

    test('ML Kit rejects invalid right < left or bottom < top', () {
      expect(
        () => VGROICoordinateConverter.fromMLKit(
          left: 200, top: 100, right: 100, bottom: 200,
          frameWidth: 1000, frameHeight: 1000,
        ),
        throwsArgumentError,
      );
      expect(
        () => VGROICoordinateConverter.fromMLKit(
          left: 100, top: 200, right: 200, bottom: 100,
          frameWidth: 1000, frameHeight: 1000,
        ),
        throwsArgumentError,
      );
    });

    test('ML Kit conversion rejects NaN/infinite input', () {
      expect(
        () => VGROICoordinateConverter.fromMLKit(
          left: double.nan, top: 10, right: 20, bottom: 20,
          frameWidth: 100, frameHeight: 100,
        ),
        throwsArgumentError,
      );
      expect(
        () => VGROICoordinateConverter.fromMLKit(
          left: 10, top: 10, right: 20, bottom: 20,
          frameWidth: double.infinity, frameHeight: 100,
        ),
        throwsArgumentError,
      );
    });

    test('ML Kit conversion rejects boxes outside normalized bounds', () {
      // Converted x = 1100 / 1000 = 1.1 > 1.0
      expect(
        () => VGROICoordinateConverter.fromMLKit(
          left: 1100, top: 100, right: 1200, bottom: 200,
          frameWidth: 1000, frameHeight: 1000,
        ),
        throwsArgumentError,
      );
      // Converted x + w = 1100 / 1000 = 1.1 > 1.0
      expect(
        () => VGROICoordinateConverter.fromMLKit(
          left: 900, top: 100, right: 1100, bottom: 200,
          frameWidth: 1000, frameHeight: 1000,
        ),
        throwsArgumentError,
      );
    });
  });
}
