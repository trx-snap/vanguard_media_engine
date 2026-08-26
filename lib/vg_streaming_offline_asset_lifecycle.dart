// Copyright (c) Connects — Vanguard Phase 4C7BH.
// Public streaming offline asset lifecycle status model.
//
// Pure Dart status and lifecycle model: provides structured data contracts
// and summary helpers for tracking streaming offline asset acquisition/download
// state transitions. This model defines the shared status surface future native
// offline download implementations can map into, without coupling to native
// downloads, platform method channels, playback mutations, or caching policies.
// The current iOS Swift loopback proxy cache remains online repeat-view/data-saving
// cache only; true offline HLS asset acquisition and playback will use Apple
// AVFoundation offline asset APIs in a later native lifecycle slice. DASH on iOS
// remains unsupported/deferred, and ABR remains player-owned.

import 'vg_streaming_playback_route_plan.dart';

export 'vg_streaming_playback_route_plan.dart'
    show
        VGStreamingFormatHint,
        VGStreamingOfflineAssetAvailability,
        VGStreamingOfflineAssetState;
export 'vg_streaming_offline_asset_acquisition_plan.dart'
    show
        VGStreamingOfflineAssetAcquisitionPriority,
        VGStreamingOfflineAssetAcquisitionRequest;

const Object _sentinel = Object();

/// State of an offline streaming asset acquisition/download task.
enum VGStreamingOfflineAssetDownloadState {
  /// Download task is queued and waiting to be scheduled by the engine or platform.
  queued,

  /// Download task is actively running and transferring media segments to local storage.
  running,

  /// Download task completed successfully; asset package is available on local disk.
  succeeded,

  /// Download task failed due to network error, decode error, or storage failure.
  failed,

  /// Download task was cancelled by user request or host lifecycle teardown.
  cancelled,

  /// Download task or stored asset expired according to license/policy limits.
  expired,

  /// Source format, DRM profile, or client platform is unsupported for offline storage.
  unsupported,

  /// Source manifest or offline asset package could not be found on server or local disk.
  notFound,

  /// Download state is unrecognized or has not yet been probed.
  unknown;

  /// Parses a dynamic string or object into a [VGStreamingOfflineAssetDownloadState].
  ///
  /// Normalizes input case-insensitively and strips hyphens, underscores, and spaces.
  /// Unrecognized or null inputs default to [VGStreamingOfflineAssetDownloadState.unknown].
  static VGStreamingOfflineAssetDownloadState parse(Object? raw) {
    if (raw == null) {
      return VGStreamingOfflineAssetDownloadState.unknown;
    }
    if (raw is VGStreamingOfflineAssetDownloadState) {
      return raw;
    }

    final normalized = raw
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll('-', '')
        .replaceAll('_', '')
        .replaceAll(' ', '');

    return switch (normalized) {
      'queued' ||
      'pending' ||
      'enqueued' ||
      'waiting' => VGStreamingOfflineAssetDownloadState.queued,
      'running' ||
      'inprogress' ||
      'downloading' ||
      'active' ||
      'started' ||
      'transferring' => VGStreamingOfflineAssetDownloadState.running,
      'succeeded' ||
      'success' ||
      'completed' ||
      'complete' ||
      'finished' ||
      'done' ||
      'available' => VGStreamingOfflineAssetDownloadState.succeeded,
      'failed' ||
      'failure' ||
      'error' ||
      'errored' => VGStreamingOfflineAssetDownloadState.failed,
      'cancelled' ||
      'canceled' ||
      'aborted' ||
      'stopped' => VGStreamingOfflineAssetDownloadState.cancelled,
      'expired' => VGStreamingOfflineAssetDownloadState.expired,
      'unsupported' => VGStreamingOfflineAssetDownloadState.unsupported,
      'notfound' => VGStreamingOfflineAssetDownloadState.notFound,
      _ => VGStreamingOfflineAssetDownloadState.unknown,
    };
  }
}

