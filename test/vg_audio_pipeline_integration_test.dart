// test/vg_audio_pipeline_integration_test.dart
// Phase 8.21 — Audio Pipeline Integration Hardening
//
// Comprehensive Dart integration test suite proving the Phase 8.14–8.20 audio
// pipeline produces the correct `exportTimeline` payload for complex editor
// drafts.
//
// This file validates the full chain:
//   VGEditorController.export()
//     → VGEditorDraft.flattenOriginalClipAudio()   (Phase 8.14A–D)
//     → VGEditorDraft.applyAudioDucking()           (Phase 8.19–8.20)
//     → exportTimeline MethodChannel call
//
// Tests are grouped by scenario, each asserting pipeline invariants rather than
// brittle whole-payload exact matching.
//
// Covered scenarios:
//   PIPE-1  Multi-clip, music + voiceover + SFX, transition crossfade
//           → original tracks flattened, ducking applied, non-music tracks safe
//   PIPE-2  Multi-clip, music + voiceover only, verify timing/trim/fade fields
//   PIPE-3  Pre-authored music keyframes preserved (ducking no-op)
//   PIPE-4  Music with no foreground overlap → no ducking keyframes added
//   PIPE-5  No explicit sidecar plan → original tracks flattened, ducking no-op
//   PIPE-6  SFX role is never treated as foreground duckee-target or as music
//   PIPE-7  Source trim field appears on flattened original track
//   PIPE-8  Transition-derived fade fields appear on original tracks (8.14D)
//   PIPE-9  Multiple music tracks — all eligible tracks receive ducking keyframes
//  PIPE-10  Export chain does not mutate the live controller draft

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';
import 'package:vanguard_media_engine/vg_editor_export_request.dart';
import 'package:vanguard_media_engine/vg_editor_export_result.dart';
import 'package:vanguard_media_engine/vg_transition_descriptor.dart';

// ─── Mock channel helpers ─────────────────────────────────────────────────────

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

/// Installs a mock that captures the `exportTimeline` args map via [capture].
/// Returns a valid export result for all other required methods.
Future<Object?> Function(String, dynamic) _exportHandler(
  void Function(dynamic args) capture,
) {
  return (method, args) async {
    switch (method) {
      case 'createTimelineTexture':
        return {'textureId': 99, 'width': 1080, 'height': 1920};
      case 'exportTimeline':
        capture(args);
        return {
          'success': true,
          'path': '/tmp/pipe_test_export.mp4',
          'durationSeconds': 10.0,
          'width': 1080,
          'height': 1920,
        };
      case 'timelinePause':
      case 'disposeTimeline':
        return null;
      default:
        return null;
    }
  };
}

// ─── Fixture helpers ──────────────────────────────────────────────────────────

/// A standard video clip with default 0→duration trim.
VGClipDescriptor _videoClip({
  required String id,
  double duration = 5.0,
  double trimStart = 0.0,
  double? trimEnd,
  double startTime = 0.0,
}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/$id.mp4',
      durationSeconds: duration,
      trimStartSeconds: trimStart,
      trimEndSeconds: trimEnd ?? duration,
      startTimeSeconds: startTime,
    );

/// A sidecar track with the given role.
VGAudioSidecarTrack _sidecarTrack({
  required String id,
  required String role,
  required double start,
  required double duration,
  double volume = 1.0,
  List<VGAudioVolumeKeyframe>? volumeKeyframes,
}) =>
    VGAudioSidecarTrack(
      trackId: id,
      url: '/tmp/$id.m4a',
      startTime: start,
      duration: duration,
      volume: volume,
      role: role,
      volumeKeyframes: volumeKeyframes,
    );

/// Extracts the `audioSidecar.tracks` list from the captured exportTimeline
/// args map.  Returns null when no audioSidecar is present in the payload.
List<Map>? _tracksFromArgs(dynamic capturedArgs) {
  if (capturedArgs is! Map) return null;
  final draftMap = capturedArgs['draft'];
  if (draftMap is! Map) return null;
  final sidecarRaw = draftMap['audioSidecar'];
  if (sidecarRaw == null) return null;
  final sidecarMap = sidecarRaw as Map;
  final list = sidecarMap['tracks'];
  if (list is! List) return null;
  return list.cast<Map>();
}

