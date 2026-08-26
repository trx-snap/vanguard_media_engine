// Copyright (c) Connects — Vanguard Phase 4C7BF.
// Public streaming offline asset acquisition request planner.
//
// Pure Dart advisory helper: turns an existing VGStreamingOfflineAssetEligibilityPlan
// into deterministic, budgeted, prioritized offline acquisition requests for a
// future native offline downloader without native download/playback coupling or side
// effects. The current iOS Swift loopback proxy cache remains online
// repeat-view/data-saving cache only; true offline HLS asset acquisition will use
// Apple AVFoundation offline asset APIs in a later native lifecycle slice. DASH on
// iOS remains unsupported/deferred, and ABR remains player-owned.

import 'vg_streaming_offline_asset_eligibility.dart';

export 'vg_streaming_offline_asset_eligibility.dart'
    show
        VGStreamingFormatHint,
        VGStreamingOfflineAssetCandidate,
        VGStreamingOfflineAssetEligibilityPlan,
        VGStreamingOfflineAssetEligibilityPlanner,
        VGStreamingOfflineAssetEligibilityRequest;

/// Priority level for an offline streaming asset acquisition request.
enum VGStreamingOfflineAssetAcquisitionPriority {
  urgent(4),
  high(3),
  normal(2),
  low(1);

  /// Relative numeric rank for priority sorting (higher value indicates higher priority).
  final int rank;

  const VGStreamingOfflineAssetAcquisitionPriority(this.rank);
}

/// Immutable request to acquire an eligible streaming asset for offline playback.
class VGStreamingOfflineAssetAcquisitionRequest {
  /// Deterministic identifier for this acquisition request.
  final String requestId;

  /// Key of the source descriptor this acquisition applies to.
  final String sourceKey;

  /// Manifest URI to acquire for offline storage.
  final Uri uri;

  /// Optional HTTP request headers required to fetch the manifest and segments.
  final Map<String, String>? httpHeaders;

  /// Format hint of the underlying stream.
  final VGStreamingFormatHint formatHint;

  /// Whether the stream requires LL-HLS tags.
  final bool requireLlHlsTags;

  /// Estimated byte size of the acquired asset.
  final int estimatedBytes;

  /// Priority level for scheduling acquisition.
  final VGStreamingOfflineAssetAcquisitionPriority priority;

  /// Optional rationale or caller-specified reason for this request.
  final String? reason;

  VGStreamingOfflineAssetAcquisitionRequest({
    required this.requestId,
    required this.sourceKey,
    required this.uri,
    Map<String, String>? httpHeaders,
    this.formatHint = VGStreamingFormatHint.auto,
    this.requireLlHlsTags = false,
    required this.estimatedBytes,
    this.priority = VGStreamingOfflineAssetAcquisitionPriority.normal,
    this.reason,
  }) : assert(requestId.isNotEmpty, 'requestId must not be empty'),
       assert(sourceKey.isNotEmpty, 'sourceKey must not be empty'),
       assert(estimatedBytes > 0, 'estimatedBytes must be greater than 0'),
       httpHeaders = httpHeaders == null ? null : Map.unmodifiable(httpHeaders);

  /// Converts this acquisition request to a primitive map for serialization and telemetry.
  Map<String, Object?> toArgs() => <String, Object?>{
    'requestId': requestId,
    'sourceKey': sourceKey,
    'uri': uri.toString(),
    if (httpHeaders != null) 'httpHeaders': httpHeaders,
    'formatHint': formatHint.toNative(),
    'requireLlHlsTags': requireLlHlsTags,
    'estimatedBytes': estimatedBytes,
    'priority': priority.name,
    if (reason != null) 'reason': reason,
  };

  @override
  String toString() =>
      'VGStreamingOfflineAssetAcquisitionRequest(requestId=$requestId, '
      'sourceKey=$sourceKey, uri=$uri, formatHint=${formatHint.name}, '
      'requireLlHlsTags=$requireLlHlsTags, estimatedBytes=$estimatedBytes, '
      'priority=${priority.name}, reason=$reason)';
}

/// Immutable record of an offline asset candidate that was dropped during acquisition planning.
class VGStreamingOfflineAssetDroppedAcquisitionCandidate {
  /// The underlying eligible offline asset candidate that was dropped.
  final VGStreamingOfflineAssetCandidate candidate;

  /// Machine-readable reason why this candidate was dropped.
  final String reason;

