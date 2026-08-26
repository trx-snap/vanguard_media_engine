// Copyright (c) Connects — Vanguard Phase 4C7BH.
// Public streaming offline asset lifecycle status model unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingOfflineAssetDownloadState', () {
    test('classifies terminal, success, and failure flags correctly', () {
      // Queued: active, non-terminal, non-success, non-failure
      expect(VGStreamingOfflineAssetDownloadState.queued.isTerminal, isFalse);
      expect(VGStreamingOfflineAssetDownloadState.queued.isSuccessful, isFalse);
      expect(VGStreamingOfflineAssetDownloadState.queued.isFailure, isFalse);

      // Running: active, non-terminal, non-success, non-failure
      expect(VGStreamingOfflineAssetDownloadState.running.isTerminal, isFalse);
      expect(
        VGStreamingOfflineAssetDownloadState.running.isSuccessful,
        isFalse,
      );
      expect(VGStreamingOfflineAssetDownloadState.running.isFailure, isFalse);

      // Succeeded: terminal, success, non-failure
      expect(VGStreamingOfflineAssetDownloadState.succeeded.isTerminal, isTrue);
      expect(
        VGStreamingOfflineAssetDownloadState.succeeded.isSuccessful,
        isTrue,
      );
      expect(VGStreamingOfflineAssetDownloadState.succeeded.isFailure, isFalse);

      // Failed: terminal, non-success, failure
      expect(VGStreamingOfflineAssetDownloadState.failed.isTerminal, isTrue);
      expect(VGStreamingOfflineAssetDownloadState.failed.isSuccessful, isFalse);
      expect(VGStreamingOfflineAssetDownloadState.failed.isFailure, isTrue);

      // Cancelled: terminal, non-success, failure
      expect(VGStreamingOfflineAssetDownloadState.cancelled.isTerminal, isTrue);
      expect(
        VGStreamingOfflineAssetDownloadState.cancelled.isSuccessful,
        isFalse,
      );
      expect(VGStreamingOfflineAssetDownloadState.cancelled.isFailure, isTrue);

      // Expired: terminal, non-success, failure
      expect(VGStreamingOfflineAssetDownloadState.expired.isTerminal, isTrue);
      expect(
        VGStreamingOfflineAssetDownloadState.expired.isSuccessful,
        isFalse,
      );
      expect(VGStreamingOfflineAssetDownloadState.expired.isFailure, isTrue);

      // Unsupported: terminal, non-success, failure
      expect(
        VGStreamingOfflineAssetDownloadState.unsupported.isTerminal,
        isTrue,
      );
      expect(
        VGStreamingOfflineAssetDownloadState.unsupported.isSuccessful,
        isFalse,
      );
      expect(
        VGStreamingOfflineAssetDownloadState.unsupported.isFailure,
        isTrue,
      );

      // NotFound: terminal, non-success, failure
      expect(VGStreamingOfflineAssetDownloadState.notFound.isTerminal, isTrue);
      expect(
        VGStreamingOfflineAssetDownloadState.notFound.isSuccessful,
        isFalse,
      );
      expect(VGStreamingOfflineAssetDownloadState.notFound.isFailure, isTrue);

      // Unknown: non-terminal, non-success, non-failure
      expect(VGStreamingOfflineAssetDownloadState.unknown.isTerminal, isFalse);
      expect(
        VGStreamingOfflineAssetDownloadState.unknown.isSuccessful,
        isFalse,
      );
      expect(VGStreamingOfflineAssetDownloadState.unknown.isFailure, isFalse);
    });

    test('parses common state names and aliases defensively', () {
      expect(
        VGStreamingOfflineAssetDownloadState.parse('queued'),
        equals(VGStreamingOfflineAssetDownloadState.queued),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('PENDING'),
        equals(VGStreamingOfflineAssetDownloadState.queued),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('enqueued'),
        equals(VGStreamingOfflineAssetDownloadState.queued),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('waiting'),
        equals(VGStreamingOfflineAssetDownloadState.queued),
      );

      expect(
        VGStreamingOfflineAssetDownloadState.parse('running'),
        equals(VGStreamingOfflineAssetDownloadState.running),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('in_progress'),
        equals(VGStreamingOfflineAssetDownloadState.running),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('IN-PROGRESS'),
        equals(VGStreamingOfflineAssetDownloadState.running),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('downloading'),
        equals(VGStreamingOfflineAssetDownloadState.running),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('active'),
        equals(VGStreamingOfflineAssetDownloadState.running),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('started'),
        equals(VGStreamingOfflineAssetDownloadState.running),
      );

      expect(
        VGStreamingOfflineAssetDownloadState.parse('succeeded'),
        equals(VGStreamingOfflineAssetDownloadState.succeeded),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('complete'),
        equals(VGStreamingOfflineAssetDownloadState.succeeded),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('COMPLETED'),
        equals(VGStreamingOfflineAssetDownloadState.succeeded),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('finished'),
        equals(VGStreamingOfflineAssetDownloadState.succeeded),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('done'),
        equals(VGStreamingOfflineAssetDownloadState.succeeded),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('available'),
        equals(VGStreamingOfflineAssetDownloadState.succeeded),
      );

      expect(
        VGStreamingOfflineAssetDownloadState.parse('failed'),
        equals(VGStreamingOfflineAssetDownloadState.failed),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('error'),
        equals(VGStreamingOfflineAssetDownloadState.failed),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('failure'),
        equals(VGStreamingOfflineAssetDownloadState.failed),
      );

      expect(
        VGStreamingOfflineAssetDownloadState.parse('cancelled'),
        equals(VGStreamingOfflineAssetDownloadState.cancelled),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('canceled'),
        equals(VGStreamingOfflineAssetDownloadState.cancelled),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('aborted'),
        equals(VGStreamingOfflineAssetDownloadState.cancelled),
      );

      expect(
        VGStreamingOfflineAssetDownloadState.parse('expired'),
        equals(VGStreamingOfflineAssetDownloadState.expired),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('unsupported'),
        equals(VGStreamingOfflineAssetDownloadState.unsupported),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('not_found'),
        equals(VGStreamingOfflineAssetDownloadState.notFound),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('NOT-FOUND'),
        equals(VGStreamingOfflineAssetDownloadState.notFound),
      );

      expect(
        VGStreamingOfflineAssetDownloadState.parse(null),
        equals(VGStreamingOfflineAssetDownloadState.unknown),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse('something_random'),
        equals(VGStreamingOfflineAssetDownloadState.unknown),
      );
      expect(
        VGStreamingOfflineAssetDownloadState.parse(
          VGStreamingOfflineAssetDownloadState.running,
        ),
        equals(VGStreamingOfflineAssetDownloadState.running),
      );
    });
  });

  group('VGStreamingOfflineAssetDownloadStatus', () {
    test('computes progressFraction correctly (null, normal, clamped)', () {
      // Null total bytes -> progressFraction is null
      final statusNoTotal = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_1',
        sourceKey: 'hls_main',
        state: VGStreamingOfflineAssetDownloadState.running,
        bytesDownloaded: 1024,
      );
      expect(statusNoTotal.progressFraction, isNull);

      // Zero total bytes -> progressFraction is null
      final statusZeroTotal = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_2',
        sourceKey: 'hls_main',
        state: VGStreamingOfflineAssetDownloadState.running,
        bytesDownloaded: 1024,
        totalBytes: 0,
      );
      expect(statusZeroTotal.progressFraction, isNull);

      // Normal progress fraction
      final statusNormal = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_3',
        sourceKey: 'hls_main',
        state: VGStreamingOfflineAssetDownloadState.running,
        bytesDownloaded: 250,
        totalBytes: 1000,
      );
      expect(statusNormal.progressFraction, closeTo(0.25, 0.0001));

      // Clamped when bytesDownloaded exceeds totalBytes
      final statusOver = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_4',
        sourceKey: 'hls_main',
        state: VGStreamingOfflineAssetDownloadState.running,
        bytesDownloaded: 1500,
        totalBytes: 1000,
      );
      expect(statusOver.progressFraction, equals(1.0));
    });

    test('derives availability only on succeeded with assetUri', () {
      final succeededWithUri = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_success',
        sourceKey: 'hls_main',
        state: VGStreamingOfflineAssetDownloadState.succeeded,
        bytesDownloaded: 4096000,
        totalBytes: 4096000,
        assetUri: Uri.parse('file:///var/mobile/Containers/Data/stream.movpkg'),
      );

      final availability = succeededWithUri.availability;
      expect(availability, isNotNull);
      expect(availability!.sourceKey, equals('hls_main'));
      expect(
        availability.state,
        equals(VGStreamingOfflineAssetState.available),
      );
      expect(
        availability.assetUri,
        equals(Uri.parse('file:///var/mobile/Containers/Data/stream.movpkg')),
      );
      expect(availability.downloadedBytes, equals(4096000));
      expect(availability.isPlayableOffline, isTrue);

      // Succeeded but no assetUri -> null availability
      final succeededNoUri = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_success_no_uri',
        sourceKey: 'hls_main',
        state: VGStreamingOfflineAssetDownloadState.succeeded,
        bytesDownloaded: 4096000,
        totalBytes: 4096000,
      );
      expect(succeededNoUri.availability, isNull);

      // Failed state with assetUri -> null availability
      final failedWithUri = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_fail',
        sourceKey: 'hls_main',
        state: VGStreamingOfflineAssetDownloadState.failed,
        bytesDownloaded: 1024,
        assetUri: Uri.parse('file:///var/mobile/Containers/Data/stream.movpkg'),
      );
      expect(failedWithUri.availability, isNull);
    });

    test('toJson serializes primitives cleanly', () {
      final status = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_100',
        sourceKey: 'hls_vod',
        state: VGStreamingOfflineAssetDownloadState.succeeded,
        bytesDownloaded: 2048,
        totalBytes: 4096,
        assetUri: Uri.parse('file:///data/asset.movpkg'),
        errorCode: 'ERR_0',
        errorMessage: 'None',
        startedAtUnixMs: 1000,
        updatedAtUnixMs: 1500,
        completedAtUnixMs: 2000,
        diagnostics: const {'codec': 'avc1', 'verified': true},
      );

      final json = status.toJson();
      expect(json['requestId'], equals('req_100'));
      expect(json['sourceKey'], equals('hls_vod'));
      expect(json['state'], equals('succeeded'));
      expect(json['bytesDownloaded'], equals(2048));
      expect(json['totalBytes'], equals(4096));
      expect(json['assetUri'], equals('file:///data/asset.movpkg'));
      expect(json['errorCode'], equals('ERR_0'));
      expect(json['errorMessage'], equals('None'));
      expect(json['startedAtUnixMs'], equals(1000));
      expect(json['updatedAtUnixMs'], equals(1500));
      expect(json['completedAtUnixMs'], equals(2000));
      expect(json['isTerminal'], isTrue);
      expect(json['isSuccessful'], isTrue);
      expect(json['isFailure'], isFalse);
      expect(json['progressFraction'], closeTo(0.5, 0.0001));
      expect(json['diagnostics'], equals({'codec': 'avc1', 'verified': true}));
    });

    test(
      'fromMap parses map representations defensively with aliases and defaults',
      () {
        final map = <Object?, Object?>{
          'requestId': 'req_map_1',
          'sourceKey': 'source_map_1',
          'state': 'in_progress',
          'bytesDownloaded': 512,
          'totalBytes': 1024,
          'assetUri': 'file:///local/path/media.movpkg',
          'errorCode': 'TIMEOUT',
          'errorMessage': 'Connection timed out',
          'startedAtUnixMs': 500,
          'updatedAtUnixMs': 750,
          'completedAtUnixMs': null,
          'diagnostics': {'network': 'wifi', 'signal': -45},
        };

        final status = VGStreamingOfflineAssetDownloadStatus.fromMap(map);
        expect(status.requestId, equals('req_map_1'));
        expect(status.sourceKey, equals('source_map_1'));
        expect(
          status.state,
          equals(VGStreamingOfflineAssetDownloadState.running),
        );
        expect(status.bytesDownloaded, equals(512));
        expect(status.totalBytes, equals(1024));
        expect(
          status.assetUri,
          equals(Uri.parse('file:///local/path/media.movpkg')),
        );
        expect(status.errorCode, equals('TIMEOUT'));
        expect(status.errorMessage, equals('Connection timed out'));
        expect(status.startedAtUnixMs, equals(500));
        expect(status.updatedAtUnixMs, equals(750));
        expect(status.completedAtUnixMs, isNull);
        expect(status.diagnostics['network'], equals('wifi'));
        expect(status.diagnostics['signal'], equals(-45));

        // Defensive fallback on empty/corrupt map
        final emptyStatus = VGStreamingOfflineAssetDownloadStatus.fromMap(
          const {},
        );
        expect(emptyStatus.requestId, equals('unknown_request'));
        expect(emptyStatus.sourceKey, equals('unknown_source'));
        expect(
          emptyStatus.state,
          equals(VGStreamingOfflineAssetDownloadState.unknown),
        );
        expect(emptyStatus.bytesDownloaded, equals(0));
        expect(emptyStatus.totalBytes, isNull);
        expect(emptyStatus.assetUri, isNull);
        expect(emptyStatus.diagnostics, isEmpty);
      },
    );

    test('copyWith preserves existing values and allows field overrides', () {
      final original = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_orig',
        sourceKey: 'source_orig',
        state: VGStreamingOfflineAssetDownloadState.queued,
        bytesDownloaded: 100,
        totalBytes: 500,
        startedAtUnixMs: 100,
        diagnostics: const {'tag': 'a'},
      );

      final updated = original.copyWith(
        state: VGStreamingOfflineAssetDownloadState.running,
        bytesDownloaded: 300,
        updatedAtUnixMs: 200,
      );

      expect(updated.requestId, equals('req_orig'));
      expect(updated.sourceKey, equals('source_orig'));
      expect(
        updated.state,
        equals(VGStreamingOfflineAssetDownloadState.running),
      );
      expect(updated.bytesDownloaded, equals(300));
      expect(updated.totalBytes, equals(500));
      expect(updated.startedAtUnixMs, equals(100));
      expect(updated.updatedAtUnixMs, equals(200));
      expect(updated.diagnostics, equals(const {'tag': 'a'}));

      // Verify null override capability
      final cleared = updated.copyWith(totalBytes: null);
      expect(cleared.totalBytes, isNull);
    });

    test('enforces assertions on invalid inputs and freezes diagnostics', () {
      expect(
        () => VGStreamingOfflineAssetDownloadStatus(
          requestId: '',
          sourceKey: 'source_1',
        ),
        throwsAssertionError,
      );

      expect(
        () => VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_1',
          sourceKey: '',
        ),
        throwsAssertionError,
      );

      expect(
        () => VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_1',
          sourceKey: 'source_1',
          bytesDownloaded: -1,
        ),
        throwsAssertionError,
      );

      expect(
        () => VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_1',
          sourceKey: 'source_1',
          totalBytes: -5,
        ),
        throwsAssertionError,
      );

      expect(
        () => VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_1',
          sourceKey: 'source_1',
          startedAtUnixMs: -10,
        ),
        throwsAssertionError,
      );

      final mutableDiagnostics = <String, Object?>{'key': 'val'};
      final status = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_1',
        sourceKey: 'source_1',
        diagnostics: mutableDiagnostics,
      );
      expect(
        () => status.diagnostics['key'] = 'new_val',
        throwsUnsupportedError,
      );
    });

    test('toString formats descriptive output', () {
      final status = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_str',
        sourceKey: 'source_str',
        state: VGStreamingOfflineAssetDownloadState.running,
        bytesDownloaded: 128,
        totalBytes: 256,
      );
      expect(status.toString(), contains('requestId=req_str'));
      expect(status.toString(), contains('state=running'));
      expect(status.toString(), contains('progressFraction=0.5'));
    });
  });

  group('VGStreamingOfflineAssetLifecycleSummary & Summarizer', () {
    test('summarizes mixed statuses accurately', () {
      final statuses = [
        VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_q',
          sourceKey: 'src_1',
          state: VGStreamingOfflineAssetDownloadState.queued,
          bytesDownloaded: 0,
          totalBytes: 1000,
        ),
        VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_r',
          sourceKey: 'src_2',
          state: VGStreamingOfflineAssetDownloadState.running,
          bytesDownloaded: 500,
          totalBytes: 1000,
        ),
        VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_s',
          sourceKey: 'src_3',
          state: VGStreamingOfflineAssetDownloadState.succeeded,
          bytesDownloaded: 1000,
          totalBytes: 1000,
          assetUri: Uri.parse('file:///data/asset_3.movpkg'),
        ),
        VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_f',
          sourceKey: 'src_4',
          state: VGStreamingOfflineAssetDownloadState.failed,
          bytesDownloaded: 200,
          errorCode: 'NET_ERR',
        ),
        VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_c',
          sourceKey: 'src_5',
          state: VGStreamingOfflineAssetDownloadState.cancelled,
          bytesDownloaded: 100,
        ),
        VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_e',
          sourceKey: 'src_6',
          state: VGStreamingOfflineAssetDownloadState.expired,
          bytesDownloaded: 0,
        ),
        VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_u',
          sourceKey: 'src_7',
          state: VGStreamingOfflineAssetDownloadState.unsupported,
          bytesDownloaded: 0,
        ),
        VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_nf',
          sourceKey: 'src_8',
          state: VGStreamingOfflineAssetDownloadState.notFound,
          bytesDownloaded: 0,
        ),
        VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_unk',
          sourceKey: 'src_9',
          state: VGStreamingOfflineAssetDownloadState.unknown,
          bytesDownloaded: 0,
        ),
      ];

      final summary = VGStreamingOfflineAssetLifecycleSummarizer.summarize(
        statuses,
      );

      expect(summary.totalCount, equals(9));
      expect(summary.queuedCount, equals(1));
      expect(summary.runningCount, equals(1));
      expect(summary.succeededCount, equals(1));
      expect(summary.failedCount, equals(1));
      expect(summary.cancelledCount, equals(1));
      expect(summary.expiredCount, equals(1));
      expect(summary.unsupportedCount, equals(1));
      expect(summary.notFoundCount, equals(1));
      expect(summary.unknownCount, equals(1));
      expect(
        summary.terminalCount,
        equals(6),
      ); // succeeded + failed + cancelled + expired + unsupported + notFound
      expect(
        summary.totalBytesDownloaded,
        equals(1800),
      ); // 0 + 500 + 1000 + 200 + 100 + 0 + 0 + 0 + 0
      expect(summary.activeRequestIds, equals(['req_q', 'req_r']));
      expect(
        summary.terminalRequestIds,
        equals(['req_s', 'req_f', 'req_c', 'req_e', 'req_u', 'req_nf']),
      );
      expect(summary.hasActiveDownloads, isTrue);
      expect(summary.allTerminal, isFalse);
      expect(summary.diagnostics['advisoryOnly'], isTrue);
      expect(summary.diagnostics['playbackMutation'], isFalse);

      final json = summary.toJson();
      expect(json['totalCount'], equals(9));
      expect(json['hasActiveDownloads'], isTrue);
      expect(json['allTerminal'], isFalse);
      expect(json['totalBytesDownloaded'], equals(1800));
      expect(summary.toString(), contains('totalCount=9'));
    });

    test('empty summary has expected defaults', () {
      final summary = VGStreamingOfflineAssetLifecycleSummarizer.summarize(
        const [],
      );

      expect(summary.totalCount, equals(0));
      expect(summary.queuedCount, equals(0));
      expect(summary.runningCount, equals(0));
      expect(summary.succeededCount, equals(0));
      expect(summary.failedCount, equals(0));
      expect(summary.cancelledCount, equals(0));
      expect(summary.expiredCount, equals(0));
      expect(summary.unsupportedCount, equals(0));
      expect(summary.notFoundCount, equals(0));
      expect(summary.unknownCount, equals(0));
      expect(summary.terminalCount, equals(0));
      expect(summary.totalBytesDownloaded, equals(0));
      expect(summary.activeRequestIds, isEmpty);
      expect(summary.terminalRequestIds, isEmpty);
      expect(summary.hasActiveDownloads, isFalse);
      expect(summary.allTerminal, isTrue);
    });

    test(
      'summary where all are terminal reports allTerminal true and hasActiveDownloads false',
      () {
        final terminalStatuses = [
          VGStreamingOfflineAssetDownloadStatus(
            requestId: 'req_s1',
            sourceKey: 'src_1',
            state: VGStreamingOfflineAssetDownloadState.succeeded,
            bytesDownloaded: 1000,
            assetUri: Uri.parse('file:///data/asset.movpkg'),
          ),
          VGStreamingOfflineAssetDownloadStatus(
            requestId: 'req_f1',
            sourceKey: 'src_2',
            state: VGStreamingOfflineAssetDownloadState.failed,
            bytesDownloaded: 100,
          ),
        ];

        final summary = VGStreamingOfflineAssetLifecycleSummarizer.summarize(
          terminalStatuses,
        );

        expect(summary.totalCount, equals(2));
        expect(summary.terminalCount, equals(2));
        expect(summary.hasActiveDownloads, isFalse);
        expect(summary.allTerminal, isTrue);
        expect(summary.activeRequestIds, isEmpty);
        expect(summary.terminalRequestIds, equals(['req_s1', 'req_f1']));
        expect(summary.totalBytesDownloaded, equals(1100));
      },
    );
  });
}
