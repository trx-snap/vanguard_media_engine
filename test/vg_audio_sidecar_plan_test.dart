// vg_audio_sidecar_plan_test.dart
// Vanguard Media Engine — Phase 8.14A/8.14B/8.14C Audio Sidecar Export Muxer
//
// Pure Dart unit tests for VGAudioSidecarTrack and VGAudioSidecarPlan,
// plus VGEditorDraft audioSidecarPlan additive bridge tests.
// Phase 8.14B additions: role, fadeInSeconds, fadeOutSeconds, multi-track.
// Phase 8.14C additions: sourceTrimStartSeconds, flattenOriginalClipAudio().
//
// Tests:
//   AST-*  VGAudioSidecarTrack round-trip, validation, equality
//   ASP-*  VGAudioSidecarPlan round-trip, validation, equality
//   EDA-*  VGEditorDraft audioSidecarPlan additive bridge tests
//   FAO-*  VGEditorDraft.flattenOriginalClipAudio() tests (Phase 8.14C)

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_audio_sidecar_plan.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_dual_camera_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';
import 'package:vanguard_media_engine/vg_time_remap_descriptor.dart';

// ── Test fixtures ─────────────────────────────────────────────────────────────

VGAudioSidecarTrack _track({
  String trackId = 'track-1',
  String url = '/tmp/music.m4a',
  double startTime = 0.0,
  double duration = 5.0,
  double volume = 1.0,
  String? role,
  double fadeInSeconds = 0.0,
  double fadeOutSeconds = 0.0,
  String? timeRemapAudioPolicy,
  double sourceTrimStartSeconds = 0.0,
}) =>
    VGAudioSidecarTrack(
      trackId: trackId,
      url: url,
      startTime: startTime,
      duration: duration,
      volume: volume,
      role: role,
      fadeInSeconds: fadeInSeconds,
      fadeOutSeconds: fadeOutSeconds,
      timeRemapAudioPolicy: timeRemapAudioPolicy,
      sourceTrimStartSeconds: sourceTrimStartSeconds,
    );

VGAudioSidecarPlan _plan({List<VGAudioSidecarTrack>? tracks}) =>
    VGAudioSidecarPlan(tracks: tracks ?? [_track()]);

VGClipDescriptor _clip({String id = 'clip-A'}) => VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/clip_a.mp4',
      durationSeconds: 5.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 5.0,
    );

VGEditorDraft _draft({VGAudioSidecarPlan? audioSidecarPlan}) => VGEditorDraft(
      id: 'draft-sidecar-test',
      clips: [_clip()],
      audioSidecarPlan: audioSidecarPlan,
    );

// ── Helper: valid video clip at given timeline position ───────────────────────

VGClipDescriptor _videoClip({
  required String id,
  String sourcePath = '/tmp/video.mp4',
  double startTimeSeconds = 0.0,
  double durationSeconds = 10.0,
  double trimStartSeconds = 0.0,
  double trimEndSeconds = 5.0,
  double speed = 1.0,
  bool isReversed = false,
  double? freezePTS,
}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: sourcePath,
      mediaKind: VGMediaKind.video,
      startTimeSeconds: startTimeSeconds,
      durationSeconds: durationSeconds,
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: trimEndSeconds,
      speed: speed,
      isReversed: isReversed,
      freezePTS: freezePTS,
    );

// ── VGAudioSidecarTrack ───────────────────────────────────────────────────────

