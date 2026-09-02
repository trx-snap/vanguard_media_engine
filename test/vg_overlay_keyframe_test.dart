// vg_overlay_keyframe_test.dart
// Vanguard Media Engine - Phase 5 (P5-OVERLAYS-KEYFRAME-INTERP)
//
// Pure Dart unit tests for VGOverlayInterpolation, VGOverlayKeyframe,
// and VGOverlayEvaluatedTransform.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGOverlayInterpolation', () {
    test('enum values and wire values match', () {
      expect(VGOverlayInterpolation.linear.value, 'linear');
      expect(VGOverlayInterpolation.easeInOut.value, 'easeInOut');
      expect(VGOverlayInterpolation.smoothstep.value, 'smoothstep');
      expect(VGOverlayInterpolation.hold.value, 'hold');
    });

    test('fromValue resolves known strings', () {
      expect(
        VGOverlayInterpolation.fromValue('linear'),
        VGOverlayInterpolation.linear,
      );
      expect(
        VGOverlayInterpolation.fromValue('easeInOut'),
        VGOverlayInterpolation.easeInOut,
      );
      expect(
        VGOverlayInterpolation.fromValue('smoothstep'),
        VGOverlayInterpolation.smoothstep,
      );
      expect(
        VGOverlayInterpolation.fromValue('hold'),
        VGOverlayInterpolation.hold,
      );
    });

    test('fromString alias resolves known strings', () {
      expect(
        VGOverlayInterpolation.fromString('linear'),
        VGOverlayInterpolation.linear,
      );
      expect(
        VGOverlayInterpolation.fromString('hold'),
        VGOverlayInterpolation.hold,
      );
    });

    test('fromValue throws ArgumentError on unknown string', () {
      expect(
        () => VGOverlayInterpolation.fromValue('bezier'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('VGOverlayKeyframe - Construction and Defaults', () {
    test('default construction sets expected values', () {
      final kf = VGOverlayKeyframe(timeSeconds: 0.0);
      expect(kf.timeSeconds, 0.0);
      expect(kf.translationX, 0.0);
      expect(kf.translationY, 0.0);
      expect(kf.width, 0.0);
      expect(kf.height, 0.0);
      expect(kf.rotation, 0.0);
      expect(kf.scale, 1.0);
      expect(kf.opacity, 1.0);
      expect(kf.interpolation, VGOverlayInterpolation.linear);
    });

    test('custom values are preserved', () {
      final kf = VGOverlayKeyframe(
        timeSeconds: 1.5,
        translationX: 120.0,
        translationY: 240.0,
        width: 300.0,
        height: 150.0,
        rotation: 0.785,
        scale: 2.0,
        opacity: 0.8,
        interpolation: VGOverlayInterpolation.easeInOut,
      );
      expect(kf.timeSeconds, 1.5);
      expect(kf.translationX, 120.0);
      expect(kf.translationY, 240.0);
      expect(kf.width, 300.0);
      expect(kf.height, 150.0);
      expect(kf.rotation, 0.785);
      expect(kf.scale, 2.0);
      expect(kf.opacity, 0.8);
      expect(kf.interpolation, VGOverlayInterpolation.easeInOut);
    });
  });

  group('VGOverlayKeyframe - Validation Rules', () {
    test('negative timeSeconds throws ArgumentError', () {
      expect(
        () => VGOverlayKeyframe(timeSeconds: -0.1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('non-finite timeSeconds throws ArgumentError', () {
      expect(
        () => VGOverlayKeyframe(timeSeconds: double.nan),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayKeyframe(timeSeconds: double.infinity),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('non-finite translation throws ArgumentError', () {
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, translationX: double.nan),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayKeyframe(
          timeSeconds: 0.0,
          translationY: double.negativeInfinity,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('negative width or height throws ArgumentError', () {
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, width: -1.0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, height: -0.01),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('non-finite width or height throws ArgumentError', () {
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, width: double.nan),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, height: double.infinity),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('non-finite rotation throws ArgumentError', () {
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, rotation: double.nan),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('scale <= 0 or non-finite throws ArgumentError', () {
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, scale: 0.0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, scale: -0.5),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, scale: double.nan),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('opacity out of [0.0, 1.0] or non-finite throws ArgumentError', () {
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, opacity: -0.01),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, opacity: 1.01),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGOverlayKeyframe(timeSeconds: 0.0, opacity: double.nan),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('VGOverlayKeyframe - copyWith', () {
    test('copyWith replaces specified properties and preserves others', () {
      final original = VGOverlayKeyframe(
        timeSeconds: 1.0,
        translationX: 10.0,
        translationY: 20.0,
        width: 100.0,
        height: 50.0,
        rotation: 0.5,
        scale: 1.5,
        opacity: 0.9,
        interpolation: VGOverlayInterpolation.hold,
      );

      final modified = original.copyWith(
        scale: 2.0,
        interpolation: VGOverlayInterpolation.linear,
      );

      expect(modified.timeSeconds, 1.0);
      expect(modified.translationX, 10.0);
      expect(modified.translationY, 20.0);
      expect(modified.width, 100.0);
      expect(modified.height, 50.0);
      expect(modified.rotation, 0.5);
      expect(modified.scale, 2.0);
      expect(modified.opacity, 0.9);
      expect(modified.interpolation, VGOverlayInterpolation.linear);
    });
  });

  group('VGOverlayKeyframe - Serialization and Equality', () {
    test('toMap and fromMap roundtrip correctly', () {
      final kf = VGOverlayKeyframe(
        timeSeconds: 2.5,
        translationX: 15.0,
        translationY: 25.0,
        width: 200.0,
        height: 100.0,
        rotation: 1.57,
        scale: 1.8,
        opacity: 0.75,
        interpolation: VGOverlayInterpolation.smoothstep,
      );

      final map = kf.toMap();
      final restored = VGOverlayKeyframe.fromMap(map);

      expect(restored, equals(kf));
      expect(restored.hashCode, equals(kf.hashCode));
    });

    test('toJson and fromJson roundtrip correctly', () {
      final kf = VGOverlayKeyframe(
        timeSeconds: 0.0,
        interpolation: VGOverlayInterpolation.hold,
      );

      final json = kf.toJson();
      final restored = VGOverlayKeyframe.fromJson(json);

      expect(restored, equals(kf));
    });

    test('fromMap uses defaults when optional fields are omitted', () {
      final map = <String, Object>{'timeSeconds': 1.0};
      final kf = VGOverlayKeyframe.fromMap(map);

      expect(kf.timeSeconds, 1.0);
      expect(kf.translationX, 0.0);
      expect(kf.translationY, 0.0);
      expect(kf.width, 0.0);
      expect(kf.height, 0.0);
      expect(kf.rotation, 0.0);
      expect(kf.scale, 1.0);
      expect(kf.opacity, 1.0);
      expect(kf.interpolation, VGOverlayInterpolation.linear);
    });

    test('fromMap throws on missing timeSeconds', () {
      expect(
        () => VGOverlayKeyframe.fromMap(<String, Object>{}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('equality and hashCode differentiate unequal keyframes', () {
      final kf1 = VGOverlayKeyframe(timeSeconds: 1.0, scale: 1.0);
      final kf2 = VGOverlayKeyframe(timeSeconds: 1.0, scale: 1.5);
      final kf3 = VGOverlayKeyframe(timeSeconds: 2.0, scale: 1.0);

      expect(kf1 == kf2, isFalse);
      expect(kf1 == kf3, isFalse);
      expect(kf1.hashCode == kf2.hashCode, isFalse);
    });

    test('toString formats cleanly', () {
      final kf = VGOverlayKeyframe(timeSeconds: 1.0);
      expect(kf.toString(), contains('VGOverlayKeyframe'));
    });
  });

  group('VGOverlayEvaluatedTransform', () {
    test('construction and field values match', () {
      final result = VGOverlayEvaluatedTransform(
        id: 'overlay_1',
        type: VGOverlayType.text,
        startTimeSeconds: 1.0,
        durationSeconds: 4.0,
        translationX: 100.0,
        translationY: 200.0,
        width: 300.0,
        height: 80.0,
        rotation: 0.1,
        scale: 1.2,
        opacity: 0.95,
        zIndex: 3,
        textContent: 'Hello World',
        assetPath: null,
      );

      expect(result.id, 'overlay_1');
      expect(result.type, VGOverlayType.text);
      expect(result.startTimeSeconds, 1.0);
      expect(result.durationSeconds, 4.0);
      expect(result.translationX, 100.0);
      expect(result.translationY, 200.0);
      expect(result.width, 300.0);
      expect(result.height, 80.0);
      expect(result.rotation, 0.1);
      expect(result.scale, 1.2);
      expect(result.opacity, 0.95);
      expect(result.zIndex, 3);
      expect(result.textContent, 'Hello World');
      expect(result.assetPath, isNull);
    });

    test('fromDescriptor and toDescriptor roundtrip', () {
      final descriptor = VGOverlayDescriptor(
        id: 'sticker_1',
        type: VGOverlayType.sticker,
        startTimeSeconds: 0.5,
        durationSeconds: 3.0,
        translationX: 50.0,
        translationY: 75.0,
        width: 120.0,
        height: 120.0,
        rotation: 0.25,
        scale: 1.5,
        opacity: 0.85,
        zIndex: 5,
        assetPath: 'assets/stickers/star.png',
      );

      final eval = VGOverlayEvaluatedTransform.fromDescriptor(
        descriptor,
        translationX: 60.0,
      );
      expect(eval.translationX, 60.0);
      expect(eval.id, 'sticker_1');
      expect(eval.assetPath, 'assets/stickers/star.png');

      final backToDesc = eval.toDescriptor();
      expect(backToDesc.translationX, 60.0);
      expect(backToDesc.id, 'sticker_1');
      expect(backToDesc.type, VGOverlayType.sticker);
      expect(backToDesc.assetPath, 'assets/stickers/star.png');
    });

    test('toMap and fromMap roundtrip correctly', () {
      final eval = VGOverlayEvaluatedTransform(
        id: 'emoji_1',
        type: VGOverlayType.emoji,
        startTimeSeconds: 2.0,
        durationSeconds: 5.0,
        translationX: 10.0,
        translationY: 20.0,
        width: 64.0,
        height: 64.0,
        rotation: 0.0,
        scale: 1.0,
        opacity: 1.0,
        zIndex: 1,
        textContent: 'sparkles',
      );

      final map = eval.toMap();
      final restored = VGOverlayEvaluatedTransform.fromMap(map);

      expect(restored, equals(eval));
      expect(restored.hashCode, equals(eval.hashCode));
    });

    test('copyWith updates specified fields', () {
      final eval = VGOverlayEvaluatedTransform(
        id: 'ov_1',
        type: VGOverlayType.text,
        startTimeSeconds: 0.0,
        durationSeconds: 1.0,
        translationX: 0.0,
        translationY: 0.0,
        width: 10.0,
        height: 10.0,
        rotation: 0.0,
        scale: 1.0,
        opacity: 1.0,
        zIndex: 0,
      );

      final updated = eval.copyWith(opacity: 0.5, zIndex: 10);
      expect(updated.opacity, 0.5);
      expect(updated.zIndex, 10);
      expect(updated.id, 'ov_1');
    });

    test('constructor validation rejects invalid numbers', () {
      expect(
        () => VGOverlayEvaluatedTransform(
          id: 'test',
          type: VGOverlayType.text,
          startTimeSeconds: -1.0,
          durationSeconds: 1.0,
          translationX: 0.0,
          translationY: 0.0,
          width: 10.0,
          height: 10.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect(
        () => VGOverlayEvaluatedTransform(
          id: 'test',
          type: VGOverlayType.text,
          startTimeSeconds: 0.0,
          durationSeconds: 1.0,
          translationX: 0.0,
          translationY: 0.0,
          width: -10.0,
          height: 10.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect(
        () => VGOverlayEvaluatedTransform(
          id: 'test',
          type: VGOverlayType.text,
          startTimeSeconds: 0.0,
          durationSeconds: 1.0,
          translationX: 0.0,
          translationY: 0.0,
          width: 10.0,
          height: 10.0,
          rotation: 0.0,
          scale: 0.0,
          opacity: 1.0,
          zIndex: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect(
        () => VGOverlayEvaluatedTransform(
          id: 'test',
          type: VGOverlayType.text,
          startTimeSeconds: 0.0,
          durationSeconds: 1.0,
          translationX: 0.0,
          translationY: 0.0,
          width: 10.0,
          height: 10.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.5,
          zIndex: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
