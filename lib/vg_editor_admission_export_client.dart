// vg_editor_admission_export_client.dart
// Vanguard Media Engine -- Phase 2-Unit AF
// Public Dart Admission-Driven Export Execution Client.
//
// Invariants:
// - Composes Unit AC admission planner, Unit AE passthrough client, and the
//   Phase 10-C VanguardTimelineExporter render path behind one explicit
//   dispatch entry point.
// - Evaluates admission first; never executes a route the admission planner
//   did not select.
// - Does not touch VGEditorController and does not touch ConnectsApp.
// - The render path builds its own disposable
//   flattenOriginalClipAudio().applyAudioCompositionPolicy() draft and never
//   mutates the caller's input draft.

import 'package:flutter/services.dart';

import 'vg_editor_draft.dart';
import 'vg_editor_export_admission.dart';
import 'vg_editor_export_readiness.dart';
import 'vg_editor_export_request.dart';
import 'vg_editor_export_result.dart';
import 'vg_passthrough_remux_client.dart';
import 'vg_timeline_exporter.dart';

/// Signature for probing export route admission for a draft and request.
typedef VGEditorAdmissionExportAdmissionProbe =
    Future<VGEditorExportAdmissionReport> Function({
      required VGEditorDraft draft,
      VGEditorExportRequest request,
    });

/// Signature for executing a passthrough remux request.
typedef VGEditorAdmissionExportPassthroughExecutor =
    Future<VGPassthroughRemuxExecutionReport> Function(
      VGPassthroughRemuxRequest request,
    );

/// Signature for executing a render export. Mirrors
/// [VanguardTimelineExporter.exportDraft] without exposing a MethodChannel
/// parameter in this client's public API.
typedef VGEditorAdmissionExportRenderExecutor =
    Future<VGEditorExportResult> Function({
      required VGEditorDraft draft,
      required VGEditorExportRequest request,
      void Function(double progress)? onProgress,
    });

/// Composite result of an admission-driven export dispatch.
final class VGEditorAdmissionExportReport {
  /// Expected proof boundary token for this dispatcher.
  static const String expectedProofBoundary =
      'admission_export_execution_client_explicit_dispatch_no_controller_no_connectsapp';

  /// Standard non-claims for this client dispatch layer.
  ///
  /// Limited to client/controller/product-level claims. Route execution may
  /// itself allocate MediaMuxer/codec resources, read samples, or write
  /// output -- this client makes no assertion about that.
  static const Map<String, bool> standardNonClaims = <String, bool>{
    'controllerTouched': false,
    'connectAppTouched': false,
    'productionExportTimelineMutated': false,
  };

  /// Whether the overall dispatch succeeded.
  final bool success;

  /// The route mode selected by admission evaluation.
  final VGEditorExportRouteMode routeMode;

  /// Diagnostic reason explaining the dispatch outcome.
  final String reason;

  /// The Unit AC admission report that drove routing.
  final VGEditorExportAdmissionReport admissionReport;

  /// The Unit AE passthrough execution report, when the passthrough route
  /// was attempted.
  final VGPassthroughRemuxExecutionReport? passthroughReport;

  /// The render export result, when the render route succeeded.
  final VGEditorExportResult? renderResult;

  /// Machine-readable error code for fail-closed outcomes.
  final String? errorCode;

  /// Human-readable error message for fail-closed outcomes.
  final String? errorMessage;

  /// Proof boundary token for this dispatch.
  final String proofBoundary;

  /// Raw diagnostic dictionary for telemetry and debugging.
  final Map<String, Object?> diagnostics;

  VGEditorAdmissionExportReport({
    required this.success,
    required this.routeMode,
    required this.reason,
    required this.admissionReport,
    this.passthroughReport,
    this.renderResult,
    this.errorCode,
    this.errorMessage,
    this.proofBoundary = expectedProofBoundary,
    Map<String, Object?> diagnostics = const <String, Object?>{},
  }) : diagnostics = Map.unmodifiable(diagnostics);

