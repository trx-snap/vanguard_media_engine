// vg_time_remap_descriptor_test.dart
// Vanguard Media Engine — Phase 7.22A
//
// Pure Dart unit tests for VGTimeRemapDescriptor, VGSpeedSegmentDescriptor,
// and VGTimeRemapAudioPolicy. Also covers VGClipDescriptor.timeRemap
// integration (serialization, fromMap, copyWith, backward compatibility).
//
// No Flutter engine or native code required — runs in `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_time_remap_descriptor.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// A minimal valid video clip descriptor for reuse across tests.
VGClipDescriptor _videoClip({
  String id = 'clip-01',
  String sourcePath = '/tmp/recording.mp4',
  double durationSeconds = 10.0,
  double trimStart = 0.0,
  double trimEnd = 10.0,
  double speed = 1.0,
  VGTimeRemapDescriptor? timeRemap,
}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: sourcePath,
      mediaKind: VGMediaKind.video,
      durationSeconds: durationSeconds,
      trimStartSeconds: trimStart,
      trimEndSeconds: trimEnd,
      speed: speed,
      timeRemap: timeRemap,
    );

/// A minimal valid VGSpeedSegmentDescriptor.
VGSpeedSegmentDescriptor _seg({
  double start = 0.0,
  double duration = 2.0,
  double speed = 1.0,
}) =>
    VGSpeedSegmentDescriptor(
      sourceStartTime: start,
      sourceDuration: duration,
      speedMultiplier: speed,
    );

/// A minimal valid VGTimeRemapDescriptor with a single 1× segment.
VGTimeRemapDescriptor _singleSegRemap({
  VGTimeRemapAudioPolicy audioPolicy = VGTimeRemapAudioPolicy.mute,
}) =>
    VGTimeRemapDescriptor(
      segments: [_seg()],
      audioPolicy: audioPolicy,
    );

