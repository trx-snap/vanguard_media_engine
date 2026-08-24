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
export 'vg_streaming_source_descriptor.dart'
    show VGStreamingSourceDescriptor, VGStreamingSourceSet;

/// Priority level for a streaming cache prewarm candidate.
enum VGStreamingCachePrewarmPriority {
  urgent(4),
  high(3),
  normal(2),
  low(1);

  final int rank;

  const VGStreamingCachePrewarmPriority(this.rank);
}

/// Immutable request to bridge a [VGStreamingSourceSet] into prioritized cache prewarm planning.
class VGStreamingCacheSourcePriorityPlanRequest {
  final VGStreamingSourceSet sourceSet;
  final String requestIdPrefix;
  final List<String> sourceKeys;
  final int maxBytes;
  final VGPlaybackCacheOptions options;
  final VGStreamingCachePrewarmLowLatencyPolicy lowLatencyPolicy;
  final Map<String, VGStreamingCachePrewarmPriority> prioritiesBySourceKey;
  final Map<String, double> weightsBySourceKey;
  final Map<String, String> reasonsBySourceKey;
  final VGStreamingCachePrewarmPriority defaultPriority;
  final double defaultWeight;
  final int? maxTotalBytesBudget;
  final VGPlaybackCacheStatus? cacheStatus;

  VGStreamingCacheSourcePriorityPlanRequest({
    required this.sourceSet,
    required this.requestIdPrefix,
    List<String> sourceKeys = const [],
    this.maxBytes = 2 * 1024 * 1024,
    this.options = const VGPlaybackCacheOptions(),
    this.lowLatencyPolicy =
        VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
    Map<String, VGStreamingCachePrewarmPriority> prioritiesBySourceKey =
        const {},
    Map<String, double> weightsBySourceKey = const {},
    Map<String, String> reasonsBySourceKey = const {},
    this.defaultPriority = VGStreamingCachePrewarmPriority.normal,
    this.defaultWeight = 1.0,
    this.maxTotalBytesBudget,
    this.cacheStatus,
  }) : sourceKeys = List.unmodifiable(sourceKeys),
       prioritiesBySourceKey = Map.unmodifiable(prioritiesBySourceKey),
       weightsBySourceKey = Map.unmodifiable(weightsBySourceKey),
       reasonsBySourceKey = Map.unmodifiable(reasonsBySourceKey),
       assert(requestIdPrefix.isNotEmpty, 'requestIdPrefix must not be empty'),
       assert(maxBytes > 0, 'maxBytes must be > 0'),
       assert(defaultWeight > 0.0, 'defaultWeight must be > 0.0'),
       assert(
         maxTotalBytesBudget == null || maxTotalBytesBudget >= 0,
         'maxTotalBytesBudget must be null or >= 0',
       );

  @override
  String toString() =>
      'VGStreamingCacheSourcePriorityPlanRequest(requestIdPrefix=$requestIdPrefix, '
      'sourceKeys=$sourceKeys, maxBytes=$maxBytes, lowLatencyPolicy=${lowLatencyPolicy.name}, '
      'defaultPriority=${defaultPriority.name}, defaultWeight=$defaultWeight, '
      'maxTotalBytesBudget=$maxTotalBytesBudget)';
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

  /// Bridges a [VGStreamingSourceSet] and caller-provided priorities into a [VGStreamingCachePriorityPlan].
  ///
  /// - Resolves sources in [request.sourceKeys] order if non-empty, otherwise uses [request.sourceSet.sources] order.
  /// - Unknown source keys emit an `unknown_source_key:<key>` warning and do not become candidates.
  /// - Low-latency sources (`requireLlHlsTags == true`) under [VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency]
  ///   are skipped before priority planning with warning `low_latency_cache_constrained:<key>`.
  /// - Valid candidate sources are converted to [VGPlaybackPrewarmRequest] instances via [VGStreamingCachePrewarmPlanner.requestForSource]
  ///   preserving URI, headers, cache options, and deterministic request IDs (`${requestIdPrefix}_${source.key}_${index}`).
  /// - Candidates are wrapped in [VGStreamingCachePrewarmCandidate] with caller-configured or default priority, weight, and reason.
  /// - Evaluates candidates against budget and cache status via [plan], returning merged warnings and extended diagnostics.
  static VGStreamingCachePriorityPlan planForSourceSet(
    VGStreamingCacheSourcePriorityPlanRequest request,
  ) {
    final warnings = <String>[];
    final candidateSources = <VGStreamingSourceDescriptor>[];
    var skippedSourceCount = 0;

    // 1. Resolve candidate sources
    if (request.sourceKeys.isNotEmpty) {
      for (final key in request.sourceKeys) {
        final source = request.sourceSet.trySourceForKey(key);
        if (source != null) {
          candidateSources.add(source);
        } else {
          warnings.add('unknown_source_key:$key');
        }
      }
    } else {
      candidateSources.addAll(request.sourceSet.sources);
    }

    final overrideOptions =
        identical(request.options, const VGPlaybackCacheOptions())
        ? null
        : request.options;

    final candidates = <VGStreamingCachePrewarmCandidate>[];

    // 2. Build prewarm candidates
    for (var i = 0; i < candidateSources.length; i++) {
      final source = candidateSources[i];

      if (source.requireLlHlsTags &&
          request.lowLatencyPolicy ==
              VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency) {
        skippedSourceCount++;
        warnings.add('low_latency_cache_constrained:${source.key}');
        continue;
      }

      final requestId = '${request.requestIdPrefix}_${source.key}_$i';
      final prewarmRequest = VGStreamingCachePrewarmPlanner.requestForSource(
        requestId: requestId,
        source: source,
        maxBytes: request.maxBytes,
        options: overrideOptions,
      );

      final priority =
          request.prioritiesBySourceKey[source.key] ?? request.defaultPriority;
      final weight =
          request.weightsBySourceKey[source.key] ?? request.defaultWeight;
      final reason = request.reasonsBySourceKey[source.key];

      candidates.add(
        VGStreamingCachePrewarmCandidate(
          request: prewarmRequest,
          priority: priority,
          weight: weight,
          isLowLatency: source.requireLlHlsTags,
          reason: reason,
        ),
      );
    }

    // 3. Delegate to priority plan
    final innerPlan = plan(
      candidates: candidates,
      maxTotalBytesBudget: request.maxTotalBytesBudget,
      cacheStatus: request.cacheStatus,
      allowLowLatency:
          request.lowLatencyPolicy ==
          VGStreamingCachePrewarmLowLatencyPolicy.allowBoundedManifestOnly,
    );

    final mergedWarnings = <String>[...warnings, ...innerPlan.warnings];

    final mergedDiagnostics = <String, Object?>{
      'sourceCount': request.sourceSet.sources.length,
      'sourceKeysProvided': request.sourceKeys.isNotEmpty,
      'resolvedSourceCount': candidateSources.length,
      'candidateCount': candidates.length,
      'skippedSourceCount': skippedSourceCount,
      'lowLatencyPolicy': request.lowLatencyPolicy.name,
      'requestIdPrefix': request.requestIdPrefix,
      ...innerPlan.diagnostics,
    };

    return VGStreamingCachePriorityPlan(
      admittedRequests: innerPlan.admittedRequests,
      droppedCandidates: innerPlan.droppedCandidates,
      totalAdmittedBytes: innerPlan.totalAdmittedBytes,
      totalRequestedBytes: innerPlan.totalRequestedBytes,
      evictionAdvisory: innerPlan.evictionAdvisory,
      warnings: mergedWarnings,
      diagnostics: mergedDiagnostics,
    );
  }
}
