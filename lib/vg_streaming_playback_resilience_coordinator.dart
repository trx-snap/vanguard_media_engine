// Copyright (c) Connects — Vanguard Phase 4C7AW.
// Public streaming playback resilience coordinator.
//
// Pure Dart coordinator: combines in-memory retry attempt journaling, rolling-window
// retry budget evaluation, and resilience decision planning into a single stateful,
// advisory helper without executing playback, calling platform channels, owning timers,
// reading clocks, touching Media3/AVPlayer/WebRTC, or editing native code.
//
// Bounded convenience wrapper: does NOT execute open/play/pause/stop/dispose, does NOT
// allocate native decoders/surfaces, and does NOT control product feed policies.

import 'vg_streaming_playback_resilience_decision.dart';
import 'vg_streaming_playback_retry_journal.dart';

export 'vg_streaming_playback_resilience_decision.dart';
export 'vg_streaming_playback_retry_journal.dart';

/// Immutable configuration for [VGStreamingPlaybackResilienceCoordinator].
class VGStreamingPlaybackResilienceCoordinatorConfig {
  /// Journal configuration for in-memory attempt retention and bounds.
  final VGStreamingPlaybackRetryJournalConfig journalConfig;

  /// Retry budget configuration for rolling windows and attempt limits.
  final VGStreamingPlaybackRetryBudgetConfig retryBudgetConfig;

  /// Optional default stream key scoping coordinator operations.
  final String? streamKey;

  const VGStreamingPlaybackResilienceCoordinatorConfig({
    this.journalConfig = const VGStreamingPlaybackRetryJournalConfig(),
    this.retryBudgetConfig = const VGStreamingPlaybackRetryBudgetConfig(),
    this.streamKey,
  });

  /// Serializes config to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'journalConfig': journalConfig.toJson(),
    'retryBudgetConfig': retryBudgetConfig.toJson(),
    'streamKey': ?streamKey,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackResilienceCoordinatorConfig(journalConfig=$journalConfig, '
      'retryBudgetConfig=$retryBudgetConfig, streamKey=$streamKey)';
}

/// Immutable evaluation result produced by [VGStreamingPlaybackResilienceCoordinator.evaluate].
class VGStreamingPlaybackResilienceCoordinatorEvaluation {
  /// Upstream resilience snapshot containing health advice and recovery plan.
  final VGStreamingPlaybackResilienceSnapshot snapshot;

  /// Evaluated retry budget result for current window and recovery plan.
  final VGStreamingPlaybackRetryBudgetResult retryBudget;

  /// Rendered actionable resilience decision for host execution.
  final VGStreamingPlaybackResilienceDecision decision;

  /// Filtered journal snapshot capturing attempt history at evaluation time.
  final VGStreamingPlaybackRetryJournalSnapshot journalSnapshot;

  /// Invariant: always `true` (pure advisory; zero native/player allocations).
  final bool advisoryOnly;

  /// Invariant: always `false` (zero playback mutation).
  final bool playbackMutation;

  /// Diagnostics dictionary containing evaluated telemetry metrics.
  final Map<String, Object?> diagnostics;

  /// Actionable resilience decision recommended for host execution.
  VGStreamingPlaybackResilienceDecisionAction get action => decision.action;

  /// Whether the host application can initiate a retry immediately.
  bool get canRetryNow => decision.canRetryNow;

  /// Whether the host application should record a retry attempt into the journal upon executing a retry.
  bool get shouldRecordAttemptOnHostRetry =>
      decision.shouldRecordAttemptOnHostRetry;

  /// Whether host application / user action is strictly required before retry.
  bool get requiresHostAction => decision.requiresHostAction;

  /// Number of milliseconds the host must wait before attempting retry (0 if none).
  int get retryAfterMs => decision.retryAfterMs;

  /// Immutable list of rationale and warning codes justifying this decision.
  List<String> get reasons => decision.reasons;

  /// Convenience alias for [reasons].
  List<String> get warnings => decision.warnings;

  const VGStreamingPlaybackResilienceCoordinatorEvaluation({
    required this.snapshot,
    required this.retryBudget,
    required this.decision,
    required this.journalSnapshot,
    this.advisoryOnly = true,
    this.playbackMutation = false,
    this.diagnostics = const <String, Object?>{},
  });

