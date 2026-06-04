// vg_transform_keyframe_descriptor_test.dart
// Vanguard Media Engine — Phase 7.23
//
// Pure Dart unit tests for VGKeyframeInterpolation, VGTransformKeyframeDescriptor,
// and VGTransformTrackDescriptor (including interpolatedTransformAt). Also covers
// VGClipDescriptor.transformTrack integration (serialization, fromMap, copyWith,
// backward compatibility).
//
// No Flutter engine or native code required — runs in `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_transform_keyframe_descriptor.dart';
import 'package:vanguard_media_engine/vg_clip_transform_descriptor.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// A minimal valid video clip for reuse.
VGClipDescriptor _videoClip({
  VGTransformTrackDescriptor? transformTrack,
  VGClipTransformDescriptor? transform,
}) =>
    VGClipDescriptor(
      id: 'clip-01',
      sourcePath: '/tmp/recording.mp4',
      mediaKind: VGMediaKind.video,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      transform: transform,
      transformTrack: transformTrack,
    );

/// Identity keyframe at time 0.
VGTransformKeyframeDescriptor _identityKeyframe({int timeUs = 0}) =>
    VGTransformKeyframeDescriptor(timeUs: timeUs);

/// A single-keyframe track (simplest valid track).
VGTransformTrackDescriptor _singleKeyframeTrack({
  int timeUs = 0,
  double scaleX = 1.0,
  double scaleY = 1.0,
  double translationX = 0.0,
  double translationY = 0.0,
  double rotation = 0.0,
  double opacity = 1.0,
  double anchorX = 0.5,
  double anchorY = 0.5,
  VGKeyframeInterpolation interpolation = VGKeyframeInterpolation.linear,
}) =>
    VGTransformTrackDescriptor(
      keyframes: [
        VGTransformKeyframeDescriptor(
          timeUs: timeUs,
          scaleX: scaleX,
          scaleY: scaleY,
          translationX: translationX,
          translationY: translationY,
          rotation: rotation,
          opacity: opacity,
        ),
      ],
      interpolation: interpolation,
      anchorX: anchorX,
      anchorY: anchorY,
    );

