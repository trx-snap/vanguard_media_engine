// Copyright (c) Connects — Vanguard Phase 4C7AS.
// Public streaming playback retry attempt journal.
//
// Pure Dart in-memory journal helper: records, trims, prunes, snapshots, and
// evaluates streaming playback retry attempts against recovery plans and retry
// budget policies without executing retries, persisting to disk, owning timers,
// or mutating playback.
//
// Bounded convenience wrapper: does NOT execute open/play/pause/stop/dispose,
// does NOT allocate native decoders/surfaces, and does NOT control product feed policies.

import 'vg_streaming_playback_retry_budget.dart';

export 'vg_streaming_playback_retry_budget.dart';

/// Immutable configuration for [VGStreamingPlaybackRetryJournal].
class VGStreamingPlaybackRetryJournalConfig {
  /// Maximum number of attempts stored in-memory (must be > 0). Defaults to 64.
  final int maxStoredAttempts;

  /// Optional default rolling time window in milliseconds for pruning (if provided, must be > 0).
  final int? defaultWindowMs;

  const VGStreamingPlaybackRetryJournalConfig({
    this.maxStoredAttempts = 64,
    this.defaultWindowMs,
  }) : assert(maxStoredAttempts > 0, 'maxStoredAttempts must be > 0'),
       assert(
         defaultWindowMs == null || defaultWindowMs > 0,
         'defaultWindowMs must be > 0',
       );

  /// Serializes config to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'maxStoredAttempts': maxStoredAttempts,
    'defaultWindowMs': ?defaultWindowMs,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackRetryJournalConfig(maxStoredAttempts=$maxStoredAttempts, '
      'defaultWindowMs=$defaultWindowMs)';
}

/// Immutable snapshot of retry journal state at a given point in time.
class VGStreamingPlaybackRetryJournalSnapshot {
  /// Number of retry attempts captured in this snapshot.
  final int count;

  /// Immutable list of retry attempts.
  final List<VGStreamingPlaybackRetryAttempt> attempts;

  /// Optional stream key filter applied to this snapshot.
  final String? streamKey;

  /// Invariant: always `true` (pure advisory; zero player or network mutation).
  final bool advisoryOnly;

  /// Invariant: always `false` (zero playback mutation).
  final bool playbackMutation;

  /// Diagnostics dictionary containing snapshot metadata.
  final Map<String, Object?> diagnostics;

  const VGStreamingPlaybackRetryJournalSnapshot({
    required this.count,
    required this.attempts,
    this.streamKey,
    this.advisoryOnly = true,
    this.playbackMutation = false,
    this.diagnostics = const <String, Object?>{},
  });

