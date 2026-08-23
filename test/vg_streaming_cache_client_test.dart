// vg_streaming_cache_client_test.dart
// Vanguard Media Engine — Phase 4C6F5: public streaming cache API Dart contract tests.

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
  // 1. VGPlaybackCacheOptions serialization
  // ─────────────────────────────────────────────────────────────────────────
  group('VGPlaybackCacheOptions.toArgs', () {
    test('default options serialize cacheEnabled=true only', () {
      const options = VGPlaybackCacheOptions();
      final args = options.toArgs();

      expect(args, equals(<String, Object?>{'cacheEnabled': true}));
    });

    test(
      'forwards cacheEnabled, cacheMaxBytes, cacheDirectoryName, and minimumFreeBytesAfterPrewarm',
      () {
        const options = VGPlaybackCacheOptions(
          cacheEnabled: false,
          cacheMaxBytes: 256 * 1024 * 1024,
          cacheDirectoryName: 'custom_vanguard_cache',
          minimumFreeBytesAfterPrewarm: 64 * 1024 * 1024,
        );
        final args = options.toArgs();

        expect(args['cacheEnabled'], isFalse);
        expect(args['cacheMaxBytes'], equals(256 * 1024 * 1024));
        expect(args['cacheDirectoryName'], equals('custom_vanguard_cache'));
        expect(args['minimumFreeBytesAfterPrewarm'], equals(64 * 1024 * 1024));
      },
    );

    test('forwards minimumFreeBytesAfterPrewarm=0 when guard is disabled', () {
      const options = VGPlaybackCacheOptions(minimumFreeBytesAfterPrewarm: 0);
      final args = options.toArgs();

      expect(args['cacheEnabled'], isTrue);
      expect(args['minimumFreeBytesAfterPrewarm'], equals(0));
      expect(args.containsKey('cacheMaxBytes'), isFalse);
      expect(args.containsKey('cacheDirectoryName'), isFalse);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2 & 3. VGStreamingCacheClient.prewarm contract and storage guard parsing
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingCacheClient.prewarm', () {
    test(
      'forwards minimumFreeBytesAfterPrewarm through MethodChannel args and parses blocked_low_storage result',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'startPlaybackCachePrewarm') {
            return <Object?, Object?>{
              'phase': 'Phase4C6F3',
              'pass': false,
              'requestId': 'req-blocked-101',
              'state': 'blocked_low_storage',
              'raw':
                  'status=BLOCKED;reason=LOW_STORAGE;available=52428800;required=67108864',
              'storageGuardPhase': 'Phase4C6F3',
              'storageGuardPass': false,
              'availableBytes': 52428800,
              'requestedBytes': 2097152,
              'minimumFreeBytesAfterPrewarm': 67108864,
              'projectedAvailableBytes': 50331648,
            };
          }
          return null;
        });

        final client = VGStreamingCacheClient(channel: channel);
        const options = VGPlaybackCacheOptions(
          minimumFreeBytesAfterPrewarm: 67108864,
        );

        final result = await client.prewarm(
          requestId: 'req-blocked-101',
          uri: Uri.parse('https://example.com/stream.mp4'),
          maxBytes: 2097152,
          options: options,
        );

        // Verify arguments forwarded over MethodChannel
        expect(recordedCall, isNotNull);
        expect(recordedCall!.method, equals('startPlaybackCachePrewarm'));
        final callArgs = recordedCall!.arguments as Map;
        expect(callArgs['requestId'], equals('req-blocked-101'));
        expect(callArgs['uri'], equals('https://example.com/stream.mp4'));
        expect(callArgs['maxBytes'], equals(2097152));
        expect(callArgs['cacheEnabled'], isTrue);
        expect(callArgs['minimumFreeBytesAfterPrewarm'], equals(67108864));

        // Verify parsed Dart result
        expect(
          result.state,
          equals(VGPlaybackPrewarmStartState.blockedLowStorage),
        );
        expect(result.pass, isFalse);
        expect(result.storageGuardPass, isFalse);
        expect(result.phase, equals('Phase4C6F3'));
        expect(result.requestId, equals('req-blocked-101'));
        expect(result.storageGuardPhase, equals('Phase4C6F3'));
        expect(result.availableBytes, equals(52428800));
        expect(result.requestedBytes, equals(2097152));
        expect(result.minimumFreeBytesAfterPrewarm, equals(67108864));
        expect(result.projectedAvailableBytes, equals(50331648));
        expect(
          result.raw,
          equals(
            'status=BLOCKED;reason=LOW_STORAGE;available=52428800;required=67108864',
          ),
        );
      },
    );

    test('parses storage_guard_error result correctly', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startPlaybackCachePrewarm') {
          return <Object?, Object?>{
            'phase': 'Phase4C6F3',
            'pass': false,
            'requestId': 'req-guard-err-202',
            'state': 'storage_guard_error',
            'raw': 'status=ERROR;reason=STATFS_FAILED',
            'storageGuardPhase': 'Phase4C6F3',
            'storageGuardPass': false,
          };
        }
        return null;
      });

      final client = VGStreamingCacheClient(channel: channel);
      final result = await client.prewarm(
        requestId: 'req-guard-err-202',
        uri: Uri.parse('https://example.com/audio.m4a'),
      );

      expect(
        result.state,
        equals(VGPlaybackPrewarmStartState.storageGuardError),
      );
      expect(result.pass, isFalse);
      expect(result.storageGuardPass, isFalse);
      expect(result.phase, equals('Phase4C6F3'));
      expect(result.requestId, equals('req-guard-err-202'));
      expect(result.storageGuardPhase, equals('Phase4C6F3'));
      expect(result.raw, equals('status=ERROR;reason=STATFS_FAILED'));
      expect(result.availableBytes, isNull);
      expect(result.projectedAvailableBytes, isNull);
    });

    test('parses accepted result correctly', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startPlaybackCachePrewarm') {
          return <Object?, Object?>{
            'phase': 'Phase4C6E',
            'pass': true,
            'requestId': 'req-accepted-303',
            'state': 'accepted',
            'raw': 'status=ACCEPTED',
            'storageGuardPhase': 'Phase4C6F3',
            'storageGuardPass': true,
            'availableBytes': 500000000,
            'requestedBytes': 2097152,
            'minimumFreeBytesAfterPrewarm': 67108864,
            'projectedAvailableBytes': 497902848,
          };
        }
        return null;
      });

      final client = VGStreamingCacheClient(channel: channel);
      final result = await client.prewarm(
        requestId: 'req-accepted-303',
        uri: Uri.parse('https://example.com/video.mp4'),
      );

      expect(result.state, equals(VGPlaybackPrewarmStartState.accepted));
      expect(result.pass, isTrue);
      expect(result.storageGuardPass, isTrue);
      expect(result.phase, equals('Phase4C6E'));
      expect(result.requestId, equals('req-accepted-303'));
      expect(result.availableBytes, equals(500000000));
      expect(result.projectedAvailableBytes, equals(497902848));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Missing plugin / unsupported platform handling
  // ─────────────────────────────────────────────────────────────────────────
  group('MissingPluginException / unsupported handling', () {
    const unhandledChannel = MethodChannel('unhandled_channel_test');

    test(
      'prewarm returns typed unsupported result when plugin is missing without throwing',
      () async {
        final client = VGStreamingCacheClient(channel: unhandledChannel);

        final result = await client.prewarm(
          requestId: 'req-missing-prewarm',
          uri: Uri.parse('https://example.com/clip.mp4'),
        );

        expect(result.state, equals(VGPlaybackPrewarmStartState.unsupported));
        expect(result.pass, isFalse);
        expect(result.phase, equals('unsupported'));
        expect(result.requestId, equals('req-missing-prewarm'));
        expect(result.raw, equals('status=UNSUPPORTED;platform=non-android'));
        expect(result.storageGuardPass, isNull);
      },
    );

    test(
      'getStatus returns typed unsupported result when plugin is missing without throwing',
      () async {
        final client = VGStreamingCacheClient(channel: unhandledChannel);

        final status = await client.getStatus();

        expect(status.pass, isFalse);
        expect(status.phase, equals('unsupported'));
        expect(status.state, equals('unsupported'));
        expect(status.cacheAvailable, isFalse);
        expect(status.cacheEnabled, isFalse);
        expect(status.cacheSpaceBytes, equals(0));
        expect(status.resourceCount, equals(0));
        expect(status.raw, equals('status=UNSUPPORTED;platform=non-android'));
      },
    );

    test(
      'clear returns typed unsupported result when plugin is missing without throwing',
      () async {
        final client = VGStreamingCacheClient(channel: unhandledChannel);

        final clearResult = await client.clear();

        expect(clearResult.pass, isFalse);
        expect(clearResult.phase, equals('unsupported'));
        expect(clearResult.state, equals('unsupported'));
        expect(clearResult.cacheAvailable, isFalse);
        expect(clearResult.beforeBytes, equals(0));
        expect(clearResult.afterBytes, equals(0));
        expect(clearResult.resourceCountBefore, equals(0));
        expect(clearResult.removedResourceCount, equals(0));
        expect(clearResult.failedResourceCount, equals(0));
        expect(
          clearResult.raw,
          equals('status=UNSUPPORTED;platform=non-android'),
        );
      },
    );

    test(
      'getPrewarmStatus, cancelPrewarm, and clear return typed unsupported results when plugin is missing',
      () async {
        final client = VGStreamingCacheClient(channel: unhandledChannel);

        final prewarmStatus = await client.getPrewarmStatus('req-missing-poll');
        expect(
          prewarmStatus.state,
          equals(VGPlaybackPrewarmJobState.unsupported),
        );
        expect(prewarmStatus.phase, equals('unsupported'));
        expect(prewarmStatus.requestId, equals('req-missing-poll'));
        expect(prewarmStatus.cacheAvailable, isFalse);

        final cancelResult = await client.cancelPrewarm('req-missing-cancel');
        expect(cancelResult.pass, isFalse);
        expect(cancelResult.phase, equals('unsupported'));
        expect(cancelResult.state, equals('unsupported'));
        expect(cancelResult.requestId, equals('req-missing-cancel'));

        final clearResult = await client.clear();
        expect(clearResult.pass, isFalse);
        expect(clearResult.phase, equals('unsupported'));
        expect(clearResult.state, equals('unsupported'));
        expect(clearResult.cacheAvailable, isFalse);
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Additional status and clear route coverage
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingCacheClient status, prewarmStatus, cancel, clear', () {
    test(
      'getStatus forwards options and parses Android status metrics',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'getPlaybackCacheStatus') {
            return <Object?, Object?>{
              'phase': 'Phase4C6E',
              'metricsPhase': 'Phase4C6F2',
              'pass': true,
              'state': 'available',
              'cacheAvailable': true,
              'cacheEnabled': true,
              'cacheDir': '/data/user/0/app/cache/vanguard_playback_cache',
              'maxCacheBytes': 536870912,
              'cacheSpaceBytes': 12345678,
              'resourceCount': 42,
              'raw': 'status=OK',
            };
          }
          return null;
        });

        final client = VGStreamingCacheClient(channel: channel);
        const options = VGPlaybackCacheOptions(
          cacheEnabled: true,
          cacheMaxBytes: 536870912,
          cacheDirectoryName: 'vanguard_playback_cache',
          minimumFreeBytesAfterPrewarm: 67108864,
        );
        final status = await client.getStatus(options: options);

        expect(recordedCall, isNotNull);
        expect(recordedCall!.method, equals('getPlaybackCacheStatus'));
        final callArgs = recordedCall!.arguments as Map;
        expect(callArgs['cacheEnabled'], isTrue);
        expect(callArgs['cacheMaxBytes'], equals(536870912));
        expect(
          callArgs['cacheDirectoryName'],
          equals('vanguard_playback_cache'),
        );
        expect(callArgs['minimumFreeBytesAfterPrewarm'], equals(67108864));

        expect(status.phase, equals('Phase4C6E'));
        expect(status.metricsPhase, equals('Phase4C6F2'));
        expect(status.pass, isTrue);
        expect(status.state, equals('available'));
        expect(status.cacheAvailable, isTrue);
        expect(status.cacheEnabled, isTrue);
        expect(
          status.cacheDir,
          equals('/data/user/0/app/cache/vanguard_playback_cache'),
        );
        expect(status.maxCacheBytes, equals(536870912));
        expect(status.cacheSpaceBytes, equals(12345678));
        expect(status.resourceCount, equals(42));
        expect(status.raw, equals('status=OK'));
      },
    );

    test('getPrewarmStatus parses job states', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getPlaybackCachePrewarmStatus') {
          return <Object?, Object?>{
            'phase': 'Phase4C6E',
            'requestId': 'req-status-404',
            'state': 'running',
            'bytesCached': 1048576,
            'newBytesCached': 524288,
            'requestLength': 2097152,
            'cacheAvailable': true,
            'raw': 'status=RUNNING',
          };
        }
        return null;
      });

      final client = VGStreamingCacheClient(channel: channel);
      final status = await client.getPrewarmStatus('req-status-404');

      expect(status.state, equals(VGPlaybackPrewarmJobState.running));
      expect(status.requestId, equals('req-status-404'));
      expect(status.bytesCached, equals(1048576));
      expect(status.newBytesCached, equals(524288));
      expect(status.requestLength, equals(2097152));
      expect(status.cacheAvailable, isTrue);
    });

    test('cancelPrewarm parses cancel result', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancelPlaybackCachePrewarm') {
          return <Object?, Object?>{
            'phase': 'Phase4C6E',
            'pass': true,
            'requestId': 'req-cancel-505',
            'state': 'cancel_requested',
            'raw': 'status=CANCEL_REQUESTED',
          };
        }
        return null;
      });

      final client = VGStreamingCacheClient(channel: channel);
      final result = await client.cancelPrewarm('req-cancel-505');

      expect(result.pass, isTrue);
      expect(result.phase, equals('Phase4C6E'));
      expect(result.requestId, equals('req-cancel-505'));
      expect(result.state, equals('cancel_requested'));
    });

    test('clear forwards options and parses clear result', () async {
      MethodCall? recordedCall;
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        recordedCall = call;
        if (call.method == 'clearPlaybackCache') {
          return <Object?, Object?>{
            'phase': 'Phase4C6F',
            'pass': true,
            'state': 'cleared',
            'cacheAvailable': true,
            'beforeBytes': 10000000,
            'afterBytes': 0,
            'resourceCountBefore': 15,
            'removedResourceCount': 15,
            'failedResourceCount': 0,
            'raw': 'status=CLEARED',
          };
        }
        return null;
      });

      final client = VGStreamingCacheClient(channel: channel);
      const options = VGPlaybackCacheOptions(cacheDirectoryName: 'test_dir');
      final result = await client.clear(options: options);

      expect(recordedCall, isNotNull);
      expect(recordedCall!.method, equals('clearPlaybackCache'));
      final callArgs = recordedCall!.arguments as Map;
      expect(callArgs['cacheDirectoryName'], equals('test_dir'));

      expect(result.phase, equals('Phase4C6F'));
      expect(result.pass, isTrue);
      expect(result.state, equals('cleared'));
      expect(result.cacheAvailable, isTrue);
      expect(result.beforeBytes, equals(10000000));
      expect(result.afterBytes, equals(0));
      expect(result.resourceCountBefore, equals(15));
      expect(result.removedResourceCount, equals(15));
      expect(result.failedResourceCount, equals(0));
      expect(result.raw, equals('status=CLEARED'));
    });
  });
}