  VGStreamingOfflineAssetDroppedAcquisitionCandidate({
    required this.candidate,
    required this.reason,
  }) : assert(reason.isNotEmpty, 'reason must not be empty');

  @override
  String toString() =>
      'VGStreamingOfflineAssetDroppedAcquisitionCandidate('
      'candidate=${candidate.sourceKey}, reason=$reason)';
}

/// Immutable result of offline streaming asset acquisition planning.
class VGStreamingOfflineAssetAcquisitionPlan {
  /// Ordered list of budgeted acquisition requests ready for native acquisition scheduling.
  final List<VGStreamingOfflineAssetAcquisitionRequest> requests;

  /// List of candidates that were dropped during acquisition planning (e.g. budget exceeded).
  final List<VGStreamingOfflineAssetDroppedAcquisitionCandidate>
  droppedCandidates;

  /// Advisory warnings emitted during planning or propagated from eligibility evaluation.
  final List<String> warnings;

  /// Diagnostic metadata for telemetry and auditing.
  final Map<String, Object?> diagnostics;

  VGStreamingOfflineAssetAcquisitionPlan({
    List<VGStreamingOfflineAssetAcquisitionRequest> requests = const [],
    List<VGStreamingOfflineAssetDroppedAcquisitionCandidate> droppedCandidates =
        const [],
    List<String> warnings = const [],
    Map<String, Object?> diagnostics = const {},
  }) : requests = List.unmodifiable(requests),
       droppedCandidates = List.unmodifiable(droppedCandidates),
       warnings = List.unmodifiable(warnings),
       diagnostics = Map.unmodifiable(diagnostics);

  /// Whether the plan contains at least one acquisition request.
  bool get hasRequests => requests.isNotEmpty;

  /// Whether any eligible candidate was dropped during acquisition planning.
  bool get hasDrops => droppedCandidates.isNotEmpty;

  /// Total estimated bytes across all admitted acquisition requests.
  int get totalEstimatedBytes =>
      requests.fold<int>(0, (sum, r) => sum + r.estimatedBytes);

  @override
  String toString() =>
      'VGStreamingOfflineAssetAcquisitionPlan(requests=${requests.length}, '
      'droppedCandidates=${droppedCandidates.length}, '
      'totalEstimatedBytes=$totalEstimatedBytes, warnings=$warnings)';
}

class _IndexedCandidateItem {
  final int originalIndex;
  final VGStreamingOfflineAssetCandidate candidate;
  final VGStreamingOfflineAssetAcquisitionPriority priority;
  final int estimatedBytes;
  final String? reason;
  final String requestId;

  const _IndexedCandidateItem({
    required this.originalIndex,
    required this.candidate,
    required this.priority,
    required this.estimatedBytes,
    required this.reason,
    required this.requestId,
  });
}

