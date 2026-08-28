// vg_camera2_thermal_load_shedding_policy.dart
// vanguard_media_engine — Phase 3-Unit U: Android Camera2 Mid-Recording
// Thermal Load-Shedding Policy & Mitigation Planner.
//
// Pure Dart advisory planner. Evaluates mid-recording thermal transitions
// (nominal, fair, serious, critical) and produces deterministic mitigation plans
// (maintain, monitor, reduceFrameRate, dropSecondaryCamera, stopRecording).
//
// No MethodChannel, no dart:io, no Flutter widgets, no native calls, no camera
// session mutations, and no renderer or encoder changes.

import 'package:flutter/foundation.dart';

import 'vanguard_media_engine.dart';

/// Decisions produced by [VGCamera2ThermalLoadSheddingPlanner.evaluate].
enum VGCamera2ThermalLoadSheddingDecision {
  /// Maintain current recording and session configuration without alteration.
  maintain,

  /// Continue recording but monitor thermal trend; notify Dart / product layer.
  monitor,

  /// Reduce capture and processing frame rate to lower thermal pressure.
  reduceFrameRate,

  /// Drop the secondary camera stream at the next safe graph boundary.
  dropSecondaryCamera,

  /// Stop active recording at the next safe graph boundary to avoid data corruption
  /// or hardware thermal shutdown.
  stopRecording,
}

/// Immutable input configuration for thermal load-shedding evaluation.
@immutable
class VGCamera2ThermalLoadSheddingInput {
  const VGCamera2ThermalLoadSheddingInput({
    required this.thermalState,
    this.wasRecording = false,
    this.hadSecondaryCamera = false,
    this.currentFps = 30,
    this.currentResolutionScale = 1.0,
    this.canPreserveEncoderContract = true,
  });

  /// The observed device thermal state.
  final VGThermalState thermalState;

  /// Whether a recording was actively in progress when the thermal transition occurred.
  final bool wasRecording;

  /// Whether a secondary (e.g. concurrent dual) camera was active.
  final bool hadSecondaryCamera;

  /// Current operating frame rate in FPS.
  final int currentFps;

  /// Current resolution scale relative to initial configuration (e.g. 1.0 = 100%).
  final double currentResolutionScale;

  /// Whether the video encoder output contract (e.g. container track format/dimensions)
  /// can be safely preserved during mid-stream load shedding.
  final bool canPreserveEncoderContract;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'thermalState': thermalState.name,
      'wasRecording': wasRecording,
      'hadSecondaryCamera': hadSecondaryCamera,
      'currentFps': currentFps,
      'currentResolutionScale': currentResolutionScale,
      'canPreserveEncoderContract': canPreserveEncoderContract,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ThermalLoadSheddingInput &&
        other.thermalState == thermalState &&
        other.wasRecording == wasRecording &&
        other.hadSecondaryCamera == hadSecondaryCamera &&
        other.currentFps == currentFps &&
        other.currentResolutionScale == currentResolutionScale &&
        other.canPreserveEncoderContract == canPreserveEncoderContract;
  }

  @override
  int get hashCode => Object.hash(
    thermalState,
    wasRecording,
    hadSecondaryCamera,
    currentFps,
    currentResolutionScale,
    canPreserveEncoderContract,
  );

  @override
  String toString() =>
      'VGCamera2ThermalLoadSheddingInput('
      'thermalState: $thermalState, '
      'wasRecording: $wasRecording, '
      'hadSecondaryCamera: $hadSecondaryCamera, '
      'currentFps: $currentFps, '
      'currentResolutionScale: $currentResolutionScale, '
      'canPreserveEncoderContract: $canPreserveEncoderContract)';
}

/// Immutable advisory plan emitted by [VGCamera2ThermalLoadSheddingPlanner.evaluate].
@immutable
class VGCamera2ThermalLoadSheddingPlan {
  const VGCamera2ThermalLoadSheddingPlan({
    required this.decision,
    required this.reasons,
    required this.thermalState,
    required this.wasRecording,
    required this.hadSecondaryCamera,
    required this.currentFps,
    required this.targetFps,
    required this.targetResolutionScale,
    required this.notifyDart,
    required this.requiresSafeGraphBoundary,
    required this.preservesEncoderContract,
    required this.shouldDropSecondaryCamera,
    required this.shouldStopRecording,
    required this.diagnostics,
  });

