// vg_editor_draft_ducking_test.dart
// Vanguard Media Engine — Phase 10-C Slice B Audio Composition Policy
//
// Pure Dart unit tests for VGEditorDraft.applyAudioCompositionPolicy().
// Verifies static Original muting, VO-triggered ducking, ownership boundary,
// role classification, and backward-compatible applyAudioDucking() wrapper.
//
// Tests:
//   POLICY-1   draft with no audioSidecarPlan returns the same instance
//   POLICY-2   Original-only: non-unity volume is preserved unchanged
//   POLICY-3   Original-only: explicit zero remains explicit zero
//   POLICY-4   Original-only: existing keyframes and fades remain unchanged
//   POLICY-5   Original + music: derived Original volume is 0.0
//   POLICY-6   Original + sfx: derived Original volume is 0.0
//   POLICY-7   Original + voiceover: derived Original volume is 0.0
//   POLICY-8   Derived muted Original contains no automation
//   POLICY-9   Raw Original keyframes remain intact in source draft
//   POLICY-10  Original + music + voiceover: Original zero, music ducks
//   POLICY-11  Original + sfx + voiceover: Original zero, sfx ducks
//   POLICY-12  Added + voiceover without Original works
//   POLICY-13  Null and unknown roles do not cause muting alone
//   POLICY-14  Null role not ducked
//   POLICY-15  Unknown role not ducked
//   POLICY-16  Voiceover track remains unchanged
//   POLICY-17  Raw plan is deeply unchanged after normalization
//   POLICY-18  Separate derived draft returned when changes occur
//   POLICY-19  All non-audio draft fields are preserved
//   POLICY-20  Track ordering, IDs, timing are preserved in derived output
//   POLICY-21  Same raw input produces equal derived output (repeatability)
//   POLICY-22  applyAudioDucking wrapper produces same result as applyAudioCompositionPolicy
//   POLICY-23  Explicit zero semantics are protected
//   POLICY-24  Existing music keyframes are preserved; ducking skipped
//   POLICY-25  Multiple voiceover intervals merge correctly
//   POLICY-26  Custom duckingConfig is respected

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
      id: 'draft-policy-test',
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

