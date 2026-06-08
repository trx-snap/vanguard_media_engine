// vg_audio_sidecar_plan_test.dart
// Vanguard Media Engine — Phase 8.14A Audio Sidecar Export Muxer MVP
//
// Pure Dart unit tests for VGAudioSidecarTrack and VGAudioSidecarPlan,
// plus VGEditorDraft audioSidecarPlan additive bridge tests.
//
// Tests:
//   AST-*  VGAudioSidecarTrack round-trip, validation, equality
//   ASP-*  VGAudioSidecarPlan round-trip, validation, equality
//   EDA-*  VGEditorDraft audioSidecarPlan additive bridge tests

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_audio_sidecar_plan.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';

// ── Test fixtures ─────────────────────────────────────────────────────────────

VGAudioSidecarTrack _track({
  String trackId = 'track-1',
  String url = '/tmp/music.m4a',
  double startTime = 0.0,
  double duration = 5.0,
  double volume = 1.0,
  String? timeRemapAudioPolicy,
}) =>
    VGAudioSidecarTrack(
      trackId: trackId,
      url: url,
      startTime: startTime,
      duration: duration,
      volume: volume,
      timeRemapAudioPolicy: timeRemapAudioPolicy,
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
}