  /// The mitigation decision recommended by the planner.
  final VGCamera2ThermalLoadSheddingDecision decision;

  /// Stable reason codes explaining the decision.
  final List<String> reasons;

  /// The thermal state that triggered this evaluation.
  final VGThermalState thermalState;

  /// Whether recording was active at evaluation time.
  final bool wasRecording;

  /// Whether a secondary camera was active at evaluation time.
  final bool hadSecondaryCamera;

  /// Input frame rate prior to mitigation.
  final int currentFps;

  /// Recommended target frame rate after mitigation.
  final int targetFps;

  /// Recommended target resolution scale (<= currentResolutionScale and > 0).
  final double targetResolutionScale;

  /// Whether Dart / application layer must be notified of this thermal change.
  final bool notifyDart;

  /// Whether the mitigation action must be executed strictly at a safe graph boundary.
  final bool requiresSafeGraphBoundary;

  /// Whether the encoder output contract remains preserved under this plan.
  final bool preservesEncoderContract;

  /// Whether the secondary camera stream should be dropped.
  final bool shouldDropSecondaryCamera;

  /// Whether the active recording should be stopped.
  final bool shouldStopRecording;

  /// Diagnostic telemetry and non-claims for advisory verification.
  final Map<String, Object?> diagnostics;

  bool get isMaintaining =>
      decision == VGCamera2ThermalLoadSheddingDecision.maintain;

  bool get isMonitoring =>
      decision == VGCamera2ThermalLoadSheddingDecision.monitor;

  bool get isReducingFrameRate =>
      decision == VGCamera2ThermalLoadSheddingDecision.reduceFrameRate;

  bool get isDroppingSecondaryCamera =>
      decision == VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera;

  bool get isStoppingRecording =>
      decision == VGCamera2ThermalLoadSheddingDecision.stopRecording;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'decision': decision.name,
      'reasons': reasons,
      'thermalState': thermalState.name,
      'wasRecording': wasRecording,
      'hadSecondaryCamera': hadSecondaryCamera,
      'currentFps': currentFps,
      'targetFps': targetFps,
      'targetResolutionScale': targetResolutionScale,
      'notifyDart': notifyDart,
      'requiresSafeGraphBoundary': requiresSafeGraphBoundary,
      'preservesEncoderContract': preservesEncoderContract,
      'shouldDropSecondaryCamera': shouldDropSecondaryCamera,
      'shouldStopRecording': shouldStopRecording,
      'diagnostics': diagnostics,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ThermalLoadSheddingPlan &&
        other.decision == decision &&
        listEquals(other.reasons, reasons) &&
        other.thermalState == thermalState &&
        other.wasRecording == wasRecording &&
        other.hadSecondaryCamera == hadSecondaryCamera &&
        other.currentFps == currentFps &&
        other.targetFps == targetFps &&
        other.targetResolutionScale == targetResolutionScale &&
        other.notifyDart == notifyDart &&
        other.requiresSafeGraphBoundary == requiresSafeGraphBoundary &&
        other.preservesEncoderContract == preservesEncoderContract &&
        other.shouldDropSecondaryCamera == shouldDropSecondaryCamera &&
        other.shouldStopRecording == shouldStopRecording &&
        _deepMapEquals(other.diagnostics, diagnostics);
  }

  @override
  int get hashCode => Object.hash(
    decision,
    Object.hashAll(reasons),
    thermalState,
    wasRecording,
    hadSecondaryCamera,
    currentFps,
    targetFps,
    targetResolutionScale,
    notifyDart,
    requiresSafeGraphBoundary,
    preservesEncoderContract,
    shouldDropSecondaryCamera,
    shouldStopRecording,
    _stableDiagnosticsHash(diagnostics),
  );

  static bool _deepMapEquals(
    Map<dynamic, dynamic>? a,
    Map<dynamic, dynamic>? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepValueEquals(a[key], b[key])) return false;
    }
    return true;
  }

  static bool _deepListEquals(List<dynamic>? a, List<dynamic>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepValueEquals(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _deepValueEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      return _deepMapEquals(a, b);
    }
    if (a is List && b is List) {
      return _deepListEquals(a, b);
    }
    return a == b;
  }

  static int _stableDiagnosticsHash(Map<dynamic, dynamic> map) {
    final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
    return Object.hashAll(
      sortedKeys.map((key) {
        final value = map[key];
        return Object.hash(key, _deepValueHash(value));
      }),
    );
  }

  static int _deepValueHash(Object? value) {
    if (value is Map) {
      return _stableDiagnosticsHash(value);
    }
    if (value is List) {
      return Object.hashAll(value.map(_deepValueHash));
    }
    return value.hashCode;
  }

  @override
  String toString() =>
      'VGCamera2ThermalLoadSheddingPlan('
      'decision: $decision, '
      'reasons: $reasons, '
      'thermalState: $thermalState, '
      'wasRecording: $wasRecording, '
      'hadSecondaryCamera: $hadSecondaryCamera, '
      'currentFps: $currentFps, '
      'targetFps: $targetFps, '
      'targetResolutionScale: $targetResolutionScale, '
      'notifyDart: $notifyDart, '
      'requiresSafeGraphBoundary: $requiresSafeGraphBoundary, '
      'preservesEncoderContract: $preservesEncoderContract, '
      'shouldDropSecondaryCamera: $shouldDropSecondaryCamera, '
      'shouldStopRecording: $shouldStopRecording, '
      'diagnostics: $diagnostics)';
}