/// Convenience extensions on [VGStreamingOfflineAssetDownloadState].
extension VGStreamingOfflineAssetDownloadStateX
    on VGStreamingOfflineAssetDownloadState {
  /// Whether this state is a terminal lifecycle state.
  ///
  /// Terminal states include [succeeded], [failed], [cancelled], [expired],
  /// [unsupported], and [notFound]. Non-terminal states include [queued],
  /// [running], and [unknown].
  bool get isTerminal => switch (this) {
    VGStreamingOfflineAssetDownloadState.succeeded ||
    VGStreamingOfflineAssetDownloadState.failed ||
    VGStreamingOfflineAssetDownloadState.cancelled ||
    VGStreamingOfflineAssetDownloadState.expired ||
    VGStreamingOfflineAssetDownloadState.unsupported ||
    VGStreamingOfflineAssetDownloadState.notFound => true,
    VGStreamingOfflineAssetDownloadState.queued ||
    VGStreamingOfflineAssetDownloadState.running ||
    VGStreamingOfflineAssetDownloadState.unknown => false,
  };

  /// Whether this state indicates successful acquisition completion.
  bool get isSuccessful =>
      this == VGStreamingOfflineAssetDownloadState.succeeded;

  /// Whether this state represents a terminal failure or error condition.
  ///
  /// Includes [failed], [cancelled], [expired], [unsupported], and [notFound].
  bool get isFailure => switch (this) {
    VGStreamingOfflineAssetDownloadState.failed ||
    VGStreamingOfflineAssetDownloadState.cancelled ||
    VGStreamingOfflineAssetDownloadState.expired ||
    VGStreamingOfflineAssetDownloadState.unsupported ||
    VGStreamingOfflineAssetDownloadState.notFound => true,
    VGStreamingOfflineAssetDownloadState.queued ||
    VGStreamingOfflineAssetDownloadState.running ||
    VGStreamingOfflineAssetDownloadState.succeeded ||
    VGStreamingOfflineAssetDownloadState.unknown => false,
  };
}

/// Immutable record of an offline streaming asset acquisition/download status.
class VGStreamingOfflineAssetDownloadStatus {
  /// Deterministic identifier of the acquisition request.
  final String requestId;

  /// Key of the source descriptor this download applies to.
  final String sourceKey;

  /// Current download lifecycle state.
  final VGStreamingOfflineAssetDownloadState state;

  /// Cumulative bytes downloaded to local storage so far.
  final int bytesDownloaded;

  /// Total expected bytes of the asset, or `null` if unknown.
  final int? totalBytes;

  /// Local file URI pointing to the stored asset package or manifest, if available.
  final Uri? assetUri;

  /// Optional platform/network error code on failure.
  final String? errorCode;

  /// Optional descriptive error message on failure.
  final String? errorMessage;

  /// Milliseconds since Unix epoch when acquisition started, or `null` if unstarted.
  final int? startedAtUnixMs;

  /// Milliseconds since Unix epoch when status was last updated, or `null` if unknown.
  final int? updatedAtUnixMs;

  /// Milliseconds since Unix epoch when acquisition finished/terminated, or `null` if active.
  final int? completedAtUnixMs;

  /// Diagnostic telemetry metadata.
  final Map<String, Object?> diagnostics;

  VGStreamingOfflineAssetDownloadStatus({
    required this.requestId,
    required this.sourceKey,
    this.state = VGStreamingOfflineAssetDownloadState.unknown,
    this.bytesDownloaded = 0,
    this.totalBytes,
    this.assetUri,
    this.errorCode,
    this.errorMessage,
    this.startedAtUnixMs,
    this.updatedAtUnixMs,
    this.completedAtUnixMs,
    Map<String, Object?> diagnostics = const {},
  }) : assert(requestId.isNotEmpty, 'requestId must not be empty'),
       assert(sourceKey.isNotEmpty, 'sourceKey must not be empty'),
       assert(bytesDownloaded >= 0, 'bytesDownloaded must be >= 0'),
       assert(
         totalBytes == null || totalBytes >= 0,
         'totalBytes must be null or >= 0',
       ),
       assert(
         startedAtUnixMs == null || startedAtUnixMs >= 0,
         'startedAtUnixMs must be null or >= 0',
       ),
       assert(
         updatedAtUnixMs == null || updatedAtUnixMs >= 0,
         'updatedAtUnixMs must be null or >= 0',
       ),
       assert(
         completedAtUnixMs == null || completedAtUnixMs >= 0,
         'completedAtUnixMs must be null or >= 0',
       ),
       diagnostics = Map.unmodifiable(diagnostics);

