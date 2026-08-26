// vg_streaming_offline_asset_client_test.dart
// Vanguard Media Engine — Phase 4C7BI: public streaming offline asset MethodChannel client contract tests.

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
  // 1. startAcquisition: Serialization & Response Parsing
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingOfflineAssetClient.startAcquisition', () {
    test(
      'serializes request fields, headers, formatHint, priority, and minimumFreeBytes, then parses accepted result',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'startStreamingOfflineAssetAcquisition') {
            return <Object?, Object?>{
              'phase': 'Phase4C7BI',
              'pass': true,
              'requestId': 'req_offline_101',
              'sourceKey': 'hls_main',
              'state': 'accepted',
              'raw': 'status=ACCEPTED',
              'storageGuardPhase': 'Phase4C6F3',
              'storageGuardPass': true,
              'availableBytes': 500000000,
              'requestedBytes': 67108864,
              'minimumFreeBytes': 67108864,
              'projectedAvailableBytes': 432891136,
            };
          }
          return null;
        });

        final client = VGStreamingOfflineAssetClient(channel: channel);
        final request = VGStreamingOfflineAssetAcquisitionRequest(
          requestId: 'req_offline_101',
          sourceKey: 'hls_main',
          uri: Uri.parse('https://cdn.example.com/vod/master.m3u8'),
          httpHeaders: const {'Authorization': 'Bearer test_token'},
          formatHint: VGStreamingFormatHint.hls,
          requireLlHlsTags: false,
          estimatedBytes: 67108864,
          priority: VGStreamingOfflineAssetAcquisitionPriority.urgent,
          reason: 'primary_feature_download',
        );

        final result = await client.startAcquisition(
          request,
          minimumFreeBytes: 67108864,
        );

        // Verify channel call and arguments
        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('startStreamingOfflineAssetAcquisition'),
        );
        final args = recordedCall!.arguments as Map;
        expect(args['requestId'], equals('req_offline_101'));
        expect(args['sourceKey'], equals('hls_main'));
        expect(args['uri'], equals('https://cdn.example.com/vod/master.m3u8'));
        expect(
          args['httpHeaders'],
          equals({'Authorization': 'Bearer test_token'}),
        );
        expect(args['formatHint'], equals('HLS'));
        expect(args['requireLlHlsTags'], isFalse);
        expect(args['estimatedBytes'], equals(67108864));
        expect(args['priority'], equals('urgent'));
        expect(args['reason'], equals('primary_feature_download'));
        expect(args['minimumFreeBytes'], equals(67108864));

        // Verify typed parsed result
        expect(result.pass, isTrue);
        expect(result.phase, equals('Phase4C7BI'));
        expect(result.requestId, equals('req_offline_101'));
        expect(result.sourceKey, equals('hls_main'));
        expect(
          result.state,
          equals(VGStreamingOfflineAssetAcquisitionStartState.accepted),
        );
        expect(result.storageGuardPass, isTrue);
        expect(result.storageGuardPhase, equals('Phase4C6F3'));
        expect(result.availableBytes, equals(500000000));
        expect(result.requestedBytes, equals(67108864));
        expect(result.minimumFreeBytes, equals(67108864));
        expect(result.projectedAvailableBytes, equals(432891136));
        expect(result.raw, equals('status=ACCEPTED'));
      },
    );

    test('parses blocked_low_storage result correctly', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startStreamingOfflineAssetAcquisition') {
          return <Object?, Object?>{
            'phase': 'Phase4C7BI',
            'pass': false,
            'requestId': 'req_blocked_202',
            'sourceKey': 'hls_large',
            'state': 'blocked_low_storage',
            'raw': 'status=BLOCKED;reason=LOW_STORAGE',
            'storageGuardPhase': 'Phase4C6F3',
            'storageGuardPass': false,
            'availableBytes': 30000000,
            'requestedBytes': 67108864,
            'minimumFreeBytes': 67108864,
            'projectedAvailableBytes': -37108864,
          };
        }
        return null;
      });

      final client = VGStreamingOfflineAssetClient(channel: channel);
      final request = VGStreamingOfflineAssetAcquisitionRequest(
        requestId: 'req_blocked_202',
        sourceKey: 'hls_large',
        uri: Uri.parse('https://cdn.example.com/vod/large.m3u8'),
        estimatedBytes: 67108864,
      );

      final result = await client.startAcquisition(request);

      expect(result.pass, isFalse);
      expect(
        result.state,
        equals(VGStreamingOfflineAssetAcquisitionStartState.blockedLowStorage),
      );
      expect(result.storageGuardPass, isFalse);
      expect(result.availableBytes, equals(30000000));
      expect(result.projectedAvailableBytes, equals(-37108864));
    });

    test('parses duplicate and storage_guard_error results', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startStreamingOfflineAssetAcquisition') {
          return <Object?, Object?>{
            'phase': 'Phase4C7BI',
            'pass': false,
            'requestId': 'req_dup_303',
            'state': 'duplicate',
            'raw': 'status=DUPLICATE',
          };
        }
        return null;
      });

      final client = VGStreamingOfflineAssetClient(channel: channel);
      final request = VGStreamingOfflineAssetAcquisitionRequest(
        requestId: 'req_dup_303',
        sourceKey: 'hls_main',
        uri: Uri.parse('https://cdn.example.com/vod/master.m3u8'),
        estimatedBytes: 1024,
      );

      final result = await client.startAcquisition(request);
      expect(result.pass, isFalse);
      expect(
        result.state,
        equals(VGStreamingOfflineAssetAcquisitionStartState.duplicate),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. getStatus: Argument Validation & Response Parsing
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingOfflineAssetClient.getStatus', () {
    test(
      'forwards requestId and sourceKey, then parses succeeded status with availability',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'getStreamingOfflineAssetStatus') {
            return <Object?, Object?>{
              'requestId': 'req_stat_404',
              'sourceKey': 'hls_complete',
              'state': 'succeeded',
              'bytesDownloaded': 52428800,
              'totalBytes': 52428800,
              'assetUri':
                  'file:///var/mobile/Containers/Data/Application/offline.movpkg',
              'startedAtUnixMs': 1700000000000,
              'completedAtUnixMs': 1700000050000,
              'diagnostics': {'nativeBackend': 'AVAssetDownloadURLSession'},
            };
          }
          return null;
        });

        final client = VGStreamingOfflineAssetClient(channel: channel);
        final status = await client.getStatus(
          requestId: 'req_stat_404',
          sourceKey: 'hls_complete',
        );

        expect(recordedCall, isNotNull);
        expect(recordedCall!.method, equals('getStreamingOfflineAssetStatus'));
        final args = recordedCall!.arguments as Map;
        expect(args['requestId'], equals('req_stat_404'));
        expect(args['sourceKey'], equals('hls_complete'));

        expect(status.requestId, equals('req_stat_404'));
        expect(status.sourceKey, equals('hls_complete'));
        expect(
          status.state,
          equals(VGStreamingOfflineAssetDownloadState.succeeded),
        );
        expect(status.isSuccessful, isTrue);
        expect(status.isTerminal, isTrue);
        expect(status.isFailure, isFalse);
        expect(status.bytesDownloaded, equals(52428800));
        expect(status.totalBytes, equals(52428800));
        expect(status.progressFraction, equals(1.0));
        expect(
          status.assetUri,
          equals(
            Uri.parse(
              'file:///var/mobile/Containers/Data/Application/offline.movpkg',
            ),
          ),
        );
        expect(status.availability, isNotNull);
        expect(status.availability!.isPlayableOffline, isTrue);
        expect(
          status.availability!.state,
          equals(VGStreamingOfflineAssetState.available),
        );
        expect(status.availability!.sourceKey, equals('hls_complete'));
      },
    );

    test('validates non-empty requestId', () async {
      final client = VGStreamingOfflineAssetClient(channel: channel);

      expect(
        () => client.getStatus(requestId: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => client.getStatus(requestId: '   '),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. cancelAcquisition: Argument Validation & Response Parsing
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingOfflineAssetClient.cancelAcquisition', () {
    test('forwards requestId and parses cancel_requested result', () async {
      MethodCall? recordedCall;
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        recordedCall = call;
        if (call.method == 'cancelStreamingOfflineAssetAcquisition') {
          return <Object?, Object?>{
            'phase': 'Phase4C7BI',
            'pass': true,
            'requestId': 'req_cancel_505',
            'state': 'cancel_requested',
            'raw': 'status=CANCEL_REQUESTED',
          };
        }
        return null;
      });

      final client = VGStreamingOfflineAssetClient(channel: channel);
      final result = await client.cancelAcquisition('req_cancel_505');

      expect(recordedCall, isNotNull);
      expect(
        recordedCall!.method,
        equals('cancelStreamingOfflineAssetAcquisition'),
      );
      expect(recordedCall!.arguments, equals({'requestId': 'req_cancel_505'}));

      expect(result.pass, isTrue);
      expect(result.phase, equals('Phase4C7BI'));
      expect(result.requestId, equals('req_cancel_505'));
      expect(
        result.state,
        equals(VGStreamingOfflineAssetCommandState.cancelRequested),
      );
    });

    test('parses not_found_or_terminal result for unknown task', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancelStreamingOfflineAssetAcquisition') {
          return <Object?, Object?>{
            'phase': 'Phase4C7BI',
            'pass': true,
            'requestId': 'req_missing',
            'state': 'not_found_or_terminal',
            'raw': 'status=NOT_FOUND',
          };
        }
        return null;
      });

      final client = VGStreamingOfflineAssetClient(channel: channel);
      final result = await client.cancelAcquisition('req_missing');

      expect(result.pass, isTrue);
      expect(
        result.state,
        equals(VGStreamingOfflineAssetCommandState.notFoundOrTerminal),
      );
    });

    test('validates non-empty requestId', () async {
      final client = VGStreamingOfflineAssetClient(channel: channel);

      expect(() => client.cancelAcquisition(''), throwsA(isA<ArgumentError>()));
      expect(
        () => client.cancelAcquisition('   '),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. deleteAsset & clearAssets: Operations & Parsing
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingOfflineAssetClient.deleteAsset & clearAssets', () {
    test(
      'deleteAsset forwards identifiers and parses deleted result',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'deleteStreamingOfflineAsset') {
            return <Object?, Object?>{
              'phase': 'Phase4C7BI',
              'pass': true,
              'sourceKey': 'hls_delete_me',
              'state': 'deleted',
              'freedBytes': 104857600,
              'raw': 'status=DELETED',
            };
          }
          return null;
        });

        final client = VGStreamingOfflineAssetClient(channel: channel);
        final result = await client.deleteAsset(sourceKey: 'hls_delete_me');

        expect(recordedCall, isNotNull);
        expect(recordedCall!.method, equals('deleteStreamingOfflineAsset'));
        expect(recordedCall!.arguments, equals({'sourceKey': 'hls_delete_me'}));

        expect(result.pass, isTrue);
        expect(result.sourceKey, equals('hls_delete_me'));
        expect(
          result.state,
          equals(VGStreamingOfflineAssetCommandState.deleted),
        );
        expect(result.freedBytes, equals(104857600));
      },
    );

    test('deleteAsset parses not_found result', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'deleteStreamingOfflineAsset') {
          return <Object?, Object?>{
            'phase': 'Phase4C7BI',
            'pass': false,
            'sourceKey': 'hls_nonexistent',
            'state': 'not_found',
            'raw': 'status=NOT_FOUND',
          };
        }
        return null;
      });

      final client = VGStreamingOfflineAssetClient(channel: channel);
      final result = await client.deleteAsset(sourceKey: 'hls_nonexistent');

      expect(result.pass, isFalse);
      expect(
        result.state,
        equals(VGStreamingOfflineAssetCommandState.notFound),
      );
    });

    test(
      'deleteAsset validates that at least one identifier is provided',
      () async {
        final client = VGStreamingOfflineAssetClient(channel: channel);

        expect(() => client.deleteAsset(), throwsA(isA<ArgumentError>()));
        expect(
          () => client.deleteAsset(requestId: '', sourceKey: ''),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => client.deleteAsset(requestId: '   '),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('clearAssets parses cleared result with aggregate counts', () async {
      MethodCall? recordedCall;
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        recordedCall = call;
        if (call.method == 'clearStreamingOfflineAssets') {
          return <Object?, Object?>{
            'phase': 'Phase4C7BI',
            'pass': true,
            'state': 'cleared',
            'freedBytes': 314572800,
            'removedCount': 3,
            'raw': 'status=CLEARED',
          };
        }
        return null;
      });

      final client = VGStreamingOfflineAssetClient(channel: channel);
      final result = await client.clearAssets();

      expect(recordedCall, isNotNull);
      expect(recordedCall!.method, equals('clearStreamingOfflineAssets'));
      expect(recordedCall!.arguments, equals(<String, Object?>{}));

      expect(result.pass, isTrue);
      expect(result.state, equals(VGStreamingOfflineAssetCommandState.cleared));
      expect(result.freedBytes, equals(314572800));
      expect(result.removedCount, equals(3));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. queryAvailability: Defensive List Parsing & Validation
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingOfflineAssetClient.queryAvailability', () {
    test(
      'forwards sourceKeys and parses multiple assets defensively',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'queryStreamingOfflineAssetAvailability') {
            return <Object?, Object?>{
              'phase': 'Phase4C7BI',
              'pass': true,
              'raw': 'status=OK',
              'assets': [
                {
                  'sourceKey': 'hls_avail_1',
                  'state': 'available',
                  'assetUri': 'file:///offline/1.movpkg',
                  'downloadedBytes': 204800,
                  'expiresAtUnixMs': 1800000000000,
                },
                {
                  'sourceKey': 'hls_stale_2',
                  'state': 'stale',
                  'reason': 'manifest_outdated',
                },
                {'sourceKey': 'hls_unsupported_3', 'state': 'unsupported'},
              ],
            };
          }
          return null;
        });

        final client = VGStreamingOfflineAssetClient(channel: channel);
        final result = await client.queryAvailability(
          sourceKeys: ['hls_avail_1', 'hls_stale_2', 'hls_unsupported_3'],
        );

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('queryStreamingOfflineAssetAvailability'),
        );
        expect(
          recordedCall!.arguments,
          equals({
            'sourceKeys': ['hls_avail_1', 'hls_stale_2', 'hls_unsupported_3'],
          }),
        );

        expect(result.pass, isTrue);
        expect(result.phase, equals('Phase4C7BI'));
        expect(result.assets.length, equals(3));

        final a1 = result.assets[0];
        expect(a1.sourceKey, equals('hls_avail_1'));
        expect(a1.state, equals(VGStreamingOfflineAssetState.available));
        expect(a1.isPlayableOffline, isTrue);
        expect(a1.assetUri, equals(Uri.parse('file:///offline/1.movpkg')));
        expect(a1.downloadedBytes, equals(204800));
        expect(a1.expiresAtUnixMs, equals(1800000000000));

        final a2 = result.assets[1];
        expect(a2.sourceKey, equals('hls_stale_2'));
        expect(a2.state, equals(VGStreamingOfflineAssetState.stale));
        expect(a2.isPlayableOffline, isFalse);
        expect(a2.reason, equals('manifest_outdated'));

        final a3 = result.assets[2];
        expect(a3.sourceKey, equals('hls_unsupported_3'));
        expect(a3.state, equals(VGStreamingOfflineAssetState.unsupported));
      },
    );

    test('validates sourceKeys list when supplied', () async {
      final client = VGStreamingOfflineAssetClient(channel: channel);

      expect(
        () => client.queryAvailability(sourceKeys: []),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => client.queryAvailability(sourceKeys: ['valid', '   ']),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6. MissingPluginException / Unsupported Platform Handling
  // ─────────────────────────────────────────────────────────────────────────
  group('MissingPluginException / unsupported handling', () {
    const unhandledChannel = MethodChannel('unhandled_channel_offline_test');

    test(
      'startAcquisition returns typed unsupported result without throwing',
      () async {
        final client = VGStreamingOfflineAssetClient(channel: unhandledChannel);
        final request = VGStreamingOfflineAssetAcquisitionRequest(
          requestId: 'req_unsupported_start',
          sourceKey: 'hls_source',
          uri: Uri.parse('https://example.com/vod.m3u8'),
          estimatedBytes: 1000,
        );

        final result = await client.startAcquisition(request);

        expect(result.pass, isFalse);
        expect(result.phase, equals('unsupported'));
        expect(result.requestId, equals('req_unsupported_start'));
        expect(result.sourceKey, equals('hls_source'));
        expect(
          result.state,
          equals(VGStreamingOfflineAssetAcquisitionStartState.unsupported),
        );
        expect(result.raw, equals('status=UNSUPPORTED;platform=unsupported'));
      },
    );

    test(
      'getStatus returns typed unsupported status without throwing',
      () async {
        final client = VGStreamingOfflineAssetClient(channel: unhandledChannel);

        final status = await client.getStatus(
          requestId: 'req_unsupported_status',
          sourceKey: 'hls_source',
        );

        expect(status.requestId, equals('req_unsupported_status'));
        expect(status.sourceKey, equals('hls_source'));
        expect(
          status.state,
          equals(VGStreamingOfflineAssetDownloadState.unsupported),
        );
        expect(status.isTerminal, isTrue);
        expect(status.isFailure, isTrue);
        expect(status.isSuccessful, isFalse);
        expect(status.availability, isNull);
      },
    );

    test(
      'cancelAcquisition returns typed unsupported result without throwing',
      () async {
        final client = VGStreamingOfflineAssetClient(channel: unhandledChannel);

        final result = await client.cancelAcquisition('req_unsupported_cancel');

        expect(result.pass, isFalse);
        expect(result.phase, equals('unsupported'));
        expect(result.requestId, equals('req_unsupported_cancel'));
        expect(
          result.state,
          equals(VGStreamingOfflineAssetCommandState.unsupported),
        );
      },
    );

    test(
      'deleteAsset returns typed unsupported result without throwing',
      () async {
        final client = VGStreamingOfflineAssetClient(channel: unhandledChannel);

        final result = await client.deleteAsset(
          requestId: 'req_unsupported_del',
          sourceKey: 'hls_del',
        );

        expect(result.pass, isFalse);
        expect(result.phase, equals('unsupported'));
        expect(result.requestId, equals('req_unsupported_del'));
        expect(result.sourceKey, equals('hls_del'));
        expect(
          result.state,
          equals(VGStreamingOfflineAssetCommandState.unsupported),
        );
      },
    );

    test(
      'clearAssets returns typed unsupported result without throwing',
      () async {
        final client = VGStreamingOfflineAssetClient(channel: unhandledChannel);

        final result = await client.clearAssets();

        expect(result.pass, isFalse);
        expect(result.phase, equals('unsupported'));
        expect(
          result.state,
          equals(VGStreamingOfflineAssetCommandState.unsupported),
        );
      },
    );

    test(
      'queryAvailability returns typed unsupported result without throwing',
      () async {
        final client = VGStreamingOfflineAssetClient(channel: unhandledChannel);

        final result = await client.queryAvailability();

        expect(result.pass, isFalse);
        expect(result.phase, equals('unsupported'));
        expect(result.assets, isEmpty);
      },
    );
  });
}