void main() {
  // ── VGKeyframeInterpolation — wire values ─────────────────────────────────

  group('VGKeyframeInterpolation — wire values', () {
    test('KI-1 linear serializes to "linear"', () {
      expect(VGKeyframeInterpolation.linear.value, 'linear');
    });

    test('KI-2 hold serializes to "hold"', () {
      expect(VGKeyframeInterpolation.hold.value, 'hold');
    });

    test('KI-3 fromValue resolves "linear" correctly', () {
      expect(
        VGKeyframeInterpolation.fromValue('linear'),
        VGKeyframeInterpolation.linear,
      );
    });

    test('KI-4 fromValue resolves "hold" correctly', () {
      expect(
        VGKeyframeInterpolation.fromValue('hold'),
        VGKeyframeInterpolation.hold,
      );
    });

    test('KI-5 fromValue falls back to linear for unknown string', () {
      expect(
        VGKeyframeInterpolation.fromValue('bezier'),
        VGKeyframeInterpolation.linear,
      );
      expect(
        VGKeyframeInterpolation.fromValue(''),
        VGKeyframeInterpolation.linear,
      );
    });
  });

  // ── VGTransformKeyframeDescriptor — construction ──────────────────────────

  group('VGTransformKeyframeDescriptor — construction', () {
    test('TK-1 valid identity keyframe constructs correctly', () {
      const k = VGTransformKeyframeDescriptor(timeUs: 0);
      expect(k.timeUs, 0);
      expect(k.scaleX, 1.0);
      expect(k.scaleY, 1.0);
      expect(k.translationX, 0.0);
      expect(k.translationY, 0.0);
      expect(k.rotation, 0.0);
      expect(k.opacity, 1.0);
    });

    test('TK-2 non-default fields stored correctly', () {
      const k = VGTransformKeyframeDescriptor(
        timeUs: 500000,
        scaleX: 0.5,
        scaleY: 2.0,
        translationX: 100.0,
        translationY: -50.0,
        rotation: 1.5708,
        opacity: 0.75,
      );
      expect(k.timeUs, 500000);
      expect(k.scaleX, 0.5);
      expect(k.scaleY, 2.0);
      expect(k.translationX, 100.0);
      expect(k.translationY, -50.0);
      expect(k.rotation, 1.5708);
      expect(k.opacity, 0.75);
    });

    test('TK-3 negative timeUs triggers assert', () {
      expect(
        () => VGTransformKeyframeDescriptor(timeUs: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TK-4 scaleX == 0 triggers assert', () {
      expect(
        () => VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 0.0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TK-5 negative scaleX triggers assert', () {
      expect(
        () => VGTransformKeyframeDescriptor(timeUs: 0, scaleX: -1.0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TK-6 scaleY == 0 triggers assert', () {
      expect(
        () => VGTransformKeyframeDescriptor(timeUs: 0, scaleY: 0.0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TK-7 negative scaleY triggers assert', () {
      expect(
        () => VGTransformKeyframeDescriptor(timeUs: 0, scaleY: -0.5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TK-8 opacity < 0 triggers assert', () {
      expect(
        () => VGTransformKeyframeDescriptor(timeUs: 0, opacity: -0.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TK-9 opacity > 1 triggers assert', () {
      expect(
        () => VGTransformKeyframeDescriptor(timeUs: 0, opacity: 1.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TK-10 opacity == 0.0 is valid (fully transparent)', () {
      const k = VGTransformKeyframeDescriptor(timeUs: 0, opacity: 0.0);
      expect(k.opacity, 0.0);
    });

    test('TK-11 opacity == 1.0 is valid (fully opaque)', () {
      const k = VGTransformKeyframeDescriptor(timeUs: 0, opacity: 1.0);
      expect(k.opacity, 1.0);
    });

    test('TK-12 timeUs == 0 is valid (first frame)', () {
      expect(() => VGTransformKeyframeDescriptor(timeUs: 0), returnsNormally);
    });
  });

  // ── VGTransformKeyframeDescriptor — serialization ─────────────────────────

  group('VGTransformKeyframeDescriptor — toMap / fromMap', () {
    test('TK-S1 toMap produces correct keys and values', () {
      const k = VGTransformKeyframeDescriptor(
        timeUs: 1000000,
        scaleX: 0.5,
        scaleY: 0.8,
        translationX: 120.0,
        translationY: -30.0,
        rotation: 0.785,
        opacity: 0.7,
      );
      final m = k.toMap();
      expect(m['timeUs'], 1000000);
      expect(m['scaleX'], 0.5);
      expect(m['scaleY'], 0.8);
      expect(m['translationX'], 120.0);
      expect(m['translationY'], -30.0);
      expect(m['rotation'], 0.785);
      expect(m['opacity'], 0.7);
      // Anchor is NOT per-keyframe — must not be present.
      expect(m.containsKey('anchorX'), isFalse);
      expect(m.containsKey('anchorY'), isFalse);
    });

    test('TK-S2 fromMap round-trips correctly', () {
      const original = VGTransformKeyframeDescriptor(
        timeUs: 2000000,
        scaleX: 1.5,
        scaleY: 1.5,
        translationX: 50.0,
        translationY: 25.0,
        rotation: -0.5,
        opacity: 0.9,
      );
      final clone = VGTransformKeyframeDescriptor.fromMap(
        original.toMap().cast<Object?, Object?>(),
      );
      expect(clone, isNotNull);
      expect(clone!.timeUs, 2000000);
      expect(clone.scaleX, closeTo(1.5, 1e-9));
      expect(clone.scaleY, closeTo(1.5, 1e-9));
      expect(clone.translationX, closeTo(50.0, 1e-9));
      expect(clone.translationY, closeTo(25.0, 1e-9));
      expect(clone.rotation, closeTo(-0.5, 1e-9));
      expect(clone.opacity, closeTo(0.9, 1e-9));
    });

    test('TK-S3 fromMap returns null when timeUs is missing', () {
      final m = <Object?, Object?>{
        'scaleX': 1.0,
        'scaleY': 1.0,
        'opacity': 1.0,
      };
      expect(VGTransformKeyframeDescriptor.fromMap(m), isNull);
    });

    test('TK-S4 fromMap returns null for negative timeUs', () {
      final m = <Object?, Object?>{
        'timeUs': -1,
        'scaleX': 1.0,
        'scaleY': 1.0,
        'opacity': 1.0,
      };
      expect(VGTransformKeyframeDescriptor.fromMap(m), isNull);
    });

    test('TK-S5 fromMap returns null for scaleX <= 0', () {
      final m = <Object?, Object?>{
        'timeUs': 0,
        'scaleX': 0.0,
        'scaleY': 1.0,
        'opacity': 1.0,
      };
      expect(VGTransformKeyframeDescriptor.fromMap(m), isNull);
    });

    test('TK-S6 fromMap returns null for scaleY <= 0', () {
      final m = <Object?, Object?>{
        'timeUs': 0,
        'scaleX': 1.0,
        'scaleY': -1.0,
        'opacity': 1.0,
      };
      expect(VGTransformKeyframeDescriptor.fromMap(m), isNull);
    });

    test('TK-S7 fromMap returns null for opacity > 1', () {
      final m = <Object?, Object?>{
        'timeUs': 0,
        'scaleX': 1.0,
        'scaleY': 1.0,
        'opacity': 1.5,
      };
      expect(VGTransformKeyframeDescriptor.fromMap(m), isNull);
    });

    test('TK-S8 fromMap returns null for NaN scaleX', () {
      final m = <Object?, Object?>{
        'timeUs': 0,
        'scaleX': double.nan,
        'scaleY': 1.0,
        'opacity': 1.0,
      };
      expect(VGTransformKeyframeDescriptor.fromMap(m), isNull);
    });

    test('TK-S9 fromMap returns null for infinite translationX', () {
      final m = <Object?, Object?>{
        'timeUs': 0,
        'scaleX': 1.0,
        'scaleY': 1.0,
        'translationX': double.infinity,
        'opacity': 1.0,
      };
      expect(VGTransformKeyframeDescriptor.fromMap(m), isNull);
    });

    test('TK-S10 fromMap accepts num (int) for scaleX field', () {
      final m = <Object?, Object?>{
        'timeUs': 0,
        'scaleX': 2,
        'scaleY': 1,
        'opacity': 1,
      };
      final k = VGTransformKeyframeDescriptor.fromMap(m);
      expect(k, isNotNull);
      expect(k!.scaleX, 2.0);
    });

    test('TK-S11 fromMap applies identity defaults for missing optional fields', () {
      final m = <Object?, Object?>{'timeUs': 0};
      final k = VGTransformKeyframeDescriptor.fromMap(m);
      expect(k, isNotNull);
      expect(k!.scaleX, 1.0);
      expect(k.scaleY, 1.0);
      expect(k.translationX, 0.0);
      expect(k.rotation, 0.0);
      expect(k.opacity, 1.0);
    });
  });

  // ── VGTransformKeyframeDescriptor — equality ──────────────────────────────

  group('VGTransformKeyframeDescriptor — equality and hashCode', () {
    test('TK-E1 identical keyframes are equal', () {
      const a = VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 0.5);
      const b = VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 0.5);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('TK-E2 keyframes with different timeUs are not equal', () {
      const a = VGTransformKeyframeDescriptor(timeUs: 0);
      const b = VGTransformKeyframeDescriptor(timeUs: 1000);
      expect(a == b, isFalse);
    });

    test('TK-E3 keyframes with different scaleX are not equal', () {
      const a = VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 0.5);
      const b = VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 0.8);
      expect(a == b, isFalse);
    });
  });

  // ── VGTransformTrackDescriptor — construction ─────────────────────────────

  group('VGTransformTrackDescriptor — construction', () {
    test('TT-1 valid single-keyframe track constructs correctly', () {
      final track = _singleKeyframeTrack();
      expect(track.keyframes, hasLength(1));
      expect(track.interpolation, VGKeyframeInterpolation.linear);
      expect(track.anchorX, 0.5);
      expect(track.anchorY, 0.5);
    });

    test('TT-2 multiple sorted keyframes are valid', () {
      final track = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0),
          VGTransformKeyframeDescriptor(timeUs: 500000),
          VGTransformKeyframeDescriptor(timeUs: 1000000),
        ],
      );
      expect(track.keyframes, hasLength(3));
    });

    test('TT-3 empty keyframes list triggers assert', () {
      expect(
        () => VGTransformTrackDescriptor(keyframes: []),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TT-4 duplicate timeUs triggers assert', () {
      expect(
        () => VGTransformTrackDescriptor(
          keyframes: [
            VGTransformKeyframeDescriptor(timeUs: 0),
            VGTransformKeyframeDescriptor(timeUs: 0), // duplicate
          ],
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TT-5 unsorted keyframes trigger assert', () {
      expect(
        () => VGTransformTrackDescriptor(
          keyframes: [
            VGTransformKeyframeDescriptor(timeUs: 500000),
            VGTransformKeyframeDescriptor(timeUs: 0), // out of order
          ],
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TT-6 anchorX out of range triggers assert', () {
      expect(
        () => VGTransformTrackDescriptor(
          keyframes: [VGTransformKeyframeDescriptor(timeUs: 0)],
          anchorX: -0.1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TT-7 anchorY out of range triggers assert', () {
      expect(
        () => VGTransformTrackDescriptor(
          keyframes: [VGTransformKeyframeDescriptor(timeUs: 0)],
          anchorY: 1.1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TT-8 keyframes list is immutable after construction', () {
      final track = _singleKeyframeTrack();
      expect(
        () => (track.keyframes as List).add(VGTransformKeyframeDescriptor(timeUs: 1)),
        throwsUnsupportedError,
      );
    });

    test('TT-9 anchor defaults to 0.5 center', () {
      final track = VGTransformTrackDescriptor(
        keyframes: [VGTransformKeyframeDescriptor(timeUs: 0)],
      );
      expect(track.anchorX, 0.5);
      expect(track.anchorY, 0.5);
    });

    test('TT-10 custom anchor is stored correctly', () {
      final track = VGTransformTrackDescriptor(
        keyframes: [VGTransformKeyframeDescriptor(timeUs: 0)],
        anchorX: 0.25,
        anchorY: 0.75,
      );
      expect(track.anchorX, 0.25);
      expect(track.anchorY, 0.75);
    });

    test('TT-11 hold interpolation is accepted', () {
      final track = VGTransformTrackDescriptor(
        keyframes: [VGTransformKeyframeDescriptor(timeUs: 0)],
        interpolation: VGKeyframeInterpolation.hold,
      );
      expect(track.interpolation, VGKeyframeInterpolation.hold);
    });
  });

  // ── VGTransformTrackDescriptor — serialization ────────────────────────────

  group('VGTransformTrackDescriptor — toMap / fromMap', () {
    test('TT-S1 toMap produces correct shape', () {
      final track = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0),
          VGTransformKeyframeDescriptor(timeUs: 500000, scaleX: 0.5),
        ],
        interpolation: VGKeyframeInterpolation.hold,
        anchorX: 0.3,
        anchorY: 0.7,
      );
      final m = track.toMap();
      expect(m['interpolation'], 'hold');
      expect(m['anchorX'], 0.3);
      expect(m['anchorY'], 0.7);
      final kfs = m['keyframes'] as List;
      expect(kfs, hasLength(2));
      expect((kfs[0] as Map)['timeUs'], 0);
      expect((kfs[1] as Map)['scaleX'], 0.5);
    });

    test('TT-S2 anchor NOT present in individual keyframe maps', () {
      final track = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0),
        ],
        anchorX: 0.3,
        anchorY: 0.7,
      );
      final m = track.toMap();
      final kfs = m['keyframes'] as List;
      final kfMap = kfs[0] as Map;
      expect(kfMap.containsKey('anchorX'), isFalse);
      expect(kfMap.containsKey('anchorY'), isFalse);
    });

    test('TT-S3 fromMap round-trips single keyframe track', () {
      final original = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 0.75, opacity: 0.8),
        ],
        interpolation: VGKeyframeInterpolation.linear,
        anchorX: 0.3,
        anchorY: 0.7,
      );
      final m = original.toMap().cast<Object?, Object?>();
      final clone = VGTransformTrackDescriptor.fromMap(m);
      expect(clone, isNotNull);
      expect(clone!.keyframes, hasLength(1));
      expect(clone.keyframes[0].scaleX, closeTo(0.75, 1e-9));
      expect(clone.keyframes[0].opacity, closeTo(0.8, 1e-9));
      expect(clone.interpolation, VGKeyframeInterpolation.linear);
      expect(clone.anchorX, closeTo(0.3, 1e-9));
      expect(clone.anchorY, closeTo(0.7, 1e-9));
    });

    test('TT-S4 fromMap round-trips multi-keyframe track', () {
      final original = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0),
          VGTransformKeyframeDescriptor(timeUs: 1000000, scaleX: 0.5),
        ],
        interpolation: VGKeyframeInterpolation.hold,
      );
      final clone = VGTransformTrackDescriptor.fromMap(
        original.toMap().cast<Object?, Object?>(),
      );
      expect(clone, isNotNull);
      expect(clone!.keyframes, hasLength(2));
      expect(clone.interpolation, VGKeyframeInterpolation.hold);
    });

    test('TT-S5 fromMap returns null when keyframes key is missing', () {
      final m = <Object?, Object?>{'interpolation': 'linear', 'anchorX': 0.5, 'anchorY': 0.5};
      expect(VGTransformTrackDescriptor.fromMap(m), isNull);
    });

    test('TT-S6 fromMap returns null when keyframes list is empty', () {
      final m = <Object?, Object?>{
        'interpolation': 'linear',
        'anchorX': 0.5,
        'anchorY': 0.5,
        'keyframes': <dynamic>[],
      };
      expect(VGTransformTrackDescriptor.fromMap(m), isNull);
    });

    test('TT-S7 fromMap returns null when keyframe is malformed', () {
      final m = <Object?, Object?>{
        'interpolation': 'linear',
        'anchorX': 0.5,
        'anchorY': 0.5,
        'keyframes': [
          {'timeUs': 0, 'scaleX': -1.0, 'scaleY': 1.0, 'opacity': 1.0},
        ],
      };
      expect(VGTransformTrackDescriptor.fromMap(m), isNull);
    });

    test('TT-S8 fromMap returns null when keyframes are unsorted', () {
      final m = <Object?, Object?>{
        'interpolation': 'linear',
        'anchorX': 0.5,
        'anchorY': 0.5,
        'keyframes': [
          {'timeUs': 500000, 'scaleX': 1.0, 'scaleY': 1.0, 'opacity': 1.0},
          {'timeUs': 0, 'scaleX': 1.0, 'scaleY': 1.0, 'opacity': 1.0},
        ],
      };
      expect(VGTransformTrackDescriptor.fromMap(m), isNull);
    });

    test('TT-S9 fromMap returns null for duplicate timeUs', () {
      final m = <Object?, Object?>{
        'interpolation': 'linear',
        'anchorX': 0.5,
        'anchorY': 0.5,
        'keyframes': [
          {'timeUs': 0, 'scaleX': 1.0, 'scaleY': 1.0, 'opacity': 1.0},
          {'timeUs': 0, 'scaleX': 0.5, 'scaleY': 0.5, 'opacity': 0.5},
        ],
      };
      expect(VGTransformTrackDescriptor.fromMap(m), isNull);
    });

    test('TT-S10 fromMap defaults interpolation to linear when absent', () {
      final m = <Object?, Object?>{
        'anchorX': 0.5,
        'anchorY': 0.5,
        'keyframes': [
          {'timeUs': 0, 'scaleX': 1.0, 'scaleY': 1.0, 'opacity': 1.0},
        ],
      };
      final track = VGTransformTrackDescriptor.fromMap(m);
      expect(track, isNotNull);
      expect(track!.interpolation, VGKeyframeInterpolation.linear);
    });

    test('TT-S11 fromMap defaults anchor to 0.5 when absent', () {
      final m = <Object?, Object?>{
        'keyframes': [
          {'timeUs': 0, 'scaleX': 1.0, 'scaleY': 1.0, 'opacity': 1.0},
        ],
      };
      final track = VGTransformTrackDescriptor.fromMap(m);
      expect(track, isNotNull);
      expect(track!.anchorX, 0.5);
      expect(track.anchorY, 0.5);
    });

    test('TT-S12 fromMap returns null for anchorX out of range', () {
      final m = <Object?, Object?>{
        'anchorX': 1.5,
        'anchorY': 0.5,
        'keyframes': [
          {'timeUs': 0, 'scaleX': 1.0, 'scaleY': 1.0, 'opacity': 1.0},
        ],
      };
      expect(VGTransformTrackDescriptor.fromMap(m), isNull);
    });
  });

  // ── VGTransformTrackDescriptor — equality ─────────────────────────────────

  group('VGTransformTrackDescriptor — equality and hashCode', () {
    test('TT-E1 identical tracks are equal', () {
      final a = _singleKeyframeTrack();
      final b = _singleKeyframeTrack();
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('TT-E2 tracks with different interpolation are not equal', () {
      final a = _singleKeyframeTrack(interpolation: VGKeyframeInterpolation.linear);
      final b = _singleKeyframeTrack(interpolation: VGKeyframeInterpolation.hold);
      expect(a == b, isFalse);
    });

    test('TT-E3 tracks with different anchor are not equal', () {
      final a = _singleKeyframeTrack(anchorX: 0.3);
      final b = _singleKeyframeTrack(anchorX: 0.5);
      expect(a == b, isFalse);
    });

    test('TT-E4 tracks with different keyframe count are not equal', () {
      final a = VGTransformTrackDescriptor(
        keyframes: [VGTransformKeyframeDescriptor(timeUs: 0)],
      );
      final b = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0),
          VGTransformKeyframeDescriptor(timeUs: 1000000),
        ],
      );
      expect(a == b, isFalse);
    });
  });

  // ── VGTransformTrackDescriptor — interpolatedTransformAt ──────────────────

  group('VGTransformTrackDescriptor — interpolatedTransformAt (linear)', () {
    late VGTransformTrackDescriptor twoKeyTrack;

    setUp(() {
      twoKeyTrack = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(
            timeUs: 0,
            scaleX: 1.0,
            scaleY: 1.0,
            translationX: 0.0,
            translationY: 0.0,
            rotation: 0.0,
            opacity: 1.0,
          ),
          VGTransformKeyframeDescriptor(
            timeUs: 1000000, // 1 second
            scaleX: 0.5,
            scaleY: 0.5,
            translationX: 100.0,
            translationY: 50.0,
            rotation: 1.5708,
            opacity: 0.0,
          ),
        ],
        interpolation: VGKeyframeInterpolation.linear,
        anchorX: 0.25,
        anchorY: 0.75,
      );
    });

    test('TI-L1 before first keyframe clamps to first', () {
      final t = twoKeyTrack.interpolatedTransformAt(-1000000); // before t=0
      expect(t.scaleX, closeTo(1.0, 1e-9));
      expect(t.scaleY, closeTo(1.0, 1e-9));
      expect(t.translationX, closeTo(0.0, 1e-9));
      expect(t.opacity, closeTo(1.0, 1e-9));
    });

    test('TI-L2 exactly at first keyframe returns exact first values', () {
      final t = twoKeyTrack.interpolatedTransformAt(0);
      expect(t.scaleX, closeTo(1.0, 1e-9));
      expect(t.translationX, closeTo(0.0, 1e-9));
      expect(t.opacity, closeTo(1.0, 1e-9));
    });

    test('TI-L3 exactly at last keyframe returns exact last values', () {
      final t = twoKeyTrack.interpolatedTransformAt(1000000);
      expect(t.scaleX, closeTo(0.5, 1e-9));
      expect(t.translationX, closeTo(100.0, 1e-9));
      expect(t.opacity, closeTo(0.0, 1e-9));
    });

    test('TI-L4 after last keyframe clamps to last', () {
      final t = twoKeyTrack.interpolatedTransformAt(2000000); // after 1s
      expect(t.scaleX, closeTo(0.5, 1e-9));
      expect(t.opacity, closeTo(0.0, 1e-9));
    });

    test('TI-L5 at t=0.5 (500000µs) linear lerp is midpoint', () {
      final t = twoKeyTrack.interpolatedTransformAt(500000);
      // Midpoint between keyframe A and keyframe B
      expect(t.scaleX, closeTo(0.75, 1e-6)); // (1.0 + 0.5) / 2
      expect(t.scaleY, closeTo(0.75, 1e-6));
      expect(t.translationX, closeTo(50.0, 1e-6)); // (0 + 100) / 2
      expect(t.translationY, closeTo(25.0, 1e-6)); // (0 + 50) / 2
      expect(t.rotation, closeTo(0.7854, 1e-3)); // ~pi/4
      expect(t.opacity, closeTo(0.5, 1e-6));
    });

    test('TI-L6 at t=0.25 (250000µs) linear lerp is quarter-point', () {
      final t = twoKeyTrack.interpolatedTransformAt(250000);
      expect(t.scaleX, closeTo(0.875, 1e-6)); // 1.0 - 0.25 * 0.5
      expect(t.translationX, closeTo(25.0, 1e-6)); // 0.25 * 100
      expect(t.opacity, closeTo(0.75, 1e-6)); // 1.0 - 0.25 * 1.0
    });

    test('TI-L7 track-level anchor is included in result', () {
      final t = twoKeyTrack.interpolatedTransformAt(0);
      expect(t.anchorX, closeTo(0.25, 1e-9));
      expect(t.anchorY, closeTo(0.75, 1e-9));
    });

    test('TI-L8 opacity remains clamped to [0.0, 1.0]', () {
      // Both keyframes have valid [0,1] opacity; output must stay in range.
      for (final us in [0, 250000, 500000, 750000, 1000000, 2000000]) {
        final t = twoKeyTrack.interpolatedTransformAt(us);
        expect(t.opacity, greaterThanOrEqualTo(0.0));
        expect(t.opacity, lessThanOrEqualTo(1.0));
      }
    });

    test('TI-L9 scale remains > 0 throughout interpolation', () {
      for (final us in [0, 250000, 500000, 750000, 1000000]) {
        final t = twoKeyTrack.interpolatedTransformAt(us);
        expect(t.scaleX, greaterThan(0.0));
        expect(t.scaleY, greaterThan(0.0));
      }
    });

    test('TI-L10 rotation uses direct linear interpolation (no wraparound)', () {
      // Rotation from 0 to pi (3.14159...) — direct lerp, not shortest-path.
      final track = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0, rotation: 0.0),
          VGTransformKeyframeDescriptor(timeUs: 1000000, rotation: 3.14159),
        ],
      );
      final t = track.interpolatedTransformAt(500000);
      expect(t.rotation, closeTo(3.14159 / 2.0, 1e-3));
    });

    test('TI-L11 single keyframe returns constant for all times', () {
      final track = _singleKeyframeTrack(scaleX: 0.5, opacity: 0.6);
      // Before, at, and after the only keyframe — all should return the same values.
      for (final us in [-1000000, 0, 500000, 5000000]) {
        final t = track.interpolatedTransformAt(us);
        expect(t.scaleX, closeTo(0.5, 1e-9));
        expect(t.opacity, closeTo(0.6, 1e-9));
      }
    });

    test('TI-L12 three-keyframe track brackets correctly', () {
      // Keyframes at t=0, t=1s, t=2s.
      final track = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0, translationX: 0.0),
          VGTransformKeyframeDescriptor(timeUs: 1000000, translationX: 100.0),
          VGTransformKeyframeDescriptor(timeUs: 2000000, translationX: 50.0),
        ],
      );
      // At t=0.5s: lerp between kf[0] and kf[1] → 50.0
      expect(track.interpolatedTransformAt(500000).translationX, closeTo(50.0, 1e-6));
      // At t=1.5s: lerp between kf[1] and kf[2] → (100 + 50) / 2 = 75.0
      expect(track.interpolatedTransformAt(1500000).translationX, closeTo(75.0, 1e-6));
    });
  });

  group('VGTransformTrackDescriptor — interpolatedTransformAt (hold)', () {
    late VGTransformTrackDescriptor holdTrack;

    setUp(() {
      holdTrack = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0, translationX: 0.0),
          VGTransformKeyframeDescriptor(timeUs: 1000000, translationX: 100.0),
          VGTransformKeyframeDescriptor(timeUs: 2000000, translationX: 200.0),
        ],
        interpolation: VGKeyframeInterpolation.hold,
      );
    });

    test('TI-H1 before first keyframe returns first', () {
      final t = holdTrack.interpolatedTransformAt(-1000);
      expect(t.translationX, closeTo(0.0, 1e-9));
    });

    test('TI-H2 exactly at first keyframe returns first', () {
      final t = holdTrack.interpolatedTransformAt(0);
      expect(t.translationX, closeTo(0.0, 1e-9));
    });

    test('TI-H3 between first and second keyframe returns first (hold)', () {
      // Between t=0 and t=1s — hold returns kf[0]
      final t = holdTrack.interpolatedTransformAt(500000);
      expect(t.translationX, closeTo(0.0, 1e-9));
    });

    test('TI-H4 exactly at second keyframe returns second', () {
      final t = holdTrack.interpolatedTransformAt(1000000);
      // At boundary: the binary search finds lo=0, hi=1. But 1000000 >= kf[1].timeUs
      // so it clamps to last... No: exactly at kf[1].timeUs = 1000000.
      // Wait: kf[1].timeUs == timeUs, so the condition `timeUs >= keyframes.last.timeUs`
      // is false (last is kf[2] at 2s). We fall into the binary search.
      // The binary search will find lo=1 (timeUs==kf[1].timeUs <= timeUs). Hold returns kf[lo] = kf[1].
      expect(t.translationX, closeTo(100.0, 1e-9));
    });

    test('TI-H5 between second and third keyframe returns second (hold)', () {
      final t = holdTrack.interpolatedTransformAt(1500000);
      expect(t.translationX, closeTo(100.0, 1e-9));
    });

    test('TI-H6 after last keyframe returns last', () {
      final t = holdTrack.interpolatedTransformAt(3000000);
      expect(t.translationX, closeTo(200.0, 1e-9));
    });
  });

  // ── VGClipDescriptor — transformTrack integration ─────────────────────────

  group('VGClipDescriptor — transformTrack field (Phase 7.23)', () {
    test('TCD-1 default clip has transformTrack == null', () {
      final clip = _videoClip();
      expect(clip.transformTrack, isNull);
    });

    test('TCD-2 clip with transformTrack stores it correctly', () {
      final track = _singleKeyframeTrack();
      final clip = _videoClip(transformTrack: track);
      expect(clip.transformTrack, isNotNull);
      expect(clip.transformTrack!.keyframes, hasLength(1));
    });

    test('TCD-3 toMap() omits transformTrack when null', () {
      final clip = _videoClip();
      expect(clip.toMap().containsKey('transformTrack'), isFalse);
    });

    test('TCD-4 toMap() includes transformTrack when non-null', () {
      final track = _singleKeyframeTrack(scaleX: 0.5);
      final clip = _videoClip(transformTrack: track);
      final m = clip.toMap();
      expect(m.containsKey('transformTrack'), isTrue);
      final tt = m['transformTrack'] as Map;
      expect(tt['interpolation'], 'linear');
      final kfs = tt['keyframes'] as List;
      expect(kfs, hasLength(1));
    });

    test('TCD-5 fromMap() round-trips clip with transformTrack', () {
      final track = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 0.75, opacity: 0.8),
          VGTransformKeyframeDescriptor(timeUs: 1000000, scaleX: 1.5),
        ],
        interpolation: VGKeyframeInterpolation.linear,
        anchorX: 0.3,
        anchorY: 0.7,
      );
      final clip = _videoClip(transformTrack: track);
      final clone = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(clip.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!.transformTrack, isNotNull);
      expect(clone.transformTrack!.keyframes, hasLength(2));
      expect(clone.transformTrack!.keyframes[0].scaleX, closeTo(0.75, 1e-9));
      expect(clone.transformTrack!.interpolation, VGKeyframeInterpolation.linear);
      expect(clone.transformTrack!.anchorX, closeTo(0.3, 1e-9));
    });

    test('TCD-6 fromMap() produces null transformTrack when key absent (backward compat)', () {
      final clip = _videoClip(); // no transformTrack
      final m = Map<Object?, Object?>.from(clip.toMap());
      expect(m.containsKey('transformTrack'), isFalse);
      final clone = VGClipDescriptor.fromMap(m);
      expect(clone, isNotNull);
      expect(clone!.transformTrack, isNull);
    });

    test('TCD-7 fromMap() returns null for malformed transformTrack', () {
      final clip = _videoClip();
      final m = Map<Object?, Object?>.from(clip.toMap());
      // Inject malformed transformTrack (empty keyframes)
      m['transformTrack'] = {
        'interpolation': 'linear',
        'anchorX': 0.5,
        'anchorY': 0.5,
        'keyframes': <dynamic>[],
      };
      expect(VGClipDescriptor.fromMap(m), isNull);
    });

    test('TCD-8 copyWith preserves transformTrack when not overridden', () {
      final track = _singleKeyframeTrack();
      final clip = _videoClip(transformTrack: track);
      final copy = clip.copyWith(id: 'clip-02');
      expect(copy.transformTrack, equals(track));
    });

    test('TCD-9 copyWith can update transformTrack', () {
      final original = _videoClip(transformTrack: _singleKeyframeTrack());
      final newTrack = VGTransformTrackDescriptor(
        keyframes: [
          VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 2.0),
        ],
        interpolation: VGKeyframeInterpolation.hold,
      );
      final copy = original.copyWith(transformTrack: newTrack);
      expect(copy.transformTrack!.interpolation, VGKeyframeInterpolation.hold);
      expect(copy.transformTrack!.keyframes[0].scaleX, 2.0);
    });

    test('TCD-10 copyWith can clear transformTrack to null via sentinel', () {
      final original = _videoClip(transformTrack: _singleKeyframeTrack());
      final copy = original.copyWith(transformTrack: null);
      expect(copy.transformTrack, isNull);
    });

    test('TCD-11 transformTrack is included in equality check', () {
      final a = _videoClip();
      final b = _videoClip(transformTrack: _singleKeyframeTrack());
      expect(a == b, isFalse);
    });

    test('TCD-12 clips with identical transformTrack are equal', () {
      final a = _videoClip(transformTrack: _singleKeyframeTrack());
      final b = _videoClip(transformTrack: _singleKeyframeTrack());
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('TCD-13 existing static transform field unaffected by transformTrack addition', () {
      const td = VGClipTransformDescriptor(scaleX: 0.5);
      final clip = _videoClip(transform: td, transformTrack: _singleKeyframeTrack());
      expect(clip.transform, equals(td));       // static transform preserved
      expect(clip.transformTrack, isNotNull);   // keyframe track also present
    });

    test('TCD-14 existing clip without transformTrack round-trips with no regression', () {
      final clip = VGClipDescriptor(
        id: 'compat-01',
        sourcePath: '/tmp/video.mp4',
        mediaKind: VGMediaKind.video,
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 5.0,
        speed: 1.0,
      );
      final clone = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(clip.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!.id, clip.id);
      expect(clone.transformTrack, isNull);
      expect(clone.transform, isNull);
    });
  });
}
