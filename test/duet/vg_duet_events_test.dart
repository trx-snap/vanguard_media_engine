// Copyright 2026, Connects. All rights reserved.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/channel/vanguard_channel_dispatcher.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_events.dart';

const _kChannel = MethodChannel('vanguard_media_engine');

/// Simulates a native → Dart invocation via the dispatcher's channel.
Future<void> _invokeNative(String method, [dynamic arguments]) async {
  const codec = StandardMethodCodec();
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
    dispatcher.resetForTesting(
      channel: const MethodChannel('vanguard_media_engine'),
    );
  });

  tearDown(() {
    dispatcher.resetForTesting(
      channel: const MethodChannel('vanguard_media_engine'),
    );
  });

  group('VGDuetEvent.tryParse', () {
    test(
      '1. VGDuetEvent.tryParse accepts a complete green_screen_fallback payload and maps all fields',
      () {
        final payload = {
          'event': 'green_screen_fallback',
          'sessionId': 'session-green-screen-101',
          'previousBackend': 'green_screen',
          'currentBackend': 'pip',
          'reason': 'thermal_throttling',
          'userMessage':
              'Switched to picture-in-picture due to high device temperature.',
        };

        final event = VGDuetEvent.tryParse(payload);

        expect(event, isNotNull);
        expect(event!.type, VGDuetEventType.greenScreenFallback);
        expect(event.sessionId, 'session-green-screen-101');
        expect(event.previousBackend, 'green_screen');
        expect(event.currentBackend, 'pip');
        expect(event.reason, 'thermal_throttling');
        expect(
          event.userMessage,
          'Switched to picture-in-picture due to high device temperature.',
        );
      },
    );

    test(
      'accepts a complete green_screen_degraded payload and maps all fields',
      () {
        final payload = {
          'event': 'green_screen_degraded',
          'sessionId': 'session-green-screen-102',
          'previousBackend': 'green_screen',
          'currentBackend': 'green_screen',
          'reason': 'frame_drop',
          'userMessage': 'Degraded performance detected on green screen.',
        };

        final event = VGDuetEvent.tryParse(payload);

        expect(event, isNotNull);
        expect(event!.type, VGDuetEventType.greenScreenDegraded);
        expect(event.sessionId, 'session-green-screen-102');
        expect(event.previousBackend, 'green_screen');
        expect(event.currentBackend, 'green_screen');
        expect(event.reason, 'frame_drop');
        expect(
          event.userMessage,
          'Degraded performance detected on green screen.',
        );
      },
    );

    test(
      '2. tryParse silently rejects malformed payloads and unknown event names by returning null',
      () {
        // Unknown event names
        expect(
          VGDuetEvent.tryParse({
            'event': 'unknown_event',
            'sessionId': 'session-101',
            'previousBackend': 'green_screen',
            'currentBackend': 'pip',
            'reason': 'thermal',
            'userMessage': 'message',
          }),
          isNull,
        );
        expect(
          VGDuetEvent.tryParse({
            'event': 'green_screen_unknown',
            'sessionId': 'session-101',
            'previousBackend': 'green_screen',
            'currentBackend': 'pip',
            'reason': 'thermal',
            'userMessage': 'message',
          }),
          isNull,
        );
        expect(VGDuetEvent.tryParse({'event': ''}), isNull);
        expect(VGDuetEvent.tryParse({'event': 123}), isNull);
        expect(VGDuetEvent.tryParse(<dynamic, dynamic>{}), isNull);

        // Missing or non-string fields in an otherwise valid payload
        const requiredKeys = [
          'sessionId',
          'previousBackend',
          'currentBackend',
          'reason',
          'userMessage',
        ];

        final validBase = {
          'event': 'green_screen_fallback',
          'sessionId': 'session-101',
          'previousBackend': 'green_screen',
          'currentBackend': 'pip',
          'reason': 'thermal_throttling',
          'userMessage': 'Fallback to PiP',
        };

        for (final key in requiredKeys) {
          // Missing key
          final missing = Map<dynamic, dynamic>.from(validBase)..remove(key);
          expect(
            VGDuetEvent.tryParse(missing),
            isNull,
            reason: 'Missing $key should return null',
          );

          // Non-string int value
          final nonStringInt = Map<dynamic, dynamic>.from(validBase)
            ..[key] = 42;
          expect(
            VGDuetEvent.tryParse(nonStringInt),
            isNull,
            reason: 'Non-string int $key should return null',
          );

          // Non-string double value
          final nonStringDouble = Map<dynamic, dynamic>.from(validBase)
            ..[key] = 3.14;
          expect(
            VGDuetEvent.tryParse(nonStringDouble),
            isNull,
            reason: 'Non-string double $key should return null',
          );

          // Null value
          final nullValue = Map<dynamic, dynamic>.from(validBase)..[key] = null;
          expect(
            VGDuetEvent.tryParse(nullValue),
            isNull,
            reason: 'Null $key should return null',
          );
        }
      },
    );

    test('auto_stop parses with only event and sessionId, defaulting the '
        'green-screen fields to empty strings', () {
      final event = VGDuetEvent.tryParse({
        'event': 'auto_stop',
        'sessionId': 'session-auto-stop-001',
      });

      expect(event, isNotNull);
      expect(event!.type, VGDuetEventType.autoStop);
      expect(event.sessionId, 'session-auto-stop-001');
      expect(event.previousBackend, '');
      expect(event.currentBackend, '');
      expect(event.reason, '');
      expect(event.userMessage, '');
    });

    test(
      'auto_stop preserves the native reason and ignores non-string optional '
      'fields',
      () {
        final event = VGDuetEvent.tryParse({
          'event': 'auto_stop',
          'sessionId': 'session-auto-stop-002',
          'reason': 'trim_end_reached',
          'previousBackend': 42,
          'userMessage': null,
        });

        expect(event, isNotNull);
        expect(event!.type, VGDuetEventType.autoStop);
        expect(event.reason, 'trim_end_reached');
        expect(event.previousBackend, '');
        expect(event.currentBackend, '');
        expect(event.userMessage, '');
      },
    );

    test('auto_stop still requires a string sessionId', () {
      expect(
        VGDuetEvent.tryParse({'event': 'auto_stop'}),
        isNull,
        reason: 'Missing sessionId should return null',
      );
      expect(
        VGDuetEvent.tryParse({'event': 'auto_stop', 'sessionId': 999}),
        isNull,
        reason: 'Non-string sessionId should return null',
      );
      expect(
        VGDuetEvent.tryParse({'event': 'auto_stop', 'sessionId': null}),
        isNull,
        reason: 'Null sessionId should return null',
      );
    });

    test('green-screen events still require every backend field even after '
        'auto_stop relaxed its own contract', () {
      expect(
        VGDuetEvent.tryParse({
          'event': 'green_screen_fallback',
          'sessionId': 'session-strict-001',
        }),
        isNull,
      );
      expect(
        VGDuetEvent.tryParse({
          'event': 'green_screen_degraded',
          'sessionId': 'session-strict-002',
          'reason': 'frame_drop',
        }),
        isNull,
      );
    });
  });

  group('VGDuetEvents.stream', () {
    test(
      '3. VGDuetEvents.stream receives onDuetEvent dispatched through the existing MethodChannel/VanguardChannelDispatcher path',
      () async {
        expect(dispatcher.duetEventListenerCountForTesting, 0);

        final receivedEvents = <VGDuetEvent>[];
        final subscription = VGDuetEvents.stream.listen(receivedEvents.add);
        addTearDown(() async => subscription.cancel());

        // First stream listener lazily registers dispatcher listener
        expect(dispatcher.duetEventListenerCountForTesting, 1);

        final payload = {
          'event': 'green_screen_fallback',
          'sessionId': 'session-dispatch-001',
          'previousBackend': 'green_screen',
          'currentBackend': 'pip',
          'reason': 'thermal_throttling',
          'userMessage': 'Switching to PiP due to thermal throttling.',
        };

        await _invokeNative('onDuetEvent', payload);
        await pumpEventQueue();

        expect(receivedEvents.length, 1);
        final event = receivedEvents.first;
        expect(event.type, VGDuetEventType.greenScreenFallback);
        expect(event.sessionId, 'session-dispatch-001');
        expect(event.previousBackend, 'green_screen');
        expect(event.currentBackend, 'pip');
        expect(event.reason, 'thermal_throttling');
        expect(
          event.userMessage,
          'Switching to PiP due to thermal throttling.',
        );

        // Malformed native payloads and unknown events are silently dropped
        await _invokeNative('onDuetEvent', {'event': 'unknown_event'});
        await _invokeNative('onDuetEvent', {
          'event': 'green_screen_fallback',
          'sessionId': 999, // malformed
        });
        await _invokeNative('onDuetEvent', 'not_a_map');
        await _invokeNative('onDuetEvent', null);
        await pumpEventQueue();

        expect(receivedEvents.length, 1);

        // Cancel subscription and verify dispatcher listener count returns to zero
        await subscription.cancel();
        expect(dispatcher.duetEventListenerCountForTesting, 0);
      },
    );

    test(
      '4. Multiple stream listeners receive the same valid event, and cancelling one listener does not prevent the other from receiving a later event',
      () async {
        expect(dispatcher.duetEventListenerCountForTesting, 0);

        final listener1Events = <VGDuetEvent>[];
        final listener2Events = <VGDuetEvent>[];

        final sub1 = VGDuetEvents.stream.listen(listener1Events.add);
        final sub2 = VGDuetEvents.stream.listen(listener2Events.add);
        addTearDown(() async {
          await sub1.cancel();
          await sub2.cancel();
        });

        // Broadcast stream registers a single listener on dispatcher
        expect(dispatcher.duetEventListenerCountForTesting, 1);

        final event1Payload = {
          'event': 'green_screen_fallback',
          'sessionId': 'session-multi-001',
          'previousBackend': 'green_screen',
          'currentBackend': 'pip',
          'reason': 'gpu_oom',
          'userMessage': 'Fallback to PiP (event 1)',
        };

        await _invokeNative('onDuetEvent', event1Payload);
        await pumpEventQueue();

        expect(listener1Events.length, 1);
        expect(listener1Events.first.sessionId, 'session-multi-001');
        expect(listener1Events.first.reason, 'gpu_oom');

        expect(listener2Events.length, 1);
        expect(listener2Events.first.sessionId, 'session-multi-001');
        expect(listener2Events.first.reason, 'gpu_oom');

        // Cancelling one listener does not prevent the other from receiving later events
        await sub1.cancel();
        expect(
          dispatcher.duetEventListenerCountForTesting,
          1,
          reason: 'Dispatcher listener must remain while sub2 is still active',
        );

        final event2Payload = {
          'event': 'green_screen_fallback',
          'sessionId': 'session-multi-002',
          'previousBackend': 'green_screen',
          'currentBackend': 'pip',
          'reason': 'thermal_throttling',
          'userMessage': 'Fallback to PiP (event 2)',
        };

        await _invokeNative('onDuetEvent', event2Payload);
        await pumpEventQueue();

        // sub1 did not receive the second event
        expect(listener1Events.length, 1);

        // sub2 received the second event
        expect(listener2Events.length, 2);
        expect(listener2Events.last.sessionId, 'session-multi-002');
        expect(listener2Events.last.reason, 'thermal_throttling');

        // Ensure all subscriptions are cancelled and dispatcher listener count returns to zero
        await sub2.cancel();
        expect(dispatcher.duetEventListenerCountForTesting, 0);
      },
    );

    test(
      'a minimal native auto_stop payload reaches VGDuetEvents.stream through '
      'the same onDuetEvent dispatcher path as the green-screen events',
      () async {
        final receivedEvents = <VGDuetEvent>[];
        final subscription = VGDuetEvents.stream.listen(receivedEvents.add);
        addTearDown(() async => subscription.cancel());

        await _invokeNative('onDuetEvent', {
          'event': 'auto_stop',
          'sessionId': 'session-auto-stop-dispatch',
          'reason': 'trim_end_reached',
        });
        await pumpEventQueue();

        expect(receivedEvents.length, 1);
        expect(receivedEvents.first.type, VGDuetEventType.autoStop);
        expect(receivedEvents.first.sessionId, 'session-auto-stop-dispatch');
        expect(receivedEvents.first.reason, 'trim_end_reached');
        expect(receivedEvents.first.userMessage, '');
      },
    );
  });
}
