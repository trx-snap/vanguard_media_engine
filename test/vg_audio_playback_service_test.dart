// vg_audio_playback_service_test.dart
// vanguard_media_engine — Phase 8.16
//
// Unit tests for VGAudioPlaybackService Dart bridge.
//
// Coverage:
//   PS-1:  load sends audioPlayback_load with correct path and returns duration.
//   PS-2:  empty path throws ArgumentError (Dart-side, no channel call).
//   PS-3:  play sends audioPlayback_play.
//   PS-4:  pause sends audioPlayback_pause.
//   PS-5:  stop sends audioPlayback_stop.
//   PS-6:  seekTo sends audioPlayback_seekTo with correct seconds.
//   PS-7:  negative seek throws ArgumentError (Dart-side, no channel call).
//   PS-8:  non-finite seek throws ArgumentError.
//   PS-9:  setVolume sends audioPlayback_setVolume with correct volume.
//   PS-10: volume < 0.0 throws ArgumentError.
//   PS-11: volume > 1.0 throws ArgumentError.
//   PS-12: non-finite volume throws ArgumentError.
//   PS-13: getPosition sends audioPlayback_getPosition and returns seconds.
//   PS-14: native FlutterError for load maps to PlatformException.
//   PS-15: getPosition returns 0.0 on null native response.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_audio_playback_service.dart';

