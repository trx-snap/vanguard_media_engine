// vg_playback_session_test.dart
// Vanguard Media Engine — Phase 1B, P1B-10
//
// Pure Dart unit tests for VGPlaybackSession and VGPlaybackClient using a mock
// method channel. No Flutter engine or native code required — runs in pub test.
//
// Acceptance Criteria covered:
//   AC-11  TestDefaultBinaryMessengerBinding mock channel infrastructure
//   AC-12  createSession → correct VGPlaybackSession (sessionId + textureId)
//   AC-13  play / pause / seekTo / dispose fire correct channel calls
//   AC-14  dispose() idempotency — channel fires only once

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_playback_session.dart';
import 'package:vanguard_media_engine/vg_playback_client.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Mock channel harness
// ─────────────────────────────────────────────────────────────────────────────

/// All method calls recorded by the mock channel during a test.
final List<MethodCall> _log = [];

/// The response to return for the next `createTexture` call.
Object? _createTextureResponse;

/// Installs a mock handler on the `vanguard_media_engine` channel and clears
/// the call log. Call in setUp().
void _installMock() {
  _log.clear();
  _createTextureResponse = null;

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    (MethodCall call) async {
      _log.add(call);
      switch (call.method) {
        case 'createTexture':
          return _createTextureResponse;
        default:
          return null; // play / pause / seekTo / dispose all return void
      }
    },
  );
}

/// Removes the mock handler. Call in tearDown().
void _removeMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    null,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Finds the first recorded call with [name].
MethodCall _call(String name) =>
    _log.firstWhere((c) => c.method == name,
        orElse: () => throw TestFailure('No "$name" call recorded. Log: $_log'));

