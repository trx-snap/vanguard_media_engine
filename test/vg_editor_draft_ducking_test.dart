// vg_editor_draft_ducking_test.dart
// Vanguard Media Engine — Phase 8.19 Audio Ducking Engine Draft Integration
//
// Pure Dart unit tests for VGEditorDraft.applyAudioDucking().
// Verifies that the method correctly delegates to VGAudioDuckingEngine
// and produces the expected non-destructive, model-level results.
//
// Tests:
//   DUCK-1  draft with no audioSidecarPlan returns the same instance
//   DUCK-2  draft with empty sidecar tracks is not possible (assertion guard)
//   DUCK-3  draft with music only returns this (no foreground intervals)
//   DUCK-4  draft with voiceover only returns this (no music to duck)
//   DUCK-5  draft with music + voiceover applies keyframes to the music track
//   DUCK-6  custom VGAudioDuckingConfig is respected
//   DUCK-7  original draft/plan/tracks are not mutated
//   DUCK-8  non-audio draft fields are preserved exactly
//   DUCK-9  existing music track keyframes are preserved (not overwritten)
//   DUCK-10 returned draft non-audio fields are identity-preserved
//   DUCK-11 music + original role applies keyframes
//   DUCK-12 draft with music + non-overlapping voiceover returns this

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_audio_ducking_engine.dart';
import 'package:vanguard_media_engine/vg_audio_sidecar_plan.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';

// ── Test fixtures ─────────────────────────────────────────────────────────────

VGClipDescriptor _clip({String id = 'clip-A'}) => VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/clip.mp4',
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
    );

VGEditorDraft _draft({VGAudioSidecarPlan? audioSidecarPlan}) => VGEditorDraft(
      id: 'draft-ducking-test',
      clips: [_clip()],
      canvasWidth: 1080,
      canvasHeight: 1920,
      audioSidecarPlan: audioSidecarPlan,
    );

VGAudioSidecarTrack _musicTrack({
  String trackId = 'music-1',
  double startTime = 0.0,
  double duration = 10.0,
  double volume = 0.8,
  List<VGAudioVolumeKeyframe>? volumeKeyframes,
}) =>
    VGAudioSidecarTrack(
      trackId: trackId,
      url: '/tmp/music.m4a',
      startTime: startTime,
      duration: duration,
      volume: volume,
      role: 'music',
      volumeKeyframes: volumeKeyframes,
    );

VGAudioSidecarTrack _voiceoverTrack({
  String trackId = 'vo-1',
  double startTime = 2.0,
  double duration = 4.0,
}) =>
    VGAudioSidecarTrack(
      trackId: trackId,
      url: '/tmp/voiceover.m4a',
      startTime: startTime,
      duration: duration,
      volume: 1.0,
      role: 'voiceover',
    );

