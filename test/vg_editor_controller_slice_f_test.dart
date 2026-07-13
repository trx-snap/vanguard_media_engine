// vg_editor_controller_slice_f_test.dart
// Vanguard Media Engine — Phase 10-C Slice F
//
// Focused Dart tests verifying that VGEditorController derives a disposable
// preview draft (flattenOriginalClipAudio → applyAudioCompositionPolicy) for
// both createTimelineTexture (initialize) and updateTimeline (updateDraft).
//
// Tests:
//   SF-1  initialize sends derived draft (Original flattened from clips)
//   SF-2  updateDraft sends derived draft from nextDraft, not stale value.draft
//   SF-3  raw authoring draft is never mutated by initialize
//   SF-4  raw authoring draft is never mutated by updateDraft
//   SF-5  repeated derivation does not accumulate Original tracks
//   SF-6  zero-volume Music causes Original to be muted in derived draft
//   SF-7  Voiceover causes Original muting — VO is not filtered before derivation

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';

// ── Test fixtures ─────────────────────────────────────────────────────────────

VGClipDescriptor _clip({required String id, double trimEnd = 5.0}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/fixture_$id.mp4',
      durationSeconds: trimEnd,
      trimStartSeconds: 0.0,
      trimEndSeconds: trimEnd,
    );

VGAudioSidecarTrack _track({
  required String trackId,
  required String role,
  double volume = 1.0,
  double startTime = 0.0,
  double duration = 5.0,
}) => VGAudioSidecarTrack(
  trackId: trackId,
  url: '/tmp/$trackId.mp3',
  startTime: startTime,
  duration: duration,
  volume: volume,
  role: role,
);

// ── Mock channel helpers ───────────────────────────────────────────────────────

void _setMockHandler(
  Future<Object?> Function(String method, dynamic args) handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    (call) => handler(call.method, call.arguments),
  );
}

void _clearMockHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    null,
  );
}

