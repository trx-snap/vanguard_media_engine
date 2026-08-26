// Copyright (c) Connects — Vanguard Phase 4C7BJ.
// Public streaming offline asset status poller helper.
//
// Pure Dart periodic telemetry poller over VGStreamingOfflineAssetClient.
// Provides broadcast Stream<VGStreamingOfflineAssetDownloadStatus> and synchronous
// latest status cache without busy-polling collisions or native coupling.
//
// Bounded convenience wrapper: does NOT make product feed decisions,
// retry policy, ABR decisions, caching policy, filesystem operations,
// or native lifecycle decisions.

import 'dart:async';

import 'vg_streaming_offline_asset_client.dart';
import 'vg_streaming_offline_asset_lifecycle.dart';

export 'vg_streaming_offline_asset_client.dart'
    show
        VGStreamingOfflineAssetAcquisitionStartState,
        VGStreamingOfflineAssetAcquisitionStartResult,
        VGStreamingOfflineAssetAvailabilityResult,
        VGStreamingOfflineAssetClient,
        VGStreamingOfflineAssetCommandResult,
        VGStreamingOfflineAssetCommandState;
export 'vg_streaming_offline_asset_lifecycle.dart'
    show
        VGStreamingOfflineAssetDownloadState,
        VGStreamingOfflineAssetDownloadStatus;

/// Immutable configuration options for [VGStreamingOfflineAssetStatusPoller].
class VGStreamingOfflineAssetStatusPollerConfig {
  /// Polling interval between status queries. Defaults to 500 milliseconds.
  final Duration interval;

  /// Whether to emit an initial status update immediately when [VGStreamingOfflineAssetStatusPoller.start] is called.
  /// Defaults to `true`.
  final bool emitInitialStatus;

  /// Whether to automatically stop polling when a terminal download status is observed.
  /// Defaults to `true`.
  final bool stopWhenTerminal;

  VGStreamingOfflineAssetStatusPollerConfig({
    this.interval = const Duration(milliseconds: 500),
    this.emitInitialStatus = true,
    this.stopWhenTerminal = true,
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
      'VGStreamingOfflineAssetStatusPollerConfig(interval=${interval.inMilliseconds}ms, '
      'emitInitialStatus=$emitInitialStatus, stopWhenTerminal=$stopWhenTerminal)';
}

/// Bounded public Dart status poller over [VGStreamingOfflineAssetClient].
///
/// Periodically queries the offline asset client for status updates, caches the
/// most recently observed [VGStreamingOfflineAssetDownloadStatus], and emits updates
/// over a broadcast stream.
///
/// Prevents overlapping refresh operations and safeguards callers from polling
/// exceptions or disposal lifecycle races.
///
/// NOTE: This poller does NOT own or dispose the underlying [client].
class VGStreamingOfflineAssetStatusPoller {
  /// The underlying offline asset client being polled.
  final VGStreamingOfflineAssetClient client;

  /// Unique acquisition task identifier being polled.
  final String requestId;

  /// Optional source descriptor key for catalog lookup.
  final String? sourceKey;

  /// Immutable configuration for this poller.
  final VGStreamingOfflineAssetStatusPollerConfig config;

  final StreamController<VGStreamingOfflineAssetDownloadStatus>
  _statusController =
      StreamController<VGStreamingOfflineAssetDownloadStatus>.broadcast();

  Timer? _timer;
  bool _isRefreshing = false;
  bool _isDisposed = false;
  VGStreamingOfflineAssetDownloadStatus _latest;

  VGStreamingOfflineAssetStatusPoller({
    required this.client,
    required String requestId,
    String? sourceKey,
    VGStreamingOfflineAssetStatusPollerConfig? config,
  }) : requestId = _validateRequestId(requestId),
       sourceKey = _validateSourceKey(sourceKey),
       config = config ?? VGStreamingOfflineAssetStatusPollerConfig(),
       _latest = VGStreamingOfflineAssetDownloadStatus(
         requestId: _validateRequestId(requestId),
         sourceKey: (sourceKey != null && sourceKey.trim().isNotEmpty)
             ? sourceKey
             : 'unknown_source',
         state: VGStreamingOfflineAssetDownloadState.unknown,
         diagnostics: const <String, Object?>{
           'phase': 'Phase4C7BJ',
           'advisoryOnly': true,
           'playbackMutation': false,
         },
       );

  static String _validateRequestId(String requestId) {
    if (requestId.trim().isEmpty) {
      throw ArgumentError.value(requestId, 'requestId', 'must not be empty');
    }
    return requestId;
  }

  static String? _validateSourceKey(String? sourceKey) {
    if (sourceKey != null && sourceKey.trim().isEmpty) {
      throw ArgumentError.value(
        sourceKey,
        'sourceKey',
        'must not be blank if supplied',
      );
    }
    return sourceKey;
  }

  /// Broadcast stream of [VGStreamingOfflineAssetDownloadStatus] updates.
  Stream<VGStreamingOfflineAssetDownloadStatus> get statuses =>
      _statusController.stream;

  /// Most recently observed [VGStreamingOfflineAssetDownloadStatus].
  VGStreamingOfflineAssetDownloadStatus get latest => _latest;

  /// Whether periodic polling is actively running.
  bool get isRunning => _timer != null && _timer!.isActive;

  /// Whether this poller has been disposed.
  bool get isDisposed => _isDisposed;

  /// Manually triggers a single status refresh cycle.
  ///
  /// Returns the resulting [VGStreamingOfflineAssetDownloadStatus].
  /// If disposed or if a refresh is already in flight, returns [latest] without error.
  Future<VGStreamingOfflineAssetDownloadStatus> refreshOnce() async {
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
      VGStreamingOfflineAssetDownloadStatus status;
      try {
        status = await client.getStatus(
          requestId: requestId,
          sourceKey: sourceKey,
        );
      } catch (_) {
        status = _latest;
      }

      if (!_isDisposed) {
        _latest = status;
        if (!_statusController.isClosed) {
          _statusController.add(status);
        }
        if (config.stopWhenTerminal && status.isTerminal) {
          stop();
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
  /// If [config.emitInitialStatus] is true, triggers an initial async refresh tick.
  void start() {
    if (_isDisposed || isRunning) {
      return;
    }
    if (config.emitInitialStatus) {
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
  /// Does NOT dispose the underlying [client].
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    stop();
    await _statusController.close();
  }

  @override
  String toString() =>
      'VGStreamingOfflineAssetStatusPoller(requestId=$requestId, sourceKey=$sourceKey, '
      'isRunning=$isRunning, isDisposed=$isDisposed, '
      'interval=${config.interval.inMilliseconds}ms, latest=$_latest)';
}