void main() {
  // ─────────────────────────────────────────────────────────────────────────────
  // VGAudioSidecarTrack — construction and field access
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGAudioSidecarTrack — construction', () {
    test('AST-1 valid track constructs without error', () {
      expect(() => _track(), returnsNormally);
    });

    test('AST-2 fields are stored correctly', () {
      final t = _track(
        trackId: 'tid-1',
        url: '/device/audio.m4a',
        startTime: 2.5,
        duration: 10.0,
        volume: 0.8,
        timeRemapAudioPolicy: 'preserve',
      );
      expect(t.trackId, 'tid-1');
      expect(t.url, '/device/audio.m4a');
      expect(t.startTime, closeTo(2.5, 1e-9));
      expect(t.duration, closeTo(10.0, 1e-9));
      expect(t.volume, closeTo(0.8, 1e-9));
      expect(t.timeRemapAudioPolicy, 'preserve');
    });

    test('AST-3 volume defaults to 1.0', () {
      final t = VGAudioSidecarTrack(
        trackId: 'tid',
        url: '/tmp/a.m4a',
        startTime: 0.0,
        duration: 3.0,
      );
      expect(t.volume, closeTo(1.0, 1e-9));
    });

    test('AST-4 timeRemapAudioPolicy defaults to null', () {
      expect(_track().timeRemapAudioPolicy, isNull);
    });

    // Phase 8.14B: role and fade fields
    test('AST-19 role defaults to null', () {
      expect(_track().role, isNull);
    });

    test('AST-20 fadeInSeconds defaults to 0.0', () {
      expect(_track().fadeInSeconds, closeTo(0.0, 1e-9));
    });

    test('AST-21 fadeOutSeconds defaults to 0.0', () {
      expect(_track().fadeOutSeconds, closeTo(0.0, 1e-9));
    });

    test('AST-22 role is stored correctly', () {
      final t = _track(role: 'voiceover');
      expect(t.role, 'voiceover');
    });

    test('AST-23 fadeInSeconds is stored correctly', () {
      final t = _track(fadeInSeconds: 0.5);
      expect(t.fadeInSeconds, closeTo(0.5, 1e-9));
    });

    test('AST-24 fadeOutSeconds is stored correctly', () {
      final t = _track(fadeOutSeconds: 0.75);
      expect(t.fadeOutSeconds, closeTo(0.75, 1e-9));
    });

    test('AST-25 all 8.14B fields stored together', () {
      final t = _track(
        role: 'music',
        fadeInSeconds: 0.3,
        fadeOutSeconds: 0.5,
        volume: 0.6,
      );
      expect(t.role, 'music');
      expect(t.fadeInSeconds, closeTo(0.3, 1e-9));
      expect(t.fadeOutSeconds, closeTo(0.5, 1e-9));
      expect(t.volume, closeTo(0.6, 1e-9));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // VGAudioSidecarTrack — toMap / fromMap round-trip
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGAudioSidecarTrack — toMap/fromMap round-trip', () {
    test('AST-5 round-trip preserves all fields', () {
      final original = _track(
        trackId: 'rt-track',
        url: '/path/to/audio.mp3',
        startTime: 1.5,
        duration: 8.0,
        volume: 0.75,
        timeRemapAudioPolicy: 'mute',
      );
      final map = original.toMap();
      final restored =
          VGAudioSidecarTrack.fromMap(map.cast<Object?, Object?>());

      expect(restored, isNotNull);
      expect(restored!.trackId, 'rt-track');
      expect(restored.url, '/path/to/audio.mp3');
      expect(restored.startTime, closeTo(1.5, 1e-9));
      expect(restored.duration, closeTo(8.0, 1e-9));
      expect(restored.volume, closeTo(0.75, 1e-9));
      expect(restored.timeRemapAudioPolicy, 'mute');
    });

    test('AST-6 toMap shape contains required keys', () {
      final map = _track().toMap();
      expect(map['trackId'], isA<String>());
      expect(map['url'], isA<String>());
      expect(map['startTime'], isA<double>());
      expect(map['duration'], isA<double>());
      expect(map['volume'], isA<double>());
    });

    test('AST-7 toMap omits timeRemapAudioPolicy when null', () {
      final map = _track().toMap();
      expect(map.containsKey('timeRemapAudioPolicy'), isFalse);
    });

    test('AST-8 toMap includes timeRemapAudioPolicy when set', () {
      final map = _track(timeRemapAudioPolicy: 'preserve').toMap();
      expect(map['timeRemapAudioPolicy'], 'preserve');
    });

    // Phase 8.14B: role and fade serialisation
    test('AST-26 toMap omits role when null', () {
      final map = _track().toMap();
      expect(map.containsKey('role'), isFalse);
    });

    test('AST-27 toMap includes role when set', () {
      final map = _track(role: 'sfx').toMap();
      expect(map['role'], 'sfx');
    });

    test('AST-28 toMap omits fadeInSeconds when 0.0', () {
      final map = _track(fadeInSeconds: 0.0).toMap();
      expect(map.containsKey('fadeInSeconds'), isFalse);
    });

    test('AST-29 toMap includes fadeInSeconds when non-zero', () {
      final map = _track(fadeInSeconds: 0.5).toMap();
      expect(map['fadeInSeconds'], closeTo(0.5, 1e-9));
    });

    test('AST-30 toMap omits fadeOutSeconds when 0.0', () {
      final map = _track(fadeOutSeconds: 0.0).toMap();
      expect(map.containsKey('fadeOutSeconds'), isFalse);
    });

    test('AST-31 toMap includes fadeOutSeconds when non-zero', () {
      final map = _track(fadeOutSeconds: 0.75).toMap();
      expect(map['fadeOutSeconds'], closeTo(0.75, 1e-9));
    });

    test('AST-32 round-trip preserves role and fades', () {
      final original = _track(
        role: 'voiceover',
        fadeInSeconds: 0.3,
        fadeOutSeconds: 0.6,
        volume: 0.7,
      );
      final restored = VGAudioSidecarTrack.fromMap(
        original.toMap().cast<Object?, Object?>(),
      );
      expect(restored, isNotNull);
      expect(restored!.role, 'voiceover');
      expect(restored.fadeInSeconds, closeTo(0.3, 1e-9));
      expect(restored.fadeOutSeconds, closeTo(0.6, 1e-9));
      expect(restored.volume, closeTo(0.7, 1e-9));
    });

    test('AST-33 fromMap defaults fadeInSeconds to 0.0 when absent', () {
      final result = VGAudioSidecarTrack.fromMap({
        'trackId': 'tid',
        'url': '/tmp/a.m4a',
        'startTime': 0.0,
        'duration': 5.0,
      });
      expect(result, isNotNull);
      expect(result!.fadeInSeconds, closeTo(0.0, 1e-9));
    });

    test('AST-34 fromMap defaults fadeOutSeconds to 0.0 when absent', () {
      final result = VGAudioSidecarTrack.fromMap({
        'trackId': 'tid',
        'url': '/tmp/a.m4a',
        'startTime': 0.0,
        'duration': 5.0,
      });
      expect(result, isNotNull);
      expect(result!.fadeOutSeconds, closeTo(0.0, 1e-9));
    });

    test('AST-35 fromMap defaults role to null when absent', () {
      final result = VGAudioSidecarTrack.fromMap({
        'trackId': 'tid',
        'url': '/tmp/a.m4a',
        'startTime': 0.0,
        'duration': 5.0,
      });
      expect(result, isNotNull);
      expect(result!.role, isNull);
    });

    test('AST-9 fromMap returns null for empty trackId', () {
      final result = VGAudioSidecarTrack.fromMap({
        'trackId': '',
        'url': '/tmp/a.m4a',
        'startTime': 0.0,
        'duration': 5.0,
      });
      expect(result, isNull);
    });

    test('AST-10 fromMap returns null for missing url', () {
      final result = VGAudioSidecarTrack.fromMap({
        'trackId': 'tid',
        'startTime': 0.0,
        'duration': 5.0,
      });
      expect(result, isNull);
    });

    test('AST-11 fromMap returns null for zero duration', () {
      final result = VGAudioSidecarTrack.fromMap({
        'trackId': 'tid',
        'url': '/tmp/a.m4a',
        'startTime': 0.0,
        'duration': 0.0,
      });
      expect(result, isNull);
    });

    test('AST-12 fromMap returns null for negative duration', () {
      final result = VGAudioSidecarTrack.fromMap({
        'trackId': 'tid',
        'url': '/tmp/a.m4a',
        'startTime': 0.0,
        'duration': -1.0,
      });
      expect(result, isNull);
    });

    test('AST-13 fromMap uses default volume 1.0 when absent', () {
      final result = VGAudioSidecarTrack.fromMap({
        'trackId': 'tid',
        'url': '/tmp/a.m4a',
        'startTime': 0.0,
        'duration': 5.0,
      });
      expect(result, isNotNull);
      expect(result!.volume, closeTo(1.0, 1e-9));
    });

    test('AST-14 fromMap ignores unknown timeRemapAudioPolicy string', () {
      // Should parse successfully; non-null policy string is preserved.
      final result = VGAudioSidecarTrack.fromMap({
        'trackId': 'tid',
        'url': '/tmp/a.m4a',
        'startTime': 0.0,
        'duration': 5.0,
        'timeRemapAudioPolicy': 'unknown_future_value',
      });
      expect(result, isNotNull);
      expect(result!.timeRemapAudioPolicy, 'unknown_future_value');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // VGAudioSidecarTrack — equality and hashCode
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGAudioSidecarTrack — equality', () {
    test('AST-15 equal tracks are equal', () {
      final a = _track(trackId: 'x');
      final b = _track(trackId: 'x');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('AST-16 tracks with different trackId are not equal', () {
      expect(_track(trackId: 'a') == _track(trackId: 'b'), isFalse);
    });

    test('AST-17 tracks with different url are not equal', () {
      expect(
        _track(url: '/a.m4a') == _track(url: '/b.m4a'),
        isFalse,
      );
    });

    test('AST-18 tracks with different volume are not equal', () {
      expect(
        _track(volume: 0.5) == _track(volume: 1.0),
        isFalse,
      );
    });

    // Phase 8.14B: equality for new fields
    test('AST-36 tracks with different role are not equal', () {
      expect(
        _track(role: 'music') == _track(role: 'voiceover'),
        isFalse,
      );
    });

    test('AST-37 tracks with different fadeInSeconds are not equal', () {
      expect(
        _track(fadeInSeconds: 0.5) == _track(fadeInSeconds: 0.0),
        isFalse,
      );
    });

    test('AST-38 tracks with different fadeOutSeconds are not equal', () {
      expect(
        _track(fadeOutSeconds: 0.5) == _track(fadeOutSeconds: 0.0),
        isFalse,
      );
    });

    test('AST-39 tracks identical including new fields are equal', () {
      final a = _track(role: 'sfx', fadeInSeconds: 0.2, fadeOutSeconds: 0.4);
      final b = _track(role: 'sfx', fadeInSeconds: 0.2, fadeOutSeconds: 0.4);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // VGAudioSidecarPlan — construction
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGAudioSidecarPlan — construction', () {
    test('ASP-1 valid plan constructs without error', () {
      expect(() => _plan(), returnsNormally);
    });

    test('ASP-2 empty tracks list throws AssertionError', () {
      expect(
        () => VGAudioSidecarPlan(tracks: const []),
        throwsAssertionError,
      );
    });

    test('ASP-3 tracks list is unmodifiable', () {
      final plan = _plan();
      expect(
        () => (plan.tracks as List).add(_track(trackId: 'new')),
        throwsUnsupportedError,
      );
    });

    // Phase 8.14B: multi-track support
    test('ASP-12 plan with multiple tracks constructs without error', () {
      expect(
        () => VGAudioSidecarPlan(tracks: [
          _track(trackId: 't1'),
          _track(trackId: 't2', url: '/tmp/sfx.m4a', role: 'sfx'),
        ]),
        returnsNormally,
      );
    });

    test('ASP-13 multi-track plan stores all tracks', () {
      final plan = VGAudioSidecarPlan(tracks: [
        _track(trackId: 'a'),
        _track(trackId: 'b'),
        _track(trackId: 'c'),
      ]);
      expect(plan.tracks.length, 3);
      expect(plan.tracks[0].trackId, 'a');
      expect(plan.tracks[2].trackId, 'c');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // VGAudioSidecarPlan — toMap / fromMap round-trip
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGAudioSidecarPlan — toMap/fromMap round-trip', () {
    test('ASP-4 round-trip preserves all fields', () {
      final original = _plan(
        tracks: [
          _track(
            trackId: 'rt-plan-track',
            url: '/audio/bg.mp3',
            startTime: 0.5,
            duration: 12.0,
            volume: 0.9,
          ),
        ],
      );
      final map = original.toMap();
      final restored =
          VGAudioSidecarPlan.fromMap(map.cast<Object?, Object?>());

      expect(restored, isNotNull);
      expect(restored!.tracks.length, 1);
      expect(restored.tracks[0].trackId, 'rt-plan-track');
      expect(restored.tracks[0].url, '/audio/bg.mp3');
      expect(restored.tracks[0].startTime, closeTo(0.5, 1e-9));
      expect(restored.tracks[0].duration, closeTo(12.0, 1e-9));
      expect(restored.tracks[0].volume, closeTo(0.9, 1e-9));
    });

    // Phase 8.14B: multi-track round-trip with fades and roles
    test('ASP-14 multi-track round-trip preserves all tracks with 8.14B fields', () {
      final original = VGAudioSidecarPlan(tracks: [
        _track(
          trackId: 'music-1',
          url: '/tmp/music.m4a',
          startTime: 0.0,
          duration: 5.0,
          volume: 0.8,
          role: 'music',
          fadeInSeconds: 0.5,
          fadeOutSeconds: 0.5,
        ),
        _track(
          trackId: 'vo-1',
          url: '/tmp/vo.m4a',
          startTime: 1.0,
          duration: 3.0,
          volume: 1.0,
          role: 'voiceover',
          fadeInSeconds: 0.0,
          fadeOutSeconds: 0.25,
        ),
      ]);
      final restored = VGAudioSidecarPlan.fromMap(
        original.toMap().cast<Object?, Object?>(),
      );
      expect(restored, isNotNull);
      expect(restored!.tracks.length, 2);
      expect(restored.tracks[0].trackId, 'music-1');
      expect(restored.tracks[0].role, 'music');
      expect(restored.tracks[0].fadeInSeconds, closeTo(0.5, 1e-9));
      expect(restored.tracks[0].fadeOutSeconds, closeTo(0.5, 1e-9));
      expect(restored.tracks[1].trackId, 'vo-1');
      expect(restored.tracks[1].role, 'voiceover');
      expect(restored.tracks[1].fadeInSeconds, closeTo(0.0, 1e-9));
      expect(restored.tracks[1].fadeOutSeconds, closeTo(0.25, 1e-9));
    });

    test('ASP-15 multi-track equality: same two-track plans are equal', () {
      final a = VGAudioSidecarPlan(tracks: [
        _track(trackId: 'x', role: 'music', fadeInSeconds: 0.3),
        _track(trackId: 'y', role: 'sfx'),
      ]);
      final b = VGAudioSidecarPlan(tracks: [
        _track(trackId: 'x', role: 'music', fadeInSeconds: 0.3),
        _track(trackId: 'y', role: 'sfx'),
      ]);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('ASP-5 toMap shape has "tracks" list key', () {
      final map = _plan().toMap();
      expect(map['tracks'], isA<List>());
    });

    test('ASP-6 fromMap returns null when tracks key is missing', () {
      final result = VGAudioSidecarPlan.fromMap({});
      expect(result, isNull);
    });

    test('ASP-7 fromMap returns null when tracks list is empty', () {
      final result = VGAudioSidecarPlan.fromMap({'tracks': <Object?>[]});
      expect(result, isNull);
    });

    test('ASP-8 fromMap skips malformed track entries gracefully', () {
      // A map with one valid and one malformed track.
      // Malformed entry (missing url) is skipped; plan is created from valid track.
      final result = VGAudioSidecarPlan.fromMap({
        'tracks': <Object?>[
          {
            'trackId': 'valid',
            'url': '/audio/ok.m4a',
            'startTime': 0.0,
            'duration': 5.0,
            'volume': 1.0,
          },
          {
            // Missing url — should be skipped
            'trackId': 'bad',
            'startTime': 0.0,
            'duration': 3.0,
          },
        ],
      });
      expect(result, isNotNull);
      expect(result!.tracks.length, 1);
      expect(result.tracks[0].trackId, 'valid');
    });

    test('ASP-9 fromMap returns null when all tracks are malformed', () {
      final result = VGAudioSidecarPlan.fromMap({
        'tracks': <Object?>[
          {'trackId': 'bad', 'startTime': 0.0, 'duration': 5.0},
        ],
      });
      expect(result, isNull);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // VGAudioSidecarPlan — equality
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGAudioSidecarPlan — equality', () {
    test('ASP-10 equal plans are equal', () {
      final a = _plan();
      final b = _plan();
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('ASP-11 plans with different tracks are not equal', () {
      final a = _plan(tracks: [_track(trackId: 'a')]);
      final b = _plan(tracks: [_track(trackId: 'b')]);
      expect(a == b, isFalse);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // VGEditorDraft — audioSidecarPlan additive bridge
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft — audioSidecarPlan additive bridge (Phase 8.14A)', () {
    test('EDA-1 audioSidecarPlan defaults to null', () {
      final d = _draft();
      expect(d.audioSidecarPlan, isNull);
    });

    test('EDA-2 audioSidecarPlan is stored when provided', () {
      final plan = _plan();
      final d = _draft(audioSidecarPlan: plan);
      expect(d.audioSidecarPlan, plan);
    });

    test('EDA-3 toMap omits "audioSidecar" key when plan is null', () {
      final map = _draft().toMap();
      expect(map.containsKey('audioSidecar'), isFalse);
    });

    test('EDA-4 toMap emits "audioSidecar" key when plan is set', () {
      final plan = _plan();
      final map = _draft(audioSidecarPlan: plan).toMap();
      expect(map.containsKey('audioSidecar'), isTrue);
      expect(map['audioSidecar'], isA<Map>());
    });

    test('EDA-5 toMap audioSidecar value round-trips through VGAudioSidecarPlan.fromMap', () {
      final original = _plan(
        tracks: [
          _track(
            trackId: 'bridge-track',
            url: '/audio/voiceover.mp3',
            startTime: 1.0,
            duration: 7.5,
            volume: 0.85,
          ),
        ],
      );
      final draftMap = _draft(audioSidecarPlan: original).toMap();
      final sidecarRaw = draftMap['audioSidecar'];
      expect(sidecarRaw, isA<Map>());

      final restored = VGAudioSidecarPlan.fromMap(
        (sidecarRaw! as Map).cast<Object?, Object?>(),
      );
      expect(restored, isNotNull);
      expect(restored!.tracks[0].trackId, 'bridge-track');
      expect(restored.tracks[0].startTime, closeTo(1.0, 1e-9));
      expect(restored.tracks[0].duration, closeTo(7.5, 1e-9));
      expect(restored.tracks[0].volume, closeTo(0.85, 1e-9));
    });

    test('EDA-6 fromMap produces null audioSidecarPlan when key is absent (backward-compatible)', () {
      final original = _draft();
      final map = original.toMap();
      // Confirm no 'audioSidecar' key emitted.
      expect(map.containsKey('audioSidecar'), isFalse);
      // fromMap on a legacy map must produce a draft with null sidecar.
      final restored = VGEditorDraft.fromMap(map.cast<Object?, Object?>());
      expect(restored, isNotNull);
      expect(restored!.audioSidecarPlan, isNull);
    });

    test('EDA-7 VGEditorDraft.fromMap round-trip preserves audioSidecarPlan', () {
      final plan = _plan(
        tracks: [_track(trackId: 't1', url: '/tmp/bg.m4a', duration: 10.0)],
      );
      final original = _draft(audioSidecarPlan: plan);
      final map = original.toMap();
      final restored = VGEditorDraft.fromMap(map.cast<Object?, Object?>());

      expect(restored, isNotNull);
      expect(restored!.audioSidecarPlan, isNotNull);
      expect(restored.audioSidecarPlan!.tracks.length, 1);
      expect(restored.audioSidecarPlan!.tracks[0].trackId, 't1');
    });

    test('EDA-8 equality: drafts with same audioSidecarPlan are equal', () {
      final plan = _plan();
      final a = _draft(audioSidecarPlan: plan);
      final b = _draft(audioSidecarPlan: plan);
      expect(a, equals(b));
    });

    test('EDA-9 equality: drafts with different audioSidecarPlan are not equal', () {
      final a = _draft(audioSidecarPlan: _plan(tracks: [_track(trackId: 'a')]));
      final b = _draft(audioSidecarPlan: _plan(tracks: [_track(trackId: 'b')]));
      expect(a == b, isFalse);
    });

    test('EDA-10 equality: draft with null plan != draft with non-null plan', () {
      final a = _draft();
      final b = _draft(audioSidecarPlan: _plan());
      expect(a == b, isFalse);
    });

    test('EDA-11 copyWith preserves audioSidecarPlan when not specified', () {
      final plan = _plan();
      final original = _draft(audioSidecarPlan: plan);
      final copy = original.copyWith(fps: 60);
      expect(copy.audioSidecarPlan, equals(plan));
    });

    test('EDA-12 copyWith replaces audioSidecarPlan when specified', () {
      final plan1 = _plan(tracks: [_track(trackId: 'old')]);
      final plan2 = _plan(tracks: [_track(trackId: 'new')]);
      final original = _draft(audioSidecarPlan: plan1);
      final copy = original.copyWith(audioSidecarPlan: plan2);
      expect(copy.audioSidecarPlan!.tracks[0].trackId, 'new');
      expect(original.audioSidecarPlan!.tracks[0].trackId, 'old');
    });

    test('EDA-13 trimClip preserves audioSidecarPlan through layout recomputation', () {
      final plan = _plan();
      final d = VGEditorDraft.sequentialWithTransitions(
        id: 'eda-13',
        clips: [
          _clip(id: 'A'),
          VGClipDescriptor(
            id: 'B',
            sourcePath: '/tmp/b.mp4',
            durationSeconds: 5.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 5.0,
          ),
        ],
        audioSidecarPlan: plan,
      );
      final trimmed = d.trimClip(
        clipId: 'A',
        trimStartSeconds: 0.5,
        trimEndSeconds: 4.5,
      );
      expect(trimmed.audioSidecarPlan, equals(plan));
    });

    test('EDA-14 toString includes sidecar track count when plan is set', () {
      final plan = _plan();
      final d = _draft(audioSidecarPlan: plan);
      expect(d.toString(), contains('audioSidecar: 1 track(s)'));
    });

    test('EDA-15 toString does not mention sidecar when plan is null', () {
      final d = _draft();
      expect(d.toString(), isNot(contains('audioSidecar')));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // VGAudioSidecarTrack — Phase 8.14C sourceTrimStartSeconds
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGAudioSidecarTrack — Phase 8.14C sourceTrimStartSeconds', () {
    test('AST-40 defaults to 0.0', () {
      expect(_track().sourceTrimStartSeconds, closeTo(0.0, 1e-9));
    });

    test('AST-41 stored correctly when set', () {
      expect(
        _track(sourceTrimStartSeconds: 1.5).sourceTrimStartSeconds,
        closeTo(1.5, 1e-9),
      );
    });

    test('AST-42 toMap omits sourceTrimStart when 0.0', () {
      final map = _track(sourceTrimStartSeconds: 0.0).toMap();
      expect(map.containsKey('sourceTrimStart'), isFalse);
    });

    test('AST-43 toMap includes sourceTrimStart when non-zero', () {
      final map = _track(sourceTrimStartSeconds: 2.0).toMap();
      expect(map['sourceTrimStart'], closeTo(2.0, 1e-9));
    });

    test('AST-44 round-trip preserves sourceTrimStartSeconds via sourceTrimStart key', () {
      final original = _track(sourceTrimStartSeconds: 1.25);
      final map = original.toMap();
      expect(map.containsKey('sourceTrimStart'), isTrue);
      expect(map['sourceTrimStart'], closeTo(1.25, 1e-9));

      final restored = VGAudioSidecarTrack.fromMap(map.cast<Object?, Object?>());
      expect(restored, isNotNull);
      expect(restored!.sourceTrimStartSeconds, closeTo(1.25, 1e-9));
    });

    test('AST-45 fromMap defaults sourceTrimStartSeconds to 0.0 when absent', () {
      final result = VGAudioSidecarTrack.fromMap({
        'trackId': 'tid',
        'url': '/tmp/a.m4a',
        'startTime': 0.0,
        'duration': 5.0,
      });
      expect(result, isNotNull);
      expect(result!.sourceTrimStartSeconds, closeTo(0.0, 1e-9));
    });

    test('AST-46 tracks with different sourceTrimStartSeconds are not equal', () {
      expect(
        _track(sourceTrimStartSeconds: 0.5) == _track(sourceTrimStartSeconds: 0.0),
        isFalse,
      );
    });

    test('AST-47 tracks identical including sourceTrimStartSeconds are equal', () {
      final a = _track(sourceTrimStartSeconds: 1.5);
      final b = _track(sourceTrimStartSeconds: 1.5);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // VGEditorDraft.flattenOriginalClipAudio() — Phase 8.14C
  // ─────────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft.flattenOriginalClipAudio() — Phase 8.14C', () {
    // ── Basic generation ─────────────────────────────────────────────────────

    test('FAO-1 single eligible video clip produces exactly one original-audio track', () {
      final clip = _videoClip(
        id: 'v1',
        sourcePath: '/path/to/clip.mp4',
        startTimeSeconds: 0.0,
        trimStartSeconds: 0.5,
        trimEndSeconds: 3.5,
      );
      final draft = VGEditorDraft(id: 'fao-1', clips: [clip]);
      final result = draft.flattenOriginalClipAudio();

      expect(result.audioSidecarPlan, isNotNull);
      expect(result.audioSidecarPlan!.tracks.length, 1);

      final t = result.audioSidecarPlan!.tracks[0];
      expect(t.trackId, 'original-v1');
      expect(t.url, '/path/to/clip.mp4');
      expect(t.startTime, closeTo(0.0, 1e-9));
      expect(t.duration, closeTo(3.0, 1e-9)); // trimEnd - trimStart = 3.5 - 0.5
      expect(t.sourceTrimStartSeconds, closeTo(0.5, 1e-9));
      expect(t.role, 'original');
      expect(t.volume, closeTo(1.0, 1e-9));
      expect(t.fadeInSeconds, closeTo(0.0, 1e-9));
      expect(t.fadeOutSeconds, closeTo(0.0, 1e-9));
    });

    test('FAO-2 multi-clip timeline produces one track per eligible clip', () {
      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'fao-2',
        clips: [
          _videoClip(id: 'v1', durationSeconds: 10.0, trimStartSeconds: 0.0, trimEndSeconds: 3.0),
          _videoClip(id: 'v2', durationSeconds: 10.0, trimStartSeconds: 1.0, trimEndSeconds: 4.0),
        ],
      );
      final result = draft.flattenOriginalClipAudio();

      expect(result.audioSidecarPlan, isNotNull);
      expect(result.audioSidecarPlan!.tracks.length, 2);

      final t1 = result.audioSidecarPlan!.tracks[0];
      expect(t1.trackId, 'original-v1');
      expect(t1.startTime, closeTo(0.0, 1e-9));
      expect(t1.duration, closeTo(3.0, 1e-9));
      expect(t1.sourceTrimStartSeconds, closeTo(0.0, 1e-9));

      final t2 = result.audioSidecarPlan!.tracks[1];
      expect(t2.trackId, 'original-v2');
      expect(t2.startTime, closeTo(3.0, 1e-9)); // sequential: clip 2 starts after clip 1
      expect(t2.duration, closeTo(3.0, 1e-9));
      expect(t2.sourceTrimStartSeconds, closeTo(1.0, 1e-9));
    });

    test('FAO-3 existing explicit sidecar tracks are preserved; generated tracks appended', () {
      final musicTrack = VGAudioSidecarTrack(
        trackId: 'music-1',
        url: '/music.m4a',
        startTime: 0.0,
        duration: 5.0,
        role: 'music',
      );
      final clip = _videoClip(id: 'v1', trimEndSeconds: 3.0);
      final draft = VGEditorDraft(
        id: 'fao-3',
        clips: [clip],
        audioSidecarPlan: VGAudioSidecarPlan(tracks: [musicTrack]),
      );
      final result = draft.flattenOriginalClipAudio();

      expect(result.audioSidecarPlan, isNotNull);
      expect(result.audioSidecarPlan!.tracks.length, 2);
      // Music track is first (existing), original track appended.
      expect(result.audioSidecarPlan!.tracks[0].trackId, 'music-1');
      expect(result.audioSidecarPlan!.tracks[1].trackId, 'original-v1');
    });

    // ── Generated track fades are 0.0 ────────────────────────────────────────

    test('FAO-4 generated tracks always have fadeInSeconds = 0.0', () {
      final clip = _videoClip(id: 'v1', trimEndSeconds: 3.0);
      final result = VGEditorDraft(id: 'fao-4', clips: [clip])
          .flattenOriginalClipAudio();
      expect(result.audioSidecarPlan!.tracks[0].fadeInSeconds, closeTo(0.0, 1e-9));
    });

    test('FAO-5 generated tracks always have fadeOutSeconds = 0.0', () {
      final clip = _videoClip(id: 'v1', trimEndSeconds: 3.0);
      final result = VGEditorDraft(id: 'fao-5', clips: [clip])
          .flattenOriginalClipAudio();
      expect(result.audioSidecarPlan!.tracks[0].fadeOutSeconds, closeTo(0.0, 1e-9));
    });

    // ── Skip condition tests ──────────────────────────────────────────────────

    test('FAO-6 skip condition 1: image clip is skipped', () {
      final clip = VGClipDescriptor(
        id: 'img-1',
        sourcePath: '/tmp/img.png',
        mediaKind: VGMediaKind.image,
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
      );
      final draft = VGEditorDraft(id: 'fao-6', clips: [clip]);
      final result = draft.flattenOriginalClipAudio();
      // No eligible clips → same instance returned.
      expect(identical(draft, result), isTrue);
    });

    test('FAO-7 skip condition 2: speed != 1.0 clip is skipped', () {
      final clip = _videoClip(id: 'v1', speed: 0.5, trimEndSeconds: 3.0);
      final draft = VGEditorDraft(id: 'fao-7', clips: [clip]);
      final result = draft.flattenOriginalClipAudio();
      expect(identical(draft, result), isTrue);
    });

    test('FAO-8 skip condition 3: isReversed clip is skipped', () {
      final clip = _videoClip(id: 'v1', isReversed: true, trimEndSeconds: 3.0);
      final draft = VGEditorDraft(id: 'fao-8', clips: [clip]);
      final result = draft.flattenOriginalClipAudio();
      expect(identical(draft, result), isTrue);
    });

    test('FAO-9 skip condition 4: freeze-frame clip (freezePTS != null) is skipped', () {
      // freezePTS requires isReversed == false and mediaKind == video.
      final clip = VGClipDescriptor(
        id: 'freeze-1',
        sourcePath: '/tmp/video.mp4',
        mediaKind: VGMediaKind.video,
        durationSeconds: 10.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 2.0, // hold duration for freeze
        freezePTS: 1.5,
      );
      final draft = VGEditorDraft(id: 'fao-9', clips: [clip]);
      final result = draft.flattenOriginalClipAudio();
      expect(identical(draft, result), isTrue);
    });

    test('FAO-10 skip condition 5: timeRemap != null clip is skipped', () {
      final remap = VGTimeRemapDescriptor(
        segments: [
          VGSpeedSegmentDescriptor(
            sourceStartTime: 0.0,
            sourceDuration: 3.0,
            speedMultiplier: 1.0,
          ),
        ],
        audioPolicy: VGTimeRemapAudioPolicy.mute,
      );
      final clip = VGClipDescriptor(
        id: 'remap-1',
        sourcePath: '/tmp/video.mp4',
        mediaKind: VGMediaKind.video,
        durationSeconds: 10.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        timeRemap: remap,
      );
      final draft = VGEditorDraft(id: 'fao-10', clips: [clip]);
      final result = draft.flattenOriginalClipAudio();
      expect(identical(draft, result), isTrue);
    });

    test('FAO-11 skip condition 6: dualCamera != null clip is skipped', () {
      final primary = _videoClip(id: 'primary', trimEndSeconds: 3.0);
      final secondary = _videoClip(id: 'secondary', trimEndSeconds: 3.0);
      final dualCameraClip = primary.copyWith(
        dualCamera: VGDualCameraDescriptor(
          primaryClip: primary,
          secondaryClip: secondary,
          layoutMode: VGDualCameraLayoutMode.pip,
        ),
      );
      final draft = VGEditorDraft(id: 'fao-11', clips: [dualCameraClip]);
      final result = draft.flattenOriginalClipAudio();
      expect(identical(draft, result), isTrue);
    });

    // ── Mixed eligible and ineligible clips ───────────────────────────────────

    test('FAO-12 mixed timeline: ineligible clips are skipped, eligible clips generate tracks', () {
      final videoClip = _videoClip(id: 'v1', trimStartSeconds: 0.0, trimEndSeconds: 3.0);
      final imageClip = VGClipDescriptor(
        id: 'img-1',
        sourcePath: '/tmp/img.png',
        mediaKind: VGMediaKind.image,
        startTimeSeconds: 3.0,
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 2.0,
      );
      final draft = VGEditorDraft(id: 'fao-12', clips: [videoClip, imageClip]);
      final result = draft.flattenOriginalClipAudio();

      expect(result.audioSidecarPlan, isNotNull);
      expect(result.audioSidecarPlan!.tracks.length, 1);
      expect(result.audioSidecarPlan!.tracks[0].trackId, 'original-v1');
    });

    // ── No eligible clips returns same instance ───────────────────────────────

    test('FAO-13 returns same instance when no eligible clips', () {
      final imageClip = VGClipDescriptor(
        id: 'img-1',
        sourcePath: '/tmp/img.png',
        mediaKind: VGMediaKind.image,
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
      );
      final draft = VGEditorDraft(id: 'fao-13', clips: [imageClip]);
      final result = draft.flattenOriginalClipAudio();
      expect(identical(draft, result), isTrue);
    });

    // ── trimStartSeconds = 0.0 does not emit sourceTrimStart in wire ─────────

    test('FAO-14 sourceTrimStartSeconds=0.0 omitted from generated track wire', () {
      final clip = _videoClip(id: 'v1', trimStartSeconds: 0.0, trimEndSeconds: 3.0);
      final result = VGEditorDraft(id: 'fao-14', clips: [clip])
          .flattenOriginalClipAudio();
      final plan = result.audioSidecarPlan!;
      final trackMap = plan.tracks[0].toMap();
      // 0.0 sourceTrimStart is omitted from wire (backward-compatible with 8.14B).
      expect(trackMap.containsKey('sourceTrimStart'), isFalse);
    });

    test('FAO-15 non-zero trimStartSeconds emits sourceTrimStart in generated track wire', () {
      final clip = _videoClip(id: 'v1', trimStartSeconds: 1.5, trimEndSeconds: 4.5);
      final result = VGEditorDraft(id: 'fao-15', clips: [clip])
          .flattenOriginalClipAudio();
      final plan = result.audioSidecarPlan!;
      final trackMap = plan.tracks[0].toMap();
      expect(trackMap['sourceTrimStart'], closeTo(1.5, 1e-9));
    });
  });
}
