// Copyright (c) Connects — Vanguard Phase 4C7M.
// Public streaming playback decision planner.
//
// Pure Dart advisory helper: combines streaming preflight report, startup plan,
// and candidate source selection into a unified, immutable app-facing decision
// object without platform coupling, native calls, or side effects.

import 'vg_streaming_playback_client.dart';
import 'vg_streaming_preflight_composite_evaluator.dart';
import 'vg_streaming_source_selector.dart';
import 'vg_streaming_startup_plan.dart';

export 'vg_streaming_playback_client.dart'
    show
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingPlaybackOptions;
export 'vg_streaming_preflight_client.dart' show VGStreamingPreflightReport;
export 'vg_streaming_preflight_composite_evaluator.dart'
    show
        VGStreamingPreflightCompositeEvaluation,
        VGStreamingPreflightCompositeEvaluator;
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

  /// Optional client capability profile for advisory compatibility filtering.
  final VGStreamingSourceClientCapabilities? clientCapabilities;

  const VGStreamingPlaybackDecisionRequest({
    required this.sourceSet,
    required this.preflightReport,
    this.preference = VGStreamingSourceSelectionPreference.preserveOrder,
    this.preferredKeys = const [],
    this.requirePlanToProceed = true,
    this.clientCapabilities,
  });

  @override
  String toString() =>
      'VGStreamingPlaybackDecisionRequest(preference=$preference, '
      'preferredKeys=$preferredKeys, requirePlanToProceed=$requirePlanToProceed, '
      'clientCapabilities=$clientCapabilities)';
}

/// Immutable request configuration for streaming playback decision planning
/// with composite preflight evaluation.
class VGStreamingPlaybackCompositeDecisionRequest {
  /// Candidate set of streaming sources.
  final VGStreamingSourceSet sourceSet;

  /// Preflight advisory report evaluating device and network readiness.
  final VGStreamingPreflightReport preflightReport;

  /// Composite preflight evaluation combining manifest, codec, and compatibility reports.
  final VGStreamingPreflightCompositeEvaluation compositeEvaluation;

  /// Preference strategy for candidate source selection.
  final VGStreamingSourceSelectionPreference preference;

  /// Optional prioritized list of source keys to evaluate.
  final List<String> preferredKeys;

  /// Whether preflight startup plan must pass to proceed to playback.
  final bool requirePlanToProceed;

  /// Optional client capability profile for advisory compatibility filtering.
  final VGStreamingSourceClientCapabilities? clientCapabilities;

  const VGStreamingPlaybackCompositeDecisionRequest({
    required this.sourceSet,
    required this.preflightReport,
    required this.compositeEvaluation,
    this.preference = VGStreamingSourceSelectionPreference.preserveOrder,
    this.preferredKeys = const [],
    this.requirePlanToProceed = true,
    this.clientCapabilities,
  });

  @override
  String toString() =>
      'VGStreamingPlaybackCompositeDecisionRequest(preference=$preference, '
      'preferredKeys=$preferredKeys, requirePlanToProceed=$requirePlanToProceed, '
      'compositeStatus=${compositeEvaluation.status}, '
      'clientCapabilities=$clientCapabilities)';
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
      clientCapabilities: request.clientCapabilities,
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
      if (request.clientCapabilities != null)
        'clientType': request.clientCapabilities!.clientType,
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

