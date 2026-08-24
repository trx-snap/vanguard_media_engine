// Copyright (c) Connects — Vanguard Phase 4C7AQ.
// Public streaming playback retry budget planner.
//
// Pure Dart advisory helper: evaluates recovery plans and recent retry attempts
// against a configurable time window and cooldown delay to produce deterministic,
// bounded retry decisions without executing retries, mutating playback, owning timers,
// or calling native platform channels.
//
// Bounded convenience wrapper: does NOT execute open/play/pause/stop/dispose, does NOT
// allocate native decoders/surfaces, and does NOT control product feed policies.

import 'dart:math' as math;

import 'vg_streaming_playback_recovery_plan.dart';

export 'vg_streaming_playback_recovery_plan.dart'
    show
        VGStreamingPlaybackRecoveryIntent,
        VGStreamingPlaybackRecoveryPlan,
        VGStreamingPlaybackRecoveryUrgency;

/// Actionable retry budget decision produced by [VGStreamingPlaybackRetryBudgetPlanner].
enum VGStreamingPlaybackRetryBudgetDecision {
  /// Retry is permitted within the current budget window.
  allow,

  /// Retry is permitted but must wait for the required cooldown/delay to elapse.
  delay,

  /// Retry is blocked because the attempt budget is exhausted or invalid.
  block,

  /// The recovery plan does not require or support retry (e.g. terminal stop, wait for buffer, healthy).
  notRetryable;

  /// Serializes decision to camelCase string.
  String toJson() => name;
}

/// Typed rationale code explaining why a retry budget decision was rendered.
enum VGStreamingPlaybackRetryBudgetReason {
  /// The recovery plan does not require reopening playback (e.g. none, waitForBuffer).
  recoveryDoesNotReopen,

  /// The recovery plan cannot be retried (e.g. missing required playback options).
  recoveryNotRetryable,

  /// Sufficient attempt budget is available and cooldown conditions are satisfied.
  attemptBudgetAvailable,

  /// Minimum cooldown delay or plan retry delay has not elapsed since the last attempt.
  minimumDelayNotElapsed,

  /// The maximum number of retry attempts within the rolling window has been reached.
  attemptBudgetExhausted,

  /// The recovery plan indicates a terminal stop and terminal retries are blocked.
  terminalStop,

  /// Invariant guard: recovery plan or budget evaluation is strictly advisory.
  advisoryOnly;

  /// Serializes reason to camelCase string.
  String toJson() => name;
}

/// Immutable record of a single streaming playback retry attempt.
class VGStreamingPlaybackRetryAttempt {
  /// Wall-clock timestamp in milliseconds when the retry attempt occurred (must be >= 0).
  final int timestampMs;

  /// The recovery intent associated with this attempt.
  final VGStreamingPlaybackRecoveryIntent intent;

  /// Optional stream key identifying the stream source for this attempt.
  final String? streamKey;

  /// Optional human-readable reason or context for this attempt.
  final String? reason;

  const VGStreamingPlaybackRetryAttempt({
    required this.timestampMs,
    required this.intent,
    this.streamKey,
    this.reason,
  }) : assert(timestampMs >= 0, 'timestampMs must be >= 0');

  /// Serializes attempt to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'timestampMs': timestampMs,
    'intent': intent.name,
    if (streamKey != null) 'streamKey': streamKey,
    if (reason != null) 'reason': reason,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackRetryAttempt(timestampMs=$timestampMs, intent=$intent, '
      'streamKey=$streamKey, reason=$reason)';
}

/// Immutable configuration options for [VGStreamingPlaybackRetryBudgetPlanner].
class VGStreamingPlaybackRetryBudgetConfig {
  /// Maximum number of allowed retry attempts within [windowMs]. Defaults to 3 (must be > 0).
  final int maxAttempts;

  /// Rolling time window duration in milliseconds. Defaults to 120,000 ms (2 minutes, must be > 0).
  final int windowMs;

  /// Minimum cooldown delay in milliseconds between consecutive retries. Defaults to 750 ms (must be >= 0).
  final int minimumDelayMs;

  /// Whether [VGStreamingPlaybackRecoveryIntent.stopTerminal] should be blocked from retrying. Defaults to true.
  final bool blockTerminalStop;

  /// Whether valid [VGStreamingPlaybackOptions] are required for reopening. Defaults to true.
  final bool requirePlaybackOptionsForReopen;

  /// Whether host action requirements should be respected. Defaults to true.
  final bool requireHostActionRespect;

