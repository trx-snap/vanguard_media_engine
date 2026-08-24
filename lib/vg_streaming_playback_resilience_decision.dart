// Copyright (c) Connects — Vanguard Phase 4C7AU.
// Public streaming playback resilience decision planner.
//
// Pure Dart advisory helper: combines resilience snapshot (health advice + recovery plan)
// and retry budget evaluation into a final, immutable host-readable resilience decision
// without platform coupling, native calls, timers, or side effects.
//
// Bounded convenience wrapper: does NOT execute open/play/pause/stop/dispose, does NOT
// allocate native decoders/surfaces, and does NOT control product feed policies.

import 'vg_streaming_playback_resilience_monitor.dart';
import 'vg_streaming_playback_retry_budget.dart';

export 'vg_streaming_playback_resilience_monitor.dart'
    show
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingPlaybackHealthAction,
        VGStreamingPlaybackHealthAdvice,
        VGStreamingPlaybackHealthAdvisor,
        VGStreamingPlaybackHealthAdvisorRequest,
        VGStreamingPlaybackHealthSeverity,
        VGStreamingPlaybackOptions,
        VGStreamingPlaybackRecoveryIntent,
        VGStreamingPlaybackRecoveryPlan,
        VGStreamingPlaybackRecoveryPlanRequest,
        VGStreamingPlaybackRecoveryPlanner,
        VGStreamingPlaybackRecoveryUrgency,
        VGStreamingPlaybackResilienceMonitor,
        VGStreamingPlaybackResilienceMonitorConfig,
        VGStreamingPlaybackResilienceSnapshot,
        VGStreamingPlaybackStatusSummary,
        VGStreamingPreflightReport;
export 'vg_streaming_playback_retry_budget.dart'
    show
        VGStreamingPlaybackRetryAttempt,
        VGStreamingPlaybackRetryBudgetConfig,
        VGStreamingPlaybackRetryBudgetDecision,
        VGStreamingPlaybackRetryBudgetPlanner,
        VGStreamingPlaybackRetryBudgetReason,
        VGStreamingPlaybackRetryBudgetRequest,
        VGStreamingPlaybackRetryBudgetResult;

/// Actionable resilience decision rendered by [VGStreamingPlaybackResilienceDecisionPlanner].
enum VGStreamingPlaybackResilienceDecisionAction {
  /// Session is healthy or normal; continue observing playback status.
  observe,

  /// Session is temporarily buffering; show buffering UI and wait passively.
  showBuffering,

  /// Recovery requires explicit host action / user interaction; do not automatically retry.
  hostActionRequired,

  /// Retry is permitted within budget and cooldown; host should schedule/execute retry now.
  scheduleRetry,

  /// Retry is permitted but must wait for remaining cooldown delay.
  waitForRetryDelay,

  /// Retry is blocked by budget limits, invariant failure, or non-retryable state.
  retryBlocked,

  /// Playback reached an unrecoverable terminal state; stop session completely.
  stopTerminal;

  /// Serializes action to camelCase string.
  String toJson() => name;
}

/// Immutable request for evaluating a streaming playback resilience decision.
class VGStreamingPlaybackResilienceDecisionRequest {
  /// Resilience snapshot containing current status, health advice, and recovery plan.
  final VGStreamingPlaybackResilienceSnapshot snapshot;

  /// Evaluated retry budget result for the current recovery plan and history.
  final VGStreamingPlaybackRetryBudgetResult retryBudget;

  /// Optional stream key identifying the stream being evaluated.
  final String? streamKey;

  VGStreamingPlaybackResilienceDecisionRequest({
    required this.snapshot,
    required this.retryBudget,
    this.streamKey,
  }) : assert(!snapshot.playbackMutation, 'snapshot must not mutate playback'),
       assert(
         !retryBudget.playbackMutation,
         'retryBudget must not mutate playback',
       );

