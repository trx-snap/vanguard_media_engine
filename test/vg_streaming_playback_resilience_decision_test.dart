// Copyright (c) Connects — Vanguard Phase 4C7AU.
// Public streaming playback resilience decision planner unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackResilienceDecisionPlanner', () {
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
    }) {
      return VGStreamingPlaybackStatusSummary(
        hasSession: true,
        isLive: false,
        isSeekable: true,
        isPlaying: isPlaying,
        isBufferingOrOpening: false,
        isTerminal: false,
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

    // Helper to create mock resilience snapshot
    VGStreamingPlaybackResilienceSnapshot createSnapshot({
      VGStreamingPlaybackStatusSummary? status,
      VGStreamingPlaybackHealthAdvice? healthAdvice,
      VGStreamingPlaybackRecoveryPlan? recoveryPlan,
      int historyLength = 4,
      bool advisoryOnly = true,
      bool playbackMutation = false,
    }) {
      final stat = status ?? createSummary();
      final adv = healthAdvice ?? createAdvice();
      final plan = recoveryPlan ?? createPlan();
      return VGStreamingPlaybackResilienceSnapshot(
        status: stat,
        healthAdvice: adv,
        recoveryPlan: plan,
        historyLength: historyLength,
        advisoryOnly: advisoryOnly,
        playbackMutation: playbackMutation,
        diagnostics: const {'snapshot': true},
      );
    }

    // Helper to create mock retry budget result
    VGStreamingPlaybackRetryBudgetResult createBudgetResult({
      VGStreamingPlaybackRetryBudgetDecision decision =
          VGStreamingPlaybackRetryBudgetDecision.allow,
      bool canRetry = true,
      int attemptsInWindow = 0,
      int remainingAttempts = 3,
      int retryAfterMs = 0,
      bool advisoryOnly = true,
      bool playbackMutation = false,
      List<VGStreamingPlaybackRetryBudgetReason> reasons = const [
        VGStreamingPlaybackRetryBudgetReason.attemptBudgetAvailable,
      ],
      List<String> reasonCodes = const ['attempt_budget_available'],
    }) {
      return VGStreamingPlaybackRetryBudgetResult(
        decision: decision,
        canRetry: canRetry,
        attemptsInWindow: attemptsInWindow,
        remainingAttempts: remainingAttempts,
        retryAfterMs: retryAfterMs,
        advisoryOnly: advisoryOnly,
        playbackMutation: playbackMutation,
        reasons: reasons,
        reasonCodes: reasonCodes,
        diagnostics: const {'budget': true},
      );
    }

    test('1. observe for healthy/no-op recovery', () {
      final snapshot = createSnapshot(
        recoveryPlan: createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.none,
          urgency: VGStreamingPlaybackRecoveryUrgency.none,
          reasons: const ['healthy_signal'],
        ),
      );
      final budget = createBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.notRetryable,
        canRetry: false,
        reasons: const [
          VGStreamingPlaybackRetryBudgetReason.recoveryDoesNotReopen,
        ],
        reasonCodes: const ['recovery_does_not_reopen'],
      );

      final decision = VGStreamingPlaybackResilienceDecisionPlanner.decide(
        VGStreamingPlaybackResilienceDecisionRequest(
          snapshot: snapshot,
          retryBudget: budget,
        ),
      );

      expect(
        decision.action,
        equals(VGStreamingPlaybackResilienceDecisionAction.observe),
      );
      expect(decision.canRetryNow, isFalse);
      expect(decision.shouldRecordAttemptOnHostRetry, isFalse);
      expect(decision.requiresHostAction, isFalse);
      expect(decision.retryAfterMs, equals(0));
      expect(decision.playbackOptions, isNull);
      expect(decision.resumePositionMs, isNull);
      expect(decision.reasons, contains('healthy_signal'));
      expect(decision.reasons, contains('recovery_does_not_reopen'));
      expect(decision.reasons, contains('observe_healthy_playback'));
    });

    test('2. showBuffering for wait-for-buffer recovery', () {
      final snapshot = createSnapshot(
        recoveryPlan: createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.waitForBuffer,
          urgency: VGStreamingPlaybackRecoveryUrgency.passive,
          reasons: const ['wait_for_buffer_recovery'],
        ),
      );
      final budget = createBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.notRetryable,
        canRetry: false,
        reasons: const [
          VGStreamingPlaybackRetryBudgetReason.recoveryDoesNotReopen,
        ],
        reasonCodes: const ['recovery_does_not_reopen'],
      );

      final decision = VGStreamingPlaybackResilienceDecisionPlanner.decide(
        VGStreamingPlaybackResilienceDecisionRequest(
          snapshot: snapshot,
          retryBudget: budget,
        ),
      );

      expect(
        decision.action,
        equals(VGStreamingPlaybackResilienceDecisionAction.showBuffering),
      );
      expect(decision.canRetryNow, isFalse);
      expect(decision.shouldRecordAttemptOnHostRetry, isFalse);
      expect(decision.requiresHostAction, isFalse);
      expect(decision.retryAfterMs, equals(0));
      expect(decision.playbackOptions, isNull);
      expect(decision.resumePositionMs, isNull);
      expect(decision.reasons, contains('wait_for_buffer_recovery'));
      expect(decision.reasons, contains('show_buffering_active'));
    });

    test('3. hostActionRequired wins over retry budget', () {
      final options = createOptions();
      final snapshot = createSnapshot(
        recoveryPlan: createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryConstrainedProfile,
          urgency: VGStreamingPlaybackRecoveryUrgency.active,
          requiresHostAction: true,
          shouldReopenPlayback: true,
          canBuildPlaybackOptions: true,
          playbackOptions: options,
          resumePositionMs: 15000,
          reasons: const ['prefer_constrained_profile_planned'],
        ),
      );
      // Even if retry budget reports allow, host action required must win
      final budget = createBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.allow,
        canRetry: true,
        reasons: const [
          VGStreamingPlaybackRetryBudgetReason.attemptBudgetAvailable,
        ],
        reasonCodes: const ['attempt_budget_available'],
      );

      final decision = VGStreamingPlaybackResilienceDecisionPlanner.decide(
        VGStreamingPlaybackResilienceDecisionRequest(
          snapshot: snapshot,
          retryBudget: budget,
        ),
      );

      expect(
        decision.action,
        equals(VGStreamingPlaybackResilienceDecisionAction.hostActionRequired),
      );
      expect(decision.canRetryNow, isFalse);
      expect(decision.shouldRecordAttemptOnHostRetry, isFalse);
      expect(decision.requiresHostAction, isTrue);
      expect(decision.retryAfterMs, equals(0));
      expect(decision.playbackOptions, equals(options));
      expect(decision.resumePositionMs, equals(15000));
      expect(decision.reasons, contains('prefer_constrained_profile_planned'));
      expect(decision.reasons, contains('host_action_required_planned'));
    });

    test(
      '4. scheduleRetry carries options/resume position and sets shouldRecordAttemptOnHostRetry=true',
      () {
        final options = createOptions();
        final snapshot = createSnapshot(
          recoveryPlan: createPlan(
            intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
            urgency: VGStreamingPlaybackRecoveryUrgency.active,
            requiresHostAction: false,
            shouldReopenPlayback: true,
            canBuildPlaybackOptions: true,
            playbackOptions: options,
            resumePositionMs: 22000,
            reasons: const ['retry_playback_reopen_planned'],
          ),
        );
        final budget = createBudgetResult(
          decision: VGStreamingPlaybackRetryBudgetDecision.allow,
          canRetry: true,
          attemptsInWindow: 1,
          remainingAttempts: 2,
          reasons: const [
            VGStreamingPlaybackRetryBudgetReason.attemptBudgetAvailable,
          ],
          reasonCodes: const ['attempt_budget_available'],
        );

        final decision = VGStreamingPlaybackResilienceDecisionPlanner.decide(
          VGStreamingPlaybackResilienceDecisionRequest(
            snapshot: snapshot,
            retryBudget: budget,
            streamKey: 'stream_vod_1',
          ),
        );

        expect(
          decision.action,
          equals(VGStreamingPlaybackResilienceDecisionAction.scheduleRetry),
        );
        expect(decision.canRetryNow, isTrue);
        expect(decision.shouldRecordAttemptOnHostRetry, isTrue);
        expect(decision.requiresHostAction, isFalse);
        expect(decision.retryAfterMs, equals(0));
        expect(decision.playbackOptions, equals(options));
        expect(decision.resumePositionMs, equals(22000));
        expect(decision.reasons, contains('retry_playback_reopen_planned'));
        expect(decision.reasons, contains('attempt_budget_available'));
        expect(decision.reasons, contains('schedule_retry_permitted'));
      },
    );

    test('5. waitForRetryDelay carries retryAfterMs', () {
      final options = createOptions();
      final snapshot = createSnapshot(
        recoveryPlan: createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          urgency: VGStreamingPlaybackRecoveryUrgency.active,
          requiresHostAction: false,
          shouldReopenPlayback: true,
          canBuildPlaybackOptions: true,
          playbackOptions: options,
          resumePositionMs: 5000,
          reasons: const ['retry_playback_reopen_planned'],
        ),
      );
      final budget = createBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.delay,
        canRetry: false,
        retryAfterMs: 450,
        reasons: const [
          VGStreamingPlaybackRetryBudgetReason.minimumDelayNotElapsed,
        ],
        reasonCodes: const ['minimum_delay_not_elapsed'],
      );

      final decision = VGStreamingPlaybackResilienceDecisionPlanner.decide(
        VGStreamingPlaybackResilienceDecisionRequest(
          snapshot: snapshot,
          retryBudget: budget,
        ),
      );

      expect(
        decision.action,
        equals(VGStreamingPlaybackResilienceDecisionAction.waitForRetryDelay),
      );
      expect(decision.canRetryNow, isFalse);
      expect(decision.shouldRecordAttemptOnHostRetry, isFalse);
      expect(decision.requiresHostAction, isFalse);
      expect(decision.retryAfterMs, equals(450));
      expect(decision.playbackOptions, equals(options));
      expect(decision.resumePositionMs, equals(5000));
      expect(decision.reasons, contains('minimum_delay_not_elapsed'));
      expect(decision.reasons, contains('wait_for_retry_delay_active'));
    });

    test('6. retryBlocked for exhausted/blocked budget', () {
      final options = createOptions();
      final snapshot = createSnapshot(
        recoveryPlan: createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          urgency: VGStreamingPlaybackRecoveryUrgency.active,
          requiresHostAction: false,
          shouldReopenPlayback: true,
          canBuildPlaybackOptions: true,
          playbackOptions: options,
          resumePositionMs: 5000,
          reasons: const ['retry_playback_reopen_planned'],
        ),
      );
      final budget = createBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.block,
        canRetry: false,
        attemptsInWindow: 3,
        remainingAttempts: 0,
        retryAfterMs: 45000,
        reasons: const [
          VGStreamingPlaybackRetryBudgetReason.attemptBudgetExhausted,
        ],
        reasonCodes: const ['attempt_budget_exhausted'],
      );

      final decision = VGStreamingPlaybackResilienceDecisionPlanner.decide(
        VGStreamingPlaybackResilienceDecisionRequest(
          snapshot: snapshot,
          retryBudget: budget,
        ),
      );

      expect(
        decision.action,
        equals(VGStreamingPlaybackResilienceDecisionAction.retryBlocked),
      );
      expect(decision.canRetryNow, isFalse);
      expect(decision.shouldRecordAttemptOnHostRetry, isFalse);
      expect(decision.requiresHostAction, isFalse);
      expect(decision.retryAfterMs, equals(45000));
      expect(decision.playbackOptions, equals(options));
      expect(decision.resumePositionMs, equals(5000));
      expect(decision.reasons, contains('attempt_budget_exhausted'));
      expect(decision.reasons, contains('retry_blocked_budget_exhausted'));
    });

    test('7. stopTerminal for terminal recovery intent', () {
      final snapshot = createSnapshot(
        recoveryPlan: createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.stopTerminal,
          urgency: VGStreamingPlaybackRecoveryUrgency.none,
          reasons: const ['terminal_do_not_retry'],
        ),
      );
      final budget = createBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.notRetryable,
        canRetry: false,
        reasons: const [VGStreamingPlaybackRetryBudgetReason.terminalStop],
        reasonCodes: const ['terminal_stop'],
      );

      final decision = VGStreamingPlaybackResilienceDecisionPlanner.decide(
        VGStreamingPlaybackResilienceDecisionRequest(
          snapshot: snapshot,
          retryBudget: budget,
        ),
      );

      expect(
        decision.action,
        equals(VGStreamingPlaybackResilienceDecisionAction.stopTerminal),
      );
      expect(decision.canRetryNow, isFalse);
      expect(decision.shouldRecordAttemptOnHostRetry, isFalse);
      expect(decision.requiresHostAction, isFalse);
      expect(decision.retryAfterMs, equals(0));
      expect(decision.playbackOptions, isNull);
      expect(decision.resumePositionMs, isNull);
      expect(decision.reasons, contains('terminal_do_not_retry'));
      expect(decision.reasons, contains('terminal_stop'));
      expect(decision.reasons, contains('stop_terminal_planned'));
    });

    test('8. reasons are de-duplicated and preserve order', () {
      final snapshot = createSnapshot(
        recoveryPlan: createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          urgency: VGStreamingPlaybackRecoveryUrgency.active,
          requiresHostAction: false,
          shouldReopenPlayback: true,
          canBuildPlaybackOptions: true,
          playbackOptions: createOptions(),
          resumePositionMs: 1000,
          reasons: const ['reason_alpha', 'reason_shared'],
        ),
      );
      final budget = createBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.allow,
        canRetry: true,
        reasons: const [
          VGStreamingPlaybackRetryBudgetReason.attemptBudgetAvailable,
        ],
        reasonCodes: const ['reason_shared', 'reason_beta'],
      );

      final decision = VGStreamingPlaybackResilienceDecisionPlanner.decide(
        VGStreamingPlaybackResilienceDecisionRequest(
          snapshot: snapshot,
          retryBudget: budget,
        ),
      );

      expect(decision.reasons, [
        'reason_alpha',
        'reason_shared',
        'reason_beta',
        'schedule_retry_permitted',
      ]);
      expect(decision.warnings, equals(decision.reasons));
    });

    test('9. diagnostics include key fields and JSON serializes', () {
      final options = createOptions();
      final snapshot = createSnapshot(
        recoveryPlan: createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          urgency: VGStreamingPlaybackRecoveryUrgency.active,
          requiresHostAction: false,
          shouldReopenPlayback: true,
          canBuildPlaybackOptions: true,
          playbackOptions: options,
          resumePositionMs: 12345,
          reasons: const ['retry_reason'],
        ),
      );
      final budget = createBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.allow,
        canRetry: true,
        attemptsInWindow: 1,
        remainingAttempts: 2,
        reasons: const [
          VGStreamingPlaybackRetryBudgetReason.attemptBudgetAvailable,
        ],
        reasonCodes: const ['attempt_budget_available'],
      );

      final request = VGStreamingPlaybackResilienceDecisionRequest(
        snapshot: snapshot,
        retryBudget: budget,
        streamKey: 'live_main',
      );

      final decision = VGStreamingPlaybackResilienceDecisionPlanner.decide(
        request,
      );

      // Diagnostics check
      final diag = decision.diagnostics;
      expect(
        diag['action'],
        equals(VGStreamingPlaybackResilienceDecisionAction.scheduleRetry.name),
      );
      expect(diag['streamKey'], equals('live_main'));
      expect(
        diag['recoveryIntent'],
        equals(VGStreamingPlaybackRecoveryIntent.retryCurrentProfile.name),
      );
      expect(
        diag['recoveryUrgency'],
        equals(VGStreamingPlaybackRecoveryUrgency.active.name),
      );
      expect(diag['canRetryNow'], isTrue);
      expect(diag['shouldRecordAttemptOnHostRetry'], isTrue);
      expect(diag['requiresHostAction'], isFalse);
      expect(diag['retryAfterMs'], equals(0));
      expect(diag['attemptsInWindow'], equals(1));
      expect(diag['remainingAttempts'], equals(2));
      expect(
        diag['budgetDecision'],
        equals(VGStreamingPlaybackRetryBudgetDecision.allow.name),
      );
      expect(diag['advisoryOnly'], isTrue);
      expect(diag['playbackMutation'], isFalse);
      expect(diag['reasons'], contains('schedule_retry_permitted'));

      // Serialization checks
      final json = decision.toJson();
      expect(
        json['action'],
        equals(VGStreamingPlaybackResilienceDecisionAction.scheduleRetry.name),
      );
      expect(json['canRetryNow'], isTrue);
      expect(json['shouldRecordAttemptOnHostRetry'], isTrue);
      expect(json['requiresHostAction'], isFalse);
      expect(json['retryAfterMs'], equals(0));
      expect(
        json['recoveryIntent'],
        equals(VGStreamingPlaybackRecoveryIntent.retryCurrentProfile.name),
      );
      expect(
        json['recoveryUrgency'],
        equals(VGStreamingPlaybackRecoveryUrgency.active.name),
      );
      expect(json['playbackOptions'], isNotNull);
      expect(json['resumePositionMs'], equals(12345));
      expect(json['advisoryOnly'], isTrue);
      expect(json['playbackMutation'], isFalse);
      expect((json['reasons'] as List).isNotEmpty, isTrue);

      expect(
        decision.toString(),
        contains('VGStreamingPlaybackResilienceDecision'),
      );
      expect(
        request.toString(),
        contains('VGStreamingPlaybackResilienceDecisionRequest'),
      );
      expect(request.toJson()['streamKey'], equals('live_main'));
    });

    test(
      '10. invariant rejection returns retryBlocked when non-advisory/mutating input is supplied',
      () {
        // Case A: Plan inside snapshot has playbackMutation = true
        final mutatingPlan = createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          playbackMutation: true,
        );
        final snapshotMutatingPlan = createSnapshot(recoveryPlan: mutatingPlan);
        final budget = createBudgetResult();

        final decisionMutating =
            VGStreamingPlaybackResilienceDecisionPlanner.decide(
              VGStreamingPlaybackResilienceDecisionRequest(
                snapshot: snapshotMutatingPlan,
                retryBudget: budget,
              ),
            );

        expect(
          decisionMutating.action,
          equals(VGStreamingPlaybackResilienceDecisionAction.retryBlocked),
        );
        expect(decisionMutating.canRetryNow, isFalse);
        expect(decisionMutating.shouldRecordAttemptOnHostRetry, isFalse);
        expect(
          decisionMutating.reasons,
          contains('mutation_invariant_rejected'),
        );
        expect(
          decisionMutating.diagnostics['invariantViolation'],
          equals(true),
        );

        // Case B: Plan inside snapshot has advisoryOnly = false
        final nonAdvisoryPlan = createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          advisoryOnly: false,
        );
        final snapshotNonAdvisoryPlan = createSnapshot(
          recoveryPlan: nonAdvisoryPlan,
        );

        final decisionNonAdvisory =
            VGStreamingPlaybackResilienceDecisionPlanner.decide(
              VGStreamingPlaybackResilienceDecisionRequest(
                snapshot: snapshotNonAdvisoryPlan,
                retryBudget: budget,
              ),
            );

        expect(
          decisionNonAdvisory.action,
          equals(VGStreamingPlaybackResilienceDecisionAction.retryBlocked),
        );
        expect(decisionNonAdvisory.canRetryNow, isFalse);
        expect(
          decisionNonAdvisory.reasons,
          contains('mutation_invariant_rejected'),
        );

        // Case C: Budget has advisoryOnly = false
        final nonAdvisoryBudget = createBudgetResult(advisoryOnly: false);
        final snapshotNormal = createSnapshot();

        final decisionNonAdvisoryBudget =
            VGStreamingPlaybackResilienceDecisionPlanner.decide(
              VGStreamingPlaybackResilienceDecisionRequest(
                snapshot: snapshotNormal,
                retryBudget: nonAdvisoryBudget,
              ),
            );

        expect(
          decisionNonAdvisoryBudget.action,
          equals(VGStreamingPlaybackResilienceDecisionAction.retryBlocked),
        );
        expect(decisionNonAdvisoryBudget.canRetryNow, isFalse);
        expect(
          decisionNonAdvisoryBudget.reasons,
          contains('mutation_invariant_rejected'),
        );

        // Case D: Request constructor asserts on mutating snapshot / budget
        final mutatingSnapshot = createSnapshot(playbackMutation: true);
        expect(
          () => VGStreamingPlaybackResilienceDecisionRequest(
            snapshot: mutatingSnapshot,
            retryBudget: budget,
          ),
          throwsAssertionError,
        );

        final mutatingBudget = createBudgetResult(playbackMutation: true);
        expect(
          () => VGStreamingPlaybackResilienceDecisionRequest(
            snapshot: snapshotNormal,
            retryBudget: mutatingBudget,
          ),
          throwsAssertionError,
        );
      },
    );
  });
}
