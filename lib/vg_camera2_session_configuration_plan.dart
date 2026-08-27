// vg_camera2_session_configuration_plan.dart
// vanguard_media_engine — Phase 3-Unit E: Android Camera2 Session Configuration
// Eligibility Planner.
//
// Pure Dart advisory planner. Consumes Phase 3 Units A-D capability metadata
// and Unit C readiness plan to emit a deterministic future Camera2
// session-configuration attempt/fallback plan. No MethodChannel, no camera
// open, no permission request, and no native calls.

import 'package:flutter/foundation.dart';

import 'vg_camera_hardware_capability_report.dart';
import 'vg_camera2_readiness_plan.dart';

/// Decision produced by [VGCamera2SessionConfigurationPlanner.evaluate].
enum VGCamera2SessionConfigurationDecision {
  /// Session configuration is blocked (e.g. no cameras, severe thermal state,
  /// or no valid primary surfaces).
  blocked,

  /// Single-camera session configuration fallback.
  singleCameraFallback,

  /// Concurrent dual-camera session configuration candidate for runtime
  /// validation.
  concurrentValidationCandidate,
}

/// Role of a surface within a Camera2 session configuration plan.
enum VGCamera2SessionSurfaceRole { preview, videoRecord }

/// Advisory specification for a single Camera2 session output surface.
@immutable
class VGCamera2SessionSurfacePlan {
  const VGCamera2SessionSurfacePlan({
    required this.cameraId,
    required this.role,
    required this.formatName,
    required this.size,
    required this.streamUseCaseName,
  });

  final String cameraId;
  final VGCamera2SessionSurfaceRole role;
  final String formatName;
  final VGCameraSize size;
  final String streamUseCaseName;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'cameraId': cameraId,
      'role': role.name,
      'formatName': formatName,
      'size': size.toMap(),
      'streamUseCaseName': streamUseCaseName,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2SessionSurfacePlan &&
        other.cameraId == cameraId &&
        other.role == role &&
        other.formatName == formatName &&
        other.size == size &&
        other.streamUseCaseName == streamUseCaseName;
  }

  @override
  int get hashCode =>
      Object.hash(cameraId, role, formatName, size, streamUseCaseName);

  @override
  String toString() =>
      'VGCamera2SessionSurfacePlan('
      'cameraId: $cameraId, '
      'role: $role, '
      'formatName: $formatName, '
      'size: $size, '
      'streamUseCaseName: $streamUseCaseName)';
}

/// Deterministic advisory Camera2 session configuration plan.
@immutable
class VGCamera2SessionConfigurationPlan {
  const VGCamera2SessionConfigurationPlan({
    required this.decision,
    required this.reasons,
    required this.surfacePlans,
    required this.selectedConcurrentCameraIds,
    required this.requiresCameraPermission,
    required this.requiresRuntimeSessionValidation,
    required this.diagnostics,
  });

  final VGCamera2SessionConfigurationDecision decision;
  final List<String> reasons;
  final List<VGCamera2SessionSurfacePlan> surfacePlans;
  final List<String> selectedConcurrentCameraIds;
  final bool requiresCameraPermission;
  final bool requiresRuntimeSessionValidation;
  final Map<String, Object?> diagnostics;

  bool get isBlocked =>
      decision == VGCamera2SessionConfigurationDecision.blocked;

  bool get usesSingleCameraFallback =>
      decision == VGCamera2SessionConfigurationDecision.singleCameraFallback;

  bool get isConcurrentValidationCandidate =>
      decision ==
      VGCamera2SessionConfigurationDecision.concurrentValidationCandidate;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'decision': decision.name,
      'reasons': reasons,
      'surfacePlans': surfacePlans
          .map((s) => s.toMap())
          .toList(growable: false),
      'selectedConcurrentCameraIds': selectedConcurrentCameraIds,
      'requiresCameraPermission': requiresCameraPermission,
      'requiresRuntimeSessionValidation': requiresRuntimeSessionValidation,
      'diagnostics': diagnostics,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2SessionConfigurationPlan &&
        other.decision == decision &&
        listEquals(other.reasons, reasons) &&
        listEquals(other.surfacePlans, surfacePlans) &&
        listEquals(
          other.selectedConcurrentCameraIds,
          selectedConcurrentCameraIds,
        ) &&
        other.requiresCameraPermission == requiresCameraPermission &&
        other.requiresRuntimeSessionValidation ==
            requiresRuntimeSessionValidation &&
        mapEquals(other.diagnostics, diagnostics);
  }

  @override
  int get hashCode => Object.hash(
    decision,
    Object.hashAll(reasons),
    Object.hashAll(surfacePlans),
    Object.hashAll(selectedConcurrentCameraIds),
    requiresCameraPermission,
    requiresRuntimeSessionValidation,
    _stableDiagnosticsHash(diagnostics),
  );

  static int _stableDiagnosticsHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGCamera2SessionConfigurationPlan('
      'decision: $decision, '
      'reasons: $reasons, '
      'surfacePlans: $surfacePlans, '
      'selectedConcurrentCameraIds: $selectedConcurrentCameraIds, '
      'requiresCameraPermission: $requiresCameraPermission, '
      'requiresRuntimeSessionValidation: $requiresRuntimeSessionValidation, '
      'diagnostics: $diagnostics)';
}