  /// Creates a download status from a loosely typed map (e.g. from platform channels or JSON).
  factory VGStreamingOfflineAssetDownloadStatus.fromMap(
    Map<Object?, Object?> map,
  ) {
    final rawRequestId = map['requestId']?.toString().trim();
    final requestId = (rawRequestId != null && rawRequestId.isNotEmpty)
        ? rawRequestId
        : 'unknown_request';

    final rawSourceKey = map['sourceKey']?.toString().trim();
    final sourceKey = (rawSourceKey != null && rawSourceKey.isNotEmpty)
        ? rawSourceKey
        : 'unknown_source';

    final state = VGStreamingOfflineAssetDownloadState.parse(map['state']);

    final rawBytesDownloaded = (map['bytesDownloaded'] as num?)?.toInt() ?? 0;
    final bytesDownloaded = rawBytesDownloaded < 0 ? 0 : rawBytesDownloaded;

    final rawTotalBytes = (map['totalBytes'] as num?)?.toInt();
    final totalBytes = (rawTotalBytes != null && rawTotalBytes >= 0)
        ? rawTotalBytes
        : null;

    final rawAssetUri = map['assetUri']?.toString().trim();
    final assetUri = (rawAssetUri != null && rawAssetUri.isNotEmpty)
        ? Uri.tryParse(rawAssetUri)
        : null;

    final errorCode = map['errorCode']?.toString();
    final errorMessage = map['errorMessage']?.toString();

    final rawStartedAt = (map['startedAtUnixMs'] as num?)?.toInt();
    final startedAtUnixMs = (rawStartedAt != null && rawStartedAt >= 0)
        ? rawStartedAt
        : null;

    final rawUpdatedAt = (map['updatedAtUnixMs'] as num?)?.toInt();
    final updatedAtUnixMs = (rawUpdatedAt != null && rawUpdatedAt >= 0)
        ? rawUpdatedAt
        : null;

    final rawCompletedAt = (map['completedAtUnixMs'] as num?)?.toInt();
    final completedAtUnixMs = (rawCompletedAt != null && rawCompletedAt >= 0)
        ? rawCompletedAt
        : null;

    final rawDiagnostics = map['diagnostics'];
    final diagnostics = <String, Object?>{};
    if (rawDiagnostics is Map) {
      for (final entry in rawDiagnostics.entries) {
        if (entry.key != null) {
          diagnostics[entry.key.toString()] = entry.value;
        }
      }
    }

    return VGStreamingOfflineAssetDownloadStatus(
      requestId: requestId,
      sourceKey: sourceKey,
      state: state,
      bytesDownloaded: bytesDownloaded,
      totalBytes: totalBytes,
      assetUri: assetUri,
      errorCode: errorCode,
      errorMessage: errorMessage,
      startedAtUnixMs: startedAtUnixMs,
      updatedAtUnixMs: updatedAtUnixMs,
      completedAtUnixMs: completedAtUnixMs,
      diagnostics: diagnostics,
    );
  }

  /// Whether this download has reached a terminal lifecycle state.
  bool get isTerminal => state.isTerminal;

  /// Whether this download succeeded and completed.
  bool get isSuccessful => state.isSuccessful;

  /// Whether this download ended in failure or cancellation.
  bool get isFailure => state.isFailure;

  /// Normalized download progress fraction clamped to `0.0..1.0`.
  ///
  /// Returns `null` if [totalBytes] is `null` or `<= 0`.
  double? get progressFraction {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (bytesDownloaded / total).clamp(0.0, 1.0);
  }

  /// Derives an offline asset availability descriptor if acquisition completed successfully.
  ///
  /// Returns non-null [VGStreamingOfflineAssetAvailability] only when [state] is
  /// [VGStreamingOfflineAssetDownloadState.succeeded] and [assetUri] is present.
  VGStreamingOfflineAssetAvailability? get availability {
    if (state == VGStreamingOfflineAssetDownloadState.succeeded &&
        assetUri != null) {
      return VGStreamingOfflineAssetAvailability(
        sourceKey: sourceKey,
        state: VGStreamingOfflineAssetState.available,
        assetUri: assetUri,
        downloadedBytes: bytesDownloaded,
      );
    }
    return null;
  }

  /// Creates a copy of this download status with the specified fields replaced.
  VGStreamingOfflineAssetDownloadStatus copyWith({
    String? requestId,
    String? sourceKey,
    VGStreamingOfflineAssetDownloadState? state,
    int? bytesDownloaded,
    Object? totalBytes = _sentinel,
    Object? assetUri = _sentinel,
    Object? errorCode = _sentinel,
    Object? errorMessage = _sentinel,
    Object? startedAtUnixMs = _sentinel,
    Object? updatedAtUnixMs = _sentinel,
    Object? completedAtUnixMs = _sentinel,
    Map<String, Object?>? diagnostics,
  }) {
    return VGStreamingOfflineAssetDownloadStatus(
      requestId: requestId ?? this.requestId,
      sourceKey: sourceKey ?? this.sourceKey,
      state: state ?? this.state,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      totalBytes: identical(totalBytes, _sentinel)
          ? this.totalBytes
          : totalBytes as int?,
      assetUri: identical(assetUri, _sentinel)
          ? this.assetUri
          : assetUri as Uri?,
      errorCode: identical(errorCode, _sentinel)
          ? this.errorCode
          : errorCode as String?,
      errorMessage: identical(errorMessage, _sentinel)
          ? this.errorMessage
          : errorMessage as String?,
      startedAtUnixMs: identical(startedAtUnixMs, _sentinel)
          ? this.startedAtUnixMs
          : startedAtUnixMs as int?,
      updatedAtUnixMs: identical(updatedAtUnixMs, _sentinel)
          ? this.updatedAtUnixMs
          : updatedAtUnixMs as int?,
      completedAtUnixMs: identical(completedAtUnixMs, _sentinel)
          ? this.completedAtUnixMs
          : completedAtUnixMs as int?,
      diagnostics: diagnostics ?? this.diagnostics,
    );
  }

