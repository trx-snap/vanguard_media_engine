// Copyright (c) Connects — Vanguard Phase 4C7M.
// Public streaming playback decision planner.
//
// Pure Dart advisory helper: combines streaming preflight report, startup plan,
// and candidate source selection into a unified, immutable app-facing decision
// object without platform coupling, native calls, or side effects.

import 'vg_streaming_playback_client.dart';
import 'vg_streaming_source_selector.dart';
import 'vg_streaming_startup_plan.dart';

export 'vg_streaming_playback_client.dart'
    show
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingPlaybackOptions;
export 'vg_streaming_preflight_client.dart' show VGStreamingPreflightReport;
export 'vg_streaming_source_descriptor.dart'
    show VGStreamingSourceDescriptor, VGStreamingSourceSet;
export 'vg_streaming_source_selector.dart'
    show
        VGStreamingSourceSelection,
        VGStreamingSourceSelectionPreference,
        VGStreamingSourceSelectionRequest,
        VGStreamingSourceSelector;
export 'vg_streaming_startup_plan.dart'
    show VGStreamingStartupPlan, VGStreamingStartupPlanner;

/// Immutable request configuration for streaming playback decision planning.
class VGStreamingPlaybackDecisionRequest {
  /// Candidate set of streaming sources.
  final VGStreamingSourceSet sourceSet;

  /// Preflight advisory report evaluating device and network readiness.
  final VGStreamingPreflightReport preflightReport;

  /// Preference strategy for candidate source selection.
  final VGStreamingSourceSelectionPreference preference;

  /// Optional prioritized list of source keys to evaluate.
  final List<String> preferredKeys;

  /// Whether preflight startup plan must pass to proceed to playback.
  final bool requirePlanToProceed;

  const VGStreamingPlaybackDecisionRequest({
    required this.sourceSet,
    required this.preflightReport,
    this.preference = VGStreamingSourceSelectionPreference.preserveOrder,
    this.preferredKeys = const [],
    this.requirePlanToProceed = true,
  });

  @override
  String toString() =>
      'VGStreamingPlaybackDecisionRequest(preference=$preference, '
      'preferredKeys=$preferredKeys, requirePlanToProceed=$requirePlanToProceed)';
}

/// Immutable result of a streaming playback decision evaluation.
class VGStreamingPlaybackDecision {
  /// Startup plan derived from preflight evaluation.
  final VGStreamingStartupPlan startupPlan;

  /// Candidate source selection result.
  final VGStreamingSourceSelection selection;

  /// Whether playback can proceed safely.
  final bool canOpenPlayback;

  /// Key of the selected streaming source, or `null` if no source was selected.
  final String? selectedKey;

  /// Selected streaming source descriptor, or `null` if selection failed.
  final VGStreamingSourceDescriptor? selectedSource;

  /// Validated playback options ready for [VGStreamingPlaybackClient.open],
  /// or `null` if playback cannot proceed.
  final VGStreamingPlaybackOptions? playbackOptions;

  /// High-level decision identifier (e.g. `playback_ready`, `startup_plan_blocked`).
  final String decision;

  /// Combined list of warnings from preflight, startup plan, and source selector.
  final List<String> warnings;

  /// Diagnostic metadata for logging and telemetry.
  final Map<String, Object?> diagnostics;

  const VGStreamingPlaybackDecision({
    required this.startupPlan,
    required this.selection,
    required this.canOpenPlayback,
    this.selectedKey,
    this.selectedSource,
    this.playbackOptions,
    required this.decision,
    this.warnings = const [],
    this.diagnostics = const {},
  });

  @override
  String toString() =>
      'VGStreamingPlaybackDecision(canOpenPlayback=$canOpenPlayback, '
      'selectedKey=$selectedKey, decision=$decision, warnings=$warnings)';
}

/// Deterministic pure Dart planner for streaming playback decisions.
abstract final class VGStreamingPlaybackDecisionPlanner {
  /// Evaluates [request] and produces an immutable [VGStreamingPlaybackDecision].
  static VGStreamingPlaybackDecision plan(
    VGStreamingPlaybackDecisionRequest request,
  ) {
    // 1. Synthesize startup plan from preflight report.
    final startupPlan = VGStreamingStartupPlanner.fromPreflight(
      request.preflightReport,
    );

    // 2. Select source using candidate source set and startup plan.
    final selectionRequest = VGStreamingSourceSelectionRequest(
      sourceSet: request.sourceSet,
      startupPlan: startupPlan,
      preference: request.preference,
      preferredKeys: request.preferredKeys,
      requirePlanToProceed: request.requirePlanToProceed,
    );
    final selection = VGStreamingSourceSelector.select(selectionRequest);

    // 3. Determine if playback can proceed.
    final canOpenPlayback =
        startupPlan.shouldProceed &&
        selection.selected &&
        selection.playbackOptions != null;

    // 4. Determine decision identifier.
    final String decision;
    if (canOpenPlayback) {
      decision = 'playback_ready';
    } else if (!startupPlan.shouldProceed) {
      decision = 'startup_plan_blocked';
    } else {
      decision = selection.decision;
    }

    // 5. Combine warnings without mutating input lists.
    final combinedWarnings = <String>[];
    for (final warning in startupPlan.warnings) {
      if (!combinedWarnings.contains(warning)) {
        combinedWarnings.add(warning);
      }
    }
    for (final warning in selection.warnings) {
      if (!combinedWarnings.contains(warning)) {
        combinedWarnings.add(warning);
      }
    }

    // 6. Diagnostics metadata.
    final diagnostics = <String, Object?>{
      'preflightPhase': request.preflightReport.phase,
      'preflightPass': request.preflightReport.pass,
      'startupReason': startupPlan.reason,
      'selectionDecision': selection.decision,
      'preference': request.preference.name,
      'selectedKey': selection.selectedKey,
      'canOpenPlayback': canOpenPlayback,
      'requirePlanToProceed': request.requirePlanToProceed,
      'recommendedNetworkProfile': startupPlan.recommendedNetworkProfile
          .toNative(),
    };

    return VGStreamingPlaybackDecision(
      startupPlan: startupPlan,
      selection: selection,
      canOpenPlayback: canOpenPlayback,
      selectedKey: selection.selectedKey,
      selectedSource: selection.source,
      playbackOptions: canOpenPlayback ? selection.playbackOptions : null,
      decision: decision,
      warnings: List<String>.unmodifiable(combinedWarnings),
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
    );
  }
}
