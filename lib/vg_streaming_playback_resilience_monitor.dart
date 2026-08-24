// Copyright (c) Connects — Vanguard Phase 4C7AM.
// Public streaming playback resilience monitor.
//
// Pure Dart stream monitor: consumes a stream of VGStreamingPlaybackStatusSummary
// values, maintains a bounded chronological history, evaluates health advice via
// VGStreamingPlaybackHealthAdvisor, and synthesizes recovery plans via
// VGStreamingPlaybackRecoveryPlanner into composite resilience snapshots.
//
// Bounded convenience wrapper: does NOT own or dispose the player, does NOT
// control Media3 ABR, does NOT call MethodChannel or native platform channels,
// and does NOT automatically retry or reopen playback.

import 'dart:async';

import 'vg_streaming_playback_health_advisor.dart';
import 'vg_streaming_playback_recovery_plan.dart';

export 'vg_streaming_playback_client.dart'
    show
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingPlaybackOptions;
export 'vg_streaming_playback_health_advisor.dart'
    show
        VGStreamingPlaybackHealthAction,
        VGStreamingPlaybackHealthAdvice,
        VGStreamingPlaybackHealthAdvisor,
        VGStreamingPlaybackHealthAdvisorRequest,
        VGStreamingPlaybackHealthSeverity;
export 'vg_streaming_playback_recovery_plan.dart'
    show
        VGStreamingPlaybackRecoveryIntent,
        VGStreamingPlaybackRecoveryPlan,
        VGStreamingPlaybackRecoveryPlanRequest,
        VGStreamingPlaybackRecoveryPlanner,
        VGStreamingPlaybackRecoveryUrgency;
export 'vg_streaming_playback_status_summary.dart'
    show VGStreamingPlaybackStatusSummary;
export 'vg_streaming_preflight_client.dart' show VGStreamingPreflightReport;

/// Immutable configuration options for [VGStreamingPlaybackResilienceMonitor].
class VGStreamingPlaybackResilienceMonitorConfig {
  /// Maximum number of historical [VGStreamingPlaybackStatusSummary] samples retained
  /// in FIFO order for health trend evaluation. Defaults to 8, must be > 0.
  final int maxHistoryLength;

  /// Active network profile applied to the playback session. Defaults to [VGStreamingNetworkProfile.auto].
  final VGStreamingNetworkProfile currentNetworkProfile;

  /// Optional preflight compatibility report for initial stream/device constraints.
  final VGStreamingPreflightReport? preflightReport;

  /// Optional active playback options used to configure the current session.
  final VGStreamingPlaybackOptions? currentOptions;

  /// Buffer percentage (0..100) below which the buffer is considered low. Defaults to 15.
  final int lowBufferPercentThreshold;

  /// Look-ahead buffer duration in milliseconds below which the buffer is considered low. Defaults to 2000.
  final int lowBufferMsThreshold;

  /// Number of buffering samples in recent window indicating recurring rebuffering. Defaults to 2.
  final int repeatedBufferingCountThreshold;

  /// Consecutive samples with identical playhead position while playing indicating a stall. Defaults to 3.
  final int stalledPositionCountThreshold;

  /// Whether the host application policy permits automated retry without manual user intervention. Defaults to false.
  final bool allowAutomaticRetry;

  /// Recommended cooldown / backoff delay in milliseconds before dispatching recovery action. Defaults to 750.
  final int retryDelayMs;

  /// Optional explicit resume position override in milliseconds (clamped to >= 0).
  final int? resumePositionOverrideMs;

  /// Whether cache configuration from [currentOptions] should be preserved in cloned recovery options. Defaults to true.
  final bool preserveCacheOptions;