  /// Converts this status to a primitive map for serialization and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'requestId': requestId,
    'sourceKey': sourceKey,
    'state': state.name,
    'bytesDownloaded': bytesDownloaded,
    'totalBytes': totalBytes,
    'assetUri': assetUri?.toString(),
    'errorCode': errorCode,
    'errorMessage': errorMessage,
    'startedAtUnixMs': startedAtUnixMs,
    'updatedAtUnixMs': updatedAtUnixMs,
    'completedAtUnixMs': completedAtUnixMs,
    'isTerminal': isTerminal,
    'isSuccessful': isSuccessful,
    'isFailure': isFailure,
    'progressFraction': progressFraction,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingOfflineAssetDownloadStatus('
      'requestId=$requestId, sourceKey=$sourceKey, state=${state.name}, '
      'bytesDownloaded=$bytesDownloaded, totalBytes=$totalBytes, '
      'progressFraction=$progressFraction, assetUri=$assetUri, '
      'isTerminal=$isTerminal, isSuccessful=$isSuccessful, isFailure=$isFailure, '
      'errorCode=$errorCode, errorMessage=$errorMessage)';
}

/// Immutable aggregated summary of offline asset download tasks.
class VGStreamingOfflineAssetLifecycleSummary {
  /// Total number of tracked download requests.
  final int totalCount;

  /// Number of downloads in [VGStreamingOfflineAssetDownloadState.queued] state.
  final int queuedCount;

  /// Number of downloads in [VGStreamingOfflineAssetDownloadState.running] state.
  final int runningCount;

  /// Number of downloads in [VGStreamingOfflineAssetDownloadState.succeeded] state.
  final int succeededCount;

  /// Number of downloads in [VGStreamingOfflineAssetDownloadState.failed] state.
  final int failedCount;

  /// Number of downloads in [VGStreamingOfflineAssetDownloadState.cancelled] state.
  final int cancelledCount;

  /// Number of downloads in [VGStreamingOfflineAssetDownloadState.expired] state.
  final int expiredCount;

  /// Number of downloads in [VGStreamingOfflineAssetDownloadState.unsupported] state.
  final int unsupportedCount;

  /// Number of downloads in [VGStreamingOfflineAssetDownloadState.notFound] state.
  final int notFoundCount;

  /// Number of downloads in [VGStreamingOfflineAssetDownloadState.unknown] state.
  final int unknownCount;

  /// Total number of downloads in terminal states.
  final int terminalCount;

  /// Cumulative total bytes downloaded across all tracked download tasks.
  final int totalBytesDownloaded;

  /// List of request IDs for currently active (queued or running) downloads.
  final List<String> activeRequestIds;

  /// List of request IDs for downloads in terminal states.
  final List<String> terminalRequestIds;

  /// Diagnostic telemetry metadata.
  final Map<String, Object?> diagnostics;

  VGStreamingOfflineAssetLifecycleSummary({
    this.totalCount = 0,
    this.queuedCount = 0,
    this.runningCount = 0,
    this.succeededCount = 0,
    this.failedCount = 0,
    this.cancelledCount = 0,
    this.expiredCount = 0,
    this.unsupportedCount = 0,
    this.notFoundCount = 0,
    this.unknownCount = 0,
    this.terminalCount = 0,
    this.totalBytesDownloaded = 0,
    List<String> activeRequestIds = const [],
    List<String> terminalRequestIds = const [],
    Map<String, Object?> diagnostics = const {},
  }) : activeRequestIds = List.unmodifiable(activeRequestIds),
       terminalRequestIds = List.unmodifiable(terminalRequestIds),
       diagnostics = Map.unmodifiable(diagnostics);

  /// Whether there are any active (queued or running) downloads.
  bool get hasActiveDownloads => activeRequestIds.isNotEmpty;

