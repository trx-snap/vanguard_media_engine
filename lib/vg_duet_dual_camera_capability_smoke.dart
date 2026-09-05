// vg_duet_dual_camera_capability_smoke.dart
// vanguard_media_engine - P3-CAM-DUET-CAPABILITY-ADMISSION-ROUTE: Duet/Dual Camera
// Capability Admission Route & Physical Smoke Contract.
//
// Pure Dart typed report and runner for Duet/Dual Camera capability gating.
// Calls VGDuetDualCameraCapabilityEvaluator twice (production mode false and
// diagnostic mode true) to verify capability admission, fail-closed isolation,
// and honest diagnostic continuation without camera open, capture, or render.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_dual_camera_capability_policy.dart';

/// Proof boundary identifier for the Duet capability admission route smoke.
const String kDuetDualCameraCapabilityAdmissionProofBoundary =
    'duet_dual_camera_capability_admission_policy_derived_no_real_concurrent_hardware_proof_no_camera_open_no_render';

/// Physical smoke PASS marker token.
const String kDuetDualCameraCapabilityAdmissionPassMarker =
    'ANDROID_DAG_PHASE3_DUET_CAPABILITY_ADMISSION_PHYSICAL_SMOKE_PASS';

/// Physical smoke FAIL marker token.
const String kDuetDualCameraCapabilityAdmissionFailMarker =
    'ANDROID_DAG_PHASE3_DUET_CAPABILITY_ADMISSION_PHYSICAL_SMOKE_FAIL';

/// Physical smoke START marker token.
const String kDuetDualCameraCapabilityAdmissionStartMarker =
    'ANDROID_DAG_PHASE3_DUET_CAPABILITY_ADMISSION_PHYSICAL_SMOKE_START';

/// Immutable typed smoke report produced by [VGDuetDualCameraCapabilitySmokeRunner].
@immutable
class VGDuetDualCameraCapabilitySmokeReport {
  const VGDuetDualCameraCapabilitySmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.passMarker,
    required this.failMarker,
    required this.productionPolicy,
    required this.diagnosticPolicy,
    required this.reasons,
    required this.diagnostics,
  });

  /// Whether the capability admission smoke passed all verification lanes.
  final bool pass;

  /// Proof boundary string documenting that this smoke verifies derived capability
  /// policy without opening cameras or allocating render pipelines.
  final String proofBoundary;

  /// String marker emitted upon smoke pass.
  final String passMarker;

  /// String marker emitted upon smoke failure.
  final String failMarker;

  /// Evaluated policy for production capture ([allowDiagnosticSyntheticMode] = false).
  final VGDuetDualCameraCapabilityPolicy productionPolicy;

  /// Evaluated policy for diagnostic development ([allowDiagnosticSyntheticMode] = true).
  final VGDuetDualCameraCapabilityPolicy diagnosticPolicy;

  /// Structured reason codes explaining the verdict.
  final List<String> reasons;

  /// Additional diagnostics capturing hardware and policy evaluation state.
  final Map<String, Object?> diagnostics;

  /// Serializes this smoke report to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'proofBoundary': proofBoundary,
      'passMarker': passMarker,
      'failMarker': failMarker,
      'productionPolicy': productionPolicy.toMap(),
      'diagnosticPolicy': diagnosticPolicy.toMap(),
      'reasons': reasons,
      'diagnostics': diagnostics,
    };
  }

  /// Deserializes a smoke report from a raw map, returning `null` if invalid.
  static VGDuetDualCameraCapabilitySmokeReport? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final pass = raw['pass'] as bool? ?? false;
    final proofBoundary = raw['proofBoundary'] as String? ?? '';
    final passMarker = raw['passMarker'] as String? ?? '';
    final failMarker = raw['failMarker'] as String? ?? '';

    final prodRaw = raw['productionPolicy'];
    final diagRaw = raw['diagnosticPolicy'];
    final productionPolicy = VGDuetDualCameraCapabilityPolicy.fromMap(prodRaw);
    final diagnosticPolicy = VGDuetDualCameraCapabilityPolicy.fromMap(diagRaw);
    if (productionPolicy == null || diagnosticPolicy == null) return null;

    final reasonsRaw = raw['reasons'];
    final reasons = reasonsRaw is List
        ? reasonsRaw
              .whereType<Object>()
              .map((e) => e.toString())
              .toList(growable: false)
        : const <String>[];

    final diagMapRaw = raw['diagnostics'];
    final diagnostics = diagMapRaw is Map
        ? Map<String, Object?>.from(diagMapRaw)
        : const <String, Object?>{};

    return VGDuetDualCameraCapabilitySmokeReport(
      pass: pass,
      proofBoundary: proofBoundary,
      passMarker: passMarker,
      failMarker: failMarker,
      productionPolicy: productionPolicy,
      diagnosticPolicy: diagnosticPolicy,
      reasons: reasons,
      diagnostics: diagnostics,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGDuetDualCameraCapabilitySmokeReport &&
        other.pass == pass &&
        other.proofBoundary == proofBoundary &&
        other.passMarker == passMarker &&
        other.failMarker == failMarker &&
        other.productionPolicy == productionPolicy &&
        other.diagnosticPolicy == diagnosticPolicy &&
        listEquals(other.reasons, reasons) &&
        mapEquals(other.diagnostics, diagnostics);
  }

  @override
  int get hashCode => Object.hash(
    pass,
    proofBoundary,
    passMarker,
    failMarker,
    productionPolicy,
    diagnosticPolicy,
    Object.hashAll(reasons),
    _stableMapHash(diagnostics),
  );

  static int _stableMapHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGDuetDualCameraCapabilitySmokeReport(pass: $pass, proofBoundary: $proofBoundary, production: ${productionPolicy.decision.name}, diagnostic: ${diagnosticPolicy.decision.name})';
}

