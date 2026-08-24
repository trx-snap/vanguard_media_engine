// Copyright (c) Connects — Vanguard Phase 4C7AQ.
// Public streaming playback retry budget planner unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackRetryBudgetPlanner', () {
    // Helper to create mock playback options
    VGStreamingPlaybackOptions createOptions({
      VGStreamingNetworkProfile networkProfile =
          VGStreamingNetworkProfile.constrained,
    }) {
      return VGStreamingPlaybackOptions(
        uri: Uri.parse('https://cdn.example.com/live/master.m3u8'),
        initialWidth: 1080,
        initialHeight: 1920,
        networkProfile: networkProfile,
      );
    }

    // Helper to create mock recovery plan
    VGStreamingPlaybackRecoveryPlan createPlan({
      VGStreamingPlaybackRecoveryIntent intent =
          VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
      VGStreamingPlaybackRecoveryUrgency urgency =
          VGStreamingPlaybackRecoveryUrgency.active,
      bool shouldReopenPlayback = true,
      bool requiresHostAction = true,
      bool canBuildPlaybackOptions = true,
      VGStreamingPlaybackOptions? playbackOptions,
      int? resumePositionMs,
      int retryDelayMs = 750,
      bool advisoryOnly = true,
      bool playbackMutation = false,
      List<String> reasons = const ['test_reason'],
    }) {
      return VGStreamingPlaybackRecoveryPlan(
        intent: intent,
        urgency: urgency,
        shouldReopenPlayback: shouldReopenPlayback,
        requiresHostAction: requiresHostAction,
        canBuildPlaybackOptions: canBuildPlaybackOptions,
        playbackOptions: playbackOptions ?? createOptions(),
        resumePositionMs: resumePositionMs,
        retryDelayMs: retryDelayMs,
        advisoryOnly: advisoryOnly,
        playbackMutation: playbackMutation,
        reasons: reasons,
      );
    }

    test('1. Config and attempt model validation and defaults', () {
      // Default config
      const defaultConfig = VGStreamingPlaybackRetryBudgetConfig();
      expect(defaultConfig.maxAttempts, equals(3));
      expect(defaultConfig.windowMs, equals(120000));
      expect(defaultConfig.minimumDelayMs, equals(750));
      expect(defaultConfig.blockTerminalStop, isTrue);
      expect(defaultConfig.requirePlaybackOptionsForReopen, isTrue);
      expect(defaultConfig.requireHostActionRespect, isTrue);

      // Attempt model validation
      const attempt = VGStreamingPlaybackRetryAttempt(
        timestampMs: 1000,
        intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        streamKey: 'stream_1',
        reason: 'network_rebuffer',
      );
      expect(attempt.timestampMs, equals(1000));
      expect(
        attempt.intent,
        equals(VGStreamingPlaybackRecoveryIntent.retryCurrentProfile),
      );
      expect(attempt.streamKey, equals('stream_1'));
      expect(attempt.reason, equals('network_rebuffer'));

      // Assertions on negative values
      expect(
        () => VGStreamingPlaybackRetryBudgetConfig(maxAttempts: 0),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingPlaybackRetryBudgetConfig(windowMs: 0),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingPlaybackRetryBudgetConfig(minimumDelayMs: -1),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingPlaybackRetryAttempt(
          timestampMs: -1,
          intent: VGStreamingPlaybackRecoveryIntent.none,
        ),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingPlaybackRetryBudgetRequest(
          recoveryPlan: createPlan(),
          nowMs: -1,
        ),
        throwsAssertionError,
      );
    });

    test('2. Invariants hold across all evaluations', () {
      final plan = createPlan();
      final request = VGStreamingPlaybackRetryBudgetRequest(
        recoveryPlan: plan,
        nowMs: 10000,
      );
      final result = VGStreamingPlaybackRetryBudgetPlanner.evaluate(request);

      expect(result.advisoryOnly, isTrue);
      expect(result.playbackMutation, isFalse);
      expect(result.diagnostics['advisoryOnly'], isTrue);
      expect(result.diagnostics['playbackMutation'], isFalse);
    });

    test('3. Non-advisory or mutating recovery plan is blocked', () {
      // Non-advisory plan
      final nonAdvisoryPlan = createPlan(advisoryOnly: false);
      final req1 = VGStreamingPlaybackRetryBudgetRequest(
        recoveryPlan: nonAdvisoryPlan,
        nowMs: 10000,
      );
      final res1 = VGStreamingPlaybackRetryBudgetPlanner.evaluate(req1);
      expect(
        res1.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.block),
      );
      expect(res1.canRetry, isFalse);
      expect(
        res1.reasons,
        contains(VGStreamingPlaybackRetryBudgetReason.advisoryOnly),
      );
      expect(res1.reasonCodes, contains('recovery_plan_mutation_rejected'));

      // Mutating plan
      final mutatingPlan = createPlan(playbackMutation: true);
      final req2 = VGStreamingPlaybackRetryBudgetRequest(
        recoveryPlan: mutatingPlan,
        nowMs: 10000,
      );
      final res2 = VGStreamingPlaybackRetryBudgetPlanner.evaluate(req2);
      expect(
        res2.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.block),
      );
      expect(res2.canRetry, isFalse);
      expect(
        res2.reasons,
        contains(VGStreamingPlaybackRetryBudgetReason.advisoryOnly),
      );
    });

    test(
      '4. Non-reopening intents (none, waitForBuffer) return notRetryable',
      () {
        // Intent: none
        final planNone = createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.none,
          shouldReopenPlayback: false,
        );
        final resNone = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
          VGStreamingPlaybackRetryBudgetRequest(
            recoveryPlan: planNone,
            nowMs: 10000,
          ),
        );
        expect(
          resNone.decision,
          equals(VGStreamingPlaybackRetryBudgetDecision.notRetryable),
        );
        expect(resNone.canRetry, isFalse);
        expect(
          resNone.reasons,
          contains(VGStreamingPlaybackRetryBudgetReason.recoveryDoesNotReopen),
        );
        expect(resNone.reasonCodes, contains('recovery_does_not_reopen'));

        // Intent: waitForBuffer
        final planWait = createPlan(
          intent: VGStreamingPlaybackRecoveryIntent.waitForBuffer,
          shouldReopenPlayback: false,
        );
        final resWait = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
          VGStreamingPlaybackRetryBudgetRequest(
            recoveryPlan: planWait,
            nowMs: 10000,
          ),
        );
        expect(
          resWait.decision,
          equals(VGStreamingPlaybackRetryBudgetDecision.notRetryable),
        );
        expect(resWait.canRetry, isFalse);
        expect(
          resWait.reasons,
          contains(VGStreamingPlaybackRetryBudgetReason.recoveryDoesNotReopen),
        );
      },
    );

    test('5. Terminal stop intent returns notRetryable when blocked', () {
      final planTerminal = createPlan(
        intent: VGStreamingPlaybackRecoveryIntent.stopTerminal,
        shouldReopenPlayback: false,
      );

      // Default: blockTerminalStop = true
      final resBlocked = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
        VGStreamingPlaybackRetryBudgetRequest(
          recoveryPlan: planTerminal,
          nowMs: 10000,
        ),
      );
      expect(
        resBlocked.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.notRetryable),
      );
      expect(resBlocked.canRetry, isFalse);
      expect(
        resBlocked.reasons,
        contains(VGStreamingPlaybackRetryBudgetReason.terminalStop),
      );
      expect(resBlocked.reasonCodes, contains('terminal_stop'));
    });

    test('6. shouldReopenPlayback == false returns notRetryable', () {
      final planNoReopen = createPlan(
        intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        shouldReopenPlayback: false,
      );
      final res = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
        VGStreamingPlaybackRetryBudgetRequest(
          recoveryPlan: planNoReopen,
          nowMs: 10000,
        ),
      );
      expect(
        res.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.notRetryable),
      );
      expect(res.canRetry, isFalse);
      expect(
        res.reasons,
        contains(VGStreamingPlaybackRetryBudgetReason.recoveryDoesNotReopen),
      );
    });

    test('7. Missing playback options blocks reopen when required', () {
      final planNoOptions = VGStreamingPlaybackRecoveryPlan(
        intent: VGStreamingPlaybackRecoveryIntent.retryConstrainedProfile,
        urgency: VGStreamingPlaybackRecoveryUrgency.active,
        shouldReopenPlayback: true,
        requiresHostAction: true,
        canBuildPlaybackOptions: false,
        playbackOptions: null,
        retryDelayMs: 750,
      );

      final res = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
        VGStreamingPlaybackRetryBudgetRequest(
          recoveryPlan: planNoOptions,
          config: const VGStreamingPlaybackRetryBudgetConfig(
            requirePlaybackOptionsForReopen: true,
          ),
          nowMs: 10000,
        ),
      );
      expect(
        res.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.block),
      );
      expect(res.canRetry, isFalse);
      expect(
        res.reasons,
        contains(VGStreamingPlaybackRetryBudgetReason.recoveryNotRetryable),
      );
      expect(res.reasonCodes, contains('missing_playback_options'));
    });

    test(
      '8. Budget available allows retry and calculates remaining attempts',
      () {
        final plan = createPlan();

        // Case A: 0 prior attempts (fresh budget, maxAttempts = 3)
        final resFresh = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
          VGStreamingPlaybackRetryBudgetRequest(
            recoveryPlan: plan,
            recentAttempts: const [],
            nowMs: 50000,
          ),
        );
        expect(
          resFresh.decision,
          equals(VGStreamingPlaybackRetryBudgetDecision.allow),
        );
        expect(resFresh.canRetry, isTrue);
        expect(resFresh.attemptsInWindow, equals(0));
        expect(resFresh.remainingAttempts, equals(2)); // 3 - 0 - 1 = 2
        expect(resFresh.retryAfterMs, equals(0));
        expect(
          resFresh.reasons,
          contains(VGStreamingPlaybackRetryBudgetReason.attemptBudgetAvailable),
        );
        expect(resFresh.reasonCodes, contains('attempt_budget_available'));

        // Case B: 1 prior attempt at nowMs - 5000 (delay elapsed, 1 in window)
        final resOne = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
          VGStreamingPlaybackRetryBudgetRequest(
            recoveryPlan: plan,
            recentAttempts: [
              const VGStreamingPlaybackRetryAttempt(
                timestampMs: 45000,
                intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
              ),
            ],
            nowMs: 50000,
          ),
        );
        expect(
          resOne.decision,
          equals(VGStreamingPlaybackRetryBudgetDecision.allow),
        );
        expect(resOne.canRetry, isTrue);
        expect(resOne.attemptsInWindow, equals(1));
        expect(resOne.remainingAttempts, equals(1)); // 3 - 1 - 1 = 1
        expect(resOne.retryAfterMs, equals(0));

        // Case C: 2 prior attempts at nowMs - 10000, nowMs - 5000 (delay elapsed, 2 in window)
        final resTwo = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
          VGStreamingPlaybackRetryBudgetRequest(
            recoveryPlan: plan,
            recentAttempts: [
              const VGStreamingPlaybackRetryAttempt(
                timestampMs: 40000,
                intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
              ),
              const VGStreamingPlaybackRetryAttempt(
                timestampMs: 45000,
                intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
              ),
            ],
            nowMs: 50000,
          ),
        );
        expect(
          resTwo.decision,
          equals(VGStreamingPlaybackRetryBudgetDecision.allow),
        );
        expect(resTwo.canRetry, isTrue);
        expect(resTwo.attemptsInWindow, equals(2));
        expect(resTwo.remainingAttempts, equals(0)); // 3 - 2 - 1 = 0
        expect(resTwo.retryAfterMs, equals(0));
      },
    );

    test('9. Minimum delay not elapsed returns delay and exact retryAfterMs', () {
      final plan = createPlan(retryDelayMs: 1000); // 1000 ms plan cooldown

      // Prior attempt was 300 ms ago at nowMs = 50000 (attempt at 49700)
      final res = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
        VGStreamingPlaybackRetryBudgetRequest(
          recoveryPlan: plan,
          config: const VGStreamingPlaybackRetryBudgetConfig(
            minimumDelayMs: 750,
          ),
          recentAttempts: [
            const VGStreamingPlaybackRetryAttempt(
              timestampMs: 49700,
              intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
            ),
          ],
          nowMs: 50000,
        ),
      );

      expect(
        res.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.delay),
      );
      expect(res.canRetry, isFalse);
      expect(res.attemptsInWindow, equals(1));
      expect(res.remainingAttempts, equals(2)); // 3 - 1 = 2
      // Cooldown = max(750, 1000) = 1000. Elapsed = 300. Remaining delay = 700.
      expect(res.retryAfterMs, equals(700));
      expect(
        res.reasons,
        contains(VGStreamingPlaybackRetryBudgetReason.minimumDelayNotElapsed),
      );
      expect(res.reasonCodes, contains('minimum_delay_not_elapsed'));
      expect(res.diagnostics['requiredCooldownMs'], equals(1000));
      expect(res.diagnostics['elapsedSinceLatestMs'], equals(300));
    });

    test(
      '10. Attempt budget exhausted returns block and retryAfterMs until window expiry',
      () {
        final plan = createPlan();
        // Config: maxAttempts = 3, windowMs = 120000 (2 minutes)
        // Attempts at 10000, 25000, 40000. nowMs = 50000.
        final res = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
          VGStreamingPlaybackRetryBudgetRequest(
            recoveryPlan: plan,
            config: const VGStreamingPlaybackRetryBudgetConfig(
              maxAttempts: 3,
              windowMs: 120000,
            ),
            recentAttempts: [
              const VGStreamingPlaybackRetryAttempt(
                timestampMs: 10000,
                intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
              ),
              const VGStreamingPlaybackRetryAttempt(
                timestampMs: 25000,
                intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
              ),
              const VGStreamingPlaybackRetryAttempt(
                timestampMs: 40000,
                intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
              ),
            ],
            nowMs: 50000,
          ),
        );

        expect(
          res.decision,
          equals(VGStreamingPlaybackRetryBudgetDecision.block),
        );
        expect(res.canRetry, isFalse);
        expect(res.attemptsInWindow, equals(3));
        expect(res.remainingAttempts, equals(0));
        // Earliest attempt in window is 10000. Leaves window at 10000 + 120000 = 130000.
        // retryAfterMs = 130000 - 50000 = 80000.
        expect(res.retryAfterMs, equals(80000));
        expect(
          res.reasons,
          contains(VGStreamingPlaybackRetryBudgetReason.attemptBudgetExhausted),
        );
        expect(res.reasonCodes, contains('attempt_budget_exhausted'));
        expect(res.diagnostics['earliestAttemptMs'], equals(10000));
      },
    );

    test(
      '11. Stream key filtering scopes budget tracking to specific stream',
      () {
        final plan = createPlan();

        // Attempts for streamA and streamB
        final attempts = [
          const VGStreamingPlaybackRetryAttempt(
            timestampMs: 40000,
            intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
            streamKey: 'streamA',
          ),
          const VGStreamingPlaybackRetryAttempt(
            timestampMs: 42000,
            intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
            streamKey: 'streamA',
          ),
          const VGStreamingPlaybackRetryAttempt(
            timestampMs: 44000,
            intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
            streamKey: 'streamA',
          ),
          const VGStreamingPlaybackRetryAttempt(
            timestampMs: 45000,
            intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
            streamKey: 'streamB',
          ),
        ];

        // Request for streamA -> exhausted (3 attempts for streamA)
        final resA = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
          VGStreamingPlaybackRetryBudgetRequest(
            recoveryPlan: plan,
            config: const VGStreamingPlaybackRetryBudgetConfig(maxAttempts: 3),
            recentAttempts: attempts,
            nowMs: 50000,
            streamKey: 'streamA',
          ),
        );
        expect(
          resA.decision,
          equals(VGStreamingPlaybackRetryBudgetDecision.block),
        );
        expect(resA.attemptsInWindow, equals(3));

        // Request for streamB -> allowed (only 1 attempt for streamB, delay elapsed)
        final resB = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
          VGStreamingPlaybackRetryBudgetRequest(
            recoveryPlan: plan,
            config: const VGStreamingPlaybackRetryBudgetConfig(maxAttempts: 3),
            recentAttempts: attempts,
            nowMs: 50000,
            streamKey: 'streamB',
          ),
        );
        expect(
          resB.decision,
          equals(VGStreamingPlaybackRetryBudgetDecision.allow),
        );
        expect(resB.canRetry, isTrue);
        expect(resB.attemptsInWindow, equals(1));
        expect(resB.remainingAttempts, equals(1)); // 3 - 1 - 1 = 1
      },
    );

    test('12. Null stream key counts all attempts across stream keys', () {
      final plan = createPlan();

      final attempts = [
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 40000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 42000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamB',
        ),
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 44000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: null,
        ),
      ];

      final resNullKey = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
        VGStreamingPlaybackRetryBudgetRequest(
          recoveryPlan: plan,
          config: const VGStreamingPlaybackRetryBudgetConfig(maxAttempts: 3),
          recentAttempts: attempts,
          nowMs: 50000,
          streamKey: null,
        ),
      );
      // All 3 attempts counted -> exhausted
      expect(
        resNullKey.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.block),
      );
      expect(resNullKey.attemptsInWindow, equals(3));
    });

    test('13. Old attempts outside rolling window are ignored', () {
      final plan = createPlan();

      // Window is 120000 ms. nowMs = 200000.
      // Window range: [80000, 200000].
      // Attempt 1 at 50000 (outside window)
      // Attempt 2 at 70000 (outside window)
      // Attempt 3 at 90000 (inside window)
      final attempts = [
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 50000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        ),
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 70000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        ),
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 90000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        ),
      ];

      final res = VGStreamingPlaybackRetryBudgetPlanner.evaluate(
        VGStreamingPlaybackRetryBudgetRequest(
          recoveryPlan: plan,
          config: const VGStreamingPlaybackRetryBudgetConfig(
            maxAttempts: 3,
            windowMs: 120000,
          ),
          recentAttempts: attempts,
          nowMs: 200000,
        ),
      );

      // Only 1 attempt is in window.
      expect(
        res.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.allow),
      );
      expect(res.canRetry, isTrue);
      expect(res.attemptsInWindow, equals(1));
      expect(res.remainingAttempts, equals(1)); // 3 - 1 - 1 = 1
    });

    test(
      '14. Pure & deterministic: no mutation of input recentAttempts list',
      () {
        final plan = createPlan();
        final initialAttempts = <VGStreamingPlaybackRetryAttempt>[
          const VGStreamingPlaybackRetryAttempt(
            timestampMs: 40000,
            intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          ),
          const VGStreamingPlaybackRetryAttempt(
            timestampMs: 10000,
            intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          ),
        ];

        final request = VGStreamingPlaybackRetryBudgetRequest(
          recoveryPlan: plan,
          recentAttempts: initialAttempts,
          nowMs: 50000,
        );

        final result = VGStreamingPlaybackRetryBudgetPlanner.evaluate(request);
        expect(result.canRetry, isTrue);

        // Input list must not have changed length or original unsorted order
        expect(initialAttempts.length, equals(2));
        expect(initialAttempts[0].timestampMs, equals(40000));
        expect(initialAttempts[1].timestampMs, equals(10000));
      },
    );

    test(
      '15. Serialization and toString work properly for all models and enums',
      () {
        final plan = createPlan();
        const config = VGStreamingPlaybackRetryBudgetConfig(
          maxAttempts: 4,
          windowMs: 60000,
          minimumDelayMs: 500,
        );
        const attempt = VGStreamingPlaybackRetryAttempt(
          timestampMs: 15000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'hls_primary',
          reason: 'network_drop',
        );

        // Attempt toJson & toString
        final attemptJson = attempt.toJson();
        expect(attemptJson['timestampMs'], equals(15000));
        expect(attemptJson['intent'], equals('retryCurrentProfile'));
        expect(attemptJson['streamKey'], equals('hls_primary'));
        expect(attemptJson['reason'], equals('network_drop'));
        expect(attempt.toString(), contains('VGStreamingPlaybackRetryAttempt'));

        // Config toJson & toString
        final configJson = config.toJson();
        expect(configJson['maxAttempts'], equals(4));
        expect(configJson['windowMs'], equals(60000));
        expect(configJson['minimumDelayMs'], equals(500));
        expect(configJson['blockTerminalStop'], isTrue);
        expect(
          config.toString(),
          contains('VGStreamingPlaybackRetryBudgetConfig'),
        );

        // Request toJson & toString
        final request = VGStreamingPlaybackRetryBudgetRequest(
          recoveryPlan: plan,
          recentAttempts: [attempt],
          config: config,
          nowMs: 20000,
          streamKey: 'hls_primary',
        );
        final reqJson = request.toJson();
        expect(reqJson['nowMs'], equals(20000));
        expect(reqJson['streamKey'], equals('hls_primary'));
        expect((reqJson['recentAttempts'] as List).length, equals(1));
        expect(
          request.toString(),
          contains('VGStreamingPlaybackRetryBudgetRequest'),
        );

        // Result toJson & toString
        final result = VGStreamingPlaybackRetryBudgetPlanner.evaluate(request);
        final resJson = result.toJson();
        expect(resJson['decision'], equals('allow'));
        expect(resJson['canRetry'], isTrue);
        expect(resJson['attemptsInWindow'], equals(1));
        expect(resJson['remainingAttempts'], equals(2)); // 4 - 1 - 1 = 2
        expect(resJson['retryAfterMs'], equals(0));
        expect(resJson['advisoryOnly'], isTrue);
        expect(resJson['playbackMutation'], isFalse);
        expect(resJson['reasons'], contains('attemptBudgetAvailable'));
        expect(resJson['reasonCodes'], contains('attempt_budget_available'));
        expect(result.warnings, equals(result.reasonCodes));
        expect(
          result.toString(),
          contains('VGStreamingPlaybackRetryBudgetResult'),
        );

        // Enums toJson
        expect(
          VGStreamingPlaybackRetryBudgetDecision.allow.toJson(),
          equals('allow'),
        );
        expect(
          VGStreamingPlaybackRetryBudgetDecision.delay.toJson(),
          equals('delay'),
        );
        expect(
          VGStreamingPlaybackRetryBudgetDecision.block.toJson(),
          equals('block'),
        );
        expect(
          VGStreamingPlaybackRetryBudgetDecision.notRetryable.toJson(),
          equals('notRetryable'),
        );
        expect(
          VGStreamingPlaybackRetryBudgetReason.attemptBudgetAvailable.toJson(),
          equals('attemptBudgetAvailable'),
        );
      },
    );
  });
}
