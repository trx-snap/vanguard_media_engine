// vg_dual_camera_capability_policy.dart
// vanguard_media_engine - P3-CAM-DUET-CAPABILITY-POLICY: Production Dual Camera/Duet
// capability gating and unsupported-device synthetic diagnostic continuation policy.
//
// Synchronous policy planning is pure Dart (evaluating camera hardware
// capability, Camera2 readiness, session configuration plan, and runtime
// concurrent validation reports to determine admission without native calls).
// The asynchronous capability evaluator uses existing probe and validation
// MethodChannel routes to query hardware capabilities and validate concurrent
// configurations; it never opens cameras directly or allocates camera capture
// pipelines.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_camera_hardware_capability_report.dart';
import 'vg_camera2_concurrent_session_validation.dart';
import 'vg_camera2_readiness_plan.dart';
import 'vg_camera2_session_configuration_plan.dart';

/// Decision produced by [VGDuetDualCameraCapabilityPlanner.evaluate].
enum VGDuetDualCameraCapabilityDecision {
  /// Camera usage is blocked (e.g. no cameras or severe thermal state).
  blocked,

  /// Verified production real dual-camera session is supported.
  productionRealDualCamera,

  /// Single-camera fallback for production; real dual camera is hidden/disabled.
  productionHiddenSingleCameraFallback,

  /// Diagnostic-only synthetic secondary development mode on unsupported hardware;
  /// physical dual camera is false and feature is hidden from production.
  diagnosticSyntheticSingleCamera,
}

/// Immutable policy result governing production Dual Camera/Duet gating
/// and unsupported-device synthetic diagnostic continuation.
@immutable
class VGDuetDualCameraCapabilityPolicy {
  const VGDuetDualCameraCapabilityPolicy({
    required this.decision,
    required this.reasons,
    required this.diagnostics,
    required this.isProductionVisible,
    required this.isProductionRealDualCamera,
    required this.isDiagnosticSyntheticMode,
    required this.isPhysicalDualCamera,
    this.selectedPrimaryCameraId,
    this.selectedSecondaryCameraId,
  });

  /// The high-level capability decision.
  final VGDuetDualCameraCapabilityDecision decision;

  /// Human-readable explanation and policy codes.
  final List<String> reasons;

  /// Diagnostic map recording capability, readiness, session, and validation context.
  final Map<String, Object?> diagnostics;

  /// Whether the dual-camera capture UI/feature is visible in production.
  final bool isProductionVisible;

  /// Whether genuine dual-camera hardware capture is active in production.
  final bool isProductionRealDualCamera;

  /// Whether the session is operating in synthetic single-camera diagnostic mode.
  final bool isDiagnosticSyntheticMode;

  /// Whether verified physical dual-camera capture is supported by hardware/OS.
  final bool isPhysicalDualCamera;

  /// Camera ID selected as the primary capture device, or `null`.
  final String? selectedPrimaryCameraId;

  /// Camera ID selected as the secondary capture device, or `null`.
  final String? selectedSecondaryCameraId;

  /// Convenience getter for blocked state.
  bool get isBlocked => decision == VGDuetDualCameraCapabilityDecision.blocked;

  /// Convenience getter for production hidden single-camera fallback.
  bool get isProductionHiddenSingleCameraFallback =>
      decision ==
      VGDuetDualCameraCapabilityDecision.productionHiddenSingleCameraFallback;

