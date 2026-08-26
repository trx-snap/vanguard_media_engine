// Copyright (c) Connects — Vanguard Phase 4C7BK.
// Public streaming offline asset lifecycle monitor unit tests.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VGStreamingOfflineAssetLifecycleMonitorConfig', () {
    test('1. default configuration has expected values', () {
      final config = VGStreamingOfflineAssetLifecycleMonitorConfig();
      expect(config.maxHistoryLength, equals(32));
      expect(config.emitDuplicateStatuses, isTrue);
      expect(config.toString(), contains('maxHistoryLength=32'));
      expect(config.toString(), contains('emitDuplicateStatuses=true'));
    });

    test('2. custom configuration preserves values and serializes to JSON', () {
      final config = VGStreamingOfflineAssetLifecycleMonitorConfig(
        maxHistoryLength: 16,
        emitDuplicateStatuses: false,
      );
      expect(config.maxHistoryLength, equals(16));
      expect(config.emitDuplicateStatuses, isFalse);

      final json = config.toJson();
      expect(json['maxHistoryLength'], equals(16));
      expect(json['emitDuplicateStatuses'], isFalse);
    });

    test(
      '3. config rejects zero or negative maxHistoryLength with ArgumentError',
      () {
        expect(
          () => VGStreamingOfflineAssetLifecycleMonitorConfig(
            maxHistoryLength: 0,
          ),
          throwsArgumentError,
        );
        expect(
          () => VGStreamingOfflineAssetLifecycleMonitorConfig(
            maxHistoryLength: -1,
          ),
          throwsArgumentError,
        );
      },
    );
  });

  group('VGStreamingOfflineAssetLifecycleSnapshot', () {
    test('1. getters and serialization work as expected', () {
      final status = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_1',
        sourceKey: 'source_1',
        state: VGStreamingOfflineAssetDownloadState.running,
        bytesDownloaded: 2048,
        totalBytes: 4096,
      );
      final summary = VGStreamingOfflineAssetLifecycleSummary(
        totalCount: 1,
        runningCount: 1,
        activeRequestIds: const ['req_1'],
      );

      final snapshot = VGStreamingOfflineAssetLifecycleSnapshot(
        status: status,
        summary: summary,
        historyLength: 1,
        diagnostics: const {'test': true},
      );

      expect(snapshot.status, same(status));
      expect(snapshot.summary, same(summary));
      expect(snapshot.historyLength, equals(1));
      expect(snapshot.advisoryOnly, isTrue);
      expect(snapshot.playbackMutation, isFalse);
      expect(snapshot.hasActiveDownloads, isTrue);
      expect(snapshot.allTerminal, isFalse);
      expect(snapshot.isCurrentTerminal, isFalse);
      expect(snapshot.isCurrentSuccessful, isFalse);
      expect(snapshot.diagnostics['test'], isTrue);

      final json = snapshot.toJson();
      expect(json['historyLength'], equals(1));
      expect(json['advisoryOnly'], isTrue);
      expect(json['playbackMutation'], isFalse);
      expect(json['hasActiveDownloads'], isTrue);
      expect(json['allTerminal'], isFalse);
      expect(json['isCurrentTerminal'], isFalse);
      expect(json['isCurrentSuccessful'], isFalse);

      expect(snapshot.toString(), contains('requestId=req_1'));
      expect(snapshot.toString(), contains('state=running'));
      expect(snapshot.toString(), contains('hasActiveDownloads=true'));
    });

    test('2. terminal success status getters reflect terminal state', () {
      final status = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_2',
        sourceKey: 'source_2',
        state: VGStreamingOfflineAssetDownloadState.succeeded,
        bytesDownloaded: 4096,
        totalBytes: 4096,
        assetUri: Uri.parse('file:///offline/req_2.movpkg'),
      );
      final summary = VGStreamingOfflineAssetLifecycleSummary(
        totalCount: 1,
        succeededCount: 1,
        terminalCount: 1,
        terminalRequestIds: const ['req_2'],
      );

      final snapshot = VGStreamingOfflineAssetLifecycleSnapshot(
        status: status,
        summary: summary,
        historyLength: 1,
      );

      expect(snapshot.hasActiveDownloads, isFalse);
      expect(snapshot.allTerminal, isTrue);
      expect(snapshot.isCurrentTerminal, isTrue);
      expect(snapshot.isCurrentSuccessful, isTrue);
    });
  });

  group('VGStreamingOfflineAssetLifecycleMonitor synchronous evaluateOnce', () {
    late StreamController<VGStreamingOfflineAssetDownloadStatus> controller;
    late VGStreamingOfflineAssetLifecycleMonitor monitor;

    setUp(() {
      controller =
          StreamController<VGStreamingOfflineAssetDownloadStatus>.broadcast();
      monitor = VGStreamingOfflineAssetLifecycleMonitor(
        statuses: controller.stream,
      );
    });

    tearDown(() async {
      await monitor.dispose();
      await controller.close();
    });

    test('1. initial state has defaults, no history, no latest', () {
      expect(monitor.config.maxHistoryLength, equals(32));
      expect(monitor.isRunning, isFalse);
      expect(monitor.isDisposed, isFalse);
      expect(monitor.historyLength, equals(0));
      expect(monitor.history, isEmpty);
      expect(monitor.latest, isNull);
      expect(monitor.toString(), contains('isRunning=false'));
      expect(monitor.toString(), contains('historyLength=0'));
    });

    test(
      '2. evaluateOnce appends to history, updates latest, emits to stream',
      () async {
        final emitted = <VGStreamingOfflineAssetLifecycleSnapshot>[];
        final sub = monitor.snapshots.listen(emitted.add);

        final status = VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_eval_1',
          sourceKey: 'source_eval_1',
          state: VGStreamingOfflineAssetDownloadState.queued,
        );

        final snapshot = monitor.evaluateOnce(status);

        expect(monitor.historyLength, equals(1));
        expect(monitor.latest, same(snapshot));
        expect(snapshot.status, same(status));
        expect(snapshot.summary.queuedCount, equals(1));
        expect(snapshot.summary.totalCount, equals(1));
        expect(snapshot.hasActiveDownloads, isTrue);
        expect(snapshot.allTerminal, isFalse);

        await Future<void>.delayed(Duration.zero);
        expect(emitted.length, equals(1));
        expect(emitted.first, same(snapshot));

        await sub.cancel();
      },
    );

    test('3. unmodifiable history copy prevents external mutation', () {
      final status = VGStreamingOfflineAssetDownloadStatus(
        requestId: 'req_unmod',
        sourceKey: 'src_unmod',
        state: VGStreamingOfflineAssetDownloadState.running,
      );
      monitor.evaluateOnce(status);

      final list = monitor.history;
      expect(() => list.add(status), throwsUnsupportedError);
    });
  });

  group(
    'VGStreamingOfflineAssetLifecycleMonitor FIFO bounding and config update',
    () {
      late StreamController<VGStreamingOfflineAssetDownloadStatus> controller;

      setUp(() {
        controller =
            StreamController<VGStreamingOfflineAssetDownloadStatus>.broadcast();
      });

      tearDown(() async {
        await controller.close();
      });

      test('1. FIFO trims history when exceeding maxHistoryLength', () async {
        final monitor = VGStreamingOfflineAssetLifecycleMonitor(
          statuses: controller.stream,
          config: VGStreamingOfflineAssetLifecycleMonitorConfig(
            maxHistoryLength: 3,
          ),
        );

        for (var i = 1; i <= 5; i++) {
          monitor.evaluateOnce(
            VGStreamingOfflineAssetDownloadStatus(
              requestId: 'req_$i',
              sourceKey: 'src_$i',
              state: VGStreamingOfflineAssetDownloadState.running,
              bytesDownloaded: i * 100,
            ),
          );
        }

        expect(monitor.historyLength, equals(3));
        expect(
          monitor.history.map((s) => s.requestId).toList(),
          equals(['req_3', 'req_4', 'req_5']),
        );
        expect(monitor.latest!.summary.totalCount, equals(3));
        expect(
          monitor.latest!.summary.totalBytesDownloaded,
          equals(300 + 400 + 500),
        );

        await monitor.dispose();
      });

      test(
        '2. updateConfig immediately trims history if new bound is smaller',
        () async {
          final monitor = VGStreamingOfflineAssetLifecycleMonitor(
            statuses: controller.stream,
            config: VGStreamingOfflineAssetLifecycleMonitorConfig(
              maxHistoryLength: 5,
            ),
          );

          for (var i = 1; i <= 5; i++) {
            monitor.evaluateOnce(
              VGStreamingOfflineAssetDownloadStatus(
                requestId: 'req_$i',
                sourceKey: 'src_$i',
                state: VGStreamingOfflineAssetDownloadState.running,
              ),
            );
          }
          expect(monitor.historyLength, equals(5));

          monitor.updateConfig(
            VGStreamingOfflineAssetLifecycleMonitorConfig(maxHistoryLength: 2),
          );

          expect(monitor.config.maxHistoryLength, equals(2));
          expect(monitor.historyLength, equals(2));
          expect(
            monitor.history.map((s) => s.requestId).toList(),
            equals(['req_4', 'req_5']),
          );

          // Future evaluations respect new max
          monitor.evaluateOnce(
            VGStreamingOfflineAssetDownloadStatus(
              requestId: 'req_6',
              sourceKey: 'src_6',
              state: VGStreamingOfflineAssetDownloadState.succeeded,
            ),
          );
          expect(monitor.historyLength, equals(2));
          expect(
            monitor.history.map((s) => s.requestId).toList(),
            equals(['req_5', 'req_6']),
          );

          await monitor.dispose();
        },
      );

      test('3. updateConfig is a no-op after dispose', () async {
        final monitor = VGStreamingOfflineAssetLifecycleMonitor(
          statuses: controller.stream,
        );
        await monitor.dispose();

        monitor.updateConfig(
          VGStreamingOfflineAssetLifecycleMonitorConfig(maxHistoryLength: 4),
        );
        expect(monitor.config.maxHistoryLength, equals(32));
      });
    },
  );

  group(
    'VGStreamingOfflineAssetLifecycleMonitor stream lifecycle (start, stop, dispose)',
    () {
      late StreamController<VGStreamingOfflineAssetDownloadStatus> controller;
      late VGStreamingOfflineAssetLifecycleMonitor monitor;

      setUp(() {
        controller =
            StreamController<VGStreamingOfflineAssetDownloadStatus>.broadcast();
        monitor = VGStreamingOfflineAssetLifecycleMonitor(
          statuses: controller.stream,
        );
      });

      tearDown(() async {
        await monitor.dispose();
        await controller.close();
      });

      test(
        '1. start() subscribes to statuses and emits snapshots; is idempotent',
        () async {
          final emitted = <VGStreamingOfflineAssetLifecycleSnapshot>[];
          final sub = monitor.snapshots.listen(emitted.add);

          monitor.start();
          expect(monitor.isRunning, isTrue);

          // Idempotent start
          monitor.start();
          expect(monitor.isRunning, isTrue);

          controller.add(
            VGStreamingOfflineAssetDownloadStatus(
              requestId: 'req_stream_1',
              sourceKey: 'src_1',
              state: VGStreamingOfflineAssetDownloadState.running,
              bytesDownloaded: 100,
              totalBytes: 500,
            ),
          );

          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(emitted.length, equals(1));
          expect(emitted.first.status.requestId, equals('req_stream_1'));
          expect(monitor.latest?.status.requestId, equals('req_stream_1'));

          await sub.cancel();
        },
      );

      test(
        '2. stop() pauses stream listening without closing snapshots stream',
        () async {
          final emitted = <VGStreamingOfflineAssetLifecycleSnapshot>[];
          final sub = monitor.snapshots.listen(emitted.add);

          monitor.start();
          expect(monitor.isRunning, isTrue);

          controller.add(
            VGStreamingOfflineAssetDownloadStatus(
              requestId: 'req_first',
              sourceKey: 'src_1',
              state: VGStreamingOfflineAssetDownloadState.running,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(emitted.length, equals(1));

          monitor.stop();
          expect(monitor.isRunning, isFalse);

          // Event added while stopped is not received
          controller.add(
            VGStreamingOfflineAssetDownloadStatus(
              requestId: 'req_second',
              sourceKey: 'src_1',
              state: VGStreamingOfflineAssetDownloadState.running,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(emitted.length, equals(1));

          // evaluateOnce still works while stopped
          monitor.evaluateOnce(
            VGStreamingOfflineAssetDownloadStatus(
              requestId: 'req_eval_while_stopped',
              sourceKey: 'src_1',
              state: VGStreamingOfflineAssetDownloadState.succeeded,
            ),
          );
          await Future<void>.delayed(Duration.zero);
          expect(emitted.length, equals(2));
          expect(
            emitted.last.status.requestId,
            equals('req_eval_while_stopped'),
          );

          // Restarting works
          monitor.start();
          expect(monitor.isRunning, isTrue);
          controller.add(
            VGStreamingOfflineAssetDownloadStatus(
              requestId: 'req_after_restart',
              sourceKey: 'src_1',
              state: VGStreamingOfflineAssetDownloadState.succeeded,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(emitted.length, equals(3));
          expect(emitted.last.status.requestId, equals('req_after_restart'));

          await sub.cancel();
        },
      );

      test(
        '3. dispose() closes snapshots stream, stops listening, does not close input',
        () async {
          var snapshotStreamDone = false;
          monitor.snapshots.listen(
            (_) {},
            onDone: () {
              snapshotStreamDone = true;
            },
          );

          monitor.start();
          expect(monitor.isRunning, isTrue);

          await monitor.dispose();

          expect(monitor.isDisposed, isTrue);
          expect(monitor.isRunning, isFalse);
          expect(snapshotStreamDone, isTrue);

          // Input controller is still open
          expect(controller.isClosed, isFalse);

          // Dispose is idempotent
          await monitor.dispose();
          expect(monitor.isDisposed, isTrue);

          // start/stop after dispose are no-ops
          monitor.start();
          expect(monitor.isRunning, isFalse);
          monitor.stop();
          expect(monitor.isRunning, isFalse);
        },
      );

      test(
        '4. stream errors do not cancel monitor; subsequent statuses still produce snapshots',
        () async {
          final emitted = <VGStreamingOfflineAssetLifecycleSnapshot>[];
          final sub = monitor.snapshots.listen(emitted.add);

          monitor.start();

          controller.addError(Exception('transient stream error'));
          await Future<void>.delayed(const Duration(milliseconds: 10));

          expect(monitor.isRunning, isTrue);

          controller.add(
            VGStreamingOfflineAssetDownloadStatus(
              requestId: 'req_after_err',
              sourceKey: 'src_1',
              state: VGStreamingOfflineAssetDownloadState.succeeded,
            ),
          );

          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(emitted.length, equals(1));
          expect(emitted.first.status.requestId, equals('req_after_err'));
          expect(
            emitted.first.diagnostics['lastStreamError'],
            contains('transient stream error'),
          );

          await sub.cancel();
        },
      );
    },
  );

  group(
    'VGStreamingOfflineAssetLifecycleMonitor duplicate status suppression',
    () {
      late StreamController<VGStreamingOfflineAssetDownloadStatus> controller;

      setUp(() {
        controller =
            StreamController<VGStreamingOfflineAssetDownloadStatus>.broadcast();
      });

      tearDown(() async {
        await controller.close();
      });

      test(
        '1. emitDuplicateStatuses=true retains duplicates and emits each',
        () async {
          final monitor = VGStreamingOfflineAssetLifecycleMonitor(
            statuses: controller.stream,
            config: VGStreamingOfflineAssetLifecycleMonitorConfig(
              emitDuplicateStatuses: true,
            ),
          );

          final emitted = <VGStreamingOfflineAssetLifecycleSnapshot>[];
          final sub = monitor.snapshots.listen(emitted.add);

          final status = VGStreamingOfflineAssetDownloadStatus(
            requestId: 'req_dup',
            sourceKey: 'src_dup',
            state: VGStreamingOfflineAssetDownloadState.running,
            bytesDownloaded: 1000,
            totalBytes: 2000,
          );

          monitor.evaluateOnce(status);
          monitor.evaluateOnce(status);

          expect(monitor.historyLength, equals(2));
          await Future<void>.delayed(Duration.zero);
          expect(emitted.length, equals(2));

          await sub.cancel();
          await monitor.dispose();
        },
      );

      test(
        '2. emitDuplicateStatuses=false suppresses identical consecutive statuses',
        () async {
          final monitor = VGStreamingOfflineAssetLifecycleMonitor(
            statuses: controller.stream,
            config: VGStreamingOfflineAssetLifecycleMonitorConfig(
              emitDuplicateStatuses: false,
            ),
          );

          final emitted = <VGStreamingOfflineAssetLifecycleSnapshot>[];
          final sub = monitor.snapshots.listen(emitted.add);

          final status1 = VGStreamingOfflineAssetDownloadStatus(
            requestId: 'req_dup',
            sourceKey: 'src_dup',
            state: VGStreamingOfflineAssetDownloadState.running,
            bytesDownloaded: 1000,
            totalBytes: 2000,
          );

          final res1 = monitor.evaluateOnce(status1);
          expect(monitor.historyLength, equals(1));

          // Identical duplicate status
          final statusDuplicate = VGStreamingOfflineAssetDownloadStatus(
            requestId: 'req_dup',
            sourceKey: 'src_dup',
            state: VGStreamingOfflineAssetDownloadState.running,
            bytesDownloaded: 1000,
            totalBytes: 2000,
          );

          final res2 = monitor.evaluateOnce(statusDuplicate);
          expect(identical(res1, res2), isTrue);
          expect(monitor.historyLength, equals(1));

          // Progress update (different bytesDownloaded) is NOT suppressed
          final statusProgress = VGStreamingOfflineAssetDownloadStatus(
            requestId: 'req_dup',
            sourceKey: 'src_dup',
            state: VGStreamingOfflineAssetDownloadState.running,
            bytesDownloaded: 1500,
            totalBytes: 2000,
          );

          final res3 = monitor.evaluateOnce(statusProgress);
          expect(monitor.historyLength, equals(2));
          expect(res3.status.bytesDownloaded, equals(1500));

          await Future<void>.delayed(Duration.zero);
          expect(emitted.length, equals(2));

          await sub.cancel();
          await monitor.dispose();
        },
      );
    },
  );

  group('VGStreamingOfflineAssetLifecycleMonitor post-dispose evaluateOnce', () {
    late StreamController<VGStreamingOfflineAssetDownloadStatus> controller;

    setUp(() {
      controller =
          StreamController<VGStreamingOfflineAssetDownloadStatus>.broadcast();
    });

    tearDown(() async {
      await controller.close();
    });

    test(
      '1. returns latest snapshot if evaluateOnce was previously called',
      () async {
        final monitor = VGStreamingOfflineAssetLifecycleMonitor(
          statuses: controller.stream,
        );

        final status = VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_pre_disp',
          sourceKey: 'src_pre',
          state: VGStreamingOfflineAssetDownloadState.running,
        );
        final initialSnapshot = monitor.evaluateOnce(status);

        await monitor.dispose();
        expect(monitor.isDisposed, isTrue);

        final postDispStatus = VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_post_disp',
          sourceKey: 'src_post',
          state: VGStreamingOfflineAssetDownloadState.succeeded,
        );

        final result = monitor.evaluateOnce(postDispStatus);
        expect(result, same(initialSnapshot));
        expect(result.status.requestId, equals('req_pre_disp'));
        expect(monitor.historyLength, equals(1));
      },
    );

    test(
      '2. synthesizes one-off snapshot without mutating state if latest was null',
      () async {
        final monitor = VGStreamingOfflineAssetLifecycleMonitor(
          statuses: controller.stream,
        );
        await monitor.dispose();
        expect(monitor.isDisposed, isTrue);
        expect(monitor.latest, isNull);

        final status = VGStreamingOfflineAssetDownloadStatus(
          requestId: 'req_synth',
          sourceKey: 'src_synth',
          state: VGStreamingOfflineAssetDownloadState.succeeded,
          bytesDownloaded: 500,
        );

        final result = monitor.evaluateOnce(status);
        expect(result.status.requestId, equals('req_synth'));
        expect(result.summary.succeededCount, equals(1));
        expect(result.summary.totalBytesDownloaded, equals(500));
        expect(result.diagnostics['disposed'], isTrue);
        expect(result.advisoryOnly, isTrue);
        expect(result.playbackMutation, isFalse);

        // State is not mutated
        expect(monitor.historyLength, equals(0));
        expect(monitor.latest, isNull);
      },
    );
  });
}