  /// Whether the selected route was passthrough remux.
  bool get isPassthrough =>
      routeMode == VGEditorExportRouteMode.passthroughRemux;

  /// Whether the selected route was full render export.
  bool get isRender => routeMode == VGEditorExportRouteMode.renderExport;

  /// Whether the dispatch was blocked before any route executed.
  bool get isBlocked => routeMode == VGEditorExportRouteMode.blocked;

  /// Whether this report represents a fail-closed outcome.
  bool get isFailure => !success;

  /// Serialises this report to a JSON-compatible map.
  Map<String, Object?> toMap() => <String, Object?>{
    'success': success,
    'routeMode': routeMode.name,
    'reason': reason,
    'isPassthrough': isPassthrough,
    'isRender': isRender,
    'isBlocked': isBlocked,
    'isFailure': isFailure,
    'admissionReport': admissionReport.toMap(),
    if (passthroughReport != null)
      'passthroughReport': passthroughReport!.toMap(),
    if (renderResult != null) 'renderResult': renderResult!.toMap(),
    if (errorCode != null) 'errorCode': errorCode,
    if (errorMessage != null) 'errorMessage': errorMessage,
    'proofBoundary': proofBoundary,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGEditorAdmissionExportReport(success: $success, routeMode: ${routeMode.name}, reason: $reason, errorCode: $errorCode, errorMessage: $errorMessage, proofBoundary: $proofBoundary)';
}

/// Public admission-driven export dispatcher.
///
/// Evaluates the Unit AC [VGEditorExportAdmissionPlanner] first, then
/// dispatches to the Unit AE [VGPassthroughRemuxClient] or the Phase 10-C
/// [VanguardTimelineExporter] render path based on the admitted route --
/// never both, never a route the admission planner did not select.
final class VGEditorAdmissionExportClient {
  /// Optional injected admission probe, matching the Unit AC planner
  /// `evaluate` signature. Defaults to
  /// `const VGEditorExportAdmissionPlanner().evaluate`.
  final VGEditorAdmissionExportAdmissionProbe _admissionProbe;

  /// Optional injected passthrough executor, matching the Unit AE client
  /// `export` signature. Defaults to `VGPassthroughRemuxClient().export`.
  final VGEditorAdmissionExportPassthroughExecutor _passthroughExecutor;

  /// Optional injected render executor, matching
  /// [VanguardTimelineExporter.exportDraft] minus the MethodChannel
  /// parameter. Defaults to [VanguardTimelineExporter.exportDraft].
  final VGEditorAdmissionExportRenderExecutor _renderExecutor;

  VGEditorAdmissionExportClient({
    VGEditorAdmissionExportAdmissionProbe? admissionProbe,
    VGEditorAdmissionExportPassthroughExecutor? passthroughExecutor,
    VGEditorAdmissionExportRenderExecutor? renderExecutor,
  }) : _admissionProbe =
           admissionProbe ?? const VGEditorExportAdmissionPlanner().evaluate,
       _passthroughExecutor =
           passthroughExecutor ?? VGPassthroughRemuxClient().export,
       _renderExecutor = renderExecutor ?? VanguardTimelineExporter.exportDraft;