  /// Serializes snapshot to map.
  Map<String, Object?> toJson() => <String, Object?>{
    'count': count,
    'streamKey': ?streamKey,
    'attempts': attempts.map((a) => a.toJson()).toList(),
    'advisoryOnly': advisoryOnly,
    'playbackMutation': playbackMutation,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackRetryJournalSnapshot(count=$count, streamKey=$streamKey, '
      'attempts=${attempts.length}, advisoryOnly=$advisoryOnly, '
      'playbackMutation=$playbackMutation)';
}

/// Pure Dart in-memory journal for recording, pruning, and querying
/// streaming playback retry attempts ([VGStreamingPlaybackRetryAttempt]).
///
/// Bounded convenience helper: does NOT execute open/play/pause/stop/dispose,
/// does NOT persist to disk, does NOT own timers/clocks, and does NOT call
/// platform channels.
class VGStreamingPlaybackRetryJournal {
  /// Active journal configuration.
  final VGStreamingPlaybackRetryJournalConfig config;

  final List<VGStreamingPlaybackRetryAttempt> _attempts = [];

  /// Creates a new retry journal with optional [initialAttempts] and [config].
  VGStreamingPlaybackRetryJournal({
    Iterable<VGStreamingPlaybackRetryAttempt>? initialAttempts,
    this.config = const VGStreamingPlaybackRetryJournalConfig(),
  }) {
    if (initialAttempts != null) {
      for (final attempt in initialAttempts) {
        record(attempt);
      }
    }
  }

  /// Number of recorded retry attempts currently held in-memory.
  int get length => _attempts.length;

  /// Whether the journal contains no recorded retry attempts.
  bool get isEmpty => _attempts.isEmpty;

  /// Whether the journal contains at least one recorded retry attempt.
  bool get isNotEmpty => _attempts.isNotEmpty;

  /// Records a retry [attempt] into the journal and trims oldest entries if [config.maxStoredAttempts] is exceeded.
  void record(VGStreamingPlaybackRetryAttempt attempt) {
    _attempts.add(attempt);
    if (_attempts.length > config.maxStoredAttempts) {
      _attempts.removeRange(0, _attempts.length - config.maxStoredAttempts);
    }
  }

  /// Constructs and records a new [VGStreamingPlaybackRetryAttempt] with [nowMs] timestamp.
  VGStreamingPlaybackRetryAttempt recordNow({
    required int nowMs,
    required VGStreamingPlaybackRecoveryIntent intent,
    String? streamKey,
    String? reason,
  }) {
    final attempt = VGStreamingPlaybackRetryAttempt(
      timestampMs: nowMs,
      intent: intent,
      streamKey: streamKey,
      reason: reason,
    );
    record(attempt);
    return attempt;
  }

  /// Clears all recorded retry attempts from memory.
  void clear() {
    _attempts.clear();
  }

  /// Removes all recorded retry attempts matching [streamKey].
  ///
  /// Returns the number of removed attempts.
  int clearStream(String streamKey) {
    final initialCount = _attempts.length;
    _attempts.removeWhere((a) => a.streamKey == streamKey);
    return initialCount - _attempts.length;
  }

  /// Prunes retry attempts older than [nowMs - effectiveWindowMs].
  ///
  /// Uses [windowMs] if provided, otherwise falls back to [config.defaultWindowMs].
  /// If neither is available, does nothing and returns 0.
  /// When [streamKey] is provided, only matching attempts older than the window are removed.
  /// Returns the number of removed attempts.
  int prune({required int nowMs, int? windowMs, String? streamKey}) {
    final effectiveWindowMs = windowMs ?? config.defaultWindowMs;
    if (effectiveWindowMs == null || effectiveWindowMs <= 0) {
      return 0;
    }
    final cutoffMs = nowMs - effectiveWindowMs;
    final initialCount = _attempts.length;
    _attempts.removeWhere((a) {
      if (streamKey != null && a.streamKey != streamKey) {
        return false;
      }
      return a.timestampMs < cutoffMs;
    });
    return initialCount - _attempts.length;
  }

  /// Returns an unmodifiable copy of attempts, optionally filtered by [streamKey].
  List<VGStreamingPlaybackRetryAttempt> attempts({String? streamKey}) {
    if (streamKey != null) {
      return List<VGStreamingPlaybackRetryAttempt>.unmodifiable(
        _attempts.where((a) => a.streamKey == streamKey),
      );
    }
    return List<VGStreamingPlaybackRetryAttempt>.unmodifiable(_attempts);
  }

  /// Produces an immutable [VGStreamingPlaybackRetryJournalSnapshot].
  VGStreamingPlaybackRetryJournalSnapshot snapshot({String? streamKey}) {
    final filtered = attempts(streamKey: streamKey);
    final diagnostics = <String, Object?>{
      'totalCount': _attempts.length,
      'snapshotCount': filtered.length,
      'maxStoredAttempts': config.maxStoredAttempts,
      'defaultWindowMs': ?config.defaultWindowMs,
      'streamKey': ?streamKey,
    };
    return VGStreamingPlaybackRetryJournalSnapshot(
      count: filtered.length,
      attempts: filtered,
      streamKey: streamKey,
      advisoryOnly: true,
      playbackMutation: false,
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
    );
  }

  /// Evaluates retry budget for [recoveryPlan] using recorded journal attempts.
  ///
  /// Passes recorded attempts (optionally filtered by [streamKey]) to
  /// [VGStreamingPlaybackRetryBudgetPlanner.evaluate].
  ///
  /// Invariant: does NOT mutate journal contents.
  VGStreamingPlaybackRetryBudgetResult evaluateBudget({
    required VGStreamingPlaybackRecoveryPlan recoveryPlan,
    required int nowMs,
    VGStreamingPlaybackRetryBudgetConfig config =
        const VGStreamingPlaybackRetryBudgetConfig(),
    String? streamKey,
  }) {
    final relevantAttempts = attempts(streamKey: streamKey);
    final request = VGStreamingPlaybackRetryBudgetRequest(
      recoveryPlan: recoveryPlan,
      recentAttempts: relevantAttempts,
      config: config,
      nowMs: nowMs,
      streamKey: streamKey,
    );
    return VGStreamingPlaybackRetryBudgetPlanner.evaluate(request);
  }

  /// Constructs a journal from deserialized JSON, defensively skipping malformed entries.
  factory VGStreamingPlaybackRetryJournal.fromJson(
    Map<String, Object?> json, {
    VGStreamingPlaybackRetryJournalConfig config =
        const VGStreamingPlaybackRetryJournalConfig(),
  }) {
    final attemptsRaw = json['attempts'];
    final attempts = <VGStreamingPlaybackRetryAttempt>[];
    if (attemptsRaw is List) {
      for (final entry in attemptsRaw) {
        if (entry is Map) {
          final map = Map<String, Object?>.from(entry);
          final ts = map['timestampMs'];
          final intentName = map['intent'];
          if (ts is num && ts >= 0 && intentName is String) {
            final intent = VGStreamingPlaybackRecoveryIntent.values
                .where((i) => i.name == intentName)
                .firstOrNull;
            if (intent != null) {
              final streamKey = map['streamKey'] as String?;
              final reason = map['reason'] as String?;
              attempts.add(
                VGStreamingPlaybackRetryAttempt(
                  timestampMs: ts.toInt(),
                  intent: intent,
                  streamKey: streamKey,
                  reason: reason,
                ),
              );
            }
          }
        }
      }
    }
    return VGStreamingPlaybackRetryJournal(
      initialAttempts: attempts,
      config: config,
    );
  }
}