  const VGStreamingPlaybackRetryBudgetConfig({
    this.maxAttempts = 3,
    this.windowMs = 120000,
    this.minimumDelayMs = 750,
    this.blockTerminalStop = true,
    this.requirePlaybackOptionsForReopen = true,
    this.requireHostActionRespect = true,
  }) : assert(maxAttempts > 0, 'maxAttempts must be > 0'),
       assert(windowMs > 0, 'windowMs must be > 0'),
       assert(minimumDelayMs >= 0, 'minimumDelayMs must be >= 0');

  /// Serializes config to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'maxAttempts': maxAttempts,
    'windowMs': windowMs,
    'minimumDelayMs': minimumDelayMs,
    'blockTerminalStop': blockTerminalStop,
    'requirePlaybackOptionsForReopen': requirePlaybackOptionsForReopen,
    'requireHostActionRespect': requireHostActionRespect,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackRetryBudgetConfig(maxAttempts=$maxAttempts, '
      'windowMs=$windowMs, minimumDelayMs=$minimumDelayMs, '
      'blockTerminalStop=$blockTerminalStop, '
      'requirePlaybackOptionsForReopen=$requirePlaybackOptionsForReopen)';
}

/// Immutable request for evaluating streaming playback retry budget.
class VGStreamingPlaybackRetryBudgetRequest {
  /// Recovery plan produced by [VGStreamingPlaybackRecoveryPlanner].
  final VGStreamingPlaybackRecoveryPlan recoveryPlan;

  /// Chronological or historical list of recent retry attempts.
  final List<VGStreamingPlaybackRetryAttempt> recentAttempts;

  /// Retry budget configuration.
  final VGStreamingPlaybackRetryBudgetConfig config;

  /// Deterministic reference timestamp in milliseconds for evaluation (must be >= 0).
  final int nowMs;

  /// Optional stream key to scope budget tracking to a specific stream.
  final String? streamKey;

  const VGStreamingPlaybackRetryBudgetRequest({
    required this.recoveryPlan,
    this.recentAttempts = const <VGStreamingPlaybackRetryAttempt>[],
    this.config = const VGStreamingPlaybackRetryBudgetConfig(),
    required this.nowMs,
    this.streamKey,
  }) : assert(nowMs >= 0, 'nowMs must be >= 0');

  /// Serializes request to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'recoveryPlan': recoveryPlan.toJson(),
    'recentAttempts': recentAttempts.map((a) => a.toJson()).toList(),
    'config': config.toJson(),
    'nowMs': nowMs,
    if (streamKey != null) 'streamKey': streamKey,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackRetryBudgetRequest(intent=${recoveryPlan.intent}, '
      'attemptsCount=${recentAttempts.length}, nowMs=$nowMs, streamKey=$streamKey)';
}

/// Immutable result of a streaming playback retry budget evaluation.
class VGStreamingPlaybackRetryBudgetResult {
  /// The budget decision.
  final VGStreamingPlaybackRetryBudgetDecision decision;

  /// Whether retry is currently permitted (`true` only when [decision] is [VGStreamingPlaybackRetryBudgetDecision.allow]).
  final bool canRetry;

  /// Number of matching retry attempts recorded within the rolling time window.
  final int attemptsInWindow;

  /// Number of remaining retry attempts available after this decision.
  final int remainingAttempts;

  /// Number of milliseconds the host app must wait before retrying (0 if allowed immediately).
  final int retryAfterMs;

  /// Invariant: always `true` (pure advisory; zero player or network mutation).
  final bool advisoryOnly;

  /// Invariant: always `false` (zero playback mutation).
  final bool playbackMutation;

  /// Typed list of rationale enums explaining the decision.
  final List<VGStreamingPlaybackRetryBudgetReason> reasons;

  /// String representations of rationale codes.
  final List<String> reasonCodes;

  /// Diagnostics dictionary containing evaluated telemetry metrics.
  final Map<String, Object?> diagnostics;

  /// Convenience alias for [reasonCodes].
  List<String> get warnings => reasonCodes;

  const VGStreamingPlaybackRetryBudgetResult({
    required this.decision,
    required this.canRetry,
    required this.attemptsInWindow,
    required this.remainingAttempts,
    required this.retryAfterMs,
    this.advisoryOnly = true,
    this.playbackMutation = false,
    required this.reasons,
    required this.reasonCodes,
    this.diagnostics = const <String, Object?>{},
  });

