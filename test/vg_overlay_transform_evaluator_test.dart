// vg_overlay_transform_evaluator_test.dart
// Vanguard Media Engine - Phase 5 (P5-OVERLAYS-KEYFRAME-INTERP)
//
// Pure Dart unit tests for VGOverlayTransformEvaluator.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGOverlayTransformEvaluator - Linear Interpolation', () {
    test(
      'interpolates translation, size, rotation, scale, and opacity linearly',
      () {
        final overlay = VGOverlayDescriptor(
          id: 'ov_lin',
          startTimeSeconds: 1.0,
          durationSeconds: 4.0,
        );

        final kf0 = VGOverlayKeyframe(
          timeSeconds: 0.0,
          translationX: 0.0,
          translationY: 100.0,
          width: 100.0,
          height: 50.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 0.2,
          interpolation: VGOverlayInterpolation.linear,
        );

        final kf1 = VGOverlayKeyframe(
          timeSeconds: 2.0,
          translationX: 200.0,
          translationY: 300.0,
          width: 300.0,
          height: 150.0,
          rotation: 1.57,
          scale: 2.0,
          opacity: 1.0,
          interpolation: VGOverlayInterpolation.linear,
        );

        // pts = 2.0 -> localTime = 1.0 -> progress = 1.0 / 2.0 = 0.5 (midpoint)
        final evalMid = VGOverlayTransformEvaluator.evaluateOverlay(
          overlay: overlay,
          ptsSeconds: 2.0,
          keyframes: [kf0, kf1],
        );

        expect(evalMid, isNotNull);
        expect(evalMid!.translationX, closeTo(100.0, 1e-6));
        expect(evalMid.translationY, closeTo(200.0, 1e-6));
        expect(evalMid.width, closeTo(200.0, 1e-6));
        expect(evalMid.height, closeTo(100.0, 1e-6));
        expect(evalMid.rotation, closeTo(0.785, 1e-6));
        expect(evalMid.scale, closeTo(1.5, 1e-6));
        expect(evalMid.opacity, closeTo(0.6, 1e-6));

        // pts = 1.5 -> localTime = 0.5 -> progress = 0.5 / 2.0 = 0.25 (quarter)
        final evalQ = VGOverlayTransformEvaluator.evaluateOverlay(
          overlay: overlay,
          ptsSeconds: 1.5,
          keyframes: [kf0, kf1],
        );

        expect(evalQ, isNotNull);
        expect(evalQ!.translationX, closeTo(50.0, 1e-6));
        expect(evalQ.translationY, closeTo(150.0, 1e-6));
        expect(evalQ.width, closeTo(150.0, 1e-6));
        expect(evalQ.height, closeTo(75.0, 1e-6));
        expect(evalQ.scale, closeTo(1.25, 1e-6));
        expect(evalQ.opacity, closeTo(0.4, 1e-6));
      },
    );
  });

  group('VGOverlayTransformEvaluator - easeInOut and smoothstep', () {
    test('easeInOut evaluates cubic smoothstep curve f(t) = 3t^2 - 2t^3', () {
      final overlay = VGOverlayDescriptor(
        id: 'ov_ease',
        startTimeSeconds: 0.0,
        durationSeconds: 10.0,
      );

      final kf0 = VGOverlayKeyframe(
        timeSeconds: 0.0,
        translationX: 0.0,
        interpolation: VGOverlayInterpolation.easeInOut,
      );
      final kf1 = VGOverlayKeyframe(timeSeconds: 4.0, translationX: 100.0);

      // t = 1.0 -> progress = 0.25
      // cubic smoothstep: 0.25 * 0.25 * (3 - 2 * 0.25) = 0.0625 * 2.5 = 0.15625
      final eval25 = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 1.0,
        keyframes: [kf0, kf1],
      );
      expect(eval25!.translationX, closeTo(15.625, 1e-6));

      // t = 2.0 -> progress = 0.5
      // cubic smoothstep at midpoint is exactly 0.5
      final eval50 = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 2.0,
        keyframes: [kf0, kf1],
      );
      expect(eval50!.translationX, closeTo(50.0, 1e-6));

      // t = 3.0 -> progress = 0.75
      // cubic smoothstep: 0.75 * 0.75 * (3 - 2 * 0.75) = 0.5625 * 1.5 = 0.84375
      final eval75 = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 3.0,
        keyframes: [kf0, kf1],
      );
      expect(eval75!.translationX, closeTo(84.375, 1e-6));
    });

    test('smoothstep enum alias behaves identically to easeInOut', () {
      final overlay = VGOverlayDescriptor(
        id: 'ov_smooth',
        startTimeSeconds: 0.0,
        durationSeconds: 2.0,
      );

      final kf0 = VGOverlayKeyframe(
        timeSeconds: 0.0,
        scale: 1.0,
        interpolation: VGOverlayInterpolation.smoothstep,
      );
      final kf1 = VGOverlayKeyframe(timeSeconds: 2.0, scale: 3.0);

      // t = 0.5 -> progress = 0.25 -> p = 0.15625
      // scale = 1.0 + (3.0 - 1.0) * 0.15625 = 1.0 + 0.3125 = 1.3125
      final eval = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 0.5,
        keyframes: [kf0, kf1],
      );
      expect(eval!.scale, closeTo(1.3125, 1e-6));
    });
  });

  group('VGOverlayTransformEvaluator - Hold Mode', () {
    test(
      'hold mode keeps start keyframe values until next keyframe is reached',
      () {
        final overlay = VGOverlayDescriptor(
          id: 'ov_hold',
          startTimeSeconds: 0.0,
          durationSeconds: 5.0,
        );

        final kf0 = VGOverlayKeyframe(
          timeSeconds: 1.0,
          translationX: 10.0,
          opacity: 0.2,
          interpolation: VGOverlayInterpolation.hold,
        );
        final kf1 = VGOverlayKeyframe(
          timeSeconds: 3.0,
          translationX: 50.0,
          opacity: 0.9,
        );

        // Before kf0 (t=0.5): clamped to kf0
        final eval05 = VGOverlayTransformEvaluator.evaluateOverlay(
          overlay: overlay,
          ptsSeconds: 0.5,
          keyframes: [kf0, kf1],
        );
        expect(eval05!.translationX, 10.0);
        expect(eval05.opacity, 0.2);

        // Between kf0 and kf1 (t=2.0): holds kf0
        final eval20 = VGOverlayTransformEvaluator.evaluateOverlay(
          overlay: overlay,
          ptsSeconds: 2.0,
          keyframes: [kf0, kf1],
        );
        expect(eval20!.translationX, 10.0);
        expect(eval20.opacity, 0.2);

        // Just before kf1 (t=2.99): holds kf0
        final eval299 = VGOverlayTransformEvaluator.evaluateOverlay(
          overlay: overlay,
          ptsSeconds: 2.99,
          keyframes: [kf0, kf1],
        );
        expect(eval299!.translationX, 10.0);

        // Exactly at kf1 (t=3.0): switches to kf1
        final eval30 = VGOverlayTransformEvaluator.evaluateOverlay(
          overlay: overlay,
          ptsSeconds: 3.0,
          keyframes: [kf0, kf1],
        );
        expect(eval30!.translationX, 50.0);
        expect(eval30.opacity, 0.9);
      },
    );
  });

  group('VGOverlayTransformEvaluator - Exact Keyframes and Clamping', () {
    test('exact keyframe timestamps return exact keyframe values', () {
      final overlay = VGOverlayDescriptor(
        id: 'ov_exact',
        startTimeSeconds: 2.0,
        durationSeconds: 6.0,
      );

      final kf0 = VGOverlayKeyframe(
        timeSeconds: 1.0,
        translationX: 100.0,
        rotation: 0.5,
      );
      final kf1 = VGOverlayKeyframe(
        timeSeconds: 3.0,
        translationX: 300.0,
        rotation: 1.5,
      );

      // pts = 3.0 -> localTime = 1.0 (kf0)
      final evalKf0 = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 3.0,
        keyframes: [kf0, kf1],
      );
      expect(evalKf0!.translationX, 100.0);
      expect(evalKf0.rotation, 0.5);

      // pts = 5.0 -> localTime = 3.0 (kf1)
      final evalKf1 = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 5.0,
        keyframes: [kf0, kf1],
      );
      expect(evalKf1!.translationX, 300.0);
      expect(evalKf1.rotation, 1.5);
    });

    test('clamps to first keyframe before first keyframe time', () {
      final overlay = VGOverlayDescriptor(
        id: 'ov_clamp_pre',
        startTimeSeconds: 0.0,
        durationSeconds: 5.0,
      );

      final kf0 = VGOverlayKeyframe(timeSeconds: 2.0, translationX: 50.0);
      final kf1 = VGOverlayKeyframe(timeSeconds: 4.0, translationX: 150.0);

      final eval = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 1.0,
        keyframes: [kf0, kf1],
      );
      expect(eval!.translationX, 50.0);
    });

    test('clamps to last keyframe after last keyframe time', () {
      final overlay = VGOverlayDescriptor(
        id: 'ov_clamp_post',
        startTimeSeconds: 0.0,
        durationSeconds: 5.0,
      );

      final kf0 = VGOverlayKeyframe(timeSeconds: 1.0, translationX: 50.0);
      final kf1 = VGOverlayKeyframe(timeSeconds: 3.0, translationX: 150.0);

      final eval = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 4.5,
        keyframes: [kf0, kf1],
      );
      expect(eval!.translationX, 150.0);
    });

    test(
      'single keyframe provides constant transform across active interval',
      () {
        final overlay = VGOverlayDescriptor(
          id: 'ov_single',
          startTimeSeconds: 1.0,
          durationSeconds: 3.0,
        );

        final kf = VGOverlayKeyframe(
          timeSeconds: 1.5,
          translationX: 77.0,
          scale: 2.5,
        );

        final eval1 = VGOverlayTransformEvaluator.evaluateOverlay(
          overlay: overlay,
          ptsSeconds: 1.2,
          keyframes: [kf],
        );
        final eval2 = VGOverlayTransformEvaluator.evaluateOverlay(
          overlay: overlay,
          ptsSeconds: 3.8,
          keyframes: [kf],
        );

        expect(eval1!.translationX, 77.0);
        expect(eval1.scale, 2.5);
        expect(eval2!.translationX, 77.0);
        expect(eval2.scale, 2.5);
      },
    );
  });

  group('VGOverlayTransformEvaluator - Active Interval & Static Fallback', () {
    test(
      'returns null outside active interval [startTime, startTime + duration)',
      () {
        final overlay = VGOverlayDescriptor(
          id: 'ov_interval',
          startTimeSeconds: 2.0,
          durationSeconds: 3.0,
        );

        // Before start
        expect(
          VGOverlayTransformEvaluator.evaluateOverlay(
            overlay: overlay,
            ptsSeconds: 1.99,
          ),
          isNull,
        );

        // Exact start is active
        expect(
          VGOverlayTransformEvaluator.evaluateOverlay(
            overlay: overlay,
            ptsSeconds: 2.0,
          ),
          isNotNull,
        );

        // Midpoint is active
        expect(
          VGOverlayTransformEvaluator.evaluateOverlay(
            overlay: overlay,
            ptsSeconds: 3.5,
          ),
          isNotNull,
        );

        // End boundary is exclusive -> null
        expect(
          VGOverlayTransformEvaluator.evaluateOverlay(
            overlay: overlay,
            ptsSeconds: 5.0,
          ),
          isNull,
        );

        // After end -> null
        expect(
          VGOverlayTransformEvaluator.evaluateOverlay(
            overlay: overlay,
            ptsSeconds: 6.0,
          ),
          isNull,
        );

        // Negative pts -> null
        expect(
          VGOverlayTransformEvaluator.evaluateOverlay(
            overlay: overlay,
            ptsSeconds: -0.5,
          ),
          isNull,
        );
      },
    );

    test('no keyframes returns static descriptor transform while active', () {
      final overlay = VGOverlayDescriptor(
        id: 'ov_static',
        type: VGOverlayType.text,
        startTimeSeconds: 1.0,
        durationSeconds: 2.0,
        translationX: 120.0,
        translationY: 80.0,
        width: 250.0,
        height: 60.0,
        rotation: 0.12,
        scale: 1.3,
        opacity: 0.9,
        zIndex: 2,
        textContent: 'Static text',
      );

      final eval = VGOverlayTransformEvaluator.evaluateOverlay(
        overlay: overlay,
        ptsSeconds: 1.5,
        keyframes: null,
      );

      expect(eval, isNotNull);
      expect(eval!.id, 'ov_static');
      expect(eval.type, VGOverlayType.text);
      expect(eval.translationX, 120.0);
      expect(eval.translationY, 80.0);
      expect(eval.width, 250.0);
      expect(eval.height, 60.0);
      expect(eval.rotation, 0.12);
      expect(eval.scale, 1.3);
      expect(eval.opacity, 0.9);
      expect(eval.zIndex, 2);
      expect(eval.textContent, 'Static text');
    });
  });

  group('VGOverlayTransformEvaluator - Multiple Overlays & Sorting', () {
    test(
      'filters inactive overlays and sorts by zIndex ascending then id ascending',
      () {
        final ov1 = VGOverlayDescriptor(
          id: 'ov_b',
          startTimeSeconds: 0.0,
          durationSeconds: 5.0,
          zIndex: 1,
        );
        final ov2 = VGOverlayDescriptor(
          id: 'ov_a',
          startTimeSeconds: 0.0,
          durationSeconds: 5.0,
          zIndex: 1,
        );
        final ov3 = VGOverlayDescriptor(
          id: 'ov_z0',
          startTimeSeconds: 0.0,
          durationSeconds: 5.0,
          zIndex: 0,
        );
        final ov4 = VGOverlayDescriptor(
          id: 'ov_top',
          startTimeSeconds: 0.0,
          durationSeconds: 5.0,
          zIndex: 10,
        );
        final ovInactive = VGOverlayDescriptor(
          id: 'ov_inactive',
          startTimeSeconds: 8.0,
          durationSeconds: 2.0,
          zIndex: 5,
        );

        final keyframesMap = <String, List<VGOverlayKeyframe>>{
          'ov_b': [
            VGOverlayKeyframe(timeSeconds: 0.0, translationX: 10.0),
            VGOverlayKeyframe(timeSeconds: 5.0, translationX: 50.0),
          ],
        };

        final results = VGOverlayTransformEvaluator.evaluateOverlays(
          overlays: [ov1, ov2, ov3, ov4, ovInactive],
          ptsSeconds: 2.5,
          keyframesByOverlayId: keyframesMap,
        );

        // ovInactive is excluded (4 overlays returned)
        expect(results.length, 4);

        // Ordering:
        // 1. ov_z0 (zIndex: 0)
        // 2. ov_a  (zIndex: 1, id 'ov_a' < 'ov_b')
        // 3. ov_b  (zIndex: 1, id 'ov_b')
        // 4. ov_top (zIndex: 10)
        expect(results[0].id, 'ov_z0');
        expect(results[1].id, 'ov_a');
        expect(results[2].id, 'ov_b');
        expect(results[3].id, 'ov_top');

        // Keyframed interpolation applied to ov_b
        expect(results[2].translationX, closeTo(30.0, 1e-6));
      },
    );
  });

  group('VGOverlayTransformEvaluator - Validation and Error Handling', () {
    test('non-monotonic keyframes throw ArgumentError', () {
      final keyframes = [
        VGOverlayKeyframe(timeSeconds: 2.0),
        VGOverlayKeyframe(timeSeconds: 1.0),
      ];

      expect(
        () => VGOverlayTransformEvaluator.validateKeyframes(keyframes, 5.0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('duplicate keyframe timestamps throw ArgumentError', () {
      final keyframes = [
        VGOverlayKeyframe(timeSeconds: 1.0),
        VGOverlayKeyframe(timeSeconds: 1.0),
      ];

      expect(
        () => VGOverlayTransformEvaluator.validateKeyframes(keyframes, 5.0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('keyframe beyond duration throws ArgumentError', () {
      final keyframes = [VGOverlayKeyframe(timeSeconds: 6.0)];

      expect(
        () => VGOverlayTransformEvaluator.validateKeyframes(keyframes, 5.0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('invalid or zero duration throws ArgumentError', () {
      expect(
        () => VGOverlayTransformEvaluator.validateKeyframes([], 0.0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayTransformEvaluator.validateKeyframes([], -2.0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayTransformEvaluator.validateKeyframes([], double.nan),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('non-finite ptsSeconds in evaluateOverlay throws ArgumentError', () {
      final overlay = VGOverlayDescriptor(id: 'ov', durationSeconds: 2.0);
      expect(
        () => VGOverlayTransformEvaluator.evaluateOverlay(
          overlay: overlay,
          ptsSeconds: double.nan,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayTransformEvaluator.evaluateOverlays(
          overlays: [overlay],
          ptsSeconds: double.infinity,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