  /// Serializes this policy to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'decision': decision.name,
      'reasons': reasons,
      'diagnostics': diagnostics,
      'isProductionVisible': isProductionVisible,
      'isProductionRealDualCamera': isProductionRealDualCamera,
      'isDiagnosticSyntheticMode': isDiagnosticSyntheticMode,
      'isPhysicalDualCamera': isPhysicalDualCamera,
      'selectedPrimaryCameraId': selectedPrimaryCameraId,
      'selectedSecondaryCameraId': selectedSecondaryCameraId,
    };
  }

  /// Deserializes a policy from a raw map, returning `null` if invalid.
  static VGDuetDualCameraCapabilityPolicy? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final decisionRaw = raw['decision'] as String?;
    VGDuetDualCameraCapabilityDecision? decision;
    for (final v in VGDuetDualCameraCapabilityDecision.values) {
      if (v.name == decisionRaw) {
        decision = v;
        break;
      }
    }
    if (decision == null) return null;

    final reasonsRaw = raw['reasons'];
    final reasons = reasonsRaw is List
        ? reasonsRaw
              .whereType<Object>()
              .map((e) => e.toString())
              .toList(growable: false)
        : const <String>[];

    final diagnosticsRaw = raw['diagnostics'];
    final diagnostics = diagnosticsRaw is Map
        ? Map<String, Object?>.from(diagnosticsRaw)
        : const <String, Object?>{};

    return VGDuetDualCameraCapabilityPolicy(
      decision: decision,
      reasons: reasons,
      diagnostics: diagnostics,
      isProductionVisible: raw['isProductionVisible'] as bool? ?? false,
      isProductionRealDualCamera:
          raw['isProductionRealDualCamera'] as bool? ?? false,
      isDiagnosticSyntheticMode:
          raw['isDiagnosticSyntheticMode'] as bool? ?? false,
      isPhysicalDualCamera: raw['isPhysicalDualCamera'] as bool? ?? false,
      selectedPrimaryCameraId: raw['selectedPrimaryCameraId'] as String?,
      selectedSecondaryCameraId: raw['selectedSecondaryCameraId'] as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGDuetDualCameraCapabilityPolicy &&
        other.decision == decision &&
        listEquals(other.reasons, reasons) &&
        mapEquals(other.diagnostics, diagnostics) &&
        other.isProductionVisible == isProductionVisible &&
        other.isProductionRealDualCamera == isProductionRealDualCamera &&
        other.isDiagnosticSyntheticMode == isDiagnosticSyntheticMode &&
        other.isPhysicalDualCamera == isPhysicalDualCamera &&
        other.selectedPrimaryCameraId == selectedPrimaryCameraId &&
        other.selectedSecondaryCameraId == selectedSecondaryCameraId;
  }

  @override
  int get hashCode => Object.hash(
    decision,
    Object.hashAll(reasons),
    _stableDiagnosticsHash(diagnostics),
    isProductionVisible,
    isProductionRealDualCamera,
    isDiagnosticSyntheticMode,
    isPhysicalDualCamera,
    selectedPrimaryCameraId,
    selectedSecondaryCameraId,
  );

  static int _stableDiagnosticsHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGDuetDualCameraCapabilityPolicy('
      'decision: $decision, '
      'reasons: $reasons, '
      'diagnostics: $diagnostics, '
      'isProductionVisible: $isProductionVisible, '
      'isProductionRealDualCamera: $isProductionRealDualCamera, '
      'isDiagnosticSyntheticMode: $isDiagnosticSyntheticMode, '
      'isPhysicalDualCamera: $isPhysicalDualCamera, '
      'selectedPrimaryCameraId: $selectedPrimaryCameraId, '
      'selectedSecondaryCameraId: $selectedSecondaryCameraId)';
}

/// Pure Dart planner that evaluates Camera2 readiness, session plan,
/// and runtime validation report into a deterministic [VGDuetDualCameraCapabilityPolicy].
final class VGDuetDualCameraCapabilityPlanner {
  const VGDuetDualCameraCapabilityPlanner();

