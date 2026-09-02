// vg_roi_keyframe_sidecar_builder_test.dart
// UMF V2 Animated / Keyframed ROI Sidecar Builder Tests (P5-ANIM-ROI-KEYFRAME-INTERP)

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGROIKeyframe', () {
    test('Valid construction and JSON roundtrip serialization', () {
      final box = VGROIBox(x: 0.1, y: 0.2, w: 0.3, h: 0.4);
      final keyframe = VGROIKeyframe(
        timestampMs: 150,
        box: box,
        interpolation: VGROIKeyframeInterpolation.easeInOut,
        quality: 'user_keyed',
        confidence: 0.95,
        paddingPolicy: 'standard',
      );

      final json = keyframe.toJson();
      expect(json['timestampMs'], equals(150));
      expect(json['interpolation'], equals('easeInOut'));
      expect(json['quality'], equals('user_keyed'));
      expect(json['confidence'], equals(0.95));
      expect(json['paddingPolicy'], equals('standard'));
      expect(json['box'], isNotNull);

      final roundtrip = VGROIKeyframe.fromJson(json);
      expect(roundtrip, equals(keyframe));
      expect(roundtrip.box, equals(box));
      expect(
        roundtrip.interpolation,
        equals(VGROIKeyframeInterpolation.easeInOut),
      );
    });

    test('Null box and optional null fields serialize correctly', () {
      final keyframe = VGROIKeyframe(
        timestampMs: 300,
        box: null,
        interpolation: VGROIKeyframeInterpolation.linear,
      );

      final json = keyframe.toJson();
      expect(json['timestampMs'], equals(300));
      expect(json['box'], isNull);
      expect(json['quality'], isNull);
      expect(json['confidence'], isNull);
      expect(json['paddingPolicy'], isNull);

      final roundtrip = VGROIKeyframe.fromJson(json);
      expect(roundtrip, equals(keyframe));
      expect(roundtrip.box, isNull);
    });

    test('Invalid keyframe constructions throw ArgumentError', () {
      // Negative timestamp
      expect(() => VGROIKeyframe(timestampMs: -1), throwsArgumentError);
      // Empty quality string
      expect(
        () => VGROIKeyframe(timestampMs: 0, quality: ''),
        throwsArgumentError,
      );
      // Invalid confidence (< 0.0 or > 1.0 or NaN)
      expect(
        () => VGROIKeyframe(timestampMs: 0, confidence: -0.1),
        throwsArgumentError,
      );
      expect(
        () => VGROIKeyframe(timestampMs: 0, confidence: 1.1),
        throwsArgumentError,
      );
      expect(
        () => VGROIKeyframe(timestampMs: 0, confidence: double.nan),
        throwsArgumentError,
      );
    });

    test('fromJson throws ArgumentError on missing timestampMs', () {
      expect(
        () => VGROIKeyframe.fromJson(<String, dynamic>{'quality': 'stable'}),
        throwsArgumentError,
      );
    });

    test('fromJson throws ArgumentError on unsupported interpolation', () {
      expect(
        () => VGROIKeyframe.fromJson(<String, dynamic>{
          'timestampMs': 100,
          'interpolation': 'unsupported_curve',
        }),
        throwsArgumentError,
      );
    });

    test('fromJson defaults omitted or null interpolation to linear', () {
      final kfOmitted = VGROIKeyframe.fromJson(<String, dynamic>{
        'timestampMs': 100,
      });
      expect(
        kfOmitted.interpolation,
        equals(VGROIKeyframeInterpolation.linear),
      );

      final kfNull = VGROIKeyframe.fromJson(<String, dynamic>{
        'timestampMs': 200,
        'interpolation': null,
      });
      expect(kfNull.interpolation, equals(VGROIKeyframeInterpolation.linear));
    });
  });

  group('VGROIKeyframeSidecarBuilder', () {
    test('Linear interpolation between two boxes at midpoint', () {
      final startBox = VGROIBox(x: 0.1, y: 0.2, w: 0.3, h: 0.4);
      final endBox = VGROIBox(x: 0.3, y: 0.6, w: 0.5, h: 0.2);

      final keyframes = [
        VGROIKeyframe(
          timestampMs: 0,
          box: startBox,
          interpolation: VGROIKeyframeInterpolation.linear,
        ),
        VGROIKeyframe(
          timestampMs: 1000,
          box: endBox,
          interpolation: VGROIKeyframeInterpolation.linear,
        ),
      ];

      final sidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 1000,
        outputWidth: 1080,
        outputHeight: 1920,
        sampleIntervalMs: 500,
        keyframes: keyframes,
      );

      expect(sidecar.coordinateSpace, equals('export_output_normalized'));
      expect(sidecar.finalized, isTrue);
      expect(sidecar.videoIdentity.durationMs, equals(1000));
      expect(sidecar.videoIdentity.width, equals(1080));
      expect(sidecar.videoIdentity.height, equals(1920));
      expect(sidecar.videoIdentity.hash, isNull);

      // Generated samples at t = 0, 500, 1000
      expect(sidecar.samples.length, equals(3));

      // t = 0 (Start endpoint)
      final sample0 = sidecar.samples[0];
      expect(sample0.timestampMs, equals(0));
      expect(sample0.box, isNotNull);
      expect(sample0.box!.x, closeTo(0.1, 1e-6));
      expect(sample0.box!.y, closeTo(0.2, 1e-6));
      expect(sample0.box!.w, closeTo(0.3, 1e-6));
      expect(sample0.box!.h, closeTo(0.4, 1e-6));

      // t = 500 (Midpoint)
      final sample500 = sidecar.samples[1];
      expect(sample500.timestampMs, equals(500));
      expect(sample500.box, isNotNull);
      expect(sample500.box!.x, closeTo(0.2, 1e-6));
      expect(sample500.box!.y, closeTo(0.4, 1e-6));
      expect(sample500.box!.w, closeTo(0.4, 1e-6));
      expect(sample500.box!.h, closeTo(0.3, 1e-6));

      // t = 1000 (End endpoint)
      final sample1000 = sidecar.samples[2];
      expect(sample1000.timestampMs, equals(1000));
      expect(sample1000.box, isNotNull);
      expect(sample1000.box!.x, closeTo(0.3, 1e-6));
      expect(sample1000.box!.y, closeTo(0.6, 1e-6));
      expect(sample1000.box!.w, closeTo(0.5, 1e-6));
      expect(sample1000.box!.h, closeTo(0.2, 1e-6));

      expect(sidecar.coverage.coveragePercent, equals(1.0));
    });

    test(
      'easeInOut differs from linear at a non-midpoint and preserves endpoints',
      () {
        final startBox = VGROIBox(x: 0.0, y: 0.0, w: 0.2, h: 0.2);
        final endBox = VGROIBox(x: 0.8, y: 0.8, w: 0.2, h: 0.2);

        // Build easeInOut sidecar
        final easeInOutSidecar = VGROIKeyframeSidecarBuilder.build(
          durationMs: 1000,
          outputWidth: 1080,
          outputHeight: 1920,
          sampleIntervalMs: 250,
          keyframes: [
            VGROIKeyframe(
              timestampMs: 0,
              box: startBox,
              interpolation: VGROIKeyframeInterpolation.easeInOut,
            ),
            VGROIKeyframe(
              timestampMs: 1000,
              box: endBox,
              interpolation: VGROIKeyframeInterpolation.linear,
            ),
          ],
        );

        // Build linear sidecar
        final linearSidecar = VGROIKeyframeSidecarBuilder.build(
          durationMs: 1000,
          outputWidth: 1080,
          outputHeight: 1920,
          sampleIntervalMs: 250,
          keyframes: [
            VGROIKeyframe(
              timestampMs: 0,
              box: startBox,
              interpolation: VGROIKeyframeInterpolation.linear,
            ),
            VGROIKeyframe(
              timestampMs: 1000,
              box: endBox,
              interpolation: VGROIKeyframeInterpolation.linear,
            ),
          ],
        );

        expect(
          easeInOutSidecar.samples.length,
          equals(5),
        ); // 0, 250, 500, 750, 1000
        expect(linearSidecar.samples.length, equals(5));

        // Endpoints match exactly
        expect(easeInOutSidecar.samples[0].box, equals(startBox));
        expect(linearSidecar.samples[0].box, equals(startBox));
        expect(easeInOutSidecar.samples[4].box, equals(endBox));
        expect(linearSidecar.samples[4].box, equals(endBox));

        // Midpoint at t = 500ms (u = 0.5): easeInOut and linear are equal (0.5)
        expect(easeInOutSidecar.samples[2].box!.x, closeTo(0.4, 1e-6));
        expect(linearSidecar.samples[2].box!.x, closeTo(0.4, 1e-6));

        // Non-midpoint at t = 250ms (u = 0.25):
        // Linear factor = 0.25 -> x = 0.2
        // easeInOut factor = 3*(0.25^2) - 2*(0.25^3) = 0.15625 -> x = 0.8 * 0.15625 = 0.125
        final ease250 = easeInOutSidecar.samples[1].box!;
        final lin250 = linearSidecar.samples[1].box!;
        expect(lin250.x, closeTo(0.2, 1e-6));
        expect(ease250.x, closeTo(0.125, 1e-6));
        expect(ease250.x, isNot(equals(lin250.x)));

        // Non-midpoint at t = 750ms (u = 0.75):
        // Linear factor = 0.75 -> x = 0.6
        // easeInOut factor = 3*(0.75^2) - 2*(0.75^3) = 0.84375 -> x = 0.8 * 0.84375 = 0.675
        final ease750 = easeInOutSidecar.samples[3].box!;
        final lin750 = linearSidecar.samples[3].box!;
        expect(lin750.x, closeTo(0.6, 1e-6));
        expect(ease750.x, closeTo(0.675, 1e-6));
        expect(ease750.x, isNot(equals(lin750.x)));
      },
    );

    test('smoothstep interpolation behaves identically to easeInOut', () {
      final startBox = VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2);
      final endBox = VGROIBox(x: 0.7, y: 0.7, w: 0.2, h: 0.2);

      final smoothstepSidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 1000,
        outputWidth: 720,
        outputHeight: 1280,
        sampleIntervalMs: 100,
        keyframes: [
          VGROIKeyframe(
            timestampMs: 0,
            box: startBox,
            interpolation: VGROIKeyframeInterpolation.smoothstep,
          ),
          VGROIKeyframe(timestampMs: 1000, box: endBox),
        ],
      );

      final easeInOutSidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 1000,
        outputWidth: 720,
        outputHeight: 1280,
        sampleIntervalMs: 100,
        keyframes: [
          VGROIKeyframe(
            timestampMs: 0,
            box: startBox,
            interpolation: VGROIKeyframeInterpolation.easeInOut,
          ),
          VGROIKeyframe(timestampMs: 1000, box: endBox),
        ],
      );

      expect(
        smoothstepSidecar.samples.length,
        equals(easeInOutSidecar.samples.length),
      );
      for (int i = 0; i < smoothstepSidecar.samples.length; i++) {
        expect(
          smoothstepSidecar.samples[i].box,
          equals(easeInOutSidecar.samples[i].box),
        );
      }
    });

    test(
      'exact keyframe timestamp included even off sample grid without duplicates',
      () {
        final box0 = VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2);
        final box137 = VGROIBox(x: 0.2, y: 0.3, w: 0.25, h: 0.25);
        final box1000 = VGROIBox(x: 0.5, y: 0.5, w: 0.3, h: 0.3);

        final sidecar = VGROIKeyframeSidecarBuilder.build(
          durationMs: 1000,
          outputWidth: 1080,
          outputHeight: 1920,
          sampleIntervalMs: 100,
          keyframes: [
            VGROIKeyframe(timestampMs: 0, box: box0),
            VGROIKeyframe(
              timestampMs: 137,
              box: box137,
              quality: 'off_grid_exact',
              confidence: 0.99,
            ),
            VGROIKeyframe(timestampMs: 1000, box: box1000),
          ],
        );

        final timestamps = sidecar.samples.map((s) => s.timestampMs).toList();
        // Grid points 0, 100, 200, ..., 1000 + off-grid point 137
        expect(timestamps.contains(137), isTrue);

        // Verify strictly ascending and no duplicates
        for (int i = 1; i < timestamps.length; i++) {
          expect(timestamps[i], greaterThan(timestamps[i - 1]));
        }

        final exactSample = sidecar.samples.firstWhere(
          (s) => s.timestampMs == 137,
        );
        expect(exactSample.box, equals(box137));
        expect(exactSample.quality, equals('off_grid_exact'));
        expect(exactSample.confidence, equals(0.99));
      },
    );

    test('null-box segment emits no invented boxes', () {
      final boxA = VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2);
      final boxC = VGROIBox(x: 0.6, y: 0.6, w: 0.3, h: 0.3);

      final sidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 1000,
        outputWidth: 1080,
        outputHeight: 1920,
        sampleIntervalMs: 100,
        keyframes: [
          VGROIKeyframe(timestampMs: 0, box: boxA),
          VGROIKeyframe(timestampMs: 400, box: null), // ROI lost
          VGROIKeyframe(timestampMs: 800, box: boxC), // ROI recovered
        ],
      );

      // t = 0: has boxA
      expect(
        sidecar.samples.firstWhere((s) => s.timestampMs == 0).box,
        equals(boxA),
      );

      // Intermediate samples in (0, 400) have null box because endpoint at 400 is null
      for (final t in [100, 200, 300]) {
        final sample = sidecar.samples.firstWhere((s) => s.timestampMs == t);
        expect(sample.box, isNull, reason: 'Sample at $t ms should be null');
        expect(sample.quality, equals('missing'));
      }

      // t = 400: exact null keyframe
      expect(
        sidecar.samples.firstWhere((s) => s.timestampMs == 400).box,
        isNull,
      );

      // Intermediate samples in (400, 800) have null box because startpoint at 400 is null
      for (final t in [500, 600, 700]) {
        final sample = sidecar.samples.firstWhere((s) => s.timestampMs == t);
        expect(sample.box, isNull, reason: 'Sample at $t ms should be null');
      }

      // t = 800: exact boxC keyframe
      expect(
        sidecar.samples.firstWhere((s) => s.timestampMs == 800).box,
        equals(boxC),
      );

      // t > 800 (900, 1000): outside last keyframe, no invented box -> null
      for (final t in [900, 1000]) {
        final sample = sidecar.samples.firstWhere((s) => s.timestampMs == t);
        expect(sample.box, isNull, reason: 'Sample at $t ms should be null');
      }

      // Coverage should reflect non-null samples (t=0 and t=800 -> 2 non-null out of 11)
      expect(sidecar.coverage.coveragePercent, closeTo(2.0 / 11.0, 1e-6));
    });

    test('all-null keyframes returns valid finalized empty export sidecar', () {
      final sidecar = VGROIKeyframeSidecarBuilder.build(
        durationMs: 5000,
        outputWidth: 1080,
        outputHeight: 1920,
        sampleIntervalMs: 100,
        keyframes: [
          VGROIKeyframe(timestampMs: 0, box: null),
          VGROIKeyframe(timestampMs: 2500, box: null),
          VGROIKeyframe(timestampMs: 5000, box: null),
        ],
      );

      expect(sidecar.coordinateSpace, equals('export_output_normalized'));
      expect(sidecar.finalized, isTrue);
      expect(sidecar.samples, isEmpty);
      expect(sidecar.coverage.coveragePercent, equals(0.0));
      expect(sidecar.videoIdentity.durationMs, equals(5000));
      expect(sidecar.videoIdentity.width, equals(1080));
      expect(sidecar.videoIdentity.height, equals(1920));
      expect(sidecar.videoIdentity.hash, isNull);
    });

    test(
      'empty keyframes list returns valid finalized empty export sidecar',
      () {
        final sidecar = VGROIKeyframeSidecarBuilder.build(
          durationMs: 3000,
          outputWidth: 720,
          outputHeight: 1280,
          keyframes: const [],
        );

        expect(sidecar.coordinateSpace, equals('export_output_normalized'));
        expect(sidecar.finalized, isTrue);
        expect(sidecar.samples, isEmpty);
        expect(sidecar.coverage.coveragePercent, equals(0.0));
        expect(sidecar.videoIdentity.durationMs, equals(3000));
        expect(sidecar.videoIdentity.width, equals(720));
        expect(sidecar.videoIdentity.height, equals(1280));
      },
    );

    test('duplicate timestamp and invalid parameters throw ArgumentError', () {
      final validBox = VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2);

      // Duplicate timestamps
      expect(
        () => VGROIKeyframeSidecarBuilder.build(
          durationMs: 1000,
          outputWidth: 1080,
          outputHeight: 1920,
          keyframes: [
            VGROIKeyframe(timestampMs: 200, box: validBox),
            VGROIKeyframe(timestampMs: 200, box: validBox),
          ],
        ),
        throwsArgumentError,
      );

      // Non-positive durationMs
      expect(
        () => VGROIKeyframeSidecarBuilder.build(
          durationMs: 0,
          outputWidth: 1080,
          outputHeight: 1920,
          keyframes: [VGROIKeyframe(timestampMs: 0, box: validBox)],
        ),
        throwsArgumentError,
      );
      expect(
        () => VGROIKeyframeSidecarBuilder.build(
          durationMs: -100,
          outputWidth: 1080,
          outputHeight: 1920,
          keyframes: [VGROIKeyframe(timestampMs: 0, box: validBox)],
        ),
        throwsArgumentError,
      );

      // Non-positive dimensions
      expect(
        () => VGROIKeyframeSidecarBuilder.build(
          durationMs: 1000,
          outputWidth: 0,
          outputHeight: 1920,
          keyframes: [VGROIKeyframe(timestampMs: 0, box: validBox)],
        ),
        throwsArgumentError,
      );
      expect(
        () => VGROIKeyframeSidecarBuilder.build(
          durationMs: 1000,
          outputWidth: 1080,
          outputHeight: -1,
          keyframes: [VGROIKeyframe(timestampMs: 0, box: validBox)],
        ),
        throwsArgumentError,
      );

      // Non-positive sampleIntervalMs
      expect(
        () => VGROIKeyframeSidecarBuilder.build(
          durationMs: 1000,
          outputWidth: 1080,
          outputHeight: 1920,
          sampleIntervalMs: 0,
          keyframes: [VGROIKeyframe(timestampMs: 0, box: validBox)],
        ),
        throwsArgumentError,
      );

      // Keyframe timestamp exceeds durationMs
      expect(
        () => VGROIKeyframeSidecarBuilder.build(
          durationMs: 1000,
          outputWidth: 1080,
          outputHeight: 1920,
          keyframes: [VGROIKeyframe(timestampMs: 1500, box: validBox)],
        ),
        throwsArgumentError,
      );
    });

    test(
      'JSON roundtrip and public export through vanguard_media_engine.dart',
      () {
        final sidecar = VGROIKeyframeSidecarBuilder.build(
          durationMs: 1000,
          outputWidth: 1080,
          outputHeight: 1920,
          sampleIntervalMs: 250,
          keyframes: [
            VGROIKeyframe(
              timestampMs: 0,
              box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
              interpolation: VGROIKeyframeInterpolation.linear,
              quality: 'user_keyed',
              confidence: 0.9,
            ),
            VGROIKeyframe(
              timestampMs: 1000,
              box: VGROIBox(x: 0.5, y: 0.5, w: 0.3, h: 0.3),
              interpolation: VGROIKeyframeInterpolation.linear,
              quality: 'user_keyed',
              confidence: 0.95,
            ),
          ],
        );

        final json = sidecar.toJson();
        expect(json['coordinateSpace'], equals('export_output_normalized'));
        expect(json['finalized'], isTrue);
        expect(json['samples'], isList);

        final roundtrip = VGROISidecar.fromJson(json);
        expect(roundtrip, equals(sidecar));
        expect(roundtrip.samples.length, equals(sidecar.samples.length));
        for (int i = 0; i < roundtrip.samples.length; i++) {
          expect(roundtrip.samples[i], equals(sidecar.samples[i]));
        }
      },
    );
  });
}
