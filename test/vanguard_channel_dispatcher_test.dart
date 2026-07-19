// vanguard_channel_dispatcher_test.dart
// Vanguard Media Engine — MethodChannel Router Unit Tests
//
// Coverage:
//   DISP-1:  Handler is registered exactly once (idempotent).
//   DISP-2:  onTimelineFrame routes to the registered subscription.
//   DISP-3:  onTimelineEOS routes to the registered subscription.
//   DISP-4:  Unknown callbacks are silently dropped.
//   DISP-5:  Timeline subscription keyed by textureId — different IDs get independent delivery.
//   DISP-6:  Stale unregister token is a no-op (replacement token wins).
//   DISP-7:  onExportProgress routes to registered export listener.
//   DISP-8:  Export listener unregistered in finally — stale token no-op.
//   DISP-9:  onPlaybackComplete routes to registered listener with correct textureId.
//   DISP-10: onNodeDurationProbed routes correctly.
//   DISP-11: onThermalStateChanged routes to thermal listener.
//   DISP-12: All numeric payloads tolerate int-as-double (Flutter codec behavior).
//   DISP-13: Malformed payload (missing textureId) is silently dropped.
//   DISP-14: Replacing an existing timeline subscription removes the old callback.
//   DISP-15: Progress clamped to [0.0, 1.0] — negative and >1.0 clamped.
//
// All tests use TestDefaultBinaryMessengerBinding to inject simulated native
// callbacks without requiring a real device.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/channel/vanguard_channel_dispatcher.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _kChannel = MethodChannel('vanguard_media_engine');

