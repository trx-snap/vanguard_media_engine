// vg_passthrough_remux_decision.dart
// Vanguard Media Engine -- Phase 2-Unit AB
// Public Passthrough Remux Decision Planner & Composite Readiness Report.
//
// Invariants:
// - Composes Unit W VGPassthroughRemuxEvaluator and Unit AA VGPassthroughRemuxCapabilityClient.
// - Pure Dart advisory planner returning fail-closed readiness reports.
// - Zero native muxing, zero sample reads, zero output writing, zero codec allocation.
// - Zero production export timeline bypass, zero C++ sink node creation, zero ConnectsApp touch.

import 'dart:async';

import 'vg_editor_draft.dart';
import 'vg_editor_export_request.dart';
import 'vg_passthrough_remux_capability_client.dart';
import 'vg_passthrough_remux_evaluator.dart';

/// Signature for probing Android passthrough remux capability of a source path.
typedef VGPassthroughRemuxCapabilityProbe =
    Future<VGPassthroughRemuxCapabilityReport> Function(String sourcePath);

/// Composite readiness report combining Unit W preflight evaluation and
/// Unit AA native platform capability inspection.
class VGPassthroughRemuxDecisionReport {
  /// Expected composite decision proof boundary token.
  static const String expectedProofBoundary =
      'passthrough_remux_decision_planner_preflight_composite_advisory';

  /// Standard Unit AB invariant non-claims map.
  static const Map<String, bool> standardNonClaims = <String, bool>{
    'mediaMuxerStarted': false,
    'mediaCodecAllocated': false,
    'samplesRead': false,
    'outputFileWritten': false,
    'productionExportTimelineBypass': false,
    'cppPassthroughRemuxSinkNode': false,
    'connectAppTouched': false,
  };

  /// Whether the evaluated draft and source media are ready for zero-reencode passthrough remux.
  final bool canPassthroughRemux;

  /// Diagnostic reason explaining the decision (e.g. 'ready', 'preflight_ineligible', 'capability_ineligible:...').
  final String reason;

  /// Pure Dart preflight evaluation report from Unit W.
  final VGPassthroughRemuxReport preflightReport;

  /// Native platform capability probe report from Unit AA, or null if preflight was ineligible.
  final VGPassthroughRemuxCapabilityReport? capabilityReport;

  /// Whether a native capability probe was attempted.
  final bool capabilityProbeAttempted;

  /// Proof boundary token for this composite advisory planner.
  final String proofBoundary;

  /// Invariant non-claims verifying no execution side effects took place.
  final Map<String, bool> nonClaims;

  /// Raw diagnostic dictionary for telemetry and debugging.
  final Map<String, Object?> diagnostics;

  const VGPassthroughRemuxDecisionReport({
    required this.canPassthroughRemux,
    required this.reason,
    required this.preflightReport,
    this.capabilityReport,
    required this.capabilityProbeAttempted,
    this.proofBoundary = expectedProofBoundary,
    this.nonClaims = standardNonClaims,
    this.diagnostics = const <String, Object?>{},
  });

  /// Convenience getter indicating readiness for passthrough remux.
  bool get isReady => canPassthroughRemux;

  /// Convenience getter indicating passthrough remux is blocked.
  bool get isBlocked => !canPassthroughRemux;

  /// Whether the report proof boundary matches the expected Unit AB token.
  bool get proofBoundaryMatches => proofBoundary == expectedProofBoundary;

  /// Whether all invariant non-claims strictly hold (all false).
  bool get diagnosticNonClaimsHold {
    if (nonClaims.isEmpty) return false;
    const requiredKeys = <String>[
      'mediaMuxerStarted',
      'mediaCodecAllocated',
      'samplesRead',
      'outputFileWritten',
      'productionExportTimelineBypass',
      'cppPassthroughRemuxSinkNode',
      'connectAppTouched',
    ];
    for (final key in requiredKeys) {
      if (nonClaims[key] != false) {
        return false;
      }
    }
    return nonClaims.values.every((v) => v == false);
  }

  /// Converts this decision report to a JSON-compatible map.
  Map<String, Object?> toMap() => <String, Object?>{
    'canPassthroughRemux': canPassthroughRemux,
    'reason': reason,
    'isReady': isReady,
    'isBlocked': isBlocked,
    'capabilityProbeAttempted': capabilityProbeAttempted,
    'proofBoundary': proofBoundary,
    'proofBoundaryMatches': proofBoundaryMatches,
    'diagnosticNonClaimsHold': diagnosticNonClaimsHold,
    'preflightReport': preflightReport.toMap(),
    'capabilityReport': capabilityReport?.toMap(),
    'nonClaims': nonClaims,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGPassthroughRemuxDecisionReport(canPassthroughRemux: $canPassthroughRemux, reason: $reason, capabilityProbeAttempted: $capabilityProbeAttempted, proofBoundary: $proofBoundary, preflightReport: $preflightReport, capabilityReport: $capabilityReport)';
}

/// Advisory planner that composes Unit W preflight evaluation and Unit AA native
/// capability probing into a single fail-closed [VGPassthroughRemuxDecisionReport].
class VGPassthroughRemuxDecisionPlanner {
  /// Evaluator used for preflight timeline inspection.
  final VGPassthroughRemuxEvaluator evaluator;

  /// Optional injected capability probe callback for testing.
  final VGPassthroughRemuxCapabilityProbe? _capabilityProbe;