  /// Evaluates camera hardware, readiness, session plan, and optional runtime
  /// validation to produce a fail-closed production policy or diagnostic continuation.
  VGDuetDualCameraCapabilityPolicy evaluate({
    required VGCameraHardwareCapabilityReport report,
    VGCamera2ReadinessPlan? readinessPlan,
    VGCamera2SessionConfigurationPlan? sessionConfigurationPlan,
    VGCamera2ConcurrentSessionValidationReport? runtimeValidationReport,
    bool allowDiagnosticSyntheticMode = false,
  }) {
    final readiness =
        readinessPlan ?? const VGCamera2ReadinessPlanner().evaluate(report);
    final sessionPlan =
        sessionConfigurationPlan ??
        const VGCamera2SessionConfigurationPlanner().evaluate(
          report: report,
          readinessPlan: readiness,
        );

    final selectedPrimaryId =
        readiness.selectedPrimaryCameraId ??
        (report.cameras.isNotEmpty ? report.cameras.first.cameraId : null);
    final selectedSecondaryId = readiness.selectedSecondaryCameraId;

    final reasons = <String>[];
    void addReason(String r) {
      if (!reasons.contains(r)) {
        reasons.add(r);
      }
    }

    for (final r in readiness.reasons) {
      addReason(r);
    }
    for (final r in sessionPlan.reasons) {
      addReason(r);
    }
    if (runtimeValidationReport != null) {
      for (final r in runtimeValidationReport.reasons) {
        addReason(r);
      }
    }

    final bool? runtimeValidationCameraIdsMatch;
    if (runtimeValidationReport != null) {
      final reportIds = runtimeValidationReport.selectedConcurrentCameraIds;
      final planIds = sessionPlan.selectedConcurrentCameraIds;
      final reportSet = reportIds.toSet();
      final planSet = planIds.toSet();
      runtimeValidationCameraIdsMatch =
          reportIds.length == planIds.length &&
          reportSet.length == reportIds.length &&
          setEquals(reportSet, planSet);
    } else {
      runtimeValidationCameraIdsMatch = null;
    }

    final diagnostics = <String, Object?>{
      'cameraCount': report.cameraCount,
      'supportsConcurrentCamera': report.supportsConcurrentCamera,
      'readinessDecision': readiness.decision.name,
      'sessionConfigurationDecision': sessionPlan.decision.name,
      if (runtimeValidationReport != null) ...<String, Object?>{
        'runtimeValidationDecision': runtimeValidationReport.decision.name,
        'runtimeValidationCameraIdsMatch': runtimeValidationCameraIdsMatch,
      },
      'requiresRuntimeSessionValidation':
          sessionPlan.requiresRuntimeSessionValidation,
      'hasCameraPermission': report.hasCameraPermission,
      'selectedPrimaryCameraId': selectedPrimaryId,
      'selectedSecondaryCameraId': selectedSecondaryId,
      'primaryCameraId': selectedPrimaryId,
      'secondaryCameraId': selectedSecondaryId,
    };

    // 1. If readiness is blocked or session plan is blocked:
    // decision=blocked, production visible false, physical dual false, diagnostic false;
    // preserve readiness/session reasons.
    if (readiness.isBlocked || sessionPlan.isBlocked) {
      return VGDuetDualCameraCapabilityPolicy(
        decision: VGDuetDualCameraCapabilityDecision.blocked,
        reasons: reasons,
        diagnostics: diagnostics,
        isProductionVisible: false,
        isProductionRealDualCamera: false,
        isDiagnosticSyntheticMode: false,
        isPhysicalDualCamera: false,
        selectedPrimaryCameraId: selectedPrimaryId,
        selectedSecondaryCameraId: selectedSecondaryId,
      );
    }

    // 2. If runtimeValidationReport?.isRuntimeSupported == true AND
    // runtimeValidationCameraIdsMatch == true AND
    // sessionConfigurationPlan.isConcurrentValidationCandidate:
    // decision=productionRealDualCamera, production visible true,
    // production real true, physical dual true, diagnostic false.
    // If runtime supported is true but IDs mismatch: do not expose production,
    // add runtime_validation_camera_ids_mismatch, and fallback.
    if (runtimeValidationReport?.isRuntimeSupported == true) {
      if (runtimeValidationCameraIdsMatch == true &&
          sessionPlan.isConcurrentValidationCandidate) {
        return VGDuetDualCameraCapabilityPolicy(
          decision: VGDuetDualCameraCapabilityDecision.productionRealDualCamera,
          reasons: reasons,
          diagnostics: diagnostics,
          isProductionVisible: true,
          isProductionRealDualCamera: true,
          isDiagnosticSyntheticMode: false,
          isPhysicalDualCamera: true,
          selectedPrimaryCameraId: selectedPrimaryId,
          selectedSecondaryCameraId: selectedSecondaryId,
        );
      }
      if (runtimeValidationCameraIdsMatch == false) {
        addReason('runtime_validation_camera_ids_mismatch');
      }
    }

    // 3. If sessionConfigurationPlan.isConcurrentValidationCandidate but
    // runtimeValidationReport is null: do NOT mark production visible.
    // decision=productionHiddenSingleCameraFallback, reason include
    // runtime_validation_required, physical dual false. This avoids presenting
    // a not-yet-validated dual feature.
    if (sessionPlan.isConcurrentValidationCandidate &&
        runtimeValidationReport == null) {
      addReason('runtime_validation_required');
      return VGDuetDualCameraCapabilityPolicy(
        decision: VGDuetDualCameraCapabilityDecision
            .productionHiddenSingleCameraFallback,
        reasons: reasons,
        diagnostics: diagnostics,
        isProductionVisible: false,
        isProductionRealDualCamera: false,
        isDiagnosticSyntheticMode: false,
        isPhysicalDualCamera: false,
        selectedPrimaryCameraId: selectedPrimaryId,
        selectedSecondaryCameraId: selectedSecondaryId,
      );
    }

    // 4. If runtimeValidationReport indicates notSupported or notCandidate,
    // or session plan is single fallback: production hidden single fallback
    // unless allowDiagnosticSyntheticMode is true and primary camera exists.
    // Then decision=diagnosticSyntheticSingleCamera, production visible false,
    // diagnostic true, physical dual false, reason include
    // diagnostic_synthetic_single_camera_enabled and
    // no_concurrent_camera_combination/no_matching_concurrent_camera_set when present.
    // 5. If no primary camera exists, do not enable diagnostic mode.
    final primaryExists = selectedPrimaryId != null;
    if (allowDiagnosticSyntheticMode && primaryExists) {
      addReason('diagnostic_synthetic_single_camera_enabled');
      if (!report.supportsConcurrentCamera ||
          report.concurrentCameraIdSets.isEmpty) {
        if (!reasons.contains('no_matching_concurrent_camera_set') &&
            !reasons.contains('no_concurrent_camera_combination')) {
          addReason('no_concurrent_camera_combination');
        }
      }
      return VGDuetDualCameraCapabilityPolicy(
        decision:
            VGDuetDualCameraCapabilityDecision.diagnosticSyntheticSingleCamera,
        reasons: reasons,
        diagnostics: diagnostics,
        isProductionVisible: false,
        isProductionRealDualCamera: false,
        isDiagnosticSyntheticMode: true,
        isPhysicalDualCamera: false,
        selectedPrimaryCameraId: selectedPrimaryId,
        selectedSecondaryCameraId: selectedSecondaryId,
      );
    }

    // Default production hidden single fallback.
    return VGDuetDualCameraCapabilityPolicy(
      decision: VGDuetDualCameraCapabilityDecision
          .productionHiddenSingleCameraFallback,
      reasons: reasons,
      diagnostics: diagnostics,
      isProductionVisible: false,
      isProductionRealDualCamera: false,
      isDiagnosticSyntheticMode: false,
      isPhysicalDualCamera: false,
      selectedPrimaryCameraId: selectedPrimaryId,
      selectedSecondaryCameraId: selectedSecondaryId,
    );
  }
}

