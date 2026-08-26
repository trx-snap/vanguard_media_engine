// Copyright (c) Connects — Vanguard Phase 4C7BK.
// Public streaming offline asset lifecycle monitor.
//
// Pure Dart stream monitor: consumes a stream of VGStreamingOfflineAssetDownloadStatus
// updates, maintains a bounded chronological history, computes aggregated lifecycle
// summaries via VGStreamingOfflineAssetLifecycleSummarizer, and emits composite
// lifecycle snapshots over a broadcast stream.
//
// Bounded convenience wrapper: does NOT own or dispose the input stream or client,
// does NOT call MethodChannel or native platform channels, does NOT perform downloads
// or filesystem operations, does NOT schedule retry or queue policy, does NOT make
// product UX decisions, and does NOT alter playback state.

import 'dart:async';

import 'vg_streaming_offline_asset_lifecycle.dart';

export 'vg_streaming_offline_asset_lifecycle.dart'
    show
        VGStreamingOfflineAssetDownloadState,
        VGStreamingOfflineAssetDownloadStateX,
        VGStreamingOfflineAssetDownloadStatus,
        VGStreamingOfflineAssetLifecycleSummarizer,
        VGStreamingOfflineAssetLifecycleSummary;

/// Immutable configuration options for [VGStreamingOfflineAssetLifecycleMonitor].
class VGStreamingOfflineAssetLifecycleMonitorConfig {
  /// Maximum number of historical [VGStreamingOfflineAssetDownloadStatus] samples retained
  /// in FIFO order for lifecycle summary computation. Defaults to 32, must be > 0.
  final int maxHistoryLength;

  /// Whether identical consecutive status updates should trigger snapshot emission and history retention.
  /// Defaults to `true`.
  final bool emitDuplicateStatuses;

  VGStreamingOfflineAssetLifecycleMonitorConfig({
    this.maxHistoryLength = 32,
    this.emitDuplicateStatuses = true,
  }) {
    if (maxHistoryLength <= 0) {
      throw ArgumentError.value(
        maxHistoryLength,
        'maxHistoryLength',
        'must be greater than 0',
      );
    }
  }

  /// Serializes config to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'maxHistoryLength': maxHistoryLength,
    'emitDuplicateStatuses': emitDuplicateStatuses,
  };

  @override
  String toString() =>
      'VGStreamingOfflineAssetLifecycleMonitorConfig(maxHistoryLength=$maxHistoryLength, '
      'emitDuplicateStatuses=$emitDuplicateStatuses)';
}

/// Immutable composite lifecycle snapshot produced by [VGStreamingOfflineAssetLifecycleMonitor].
class VGStreamingOfflineAssetLifecycleSnapshot {
  /// Current evaluated offline asset download status.
  final VGStreamingOfflineAssetDownloadStatus status;

  /// Aggregated lifecycle summary computed across the monitor's bounded history.
  final VGStreamingOfflineAssetLifecycleSummary summary;

  /// Number of historical status updates currently retained in the monitor's history window.
  final int historyLength;

  /// Invariant: always `true` (pure advisory; zero native or session mutation).
  final bool advisoryOnly;

  /// Invariant: always `false` (zero playback mutation).
  final bool playbackMutation;

  /// Diagnostic telemetry metadata.
  final Map<String, Object?> diagnostics;

  /// Whether any tracked downloads in the summary are currently active (queued or running).
  bool get hasActiveDownloads => summary.hasActiveDownloads;

  /// Whether all tracked downloads in the summary have reached a terminal state.
  bool get allTerminal => summary.allTerminal;

  /// Whether the current [status] has reached a terminal lifecycle state.
  bool get isCurrentTerminal => status.isTerminal;

  /// Whether the current [status] completed successfully.
  bool get isCurrentSuccessful => status.isSuccessful;

  const VGStreamingOfflineAssetLifecycleSnapshot({
    required this.status,
    required this.summary,
    required this.historyLength,
    this.advisoryOnly = true,
    this.playbackMutation = false,
    this.diagnostics = const <String, Object?>{},
  });

  /// Serializes snapshot to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'status': status.toJson(),
    'summary': summary.toJson(),
    'historyLength': historyLength,
    'advisoryOnly': advisoryOnly,
    'playbackMutation': playbackMutation,
    'hasActiveDownloads': hasActiveDownloads,
    'allTerminal': allTerminal,
    'isCurrentTerminal': isCurrentTerminal,
    'isCurrentSuccessful': isCurrentSuccessful,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingOfflineAssetLifecycleSnapshot(requestId=${status.requestId}, '
      'state=${status.state.name}, historyLength=$historyLength, '
      'hasActiveDownloads=$hasActiveDownloads, allTerminal=$allTerminal)';
}

/// Pure Dart offline asset lifecycle monitor over a stream of [VGStreamingOfflineAssetDownloadStatus] values.
///
/// Subscribes to status updates, maintains bounded FIFO history, aggregates lifecycle
/// metrics using [VGStreamingOfflineAssetLifecycleSummarizer], and emits [VGStreamingOfflineAssetLifecycleSnapshot]
/// events over a broadcast stream.
///
/// NOTE: This monitor does NOT own or dispose the input stream or underlying client/poller.
class VGStreamingOfflineAssetLifecycleMonitor {
  /// Input stream of offline asset download status updates.
  final Stream<VGStreamingOfflineAssetDownloadStatus> statuses;

