// Copyright 2026, Connects. All rights reserved.
//
// VG-DUET-GREEN-SCREEN (Android backend ladder): `green_screen_degraded`
// contract.
//
// Native ladder: mediapipe_cpu -> mlkit -> none (safe PiP).
//   - A MediaPipe failure (init or runtime) emits exactly ONE non-terminal
//     `green_screen_degraded` with previousBackend=mediapipe_cpu and
//     currentBackend=mlkit; green screen stays live on ML Kit.
//   - An ML Kit failure keeps using the existing terminal
//     `green_screen_fallback` with currentBackend=pip.
//
// These tests pin the Dart side of that contract: parsing, reason keys,
// ordering through the shared VanguardChannelDispatcher `onDuetEvent` path,
// and non-terminal semantics. No public Dart API is added.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/channel/vanguard_channel_dispatcher.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_events.dart';

const String _kChannelName = 'vanguard_media_engine';

/// Backend ids as emitted by the Android adapter (DuetSegmentationBackend.*).
const String kMediaPipeCpuBackend = 'mediapipe_cpu';
const String kMlKitBackend = 'mlkit';

/// Preview backend reported by the terminal fallback event.
const String kPipBackend = 'pip';

/// Machine reason keys the Android adapter can attach to a degrade event
/// (DuetSegmentationFailureReason.* plus the synchronous-throw variant).
const List<String> kAndroidDegradeReasons = <String>[
  'mediapipe_init_failed',
  'mediapipe_inference_failed',
  'mediapipe_frame_convert_failed',
  'mediapipe_empty_result',
  'mediapipe_mask_size_mismatch',
  'mediapipe_cpu_segment_threw',
];

const String kDegradedUserMessage =
    'Green screen switched to the compatibility segmenter (ML Kit); '
    'edge quality may be reduced.';

Map<String, Object?> _degradePayload({
  String sessionId = 'session-android-gs-001',
  String reason = 'mediapipe_inference_failed',
}) => <String, Object?>{
  'event': 'green_screen_degraded',
  'sessionId': sessionId,
  'previousBackend': kMediaPipeCpuBackend,
  'currentBackend': kMlKitBackend,
  'reason': reason,
  'userMessage': kDegradedUserMessage,
};

Map<String, Object?> _fallbackPayload({
  String sessionId = 'session-android-gs-001',
  String reason = 'mlkit_failure',
}) => <String, Object?>{
  'event': 'green_screen_fallback',
  'sessionId': sessionId,
  'previousBackend': kMlKitBackend,
  'currentBackend': kPipBackend,
  'reason': reason,
  'userMessage': 'Green screen unavailable. Switched to Picture-in-Picture',
};