  /// Serializes result to map.
  Map<String, Object?> toJson() => <String, Object?>{
    'decision': decision.name,
    'canRetry': canRetry,
    'attemptsInWindow': attemptsInWindow,
    'remainingAttempts': remainingAttempts,
    'retryAfterMs': retryAfterMs,
    'advisoryOnly': advisoryOnly,
    'playbackMutation': playbackMutation,
    'reasons': reasons.map((r) => r.name).toList(),
    'reasonCodes': reasonCodes,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackRetryBudgetResult(decision=$decision, canRetry=$canRetry, '
      'attemptsInWindow=$attemptsInWindow, remainingAttempts=$remainingAttempts, '
      'retryAfterMs=$retryAfterMs, reasons=$reasonCodes)';
}

/// Pure Dart advisory helper for evaluating streaming playback retry budgets.
abstract final class VGStreamingPlaybackRetryBudgetPlanner {
  /// Evaluates [request] and produces an immutable [VGStreamingPlaybackRetryBudgetResult].
  static VGStreamingPlaybackRetryBudgetResult evaluate(
    VGStreamingPlaybackRetryBudgetRequest request,
  ) {
    final recoveryPlan = request.recoveryPlan;
    final config = request.config;
    final nowMs = request.nowMs;
    final targetStreamKey = request.streamKey;

    // 1. Invariant safety check: block non-advisory or mutating recovery plans.
    if (!recoveryPlan.advisoryOnly || recoveryPlan.playbackMutation) {
      const reasons = <VGStreamingPlaybackRetryBudgetReason>[
        VGStreamingPlaybackRetryBudgetReason.advisoryOnly,
      ];
      final reasonCodes = <String>['recovery_plan_mutation_rejected'];
      final diagnostics = <String, Object?>{
        'decision': VGStreamingPlaybackRetryBudgetDecision.block.name,
        'canRetry': false,
        'attemptsInWindow': 0,
        'remainingAttempts': 0,
        'retryAfterMs': 0,
        'advisoryOnly': true,
        'playbackMutation': false,
        'reasons': reasonCodes,
      };
      return VGStreamingPlaybackRetryBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.block,
        canRetry: false,
        attemptsInWindow: 0,
        remainingAttempts: 0,
        retryAfterMs: 0,
        advisoryOnly: true,
        playbackMutation: false,
        reasons: List<VGStreamingPlaybackRetryBudgetReason>.unmodifiable(
          reasons,
        ),
        reasonCodes: List<String>.unmodifiable(reasonCodes),
        diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
      );
    }

    // 2. Non-reopening intents: none, waitForBuffer
    if (recoveryPlan.intent == VGStreamingPlaybackRecoveryIntent.none ||
        recoveryPlan.intent ==
            VGStreamingPlaybackRecoveryIntent.waitForBuffer) {
      const reasons = <VGStreamingPlaybackRetryBudgetReason>[
        VGStreamingPlaybackRetryBudgetReason.recoveryDoesNotReopen,
      ];
      final reasonCodes = <String>['recovery_does_not_reopen'];
      final diagnostics = <String, Object?>{
        'decision': VGStreamingPlaybackRetryBudgetDecision.notRetryable.name,
        'canRetry': false,
        'intent': recoveryPlan.intent.name,
        'attemptsInWindow': 0,
        'remainingAttempts': 0,
        'retryAfterMs': 0,
        'advisoryOnly': true,
        'playbackMutation': false,
        'reasons': reasonCodes,
      };
      return VGStreamingPlaybackRetryBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.notRetryable,
        canRetry: false,
        attemptsInWindow: 0,
        remainingAttempts: 0,
        retryAfterMs: 0,
        advisoryOnly: true,
        playbackMutation: false,
        reasons: List<VGStreamingPlaybackRetryBudgetReason>.unmodifiable(
          reasons,
        ),
        reasonCodes: List<String>.unmodifiable(reasonCodes),
        diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
      );
    }

    // 3. Terminal stop intent
    if (recoveryPlan.intent == VGStreamingPlaybackRecoveryIntent.stopTerminal &&
        config.blockTerminalStop) {
      const reasons = <VGStreamingPlaybackRetryBudgetReason>[
        VGStreamingPlaybackRetryBudgetReason.terminalStop,
      ];
      final reasonCodes = <String>['terminal_stop'];
      final diagnostics = <String, Object?>{
        'decision': VGStreamingPlaybackRetryBudgetDecision.notRetryable.name,
        'canRetry': false,
        'intent': recoveryPlan.intent.name,
        'attemptsInWindow': 0,
        'remainingAttempts': 0,
        'retryAfterMs': 0,
        'advisoryOnly': true,
        'playbackMutation': false,
        'reasons': reasonCodes,
      };
      return VGStreamingPlaybackRetryBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.notRetryable,
        canRetry: false,
        attemptsInWindow: 0,
        remainingAttempts: 0,
        retryAfterMs: 0,
        advisoryOnly: true,
        playbackMutation: false,
        reasons: List<VGStreamingPlaybackRetryBudgetReason>.unmodifiable(
          reasons,
        ),
        reasonCodes: List<String>.unmodifiable(reasonCodes),
        diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
      );
    }