VGAudioSidecarTrack _originalTrack({
  String trackId = 'original-clip-A',
  double startTime = 0.0,
  double duration = 5.0,
}) =>
    VGAudioSidecarTrack(
      trackId: trackId,
      url: '/tmp/clip.mp4',
      startTime: startTime,
      duration: duration,
      volume: 1.0,
      role: 'original',
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── DUCK-1 ────────────────────────────────────────────────────────────────
  test('DUCK-1: draft with no audioSidecarPlan returns the same instance', () {
    final draft = _draft();
    expect(draft.audioSidecarPlan, isNull);
    final result = draft.applyAudioDucking();
    expect(identical(result, draft), isTrue,
        reason: 'Should return this when audioSidecarPlan is null');
  });

  // ── DUCK-3 ────────────────────────────────────────────────────────────────
  test('DUCK-3: draft with music only returns this (no foreground intervals)',
      () {
    final plan = VGAudioSidecarPlan(tracks: [_musicTrack()]);
    final draft = _draft(audioSidecarPlan: plan);
    final result = draft.applyAudioDucking();
    expect(identical(result, draft), isTrue,
        reason:
            'Music-only plan has no foreground intervals — engine should not duck');
  });

  // ── DUCK-4 ────────────────────────────────────────────────────────────────
  test('DUCK-4: draft with voiceover only returns this (no music to duck)', () {
    final plan = VGAudioSidecarPlan(tracks: [_voiceoverTrack()]);
    final draft = _draft(audioSidecarPlan: plan);
    final result = draft.applyAudioDucking();
    expect(identical(result, draft), isTrue,
        reason:
            'Voiceover-only plan has no music tracks — engine should not change anything');
  });

  // ── DUCK-5 ────────────────────────────────────────────────────────────────
  test('DUCK-5: draft with music + voiceover applies keyframes to music track',
      () {
    final music = _musicTrack(startTime: 0.0, duration: 10.0);
    final vo = _voiceoverTrack(startTime: 2.0, duration: 4.0);
    final plan = VGAudioSidecarPlan(tracks: [music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    final result = draft.applyAudioDucking();

    expect(identical(result, draft), isFalse,
        reason: 'Music track should have been modified by ducking');

    final resultPlan = result.audioSidecarPlan;
    expect(resultPlan, isNotNull);
    expect(resultPlan!.tracks.length, 2);

    final resultMusic = resultPlan.tracks.firstWhere((t) => t.role == 'music');
    final resultVo =
        resultPlan.tracks.firstWhere((t) => t.role == 'voiceover');

    // Music track should now have keyframes.
    expect(resultMusic.volumeKeyframes, isNotNull);
    expect(resultMusic.volumeKeyframes!.isNotEmpty, isTrue,
        reason: 'Ducking should have added volume keyframes to music track');

    // Voiceover track should be unchanged.
    expect(resultVo, equals(vo));

    // Keyframes must contain a duck point (volume < 0.8 = original volume).
    final hasDuckPoint =
        resultMusic.volumeKeyframes!.any((kf) => kf.volume < music.volume);
    expect(hasDuckPoint, isTrue,
        reason: 'At least one keyframe should have a volume < original');
  });

  // ── DUCK-6 ────────────────────────────────────────────────────────────────
  test('DUCK-6: custom VGAudioDuckingConfig is respected', () {
    const customConfig = VGAudioDuckingConfig(
      duckVolume: 0.1,
      attackSeconds: 0.05,
      releaseSeconds: 0.1,
      mergeGapSeconds: 0.01,
    );
    final music = _musicTrack(startTime: 0.0, duration: 10.0);
    final vo = _voiceoverTrack(startTime: 2.0, duration: 4.0);
    final plan = VGAudioSidecarPlan(tracks: [music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    final result = draft.applyAudioDucking(config: customConfig);
    final resultMusic = result.audioSidecarPlan!.tracks
        .firstWhere((t) => t.role == 'music');

    expect(resultMusic.volumeKeyframes, isNotNull);

    // With duckVolume=0.1, the minimum volume in keyframes should be 0.1.
    final minVolume = resultMusic.volumeKeyframes!
        .map((kf) => kf.volume)
        .reduce((a, b) => a < b ? a : b);
    expect(minVolume, closeTo(0.1, 1e-9),
        reason:
            'The minimum keyframe volume should equal the custom duckVolume');
  });

  // ── DUCK-7 ────────────────────────────────────────────────────────────────
  test('DUCK-7: original draft/plan/tracks are not mutated', () {
    final music = _musicTrack();
    final vo = _voiceoverTrack();
    final plan = VGAudioSidecarPlan(tracks: [music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    // Capture original state.
    final originalTracks = List<VGAudioSidecarTrack>.from(plan.tracks);
    final originalMusicKeyframes = music.volumeKeyframes;

    draft.applyAudioDucking();

    // Original plan should not be mutated.
    expect(plan.tracks.length, originalTracks.length);
    expect(plan.tracks[0], equals(music));
    expect(music.volumeKeyframes, equals(originalMusicKeyframes));

    // Original draft should not be mutated.
    expect(draft.audioSidecarPlan, same(plan));
    expect(draft.audioSidecarPlan!.tracks, same(plan.tracks));
  });

  // ── DUCK-8 ────────────────────────────────────────────────────────────────
  test('DUCK-8: non-audio draft fields are preserved exactly', () {
    final music = _musicTrack();
    final vo = _voiceoverTrack();
    final plan = VGAudioSidecarPlan(tracks: [music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    final result = draft.applyAudioDucking();

    // All non-audio fields must have the same values.
    expect(result.id, draft.id);
    expect(result.clips, equals(draft.clips));
    expect(result.transitions, equals(draft.transitions));
    expect(result.canvasWidth, draft.canvasWidth);
    expect(result.canvasHeight, draft.canvasHeight);
    expect(result.fps, draft.fps);
    expect(result.canvas, draft.canvas);
    expect(result.overlays, equals(draft.overlays));
    // Only audioSidecarPlan differs — confirm it is not the same object.
    expect(identical(result.audioSidecarPlan, draft.audioSidecarPlan), isFalse,
        reason: 'New audioSidecarPlan instance should be returned after ducking');
  });

  // ── DUCK-9 ────────────────────────────────────────────────────────────────
  test('DUCK-9: existing music track keyframes are preserved (not overwritten)',
      () {
    // Pre-authored keyframes: the engine must not overwrite these.
    final preAuthoredKeyframes = [
      const VGAudioVolumeKeyframe(time: 0.0, volume: 0.8),
      const VGAudioVolumeKeyframe(time: 5.0, volume: 0.3),
      const VGAudioVolumeKeyframe(time: 10.0, volume: 0.8),
    ];
    final music =
        _musicTrack(volumeKeyframes: preAuthoredKeyframes);
    final vo = _voiceoverTrack(startTime: 2.0, duration: 4.0);
    final plan = VGAudioSidecarPlan(tracks: [music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    // With pre-authored keyframes, the engine skips the track.
    // The plan should be unchanged → returns this.
    final result = draft.applyAudioDucking();
    expect(identical(result, draft), isTrue,
        reason:
            'Music track with pre-authored keyframes must not be modified — engine should skip it');
  });

  // ── DUCK-10 ───────────────────────────────────────────────────────────────
  test(
      'DUCK-10: returned draft non-audio fields have equal values when unchanged',
      () {
    final music = _musicTrack();
    final vo = _voiceoverTrack();
    final plan = VGAudioSidecarPlan(tracks: [music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    final result = draft.applyAudioDucking();

    // copyWith passes through the same underlying clip/transition/overlay
    // data; the VGEditorDraft constructor wraps in List.unmodifiable so
    // reference identity is not guaranteed. Value equality is the correct check.
    expect(result.clips, equals(draft.clips));
    expect(result.transitions, equals(draft.transitions));
    expect(result.overlays, equals(draft.overlays));
    expect(result.canvasWidth, draft.canvasWidth);
    expect(result.canvasHeight, draft.canvasHeight);
    expect(result.fps, draft.fps);
  });

  // ── DUCK-11 ───────────────────────────────────────────────────────────────
  test('DUCK-11: music + original role applies keyframes to music track', () {
    final music = _musicTrack(startTime: 0.0, duration: 10.0);
    final original = _originalTrack(startTime: 1.0, duration: 5.0);
    final plan = VGAudioSidecarPlan(tracks: [music, original]);
    final draft = _draft(audioSidecarPlan: plan);

    final result = draft.applyAudioDucking();
    expect(identical(result, draft), isFalse,
        reason: 'Original role is a foreground role and should trigger ducking');

    final resultMusic = result.audioSidecarPlan!.tracks
        .firstWhere((t) => t.role == 'music');
    expect(resultMusic.volumeKeyframes, isNotNull);
    expect(resultMusic.volumeKeyframes!.isNotEmpty, isTrue);
  });

  // ── DUCK-12 ───────────────────────────────────────────────────────────────
  test(
      'DUCK-12: music + non-overlapping voiceover returns this (no overlap)',
      () {
    // Music plays 0–3s. Voiceover plays 5–8s. No overlap.
    final music = _musicTrack(startTime: 0.0, duration: 3.0);
    final vo = _voiceoverTrack(startTime: 5.0, duration: 3.0);
    final plan = VGAudioSidecarPlan(tracks: [music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    final result = draft.applyAudioDucking();
    expect(identical(result, draft), isTrue,
        reason:
            'No overlap between music and voiceover — engine should return unchanged tracks');
  });
}