  const VGPassthroughRemuxDecisionPlanner({
    this.evaluator = const VGPassthroughRemuxEvaluator(),
    VGPassthroughRemuxCapabilityProbe? capabilityProbe,
  }) : _capabilityProbe = capabilityProbe;

  /// Evaluates the given [draft] and optional [request] to produce a fail-closed
  /// [VGPassthroughRemuxDecisionReport].
  Future<VGPassthroughRemuxDecisionReport> evaluate({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
  }) async {
    // 1. Always run Unit W preflight first.
    final preflightReport = evaluator.evaluate(draft: draft, request: request);

    // 2. If Unit W preflight is ineligible, fail-closed without probing native capability.
    if (preflightReport.isIneligible) {
      final diagnostics = <String, Object?>{
        'preflightReport': preflightReport.toMap(),
        'capabilityProbeAttempted': false,
        'proofBoundary': VGPassthroughRemuxDecisionReport.expectedProofBoundary,
        'nonClaims': VGPassthroughRemuxDecisionReport.standardNonClaims,
      };
      return VGPassthroughRemuxDecisionReport(
        canPassthroughRemux: false,
        reason: 'preflight_ineligible',
        preflightReport: preflightReport,
        capabilityReport: null,
        capabilityProbeAttempted: false,
        proofBoundary: VGPassthroughRemuxDecisionReport.expectedProofBoundary,
        nonClaims: VGPassthroughRemuxDecisionReport.standardNonClaims,
        diagnostics: diagnostics,
      );
    }

    // 3. Preflight passed: exactly one clip is present.
    final sourcePath = draft.clips.single.sourcePath;

    // 4. Call capability probe.
    VGPassthroughRemuxCapabilityReport capabilityReport;
    try {
      final probe = _capabilityProbe ?? _defaultCapabilityProbe;
      capabilityReport = await probe(sourcePath);
    } catch (e) {
      final diagnostics = <String, Object?>{
        'sourcePath': sourcePath,
        'preflightReport': preflightReport.toMap(),
        'capabilityProbeAttempted': true,
        'error': '$e',
        'proofBoundary': VGPassthroughRemuxDecisionReport.expectedProofBoundary,
        'nonClaims': VGPassthroughRemuxDecisionReport.standardNonClaims,
      };
      return VGPassthroughRemuxDecisionReport(
        canPassthroughRemux: false,
        reason: 'capability_probe_exception:$e',
        preflightReport: preflightReport,
        capabilityReport: null,
        capabilityProbeAttempted: true,
        proofBoundary: VGPassthroughRemuxDecisionReport.expectedProofBoundary,
        nonClaims: VGPassthroughRemuxDecisionReport.standardNonClaims,
        diagnostics: diagnostics,
      );
    }

    // 5. Evaluate capability report invariants.
    final canPassthroughRemux =
        capabilityReport.canPassthroughRemux &&
        capabilityReport.proofBoundaryMatches &&
        capabilityReport.diagnosticNonClaimsHold &&
        capabilityReport.hasSupportedVideo &&
        capabilityReport.hasSupportedAudioOrNoAudio;

    final String reason;
    if (canPassthroughRemux) {
      reason = 'ready';
    } else if (!capabilityReport.canPassthroughRemux) {
      reason = 'capability_ineligible:${capabilityReport.reason}';
    } else if (!capabilityReport.proofBoundaryMatches) {
      reason = 'capability_ineligible:proof_boundary_mismatch';
    } else if (!capabilityReport.diagnosticNonClaimsHold) {
      reason = 'capability_ineligible:non_claims_violation';
    } else if (!capabilityReport.hasSupportedVideo) {
      reason = 'capability_ineligible:unsupported_video';
    } else if (!capabilityReport.hasSupportedAudioOrNoAudio) {
      reason = 'capability_ineligible:unsupported_audio';
    } else {
      reason = 'capability_ineligible:unsupported';
    }

    final diagnostics = <String, Object?>{
      'sourcePath': sourcePath,
      'preflightReport': preflightReport.toMap(),
      'capabilityReport': capabilityReport.toMap(),
      'capabilityProbeAttempted': true,
      'proofBoundary': VGPassthroughRemuxDecisionReport.expectedProofBoundary,
      'nonClaims': VGPassthroughRemuxDecisionReport.standardNonClaims,
    };

    return VGPassthroughRemuxDecisionReport(
      canPassthroughRemux: canPassthroughRemux,
      reason: reason,
      preflightReport: preflightReport,
      capabilityReport: capabilityReport,
      capabilityProbeAttempted: true,
      proofBoundary: VGPassthroughRemuxDecisionReport.expectedProofBoundary,
      nonClaims: VGPassthroughRemuxDecisionReport.standardNonClaims,
      diagnostics: diagnostics,
    );
  }

  static Future<VGPassthroughRemuxCapabilityReport> _defaultCapabilityProbe(
    String sourcePath,
  ) {
    return VGPassthroughRemuxCapabilityClient().probe(sourcePath);
  }

  /// Convenience static evaluation entry point.
  static Future<VGPassthroughRemuxDecisionReport> evaluateDraft({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
    VGPassthroughRemuxCapabilityProbe? capabilityProbe,
  }) => VGPassthroughRemuxDecisionPlanner(
    capabilityProbe: capabilityProbe,
  ).evaluate(draft: draft, request: request);
}