/// Simulates a native -> Dart invocation via the dispatcher's channel.
Future<void> _invokeNative(String method, [dynamic arguments]) async {
  const codec = StandardMethodCodec();
  final data = codec.encodeMethodCall(MethodCall(method, arguments));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(_kChannelName, data, (ByteData? reply) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VanguardChannelDispatcher dispatcher;

  setUp(() {
    dispatcher = VanguardChannelDispatcher.instance;
    dispatcher.resetForTesting(channel: const MethodChannel(_kChannelName));
  });

  tearDown(() {
    dispatcher.resetForTesting(channel: const MethodChannel(_kChannelName));
  });

  group('green_screen_degraded (Android mediapipe_cpu -> mlkit ladder)', () {
    test('1. parses the Android degrade payload and maps every field', () {
      final event = VGDuetEvent.tryParse(_degradePayload());

      expect(event, isNotNull);
      expect(event!.type, VGDuetEventType.greenScreenDegraded);
      expect(event.sessionId, 'session-android-gs-001');
      expect(event.previousBackend, kMediaPipeCpuBackend);
      expect(event.currentBackend, kMlKitBackend);
      expect(event.reason, 'mediapipe_inference_failed');
      expect(event.userMessage, kDegradedUserMessage);
    });

    test(
      '2. every Android degrade reason key parses as a non-terminal degrade',
      () {
        for (final reason in kAndroidDegradeReasons) {
          final event = VGDuetEvent.tryParse(_degradePayload(reason: reason));
          expect(event, isNotNull, reason: 'reason "$reason" must parse');
          expect(
            event!.type,
            VGDuetEventType.greenScreenDegraded,
            reason: 'reason "$reason" must be a degrade, not a fallback',
          );
          expect(event.reason, reason);
          // Non-terminal: the current backend is a live segmenter, never PiP.
          expect(event.currentBackend, kMlKitBackend);
          expect(event.currentBackend, isNot(kPipBackend));
          expect(event.previousBackend, kMediaPipeCpuBackend);
        }
      },
    );

    test(
      '3. degrade then terminal fallback arrive in order through the dispatcher',
      () async {
        expect(dispatcher.duetEventListenerCountForTesting, 0);

        final received = <VGDuetEvent>[];
        final subscription = VGDuetEvents.stream.listen(received.add);
        addTearDown(() async => subscription.cancel());
        expect(dispatcher.duetEventListenerCountForTesting, 1);

        // Native ladder: MediaPipe fails -> one degrade (green screen live on
        // ML Kit) -> ML Kit later fails -> terminal fallback (safe PiP).
        await _invokeNative('onDuetEvent', _degradePayload());
        await _invokeNative('onDuetEvent', _fallbackPayload());
        await pumpEventQueue();

        expect(received.length, 2);

        final degrade = received[0];
        expect(degrade.type, VGDuetEventType.greenScreenDegraded);
        expect(degrade.sessionId, 'session-android-gs-001');
        expect(degrade.previousBackend, kMediaPipeCpuBackend);
        expect(degrade.currentBackend, kMlKitBackend);
        expect(degrade.reason, 'mediapipe_inference_failed');
        expect(degrade.userMessage, kDegradedUserMessage);

        final fallback = received[1];
        expect(fallback.type, VGDuetEventType.greenScreenFallback);
        expect(fallback.sessionId, 'session-android-gs-001');
        expect(fallback.previousBackend, kMlKitBackend);
        expect(fallback.currentBackend, kPipBackend);
        expect(fallback.reason, 'mlkit_failure');

        await subscription.cancel();
        expect(dispatcher.duetEventListenerCountForTesting, 0);
      },
    );

    test('4. one native degrade emission yields exactly one stream event and '
        'is delivered to every concurrent listener', () async {
      final listenerA = <VGDuetEvent>[];
      final listenerB = <VGDuetEvent>[];
      final subA = VGDuetEvents.stream.listen(listenerA.add);
      final subB = VGDuetEvents.stream.listen(listenerB.add);
      addTearDown(() async {
        await subA.cancel();
        await subB.cancel();
      });
      expect(dispatcher.duetEventListenerCountForTesting, 1);

      await _invokeNative(
        'onDuetEvent',
        _degradePayload(reason: 'mediapipe_init_failed'),
      );
      await pumpEventQueue();

      expect(listenerA.length, 1);
      expect(listenerB.length, 1);
      expect(listenerA.single.type, VGDuetEventType.greenScreenDegraded);
      expect(listenerA.single.reason, 'mediapipe_init_failed');
      expect(listenerB.single.reason, 'mediapipe_init_failed');
      expect(listenerA.single.currentBackend, kMlKitBackend);

      await subA.cancel();
      await subB.cancel();
      expect(dispatcher.duetEventListenerCountForTesting, 0);
    });

    test(
      '5. malformed degrade payloads are dropped and do not disturb later events',
      () async {
        final received = <VGDuetEvent>[];
        final subscription = VGDuetEvents.stream.listen(received.add);
        addTearDown(() async => subscription.cancel());

        // Missing userMessage.
        final missingMessage = _degradePayload()..remove('userMessage');
        // Wrong types.
        final wrongTypes = _degradePayload()
          ..['previousBackend'] = 1
          ..['currentBackend'] = 2.5;
        // Unknown event name in the degrade family.
        final unknownName = _degradePayload()..['event'] = 'green_screen_x';

        await _invokeNative('onDuetEvent', missingMessage);
        await _invokeNative('onDuetEvent', wrongTypes);
        await _invokeNative('onDuetEvent', unknownName);
        await _invokeNative('onDuetEvent', 'not_a_map');
        await _invokeNative('onDuetEvent', null);
        await pumpEventQueue();
        expect(received, isEmpty);

        // A well-formed degrade still arrives afterwards.
        await _invokeNative('onDuetEvent', _degradePayload());
        await pumpEventQueue();
        expect(received.length, 1);
        expect(received.single.type, VGDuetEventType.greenScreenDegraded);
        expect(received.single.previousBackend, kMediaPipeCpuBackend);
        expect(received.single.currentBackend, kMlKitBackend);
      },
    );
  });
}