    // 4. Recovery plan does not reopen playback
    if (!recoveryPlan.shouldReopenPlayback) {
      const reasons = <VGStreamingPlaybackRetryBudgetReason>[
        VGStreamingPlaybackRetryBudgetReason.recoveryDoesNotReopen,
      ];
      final reasonCodes = <String>['recovery_does_not_reopen'];
      final diagnostics = <String, Object?>{
        'decision': VGStreamingPlaybackRetryBudgetDecision.notRetryable.name,
        'canRetry': false,
        'shouldReopenPlayback': false,
        'attemptsInWindow': 0,
        'remainingAttempts': 0,
        'retryAfterMs': 0,
        'advisoryOnly': true,
        'playbackMutation': false,
        'reasons': reasonCodes,
      };
      return VGStreamingPlaybackRetryBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.notRetryable,
        canRetry: false,
        attemptsInWindow: 0,
        remainingAttempts: 0,
        retryAfterMs: 0,
        advisoryOnly: true,
        playbackMutation: false,
        reasons: List<VGStreamingPlaybackRetryBudgetReason>.unmodifiable(
          reasons,
        ),
        reasonCodes: List<String>.unmodifiable(reasonCodes),
        diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
      );
    }

    // 5. Reopening requires playback options if configured
    if (config.requirePlaybackOptionsForReopen &&
        recoveryPlan.playbackOptions == null) {
      const reasons = <VGStreamingPlaybackRetryBudgetReason>[
        VGStreamingPlaybackRetryBudgetReason.recoveryNotRetryable,
      ];
      final reasonCodes = <String>['missing_playback_options'];
      final diagnostics = <String, Object?>{
        'decision': VGStreamingPlaybackRetryBudgetDecision.block.name,
        'canRetry': false,
        'missingPlaybackOptions': true,
        'attemptsInWindow': 0,
        'remainingAttempts': 0,
        'retryAfterMs': 0,
        'advisoryOnly': true,
        'playbackMutation': false,
        'reasons': reasonCodes,
      };
      return VGStreamingPlaybackRetryBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.block,
        canRetry: false,
        attemptsInWindow: 0,
        remainingAttempts: 0,
        retryAfterMs: 0,
        advisoryOnly: true,
        playbackMutation: false,
        reasons: List<VGStreamingPlaybackRetryBudgetReason>.unmodifiable(
          reasons,
        ),
        reasonCodes: List<String>.unmodifiable(reasonCodes),
        diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
      );
    }

    // 6. Filter attempts within [nowMs - windowMs, nowMs]
    // If request.streamKey is specified, count only attempts matching that streamKey.
    // If request.streamKey is null, count all attempts in window.
    final windowStartMs = nowMs - config.windowMs;
    final matchingAttempts = <VGStreamingPlaybackRetryAttempt>[];

    for (final attempt in request.recentAttempts) {
      if (targetStreamKey != null && attempt.streamKey != targetStreamKey) {
        continue;
      }
      if (attempt.timestampMs >= windowStartMs &&
          attempt.timestampMs <= nowMs) {
        matchingAttempts.add(attempt);
      }
    }

    // Sort chronologically ascending by timestampMs
    matchingAttempts.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    final attemptsInWindow = matchingAttempts.length;

    // 7. Check if attempt budget in window is exhausted
    if (attemptsInWindow >= config.maxAttempts) {
      final earliestAttemptMs = matchingAttempts.first.timestampMs;
      final retryAfterMs = math.max(
        0,
        (earliestAttemptMs + config.windowMs) - nowMs,
      );
      const reasons = <VGStreamingPlaybackRetryBudgetReason>[
        VGStreamingPlaybackRetryBudgetReason.attemptBudgetExhausted,
      ];
      final reasonCodes = <String>['attempt_budget_exhausted'];
      final diagnostics = <String, Object?>{
        'decision': VGStreamingPlaybackRetryBudgetDecision.block.name,
        'canRetry': false,
        'attemptsInWindow': attemptsInWindow,
        'remainingAttempts': 0,
        'retryAfterMs': retryAfterMs,
        'maxAttempts': config.maxAttempts,
        'windowMs': config.windowMs,
        'earliestAttemptMs': earliestAttemptMs,
        'nowMs': nowMs,
        'streamKey': ?targetStreamKey,
        'advisoryOnly': true,
        'playbackMutation': false,
        'reasons': reasonCodes,
      };
      return VGStreamingPlaybackRetryBudgetResult(
        decision: VGStreamingPlaybackRetryBudgetDecision.block,
        canRetry: false,
        attemptsInWindow: attemptsInWindow,
        remainingAttempts: 0,
        retryAfterMs: retryAfterMs,
        advisoryOnly: true,
        playbackMutation: false,
        reasons: List<VGStreamingPlaybackRetryBudgetReason>.unmodifiable(
          reasons,
        ),
        reasonCodes: List<String>.unmodifiable(reasonCodes),
        diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
      );
    }

