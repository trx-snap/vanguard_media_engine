// Copyright (c) Connects — Vanguard Phase 4C7BE.
// Public streaming offline asset eligibility planner.
//
// Pure Dart advisory helper: evaluates a VGStreamingSourceSet and determines
// which sources are eligible for a future offline HLS asset acquisition
// pipeline, without native offline download/playback coupling or side
// effects. The current iOS Swift loopback proxy cache remains online
// repeat-view/data-saving cache only; true offline HLS asset acquisition
// will use Apple AVFoundation offline asset APIs in a later slice. DASH on
// iOS remains unsupported/deferred, and LL-HLS live-edge offline persistence
// is constrained and rejected by default. ABR remains player-owned — this
// planner is advisory only and never mutates playback state.

import 'vg_streaming_source_selector.dart';

export 'vg_streaming_playback_client.dart' show VGStreamingFormatHint;
export 'vg_streaming_source_descriptor.dart'
    show VGStreamingSourceDescriptor, VGStreamingSourceSet;
export 'vg_streaming_source_selector.dart'
    show VGStreamingSourceClientCapabilities;

/// Eligibility state for a candidate source under offline HLS asset planning.
enum VGStreamingOfflineAssetEligibilityState {
  /// Source is eligible for future offline HLS asset acquisition.
  eligible,

  /// Source format is not eligible for offline asset acquisition (e.g. DASH, unknown format).
  unsupportedFormat,

  /// Source is LL-HLS live-edge content, which is constrained for offline persistence.
  lowLatencyConstrained,

  /// Client capabilities do not support this source's format for offline acquisition.
  clientUnsupported,

  /// Source descriptor is invalid for offline acquisition (e.g. unsupported URI scheme).
  invalidSource,
}

/// Immutable candidate eligible for future offline HLS asset acquisition.
class VGStreamingOfflineAssetCandidate {
  /// Key of the source descriptor this candidate applies to.
  final String sourceKey;

  /// HTTP/HTTPS URI of the manifest to acquire offline.
  final Uri uri;

  /// Optional HTTP request headers required to fetch the manifest/segments.
  final Map<String, String>? httpHeaders;

  /// Format hint of the underlying source.
  final VGStreamingFormatHint formatHint;

  /// Whether the source requires LL-HLS tags.
  final bool requireLlHlsTags;

  VGStreamingOfflineAssetCandidate({
    required this.sourceKey,
    required this.uri,
    Map<String, String>? httpHeaders,
    this.formatHint = VGStreamingFormatHint.auto,
    this.requireLlHlsTags = false,
  }) : assert(sourceKey.isNotEmpty, 'sourceKey must not be empty'),
       httpHeaders = httpHeaders == null ? null : Map.unmodifiable(httpHeaders);

  /// Converts this candidate to a primitive map for serialization and telemetry.
  Map<String, Object?> toArgs() => <String, Object?>{
    'sourceKey': sourceKey,
    'uri': uri.toString(),
    if (httpHeaders != null) 'httpHeaders': httpHeaders,
    'formatHint': formatHint.toNative(),
    'requireLlHlsTags': requireLlHlsTags,
  };

  @override
  String toString() =>
      'VGStreamingOfflineAssetCandidate(sourceKey=$sourceKey, uri=$uri, '
      'formatHint=${formatHint.name}, requireLlHlsTags=$requireLlHlsTags)';
}

/// Immutable record of a source rejected for offline HLS asset acquisition.
class VGStreamingOfflineAssetRejectedSource {
  /// Key of the source descriptor this rejection applies to.
  final String sourceKey;

  /// Eligibility state describing the rejection category.
  final VGStreamingOfflineAssetEligibilityState state;

  /// Machine-readable rejection reason code.
  final String reason;

  /// Format hint of the underlying source.
  final VGStreamingFormatHint formatHint;

  /// Whether the source requires LL-HLS tags.
  final bool requireLlHlsTags;

  VGStreamingOfflineAssetRejectedSource({
    required this.sourceKey,
    required this.state,
    required this.reason,
    this.formatHint = VGStreamingFormatHint.auto,
    this.requireLlHlsTags = false,
  }) : assert(sourceKey.isNotEmpty, 'sourceKey must not be empty'),
       assert(reason.isNotEmpty, 'reason must not be empty');

