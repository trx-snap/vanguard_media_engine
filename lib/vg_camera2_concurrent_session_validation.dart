// vg_camera2_concurrent_session_validation.dart
// vanguard_media_engine — Phase 3-Unit F: Android Camera2 guarded concurrent
// SessionConfiguration validation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3UnitFConcurrentSessionValidation` MethodChannel route.
// Diagnostic/capability foundation only — no camera is opened, no capture
// session is created, and no permission is requested from this file.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_camera2_session_configuration_plan.dart';

/// Decision produced by the native Phase 3-Unit F concurrent
/// SessionConfiguration validator.
enum VGCamera2ConcurrentSessionValidationDecision {
  /// The device API level does not support the required guard/query surface.
  unsupportedApi,

  /// `Manifest.permission.CAMERA` was not granted; no query was attempted.
  permissionRequired,

  /// The supplied plan is not a concurrent-session candidate (fewer than 2
  /// selected/distinct camera ids); no query was attempted.
  notCandidate,

  /// `CameraManager.isConcurrentSessionConfigurationSupported` returned true.
  supported,

  /// `CameraManager.isConcurrentSessionConfigurationSupported` returned
  /// false.
  notSupported,

  /// The native validator threw while attempting the runtime query.
  validationFailed;

  /// Maps a raw native decision string to the matching enum value, falling
  /// back to [validationFailed] for unrecognised/missing values.
  static VGCamera2ConcurrentSessionValidationDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGCamera2ConcurrentSessionValidationDecision.validationFailed;
    }
    for (final value in VGCamera2ConcurrentSessionValidationDecision.values) {
      if (value.name == raw) return value;
    }
    return VGCamera2ConcurrentSessionValidationDecision.validationFailed;
  }
}

/// Typed report returned by
/// [VGCamera2ConcurrentSessionValidationReport.validateAndroidCamera2ConcurrentSessionConfiguration],
/// mirroring the native validator's result map.
@immutable
class VGCamera2ConcurrentSessionValidationReport {
  const VGCamera2ConcurrentSessionValidationReport({
    required this.success,
    required this.apiLevel,
    required this.hasCameraPermission,
    required this.attemptedRuntimeValidation,
    required this.supported,
    required this.decision,
    required this.reasons,
    required this.selectedConcurrentCameraIds,
    required this.surfacePlanCount,
    required this.diagnostics,
  });

  /// Whether the native validator completed without throwing.
  final bool success;

  /// `Build.VERSION.SDK_INT` on the validating device.
  final int apiLevel;

  /// Current `Manifest.permission.CAMERA` grant state — queried without
  /// prompting.
  final bool hasCameraPermission;

  /// Whether the native validator actually invoked
  /// `CameraManager.isConcurrentSessionConfigurationSupported`.
  final bool attemptedRuntimeValidation;

  /// The runtime-reported concurrent-session support result. Only meaningful
  /// when [attemptedRuntimeValidation] is true.
  final bool supported;

  /// The validation decision.
  final VGCamera2ConcurrentSessionValidationDecision decision;

  /// Human-readable reason codes explaining [decision].
  final List<String> reasons;

  /// Camera ids from the input plan that were considered for concurrent
  /// validation.
  final List<String> selectedConcurrentCameraIds;

  /// Number of surface plans present in the input plan.
  final int surfacePlanCount;

  /// Additional diagnostic key/value pairs (e.g. native error details).
  final Map<String, Object?> diagnostics;

  /// Whether [decision] is [VGCamera2ConcurrentSessionValidationDecision.permissionRequired].
  bool get isPermissionRequired =>
      decision ==
      VGCamera2ConcurrentSessionValidationDecision.permissionRequired;

  /// Whether the runtime query was attempted and reported support.
  bool get isRuntimeSupported =>
      attemptedRuntimeValidation &&
      decision == VGCamera2ConcurrentSessionValidationDecision.supported;

  /// Whether the runtime query was attempted and reported no support.
  bool get isRuntimeRejected =>
      attemptedRuntimeValidation &&
      decision == VGCamera2ConcurrentSessionValidationDecision.notSupported;

  /// Whether the native validator actually attempted the runtime query.
  bool get isRuntimeValidationAttempted => attemptedRuntimeValidation;

