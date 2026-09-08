// vg_editor_audio_readiness_test.dart
// Vanguard Media Engine — iOS Phase 10F Slice 3 Async Audio Readiness Tests
//
// Coverage:
//   REQ-4: Controller initialize with {textureId, width, height, prepareSessionId, audioPending:true}
//          sets isReady == true and audioReadiness == pending; matching native event changes it to ready.
//   REQ-5: Controller ignores wrong textureId and wrong prepareSessionId events.
//   REQ-6: Controller initialize with audioPending:false sets terminal silent; a later event cannot change it.
//   REQ-7: Controller updateDraft establishes a new prepareSessionId; old event is ignored and new matching event is accepted.
//   REQ-8: Controller play while audioReadiness == pending still invokes timelinePlay.
//   VGEditorValue:
//     - default audioReadiness is unknown
//     - isTerminal returns true for ready, silent, failed
//   Edge cases & integration:
//     - pre-registration buffered audio state drained during initialize()
//     - terminal ready state is sticky
//     - terminal failed state is reached when state == 'failed'
//     - unknown audio state string is dropped silently
//     - disposed controller drops audio events gracefully

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/channel/vanguard_channel_dispatcher.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';
import 'package:vanguard_media_engine/vg_editor_value.dart';

// ── Test Fixtures ─────────────────────────────────────────────────────────────

VGClipDescriptor _clip({String id = 'clip-1', double duration = 5.0}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/fixture_$id.mp4',
      durationSeconds: duration,
      trimStartSeconds: 0.0,
      trimEndSeconds: duration,
    );

VGEditorDraft _draft({String id = 'draft-test'}) => VGEditorDraft(
  id: id,
  clips: [
    _clip(id: 'clip-A'),
    _clip(id: 'clip-B'),
  ],
);

// ── Mock Channel Setup ────────────────────────────────────────────────────────

const _channelName = 'vanguard_media_engine';

void _setMockHandler(
  Future<Object?> Function(String method, dynamic args) handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (call) => handler(call.method, call.arguments),
      );
}

void _clearMockHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), null);
}

