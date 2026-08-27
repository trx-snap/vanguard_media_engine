// vg_camera2_readiness_plan.dart
// vanguard_media_engine — Phase 3-Unit C: Android Camera2 readiness &
// fallback planner.
//
// Pure Dart planner. Consumes a VGCameraHardwareCapabilityReport (Units
// A/B) and produces a deterministic attempt/fallback recommendation for
// future Android live camera work. No MethodChannel, no native calls.

import 'package:flutter/foundation.dart';

import 'vg_camera_hardware_capability_report.dart';

/// Decision produced by [VGCamera2ReadinessPlanner.evaluate].
enum VGCamera2ReadinessDecision {
  /// No cameras are present on the device.
  noCamera,

  /// Thermal state is too severe to safely start a camera session.
  thermalBlocked,

  /// Only a single camera should be attempted.
  singleCameraOnly,

  /// A dual-camera (concurrent) session is a viable candidate.
  dualCameraCandidate,
}

/// Deterministic Android Camera2 readiness/fallback plan derived from a
/// [VGCameraHardwareCapabilityReport].
@immutable
class VGCamera2ReadinessPlan {
  const VGCamera2ReadinessPlan({
    required this.decision,
    required this.reasons,
    required this.diagnostics,
    this.selectedPrimaryCameraId,
    this.selectedSecondaryCameraId,
    this.selectedPreviewSize,
    this.selectedVideoSize,
    this.selectedFpsRange,
  });

  final VGCamera2ReadinessDecision decision;
  final List<String> reasons;
  final Map<String, Object?> diagnostics;
  final String? selectedPrimaryCameraId;
  final String? selectedSecondaryCameraId;
  final VGCameraSize? selectedPreviewSize;
  final VGCameraSize? selectedVideoSize;
  final VGCameraFpsRange? selectedFpsRange;

  bool get isDualCameraCandidate =>
      decision == VGCamera2ReadinessDecision.dualCameraCandidate;

  bool get isSingleCameraOnly =>
      decision == VGCamera2ReadinessDecision.singleCameraOnly;

  bool get isBlocked =>
      decision == VGCamera2ReadinessDecision.noCamera ||
      decision == VGCamera2ReadinessDecision.thermalBlocked;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'decision': decision.name,
      'reasons': reasons,
      'diagnostics': diagnostics,
      'selectedPrimaryCameraId': selectedPrimaryCameraId,
      'selectedSecondaryCameraId': selectedSecondaryCameraId,
      'selectedPreviewSize': selectedPreviewSize?.toMap(),
      'selectedVideoSize': selectedVideoSize?.toMap(),
      'selectedFpsRange': selectedFpsRange?.toMap(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ReadinessPlan &&
        other.decision == decision &&
        listEquals(other.reasons, reasons) &&
        mapEquals(other.diagnostics, diagnostics) &&
        other.selectedPrimaryCameraId == selectedPrimaryCameraId &&
        other.selectedSecondaryCameraId == selectedSecondaryCameraId &&
        other.selectedPreviewSize == selectedPreviewSize &&
        other.selectedVideoSize == selectedVideoSize &&
        other.selectedFpsRange == selectedFpsRange;
  }

  @override
  int get hashCode => Object.hash(
    decision,
    Object.hashAll(reasons),
    _stableDiagnosticsHash(diagnostics),
    selectedPrimaryCameraId,
    selectedSecondaryCameraId,
    selectedPreviewSize,
    selectedVideoSize,
    selectedFpsRange,
  );

  static int _stableDiagnosticsHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGCamera2ReadinessPlan('
      'decision: $decision, '
      'reasons: $reasons, '
      'diagnostics: $diagnostics, '
      'selectedPrimaryCameraId: $selectedPrimaryCameraId, '
      'selectedSecondaryCameraId: $selectedSecondaryCameraId, '
      'selectedPreviewSize: $selectedPreviewSize, '
      'selectedVideoSize: $selectedVideoSize, '
      'selectedFpsRange: $selectedFpsRange)';
}

/// Pure Dart planner producing a deterministic Android Camera2
/// attempt/fallback recommendation from a hardware capability report.
///
/// No MethodChannel usage and no native calls — this is a planning-only
/// consumer of [VGCameraHardwareCapabilityReport] (Units A/B output).
final class VGCamera2ReadinessPlanner {
  const VGCamera2ReadinessPlanner();

  static const List<String> _severeThermalNames = <String>[
    'severe',
    'critical',
    'emergency',
    'shutdown',
  ];

  VGCamera2ReadinessPlan evaluate(VGCameraHardwareCapabilityReport report) {
    final reasons = <String>[];

    final primary = _selectPrimary(report);
    final secondary = _selectSecondary(report, primary);
    final primaryLensFacing = primary?.lensFacing;
    final secondaryLensFacing = secondary?.lensFacing;

    if (report.cameraCount == 0 || report.cameras.isEmpty) {
      reasons.add('no_camera_available');
      return VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.noCamera,
        reasons: reasons,
        diagnostics: _diagnostics(
          report: report,
          primaryLensFacing: primaryLensFacing,
          secondaryLensFacing: secondaryLensFacing,
          concurrentSetMatched: false,
          primaryPreviewSizeCount: 0,
          primaryVideoSizeCount: 0,
          primaryFpsRangeCount: 0,
        ),
      );
    }