  VGStreamingOfflineAssetLifecycleMonitorConfig _config;

  final StreamController<VGStreamingOfflineAssetLifecycleSnapshot>
  _snapshotsController =
      StreamController<VGStreamingOfflineAssetLifecycleSnapshot>.broadcast();

  StreamSubscription<VGStreamingOfflineAssetDownloadStatus>? _subscription;
  final List<VGStreamingOfflineAssetDownloadStatus> _history =
      <VGStreamingOfflineAssetDownloadStatus>[];
  VGStreamingOfflineAssetLifecycleSnapshot? _latest;
  bool _isDisposed = false;
  String? _lastStreamError;

  VGStreamingOfflineAssetLifecycleMonitor({
    required this.statuses,
    VGStreamingOfflineAssetLifecycleMonitorConfig? config,
  }) : _config = config ?? VGStreamingOfflineAssetLifecycleMonitorConfig();

  /// Current immutable configuration for this monitor.
  VGStreamingOfflineAssetLifecycleMonitorConfig get config => _config;

  /// Broadcast stream of evaluated [VGStreamingOfflineAssetLifecycleSnapshot] events.
  Stream<VGStreamingOfflineAssetLifecycleSnapshot> get snapshots =>
      _snapshotsController.stream;

  /// Most recently evaluated lifecycle snapshot, or `null` if none evaluated yet.
  VGStreamingOfflineAssetLifecycleSnapshot? get latest => _latest;

  /// Whether the monitor is actively subscribed to the input stream.
  bool get isRunning => _subscription != null;

  /// Whether this monitor has been disposed.
  bool get isDisposed => _isDisposed;

  /// Current number of items in the bounded history window.
  int get historyLength => _history.length;

  /// Unmodifiable view of historical status updates leading up to current.
  List<VGStreamingOfflineAssetDownloadStatus> get history =>
      List.unmodifiable(_history);

  /// Updates monitor configuration for subsequent evaluations, immediately trimming history if needed.
  void updateConfig(VGStreamingOfflineAssetLifecycleMonitorConfig config) {
    if (_isDisposed) {
      return;
    }
    _config = config;
    while (_history.length > _config.maxHistoryLength) {
      _history.removeAt(0);
    }
  }

  /// Starts listening to [statuses].
  ///
  /// Idempotent. If already running or disposed, this is a no-op.
  void start() {
    if (_isDisposed || isRunning) {
      return;
    }
    _subscription = statuses.listen(
      (status) {
        if (!_isDisposed) {
          evaluateOnce(status);
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
  ///
  /// Does NOT close or cancel the input stream.
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    stop();
    await _snapshotsController.close();
  }

  /// Evaluates a single [VGStreamingOfflineAssetDownloadStatus], updates bounded history,
  /// updates [latest], emits to [snapshots] if not disposed, and returns the snapshot.
  ///
  /// If [isDisposed] is true, returns [latest] if available, or synthesizes a one-off
  /// snapshot from [status] without mutating history or emitting events.
  VGStreamingOfflineAssetLifecycleSnapshot evaluateOnce(
    VGStreamingOfflineAssetDownloadStatus status,
  ) {
    if (_isDisposed) {
      if (_latest != null) {
        return _latest!;
      }
      final summary = VGStreamingOfflineAssetLifecycleSummarizer.summarize([
        status,
      ]);
      return VGStreamingOfflineAssetLifecycleSnapshot(
        status: status,
        summary: summary,
        historyLength: _history.length,
        advisoryOnly: true,
        playbackMutation: false,
        diagnostics: const <String, Object?>{
          'phase': 'Phase4C7BK',
          'disposed': true,
          'advisoryOnly': true,
          'playbackMutation': false,
        },
      );
    }

    if (!_config.emitDuplicateStatuses && _latest != null) {
      final prevStatus = _latest!.status;
      final isDuplicate =
          status.requestId == prevStatus.requestId &&
          status.sourceKey == prevStatus.sourceKey &&
          status.state == prevStatus.state &&
          status.bytesDownloaded == prevStatus.bytesDownloaded &&
          status.totalBytes == prevStatus.totalBytes &&
          status.assetUri == prevStatus.assetUri;
      if (isDuplicate) {
        return _latest!;
      }
    }

    _history.add(status);
    while (_history.length > _config.maxHistoryLength) {
      _history.removeAt(0);
    }

    final summary = VGStreamingOfflineAssetLifecycleSummarizer.summarize(
      _history,
    );

    final diagnostics = <String, Object?>{
      'phase': 'Phase4C7BK',
      'historyLength': _history.length,
      'maxHistoryLength': _config.maxHistoryLength,
      'emitDuplicateStatuses': _config.emitDuplicateStatuses,
      'isRunning': isRunning,
      'isDisposed': _isDisposed,
      'advisoryOnly': true,
      'playbackMutation': false,
      if (_lastStreamError != null) 'lastStreamError': _lastStreamError,
    };

    final snapshot = VGStreamingOfflineAssetLifecycleSnapshot(
      status: status,
      summary: summary,
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
      'VGStreamingOfflineAssetLifecycleMonitor(isRunning=$isRunning, '
      'isDisposed=$isDisposed, historyLength=${_history.length}, '
      'latest=$_latest)';
}