/// Pure Dart advisory planner for Camera2 mid-recording thermal mitigation.
///
/// Evaluates input thermal states and recording context deterministically to produce
/// a [VGCamera2ThermalLoadSheddingPlan].
final class VGCamera2ThermalLoadSheddingPlanner {
  const VGCamera2ThermalLoadSheddingPlanner({this.minFpsFloor = 15});

  /// The minimum frame rate target floor for FPS reduction.
  final int minFpsFloor;

  static const String proofBoundary =
      'thermal_load_shedding_policy_advisory_no_camera_session_mutation';

  static const Map<String, bool> nonClaims = <String, bool>{
    'cameraSessionMutated': false,
    'captureRequestUpdated': false,
    'cameraOpened': false,
    'rendererTouched': false,
    'encoderTouched': false,
    'realForcedOverheat': false,
  };

  /// Evaluates thermal load-shedding policy using an explicit input object.
  VGCamera2ThermalLoadSheddingPlan evaluateInput(
    VGCamera2ThermalLoadSheddingInput input,
  ) {
    return evaluate(
      thermalState: input.thermalState,
      wasRecording: input.wasRecording,
      hadSecondaryCamera: input.hadSecondaryCamera,
      currentFps: input.currentFps,
      currentResolutionScale: input.currentResolutionScale,
      canPreserveEncoderContract: input.canPreserveEncoderContract,
    );
  }

