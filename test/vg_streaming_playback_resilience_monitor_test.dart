// Copyright (c) Connects — Vanguard Phase 4C7AM.
// Public streaming playback resilience monitor unit tests.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackResilienceMonitor', () {
    // Helper to create test status summaries
    VGStreamingPlaybackStatusSummary createSummary({
      bool hasSession = true,
      bool isPlaying = true,
      bool isBufferingOrOpening = false,
      bool isTerminal = false,
      bool isLive = false,
      int positionMs = 10000,
      int bufferedPositionMs = 25000,
      int bufferedPercent = 80,
      String raw = 'status=OK',
      Map<String, Object?> diagnostics = const {},
    }) {
      return VGStreamingPlaybackStatusSummary(
        hasSession: hasSession,
        isLive: isLive,
        isSeekable: !isLive,
        isPlaying: isPlaying,
        isBufferingOrOpening: isBufferingOrOpening,
        isTerminal: isTerminal,
        durationMs: isLive ? -1 : 60000,
        positionMs: positionMs,
        bufferedPositionMs: bufferedPositionMs,
        bufferedPercent: bufferedPercent,
        progressFraction: isLive ? 0.0 : (positionMs / 60000.0),
        bufferedFraction: bufferedPercent / 100.0,
        effectiveDisplayWidth: 1920,
        effectiveDisplayHeight: 1080,
        hasRotationMetadata: false,
        playbackCacheEnabled: true,
        playbackCacheTelemetryAttached: true,
        playbackCacheReadObserved: true,
        playbackCacheBytesRead: 1024,
        playbackCacheSizeBytes: 2048,
        playbackCacheIgnoredCount: 0,
        raw: raw,
        diagnostics: diagnostics,
      );
    }

    // Helper to create test playback options
    VGStreamingPlaybackOptions createOptions({
      VGStreamingNetworkProfile networkProfile = VGStreamingNetworkProfile.auto,
    }) {
      return VGStreamingPlaybackOptions(
        uri: Uri.parse('https://cdn.example.com/stream.m3u8'),
        initialWidth: 1080,
        initialHeight: 1920,
        formatHint: VGStreamingFormatHint.hls,
        networkProfile: networkProfile,
        autoPlay: true,
        cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
      );
    }

    test('1. Config validates parameters and rejects invalid values', () {
      expect(
        () => VGStreamingPlaybackResilienceMonitorConfig(maxHistoryLength: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGStreamingPlaybackResilienceMonitorConfig(maxHistoryLength: -1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGStreamingPlaybackResilienceMonitorConfig(retryDelayMs: -1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGStreamingPlaybackResilienceMonitorConfig(
          resumePositionOverrideMs: -5,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGStreamingPlaybackResilienceMonitorConfig(
          lowBufferPercentThreshold: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGStreamingPlaybackResilienceMonitorConfig(
          lowBufferMsThreshold: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGStreamingPlaybackResilienceMonitorConfig(
          repeatedBufferingCountThreshold: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VGStreamingPlaybackResilienceMonitorConfig(
          stalledPositionCountThreshold: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );

      final validConfig = VGStreamingPlaybackResilienceMonitorConfig(
        maxHistoryLength: 10,
        currentNetworkProfile: VGStreamingNetworkProfile.stable,
        retryDelayMs: 500,
        resumePositionOverrideMs: 2000,
      );
      expect(validConfig.maxHistoryLength, equals(10));
      expect(
        validConfig.currentNetworkProfile,
        equals(VGStreamingNetworkProfile.stable),
      );
      expect(validConfig.retryDelayMs, equals(500));
      expect(validConfig.resumePositionOverrideMs, equals(2000));
      expect(validConfig.allowAutomaticRetry, isFalse);
      expect(validConfig.preserveCacheOptions, isTrue);

      final configJson = validConfig.toJson();
      expect(configJson['maxHistoryLength'], equals(10));
      expect(configJson['retryDelayMs'], equals(500));
      expect(
        validConfig.toString(),
        contains('VGStreamingPlaybackResilienceMonitorConfig'),
      );
    });

    test(
      '2. evaluateOnce emits snapshot and combines health advice + recovery plan',
      () async {
        final streamController =
            StreamController<VGStreamingPlaybackStatusSummary>.broadcast();
        final monitor = VGStreamingPlaybackResilienceMonitor(
          summaries: streamController.stream,
          config: VGStreamingPlaybackResilienceMonitorConfig(
            currentOptions: createOptions(),
          ),
        );

        final emittedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
        final sub = monitor.snapshots.listen(emittedSnapshots.add);

        final summary = createSummary(
          positionMs: 5000,
          bufferedPositionMs: 20000,
          bufferedPercent: 70,
        );

        final snapshot = monitor.evaluateOnce(summary);

        expect(snapshot.advisoryOnly, isTrue);
        expect(snapshot.playbackMutation, isFalse);
        expect(
          snapshot.healthAdvice.severity,
          equals(VGStreamingPlaybackHealthSeverity.healthy),
        );
        expect(
          snapshot.recoveryPlan.intent,
          equals(VGStreamingPlaybackRecoveryIntent.none),
        );
        expect(snapshot.historyLength, equals(1));
        expect(monitor.historyLength, equals(1));
        expect(monitor.latest, equals(snapshot));

        await Future<void>.delayed(Duration.zero);
        expect(emittedSnapshots.length, equals(1));
        expect(emittedSnapshots.first, equals(snapshot));

        final json = snapshot.toJson();
        expect(json['advisoryOnly'], isTrue);
        expect(json['playbackMutation'], isFalse);
        expect(json['historyLength'], equals(1));
        expect(
          snapshot.toString(),
          contains('VGStreamingPlaybackResilienceSnapshot'),
        );
        expect(snapshot.warnings, equals(snapshot.reasons));

        await sub.cancel();
        await monitor.dispose();
        await streamController.close();
      },
    );

    test(
      '3. History is bounded FIFO and recent history affects repeated-buffering / degraded advice',
      () async {
        final streamController =
            StreamController<VGStreamingPlaybackStatusSummary>.broadcast();
        final monitor = VGStreamingPlaybackResilienceMonitor(
          summaries: streamController.stream,
          config: VGStreamingPlaybackResilienceMonitorConfig(
            maxHistoryLength: 3,
            currentOptions: createOptions(),
            repeatedBufferingCountThreshold: 2,
          ),
        );

        // Step 1: Add first normal summary
        final s1 = createSummary(
          positionMs: 1000,
          bufferedPercent: 60,
          isBufferingOrOpening: false,
        );
        final snap1 = monitor.evaluateOnce(s1);
        expect(
          snap1.healthAdvice.severity,
          equals(VGStreamingPlaybackHealthSeverity.healthy),
        );
        expect(monitor.historyLength, equals(1));

        // Step 2: Add first buffering summary (watch state)
        final s2 = createSummary(
          positionMs: 1000,
          bufferedPercent: 5,
          isBufferingOrOpening: true,
        );
        final snap2 = monitor.evaluateOnce(s2);
        expect(
          snap2.healthAdvice.severity,
          equals(VGStreamingPlaybackHealthSeverity.degraded),
        ); // buffering + low buffer
        expect(monitor.historyLength, equals(2));

        // Step 3: Add second buffering summary (repeated buffering -> degraded + preferConstrainedProfile)
        final s3 = createSummary(
          positionMs: 1000,
          bufferedPercent: 20,
          isBufferingOrOpening: true,
        );
        final snap3 = monitor.evaluateOnce(s3);
        expect(
          snap3.healthAdvice.severity,
          equals(VGStreamingPlaybackHealthSeverity.degraded),
        );
        expect(
          snap3.recoveryPlan.intent,
          equals(VGStreamingPlaybackRecoveryIntent.retryConstrainedProfile),
        );
        expect(monitor.historyLength, equals(3));

        // Step 4: Add fourth summary to test FIFO bounds
        final s4 = createSummary(
          positionMs: 2000,
          bufferedPercent: 80,
          isBufferingOrOpening: false,
        );
        monitor.evaluateOnce(s4);
        expect(monitor.historyLength, equals(3));
        expect(monitor.history.first, equals(s2)); // s1 was dropped
        expect(monitor.history.last, equals(s4));

        await monitor.dispose();
        await streamController.close();
      },
    );

    test(
      '4. start() listens to stream, emits snapshots, and is idempotent',
      () async {
        final streamController =
            StreamController<VGStreamingPlaybackStatusSummary>.broadcast();
        final monitor = VGStreamingPlaybackResilienceMonitor(
          summaries: streamController.stream,
          config: VGStreamingPlaybackResilienceMonitorConfig(
            currentOptions: createOptions(),
          ),
        );

        final emittedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
        final sub = monitor.snapshots.listen(emittedSnapshots.add);

        expect(monitor.isRunning, isFalse);
        monitor.start();
        expect(monitor.isRunning, isTrue);

        // Idempotent start call
        monitor.start();
        expect(monitor.isRunning, isTrue);

        final s1 = createSummary(positionMs: 3000);
        final s2 = createSummary(positionMs: 4000);

        streamController.add(s1);
        streamController.add(s2);

        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(emittedSnapshots.length, equals(2));
        expect(emittedSnapshots[0].status.positionMs, equals(3000));
        expect(emittedSnapshots[1].status.positionMs, equals(4000));
        expect(monitor.latest, equals(emittedSnapshots[1]));

        await sub.cancel();
        await monitor.dispose();
        await streamController.close();
      },
    );

    test(
      '5. stop() cancels subscription but keeps stream usable for later start/evaluateOnce',
      () async {
        final streamController =
            StreamController<VGStreamingPlaybackStatusSummary>.broadcast();
        final monitor = VGStreamingPlaybackResilienceMonitor(
          summaries: streamController.stream,
        );

        final emittedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
        final sub = monitor.snapshots.listen(emittedSnapshots.add);

        monitor.start();
        expect(monitor.isRunning, isTrue);

        streamController.add(createSummary(positionMs: 1000));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(emittedSnapshots.length, equals(1));

        // Stop polling
        monitor.stop();
        expect(monitor.isRunning, isFalse);

        // Stream event while stopped is ignored by monitor
        streamController.add(createSummary(positionMs: 2000));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(emittedSnapshots.length, equals(1));

        // evaluateOnce still works manually
        monitor.evaluateOnce(createSummary(positionMs: 3000));
        await Future<void>.delayed(Duration.zero);
        expect(emittedSnapshots.length, equals(2));
        expect(emittedSnapshots.last.status.positionMs, equals(3000));

        // Restarting monitor works
        monitor.start();
        expect(monitor.isRunning, isTrue);
        streamController.add(createSummary(positionMs: 4000));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(emittedSnapshots.length, equals(3));
        expect(emittedSnapshots.last.status.positionMs, equals(4000));

        await sub.cancel();
        await monitor.dispose();
        await streamController.close();
      },
    );

    test(
      '6. dispose() closes output, prevents later emissions, and is idempotent',
      () async {
        final streamController =
            StreamController<VGStreamingPlaybackStatusSummary>.broadcast();
        final monitor = VGStreamingPlaybackResilienceMonitor(
          summaries: streamController.stream,
        );

        final emittedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
        var streamCompleted = false;
        final sub = monitor.snapshots.listen(
          emittedSnapshots.add,
          onDone: () => streamCompleted = true,
        );

        monitor.start();
        monitor.evaluateOnce(createSummary(positionMs: 1000));
        await Future<void>.delayed(Duration.zero);
        expect(emittedSnapshots.length, equals(1));

        await monitor.dispose();
        expect(monitor.isDisposed, isTrue);
        expect(monitor.isRunning, isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(streamCompleted, isTrue);

        // Subsequent start or evaluateOnce do not emit
        monitor.start();
        expect(monitor.isRunning, isFalse);

        final postDisposeSnap = monitor.evaluateOnce(
          createSummary(positionMs: 5000),
        );
        expect(postDisposeSnap, isNotNull);
        expect(emittedSnapshots.length, equals(1)); // no new emission

        // Multiple disposes are safe
        await monitor.dispose();
        expect(monitor.isDisposed, isTrue);

        await sub.cancel();
        await streamController.close();
      },
    );

    test('7. Input stream error does not throw or close monitor', () async {
      final streamController =
          StreamController<VGStreamingPlaybackStatusSummary>.broadcast();
      final monitor = VGStreamingPlaybackResilienceMonitor(
        summaries: streamController.stream,
      );

      final emittedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
      final sub = monitor.snapshots.listen(emittedSnapshots.add);

      monitor.start();

      streamController.add(createSummary(positionMs: 1000));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(emittedSnapshots.length, equals(1));

      // Emit error on stream
      streamController.addError(Exception('Network socket reset'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Monitor remains running and alive
      expect(monitor.isRunning, isTrue);
      expect(monitor.isDisposed, isFalse);

      // Subsequent items are still processed
      streamController.add(createSummary(positionMs: 2000));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(emittedSnapshots.length, equals(2));
      expect(
        emittedSnapshots.last.diagnostics['lastStreamError'],
        contains('Network socket reset'),
      );

      await sub.cancel();
      await monitor.dispose();
      await streamController.close();
    });

    test(
      '8. Low-latency degraded status produces recovery plan reopenStandardLatency',
      () async {
        final streamController =
            StreamController<VGStreamingPlaybackStatusSummary>.broadcast();
        final monitor = VGStreamingPlaybackResilienceMonitor(
          summaries: streamController.stream,
          config: VGStreamingPlaybackResilienceMonitorConfig(
            currentNetworkProfile: VGStreamingNetworkProfile.lowLatency,
            currentOptions: createOptions(
              networkProfile: VGStreamingNetworkProfile.lowLatency,
            ),
          ),
        );

        final summary = createSummary(
          isLive: true,
          positionMs: 12000,
          bufferedPercent: 5,
          isBufferingOrOpening: true,
        );

        final snapshot = monitor.evaluateOnce(summary);

        expect(
          snapshot.healthAdvice.severity,
          equals(VGStreamingPlaybackHealthSeverity.degraded),
        );
        expect(
          snapshot.healthAdvice.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.leaveLowLatency),
        );
        expect(snapshot.healthAdvice.shouldLeaveLowLatency, isTrue);
        expect(
          snapshot.recoveryPlan.intent,
          equals(VGStreamingPlaybackRecoveryIntent.reopenStandardLatency),
        );
        expect(
          snapshot.recoveryPlan.urgency,
          equals(VGStreamingPlaybackRecoveryUrgency.immediate),
        );
        expect(snapshot.recoveryPlan.shouldReopenPlayback, isTrue);
        expect(snapshot.recoveryPlan.requiresHostAction, isTrue);
        expect(snapshot.recoveryPlan.canBuildPlaybackOptions, isTrue);
        expect(
          snapshot.recoveryPlan.playbackOptions!.networkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );

        await monitor.dispose();
        await streamController.close();
      },
    );

    test(
      '9. updateConfig updates config and trims history if needed',
      () async {
        final streamController =
            StreamController<VGStreamingPlaybackStatusSummary>.broadcast();
        final monitor = VGStreamingPlaybackResilienceMonitor(
          summaries: streamController.stream,
          config: VGStreamingPlaybackResilienceMonitorConfig(
            maxHistoryLength: 5,
          ),
        );

        for (var i = 1; i <= 5; i++) {
          monitor.evaluateOnce(createSummary(positionMs: i * 1000));
        }
        expect(monitor.historyLength, equals(5));

        // Update config with shorter maxHistoryLength
        monitor.updateConfig(
          VGStreamingPlaybackResilienceMonitorConfig(maxHistoryLength: 2),
        );
        expect(monitor.config.maxHistoryLength, equals(2));
        expect(monitor.historyLength, equals(2));
        expect(monitor.history.first.positionMs, equals(4000));
        expect(monitor.history.last.positionMs, equals(5000));

        await monitor.dispose();
        // updateConfig after dispose is no-op
        monitor.updateConfig(
          VGStreamingPlaybackResilienceMonitorConfig(maxHistoryLength: 10),
        );
        expect(monitor.config.maxHistoryLength, equals(2));

        await streamController.close();
      },
    );

    test('10. ToString formats monitor status accurately', () async {
      final streamController =
          StreamController<VGStreamingPlaybackStatusSummary>.broadcast();
      final monitor = VGStreamingPlaybackResilienceMonitor(
        summaries: streamController.stream,
      );

      expect(monitor.toString(), contains('isRunning=false'));
      expect(monitor.toString(), contains('isDisposed=false'));
      expect(monitor.toString(), contains('historyLength=0'));

      await monitor.dispose();
      await streamController.close();
    });
  });
}
