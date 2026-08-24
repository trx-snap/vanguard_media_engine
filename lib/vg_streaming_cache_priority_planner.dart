// Copyright (c) Connects — Vanguard Phase 4C6R.
// Public streaming cache prewarm priority/eviction planner.
//
// Pure Dart planning types: sorts, deduplicates, bounds, and arbitrates
// multi-candidate streaming cache prewarm requests against priority, weights,
// byte budgets, and cache readiness/eviction advisory states.

import 'vg_streaming_cache_client.dart';
import 'vg_streaming_cache_prewarm_plan.dart';

export 'vg_streaming_cache_client.dart'
    show VGPlaybackCacheOptions, VGPlaybackCacheStatus;
export 'vg_streaming_cache_prewarm_plan.dart'
    show VGPlaybackPrewarmRequest, VGStreamingCachePrewarmLowLatencyPolicy;

/// Priority level for a streaming cache prewarm candidate.
enum VGStreamingCachePrewarmPriority {
  urgent(4),
  high(3),
  normal(2),
  low(1);

  final int rank;

  const VGStreamingCachePrewarmPriority(this.rank);
}

/// Candidate streaming cache prewarm request submitted for priority evaluation.
class VGStreamingCachePrewarmCandidate {
  final VGPlaybackPrewarmRequest request;
  final VGStreamingCachePrewarmPriority priority;
  final double weight;
  final bool isLowLatency;
  final String? reason;

  VGStreamingCachePrewarmCandidate({
    required this.request,
    this.priority = VGStreamingCachePrewarmPriority.normal,
    this.weight = 1.0,
    this.isLowLatency = false,
    this.reason,
  }) : assert(weight > 0.0, 'weight must be > 0.0');

  @override
  String toString() =>
      'VGStreamingCachePrewarmCandidate(requestId=${request.requestId}, '
      'priority=${priority.name}, weight=$weight, isLowLatency=$isLowLatency, '
      'reason=$reason)';
}

/// Dropped candidate along with evaluation drop reason.
class VGStreamingCacheDroppedPrewarmCandidate {
  final VGStreamingCachePrewarmCandidate candidate;
  final String reason;

  const VGStreamingCacheDroppedPrewarmCandidate({
    required this.candidate,
    required this.reason,
  });

  @override
  String toString() =>
      'VGStreamingCacheDroppedPrewarmCandidate('
      'requestId=${candidate.request.requestId}, reason=$reason)';
}

/// Eviction recommendation descriptor when projected cache footprint exceeds max capacity.
class VGStreamingCacheEvictionAdvisory {
  final int recommendedBytesToFree;
  final int currentCacheSpaceBytes;
  final int maxCacheBytes;
  final int requestedAdmitBytes;
  final String rationale;

  VGStreamingCacheEvictionAdvisory({
    required this.recommendedBytesToFree,
    required this.currentCacheSpaceBytes,
    required this.maxCacheBytes,
    required this.requestedAdmitBytes,
    required this.rationale,
  }) : assert(
         recommendedBytesToFree >= 0,
         'recommendedBytesToFree must be >= 0',
       ),
       assert(
         currentCacheSpaceBytes >= 0,
         'currentCacheSpaceBytes must be >= 0',
       ),
       assert(maxCacheBytes > 0, 'maxCacheBytes must be > 0'),
       assert(requestedAdmitBytes >= 0, 'requestedAdmitBytes must be >= 0');

  Map<String, Object?> toJson() => <String, Object?>{
    'recommendedBytesToFree': recommendedBytesToFree,
    'currentCacheSpaceBytes': currentCacheSpaceBytes,
    'maxCacheBytes': maxCacheBytes,
    'requestedAdmitBytes': requestedAdmitBytes,
    'rationale': rationale,
  };

  @override
  String toString() =>
      'VGStreamingCacheEvictionAdvisory(recommendedBytesToFree=$recommendedBytesToFree, '
      'currentCacheSpaceBytes=$currentCacheSpaceBytes, maxCacheBytes=$maxCacheBytes, '
      'requestedAdmitBytes=$requestedAdmitBytes, rationale=$rationale)';
}

/// Resulting plan containing admitted requests, dropped candidates, warnings, and eviction advisory.
class VGStreamingCachePriorityPlan {
  final List<VGPlaybackPrewarmRequest> admittedRequests;
  final List<VGStreamingCacheDroppedPrewarmCandidate> droppedCandidates;
  final int totalAdmittedBytes;
  final int totalRequestedBytes;
  final VGStreamingCacheEvictionAdvisory? evictionAdvisory;
  final List<String> warnings;
  final Map<String, Object?> diagnostics;