List<Map<Object?, Object?>> _tracksFromDraftMap(Map draftMap) {
  final plan = draftMap['audioSidecar'] as Map?;
  if (plan == null) return [];
  final tracks = plan['tracks'] as List?;
  if (tracks == null) return [];
  return tracks.map((t) => t as Map<Object?, Object?>).toList();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(_clearMockHandler);

  // SF-1 ─────────────────────────────────────────────────────────────────────
  test('SF-1  initialize sends derived draft with flattened Original tracks', () async {
    final rawDraft = VGEditorDraft(
      id: 'draft-sf1',
      clips: [_clip(id: 'clip-A', trimEnd: 3.0), _clip(id: 'clip-B', trimEnd: 4.0)],
    );
    expect(rawDraft.audioSidecarPlan, isNull,
        reason: 'raw draft must start with no sidecar plan');

    dynamic capturedDraftMap;
    _setMockHandler((method, args) async {
      if (method == 'createTimelineTexture') {
        capturedDraftMap = (args as Map)['draft'];
        return {'textureId': 1, 'width': 640, 'height': 360};
      }
      if (method == 'disposeTimeline') return null;
      return null;
    });

    final controller = VGEditorController(initialDraft: rawDraft);
    addTearDown(controller.dispose);
    await controller.initialize();

    expect(capturedDraftMap, isNotNull);
    final tracks = _tracksFromDraftMap(capturedDraftMap as Map);
    expect(tracks, hasLength(2),
        reason: 'derived draft must contain one original track per video clip');
    expect(tracks.every((t) => t['role'] == 'original'), isTrue,
        reason: 'all derived tracks must have role == original');
  });

  // SF-2 ─────────────────────────────────────────────────────────────────────
  test('SF-2  updateDraft derives from nextDraft not stale value.draft', () async {
    final initialDraft = VGEditorDraft(
      id: 'draft-sf2-initial',
      clips: [_clip(id: 'clip-A', trimEnd: 3.0)],
    );
    final nextDraft = VGEditorDraft(
      id: 'draft-sf2-next',
      clips: [
        _clip(id: 'clip-X', trimEnd: 2.0),
        _clip(id: 'clip-Y', trimEnd: 2.0),
        _clip(id: 'clip-Z', trimEnd: 2.0),
      ],
    );

    dynamic capturedUpdateDraftMap;
    _setMockHandler((method, args) async {
      switch (method) {
        case 'createTimelineTexture':
          return {'textureId': 1, 'width': 640, 'height': 360};
        case 'updateTimeline':
          capturedUpdateDraftMap = (args as Map)['draft'];
          return {'textureId': 2, 'width': 640, 'height': 360};
        case 'disposeTimeline':
          return null;
        default:
          return null;
      }
    });

    final controller = VGEditorController(initialDraft: initialDraft);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.updateDraft(nextDraft);

    expect(capturedUpdateDraftMap, isNotNull);
    final tracks = _tracksFromDraftMap(capturedUpdateDraftMap as Map);
    expect(tracks, hasLength(3),
        reason:
            'derived draft must contain 3 original tracks from nextDraft, not '
            '${tracks.length} from stale value.draft');
  });

  // SF-3 ─────────────────────────────────────────────────────────────────────
  test('SF-3  raw draft is unchanged after initialize', () async {
    final rawDraft = VGEditorDraft(
      id: 'draft-sf3',
      clips: [_clip(id: 'clip-A', trimEnd: 5.0)],
    );
    final planBefore = rawDraft.audioSidecarPlan;

    _setMockHandler((method, args) async {
      if (method == 'createTimelineTexture') {
        return {'textureId': 1, 'width': 640, 'height': 360};
      }
      if (method == 'disposeTimeline') return null;
      return null;
    });

    final controller = VGEditorController(initialDraft: rawDraft);
    addTearDown(controller.dispose);
    await controller.initialize();

    expect(rawDraft.audioSidecarPlan, equals(planBefore),
        reason: 'initialize must not mutate the raw authoring draft');
    expect(controller.value.draft.audioSidecarPlan, equals(planBefore),
        reason: 'controller authoring state must not persist the derived draft');
  });

  // SF-4 ─────────────────────────────────────────────────────────────────────
  test('SF-4  raw nextDraft is unchanged after updateDraft', () async {
    final initialDraft = VGEditorDraft(
      id: 'draft-sf4-initial',
      clips: [_clip(id: 'clip-A', trimEnd: 3.0)],
    );
    final nextDraft = VGEditorDraft(
      id: 'draft-sf4-next',
      clips: [_clip(id: 'clip-B', trimEnd: 4.0)],
    );
    final planBefore = nextDraft.audioSidecarPlan;

    _setMockHandler((method, args) async {
      switch (method) {
        case 'createTimelineTexture':
          return {'textureId': 1, 'width': 640, 'height': 360};
        case 'updateTimeline':
          return {'textureId': 2, 'width': 640, 'height': 360};
        case 'disposeTimeline':
          return null;
        default:
          return null;
      }
    });

    final controller = VGEditorController(initialDraft: initialDraft);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.updateDraft(nextDraft);

    expect(nextDraft.audioSidecarPlan, equals(planBefore),
        reason: 'updateDraft must not mutate the raw nextDraft');
  });

  // SF-5 ─────────────────────────────────────────────────────────────────────
  test('SF-5  repeated updateDraft does not accumulate Original tracks', () async {
    final draft = VGEditorDraft(
      id: 'draft-sf5',
      clips: [_clip(id: 'clip-A', trimEnd: 3.0), _clip(id: 'clip-B', trimEnd: 3.0)],
    );

    List<Map<Object?, Object?>> capturedTracks = [];
    _setMockHandler((method, args) async {
      switch (method) {
        case 'createTimelineTexture':
          return {'textureId': 1, 'width': 640, 'height': 360};
        case 'updateTimeline':
          capturedTracks = _tracksFromDraftMap((args as Map)['draft'] as Map);
          return {'textureId': 2, 'width': 640, 'height': 360};
        case 'disposeTimeline':
          return null;
        default:
          return null;
      }
    });

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.updateDraft(draft);
    final countAfterFirst = capturedTracks.length;

    await controller.updateDraft(draft);
    final countAfterSecond = capturedTracks.length;

    expect(countAfterFirst, equals(2), reason: 'first update must produce 2 original tracks');
    expect(countAfterSecond, equals(countAfterFirst),
        reason:
            'second update with same draft must not accumulate tracks; '
            'got $countAfterSecond vs $countAfterFirst');
  });

  // SF-6 ─────────────────────────────────────────────────────────────────────
  test('SF-6  zero-volume Music causes Original muting in derived draft', () async {
    final rawDraft = VGEditorDraft(
      id: 'draft-sf6',
      clips: [_clip(id: 'clip-A', trimEnd: 5.0)],
      audioSidecarPlan: VGAudioSidecarPlan(
        tracks: [_track(trackId: 'music-1', role: 'music', volume: 0.0)],
      ),
    );

    dynamic capturedDraftMap;
    _setMockHandler((method, args) async {
      if (method == 'createTimelineTexture') {
        capturedDraftMap = (args as Map)['draft'];
        return {'textureId': 1, 'width': 640, 'height': 360};
      }
      if (method == 'disposeTimeline') return null;
      return null;
    });

    final controller = VGEditorController(initialDraft: rawDraft);
    addTearDown(controller.dispose);
    await controller.initialize();

    final tracks = _tracksFromDraftMap(capturedDraftMap as Map);
    final originalTracks = tracks.where((t) => t['role'] == 'original').toList();
    expect(originalTracks, hasLength(1));

    final originalVolume = (originalTracks.first['volume'] as num).toDouble();
    expect(originalVolume, closeTo(0.0, 0.001),
        reason:
            'original must be muted when music track is present; got $originalVolume');
  });

  // SF-7 ─────────────────────────────────────────────────────────────────────
  test('SF-7  Voiceover causes Original muting — VO is not filtered before derivation', () async {
    final rawDraft = VGEditorDraft(
      id: 'draft-sf7',
      clips: [_clip(id: 'clip-A', trimEnd: 5.0)],
      audioSidecarPlan: VGAudioSidecarPlan(
        tracks: [_track(trackId: 'vo-1', role: 'voiceover', volume: 1.0)],
      ),
    );

    dynamic capturedDraftMap;
    _setMockHandler((method, args) async {
      if (method == 'createTimelineTexture') {
        capturedDraftMap = (args as Map)['draft'];
        return {'textureId': 1, 'width': 640, 'height': 360};
      }
      if (method == 'disposeTimeline') return null;
      return null;
    });

    final controller = VGEditorController(initialDraft: rawDraft);
    addTearDown(controller.dispose);
    await controller.initialize();

    final tracks = _tracksFromDraftMap(capturedDraftMap as Map);
    final voTracks = tracks.where((t) => t['role'] == 'voiceover').toList();
    final originalTracks = tracks.where((t) => t['role'] == 'original').toList();

    expect(voTracks, hasLength(1),
        reason: 'VO track must not be filtered before derivation');
    expect(originalTracks, hasLength(1),
        reason: 'flattened original track must be present');

    final originalVolume = (originalTracks.first['volume'] as num).toDouble();
    expect(originalVolume, closeTo(0.0, 0.001),
        reason:
            'original must be muted when voiceover is present; got $originalVolume');
  });
}
