// vg_editor_draft_test.dart
// Vanguard Media Engine — Phase 7 Stage 7.7
//
// Pure Dart unit tests for VGEditorDraft.
//
// Tests:
//   - Construction validation (id, clips, canvas, fps)
//   - Clip ID uniqueness
//   - Transition reference validation
//   - durationSeconds computation
//   - toMap / fromMap round-trip
//   - copyWith mutations
//   - equality / hashCode

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_transition_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';

// ── Test fixtures ─────────────────────────────────────────────────────────────

VGClipDescriptor _clip({
  String id = 'clip-A',
  String sourcePath = '/tmp/clip_a.mp4',
  double trimStart = 0.0,
  double trimEnd = 5.0,
  double duration = 5.0,
  double speed = 1.0,
}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: sourcePath,
      durationSeconds: duration,
      trimStartSeconds: trimStart,
      trimEndSeconds: trimEnd,
      speed: speed,
    );

VGEditorDraft _draft({
  String id = 'draft-001',
  List<VGClipDescriptor>? clips,
  List<VGTransitionDescriptor> transitions = const [],
  int canvasWidth = 640,
  int canvasHeight = 360,
  int fps = 30,
}) =>
    VGEditorDraft(
      id: id,
      clips: clips ?? [_clip(id: 'clip-A'), _clip(id: 'clip-B')],
      transitions: transitions,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // Construction validation
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — construction validation', () {
    test('ED-1  valid draft constructs without error', () {
      expect(() => _draft(), returnsNormally);
    });

    test('ED-2  empty id throws AssertionError', () {
      expect(
        () => VGEditorDraft(
          id: '',
          clips: [_clip()],
        ),
        throwsAssertionError,
      );
    });

    test('ED-3  empty clips throws AssertionError', () {
      expect(
        () => VGEditorDraft(id: 'x', clips: const []),
        throwsAssertionError,
      );
    });

    test('ED-4  canvasWidth == 0 throws AssertionError', () {
      expect(
        () => _draft(canvasWidth: 0),
        throwsAssertionError,
      );
    });

    test('ED-5  canvasHeight == 0 throws AssertionError', () {
      expect(
        () => _draft(canvasHeight: 0),
        throwsAssertionError,
      );
    });

    test('ED-6  fps == 0 throws AssertionError', () {
      expect(
        () => _draft(fps: 0),
        throwsAssertionError,
      );
    });

    test('ED-7  negative canvasWidth throws AssertionError', () {
      expect(
        () => _draft(canvasWidth: -1),
        throwsAssertionError,
      );
    });

    test('ED-8  negative fps throws AssertionError', () {
      expect(
        () => _draft(fps: -1),
        throwsAssertionError,
      );
    });

    test('ED-9  single clip is valid', () {
      final d = VGEditorDraft(id: 'x', clips: [_clip()]);
      expect(d.clips.length, 1);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Clip ID uniqueness
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — clip ID uniqueness', () {
    test('ED-10 unique clip IDs are valid', () {
      expect(
        () => _draft(clips: [
          _clip(id: 'clip-A'),
          _clip(id: 'clip-B'),
        ]),
        returnsNormally,
      );
    });

    test('ED-11 duplicate clip ID throws AssertionError', () {
      expect(
        () => VGEditorDraft(
          id: 'd',
          clips: [
            _clip(id: 'clip-X'),
            _clip(id: 'clip-X'), // duplicate
          ],
        ),
        throwsAssertionError,
      );
    });

    test('ED-12 three clips with unique IDs are valid', () {
      expect(
        () => VGEditorDraft(
          id: 'd',
          clips: [
            _clip(id: 'A'),
            _clip(id: 'B'),
            _clip(id: 'C'),
          ],
        ),
        returnsNormally,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Transition reference validation
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — transition reference validation', () {
    test('ED-13 empty transitions are valid', () {
      expect(() => _draft(transitions: const []), returnsNormally);
    });

    test('ED-14 transition with null clip refs is valid (Stage 7.1 compat)', () {
      final t = VGTransitionDescriptor(
        id: 'tr-1',
        type: VGTransitionType.none,
        durationSeconds: 0.0,
        // fromClipId and toClipId are null
      );
      expect(() => _draft(transitions: [t]), returnsNormally);
    });

    test('ED-15 transition with valid clip refs is valid', () {
      final t = VGTransitionDescriptor(
        id: 'tr-1',
        type: VGTransitionType.none,
        durationSeconds: 0.0,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
      );
      expect(() => _draft(transitions: [t]), returnsNormally);
    });

    test('ED-16 transition with unknown fromClipId throws AssertionError', () {
      final t = VGTransitionDescriptor(
        id: 'tr-1',
        type: VGTransitionType.none,
        durationSeconds: 0.0,
        fromClipId: 'clip-UNKNOWN',
        toClipId: 'clip-B',
      );
      expect(() => _draft(transitions: [t]), throwsAssertionError);
    });

    test('ED-17 transition with unknown toClipId throws AssertionError', () {
      final t = VGTransitionDescriptor(
        id: 'tr-1',
        type: VGTransitionType.none,
        durationSeconds: 0.0,
        fromClipId: 'clip-A',
        toClipId: 'clip-UNKNOWN',
      );
      expect(() => _draft(transitions: [t]), throwsAssertionError);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // durationSeconds
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — durationSeconds', () {
    test('ED-18 two 5s clips → 10s total', () {
      final d = _draft(clips: [
        _clip(id: 'A', trimStart: 0.0, trimEnd: 5.0),
        _clip(id: 'B', trimStart: 0.0, trimEnd: 5.0),
      ]);
      expect(d.durationSeconds, closeTo(10.0, 0.001));
    });

    test('ED-19 trimmed clip A to 3s + full clip B → 8s', () {
      final d = _draft(clips: [
        _clip(id: 'A', trimStart: 1.0, trimEnd: 4.0), // 3s
        _clip(id: 'B', trimStart: 0.0, trimEnd: 5.0), // 5s
      ]);
      expect(d.durationSeconds, closeTo(8.0, 0.001));
    });

    test('ED-20 both clips trimmed to 3s → 6s', () {
      final d = _draft(clips: [
        _clip(id: 'A', trimStart: 1.0, trimEnd: 4.0), // 3s
        _clip(id: 'B', trimStart: 1.0, trimEnd: 4.0), // 3s
      ]);
      expect(d.durationSeconds, closeTo(6.0, 0.001));
    });

    test('ED-21 single clip with speed 2× halves timeline contribution', () {
      final d = VGEditorDraft(
        id: 'x',
        clips: [_clip(id: 'A', trimStart: 0.0, trimEnd: 4.0, speed: 2.0)],
      );
      // timelineDuration = trimDuration / speed = 4.0 / 2.0 = 2.0
      expect(d.durationSeconds, closeTo(2.0, 0.001));
    });

    test('ED-22 single clip with speed 0.5 doubles timeline contribution', () {
      final d = VGEditorDraft(
        id: 'x',
        clips: [_clip(id: 'A', trimStart: 0.0, trimEnd: 4.0, speed: 0.5)],
      );
      // timelineDuration = 4.0 / 0.5 = 8.0
      expect(d.durationSeconds, closeTo(8.0, 0.001));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // toMap / fromMap round-trip
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — toMap/fromMap round-trip', () {
    test('ED-23 round-trip preserves all fields', () {
      final original = _draft(
        id: 'rt-test',
        clips: [
          _clip(id: 'A', trimStart: 1.0, trimEnd: 4.0),
          _clip(id: 'B', trimStart: 0.0, trimEnd: 5.0),
        ],
        canvasWidth: 1920,
        canvasHeight: 1080,
        fps: 60,
      );
      final map = original.toMap();
      final restored = VGEditorDraft.fromMap(
        map.map((k, v) => MapEntry<Object?, Object?>(k, v)),
      );

      expect(restored, isNotNull);
      expect(restored!.id, original.id);
      expect(restored.clips.length, original.clips.length);
      expect(restored.clips[0].id, 'A');
      expect(restored.clips[0].trimStartSeconds, 1.0);
      expect(restored.clips[0].trimEndSeconds, 4.0);
      expect(restored.clips[1].id, 'B');
      expect(restored.canvasWidth, 1920);
      expect(restored.canvasHeight, 1080);
      expect(restored.fps, 60);
    });

    test('ED-24 toMap shape is JSON-compatible', () {
      final d = _draft();
      final map = d.toMap();
      expect(map['id'], isA<String>());
      expect(map['clips'], isA<List>());
      expect(map['transitions'], isA<List>());
      expect(map['canvasWidth'], isA<int>());
      expect(map['canvasHeight'], isA<int>());
      expect(map['fps'], isA<int>());
    });

    test('ED-25 fromMap returns null for missing id', () {
      final result = VGEditorDraft.fromMap({
        'clips': <dynamic>[
          _clip().toMap(),
        ],
        'canvasWidth': 640,
        'canvasHeight': 360,
        'fps': 30,
      });
      expect(result, isNull);
    });

    test('ED-26 fromMap returns null for empty clips', () {
      final result = VGEditorDraft.fromMap({
        'id': 'x',
        'clips': <dynamic>[],
        'canvasWidth': 640,
        'canvasHeight': 360,
        'fps': 30,
      });
      expect(result, isNull);
    });

    test('ED-27 fromMap returns null for invalid canvasWidth', () {
      final result = VGEditorDraft.fromMap({
        'id': 'x',
        'clips': [_clip().toMap()],
        'canvasWidth': 0,
        'canvasHeight': 360,
        'fps': 30,
      });
      expect(result, isNull);
    });

    test('ED-28 fromMap uses defaults for missing optional fields', () {
      final result = VGEditorDraft.fromMap({
        'id': 'x',
        'clips': [_clip().toMap()],
        // canvasWidth/Height/fps omitted → use defaults
      });
      expect(result, isNotNull);
      expect(result!.canvasWidth, 640);
      expect(result.canvasHeight, 360);
      expect(result.fps, 30);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // copyWith
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — copyWith', () {
    test('ED-29 copyWith replaces id', () {
      final d = _draft(id: 'original');
      final d2 = d.copyWith(id: 'modified');
      expect(d2.id, 'modified');
      expect(d.id, 'original'); // immutable original
    });

    test('ED-30 copyWith replaces clips', () {
      final d = _draft();
      final d2 = d.copyWith(
        clips: [_clip(id: 'A', trimStart: 1.0, trimEnd: 4.0)],
      );
      expect(d2.clips.length, 1);
      expect(d2.clips[0].trimStartSeconds, 1.0);
    });

    test('ED-31 copyWith replaces canvasWidth', () {
      final d = _draft(canvasWidth: 640);
      final d2 = d.copyWith(canvasWidth: 1920);
      expect(d2.canvasWidth, 1920);
      expect(d.canvasWidth, 640); // original unchanged
    });

    test('ED-32 copyWith without args produces equal draft', () {
      final d = _draft();
      final d2 = d.copyWith();
      expect(d2, d);
    });

    test('ED-33 copyWith durationSeconds updates correctly after clip change', () {
      final d = _draft(clips: [
        _clip(id: 'A', trimStart: 0.0, trimEnd: 5.0),
        _clip(id: 'B', trimStart: 0.0, trimEnd: 5.0),
      ]);
      expect(d.durationSeconds, closeTo(10.0, 0.001));

      final d2 = d.copyWith(clips: [
        _clip(id: 'A', trimStart: 1.0, trimEnd: 4.0), // 3s
        _clip(id: 'B', trimStart: 1.0, trimEnd: 4.0), // 3s
      ]);
      expect(d2.durationSeconds, closeTo(6.0, 0.001));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Equality and hashCode
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — equality and hashCode', () {
    test('ED-34 equal drafts with same content are equal', () {
      final a = _draft(id: 'x');
      final b = _draft(id: 'x');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('ED-35 drafts with different ids are not equal', () {
      final a = _draft(id: 'a');
      final b = _draft(id: 'b');
      expect(a == b, isFalse);
    });

    test('ED-36 drafts with different clips are not equal', () {
      final a = _draft(clips: [_clip(id: 'A', trimEnd: 5.0)]);
      final b = _draft(clips: [_clip(id: 'A', trimEnd: 4.0)]);
      expect(a == b, isFalse);
    });

    test('ED-37 drafts with different canvasWidth are not equal', () {
      final a = _draft(canvasWidth: 640);
      final b = _draft(canvasWidth: 1920);
      expect(a == b, isFalse);
    });

    test('ED-38 drafts with different fps are not equal', () {
      final a = _draft(fps: 30);
      final b = _draft(fps: 60);
      expect(a == b, isFalse);
    });

    test('ED-39 clips list is unmodifiable', () {
      final d = _draft();
      expect(
        () => (d.clips as List).add(_clip(id: 'C')),
        throwsUnsupportedError,
      );
    });

    test('ED-40 transitions list is unmodifiable', () {
      final d = _draft();
      expect(
        () => (d.transitions as List).add(
          VGTransitionDescriptor(id: 'tr-x', durationSeconds: 0.0),
        ),
        throwsUnsupportedError,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // sequentialWithTransitions factory (Phase 7.10 / DEC-143)
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — sequentialWithTransitions (Phase 7.10)', () {
    test('ED-41 no transitions: clips are placed sequentially (same as hard-cut)', () {
      // Without any transitions, cursor advances by full timelineDuration each clip.
      final d = VGEditorDraft.sequentialWithTransitions(
        id: 'test-41',
        clips: [
          _clip(id: 'A', trimStart: 0.0, trimEnd: 4.0),
          _clip(id: 'B', trimStart: 0.0, trimEnd: 3.0),
        ],
      );
      expect(d.clips[0].startTimeSeconds, closeTo(0.0, 0.001));
      expect(d.clips[1].startTimeSeconds, closeTo(4.0, 0.001));
      expect(d.durationSeconds, closeTo(7.0, 0.001));
    });

    test('ED-42 single dissolve: clip B start is shifted back by transition overlap', () {
      // Dissolve of 0.5s: clipA (5s) overlaps clipB (5s) by 0.5s.
      // clipA.startTimeSeconds = 0.0
      // clipB.startTimeSeconds = 5.0 - 0.5 = 4.5
      final tr = VGTransitionDescriptor(
        id: 'tr-AB',
        type: VGTransitionType.dissolve,
        durationSeconds: 0.5,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
      );
      final d = VGEditorDraft.sequentialWithTransitions(
        id: 'test-42',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [tr],
      );
      expect(d.clips[0].startTimeSeconds, closeTo(0.0, 0.001));
      expect(d.clips[1].startTimeSeconds, closeTo(4.5, 0.001));
    });

    test('ED-43 durationSeconds subtracts single dissolve overlap', () {
      // Two 5s clips with a 0.5s dissolve: total = 10.0 - 0.5 = 9.5s
      final tr = VGTransitionDescriptor(
        id: 'tr-AB',
        type: VGTransitionType.dissolve,
        durationSeconds: 0.5,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
      );
      final d = VGEditorDraft.sequentialWithTransitions(
        id: 'test-43',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [tr],
      );
      expect(d.durationSeconds, closeTo(9.5, 0.001));
    });

    test('ED-44 durationSeconds subtracts multiple dissolve overlaps', () {
      // Three 5s clips with 0.5s dissolves between each:
      // total = 15.0 - 0.5 - 0.5 = 14.0s
      final trAB = VGTransitionDescriptor(
        id: 'tr-AB',
        type: VGTransitionType.dissolve,
        durationSeconds: 0.5,
        fromClipId: 'A',
        toClipId: 'B',
      );
      final trBC = VGTransitionDescriptor(
        id: 'tr-BC',
        type: VGTransitionType.dissolve,
        durationSeconds: 0.5,
        fromClipId: 'B',
        toClipId: 'C',
      );
      final d = VGEditorDraft.sequentialWithTransitions(
        id: 'test-44',
        clips: [
          _clip(id: 'A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'B', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'C', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [trAB, trBC],
      );
      expect(d.durationSeconds, closeTo(14.0, 0.001));
      // Also validate startTimeSeconds layout
      expect(d.clips[0].startTimeSeconds, closeTo(0.0, 0.001));
      expect(d.clips[1].startTimeSeconds, closeTo(4.5, 0.001));
      expect(d.clips[2].startTimeSeconds, closeTo(9.0, 0.001));
    });

    test('ED-45 durationSeconds unchanged for hard-cut-only transitions', () {
      // Hard-cut transitions have zero overlap — durationSeconds is unchanged.
      final tr = VGTransitionDescriptor(
        id: 'tr-AB',
        type: VGTransitionType.none,
        durationSeconds: 0.0,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
      );
      final d = VGEditorDraft.sequentialWithTransitions(
        id: 'test-45',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [tr],
      );
      // Hard cut: no overlap subtracted
      expect(d.durationSeconds, closeTo(10.0, 0.001));
      expect(d.clips[1].startTimeSeconds, closeTo(5.0, 0.001));
    });
  });
}