  /// Evaluates admission for [draft]/[request] and dispatches to the
  /// admitted export route.
  ///
  /// Never throws for expected blocked or execution-failure outcomes --
  /// those are returned as fail-closed reports. Only truly unexpected
  /// construction issues may throw.
  Future<VGEditorAdmissionExportReport> export({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
    void Function(double progress)? onProgress,
  }) async {
    final VGEditorExportAdmissionReport admissionReport;
    try {
      admissionReport = await _admissionProbe(draft: draft, request: request);
    } on PlatformException catch (e) {
      final minimalAdmissionReport = _createMinimalBlockedAdmissionReport(
        draft: draft,
        request: request,
      );
      return VGEditorAdmissionExportReport(
        success: false,
        routeMode: VGEditorExportRouteMode.blocked,
        reason: 'admission_probe_failed',
        admissionReport: minimalAdmissionReport,
        errorCode: e.code.isNotEmpty ? e.code : 'ADMISSION_PROBE_FAILED',
        errorMessage: e.message,
        proofBoundary: VGEditorAdmissionExportReport.expectedProofBoundary,
        diagnostics: <String, Object?>{
          'admissionReport': minimalAdmissionReport.toMap(),
          'errorDetails': e.details,
        },
      );
    } catch (e) {
      final minimalAdmissionReport = _createMinimalBlockedAdmissionReport(
        draft: draft,
        request: request,
      );
      return VGEditorAdmissionExportReport(
        success: false,
        routeMode: VGEditorExportRouteMode.blocked,
        reason: 'admission_probe_failed',
        admissionReport: minimalAdmissionReport,
        errorCode: 'ADMISSION_PROBE_FAILED',
        errorMessage: '$e',
        proofBoundary: VGEditorAdmissionExportReport.expectedProofBoundary,
        diagnostics: <String, Object?>{
          'admissionReport': minimalAdmissionReport.toMap(),
        },
      );
    }

    switch (admissionReport.routeMode) {
      case VGEditorExportRouteMode.blocked:
        return VGEditorAdmissionExportReport(
          success: false,
          routeMode: VGEditorExportRouteMode.blocked,
          reason: 'admission_blocked:${admissionReport.reason}',
          admissionReport: admissionReport,
          diagnostics: <String, Object?>{
            'admissionReport': admissionReport.toMap(),
          },
        );

      case VGEditorExportRouteMode.passthroughRemux:
        return _dispatchPassthrough(
          draft: draft,
          request: request,
          admissionReport: admissionReport,
        );

      case VGEditorExportRouteMode.renderExport:
        return _dispatchRender(
          draft: draft,
          request: request,
          onProgress: onProgress,
          admissionReport: admissionReport,
        );
    }
  }

  static VGEditorExportAdmissionReport _createMinimalBlockedAdmissionReport({
    required VGEditorDraft draft,
    required VGEditorExportRequest request,
  }) {
    final fallbackReadiness = const VGEditorExportReadinessEvaluator().evaluate(
      draft: draft,
      request: request,
    );
    return VGEditorExportAdmissionReport(
      routeMode: VGEditorExportRouteMode.blocked,
      reason: 'admission_probe_failed',
      exportReadinessReport: fallbackReadiness,
      passthroughDecisionAttempted: false,
      proofBoundary: VGEditorExportAdmissionReport.expectedProofBoundary,
      nonClaims: VGEditorExportAdmissionReport.standardNonClaims,
    );
  }

  Future<VGEditorAdmissionExportReport> _dispatchPassthrough({
    required VGEditorDraft draft,
    required VGEditorExportRequest request,
    required VGEditorExportAdmissionReport admissionReport,
  }) async {
    final outputPath = request.outputPath?.trim();
    if (outputPath == null || outputPath.isEmpty) {
      return VGEditorAdmissionExportReport(
        success: false,
        routeMode: VGEditorExportRouteMode.passthroughRemux,
        reason: 'passthrough_output_path_required',
        admissionReport: admissionReport,
        errorCode: 'PASSTHROUGH_OUTPUT_PATH_REQUIRED',
        errorMessage:
            'request.outputPath must be a non-empty path for the passthrough remux route',
        diagnostics: <String, Object?>{
          'admissionReport': admissionReport.toMap(),
        },
      );
    }

    final VGPassthroughRemuxExecutionReport passthroughReport;
    try {
      passthroughReport = await _passthroughExecutor(
        VGPassthroughRemuxRequest(
          sourcePath: draft.clips.single.sourcePath,
          outputPath: outputPath,
        ),
      );
    } on PlatformException catch (e) {
      return VGEditorAdmissionExportReport(
        success: false,
        routeMode: VGEditorExportRouteMode.passthroughRemux,
        reason: 'passthrough_execution_failed',
        admissionReport: admissionReport,
        errorCode: e.code.isNotEmpty ? e.code : 'PASSTHROUGH_EXECUTION_FAILED',
        errorMessage: e.message,
        diagnostics: <String, Object?>{
          'admissionReport': admissionReport.toMap(),
          'errorDetails': e.details,
        },
      );
    } catch (e) {
      return VGEditorAdmissionExportReport(
        success: false,
        routeMode: VGEditorExportRouteMode.passthroughRemux,
        reason: 'passthrough_execution_failed',
        admissionReport: admissionReport,
        errorCode: 'PASSTHROUGH_EXECUTION_FAILED',
        errorMessage: '$e',
        diagnostics: <String, Object?>{
          'admissionReport': admissionReport.toMap(),
        },
      );
    }

    final admitted =
        passthroughReport.success &&
        passthroughReport.proofBoundaryMatches &&
        passthroughReport.diagnosticNonClaimsHold;

    return VGEditorAdmissionExportReport(
      success: admitted,
      routeMode: VGEditorExportRouteMode.passthroughRemux,
      reason: admitted
          ? 'passthrough_export_succeeded'
          : 'passthrough_execution_failed',
      admissionReport: admissionReport,
      passthroughReport: passthroughReport,
      errorCode: admitted
          ? null
          : (passthroughReport.errorCode ?? 'PASSTHROUGH_EXECUTION_FAILED'),
      errorMessage: admitted ? null : passthroughReport.errorMessage,
      diagnostics: <String, Object?>{
        'admissionReport': admissionReport.toMap(),
        'passthroughReport': passthroughReport.toMap(),
      },
    );
  }

