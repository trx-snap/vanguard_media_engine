// vg_editor_export_admission.dart
// Vanguard Media Engine -- Phase 2-Unit AC
// Public Export Route Admission Planner & Decision Adapter.
//
// Invariants:
// - Composes Unit J VGEditorExportReadinessEvaluator and Unit AB VGPassthroughRemuxDecisionPlanner.
// - Pure Dart advisory planner returning fail-closed export route admission reports.
// - Zero native muxing, zero sample reads, zero output writing, zero codec allocation.
// - Zero production export timeline bypass, zero C++ sink node creation, zero ConnectsApp touch.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'vg_editor_draft.dart';
import 'vg_editor_export_readiness.dart';
import 'vg_editor_export_request.dart';
import 'vg_passthrough_remux_decision.dart';

/// Supported export route execution modes for an editor timeline.
enum VGEditorExportRouteMode {
  /// Zero-reencode passthrough remux route (single compatible video clip, no effects).
  passthroughRemux,

  /// Full timeline render and re-encode export route.
  renderExport,

  /// Timeline export is blocked due to invalid, unsupported, or missing inputs.
  blocked,
}

/// Signature for probing passthrough remux decision of a draft and request.
typedef VGEditorExportPassthroughDecisionProbe =
    Future<VGPassthroughRemuxDecisionReport> Function({
      required VGEditorDraft draft,
      VGEditorExportRequest request,
    });

/// Top-level composite export route admission report.
final class VGEditorExportAdmissionReport {
  /// Expected composite decision proof boundary token.
  static const String expectedProofBoundary =
      'export_route_admission_planner_composite_advisory_no_exporttimeline_bypass';

  /// Standard Unit AC invariant non-claims map.
  static const Map<String, bool> standardNonClaims = <String, bool>{
    'productionExportTimelineBypass': false,
    'mediaMuxerStarted': false,
    'mediaCodecAllocated': false,
    'samplesRead': false,
    'outputFileWritten': false,
    'cppPassthroughRemuxSinkNode': false,
    'connectAppTouched': false,
  };

  /// The decided export route mode.
  final VGEditorExportRouteMode routeMode;

  /// Diagnostic reason explaining the admission decision.
  final String reason;

  /// Unit J export readiness preflight report.
  final VGEditorExportReadinessReport exportReadinessReport;

  /// Unit AB passthrough remux decision report, or null if preflight was blocked or threw.
  final VGPassthroughRemuxDecisionReport? passthroughDecisionReport;

  /// Whether a passthrough remux decision probe was attempted.
  final bool passthroughDecisionAttempted;

  /// Proof boundary token for this composite admission planner.
  final String proofBoundary;

  /// Invariant non-claims verifying no execution side effects took place.
  final Map<String, bool> nonClaims;

  /// Raw diagnostic dictionary for telemetry and debugging.
  final Map<String, Object?> diagnostics;

  VGEditorExportAdmissionReport({
    required this.routeMode,
    required this.reason,
    required this.exportReadinessReport,
    this.passthroughDecisionReport,
    required this.passthroughDecisionAttempted,
    this.proofBoundary = expectedProofBoundary,
    Map<String, bool> nonClaims = standardNonClaims,
    Map<String, Object?> diagnostics = const <String, Object?>{},
  }) : nonClaims = Map.unmodifiable(nonClaims),
       diagnostics = Map.unmodifiable(diagnostics);

  /// Convenience getter indicating passthrough remux route should be used.
  bool get usePassthroughRemux =>
      routeMode == VGEditorExportRouteMode.passthroughRemux;

  /// Convenience getter indicating render export route should be used.
  bool get useRenderExport => routeMode == VGEditorExportRouteMode.renderExport;

  /// Convenience getter indicating export is blocked.
  bool get isBlocked => routeMode == VGEditorExportRouteMode.blocked;

  /// Whether the report proof boundary matches the expected Unit AC token.
  bool get proofBoundaryMatches => proofBoundary == expectedProofBoundary;

