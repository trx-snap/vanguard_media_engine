// Copyright (c) Connects — Vanguard Phase 4C7BD.
// Public streaming playback route planner for online cache vs offline asset.
//
// Pure Dart advisory helper: evaluates playback decisions and offline asset
// availability to route between network, online cache, offline asset, or blocked
// states without platform coupling, native calls, or side effects.

import 'vg_streaming_playback_decision.dart';

export 'vg_streaming_cache_client.dart'
    show VGPlaybackCacheOptions, VGPlaybackCacheStatus;
export 'vg_streaming_playback_client.dart'
    show
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingPlaybackOptions;
export 'vg_streaming_playback_decision.dart'
    show
        VGStreamingPlaybackDecision,
        VGStreamingPlaybackDecisionPlanner,
        VGStreamingPlaybackDecisionRequest;
export 'vg_streaming_source_descriptor.dart'
    show VGStreamingSourceDescriptor, VGStreamingSourceSet;
export 'vg_streaming_source_selector.dart'
    show
        VGStreamingSourceClientCapabilities,
        VGStreamingSourceSelection,
        VGStreamingSourceSelectionPreference,
        VGStreamingSourceSelectionRequest,
        VGStreamingSourceSelector;
export 'vg_streaming_startup_plan.dart'
    show VGStreamingStartupPlan, VGStreamingStartupPlanner;

/// Playback routing mode determined by [VGStreamingPlaybackRoutePlanner].
enum VGStreamingPlaybackRouteMode {
  /// Standard network playback without local Vanguard cache.
  network,

  /// Online read-through/repeat-view cached playback via Vanguard cache.
  onlineCache,

  /// True offline HLS asset playback route.
  offlineAsset,

  /// Playback cannot proceed (e.g. offline requested without network fallback or upstream blocked).
  blocked,
}

/// Lifecycle or availability state of a local offline asset.
enum VGStreamingOfflineAssetState {
  /// State has not been probed or is unrecognized.
  unknown,

  /// Asset is not stored locally or is unavailable.
  unavailable,

  /// Asset is completely downloaded and ready for offline playback.
  available,

  /// Asset download is incomplete, requires update, or manifest is stale.
  stale,

  /// Asset or license has expired.
  expired,

  /// Format or client is unsupported for offline asset storage.
  unsupported,
}

/// Offline asset availability descriptor for candidate streaming sources.
class VGStreamingOfflineAssetAvailability {
  /// Key of the source descriptor this availability record applies to.
  final String sourceKey;

  /// Probed or claimed offline asset state.
  final VGStreamingOfflineAssetState state;

  /// Local file URI pointing to the stored offline package/manifest, if available.
  final Uri? assetUri;

  /// Total downloaded bytes on disk, or `null` if unknown.
  final int? downloadedBytes;

  /// Expiration timestamp in milliseconds since epoch, or `null` if unconstrained.
  final int? expiresAtUnixMs;

  /// Optional advisory reason for non-available or degraded state.
  final String? reason;

  const VGStreamingOfflineAssetAvailability({
    required this.sourceKey,
    this.state = VGStreamingOfflineAssetState.unknown,
    this.assetUri,
    this.downloadedBytes,
    this.expiresAtUnixMs,
    this.reason,
  }) : assert(sourceKey.length > 0, 'sourceKey must not be empty'),
       assert(
         downloadedBytes == null || downloadedBytes >= 0,
         'downloadedBytes must be null or >= 0',
       ),
       assert(
         expiresAtUnixMs == null || expiresAtUnixMs >= 0,
         'expiresAtUnixMs must be null or >= 0',
       );

  /// Whether the asset is playable offline in a zero-network environment.
  bool get isPlayableOffline =>
      state == VGStreamingOfflineAssetState.available && assetUri != null;