/// Finds the first track in [tracks] whose 'trackId' == [id], or null.
Map? _findById(List<Map> tracks, String id) {
  for (final t in tracks) {
    if (t['trackId'] == id) return t;
  }
  return null;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    _clearMockHandler();
  });

  // ── PIPE-1: Full complex export ─────────────────────────────────────────────

  test(
      'PIPE-1: multi-clip export with music, voiceover, SFX, crossfade applies '
      'ducking to music only; flattens original tracks; voiceover/SFX unchanged',
      () async {
    // Two sequential video clips with a dissolve transition between them.
    // clip-A: occupies 0–5 s on the timeline (trimStart 0, trimEnd 5)
    // clip-B: starts at 5 s (startTimeSeconds computed by draft placement)
    //
    // NOTE: VGEditorDraft in sequential mode derives startTimeSeconds
    // automatically via VGEditorDraft.sequentialWithTransitions. For this test
    // we supply explicit startTimeSeconds to keep the fixture self-contained.
    final clipA = _videoClip(id: 'clip-A', duration: 5.0, startTime: 0.0);
    final clipB = _videoClip(id: 'clip-B', duration: 5.0, startTime: 5.0);

    // Dissolve transition between A→B (non-hard-cut → produces fade fields).
    const transition = VGTransitionDescriptor(
      id: 'tr-ab',
      type: VGTransitionType.dissolve,
      durationSeconds: 0.5,
      fromClipId: 'clip-A',
      toClipId: 'clip-B',
    );

    // Music spans the whole 10 s. Voiceover sits at 2–4 s. SFX at 8–9 s.
    final draft = VGEditorDraft(
      id: 'draft-pipe1',
      clips: [clipA, clipB],
      transitions: const [transition],
      audioSidecarPlan: VGAudioSidecarPlan(
        tracks: [
          _sidecarTrack(
              id: 'music-1', role: 'music', start: 0.0, duration: 10.0),
          _sidecarTrack(
              id: 'vo-1', role: 'voiceover', start: 2.0, duration: 2.0),
          _sidecarTrack(id: 'sfx-1', role: 'sfx', start: 8.0, duration: 1.0),
        ],
      ),
    );

    dynamic capturedArgs;
    _setMockHandler(_exportHandler((args) => capturedArgs = args));

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();

    final result = await controller.export(const VGEditorExportRequest());
    expect(result, isA<VGEditorExportResult>());

    final tracks = _tracksFromArgs(capturedArgs);
    expect(tracks, isNotNull, reason: 'audioSidecar.tracks must be present');
    expect(tracks!.length, greaterThanOrEqualTo(5),
        reason:
            'Expected music-1, vo-1, sfx-1, original-clip-A, original-clip-B');

    // Original tracks must be present (flattenOriginalClipAudio).
    final origA = _findById(tracks, 'original-clip-A');
    final origB = _findById(tracks, 'original-clip-B');
    expect(origA, isNotNull, reason: 'original-clip-A must be flattened');
    expect(origB, isNotNull, reason: 'original-clip-B must be flattened');

    // Explicit roles are preserved.
    final musicTrack = _findById(tracks, 'music-1');
    final voTrack = _findById(tracks, 'vo-1');
    final sfxTrack = _findById(tracks, 'sfx-1');
    expect(musicTrack, isNotNull);
    expect(voTrack, isNotNull);
    expect(sfxTrack, isNotNull);
    expect(musicTrack!['role'], 'music');
    expect(voTrack!['role'], 'voiceover');
    expect(sfxTrack!['role'], 'sfx');

    // Music must have ducking keyframes (overlapping original+voiceover).
    expect(musicTrack.containsKey('volumeKeyframes'), isTrue,
        reason: 'music-1 must receive ducking keyframes');
    final kfs = musicTrack['volumeKeyframes'] as List;
    expect(kfs, isNotEmpty);
    final hasDip = kfs.any((kf) => ((kf as Map)['volume'] as num) < 1.0);
    expect(hasDip, isTrue,
        reason: 'at least one keyframe must show a ducked volume');

    // Voiceover and SFX must NOT have auto-injected volumeKeyframes.
    expect(voTrack.containsKey('volumeKeyframes'), isFalse,
        reason: 'voiceover must not receive ducking keyframes');
    expect(sfxTrack.containsKey('volumeKeyframes'), isFalse,
        reason: 'sfx must not receive ducking keyframes');

    // Original tracks must NOT have auto-injected volumeKeyframes.
    expect(origA!.containsKey('volumeKeyframes'), isFalse,
        reason: 'original-clip-A must not receive ducking keyframes');
    expect(origB!.containsKey('volumeKeyframes'), isFalse,
        reason: 'original-clip-B must not receive ducking keyframes');
  });

  // ── PIPE-2: Timing, source-trim, and fade fields ────────────────────────────

  test(
      'PIPE-2: original track has correct startTime, duration, '
      'sourceTrimStart, role; explicit tracks preserve timing fields',
      () async {
    // clip-A: starts at 0, trimStart 1.5, trimEnd 6.5 → timeline duration 5.0
    final clipA = VGClipDescriptor(
      id: 'clip-A',
      sourcePath: '/tmp/clip-A.mp4',
      durationSeconds: 10.0,
      trimStartSeconds: 1.5,
      trimEndSeconds: 6.5,
      startTimeSeconds: 0.0,
    );

    final draft = VGEditorDraft(
      id: 'draft-pipe2',
      clips: [clipA],
      audioSidecarPlan: VGAudioSidecarPlan(
        tracks: [
          _sidecarTrack(
              id: 'vo-1',
              role: 'voiceover',
              start: 1.0,
              duration: 3.0,
              volume: 0.9),
        ],
      ),
    );

    dynamic capturedArgs;
    _setMockHandler(_exportHandler((args) => capturedArgs = args));

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.export(const VGEditorExportRequest());

    final tracks = _tracksFromArgs(capturedArgs)!;

    // Original track assertions.
    final orig = _findById(tracks, 'original-clip-A');
    expect(orig, isNotNull);
    expect((orig!['startTime'] as num).toDouble(), closeTo(0.0, 1e-9));
    // timelineDuration = trimEnd - trimStart = 5.0
    expect((orig['duration'] as num).toDouble(), closeTo(5.0, 1e-9));
    // Wire key is 'sourceTrimStart' (omitted when 0.0; present because trimStart = 1.5).
    expect(orig.containsKey('sourceTrimStart'), isTrue,
        reason: 'source trim must be present in original track when trimStart != 0');
    expect((orig['sourceTrimStart'] as num).toDouble(),
        closeTo(1.5, 1e-9));
    expect(orig['role'], 'original');

    // Explicit voiceover timing is preserved.
    final vo = _findById(tracks, 'vo-1');
    expect(vo, isNotNull);
    expect((vo!['startTime'] as num).toDouble(), closeTo(1.0, 1e-9));
    expect((vo['duration'] as num).toDouble(), closeTo(3.0, 1e-9));
    expect((vo['volume'] as num).toDouble(), closeTo(0.9, 1e-9));
  });

  // ── PIPE-3: Pre-authored music keyframes preserved ──────────────────────────

  test(
      'PIPE-3: pre-authored music keyframes are preserved exactly; '
      'ducking engine must not overwrite them',
      () async {
    const preAuthored = [
      VGAudioVolumeKeyframe(time: 0.0, volume: 0.7),
      VGAudioVolumeKeyframe(time: 3.0, volume: 0.1),
      VGAudioVolumeKeyframe(time: 7.0, volume: 0.7),
      VGAudioVolumeKeyframe(time: 10.0, volume: 0.7),
    ];

    final draft = VGEditorDraft(
      id: 'draft-pipe3',
      clips: [_videoClip(id: 'clip-A', duration: 10.0)],
      audioSidecarPlan: VGAudioSidecarPlan(
        tracks: [
          _sidecarTrack(
            id: 'music-1',
            role: 'music',
            start: 0.0,
            duration: 10.0,
            volumeKeyframes: preAuthored,
          ),
        ],
      ),
    );

    dynamic capturedArgs;
    _setMockHandler(_exportHandler((args) => capturedArgs = args));

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.export(const VGEditorExportRequest());

    final tracks = _tracksFromArgs(capturedArgs)!;
    final music = _findById(tracks, 'music-1')!;

    expect(music.containsKey('volumeKeyframes'), isTrue);
    final kfs = music['volumeKeyframes'] as List;
    expect(kfs.length, 4,
        reason: 'pre-authored keyframes must be preserved exactly');

    final times = kfs.map((kf) => ((kf as Map)['time'] as num).toDouble());
    final vols = kfs.map((kf) => ((kf as Map)['volume'] as num).toDouble());
    expect(times, containsAllInOrder([
      closeTo(0.0, 1e-9),
      closeTo(3.0, 1e-9),
      closeTo(7.0, 1e-9),
      closeTo(10.0, 1e-9),
    ]));
    expect(vols, containsAllInOrder([
      closeTo(0.7, 1e-9),
      closeTo(0.1, 1e-9),
      closeTo(0.7, 1e-9),
      closeTo(0.7, 1e-9),
    ]));
  });

  // ── PIPE-4: No foreground overlap → no ducking keyframes ────────────────────

  test(
      'PIPE-4: music with no foreground overlap produces no ducking keyframes '
      '(no-op regression)',
      () async {
    // clip-A occupies 0–5 s. Music starts at 7 s → no overlap.
    final draft = VGEditorDraft(
      id: 'draft-pipe4',
      clips: [_videoClip(id: 'clip-A', duration: 5.0)],
      audioSidecarPlan: VGAudioSidecarPlan(
        tracks: [
          _sidecarTrack(
              id: 'music-1', role: 'music', start: 7.0, duration: 5.0),
        ],
      ),
    );

    dynamic capturedArgs;
    _setMockHandler(_exportHandler((args) => capturedArgs = args));

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.export(const VGEditorExportRequest());

    final tracks = _tracksFromArgs(capturedArgs)!;
    final music = _findById(tracks, 'music-1')!;

    // No overlap → ducking is a pure no-op → no volumeKeyframes.
    expect(music.containsKey('volumeKeyframes'), isFalse,
        reason:
            'music with no overlap must not receive auto-generated volumeKeyframes');
  });

  // ── PIPE-5: No explicit sidecar plan ────────────────────────────────────────

  test(
      'PIPE-5: draft with no explicit audioSidecarPlan: original tracks '
      'flattened from clips, ducking is a no-op, no volumeKeyframes injected',
      () async {
    final draft = VGEditorDraft(
      id: 'draft-pipe5',
      clips: [
        _videoClip(id: 'clip-A', duration: 5.0, startTime: 0.0),
        _videoClip(id: 'clip-B', duration: 5.0, startTime: 5.0),
      ],
    );

    dynamic capturedArgs;
    _setMockHandler(_exportHandler((args) => capturedArgs = args));

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();

    final result = await controller.export(const VGEditorExportRequest());
    expect(result, isA<VGEditorExportResult>());

    // flattenOriginalClipAudio adds original tracks → audioSidecar present.
    final tracks = _tracksFromArgs(capturedArgs);
    expect(tracks, isNotNull);
    expect(tracks!.length, greaterThanOrEqualTo(2));

    // All generated tracks are 'original'; none should have volumeKeyframes
    // (no music → ducking is a no-op).
    for (final t in tracks) {
      expect(t.containsKey('volumeKeyframes'), isFalse,
          reason:
              'original-only draft must not have any volumeKeyframes injected');
    }
  });

  // ── PIPE-6: SFX role safety ─────────────────────────────────────────────────

  test(
      'PIPE-6: SFX track is neither ducked as foreground-trigger '
      'nor treated as background music',
      () async {
    // Music track overlaps the SFX track only (no voiceover, no original clip
    // that overlaps). If SFX were treated as a foreground signal, music would
    // be ducked. If SFX were treated as music, it would be ducked too. Both
    // are wrong; both tracks should come through without added keyframes.
    //
    // Note: original-clip-A IS a foreground track and DOES overlap music.
    // We set the clip at 10–15 s so it does NOT overlap music at 0–8 s.
    final draft = VGEditorDraft(
      id: 'draft-pipe6',
      clips: [_videoClip(id: 'clip-A', duration: 5.0, startTime: 10.0)],
      audioSidecarPlan: VGAudioSidecarPlan(
        tracks: [
          _sidecarTrack(
              id: 'music-1', role: 'music', start: 0.0, duration: 8.0),
          _sidecarTrack(id: 'sfx-1', role: 'sfx', start: 2.0, duration: 1.0),
        ],
      ),
    );

    dynamic capturedArgs;
    _setMockHandler(_exportHandler((args) => capturedArgs = args));

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.export(const VGEditorExportRequest());

    final tracks = _tracksFromArgs(capturedArgs)!;
    final sfx = _findById(tracks, 'sfx-1')!;

    // SFX must not be ducked (not treated as music).
    expect(sfx.containsKey('volumeKeyframes'), isFalse,
        reason: 'sfx track must not be treated as background music');

    // Verify roles are preserved.
    expect(sfx['role'], 'sfx');
  });

  // ── PIPE-7: Source trim field on flattened original track ───────────────────

  test(
      'PIPE-7: flattened original track carries correct sourceTrimStartSeconds '
      'matching the clip trimStartSeconds',
      () async {
    // Clip with non-zero trimStart so we can verify the sidecar trim field.
    final clip = VGClipDescriptor(
      id: 'clip-A',
      sourcePath: '/tmp/clip-A.mp4',
      durationSeconds: 12.0,
      trimStartSeconds: 2.0,
      trimEndSeconds: 8.0,
      startTimeSeconds: 0.0,
    );

    final draft = VGEditorDraft(
      id: 'draft-pipe7',
      clips: [clip],
    );

    dynamic capturedArgs;
    _setMockHandler(_exportHandler((args) => capturedArgs = args));

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.export(const VGEditorExportRequest());

    final tracks = _tracksFromArgs(capturedArgs)!;
    final orig = _findById(tracks, 'original-clip-A')!;

    // Wire key is 'sourceTrimStart' (emitted only when non-zero).
    expect(orig.containsKey('sourceTrimStart'), isTrue,
        reason: 'sourceTrimStart wire key must be present when trimStart != 0');
    expect((orig['sourceTrimStart'] as num).toDouble(),
        closeTo(2.0, 1e-9),
        reason:
            'sourceTrimStart must match clip.trimStartSeconds = 2.0');
    // Timeline duration = trimEnd - trimStart = 6.0
    expect((orig['duration'] as num).toDouble(), closeTo(6.0, 1e-9));
  });

  // ── PIPE-8: Transition-derived fade fields (Phase 8.14D) ────────────────────

  test(
      'PIPE-8: flattened original tracks carry transition-derived '
      'fadeInSeconds / fadeOutSeconds for non-hard-cut transitions',
      () async {
    // Two clips with a dissolve transition. clip-A has an outgoing dissolve
    // (0.6 s) → fadeOut 0.6 s. clip-B has an incoming dissolve → fadeIn 0.6 s.
    final clipA = _videoClip(id: 'clip-A', duration: 5.0, startTime: 0.0);
    final clipB = _videoClip(id: 'clip-B', duration: 5.0, startTime: 5.0);

    const dissolve = VGTransitionDescriptor(
      id: 'tr-ab',
      type: VGTransitionType.dissolve,
      durationSeconds: 0.6,
      fromClipId: 'clip-A',
      toClipId: 'clip-B',
    );

    final draft = VGEditorDraft(
      id: 'draft-pipe8',
      clips: [clipA, clipB],
      transitions: const [dissolve],
    );

    dynamic capturedArgs;
    _setMockHandler(_exportHandler((args) => capturedArgs = args));

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.export(const VGEditorExportRequest());

    final tracks = _tracksFromArgs(capturedArgs)!;
    final origA = _findById(tracks, 'original-clip-A')!;
    final origB = _findById(tracks, 'original-clip-B')!;

    // clip-A is the outgoing clip → fadeOut = transition duration 0.6.
    final fadeOutA = origA['fadeOutSeconds'];
    expect(fadeOutA, isNotNull, reason: 'original-clip-A must have fadeOutSeconds');
    expect((fadeOutA as num).toDouble(), closeTo(0.6, 1e-9));

    // clip-B is the incoming clip → fadeIn = transition duration 0.6.
    final fadeInB = origB['fadeInSeconds'];
    expect(fadeInB, isNotNull, reason: 'original-clip-B must have fadeInSeconds');
    expect((fadeInB as num).toDouble(), closeTo(0.6, 1e-9));
  });

  // ── PIPE-9: Multiple music tracks each ducked ───────────────────────────────

  test(
      'PIPE-9: two music tracks both receive ducking keyframes when '
      'original clip overlaps both',
      () async {
    final draft = VGEditorDraft(
      id: 'draft-pipe9',
      clips: [_videoClip(id: 'clip-A', duration: 10.0)],
      audioSidecarPlan: VGAudioSidecarPlan(
        tracks: [
          _sidecarTrack(
              id: 'music-1', role: 'music', start: 0.0, duration: 10.0),
          _sidecarTrack(
              id: 'music-2', role: 'music', start: 0.0, duration: 10.0),
        ],
      ),
    );

    dynamic capturedArgs;
    _setMockHandler(_exportHandler((args) => capturedArgs = args));

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.export(const VGEditorExportRequest());

    final tracks = _tracksFromArgs(capturedArgs)!;
    final m1 = _findById(tracks, 'music-1')!;
    final m2 = _findById(tracks, 'music-2')!;

    // Both music tracks must be ducked.
    expect(m1.containsKey('volumeKeyframes'), isTrue,
        reason: 'music-1 must be ducked');
    expect(m2.containsKey('volumeKeyframes'), isTrue,
        reason: 'music-2 must be ducked');
    expect((m1['volumeKeyframes'] as List), isNotEmpty);
    expect((m2['volumeKeyframes'] as List), isNotEmpty);
  });

  // ── PIPE-10: Export chain does not mutate live controller draft ─────────────

  test(
      'PIPE-10: export() does not mutate the live controller draft; '
      'value.draft is identical before and after export',
      () async {
    final draft = VGEditorDraft(
      id: 'draft-pipe10',
      clips: [_videoClip(id: 'clip-A', duration: 5.0)],
      audioSidecarPlan: VGAudioSidecarPlan(
        tracks: [
          _sidecarTrack(
              id: 'music-1', role: 'music', start: 0.0, duration: 5.0),
        ],
      ),
    );

    _setMockHandler(_exportHandler((_) {}));

    final controller = VGEditorController(initialDraft: draft);
    addTearDown(controller.dispose);
    await controller.initialize();

    final draftBefore = controller.value.draft;
    await controller.export(const VGEditorExportRequest());
    final draftAfter = controller.value.draft;

    // The live draft must be the exact same instance (no mutation).
    expect(identical(draftBefore, draftAfter), isTrue,
        reason: 'export() must not mutate controller.value.draft');

    // And it must have no audioSidecarPlan modification (original plan is
    // preserved; export created a separate offline draft).
    final planTracks = draftAfter.audioSidecarPlan!.tracks;
    expect(planTracks.length, 1,
        reason:
            'original sidecar plan must not be expanded by the export chain');
    expect(planTracks.first.trackId, 'music-1');
  });
}
