// vg_editor_draft_test.dart
// Vanguard Media Engine — Phase 7 Stage 7.7 / Phase 7.11
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
//   - Phase 7.11: sequentialWithTransitions preserves clip.transform (D6)

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_clip_transform_descriptor.dart';
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

    // ── Phase 7.11 / D6: sequentialWithTransitions must preserve clip.transform ─
    //
    // Audit finding (Gemini Phase 7.11 mechanical audit): the implementation
    // uses copyWith(startTimeSeconds: cursor) which — by design of the sentinel
    // pattern — preserves all other fields including the nullable transform.
    // This test is the explicit proof of that guarantee (DEC-144 / D6).
    test('ED-46 (Phase 7.11 / D6) sequentialWithTransitions preserves clip.transform after startTimeSeconds adjustment', () {
      // Non-identity transform applied to Clip B.
      // All 8 fields deviate from their identity defaults.
      const tdB = VGClipTransformDescriptor(
        scaleX:       0.5,
        scaleY:       0.5,
        translationX: 100.0,
        translationY: 50.0,
        rotation:     0.785, // ~45° clockwise
        opacity:      0.5,
        anchorX:      0.5,
        anchorY:      0.5,
      );

      // Clip A: no transform (null = identity pass-through).
      final clipA = VGClipDescriptor(
        id: 'clip-A-46',
        sourcePath: '/tmp/clip_a_46.mp4',
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 5.0,
      );

      // Clip B: has the non-identity transform.
      final clipB = VGClipDescriptor(
        id: 'clip-B-46',
        sourcePath: '/tmp/clip_b_46.mp4',
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 5.0,
        transform: tdB,
      );

      // 1-second dissolve between A and B.
      // Expected Clip B startTimeSeconds = 5.0 - 1.0 = 4.0.
      final transition = VGTransitionDescriptor(
        id: 'tr-46',
        type: VGTransitionType.dissolve,
        durationSeconds: 1.0,
        fromClipId: 'clip-A-46',
        toClipId:   'clip-B-46',
      );

      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'test-46',
        clips: [clipA, clipB],
        transitions: [transition],
      );

      // ── Timeline layout assertions ──────────────────────────────────────────
      // Clip A starts at time 0.
      expect(draft.clips[0].startTimeSeconds, closeTo(0.0, 1e-9));
      // Clip B is shifted back by the dissolve overlap.
      expect(draft.clips[1].startTimeSeconds, closeTo(4.0, 1e-9));
      // Total duration = 5 + 5 - 1 = 9 seconds.
      expect(draft.durationSeconds, closeTo(9.0, 1e-9));

      // ── Clip A transform is null (unchanged) ────────────────────────────────
      expect(draft.clips[0].transform, isNull);

      // ── D6: Clip B transform is non-null and field values are preserved ─────
      final resultTransform = draft.clips[1].transform;
      expect(resultTransform, isNotNull,
          reason: 'sequentialWithTransitions must not drop clip.transform');
      expect(resultTransform!.scaleX,       closeTo(0.5,   1e-9));
      expect(resultTransform.scaleY,        closeTo(0.5,   1e-9));
      expect(resultTransform.translationX,  closeTo(100.0, 1e-9));
      expect(resultTransform.translationY,  closeTo(50.0,  1e-9));
      expect(resultTransform.rotation,      closeTo(0.785, 1e-9));
      expect(resultTransform.opacity,       closeTo(0.5,   1e-9));
      expect(resultTransform.anchorX,       closeTo(0.5,   1e-9));
      expect(resultTransform.anchorY,       closeTo(0.5,   1e-9));

      // ── Equality check: the preserved descriptor equals the original ─────────
      expect(resultTransform, equals(tdB));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // trimClip (Phase 7.13 / DEC-146)
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — trimClip (Phase 7.13)', () {
    // Shared fixtures.
    // Two 5-second clips with no transitions (hard-cut baseline).
    VGEditorDraft makeTrimDraft() => VGEditorDraft.sequentialWithTransitions(
          id: 'draft-trim',
          clips: [
            _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
            _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
          ],
        );

    // Two 5-second clips with a 1-second dissolve between them.
    VGEditorDraft makeTransitionDraft() {
      final tr = VGTransitionDescriptor(
        id: 'tr-AB',
        type: VGTransitionType.dissolve,
        durationSeconds: 1.0,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
      );
      return VGEditorDraft.sequentialWithTransitions(
        id: 'draft-dissolve',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [tr],
      );
    }

    test('TR-DR1 valid trim updates clip trim values on returned draft', () {
      final draft = makeTrimDraft();
      final trimmed = draft.trimClip(
        clipId: 'clip-A',
        trimStartSeconds: 1.5,
        trimEndSeconds: 4.5,
      );

      // Original draft is immutable — unchanged.
      expect(draft.clips[0].trimStartSeconds, closeTo(0.0, 1e-9));
      expect(draft.clips[0].trimEndSeconds, closeTo(5.0, 1e-9));

      // Returned draft reflects the new trim values.
      expect(trimmed.clips[0].id, 'clip-A');
      expect(trimmed.clips[0].trimStartSeconds, closeTo(1.5, 1e-9));
      expect(trimmed.clips[0].trimEndSeconds, closeTo(4.5, 1e-9));
      // Clip B must be unchanged.
      expect(trimmed.clips[1].trimStartSeconds, closeTo(0.0, 1e-9));
      expect(trimmed.clips[1].trimEndSeconds, closeTo(5.0, 1e-9));
    });

    test('TR-DR2 trim recomputes startTimeSeconds for downstream clip', () {
      final draft = makeTrimDraft();
      // Trim clip A to 3 s (1.0 → 4.0). clip B must shift back.
      final trimmed = draft.trimClip(
        clipId: 'clip-A',
        trimStartSeconds: 1.0,
        trimEndSeconds: 4.0,
      );

      // Clip A starts at 0, timelineDuration = 3s.
      expect(trimmed.clips[0].startTimeSeconds, closeTo(0.0, 1e-9));
      // Clip B must start immediately after clip A (no transition overlap).
      expect(trimmed.clips[1].startTimeSeconds, closeTo(3.0, 1e-9));
      // Total draft duration = 3 + 5 = 8s.
      expect(trimmed.durationSeconds, closeTo(8.0, 1e-9));
    });

    test('TR-DR3 trim preserves transform and other fields on untouched clips', () {
      // Clip B has a non-identity transform.
      const tdB = VGClipTransformDescriptor(
        scaleX: 0.5,
        scaleY: 0.5,
        opacity: 0.75,
      );
      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-tr3',
        clips: [
          VGClipDescriptor(
            id: 'clip-A',
            sourcePath: '/tmp/a.mp4',
            durationSeconds: 5.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 5.0,
          ),
          VGClipDescriptor(
            id: 'clip-B',
            sourcePath: '/tmp/b.mp4',
            durationSeconds: 5.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 5.0,
            transform: tdB,
          ),
        ],
      );

      final trimmed = draft.trimClip(
        clipId: 'clip-A',
        trimStartSeconds: 0.5,
        trimEndSeconds: 4.0,
      );

      // Clip B transform must be preserved exactly.
      expect(trimmed.clips[1].transform, isNotNull);
      expect(trimmed.clips[1].transform!.scaleX, closeTo(0.5, 1e-9));
      expect(trimmed.clips[1].transform!.opacity, closeTo(0.75, 1e-9));
      expect(trimmed.clips[1].transform, equals(tdB));
    });

    test('TR-DR4 trimEndSeconds exceeding durationSeconds throws ArgumentError', () {
      final draft = makeTrimDraft();
      expect(
        () => draft.trimClip(
          clipId: 'clip-A',
          trimStartSeconds: 0.0,
          trimEndSeconds: 6.0, // durationSeconds is 5.0
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TR-DR5 trim duration below 0.1 s minimum throws ArgumentError', () {
      final draft = makeTrimDraft();
      expect(
        () => draft.trimClip(
          clipId: 'clip-A',
          trimStartSeconds: 2.0,
          trimEndSeconds: 2.05, // 0.05s < 0.1s minimum
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TR-DR6 trim shorter than attached transition overlap throws ArgumentError', () {
      // clip A has a 1s dissolve out. Trimming it to exactly 0.9s wall-clock
      // would collapse the transition window.
      final draft = makeTransitionDraft();
      expect(
        () => draft.trimClip(
          clipId: 'clip-A',
          trimStartSeconds: 0.0,
          trimEndSeconds: 0.9, // 0.9s < 1.0s dissolve overlap → invalid
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TR-DR7 unknown clipId throws ArgumentError', () {
      final draft = makeTrimDraft();
      expect(
        () => draft.trimClip(
          clipId: 'clip-UNKNOWN',
          trimStartSeconds: 0.0,
          trimEndSeconds: 3.0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TR-DR8 negative trimStartSeconds throws ArgumentError', () {
      final draft = makeTrimDraft();
      expect(
        () => draft.trimClip(
          clipId: 'clip-A',
          trimStartSeconds: -0.1,
          trimEndSeconds: 3.0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TR-DR9 trim clip A with dissolve recomputes clip B start correctly', () {
      // clip A 5s, clip B 5s, dissolve 1s → baseline: B starts at 4.0s.
      // Trim A to 2.0 → 4.5 (2.5s). New B start = 2.5 - 1.0 = 1.5s.
      final draft = makeTransitionDraft();
      final trimmed = draft.trimClip(
        clipId: 'clip-A',
        trimStartSeconds: 2.0,
        trimEndSeconds: 4.5,
      );

      expect(trimmed.clips[0].startTimeSeconds, closeTo(0.0, 1e-9));
      // A timelineDuration = 2.5s; overlap = 1.0s → B starts at 1.5s.
      expect(trimmed.clips[1].startTimeSeconds, closeTo(1.5, 1e-9));
      // Total duration = 1.5 + 5.0 = 6.5s.
      expect(trimmed.durationSeconds, closeTo(6.5, 1e-9));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // splitClip (Phase 7.14 / DEC-147)
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — splitClip (Phase 7.14)', () {
    // Shared fixture: two 5-second clips, no transitions (hard-cut baseline).
    VGEditorDraft makeSplitDraft() => VGEditorDraft.sequentialWithTransitions(
          id: 'draft-split',
          clips: [
            _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
            _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
          ],
        );

    // Transition fixture: clip A (5s) → dissolve (1s) → clip B (5s).
    VGEditorDraft makeTransitionSplitDraft() {
      final tr = VGTransitionDescriptor(
        id: 'tr-AB',
        type: VGTransitionType.dissolve,
        durationSeconds: 1.0,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
      );
      return VGEditorDraft.sequentialWithTransitions(
        id: 'draft-split-dissolve',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [tr],
      );
    }

    test('TR-SP1 valid split returns new draft; original is unchanged', () {
      final draft = makeSplitDraft();
      final split = draft.splitClip(clipId: 'clip-A', splitSeconds: 3.0);

      // Original draft is immutable — unchanged.
      expect(draft.clips.length, 2);
      expect(draft.clips[0].trimEndSeconds, closeTo(5.0, 1e-9));

      // Returned draft has 3 clips (A, A-split-1, B).
      expect(split.clips.length, 3);
    });

    test('TR-SP2 left clip retains ID and updates trimEnd; right clip gets new ID and correct trimStart', () {
      final draft = makeSplitDraft();
      final split = draft.splitClip(clipId: 'clip-A', splitSeconds: 3.0);

      // Left clip: original ID, trimEnd = splitSeconds.
      final left = split.clips[0];
      expect(left.id, 'clip-A');
      expect(left.trimStartSeconds, closeTo(0.0, 1e-9));
      expect(left.trimEndSeconds, closeTo(3.0, 1e-9));

      // Right clip: deterministic ID, trimStart = splitSeconds, trimEnd unchanged.
      final right = split.clips[1];
      expect(right.id, 'clip-A-split-1');
      expect(right.trimStartSeconds, closeTo(3.0, 1e-9));
      expect(right.trimEndSeconds, closeTo(5.0, 1e-9));

      // Both clips inherit sourcePath and mediaKind.
      expect(right.sourcePath, left.sourcePath);
      expect(right.mediaKind, left.mediaKind);
      expect(right.durationSeconds, closeTo(left.durationSeconds, 1e-9));
    });

    test('TR-SP3 start-time cascade is correct after split', () {
      // Clip A (5s) split at 3s → left=3s, right=2s; then Clip B (5s).
      // Expected: left@0.0, right@3.0, B@5.0. Total = 10s.
      final draft = makeSplitDraft();
      final split = draft.splitClip(clipId: 'clip-A', splitSeconds: 3.0);

      expect(split.clips[0].startTimeSeconds, closeTo(0.0, 1e-9));
      expect(split.clips[1].startTimeSeconds, closeTo(3.0, 1e-9));
      expect(split.clips[2].startTimeSeconds, closeTo(5.0, 1e-9));
      // Total duration is preserved: 3 + 2 + 5 = 10s (hard cut, no overlap lost).
      expect(split.durationSeconds, closeTo(10.0, 1e-9));
    });

    test('TR-SP4 outgoing transition is rebound to right clip; incoming stays on left', () {
      // Dissolve A→B: after split, dissolve should be rebound to A-split-1→B.
      final draft = makeTransitionSplitDraft();
      final split = draft.splitClip(clipId: 'clip-A', splitSeconds: 3.0);

      // The transition's fromClipId must now be the right clip ID.
      expect(split.transitions.length, 1);
      final t = split.transitions[0];
      expect(t.fromClipId, 'clip-A-split-1',
          reason: 'Outgoing transition must be rebound to right split clip');
      expect(t.toClipId, 'clip-B',
          reason: 'Transition target must remain clip-B');
    });

    test('TR-SP5 still-image clip split preserves mediaKind', () {
      // A still-image clip (VGMediaKind.image) can be split — display hold window divides.
      final stillClip = VGClipDescriptor(
        id: 'still-A',
        sourcePath: '/tmp/still_a.png',
        mediaKind: VGMediaKind.image,
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 5.0,
      );
      final draft = VGEditorDraft(
        id: 'draft-still-split',
        clips: [stillClip],
      );
      final split = draft.splitClip(clipId: 'still-A', splitSeconds: 2.5);

      expect(split.clips.length, 2);
      expect(split.clips[0].mediaKind, VGMediaKind.image,
          reason: 'Left clip must retain image mediaKind');
      expect(split.clips[1].mediaKind, VGMediaKind.image,
          reason: 'Right clip must retain image mediaKind');
      expect(split.clips[0].trimEndSeconds, closeTo(2.5, 1e-9));
      expect(split.clips[1].trimStartSeconds, closeTo(2.5, 1e-9));
    });

    test('TR-SP6 out-of-bounds splitSeconds throws ArgumentError', () {
      final draft = makeSplitDraft();

      // Below trimStartSeconds (== 0.0).
      expect(
        () => draft.splitClip(clipId: 'clip-A', splitSeconds: -1.0),
        throwsA(isA<ArgumentError>()),
      );

      // Equal to trimStartSeconds.
      expect(
        () => draft.splitClip(clipId: 'clip-A', splitSeconds: 0.0),
        throwsA(isA<ArgumentError>()),
      );

      // Equal to trimEndSeconds.
      expect(
        () => draft.splitClip(clipId: 'clip-A', splitSeconds: 5.0),
        throwsA(isA<ArgumentError>()),
      );

      // Beyond trimEndSeconds.
      expect(
        () => draft.splitClip(clipId: 'clip-A', splitSeconds: 6.0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TR-SP7 resulting clips below 0.1 s minimum throw ArgumentError', () {
      final draft = makeSplitDraft();

      // Left clip would be 0.05s (below minimum).
      expect(
        () => draft.splitClip(clipId: 'clip-A', splitSeconds: 0.05),
        throwsA(isA<ArgumentError>()),
      );

      // Right clip would be 0.05s (below minimum).
      expect(
        () => draft.splitClip(clipId: 'clip-A', splitSeconds: 4.95),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TR-SP8 split violating transition overlap boundary throws ArgumentError', () {
      // Dissolve A→B is 1s. Splitting clip A at 0.5s → right clip = 4.5s
      // wall-clock, which is fine for the outgoing transition (4.5 >= 1.0).
      // But splitting at 4.9s → right clip = 0.1s exactly ≥ min duration,
      // but right timeline duration (0.1s / 1.0 speed = 0.1s) < overlapOut (1.0s).
      final draft = makeTransitionSplitDraft();

      // Split creates right clip with only 0.1s, which is < 1.0s outgoing overlap.
      expect(
        () => draft.splitClip(clipId: 'clip-A', splitSeconds: 4.9),
        throwsA(isA<ArgumentError>()),
        reason: 'Right clip timelineDuration must be >= outgoing transition overlap',
      );

      // Unknown clip ID throws ArgumentError.
      expect(
        () => draft.splitClip(clipId: 'clip-UNKNOWN', splitSeconds: 2.0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // reorderClip (Phase 7.15 / DEC-148)
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — reorderClip (Phase 7.15)', () {
    // Shared fixtures.
    // Three 5-second clips, no transitions (hard-cut baseline).
    VGEditorDraft makeThreeClipDraft() => VGEditorDraft.sequentialWithTransitions(
          id: 'draft-reorder',
          clips: [
            _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
            _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
            _clip(id: 'clip-C', trimStart: 0.0, trimEnd: 5.0),
          ],
        );

    // Three clips with dissolve A→B and dissolve B→C (1s each).
    VGEditorDraft makeTransitionThreeClipDraft() {
      final trAB = VGTransitionDescriptor(
        id: 'tr-AB',
        type: VGTransitionType.dissolve,
        durationSeconds: 1.0,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
      );
      final trBC = VGTransitionDescriptor(
        id: 'tr-BC',
        type: VGTransitionType.dissolve,
        durationSeconds: 1.0,
        fromClipId: 'clip-B',
        toClipId: 'clip-C',
      );
      return VGEditorDraft.sequentialWithTransitions(
        id: 'draft-reorder-dissolve',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-C', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [trAB, trBC],
      );
    }

    test('RO-DR1 valid reorder moves clip and returns new draft; original is unchanged', () {
      final draft = makeThreeClipDraft();
      // Move clip-A (index 0) to index 2 → [B, C, A].
      final reordered = draft.reorderClip(fromIndex: 0, toIndex: 2);

      // Original draft is immutable — unchanged.
      expect(draft.clips[0].id, 'clip-A');
      expect(draft.clips.length, 3);

      // Reordered draft has clips in new order.
      expect(reordered.clips.length, 3);
      expect(reordered.clips[0].id, 'clip-B');
      expect(reordered.clips[1].id, 'clip-C');
      expect(reordered.clips[2].id, 'clip-A');
    });

    test('RO-DR2 reorder forward: [A, B, C] → move index 0 to 1 → [B, A, C]', () {
      final draft = makeThreeClipDraft();
      final reordered = draft.reorderClip(fromIndex: 0, toIndex: 1);

      expect(reordered.clips[0].id, 'clip-B');
      expect(reordered.clips[1].id, 'clip-A');
      expect(reordered.clips[2].id, 'clip-C');
    });

    test('RO-DR3 reorder backward: [A, B, C] → move index 2 to 0 → [C, A, B]', () {
      final draft = makeThreeClipDraft();
      final reordered = draft.reorderClip(fromIndex: 2, toIndex: 0);

      expect(reordered.clips[0].id, 'clip-C');
      expect(reordered.clips[1].id, 'clip-A');
      expect(reordered.clips[2].id, 'clip-B');
    });

    test('RO-DR4 startTimeSeconds are recomputed sequentially after reorder (no transitions)', () {
      // Three 5s clips → after reorder, starts must still be 0, 5, 10.
      final draft = makeThreeClipDraft();
      final reordered = draft.reorderClip(fromIndex: 0, toIndex: 2);

      expect(reordered.clips[0].startTimeSeconds, closeTo(0.0, 1e-9));
      expect(reordered.clips[1].startTimeSeconds, closeTo(5.0, 1e-9));
      expect(reordered.clips[2].startTimeSeconds, closeTo(10.0, 1e-9));
      // Total duration is unchanged: 15s.
      expect(reordered.durationSeconds, closeTo(15.0, 1e-9));
    });

    test('RO-DR5 Option D: two-clip swap relinks slot-0 transition from A→B to B→A', () {
      // [A, B] with fade A→B (slot 0). Swap → [B, A].
      // Option D: slot 0 now spans B→A → relink tr-AB to (from:B, to:A).
      // Transition id/type/duration/curve must be preserved.
      final trAB = VGTransitionDescriptor(
        id: 'tr-AB',
        type: VGTransitionType.fade,
        durationSeconds: 1.0,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
        curve: VGTransitionCurve.easeInOut,
      );
      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-ro5',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [trAB],
      );
      final reordered = draft.reorderClip(fromIndex: 0, toIndex: 1);

      // Clip order swapped.
      expect(reordered.clips[0].id, 'clip-B');
      expect(reordered.clips[1].id, 'clip-A');

      // Transition relinked — not dropped.
      expect(reordered.transitions.length, 1,
          reason: 'Slot-0 fade must survive; Option D relinks rather than drops');
      final t = reordered.transitions[0];
      expect(t.id, 'tr-AB', reason: 'Transition ID must be preserved');
      expect(t.type, VGTransitionType.fade,
          reason: 'Transition type must be preserved');
      expect(t.durationSeconds, closeTo(1.0, 1e-9),
          reason: 'Transition duration must be preserved');
      expect(t.curve, VGTransitionCurve.easeInOut,
          reason: 'Transition curve must be preserved');
      // fromClipId/toClipId rewritten to new adjacency.
      expect(t.fromClipId, 'clip-B',
          reason: 'fromClipId rewritten to new slot-0 left clip (B)');
      expect(t.toClipId, 'clip-A',
          reason: 'toClipId rewritten to new slot-0 right clip (A)');
    });

    test('RO-DR6 Option D: three-clip reorder relinks both slots', () {
      // [A, B, C] with dissolve A→B (slot 0) and dissolve B→C (slot 1).
      // Move A (index 0) to index 2 → [B, C, A].
      // Slot 0 was A→B → now spans B→C → relinked to (from:B, to:C).
      // Slot 1 was B→C → now spans C→A → relinked to (from:C, to:A).
      final draft = makeTransitionThreeClipDraft();
      final reordered = draft.reorderClip(fromIndex: 0, toIndex: 2);

      // Clip order: [B, C, A].
      expect(reordered.clips[0].id, 'clip-B');
      expect(reordered.clips[1].id, 'clip-C');
      expect(reordered.clips[2].id, 'clip-A');

      // Both transitions survive (relinked).
      expect(reordered.transitions.length, 2,
          reason: 'Both slot transitions must be relinked, not dropped');

      // Slot 0: was tr-AB (A→B), now relinked to B→C.
      final t0 = reordered.transitions[0];
      expect(t0.id, 'tr-AB', reason: 'Slot-0 transition ID preserved');
      expect(t0.type, VGTransitionType.dissolve);
      expect(t0.fromClipId, 'clip-B',
          reason: 'Slot-0 relinked to new left clip B');
      expect(t0.toClipId, 'clip-C',
          reason: 'Slot-0 relinked to new right clip C');

      // Slot 1: was tr-BC (B→C), now relinked to C→A.
      final t1 = reordered.transitions[1];
      expect(t1.id, 'tr-BC', reason: 'Slot-1 transition ID preserved');
      expect(t1.type, VGTransitionType.dissolve);
      expect(t1.fromClipId, 'clip-C',
          reason: 'Slot-1 relinked to new left clip C');
      expect(t1.toClipId, 'clip-A',
          reason: 'Slot-1 relinked to new right clip A');
    });

    test('RO-DR7 Option D: reorder with only slot-0 transition relinks to new slot-0 pair', () {
      // [A, B, C] with dissolve A→B (slot 0 only).
      // Move B (index 1) to index 0 → [B, A, C].
      // Slot 0 was A→B → now spans B→A → relinked to (from:B, to:A).
      // Slot 1 had no transition → no transition emitted for slot 1.
      final trAB = VGTransitionDescriptor(
        id: 'tr-AB',
        type: VGTransitionType.dissolve,
        durationSeconds: 1.0,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
      );
      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-ro7',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-C', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [trAB],
      );
      final reordered = draft.reorderClip(fromIndex: 1, toIndex: 0);

      expect(reordered.clips[0].id, 'clip-B');
      expect(reordered.clips[1].id, 'clip-A');
      expect(reordered.clips[2].id, 'clip-C');

      // Slot 0 transition relinked B→A (not dropped).
      expect(reordered.transitions.length, 1,
          reason: 'Slot-0 dissolve must be relinked to new B→A adjacency');
      expect(reordered.transitions[0].id, 'tr-AB',
          reason: 'Transition ID preserved after relink');
      expect(reordered.transitions[0].fromClipId, 'clip-B',
          reason: 'Slot-0 left clip is now B');
      expect(reordered.transitions[0].toClipId, 'clip-A',
          reason: 'Slot-0 right clip is now A');
    });

    test('RO-DR8 Option D: relinked transitions recompute startTimeSeconds correctly', () {
      // [A, B, C] with dissolve A→B (1s, slot 0) and dissolve B→C (1s, slot 1).
      // Move A (index 0) to index 2 → [B, C, A].
      // Both slots survive with relinked fromClipId/toClipId.
      // Layout: B@0, C@(5-1)=4s (slot-0 overlap 1s), A@(4+5-1)=8s (slot-1 overlap 1s).
      // Total = 8 + 5 = 13s (two 1s overlaps → 15 - 2 = 13s).
      final draft = makeTransitionThreeClipDraft();
      final reordered = draft.reorderClip(fromIndex: 0, toIndex: 2);

      expect(reordered.clips[0].startTimeSeconds, closeTo(0.0, 1e-9));
      expect(reordered.clips[1].startTimeSeconds, closeTo(4.0, 1e-9));
      expect(reordered.clips[2].startTimeSeconds, closeTo(8.0, 1e-9));
      // Total duration: 13s (both 1s overlaps preserved).
      expect(reordered.durationSeconds, closeTo(13.0, 1e-9));
      // Both transitions present.
      expect(reordered.transitions.length, 2);
    });

    test('RO-DR9 clip fields are fully preserved after reorder (sourcePath, transform, speed)', () {
      // Ensure reorderClip does not lose clip metadata.
      const tdA = VGClipTransformDescriptor(scaleX: 0.5, scaleY: 0.5, opacity: 0.8);
      final clipA = VGClipDescriptor(
        id: 'clip-A',
        sourcePath: '/tmp/clip_a.mp4',
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 5.0,
        transform: tdA,
      );
      final clipB = VGClipDescriptor(
        id: 'clip-B',
        sourcePath: '/tmp/clip_b.mp4',
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 5.0,
      );
      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-ro9',
        clips: [clipA, clipB],
      );
      // Move A to index 1 → [B, A].
      final reordered = draft.reorderClip(fromIndex: 0, toIndex: 1);

      expect(reordered.clips[0].id, 'clip-B');
      expect(reordered.clips[1].id, 'clip-A');
      // Clip A's transform must survive the move.
      expect(reordered.clips[1].transform, isNotNull);
      expect(reordered.clips[1].transform!.scaleX, closeTo(0.5, 1e-9));
      expect(reordered.clips[1].transform!.opacity, closeTo(0.8, 1e-9));
      expect(reordered.clips[1].transform, equals(tdA));
    });

    test('RO-DR10 fromIndex == toIndex is a no-op: returns same instance, does not throw', () {
      final draft = makeThreeClipDraft();
      final result = draft.reorderClip(fromIndex: 1, toIndex: 1);
      // Must be the identical object — no unnecessary rebuild.
      expect(identical(result, draft), isTrue,
          reason: 'No-op reorder must return the same draft instance');
      // Clips are unmodified.
      expect(result.clips[0].id, 'clip-A');
      expect(result.clips[1].id, 'clip-B');
      expect(result.clips[2].id, 'clip-C');
    });

    test('RO-DR11 fromIndex out of range throws ArgumentError', () {
      final draft = makeThreeClipDraft();
      // Too low.
      expect(
        () => draft.reorderClip(fromIndex: -1, toIndex: 0),
        throwsA(isA<ArgumentError>()),
      );
      // Too high.
      expect(
        () => draft.reorderClip(fromIndex: 3, toIndex: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('RO-DR12 toIndex out of range throws ArgumentError', () {
      final draft = makeThreeClipDraft();
      // Too low.
      expect(
        () => draft.reorderClip(fromIndex: 0, toIndex: -1),
        throwsA(isA<ArgumentError>()),
      );
      // Too high (3 clips → max index = 2).
      expect(
        () => draft.reorderClip(fromIndex: 0, toIndex: 3),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('RO-DR13 two-clip swap: [A, B] → [B, A]', () {
      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-ro13',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 4.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 3.0),
        ],
      );
      final reordered = draft.reorderClip(fromIndex: 0, toIndex: 1);

      expect(reordered.clips[0].id, 'clip-B');
      expect(reordered.clips[1].id, 'clip-A');
      expect(reordered.clips[0].startTimeSeconds, closeTo(0.0, 1e-9));
      expect(reordered.clips[1].startTimeSeconds, closeTo(3.0, 1e-9));
      // Total: 3 + 4 = 7s (same total as before, just different order).
      expect(reordered.durationSeconds, closeTo(7.0, 1e-9));
    });

    test('RO-DR14 null-ref transitions (Stage 7.1 compat) are discarded by Option D', () {
      // A transition with null fromClipId / toClipId cannot be matched to a
      // boundary slot and is therefore discarded by Option D.
      // (Under Option B they were retained; Option D intentionally changes this.)
      final nullRefTransition = VGTransitionDescriptor(
        id: 'tr-null',
        type: VGTransitionType.none,
        durationSeconds: 0.0,
        // fromClipId and toClipId are null (Stage 7.1 compat).
      );
      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-ro14',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [nullRefTransition],
      );
      final reordered = draft.reorderClip(fromIndex: 0, toIndex: 1);

      // Null-ref transition has no slot match → discarded.
      expect(reordered.transitions, isEmpty,
          reason: 'Option D discards null-ref transitions that cannot be '
              'slot-matched. Callers must re-add after reorder if needed.');
    });

    test(
        'RO-DR15 relinked transition duration exceeding new adjacent clip '
        'timelineDuration throws ArgumentError',
        () {
      // Slot-0 has a 4s dissolve. After reorder, slot-0 lands between clips
      // of only 2s each → 4s > 2s → ArgumentError before any channel call.
      final longTransition = VGTransitionDescriptor(
        id: 'tr-long',
        type: VGTransitionType.dissolve,
        durationSeconds: 4.0,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
      );
      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-ro15',
        clips: [
          // clip-A: 10s timeline (large enough to hold 4s transition originally)
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 10.0),
          // clip-B: 2s timeline (too short to hold 4s after relink)
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 2.0),
          _clip(id: 'clip-C', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [longTransition],
      );
      // Move clip-C to index 0 → [C, A, B].
      // Slot 0 was clip-A→clip-B (tr-long, 4s). New slot 0 spans C(5s)→A(10s).
      // 4s <= 5s and 4s <= 10s → this relink is SAFE. No throw.
      final safeReorder = draft.reorderClip(fromIndex: 2, toIndex: 0);
      expect(safeReorder.transitions.length, 1,
          reason: 'C(5s)→A(10s): 4s fits both clips; must relink successfully');

      // Now move clip-A to index 2 → [B, C, A].
      // Slot 0 was clip-A→clip-B (tr-long, 4s). New slot 0 spans B(2s)→C(5s).
      // 4s > 2s (clip-B timeline) → ArgumentError.
      expect(
        () => draft.reorderClip(fromIndex: 0, toIndex: 2),
        throwsA(isA<ArgumentError>()),
        reason: 'B(2s)→C(5s): 4s exceeds B.timelineDuration; must throw');
    });

    test(
        'RO-DR16 Option D: no transition created for boundary that had none',
        () {
      // [A, B, C] — slot 0 has dissolve A→B; slot 1 has no transition.
      // Move C (index 2) to index 0 → [C, A, B].
      // Slot 0 had tr-AB → relinked to C→A.
      // Slot 1 had no transition → still no transition.
      final trAB = VGTransitionDescriptor(
        id: 'tr-AB',
        type: VGTransitionType.dissolve,
        durationSeconds: 1.0,
        fromClipId: 'clip-A',
        toClipId: 'clip-B',
      );
      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-ro16',
        clips: [
          _clip(id: 'clip-A', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-B', trimStart: 0.0, trimEnd: 5.0),
          _clip(id: 'clip-C', trimStart: 0.0, trimEnd: 5.0),
        ],
        transitions: [trAB],
      );
      final reordered = draft.reorderClip(fromIndex: 2, toIndex: 0);

      // New order: [C, A, B].
      expect(reordered.clips[0].id, 'clip-C');
      expect(reordered.clips[1].id, 'clip-A');
      expect(reordered.clips[2].id, 'clip-B');

      // Exactly 1 transition: slot-0 relinked C→A.
      expect(reordered.transitions.length, 1,
          reason: 'Only slot 0 had a transition; slot 1 must stay empty');
      expect(reordered.transitions[0].id, 'tr-AB');
      expect(reordered.transitions[0].fromClipId, 'clip-C',
          reason: 'Slot-0 relinked to new left clip C');
      expect(reordered.transitions[0].toClipId, 'clip-A',
          reason: 'Slot-0 relinked to new right clip A');
    });
  });
}