/// Pure Dart planning utility that converts an eligibility plan into prioritized, budgeted acquisition requests.
abstract final class VGStreamingOfflineAssetAcquisitionPlanner {
  /// Evaluates [eligibilityPlan] candidates, applies priority ordering, assigns deterministic request IDs,
  /// bounds requests against [maxTotalEstimatedBytesBudget], and returns an immutable [VGStreamingOfflineAssetAcquisitionPlan].
  static VGStreamingOfflineAssetAcquisitionPlan plan({
    required VGStreamingOfflineAssetEligibilityPlan eligibilityPlan,
    required String requestIdPrefix,
    int defaultEstimatedBytes = 64 * 1024 * 1024,
    int? maxTotalEstimatedBytesBudget,
    Map<String, VGStreamingOfflineAssetAcquisitionPriority>
        prioritiesBySourceKey =
        const {},
    Map<String, int> estimatedBytesBySourceKey = const {},
    Map<String, String> reasonsBySourceKey = const {},
    VGStreamingOfflineAssetAcquisitionPriority defaultPriority =
        VGStreamingOfflineAssetAcquisitionPriority.normal,
  }) {
    assert(requestIdPrefix.isNotEmpty, 'requestIdPrefix must not be empty');
    assert(
      defaultEstimatedBytes > 0,
      'defaultEstimatedBytes must be greater than 0',
    );
    assert(
      maxTotalEstimatedBytesBudget == null || maxTotalEstimatedBytesBudget >= 0,
      'maxTotalEstimatedBytesBudget must be null or >= 0',
    );
    assert(
      estimatedBytesBySourceKey.values.every((v) => v > 0),
      'All estimatedBytesBySourceKey values must be greater than 0',
    );

    final warnings = <String>[];
    void addWarning(String w) {
      if (!warnings.contains(w)) {
        warnings.add(w);
      }
    }

    // Propagate eligibility warnings first in encounter order.
    for (final w in eligibilityPlan.warnings) {
      addWarning(w);
    }

    final requests = <VGStreamingOfflineAssetAcquisitionRequest>[];
    final droppedCandidates =
        <VGStreamingOfflineAssetDroppedAcquisitionCandidate>[];

    if (eligibilityPlan.candidates.isEmpty) {
      final diagnostics = <String, Object?>{
        'eligibilityCandidateCount': 0,
        'candidateCount': 0,
        'eligibilityRejectedCount': eligibilityPlan.rejectedSources.length,
        'requestCount': 0,
        'droppedCount': 0,
        'totalEstimatedBytes': 0,
        'maxTotalEstimatedBytesBudget': maxTotalEstimatedBytesBudget,
        'defaultEstimatedBytes': defaultEstimatedBytes,
        'defaultPriority': defaultPriority.name,
        'advisoryOnly': true,
        'playbackMutation': false,
      };

      return VGStreamingOfflineAssetAcquisitionPlan(
        requests: requests,
        droppedCandidates: droppedCandidates,
        warnings: warnings,
        diagnostics: diagnostics,
      );
    }

    // Prepare candidate items with deterministic IDs and overrides.
    final items = <_IndexedCandidateItem>[];
    for (var i = 0; i < eligibilityPlan.candidates.length; i++) {
      final candidate = eligibilityPlan.candidates[i];
      final sourceKey = candidate.sourceKey;
      final priority = prioritiesBySourceKey[sourceKey] ?? defaultPriority;
      final estimatedBytes =
          estimatedBytesBySourceKey[sourceKey] ?? defaultEstimatedBytes;
      final reason = reasonsBySourceKey[sourceKey];
      final requestId = '${requestIdPrefix}_${sourceKey}_$i';

      items.add(
        _IndexedCandidateItem(
          originalIndex: i,
          candidate: candidate,
          priority: priority,
          estimatedBytes: estimatedBytes,
          reason: reason,
          requestId: requestId,
        ),
      );
    }

    // Sort candidates: priority rank descending, original index ascending.
    items.sort((a, b) {
      final rankDiff = b.priority.rank.compareTo(a.priority.rank);
      if (rankDiff != 0) return rankDiff;
      return a.originalIndex.compareTo(b.originalIndex);
    });

    var cumulativeEstimatedBytes = 0;

    for (final item in items) {
      if (maxTotalEstimatedBytesBudget != null) {
        if (cumulativeEstimatedBytes + item.estimatedBytes >
            maxTotalEstimatedBytesBudget) {
          droppedCandidates.add(
            VGStreamingOfflineAssetDroppedAcquisitionCandidate(
              candidate: item.candidate,
              reason: 'estimated_budget_exceeded',
            ),
          );
          addWarning(
            'offline_acquisition_dropped:${item.candidate.sourceKey}:estimated_budget_exceeded',
          );
          continue;
        }
      }

      requests.add(
        VGStreamingOfflineAssetAcquisitionRequest(
          requestId: item.requestId,
          sourceKey: item.candidate.sourceKey,
          uri: item.candidate.uri,
          httpHeaders: item.candidate.httpHeaders,
          formatHint: item.candidate.formatHint,
          requireLlHlsTags: item.candidate.requireLlHlsTags,
          estimatedBytes: item.estimatedBytes,
          priority: item.priority,
          reason: item.reason,
        ),
      );
      cumulativeEstimatedBytes += item.estimatedBytes;
    }

    final diagnostics = <String, Object?>{
      'eligibilityCandidateCount': eligibilityPlan.candidates.length,
      'candidateCount': eligibilityPlan.candidates.length,
      'eligibilityRejectedCount': eligibilityPlan.rejectedSources.length,
      'requestCount': requests.length,
      'droppedCount': droppedCandidates.length,
      'totalEstimatedBytes': cumulativeEstimatedBytes,
      'maxTotalEstimatedBytesBudget': maxTotalEstimatedBytesBudget,
      'defaultEstimatedBytes': defaultEstimatedBytes,
      'defaultPriority': defaultPriority.name,
      'advisoryOnly': true,
      'playbackMutation': false,
    };

    return VGStreamingOfflineAssetAcquisitionPlan(
      requests: requests,
      droppedCandidates: droppedCandidates,
      warnings: warnings,
      diagnostics: diagnostics,
    );
  }
}