  /// Serializes evaluation to map.
  Map<String, Object?> toJson() => <String, Object?>{
    'snapshot': snapshot.toJson(),
    'retryBudget': retryBudget.toJson(),
    'decision': decision.toJson(),
    'journalSnapshot': journalSnapshot.toJson(),
    'advisoryOnly': advisoryOnly,
    'playbackMutation': playbackMutation,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackResilienceCoordinatorEvaluation(action=$action, '
      'canRetryNow=$canRetryNow, shouldRecordAttemptOnHostRetry=$shouldRecordAttemptOnHostRetry, '
      'requiresHostAction=$requiresHostAction, retryAfterMs=$retryAfterMs, '
      'journalAttempts=${journalSnapshot.count}, advisoryOnly=$advisoryOnly, '
      'playbackMutation=$playbackMutation)';
}

/// Pure Dart public coordinator combining retry journal, retry budget, and
/// resilience decision planner into a single cohesive, stateful convenience helper.
///
/// Bounded convenience wrapper: does NOT execute open/play/pause/stop/dispose,
/// does NOT call platform channels, does NOT own timers or clocks, does NOT
/// touch Media3/AVPlayer/WebRTC, and does NOT edit native code.
class VGStreamingPlaybackResilienceCoordinator {
  /// Coordinator configuration.
  final VGStreamingPlaybackResilienceCoordinatorConfig config;

  /// Owned in-memory retry attempt journal.
  final VGStreamingPlaybackRetryJournal _journal;

  /// Creates a new resilience coordinator with optional [config] and [initialAttempts].
  VGStreamingPlaybackResilienceCoordinator({
    this.config = const VGStreamingPlaybackResilienceCoordinatorConfig(),
    Iterable<VGStreamingPlaybackRetryAttempt>? initialAttempts,
  }) : _journal = VGStreamingPlaybackRetryJournal(
         initialAttempts: initialAttempts,
         config: config.journalConfig,
       );

  /// Accessor for the owned [VGStreamingPlaybackRetryJournal].
  VGStreamingPlaybackRetryJournal get journal => _journal;

  /// Total number of retry attempts currently stored in the owned journal.
  int get length => _journal.length;

  /// Whether the owned journal contains no retry attempts.
  bool get isEmpty => _journal.isEmpty;

  /// Whether the owned journal contains at least one retry attempt.
  bool get isNotEmpty => _journal.isNotEmpty;

  /// Evaluates resilience for [snapshot] at [nowMs].
  ///
  /// Prunes expired attempts from the owned journal using [nowMs] and
  /// [config.retryBudgetConfig.windowMs], evaluates retry budget using the
  /// owned journal, calls [VGStreamingPlaybackResilienceDecisionPlanner.decide],
  /// and returns an immutable [VGStreamingPlaybackResilienceCoordinatorEvaluation].
  ///
  /// Invariant: does NOT automatically record a retry attempt into the journal.
  VGStreamingPlaybackResilienceCoordinatorEvaluation evaluate({
    required VGStreamingPlaybackResilienceSnapshot snapshot,
    required int nowMs,
    String? streamKey,
  }) {
    final effectiveStreamKey = streamKey ?? config.streamKey;

    // 1. Housekeeping: prune expired entries older than retry budget windowMs
    _journal.prune(
      nowMs: nowMs,
      windowMs: config.retryBudgetConfig.windowMs,
      streamKey: effectiveStreamKey,
    );

    // 2. Evaluate retry budget against current journal attempts
    final retryBudget = _journal.evaluateBudget(
      recoveryPlan: snapshot.recoveryPlan,
      nowMs: nowMs,
      config: config.retryBudgetConfig,
      streamKey: effectiveStreamKey,
    );

    // 3. Plan final actionable resilience decision
    final decision = VGStreamingPlaybackResilienceDecisionPlanner.decide(
      VGStreamingPlaybackResilienceDecisionRequest(
        snapshot: snapshot,
        retryBudget: retryBudget,
        streamKey: effectiveStreamKey,
      ),
    );

    // 4. Capture current journal snapshot
    final journalSnap = _journal.snapshot(streamKey: effectiveStreamKey);

    final diagnostics = <String, Object?>{
      'action': decision.action.name,
      'streamKey': ?effectiveStreamKey,
      'canRetryNow': decision.canRetryNow,
      'shouldRecordAttemptOnHostRetry': decision.shouldRecordAttemptOnHostRetry,
      'requiresHostAction': decision.requiresHostAction,
      'retryAfterMs': decision.retryAfterMs,
      'recoveryIntent': decision.recoveryIntent.name,
      'recoveryUrgency': decision.recoveryUrgency.name,
      'attemptsInWindow': retryBudget.attemptsInWindow,
      'remainingAttempts': retryBudget.remainingAttempts,
      'budgetDecision': retryBudget.decision.name,
      'journalCount': journalSnap.count,
      'journalTotalCount': _journal.length,
      'advisoryOnly': true,
      'playbackMutation': false,
      'reasons': decision.reasons,
    };

    return VGStreamingPlaybackResilienceCoordinatorEvaluation(
      snapshot: snapshot,
      retryBudget: retryBudget,
      decision: decision,
      journalSnapshot: journalSnap,
      advisoryOnly: true,
      playbackMutation: false,
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
    );
  }

  /// Explicitly records a retry attempt into the owned journal when the host
  /// actually executes a retry.
  ///
  /// Callers must invoke this method ONLY after the host application initiates
  /// retry / playback open, and only when [decision.shouldRecordAttemptOnHostRetry]
  /// is `true`.
  ///
  /// Returns the newly recorded [VGStreamingPlaybackRetryAttempt] if recorded,
  /// or `null` if [decision.shouldRecordAttemptOnHostRetry] was `false`.
  VGStreamingPlaybackRetryAttempt? recordHostRetryAttempted({
    required int nowMs,
    required VGStreamingPlaybackResilienceDecision decision,
    String? streamKey,
    String? reason,
  }) {
    if (!decision.shouldRecordAttemptOnHostRetry) {
      return null;
    }

    final effectiveStreamKey = streamKey ?? config.streamKey;
    final effectiveReason =
        reason ??
        (decision.reasons.isNotEmpty ? decision.reasons.join(',') : null);

    return _journal.recordNow(
      nowMs: nowMs,
      intent: decision.recoveryIntent,
      streamKey: effectiveStreamKey,
      reason: effectiveReason,
    );
  }

  /// Clears all recorded retry attempts from the owned journal.
  void clear() {
    _journal.clear();
  }

  /// Removes all recorded retry attempts matching [streamKey] from the owned journal.
  ///
  /// Returns the number of removed attempts.
  int clearStream(String streamKey) {
    return _journal.clearStream(streamKey);
  }

  /// Produces an immutable snapshot of the owned journal, optionally filtered by [streamKey].
  ///
  /// Uses [streamKey] if supplied, otherwise falls back to [config.streamKey].
  VGStreamingPlaybackRetryJournalSnapshot journalSnapshot({String? streamKey}) {
    final effectiveStreamKey = streamKey ?? config.streamKey;
    return _journal.snapshot(streamKey: effectiveStreamKey);
  }
}
