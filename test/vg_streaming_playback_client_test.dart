// Copyright (c) Connects — Vanguard Phase 4C7B.
// Public package-level adaptive streaming playback API Dart contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(channel, null);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Enums and Encoders/Decoders
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingFormatHint', () {
    test('toNative returns correct native enum names', () {
      expect(VGStreamingFormatHint.auto.toNative(), equals('AUTO'));
      expect(VGStreamingFormatHint.hls.toNative(), equals('HLS'));
      expect(VGStreamingFormatHint.dash.toNative(), equals('DASH'));
    });

    test('fromString parses strings accurately', () {
      expect(
        VGStreamingFormatHint.fromString('hls'),
        equals(VGStreamingFormatHint.hls),
      );
      expect(
        VGStreamingFormatHint.fromString('HLS'),
        equals(VGStreamingFormatHint.hls),
      );
      expect(
        VGStreamingFormatHint.fromString('dash'),
        equals(VGStreamingFormatHint.dash),
      );
      expect(
        VGStreamingFormatHint.fromString('DASH'),
        equals(VGStreamingFormatHint.dash),
      );
      expect(
        VGStreamingFormatHint.fromString('auto'),
        equals(VGStreamingFormatHint.auto),
      );
      expect(
        VGStreamingFormatHint.fromString(null),
        equals(VGStreamingFormatHint.auto),
      );
      expect(
        VGStreamingFormatHint.fromString('invalid'),
        equals(VGStreamingFormatHint.auto),
      );
    });

    test('fromString with fallback parameter works', () {
      expect(
        VGStreamingFormatHint.fromString(
          null,
          fallback: VGStreamingFormatHint.hls,
        ),
        equals(VGStreamingFormatHint.hls),
      );
      expect(
        VGStreamingFormatHint.fromString(
          'invalid',
          fallback: VGStreamingFormatHint.dash,
        ),
        equals(VGStreamingFormatHint.dash),
      );
      expect(
        VGStreamingFormatHint.fromString(
          'hls',
          fallback: VGStreamingFormatHint.dash,
        ),
        equals(VGStreamingFormatHint.hls),
      );
      expect(
        VGStreamingFormatHint.fromString(
          'dash',
          fallback: VGStreamingFormatHint.hls,
        ),
        equals(VGStreamingFormatHint.dash),
      );
      expect(
        VGStreamingFormatHint.fromString(
          'auto',
          fallback: VGStreamingFormatHint.hls,
        ),
        equals(VGStreamingFormatHint.auto),
      );
    });
  });

  group('VGStreamingNetworkProfile', () {
    test('toNative returns correct native enum names', () {
      expect(VGStreamingNetworkProfile.auto.toNative(), equals('AUTO'));
      expect(VGStreamingNetworkProfile.stable.toNative(), equals('STABLE'));
      expect(
        VGStreamingNetworkProfile.constrained.toNative(),
        equals('CONSTRAINED'),
      );
      expect(
        VGStreamingNetworkProfile.lowLatency.toNative(),
        equals('LOW_LATENCY'),
      );
    });

    test('fromString parses strings accurately', () {
      expect(
        VGStreamingNetworkProfile.fromString('auto'),
        equals(VGStreamingNetworkProfile.auto),
      );
      expect(
        VGStreamingNetworkProfile.fromString('stable'),
        equals(VGStreamingNetworkProfile.stable),
      );
      expect(
        VGStreamingNetworkProfile.fromString('STABLE'),
        equals(VGStreamingNetworkProfile.stable),
      );
      expect(
        VGStreamingNetworkProfile.fromString('constrained'),
        equals(VGStreamingNetworkProfile.constrained),
      );
      expect(
        VGStreamingNetworkProfile.fromString('CONSTRAINED'),
        equals(VGStreamingNetworkProfile.constrained),
      );
      expect(
        VGStreamingNetworkProfile.fromString('lowLatency'),
        equals(VGStreamingNetworkProfile.lowLatency),
      );
      expect(
        VGStreamingNetworkProfile.fromString('LOW_LATENCY'),
        equals(VGStreamingNetworkProfile.lowLatency),
      );
      expect(
        VGStreamingNetworkProfile.fromString('low_latency'),
        equals(VGStreamingNetworkProfile.lowLatency),
      );
      expect(
        VGStreamingNetworkProfile.fromString(null),
        equals(VGStreamingNetworkProfile.auto),
      );
      expect(
        VGStreamingNetworkProfile.fromString('invalid'),
        equals(VGStreamingNetworkProfile.auto),
      );
    });
  });

  group('VGStreamingPlaybackState.fromString', () {
    test('covers all states and aliases', () {
      expect(
        VGStreamingPlaybackState.fromString('idle'),
        equals(VGStreamingPlaybackState.idle),
      );
      expect(
        VGStreamingPlaybackState.fromString('Idle'),
        equals(VGStreamingPlaybackState.idle),
      );
      expect(
        VGStreamingPlaybackState.fromString('opening'),
        equals(VGStreamingPlaybackState.opening),
      );
      expect(
        VGStreamingPlaybackState.fromString('Opening'),
        equals(VGStreamingPlaybackState.opening),
      );
      expect(
        VGStreamingPlaybackState.fromString('Preparing'),
        equals(VGStreamingPlaybackState.opening),
      );
      expect(
        VGStreamingPlaybackState.fromString('preparing'),
        equals(VGStreamingPlaybackState.opening),
      );
      expect(
        VGStreamingPlaybackState.fromString('buffering'),
        equals(VGStreamingPlaybackState.buffering),
      );
      expect(
        VGStreamingPlaybackState.fromString('Buffering'),
        equals(VGStreamingPlaybackState.buffering),
      );
      expect(
        VGStreamingPlaybackState.fromString('playing'),
        equals(VGStreamingPlaybackState.playing),
      );
      expect(
        VGStreamingPlaybackState.fromString('Playing'),
        equals(VGStreamingPlaybackState.playing),
      );
      expect(
        VGStreamingPlaybackState.fromString('paused'),
        equals(VGStreamingPlaybackState.paused),
      );
      expect(
        VGStreamingPlaybackState.fromString('Paused'),
        equals(VGStreamingPlaybackState.paused),
      );
      expect(
        VGStreamingPlaybackState.fromString('Prepared'),
        equals(VGStreamingPlaybackState.paused),
      );
      expect(
        VGStreamingPlaybackState.fromString('prepared'),
        equals(VGStreamingPlaybackState.paused),
      );
      expect(
        VGStreamingPlaybackState.fromString('seeking'),
        equals(VGStreamingPlaybackState.seeking),
      );
      expect(
        VGStreamingPlaybackState.fromString('Seeking'),
        equals(VGStreamingPlaybackState.seeking),
      );
      expect(
        VGStreamingPlaybackState.fromString('ended'),
        equals(VGStreamingPlaybackState.ended),
      );
      expect(
        VGStreamingPlaybackState.fromString('Ended'),
        equals(VGStreamingPlaybackState.ended),
      );
      expect(
        VGStreamingPlaybackState.fromString('Completed'),
        equals(VGStreamingPlaybackState.ended),
      );
      expect(
        VGStreamingPlaybackState.fromString('completed'),
        equals(VGStreamingPlaybackState.ended),
      );
      expect(
        VGStreamingPlaybackState.fromString('failed'),
        equals(VGStreamingPlaybackState.failed),
      );
      expect(
        VGStreamingPlaybackState.fromString('Failed'),
        equals(VGStreamingPlaybackState.failed),
      );
      expect(
        VGStreamingPlaybackState.fromString('surfaceLost'),
        equals(VGStreamingPlaybackState.surfaceLost),
      );
      expect(
        VGStreamingPlaybackState.fromString('SurfaceLost'),
        equals(VGStreamingPlaybackState.surfaceLost),
      );
      expect(
        VGStreamingPlaybackState.fromString('surface_lost'),
        equals(VGStreamingPlaybackState.surfaceLost),
      );
      expect(
        VGStreamingPlaybackState.fromString('backgrounded'),
        equals(VGStreamingPlaybackState.backgrounded),
      );
      expect(
        VGStreamingPlaybackState.fromString('Backgrounded'),
        equals(VGStreamingPlaybackState.backgrounded),
      );
      expect(
        VGStreamingPlaybackState.fromString('disposed'),
        equals(VGStreamingPlaybackState.disposed),
      );
      expect(
        VGStreamingPlaybackState.fromString('Disposed'),
        equals(VGStreamingPlaybackState.disposed),
      );
      expect(
        VGStreamingPlaybackState.fromString('unsupported'),
        equals(VGStreamingPlaybackState.unsupported),
      );
      expect(
        VGStreamingPlaybackState.fromString('Unsupported'),
        equals(VGStreamingPlaybackState.unsupported),
      );
      expect(
        VGStreamingPlaybackState.fromString(null),
        equals(VGStreamingPlaybackState.idle),
      );
      expect(
        VGStreamingPlaybackState.fromString('unknown_state'),
        equals(VGStreamingPlaybackState.idle),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGStreamingPlaybackOptions
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingPlaybackOptions', () {
    test(
      'enforces positive dimensions and non-negative initialPositionMs assertions',
      () {
        expect(
          () => VGStreamingPlaybackOptions(
            uri: Uri.parse('https://example.com/live.m3u8'),
            initialWidth: 0,
            initialHeight: 720,
          ),
          throwsAssertionError,
        );

        expect(
          () => VGStreamingPlaybackOptions(
            uri: Uri.parse('https://example.com/live.m3u8'),
            initialWidth: 1280,
            initialHeight: -1,
          ),
          throwsAssertionError,
        );

        expect(
          () => VGStreamingPlaybackOptions(
            uri: Uri.parse('https://example.com/live.m3u8'),
            initialWidth: 1280,
            initialHeight: 720,
            initialPositionMs: -100,
          ),
          throwsAssertionError,
        );
      },
    );

    test('toArgs outputs defaults correctly', () {
      final options = VGStreamingPlaybackOptions(
        uri: Uri.parse('https://example.com/live.m3u8'),
        initialWidth: 1280,
        initialHeight: 720,
      );

      final args = options.toArgs();
      expect(args['uri'], equals('https://example.com/live.m3u8'));
      expect(args['initialWidth'], equals(1280));
      expect(args['initialHeight'], equals(720));
      expect(args['formatHint'], equals('AUTO'));
      expect(args['networkProfile'], equals('AUTO'));
      expect(args['autoPlay'], isTrue);
      expect(args.containsKey('httpHeaders'), isFalse);
      expect(args.containsKey('startPositionMs'), isFalse);
      expect(args.containsKey('cacheEnabled'), isFalse);
    });

    test(
      'toArgs forwards dimensions, headers, HLS/DASH/AUTO, LOW_LATENCY, autoplay, startPositionMs, and cache args',
      () {
        final options = VGStreamingPlaybackOptions(
          uri: Uri.parse('https://example.com/manifest.mpd'),
          initialWidth: 1920,
          initialHeight: 1080,
          httpHeaders: const {
            'Authorization': 'Bearer token123',
            'X-Custom': 'Value',
          },
          formatHint: VGStreamingFormatHint.dash,
          networkProfile: VGStreamingNetworkProfile.lowLatency,
          autoPlay: false,
          initialPositionMs: 15000,
          cacheOptions: const VGPlaybackCacheOptions(
            cacheEnabled: true,
            cacheMaxBytes: 100 * 1024 * 1024,
            cacheDirectoryName: 'test_cache',
            minimumFreeBytesAfterPrewarm: 32 * 1024 * 1024,
          ),
        );

        final args = options.toArgs();
        expect(args['uri'], equals('https://example.com/manifest.mpd'));
        expect(args['initialWidth'], equals(1920));
        expect(args['initialHeight'], equals(1080));
        expect(
          args['httpHeaders'],
          equals({'Authorization': 'Bearer token123', 'X-Custom': 'Value'}),
        );
        expect(args['formatHint'], equals('DASH'));
        expect(args['networkProfile'], equals('LOW_LATENCY'));
        expect(args['autoPlay'], isFalse);
        expect(args['startPositionMs'], equals(15000));
        expect(args['cacheEnabled'], isTrue);
        expect(args['cacheMaxBytes'], equals(100 * 1024 * 1024));
        expect(args['cacheDirectoryName'], equals('test_cache'));
        expect(args['minimumFreeBytesAfterPrewarm'], equals(32 * 1024 * 1024));
      },
    );

    test('toArgs formatHint HLS and networkProfile STABLE and CONSTRAINED', () {
      final hlsOptions = VGStreamingPlaybackOptions(
        uri: Uri.parse('https://example.com/stream.m3u8'),
        initialWidth: 640,
        initialHeight: 480,
        formatHint: VGStreamingFormatHint.hls,
        networkProfile: VGStreamingNetworkProfile.stable,
      );
      expect(hlsOptions.toArgs()['formatHint'], equals('HLS'));
      expect(hlsOptions.toArgs()['networkProfile'], equals('STABLE'));

      final constrainedOptions = VGStreamingPlaybackOptions(
        uri: Uri.parse('https://example.com/stream.m3u8'),
        initialWidth: 640,
        initialHeight: 480,
        networkProfile: VGStreamingNetworkProfile.constrained,
      );
      expect(
        constrainedOptions.toArgs()['networkProfile'],
        equals('CONSTRAINED'),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. VGStreamingPlaybackSession
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingPlaybackSession', () {
    test(
      'fromMap parses all fields defensively and handles non-string keys',
      () {
        final rawMap = <Object?, Object?>{
          'pass': true,
          'phase': 'Phase4C1D1',
          'sessionId': 'custom_sess_001',
          'textureId': 42,
          'format': 'HLS',
          'state': 'Playing',
          'durationMs': 60000,
          'positionMs': 12000,
          'bufferedPositionMs': 18000,
          'liveOffsetMs': 1500,
          'videoWidth': 1280,
          'videoHeight': 720,
          'renderedFrames': 360,
          'decodedFrames': 365,
          'raw': 'status=OK;state=Playing',
          123: 'integer_key_value',
        };

        final session = VGStreamingPlaybackSession.fromMap(rawMap);
        expect(session.pass, isTrue);
        expect(session.phase, equals('Phase4C1D1'));
        expect(session.sessionId, equals('custom_sess_001'));
        expect(session.textureId, equals(42));
        expect(session.format, equals(VGStreamingFormatHint.hls));
        expect(session.state, equals(VGStreamingPlaybackState.playing));
        expect(session.durationMs, equals(60000));
        expect(session.positionMs, equals(12000));
        expect(session.bufferedPositionMs, equals(18000));
        expect(session.liveOffsetMs, equals(1500));
        expect(session.videoWidth, equals(1280));
        expect(session.videoHeight, equals(720));
        expect(session.rotationDegrees, equals(0));
        expect(session.displayWidth, equals(0));
        expect(session.displayHeight, equals(0));
        expect(session.effectiveDisplayWidth, equals(1280));
        expect(session.effectiveDisplayHeight, equals(720));
        expect(session.hasRotationMetadata, isFalse);
        expect(session.renderedFrames, equals(360));
        expect(session.decodedFrames, equals(365));
        expect(session.raw, equals('status=OK;state=Playing'));
        expect(session.diagnostics['pass'], isTrue);
        expect(session.diagnostics['123'], equals('integer_key_value'));
      },
    );

    test(
      'fromMap parses explicit displayWidth and displayHeight and prioritizes them',
      () {
        final rawMap = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'state': 'Playing',
          'videoWidth': 1920,
          'videoHeight': 1080,
          'rotationDegrees': 90,
          'displayWidth': 1080,
          'displayHeight': 1920,
        };

        final session = VGStreamingPlaybackSession.fromMap(rawMap);
        expect(session.videoWidth, equals(1920));
        expect(session.videoHeight, equals(1080));
        expect(session.rotationDegrees, equals(90));
        expect(session.displayWidth, equals(1080));
        expect(session.displayHeight, equals(1920));
        expect(session.effectiveDisplayWidth, equals(1080));
        expect(session.effectiveDisplayHeight, equals(1920));
        expect(session.hasRotationMetadata, isTrue);
      },
    );

    test(
      'fromMap parses rotationDegrees 90 and 270 and swaps effective display dimensions when display dimensions absent',
      () {
        final rot90Map = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'state': 'Playing',
          'videoWidth': 1920,
          'videoHeight': 1080,
          'rotationDegrees': 90,
        };

        final session90 = VGStreamingPlaybackSession.fromMap(rot90Map);
        expect(session90.videoWidth, equals(1920));
        expect(session90.videoHeight, equals(1080));
        expect(session90.rotationDegrees, equals(90));
        expect(session90.displayWidth, equals(0));
        expect(session90.displayHeight, equals(0));
        expect(session90.effectiveDisplayWidth, equals(1080));
        expect(session90.effectiveDisplayHeight, equals(1920));
        expect(session90.hasRotationMetadata, isTrue);

        final rot270Map = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'state': 'Playing',
          'videoWidth': 1280,
          'videoHeight': 720,
          'rotation': 270,
        };

        final session270 = VGStreamingPlaybackSession.fromMap(rot270Map);
        expect(session270.videoWidth, equals(1280));
        expect(session270.videoHeight, equals(720));
        expect(session270.rotationDegrees, equals(270));
        expect(session270.effectiveDisplayWidth, equals(720));
        expect(session270.effectiveDisplayHeight, equals(1280));
        expect(session270.hasRotationMetadata, isTrue);
      },
    );

    test(
      'fromMap preserves aspect ratio for rotation 0 and 180 without swapping dimensions',
      () {
        final rot0Map = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'state': 'Playing',
          'videoWidth': 1920,
          'videoHeight': 1080,
          'rotationDegrees': 0,
        };
        final session0 = VGStreamingPlaybackSession.fromMap(rot0Map);
        expect(session0.effectiveDisplayWidth, equals(1920));
        expect(session0.effectiveDisplayHeight, equals(1080));
        expect(session0.hasRotationMetadata, isFalse);

        final rot180Map = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'state': 'Playing',
          'videoWidth': 1920,
          'videoHeight': 1080,
          'rotationDegrees': 180,
        };
        final session180 = VGStreamingPlaybackSession.fromMap(rot180Map);
        expect(session180.effectiveDisplayWidth, equals(1920));
        expect(session180.effectiveDisplayHeight, equals(1080));
        expect(session180.hasRotationMetadata, isTrue);
      },
    );

    test(
      'fromMap normalizes non-cardinal, negative, or invalid rotation strings to 0 safely',
      () {
        final invalidMap1 = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'videoWidth': 1280,
          'videoHeight': 720,
          'rotationDegrees': 45,
        };
        final session1 = VGStreamingPlaybackSession.fromMap(invalidMap1);
        expect(session1.rotationDegrees, equals(0));
        expect(session1.effectiveDisplayWidth, equals(1280));
        expect(session1.effectiveDisplayHeight, equals(720));

        final invalidMap2 = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'videoWidth': 1280,
          'videoHeight': 720,
          'rotationDegrees': 'not_a_number',
        };
        final session2 = VGStreamingPlaybackSession.fromMap(invalidMap2);
        expect(session2.rotationDegrees, equals(0));

        final cardinalStringMap = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'videoWidth': 1280,
          'videoHeight': 720,
          'rotationDegrees': '90',
        };
        final session3 = VGStreamingPlaybackSession.fromMap(cardinalStringMap);
        expect(session3.rotationDegrees, equals(90));
        expect(session3.effectiveDisplayWidth, equals(720));
        expect(session3.effectiveDisplayHeight, equals(1280));

        final modulo360Map = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'videoWidth': 1280,
          'videoHeight': 720,
          'rotationDegrees': -90,
        };
        final session4 = VGStreamingPlaybackSession.fromMap(modulo360Map);
        expect(session4.rotationDegrees, equals(270));
        expect(session4.effectiveDisplayWidth, equals(720));
        expect(session4.effectiveDisplayHeight, equals(1280));
      },
    );

    test(
      'effectiveDisplayWidth and effectiveDisplayHeight return 0 when source dimensions are non-positive',
      () {
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'zero_dim',
          textureId: 10,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          videoWidth: 0,
          videoHeight: 0,
          rotationDegrees: 90,
          raw: '',
          diagnostics: {},
        );
        expect(session.effectiveDisplayWidth, equals(0));
        expect(session.effectiveDisplayHeight, equals(0));
        expect(session.hasRotationMetadata, isTrue);
      },
    );

    test(
      'sessionId falls back to textureId string when native sessionId is absent',
      () {
        final rawMap = <Object?, Object?>{
          'pass': true,
          'textureId': 105,
          'state': 'Prepared',
        };

        final session = VGStreamingPlaybackSession.fromMap(rawMap);
        expect(session.sessionId, equals('105'));
        expect(session.textureId, equals(105));
        expect(session.state, equals(VGStreamingPlaybackState.paused));
      },
    );

    test(
      'sessionId falls back to empty string when textureId is negative and sessionId absent',
      () {
        final rawMap = <Object?, Object?>{
          'pass': false,
          'textureId': -1,
          'state': 'Failed',
        };

        final session = VGStreamingPlaybackSession.fromMap(rawMap);
        expect(session.sessionId, equals(''));
        expect(session.textureId, equals(-1));
        expect(session.state, equals(VGStreamingPlaybackState.failed));
      },
    );

    test('unsupported factory returns safe fallback values', () {
      final session = VGStreamingPlaybackSession.unsupported();
      expect(session.pass, isFalse);
      expect(session.phase, equals('unsupported'));
      expect(session.sessionId, equals(''));
      expect(session.textureId, equals(-1));
      expect(session.format, equals(VGStreamingFormatHint.auto));
      expect(session.state, equals(VGStreamingPlaybackState.unsupported));
      expect(session.durationMs, equals(-1));
      expect(session.positionMs, equals(0));
      expect(session.bufferedPositionMs, equals(0));
      expect(session.liveOffsetMs, isNull);
      expect(session.videoWidth, equals(0));
      expect(session.videoHeight, equals(0));
      expect(session.rotationDegrees, equals(0));
      expect(session.displayWidth, equals(0));
      expect(session.displayHeight, equals(0));
      expect(session.effectiveDisplayWidth, equals(0));
      expect(session.effectiveDisplayHeight, equals(0));
      expect(session.hasRotationMetadata, isFalse);
      expect(session.renderedFrames, equals(0));
      expect(session.decodedFrames, equals(0));
      expect(session.raw, equals('status=UNSUPPORTED;platform=non-android'));
      expect(session.toString(), contains('unsupported'));
      expect(session.toString(), contains('rotationDegrees=0'));
      expect(session.toString(), contains('displayWidth=0'));
      expect(session.toString(), contains('displayHeight=0'));
    });

    test(
      'fromMap preserves fallbackFormat when native format/formatHint is absent or unknown',
      () {
        final absentMap = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'state': 'Playing',
        };
        final session1 = VGStreamingPlaybackSession.fromMap(
          absentMap,
          fallbackFormat: VGStreamingFormatHint.hls,
        );
        expect(session1.format, equals(VGStreamingFormatHint.hls));

        final unknownMap = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'format': 'unknown_format',
        };
        final session2 = VGStreamingPlaybackSession.fromMap(
          unknownMap,
          fallbackFormat: VGStreamingFormatHint.dash,
        );
        expect(session2.format, equals(VGStreamingFormatHint.dash));

        final explicitMap = <Object?, Object?>{
          'pass': true,
          'textureId': 10,
          'format': 'DASH',
        };
        final session3 = VGStreamingPlaybackSession.fromMap(
          explicitMap,
          fallbackFormat: VGStreamingFormatHint.hls,
        );
        expect(session3.format, equals(VGStreamingFormatHint.dash));

        final defaultFallback = VGStreamingPlaybackSession.fromMap(absentMap);
        expect(defaultFallback.format, equals(VGStreamingFormatHint.auto));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. VGStreamingPlaybackClient MethodChannel contracts
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingPlaybackClient', () {
    test(
      'open calls createAndroidDagPhase4C1D1StreamingPlayback and parses response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'createAndroidDagPhase4C1D1StreamingPlayback') {
            return <Object?, Object?>{
              'pass': true,
              'phase': 'Phase4C1D1',
              'textureId': 77,
              'sessionId': 'stream_sess_77',
              'state': 'Preparing',
              'format': 'HLS',
              'width': 1280,
              'height': 720,
              'raw': 'status=OK;state=Preparing',
            };
          }
          return null;
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        final options = VGStreamingPlaybackOptions(
          uri: Uri.parse('https://example.com/live.m3u8'),
          initialWidth: 1280,
          initialHeight: 720,
          formatHint: VGStreamingFormatHint.hls,
        );

        final session = await client.open(options);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('createAndroidDagPhase4C1D1StreamingPlayback'),
        );
        final callArgs = recordedCall!.arguments as Map;
        expect(callArgs['uri'], equals('https://example.com/live.m3u8'));
        expect(callArgs['initialWidth'], equals(1280));
        expect(callArgs['initialHeight'], equals(720));
        expect(callArgs['formatHint'], equals('HLS'));

        expect(session.pass, isTrue);
        expect(session.phase, equals('Phase4C1D1'));
        expect(session.sessionId, equals('stream_sess_77'));
        expect(session.textureId, equals(77));
        expect(session.state, equals(VGStreamingPlaybackState.opening));
        expect(session.format, equals(VGStreamingFormatHint.hls));
        expect(session.videoWidth, equals(1280));
        expect(session.videoHeight, equals(720));
        expect(session.raw, equals('status=OK;state=Preparing'));
      },
    );

    test(
      'open with formatHint HLS preserves format when native response omits format',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createAndroidDagPhase4C1D1StreamingPlayback') {
            return <Object?, Object?>{
              'pass': true,
              'phase': 'Phase4C1D1',
              'textureId': 88,
              'sessionId': 'stream_sess_88',
              'state': 'Playing',
              'raw': 'status=OK;state=Playing',
            };
          }
          return null;
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        final options = VGStreamingPlaybackOptions(
          uri: Uri.parse('https://example.com/live.m3u8'),
          initialWidth: 1280,
          initialHeight: 720,
          formatHint: VGStreamingFormatHint.hls,
        );

        final session = await client.open(options);
        expect(session.pass, isTrue);
        expect(session.format, equals(VGStreamingFormatHint.hls));
      },
    );

    test(
      'open with formatHint DASH preserves format when native response omits format',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createAndroidDagPhase4C1D1StreamingPlayback') {
            return <Object?, Object?>{
              'pass': true,
              'phase': 'Phase4C1D1',
              'textureId': 89,
              'sessionId': 'stream_sess_89',
              'state': 'Playing',
              'raw': 'status=OK;state=Playing',
            };
          }
          return null;
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        final options = VGStreamingPlaybackOptions(
          uri: Uri.parse('https://example.com/manifest.mpd'),
          initialWidth: 1920,
          initialHeight: 1080,
          formatHint: VGStreamingFormatHint.dash,
        );

        final session = await client.open(options);
        expect(session.pass, isTrue);
        expect(session.format, equals(VGStreamingFormatHint.dash));
      },
    );

    test(
      'play forwards textureId to playAndroidDagPhase4C1D1StreamingPlayback',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'playAndroidDagPhase4C1D1StreamingPlayback') {
            return <Object?, Object?>{
              'pass': true,
              'phase': 'Phase4C1D1',
              'textureId': 77,
              'state': 'Playing',
              'raw': 'status=OK;state=Playing',
            };
          }
          return null;
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'stream_sess_77',
          textureId: 77,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.paused,
          raw: 'status=OK;state=Paused',
          diagnostics: {},
        );

        final result = await client.play(session);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('playAndroidDagPhase4C1D1StreamingPlayback'),
        );
        expect(recordedCall!.arguments, equals({'textureId': 77}));
        expect(result.pass, isTrue);
        expect(result.state, equals(VGStreamingPlaybackState.playing));
        expect(result.format, equals(VGStreamingFormatHint.hls));
      },
    );

    test(
      'pause forwards textureId to pauseAndroidDagPhase4C1D1StreamingPlayback',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'pauseAndroidDagPhase4C1D1StreamingPlayback') {
            return <Object?, Object?>{
              'pass': true,
              'phase': 'Phase4C1D1',
              'textureId': 77,
              'state': 'Paused',
              'raw': 'status=OK;state=Paused',
            };
          }
          return null;
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'stream_sess_77',
          textureId: 77,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          raw: 'status=OK;state=Playing',
          diagnostics: {},
        );

        final result = await client.pause(session);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('pauseAndroidDagPhase4C1D1StreamingPlayback'),
        );
        expect(recordedCall!.arguments, equals({'textureId': 77}));
        expect(result.pass, isTrue);
        expect(result.state, equals(VGStreamingPlaybackState.paused));
        expect(result.format, equals(VGStreamingFormatHint.hls));
      },
    );

    test(
      'seek forwards textureId and positionMs to seekAndroidDagPhase4C1D1StreamingPlayback',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'seekAndroidDagPhase4C1D1StreamingPlayback') {
            return <Object?, Object?>{
              'pass': true,
              'phase': 'Phase4C1D1',
              'textureId': 77,
              'positionMs': 5000,
              'state': 'Seeking',
              'raw': 'status=OK;state=Seeking;positionMs=5000',
            };
          }
          return null;
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'stream_sess_77',
          textureId: 77,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          raw: 'status=OK;state=Playing',
          diagnostics: {},
        );

        final result = await client.seek(session, 5000);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('seekAndroidDagPhase4C1D1StreamingPlayback'),
        );
        expect(
          recordedCall!.arguments,
          equals({'textureId': 77, 'positionMs': 5000}),
        );
        expect(result.pass, isTrue);
        expect(result.state, equals(VGStreamingPlaybackState.seeking));
        expect(result.positionMs, equals(5000));
        expect(result.format, equals(VGStreamingFormatHint.hls));
      },
    );

    test(
      'stop forwards textureId to stopAndroidDagPhase4C1D1StreamingPlayback',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'stopAndroidDagPhase4C1D1StreamingPlayback') {
            return <Object?, Object?>{
              'pass': true,
              'phase': 'Phase4C1D1',
              'textureId': 77,
              'state': 'Idle',
              'raw': 'status=OK;state=Idle',
            };
          }
          return null;
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'stream_sess_77',
          textureId: 77,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          raw: 'status=OK;state=Playing',
          diagnostics: {},
        );

        final result = await client.stop(session);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('stopAndroidDagPhase4C1D1StreamingPlayback'),
        );
        expect(recordedCall!.arguments, equals({'textureId': 77}));
        expect(result.pass, isTrue);
        expect(result.state, equals(VGStreamingPlaybackState.idle));
        expect(result.format, equals(VGStreamingFormatHint.hls));
      },
    );

    test(
      'getStatus forwards textureId to diagnoseAndroidDagPhase4C1D1StreamingPlayback',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'diagnoseAndroidDagPhase4C1D1StreamingPlayback') {
            return <Object?, Object?>{
              'pass': true,
              'phase': 'Phase4C1D1',
              'textureId': 77,
              'state': 'Playing',
              'renderedFrames': 450,
              'raw': 'status=OK;state=Playing',
            };
          }
          return null;
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'stream_sess_77',
          textureId: 77,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          raw: 'status=OK;state=Playing',
          diagnostics: {},
        );

        final result = await client.getStatus(session);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('diagnoseAndroidDagPhase4C1D1StreamingPlayback'),
        );
        expect(recordedCall!.arguments, equals({'textureId': 77}));
        expect(result.pass, isTrue);
        expect(result.renderedFrames, equals(450));
        expect(result.state, equals(VGStreamingPlaybackState.playing));
        expect(result.format, equals(VGStreamingFormatHint.hls));
      },
    );

    test(
      'getStatus and control methods preserve prior session.format when native response omits format',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          return <Object?, Object?>{
            'pass': true,
            'phase': 'Phase4C1D1',
            'textureId': 77,
            'state': 'Playing',
            'raw': 'status=OK;state=Playing',
          };
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'stream_sess_77',
          textureId: 77,
          format: VGStreamingFormatHint.dash,
          state: VGStreamingPlaybackState.paused,
          raw: 'status=OK;state=Paused',
          diagnostics: {},
        );

        final statusResult = await client.getStatus(session);
        expect(statusResult.format, equals(VGStreamingFormatHint.dash));

        final playResult = await client.play(session);
        expect(playResult.format, equals(VGStreamingFormatHint.dash));

        final pauseResult = await client.pause(session);
        expect(pauseResult.format, equals(VGStreamingFormatHint.dash));

        final seekResult = await client.seek(session, 5000);
        expect(seekResult.format, equals(VGStreamingFormatHint.dash));

        final stopResult = await client.stop(session);
        expect(stopResult.format, equals(VGStreamingFormatHint.dash));
      },
    );

    test(
      'dispose forwards textureId to disposeAndroidDagPhase4C1D1StreamingPlayback',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'disposeAndroidDagPhase4C1D1StreamingPlayback') {
            return <Object?, Object?>{
              'pass': true,
              'state': 'Disposed',
              'textureId': 77,
              'raw': 'status=OK;already_disposed',
            };
          }
          return null;
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'stream_sess_77',
          textureId: 77,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          raw: 'status=OK;state=Playing',
          diagnostics: {},
        );

        await client.dispose(session);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('disposeAndroidDagPhase4C1D1StreamingPlayback'),
        );
        expect(recordedCall!.arguments, equals({'textureId': 77}));
      },
    );

    test('returns unsupported when platform returns non-map', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return 'not_a_map';
      });

      final client = VGStreamingPlaybackClient(channel: channel);
      final options = VGStreamingPlaybackOptions(
        uri: Uri.parse('https://example.com/test.m3u8'),
        initialWidth: 640,
        initialHeight: 480,
      );

      final openResult = await client.open(options);
      expect(openResult.state, equals(VGStreamingPlaybackState.unsupported));

      const session = VGStreamingPlaybackSession(
        pass: true,
        phase: 'test',
        sessionId: '1',
        textureId: 1,
        format: VGStreamingFormatHint.auto,
        state: VGStreamingPlaybackState.idle,
        raw: '',
        diagnostics: {},
      );

      final playResult = await client.play(session);
      expect(playResult.state, equals(VGStreamingPlaybackState.unsupported));

      final pauseResult = await client.pause(session);
      expect(pauseResult.state, equals(VGStreamingPlaybackState.unsupported));

      final seekResult = await client.seek(session, 1000);
      expect(seekResult.state, equals(VGStreamingPlaybackState.unsupported));

      final stopResult = await client.stop(session);
      expect(stopResult.state, equals(VGStreamingPlaybackState.unsupported));

      final statusResult = await client.getStatus(session);
      expect(statusResult.state, equals(VGStreamingPlaybackState.unsupported));
    });

    test(
      'MissingPluginException returns typed unsupported for all methods and dispose does not throw',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException(
            'No implementation found for method ${call.method}',
          );
        });

        final client = VGStreamingPlaybackClient(channel: channel);
        final options = VGStreamingPlaybackOptions(
          uri: Uri.parse('https://example.com/test.m3u8'),
          initialWidth: 1280,
          initialHeight: 720,
        );

        final openResult = await client.open(options);
        expect(openResult.pass, isFalse);
        expect(openResult.phase, equals('unsupported'));
        expect(openResult.state, equals(VGStreamingPlaybackState.unsupported));
        expect(openResult.textureId, equals(-1));
        expect(openResult.raw, contains('status=UNSUPPORTED'));

        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'test',
          sessionId: '1',
          textureId: 1,
          format: VGStreamingFormatHint.auto,
          state: VGStreamingPlaybackState.playing,
          raw: '',
          diagnostics: {},
        );

        final playResult = await client.play(session);
        expect(playResult.state, equals(VGStreamingPlaybackState.unsupported));

        final pauseResult = await client.pause(session);
        expect(pauseResult.state, equals(VGStreamingPlaybackState.unsupported));

        final seekResult = await client.seek(session, 1000);
        expect(seekResult.state, equals(VGStreamingPlaybackState.unsupported));

        final stopResult = await client.stop(session);
        expect(stopResult.state, equals(VGStreamingPlaybackState.unsupported));

        final statusResult = await client.getStatus(session);
        expect(
          statusResult.state,
          equals(VGStreamingPlaybackState.unsupported),
        );

        // dispose must complete without throwing
        await expectLater(client.dispose(session), completes);
      },
    );
  });
}