  /// Converts this descriptor to a primitive map for serialization and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'sourceKey': sourceKey,
    'state': state.name,
    'assetUri': assetUri?.toString(),
    'downloadedBytes': downloadedBytes,
    'expiresAtUnixMs': expiresAtUnixMs,
    'reason': reason,
    'isPlayableOffline': isPlayableOffline,
  };

  @override
  String toString() =>
      'VGStreamingOfflineAssetAvailability(sourceKey=$sourceKey, '
      'state=${state.name}, assetUri=$assetUri, downloadedBytes=$downloadedBytes, '
      'expiresAtUnixMs=$expiresAtUnixMs, reason=$reason, isPlayableOffline=$isPlayableOffline)';
}

/// Immutable request configuration for streaming playback route planning.
class VGStreamingPlaybackRouteRequest {
  /// Upstream playback decision containing selected source and playback options.
  final VGStreamingPlaybackDecision decision;

  /// Whether to prefer playing offline asset over online network/cache stream.
  final bool preferOffline;

  /// Whether to fall back to network/cache playback when offline asset is unavailable.
  final bool allowNetworkFallback;

  /// Map of known offline asset availability records keyed by source descriptor key.
  final Map<String, VGStreamingOfflineAssetAvailability>
  offlineAssetsBySourceKey;

  VGStreamingPlaybackRouteRequest({
    required this.decision,
    this.preferOffline = false,
    this.allowNetworkFallback = true,
    Map<String, VGStreamingOfflineAssetAvailability> offlineAssetsBySourceKey =
        const {},
  }) : offlineAssetsBySourceKey = Map.unmodifiable(offlineAssetsBySourceKey);

  @override
  String toString() =>
      'VGStreamingPlaybackRouteRequest(decision=${decision.decision}, '
      'preferOffline=$preferOffline, allowNetworkFallback=$allowNetworkFallback, '
      'offlineAssets=${offlineAssetsBySourceKey.keys.toList()})';
}

/// Immutable result of a streaming playback route evaluation.
class VGStreamingPlaybackRoutePlan {
  /// Selected playback route mode.
  final VGStreamingPlaybackRouteMode mode;

  /// High-level route decision identifier.
  final String decision;

  /// Selected streaming source key, or `null` if blocked.
  final String? selectedKey;

  /// Selected streaming source descriptor, or `null` if blocked.
  final VGStreamingSourceDescriptor? selectedSource;

  /// Validated playback options ready for client consumption, or `null` for blocked routes.
  final VGStreamingPlaybackOptions? playbackOptions;

  /// Resolved offline asset availability descriptor if evaluated, or `null`.
  final VGStreamingOfflineAssetAvailability? offlineAsset;

  /// Whether this route can be opened directly with the current public playback client.
  final bool canOpenWithCurrentPlaybackClient;

  /// Whether this route requires host/native offline asset playback handling.
  final bool requiresOfflineAssetPlayback;

  /// Whether this plan is advisory-only without executing playback or I/O.
  final bool advisoryOnly;

  /// Whether evaluating this plan caused playback state mutation.
  final bool playbackMutation;

  /// Combined list of deduplicated warnings from upstream decision and route evaluation.
  final List<String> warnings;

  /// Diagnostic metadata for logging and telemetry.
  final Map<String, Object?> diagnostics;

  VGStreamingPlaybackRoutePlan({
    required this.mode,
    required this.decision,
    this.selectedKey,
    this.selectedSource,
    this.playbackOptions,
    this.offlineAsset,
    required this.canOpenWithCurrentPlaybackClient,
    required this.requiresOfflineAssetPlayback,
    this.advisoryOnly = true,
    this.playbackMutation = false,
    List<String> warnings = const [],
    Map<String, Object?> diagnostics = const {},
  }) : warnings = List.unmodifiable(warnings),
       diagnostics = Map.unmodifiable(diagnostics);

  /// Whether this plan routes to direct network playback without Vanguard cache.
  bool get shouldUseNetwork => mode == VGStreamingPlaybackRouteMode.network;

  /// Whether this plan routes to online read-through/repeat-view Vanguard cache playback.
  bool get shouldUseOnlineCache =>
      mode == VGStreamingPlaybackRouteMode.onlineCache;

  /// Whether this plan routes to local offline asset playback.
  bool get shouldUseOfflineAsset =>
      mode == VGStreamingPlaybackRouteMode.offlineAsset;