  /// Whether all invariant non-claims strictly hold (all false).
  bool get diagnosticNonClaimsHold {
    if (nonClaims.isEmpty) return false;
    const requiredKeys = <String>[
      'productionExportTimelineBypass',
      'mediaMuxerStarted',
      'mediaCodecAllocated',
      'samplesRead',
      'outputFileWritten',
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

  /// Serialises this report to a JSON-compatible map.
  Map<String, Object?> toMap() => <String, Object?>{
    'routeMode': routeMode.name,
    'reason': reason,
    'usePassthroughRemux': usePassthroughRemux,
    'useRenderExport': useRenderExport,
    'isBlocked': isBlocked,
    'passthroughDecisionAttempted': passthroughDecisionAttempted,
    'proofBoundary': proofBoundary,
    'proofBoundaryMatches': proofBoundaryMatches,
    'diagnosticNonClaimsHold': diagnosticNonClaimsHold,
    'exportReadinessReport': exportReadinessReport.toMap(),
    'passthroughDecisionReport': passthroughDecisionReport?.toMap(),
    'nonClaims': nonClaims,
    'diagnostics': diagnostics,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGEditorExportAdmissionReport &&
          other.routeMode == routeMode &&
          other.reason == reason &&
          other.exportReadinessReport == exportReadinessReport &&
          other.passthroughDecisionReport == passthroughDecisionReport &&
          other.passthroughDecisionAttempted == passthroughDecisionAttempted &&
          other.proofBoundary == proofBoundary &&
          mapEquals(other.nonClaims, nonClaims) &&
          mapEquals(other.diagnostics, diagnostics);

  @override
  int get hashCode => Object.hash(
    routeMode,
    reason,
    exportReadinessReport.decision,
    passthroughDecisionReport?.canPassthroughRemux,
    passthroughDecisionAttempted,
    proofBoundary,
    Object.hashAll(nonClaims.keys),
    Object.hashAll(nonClaims.values),
    Object.hashAll(diagnostics.keys),
    Object.hashAll(diagnostics.values),
  );

  @override
  String toString() =>
      'VGEditorExportAdmissionReport(routeMode: ${routeMode.name}, reason: $reason, usePassthroughRemux: $usePassthroughRemux, useRenderExport: $useRenderExport, isBlocked: $isBlocked, passthroughDecisionAttempted: $passthroughDecisionAttempted, proofBoundary: $proofBoundary, exportReadinessReport: $exportReadinessReport, passthroughDecisionReport: $passthroughDecisionReport)';
}

/// Advisory planner that composes Unit J export readiness evaluation and Unit AB
/// passthrough remux decision probing into a single fail-closed [VGEditorExportAdmissionReport].
final class VGEditorExportAdmissionPlanner {
  /// Evaluator used for Unit J export readiness preflight inspection.
  final VGEditorExportReadinessEvaluator exportReadinessEvaluator;

  /// Optional injected passthrough decision probe callback for testing.
  final VGEditorExportPassthroughDecisionProbe? _passthroughDecisionProbe;

  const VGEditorExportAdmissionPlanner({
    this.exportReadinessEvaluator = const VGEditorExportReadinessEvaluator(),
    VGEditorExportPassthroughDecisionProbe? passthroughDecisionProbe,
  }) : _passthroughDecisionProbe = passthroughDecisionProbe;

  /// Evaluates the given [draft] and optional [request] to produce a fail-closed
  /// [VGEditorExportAdmissionReport].
  Future<VGEditorExportAdmissionReport> evaluate({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
  }) async {
    // 1. Run Unit J readiness preflight first.
    final exportReadinessReport = exportReadinessEvaluator.evaluate(
      draft: draft,
      request: request,
    );

    // 2. If Unit J is blocked, do not invoke passthrough decision probe.
    if (exportReadinessReport.isBlocked) {
      final diagnostics = <String, Object?>{
        'exportReadinessReport': exportReadinessReport.toMap(),
        'passthroughDecisionAttempted': false,
        'proofBoundary': VGEditorExportAdmissionReport.expectedProofBoundary,
        'nonClaims': VGEditorExportAdmissionReport.standardNonClaims,
      };

      return VGEditorExportAdmissionReport(
        routeMode: VGEditorExportRouteMode.blocked,
        reason: 'export_blocked',
        exportReadinessReport: exportReadinessReport,
        passthroughDecisionReport: null,
        passthroughDecisionAttempted: false,
        proofBoundary: VGEditorExportAdmissionReport.expectedProofBoundary,
        nonClaims: VGEditorExportAdmissionReport.standardNonClaims,
        diagnostics: diagnostics,
      );
    }

    // 3. Unit J is ready; invoke passthrough decision probe.
    VGPassthroughRemuxDecisionReport passthroughDecisionReport;
    try {
      final probe =
          _passthroughDecisionProbe ?? _defaultPassthroughDecisionProbe;
      passthroughDecisionReport = await probe(draft: draft, request: request);
    } catch (e) {
      final diagnostics = <String, Object?>{
        'exportReadinessReport': exportReadinessReport.toMap(),
        'passthroughDecisionAttempted': true,
        'error': '$e',
        'proofBoundary': VGEditorExportAdmissionReport.expectedProofBoundary,
        'nonClaims': VGEditorExportAdmissionReport.standardNonClaims,
      };

      return VGEditorExportAdmissionReport(
        routeMode: VGEditorExportRouteMode.renderExport,
        reason: 'render_export_ready:passthrough_exception',
        exportReadinessReport: exportReadinessReport,
        passthroughDecisionReport: null,
        passthroughDecisionAttempted: true,
        proofBoundary: VGEditorExportAdmissionReport.expectedProofBoundary,
        nonClaims: VGEditorExportAdmissionReport.standardNonClaims,
        diagnostics: diagnostics,
      );
    }

    // 4. Evaluate Unit AB composite report.
    final bool canPassthrough =
        passthroughDecisionReport.isReady &&
        passthroughDecisionReport.proofBoundaryMatches &&
        passthroughDecisionReport.diagnosticNonClaimsHold;

    final capReport = passthroughDecisionReport.capabilityReport;
    final bool isSourceUnavailable =
        capReport != null && (!capReport.fileExists || !capReport.fileReadable);

    final VGEditorExportRouteMode routeMode;
    final String reason;

    if (canPassthrough) {
      routeMode = VGEditorExportRouteMode.passthroughRemux;
      reason = 'passthrough_ready';
    } else if (isSourceUnavailable) {
      routeMode = VGEditorExportRouteMode.blocked;
      reason = 'export_blocked:source_unavailable';
    } else {
      routeMode = VGEditorExportRouteMode.renderExport;
      reason = 'render_export_ready';
    }

    final diagnostics = <String, Object?>{
      'exportReadinessReport': exportReadinessReport.toMap(),
      'passthroughDecisionReport': passthroughDecisionReport.toMap(),
      'passthroughDecisionAttempted': true,
      'proofBoundary': VGEditorExportAdmissionReport.expectedProofBoundary,
      'nonClaims': VGEditorExportAdmissionReport.standardNonClaims,
    };

    return VGEditorExportAdmissionReport(
      routeMode: routeMode,
      reason: reason,
      exportReadinessReport: exportReadinessReport,
      passthroughDecisionReport: passthroughDecisionReport,
      passthroughDecisionAttempted: true,
      proofBoundary: VGEditorExportAdmissionReport.expectedProofBoundary,
      nonClaims: VGEditorExportAdmissionReport.standardNonClaims,
      diagnostics: diagnostics,
    );
  }

  static Future<VGPassthroughRemuxDecisionReport>
  _defaultPassthroughDecisionProbe({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
  }) {
    return const VGPassthroughRemuxDecisionPlanner().evaluate(
      draft: draft,
      request: request,
    );
  }

  /// Convenience static evaluation entry point.
  static Future<VGEditorExportAdmissionReport> evaluateDraft({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
    VGEditorExportReadinessEvaluator exportReadinessEvaluator =
        const VGEditorExportReadinessEvaluator(),
    VGEditorExportPassthroughDecisionProbe? passthroughDecisionProbe,
  }) => VGEditorExportAdmissionPlanner(
    exportReadinessEvaluator: exportReadinessEvaluator,
    passthroughDecisionProbe: passthroughDecisionProbe,
  ).evaluate(draft: draft, request: request);
}
