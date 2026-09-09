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
//   DISP-16: onTimelineAudioStateChanged routes to registered timeline listener.
//   DISP-17: Pre-registration audio state is buffered and drained once on registration.
//   DISP-18: Pending audio state purged on unregister/reset; malformed payloads dropped.
//   DISP-19: onPhotoVideoDownloadProgress routes by assetId, clamps, drops
//            malformed/stale events, and is silent after unregister.
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
        onFrame: (pts, gen) {},
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
        onFrame: (pts, gen) => receivedPts = pts,
        onEOS: () => eosReceived = true,
      );

      await _invokeNative('onTimelineFrame', {
        'textureId': tid,
        'pts': 1.5,
        'generation': 1,
      });
      expect(receivedPts, closeTo(1.5, 0.001));
      expect(eosReceived, isFalse);

      dispatcher.unregisterTimelineListener(sub);
    });

    test('onTimelineEOS fires EOS callback', () async {
      const tid = 43;
      bool eosReceived = false;

      final sub = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (pts, gen) {},
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
        onFrame: (pts, gen) => pts1 = pts,
        onEOS: () {},
      );
      final sub2 = dispatcher.registerTimelineListener(
        textureId: 2,
        onFrame: (pts, gen) => pts2 = pts,
        onEOS: () {},
      );

      await _invokeNative('onTimelineFrame', {
        'textureId': 1,
        'pts': 3.0,
        'generation': 0,
      });
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
        onFrame: (pts, gen) => callCount++,
        onEOS: () {},
      );

      // Replace with a new subscription.
      final newSub = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (pts, gen) => callCount += 10,
        onEOS: () {},
      );

      // Unregister old token — must NOT remove the new subscription.
      dispatcher.unregisterTimelineListener(oldSub);

      await _invokeNative('onTimelineFrame', {
        'textureId': tid,
        'pts': 0.5,
        'generation': 0,
      });
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

  group('DISP-8: export progress listener stack behavior', () {
    test('old export token does not unregister newer subscription', () async {
      double? received;

      final old = dispatcher.registerExportListener((_) {});
      final fresh = dispatcher.registerExportListener((p) => received = p);

      dispatcher.unregisterExportListener(
        old,
      ); // stale/older unregister — must not remove newer

      await _invokeNative('onExportProgress', 0.5);
      expect(received, closeTo(0.5, 0.001));

      dispatcher.unregisterExportListener(fresh);
    });

    test('newest listener receives events', () async {
      final eventsOld = <double>[];
      final eventsNew = <double>[];

      final old = dispatcher.registerExportListener((p) => eventsOld.add(p));
      final fresh = dispatcher.registerExportListener((p) => eventsNew.add(p));

      await _invokeNative('onExportProgress', 0.3);

      expect(eventsOld, isEmpty);
      expect(eventsNew, [closeTo(0.3, 0.001)]);

      dispatcher.unregisterExportListener(fresh);
      dispatcher.unregisterExportListener(old);
    });

    test('unregistering newest restores older listener', () async {
      final eventsOld = <double>[];
      final eventsNew = <double>[];

      final old = dispatcher.registerExportListener((p) => eventsOld.add(p));
      final fresh = dispatcher.registerExportListener((p) => eventsNew.add(p));

      await _invokeNative('onExportProgress', 0.2);
      expect(eventsNew, [closeTo(0.2, 0.001)]);
      expect(eventsOld, isEmpty);

      // Unregister newest listener — older listener must be restored to top.
      dispatcher.unregisterExportListener(fresh);

      await _invokeNative('onExportProgress', 0.7);
      expect(eventsOld, [closeTo(0.7, 0.001)]);
      expect(eventsNew.length, 1); // No new events for unregistered fresh

      dispatcher.unregisterExportListener(old);
    });

    test('final unregister clears the slot', () async {
      expect(dispatcher.hasExportListenerForTesting, isFalse);

      double? received;
      final sub = dispatcher.registerExportListener((p) => received = p);
      expect(dispatcher.hasExportListenerForTesting, isTrue);

      dispatcher.unregisterExportListener(sub);
      expect(dispatcher.hasExportListenerForTesting, isFalse);

      await _invokeNative('onExportProgress', 0.9);
      expect(received, isNull);
    });
  });

  // ── DISP-9 ──────────────────────────────────────────────────────────────────

  group('DISP-9: playback complete routing', () {
    test('onPlaybackComplete routes with textureId', () async {
      int? receivedId;
      final sub = dispatcher.registerPlaybackCompleteListener(
        (tid) => receivedId = tid,
      );
      await _invokeNative('onPlaybackComplete', {'textureId': 99});
      expect(receivedId, 99);
      dispatcher.unregisterPlaybackCompleteListener(sub);
    });

    test('stale token does not remove newer subscriber', () async {
      int? receivedId;

      final old = dispatcher.registerPlaybackCompleteListener((_) {});
      final fresh = dispatcher.registerPlaybackCompleteListener(
        (tid) => receivedId = tid,
      );

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

      await _invokeNative('onNodeDurationProbed', {
        'path': '/tmp/clip.mp4',
        'duration': 7.25,
      });
      expect(receivedPath, '/tmp/clip.mp4');
      expect(receivedDuration, closeTo(7.25, 0.001));

      dispatcher.unregisterDurationProbedListener(sub);
    });
  });

  // ── DISP-11 ─────────────────────────────────────────────────────────────────

  group('DISP-11: thermal state routing', () {
    test('onThermalStateChanged routes rawValue', () async {
      int? receivedRaw;
      final sub = dispatcher.registerThermalStateListener(
        (raw) => receivedRaw = raw,
      );
      await _invokeNative('onThermalStateChanged', 2);
      expect(receivedRaw, 2);
      dispatcher.unregisterThermalStateListener(sub);
    });
  });

  // ── DISP-12 ─────────────────────────────────────────────────────────────────

  group('DISP-12: int-as-double tolerance (Flutter codec int delivery)', () {
    test(
      'onTimelineFrame pts delivered as int still parsed correctly',
      () async {
        const tid = 55;
        double? receivedPts;

        final sub = dispatcher.registerTimelineListener(
          textureId: tid,
          onFrame: (pts, _) => receivedPts = pts,
          onEOS: () {},
        );

        // Simulate native sending pts=0 as an int (common for first frame).
        await _invokeNative('onTimelineFrame', {
          'textureId': tid,
          'pts': 0,
          'generation': 0,
        });
        expect(receivedPts, closeTo(0.0, 0.001));

        dispatcher.unregisterTimelineListener(sub);
      },
    );

    test(
      'onThermalStateChanged rawValue delivered as double still parsed',
      () async {
        int? receivedRaw;
        final sub = dispatcher.registerThermalStateListener(
          (raw) => receivedRaw = raw,
        );

        // Native may deliver int as double (e.g. 3.0 → toInt → 3)
        await _invokeNative('onThermalStateChanged', 3.0);
        expect(receivedRaw, 3);

        dispatcher.unregisterThermalStateListener(sub);
      },
    );
  });

  // ── DISP-13 ─────────────────────────────────────────────────────────────────

  group('DISP-13: malformed payload silently dropped', () {
    test('onTimelineFrame without textureId is dropped', () async {
      int fireCount = 0;

      final sub = dispatcher.registerTimelineListener(
        textureId: 100,
        onFrame: (pts, gen) => fireCount++,
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
        onFrame: (pts, gen) => fireCount++,
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
        onFrame: (pts, gen) => oldCallCount++,
        onEOS: () {},
      );

      // Replace — old must be gone.
      final fresh = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (pts, gen) => newCallCount++,
        onEOS: () {},
      );
      // old subscription is superseded — we do not unregister it (stale token test).
      // ignore: unused_local_variable
      addTearDown(() => dispatcher.unregisterTimelineListener(old));

      await _invokeNative('onTimelineFrame', {
        'textureId': tid,
        'pts': 1.0,
        'generation': 0,
      });
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

  // ── DISP-16 ─────────────────────────────────────────────────────────────────

  group('DISP-16: timeline audio readiness routing', () {
    test(
      'onTimelineAudioStateChanged delivers directly to registered listener',
      () async {
        const tid = 50;
        const sid = 101;
        const state = 'ready';
        int? receivedTid;
        int? receivedSid;
        String? receivedState;

        final sub = dispatcher.registerTimelineListener(
          textureId: tid,
          onFrame: (pts, gen) {},
          onEOS: () {},
          onAudioStateChanged: (t, s, st) {
            receivedTid = t;
            receivedSid = s;
            receivedState = st;
          },
        );

        await _invokeNative('onTimelineAudioStateChanged', {
          'textureId': tid,
          'prepareSessionId': sid,
          'state': state,
        });

        expect(receivedTid, tid);
        expect(receivedSid, sid);
        expect(receivedState, state);

        dispatcher.unregisterTimelineListener(sub);
      },
    );

    test(
      'onTimelineAudioStateChanged routes only to matching textureId',
      () async {
        int? receivedTid1;
        int? receivedTid2;

        final sub1 = dispatcher.registerTimelineListener(
          textureId: 10,
          onFrame: (pts, gen) {},
          onEOS: () {},
          onAudioStateChanged: (t, s, st) => receivedTid1 = t,
        );
        final sub2 = dispatcher.registerTimelineListener(
          textureId: 20,
          onFrame: (pts, gen) {},
          onEOS: () {},
          onAudioStateChanged: (t, s, st) => receivedTid2 = t,
        );

        await _invokeNative('onTimelineAudioStateChanged', {
          'textureId': 10,
          'prepareSessionId': 1,
          'state': 'ready',
        });

        expect(receivedTid1, 10);
        expect(receivedTid2, isNull);

        dispatcher.unregisterTimelineListener(sub1);
        dispatcher.unregisterTimelineListener(sub2);
      },
    );

    test(
      'registered listener without onAudioStateChanged does not throw or buffer',
      () async {
        const tid = 30;
        final sub = dispatcher.registerTimelineListener(
          textureId: tid,
          onFrame: (pts, gen) {},
          onEOS: () {},
          onAudioStateChanged: null,
        );

        await expectLater(
          _invokeNative('onTimelineAudioStateChanged', {
            'textureId': tid,
            'prepareSessionId': 1,
            'state': 'ready',
          }),
          completes,
        );

        expect(dispatcher.hasPendingAudioStateForTesting(tid), isFalse);

        dispatcher.unregisterTimelineListener(sub);
      },
    );
  });

  // ── DISP-17 ─────────────────────────────────────────────────────────────────

  group('DISP-17: pre-registration audio state buffering and single drain', () {
    test(
      'buffers pre-registration audio state and drains once on registration',
      () async {
        const tid = 55;
        const sid = 42;
        const state = 'ready';

        // Event arrives BEFORE listener registration.
        await _invokeNative('onTimelineAudioStateChanged', {
          'textureId': tid,
          'prepareSessionId': sid,
          'state': state,
        });

        expect(dispatcher.hasPendingAudioStateForTesting(tid), isTrue);

        int callCount = 0;
        int? drainedTid;
        int? drainedSid;
        String? drainedState;

        final sub = dispatcher.registerTimelineListener(
          textureId: tid,
          onFrame: (pts, gen) {},
          onEOS: () {},
          onAudioStateChanged: (t, s, st) {
            callCount++;
            drainedTid = t;
            drainedSid = s;
            drainedState = st;
          },
        );

        // Synchronously drained during registration.
        expect(callCount, 1);
        expect(drainedTid, tid);
        expect(drainedSid, sid);
        expect(drainedState, state);
        expect(dispatcher.hasPendingAudioStateForTesting(tid), isFalse);

        // Unregister and re-register: must NOT drain again.
        dispatcher.unregisterTimelineListener(sub);

        int secondCallCount = 0;
        final sub2 = dispatcher.registerTimelineListener(
          textureId: tid,
          onFrame: (pts, gen) {},
          onEOS: () {},
          onAudioStateChanged: (t, s, st) => secondCallCount++,
        );

        expect(secondCallCount, 0);
        dispatcher.unregisterTimelineListener(sub2);
      },
    );

    test(
      'last-value-wins pre-registration buffering for same textureId',
      () async {
        const tid = 56;

        await _invokeNative('onTimelineAudioStateChanged', {
          'textureId': tid,
          'prepareSessionId': 1,
          'state': 'pending',
        });
        await _invokeNative('onTimelineAudioStateChanged', {
          'textureId': tid,
          'prepareSessionId': 2,
          'state': 'ready',
        });

        int callCount = 0;
        int? drainedSid;
        String? drainedState;

        final sub = dispatcher.registerTimelineListener(
          textureId: tid,
          onFrame: (pts, gen) {},
          onEOS: () {},
          onAudioStateChanged: (t, s, st) {
            callCount++;
            drainedSid = s;
            drainedState = st;
          },
        );

        expect(callCount, 1);
        expect(drainedSid, 2);
        expect(drainedState, 'ready');

        dispatcher.unregisterTimelineListener(sub);
      },
    );

    test(
      'registration without onAudioStateChanged drains and discards buffered state',
      () async {
        const tid = 57;

        await _invokeNative('onTimelineAudioStateChanged', {
          'textureId': tid,
          'prepareSessionId': 1,
          'state': 'ready',
        });

        expect(dispatcher.hasPendingAudioStateForTesting(tid), isTrue);

        final sub1 = dispatcher.registerTimelineListener(
          textureId: tid,
          onFrame: (pts, gen) {},
          onEOS: () {},
        );

        expect(dispatcher.hasPendingAudioStateForTesting(tid), isFalse);
        dispatcher.unregisterTimelineListener(sub1);

        // Subsequent registration must not receive the discarded state.
        int laterCallCount = 0;
        final sub2 = dispatcher.registerTimelineListener(
          textureId: tid,
          onFrame: (pts, gen) {},
          onEOS: () {},
          onAudioStateChanged: (t, s, st) => laterCallCount++,
        );
        expect(laterCallCount, 0);

        dispatcher.unregisterTimelineListener(sub2);
      },
    );
  });

  // ── DISP-18 ─────────────────────────────────────────────────────────────────

  group('DISP-18: pending audio state purge and malformed payload handling', () {
    test('purges pending audio state on unregister', () async {
      const tid = 60;
      final sub = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (pts, gen) {},
        onEOS: () {},
      );
      // Unregister live listener.
      dispatcher.unregisterTimelineListener(sub);

      // Now buffer an event while unregistered.
      await _invokeNative('onTimelineAudioStateChanged', {
        'textureId': tid,
        'prepareSessionId': 1,
        'state': 'ready',
      });
      expect(dispatcher.hasPendingAudioStateForTesting(tid), isTrue);

      // Calling unregister with the subscription purges buffered state for tid.
      dispatcher.unregisterTimelineListener(sub);
      expect(dispatcher.hasPendingAudioStateForTesting(tid), isFalse);
    });

    test('purges pending audio state on resetForTesting', () async {
      const tid = 61;
      await _invokeNative('onTimelineAudioStateChanged', {
        'textureId': tid,
        'prepareSessionId': 1,
        'state': 'ready',
      });
      expect(dispatcher.hasPendingAudioStateForTesting(tid), isTrue);

      dispatcher.resetForTesting(channel: _kChannel);
      expect(dispatcher.hasPendingAudioStateForTesting(tid), isFalse);
    });

    test(
      'malformed onTimelineAudioStateChanged payloads are silently dropped',
      () async {
        const tid = 70;
        int callCount = 0;

        final sub = dispatcher.registerTimelineListener(
          textureId: tid,
          onFrame: (pts, gen) {},
          onEOS: () {},
          onAudioStateChanged: (t, s, st) => callCount++,
        );

        // Missing textureId
        await _invokeNative('onTimelineAudioStateChanged', {
          'prepareSessionId': 1,
          'state': 'ready',
        });
        // Missing prepareSessionId
        await _invokeNative('onTimelineAudioStateChanged', {
          'textureId': tid,
          'state': 'ready',
        });
        // Missing state
        await _invokeNative('onTimelineAudioStateChanged', {
          'textureId': tid,
          'prepareSessionId': 1,
        });
        // Non-map payload
        await _invokeNative('onTimelineAudioStateChanged', 'invalid');
        // Null payload
        await _invokeNative('onTimelineAudioStateChanged', null);

        expect(callCount, 0);
        expect(dispatcher.hasPendingAudioStateForTesting(tid), isFalse);

        dispatcher.unregisterTimelineListener(sub);

        // Also verify malformed payload does not buffer when no listener is registered
        await _invokeNative('onTimelineAudioStateChanged', {'state': 'ready'});
        expect(dispatcher.hasPendingAudioStateForTesting(tid), isFalse);
      },
    );

    test('numeric fields tolerate int-as-double', () async {
      const tid = 80;
      int? receivedTid;
      int? receivedSid;

      final sub = dispatcher.registerTimelineListener(
        textureId: tid,
        onFrame: (pts, gen) {},
        onEOS: () {},
        onAudioStateChanged: (t, s, st) {
          receivedTid = t;
          receivedSid = s;
        },
      );

      await _invokeNative('onTimelineAudioStateChanged', {
        'textureId': 80.0,
        'prepareSessionId': 42.0,
        'state': 'ready',
      });

      expect(receivedTid, 80);
      expect(receivedSid, 42);

      dispatcher.unregisterTimelineListener(sub);
    });
  });

  // ── DISP-19 ─────────────────────────────────────────────────────────────────

  group('DISP-19: PhotoKit iCloud download progress routing', () {
    const assetA = 'PHASSET-A/L0/001';
    const assetB = 'PHASSET-B/L0/002';

    test('routes onPhotoVideoDownloadProgress to the listener for its assetId',
        () async {
      final eventsA = <double>[];
      final eventsB = <double>[];

      final subA = dispatcher.registerPhotoVideoDownloadProgressListener(
        assetId: assetA,
        onProgress: eventsA.add,
      );
      final subB = dispatcher.registerPhotoVideoDownloadProgressListener(
        assetId: assetB,
        onProgress: eventsB.add,
      );
      expect(dispatcher.isHandlerRegistered, isTrue);

      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': 0.25,
      });
      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetB,
        'progress': 0.5,
      });

      expect(eventsA, [closeTo(0.25, 0.001)]);
      expect(eventsB, [closeTo(0.5, 0.001)]);

      dispatcher.unregisterPhotoVideoDownloadProgressListener(subA);
      dispatcher.unregisterPhotoVideoDownloadProgressListener(subB);
    });

    test('clamps progress to [0.0, 1.0] and tolerates int payloads', () async {
      final events = <double>[];
      final sub = dispatcher.registerPhotoVideoDownloadProgressListener(
        assetId: assetA,
        onProgress: events.add,
      );

      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': -0.2,
      });
      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': 1.7,
      });
      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': 1,
      });

      expect(events, [
        closeTo(0.0, 0.001),
        closeTo(1.0, 0.001),
        closeTo(1.0, 0.001),
      ]);

      dispatcher.unregisterPhotoVideoDownloadProgressListener(sub);
    });

    test('drops malformed payloads without throwing', () async {
      int callCount = 0;
      final sub = dispatcher.registerPhotoVideoDownloadProgressListener(
        assetId: assetA,
        onProgress: (_) => callCount++,
      );

      // Missing progress.
      await _invokeNative('onPhotoVideoDownloadProgress', {'assetId': assetA});
      // Missing assetId.
      await _invokeNative('onPhotoVideoDownloadProgress', {'progress': 0.5});
      // Empty assetId.
      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': '',
        'progress': 0.5,
      });
      // Non-string assetId.
      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': 42,
        'progress': 0.5,
      });
      // Non-numeric progress.
      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': 'half',
      });
      // Non-map / null payloads.
      await _invokeNative('onPhotoVideoDownloadProgress', 0.5);
      await _invokeNative('onPhotoVideoDownloadProgress', null);

      expect(callCount, 0);

      dispatcher.unregisterPhotoVideoDownloadProgressListener(sub);
    });

    test('drops stale events for assetIds with no listener (never buffers)',
        () async {
      // No listener registered at all for assetB.
      dispatcher.ensureHandlerRegistered();
      await expectLater(
        _invokeNative('onPhotoVideoDownloadProgress', {
          'assetId': assetB,
          'progress': 0.4,
        }),
        completes,
      );
      expect(
        dispatcher.hasPhotoVideoDownloadProgressListenerForTesting(assetB),
        isFalse,
      );

      // A listener registered afterwards must not receive the earlier event.
      int lateCount = 0;
      final sub = dispatcher.registerPhotoVideoDownloadProgressListener(
        assetId: assetB,
        onProgress: (_) => lateCount++,
      );
      expect(lateCount, 0);
      dispatcher.unregisterPhotoVideoDownloadProgressListener(sub);
    });

    test('no callback after unregister; stale token is a no-op', () async {
      int oldCount = 0;
      int newCount = 0;

      final old = dispatcher.registerPhotoVideoDownloadProgressListener(
        assetId: assetA,
        onProgress: (_) => oldCount++,
      );
      dispatcher.unregisterPhotoVideoDownloadProgressListener(old);
      expect(
        dispatcher.hasPhotoVideoDownloadProgressListenerForTesting(assetA),
        isFalse,
      );

      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': 0.3,
      });
      expect(oldCount, 0);

      // Re-register (retry) for the same assetId: only the new listener fires.
      final fresh = dispatcher.registerPhotoVideoDownloadProgressListener(
        assetId: assetA,
        onProgress: (_) => newCount++,
      );
      // Unregistering the already-stale old token must not remove the
      // fresh registration.
      dispatcher.unregisterPhotoVideoDownloadProgressListener(old);
      expect(
        dispatcher.hasPhotoVideoDownloadProgressListenerForTesting(assetA),
        isTrue,
      );

      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': 0.6,
      });
      expect(oldCount, 0);
      expect(newCount, 1);

      dispatcher.unregisterPhotoVideoDownloadProgressListener(fresh);
      expect(
        dispatcher.hasPhotoVideoDownloadProgressListenerForTesting(assetA),
        isFalse,
      );

      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': 0.9,
      });
      expect(newCount, 1);
    });

    test('replacing a registration for the same assetId supersedes the old one',
        () async {
      int oldCount = 0;
      int newCount = 0;

      final old = dispatcher.registerPhotoVideoDownloadProgressListener(
        assetId: assetA,
        onProgress: (_) => oldCount++,
      );
      final fresh = dispatcher.registerPhotoVideoDownloadProgressListener(
        assetId: assetA,
        onProgress: (_) => newCount++,
      );

      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': 0.5,
      });
      expect(oldCount, 0);
      expect(newCount, 1);

      // Old token unregister is a no-op against the fresh entry.
      dispatcher.unregisterPhotoVideoDownloadProgressListener(old);
      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': 0.8,
      });
      expect(newCount, 2);

      dispatcher.unregisterPhotoVideoDownloadProgressListener(fresh);
    });

    test('resetForTesting clears download progress listeners', () async {
      int count = 0;
      dispatcher.registerPhotoVideoDownloadProgressListener(
        assetId: assetA,
        onProgress: (_) => count++,
      );
      dispatcher.resetForTesting(channel: _kChannel);
      expect(
        dispatcher.hasPhotoVideoDownloadProgressListenerForTesting(assetA),
        isFalse,
      );
      dispatcher.ensureHandlerRegistered();
      await _invokeNative('onPhotoVideoDownloadProgress', {
        'assetId': assetA,
        'progress': 0.5,
      });
      expect(count, 0);
    });
  });
}