  VGStreamingPlaybackResilienceMonitorConfig({
    this.maxHistoryLength = 8,
    this.currentNetworkProfile = VGStreamingNetworkProfile.auto,
    this.preflightReport,
    this.currentOptions,
    this.lowBufferPercentThreshold = 15,
    this.lowBufferMsThreshold = 2000,
    this.repeatedBufferingCountThreshold = 2,
    this.stalledPositionCountThreshold = 3,
    this.allowAutomaticRetry = false,
    this.retryDelayMs = 750,
    this.resumePositionOverrideMs,
    this.preserveCacheOptions = true,
  }) {
    if (maxHistoryLength <= 0) {
      throw ArgumentError.value(
        maxHistoryLength,
        'maxHistoryLength',
        'must be greater than 0',
      );
    }
    if (retryDelayMs < 0) {
      throw ArgumentError.value(retryDelayMs, 'retryDelayMs', 'must be >= 0');
    }
    if (resumePositionOverrideMs != null && resumePositionOverrideMs! < 0) {
      throw ArgumentError.value(
        resumePositionOverrideMs,
        'resumePositionOverrideMs',
        'must be >= 0',
      );
    }
    if (lowBufferPercentThreshold < 0) {
      throw ArgumentError.value(
        lowBufferPercentThreshold,
        'lowBufferPercentThreshold',
        'must be >= 0',
      );
    }
    if (lowBufferMsThreshold < 0) {
      throw ArgumentError.value(
        lowBufferMsThreshold,
        'lowBufferMsThreshold',
        'must be >= 0',
      );
    }
    if (repeatedBufferingCountThreshold < 0) {
      throw ArgumentError.value(
        repeatedBufferingCountThreshold,
        'repeatedBufferingCountThreshold',
        'must be >= 0',
      );
    }
    if (stalledPositionCountThreshold < 0) {
      throw ArgumentError.value(
        stalledPositionCountThreshold,
        'stalledPositionCountThreshold',
        'must be >= 0',
      );
    }
  }

  /// Serializes config to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'maxHistoryLength': maxHistoryLength,
    'currentNetworkProfile': currentNetworkProfile.toNative(),
    if (preflightReport != null)
      'preflightReport': preflightReport!.diagnostics,
    if (currentOptions != null) 'currentOptions': currentOptions!.toArgs(),
    'lowBufferPercentThreshold': lowBufferPercentThreshold,
    'lowBufferMsThreshold': lowBufferMsThreshold,
    'repeatedBufferingCountThreshold': repeatedBufferingCountThreshold,
    'stalledPositionCountThreshold': stalledPositionCountThreshold,
    'allowAutomaticRetry': allowAutomaticRetry,
    'retryDelayMs': retryDelayMs,
    if (resumePositionOverrideMs != null)
      'resumePositionOverrideMs': resumePositionOverrideMs,
    'preserveCacheOptions': preserveCacheOptions,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackResilienceMonitorConfig(maxHistoryLength=$maxHistoryLength, '
      'profile=$currentNetworkProfile, retryDelayMs=$retryDelayMs, '
      'allowAutomaticRetry=$allowAutomaticRetry)';
}

/// Immutable composite resilience snapshot produced by [VGStreamingPlaybackResilienceMonitor].
class VGStreamingPlaybackResilienceSnapshot {
  /// Current evaluated playback status summary.
  final VGStreamingPlaybackStatusSummary status;

  /// Evaluated playback health advice for the current status and recent window.
  final VGStreamingPlaybackHealthAdvice healthAdvice;

  /// Recommended playback recovery plan synthesized from [healthAdvice].
  final VGStreamingPlaybackRecoveryPlan recoveryPlan;

  /// Number of historical samples currently retained in the monitor's history window.
  final int historyLength;

  /// Invariant: always `true` (pure advisory; zero player or session mutation).
  final bool advisoryOnly;

  /// Invariant: always `false` (zero playback mutation).
  final bool playbackMutation;

  /// Diagnostics dictionary containing evaluated telemetry metrics.
  final Map<String, Object?> diagnostics;

  /// Convenience alias for [recoveryPlan.reasons].
  List<String> get reasons => recoveryPlan.reasons;

  /// Convenience alias for [recoveryPlan.warnings].
  List<String> get warnings => recoveryPlan.warnings;

  const VGStreamingPlaybackResilienceSnapshot({
    required this.status,
    required this.healthAdvice,
    required this.recoveryPlan,
    required this.historyLength,
    this.advisoryOnly = true,
    this.playbackMutation = false,
    this.diagnostics = const <String, Object?>{},
  });

