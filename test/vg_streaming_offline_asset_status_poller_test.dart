// Copyright (c) Connects — Vanguard Phase 4C7BJ.
// Public streaming offline asset status poller unit tests.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

class FakeStreamingOfflineAssetClient extends VGStreamingOfflineAssetClient {
  int getStatusCalls = 0;
  List<({String requestId, String? sourceKey})> recordedGetStatusCalls = [];

  FutureOr<VGStreamingOfflineAssetDownloadStatus> Function(
    String requestId,
    String? sourceKey,
  )?
  onGetStatus;

  @override
  Future<VGStreamingOfflineAssetDownloadStatus> getStatus({
    required String requestId,
    String? sourceKey,
  }) async {
    getStatusCalls++;
    recordedGetStatusCalls.add((requestId: requestId, sourceKey: sourceKey));
    if (onGetStatus != null) {
      return await onGetStatus!(requestId, sourceKey);
    }
    return VGStreamingOfflineAssetDownloadStatus(
      requestId: requestId,
      sourceKey: sourceKey ?? 'fake_source',
      state: VGStreamingOfflineAssetDownloadState.running,
      bytesDownloaded: 1024,
      totalBytes: 2048,
      diagnostics: const {'fake': true},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VGStreamingOfflineAssetStatusPollerConfig', () {
    test('1. default configuration has expected values', () {
      final config = VGStreamingOfflineAssetStatusPollerConfig();
      expect(config.interval, equals(const Duration(milliseconds: 500)));
      expect(config.emitInitialStatus, isTrue);
      expect(config.stopWhenTerminal, isTrue);
      expect(config.toString(), contains('500ms'));
      expect(config.toString(), contains('emitInitialStatus=true'));
      expect(config.toString(), contains('stopWhenTerminal=true'));
    });

    test('2. custom configuration preserves values', () {
      final config = VGStreamingOfflineAssetStatusPollerConfig(
        interval: const Duration(seconds: 2),
        emitInitialStatus: false,
        stopWhenTerminal: false,
      );
      expect(config.interval, equals(const Duration(seconds: 2)));
      expect(config.emitInitialStatus, isFalse);
      expect(config.stopWhenTerminal, isFalse);
      expect(config.toString(), contains('2000ms'));
      expect(config.toString(), contains('emitInitialStatus=false'));
      expect(config.toString(), contains('stopWhenTerminal=false'));
    });

    test('3. config rejects zero/negative interval with ArgumentError', () {
      expect(
        () =>
            VGStreamingOfflineAssetStatusPollerConfig(interval: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => VGStreamingOfflineAssetStatusPollerConfig(
          interval: const Duration(milliseconds: -100),
        ),
        throwsArgumentError,
      );
    });
  });

  group('VGStreamingOfflineAssetStatusPoller constructor & initial state', () {
    late FakeStreamingOfflineAssetClient fakeClient;

    setUp(() {
      fakeClient = FakeStreamingOfflineAssetClient();
    });

    test('1. constructor validates blank requestId', () {
      expect(
        () => VGStreamingOfflineAssetStatusPoller(
          client: fakeClient,
          requestId: '',
        ),
        throwsArgumentError,
      );
      expect(
        () => VGStreamingOfflineAssetStatusPoller(
          client: fakeClient,
          requestId: '   ',
        ),
        throwsArgumentError,
      );
    });

    test('2. constructor validates blank sourceKey if supplied', () {
      expect(
        () => VGStreamingOfflineAssetStatusPoller(
          client: fakeClient,
          requestId: 'req_valid',
          sourceKey: '   ',
        ),
        throwsArgumentError,
      );

      // null sourceKey is valid
      final poller = VGStreamingOfflineAssetStatusPoller(
        client: fakeClient,
        requestId: 'req_valid',
        sourceKey: null,
      );
      expect(poller.sourceKey, isNull);
    });

    test(
      '3. initial state has supplied requestId, unknown fallback, unknown state',
      () {
        final poller = VGStreamingOfflineAssetStatusPoller(
          client: fakeClient,
          requestId: 'req_init_101',
        );

        expect(poller.client, same(fakeClient));
        expect(poller.requestId, equals('req_init_101'));
        expect(poller.sourceKey, isNull);
        expect(poller.isRunning, isFalse);
        expect(poller.isDisposed, isFalse);

        final latest = poller.latest;
        expect(latest.requestId, equals('req_init_101'));
        expect(latest.sourceKey, equals('unknown_source'));
        expect(
          latest.state,
          equals(VGStreamingOfflineAssetDownloadState.unknown),
        );
        expect(latest.bytesDownloaded, equals(0));
        expect(latest.isTerminal, isFalse);
        expect(latest.isSuccessful, isFalse);
        expect(latest.isFailure, isFalse);
        expect(latest.diagnostics['phase'], equals('Phase4C7BJ'));
        expect(latest.diagnostics['advisoryOnly'], isTrue);
        expect(latest.diagnostics['playbackMutation'], isFalse);

        expect(poller.toString(), contains('requestId=req_init_101'));
        expect(poller.toString(), contains('isRunning=false'));
      },
    );

    test('4. constructor preserves supplied non-blank sourceKey', () {
      final poller = VGStreamingOfflineAssetStatusPoller(
        client: fakeClient,
        requestId: 'req_init_102',
        sourceKey: 'hls_source_key',
      );

      expect(poller.sourceKey, equals('hls_source_key'));
      expect(poller.latest.sourceKey, equals('hls_source_key'));
    });
  });

  group('VGStreamingOfflineAssetStatusPoller.refreshOnce', () {
    late FakeStreamingOfflineAssetClient fakeClient;

    setUp(() {
      fakeClient = FakeStreamingOfflineAssetClient();
    });

    test(
      '1. refreshOnce calls client once, updates latest, and emits status',
      () async {
        fakeClient.onGetStatus = (reqId, srcKey) {
          return VGStreamingOfflineAssetDownloadStatus(
            requestId: reqId,
            sourceKey: srcKey ?? 'src_test',
            state: VGStreamingOfflineAssetDownloadState.running,
            bytesDownloaded: 5000,
            totalBytes: 10000,
            diagnostics: const {'test': 'running'},
          );
        };

        final poller = VGStreamingOfflineAssetStatusPoller(
          client: fakeClient,
          requestId: 'req_refresh_1',
          sourceKey: 'src_test',
        );

        final emitted = <VGStreamingOfflineAssetDownloadStatus>[];
        final sub = poller.statuses.listen(emitted.add);

        final result = await poller.refreshOnce();

        expect(fakeClient.getStatusCalls, equals(1));
        expect(
          fakeClient.recordedGetStatusCalls.first.requestId,
          equals('req_refresh_1'),
        );
        expect(
          fakeClient.recordedGetStatusCalls.first.sourceKey,
          equals('src_test'),
        );

        expect(
          result.state,
          equals(VGStreamingOfflineAssetDownloadState.running),
        );
        expect(result.bytesDownloaded, equals(5000));
        expect(result.totalBytes, equals(10000));
        expect(poller.latest.bytesDownloaded, equals(5000));

        await Future<void>.delayed(Duration.zero);
        expect(emitted.length, equals(1));
        expect(emitted.first.bytesDownloaded, equals(5000));

        await sub.cancel();
        await poller.dispose();
      },
    );

    test(
      '2. overlapping refreshOnce calls do not invoke client concurrently',
      () async {
        final completer = Completer<VGStreamingOfflineAssetDownloadStatus>();
        fakeClient.onGetStatus = (reqId, srcKey) => completer.future;

        final poller = VGStreamingOfflineAssetStatusPoller(
          client: fakeClient,
          requestId: 'req_overlap_1',
          sourceKey: 'src_overlap',
        );

        final future1 = poller.refreshOnce();
        expect(fakeClient.getStatusCalls, equals(1));

        final future2 = poller.refreshOnce();
        expect(fakeClient.getStatusCalls, equals(1));

        completer.complete(
          VGStreamingOfflineAssetDownloadStatus(
            requestId: 'req_overlap_1',
            sourceKey: 'src_overlap',
            state: VGStreamingOfflineAssetDownloadState.running,
            bytesDownloaded: 8000,
            totalBytes: 10000,
          ),
        );

        final res1 = await future1;
        final res2 = await future2;

        expect(res1.bytesDownloaded, equals(8000));
        expect(res2, isNotNull);
        expect(fakeClient.getStatusCalls, equals(1));

        await poller.dispose();
      },
    );

    test(
      '3. client exception is caught, latest returned and emitted without throwing',
      () async {
        fakeClient.onGetStatus = (reqId, srcKey) {
          throw Exception('network_timeout');
        };

        final poller = VGStreamingOfflineAssetStatusPoller(
          client: fakeClient,
          requestId: 'req_err_1',
          sourceKey: 'src_err',
        );

        final emitted = <VGStreamingOfflineAssetDownloadStatus>[];
        final sub = poller.statuses.listen(emitted.add);

        final result = await poller.refreshOnce();

        expect(fakeClient.getStatusCalls, equals(1));
        expect(
          result.state,
          equals(VGStreamingOfflineAssetDownloadState.unknown),
        );
        expect(
          poller.latest.state,
          equals(VGStreamingOfflineAssetDownloadState.unknown),
        );

        await Future<void>.delayed(Duration.zero);
        expect(emitted.length, equals(1));
        expect(
          emitted.first.state,
          equals(VGStreamingOfflineAssetDownloadState.unknown),
        );

        await sub.cancel();
        await poller.dispose();
      },
    );

    test('4. disposed refreshOnce does not throw and returns latest', () async {
      final poller = VGStreamingOfflineAssetStatusPoller(
        client: fakeClient,
        requestId: 'req_disp_refresh',
      );
      await poller.dispose();
      expect(poller.isDisposed, isTrue);

      final result = await poller.refreshOnce();
      expect(fakeClient.getStatusCalls, equals(0));
      expect(result.requestId, equals('req_disp_refresh'));
    });
  });

  group(
    'VGStreamingOfflineAssetStatusPoller start, stop, terminal behavior',
    () {
      late FakeStreamingOfflineAssetClient fakeClient;

      setUp(() {
        fakeClient = FakeStreamingOfflineAssetClient();
      });

      test(
        '1. start() is idempotent and emits initial status when configured',
        () async {
          final poller = VGStreamingOfflineAssetStatusPoller(
            client: fakeClient,
            requestId: 'req_start_1',
            config: VGStreamingOfflineAssetStatusPollerConfig(
              interval: const Duration(milliseconds: 100),
              emitInitialStatus: true,
            ),
          );

          final emitted = <VGStreamingOfflineAssetDownloadStatus>[];
          final sub = poller.statuses.listen(emitted.add);

          poller.start();
          expect(poller.isRunning, isTrue);

          // Calling start again is a no-op
          poller.start();
          expect(poller.isRunning, isTrue);

          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(emitted.isNotEmpty, isTrue);
          expect(fakeClient.getStatusCalls, greaterThanOrEqualTo(1));

          poller.stop();
          expect(poller.isRunning, isFalse);

          await sub.cancel();
          await poller.dispose();
        },
      );

      test(
        '2. start() with emitInitialStatus=false waits until timer tick',
        () async {
          final poller = VGStreamingOfflineAssetStatusPoller(
            client: fakeClient,
            requestId: 'req_start_no_init',
            config: VGStreamingOfflineAssetStatusPollerConfig(
              interval: const Duration(milliseconds: 200),
              emitInitialStatus: false,
            ),
          );

          final emitted = <VGStreamingOfflineAssetDownloadStatus>[];
          final sub = poller.statuses.listen(emitted.add);

          poller.start();
          expect(poller.isRunning, isTrue);

          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(emitted.isEmpty, isTrue);
          expect(fakeClient.getStatusCalls, equals(0));

          poller.stop();
          expect(poller.isRunning, isFalse);

          await sub.cancel();
          await poller.dispose();
        },
      );

      test(
        '3. stopWhenTerminal=true stops polling after terminal status',
        () async {
          var callCount = 0;
          fakeClient.onGetStatus = (reqId, srcKey) {
            callCount++;
            if (callCount >= 2) {
              return VGStreamingOfflineAssetDownloadStatus(
                requestId: reqId,
                sourceKey: srcKey ?? 'src_term',
                state: VGStreamingOfflineAssetDownloadState.succeeded,
                bytesDownloaded: 10000,
                totalBytes: 10000,
                assetUri: Uri.parse('file:///offline/test.movpkg'),
              );
            }
            return VGStreamingOfflineAssetDownloadStatus(
              requestId: reqId,
              sourceKey: srcKey ?? 'src_term',
              state: VGStreamingOfflineAssetDownloadState.running,
              bytesDownloaded: 5000,
              totalBytes: 10000,
            );
          };

          final poller = VGStreamingOfflineAssetStatusPoller(
            client: fakeClient,
            requestId: 'req_term_auto_stop',
            config: VGStreamingOfflineAssetStatusPollerConfig(
              interval: const Duration(milliseconds: 40),
              emitInitialStatus: true,
              stopWhenTerminal: true,
            ),
          );

          poller.start();
          expect(poller.isRunning, isTrue);

          await Future<void>.delayed(const Duration(milliseconds: 120));

          expect(poller.latest.isTerminal, isTrue);
          expect(poller.latest.isSuccessful, isTrue);
          expect(poller.isRunning, isFalse);

          final callsAfterStop = fakeClient.getStatusCalls;
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(fakeClient.getStatusCalls, equals(callsAfterStop));

          await poller.dispose();
        },
      );

      test(
        '4. stopWhenTerminal=false continues running after terminal status',
        () async {
          fakeClient.onGetStatus = (reqId, srcKey) {
            return VGStreamingOfflineAssetDownloadStatus(
              requestId: reqId,
              sourceKey: srcKey ?? 'src_term_cont',
              state: VGStreamingOfflineAssetDownloadState.succeeded,
              bytesDownloaded: 10000,
              totalBytes: 10000,
              assetUri: Uri.parse('file:///offline/test.movpkg'),
            );
          };

          final poller = VGStreamingOfflineAssetStatusPoller(
            client: fakeClient,
            requestId: 'req_term_no_stop',
            config: VGStreamingOfflineAssetStatusPollerConfig(
              interval: const Duration(milliseconds: 40),
              emitInitialStatus: true,
              stopWhenTerminal: false,
            ),
          );

          poller.start();
          expect(poller.isRunning, isTrue);

          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(poller.latest.isTerminal, isTrue);
          expect(poller.isRunning, isTrue);

          poller.stop();
          expect(poller.isRunning, isFalse);

          await poller.dispose();
        },
      );

      test(
        '5. stop() cancels periodic polling without closing stream',
        () async {
          final poller = VGStreamingOfflineAssetStatusPoller(
            client: fakeClient,
            requestId: 'req_stop_test',
            config: VGStreamingOfflineAssetStatusPollerConfig(
              interval: const Duration(milliseconds: 40),
              emitInitialStatus: false,
            ),
          );

          final emitted = <VGStreamingOfflineAssetDownloadStatus>[];
          final sub = poller.statuses.listen(emitted.add);

          poller.start();
          expect(poller.isRunning, isTrue);

          await Future<void>.delayed(const Duration(milliseconds: 100));
          final callsBeforeStop = fakeClient.getStatusCalls;
          expect(callsBeforeStop, greaterThanOrEqualTo(1));

          poller.stop();
          expect(poller.isRunning, isFalse);

          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(fakeClient.getStatusCalls, equals(callsBeforeStop));

          // Stream is still open and refreshOnce can still be called
          await poller.refreshOnce();
          expect(fakeClient.getStatusCalls, equals(callsBeforeStop + 1));

          await sub.cancel();
          await poller.dispose();
        },
      );
    },
  );

  group('VGStreamingOfflineAssetStatusPoller.dispose', () {
    late FakeStreamingOfflineAssetClient fakeClient;

    setUp(() {
      fakeClient = FakeStreamingOfflineAssetClient();
    });

    test(
      '1. dispose() is idempotent, closes stream, and does not dispose client',
      () async {
        final poller = VGStreamingOfflineAssetStatusPoller(
          client: fakeClient,
          requestId: 'req_dispose_1',
          config: VGStreamingOfflineAssetStatusPollerConfig(
            interval: const Duration(milliseconds: 40),
          ),
        );

        poller.start();
        expect(poller.isRunning, isTrue);

        bool streamDone = false;
        poller.statuses.listen(
          (_) {},
          onDone: () {
            streamDone = true;
          },
        );

        await poller.dispose();

        expect(poller.isDisposed, isTrue);
        expect(poller.isRunning, isFalse);
        expect(streamDone, isTrue);

        // Calling dispose again is a safe no-op
        await poller.dispose();
        expect(poller.isDisposed, isTrue);

        // Calling start or stop after dispose is a no-op
        poller.start();
        expect(poller.isRunning, isFalse);
        poller.stop();
        expect(poller.isRunning, isFalse);
      },
    );
  });
}