void main() {
  // ── VGTimeRemapAudioPolicy ─────────────────────────────────────────────────

  group('VGTimeRemapAudioPolicy — wire values', () {
    test('TR-AP-1 mute serializes to "mute"', () {
      expect(VGTimeRemapAudioPolicy.mute.value, 'mute');
    });

    test('TR-AP-2 reject serializes to "reject"', () {
      expect(VGTimeRemapAudioPolicy.reject.value, 'reject');
    });

    test('TR-AP-3 preserveOriginalWhenSpeedIs1 serializes correctly', () {
      expect(
        VGTimeRemapAudioPolicy.preserveOriginalWhenSpeedIs1.value,
        'preserveOriginalWhenSpeedIs1',
      );
    });

    test('TR-AP-4 offlineRetimeIfSupported serializes correctly', () {
      expect(
        VGTimeRemapAudioPolicy.offlineRetimeIfSupported.value,
        'offlineRetimeIfSupported',
      );
    });

    test('TR-AP-5 deferToFullAudioGraph serializes correctly', () {
      expect(
        VGTimeRemapAudioPolicy.deferToFullAudioGraph.value,
        'deferToFullAudioGraph',
      );
    });

    test('TR-AP-6 fromValue resolves known values correctly', () {
      expect(
        VGTimeRemapAudioPolicy.fromValue('mute'),
        VGTimeRemapAudioPolicy.mute,
      );
      expect(
        VGTimeRemapAudioPolicy.fromValue('reject'),
        VGTimeRemapAudioPolicy.reject,
      );
      expect(
        VGTimeRemapAudioPolicy.fromValue('preserveOriginalWhenSpeedIs1'),
        VGTimeRemapAudioPolicy.preserveOriginalWhenSpeedIs1,
      );
      expect(
        VGTimeRemapAudioPolicy.fromValue('offlineRetimeIfSupported'),
        VGTimeRemapAudioPolicy.offlineRetimeIfSupported,
      );
      expect(
        VGTimeRemapAudioPolicy.fromValue('deferToFullAudioGraph'),
        VGTimeRemapAudioPolicy.deferToFullAudioGraph,
      );
    });

    test('TR-AP-7 fromValue falls back to mute for unknown strings', () {
      expect(
        VGTimeRemapAudioPolicy.fromValue('unknownPolicy'),
        VGTimeRemapAudioPolicy.mute,
      );
      expect(
        VGTimeRemapAudioPolicy.fromValue(''),
        VGTimeRemapAudioPolicy.mute,
      );
    });
  });

  // ── VGSpeedSegmentDescriptor — construction ────────────────────────────────

  group('VGSpeedSegmentDescriptor — construction validation', () {
    test('TR-SS-1 valid segment is constructible', () {
      final seg = VGSpeedSegmentDescriptor(
        sourceStartTime: 0.0,
        sourceDuration: 2.0,
        speedMultiplier: 1.5,
      );
      expect(seg.sourceStartTime, 0.0);
      expect(seg.sourceDuration, 2.0);
      expect(seg.speedMultiplier, 1.5);
    });

    test('TR-SS-2 sourceEndTime equals start + duration', () {
      final seg = _seg(start: 1.0, duration: 3.0);
      expect(seg.sourceEndTime, closeTo(4.0, 1e-10));
    });

    test('TR-SS-3 sourceStartTime = 0 is valid (boundary)', () {
      expect(() => _seg(start: 0.0), returnsNormally);
    });

    test('TR-SS-4 negative sourceStartTime triggers assert', () {
      expect(
        () => VGSpeedSegmentDescriptor(
          sourceStartTime: -0.001,
          sourceDuration: 1.0,
          speedMultiplier: 1.0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TR-SS-5 zero sourceDuration triggers assert', () {
      expect(
        () => VGSpeedSegmentDescriptor(
          sourceStartTime: 0.0,
          sourceDuration: 0.0,
          speedMultiplier: 1.0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TR-SS-6 negative sourceDuration triggers assert', () {
      expect(
        () => VGSpeedSegmentDescriptor(
          sourceStartTime: 0.0,
          sourceDuration: -1.0,
          speedMultiplier: 1.0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TR-SS-7 zero speedMultiplier triggers assert', () {
      expect(
        () => VGSpeedSegmentDescriptor(
          sourceStartTime: 0.0,
          sourceDuration: 1.0,
          speedMultiplier: 0.0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TR-SS-8 negative speedMultiplier triggers assert', () {
      expect(
        () => VGSpeedSegmentDescriptor(
          sourceStartTime: 0.0,
          sourceDuration: 1.0,
          speedMultiplier: -1.0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  // ── VGSpeedSegmentDescriptor — serialization ───────────────────────────────

  group('VGSpeedSegmentDescriptor — serialization', () {
    test('TR-SS-9 toMap() produces correct wire format', () {
      final seg = VGSpeedSegmentDescriptor(
        sourceStartTime: 1.0,
        sourceDuration: 3.0,
        speedMultiplier: 0.5,
      );
      final m = seg.toMap();
      expect(m['sourceStartTime'], 1.0);
      expect(m['sourceDuration'], 3.0);
      expect(m['speedMultiplier'], 0.5);
    });

    test('TR-SS-10 fromMap() round-trips correctly', () {
      final original = _seg(start: 2.0, duration: 4.0, speed: 2.0);
      final m = original.toMap();
      final clone =
          VGSpeedSegmentDescriptor.fromMap(m.cast<Object?, Object?>());
      expect(clone, isNotNull);
      expect(clone!.sourceStartTime, original.sourceStartTime);
      expect(clone.sourceDuration, original.sourceDuration);
      expect(clone.speedMultiplier, original.speedMultiplier);
    });

    test('TR-SS-11 fromMap() returns null when sourceStartTime is missing', () {
      final m = <Object?, Object?>{
        'sourceDuration': 2.0,
        'speedMultiplier': 1.0,
      };
      expect(VGSpeedSegmentDescriptor.fromMap(m), isNull);
    });

    test('TR-SS-12 fromMap() returns null when sourceDuration is zero', () {
      final m = <Object?, Object?>{
        'sourceStartTime': 0.0,
        'sourceDuration': 0.0,
        'speedMultiplier': 1.0,
      };
      expect(VGSpeedSegmentDescriptor.fromMap(m), isNull);
    });

    test('TR-SS-13 fromMap() returns null when speedMultiplier is negative', () {
      final m = <Object?, Object?>{
        'sourceStartTime': 0.0,
        'sourceDuration': 2.0,
        'speedMultiplier': -1.0,
      };
      expect(VGSpeedSegmentDescriptor.fromMap(m), isNull);
    });

    test('TR-SS-14 fromMap() accepts num types (int) for double fields', () {
      final m = <Object?, Object?>{
        'sourceStartTime': 0,
        'sourceDuration': 2,
        'speedMultiplier': 1,
      };
      final seg = VGSpeedSegmentDescriptor.fromMap(m);
      expect(seg, isNotNull);
      expect(seg!.sourceStartTime, 0.0);
    });
  });

  // ── VGSpeedSegmentDescriptor — equality ───────────────────────────────────

  group('VGSpeedSegmentDescriptor — equality and hashCode', () {
    test('TR-SS-15 equal segments are equal', () {
      final a = _seg(start: 1.0, duration: 2.0, speed: 1.5);
      final b = _seg(start: 1.0, duration: 2.0, speed: 1.5);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('TR-SS-16 segments with different speed are not equal', () {
      final a = _seg(speed: 1.0);
      final b = _seg(speed: 2.0);
      expect(a == b, isFalse);
    });
  });

  // ── VGTimeRemapDescriptor — construction ──────────────────────────────────

  group('VGTimeRemapDescriptor — construction validation', () {
    test('TR-TRD-1 valid single-segment remap is constructible', () {
      final remap = _singleSegRemap();
      expect(remap.segments, hasLength(1));
      expect(remap.audioPolicy, VGTimeRemapAudioPolicy.mute);
    });

    test('TR-TRD-2 multiple non-overlapping sorted segments are valid', () {
      final remap = VGTimeRemapDescriptor(
        segments: [
          _seg(start: 0.0, duration: 2.0, speed: 0.5),
          _seg(start: 2.0, duration: 3.0, speed: 2.0),
          _seg(start: 5.0, duration: 1.0, speed: 1.0),
        ],
      );
      expect(remap.segments, hasLength(3));
    });

    test('TR-TRD-3 empty segments list triggers assert', () {
      expect(
        () => VGTimeRemapDescriptor(segments: []),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TR-TRD-4 overlapping segments trigger assert', () {
      expect(
        () => VGTimeRemapDescriptor(
          segments: [
            _seg(start: 0.0, duration: 3.0, speed: 1.0), // ends at 3.0
            _seg(start: 2.0, duration: 2.0, speed: 2.0), // starts at 2.0 < 3.0
          ],
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TR-TRD-5 out-of-order segments trigger assert', () {
      expect(
        () => VGTimeRemapDescriptor(
          segments: [
            _seg(start: 5.0, duration: 1.0, speed: 1.0),
            _seg(start: 0.0, duration: 2.0, speed: 1.0),
          ],
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('TR-TRD-6 segments list is immutable after construction', () {
      final remap = _singleSegRemap();
      expect(
        () => (remap.segments as List).add(_seg(start: 5.0, duration: 1.0)),
        throwsUnsupportedError,
      );
    });

    test('TR-TRD-7 audioPolicy defaults to mute', () {
      final remap = VGTimeRemapDescriptor(segments: [_seg()]);
      expect(remap.audioPolicy, VGTimeRemapAudioPolicy.mute);
    });

    test('TR-TRD-8 all audioPolicy values are accepted in construction', () {
      for (final policy in VGTimeRemapAudioPolicy.values) {
        expect(
          () => VGTimeRemapDescriptor(segments: [_seg()], audioPolicy: policy),
          returnsNormally,
        );
      }
    });

    test('TR-TRD-9 gap between segments is valid (contiguity NOT required)', () {
      // Segments [0, 2) and [3, 5) have a gap at [2, 3) — this is allowed.
      expect(
        () => VGTimeRemapDescriptor(
          segments: [
            _seg(start: 0.0, duration: 2.0, speed: 1.0),
            _seg(start: 3.0, duration: 2.0, speed: 2.0),
          ],
        ),
        returnsNormally,
      );
    });
  });

  // ── VGTimeRemapDescriptor — serialization ─────────────────────────────────

  group('VGTimeRemapDescriptor — serialization', () {
    test('TR-TRD-10 toMap() produces correct wire format', () {
      final remap = VGTimeRemapDescriptor(
        segments: [_seg(start: 0.0, duration: 2.0, speed: 1.5)],
        audioPolicy: VGTimeRemapAudioPolicy.reject,
      );
      final m = remap.toMap();
      expect(m['audioPolicy'], 'reject');
      final segs = m['segments'] as List;
      expect(segs, hasLength(1));
      final seg = segs[0] as Map;
      expect(seg['sourceStartTime'], 0.0);
      expect(seg['sourceDuration'], 2.0);
      expect(seg['speedMultiplier'], 1.5);
    });

    test('TR-TRD-11 fromMap() round-trips a single segment correctly', () {
      final original = VGTimeRemapDescriptor(
        segments: [_seg(start: 0.0, duration: 4.0, speed: 0.25)],
        audioPolicy: VGTimeRemapAudioPolicy.preserveOriginalWhenSpeedIs1,
      );
      final m = original.toMap();
      final clone = VGTimeRemapDescriptor.fromMap(m.cast<Object?, Object?>());
      expect(clone, isNotNull);
      expect(clone!.segments, hasLength(1));
      expect(clone.segments[0].sourceStartTime, 0.0);
      expect(clone.segments[0].sourceDuration, 4.0);
      expect(clone.segments[0].speedMultiplier, 0.25);
      expect(clone.audioPolicy, VGTimeRemapAudioPolicy.preserveOriginalWhenSpeedIs1);
    });

    test('TR-TRD-12 fromMap() round-trips multiple segments', () {
      final original = VGTimeRemapDescriptor(
        segments: [
          _seg(start: 0.0, duration: 2.0, speed: 0.5),
          _seg(start: 2.0, duration: 3.0, speed: 2.0),
        ],
        audioPolicy: VGTimeRemapAudioPolicy.mute,
      );
      final clone = VGTimeRemapDescriptor.fromMap(
        original.toMap().cast<Object?, Object?>(),
      );
      expect(clone, isNotNull);
      expect(clone!.segments, hasLength(2));
      expect(clone.segments[1].speedMultiplier, 2.0);
    });

    test('TR-TRD-13 fromMap() returns null when segments key is missing', () {
      final m = <Object?, Object?>{'audioPolicy': 'mute'};
      expect(VGTimeRemapDescriptor.fromMap(m), isNull);
    });

    test('TR-TRD-14 fromMap() returns null when segments list is empty', () {
      final m = <Object?, Object?>{'segments': <dynamic>[], 'audioPolicy': 'mute'};
      expect(VGTimeRemapDescriptor.fromMap(m), isNull);
    });

    test('TR-TRD-15 fromMap() returns null when a segment is malformed', () {
      final m = <Object?, Object?>{
        'segments': [
          {'sourceStartTime': 0.0, 'sourceDuration': -1.0, 'speedMultiplier': 1.0},
        ],
        'audioPolicy': 'mute',
      };
      expect(VGTimeRemapDescriptor.fromMap(m), isNull);
    });

    test('TR-TRD-16 fromMap() returns null for overlapping segments', () {
      final m = <Object?, Object?>{
        'segments': [
          {'sourceStartTime': 0.0, 'sourceDuration': 3.0, 'speedMultiplier': 1.0},
          {'sourceStartTime': 2.0, 'sourceDuration': 2.0, 'speedMultiplier': 2.0},
        ],
        'audioPolicy': 'mute',
      };
      expect(VGTimeRemapDescriptor.fromMap(m), isNull);
    });

    test('TR-TRD-17 fromMap() defaults audioPolicy to mute when absent', () {
      final m = <Object?, Object?>{
        'segments': [
          {'sourceStartTime': 0.0, 'sourceDuration': 2.0, 'speedMultiplier': 1.0},
        ],
      };
      final remap = VGTimeRemapDescriptor.fromMap(m);
      expect(remap, isNotNull);
      expect(remap!.audioPolicy, VGTimeRemapAudioPolicy.mute);
    });

    test('TR-TRD-18 fromMap() defaults audioPolicy to mute for unknown string', () {
      final m = <Object?, Object?>{
        'segments': [
          {'sourceStartTime': 0.0, 'sourceDuration': 2.0, 'speedMultiplier': 1.0},
        ],
        'audioPolicy': 'futureUnknownPolicy',
      };
      final remap = VGTimeRemapDescriptor.fromMap(m);
      expect(remap, isNotNull);
      expect(remap!.audioPolicy, VGTimeRemapAudioPolicy.mute);
    });
  });

  // ── VGTimeRemapDescriptor — equality ─────────────────────────────────────

  group('VGTimeRemapDescriptor — equality and hashCode', () {
    test('TR-TRD-19 identical remaps are equal', () {
      final a = _singleSegRemap();
      final b = _singleSegRemap();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('TR-TRD-20 remaps with different audioPolicy are not equal', () {
      final a = _singleSegRemap(audioPolicy: VGTimeRemapAudioPolicy.mute);
      final b = _singleSegRemap(audioPolicy: VGTimeRemapAudioPolicy.reject);
      expect(a == b, isFalse);
    });

    test('TR-TRD-21 remaps with different segment counts are not equal', () {
      final a = VGTimeRemapDescriptor(segments: [_seg()]);
      final b = VGTimeRemapDescriptor(
        segments: [_seg(), _seg(start: 2.0, duration: 1.0)],
      );
      expect(a == b, isFalse);
    });
  });

  // ── VGClipDescriptor — timeRemap integration ──────────────────────────────

  group('VGClipDescriptor — timeRemap field (Phase 7.22A)', () {
    test('TR-CD-1 default clip has timeRemap == null', () {
      final clip = _videoClip();
      expect(clip.timeRemap, isNull);
    });

    test('TR-CD-2 clip with timeRemap stores it correctly', () {
      final remap = _singleSegRemap();
      final clip = _videoClip(timeRemap: remap);
      expect(clip.timeRemap, isNotNull);
      expect(clip.timeRemap!.segments, hasLength(1));
      expect(clip.timeRemap!.audioPolicy, VGTimeRemapAudioPolicy.mute);
    });

    test('TR-CD-3 toMap() omits timeRemap when null', () {
      final clip = _videoClip();
      expect(clip.toMap().containsKey('timeRemap'), isFalse);
    });

    test('TR-CD-4 toMap() includes timeRemap when non-null', () {
      final remap = _singleSegRemap(audioPolicy: VGTimeRemapAudioPolicy.reject);
      final clip = _videoClip(timeRemap: remap);
      final m = clip.toMap();
      expect(m.containsKey('timeRemap'), isTrue);
      final remapMap = m['timeRemap'] as Map;
      expect(remapMap['audioPolicy'], 'reject');
    });

    test('TR-CD-5 fromMap() round-trips clip with timeRemap', () {
      final remap = VGTimeRemapDescriptor(
        segments: [_seg(start: 0.0, duration: 5.0, speed: 2.0)],
        audioPolicy: VGTimeRemapAudioPolicy.offlineRetimeIfSupported,
      );
      final original = _videoClip(timeRemap: remap);
      final clone = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(original.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!.timeRemap, isNotNull);
      expect(clone.timeRemap!.segments[0].speedMultiplier, 2.0);
      expect(
        clone.timeRemap!.audioPolicy,
        VGTimeRemapAudioPolicy.offlineRetimeIfSupported,
      );
    });

    test('TR-CD-6 fromMap() produces null timeRemap when key absent (backward compat)', () {
      final clip = _videoClip(); // no timeRemap
      final m = Map<Object?, Object?>.from(clip.toMap());
      // Confirm key is absent in wire payload.
      expect(m.containsKey('timeRemap'), isFalse);
      final clone = VGClipDescriptor.fromMap(m);
      expect(clone, isNotNull);
      expect(clone!.timeRemap, isNull);
    });

    test('TR-CD-7 fromMap() returns null for malformed timeRemap map', () {
      final clip = _videoClip();
      final m = Map<Object?, Object?>.from(clip.toMap());
      // Inject a malformed timeRemap (empty segments).
      m['timeRemap'] = {'segments': <dynamic>[], 'audioPolicy': 'mute'};
      expect(VGClipDescriptor.fromMap(m), isNull);
    });

    test('TR-CD-8 copyWith preserves timeRemap when not overridden', () {
      final remap = _singleSegRemap();
      final original = _videoClip(timeRemap: remap);
      final copy = original.copyWith(id: 'clip-02');
      expect(copy.timeRemap, equals(remap));
    });

    test('TR-CD-9 copyWith can update timeRemap to a new descriptor', () {
      final original = _videoClip(timeRemap: _singleSegRemap());
      final newRemap = VGTimeRemapDescriptor(
        segments: [_seg(speed: 2.0)],
        audioPolicy: VGTimeRemapAudioPolicy.reject,
      );
      final copy = original.copyWith(timeRemap: newRemap);
      expect(copy.timeRemap!.audioPolicy, VGTimeRemapAudioPolicy.reject);
    });

    test('TR-CD-10 copyWith can clear timeRemap to null via sentinel', () {
      final original = _videoClip(timeRemap: _singleSegRemap());
      final copy = original.copyWith(timeRemap: null);
      expect(copy.timeRemap, isNull);
    });

    test('TR-CD-11 timeRemap is included in equality check', () {
      final a = _videoClip();
      final b = _videoClip(timeRemap: _singleSegRemap());
      expect(a == b, isFalse);
    });

    test('TR-CD-12 clips with identical timeRemap are equal', () {
      final a = _videoClip(timeRemap: _singleSegRemap());
      final b = _videoClip(timeRemap: _singleSegRemap());
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('TR-CD-13 existing speed field unchanged by timeRemap addition', () {
      // timeRemap does not affect existing speed field — both coexist.
      final remap = _singleSegRemap();
      final clip = _videoClip(speed: 0.5, timeRemap: remap);
      expect(clip.speed, 0.5);
      expect(clip.timeRemap, isNotNull);
    });

    test('TR-CD-14 existing clip round-trip without timeRemap still works', () {
      // Ensures backward compatibility: no timeRemap → no regression.
      final original = VGClipDescriptor(
        id: 'compat-01',
        sourcePath: '/tmp/video.mp4',
        mediaKind: VGMediaKind.video,
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 5.0,
        speed: 1.0,
      );
      final clone = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(original.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!.id, original.id);
      expect(clone.timeRemap, isNull);
      expect(clone.speed, 1.0);
    });
  });

  // ── VGClipDescriptor — timelineDuration with timeRemap (Phase 7.22B) ──────

  group('VGClipDescriptor — timelineDuration (Phase 7.22B)', () {
    test('TR-TLD-1 no timeRemap: timelineDuration == trimDuration / speed', () {
      // Legacy path: speed=2.0, trim [1.0, 5.0] → trimDuration=4.0
      // timelineDuration = 4.0 / 2.0 = 2.0
      final clip = _videoClip(
        trimStart: 1.0,
        trimEnd: 5.0,
        speed: 2.0,
      );
      expect(clip.timelineDuration, closeTo(2.0, 1e-10));
    });

    test('TR-TLD-2 no timeRemap speed=0.5: timelineDuration = trimDuration / 0.5', () {
      // trim [0, 4], speed=0.5 → trimDuration=4.0 → timelineDuration=8.0
      final clip = _videoClip(trimStart: 0.0, trimEnd: 4.0, speed: 0.5);
      expect(clip.timelineDuration, closeTo(8.0, 1e-10));
    });

    test('TR-TLD-3 single segment [0,4) @ 2.0×: timelineDuration == 2.0', () {
      // sourceDuration=4.0, speedMultiplier=2.0 → contribution=4.0/2.0=2.0
      final remap = VGTimeRemapDescriptor(
        segments: [
          VGSpeedSegmentDescriptor(
            sourceStartTime: 0.0,
            sourceDuration: 4.0,
            speedMultiplier: 2.0,
          ),
        ],
      );
      final clip = _videoClip(trimStart: 0.0, trimEnd: 4.0, timeRemap: remap);
      expect(clip.timelineDuration, closeTo(2.0, 1e-10));
    });

    test('TR-TLD-4 two segments [0,2)@0.5× and [2,4)@2.0×: timelineDuration == 5.0', () {
      // seg0: 2.0/0.5 = 4.0; seg1: 2.0/2.0 = 1.0 → total = 5.0
      final remap = VGTimeRemapDescriptor(
        segments: [
          VGSpeedSegmentDescriptor(
            sourceStartTime: 0.0,
            sourceDuration: 2.0,
            speedMultiplier: 0.5,
          ),
          VGSpeedSegmentDescriptor(
            sourceStartTime: 2.0,
            sourceDuration: 2.0,
            speedMultiplier: 2.0,
          ),
        ],
      );
      final clip = _videoClip(trimStart: 0.0, trimEnd: 4.0, timeRemap: remap);
      expect(clip.timelineDuration, closeTo(5.0, 1e-10));
    });

    test('TR-TLD-5 timeRemap supersedes speed for timelineDuration', () {
      // clip.speed=0.5 but timeRemap has one segment [0,4)@1.0×
      // Expected: 4.0/1.0=4.0 (not trimDuration/speed=4.0/0.5=8.0)
      final remap = VGTimeRemapDescriptor(
        segments: [
          VGSpeedSegmentDescriptor(
            sourceStartTime: 0.0,
            sourceDuration: 4.0,
            speedMultiplier: 1.0,
          ),
        ],
      );
      final clip = _videoClip(trimStart: 0.0, trimEnd: 4.0, speed: 0.5, timeRemap: remap);
      expect(clip.timelineDuration, closeTo(4.0, 1e-10));
      // Confirm it is NOT using trimDuration/speed:
      expect(clip.timelineDuration, isNot(closeTo(8.0, 1e-2)));
    });

    test('TR-TLD-6 three-segment remap accumulates correctly', () {
      // seg0: [0,3)@3.0× → 1.0s; seg1: [3,5)@1.0× → 2.0s; seg2: [5,6)@0.5× → 2.0s
      // Total: 5.0s
      final remap = VGTimeRemapDescriptor(
        segments: [
          VGSpeedSegmentDescriptor(
              sourceStartTime: 0.0, sourceDuration: 3.0, speedMultiplier: 3.0),
          VGSpeedSegmentDescriptor(
              sourceStartTime: 3.0, sourceDuration: 2.0, speedMultiplier: 1.0),
          VGSpeedSegmentDescriptor(
              sourceStartTime: 5.0, sourceDuration: 1.0, speedMultiplier: 0.5),
        ],
      );
      final clip = _videoClip(trimStart: 0.0, trimEnd: 6.0, timeRemap: remap);
      expect(clip.timelineDuration, closeTo(5.0, 1e-10));
    });

    test('TR-TLD-7 existing serialization tests unaffected: no regression', () {
      // Regression guard: a clip without timeRemap serializes identically to
      // pre-7.22B behavior.
      final clip = _videoClip(trimStart: 0.0, trimEnd: 6.0, speed: 1.5);
      expect(clip.timelineDuration, closeTo(6.0 / 1.5, 1e-10));
      final clone = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(clip.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!.timelineDuration, closeTo(6.0 / 1.5, 1e-10));
    });
  });
}