  Future<VGEditorAdmissionExportReport> _dispatchRender({
    required VGEditorDraft draft,
    required VGEditorExportRequest request,
    required void Function(double progress)? onProgress,
    required VGEditorExportAdmissionReport admissionReport,
  }) async {
    final renderDraft = draft
        .flattenOriginalClipAudio()
        .applyAudioCompositionPolicy();

    try {
      final renderResult = await _renderExecutor(
        draft: renderDraft,
        request: request,
        onProgress: onProgress,
      );

      return VGEditorAdmissionExportReport(
        success: true,
        routeMode: VGEditorExportRouteMode.renderExport,
        reason: 'render_export_succeeded',
        admissionReport: admissionReport,
        renderResult: renderResult,
        diagnostics: <String, Object?>{
          'admissionReport': admissionReport.toMap(),
        },
      );
    } on PlatformException catch (e) {
      return VGEditorAdmissionExportReport(
        success: false,
        routeMode: VGEditorExportRouteMode.renderExport,
        reason: 'render_export_failed',
        admissionReport: admissionReport,
        errorCode: e.code.isNotEmpty ? e.code : 'RENDER_EXPORT_FAILED',
        errorMessage: e.message,
        diagnostics: <String, Object?>{
          'admissionReport': admissionReport.toMap(),
          'errorDetails': e.details,
        },
      );
    } catch (e) {
      return VGEditorAdmissionExportReport(
        success: false,
        routeMode: VGEditorExportRouteMode.renderExport,
        reason: 'render_export_failed',
        admissionReport: admissionReport,
        errorCode: 'RENDER_EXPORT_FAILED',
        errorMessage: '$e',
        diagnostics: <String, Object?>{
          'admissionReport': admissionReport.toMap(),
        },
      );
    }
  }

  /// Convenience static entry point: constructs a default-wired
  /// [VGEditorAdmissionExportClient] and dispatches [export] once.
  static Future<VGEditorAdmissionExportReport> exportDraft({
    required VGEditorDraft draft,
    VGEditorExportRequest request = const VGEditorExportRequest(),
    void Function(double progress)? onProgress,
    VGEditorAdmissionExportAdmissionProbe? admissionProbe,
    VGEditorAdmissionExportPassthroughExecutor? passthroughExecutor,
    VGEditorAdmissionExportRenderExecutor? renderExecutor,
  }) => VGEditorAdmissionExportClient(
    admissionProbe: admissionProbe,
    passthroughExecutor: passthroughExecutor,
    renderExecutor: renderExecutor,
  ).export(draft: draft, request: request, onProgress: onProgress);
}