  VGStreamingCachePriorityPlan({
    required List<VGPlaybackPrewarmRequest> admittedRequests,
    required List<VGStreamingCacheDroppedPrewarmCandidate> droppedCandidates,
    required this.totalAdmittedBytes,
    required this.totalRequestedBytes,
    this.evictionAdvisory,
    List<String> warnings = const [],
    Map<String, Object?> diagnostics = const {},
  }) : admittedRequests = List.unmodifiable(admittedRequests),
       droppedCandidates = List.unmodifiable(droppedCandidates),
       warnings = List.unmodifiable(warnings),
       diagnostics = Map.unmodifiable(diagnostics);

  bool get hasRequests => admittedRequests.isNotEmpty;
  bool get hasEvictionAdvisory => evictionAdvisory != null;

  @override
  String toString() =>
      'VGStreamingCachePriorityPlan(admitted=${admittedRequests.length}, '
      'dropped=${droppedCandidates.length}, totalAdmittedBytes=$totalAdmittedBytes, '
      'totalRequestedBytes=$totalRequestedBytes, hasEvictionAdvisory=$hasEvictionAdvisory)';
}

class _IndexedCandidate {
  final int originalIndex;
  final VGStreamingCachePrewarmCandidate candidate;

  const _IndexedCandidate({
    required this.originalIndex,
    required this.candidate,
  });
}