  /// Serializes request to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'snapshot': snapshot.toJson(),
    'retryBudget': retryBudget.toJson(),
    'streamKey': ?streamKey,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackResilienceDecisionRequest(intent=${snapshot.recoveryPlan.intent}, '
      'budgetDecision=${retryBudget.decision}, streamKey=$streamKey)';
}

/// Immutable result of a streaming playback resilience decision evaluation.
class VGStreamingPlaybackResilienceDecision {
  /// Actionable resilience decision recommended for host execution.
  final VGStreamingPlaybackResilienceDecisionAction action;

  /// Whether the host application can initiate a retry immediately.
  final bool canRetryNow;

  /// Whether the host application should record a retry attempt into the journal upon executing a retry.
  final bool shouldRecordAttemptOnHostRetry;

  /// Whether host application / user action is strictly required before retry.
  final bool requiresHostAction;

  /// Number of milliseconds the host must wait before attempting retry (0 if none).
  final int retryAfterMs;

  /// Recommended recovery intent carried from the upstream recovery plan.
  final VGStreamingPlaybackRecoveryIntent recoveryIntent;

  /// Recovery urgency level carried from the upstream recovery plan.
  final VGStreamingPlaybackRecoveryUrgency recoveryUrgency;

  /// Cloned and adjusted playback options ready for [VGStreamingPlaybackClient.open], or `null`.
  final VGStreamingPlaybackOptions? playbackOptions;

  /// Recommended resume position in milliseconds for reopening playback, or `null`.
  final int? resumePositionMs;

  /// Invariant: always `true` (pure advisory; zero native/player allocations).
  final bool advisoryOnly;

  /// Invariant: always `false` (zero playback mutation).
  final bool playbackMutation;

  /// Immutable list of rationale and warning codes justifying this decision.
  final List<String> reasons;

  /// Diagnostics dictionary containing evaluated telemetry metrics.
  final Map<String, Object?> diagnostics;

  /// Convenience alias for [reasons].
  List<String> get warnings => reasons;

  const VGStreamingPlaybackResilienceDecision({
    required this.action,
    required this.canRetryNow,
    required this.shouldRecordAttemptOnHostRetry,
    required this.requiresHostAction,
    required this.retryAfterMs,
    required this.recoveryIntent,
    required this.recoveryUrgency,
    this.playbackOptions,
    this.resumePositionMs,
    this.advisoryOnly = true,
    this.playbackMutation = false,
    this.reasons = const <String>[],
    this.diagnostics = const <String, Object?>{},
  });