/// Pure Dart runner that executes the Duet / Dual Camera capability admission smoke.
class VGDuetDualCameraCapabilitySmokeRunner {
  const VGDuetDualCameraCapabilitySmokeRunner({
    this.evaluator = const VGDuetDualCameraCapabilityEvaluator(),
  });

  final VGDuetDualCameraCapabilityEvaluator evaluator;

  /// Runs the capability smoke check with an optional [channel] and returns a
  /// [VGDuetDualCameraCapabilitySmokeReport].
  Future<VGDuetDualCameraCapabilitySmokeReport> runSmoke({
    MethodChannel? channel,
  }) async {
    final productionPolicy = await evaluator.evaluateDevicePolicy(
      allowDiagnosticSyntheticMode: false,
      channel: channel,
    );
    final diagnosticPolicy = await evaluator.evaluateDevicePolicy(
      allowDiagnosticSyntheticMode: true,
      channel: channel,
    );

    final reasons = <String>[];
    var pass = true;

    void addFailure(String reason) {
      pass = false;
      if (!reasons.contains(reason)) {
        reasons.add(reason);
      }
    }

    final isRealSupported =
        productionPolicy.decision ==
        VGDuetDualCameraCapabilityDecision.productionRealDualCamera;

    if (isRealSupported) {
      // Real supported hardware route
      if (!productionPolicy.isProductionVisible) {
        addFailure('real_supported_production_not_visible');
      }
      if (!productionPolicy.isProductionRealDualCamera) {
        addFailure('real_supported_production_real_dual_false');
      }
      if (!productionPolicy.isPhysicalDualCamera) {
        addFailure('real_supported_physical_dual_false');
      }
      if (productionPolicy.selectedPrimaryCameraId == null ||
          productionPolicy.selectedSecondaryCameraId == null) {
        addFailure('real_supported_missing_selected_camera_ids');
      }
      if (productionPolicy.diagnostics['runtimeValidationCameraIdsMatch'] !=
          true) {
        addFailure('real_supported_runtime_validation_ids_mismatch');
      }
      // Diagnostic mode must NOT downgrade a real supported device
      if (diagnosticPolicy.decision !=
          VGDuetDualCameraCapabilityDecision.productionRealDualCamera) {
        addFailure('real_supported_downgraded_in_diagnostic_mode');
      }
      if (!diagnosticPolicy.isPhysicalDualCamera) {
        addFailure('diagnostic_physical_dual_false_on_supported_device');
      }
    } else {
      // Unsupported hardware route (e.g. SM-A566B)
      final isProductionHiddenFallback =
          productionPolicy.decision ==
              VGDuetDualCameraCapabilityDecision
                  .productionHiddenSingleCameraFallback ||
          productionPolicy.decision ==
              VGDuetDualCameraCapabilityDecision.blocked;

      if (!isProductionHiddenFallback) {
        addFailure('unsupported_unexpected_production_decision');
      }
      if (productionPolicy.isProductionVisible) {
        addFailure('unsupported_production_visible_true');
      }
      if (productionPolicy.isProductionRealDualCamera) {
        addFailure('unsupported_production_real_dual_true');
      }
      if (productionPolicy.isPhysicalDualCamera) {
        addFailure('unsupported_physical_dual_true');
      }

      final hasPrimary = productionPolicy.selectedPrimaryCameraId != null;
      if (hasPrimary) {
        if (diagnosticPolicy.decision !=
            VGDuetDualCameraCapabilityDecision
                .diagnosticSyntheticSingleCamera) {
          addFailure('unsupported_diagnostic_not_synthetic');
        }
        if (!diagnosticPolicy.isDiagnosticSyntheticMode) {
          addFailure('unsupported_diagnostic_flag_false');
        }
        if (diagnosticPolicy.isPhysicalDualCamera) {
          addFailure('unsupported_diagnostic_physical_dual_true');
        }
        if (diagnosticPolicy.isProductionVisible) {
          addFailure('unsupported_diagnostic_production_visible_true');
        }
        if (diagnosticPolicy.isProductionRealDualCamera) {
          addFailure('unsupported_diagnostic_production_real_dual_true');
        }
      } else {
        if (diagnosticPolicy.decision !=
            VGDuetDualCameraCapabilityDecision.blocked) {
          addFailure('no_primary_diagnostic_not_blocked');
        }
        if (diagnosticPolicy.isDiagnosticSyntheticMode) {
          addFailure('no_primary_diagnostic_mode_true');
        }
        if (diagnosticPolicy.isPhysicalDualCamera) {
          addFailure('no_primary_physical_dual_true');
        }
      }
    }

    // Diagnostics honesty check: supportsConcurrentCamera is recorded
    if (!productionPolicy.diagnostics.containsKey('supportsConcurrentCamera')) {
      addFailure('diagnostics_missing_supportsConcurrentCamera');
    }

    if (pass) {
      reasons.add(
        isRealSupported
            ? 'duet_real_concurrent_hardware_validated_pass'
            : 'duet_unsupported_hardware_fail_closed_pass',
      );
    }

    final smokeDiagnostics = <String, Object?>{
      'proofBoundary': kDuetDualCameraCapabilityAdmissionProofBoundary,
      'isRealSupported': isRealSupported,
      'supportsConcurrentCamera':
          productionPolicy.diagnostics['supportsConcurrentCamera'],
      'cameraCount': productionPolicy.diagnostics['cameraCount'],
      'selectedPrimaryCameraId': productionPolicy.selectedPrimaryCameraId,
      'selectedSecondaryCameraId': productionPolicy.selectedSecondaryCameraId,
      'productionDecision': productionPolicy.decision.name,
      'diagnosticDecision': diagnosticPolicy.decision.name,
      'productionReasons': productionPolicy.reasons,
      'diagnosticReasons': diagnosticPolicy.reasons,
      'productionDiagnostics': productionPolicy.diagnostics,
      'diagnosticDiagnostics': diagnosticPolicy.diagnostics,
    };

    return VGDuetDualCameraCapabilitySmokeReport(
      pass: pass,
      proofBoundary: kDuetDualCameraCapabilityAdmissionProofBoundary,
      passMarker: kDuetDualCameraCapabilityAdmissionPassMarker,
      failMarker: kDuetDualCameraCapabilityAdmissionFailMarker,
      productionPolicy: productionPolicy,
      diagnosticPolicy: diagnosticPolicy,
      reasons: reasons,
      diagnostics: smokeDiagnostics,
    );
  }

  /// Convenience static runner method.
  static Future<VGDuetDualCameraCapabilitySmokeReport> run({
    MethodChannel? channel,
    VGDuetDualCameraCapabilityEvaluator? evaluator,
  }) {
    final runner = evaluator != null
        ? VGDuetDualCameraCapabilitySmokeRunner(evaluator: evaluator)
        : const VGDuetDualCameraCapabilitySmokeRunner();
    return runner.runSmoke(channel: channel);
  }
}
