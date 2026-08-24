// Copyright (c) Connects — Vanguard Phase 4C7K.
// Public streaming source selector.
//
// Pure Dart advisory helper: evaluates candidate streaming sources against
// a validated startup plan and caller preferences without native coupling
// or side effects.

import 'vg_streaming_source_descriptor.dart';

export 'vg_streaming_playback_client.dart'
    show
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingPlaybackOptions;
export 'vg_streaming_source_descriptor.dart'
    show VGStreamingSourceDescriptor, VGStreamingSourceSet;
export 'vg_streaming_startup_plan.dart' show VGStreamingStartupPlan;

/// Preference strategy for selecting among candidate streaming sources.
enum VGStreamingSourceSelectionPreference {
  /// Preserves candidate ordering and selects the first available candidate.
  preserveOrder,

  /// Prefers HLS manifests over other streaming formats.
  preferHls,

  /// Prefers DASH manifests over other streaming formats.
  preferDash,

  /// Prefers low-latency configurations (LL-HLS partial segments/preload hints).
  preferLowLatency,

  /// Prefers standard latency / high reliability streams over low-latency tags.
  preferConstrainedReliability,
}

/// Pure Dart advisory client capabilities/profile model for streaming source selection.
class VGStreamingSourceClientCapabilities {
  /// Identifier describing the playback client / engine type.
  final String clientType;

  /// Whether the client engine supports standard HLS (.m3u8).
  final bool supportsHls;

  /// Whether the client engine supports DASH (.mpd).
  final bool supportsDash;

  /// Whether the client engine supports Low-Latency HLS (LL-HLS).
  final bool supportsLowLatencyHls;

  /// Advisory preference to prioritize Low-Latency sources when supported.
  final bool preferLowLatency;

  const VGStreamingSourceClientCapabilities({
    required this.clientType,
    this.supportsHls = true,
    this.supportsDash = true,
    this.supportsLowLatencyHls = true,
    this.preferLowLatency = false,
  }) : assert(clientType.length > 0, 'clientType must not be empty');

  /// Apple native AVPlayer capabilities (supports HLS and LL-HLS, does not support DASH).
  const VGStreamingSourceClientCapabilities.appleAvPlayer({
    bool preferLowLatency = false,
  }) : this(
         clientType: 'apple_avplayer',
         supportsHls: true,
         supportsDash: false,
         supportsLowLatencyHls: true,
         preferLowLatency: preferLowLatency,
       );

  /// Android Media3 / ExoPlayer capabilities (supports HLS, DASH, and LL-HLS).
  const VGStreamingSourceClientCapabilities.androidMedia3({
    bool preferLowLatency = false,
  }) : this(
         clientType: 'android_media3',
         supportsHls: true,
         supportsDash: true,
         supportsLowLatencyHls: true,
         preferLowLatency: preferLowLatency,
       );

  /// Web DASH-capable capabilities (supports HLS, DASH, and LL-HLS).
  const VGStreamingSourceClientCapabilities.webDashCapable({
    bool preferLowLatency = false,
  }) : this(
         clientType: 'web_dash_capable',
         supportsHls: true,
         supportsDash: true,
         supportsLowLatencyHls: true,
         preferLowLatency: preferLowLatency,
       );

  /// Generic HLS-only client capabilities (supports HLS/LL-HLS, not DASH).
  const VGStreamingSourceClientCapabilities.hlsOnly({
    String clientType = 'hls_only',
    bool preferLowLatency = false,
  }) : this(
         clientType: clientType,
         supportsHls: true,
         supportsDash: false,
         supportsLowLatencyHls: true,
         preferLowLatency: preferLowLatency,
       );

  @override
  String toString() =>
      'VGStreamingSourceClientCapabilities(clientType=$clientType, '
      'supportsHls=$supportsHls, supportsDash=$supportsDash, '
      'supportsLowLatencyHls=$supportsLowLatencyHls, '
      'preferLowLatency=$preferLowLatency)';
}

/// Immutable request configuration for streaming source selection.
class VGStreamingSourceSelectionRequest {
  /// Candidate set of streaming sources.
  final VGStreamingSourceSet sourceSet;

  /// Validated startup plan derived from preflight.
  final VGStreamingStartupPlan startupPlan;

  /// Selection preference strategy.
  final VGStreamingSourceSelectionPreference preference;

  /// Optional prioritized list of source keys to evaluate before other candidates.
  final List<String> preferredKeys;

  /// Whether preflight [startupPlan.shouldProceed] must be true to select a source.
  final bool requirePlanToProceed;

  /// Optional client capability profile for advisory compatibility filtering.
  final VGStreamingSourceClientCapabilities? clientCapabilities;