/// Async orchestrator that probes Android Camera2 hardware capabilities,
/// evaluates readiness and session plans, performs guarded runtime validation
/// when eligible, and evaluates the final deterministic [VGDuetDualCameraCapabilityPolicy].
class VGDuetDualCameraCapabilityEvaluator {
  const VGDuetDualCameraCapabilityEvaluator({
    this.readinessPlanner = const VGCamera2ReadinessPlanner(),
    this.sessionConfigurationPlanner =
        const VGCamera2SessionConfigurationPlanner(),
    this.policyPlanner = const VGDuetDualCameraCapabilityPlanner(),
  });

  final VGCamera2ReadinessPlanner readinessPlanner;
  final VGCamera2SessionConfigurationPlanner sessionConfigurationPlanner;
  final VGDuetDualCameraCapabilityPlanner policyPlanner;

  /// Evaluates device hardware, Camera2 readiness, session plan, and optional
  /// runtime concurrent session validation to determine the production and
  /// diagnostic capability policy.
  ///
  /// Fails closed on [PlatformException] or generic runtime failure, never
  /// throwing and never exposing real dual camera without runtime validation.
  Future<VGDuetDualCameraCapabilityPolicy> evaluateDevicePolicy({
    bool allowDiagnosticSyntheticMode = false,
    MethodChannel? channel,
  }) async {
    final VGCameraHardwareCapabilityReport report;
    try {
      report =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities(
            channel: channel,
          );
    } on PlatformException catch (e) {
      return VGDuetDualCameraCapabilityPolicy(
        decision: VGDuetDualCameraCapabilityDecision.blocked,
        reasons: <String>['probe_failed:${e.code}'],
        diagnostics: <String, Object?>{
          'stage': 'probe',
          'error': e.toString(),
          'errorCode': e.code,
          'errorMessage': e.message,
          'errorDetails': e.details,
        },
        isProductionVisible: false,
        isProductionRealDualCamera: false,
        isDiagnosticSyntheticMode: false,
        isPhysicalDualCamera: false,
      );
    } catch (e) {
      return VGDuetDualCameraCapabilityPolicy(
        decision: VGDuetDualCameraCapabilityDecision.blocked,
        reasons: const <String>['probe_failed:error'],
        diagnostics: <String, Object?>{'stage': 'probe', 'error': e.toString()},
        isProductionVisible: false,
        isProductionRealDualCamera: false,
        isDiagnosticSyntheticMode: false,
        isPhysicalDualCamera: false,
      );
    }

    try {
      final readiness = readinessPlanner.evaluate(report);
      final sessionPlan = sessionConfigurationPlanner.evaluate(
        report: report,
        readinessPlan: readiness,
      );

      VGCamera2ConcurrentSessionValidationReport? validationReport;
      if (sessionPlan.isConcurrentValidationCandidate &&
          report.hasCameraPermission) {
        try {
          validationReport =
              await VGCamera2ConcurrentSessionValidationReport.validateAndroidCamera2ConcurrentSessionConfiguration(
                plan: sessionPlan,
                channel: channel,
              );
        } on PlatformException catch (e) {
          final reasons = <String>[];
          void addReason(String r) {
            if (!reasons.contains(r)) reasons.add(r);
          }

          for (final r in readiness.reasons) {
            addReason(r);
          }
          for (final r in sessionPlan.reasons) {
            addReason(r);
          }
          addReason('runtime_validation_failed:${e.code}');

          final selectedPrimaryId =
              readiness.selectedPrimaryCameraId ??
              (report.cameras.isNotEmpty
                  ? report.cameras.first.cameraId
                  : null);
          final selectedSecondaryId = readiness.selectedSecondaryCameraId;

          return VGDuetDualCameraCapabilityPolicy(
            decision: VGDuetDualCameraCapabilityDecision
                .productionHiddenSingleCameraFallback,
            reasons: reasons,
            diagnostics: <String, Object?>{
              'stage': 'runtime_validation',
              'cameraCount': report.cameraCount,
              'supportsConcurrentCamera': report.supportsConcurrentCamera,
              'readinessDecision': readiness.decision.name,
              'sessionConfigurationDecision': sessionPlan.decision.name,
              'requiresRuntimeSessionValidation':
                  sessionPlan.requiresRuntimeSessionValidation,
              'hasCameraPermission': report.hasCameraPermission,
              'selectedPrimaryCameraId': selectedPrimaryId,
              'selectedSecondaryCameraId': selectedSecondaryId,
              'primaryCameraId': selectedPrimaryId,
              'secondaryCameraId': selectedSecondaryId,
              'error': e.toString(),
              'errorCode': e.code,
              'errorMessage': e.message,
              'errorDetails': e.details,
            },
            isProductionVisible: false,
            isProductionRealDualCamera: false,
            isDiagnosticSyntheticMode: false,
            isPhysicalDualCamera: false,
            selectedPrimaryCameraId: selectedPrimaryId,
            selectedSecondaryCameraId: selectedSecondaryId,
          );
        } catch (e) {
          final reasons = <String>[];
          void addReason(String r) {
            if (!reasons.contains(r)) reasons.add(r);
          }

          for (final r in readiness.reasons) {
            addReason(r);
          }
          for (final r in sessionPlan.reasons) {
            addReason(r);
          }
          addReason('runtime_validation_failed:error');

          final selectedPrimaryId =
              readiness.selectedPrimaryCameraId ??
              (report.cameras.isNotEmpty
                  ? report.cameras.first.cameraId
                  : null);
          final selectedSecondaryId = readiness.selectedSecondaryCameraId;

          return VGDuetDualCameraCapabilityPolicy(
            decision: VGDuetDualCameraCapabilityDecision
                .productionHiddenSingleCameraFallback,
            reasons: reasons,
            diagnostics: <String, Object?>{
              'stage': 'runtime_validation',
              'cameraCount': report.cameraCount,
              'supportsConcurrentCamera': report.supportsConcurrentCamera,
              'readinessDecision': readiness.decision.name,
              'sessionConfigurationDecision': sessionPlan.decision.name,
              'requiresRuntimeSessionValidation':
                  sessionPlan.requiresRuntimeSessionValidation,
              'hasCameraPermission': report.hasCameraPermission,
              'selectedPrimaryCameraId': selectedPrimaryId,
              'selectedSecondaryCameraId': selectedSecondaryId,
              'primaryCameraId': selectedPrimaryId,
              'secondaryCameraId': selectedSecondaryId,
              'error': e.toString(),
            },
            isProductionVisible: false,
            isProductionRealDualCamera: false,
            isDiagnosticSyntheticMode: false,
            isPhysicalDualCamera: false,
            selectedPrimaryCameraId: selectedPrimaryId,
            selectedSecondaryCameraId: selectedSecondaryId,
          );
        }
      }

      return policyPlanner.evaluate(
        report: report,
        readinessPlan: readiness,
        sessionConfigurationPlan: sessionPlan,
        runtimeValidationReport: validationReport,
        allowDiagnosticSyntheticMode: allowDiagnosticSyntheticMode,
      );
    } catch (e) {
      return VGDuetDualCameraCapabilityPolicy(
        decision: VGDuetDualCameraCapabilityDecision.blocked,
        reasons: const <String>['evaluator_failed:error'],
        diagnostics: <String, Object?>{
          'stage': 'evaluator',
          'error': e.toString(),
        },
        isProductionVisible: false,
        isProductionRealDualCamera: false,
        isDiagnosticSyntheticMode: false,
        isPhysicalDualCamera: false,
      );
    }
  }
}