  /// Converts this rejection to a primitive map for serialization and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'sourceKey': sourceKey,
    'state': state.name,
    'reason': reason,
    'formatHint': formatHint.toNative(),
    'requireLlHlsTags': requireLlHlsTags,
  };

  @override
  String toString() =>
      'VGStreamingOfflineAssetRejectedSource(sourceKey=$sourceKey, '
      'state=${state.name}, reason=$reason, formatHint=${formatHint.name}, '
      'requireLlHlsTags=$requireLlHlsTags)';
}

/// Immutable request configuration for offline HLS asset eligibility planning.
class VGStreamingOfflineAssetEligibilityRequest {
  /// Candidate set of streaming sources.
  final VGStreamingSourceSet sourceSet;

  /// Optional prioritized list of source keys to evaluate in supplied order.
  final List<String> sourceKeys;

  /// Optional client capability profile for advisory compatibility filtering.
  final VGStreamingSourceClientCapabilities? clientCapabilities;

  /// Whether LL-HLS live-edge sources are allowed to be eligible for offline acquisition.
  final bool allowLowLatency;

  /// Whether DASH sources are allowed to be eligible for offline acquisition.
  ///
  /// Advisory only — this flag is for non-Apple future backends. iOS DASH
  /// support remains unsupported/deferred; server should provide HLS/LL-HLS
  /// fallback for Apple clients.
  final bool allowDash;

  VGStreamingOfflineAssetEligibilityRequest({
    required this.sourceSet,
    List<String> sourceKeys = const [],
    this.clientCapabilities,
    this.allowLowLatency = false,
    this.allowDash = false,
  }) : sourceKeys = List.unmodifiable(sourceKeys);

  @override
  String toString() =>
      'VGStreamingOfflineAssetEligibilityRequest(sourceKeys=$sourceKeys, '
      'allowLowLatency=$allowLowLatency, allowDash=$allowDash, '
      'clientCapabilities=$clientCapabilities)';
}

/// Immutable result of an offline HLS asset eligibility evaluation.
class VGStreamingOfflineAssetEligibilityPlan {
  /// Ordered list of candidates eligible for future offline HLS asset acquisition.
  final List<VGStreamingOfflineAssetCandidate> candidates;

  /// Ordered list of sources rejected during evaluation.
  final List<VGStreamingOfflineAssetRejectedSource> rejectedSources;

  /// Source keys requested that were not found in the source set.
  final List<String> unknownKeys;

  /// Advisory warnings collected during plan evaluation.
  final List<String> warnings;

  /// Diagnostic metadata for telemetry and auditing.
  final Map<String, Object?> diagnostics;

  VGStreamingOfflineAssetEligibilityPlan({
    List<VGStreamingOfflineAssetCandidate> candidates = const [],
    List<VGStreamingOfflineAssetRejectedSource> rejectedSources = const [],
    List<String> unknownKeys = const [],
    List<String> warnings = const [],
    Map<String, Object?> diagnostics = const {},
  }) : candidates = List.unmodifiable(candidates),
       rejectedSources = List.unmodifiable(rejectedSources),
       unknownKeys = List.unmodifiable(unknownKeys),
       warnings = List.unmodifiable(warnings),
       diagnostics = Map.unmodifiable(diagnostics);

  /// Whether the plan contains at least one eligible offline asset candidate.
  bool get hasCandidates => candidates.isNotEmpty;

  /// Whether the plan contains at least one rejected source.
  bool get hasRejections => rejectedSources.isNotEmpty;

  @override
  String toString() =>
      'VGStreamingOfflineAssetEligibilityPlan(candidates=${candidates.length}, '
      'rejectedSources=${rejectedSources.length}, unknownKeys=$unknownKeys, '
      'warnings=$warnings)';
}