  /// Serializes decision to map.
  Map<String, Object?> toJson() => <String, Object?>{
    'action': action.name,
    'canRetryNow': canRetryNow,
    'shouldRecordAttemptOnHostRetry': shouldRecordAttemptOnHostRetry,
    'requiresHostAction': requiresHostAction,
    'retryAfterMs': retryAfterMs,
    'recoveryIntent': recoveryIntent.name,
    'recoveryUrgency': recoveryUrgency.name,
    if (playbackOptions != null) 'playbackOptions': playbackOptions!.toArgs(),
    'resumePositionMs': ?resumePositionMs,
    'advisoryOnly': advisoryOnly,
    'playbackMutation': playbackMutation,
    'reasons': reasons,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackResilienceDecision(action=$action, canRetryNow=$canRetryNow, '
      'shouldRecordAttemptOnHostRetry=$shouldRecordAttemptOnHostRetry, '
      'requiresHostAction=$requiresHostAction, retryAfterMs=$retryAfterMs, '
      'recoveryIntent=$recoveryIntent, recoveryUrgency=$recoveryUrgency, '
      'resumePositionMs=$resumePositionMs, reasons=$reasons)';
}

/// Pure Dart advisory helper for evaluating streaming playback resilience decisions.
abstract final class VGStreamingPlaybackResilienceDecisionPlanner {
  /// Evaluates [request] and produces an immutable [VGStreamingPlaybackResilienceDecision].
  static VGStreamingPlaybackResilienceDecision decide(
    VGStreamingPlaybackResilienceDecisionRequest request,
  ) {
    final snapshot = request.snapshot;
    final retryBudget = request.retryBudget;
    final recoveryPlan = snapshot.recoveryPlan;

    // 1. Invariant safety check: reject mutating or non-advisory inputs.
    if (!snapshot.advisoryOnly ||
        snapshot.playbackMutation ||
        !retryBudget.advisoryOnly ||
        retryBudget.playbackMutation ||
        !recoveryPlan.advisoryOnly ||
        recoveryPlan.playbackMutation) {
      const invariantReason = 'mutation_invariant_rejected';
      final combinedReasons = <String>[invariantReason];
      final diagnostics = <String, Object?>{
        'action': VGStreamingPlaybackResilienceDecisionAction.retryBlocked.name,
        'streamKey': ?request.streamKey,
        'canRetryNow': false,
        'shouldRecordAttemptOnHostRetry': false,
        'requiresHostAction': false,
        'retryAfterMs': 0,
        'advisoryOnly': true,
        'playbackMutation': false,
        'reasons': combinedReasons,
        'invariantViolation': true,
      };
      return VGStreamingPlaybackResilienceDecision(
        action: VGStreamingPlaybackResilienceDecisionAction.retryBlocked,
        canRetryNow: false,
        shouldRecordAttemptOnHostRetry: false,
        requiresHostAction: false,
        retryAfterMs: 0,
        recoveryIntent: recoveryPlan.intent,
        recoveryUrgency: recoveryPlan.urgency,
        playbackOptions: null,
        resumePositionMs: null,
        advisoryOnly: true,
        playbackMutation: false,
        reasons: List<String>.unmodifiable(combinedReasons),
        diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
      );
    }

    final VGStreamingPlaybackResilienceDecisionAction action;
    final bool canRetryNow;
    final bool shouldRecordAttemptOnHostRetry;
    final bool requiresHostAction;
    final int retryAfterMs;
    final VGStreamingPlaybackOptions? playbackOptions;
    final int? resumePositionMs;
    final String decisionReason;

    // 2. Terminal stop rule
    if (recoveryPlan.intent == VGStreamingPlaybackRecoveryIntent.stopTerminal) {
      action = VGStreamingPlaybackResilienceDecisionAction.stopTerminal;
      canRetryNow = false;
      shouldRecordAttemptOnHostRetry = false;
      requiresHostAction = recoveryPlan.requiresHostAction;
      retryAfterMs = 0;
      playbackOptions = null;
      resumePositionMs = null;
      decisionReason = 'stop_terminal_planned';
    }
    // 3. Host action required rule (wins over retry budget)
    else if (recoveryPlan.requiresHostAction) {
      action = VGStreamingPlaybackResilienceDecisionAction.hostActionRequired;
      canRetryNow = false;
      shouldRecordAttemptOnHostRetry = false;
      requiresHostAction = true;
      retryAfterMs = 0;
      playbackOptions = recoveryPlan.playbackOptions;
      resumePositionMs = recoveryPlan.resumePositionMs;
      decisionReason = 'host_action_required_planned';
    }
    // 4. Retry allowed rule
    else if (retryBudget.decision ==
            VGStreamingPlaybackRetryBudgetDecision.allow &&
        retryBudget.canRetry) {
      action = VGStreamingPlaybackResilienceDecisionAction.scheduleRetry;
      canRetryNow = true;
      shouldRecordAttemptOnHostRetry = true;
      requiresHostAction = false;
      retryAfterMs = 0;
      playbackOptions = recoveryPlan.playbackOptions;
      resumePositionMs = recoveryPlan.resumePositionMs;
      decisionReason = 'schedule_retry_permitted';
    }
    // 5. Wait for retry delay rule
    else if (retryBudget.decision ==
        VGStreamingPlaybackRetryBudgetDecision.delay) {
      action = VGStreamingPlaybackResilienceDecisionAction.waitForRetryDelay;
      canRetryNow = false;
      shouldRecordAttemptOnHostRetry = false;
      requiresHostAction = false;
      retryAfterMs = retryBudget.retryAfterMs;
      playbackOptions = recoveryPlan.playbackOptions;
      resumePositionMs = recoveryPlan.resumePositionMs;
      decisionReason = 'wait_for_retry_delay_active';
    }
    // 6. Wait for buffer rule
    else if (recoveryPlan.intent ==
        VGStreamingPlaybackRecoveryIntent.waitForBuffer) {
      action = VGStreamingPlaybackResilienceDecisionAction.showBuffering;
      canRetryNow = false;
      shouldRecordAttemptOnHostRetry = false;
      requiresHostAction = false;
      retryAfterMs = 0;
      playbackOptions = null;
      resumePositionMs = null;
      decisionReason = 'show_buffering_active';
    }
    // 7. Observe / None rule
    else if (recoveryPlan.intent == VGStreamingPlaybackRecoveryIntent.none) {
      action = VGStreamingPlaybackResilienceDecisionAction.observe;
      canRetryNow = false;
      shouldRecordAttemptOnHostRetry = false;
      requiresHostAction = false;
      retryAfterMs = 0;
      playbackOptions = null;
      resumePositionMs = null;
      decisionReason = 'observe_healthy_playback';
    }
    // 8. Fallback / Retry blocked rule
    else {
      action = VGStreamingPlaybackResilienceDecisionAction.retryBlocked;
      canRetryNow = false;
      shouldRecordAttemptOnHostRetry = false;
      requiresHostAction = recoveryPlan.requiresHostAction;
      retryAfterMs = retryBudget.retryAfterMs;
      playbackOptions = recoveryPlan.playbackOptions;
      resumePositionMs = recoveryPlan.resumePositionMs;
      decisionReason = 'retry_blocked_budget_exhausted';
    }

    // Build deduplicated reasons list preserving encounter order
    final combinedReasons = <String>[];
    for (final r in recoveryPlan.reasons) {
      if (r.isNotEmpty && !combinedReasons.contains(r)) {
        combinedReasons.add(r);
      }
    }
    for (final r in retryBudget.reasonCodes) {
      if (r.isNotEmpty && !combinedReasons.contains(r)) {
        combinedReasons.add(r);
      }
    }
    if (decisionReason.isNotEmpty &&
        !combinedReasons.contains(decisionReason)) {
      combinedReasons.add(decisionReason);
    }

    final diagnostics = <String, Object?>{
      'action': action.name,
      'streamKey': ?request.streamKey,
      'recoveryIntent': recoveryPlan.intent.name,
      'recoveryUrgency': recoveryPlan.urgency.name,
      'canRetryNow': canRetryNow,
      'shouldRecordAttemptOnHostRetry': shouldRecordAttemptOnHostRetry,
      'requiresHostAction': requiresHostAction,
      'retryAfterMs': retryAfterMs,
      'attemptsInWindow': retryBudget.attemptsInWindow,
      'remainingAttempts': retryBudget.remainingAttempts,
      'budgetDecision': retryBudget.decision.name,
      'advisoryOnly': true,
      'playbackMutation': false,
      'reasons': combinedReasons,
    };

    return VGStreamingPlaybackResilienceDecision(
      action: action,
      canRetryNow: canRetryNow,
      shouldRecordAttemptOnHostRetry: shouldRecordAttemptOnHostRetry,
      requiresHostAction: requiresHostAction,
      retryAfterMs: retryAfterMs,
      recoveryIntent: recoveryPlan.intent,
      recoveryUrgency: recoveryPlan.urgency,
      playbackOptions: playbackOptions,
      resumePositionMs: resumePositionMs,
      advisoryOnly: true,
      playbackMutation: false,
      reasons: List<String>.unmodifiable(combinedReasons),
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
    );
  }
}