  /// Parses a report from the raw native map. Defensive against both
  /// `Map<Object?, Object?>` and `Map<String, Object?>` shapes, and against
  /// missing/malformed fields — unrecognised shapes fall back to
  /// [VGCamera2ConcurrentSessionValidationDecision.validationFailed] with the
  /// raw map preserved in [diagnostics].
  static VGCamera2ConcurrentSessionValidationReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGCamera2ConcurrentSessionValidationReport(
        success: false,
        apiLevel: 0,
        hasCameraPermission: false,
        attemptedRuntimeValidation: false,
        supported: false,
        decision: VGCamera2ConcurrentSessionValidationDecision.validationFailed,
        reasons: const <String>['native_result_not_a_map'],
        selectedConcurrentCameraIds: const <String>[],
        surfacePlanCount: 0,
        diagnostics: <String, Object?>{'raw': raw},
      );
    }

    final reasonsRaw = raw['reasons'];
    final reasons = reasonsRaw is List
        ? reasonsRaw
              .whereType<Object>()
              .map((e) => e.toString())
              .toList(growable: false)
        : const <String>[];

    final selectedIdsRaw = raw['selectedConcurrentCameraIds'];
    final selectedConcurrentCameraIds = selectedIdsRaw is List
        ? selectedIdsRaw
              .whereType<Object>()
              .map((e) => e.toString())
              .toList(growable: false)
        : const <String>[];

    final diagnosticsRaw = raw['diagnostics'];
    final diagnostics = diagnosticsRaw is Map
        ? Map<String, Object?>.from(diagnosticsRaw)
        : const <String, Object?>{};

    return VGCamera2ConcurrentSessionValidationReport(
      success: raw['success'] as bool? ?? false,
      apiLevel: (raw['apiLevel'] as num?)?.toInt() ?? 0,
      hasCameraPermission: raw['hasCameraPermission'] as bool? ?? false,
      attemptedRuntimeValidation:
          raw['attemptedRuntimeValidation'] as bool? ?? false,
      supported: raw['supported'] as bool? ?? false,
      decision: VGCamera2ConcurrentSessionValidationDecision.fromRaw(
        raw['decision'],
      ),
      reasons: reasons,
      selectedConcurrentCameraIds: selectedConcurrentCameraIds,
      surfacePlanCount: (raw['surfacePlanCount'] as num?)?.toInt() ?? 0,
      diagnostics: diagnostics,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'success': success,
      'apiLevel': apiLevel,
      'hasCameraPermission': hasCameraPermission,
      'attemptedRuntimeValidation': attemptedRuntimeValidation,
      'supported': supported,
      'decision': decision.name,
      'reasons': reasons,
      'selectedConcurrentCameraIds': selectedConcurrentCameraIds,
      'surfacePlanCount': surfacePlanCount,
      'diagnostics': diagnostics,
    };
  }

  static const String _method =
      'runAndroidDagPhase3UnitFConcurrentSessionValidation';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android-backed native guarded concurrent
  /// SessionConfiguration validator for [plan] and parses the result.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGCamera2ConcurrentSessionValidationReport>
  validateAndroidCamera2ConcurrentSessionConfiguration({
    required VGCamera2SessionConfigurationPlan plan,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final raw = await ch.invokeMethod<Object?>(_method, {'plan': plan.toMap()});
    return VGCamera2ConcurrentSessionValidationReport.fromMap(raw);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ConcurrentSessionValidationReport &&
        other.success == success &&
        other.apiLevel == apiLevel &&
        other.hasCameraPermission == hasCameraPermission &&
        other.attemptedRuntimeValidation == attemptedRuntimeValidation &&
        other.supported == supported &&
        other.decision == decision &&
        listEquals(other.reasons, reasons) &&
        listEquals(
          other.selectedConcurrentCameraIds,
          selectedConcurrentCameraIds,
        ) &&
        other.surfacePlanCount == surfacePlanCount &&
        mapEquals(other.diagnostics, diagnostics);
  }

  @override
  int get hashCode => Object.hash(
    success,
    apiLevel,
    hasCameraPermission,
    attemptedRuntimeValidation,
    supported,
    decision,
    Object.hashAll(reasons),
    Object.hashAll(selectedConcurrentCameraIds),
    surfacePlanCount,
    _stableDiagnosticsHash(diagnostics),
  );

  static int _stableDiagnosticsHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGCamera2ConcurrentSessionValidationReport('
      'success: $success, '
      'apiLevel: $apiLevel, '
      'hasCameraPermission: $hasCameraPermission, '
      'attemptedRuntimeValidation: $attemptedRuntimeValidation, '
      'supported: $supported, '
      'decision: $decision, '
      'reasons: $reasons, '
      'selectedConcurrentCameraIds: $selectedConcurrentCameraIds, '
      'surfacePlanCount: $surfacePlanCount, '
      'diagnostics: $diagnostics)';
}