    // 8. Check minimum cooldown delay since the latest attempt
    final requiredCooldownMs = math.max(
      config.minimumDelayMs,
      recoveryPlan.retryDelayMs,
    );

    if (matchingAttempts.isNotEmpty) {
      final latestAttemptMs = matchingAttempts.last.timestampMs;
      final elapsedSinceLatestMs = nowMs - latestAttemptMs;

      if (elapsedSinceLatestMs < requiredCooldownMs) {
        final remainingDelayMs = requiredCooldownMs - elapsedSinceLatestMs;
        final remainingAttempts = math.max(
          0,
          config.maxAttempts - attemptsInWindow,
        );
        const reasons = <VGStreamingPlaybackRetryBudgetReason>[
          VGStreamingPlaybackRetryBudgetReason.minimumDelayNotElapsed,
        ];
        final reasonCodes = <String>['minimum_delay_not_elapsed'];
        final diagnostics = <String, Object?>{
          'decision': VGStreamingPlaybackRetryBudgetDecision.delay.name,
          'canRetry': false,
          'attemptsInWindow': attemptsInWindow,
          'remainingAttempts': remainingAttempts,
          'retryAfterMs': remainingDelayMs,
          'latestAttemptMs': latestAttemptMs,
          'elapsedSinceLatestMs': elapsedSinceLatestMs,
          'requiredCooldownMs': requiredCooldownMs,
          'minimumDelayMs': config.minimumDelayMs,
          'planRetryDelayMs': recoveryPlan.retryDelayMs,
          'nowMs': nowMs,
          'streamKey': ?targetStreamKey,
          'advisoryOnly': true,
          'playbackMutation': false,
          'reasons': reasonCodes,
        };
        return VGStreamingPlaybackRetryBudgetResult(
          decision: VGStreamingPlaybackRetryBudgetDecision.delay,
          canRetry: false,
          attemptsInWindow: attemptsInWindow,
          remainingAttempts: remainingAttempts,
          retryAfterMs: remainingDelayMs,
          advisoryOnly: true,
          playbackMutation: false,
          reasons: List<VGStreamingPlaybackRetryBudgetReason>.unmodifiable(
            reasons,
          ),
          reasonCodes: List<String>.unmodifiable(reasonCodes),
          diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
        );
      }
    }

    // 9. Retry is permitted and budget is available
    final remainingAttempts = math.max(
      0,
      config.maxAttempts - attemptsInWindow - 1,
    );
    const reasons = <VGStreamingPlaybackRetryBudgetReason>[
      VGStreamingPlaybackRetryBudgetReason.attemptBudgetAvailable,
    ];
    final reasonCodes = <String>['attempt_budget_available'];
    final diagnostics = <String, Object?>{
      'decision': VGStreamingPlaybackRetryBudgetDecision.allow.name,
      'canRetry': true,
      'attemptsInWindow': attemptsInWindow,
      'remainingAttempts': remainingAttempts,
      'retryAfterMs': 0,
      'maxAttempts': config.maxAttempts,
      'windowMs': config.windowMs,
      'requiredCooldownMs': requiredCooldownMs,
      'nowMs': nowMs,
      'streamKey': ?targetStreamKey,
      'advisoryOnly': true,
      'playbackMutation': false,
      'reasons': reasonCodes,
    };

    return VGStreamingPlaybackRetryBudgetResult(
      decision: VGStreamingPlaybackRetryBudgetDecision.allow,
      canRetry: true,
      attemptsInWindow: attemptsInWindow,
      remainingAttempts: remainingAttempts,
      retryAfterMs: 0,
      advisoryOnly: true,
      playbackMutation: false,
      reasons: List<VGStreamingPlaybackRetryBudgetReason>.unmodifiable(reasons),
      reasonCodes: List<String>.unmodifiable(reasonCodes),
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
    );
  }
}