  const VGStreamingSourceSelectionRequest({
    required this.sourceSet,
    required this.startupPlan,
    this.preference = VGStreamingSourceSelectionPreference.preserveOrder,
    this.preferredKeys = const [],
    this.requirePlanToProceed = true,
    this.clientCapabilities,
  });

  @override
  String toString() =>
      'VGStreamingSourceSelectionRequest(preference=$preference, '
      'preferredKeys=$preferredKeys, requirePlanToProceed=$requirePlanToProceed, '
      'clientCapabilities=$clientCapabilities)';
}

/// Immutable result of a streaming source selection evaluation.
class VGStreamingSourceSelection {
  /// Whether a candidate source was successfully selected and configured.
  final bool selected;

  /// Key of the selected source, or `null` if no source was selected.
  final String? selectedKey;

  /// Selected source descriptor, or `null` if selection failed.
  final VGStreamingSourceDescriptor? source;

  /// Configured playback options derived from the selected source and startup plan.
  final VGStreamingPlaybackOptions? playbackOptions;

  /// Explanation or decision identifier for the selection result.
  final String decision;

  /// List of source keys considered during evaluation.
  final List<String> consideredKeys;

  /// Warnings collected during candidate evaluation and option derivation.
  final List<String> warnings;

  /// Diagnostic metadata for inspection and telemetry.
  final Map<String, Object?> diagnostics;

  const VGStreamingSourceSelection({
    required this.selected,
    this.selectedKey,
    this.source,
    this.playbackOptions,
    required this.decision,
    this.consideredKeys = const [],
    this.warnings = const [],
    this.diagnostics = const {},
  });

  @override
  String toString() =>
      'VGStreamingSourceSelection(selected=$selected, selectedKey=$selectedKey, '
      'decision=$decision, consideredKeys=$consideredKeys, warnings=$warnings)';
}

