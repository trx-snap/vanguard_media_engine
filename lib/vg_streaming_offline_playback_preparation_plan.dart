// Copyright (c) Connects — Vanguard Phase 4C7BG.
// Public streaming offline playback preparation planner.
//
// Pure Dart advisory helper: composes VGStreamingPlaybackRoutePlanner,
// VGStreamingOfflineAssetEligibilityPlanner, and
// VGStreamingOfflineAssetAcquisitionPlanner to answer host-level advisory
// preparation questions without platform coupling, native calls, or side
// effects. The current iOS Swift loopback proxy cache remains online
// repeat-view/data-saving cache only; true offline HLS asset acquisition and
// playback will use Apple AVFoundation offline asset APIs in a later native
// lifecycle slice. DASH on iOS remains unsupported/deferred, and ABR remains
// player-owned — this planner is advisory only and never mutates playback state.

import 'vg_streaming_offline_asset_acquisition_plan.dart';
import 'vg_streaming_offline_asset_eligibility.dart';
import 'vg_streaming_playback_route_plan.dart';

export 'vg_streaming_playback_route_plan.dart'
    show
        VGPlaybackCacheOptions,
        VGPlaybackCacheStatus,
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingOfflineAssetAvailability,
        VGStreamingOfflineAssetState,
        VGStreamingPlaybackDecision,
        VGStreamingPlaybackDecisionPlanner,
        VGStreamingPlaybackDecisionRequest,
        VGStreamingPlaybackOptions,
        VGStreamingPlaybackRouteMode,
        VGStreamingPlaybackRoutePlan,
        VGStreamingPlaybackRoutePlanner,
        VGStreamingPlaybackRouteRequest,
        VGStreamingSourceClientCapabilities,
        VGStreamingSourceDescriptor,
        VGStreamingSourceSelection,
        VGStreamingSourceSelectionPreference,
        VGStreamingSourceSelectionRequest,
        VGStreamingSourceSelector,
        VGStreamingSourceSet,
        VGStreamingStartupPlan,
        VGStreamingStartupPlanner;
export 'vg_streaming_offline_asset_eligibility.dart'
    show
        VGStreamingOfflineAssetCandidate,
        VGStreamingOfflineAssetEligibilityPlan,
        VGStreamingOfflineAssetEligibilityPlanner,
        VGStreamingOfflineAssetEligibilityRequest,
        VGStreamingOfflineAssetEligibilityState,
        VGStreamingOfflineAssetRejectedSource;
export 'vg_streaming_offline_asset_acquisition_plan.dart'
    show
        VGStreamingOfflineAssetAcquisitionPlan,
        VGStreamingOfflineAssetAcquisitionPlanner,
        VGStreamingOfflineAssetAcquisitionPriority,
        VGStreamingOfflineAssetAcquisitionRequest,
        VGStreamingOfflineAssetDroppedAcquisitionCandidate;

/// Advisory action determined by [VGStreamingOfflinePlaybackPreparationPlanner].
enum VGStreamingOfflinePlaybackPreparationAction {
  /// Open an already available and downloaded local offline asset.
  openOfflineAsset,

  /// Open standard online playback via Vanguard read-through cache or direct network.
  openOnlinePlayback,

  /// Initiate offline asset acquisition for candidate stream before or alongside playback.
  acquireOfflineAsset,

  /// Playback cannot proceed and no offline acquisition is possible.
  blocked,
}

/// Immutable request configuration for streaming offline playback preparation planning.
class VGStreamingOfflinePlaybackPreparationRequest {
  /// Upstream playback decision containing selected source and options.
  final VGStreamingPlaybackDecision playbackDecision;

  /// Candidate set of streaming sources.
  final VGStreamingSourceSet sourceSet;

  /// Whether to prefer playing offline asset over online network/cache stream.
  final bool preferOffline;

  /// Whether to fall back to network/cache playback when offline asset is unavailable.
  final bool allowNetworkFallback;

  /// Map of known offline asset availability records keyed by source descriptor key.
  final Map<String, VGStreamingOfflineAssetAvailability>
  offlineAssetsBySourceKey;

  /// Optional client capability profile for advisory compatibility filtering.
  final VGStreamingSourceClientCapabilities? clientCapabilities;

  /// Whether LL-HLS live-edge sources are allowed to be eligible for offline acquisition.
  final bool allowLowLatencyOffline;