/// Pure Dart advisory planner producing a deterministic Camera2 session
/// configuration attempt or fallback plan.
final class VGCamera2SessionConfigurationPlanner {
  const VGCamera2SessionConfigurationPlanner();

  VGCamera2SessionConfigurationPlan evaluate({
    required VGCameraHardwareCapabilityReport report,
    VGCamera2ReadinessPlan? readinessPlan,
  }) {
    final readiness =
        readinessPlan ?? const VGCamera2ReadinessPlanner().evaluate(report);

    var mandatoryConcurrentCombinationCount = 0;
    var mandatoryConcurrentStreamCount = 0;
    for (final camera in report.cameras) {
      mandatoryConcurrentCombinationCount +=
          camera.mandatoryConcurrentStreamCombinations.length;
      for (final combination in camera.mandatoryConcurrentStreamCombinations) {
        mandatoryConcurrentStreamCount += combination.streams.length;
      }
    }

    final reasons = List<String>.from(readiness.reasons);

    if (readiness.isBlocked) {
      return VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.blocked,
        reasons: reasons,
        surfacePlans: const <VGCamera2SessionSurfacePlan>[],
        selectedConcurrentCameraIds: const <String>[],
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{
          'cameraCount': report.cameraCount,
          'supportsConcurrentCamera': report.supportsConcurrentCamera,
          'hasCameraPermission': report.hasCameraPermission,
          'readinessDecision': readiness.decision.name,
          'primaryCameraId': readiness.selectedPrimaryCameraId,
          'secondaryCameraId': readiness.selectedSecondaryCameraId,
          'surfacePlanCount': 0,
          'mandatoryConcurrentCombinationCount':
              mandatoryConcurrentCombinationCount,
          'mandatoryConcurrentStreamCount': mandatoryConcurrentStreamCount,
        },
      );
    }

    final requiresPermission = !report.hasCameraPermission;
    if (requiresPermission && !reasons.contains('camera_permission_absent')) {
      reasons.add('camera_permission_absent');
    }

    final primary =
        _findCamera(report.cameras, readiness.selectedPrimaryCameraId) ??
        _selectPrimaryFallback(report.cameras);
    final secondary =
        _findCamera(report.cameras, readiness.selectedSecondaryCameraId) ??
        _selectSecondaryFallback(report.cameras, primary);

    final allSurfaces = <VGCamera2SessionSurfacePlan>[];

    final primaryPreviewSize =
        readiness.selectedPreviewSize ??
        (primary != null && primary.previewSizes.isNotEmpty
            ? primary.previewSizes.first
            : null);
    if (primary != null && primaryPreviewSize != null) {
      allSurfaces.add(
        VGCamera2SessionSurfacePlan(
          cameraId: primary.cameraId,
          role: VGCamera2SessionSurfaceRole.preview,
          formatName: 'PRIVATE',
          size: primaryPreviewSize,
          streamUseCaseName: 'PREVIEW',
        ),
      );
    } else {
      reasons.add('primary_preview_surface_missing');
    }

    final primaryVideoSize =
        readiness.selectedVideoSize ??
        (primary != null && primary.videoSizes.isNotEmpty
            ? primary.videoSizes.first
            : null);
    if (primary != null && primaryVideoSize != null) {
      allSurfaces.add(
        VGCamera2SessionSurfacePlan(
          cameraId: primary.cameraId,
          role: VGCamera2SessionSurfaceRole.videoRecord,
          formatName: 'PRIVATE',
          size: primaryVideoSize,
          streamUseCaseName: 'VIDEO_RECORD',
        ),
      );
    } else {
      reasons.add('primary_video_surface_missing');
    }

    if (readiness.isDualCameraCandidate) {
      if (secondary != null) {
        final secondaryPreviewSize = secondary.previewSizes.isNotEmpty
            ? secondary.previewSizes.first
            : null;
        if (secondaryPreviewSize != null) {
          allSurfaces.add(
            VGCamera2SessionSurfacePlan(
              cameraId: secondary.cameraId,
              role: VGCamera2SessionSurfaceRole.preview,
              formatName: 'PRIVATE',
              size: secondaryPreviewSize,
              streamUseCaseName: 'PREVIEW',
            ),
          );
        } else {
          reasons.add('secondary_preview_surface_missing');
        }

        final secondaryVideoSize = secondary.videoSizes.isNotEmpty
            ? secondary.videoSizes.first
            : null;
        if (secondaryVideoSize != null) {
          allSurfaces.add(
            VGCamera2SessionSurfacePlan(
              cameraId: secondary.cameraId,
              role: VGCamera2SessionSurfaceRole.videoRecord,
              formatName: 'PRIVATE',
              size: secondaryVideoSize,
              streamUseCaseName: 'VIDEO_RECORD',
            ),
          );
        } else {
          reasons.add('secondary_video_surface_missing');
        }
      } else {
        reasons.add('secondary_preview_surface_missing');
        reasons.add('secondary_video_surface_missing');
      }
    }

