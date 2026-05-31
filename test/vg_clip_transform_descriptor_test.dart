// vg_clip_transform_descriptor_test.dart
// Vanguard Media Engine — Phase 7.11
//
// Unit tests for VGClipTransformDescriptor (pure Dart value type).
// Tests cover: construction, isIdentity, toMap/fromMap round-trip,
// copyWith, equality, hashCode, invalid constraint rejection.
//
// Run: flutter test test/vg_clip_transform_descriptor_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_transform_descriptor.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';

void main() {
  // ─────────────────────────────────────────────────────────────────────────────
  // VGClipTransformDescriptor — construction
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGClipTransformDescriptor — defaults and identity', () {
    test('TD-01 default constructor produces identity', () {
      const td = VGClipTransformDescriptor();
      expect(td.scaleX, 1.0);
      expect(td.scaleY, 1.0);
      expect(td.translationX, 0.0);
      expect(td.translationY, 0.0);
      expect(td.rotation, 0.0);
      expect(td.opacity, 1.0);
      expect(td.anchorX, 0.5);
      expect(td.anchorY, 0.5);
      expect(td.isIdentity, isTrue);
    });

    test('TD-02 non-identity scaleX makes isIdentity false', () {
      const td = VGClipTransformDescriptor(scaleX: 0.5);
      expect(td.isIdentity, isFalse);
    });

    test('TD-03 non-identity opacity makes isIdentity false', () {
      const td = VGClipTransformDescriptor(opacity: 0.8);
      expect(td.isIdentity, isFalse);
    });

    test('TD-04 non-identity rotation makes isIdentity false', () {
      const td = VGClipTransformDescriptor(rotation: 0.785);
      expect(td.isIdentity, isFalse);
    });

    test('TD-05 non-identity translation X makes isIdentity false', () {
      const td = VGClipTransformDescriptor(translationX: 100.0);
      expect(td.isIdentity, isFalse);
    });

    test('TD-06 non-identity anchor Y makes isIdentity false', () {
      const td = VGClipTransformDescriptor(anchorY: 0.0);
      expect(td.isIdentity, isFalse);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Construction validation (assert checks)
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGClipTransformDescriptor — construction validation', () {
    test('TD-10 scaleX <= 0 throws AssertionError', () {
      expect(
        () => VGClipTransformDescriptor(scaleX: 0.0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TD-11 scaleY <= 0 throws AssertionError', () {
      expect(
        () => VGClipTransformDescriptor(scaleY: -1.0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TD-12 opacity < 0 throws AssertionError', () {
      expect(
        () => VGClipTransformDescriptor(opacity: -0.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TD-13 opacity > 1 throws AssertionError', () {
      expect(
        () => VGClipTransformDescriptor(opacity: 1.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TD-14 anchorX < 0 throws AssertionError', () {
      expect(
        () => VGClipTransformDescriptor(anchorX: -0.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TD-15 anchorX > 1 throws AssertionError', () {
      expect(
        () => VGClipTransformDescriptor(anchorX: 1.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TD-16 anchorY out of range throws AssertionError', () {
      expect(
        () => VGClipTransformDescriptor(anchorY: 1.5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TD-17 opacity == 0.0 is valid', () {
      const td = VGClipTransformDescriptor(opacity: 0.0);
      expect(td.opacity, 0.0);
    });

    test('TD-18 scaleX == 0.01 is valid (very small positive)', () {
      const td = VGClipTransformDescriptor(scaleX: 0.01);
      expect(td.scaleX, 0.01);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Serialisation: toMap / fromMap round-trip
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGClipTransformDescriptor — toMap / fromMap', () {
    test('TD-20 identity round-trips correctly', () {
      const td = VGClipTransformDescriptor();
      final map = td.toMap();
      final restored = VGClipTransformDescriptor.fromMap(
        Map<Object?, Object?>.from(map),
      );
      expect(restored, isNotNull);
      expect(restored!, equals(td));
    });

    test('TD-21 non-identity round-trips correctly', () {
      const td = VGClipTransformDescriptor(
        scaleX: 0.5,
        scaleY: 0.8,
        translationX: 120.0,
        translationY: -50.0,
        rotation: 1.5708,
        opacity: 0.7,
        anchorX: 0.3,
        anchorY: 0.7,
      );
      final map = td.toMap();
      final restored = VGClipTransformDescriptor.fromMap(
        Map<Object?, Object?>.from(map),
      );
      expect(restored, isNotNull);
      expect(restored!.scaleX, closeTo(0.5, 1e-9));
      expect(restored.scaleY, closeTo(0.8, 1e-9));
      expect(restored.translationX, closeTo(120.0, 1e-9));
      expect(restored.translationY, closeTo(-50.0, 1e-9));
      expect(restored.rotation, closeTo(1.5708, 1e-9));
      expect(restored.opacity, closeTo(0.7, 1e-9));
      expect(restored.anchorX, closeTo(0.3, 1e-9));
      expect(restored.anchorY, closeTo(0.7, 1e-9));
    });

    test('TD-22 toMap keys are correct', () {
      const td = VGClipTransformDescriptor();
      final map = td.toMap();
      expect(map.containsKey('scaleX'), isTrue);
      expect(map.containsKey('scaleY'), isTrue);
      expect(map.containsKey('translationX'), isTrue);
      expect(map.containsKey('translationY'), isTrue);
      expect(map.containsKey('rotation'), isTrue);
      expect(map.containsKey('opacity'), isTrue);
      expect(map.containsKey('anchorX'), isTrue);
      expect(map.containsKey('anchorY'), isTrue);
    });

    test('TD-23 fromMap with missing keys falls back to identity defaults', () {
      final td = VGClipTransformDescriptor.fromMap(<Object?, Object?>{});
      expect(td, isNotNull);
      expect(td!.isIdentity, isTrue);
    });

    test('TD-24 fromMap with invalid scaleX returns null', () {
      final td = VGClipTransformDescriptor.fromMap(
        <Object?, Object?>{'scaleX': -1.0},
      );
      expect(td, isNull);
    });

    test('TD-25 fromMap with opacity > 1 returns null', () {
      final td = VGClipTransformDescriptor.fromMap(
        <Object?, Object?>{'opacity': 1.5},
      );
      expect(td, isNull);
    });

    test('TD-26 fromMap with anchorX < 0 returns null', () {
      final td = VGClipTransformDescriptor.fromMap(
        <Object?, Object?>{'anchorX': -0.1},
      );
      expect(td, isNull);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // copyWith
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGClipTransformDescriptor — copyWith', () {
    test('TD-30 copyWith changes only specified fields', () {
      const td = VGClipTransformDescriptor(
        scaleX: 0.5,
        opacity: 0.8,
      );
      final copy = td.copyWith(scaleX: 2.0);
      expect(copy.scaleX, 2.0);
      expect(copy.opacity, 0.8); // unchanged
      expect(copy.scaleY, 1.0); // unchanged
    });

    test('TD-31 copyWith with no args returns equal descriptor', () {
      const td = VGClipTransformDescriptor(scaleX: 0.5, opacity: 0.7);
      final copy = td.copyWith();
      expect(copy, equals(td));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Equality and hashCode
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGClipTransformDescriptor — equality and hashCode', () {
    test('TD-40 two identity descriptors are equal', () {
      const a = VGClipTransformDescriptor();
      const b = VGClipTransformDescriptor();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('TD-41 descriptors with different scaleX are not equal', () {
      const a = VGClipTransformDescriptor(scaleX: 0.5);
      const b = VGClipTransformDescriptor(scaleX: 0.6);
      expect(a == b, isFalse);
    });

    test('TD-42 descriptors with all same fields are equal', () {
      const a = VGClipTransformDescriptor(
        scaleX: 0.5, scaleY: 0.8, translationX: 10.0,
        translationY: -5.0, rotation: 0.5, opacity: 0.9,
        anchorX: 0.3, anchorY: 0.7,
      );
      const b = VGClipTransformDescriptor(
        scaleX: 0.5, scaleY: 0.8, translationX: 10.0,
        translationY: -5.0, rotation: 0.5, opacity: 0.9,
        anchorX: 0.3, anchorY: 0.7,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // toString
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGClipTransformDescriptor — toString', () {
    test('TD-50 toString contains class name', () {
      const td = VGClipTransformDescriptor();
      expect(td.toString(), contains('VGClipTransformDescriptor'));
    });

    test('TD-51 toString contains scale values', () {
      const td = VGClipTransformDescriptor(scaleX: 2.5, scaleY: 3.0);
      expect(td.toString(), contains('2.5'));
      expect(td.toString(), contains('3.0'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // VGClipDescriptor + transform integration
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGClipDescriptor + transform — Phase 7.11 integration', () {
    VGClipDescriptor _makeClip({VGClipTransformDescriptor? transform}) {
      return VGClipDescriptor(
        id: 'test-clip',
        sourcePath: '/tmp/test.mp4',
        durationSeconds: 10.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 10.0,
        transform: transform,
      );
    }

    test('CD-T01 clip without transform has null transform', () {
      final clip = _makeClip();
      expect(clip.transform, isNull);
    });

    test('CD-T02 clip with transform stores it correctly', () {
      const td = VGClipTransformDescriptor(scaleX: 0.5, opacity: 0.8);
      final clip = _makeClip(transform: td);
      expect(clip.transform, equals(td));
    });

    test('CD-T03 toMap omits transform key when null', () {
      final clip = _makeClip();
      expect(clip.toMap().containsKey('transform'), isFalse);
    });

    test('CD-T04 toMap includes transform key when non-null', () {
      const td = VGClipTransformDescriptor(scaleX: 0.5);
      final clip = _makeClip(transform: td);
      final map = clip.toMap();
      expect(map.containsKey('transform'), isTrue);
      expect(map['transform'], isA<Map>());
    });

    test('CD-T05 fromMap round-trips clip with transform', () {
      const td = VGClipTransformDescriptor(scaleX: 0.75, opacity: 0.9);
      final clip = _makeClip(transform: td);
      final map = clip.toMap();
      final restored = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(map),
      );
      expect(restored, isNotNull);
      expect(restored!.transform, isNotNull);
      expect(restored.transform!.scaleX, closeTo(0.75, 1e-9));
      expect(restored.transform!.opacity, closeTo(0.9, 1e-9));
    });

    test('CD-T06 fromMap round-trips clip without transform', () {
      final clip = _makeClip();
      final map = clip.toMap();
      final restored = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(map),
      );
      expect(restored, isNotNull);
      expect(restored!.transform, isNull);
    });

    test('CD-T07 fromMap with invalid transform returns null', () {
      final map = _makeClip().toMap();
      // Inject an invalid transform (scaleX = 0 is invalid).
      map['transform'] = <Object?, Object?>{'scaleX': 0.0};
      final restored = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(map),
      );
      expect(restored, isNull);
    });

    test('CD-T08 copyWith without transform arg preserves existing transform', () {
      const td = VGClipTransformDescriptor(scaleX: 0.5);
      final clip = _makeClip(transform: td);
      final copy = clip.copyWith(id: 'new-id');
      expect(copy.transform, equals(td));
    });

    test('CD-T09 copyWith with explicit null transform clears it', () {
      const td = VGClipTransformDescriptor(scaleX: 0.5);
      final clip = _makeClip(transform: td);
      final copy = clip.copyWith(transform: null);
      expect(copy.transform, isNull);
    });

    test('CD-T10 equality includes transform', () {
      const td = VGClipTransformDescriptor(scaleX: 0.5);
      final a = _makeClip(transform: td);
      final b = _makeClip(transform: td);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('CD-T11 clips with different transforms are not equal', () {
      const tdA = VGClipTransformDescriptor(scaleX: 0.5);
      const tdB = VGClipTransformDescriptor(scaleX: 0.8);
      final a = _makeClip(transform: tdA);
      final b = _makeClip(transform: tdB);
      expect(a == b, isFalse);
    });

    test('CD-T12 clip with transform and clip without are not equal', () {
      const td = VGClipTransformDescriptor(scaleX: 0.5);
      final a = _makeClip(transform: td);
      final b = _makeClip();
      expect(a == b, isFalse);
    });
  });
}