  /// Whether DASH sources are allowed to be eligible for offline acquisition.
  ///
  /// Advisory only — this flag is for non-Apple future backends. iOS DASH
  /// support remains unsupported/deferred.
  final bool allowDashOffline;

  /// Deterministic prefix for generated acquisition request IDs.
  final String acquisitionRequestIdPrefix;

  /// Default estimated byte size for acquisition requests without explicit override.
  final int defaultEstimatedBytes;

  /// Optional maximum total byte budget across all admitted acquisition requests.
  final int? maxTotalEstimatedBytesBudget;

  /// Optional priority overrides keyed by source descriptor key.
  final Map<String, VGStreamingOfflineAssetAcquisitionPriority>
  acquisitionPrioritiesBySourceKey;

  /// Optional byte size overrides keyed by source descriptor key.
  final Map<String, int> acquisitionEstimatedBytesBySourceKey;

  /// Optional rationale/reason overrides keyed by source descriptor key.
  final Map<String, String> acquisitionReasonsBySourceKey;

  VGStreamingOfflinePlaybackPreparationRequest({
    required this.playbackDecision,
    required this.sourceSet,
    this.preferOffline = false,
    this.allowNetworkFallback = true,
    Map<String, VGStreamingOfflineAssetAvailability> offlineAssetsBySourceKey =
        const {},
    this.clientCapabilities,
    this.allowLowLatencyOffline = false,
    this.allowDashOffline = false,
    this.acquisitionRequestIdPrefix = 'offline_acquire',
    this.defaultEstimatedBytes = 64 * 1024 * 1024,
    this.maxTotalEstimatedBytesBudget,
    Map<String, VGStreamingOfflineAssetAcquisitionPriority>
        acquisitionPrioritiesBySourceKey =
        const {},
    Map<String, int> acquisitionEstimatedBytesBySourceKey = const {},
    Map<String, String> acquisitionReasonsBySourceKey = const {},
  }) : assert(
         acquisitionRequestIdPrefix.isNotEmpty,
         'acquisitionRequestIdPrefix must not be empty',
       ),
       assert(
         defaultEstimatedBytes > 0,
         'defaultEstimatedBytes must be greater than 0',
       ),
       assert(
         maxTotalEstimatedBytesBudget == null ||
             maxTotalEstimatedBytesBudget >= 0,
         'maxTotalEstimatedBytesBudget must be null or >= 0',
       ),
       assert(
         acquisitionEstimatedBytesBySourceKey.values.every((v) => v > 0),
         'All acquisitionEstimatedBytesBySourceKey values must be greater than 0',
       ),
       offlineAssetsBySourceKey = Map.unmodifiable(offlineAssetsBySourceKey),
       acquisitionPrioritiesBySourceKey = Map.unmodifiable(
         acquisitionPrioritiesBySourceKey,
       ),
       acquisitionEstimatedBytesBySourceKey = Map.unmodifiable(
         acquisitionEstimatedBytesBySourceKey,
       ),
       acquisitionReasonsBySourceKey = Map.unmodifiable(
         acquisitionReasonsBySourceKey,
       );

  @override
  String toString() =>
      'VGStreamingOfflinePlaybackPreparationRequest('
      'playbackDecision=${playbackDecision.decision}, '
      'preferOffline=$preferOffline, allowNetworkFallback=$allowNetworkFallback, '
      'offlineAssets=${offlineAssetsBySourceKey.keys.toList()}, '
      'allowLowLatencyOffline=$allowLowLatencyOffline, '
      'allowDashOffline=$allowDashOffline, '
      'acquisitionRequestIdPrefix=$acquisitionRequestIdPrefix, '
      'defaultEstimatedBytes=$defaultEstimatedBytes, '
      'maxTotalEstimatedBytesBudget=$maxTotalEstimatedBytesBudget)';
}

/// Immutable result of a streaming offline playback preparation plan evaluation.
class VGStreamingOfflinePlaybackPreparationPlan {
  /// Recommended top-level action for host application orchestration.
  final VGStreamingOfflinePlaybackPreparationAction action;

  /// Underlying playback route plan.
  final VGStreamingPlaybackRoutePlan routePlan;

  /// Underlying offline asset eligibility plan.
  final VGStreamingOfflineAssetEligibilityPlan eligibilityPlan;

  /// Underlying offline asset acquisition request plan.
  final VGStreamingOfflineAssetAcquisitionPlan acquisitionPlan;

