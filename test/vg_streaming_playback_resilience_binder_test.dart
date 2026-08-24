// Copyright (c) Connects — Vanguard Phase 4C7BC.
// Public streaming playback resilience evaluation binder unit tests.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackResilienceBinder', () {
    // Helper to create mock playback options
    VGStreamingPlaybackOptions createOptions({
      VGStreamingNetworkProfile profile = VGStreamingNetworkProfile.constrained,
    }) {
      return VGStreamingPlaybackOptions(
        uri: Uri.parse('https://cdn.example.com/live/master.m3u8'),
        initialWidth: 1080,
        initialHeight: 1920,
        networkProfile: profile,
      );
    }

    // Helper to create mock status summary
    VGStreamingPlaybackStatusSummary createSummary({
      bool isPlaying = true,
      int positionMs = 10000,
      int bufferedPositionMs = 25000,
      bool isTerminal = false,
    }) {
      return VGStreamingPlaybackStatusSummary(
        hasSession: true,
        isLive: false,
        isSeekable: true,
        isPlaying: isPlaying,
        isBufferingOrOpening: false,
        isTerminal: isTerminal,
        durationMs: 60000,
        positionMs: positionMs,
        bufferedPositionMs: bufferedPositionMs,
        bufferedPercent: 80,
        progressFraction: positionMs / 60000.0,
        bufferedFraction: 0.8,
        effectiveDisplayWidth: 1920,
        effectiveDisplayHeight: 1080,
        hasRotationMetadata: false,
        playbackCacheEnabled: true,
        playbackCacheTelemetryAttached: true,
        playbackCacheReadObserved: true,
        playbackCacheBytesRead: 1024,
        playbackCacheSizeBytes: 2048,
        playbackCacheIgnoredCount: 0,
        raw: 'status=OK',
        diagnostics: const {},
      );
    }

    // Helper to create mock health advice
    VGStreamingPlaybackHealthAdvice createAdvice({
      VGStreamingPlaybackHealthSeverity severity =
          VGStreamingPlaybackHealthSeverity.healthy,
      VGStreamingPlaybackHealthAction recommendedAction =
          VGStreamingPlaybackHealthAction.keepCurrentProfile,
      List<String> reasons = const ['health_optimal'],
    }) {
      return VGStreamingPlaybackHealthAdvice(
        severity: severity,
        recommendedAction: recommendedAction,
        recommendedNetworkProfile: VGStreamingNetworkProfile.auto,
        shouldRetry:
            recommendedAction == VGStreamingPlaybackHealthAction.retryPlayback,
        shouldLeaveLowLatency:
            recommendedAction ==
            VGStreamingPlaybackHealthAction.leaveLowLatency,
        reasons: reasons,
      );
    }

    // Helper to create mock recovery plan
    VGStreamingPlaybackRecoveryPlan createPlan({
      VGStreamingPlaybackRecoveryIntent intent =
          VGStreamingPlaybackRecoveryIntent.none,
      VGStreamingPlaybackRecoveryUrgency urgency =
          VGStreamingPlaybackRecoveryUrgency.none,
      bool shouldReopenPlayback = false,
      bool requiresHostAction = false,
      bool canBuildPlaybackOptions = false,
      VGStreamingPlaybackOptions? playbackOptions,
      int? resumePositionMs,
      int retryDelayMs = 750,
      bool advisoryOnly = true,
      bool playbackMutation = false,
      List<String> reasons = const ['plan_ok'],
    }) {
      return VGStreamingPlaybackRecoveryPlan(
        intent: intent,
        urgency: urgency,
        shouldReopenPlayback: shouldReopenPlayback,
        requiresHostAction: requiresHostAction,
        canBuildPlaybackOptions: canBuildPlaybackOptions,
        playbackOptions: playbackOptions,
        resumePositionMs: resumePositionMs,
        retryDelayMs: retryDelayMs,
        advisoryOnly: advisoryOnly,
        playbackMutation: playbackMutation,
        reasons: reasons,
      );
    }

    // Helper to create composite resilience snapshot
    VGStreamingPlaybackResilienceSnapshot createSnapshot({
      VGStreamingPlaybackStatusSummary? status,
      VGStreamingPlaybackHealthAdvice? healthAdvice,
      VGStreamingPlaybackRecoveryPlan? recoveryPlan,
      int historyLength = 1,
    }) {
      return VGStreamingPlaybackResilienceSnapshot(
        status: status ?? createSummary(),
        healthAdvice: healthAdvice ?? createAdvice(),
        recoveryPlan: recoveryPlan ?? createPlan(),
        historyLength: historyLength,
        advisoryOnly: true,
        playbackMutation: false,
        diagnostics: const {'snapshot': true},
      );
    }

    group('VGStreamingPlaybackResilienceBinderConfig', () {
      test('defaults and serialization', () {
        const config = VGStreamingPlaybackResilienceBinderConfig();
        expect(config.streamKey, isNull);
        expect(config.emitLatestOnStart, isFalse);

        final json = config.toJson();
        expect(json['streamKey'], isNull);
        expect(json['emitLatestOnStart'], isFalse);
        expect(
          config.toString(),
          contains('VGStreamingPlaybackResilienceBinderConfig'),
        );

        const custom = VGStreamingPlaybackResilienceBinderConfig(
          streamKey: 'stream-xyz',
          emitLatestOnStart: true,
        );
        expect(custom.streamKey, 'stream-xyz');
        expect(custom.emitLatestOnStart, isTrue);
        expect(custom.toJson()['streamKey'], 'stream-xyz');
        expect(custom.toJson()['emitLatestOnStart'], isTrue);
      });
    });

    group('evaluateOnce and Invariants', () {
      test(
        'evaluates coordinator, emits evaluation, uses nowProvider and streamKey',
        () async {
          final streamController =
              StreamController<
                VGStreamingPlaybackResilienceSnapshot
              >.broadcast();
          final coordinator = VGStreamingPlaybackResilienceCoordinator();
          int currentTime = 50000;

          final binder = VGStreamingPlaybackResilienceBinder(
            snapshots: streamController.stream,
            coordinator: coordinator,
            config: const VGStreamingPlaybackResilienceBinderConfig(
              streamKey: 'binder-stream',
            ),
            nowProvider: () => currentTime,
          );

          final evaluations =
              <VGStreamingPlaybackResilienceCoordinatorEvaluation>[];
          final sub = binder.evaluations.listen(evaluations.add);

          final options = createOptions();
          final snapshot = createSnapshot(
            healthAdvice: createAdvice(
              severity: VGStreamingPlaybackHealthSeverity.stalled,
              recommendedAction: VGStreamingPlaybackHealthAction.retryPlayback,
            ),
            recoveryPlan: createPlan(
              intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
              urgency: VGStreamingPlaybackRecoveryUrgency.active,
              shouldReopenPlayback: true,
              canBuildPlaybackOptions: true,
              playbackOptions: options,
              resumePositionMs: 10000,
            ),
          );

          final eval = binder.evaluateOnce(snapshot);

          expect(eval.advisoryOnly, isTrue);
          expect(eval.playbackMutation, isFalse);
          expect(eval.diagnostics['streamKey'], 'binder-stream');
          expect(
            eval.decision.action,
            VGStreamingPlaybackResilienceDecisionAction.scheduleRetry,
          );
          expect(binder.latest, same(eval));

          // Let microtasks run
          await pumpEventQueue();
          expect(evaluations.length, 1);
          expect(evaluations.first, same(eval));

          // Invariant: coordinator journal is NOT modified automatically by evaluation
          expect(coordinator.journalSnapshot().count, 0);

          await sub.cancel();
          binder.dispose();
          await streamController.close();
        },
      );

      test(
        'custom nowMs and streamKey override config and nowProvider in evaluateOnce',
        () {
          final coordinator = VGStreamingPlaybackResilienceCoordinator();
          final binder = VGStreamingPlaybackResilienceBinder(
            snapshots: const Stream.empty(),
            coordinator: coordinator,
            config: const VGStreamingPlaybackResilienceBinderConfig(
              streamKey: 'default-key',
            ),
            nowProvider: () => 1000,
          );

          final snapshot = createSnapshot(
            recoveryPlan: createPlan(
              intent: VGStreamingPlaybackRecoveryIntent.reopenStandardLatency,
            ),
          );

          final eval = binder.evaluateOnce(
            snapshot,
            nowMs: 99999,
            streamKey: 'override-key',
          );
          expect(eval.diagnostics['streamKey'], 'override-key');
          expect(eval.retryBudget.attemptsInWindow, 0);

          binder.dispose();
        },
      );
    });
  });
}