    final isConcurrentCandidate =
        readiness.isDualCameraCandidate &&
        primary != null &&
        secondary != null &&
        allSurfaces.length == 4;

    if (isConcurrentCandidate) {
      if (requiresPermission &&
          !reasons.contains(
            'camera_permission_required_for_runtime_validation',
          )) {
        reasons.add('camera_permission_required_for_runtime_validation');
      }
      return VGCamera2SessionConfigurationPlan(
        decision:
            VGCamera2SessionConfigurationDecision.concurrentValidationCandidate,
        reasons: reasons,
        surfacePlans: allSurfaces,
        selectedConcurrentCameraIds: <String>[
          primary.cameraId,
          secondary.cameraId,
        ],
        requiresCameraPermission: requiresPermission,
        requiresRuntimeSessionValidation: true,
        diagnostics: <String, Object?>{
          'cameraCount': report.cameraCount,
          'supportsConcurrentCamera': report.supportsConcurrentCamera,
          'hasCameraPermission': report.hasCameraPermission,
          'readinessDecision': readiness.decision.name,
          'primaryCameraId': primary.cameraId,
          'secondaryCameraId': secondary.cameraId,
          'surfacePlanCount': allSurfaces.length,
          'mandatoryConcurrentCombinationCount':
              mandatoryConcurrentCombinationCount,
          'mandatoryConcurrentStreamCount': mandatoryConcurrentStreamCount,
        },
      );
    }

    final primarySurfaces = primary != null
        ? allSurfaces
              .where((s) => s.cameraId == primary.cameraId)
              .toList(growable: false)
        : const <VGCamera2SessionSurfacePlan>[];

    if (primarySurfaces.isNotEmpty) {
      return VGCamera2SessionConfigurationPlan(
        decision: VGCamera2SessionConfigurationDecision.singleCameraFallback,
        reasons: reasons,
        surfacePlans: primarySurfaces,
        selectedConcurrentCameraIds: primary != null
            ? <String>[primary.cameraId]
            : const <String>[],
        requiresCameraPermission: requiresPermission,
        requiresRuntimeSessionValidation: false,
        diagnostics: <String, Object?>{
          'cameraCount': report.cameraCount,
          'supportsConcurrentCamera': report.supportsConcurrentCamera,
          'hasCameraPermission': report.hasCameraPermission,
          'readinessDecision': readiness.decision.name,
          'primaryCameraId': primary?.cameraId,
          'secondaryCameraId': secondary?.cameraId,
          'surfacePlanCount': primarySurfaces.length,
          'mandatoryConcurrentCombinationCount':
              mandatoryConcurrentCombinationCount,
          'mandatoryConcurrentStreamCount': mandatoryConcurrentStreamCount,
        },
      );
    }

    final cameraExists =
        primary != null || report.cameras.isNotEmpty || report.cameraCount > 0;

    return VGCamera2SessionConfigurationPlan(
      decision: VGCamera2SessionConfigurationDecision.blocked,
      reasons: reasons,
      surfacePlans: const <VGCamera2SessionSurfacePlan>[],
      selectedConcurrentCameraIds: const <String>[],
      requiresCameraPermission: cameraExists ? requiresPermission : false,
      requiresRuntimeSessionValidation: false,
      diagnostics: <String, Object?>{
        'cameraCount': report.cameraCount,
        'supportsConcurrentCamera': report.supportsConcurrentCamera,
        'hasCameraPermission': report.hasCameraPermission,
        'readinessDecision': readiness.decision.name,
        'primaryCameraId': primary?.cameraId,
        'secondaryCameraId': secondary?.cameraId,
        'surfacePlanCount': 0,
        'mandatoryConcurrentCombinationCount':
            mandatoryConcurrentCombinationCount,
        'mandatoryConcurrentStreamCount': mandatoryConcurrentStreamCount,
      },
    );
  }

  VGCameraHardwareDeviceCapability? _findCamera(
    List<VGCameraHardwareDeviceCapability> cameras,
    String? cameraId,
  ) {
    if (cameraId == null) return null;
    for (final c in cameras) {
      if (c.cameraId == cameraId) return c;
    }
    return null;
  }

  VGCameraHardwareDeviceCapability? _selectPrimaryFallback(
    List<VGCameraHardwareDeviceCapability> cameras,
  ) {
    if (cameras.isEmpty) return null;
    for (final camera in cameras) {
      if (camera.lensFacing == 'back') return camera;
    }
    return cameras.first;
  }

  VGCameraHardwareDeviceCapability? _selectSecondaryFallback(
    List<VGCameraHardwareDeviceCapability> cameras,
    VGCameraHardwareDeviceCapability? primary,
  ) {
    if (primary == null) return null;
    for (final camera in cameras) {
      if (camera.lensFacing == 'front' && camera.cameraId != primary.cameraId) {
        return camera;
      }
    }
    for (final camera in cameras) {
      if (camera.cameraId != primary.cameraId) return camera;
    }
    return null;
  }
}