  /// Whether the selected playback route can be opened with the current public playback client.
  final bool canOpenWithCurrentPlaybackClient;

  /// Whether the resolved route requires host/native offline asset playback handling.
  final bool requiresOfflineAssetPlayback;

  /// Whether the host application should initiate offline asset acquisition.
  final bool shouldAcquireOfflineAsset;

  /// Selected streaming source key, or `null` if unselected.
  final String? selectedKey;

  /// Combined list of deduplicated warnings from all evaluated plans.
  final List<String> warnings;

  /// Diagnostic metadata for telemetry and auditing.
  final Map<String, Object?> diagnostics;

  VGStreamingOfflinePlaybackPreparationPlan({
    required this.action,
    required this.routePlan,
    required this.eligibilityPlan,
    required this.acquisitionPlan,
    required this.canOpenWithCurrentPlaybackClient,
    required this.requiresOfflineAssetPlayback,
    required this.shouldAcquireOfflineAsset,
    this.selectedKey,
    List<String> warnings = const [],
    Map<String, Object?> diagnostics = const {},
  }) : warnings = List.unmodifiable(warnings),
       diagnostics = Map.unmodifiable(diagnostics);

  /// Whether playback can be opened immediately now (either via current online playback client or host offline asset player).
  bool get canOpenNow =>
      (action ==
              VGStreamingOfflinePlaybackPreparationAction.openOnlinePlayback &&
          canOpenWithCurrentPlaybackClient) ||
      (action == VGStreamingOfflinePlaybackPreparationAction.openOfflineAsset);

  /// Whether playback is completely blocked without available playback or acquisition routes.
  bool get isBlocked =>
      action == VGStreamingOfflinePlaybackPreparationAction.blocked;

  @override
  String toString() =>
      'VGStreamingOfflinePlaybackPreparationPlan('
      'action=${action.name}, selectedKey=$selectedKey, '
      'canOpenNow=$canOpenNow, isBlocked=$isBlocked, '
      'canOpenWithCurrentPlaybackClient=$canOpenWithCurrentPlaybackClient, '
      'requiresOfflineAssetPlayback=$requiresOfflineAssetPlayback, '
      'shouldAcquireOfflineAsset=$shouldAcquireOfflineAsset, '
      'warnings=$warnings)';
}

