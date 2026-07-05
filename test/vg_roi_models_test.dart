// vg_roi_models_test.dart
// UMF V2 ROI Models Unit Tests (ROI-1A)

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGROIBox', () {
    test('JSON serialization uses x, y, w, h keys', () {
      final box = VGROIBox(x: 0.1, y: 0.2, w: 0.3, h: 0.4);
      final json = box.toJson();

      expect(json.containsKey('x'), isTrue);
      expect(json.containsKey('y'), isTrue);
      expect(json.containsKey('w'), isTrue);
      expect(json.containsKey('h'), isTrue);
      expect(json.containsKey('width'), isFalse);
      expect(json.containsKey('height'), isFalse);

      expect(json['x'], equals(0.1));
      expect(json['y'], equals(0.2));
      expect(json['w'], equals(0.3));
      expect(json['h'], equals(0.4));
    });

    test('Invalid box constructions throw ArgumentError', () {
      // NaN x
      expect(() => VGROIBox(x: double.nan, y: 0.1, w: 0.2, h: 0.2), throwsArgumentError);
      // Negative x
      expect(() => VGROIBox(x: -0.01, y: 0.1, w: 0.2, h: 0.2), throwsArgumentError);
      // Overflow x + w > 1.0
      expect(() => VGROIBox(x: 0.9, y: 0.1, w: 0.15, h: 0.2), throwsArgumentError);
      // Negative w
      expect(() => VGROIBox(x: 0.1, y: 0.1, w: -0.05, h: 0.2), throwsArgumentError);
    });
  });

  group('VGROISample', () {
    test('Valid construction and roundtrip serialization', () {
      final box = VGROIBox(x: 0.2, y: 0.3, w: 0.4, h: 0.5);
      final sample = VGROISample(
        timestampMs: 100,
        framePtsMs: 120,
        recordingRelativeMs: 100,
        box: box,
        quality: 'stable',
        confidence: 0.95,
        paddingPolicy: 'normal',
      );

      final json = sample.toJson();
      final roundtrip = VGROISample.fromJson(json);

      expect(roundtrip, equals(sample));
      expect(roundtrip.box, equals(box));
    });

    test('Null box and nullable fields serialize correctly', () {
      final sample = VGROISample(
        timestampMs: 200,
        framePtsMs: 220,
        recordingRelativeMs: 200,
        box: null,
        quality: 'rejected_jump',
        confidence: null,
        paddingPolicy: null,
      );

      final json = sample.toJson();
      expect(json['box'], isNull);
      expect(json['confidence'], isNull);
      expect(json['paddingPolicy'], isNull);

      final roundtrip = VGROISample.fromJson(json);
      expect(roundtrip, equals(sample));
    });

    test('Invalid sample constructions throw ArgumentError', () {
      // Negative timestampMs
      expect(
        () => VGROISample(timestampMs: -1, framePtsMs: 10, recordingRelativeMs: 10, quality: 'stable'),
        throwsArgumentError,
      );
      // Empty quality
      expect(
        () => VGROISample(timestampMs: 0, framePtsMs: 10, recordingRelativeMs: 10, quality: ''),
        throwsArgumentError,
      );
      // Invalid confidence > 1.0
      expect(
        () => VGROISample(timestampMs: 0, framePtsMs: 10, recordingRelativeMs: 10, quality: 'stable', confidence: 1.1),
        throwsArgumentError,
      );
    });
  });

  group('VGROIMissingInterval', () {
    test('Valid construction and serialization', () {
      final interval = VGROIMissingInterval(
        startMs: 100,
        endMs: 300,
        reason: 'thermal_pause',
        postProcessRequired: true,
      );

      final json = interval.toJson();
      final roundtrip = VGROIMissingInterval.fromJson(json);

      expect(roundtrip, equals(interval));
    });

    test('Invalid constructions throw ArgumentError', () {
      // endMs < startMs
      expect(
        () => VGROIMissingInterval(startMs: 200, endMs: 100, reason: 'test', postProcessRequired: false),
        throwsArgumentError,
      );
      // Empty reason
      expect(
        () => VGROIMissingInterval(startMs: 100, endMs: 200, reason: '', postProcessRequired: false),
        throwsArgumentError,
      );
      // Negative startMs
      expect(
        () => VGROIMissingInterval(startMs: -50, endMs: 200, reason: 'test', postProcessRequired: false),
        throwsArgumentError,
      );
    });
  });

  group('VGROICoverage', () {
    test('Valid construction and roundtrip', () {
      final interval = VGROIMissingInterval(
        startMs: 10,
        endMs: 50,
        reason: 'cold_start',
        postProcessRequired: true,
      );
      final coverage = VGROICoverage(
        coveragePercent: 0.85,
        missingIntervals: [interval],
      );

      final json = coverage.toJson();
      final roundtrip = VGROICoverage.fromJson(json);

      expect(roundtrip, equals(coverage));
    });

    test('Invalid coverage constructions throw ArgumentError', () {
      // coveragePercent > 1.0
      expect(() => VGROICoverage(coveragePercent: 1.01), throwsArgumentError);
      // coveragePercent < 0.0
      expect(() => VGROICoverage(coveragePercent: -0.1), throwsArgumentError);
      // NaN coveragePercent
      expect(() => VGROICoverage(coveragePercent: double.nan), throwsArgumentError);
    });
  });

  group('VGROIIdentity', () {
    test('Valid construction and roundtrip', () {
      final identity = VGROIIdentity(
        durationMs: 30000,
        width: 1080,
        height: 1920,
        hash: 'sha256-hash',
      );

      final json = identity.toJson();
      final roundtrip = VGROIIdentity.fromJson(json);

      expect(roundtrip, equals(identity));
    });

    test('Invalid constructions throw ArgumentError', () {
      // durationMs < 0
      expect(() => VGROIIdentity(durationMs: -1, width: 100, height: 100), throwsArgumentError);
      // width <= 0
      expect(() => VGROIIdentity(durationMs: 100, width: 0, height: 100), throwsArgumentError);
      // height <= 0
      expect(() => VGROIIdentity(durationMs: 100, width: 100, height: -5), throwsArgumentError);
    });
  });

  group('VGROISidecar', () {
    test('VGROISidecar full complex roundtrip serialization', () {
      final box = VGROIBox(x: 0.28, y: 0.14, w: 0.42, h: 0.36);
      final sample1 = VGROISample(
        timestampMs: 1033,
        framePtsMs: 1033,
        recordingRelativeMs: 1033,
        box: box,
        quality: 'stable',
        confidence: 0.92,
        paddingPolicy: 'normal',
      );
      final sample2 = VGROISample(
        timestampMs: 2000,
        framePtsMs: 2000,
        recordingRelativeMs: 2000,
        box: null,
        quality: 'rejected_jump',
        confidence: null,
        paddingPolicy: null,
      );

      final interval = VGROIMissingInterval(
        startMs: 0,
        endMs: 600,
        reason: 'cold_start',
        postProcessRequired: true,
      );

      final coverage = VGROICoverage(
        coveragePercent: 0.92,
        missingIntervals: [interval],
      );

      final identity = VGROIIdentity(
        durationMs: 30440,
        width: 1080,
        height: 1920,
        hash: 'sha256-dummy',
      );

      final sidecar = VGROISidecar(
        version: 1,
        sourceType: 'app_recorded',
        platform: 'ios',
        coordinateSpace: 'export_output_normalized',
        recordingSessionId: '550e8400-e29b-41d4-a716-446655440000',
        videoIdentity: identity,
        coverage: coverage,
        samples: [sample1, sample2],
        finalized: true,
      );

      final json = sidecar.toJson();
      final roundtrip = VGROISidecar.fromJson(json);

      expect(roundtrip, equals(sidecar));
      expect(roundtrip.samples.length, equals(2));
      expect(roundtrip.samples[0].box, equals(box));
      expect(roundtrip.samples[1].box, isNull);
      expect(roundtrip.coverage.missingIntervals[0], equals(interval));
    });

    test('Omitted / empty arrays roundtrip correctly', () {
      final identity = VGROIIdentity(durationMs: 100, width: 10, height: 10);
      final coverage = VGROICoverage(coveragePercent: 1.0, missingIntervals: const []);
      final sidecar = VGROISidecar(
        version: 1,
        sourceType: 'gallery_import',
        platform: 'android',
        coordinateSpace: 'portrait_capture_normalized',
        recordingSessionId: 'uuid',
        videoIdentity: identity,
        coverage: coverage,
        samples: const [],
        finalized: false,
      );

      final json = sidecar.toJson();
      final roundtrip = VGROISidecar.fromJson(json);

      expect(roundtrip, equals(sidecar));
      expect(roundtrip.samples, isEmpty);
      expect(roundtrip.coverage.missingIntervals, isEmpty);
    });

    test('Invalid sidecar constructions throw ArgumentError', () {
      final identity = VGROIIdentity(durationMs: 100, width: 10, height: 10);
      final coverage = VGROICoverage(coveragePercent: 1.0);

      // version <= 0
      expect(
        () => VGROISidecar(
          version: 0,
          sourceType: 'a',
          platform: 'b',
          coordinateSpace: 'c',
          recordingSessionId: 'd',
          videoIdentity: identity,
          coverage: coverage,
          finalized: true,
        ),
        throwsArgumentError,
      );

      // Empty sourceType
      expect(
        () => VGROISidecar(
          version: 1,
          sourceType: '',
          platform: 'b',
          coordinateSpace: 'c',
          recordingSessionId: 'd',
          videoIdentity: identity,
          coverage: coverage,
          finalized: true,
        ),
        throwsArgumentError,
      );

      // Empty coordinateSpace
      expect(
        () => VGROISidecar(
          version: 1,
          sourceType: 'a',
          platform: 'b',
          coordinateSpace: '',
          recordingSessionId: 'd',
          videoIdentity: identity,
          coverage: coverage,
          finalized: true,
        ),
        throwsArgumentError,
      );
    });
  });
}
