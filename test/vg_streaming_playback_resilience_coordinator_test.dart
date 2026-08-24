// Copyright (c) Connects — Vanguard Phase 4C7AW.
// Public streaming playback resilience coordinator unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackResilienceCoordinator', () {
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
      int historyLength = 4,
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

    test('1. Default config initialization & properties', () {
      final coordinator = VGStreamingPlaybackResilienceCoordinator();
      expect(coordinator.config.streamKey, isNull);
      expect(coordinator.config.journalConfig.maxStoredAttempts, 64);
      expect(coordinator.config.retryBudgetConfig.maxAttempts, 3);
      expect(coordinator.config.retryBudgetConfig.windowMs, 120000);
      expect(coordinator.config.retryBudgetConfig.minimumDelayMs, 750);
      expect(coordinator.journal, isNotNull);
      expect(coordinator.length, 0);
      expect(coordinator.isEmpty, isTrue);
      expect(coordinator.isNotEmpty, isFalse);

      final configJson = coordinator.config.toJson();
      expect(configJson['journalConfig'], isA<Map<String, Object?>>());
      expect(configJson['retryBudgetConfig'], isA<Map<String, Object?>>());
      expect(configJson['streamKey'], isNull);
      expect(
        coordinator.config.toString(),
        contains('VGStreamingPlaybackResilienceCoordinatorConfig'),
      );
    });

    test(
      '2. Evaluate renders scheduleRetry and carries options without auto-recording',
      () {
        final coordinator = VGStreamingPlaybackResilienceCoordinator();
        final options = createOptions();
        final plan = createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          urgency: VGStreamingPlaybackRecoveryUrgency.active,
          shouldReopenPlayback: true,
          canBuildPlaybackOptions: true,
          playbackOptions: options,
          resumePositionMs: 15000,
          reasons: ['stall_detected'],
        );
        final snapshot = createSnapshot(
          status: createSummary(positionMs: 15000),
          healthAdvice: createAdvice(
            severity: VGStreamingPlaybackHealthSeverity.stalled,
            recommendedAction: VGStreamingPlaybackHealthAction.retryPlayback,
            reasons: ['playback_stalled'],
          ),
          recoveryPlan: plan,
        );

        final evaluation = coordinator.evaluate(
          snapshot: snapshot,
          nowMs: 100000,
          streamKey: 'stream_1',
        );

        // Verify evaluation fields
        expect(
          evaluation.action,
          VGStreamingPlaybackResilienceDecisionAction.scheduleRetry,
        );
        expect(evaluation.canRetryNow, isTrue);
        expect(evaluation.shouldRecordAttemptOnHostRetry, isTrue);
        expect(evaluation.requiresHostAction, isFalse);
        expect(evaluation.retryAfterMs, 0);
        expect(evaluation.advisoryOnly, isTrue);
        expect(evaluation.playbackMutation, isFalse);
        expect(evaluation.decision.playbackOptions, options);
        expect(evaluation.decision.resumePositionMs, 15000);
        expect(evaluation.reasons, contains('stall_detected'));
        expect(evaluation.reasons, contains('schedule_retry_permitted'));
        expect(evaluation.warnings, evaluation.reasons);

        // Invariant: evaluate must NOT automatically record an attempt in journal
        expect(coordinator.length, 0);
        expect(coordinator.isEmpty, isTrue);
        expect(evaluation.journalSnapshot.count, 0);
        expect(evaluation.retryBudget.attemptsInWindow, 0);
        expect(evaluation.retryBudget.remainingAttempts, 2);
      },
    );

    test(
      '3. Explicit recordHostRetryAttempted records attempt after scheduleRetry',
      () {
        final coordinator = VGStreamingPlaybackResilienceCoordinator();
        final plan = createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          urgency: VGStreamingPlaybackRecoveryUrgency.active,
          shouldReopenPlayback: true,
          canBuildPlaybackOptions: true,
          playbackOptions: createOptions(),
          reasons: ['retry_needed'],
        );
        final snapshot = createSnapshot(recoveryPlan: plan);

        final eval = coordinator.evaluate(
          snapshot: snapshot,
          nowMs: 100000,
          streamKey: 'stream_1',
        );
        expect(
          eval.action,
          VGStreamingPlaybackResilienceDecisionAction.scheduleRetry,
        );
        expect(eval.shouldRecordAttemptOnHostRetry, isTrue);
        expect(coordinator.length, 0);

        // Host explicitly records attempt upon retry execution
        final attempt = coordinator.recordHostRetryAttempted(
          nowMs: 100000,
          decision: eval.decision,
          streamKey: 'stream_1',
          reason: 'custom_retry_invoked',
        );

        expect(attempt, isNotNull);
        expect(attempt!.timestampMs, 100000);
        expect(
          attempt.intent,
          VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        );
        expect(attempt.streamKey, 'stream_1');
        expect(attempt.reason, 'custom_retry_invoked');

        expect(coordinator.length, 1);
        expect(coordinator.isNotEmpty, isTrue);
        expect(coordinator.isEmpty, isFalse);
        expect(coordinator.journalSnapshot(streamKey: 'stream_1').count, 1);
      },
    );

    test(
      '4. recordHostRetryAttempted returns null when shouldRecordAttemptOnHostRetry is false',
      () {
        final coordinator = VGStreamingPlaybackResilienceCoordinator();

        // Case A: observe action
        final observeSnapshot = createSnapshot(
          recoveryPlan: createPlan(
            intent: VGStreamingPlaybackRecoveryIntent.none,
          ),
        );
        final observeEval = coordinator.evaluate(
          snapshot: observeSnapshot,
          nowMs: 100000,
        );
        expect(
          observeEval.action,
          VGStreamingPlaybackResilienceDecisionAction.observe,
        );
        expect(observeEval.shouldRecordAttemptOnHostRetry, isFalse);

        final attemptA = coordinator.recordHostRetryAttempted(
          nowMs: 100000,
          decision: observeEval.decision,
        );
        expect(attemptA, isNull);
        expect(coordinator.length, 0);

        // Case B: retryBlocked action (budget exhausted)
        final blockedDecision = VGStreamingPlaybackResilienceDecision(
          action: VGStreamingPlaybackResilienceDecisionAction.retryBlocked,
          canRetryNow: false,
          shouldRecordAttemptOnHostRetry: false,
          requiresHostAction: false,
          retryAfterMs: 0,
          recoveryIntent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          recoveryUrgency: VGStreamingPlaybackRecoveryUrgency.none,
        );
        final attemptB = coordinator.recordHostRetryAttempted(
          nowMs: 100000,
          decision: blockedDecision,
        );
        expect(attemptB, isNull);
        expect(coordinator.length, 0);
      },
    );

    test(
      '5. StreamKey override precedence (method arg vs config streamKey)',
      () {
        final coordinator = VGStreamingPlaybackResilienceCoordinator(
          config: const VGStreamingPlaybackResilienceCoordinatorConfig(
            streamKey: 'default_stream',
          ),
        );

        final plan = createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          shouldReopenPlayback: true,
          canBuildPlaybackOptions: true,
          playbackOptions: createOptions(),
        );
        final snapshot = createSnapshot(recoveryPlan: plan);

        // 1. Evaluate with explicit streamKey override
        final evalOverride = coordinator.evaluate(
          snapshot: snapshot,
          nowMs: 100000,
          streamKey: 'override_stream',
        );
        coordinator.recordHostRetryAttempted(
          nowMs: 100000,
          decision: evalOverride.decision,
          streamKey: 'override_stream',
        );

        // 2. Evaluate with default config streamKey
        final evalDefault = coordinator.evaluate(
          snapshot: snapshot,
          nowMs: 101000,
        );
        coordinator.recordHostRetryAttempted(
          nowMs: 101000,
          decision: evalDefault.decision,
        );

        expect(coordinator.length, 2);
        expect(
          coordinator.journalSnapshot(streamKey: 'override_stream').count,
          1,
        );
        expect(
          coordinator.journalSnapshot().count,
          1,
        ); // defaults to config streamKey 'default_stream'
        expect(
          coordinator.journalSnapshot(streamKey: 'default_stream').count,
          1,
        );
        expect(coordinator.journal.snapshot().count, 2); // all streams
      },
    );

    test(
      '6. Retry budget exhaustion transitions from allow -> delay -> block',
      () {
        final coordinator = VGStreamingPlaybackResilienceCoordinator(
          config: const VGStreamingPlaybackResilienceCoordinatorConfig(
            retryBudgetConfig: VGStreamingPlaybackRetryBudgetConfig(
              maxAttempts: 2,
              windowMs: 60000,
              minimumDelayMs: 1000,
            ),
            streamKey: 'stream_test',
          ),
        );

        final plan = createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          shouldReopenPlayback: true,
          canBuildPlaybackOptions: true,
          playbackOptions: createOptions(),
          reasons: ['retry_event'],
        );
        final snapshot = createSnapshot(recoveryPlan: plan);

        // Attempt 1 at t=10000
        final eval1 = coordinator.evaluate(snapshot: snapshot, nowMs: 10000);
        expect(
          eval1.action,
          VGStreamingPlaybackResilienceDecisionAction.scheduleRetry,
        );
        expect(eval1.canRetryNow, isTrue);
        coordinator.recordHostRetryAttempted(
          nowMs: 10000,
          decision: eval1.decision,
        );

        // Evaluate immediately at t=10100 (cooldown active: 1000ms minimum delay)
        final evalDelay = coordinator.evaluate(
          snapshot: snapshot,
          nowMs: 10100,
        );
        expect(
          evalDelay.action,
          VGStreamingPlaybackResilienceDecisionAction.waitForRetryDelay,
        );
        expect(evalDelay.canRetryNow, isFalse);
        expect(evalDelay.retryAfterMs, 900); // 1000 - (10100 - 10000)

        // Attempt 2 at t=11500 (cooldown satisfied)
        final eval2 = coordinator.evaluate(snapshot: snapshot, nowMs: 11500);
        expect(
          eval2.action,
          VGStreamingPlaybackResilienceDecisionAction.scheduleRetry,
        );
        expect(eval2.canRetryNow, isTrue);
        coordinator.recordHostRetryAttempted(
          nowMs: 11500,
          decision: eval2.decision,
        );

        // Attempt 3 at t=13000 (budget exhausted: maxAttempts=2 in 60s window)
        final eval3 = coordinator.evaluate(snapshot: snapshot, nowMs: 13000);
        expect(
          eval3.action,
          VGStreamingPlaybackResilienceDecisionAction.retryBlocked,
        );
        expect(eval3.canRetryNow, isFalse);
        expect(eval3.shouldRecordAttemptOnHostRetry, isFalse);
        expect(eval3.retryBudget.attemptsInWindow, 2);
        expect(eval3.retryBudget.remainingAttempts, 0);
        expect(eval3.reasons, contains('retry_blocked_budget_exhausted'));
      },
    );

    test(
      '7. Housekeeping automatically prunes expired attempts during evaluate',
      () {
        final coordinator = VGStreamingPlaybackResilienceCoordinator(
          config: const VGStreamingPlaybackResilienceCoordinatorConfig(
            retryBudgetConfig: VGStreamingPlaybackRetryBudgetConfig(
              maxAttempts: 2,
              windowMs: 50000,
            ),
            streamKey: 'stream_prune',
          ),
        );

        // Record old attempts at t=10000 and t=20000
        coordinator.journal.recordNow(
          nowMs: 10000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'stream_prune',
        );
        coordinator.journal.recordNow(
          nowMs: 20000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'stream_prune',
        );
        expect(coordinator.length, 2);

        final plan = createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          shouldReopenPlayback: true,
          canBuildPlaybackOptions: true,
          playbackOptions: createOptions(),
        );
        final snapshot = createSnapshot(recoveryPlan: plan);

        // Evaluate at t=75000 (windowMs=50000 -> cutoff is 25000, so t=10000 and t=20000 are pruned)
        final eval = coordinator.evaluate(snapshot: snapshot, nowMs: 75000);
        expect(
          eval.action,
          VGStreamingPlaybackResilienceDecisionAction.scheduleRetry,
        );
        expect(coordinator.length, 0); // Both pruned by evaluate housekeeping
        expect(eval.retryBudget.attemptsInWindow, 0);
        expect(eval.retryBudget.remainingAttempts, 1);
      },
    );

    test('8. Clear, clearStream, and journalSnapshot operations', () {
      final coordinator = VGStreamingPlaybackResilienceCoordinator();
      coordinator.journal.recordNow(
        nowMs: 1000,
        intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        streamKey: 'stream_A',
      );
      coordinator.journal.recordNow(
        nowMs: 2000,
        intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        streamKey: 'stream_A',
      );
      coordinator.journal.recordNow(
        nowMs: 3000,
        intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        streamKey: 'stream_B',
      );
      expect(coordinator.length, 3);

      // Snapshot tests
      expect(coordinator.journalSnapshot(streamKey: 'stream_A').count, 2);
      expect(coordinator.journalSnapshot(streamKey: 'stream_B').count, 1);

      // Clear single stream
      final removed = coordinator.clearStream('stream_A');
      expect(removed, 2);
      expect(coordinator.length, 1);
      expect(coordinator.journalSnapshot(streamKey: 'stream_A').count, 0);
      expect(coordinator.journalSnapshot(streamKey: 'stream_B').count, 1);

      // Clear all
      coordinator.clear();
      expect(coordinator.length, 0);
      expect(coordinator.isEmpty, isTrue);
    });

    test('9. Evaluation JSON serialization and diagnostics completeness', () {
      final coordinator = VGStreamingPlaybackResilienceCoordinator();
      final options = createOptions();
      final plan = createPlan(
        intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        urgency: VGStreamingPlaybackRecoveryUrgency.active,
        shouldReopenPlayback: true,
        canBuildPlaybackOptions: true,
        playbackOptions: options,
        resumePositionMs: 12000,
        reasons: ['test_reason'],
      );
      final snapshot = createSnapshot(recoveryPlan: plan);

      final eval = coordinator.evaluate(
        snapshot: snapshot,
        nowMs: 50000,
        streamKey: 'test_stream',
      );
      final json = eval.toJson();

      expect(json['snapshot'], isA<Map<String, Object?>>());
      expect(json['retryBudget'], isA<Map<String, Object?>>());
      expect(json['decision'], isA<Map<String, Object?>>());
      expect(json['journalSnapshot'], isA<Map<String, Object?>>());
      expect(json['advisoryOnly'], isTrue);
      expect(json['playbackMutation'], isFalse);
      expect(json['diagnostics'], isA<Map<String, Object?>>());

      final diag = eval.diagnostics;
      expect(diag['action'], 'scheduleRetry');
      expect(diag['streamKey'], 'test_stream');
      expect(diag['canRetryNow'], isTrue);
      expect(diag['shouldRecordAttemptOnHostRetry'], isTrue);
      expect(diag['advisoryOnly'], isTrue);
      expect(diag['playbackMutation'], isFalse);

      expect(
        eval.toString(),
        contains('VGStreamingPlaybackResilienceCoordinatorEvaluation'),
      );
    });
  });
}