/// Deterministic pure Dart planner for streaming offline playback preparation.
abstract final class VGStreamingOfflinePlaybackPreparationPlanner {
  /// Evaluates [request] and produces an immutable [VGStreamingOfflinePlaybackPreparationPlan].
  static VGStreamingOfflinePlaybackPreparationPlan plan(
    VGStreamingOfflinePlaybackPreparationRequest request,
  ) {
    // 1. Build route plan
    final routePlan = VGStreamingPlaybackRoutePlanner.plan(
      VGStreamingPlaybackRouteRequest(
        decision: request.playbackDecision,
        preferOffline: request.preferOffline,
        allowNetworkFallback: request.allowNetworkFallback,
        offlineAssetsBySourceKey: request.offlineAssetsBySourceKey,
      ),
    );

    // 2. Choose source keys for eligibility
    final List<String> sourceKeys;
    if (routePlan.selectedKey != null) {
      sourceKeys = [routePlan.selectedKey!];
    } else if (request.playbackDecision.selectedKey != null) {
      sourceKeys = [request.playbackDecision.selectedKey!];
    } else {
      sourceKeys = const [];
    }

    // 3. Build eligibility plan
    final eligibilityPlan = VGStreamingOfflineAssetEligibilityPlanner.plan(
      VGStreamingOfflineAssetEligibilityRequest(
        sourceSet: request.sourceSet,
        sourceKeys: sourceKeys,
        clientCapabilities: request.clientCapabilities,
        allowLowLatency: request.allowLowLatencyOffline,
        allowDash: request.allowDashOffline,
      ),
    );

    // 4. Build acquisition plan
    final acquisitionPlan = VGStreamingOfflineAssetAcquisitionPlanner.plan(
      eligibilityPlan: eligibilityPlan,
      requestIdPrefix: request.acquisitionRequestIdPrefix,
      defaultEstimatedBytes: request.defaultEstimatedBytes,
      maxTotalEstimatedBytesBudget: request.maxTotalEstimatedBytesBudget,
      prioritiesBySourceKey: request.acquisitionPrioritiesBySourceKey,
      estimatedBytesBySourceKey: request.acquisitionEstimatedBytesBySourceKey,
      reasonsBySourceKey: request.acquisitionReasonsBySourceKey,
    );

    // 5. Determine action
    final VGStreamingOfflinePlaybackPreparationAction action;
    if (routePlan.mode == VGStreamingPlaybackRouteMode.offlineAsset) {
      action = VGStreamingOfflinePlaybackPreparationAction.openOfflineAsset;
    } else if (routePlan.mode == VGStreamingPlaybackRouteMode.network ||
        routePlan.mode == VGStreamingPlaybackRouteMode.onlineCache) {
      if (request.preferOffline && acquisitionPlan.hasRequests) {
        action =
            VGStreamingOfflinePlaybackPreparationAction.acquireOfflineAsset;
      } else {
        action = VGStreamingOfflinePlaybackPreparationAction.openOnlinePlayback;
      }
    } else {
      // routePlan.mode == VGStreamingPlaybackRouteMode.blocked
      if (acquisitionPlan.hasRequests) {
        action =
            VGStreamingOfflinePlaybackPreparationAction.acquireOfflineAsset;
      } else {
        action = VGStreamingOfflinePlaybackPreparationAction.blocked;
      }
    }

    // 6. Booleans & selected key
    final canOpenWithCurrentPlaybackClient =
        routePlan.canOpenWithCurrentPlaybackClient;
    final requiresOfflineAssetPlayback = routePlan.requiresOfflineAssetPlayback;
    final shouldAcquireOfflineAsset =
        action ==
        VGStreamingOfflinePlaybackPreparationAction.acquireOfflineAsset;
    final selectedKey =
        routePlan.selectedKey ?? request.playbackDecision.selectedKey;

    // 7. Deduplicated warnings in encounter order
    final warnings = <String>[];
    void addWarning(String w) {
      if (!warnings.contains(w)) {
        warnings.add(w);
      }
    }

    for (final w in routePlan.warnings) {
      addWarning(w);
    }
    for (final w in eligibilityPlan.warnings) {
      addWarning(w);
    }
    for (final w in acquisitionPlan.warnings) {
      addWarning(w);
    }

    if (action ==
        VGStreamingOfflinePlaybackPreparationAction.acquireOfflineAsset) {
      final keyForWarning =
          selectedKey ??
          (acquisitionPlan.hasRequests
              ? acquisitionPlan.requests.first.sourceKey
              : 'unknown');
      if (routePlan.mode == VGStreamingPlaybackRouteMode.network ||
          routePlan.mode == VGStreamingPlaybackRouteMode.onlineCache) {
        addWarning('offline_acquisition_recommended:$keyForWarning');
      } else if (routePlan.mode == VGStreamingPlaybackRouteMode.blocked) {
        addWarning('offline_acquisition_required:$keyForWarning');
      }
    }

    // 8. Diagnostics
    final diagnostics = <String, Object?>{
      'action': action.name,
      'routeMode': routePlan.mode.name,
      'routeDecision': routePlan.decision,
      'selectedKey': selectedKey,
      'eligibilityCandidateCount': eligibilityPlan.candidates.length,
      'eligibilityRejectedCount': eligibilityPlan.rejectedSources.length,
      'acquisitionRequestCount': acquisitionPlan.requests.length,
      'acquisitionDroppedCount': acquisitionPlan.droppedCandidates.length,
      'canOpenWithCurrentPlaybackClient': canOpenWithCurrentPlaybackClient,
      'requiresOfflineAssetPlayback': requiresOfflineAssetPlayback,
      'shouldAcquireOfflineAsset': shouldAcquireOfflineAsset,
      'preferOffline': request.preferOffline,
      'allowNetworkFallback': request.allowNetworkFallback,
      'advisoryOnly': true,
      'playbackMutation': false,
    };

    return VGStreamingOfflinePlaybackPreparationPlan(
      action: action,
      routePlan: routePlan,
      eligibilityPlan: eligibilityPlan,
      acquisitionPlan: acquisitionPlan,
      canOpenWithCurrentPlaybackClient: canOpenWithCurrentPlaybackClient,
      requiresOfflineAssetPlayback: requiresOfflineAssetPlayback,
      shouldAcquireOfflineAsset: shouldAcquireOfflineAsset,
      selectedKey: selectedKey,
      warnings: warnings,
      diagnostics: diagnostics,
    );
  }
}