  /// Serializes snapshot to map.
  Map<String, Object?> toJson() => <String, Object?>{
    'status': status.toJson(),
    'healthAdvice': healthAdvice.toJson(),
    'recoveryPlan': recoveryPlan.toJson(),
    'historyLength': historyLength,
    'advisoryOnly': advisoryOnly,
    'playbackMutation': playbackMutation,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackResilienceSnapshot(severity=${healthAdvice.severity}, '
      'action=${healthAdvice.recommendedAction}, intent=${recoveryPlan.intent}, '
      'urgency=${recoveryPlan.urgency}, historyLength=$historyLength)';
}

/// Pure Dart playback resilience monitor over a stream of [VGStreamingPlaybackStatusSummary] values.
///
/// Subscribes to status updates, maintains bounded chronological history,
/// evaluates health advice using [VGStreamingPlaybackHealthAdvisor], and synthesizes
/// actionable recovery plans using [VGStreamingPlaybackRecoveryPlanner].
///
/// NOTE: This monitor does NOT own or dispose any player or poller.
class VGStreamingPlaybackResilienceMonitor {
  /// Input stream of playback status summaries.
  final Stream<VGStreamingPlaybackStatusSummary> summaries;

  VGStreamingPlaybackResilienceMonitorConfig _config;

  final StreamController<VGStreamingPlaybackResilienceSnapshot>
  _snapshotsController =
      StreamController<VGStreamingPlaybackResilienceSnapshot>.broadcast();

  StreamSubscription<VGStreamingPlaybackStatusSummary>? _subscription;
  final List<VGStreamingPlaybackStatusSummary> _history =
      <VGStreamingPlaybackStatusSummary>[];
  VGStreamingPlaybackResilienceSnapshot? _latest;
  bool _isDisposed = false;
  String? _lastStreamError;

  VGStreamingPlaybackResilienceMonitor({
    required this.summaries,
    VGStreamingPlaybackResilienceMonitorConfig? config,
  }) : _config = config ?? VGStreamingPlaybackResilienceMonitorConfig();

  /// Current immutable configuration for this monitor.
  VGStreamingPlaybackResilienceMonitorConfig get config => _config;

  /// Broadcast stream of evaluated [VGStreamingPlaybackResilienceSnapshot] events.
  Stream<VGStreamingPlaybackResilienceSnapshot> get snapshots =>
      _snapshotsController.stream;

  /// Most recently evaluated resilience snapshot, or `null` if none evaluated yet.
  VGStreamingPlaybackResilienceSnapshot? get latest => _latest;

  /// Whether the monitor is actively subscribed to the input stream.
  bool get isRunning => _subscription != null;

  /// Whether this monitor has been disposed.
  bool get isDisposed => _isDisposed;

  /// Current number of items in the bounded history window.
  int get historyLength => _history.length;

  /// Unmodifiable view of historical status summaries leading up to current.
  List<VGStreamingPlaybackStatusSummary> get history =>
      List.unmodifiable(_history);

  /// Updates monitor configuration for subsequent evaluations without clearing history.
  void updateConfig(VGStreamingPlaybackResilienceMonitorConfig config) {
    if (_isDisposed) {
      return;
    }
    _config = config;
    while (_history.length > _config.maxHistoryLength) {
      _history.removeAt(0);
    }
  }

  /// Starts listening to [summaries].
  ///
  /// Idempotent. If already running or disposed, this is a no-op.
  void start() {
    if (_isDisposed || isRunning) {
      return;
    }
    _subscription = summaries.listen(
      (summary) {
        if (!_isDisposed) {
          evaluateOnce(summary);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _lastStreamError = error.toString();
      },
      cancelOnError: false,
    );
  }

  /// Idempotently stops listening to the input stream without closing the output stream.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// Idempotently stops listening and closes the output snapshot stream.
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    stop();
    await _snapshotsController.close();
  }

  /// Evaluates a single [VGStreamingPlaybackStatusSummary], updates bounded history,
  /// updates [latest], emits to [snapshots] if not disposed, and returns the snapshot.
  VGStreamingPlaybackResilienceSnapshot evaluateOnce(
    VGStreamingPlaybackStatusSummary status,
  ) {
    if (_isDisposed) {
      if (_latest != null) {
        return _latest!;
      }
      final advice = VGStreamingPlaybackHealthAdvisor.evaluate(
        VGStreamingPlaybackHealthAdvisorRequest(
          current: status,
          recent: const [],
          preflightReport: _config.preflightReport,
          currentNetworkProfile: _config.currentNetworkProfile,
          lowBufferPercentThreshold: _config.lowBufferPercentThreshold,
          lowBufferMsThreshold: _config.lowBufferMsThreshold,
          repeatedBufferingCountThreshold:
              _config.repeatedBufferingCountThreshold,
          stalledPositionCountThreshold: _config.stalledPositionCountThreshold,
        ),
      );
      final plan = VGStreamingPlaybackRecoveryPlanner.plan(
        VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentStatus: status,
          currentOptions: _config.currentOptions,
          allowAutomaticRetry: _config.allowAutomaticRetry,
          retryDelayMs: _config.retryDelayMs,
          resumePositionOverrideMs: _config.resumePositionOverrideMs,
          preserveCacheOptions: _config.preserveCacheOptions,
        ),
      );
      return VGStreamingPlaybackResilienceSnapshot(
        status: status,
        healthAdvice: advice,
        recoveryPlan: plan,
        historyLength: _history.length,
        advisoryOnly: true,
        playbackMutation: false,
        diagnostics: const {'disposed': true},
      );
    }

    final recentWindow = List<VGStreamingPlaybackStatusSummary>.unmodifiable(
      _history,
    );

    final healthAdvice = VGStreamingPlaybackHealthAdvisor.evaluate(
      VGStreamingPlaybackHealthAdvisorRequest(
        current: status,
        recent: recentWindow,
        preflightReport: _config.preflightReport,
        currentNetworkProfile: _config.currentNetworkProfile,
        lowBufferPercentThreshold: _config.lowBufferPercentThreshold,
        lowBufferMsThreshold: _config.lowBufferMsThreshold,
        repeatedBufferingCountThreshold:
            _config.repeatedBufferingCountThreshold,
        stalledPositionCountThreshold: _config.stalledPositionCountThreshold,
      ),
    );

    final recoveryPlan = VGStreamingPlaybackRecoveryPlanner.plan(
      VGStreamingPlaybackRecoveryPlanRequest(
        advice: healthAdvice,
        currentStatus: status,
        currentOptions: _config.currentOptions,
        allowAutomaticRetry: _config.allowAutomaticRetry,
        retryDelayMs: _config.retryDelayMs,
        resumePositionOverrideMs: _config.resumePositionOverrideMs,
        preserveCacheOptions: _config.preserveCacheOptions,
      ),
    );

    _history.add(status);
    while (_history.length > _config.maxHistoryLength) {
      _history.removeAt(0);
    }

    final diagnostics = <String, Object?>{
      'historyLength': _history.length,
      'maxHistoryLength': _config.maxHistoryLength,
      'networkProfile': _config.currentNetworkProfile.toNative(),
      'hasPreflight': _config.preflightReport != null,
      'hasOptions': _config.currentOptions != null,
      'isRunning': isRunning,
      'isDisposed': _isDisposed,
      'advisoryOnly': true,
      'playbackMutation': false,
      if (_lastStreamError != null) 'lastStreamError': _lastStreamError,
    };

    final snapshot = VGStreamingPlaybackResilienceSnapshot(
      status: status,
      healthAdvice: healthAdvice,
      recoveryPlan: recoveryPlan,
      historyLength: _history.length,
      advisoryOnly: true,
      playbackMutation: false,
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
    );

    _latest = snapshot;

    if (!_isDisposed && !_snapshotsController.isClosed) {
      _snapshotsController.add(snapshot);
    }

    return snapshot;
  }

  @override
  String toString() =>
      'VGStreamingPlaybackResilienceMonitor(isRunning=$isRunning, '
      'isDisposed=$isDisposed, historyLength=${_history.length}, '
      'latest=$_latest)';
}