/// Deterministic pure Dart planner for offline HLS asset eligibility evaluation.
abstract final class VGStreamingOfflineAssetEligibilityPlanner {
  /// Evaluates [request] and returns an immutable [VGStreamingOfflineAssetEligibilityPlan].
  static VGStreamingOfflineAssetEligibilityPlan plan(
    VGStreamingOfflineAssetEligibilityRequest request,
  ) {
    final warnings = <String>[];
    void addWarning(String w) {
      if (!warnings.contains(w)) {
        warnings.add(w);
      }
    }

    final unknownKeys = <String>[];
    final candidateSources = <VGStreamingSourceDescriptor>[];
    final seenKeys = <String>{};

    if (request.sourceKeys.isNotEmpty) {
      for (final key in request.sourceKeys) {
        final source = request.sourceSet.trySourceForKey(key);
        if (source == null) {
          unknownKeys.add(key);
          addWarning('unknown_source_key:$key');
          continue;
        }
        if (!seenKeys.add(source.key)) {
          addWarning('duplicate_source_key:${source.key}');
          continue;
        }
        candidateSources.add(source);
      }
    } else {
      for (final source in request.sourceSet.sources) {
        if (!seenKeys.add(source.key)) {
          addWarning('duplicate_source_key:${source.key}');
          continue;
        }
        candidateSources.add(source);
      }
    }

    final caps = request.clientCapabilities;
    final candidates = <VGStreamingOfflineAssetCandidate>[];
    final rejectedSources = <VGStreamingOfflineAssetRejectedSource>[];

    for (final source in candidateSources) {
      final uriPath = source.uri.path.toLowerCase();
      final isDash =
          source.formatHint == VGStreamingFormatHint.dash ||
          uriPath.endsWith('.mpd');
      final isHls =
          source.formatHint == VGStreamingFormatHint.hls ||
          uriPath.endsWith('.m3u8');
      final isLlHls = source.requireLlHlsTags;

      void reject(
        VGStreamingOfflineAssetEligibilityState state,
        String reason,
      ) {
        rejectedSources.add(
          VGStreamingOfflineAssetRejectedSource(
            sourceKey: source.key,
            state: state,
            reason: reason,
            formatHint: source.formatHint,
            requireLlHlsTags: source.requireLlHlsTags,
          ),
        );
        addWarning('offline_rejected:${source.key}:$reason');
      }

      if (source.uri.scheme != 'http' && source.uri.scheme != 'https') {
        reject(
          VGStreamingOfflineAssetEligibilityState.invalidSource,
          'invalid_offline_uri_scheme',
        );
        continue;
      }

      if (isDash) {
        if (!request.allowDash) {
          reject(
            VGStreamingOfflineAssetEligibilityState.unsupportedFormat,
            'dash_offline_deferred',
          );
          continue;
        }
        if (caps != null && !caps.supportsDash) {
          reject(
            VGStreamingOfflineAssetEligibilityState.clientUnsupported,
            'client_unsupported_dash',
          );
          continue;
        }
        candidates.add(
          VGStreamingOfflineAssetCandidate(
            sourceKey: source.key,
            uri: source.uri,
            httpHeaders: source.httpHeaders,
            formatHint: source.formatHint,
            requireLlHlsTags: source.requireLlHlsTags,
          ),
        );
        continue;
      }

      if (isHls) {
        if (caps != null && !caps.supportsHls) {
          reject(
            VGStreamingOfflineAssetEligibilityState.clientUnsupported,
            'client_unsupported_hls',
          );
          continue;
        }

        if (isLlHls) {
          if (!request.allowLowLatency) {
            reject(
              VGStreamingOfflineAssetEligibilityState.lowLatencyConstrained,
              'low_latency_offline_constrained',
            );
            continue;
          }
          if (caps != null && !caps.supportsLowLatencyHls) {
            reject(
              VGStreamingOfflineAssetEligibilityState.clientUnsupported,
              'client_unsupported_ll_hls',
            );
            continue;
          }
        }

        candidates.add(
          VGStreamingOfflineAssetCandidate(
            sourceKey: source.key,
            uri: source.uri,
            httpHeaders: source.httpHeaders,
            formatHint: source.formatHint,
            requireLlHlsTags: source.requireLlHlsTags,
          ),
        );
        continue;
      }

      reject(
        VGStreamingOfflineAssetEligibilityState.unsupportedFormat,
        'unsupported_offline_format',
      );
    }

    final diagnostics = <String, Object?>{
      'sourceCount': request.sourceSet.sources.length,
      'evaluatedCount': candidateSources.length,
      'candidateCount': candidates.length,
      'rejectedCount': rejectedSources.length,
      'unknownKeyCount': unknownKeys.length,
      'allowLowLatency': request.allowLowLatency,
      'allowDash': request.allowDash,
      if (caps != null) 'clientType': caps.clientType,
      'advisoryOnly': true,
      'playbackMutation': false,
    };

    return VGStreamingOfflineAssetEligibilityPlan(
      candidates: candidates,
      rejectedSources: rejectedSources,
      unknownKeys: unknownKeys,
      warnings: warnings,
      diagnostics: diagnostics,
    );
  }
}
