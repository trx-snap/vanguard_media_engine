// Copyright (c) Connects — Vanguard Phase 4C7BC.
// Public streaming playback resilience evaluation binder.
//
// Pure Dart binder: binds a stream of resilience snapshots (e.g. from
// VGStreamingPlaybackResilienceMonitor.snapshots) to a resilience coordinator
// and emits immutable coordinator evaluations.
//
// Advisory helper only: does NOT execute playback, does NOT call
// controller.open/play/pause/stop/dispose, does NOT record retry attempts automatically,
// does NOT own player/poller/monitor lifecycle, does NOT call MethodChannel, and does NOT
// read native/platform state.

import 'dart:async';

import 'vg_streaming_playback_resilience_coordinator.dart';

/// Function signature for deterministic time injection (returns epoch milliseconds).
typedef VGStreamingPlaybackResilienceNowProvider = int Function();

/// Immutable configuration for [VGStreamingPlaybackResilienceBinder].
class VGStreamingPlaybackResilienceBinderConfig {
  /// Optional stream key scoping coordinator operations.
  final String? streamKey;

  /// Whether to immediately evaluate and emit the initial snapshot on [VGStreamingPlaybackResilienceBinder.start].
  final bool emitLatestOnStart;

  const VGStreamingPlaybackResilienceBinderConfig({
    this.streamKey,
    this.emitLatestOnStart = false,
  });

  /// Serializes config to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'streamKey': ?streamKey,
    'emitLatestOnStart': emitLatestOnStart,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackResilienceBinderConfig(streamKey=$streamKey, '
      'emitLatestOnStart=$emitLatestOnStart)';
}

/// Pure Dart advisory binder connecting snapshot streams to a resilience coordinator.
///
/// Subscribes to [snapshots], evaluates each resilience snapshot against [coordinator],
/// and emits resulting [VGStreamingPlaybackResilienceCoordinatorEvaluation] events.
///
/// Invariants:
/// - Purely advisory: never initiates or controls playback.
/// - Never automatically records attempts into the coordinator journal.
/// - Subscription lifecycle is isolated from upstream and coordinator lifecycles.
class VGStreamingPlaybackResilienceBinder {
  /// Upstream stream of resilience snapshots.
  final Stream<VGStreamingPlaybackResilienceSnapshot> snapshots;

  /// Pure Dart resilience coordinator used to evaluate snapshots.
  final VGStreamingPlaybackResilienceCoordinator coordinator;

  /// Current immutable configuration for this binder.
  final VGStreamingPlaybackResilienceBinderConfig config;

  final VGStreamingPlaybackResilienceNowProvider _nowProvider;
  VGStreamingPlaybackResilienceSnapshot? _latestSnapshot;

  final StreamController<VGStreamingPlaybackResilienceCoordinatorEvaluation>
  _evaluationsController =
      StreamController<
        VGStreamingPlaybackResilienceCoordinatorEvaluation
      >.broadcast();

  StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? _subscription;
  VGStreamingPlaybackResilienceCoordinatorEvaluation? _latest;
  bool _isDisposed = false;
  String? _lastStreamError;

  VGStreamingPlaybackResilienceBinder({
    required this.snapshots,
    required this.coordinator,
    VGStreamingPlaybackResilienceBinderConfig? config,
    VGStreamingPlaybackResilienceNowProvider? nowProvider,
    VGStreamingPlaybackResilienceSnapshot? latestSnapshot,
  }) : config = config ?? const VGStreamingPlaybackResilienceBinderConfig(),
       _nowProvider = nowProvider ?? _defaultNowProvider,
       _latestSnapshot = latestSnapshot;

  static int _defaultNowProvider() => DateTime.now().millisecondsSinceEpoch;

  /// Broadcast stream of evaluated [VGStreamingPlaybackResilienceCoordinatorEvaluation] events.
  Stream<VGStreamingPlaybackResilienceCoordinatorEvaluation> get evaluations =>
      _evaluationsController.stream;

  /// Most recently produced evaluation result, or `null` if none evaluated yet.
  VGStreamingPlaybackResilienceCoordinatorEvaluation? get latest => _latest;

  /// Whether the binder is actively subscribed to the snapshot stream.
  bool get isRunning => _subscription != null;

  /// Whether this binder has been disposed.
  bool get isDisposed => _isDisposed;

  /// Most recent error message captured from the upstream snapshot stream, if any.
  String? get lastStreamError => _lastStreamError;

  /// Starts listening to [snapshots].
  ///
  /// Idempotent. If already running or disposed, this is a no-op.
  /// If [config.emitLatestOnStart] is `true` and [latestSnapshot] is non-null,
  /// immediately evaluates and emits the latest snapshot.
  void start() {
    if (_isDisposed || isRunning) {
      return;
    }

    if (config.emitLatestOnStart && _latestSnapshot != null) {
      evaluateOnce(_latestSnapshot!);
    }

    _subscription = snapshots.listen(
      (snapshot) {
        if (!_isDisposed) {
          _latestSnapshot = snapshot;
          evaluateOnce(snapshot);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _lastStreamError = error.toString();
      },
      cancelOnError: false,
    );
  }

  /// Evaluates a single resilience [snapshot] against the coordinator.
  ///
  /// If not disposed, updates [latest] and emits the result onto [evaluations].
  /// If disposed:
  /// - Returns existing [latest] if available.
  /// - Otherwise evaluates coordinator deterministically for [snapshot] and returns
  ///   the result without updating [latest] or emitting to the closed stream.
  VGStreamingPlaybackResilienceCoordinatorEvaluation evaluateOnce(
    VGStreamingPlaybackResilienceSnapshot snapshot, {
    int? nowMs,
    String? streamKey,
  }) {
    if (_isDisposed) {
      if (_latest != null) {
        return _latest!;
      }
      final effectiveNowMs = nowMs ?? _nowProvider();
      final effectiveStreamKey = streamKey ?? config.streamKey;
      return coordinator.evaluate(
        snapshot: snapshot,
        nowMs: effectiveNowMs,
        streamKey: effectiveStreamKey,
      );
    }

    final effectiveNowMs = nowMs ?? _nowProvider();
    final effectiveStreamKey = streamKey ?? config.streamKey;
    final evaluation = coordinator.evaluate(
      snapshot: snapshot,
      nowMs: effectiveNowMs,
      streamKey: effectiveStreamKey,
    );

    _latest = evaluation;
    _evaluationsController.add(evaluation);
    return evaluation;
  }

  /// Cancels only the upstream subscription.
  ///
  /// Does NOT close the [evaluations] stream, allowing [evaluateOnce] to continue
  /// working manually or [start] to resume listening.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// Disposes this binder, cancelling subscriptions and closing the output stream.
  ///
  /// Idempotent. Does NOT dispose or clear [coordinator].
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    stop();
    _evaluationsController.close();
  }
}