/// Counts how many recorded calls have [name].
int _callCount(String name) => _log.where((c) => c.method == name).length;

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // Initialise the binding so TestDefaultBinaryMessengerBinding is available.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_installMock);
  tearDown(_removeMock);

  // ───────────────────────────────────────────────────────────────────────────
  // AC-12: createSession → VGPlaybackSession formed correctly
  // ───────────────────────────────────────────────────────────────────────────

  group('VGPlaybackClient.createSession', () {
    test('returns a VGPlaybackSession with correct sessionId and textureId '
        'from a new-style map response', () async {
      // Arrange: native returns the graph-runtime map with sessionId.
      _createTextureResponse = {
        'textureId': 42,
        'sessionId': 'test-uuid',
        'width':     1080,
        'height':    1920,
      };

      // Act
      final session = await VGPlaybackClient.createSession('/fake/video.mp4');

      // Assert: VGPlaybackSession fields match the map.
      expect(session.sessionId, equals('test-uuid'),
          reason: 'sessionId must match the native map value');
      expect(session.textureId, equals(42),
          reason: 'textureId must match the native map value');

      // Assert: exactly one createTexture call was made.
      expect(_callCount('createTexture'), equals(1));
      expect(_call('createTexture').arguments['path'],
          equals('/fake/video.mp4'));
    });

    test('falls back to a synthesised sessionId when map has no sessionId '
        '(legacy renderer path)', () async {
      // Arrange: legacy path — no sessionId key.
      _createTextureResponse = {
        'textureId': 77,
        'width':     1080,
        'height':    1920,
      };

      final session = await VGPlaybackClient.createSession('/fake/legacy.mp4');

      expect(session.textureId, equals(77));
      // Synthesised sessionId must be non-empty and contain the textureId.
      expect(session.sessionId, isNotEmpty);
      expect(session.sessionId, contains('77'));
    });

    test('handles a legacy bare-integer return without crashing', () async {
      // Arrange: bare integer (unexpected but defensively handled).
      _createTextureResponse = 99;

      final session = await VGPlaybackClient.createSession('/fake/int.mp4');

      expect(session.textureId, equals(99));
      expect(session.sessionId, contains('legacy'));
    });

    test('throws StateError when native returns null', () async {
      _createTextureResponse = null;

      expect(
        () => VGPlaybackClient.createSession('/fake/null.mp4'),
        throwsA(isA<StateError>()),
      );
    });

    test('throws StateError when textureId is negative', () async {
      _createTextureResponse = {'textureId': -1};

      expect(
        () => VGPlaybackClient.createSession('/fake/bad.mp4'),
        throwsA(isA<StateError>()),
      );
    });

    // createSessionRaw surfaces the raw map for width/height extraction.
    test('createSessionRaw returns both session and raw map', () async {
      _createTextureResponse = {
        'textureId': 55,
        'sessionId': 'raw-uuid',
        'width':     720,
        'height':    1280,
      };

      final (:session, :raw) =
          await VGPlaybackClient.createSessionRaw('/fake/raw.mp4');

      expect(session.textureId, equals(55));
      expect(session.sessionId, equals('raw-uuid'));
      expect(raw?['width'],  equals(720));
      expect(raw?['height'], equals(1280));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // AC-13: play / pause / seekTo / dispose fire correct channel calls
  // ───────────────────────────────────────────────────────────────────────────

  group('VGPlaybackSession playback control', () {
    late VGPlaybackSession session;

    setUp(() {
      // Construct a session directly — no createSession channel call needed.
      session = VGPlaybackSession(sessionId: 'test-uuid', textureId: 42);
    });

    test('play() invokes "play" with correct textureId', () async {
      await session.play();

      expect(_callCount('play'), equals(1),
          reason: 'play() must fire exactly one channel call');
      expect(_call('play').arguments['textureId'], equals(42));
    });

    test('pause() invokes "pause" with correct textureId', () async {
      await session.pause();

      expect(_callCount('pause'), equals(1));
      expect(_call('pause').arguments['textureId'], equals(42));
    });

    test('seekTo() invokes "seekTo" with correct textureId and seconds', () async {
      await session.seekTo(3.75);

      expect(_callCount('seekTo'), equals(1));
      expect(_call('seekTo').arguments['textureId'], equals(42));
      expect(_call('seekTo').arguments['seconds'],   closeTo(3.75, 1e-9));
    });

    test('dispose() invokes "dispose" with correct textureId', () async {
      await session.dispose();

      expect(_callCount('dispose'), equals(1));
      expect(_call('dispose').arguments['textureId'], equals(42));
    });

    // ─── Argument correctness variant tests ────────────────────────────────

    test('seekTo(0) sends seconds=0.0', () async {
      await session.seekTo(0.0);
      expect(_call('seekTo').arguments['seconds'], closeTo(0.0, 1e-9));
    });

    test('seekTo() with a large value sends the correct seconds', () async {
      await session.seekTo(99999.999);
      expect(_call('seekTo').arguments['seconds'], closeTo(99999.999, 1e-6));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // AC-14: dispose() idempotency
  // ───────────────────────────────────────────────────────────────────────────

  group('VGPlaybackSession.dispose() idempotency', () {
    test('calling dispose() twice fires the channel only once', () async {
      final session = VGPlaybackSession(sessionId: 'idem-uuid', textureId: 10);

      await session.dispose();
      await session.dispose(); // second call must be a no-op

      expect(_callCount('dispose'), equals(1),
          reason: 'dispose() must be idempotent: channel fires exactly once '
              'regardless of how many times dispose() is called');
    });

    test('calling dispose() three times fires the channel only once', () async {
      final session = VGPlaybackSession(sessionId: 'idem-uuid', textureId: 10);

      await session.dispose();
      await session.dispose();
      await session.dispose();

      expect(_callCount('dispose'), equals(1));
    });

    test('play() after dispose() does NOT invoke the channel', () async {
      final session = VGPlaybackSession(sessionId: 'idem-uuid', textureId: 10);

      await session.dispose();
      _log.clear(); // reset so we only count post-dispose calls

      await session.play();

      expect(_callCount('play'), equals(0),
          reason: 'play() on a disposed session must not fire the channel');
    });

    test('pause() after dispose() does NOT invoke the channel', () async {
      final session = VGPlaybackSession(sessionId: 'idem-uuid', textureId: 10);

      await session.dispose();
      _log.clear();

      await session.pause();

      expect(_callCount('pause'), equals(0),
          reason: 'pause() on a disposed session must not fire the channel');
    });

    test('seekTo() after dispose() does NOT invoke the channel', () async {
      final session = VGPlaybackSession(sessionId: 'idem-uuid', textureId: 10);

      await session.dispose();
      _log.clear();

      await session.seekTo(5.0);

      expect(_callCount('seekTo'), equals(0),
          reason: 'seekTo() on a disposed session must not fire the channel');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // AC-12 (direct object construction — no channel)
  // ───────────────────────────────────────────────────────────────────────────

  group('VGPlaybackSession fields', () {
    test('sessionId and textureId are stored as provided', () {
      final s = VGPlaybackSession(sessionId: 'abc-123', textureId: 7);
      expect(s.sessionId, equals('abc-123'));
      expect(s.textureId, equals(7));
    });

    test('toString includes sessionId and textureId', () {
      final s = VGPlaybackSession(sessionId: 'abc-123', textureId: 7);
      expect(s.toString(), contains('abc-123'));
      expect(s.toString(), contains('7'));
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// AC coverage summary
// ─────────────────────────────────────────────────────────────────────────────
//
//  AC-11  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
//         .setMockMethodCallHandler — used in every test via setUp/_installMock.
//
//  AC-12  VGPlaybackClient.createSession returns correct VGPlaybackSession:
//         - testable new-style map response (sessionId + textureId = 42)
//         - legacy map (no sessionId) → synthesised placeholder
//         - legacy bare integer return → defensive path
//         - null / negative textureId → StateError
//         - createSessionRaw: both session and raw map surfaces width/height
//
//  AC-13  play(), pause(), seekTo(), dispose() each fire exactly the right
//         method name and arguments (textureId + seconds for seekTo).
//
//  AC-14  dispose() idempotency:
//         - 2nd / 3rd call: channel not invoked again
//         - play/pause/seekTo after dispose: channel not invoked