    final isThermalBlocked =
        _severeThermalNames.contains(report.thermalStatusName) ||
        (report.thermalStatus != null && report.thermalStatus! >= 3);
    if (isThermalBlocked) {
      reasons.add('thermal_blocked');
      return VGCamera2ReadinessPlan(
        decision: VGCamera2ReadinessDecision.thermalBlocked,
        reasons: reasons,
        diagnostics: _diagnostics(
          report: report,
          primaryLensFacing: primaryLensFacing,
          secondaryLensFacing: secondaryLensFacing,
          concurrentSetMatched: false,
          primaryPreviewSizeCount: 0,
          primaryVideoSizeCount: 0,
          primaryFpsRangeCount: 0,
        ),
      );
    }

    if (!report.hasCameraPermission) {
      reasons.add('camera_permission_absent');
    }

    final primaryPreviewSize = _firstOrNull(primary?.previewSizes);
    final primaryVideoSize = _firstOrNull(primary?.videoSizes);
    final primaryFpsRange = _bestFpsRange(primary?.fpsRanges);

    if (primary == null ||
        primary.previewSizes.isEmpty ||
        primary.videoSizes.isEmpty ||
        primary.fpsRanges.isEmpty) {
      reasons.add('primary_stream_config_missing');
    }

    if (secondary == null) {
      reasons.add('no_secondary_camera');
    } else if (secondary.previewSizes.isEmpty ||
        secondary.videoSizes.isEmpty ||
        secondary.fpsRanges.isEmpty) {
      reasons.add('secondary_stream_config_missing');
    }

    var concurrentSetMatched = false;
    if (primary != null && secondary != null) {
      for (final set in report.concurrentCameraIdSets) {
        if (set.contains(primary.cameraId) &&
            set.contains(secondary.cameraId)) {
          concurrentSetMatched = true;
          break;
        }
      }
    }
    if (secondary != null && !concurrentSetMatched) {
      reasons.add('no_matching_concurrent_camera_set');
    }

    final diagnostics = _diagnostics(
      report: report,
      primaryLensFacing: primaryLensFacing,
      secondaryLensFacing: secondaryLensFacing,
      concurrentSetMatched: concurrentSetMatched,
      primaryPreviewSizeCount: primary?.previewSizes.length ?? 0,
      primaryVideoSizeCount: primary?.videoSizes.length ?? 0,
      primaryFpsRangeCount: primary?.fpsRanges.length ?? 0,
    );

    final isDualCandidate =
        report.supportsConcurrentCamera &&
        secondary != null &&
        concurrentSetMatched &&
        primary != null &&
        primary.previewSizes.isNotEmpty &&
        primary.videoSizes.isNotEmpty &&
        primary.fpsRanges.isNotEmpty &&
        secondary.previewSizes.isNotEmpty &&
        secondary.videoSizes.isNotEmpty &&
        secondary.fpsRanges.isNotEmpty;

    return VGCamera2ReadinessPlan(
      decision: isDualCandidate
          ? VGCamera2ReadinessDecision.dualCameraCandidate
          : VGCamera2ReadinessDecision.singleCameraOnly,
      reasons: reasons,
      diagnostics: diagnostics,
      selectedPrimaryCameraId: primary?.cameraId,
      selectedSecondaryCameraId: secondary?.cameraId,
      selectedPreviewSize: primaryPreviewSize,
      selectedVideoSize: primaryVideoSize,
      selectedFpsRange: primaryFpsRange,
    );
  }

  VGCameraHardwareDeviceCapability? _selectPrimary(
    VGCameraHardwareCapabilityReport report,
  ) {
    if (report.cameras.isEmpty) return null;
    for (final camera in report.cameras) {
      if (camera.lensFacing == 'back') return camera;
    }
    return report.cameras.first;
  }

  VGCameraHardwareDeviceCapability? _selectSecondary(
    VGCameraHardwareCapabilityReport report,
    VGCameraHardwareDeviceCapability? primary,
  ) {
    if (primary == null) return null;
    for (final camera in report.cameras) {
      if (camera.lensFacing == 'front' && camera.cameraId != primary.cameraId) {
        return camera;
      }
    }
    for (final camera in report.cameras) {
      if (camera.cameraId != primary.cameraId) return camera;
    }
    return null;
  }

  VGCameraSize? _firstOrNull(List<VGCameraSize>? sizes) {
    if (sizes == null || sizes.isEmpty) return null;
    return sizes.first;
  }

  VGCameraFpsRange? _bestFpsRange(List<VGCameraFpsRange>? ranges) {
    if (ranges == null || ranges.isEmpty) return null;
    var best = ranges.first;
    for (final range in ranges.skip(1)) {
      if (range.upper > best.upper ||
          (range.upper == best.upper && range.lower > best.lower)) {
        best = range;
      }
    }
    return best;
  }

  Map<String, Object?> _diagnostics({
    required VGCameraHardwareCapabilityReport report,
    required String? primaryLensFacing,
    required String? secondaryLensFacing,
    required bool concurrentSetMatched,
    required int primaryPreviewSizeCount,
    required int primaryVideoSizeCount,
    required int primaryFpsRangeCount,
  }) {
    return <String, Object?>{
      'cameraCount': report.cameraCount,
      'supportsConcurrentCamera': report.supportsConcurrentCamera,
      'hasCameraPermission': report.hasCameraPermission,
      'thermalStatusName': report.thermalStatusName,
      'primaryLensFacing': primaryLensFacing,
      'secondaryLensFacing': secondaryLensFacing,
      'concurrentSetMatched': concurrentSetMatched,
      'primaryPreviewSizeCount': primaryPreviewSizeCount,
      'primaryVideoSizeCount': primaryVideoSizeCount,
      'primaryFpsRangeCount': primaryFpsRangeCount,
    };
  }
}