  /// Evaluates composite [request] and produces an immutable [VGStreamingPlaybackDecision].
  static VGStreamingPlaybackDecision planFromComposite(
    VGStreamingPlaybackCompositeDecisionRequest request,
  ) {
    // 1. Synthesize startup plan from preflight report.
    final startupPlan = VGStreamingStartupPlanner.fromPreflight(
      request.preflightReport,
    );

    final composite = request.compositeEvaluation;

    // 2. Build composite diagnostics helper map.
    Map<String, Object?> buildCompositeDiagnostics({
      required Map<String, Object?> baseDiagnostics,
      required bool canOpenPlayback,
    }) {
      final map = <String, Object?>{
        ...baseDiagnostics,
        'compositeStatus': composite.status,
        'compositePass': composite.pass,
        'compositeAdvisoryOnly': composite.advisoryOnly,
        'compositePlaybackMutation': composite.playbackMutation,
        'compositeAvcBaselinePass': composite.avcBaselinePass,
        'compositeServerLadderPolicyPass': composite.serverLadderPolicyPass,
        'compositeTotalStreamsEvaluated': composite.totalStreamsEvaluated,
        'compositePassedStreams': composite.passedStreams,
        'compositeFailedStreams': composite.failedStreams,
        'canOpenPlayback': canOpenPlayback,
      };
      return Map<String, Object?>.unmodifiable(map);
    }

    // 3. Composite block branch if composite evaluation fails.
    if (!composite.pass) {
      final blockDecision = 'composite_preflight_blocked:${composite.status}';

      // Deduplicate warnings in encounter order: composite.warnings -> startupPlan.warnings -> blockDecision
      final combinedWarnings = <String>[];
      for (final w in composite.warnings) {
        if (!combinedWarnings.contains(w)) {
          combinedWarnings.add(w);
        }
      }
      for (final w in startupPlan.warnings) {
        if (!combinedWarnings.contains(w)) {
          combinedWarnings.add(w);
        }
      }
      if (!combinedWarnings.contains(blockDecision)) {
        combinedWarnings.add(blockDecision);
      }

      final unmodifiableWarnings = List<String>.unmodifiable(combinedWarnings);

      final nonSelectedSelection = VGStreamingSourceSelection(
        selected: false,
        selectedKey: null,
        source: null,
        playbackOptions: null,
        decision: blockDecision,
        consideredKeys: const [],
        warnings: unmodifiableWarnings,
        diagnostics: const {},
      );

      final baseDiagnostics = <String, Object?>{
        'preflightPhase': request.preflightReport.phase,
        'preflightPass': request.preflightReport.pass,
        'startupReason': startupPlan.reason,
        'selectionDecision': nonSelectedSelection.decision,
        'preference': request.preference.name,
        'selectedKey': null,
        'requirePlanToProceed': request.requirePlanToProceed,
        'recommendedNetworkProfile': startupPlan.recommendedNetworkProfile
            .toNative(),
        if (request.clientCapabilities != null)
          'clientType': request.clientCapabilities!.clientType,
      };

      return VGStreamingPlaybackDecision(
        startupPlan: startupPlan,
        selection: nonSelectedSelection,
        canOpenPlayback: false,
        selectedKey: null,
        selectedSource: null,
        playbackOptions: null,
        decision: blockDecision,
        warnings: unmodifiableWarnings,
        diagnostics: buildCompositeDiagnostics(
          baseDiagnostics: baseDiagnostics,
          canOpenPlayback: false,
        ),
      );
    }

    // 4. Composite pass: delegate to existing base planning.
    final baseDecision = plan(
      VGStreamingPlaybackDecisionRequest(
        sourceSet: request.sourceSet,
        preflightReport: request.preflightReport,
        preference: request.preference,
        preferredKeys: request.preferredKeys,
        requirePlanToProceed: request.requirePlanToProceed,
        clientCapabilities: request.clientCapabilities,
      ),
    );

    // Merge base decision warnings with composite warnings (deduped in encounter order: baseDecision -> composite)
    final combinedWarnings = <String>[];
    for (final w in baseDecision.warnings) {
      if (!combinedWarnings.contains(w)) {
        combinedWarnings.add(w);
      }
    }
    for (final w in composite.warnings) {
      if (!combinedWarnings.contains(w)) {
        combinedWarnings.add(w);
      }
    }

    return VGStreamingPlaybackDecision(
      startupPlan: baseDecision.startupPlan,
      selection: baseDecision.selection,
      canOpenPlayback: baseDecision.canOpenPlayback,
      selectedKey: baseDecision.selectedKey,
      selectedSource: baseDecision.selectedSource,
      playbackOptions: baseDecision.playbackOptions,
      decision: baseDecision.decision,
      warnings: List<String>.unmodifiable(combinedWarnings),
      diagnostics: buildCompositeDiagnostics(
        baseDiagnostics: baseDecision.diagnostics,
        canOpenPlayback: baseDecision.canOpenPlayback,
      ),
    );
  }
}