  /// Evaluates thermal load-shedding policy deterministically.
  VGCamera2ThermalLoadSheddingPlan evaluate({
    required VGThermalState thermalState,
    bool wasRecording = false,
    bool hadSecondaryCamera = false,
    int currentFps = 30,
    double currentResolutionScale = 1.0,
    bool canPreserveEncoderContract = true,
  }) {
    final VGCamera2ThermalLoadSheddingDecision decision;
    final List<String> reasons = <String>[];
    final bool notifyDart;
    final bool requiresSafeGraphBoundary;
    final bool preservesEncoderContract;
    final bool shouldDropSecondaryCamera;
    final bool shouldStopRecording;
    final int targetFps;
    final double targetResolutionScale;

    switch (thermalState) {
      case VGThermalState.nominal:
        decision = VGCamera2ThermalLoadSheddingDecision.maintain;
        reasons.add('thermal_nominal');
        notifyDart = false;
        requiresSafeGraphBoundary = false;
        preservesEncoderContract = true;
        shouldDropSecondaryCamera = false;
        shouldStopRecording = false;
        targetFps = currentFps;
        targetResolutionScale = currentResolutionScale;

      case VGThermalState.fair:
        decision = VGCamera2ThermalLoadSheddingDecision.monitor;
        reasons.add('thermal_fair_monitor');
        notifyDart = true;
        requiresSafeGraphBoundary = false;
        preservesEncoderContract = true;
        shouldDropSecondaryCamera = false;
        shouldStopRecording = false;
        targetFps = currentFps;
        targetResolutionScale = currentResolutionScale;

      case VGThermalState.serious:
        if (wasRecording) {
          notifyDart = true;
          requiresSafeGraphBoundary = true;
          if (hadSecondaryCamera) {
            decision = VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera;
            reasons.add('thermal_serious_drop_secondary');
            preservesEncoderContract = canPreserveEncoderContract;
            shouldDropSecondaryCamera = true;
            shouldStopRecording = false;
            targetFps = currentFps;
            targetResolutionScale = currentResolutionScale;
          } else {
            decision = VGCamera2ThermalLoadSheddingDecision.reduceFrameRate;
            reasons.add('thermal_serious_reduce_fps');
            preservesEncoderContract = canPreserveEncoderContract;
            shouldDropSecondaryCamera = false;
            shouldStopRecording = false;
            targetFps = _calculateReducedFps(currentFps);
            targetResolutionScale = currentResolutionScale > 0.0
                ? currentResolutionScale
                : 1.0;
          }
        } else {
          decision = VGCamera2ThermalLoadSheddingDecision.monitor;
          reasons.add('thermal_serious_not_recording');
          reasons.add('not_recording_block_new_start');
          notifyDart = true;
          requiresSafeGraphBoundary = false;
          preservesEncoderContract = true;
          shouldDropSecondaryCamera = false;
          shouldStopRecording = false;
          targetFps = currentFps;
          targetResolutionScale = currentResolutionScale;
        }

      case VGThermalState.critical:
        if (wasRecording) {
          notifyDart = true;
          requiresSafeGraphBoundary = true;
          if (canPreserveEncoderContract && hadSecondaryCamera) {
            decision = VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera;
            reasons.add('thermal_critical_drop_secondary');
            preservesEncoderContract = true;
            shouldDropSecondaryCamera = true;
            shouldStopRecording = false;
            targetFps = currentFps;
            targetResolutionScale = currentResolutionScale;
          } else {
            decision = VGCamera2ThermalLoadSheddingDecision.stopRecording;
            reasons.add('thermal_critical_stop_recording');
            if (!canPreserveEncoderContract) {
              reasons.add('encoder_contract_not_preserved');
            }
            preservesEncoderContract = false;
            shouldDropSecondaryCamera = false;
            shouldStopRecording = true;
            targetFps = currentFps;
            targetResolutionScale = currentResolutionScale;
          }
        } else {
          decision = VGCamera2ThermalLoadSheddingDecision.maintain;
          reasons.add('thermal_critical_not_recording');
          reasons.add('not_recording_block_new_start');
          notifyDart = true;
          requiresSafeGraphBoundary = false;
          preservesEncoderContract = true;
          shouldDropSecondaryCamera = false;
          shouldStopRecording = false;
          targetFps = currentFps;
          targetResolutionScale = currentResolutionScale;
        }
    }

    final diagnostics = <String, Object?>{
      'proofBoundary': proofBoundary,
      'thermalState': thermalState.name,
      'wasRecording': wasRecording,
      'hadSecondaryCamera': hadSecondaryCamera,
      'currentFps': currentFps,
      'targetFps': targetFps,
      'currentResolutionScale': currentResolutionScale,
      'targetResolutionScale': targetResolutionScale,
      'canPreserveEncoderContract': canPreserveEncoderContract,
      'nonClaims': Map<String, bool>.from(nonClaims),
    };

    return VGCamera2ThermalLoadSheddingPlan(
      decision: decision,
      reasons: List<String>.unmodifiable(reasons),
      thermalState: thermalState,
      wasRecording: wasRecording,
      hadSecondaryCamera: hadSecondaryCamera,
      currentFps: currentFps,
      targetFps: targetFps,
      targetResolutionScale: targetResolutionScale,
      notifyDart: notifyDart,
      requiresSafeGraphBoundary: requiresSafeGraphBoundary,
      preservesEncoderContract: preservesEncoderContract,
      shouldDropSecondaryCamera: shouldDropSecondaryCamera,
      shouldStopRecording: shouldStopRecording,
      diagnostics: diagnostics,
    );
  }

  int _calculateReducedFps(int currentFps) {
    if (currentFps > 30) return 30;
    if (currentFps > 24) return 24;
    if (currentFps > minFpsFloor) return minFpsFloor;
    if (currentFps > 1) return currentFps - 1;
    return 1;
  }
}