/// Pure Dart planning utility for prioritizing and arbitrating streaming cache prewarm candidates.
abstract final class VGStreamingCachePriorityPlanner {
  /// Evaluates, deduplicates, prioritizes, and bounds candidates into a [VGStreamingCachePriorityPlan].
  static VGStreamingCachePriorityPlan plan({
    required List<VGStreamingCachePrewarmCandidate> candidates,
    int? maxTotalBytesBudget,
    VGPlaybackCacheStatus? cacheStatus,
    bool allowLowLatency = false,
  }) {
    assert(
      maxTotalBytesBudget == null || maxTotalBytesBudget >= 0,
      'maxTotalBytesBudget must be null or >= 0',
    );

    final droppedCandidates = <VGStreamingCacheDroppedPrewarmCandidate>[];
    final warnings = <String>[];

    // 1. Deduplicate by candidate.request.requestId preserving strongest
    // Stronger definition: higher priority.rank, then higher weight, then earlier originalIndex
    final uniqueMap = <String, _IndexedCandidate>{};
    final duplicatesToDrop = <_IndexedCandidate>[];

    for (var i = 0; i < candidates.length; i++) {
      final indexed = _IndexedCandidate(
        originalIndex: i,
        candidate: candidates[i],
      );
      final id = indexed.candidate.request.requestId;
      final existing = uniqueMap[id];
      if (existing == null) {
        uniqueMap[id] = indexed;
      } else {
        // Compare existing vs current indexed
        final existingRank = existing.candidate.priority.rank;
        final currentRank = indexed.candidate.priority.rank;
        if (currentRank > existingRank) {
          uniqueMap[id] = indexed;
          duplicatesToDrop.add(existing);
        } else if (currentRank < existingRank) {
          duplicatesToDrop.add(indexed);
        } else {
          // Rank tie: compare weight
          final existingWeight = existing.candidate.weight;
          final currentWeight = indexed.candidate.weight;
          if (currentWeight > existingWeight) {
            uniqueMap[id] = indexed;
            duplicatesToDrop.add(existing);
          } else if (currentWeight < existingWeight) {
            duplicatesToDrop.add(indexed);
          } else {
            // Weight tie: keep earlier originalIndex (which is existing)
            duplicatesToDrop.add(indexed);
          }
        }
      }
    }

    // Process duplicate drops in original order
    duplicatesToDrop.sort((a, b) => a.originalIndex.compareTo(b.originalIndex));
    for (final dropped in duplicatesToDrop) {
      final reason =
          'duplicate_request_id:${dropped.candidate.request.requestId}';
      droppedCandidates.add(
        VGStreamingCacheDroppedPrewarmCandidate(
          candidate: dropped.candidate,
          reason: reason,
        ),
      );
      warnings.add(reason);
    }

    final uniqueCandidates = uniqueMap.values.toList();

    // totalRequestedBytes is the sum of maxBytes for unique candidates after duplicate resolution
    // and before cache/low-latency/budget drops.
    var totalRequestedBytes = 0;
    for (final uc in uniqueCandidates) {
      totalRequestedBytes += uc.candidate.request.maxBytes;
    }

    // Sort unique candidates for admitted consideration:
    // priority rank desc, weight desc, original index asc
    uniqueCandidates.sort((a, b) {
      final rankDiff = b.candidate.priority.rank.compareTo(
        a.candidate.priority.rank,
      );
      if (rankDiff != 0) return rankDiff;
      final weightDiff = b.candidate.weight.compareTo(a.candidate.weight);
      if (weightDiff != 0) return weightDiff;
      return a.originalIndex.compareTo(b.originalIndex);
    });

    final admittedRequests = <VGPlaybackPrewarmRequest>[];
    var totalAdmittedBytes = 0;

    for (final indexed in uniqueCandidates) {
      final candidate = indexed.candidate;
      final req = candidate.request;

      // Check request-level cacheEnabled
      if (!req.options.cacheEnabled) {
        final reason = 'cache_disabled:${req.requestId}';
        droppedCandidates.add(
          VGStreamingCacheDroppedPrewarmCandidate(
            candidate: candidate,
            reason: reason,
          ),
        );
        warnings.add(reason);
        continue;
      }

      // Check low-latency constraint
      if (!allowLowLatency && candidate.isLowLatency) {
        final reason = 'low_latency_cache_constrained:${req.requestId}';
        droppedCandidates.add(
          VGStreamingCacheDroppedPrewarmCandidate(
            candidate: candidate,
            reason: reason,
          ),
        );
        warnings.add(reason);
        continue;
      }

      // Check global cache status availability and enablement
      if (cacheStatus != null && !cacheStatus.cacheEnabled) {
        droppedCandidates.add(
          VGStreamingCacheDroppedPrewarmCandidate(
            candidate: candidate,
            reason: 'cache_status_disabled',
          ),
        );
        continue;
      }

      if (cacheStatus != null && !cacheStatus.cacheAvailable) {
        droppedCandidates.add(
          VGStreamingCacheDroppedPrewarmCandidate(
            candidate: candidate,
            reason: 'cache_unavailable',
          ),
        );
        continue;
      }

      // Budget check
      if (maxTotalBytesBudget != null) {
        if (maxTotalBytesBudget == 0 ||
            totalAdmittedBytes + req.maxBytes > maxTotalBytesBudget) {
          droppedCandidates.add(
            VGStreamingCacheDroppedPrewarmCandidate(
              candidate: candidate,
              reason: 'budget_exceeded',
            ),
          );
          continue;
        }
      }

      // Admit
      admittedRequests.add(req);
      totalAdmittedBytes += req.maxBytes;
    }

    // Eviction advisory evaluation
    VGStreamingCacheEvictionAdvisory? evictionAdvisory;
    if (cacheStatus?.maxCacheBytes != null && cacheStatus!.maxCacheBytes! > 0) {
      final maxCacheBytes = cacheStatus.maxCacheBytes!;
      final currentCacheSpaceBytes = cacheStatus.cacheSpaceBytes;
      final projectedTotal = currentCacheSpaceBytes + totalAdmittedBytes;
      if (projectedTotal > maxCacheBytes) {
        final overflow = projectedTotal - maxCacheBytes;
        evictionAdvisory = VGStreamingCacheEvictionAdvisory(
          recommendedBytesToFree: overflow,
          currentCacheSpaceBytes: currentCacheSpaceBytes,
          maxCacheBytes: maxCacheBytes,
          requestedAdmitBytes: totalAdmittedBytes,
          rationale:
              'Projected cache footprint ($projectedTotal bytes) exceeds maxCacheBytes ($maxCacheBytes bytes)',
        );
      }
    }

    final diagnostics = <String, Object?>{
      'candidateCount': candidates.length,
      'uniqueCandidateCount': uniqueMap.length,
      'admittedCount': admittedRequests.length,
      'droppedCount': droppedCandidates.length,
      'totalRequestedBytes': totalRequestedBytes,
      'totalAdmittedBytes': totalAdmittedBytes,
      'maxTotalBytesBudget': maxTotalBytesBudget,
      'allowLowLatency': allowLowLatency,
      'cacheStatusProvided': cacheStatus != null,
      'evictionRecommended': evictionAdvisory != null,
    };

    return VGStreamingCachePriorityPlan(
      admittedRequests: admittedRequests,
      droppedCandidates: droppedCandidates,
      totalAdmittedBytes: totalAdmittedBytes,
      totalRequestedBytes: totalRequestedBytes,
      evictionAdvisory: evictionAdvisory,
      warnings: warnings,
      diagnostics: diagnostics,
    );
  }
}
