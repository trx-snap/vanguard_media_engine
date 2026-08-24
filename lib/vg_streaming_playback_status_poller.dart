// Copyright (c) Connects — Vanguard Phase 4C7AC.
// Public streaming playback status poller helper.
//
// Pure Dart periodic telemetry poller over VGStreamingPlaybackController.
// Provides broadcast Stream<VGStreamingPlaybackStatusSummary> and synchronous
// latest summary cache without busy-polling collisions or native coupling.
//
// Bounded convenience wrapper: does NOT make product feed decisions,
// retry policy, ABR decisions, caching policy, or native lifecycle decisions.

import 'dart:async';

import 'vg_streaming_playback_controller.dart';
import 'vg_streaming_playback_status_summary.dart';

export 'vg_streaming_playback_controller.dart'
    show
        VGStreamingPlaybackController,
        VGStreamingPlaybackControllerSnapshot,
        VGStreamingPlaybackControllerState;
export 'vg_streaming_playback_status_summary.dart'
    show VGStreamingPlaybackStatusSummary;

/// Immutable configuration options for [VGStreamingPlaybackStatusPoller].
class VGStreamingPlaybackStatusPollerConfig {
  /// Polling interval between status summary emissions. Defaults to 500 milliseconds.
  final Duration interval;

  /// Whether to emit an initial status summary immediately when [VGStreamingPlaybackStatusPoller.start] is called.
  /// Defaults to `true`.
  final bool emitInitialSummary;

  VGStreamingPlaybackStatusPollerConfig({
    this.interval = const Duration(milliseconds: 500),
    this.emitInitialSummary = true,
  }) {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(
        interval,
        'interval',
        'must be greater than Duration.zero',
      );
    }
  }

  @override
  String toString() =>
      'VGStreamingPlaybackStatusPollerConfig(interval=${interval.inMilliseconds}ms, emitInitialSummary=$emitInitialSummary)';
}

/// Bounded public Dart status poller over [VGStreamingPlaybackController].
///
/// Periodically queries the playback controller status, converts snapshots
/// into immutable [VGStreamingPlaybackStatusSummary] objects, and emits them
/// over a broadcast stream.
///
/// Prevents overlapping refresh operations and safeguards the host UI from
/// polling exceptions or disposal lifecycle races.
///
/// NOTE: This poller does NOT own or dispose the underlying [controller].
class VGStreamingPlaybackStatusPoller {
  /// The underlying playback controller being polled.
  final VGStreamingPlaybackController controller;

  /// Immutable configuration for this poller.
  final VGStreamingPlaybackStatusPollerConfig config;

  final StreamController<VGStreamingPlaybackStatusSummary>
  _summariesController =
      StreamController<VGStreamingPlaybackStatusSummary>.broadcast();

  Timer? _timer;
  bool _isRefreshing = false;
  bool _isDisposed = false;
  VGStreamingPlaybackStatusSummary _latest;

  VGStreamingPlaybackStatusPoller({
    required this.controller,
    VGStreamingPlaybackStatusPollerConfig? config,
  }) : config = config ?? VGStreamingPlaybackStatusPollerConfig(),
       _latest = VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
         controller.snapshot,
       );

  /// Broadcast stream of [VGStreamingPlaybackStatusSummary] updates.
  Stream<VGStreamingPlaybackStatusSummary> get summaries =>
      _summariesController.stream;

  /// Most recently observed [VGStreamingPlaybackStatusSummary].
  VGStreamingPlaybackStatusSummary get latest => _latest;

  /// Whether periodic polling is actively running.
  bool get isRunning => _timer != null && _timer!.isActive;

  /// Whether this poller has been disposed.
  bool get isDisposed => _isDisposed;

  /// Manually triggers a single status refresh cycle.
  ///
  /// Returns the resulting [VGStreamingPlaybackStatusSummary].
  /// If disposed or if a refresh is already in flight, returns [latest] without error.
  Future<VGStreamingPlaybackStatusSummary> refreshOnce() async {
    if (_isDisposed) {
      return _latest;
    }
    if (_isRefreshing) {
      return _latest;
    }
    _isRefreshing = true;
    try {
      if (_isDisposed) {
        return _latest;
      }
      VGStreamingPlaybackStatusSummary summary;
      final currentSnapshot = controller.snapshot;
      if (currentSnapshot.session == null) {
        summary = VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
          currentSnapshot,
        );
      } else {
        try {
          final refreshedSnapshot = await controller.refresh();
          summary = VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
            refreshedSnapshot,
          );
        } catch (_) {
          summary = VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
            controller.snapshot,
          );
        }
      }

      if (!_isDisposed) {
        _latest = summary;
        if (!_summariesController.isClosed) {
          _summariesController.add(summary);
        }
      }
      return _latest;
    } finally {
      _isRefreshing = false;
    }
  }

  /// Starts periodic polling at [config.interval].
  ///
  /// Idempotent. If already running or disposed, this is a no-op.
  /// If [config.emitInitialSummary] is true, triggers an initial async refresh tick.
  void start() {
    if (_isDisposed || isRunning) {
      return;
    }
    if (config.emitInitialSummary) {
      unawaited(refreshOnce());
    }
    _timer = Timer.periodic(config.interval, (_) {
      unawaited(refreshOnce());
    });
  }

  /// Idempotently cancels periodic polling without closing the stream or disposing the poller.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Idempotently stops polling and closes the broadcast stream.
  ///
  /// Does NOT dispose the underlying [controller].
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    stop();
    await _summariesController.close();
  }

  @override
  String toString() =>
      'VGStreamingPlaybackStatusPoller(isRunning=$isRunning, isDisposed=$isDisposed, '
      'interval=${config.interval.inMilliseconds}ms, latest=$_latest)';
}