/// Deterministic pure Dart helper for selecting candidate streaming sources.
abstract final class VGStreamingSourceSelector {
  /// Evaluates [request] and returns a [VGStreamingSourceSelection].
  static VGStreamingSourceSelection select(
    VGStreamingSourceSelectionRequest request,
  ) {
    final warnings = <String>[];

    // Rule 1: Validate startup plan gating if required.
    if (request.requirePlanToProceed && !request.startupPlan.shouldProceed) {
      warnings.add('startup_plan_blocked');
      warnings.addAll(request.startupPlan.warnings);
      return VGStreamingSourceSelection(
        selected: false,
        selectedKey: null,
        source: null,
        playbackOptions: null,
        decision: 'startup_plan_blocked',
        consideredKeys: const [],
        warnings: List<String>.unmodifiable(warnings),
        diagnostics: {
          'reason': request.startupPlan.reason,
          'requirePlanToProceed': true,
        },
      );
    }

    // Rule 2 & 3: Resolve candidate list from preferredKeys or fallback to sourceSet.
    final candidates = <VGStreamingSourceDescriptor>[];

    if (request.preferredKeys.isNotEmpty) {
      for (final key in request.preferredKeys) {
        final match = request.sourceSet.trySourceForKey(key);
        if (match != null) {
          if (!candidates.contains(match)) {
            candidates.add(match);
          }
        } else {
          warnings.add('unknown_preferred_key:$key');
        }
      }
    }

    if (candidates.isEmpty) {
      candidates.addAll(request.sourceSet.sources);
    }

    final consideredKeys = candidates.map((s) => s.key).toList();

    // Rule 4: Apply client capabilities compatibility filtering if provided.
    final caps = request.clientCapabilities;
    final compatibleCandidates = <VGStreamingSourceDescriptor>[];
    if (caps != null) {
      for (final candidate in candidates) {
        final isDash =
            candidate.formatHint == VGStreamingFormatHint.dash ||
            candidate.uri.path.toLowerCase().endsWith('.mpd');
        final isHls =
            candidate.formatHint == VGStreamingFormatHint.hls ||
            candidate.uri.path.toLowerCase().endsWith('.m3u8');
        final isLlHls = candidate.requireLlHlsTags == true;

        if (isDash && !caps.supportsDash) {
          warnings.add(
            'source_incompatible:${candidate.key}:dash_not_supported',
          );
          continue;
        }

        if (isLlHls && !caps.supportsLowLatencyHls) {
          warnings.add(
            'source_incompatible:${candidate.key}:ll_hls_not_supported',
          );
          continue;
        }

        if (isHls && !caps.supportsHls) {
          warnings.add(
            'source_incompatible:${candidate.key}:hls_not_supported',
          );
          continue;
        }

        compatibleCandidates.add(candidate);
      }

      if (compatibleCandidates.isEmpty) {
        warnings.add('no_compatible_source');
        final diagnostics = <String, Object?>{
          'preference': request.preference.name,
          'clientType': caps.clientType,
          'supportsHls': caps.supportsHls,
          'supportsDash': caps.supportsDash,
          'supportsLowLatencyHls': caps.supportsLowLatencyHls,
          'preferLowLatency': caps.preferLowLatency,
          'candidateCount': candidates.length,
          'compatibleCandidateCount': 0,
        };

        return VGStreamingSourceSelection(
          selected: false,
          selectedKey: null,
          source: null,
          playbackOptions: null,
          decision: 'no_compatible_source',
          consideredKeys: List<String>.unmodifiable(consideredKeys),
          warnings: List<String>.unmodifiable(warnings),
          diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
        );
      }
    } else {
      compatibleCandidates.addAll(candidates);
    }

    // Rule 5: Apply preference strategy on compatible candidates.
    VGStreamingSourceDescriptor chosenSource;
    switch (request.preference) {
      case VGStreamingSourceSelectionPreference.preserveOrder:
        if (caps != null && caps.preferLowLatency) {
          chosenSource = compatibleCandidates.firstWhere(
            (s) => s.requireLlHlsTags == true,
            orElse: () => compatibleCandidates.first,
          );
        } else {
          chosenSource = compatibleCandidates.first;
        }
        break;
      case VGStreamingSourceSelectionPreference.preferHls:
        if (caps != null && caps.preferLowLatency) {
          chosenSource = compatibleCandidates.firstWhere(
            (s) =>
                s.formatHint == VGStreamingFormatHint.hls &&
                s.requireLlHlsTags == true,
            orElse: () => compatibleCandidates.firstWhere(
              (s) => s.formatHint == VGStreamingFormatHint.hls,
              orElse: () => compatibleCandidates.first,
            ),
          );
        } else {
          chosenSource = compatibleCandidates.firstWhere(
            (s) => s.formatHint == VGStreamingFormatHint.hls,
            orElse: () => compatibleCandidates.first,
          );
        }
        break;
      case VGStreamingSourceSelectionPreference.preferDash:
        chosenSource = compatibleCandidates.firstWhere(
          (s) => s.formatHint == VGStreamingFormatHint.dash,
          orElse: () => compatibleCandidates.first,
        );
        break;
      case VGStreamingSourceSelectionPreference.preferLowLatency:
        chosenSource = compatibleCandidates.firstWhere(
          (s) => s.requireLlHlsTags == true,
          orElse: () => compatibleCandidates.first,
        );
        break;
      case VGStreamingSourceSelectionPreference.preferConstrainedReliability:
        chosenSource = compatibleCandidates.firstWhere(
          (s) => s.requireLlHlsTags == false,
          orElse: () => compatibleCandidates.first,
        );
        break;
    }

    // Rule 6: Derive playback options using the chosen source and startup plan.
    VGStreamingPlaybackOptions? playbackOptions;
    try {
      playbackOptions = chosenSource.toPlaybackOptions(request.startupPlan);
    } catch (e) {
      warnings.add('playback_options_blocked');
      warnings.add('option_derivation_error:$e');
      final diagnostics = <String, Object?>{
        'error': e.toString(),
        'preference': request.preference.name,
        if (caps != null) ...{
          'clientType': caps.clientType,
          'supportsHls': caps.supportsHls,
          'supportsDash': caps.supportsDash,
          'supportsLowLatencyHls': caps.supportsLowLatencyHls,
          'preferLowLatency': caps.preferLowLatency,
        },
      };
      return VGStreamingSourceSelection(
        selected: false,
        selectedKey: chosenSource.key,
        source: chosenSource,
        playbackOptions: null,
        decision: 'playback_options_blocked',
        consideredKeys: List<String>.unmodifiable(consideredKeys),
        warnings: List<String>.unmodifiable(warnings),
        diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
      );
    }

    final diagnostics = <String, Object?>{
      'preference': request.preference.name,
      'formatHint': chosenSource.formatHint.name,
      'requireLlHlsTags': chosenSource.requireLlHlsTags,
      if (caps != null) ...{
        'clientType': caps.clientType,
        'supportsHls': caps.supportsHls,
        'supportsDash': caps.supportsDash,
        'supportsLowLatencyHls': caps.supportsLowLatencyHls,
        'preferLowLatency': caps.preferLowLatency,
      },
    };

    return VGStreamingSourceSelection(
      selected: true,
      selectedKey: chosenSource.key,
      source: chosenSource,
      playbackOptions: playbackOptions,
      decision: 'source_selected',
      consideredKeys: List<String>.unmodifiable(consideredKeys),
      warnings: List<String>.unmodifiable(warnings),
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
    );
  }
}
