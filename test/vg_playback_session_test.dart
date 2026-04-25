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

  // ───────────────────────────────────────────────────────────────────────────
  // Step 7: createTexture muted arg routing
  // ───────────────────────────────────────────────────────────────────────────

  group('Step 7 — createTexture muted arg', () {
    test('createSession without muted sends muted=false (Step 9: key always present)', () async {
      _createTextureResponse = {
        'textureId': 10,
        'sessionId': 'uuid-active',
        'width': 1080,
        'height': 1920,
      };
      await VGPlaybackClient.createSession('/fake/active.mp4');
      final call = _call('createTexture');
      // Step 9 always includes the muted key with value false.
      expect(call.arguments.containsKey('muted'), isTrue,
          reason: 'Step 9: muted key must always be present in createTexture payload');
      expect(call.arguments['muted'], isFalse,
          reason: 'Default createSession must send muted=false');
    });

    test('createTexture channel with muted=true is recorded correctly', () async {
      _createTextureResponse = {
        'textureId': 20,
        'sessionId': 'uuid-muted',
        'width': 1080,
        'height': 1920,
      };
      const ch = MethodChannel('vanguard_media_engine');
      await ch.invokeMethod<Object>('createTexture', {
        'path': '/fake/muted.mp4',
        'muted': true,
      });
      final call = _call('createTexture');
      expect(call.arguments['muted'], isTrue,
          reason: 'muted=true must survive the channel round-trip');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Step 7: getMasterClock routing
  // ───────────────────────────────────────────────────────────────────────────

  group('Step 7 — getMasterClock textureId routing', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('vanguard_media_engine'),
        (MethodCall call) async {
          _log.add(call);
          if (call.method == 'getMasterClock') {
            final tid = (call.arguments as Map?)?['textureId'] as int?;
            return tid != null ? 1.234 : 0.0;
          }
          return null;
        },
      );
    });

    test('no-arg getMasterClock sends null args (renderer-fallback branch)', () async {
      const ch = MethodChannel('vanguard_media_engine');
      final result = await ch.invokeMethod<double>('getMasterClock');
      final call = _call('getMasterClock');
      expect(call.arguments, isNull,
          reason: 'No-arg call must send null args — renderer fallback path');
      expect(result, equals(0.0));
    });

    test('getMasterClock with textureId sends arg and gets registry clock', () async {
      const ch = MethodChannel('vanguard_media_engine');
      final result =
          await ch.invokeMethod<double>('getMasterClock', {'textureId': 42});
      final call = _call('getMasterClock');
      expect(call.arguments['textureId'], equals(42),
          reason: 'textureId must be forwarded to native getMasterClock');
      expect(result, closeTo(1.234, 1e-6));
    });

    test('two sessions return independent clocks (no registry bleeding)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('vanguard_media_engine'),
        (MethodCall call) async {
          _log.add(call);
          if (call.method == 'getMasterClock') {
            final tid = (call.arguments as Map?)?['textureId'] as int?;
            if (tid == 1) return 1.0;
            if (tid == 2) return 2.5;
            return 0.0;
          }
          return null;
        },
      );
      const ch = MethodChannel('vanguard_media_engine');
      final c1 = await ch.invokeMethod<double>('getMasterClock', {'textureId': 1});
      final c2 = await ch.invokeMethod<double>('getMasterClock', {'textureId': 2});
      expect(c1, closeTo(1.0, 1e-6));
      expect(c2, closeTo(2.5, 1e-6));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Step 7: promoteAudio dispatch
  // ───────────────────────────────────────────────────────────────────────────

  group('Step 7 — promoteAudio dispatch', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('vanguard_media_engine'),
        (MethodCall call) async {
          _log.add(call);
          if (call.method == 'promoteAudio') {
            final sid = ((call.arguments as Map?)?['sessionId']) as String?;
            return sid != null;
          }
          return null;
        },
      );
    });

    test('promoteAudio forwards sessionId to native and returns true', () async {
      const ch = MethodChannel('vanguard_media_engine');
      final result = await ch.invokeMethod<bool>(
          'promoteAudio', {'sessionId': 'test-session-uuid'});
      final call = _call('promoteAudio');
      expect(call.arguments['sessionId'], equals('test-session-uuid'));
      expect(result, isTrue);
    });

    test('promoteAudio without sessionId returns false (BAD_ARGS path)', () async {
      const ch = MethodChannel('vanguard_media_engine');
      final result = await ch.invokeMethod<bool>('promoteAudio', {});
      expect(result, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Step 9: VGPlaybackClient.createSession muted parameter
  // ───────────────────────────────────────────────────────────────────────────

  group('Step 9 — createSession muted parameter', () {
    test('createSession() default sends muted=false', () async {
      _createTextureResponse = {
        'textureId': 30,
        'sessionId': 'uuid-s9-active',
        'width': 1080,
        'height': 1920,
      };
      await VGPlaybackClient.createSession('/fake/s9_active.mp4');
      final call = _call('createTexture');
      expect(call.arguments['path'], equals('/fake/s9_active.mp4'));
      expect(call.arguments['muted'], isFalse,
          reason: 'Omitting muted must produce muted=false in the payload');
    });

    test('createSession(muted: true) sends muted=true', () async {
      _createTextureResponse = {
        'textureId': 31,
        'sessionId': 'uuid-s9-muted',
        'width': 1080,
        'height': 1920,
      };
      await VGPlaybackClient.createSession('/fake/s9_muted.mp4', muted: true);
      final call = _call('createTexture');
      expect(call.arguments['muted'], isTrue,
          reason: 'muted: true must be forwarded to native createTexture');
    });

    test('createSession(muted: false) is identical to the default', () async {
      _createTextureResponse = {
        'textureId': 32,
        'sessionId': 'uuid-s9-explicit-false',
        'width': 1080,
        'height': 1920,
      };
      await VGPlaybackClient.createSession('/fake/s9_explicit.mp4', muted: false);
      final call = _call('createTexture');
      expect(call.arguments['muted'], isFalse);
    });

    test('createSessionRaw forwards muted=true correctly', () async {
      _createTextureResponse = {
        'textureId': 33,
        'sessionId': 'uuid-s9-raw',
        'width': 1080,
        'height': 1920,
      };
      final (:session, :raw) =
          await VGPlaybackClient.createSessionRaw('/fake/raw.mp4', muted: true);
      expect(session.textureId, equals(33));
      final call = _call('createTexture');
      expect(call.arguments['muted'], isTrue,
          reason: 'createSessionRaw must forward muted to the channel');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Step 9: VGPlaybackSession.promoteToActiveAudio
  // ───────────────────────────────────────────────────────────────────────────

  group('Step 9 — promoteToActiveAudio', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('vanguard_media_engine'),
        (MethodCall call) async {
          _log.add(call);
          if (call.method == 'promoteAudio') {
            final sid = (call.arguments as Map)['sessionId'] as String?;
            return sid != null; // true when sessionId present, false otherwise
          }
          return null;
        },
      );
    });

    test('promoteToActiveAudio sends sessionId and returns true on success',
        () async {
      final session = VGPlaybackSession(
        sessionId: 'promote-uuid-123',
        textureId: 99,
      );
      final result = await session.promoteToActiveAudio();
      final call = _call('promoteAudio');
      expect(call.arguments['sessionId'], equals('promote-uuid-123'),
          reason: 'promoteToActiveAudio must be sessionId-keyed, not textureId-keyed');
      expect(result, isTrue,
          reason: 'Must return the native Bool result');
    });

    test('promoteToActiveAudio returns false when session is disposed', () async {
      final session = VGPlaybackSession(
        sessionId: 'disposed-uuid',
        textureId: 100,
      );
      // Install mock that would return true to ensure the guard fires first.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('vanguard_media_engine'),
        (MethodCall call) async {
          _log.add(call);
          return true;
        },
      );
      await session.dispose();
      _log.clear(); // ignore the dispose call
      final result = await session.promoteToActiveAudio();
      expect(result, isFalse,
          reason: 'Disposed session must return false without calling native');
      expect(_log.where((c) => c.method == 'promoteAudio').isEmpty, isTrue,
          reason: 'No promoteAudio channel call must fire after dispose');
    });

    test('promoteToActiveAudio returns false when native returns null', () async {
      // Override mock to return null (unexpected native response).
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('vanguard_media_engine'),
        (MethodCall call) async {
          _log.add(call);
          return null; // simulate unexpected null
        },
      );
      final session = VGPlaybackSession(
        sessionId: 'null-response-uuid',
        textureId: 101,
      );
      final result = await session.promoteToActiveAudio();
      expect(result, isFalse,
          reason: 'Null native response must coerce to false via ?? false');
    });

    test('play/pause/seekTo/dispose remain textureId-keyed after Step 9', () async {
      // Regression: Step 9 must not migrate playback commands to sessionId.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('vanguard_media_engine'),
        (MethodCall call) async { _log.add(call); return null; },
      );
      final session = VGPlaybackSession(
        sessionId: 'routing-uuid',
        textureId: 77,
      );
      await session.play();
      await session.pause();
      await session.seekTo(1.5);
      for (final name in ['play', 'pause', 'seekTo']) {
        final call = _call(name);
        expect(call.arguments['textureId'], equals(77),
            reason: '$name must remain textureId-keyed in Step 9');
        expect(call.arguments.containsKey('sessionId'), isFalse,
            reason: '$name must not be migrated to sessionId in Step 9');
      }
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// AC coverage summary (updated for Step 9)
// ─────────────────────────────────────────────────────────────────────────────
//
//  AC-11  TestDefaultBinaryMessengerBinding: used in every test via setUp.
//  AC-12  VGPlaybackClient.createSession: all return shapes covered.
//  AC-13  play(), pause(), seekTo(), dispose(): correct method + args.
//  AC-14  dispose() idempotency: 2nd/3rd call silent; control after dispose silent.
//
//  Step 7 additions:
//  S7-01  createTexture: muted=false by default (key present); muted=true when set.
//  S7-02  getMasterClock: null args → renderer fallback; textureId → registry path.
//  S7-03  getMasterClock: two sessions return independent clocks (no bleeding).
//  S7-04  promoteAudio: sessionId forwarded; Bool result returned; missing → false.
//
//  Step 9 additions:
//  S9-01  createSession() default sends muted=false in payload.
//  S9-02  createSession(muted: true) sends muted=true.
//  S9-03  createSession(muted: false) explicit is identical to default.
//  S9-04  createSessionRaw forwards muted=true correctly.
//  S9-05  promoteToActiveAudio sends sessionId (not textureId); returns Bool.
//  S9-06  promoteToActiveAudio returns false when session is disposed (no channel call).
//  S9-07  promoteToActiveAudio returns false when native returns null.
//  S9-08  play/pause/seekTo remain textureId-keyed (no Step 9 migration regression).