VGAudioSidecarTrack _sfxTrack({
  String trackId = 'sfx-1',
  double startTime = 0.0,
  double duration = 5.0,
  double volume = 1.0,
}) =>
    VGAudioSidecarTrack(
      trackId: trackId,
      url: '/tmp/sfx.m4a',
      startTime: startTime,
      duration: duration,
      volume: volume,
      role: 'sfx',
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
  double duration = 10.0,
  double volume = 1.0,
  double fadeInSeconds = 0.0,
  double fadeOutSeconds = 0.0,
  List<VGAudioVolumeKeyframe>? volumeKeyframes,
}) =>
    VGAudioSidecarTrack(
      trackId: trackId,
      url: '/tmp/clip.mp4',
      startTime: startTime,
      duration: duration,
      volume: volume,
      role: 'original',
      fadeInSeconds: fadeInSeconds,
      fadeOutSeconds: fadeOutSeconds,
      volumeKeyframes: volumeKeyframes,
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── POLICY-1 ──────────────────────────────────────────────────────────────
  test('POLICY-1: draft with no audioSidecarPlan returns the same instance',
      () {
    final draft = _draft();
    expect(draft.audioSidecarPlan, isNull);
    final result = draft.applyAudioCompositionPolicy();
    expect(identical(result, draft), isTrue,
        reason: 'Should return this when audioSidecarPlan is null');
  });

  // ── POLICY-2 ──────────────────────────────────────────────────────────────
  test('POLICY-2: Original-only plan preserves non-unity volume unchanged', () {
    // Volume 0.6 — not 1.0, not 0.0. Must survive the policy pass unchanged.
    final orig = _originalTrack(volume: 0.6);
    final draft = _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig]));
    final result = draft.applyAudioCompositionPolicy();
    // No VO, no Added → no muting → returns this.
    expect(identical(result, draft), isTrue,
        reason: 'Original-only plan with no VO/Added must be preserved exactly');
    final resultOrig = result.audioSidecarPlan!.tracks.first;
    expect(resultOrig.volume, closeTo(0.6, 1e-9),
        reason: 'Non-unity volume must not be forced to 0.0 or 1.0');
  });

  // ── POLICY-3 ──────────────────────────────────────────────────────────────
  test('POLICY-3: Original-only explicit zero remains zero', () {
    final orig = _originalTrack(volume: 0.0);
    final draft = _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig]));
    final result = draft.applyAudioCompositionPolicy();
    // No VO, no Added → no change → returns this.
    expect(identical(result, draft), isTrue);
    expect(result.audioSidecarPlan!.tracks.first.volume, closeTo(0.0, 1e-9),
        reason: 'Explicit zero must not be changed');
  });

  // ── POLICY-4 ──────────────────────────────────────────────────────────────
  test('POLICY-4: Original-only existing keyframes and fades remain unchanged',
      () {
    final kfs = [
      const VGAudioVolumeKeyframe(time: 0.0, volume: 0.9),
      const VGAudioVolumeKeyframe(time: 5.0, volume: 0.5),
    ];
    final orig = _originalTrack(
      fadeInSeconds: 1.0,
      fadeOutSeconds: 0.5,
      volumeKeyframes: kfs,
    );
    final draft = _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig]));
    final result = draft.applyAudioCompositionPolicy();
    expect(identical(result, draft), isTrue,
        reason:
            'Original-only plan with no VO/Added must be identical — no automation cleared');
    final resultTrack = result.audioSidecarPlan!.tracks.first;
    expect(resultTrack.fadeInSeconds, closeTo(1.0, 1e-9));
    expect(resultTrack.fadeOutSeconds, closeTo(0.5, 1e-9));
    expect(resultTrack.volumeKeyframes, isNotNull);
    expect(resultTrack.volumeKeyframes!.length, 2);
  });

  // ── POLICY-5 ──────────────────────────────────────────────────────────────
  test('POLICY-5: Original + music — derived Original volume is 0.0', () {
    final orig = _originalTrack();
    final music = _musicTrack();
    final draft =
        _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig, music]));
    final result = draft.applyAudioCompositionPolicy();
    expect(identical(result, draft), isFalse);
    final resultOrig =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'original');
    expect(resultOrig.volume, closeTo(0.0, 1e-9),
        reason: 'Original must be zeroed in derived output when music exists');
  });

  // ── POLICY-6 ──────────────────────────────────────────────────────────────
  test('POLICY-6: Original + sfx — derived Original volume is 0.0', () {
    final orig = _originalTrack();
    final sfx = _sfxTrack();
    final draft =
        _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig, sfx]));
    final result = draft.applyAudioCompositionPolicy();
    final resultOrig =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'original');
    expect(resultOrig.volume, closeTo(0.0, 1e-9),
        reason: 'Original must be zeroed in derived output when sfx exists');
  });

  // ── POLICY-7 ──────────────────────────────────────────────────────────────
  test('POLICY-7: Original + voiceover — derived Original volume is 0.0', () {
    final orig = _originalTrack();
    final vo = _voiceoverTrack();
    final draft =
        _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig, vo]));
    final result = draft.applyAudioCompositionPolicy();
    final resultOrig =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'original');
    expect(resultOrig.volume, closeTo(0.0, 1e-9),
        reason: 'Original must be zeroed in derived output when voiceover exists');
  });

  // ── POLICY-8 ──────────────────────────────────────────────────────────────
  test(
      'POLICY-8: Derived muted Original has no automation capable of raising it above zero',
      () {
    final kfs = [
      const VGAudioVolumeKeyframe(time: 0.0, volume: 0.9),
      const VGAudioVolumeKeyframe(time: 5.0, volume: 1.0),
    ];
    final orig = _originalTrack(volumeKeyframes: kfs);
    final vo = _voiceoverTrack();
    final draft =
        _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig, vo]));
    final result = draft.applyAudioCompositionPolicy();
    final derivedOrig =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'original');
    // Derived Original must have volume 0.0 and no keyframes.
    expect(derivedOrig.volume, closeTo(0.0, 1e-9));
    expect(derivedOrig.volumeKeyframes, isNull,
        reason:
            'Derived muted Original must have null keyframes so no automation can restore it');
  });

  // ── POLICY-9 ──────────────────────────────────────────────────────────────
  test('POLICY-9: Raw Original keyframes remain intact in source draft', () {
    final kfs = [
      const VGAudioVolumeKeyframe(time: 0.0, volume: 0.9),
      const VGAudioVolumeKeyframe(time: 5.0, volume: 0.5),
    ];
    final orig = _originalTrack(volumeKeyframes: kfs);
    final vo = _voiceoverTrack();
    final plan = VGAudioSidecarPlan(tracks: [orig, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    draft.applyAudioCompositionPolicy(); // must not mutate source

    // Raw track object still has original keyframes.
    expect(orig.volumeKeyframes, isNotNull);
    expect(orig.volumeKeyframes!.length, 2);
    expect(orig.volume, closeTo(1.0, 1e-9),
        reason: 'Raw authoring Original must not be mutated');
    // Raw plan is unchanged.
    expect(draft.audioSidecarPlan, same(plan));
  });

  // ── POLICY-10 ─────────────────────────────────────────────────────────────
  test('POLICY-10: Original + music + voiceover — Original zeroed, music ducks',
      () {
    final orig = _originalTrack();
    final music = _musicTrack(startTime: 0.0, duration: 10.0);
    final vo = _voiceoverTrack(startTime: 2.0, duration: 4.0);
    final draft = _draft(
        audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig, music, vo]));

    final result = draft.applyAudioCompositionPolicy();

    final resultOrig =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'original');
    final resultMusic =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'music');
    final resultVo =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'voiceover');

    expect(resultOrig.volume, closeTo(0.0, 1e-9));
    expect(resultOrig.volumeKeyframes, isNull);
    expect(resultMusic.volumeKeyframes, isNotNull);
    expect(resultMusic.volumeKeyframes!.any((kf) => kf.volume < 0.5), isTrue);
    // VO unchanged.
    expect(identical(resultVo, vo), isTrue);
  });

  // ── POLICY-11 ─────────────────────────────────────────────────────────────
  test('POLICY-11: Original + sfx + voiceover — Original zeroed, sfx ducks',
      () {
    final orig = _originalTrack();
    final sfx = _sfxTrack(startTime: 0.0, duration: 5.0);
    final vo = _voiceoverTrack(startTime: 1.0, duration: 3.0);
    final draft = _draft(
        audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig, sfx, vo]));

    final result = draft.applyAudioCompositionPolicy();

    final resultOrig =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'original');
    final resultSfx =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'sfx');

    expect(resultOrig.volume, closeTo(0.0, 1e-9));
    expect(resultOrig.volumeKeyframes, isNull);
    expect(resultSfx.volumeKeyframes, isNotNull);
    expect(resultSfx.volumeKeyframes!.any((kf) => kf.volume < 0.5), isTrue);
  });

  // ── POLICY-12 ─────────────────────────────────────────────────────────────
  test('POLICY-12: Added + voiceover without Original works', () {
    final music = _musicTrack(startTime: 0.0, duration: 10.0);
    final vo = _voiceoverTrack(startTime: 2.0, duration: 4.0);
    final draft =
        _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [music, vo]));

    final result = draft.applyAudioCompositionPolicy();
    // Music should duck under VO.
    final resultMusic =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'music');
    expect(resultMusic.volumeKeyframes, isNotNull);
    expect(resultMusic.volumeKeyframes!.any((kf) => kf.volume < 0.5), isTrue);
  });

  // ── POLICY-13 ─────────────────────────────────────────────────────────────
  test(
      'POLICY-13: Null and unknown roles alone do not cause Original muting',
      () {
    // Arrange: only Original + an unknown role track. No VO, no known Added.
    final orig = _originalTrack(volume: 0.7);
    final unknown = VGAudioSidecarTrack(
      trackId: 'unknown-1',
      url: '/tmp/imported.m4a',
      startTime: 0.0,
      duration: 5.0,
      role: 'imported_audio', // unknown role
    );
    final draft =
        _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig, unknown]));

    final result = draft.applyAudioCompositionPolicy();
    // No muting because no known Added (music/sfx) or VO.
    expect(identical(result, draft), isTrue,
        reason:
            'Unknown roles must not trigger Original muting');
    expect(result.audioSidecarPlan!.tracks
            .firstWhere((t) => t.role == 'original')
            .volume,
        closeTo(0.7, 1e-9));
  });

  // ── POLICY-14 ─────────────────────────────────────────────────────────────
  test('POLICY-14: Null-role track is not ducked under voiceover', () {
    final nullRole = VGAudioSidecarTrack(
      trackId: 'ambient',
      url: '/tmp/ambient.m4a',
      startTime: 0.0,
      duration: 10.0,
      // role intentionally omitted (null)
    );
    final vo = _voiceoverTrack();
    final draft =
        _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [nullRole, vo]));

    final result = draft.applyAudioCompositionPolicy();
    final resultNullRole =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.trackId == 'ambient');
    expect(resultNullRole.volumeKeyframes, isNull,
        reason: 'null-role track must not receive ducking keyframes');
  });

  // ── POLICY-15 ─────────────────────────────────────────────────────────────
  test('POLICY-15: Unknown role string is not ducked under voiceover', () {
    final unknown = VGAudioSidecarTrack(
      trackId: 'unknown-2',
      url: '/tmp/unknown.m4a',
      startTime: 0.0,
      duration: 5.0,
      role: 'extracted_audio', // unknown string
    );
    final vo = _voiceoverTrack();
    final draft =
        _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [unknown, vo]));

    final result = draft.applyAudioCompositionPolicy();
    final resultUnknown =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.trackId == 'unknown-2');
    expect(resultUnknown.volumeKeyframes, isNull,
        reason: 'unknown role must not receive ducking keyframes');
  });

  // ── POLICY-16 ─────────────────────────────────────────────────────────────
  test('POLICY-16: Voiceover track is preserved unchanged in derived output',
      () {
    final vo = _voiceoverTrack();
    final music = _musicTrack();
    final draft =
        _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [music, vo]));
    final result = draft.applyAudioCompositionPolicy();
    final resultVo =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'voiceover');
    // Voiceover track object must be the identical input object (not ducked,
    // not replaced, not muted).
    expect(identical(resultVo, vo), isTrue,
        reason: 'voiceover must be preserved identically in derived output');
  });

  // ── POLICY-17 ─────────────────────────────────────────────────────────────
  test('POLICY-17: Raw plan is deeply unchanged after normalization', () {
    final orig = _originalTrack();
    final music = _musicTrack();
    final vo = _voiceoverTrack();
    final plan = VGAudioSidecarPlan(tracks: [orig, music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    // Capture raw state.
    final rawOrigVolume = orig.volume;
    final rawMusicKeyframes = music.volumeKeyframes;

    draft.applyAudioCompositionPolicy();

    // Raw plan reference unchanged.
    expect(draft.audioSidecarPlan, same(plan));
    // Raw track objects unchanged.
    expect(orig.volume, closeTo(rawOrigVolume, 1e-9));
    expect(music.volumeKeyframes, equals(rawMusicKeyframes));
    expect(plan.tracks.length, 3);
  });

  // ── POLICY-18 ─────────────────────────────────────────────────────────────
  test('POLICY-18: Separate derived draft returned when normalization changes audio',
      () {
    final orig = _originalTrack();
    final vo = _voiceoverTrack();
    final plan = VGAudioSidecarPlan(tracks: [orig, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    final result = draft.applyAudioCompositionPolicy();
    // Different instance because Original was zeroed.
    expect(identical(result, draft), isFalse);
    // Original plan and derived plan are different instances.
    expect(identical(result.audioSidecarPlan, plan), isFalse);
  });

  // ── POLICY-19 ─────────────────────────────────────────────────────────────
  test('POLICY-19: All non-audio draft fields are preserved in derived output',
      () {
    final orig = _originalTrack();
    final vo = _voiceoverTrack();
    final draft = _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig, vo]));

    final result = draft.applyAudioCompositionPolicy();

    expect(result.id, draft.id);
    expect(result.clips, equals(draft.clips));
    expect(result.transitions, equals(draft.transitions));
    expect(result.canvasWidth, draft.canvasWidth);
    expect(result.canvasHeight, draft.canvasHeight);
    expect(result.fps, draft.fps);
    expect(result.canvas, draft.canvas);
    expect(result.overlays, equals(draft.overlays));
  });

  // ── POLICY-20 ─────────────────────────────────────────────────────────────
  test(
      'POLICY-20: Track ordering, IDs, timing, and fades are preserved in derived output',
      () {
    final orig = _originalTrack(
        trackId: 'original-clip-A', startTime: 0.0, duration: 10.0,
        fadeInSeconds: 0.5, fadeOutSeconds: 0.3);
    final music = _musicTrack(trackId: 'music-1', startTime: 0.0, duration: 10.0);
    final vo = _voiceoverTrack(trackId: 'vo-1', startTime: 2.0, duration: 4.0);
    final draft = _draft(
        audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig, music, vo]));

    final result = draft.applyAudioCompositionPolicy();
    final tracks = result.audioSidecarPlan!.tracks;

    expect(tracks.length, 3);
    expect(tracks[0].trackId, 'original-clip-A');
    expect(tracks[1].trackId, 'music-1');
    expect(tracks[2].trackId, 'vo-1');
    // Fades on derived Original track must be preserved.
    expect(tracks[0].fadeInSeconds, closeTo(0.5, 1e-9));
    expect(tracks[0].fadeOutSeconds, closeTo(0.3, 1e-9));
    // Timing preserved.
    expect(tracks[0].startTime, closeTo(0.0, 1e-9));
    expect(tracks[0].duration, closeTo(10.0, 1e-9));
  });

  // ── POLICY-21 ─────────────────────────────────────────────────────────────
  test(
      'POLICY-21: Same raw input produces structurally equal derived output (repeatability)',
      () {
    final orig = _originalTrack();
    final music = _musicTrack(startTime: 0.0, duration: 10.0);
    final vo = _voiceoverTrack(startTime: 2.0, duration: 4.0);
    final plan = VGAudioSidecarPlan(tracks: [orig, music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    // Apply twice from the same raw draft (not from the result).
    final result1 = draft.applyAudioCompositionPolicy();
    final result2 = draft.applyAudioCompositionPolicy();

    // The two derived outputs must be structurally equal.
    expect(result1.audioSidecarPlan, equals(result2.audioSidecarPlan),
        reason:
            'Repeated normalization from the same raw draft must produce equal output');
  });

  // ── POLICY-22 ─────────────────────────────────────────────────────────────
  test(
      'POLICY-22: applyAudioDucking wrapper produces the same result as applyAudioCompositionPolicy',
      () {
    final orig = _originalTrack();
    final music = _musicTrack(startTime: 0.0, duration: 10.0);
    final vo = _voiceoverTrack(startTime: 2.0, duration: 4.0);
    final plan = VGAudioSidecarPlan(tracks: [orig, music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    // ignore: deprecated_member_use_from_same_package
    final viaWrapper = draft.applyAudioDucking();
    final viaDirect = draft.applyAudioCompositionPolicy();

    expect(viaWrapper.audioSidecarPlan, equals(viaDirect.audioSidecarPlan),
        reason:
            'applyAudioDucking wrapper must produce identical result to applyAudioCompositionPolicy');
  });

  // ── POLICY-23 ─────────────────────────────────────────────────────────────
  test('POLICY-23: Explicit zero-volume Original is preserved in Original-only plan',
      () {
    // Slice A established that explicit zero survives export. Ensure normalization
    // does not change it in an Original-only plan (no muting trigger).
    final orig = _originalTrack(volume: 0.0);
    final draft = _draft(audioSidecarPlan: VGAudioSidecarPlan(tracks: [orig]));
    final result = draft.applyAudioCompositionPolicy();
    // No muting trigger → same instance.
    expect(identical(result, draft), isTrue);
    expect(result.audioSidecarPlan!.tracks.first.volume, closeTo(0.0, 1e-9),
        reason: 'Slice A explicit zero must survive normalization untouched');
  });

  // ── POLICY-24 ─────────────────────────────────────────────────────────────
  test(
      'POLICY-24: Music with existing keyframes is preserved; ducking skipped (Slice B limitation)',
      () {
    final preAuthored = [
      const VGAudioVolumeKeyframe(time: 0.0, volume: 0.8),
      const VGAudioVolumeKeyframe(time: 5.0, volume: 0.3),
      const VGAudioVolumeKeyframe(time: 10.0, volume: 0.8),
    ];
    final music = _musicTrack(volumeKeyframes: preAuthored);
    final vo = _voiceoverTrack(startTime: 2.0, duration: 4.0);
    final plan = VGAudioSidecarPlan(tracks: [music, vo]);
    final draft = _draft(audioSidecarPlan: plan);

    final result = draft.applyAudioCompositionPolicy();
    final resultMusic =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'music');
    // Pre-authored keyframes must remain exactly as authored.
    expect(resultMusic.volumeKeyframes!.length, 3);
    expect(resultMusic.volumeKeyframes![1].volume, closeTo(0.3, 1e-9),
        reason:
            'Pre-authored user automation must not be overwritten by generated ducking');
  });

  // ── POLICY-25 ─────────────────────────────────────────────────────────────
  test('POLICY-25: Multiple voiceover intervals are merged correctly', () {
    final music = _musicTrack(startTime: 0.0, duration: 20.0);
    final vo1 = _voiceoverTrack(trackId: 'vo-1', startTime: 2.0, duration: 3.0);
    final vo2 = _voiceoverTrack(trackId: 'vo-2', startTime: 7.0, duration: 3.0);
    final draft = _draft(
        audioSidecarPlan: VGAudioSidecarPlan(tracks: [music, vo1, vo2]));

    final result = draft.applyAudioCompositionPolicy();
    final resultMusic =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'music');
    expect(resultMusic.volumeKeyframes, isNotNull);
    // Should have two separate dip regions (two non-adjacent VO intervals).
    final kfs = resultMusic.volumeKeyframes!;
    int dipEntries = 0;
    for (var i = 1; i < kfs.length; i++) {
      if (kfs[i - 1].volume > 0.5 &&
          kfs[i].volume < 0.5) {
        dipEntries++;
      }
    }
    expect(dipEntries, 2,
        reason:
            'Two non-overlapping VO intervals should produce two separate dip regions');
  });

  // ── POLICY-26 ─────────────────────────────────────────────────────────────
  test('POLICY-26: Custom duckingConfig is respected', () {
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

    final result = draft.applyAudioCompositionPolicy(duckingConfig: customConfig);
    final resultMusic =
        result.audioSidecarPlan!.tracks.firstWhere((t) => t.role == 'music');

    expect(resultMusic.volumeKeyframes, isNotNull);

    // With duckVolume=0.1, the minimum volume in keyframes should be 0.1.
    final minVolume = resultMusic.volumeKeyframes!
        .map((kf) => kf.volume)
        .reduce((a, b) => a < b ? a : b);
    expect(minVolume, closeTo(0.1, 1e-9),
        reason:
            'The minimum keyframe volume should equal the custom duckVolume');
  });
}