void main() {
  const channel = MethodChannel('vanguard_media_engine');
  late List<MethodCall> capturedCalls;

  setUp(() {
    capturedCalls = [];
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void setHandler(Future<dynamic> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          capturedCalls.add(call);
          return handler(call);
        });
  }

  // ── PS-1 ────────────────────────────────────────────────────────────────────
  test(
    'PS-1: load sends audioPlayback_load with path and returns duration',
    () async {
      setHandler((call) async {
        if (call.method == 'audioPlayback_load') {
          return {'durationSeconds': 12.5};
        }
        return null;
      });

      final duration = await VGAudioPlaybackService.load(path: '/tmp/test.m4a');

      expect(capturedCalls.length, 1);
      expect(capturedCalls.first.method, 'audioPlayback_load');
      final args = capturedCalls.first.arguments as Map;
      expect(args['path'], '/tmp/test.m4a');
      expect(duration, closeTo(12.5, 0.001));
    },
  );

  // ── PS-2 ────────────────────────────────────────────────────────────────────
  test(
    'PS-2: empty path throws ArgumentError without calling channel',
    () async {
      setHandler((call) async => null);

      expect(
        () => VGAudioPlaybackService.load(path: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(capturedCalls, isEmpty);
    },
  );

  // ── PS-3 ────────────────────────────────────────────────────────────────────
  test('PS-3: play sends audioPlayback_play', () async {
    setHandler((call) async => null);

    await VGAudioPlaybackService.play();

    expect(capturedCalls.length, 1);
    expect(capturedCalls.first.method, 'audioPlayback_play');
  });

  // ── PS-4 ────────────────────────────────────────────────────────────────────
  test('PS-4: pause sends audioPlayback_pause', () async {
    setHandler((call) async => null);

    await VGAudioPlaybackService.pause();

    expect(capturedCalls.length, 1);
    expect(capturedCalls.first.method, 'audioPlayback_pause');
  });

  // ── PS-5 ────────────────────────────────────────────────────────────────────
  test('PS-5: stop sends audioPlayback_stop', () async {
    setHandler((call) async => null);

    await VGAudioPlaybackService.stop();

    expect(capturedCalls.length, 1);
    expect(capturedCalls.first.method, 'audioPlayback_stop');
  });

  // ── PS-6 ────────────────────────────────────────────────────────────────────
  test(
    'PS-6: seekTo sends audioPlayback_seekTo with correct seconds',
    () async {
      setHandler((call) async => null);

      await VGAudioPlaybackService.seekTo(3.75);

      expect(capturedCalls.length, 1);
      expect(capturedCalls.first.method, 'audioPlayback_seekTo');
      final args = capturedCalls.first.arguments as Map;
      expect((args['seconds'] as num).toDouble(), closeTo(3.75, 0.001));
    },
  );

  // ── PS-7 ────────────────────────────────────────────────────────────────────
  test(
    'PS-7: negative seek throws ArgumentError without calling channel',
    () async {
      setHandler((call) async => null);

      expect(
        () => VGAudioPlaybackService.seekTo(-1.0),
        throwsA(isA<ArgumentError>()),
      );
      expect(capturedCalls, isEmpty);
    },
  );

  // ── PS-8 ────────────────────────────────────────────────────────────────────
  test('PS-8: non-finite seek throws ArgumentError', () async {
    setHandler((call) async => null);

    expect(
      () => VGAudioPlaybackService.seekTo(double.infinity),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => VGAudioPlaybackService.seekTo(double.nan),
      throwsA(isA<ArgumentError>()),
    );
    expect(capturedCalls, isEmpty);
  });

  // ── PS-9 ────────────────────────────────────────────────────────────────────
  test(
    'PS-9: setVolume sends audioPlayback_setVolume with correct volume',
    () async {
      setHandler((call) async => null);

      await VGAudioPlaybackService.setVolume(0.75);

      expect(capturedCalls.length, 1);
      expect(capturedCalls.first.method, 'audioPlayback_setVolume');
      final args = capturedCalls.first.arguments as Map;
      expect((args['volume'] as num).toDouble(), closeTo(0.75, 0.001));
    },
  );

  // ── PS-10 ───────────────────────────────────────────────────────────────────
  test('PS-10: volume < 0.0 throws ArgumentError', () async {
    setHandler((call) async => null);

    expect(
      () => VGAudioPlaybackService.setVolume(-0.1),
      throwsA(isA<ArgumentError>()),
    );
    expect(capturedCalls, isEmpty);
  });

  // ── PS-11 ───────────────────────────────────────────────────────────────────
  test('PS-11: volume > 1.0 throws ArgumentError', () async {
    setHandler((call) async => null);

    expect(
      () => VGAudioPlaybackService.setVolume(1.1),
      throwsA(isA<ArgumentError>()),
    );
    expect(capturedCalls, isEmpty);
  });

  // ── PS-12 ───────────────────────────────────────────────────────────────────
  test('PS-12: non-finite volume throws ArgumentError', () async {
    setHandler((call) async => null);

    expect(
      () => VGAudioPlaybackService.setVolume(double.nan),
      throwsA(isA<ArgumentError>()),
    );
    expect(capturedCalls, isEmpty);
  });

  // ── PS-13 ───────────────────────────────────────────────────────────────────
  test(
    'PS-13: getPosition sends audioPlayback_getPosition and returns seconds',
    () async {
      setHandler((call) async {
        if (call.method == 'audioPlayback_getPosition') {
          return {'seconds': 4.25};
        }
        return null;
      });

      final position = await VGAudioPlaybackService.getPosition();

      expect(capturedCalls.length, 1);
      expect(capturedCalls.first.method, 'audioPlayback_getPosition');
      expect(position, closeTo(4.25, 0.001));
    },
  );

  // ── PS-14 ───────────────────────────────────────────────────────────────────
  test(
    'PS-14: native FlutterError for load maps to PlatformException',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'audioPlayback_load') {
              throw PlatformException(
                code: 'LOAD_FAILED',
                message: 'Asset contains no audio track',
              );
            }
            return null;
          });

      expect(
        () => VGAudioPlaybackService.load(path: '/tmp/no_audio.mp4'),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'LOAD_FAILED'),
        ),
      );
    },
  );

  // ── PS-15 ───────────────────────────────────────────────────────────────────
  test('PS-15: getPosition returns 0.0 on null native response', () async {
    setHandler((call) async => null);

    final position = await VGAudioPlaybackService.getPosition();

    expect(position, 0.0);
  });
}