  /// Whether all tracked downloads have reached a terminal state (or if no downloads are tracked).
  bool get allTerminal => totalCount == 0 || terminalCount == totalCount;

  /// Converts this summary to a primitive map for serialization and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'totalCount': totalCount,
    'queuedCount': queuedCount,
    'runningCount': runningCount,
    'succeededCount': succeededCount,
    'failedCount': failedCount,
    'cancelledCount': cancelledCount,
    'expiredCount': expiredCount,
    'unsupportedCount': unsupportedCount,
    'notFoundCount': notFoundCount,
    'unknownCount': unknownCount,
    'terminalCount': terminalCount,
    'totalBytesDownloaded': totalBytesDownloaded,
    'activeRequestIds': activeRequestIds,
    'terminalRequestIds': terminalRequestIds,
    'hasActiveDownloads': hasActiveDownloads,
    'allTerminal': allTerminal,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingOfflineAssetLifecycleSummary('
      'totalCount=$totalCount, active=${activeRequestIds.length}, '
      'terminal=$terminalCount, totalBytesDownloaded=$totalBytesDownloaded, '
      'hasActiveDownloads=$hasActiveDownloads, allTerminal=$allTerminal)';
}

/// Pure Dart summarizer for aggregating offline asset download statuses.
abstract final class VGStreamingOfflineAssetLifecycleSummarizer {
  /// Aggregates an iterable of [VGStreamingOfflineAssetDownloadStatus] into an immutable [VGStreamingOfflineAssetLifecycleSummary].
  static VGStreamingOfflineAssetLifecycleSummary summarize(
    Iterable<VGStreamingOfflineAssetDownloadStatus> statuses,
  ) {
    var totalCount = 0;
    var queuedCount = 0;
    var runningCount = 0;
    var succeededCount = 0;
    var failedCount = 0;
    var cancelledCount = 0;
    var expiredCount = 0;
    var unsupportedCount = 0;
    var notFoundCount = 0;
    var unknownCount = 0;
    var terminalCount = 0;
    var totalBytesDownloaded = 0;

    final activeRequestIds = <String>[];
    final terminalRequestIds = <String>[];

    for (final status in statuses) {
      totalCount++;
      totalBytesDownloaded += status.bytesDownloaded;

      switch (status.state) {
        case VGStreamingOfflineAssetDownloadState.queued:
          queuedCount++;
          activeRequestIds.add(status.requestId);
        case VGStreamingOfflineAssetDownloadState.running:
          runningCount++;
          activeRequestIds.add(status.requestId);
        case VGStreamingOfflineAssetDownloadState.succeeded:
          succeededCount++;
          terminalCount++;
          terminalRequestIds.add(status.requestId);
        case VGStreamingOfflineAssetDownloadState.failed:
          failedCount++;
          terminalCount++;
          terminalRequestIds.add(status.requestId);
        case VGStreamingOfflineAssetDownloadState.cancelled:
          cancelledCount++;
          terminalCount++;
          terminalRequestIds.add(status.requestId);
        case VGStreamingOfflineAssetDownloadState.expired:
          expiredCount++;
          terminalCount++;
          terminalRequestIds.add(status.requestId);
        case VGStreamingOfflineAssetDownloadState.unsupported:
          unsupportedCount++;
          terminalCount++;
          terminalRequestIds.add(status.requestId);
        case VGStreamingOfflineAssetDownloadState.notFound:
          notFoundCount++;
          terminalCount++;
          terminalRequestIds.add(status.requestId);
        case VGStreamingOfflineAssetDownloadState.unknown:
          unknownCount++;
      }
    }

    final diagnostics = <String, Object?>{
      'advisoryOnly': true,
      'playbackMutation': false,
      'totalCount': totalCount,
      'activeCount': activeRequestIds.length,
      'terminalCount': terminalCount,
      'totalBytesDownloaded': totalBytesDownloaded,
    };

    return VGStreamingOfflineAssetLifecycleSummary(
      totalCount: totalCount,
      queuedCount: queuedCount,
      runningCount: runningCount,
      succeededCount: succeededCount,
      failedCount: failedCount,
      cancelledCount: cancelledCount,
      expiredCount: expiredCount,
      unsupportedCount: unsupportedCount,
      notFoundCount: notFoundCount,
      unknownCount: unknownCount,
      terminalCount: terminalCount,
      totalBytesDownloaded: totalBytesDownloaded,
      activeRequestIds: activeRequestIds,
      terminalRequestIds: terminalRequestIds,
      diagnostics: diagnostics,
    );
  }
}