  @override
  String toString() =>
      'VGStreamingPlaybackRoutePlan(mode=${mode.name}, decision=$decision, '
      'selectedKey=$selectedKey, '
      'canOpenWithCurrentPlaybackClient=$canOpenWithCurrentPlaybackClient, '
      'requiresOfflineAssetPlayback=$requiresOfflineAssetPlayback, '
      'warnings=$warnings)';
}

/// Deterministic pure Dart planner for streaming playback route arbitration.
abstract final class VGStreamingPlaybackRoutePlanner {
  /// Evaluates [request] and produces an immutable [VGStreamingPlaybackRoutePlan].
  static VGStreamingPlaybackRoutePlan plan(
    VGStreamingPlaybackRouteRequest request,
  ) {
    final warnings = <String>[];
    void addWarning(String w) {
      if (!warnings.contains(w)) {
        warnings.add(w);
      }
    }

    for (final w in request.decision.warnings) {
      addWarning(w);
    }

    final decision = request.decision;

    // 1. Upstream blocked or incomplete decision guard
    if (!decision.canOpenPlayback ||
        decision.selectedKey == null ||
        decision.selectedSource == null ||
        decision.playbackOptions == null) {
      final blockDecision = 'playback_decision_blocked:${decision.decision}';
      final diagnostics = <String, Object?>{
        'originalDecision': decision.decision,
        'canOpenPlayback': decision.canOpenPlayback,
        'preferOffline': request.preferOffline,
        'allowNetworkFallback': request.allowNetworkFallback,
        'hasSelectedKey': decision.selectedKey != null,
        'hasSelectedSource': decision.selectedSource != null,
        'hasPlaybackOptions': decision.playbackOptions != null,
      };

      return VGStreamingPlaybackRoutePlan(
        mode: VGStreamingPlaybackRouteMode.blocked,
        decision: blockDecision,
        selectedKey: decision.selectedKey,
        selectedSource: decision.selectedSource,
        playbackOptions: null,
        offlineAsset: null,
        canOpenWithCurrentPlaybackClient: false,
        requiresOfflineAssetPlayback: false,
        advisoryOnly: true,
        playbackMutation: false,
        warnings: warnings,
        diagnostics: diagnostics,
      );
    }

    final selectedKey = decision.selectedKey!;
    final selectedSource = decision.selectedSource!;
    final playbackOptions = decision.playbackOptions!;

    // 2. Format detection
    final uriPath = selectedSource.uri.path.toLowerCase();
    final isDash =
        selectedSource.formatHint == VGStreamingFormatHint.dash ||
        uriPath.endsWith('.mpd');
    final isHls =
        selectedSource.formatHint == VGStreamingFormatHint.hls ||
        uriPath.endsWith('.m3u8');
    final isLlHls = selectedSource.requireLlHlsTags;

    final formatName = isDash
        ? 'dash'
        : (isHls ? (isLlHls ? 'll_hls' : 'hls') : 'unknown');

    final availability = request.offlineAssetsBySourceKey[selectedKey];

    // 3. Offline evaluation if preferOffline is requested
    if (request.preferOffline) {
      var unsupportedOffline = false;

      if (isDash) {
        addWarning('offline_dash_not_supported:$selectedKey');
        unsupportedOffline = true;
      } else if (isLlHls) {
        addWarning('offline_low_latency_not_supported:$selectedKey');
        unsupportedOffline = true;
      } else if (!isHls) {
        addWarning('offline_format_not_supported:$selectedKey');
        unsupportedOffline = true;
      }

      if (!unsupportedOffline &&
          availability != null &&
          availability.isPlayableOffline) {
        final offlineFormatHint =
            playbackOptions.formatHint == VGStreamingFormatHint.dash
            ? VGStreamingFormatHint.hls
            : playbackOptions.formatHint;

        final offlinePlaybackOptions = VGStreamingPlaybackOptions(
          uri: availability.assetUri!,
          initialWidth: playbackOptions.initialWidth,
          initialHeight: playbackOptions.initialHeight,
          httpHeaders: null,
          formatHint: offlineFormatHint,
          networkProfile: playbackOptions.networkProfile,
          autoPlay: playbackOptions.autoPlay,
          initialPositionMs: playbackOptions.initialPositionMs,
          cacheOptions: null,
        );

        final diagnostics = <String, Object?>{
          'offlineAssetState': availability.state.name,
          'hasOfflineAssetUri': availability.assetUri != null,
          if (availability.assetUri != null)
            'offlineAssetUriScheme': availability.assetUri!.scheme,
          'canOpenWithCurrentPlaybackClient': true,
          'requiresOfflineAssetPlayback': false,
          'allowNetworkFallback': request.allowNetworkFallback,
          'preferOffline': true,
          'selectedFormat': formatName,
          'isLowLatency': isLlHls,
          'downloadedBytes': availability.downloadedBytes,
          'expiresAtUnixMs': availability.expiresAtUnixMs,
        };

        return VGStreamingPlaybackRoutePlan(
          mode: VGStreamingPlaybackRouteMode.offlineAsset,
          decision: 'offline_asset_ready',
          selectedKey: selectedKey,
          selectedSource: selectedSource,
          playbackOptions: offlinePlaybackOptions,
          offlineAsset: availability,
          canOpenWithCurrentPlaybackClient: true,
          requiresOfflineAssetPlayback: false,
          advisoryOnly: true,
          playbackMutation: false,
          warnings: warnings,
          diagnostics: diagnostics,
        );
      }

      if (!unsupportedOffline) {
        if (availability == null) {
          addWarning('offline_asset_missing:$selectedKey');
        } else {
          addWarning(
            'offline_asset_not_playable:$selectedKey:${availability.state.name}',
          );
        }
      }

      if (!request.allowNetworkFallback) {
        final diagnostics = <String, Object?>{
          'offlineAssetState': availability?.state.name,
          'hasOfflineAssetUri': availability?.assetUri != null,
          'allowNetworkFallback': false,
          'preferOffline': true,
          'selectedFormat': formatName,
          'isLowLatency': isLlHls,
          'originalDecision': decision.decision,
        };

        return VGStreamingPlaybackRoutePlan(
          mode: VGStreamingPlaybackRouteMode.blocked,
          decision: 'offline_route_blocked',
          selectedKey: selectedKey,
          selectedSource: selectedSource,
          playbackOptions: null,
          offlineAsset: availability,
          canOpenWithCurrentPlaybackClient: false,
          requiresOfflineAssetPlayback: false,
          advisoryOnly: true,
          playbackMutation: false,
          warnings: warnings,
          diagnostics: diagnostics,
        );
      }

      addWarning('offline_fallback_to_network:$selectedKey');
    }

    // 4. Online route evaluation
    final cacheEnabled = playbackOptions.cacheOptions?.cacheEnabled ?? false;
    final mode = cacheEnabled
        ? VGStreamingPlaybackRouteMode.onlineCache
        : VGStreamingPlaybackRouteMode.network;
    final routeDecision = cacheEnabled
        ? 'online_cache_playback_ready'
        : 'network_playback_ready';

    final diagnostics = <String, Object?>{
      'cacheEnabled': cacheEnabled,
      'selectedFormat': formatName,
      'isLowLatency': isLlHls,
      'allowNetworkFallback': request.allowNetworkFallback,
      'preferOffline': request.preferOffline,
      'originalDecision': decision.decision,
      if (availability != null) 'offlineAssetState': availability.state.name,
    };

    return VGStreamingPlaybackRoutePlan(
      mode: mode,
      decision: routeDecision,
      selectedKey: selectedKey,
      selectedSource: selectedSource,
      playbackOptions: playbackOptions,
      offlineAsset: availability,
      canOpenWithCurrentPlaybackClient: true,
      requiresOfflineAssetPlayback: false,
      advisoryOnly: true,
      playbackMutation: false,
      warnings: warnings,
      diagnostics: diagnostics,
    );
  }
}