Future<void> _simulateNativeCall(String method, [dynamic arguments]) async {
  final codec = const StandardMethodCodec();
  final data = codec.encodeMethodCall(MethodCall(method, arguments));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(_channelName, data, (ByteData? reply) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VanguardChannelDispatcher dispatcher;

  setUp(() {
    dispatcher = VanguardChannelDispatcher.instance;
    dispatcher.resetForTesting();
  });

  tearDown(() {
    _clearMockHandler();
    dispatcher.resetForTesting();
  });

  // ── VGEditorValue Audio Readiness Tests ────────────────────────────────────

  group('VGEditorValue — audioReadiness contract', () {
    test('default value has audioReadiness == unknown', () {
      final value = VGEditorValue(draft: _draft());
      expect(value.audioReadiness, VGAudioReadiness.unknown);
    });

    test('isTerminal is true only for ready, silent, failed', () {
      expect(VGAudioReadiness.unknown.isTerminal, isFalse);
      expect(VGAudioReadiness.pending.isTerminal, isFalse);
      expect(VGAudioReadiness.ready.isTerminal, isTrue);
      expect(VGAudioReadiness.silent.isTerminal, isTrue);
      expect(VGAudioReadiness.failed.isTerminal, isTrue);
    });

    test('copyWith preserves and updates audioReadiness', () {
      final initial = VGEditorValue(
        draft: _draft(),
        audioReadiness: VGAudioReadiness.pending,
      );
      expect(initial.audioReadiness, VGAudioReadiness.pending);

      final updated = initial.copyWith(audioReadiness: VGAudioReadiness.ready);
      expect(updated.audioReadiness, VGAudioReadiness.ready);

      final preserved = updated.copyWith(statusMessage: 'New status');
      expect(preserved.audioReadiness, VGAudioReadiness.ready);
      expect(preserved.statusMessage, 'New status');
    });
  });

  // ── REQ-4 ───────────────────────────────────────────────────────────────────

  group(
    'REQ-4: Controller initialize with audioPending: true and readiness transition',
    () {
      test(
        'initialize with audioPending:true sets isReady == true and audioReadiness == pending; matching native event changes it to ready',
        () async {
          const textureId = 42;
          const prepareSessionId = 1;

          _setMockHandler((method, args) async {
            if (method == 'createTimelineTexture') {
              return {
                'textureId': textureId,
                'width': 1280,
                'height': 720,
                'prepareSessionId': prepareSessionId,
                'audioPending': true,
              };
            }
            if (method == 'disposeTimeline') return null;
            return null;
          });

          final controller = VGEditorController(initialDraft: _draft());
          addTearDown(controller.dispose);

          expect(controller.value.isReady, isFalse);
          expect(controller.value.audioReadiness, VGAudioReadiness.unknown);

          await controller.initialize();

          // After initialize: video is ready, audio readiness is pending
          expect(controller.value.isReady, isTrue);
          expect(controller.value.textureId, textureId);
          expect(controller.value.renderWidth, 1280);
          expect(controller.value.renderHeight, 720);
          expect(controller.value.audioReadiness, VGAudioReadiness.pending);
          expect(controller.audioReadiness, VGAudioReadiness.pending);

          // Matching native event arrives
          await _simulateNativeCall('onTimelineAudioStateChanged', {
            'textureId': textureId,
            'prepareSessionId': prepareSessionId,
            'state': 'ready',
          });

          // Readiness updates to ready; video readiness remains true
          expect(controller.value.audioReadiness, VGAudioReadiness.ready);
          expect(controller.audioReadiness, VGAudioReadiness.ready);
          expect(controller.value.isReady, isTrue);
        },
      );

      test(
        'matching native event with state failed changes audioReadiness from pending to failed',
        () async {
          const textureId = 43;
          const prepareSessionId = 2;

          _setMockHandler((method, args) async {
            if (method == 'createTimelineTexture') {
              return {
                'textureId': textureId,
                'width': 640,
                'height': 360,
                'prepareSessionId': prepareSessionId,
                'audioPending': true,
              };
            }
            if (method == 'disposeTimeline') return null;
            return null;
          });

          final controller = VGEditorController(initialDraft: _draft());
          addTearDown(controller.dispose);
          await controller.initialize();

          expect(controller.value.audioReadiness, VGAudioReadiness.pending);

          await _simulateNativeCall('onTimelineAudioStateChanged', {
            'textureId': textureId,
            'prepareSessionId': prepareSessionId,
            'state': 'failed',
          });

          expect(controller.value.audioReadiness, VGAudioReadiness.failed);
          expect(controller.value.isReady, isTrue);
        },
      );
    },
  );

  // ── REQ-5 ───────────────────────────────────────────────────────────────────

  group(
    'REQ-5: Controller correlation filtering (textureId and prepareSessionId)',
    () {
      test('ignores event with wrong textureId', () async {
        const textureId = 10;
        const prepareSessionId = 1;

        _setMockHandler((method, args) async {
          if (method == 'createTimelineTexture') {
            return {
              'textureId': textureId,
              'width': 640,
              'height': 360,
              'prepareSessionId': prepareSessionId,
              'audioPending': true,
            };
          }
          if (method == 'disposeTimeline') return null;
          return null;
        });

        final controller = VGEditorController(initialDraft: _draft());
        addTearDown(controller.dispose);
        await controller.initialize();

        expect(controller.value.audioReadiness, VGAudioReadiness.pending);

        // Wrong textureId (99 != 10)
        await _simulateNativeCall('onTimelineAudioStateChanged', {
          'textureId': 99,
          'prepareSessionId': prepareSessionId,
          'state': 'ready',
        });

        expect(controller.value.audioReadiness, VGAudioReadiness.pending);
      });

      test('ignores event with wrong prepareSessionId', () async {
        const textureId = 10;
        const prepareSessionId = 1;

        _setMockHandler((method, args) async {
          if (method == 'createTimelineTexture') {
            return {
              'textureId': textureId,
              'width': 640,
              'height': 360,
              'prepareSessionId': prepareSessionId,
              'audioPending': true,
            };
          }
          if (method == 'disposeTimeline') return null;
          return null;
        });

        final controller = VGEditorController(initialDraft: _draft());
        addTearDown(controller.dispose);
        await controller.initialize();

        expect(controller.value.audioReadiness, VGAudioReadiness.pending);

        // Wrong prepareSessionId (99 != 1)
        await _simulateNativeCall('onTimelineAudioStateChanged', {
          'textureId': textureId,
          'prepareSessionId': 99,
          'state': 'ready',
        });

        expect(controller.value.audioReadiness, VGAudioReadiness.pending);
      });

      test(
        'ignores event when both textureId and prepareSessionId are wrong',
        () async {
          const textureId = 10;
          const prepareSessionId = 1;

          _setMockHandler((method, args) async {
            if (method == 'createTimelineTexture') {
              return {
                'textureId': textureId,
                'width': 640,
                'height': 360,
                'prepareSessionId': prepareSessionId,
                'audioPending': true,
              };
            }
            if (method == 'disposeTimeline') return null;
            return null;
          });

          final controller = VGEditorController(initialDraft: _draft());
          addTearDown(controller.dispose);
          await controller.initialize();

          expect(controller.value.audioReadiness, VGAudioReadiness.pending);

          await _simulateNativeCall('onTimelineAudioStateChanged', {
            'textureId': 999,
            'prepareSessionId': 999,
            'state': 'ready',
          });

          expect(controller.value.audioReadiness, VGAudioReadiness.pending);
        },
      );
    },
  );

  // ── REQ-6 ───────────────────────────────────────────────────────────────────

  group(
    'REQ-6: Controller initialize with audioPending: false sets terminal silent',
    () {
      test(
        'initialize with audioPending:false sets terminal silent; a later event cannot change it',
        () async {
          const textureId = 20;
          const prepareSessionId = 1;

          _setMockHandler((method, args) async {
            if (method == 'createTimelineTexture') {
              return {
                'textureId': textureId,
                'width': 640,
                'height': 360,
                'prepareSessionId': prepareSessionId,
                'audioPending': false,
              };
            }
            if (method == 'disposeTimeline') return null;
            return null;
          });

          final controller = VGEditorController(initialDraft: _draft());
          addTearDown(controller.dispose);
          await controller.initialize();

          // Terminal silent state
          expect(controller.value.isReady, isTrue);
          expect(controller.value.audioReadiness, VGAudioReadiness.silent);
          expect(controller.value.audioReadiness.isTerminal, isTrue);

          // Later matching event arrives with state 'ready'
          await _simulateNativeCall('onTimelineAudioStateChanged', {
            'textureId': textureId,
            'prepareSessionId': prepareSessionId,
            'state': 'ready',
          });

          // Terminal readiness is sticky: unchanged
          expect(controller.value.audioReadiness, VGAudioReadiness.silent);

          // Later matching event arrives with state 'failed'
          await _simulateNativeCall('onTimelineAudioStateChanged', {
            'textureId': textureId,
            'prepareSessionId': prepareSessionId,
            'state': 'failed',
          });

          expect(controller.value.audioReadiness, VGAudioReadiness.silent);
        },
      );

      test(
        'terminal ready state is sticky and cannot transition back to pending, silent, or failed',
        () async {
          const textureId = 21;
          const prepareSessionId = 1;

          _setMockHandler((method, args) async {
            if (method == 'createTimelineTexture') {
              return {
                'textureId': textureId,
                'width': 640,
                'height': 360,
                'prepareSessionId': prepareSessionId,
                'audioPending': true,
              };
            }
            if (method == 'disposeTimeline') return null;
            return null;
          });

          final controller = VGEditorController(initialDraft: _draft());
          addTearDown(controller.dispose);
          await controller.initialize();

          // Transition to ready
          await _simulateNativeCall('onTimelineAudioStateChanged', {
            'textureId': textureId,
            'prepareSessionId': prepareSessionId,
            'state': 'ready',
          });
          expect(controller.value.audioReadiness, VGAudioReadiness.ready);
          expect(controller.value.audioReadiness.isTerminal, isTrue);

          // Subsequent events for this session cannot change terminal ready
          await _simulateNativeCall('onTimelineAudioStateChanged', {
            'textureId': textureId,
            'prepareSessionId': prepareSessionId,
            'state': 'silent',
          });
          expect(controller.value.audioReadiness, VGAudioReadiness.ready);

          await _simulateNativeCall('onTimelineAudioStateChanged', {
            'textureId': textureId,
            'prepareSessionId': prepareSessionId,
            'state': 'failed',
          });
          expect(controller.value.audioReadiness, VGAudioReadiness.ready);
        },
      );
    },
  );

  // ── REQ-7 ───────────────────────────────────────────────────────────────────

  group('REQ-7: Controller updateDraft establishes new prepareSessionId', () {
    test(
      'updateDraft establishes a new prepareSessionId; old event is ignored and new matching event is accepted',
      () async {
        const initialTid = 100;
        const initialSid = 1;
        const updatedTid = 100;
        const updatedSid = 2;

        _setMockHandler((method, args) async {
          if (method == 'createTimelineTexture') {
            return {
              'textureId': initialTid,
              'width': 640,
              'height': 360,
              'prepareSessionId': initialSid,
              'audioPending': true,
            };
          }
          if (method == 'updateTimeline') {
            return {
              'textureId': updatedTid,
              'width': 640,
              'height': 360,
              'prepareSessionId': updatedSid,
              'audioPending': true,
            };
          }
          if (method == 'disposeTimeline') return null;
          return null;
        });

        final controller = VGEditorController(initialDraft: _draft());
        addTearDown(controller.dispose);
        await controller.initialize();

        expect(controller.value.audioReadiness, VGAudioReadiness.pending);

        // Update draft to establish new prepareSessionId
        await controller.updateDraft(_draft(id: 'draft-updated'));

        expect(controller.value.audioReadiness, VGAudioReadiness.pending);
        expect(controller.value.isReady, isTrue);

        // Old prepareSessionId event arrives: must be IGNORED
        await _simulateNativeCall('onTimelineAudioStateChanged', {
          'textureId': initialTid,
          'prepareSessionId': initialSid,
          'state': 'ready',
        });

        expect(controller.value.audioReadiness, VGAudioReadiness.pending);

        // New prepareSessionId matching event arrives: must be ACCEPTED
        await _simulateNativeCall('onTimelineAudioStateChanged', {
          'textureId': updatedTid,
          'prepareSessionId': updatedSid,
          'state': 'ready',
        });

        expect(controller.value.audioReadiness, VGAudioReadiness.ready);
      },
    );

    test(
      'updateDraft with texture ID change establishes new session and routes correctly',
      () async {
        const initialTid = 100;
        const initialSid = 10;
        const newTid = 200;
        const newSid = 20;

        _setMockHandler((method, args) async {
          if (method == 'createTimelineTexture') {
            return {
              'textureId': initialTid,
              'width': 640,
              'height': 360,
              'prepareSessionId': initialSid,
              'audioPending': true,
            };
          }
          if (method == 'updateTimeline') {
            return {
              'textureId': newTid,
              'width': 640,
              'height': 360,
              'prepareSessionId': newSid,
              'audioPending': true,
            };
          }
          if (method == 'disposeTimeline') return null;
          return null;
        });

        final controller = VGEditorController(initialDraft: _draft());
        addTearDown(controller.dispose);
        await controller.initialize();

        await controller.updateDraft(_draft(id: 'draft-2'));

        // Event for old texture and old session ignored
        await _simulateNativeCall('onTimelineAudioStateChanged', {
          'textureId': initialTid,
          'prepareSessionId': initialSid,
          'state': 'ready',
        });
        expect(controller.value.audioReadiness, VGAudioReadiness.pending);

        // Event for new texture but old session ignored
        await _simulateNativeCall('onTimelineAudioStateChanged', {
          'textureId': newTid,
          'prepareSessionId': initialSid,
          'state': 'ready',
        });
        expect(controller.value.audioReadiness, VGAudioReadiness.pending);

        // Event for new texture and new session accepted
        await _simulateNativeCall('onTimelineAudioStateChanged', {
          'textureId': newTid,
          'prepareSessionId': newSid,
          'state': 'ready',
        });
        expect(controller.value.audioReadiness, VGAudioReadiness.ready);
      },
    );
  });

  // ── REQ-8 ───────────────────────────────────────────────────────────────────

  group('REQ-8: Playback decoupled from audio readiness', () {
    test(
      'play while audioReadiness == pending still invokes timelinePlay',
      () async {
        const textureId = 30;
        const prepareSessionId = 5;
        final calledMethods = <String>[];

        _setMockHandler((method, args) async {
          calledMethods.add(method);
          if (method == 'createTimelineTexture') {
            return {
              'textureId': textureId,
              'width': 640,
              'height': 360,
              'prepareSessionId': prepareSessionId,
              'audioPending': true,
            };
          }
          if (method == 'timelinePlay') {
            return null;
          }
          if (method == 'disposeTimeline') return null;
          return null;
        });

        final controller = VGEditorController(initialDraft: _draft());
        addTearDown(controller.dispose);
        await controller.initialize();

        expect(controller.value.isReady, isTrue);
        expect(controller.value.audioReadiness, VGAudioReadiness.pending);

        calledMethods.clear();

        // Play while audio is still pending
        await controller.play();

        // timelinePlay must be invoked
        expect(calledMethods, contains('timelinePlay'));
        expect(controller.value.isPlaying, isTrue);
        expect(controller.value.audioReadiness, VGAudioReadiness.pending);
      },
    );

    test(
      'play while audioReadiness == silent still invokes timelinePlay',
      () async {
        const textureId = 31;
        const prepareSessionId = 6;
        final calledMethods = <String>[];

        _setMockHandler((method, args) async {
          calledMethods.add(method);
          if (method == 'createTimelineTexture') {
            return {
              'textureId': textureId,
              'width': 640,
              'height': 360,
              'prepareSessionId': prepareSessionId,
              'audioPending': false,
            };
          }
          if (method == 'timelinePlay') {
            return null;
          }
          if (method == 'disposeTimeline') return null;
          return null;
        });

        final controller = VGEditorController(initialDraft: _draft());
        addTearDown(controller.dispose);
        await controller.initialize();

        expect(controller.value.audioReadiness, VGAudioReadiness.silent);

        calledMethods.clear();
        await controller.play();

        expect(calledMethods, contains('timelinePlay'));
        expect(controller.value.isPlaying, isTrue);
      },
    );
  });

  // ── Edge Cases & Lifecycle ──────────────────────────────────────────────────

  group('Edge cases & lifecycle integration', () {
    test(
      'pre-registration buffered audio state is drained immediately during initialize()',
      () async {
        const textureId = 50;
        const prepareSessionId = 12;

        _setMockHandler((method, args) async {
          if (method == 'createTimelineTexture') {
            // Simulate native sending audio readiness event BEFORE initialize completes registration
            await _simulateNativeCall('onTimelineAudioStateChanged', {
              'textureId': textureId,
              'prepareSessionId': prepareSessionId,
              'state': 'ready',
            });
            return {
              'textureId': textureId,
              'width': 640,
              'height': 360,
              'prepareSessionId': prepareSessionId,
              'audioPending': true,
            };
          }
          if (method == 'disposeTimeline') return null;
          return null;
        });

        final controller = VGEditorController(initialDraft: _draft());
        addTearDown(controller.dispose);
        await controller.initialize();

        // Buffered event was drained during registerTimelineListener
        expect(controller.value.audioReadiness, VGAudioReadiness.ready);
        expect(controller.value.isReady, isTrue);
      },
    );

    test(
      'unknown audio state string is dropped and does not change readiness',
      () async {
        const textureId = 51;
        const prepareSessionId = 1;

        _setMockHandler((method, args) async {
          if (method == 'createTimelineTexture') {
            return {
              'textureId': textureId,
              'width': 640,
              'height': 360,
              'prepareSessionId': prepareSessionId,
              'audioPending': true,
            };
          }
          if (method == 'disposeTimeline') return null;
          return null;
        });

        final controller = VGEditorController(initialDraft: _draft());
        addTearDown(controller.dispose);
        await controller.initialize();

        expect(controller.value.audioReadiness, VGAudioReadiness.pending);

        await _simulateNativeCall('onTimelineAudioStateChanged', {
          'textureId': textureId,
          'prepareSessionId': prepareSessionId,
          'state': 'unknownState',
        });

        expect(controller.value.audioReadiness, VGAudioReadiness.pending);
      },
    );

    test('disposed controller drops audio events gracefully', () async {
      const textureId = 52;
      const prepareSessionId = 1;

      _setMockHandler((method, args) async {
        if (method == 'createTimelineTexture') {
          return {
            'textureId': textureId,
            'width': 640,
            'height': 360,
            'prepareSessionId': prepareSessionId,
            'audioPending': true,
          };
        }
        if (method == 'disposeTimeline') return null;
        return null;
      });

      final controller = VGEditorController(initialDraft: _draft());
      await controller.initialize();
      controller.dispose();

      // Delivering after dispose should not throw
      await expectLater(
        _simulateNativeCall('onTimelineAudioStateChanged', {
          'textureId': textureId,
          'prepareSessionId': prepareSessionId,
          'state': 'ready',
        }),
        completes,
      );
    });
  });
}