/// Simulates a native → Dart invocation via the dispatcher's channel.
Future<void> _invokeNative(String method, [dynamic arguments]) async {
  final codec = const StandardMethodCodec();
  final data = codec.encodeMethodCall(MethodCall(method, arguments));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'vanguard_media_engine',
    data,
    (ByteData? reply) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VanguardChannelDispatcher dispatcher;

  setUp(() {
    dispatcher = VanguardChannelDispatcher.instance;
    // Inject a fresh channel so the dispatcher can register a real handler.
    dispatcher.resetForTesting(channel: _kChannel);
  });

  tearDown(() {
    dispatcher.resetForTesting();
  });

  // ── DISP-1 ──────────────────────────────────────────────────────────────────

  group('DISP-1: handler registration idempotency', () {
    test('ensureHandlerRegistered registers once', () {
      expect(dispatcher.isHandlerRegistered, isFalse);
      dispatcher.ensureHandlerRegistered();
      expect(dispatcher.isHandlerRegistered, isTrue);
      dispatcher.ensureHandlerRegistered(); // second call — no-op
      expect(dispatcher.isHandlerRegistered, isTrue);
    });

    test('register* calls trigger handler registration', () {
      expect(dispatcher.isHandlerRegistered, isFalse);
      final sub = dispatcher.registerTimelineListener(
        textureId: 1,
        onFrame: (_) {},
        onEOS: () {},
      );
      expect(dispatcher.isHandlerRegistered, isTrue);
      dispatcher.unregisterTimelineListener(sub);
    });
  });

  // ── DISP-2 / DISP-3 ───────────────────────────────────────────────────────

  group('DISP-2/3: timeline frame and EOS routing', () {
    test('onTimelineFrame delivers pts to correct subscription', () async {
      const tid = 42;
      double? receivedPts;
      bool eosReceived = false;

      final sub = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (pts) => receivedPts = pts,
        onEOS: () => eosReceived = true,
      );

      await _invokeNative('onTimelineFrame', {'textureId': tid, 'pts': 1.5, 'generation': 1});
      expect(receivedPts, closeTo(1.5, 0.001));
      expect(eosReceived, isFalse);

      dispatcher.unregisterTimelineListener(sub);
    });

    test('onTimelineEOS fires EOS callback', () async {
      const tid = 43;
      bool eosReceived = false;

      final sub = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (_) {},
        onEOS: () => eosReceived = true,
      );

      await _invokeNative('onTimelineEOS', {'textureId': tid});
      expect(eosReceived, isTrue);

      dispatcher.unregisterTimelineListener(sub);
    });
  });

  // ── DISP-4 ──────────────────────────────────────────────────────────────────

  group('DISP-4: unknown callbacks silently dropped', () {
    test('unrecognised method does not throw', () async {
      dispatcher.ensureHandlerRegistered();
      await expectLater(
        _invokeNative('someUnknownMethod', {'foo': 'bar'}),
        completes,
      );
    });
  });

  // ── DISP-5 ──────────────────────────────────────────────────────────────────

  group('DISP-5: independent delivery by textureId', () {
    test('frame to tid=1 does not fire tid=2 subscription', () async {
      double? pts1;
      double? pts2;

      final sub1 = dispatcher.registerTimelineListener(
        textureId: 1,
        onFrame: (pts) => pts1 = pts,
        onEOS: () {},
      );
      final sub2 = dispatcher.registerTimelineListener(
        textureId: 2,
        onFrame: (pts) => pts2 = pts,
        onEOS: () {},
      );

      await _invokeNative('onTimelineFrame', {'textureId': 1, 'pts': 3.0, 'generation': 0});
      expect(pts1, closeTo(3.0, 0.001));
      expect(pts2, isNull); // tid=2 must NOT fire

      dispatcher.unregisterTimelineListener(sub1);
      dispatcher.unregisterTimelineListener(sub2);
    });
  });

  // ── DISP-6 ──────────────────────────────────────────────────────────────────

  group('DISP-6: stale unregister token is a no-op', () {
    test('old token does not unregister newer subscription', () async {
      const tid = 10;
      int callCount = 0;

      final oldSub = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (_) => callCount++,
        onEOS: () {},
      );

      // Replace with a new subscription.
      final newSub = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (_) => callCount += 10,
        onEOS: () {},
      );

      // Unregister old token — must NOT remove the new subscription.
      dispatcher.unregisterTimelineListener(oldSub);

      await _invokeNative('onTimelineFrame', {'textureId': tid, 'pts': 0.5, 'generation': 0});
      expect(callCount, 10); // new callback fired, old one is gone

      dispatcher.unregisterTimelineListener(newSub);
    });
  });

  // ── DISP-7 ──────────────────────────────────────────────────────────────────

  group('DISP-7: export progress routing', () {
    test('onExportProgress calls registered listener', () async {
      double? received;
      final sub = dispatcher.registerExportListener((p) => received = p);
      await _invokeNative('onExportProgress', 0.65);
      expect(received, closeTo(0.65, 0.001));
      dispatcher.unregisterExportListener(sub);
    });
  });

  // ── DISP-8 ──────────────────────────────────────────────────────────────────

  group('DISP-8: export stale token is no-op', () {
    test('old export token does not unregister newer subscription', () async {
      double? received;

      final old = dispatcher.registerExportListener((_) {});
      final fresh = dispatcher.registerExportListener((p) => received = p);

      dispatcher.unregisterExportListener(old); // stale — must be no-op

      await _invokeNative('onExportProgress', 0.5);
      expect(received, closeTo(0.5, 0.001));

      dispatcher.unregisterExportListener(fresh);
    });

    test('after unregister no more callbacks fire', () async {
      double? received;
      final sub = dispatcher.registerExportListener((p) => received = p);
      dispatcher.unregisterExportListener(sub);

      await _invokeNative('onExportProgress', 0.9);
      expect(received, isNull);
    });
  });

  // ── DISP-9 ──────────────────────────────────────────────────────────────────

  group('DISP-9: playback complete routing', () {
    test('onPlaybackComplete routes with textureId', () async {
      int? receivedId;
      final sub = dispatcher.registerPlaybackCompleteListener((tid) => receivedId = tid);
      await _invokeNative('onPlaybackComplete', {'textureId': 99});
      expect(receivedId, 99);
      dispatcher.unregisterPlaybackCompleteListener(sub);
    });

    test('stale token does not remove newer subscriber', () async {
      int? receivedId;

      final old = dispatcher.registerPlaybackCompleteListener((_) {});
      final fresh = dispatcher.registerPlaybackCompleteListener((tid) => receivedId = tid);

      dispatcher.unregisterPlaybackCompleteListener(old);

      await _invokeNative('onPlaybackComplete', {'textureId': 77});
      expect(receivedId, 77);

      dispatcher.unregisterPlaybackCompleteListener(fresh);
    });
  });

  // ── DISP-10 ─────────────────────────────────────────────────────────────────

  group('DISP-10: duration probed routing', () {
    test('onNodeDurationProbed routes path and duration', () async {
      String? receivedPath;
      double? receivedDuration;

      final sub = dispatcher.registerDurationProbedListener((path, dur) {
        receivedPath = path;
        receivedDuration = dur;
      });

      await _invokeNative('onNodeDurationProbed', {'path': '/tmp/clip.mp4', 'duration': 7.25});
      expect(receivedPath, '/tmp/clip.mp4');
      expect(receivedDuration, closeTo(7.25, 0.001));

      dispatcher.unregisterDurationProbedListener(sub);
    });
  });

  // ── DISP-11 ─────────────────────────────────────────────────────────────────

  group('DISP-11: thermal state routing', () {
    test('onThermalStateChanged routes rawValue', () async {
      int? receivedRaw;
      final sub = dispatcher.registerThermalStateListener((raw) => receivedRaw = raw);
      await _invokeNative('onThermalStateChanged', 2);
      expect(receivedRaw, 2);
      dispatcher.unregisterThermalStateListener(sub);
    });
  });

  // ── DISP-12 ─────────────────────────────────────────────────────────────────

  group('DISP-12: int-as-double tolerance (Flutter codec int delivery)', () {
    test('onTimelineFrame pts delivered as int still parsed correctly', () async {
      const tid = 55;
      double? receivedPts;

      final sub = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (pts) => receivedPts = pts,
        onEOS: () {},
      );

      // Simulate native sending pts=0 as an int (common for first frame).
      await _invokeNative('onTimelineFrame', {'textureId': tid, 'pts': 0, 'generation': 0});
      expect(receivedPts, closeTo(0.0, 0.001));

      dispatcher.unregisterTimelineListener(sub);
    });

    test('onThermalStateChanged rawValue delivered as double still parsed', () async {
      int? receivedRaw;
      final sub = dispatcher.registerThermalStateListener((raw) => receivedRaw = raw);

      // Native may deliver int as double (e.g. 3.0 → toInt → 3)
      await _invokeNative('onThermalStateChanged', 3.0);
      expect(receivedRaw, 3);

      dispatcher.unregisterThermalStateListener(sub);
    });
  });

  // ── DISP-13 ─────────────────────────────────────────────────────────────────

  group('DISP-13: malformed payload silently dropped', () {
    test('onTimelineFrame without textureId is dropped', () async {
      int fireCount = 0;

      final sub = dispatcher.registerTimelineListener(
        textureId: 100,
        onFrame: (_) => fireCount++,
        onEOS: () => fireCount++,
      );

      // Missing textureId — must be silently dropped.
      await _invokeNative('onTimelineFrame', {'pts': 1.0, 'generation': 0});
      expect(fireCount, 0);

      dispatcher.unregisterTimelineListener(sub);
    });

    test('onTimelineEOS without textureId is dropped', () async {
      int fireCount = 0;

      final sub = dispatcher.registerTimelineListener(
        textureId: 101,
        onFrame: (_) => fireCount++,
        onEOS: () => fireCount++,
      );

      await _invokeNative('onTimelineEOS', <String, dynamic>{}); // no textureId
      expect(fireCount, 0);

      dispatcher.unregisterTimelineListener(sub);
    });
  });

  // ── DISP-14 ─────────────────────────────────────────────────────────────────

  group('DISP-14: replacing subscription removes old callback', () {
    test('old frame callback no longer fires after replacement', () async {
      const tid = 200;
      int oldCallCount = 0;
      int newCallCount = 0;

      final old = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (_) => oldCallCount++,
        onEOS: () {},
      );

      // Replace — old must be gone.
      final fresh = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (_) => newCallCount++,
        onEOS: () {},
      );
      // old subscription is superseded — we do not unregister it (stale token test).
      // ignore: unused_local_variable
      addTearDown(() => dispatcher.unregisterTimelineListener(old));

      await _invokeNative('onTimelineFrame', {'textureId': tid, 'pts': 1.0, 'generation': 0});
      expect(oldCallCount, 0);
      expect(newCallCount, 1);

      dispatcher.unregisterTimelineListener(fresh);
    });
  });

  // ── DISP-15 ─────────────────────────────────────────────────────────────────

  group('DISP-15: export progress clamping', () {
    test('negative progress clamped to 0.0', () async {
      double? received;
      final sub = dispatcher.registerExportListener((p) => received = p);
      await _invokeNative('onExportProgress', -0.5);
      expect(received, closeTo(0.0, 0.001));
      dispatcher.unregisterExportListener(sub);
    });

    test('progress >1.0 clamped to 1.0', () async {
      double? received;
      final sub = dispatcher.registerExportListener((p) => received = p);
      await _invokeNative('onExportProgress', 1.5);
      expect(received, closeTo(1.0, 0.001));
      dispatcher.unregisterExportListener(sub);
    });
  });
}
