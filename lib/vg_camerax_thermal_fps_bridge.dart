// vg_camerax_thermal_fps_bridge.dart
// vanguard_media_engine -- P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: Android
// True-DAG foundation production bridge for CameraX repeating-request AE
// target FPS reduction.
//
// Pure Dart typed MethodChannel client over the native
// `applyAndroidCameraXThermalTargetFps` / `getAndroidCameraXThermalFpsDiagnostics`
// routes. This client performs no thermal-state policy of its own -- the
// `targetFps` passed to [applyAndroidCameraXThermalTargetFps] must already be
// the output of [VGCamera2ThermalLoadSheddingPlanner] (or another Dart policy
// authority). FPS-only: no resolution rebind, no OS thermal listener
// registry, no recording-safe claim, no app/editor/product/iOS surface.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A lower/upper AE target FPS range pair, as reported by native telemetry
/// (e.g. a candidate from `CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES`, or a
/// selected/applied/observed range snapshot).
@immutable
class VGCameraXThermalFpsRange {
  const VGCameraXThermalFpsRange({required this.lower, required this.upper});

  final int lower;
  final int upper;

  /// Parses a range from the raw native map. Returns `null` when [raw] is
  /// not a map or is missing either numeric field.
  static VGCameraXThermalFpsRange? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final lower = (raw['lower'] as num?)?.toInt();
    final upper = (raw['upper'] as num?)?.toInt();
    if (lower == null || upper == null) return null;
    return VGCameraXThermalFpsRange(lower: lower, upper: upper);
  }

  /// Parses a list of ranges from a raw native list. Non-map/malformed
  /// entries are skipped.
  static List<VGCameraXThermalFpsRange> listFromRaw(Object? raw) {
    if (raw is! List) return const <VGCameraXThermalFpsRange>[];
    return raw
        .map(VGCameraXThermalFpsRange.fromMap)
        .whereType<VGCameraXThermalFpsRange>()
        .toList(growable: false);
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'lower': lower,
    'upper': upper,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCameraXThermalFpsRange &&
        other.lower == lower &&
        other.upper == upper;
  }

  @override
  int get hashCode => Object.hash(lower, upper);

  @override
  String toString() => 'VGCameraXThermalFpsRange(lower: $lower, upper: $upper)';
}

/// Result of a successful [VGCameraXThermalFpsBridge.applyAndroidCameraXThermalTargetFps]
/// call -- the native actuator's selected/applied AE target FPS range, plus
/// frozen-contract proof telemetry.
@immutable
class VGCameraXThermalFpsApplyResult {
  const VGCameraXThermalFpsApplyResult({
    required this.requestedTargetFps,
    required this.observedCurrentLower,
    required this.observedCurrentUpper,
    required this.selectedLower,
    required this.selectedUpper,
    this.selectedRange,
    this.observedRangeBefore,
    this.observedRangeAfter,
    this.availableRanges = const <VGCameraXThermalFpsRange>[],
    this.bindGeneration = 0,
    this.recordingActiveAtApply = false,
    this.isRecordingAtApply = false,
    this.completedCaptureCountBefore = 0,
    this.completedCaptureCountAfter = 0,
    this.outcome = 'UNKNOWN',
    this.reasons = const <String>[],
    this.proofBoundary = '',
    this.nonClaims = const <String, bool>{},
  });

  /// The `targetFps` the caller requested.
  final int requestedTargetFps;

  /// The AE target FPS range lower bound observed immediately before this
  /// apply (from the most recent completed capture).
  final int observedCurrentLower;

  /// The AE target FPS range upper bound observed immediately before this
  /// apply (from the most recent completed capture).
  final int observedCurrentUpper;

  /// The lower bound of the range the native actuator selected and applied.
  final int selectedLower;

  /// The upper bound of the range the native actuator selected and applied.
  final int selectedUpper;

  /// The range the native actuator selected and applied, as a
  /// [VGCameraXThermalFpsRange] ([selectedLower]/[selectedUpper] pair).
  final VGCameraXThermalFpsRange? selectedRange;

  /// The observed AE target FPS range immediately before this apply.
  final VGCameraXThermalFpsRange? observedRangeBefore;

  /// The observed AE target FPS range at the moment this apply completed.
  final VGCameraXThermalFpsRange? observedRangeAfter;

  /// All `CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES` candidates reported by the
  /// camera device at selection time.
  final List<VGCameraXThermalFpsRange> availableRanges;

  /// The CameraX bind generation this apply was performed against.
  final int bindGeneration;

  /// Whether a video recording was actively writing frames at the moment
  /// this apply was requested.
  final bool recordingActiveAtApply;

  /// Whether a video recording was in progress at the moment this apply was
  /// requested.
  final bool isRecordingAtApply;

  /// `completedCaptureCount` sampled immediately before this apply.
  final int completedCaptureCountBefore;

  /// `completedCaptureCount` sampled at the moment this apply completed.
  final int completedCaptureCountAfter;

  /// Native outcome tag for this apply (e.g. `"APPLIED"`).
  final String outcome;

  /// Native reason codes explaining [outcome].
  final List<String> reasons;

  /// Proof-boundary identifier for the P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE
  /// slice this telemetry was produced under.
  final String proofBoundary;

  /// Explicit non-claims this slice does not prove (all `false`).
  final Map<String, bool> nonClaims;

  /// Parses a result from the raw native map. Returns `null` when [raw] is
  /// not a map or is missing any required numeric field. Frozen-contract
  /// telemetry fields fall back to safe defaults when absent so this stays
  /// forward-compatible with older native builds.
  static VGCameraXThermalFpsApplyResult? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final requestedTargetFps = (raw['requestedTargetFps'] as num?)?.toInt();
    final observedCurrentLower = (raw['observedCurrentLower'] as num?)?.toInt();
    final observedCurrentUpper = (raw['observedCurrentUpper'] as num?)?.toInt();
    final selectedLower = (raw['selectedLower'] as num?)?.toInt();
    final selectedUpper = (raw['selectedUpper'] as num?)?.toInt();
    if (requestedTargetFps == null ||
        observedCurrentLower == null ||
        observedCurrentUpper == null ||
        selectedLower == null ||
        selectedUpper == null) {
      return null;
    }
    return VGCameraXThermalFpsApplyResult(
      requestedTargetFps: requestedTargetFps,
      observedCurrentLower: observedCurrentLower,
      observedCurrentUpper: observedCurrentUpper,
      selectedLower: selectedLower,
      selectedUpper: selectedUpper,
      selectedRange: VGCameraXThermalFpsRange.fromMap(raw['selectedRange']),
      observedRangeBefore: VGCameraXThermalFpsRange.fromMap(
        raw['observedRangeBefore'],
      ),
      observedRangeAfter: VGCameraXThermalFpsRange.fromMap(
        raw['observedRangeAfter'],
      ),
      availableRanges: VGCameraXThermalFpsRange.listFromRaw(
        raw['availableRanges'],
      ),
      bindGeneration: (raw['bindGeneration'] as num?)?.toInt() ?? 0,
      recordingActiveAtApply: raw['recordingActiveAtApply'] as bool? ?? false,
      isRecordingAtApply: raw['isRecordingAtApply'] as bool? ?? false,
      completedCaptureCountBefore:
          (raw['completedCaptureCountBefore'] as num?)?.toInt() ?? 0,
      completedCaptureCountAfter:
          (raw['completedCaptureCountAfter'] as num?)?.toInt() ?? 0,
      outcome: raw['outcome'] as String? ?? 'UNKNOWN',
      reasons:
          (raw['reasons'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[],
      proofBoundary: raw['proofBoundary'] as String? ?? '',
      nonClaims:
          (raw['nonClaims'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value as bool? ?? false),
          ) ??
          const <String, bool>{},
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'requestedTargetFps': requestedTargetFps,
    'observedCurrentLower': observedCurrentLower,
    'observedCurrentUpper': observedCurrentUpper,
    'selectedLower': selectedLower,
    'selectedUpper': selectedUpper,
    'selectedRange': selectedRange?.toMap(),
    'observedRangeBefore': observedRangeBefore?.toMap(),
    'observedRangeAfter': observedRangeAfter?.toMap(),
    'availableRanges': availableRanges.map((r) => r.toMap()).toList(),
    'bindGeneration': bindGeneration,
    'recordingActiveAtApply': recordingActiveAtApply,
    'isRecordingAtApply': isRecordingAtApply,
    'completedCaptureCountBefore': completedCaptureCountBefore,
    'completedCaptureCountAfter': completedCaptureCountAfter,
    'outcome': outcome,
    'reasons': reasons,
    'proofBoundary': proofBoundary,
    'nonClaims': nonClaims,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCameraXThermalFpsApplyResult &&
        other.requestedTargetFps == requestedTargetFps &&
        other.observedCurrentLower == observedCurrentLower &&
        other.observedCurrentUpper == observedCurrentUpper &&
        other.selectedLower == selectedLower &&
        other.selectedUpper == selectedUpper &&
        other.selectedRange == selectedRange &&
        other.observedRangeBefore == observedRangeBefore &&
        other.observedRangeAfter == observedRangeAfter &&
        listEquals(other.availableRanges, availableRanges) &&
        other.bindGeneration == bindGeneration &&
        other.recordingActiveAtApply == recordingActiveAtApply &&
        other.isRecordingAtApply == isRecordingAtApply &&
        other.completedCaptureCountBefore == completedCaptureCountBefore &&
        other.completedCaptureCountAfter == completedCaptureCountAfter &&
        other.outcome == outcome &&
        listEquals(other.reasons, reasons) &&
        other.proofBoundary == proofBoundary &&
        mapEquals(other.nonClaims, nonClaims);
  }

  @override
  int get hashCode => Object.hash(
    requestedTargetFps,
    observedCurrentLower,
    observedCurrentUpper,
    selectedLower,
    selectedUpper,
    Object.hash(
      selectedRange,
      observedRangeBefore,
      observedRangeAfter,
      Object.hashAll(availableRanges),
      bindGeneration,
      recordingActiveAtApply,
      isRecordingAtApply,
      completedCaptureCountBefore,
      completedCaptureCountAfter,
      outcome,
      Object.hashAll(reasons),
      proofBoundary,
    ),
  );

  @override
  String toString() =>
      'VGCameraXThermalFpsApplyResult('
      'requestedTargetFps: $requestedTargetFps, '
      'observedCurrentLower: $observedCurrentLower, '
      'observedCurrentUpper: $observedCurrentUpper, '
      'selectedLower: $selectedLower, '
      'selectedUpper: $selectedUpper, '
      'selectedRange: $selectedRange, '
      'observedRangeBefore: $observedRangeBefore, '
      'observedRangeAfter: $observedRangeAfter, '
      'availableRanges: $availableRanges, '
      'bindGeneration: $bindGeneration, '
      'recordingActiveAtApply: $recordingActiveAtApply, '
      'isRecordingAtApply: $isRecordingAtApply, '
      'completedCaptureCountBefore: $completedCaptureCountBefore, '
      'completedCaptureCountAfter: $completedCaptureCountAfter, '
      'outcome: $outcome, '
      'reasons: $reasons, '
      'proofBoundary: $proofBoundary, '
      'nonClaims: $nonClaims)';
}

/// Snapshot diagnostics for the native CameraX thermal FPS actuation seam,
/// returned by [VGCameraXThermalFpsBridge.getAndroidCameraXThermalFpsDiagnostics].
@immutable
class VGCameraXThermalFpsDiagnostics {
  const VGCameraXThermalFpsDiagnostics({
    required this.running,
    this.textureId,
    required this.bindGeneration,
    required this.bindCount,
    required this.surfaceRequestCount,
    this.cameraProviderIdentity,
    required this.completedCaptureCount,
    this.observedAeTargetFpsLower,
    this.observedAeTargetFpsUpper,
    this.appliedAeTargetFpsLower,
    this.appliedAeTargetFpsUpper,
    required this.consecutiveAppliedRangeCompletedCaptures,
    required this.isRecording,
    required this.isRecordingActive,
    this.appliedRange,
    this.observedRangeBefore,
    this.observedRangeAfter,
    this.availableRanges = const <VGCameraXThermalFpsRange>[],
    this.recordingActiveAtApply = false,
    this.isRecordingAtApply = false,
    this.completedCaptureCountBefore = 0,
    this.completedCaptureCountAfter = 0,
    this.outcome = 'NONE',
    this.reasons = const <String>[],
    this.proofBoundary = '',
    this.nonClaims = const <String, bool>{},
  });

  /// Whether the native camera session is currently running.
  final bool running;

  /// The Flutter texture id for the active camera session, or `null` when no
  /// session is active.
  final int? textureId;

  /// Monotonically-increasing CameraX bind generation counter -- advances on
  /// every `bindUseCases()` call (`start()`, `switchCamera()`).
  final int bindGeneration;

  /// Monotonically-increasing count of `bindUseCases()` calls.
  final int bindCount;

  /// Count of `Preview.SurfaceProvider` requests served for the current
  /// session. Must stay unchanged across a thermal FPS apply -- proves no
  /// rebind occurred.
  final int surfaceRequestCount;

  /// Native `ProcessCameraProvider` identity hash for the active session, or
  /// `null` when no session is active.
  final int? cameraProviderIdentity;

  /// Count of completed captures observed via the Camera2 interop session
  /// capture callback since the current bind.
  final int completedCaptureCount;

  /// Lower bound of the most recently observed `CONTROL_AE_TARGET_FPS_RANGE`,
  /// or `null` if no completed capture has reported one yet.
  final int? observedAeTargetFpsLower;

  /// Upper bound of the most recently observed `CONTROL_AE_TARGET_FPS_RANGE`,
  /// or `null` if no completed capture has reported one yet.
  final int? observedAeTargetFpsUpper;

  /// Lower bound of the most recently applied thermal target FPS range, or
  /// `null` if none has been applied for the current bind.
  final int? appliedAeTargetFpsLower;

  /// Upper bound of the most recently applied thermal target FPS range, or
  /// `null` if none has been applied for the current bind.
  final int? appliedAeTargetFpsUpper;

  /// Count of *consecutive* completed captures whose observed AE target FPS
  /// range matches the applied range. `>= 2` is the bar for proving the
  /// actuation took hardware effect.
  final int consecutiveAppliedRangeCompletedCaptures;

  /// Whether a video recording is currently in progress.
  final bool isRecording;

  /// Whether a video recording is actively writing frames.
  final bool isRecordingActive;

  /// The most recently applied thermal target FPS range ([appliedAeTargetFpsLower]/
  /// [appliedAeTargetFpsUpper] pair), or `null` if none has been applied for
  /// the current bind.
  final VGCameraXThermalFpsRange? appliedRange;

  /// The observed AE target FPS range immediately before the most recent
  /// applyThermalTargetFps() attempt, or `null` if none has been attempted
  /// for the current bind.
  final VGCameraXThermalFpsRange? observedRangeBefore;

  /// The observed AE target FPS range at the moment the most recent
  /// applyThermalTargetFps() attempt completed, or `null` if none has been
  /// attempted for the current bind.
  final VGCameraXThermalFpsRange? observedRangeAfter;

  /// All `CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES` candidates reported at the
  /// time of the most recent applyThermalTargetFps() attempt.
  final List<VGCameraXThermalFpsRange> availableRanges;

  /// Whether a video recording was actively writing frames at the moment of
  /// the most recent applyThermalTargetFps() attempt.
  final bool recordingActiveAtApply;

  /// Whether a video recording was in progress at the moment of the most
  /// recent applyThermalTargetFps() attempt.
  final bool isRecordingAtApply;

  /// `completedCaptureCount` sampled immediately before the most recent
  /// applyThermalTargetFps() attempt.
  final int completedCaptureCountBefore;

  /// `completedCaptureCount` sampled at the moment the most recent
  /// applyThermalTargetFps() attempt completed.
  final int completedCaptureCountAfter;

  /// Native outcome tag for the most recent applyThermalTargetFps() attempt
  /// (e.g. `"APPLIED"`, `"REJECTED"`), or `"NONE"` if none has been attempted
  /// for the current bind.
  final String outcome;

  /// Native reason codes explaining [outcome].
  final List<String> reasons;

  /// Proof-boundary identifier for the P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE
  /// slice this telemetry was produced under.
  final String proofBoundary;

  /// Explicit non-claims this slice does not prove (all `false`).
  final Map<String, bool> nonClaims;

  /// Parses diagnostics from the raw native map. Returns `null` when [raw]
  /// is not a map.
  static VGCameraXThermalFpsDiagnostics? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return VGCameraXThermalFpsDiagnostics(
      running: raw['running'] as bool? ?? false,
      textureId: (raw['textureId'] as num?)?.toInt(),
      bindGeneration: (raw['bindGeneration'] as num?)?.toInt() ?? 0,
      bindCount: (raw['bindCount'] as num?)?.toInt() ?? 0,
      surfaceRequestCount: (raw['surfaceRequestCount'] as num?)?.toInt() ?? 0,
      cameraProviderIdentity: (raw['cameraProviderIdentity'] as num?)?.toInt(),
      completedCaptureCount:
          (raw['completedCaptureCount'] as num?)?.toInt() ?? 0,
      observedAeTargetFpsLower: (raw['observedAeTargetFpsLower'] as num?)
          ?.toInt(),
      observedAeTargetFpsUpper: (raw['observedAeTargetFpsUpper'] as num?)
          ?.toInt(),
      appliedAeTargetFpsLower: (raw['appliedAeTargetFpsLower'] as num?)
          ?.toInt(),
      appliedAeTargetFpsUpper: (raw['appliedAeTargetFpsUpper'] as num?)
          ?.toInt(),
      consecutiveAppliedRangeCompletedCaptures:
          (raw['consecutiveAppliedRangeCompletedCaptures'] as num?)?.toInt() ??
          0,
      isRecording: raw['isRecording'] as bool? ?? false,
      isRecordingActive: raw['isRecordingActive'] as bool? ?? false,
      appliedRange: VGCameraXThermalFpsRange.fromMap(raw['appliedRange']),
      observedRangeBefore: VGCameraXThermalFpsRange.fromMap(
        raw['observedRangeBefore'],
      ),
      observedRangeAfter: VGCameraXThermalFpsRange.fromMap(
        raw['observedRangeAfter'],
      ),
      availableRanges: VGCameraXThermalFpsRange.listFromRaw(
        raw['availableRanges'],
      ),
      recordingActiveAtApply: raw['recordingActiveAtApply'] as bool? ?? false,
      isRecordingAtApply: raw['isRecordingAtApply'] as bool? ?? false,
      completedCaptureCountBefore:
          (raw['completedCaptureCountBefore'] as num?)?.toInt() ?? 0,
      completedCaptureCountAfter:
          (raw['completedCaptureCountAfter'] as num?)?.toInt() ?? 0,
      outcome: raw['outcome'] as String? ?? 'NONE',
      reasons:
          (raw['reasons'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[],
      proofBoundary: raw['proofBoundary'] as String? ?? '',
      nonClaims:
          (raw['nonClaims'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value as bool? ?? false),
          ) ??
          const <String, bool>{},
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'running': running,
    'textureId': textureId,
    'bindGeneration': bindGeneration,
    'bindCount': bindCount,
    'surfaceRequestCount': surfaceRequestCount,
    'cameraProviderIdentity': cameraProviderIdentity,
    'completedCaptureCount': completedCaptureCount,
    'observedAeTargetFpsLower': observedAeTargetFpsLower,
    'observedAeTargetFpsUpper': observedAeTargetFpsUpper,
    'appliedAeTargetFpsLower': appliedAeTargetFpsLower,
    'appliedAeTargetFpsUpper': appliedAeTargetFpsUpper,
    'consecutiveAppliedRangeCompletedCaptures':
        consecutiveAppliedRangeCompletedCaptures,
    'isRecording': isRecording,
    'isRecordingActive': isRecordingActive,
    'appliedRange': appliedRange?.toMap(),
    'observedRangeBefore': observedRangeBefore?.toMap(),
    'observedRangeAfter': observedRangeAfter?.toMap(),
    'availableRanges': availableRanges.map((r) => r.toMap()).toList(),
    'recordingActiveAtApply': recordingActiveAtApply,
    'isRecordingAtApply': isRecordingAtApply,
    'completedCaptureCountBefore': completedCaptureCountBefore,
    'completedCaptureCountAfter': completedCaptureCountAfter,
    'outcome': outcome,
    'reasons': reasons,
    'proofBoundary': proofBoundary,
    'nonClaims': nonClaims,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCameraXThermalFpsDiagnostics &&
        other.running == running &&
        other.textureId == textureId &&
        other.bindGeneration == bindGeneration &&
        other.bindCount == bindCount &&
        other.surfaceRequestCount == surfaceRequestCount &&
        other.cameraProviderIdentity == cameraProviderIdentity &&
        other.completedCaptureCount == completedCaptureCount &&
        other.observedAeTargetFpsLower == observedAeTargetFpsLower &&
        other.observedAeTargetFpsUpper == observedAeTargetFpsUpper &&
        other.appliedAeTargetFpsLower == appliedAeTargetFpsLower &&
        other.appliedAeTargetFpsUpper == appliedAeTargetFpsUpper &&
        other.consecutiveAppliedRangeCompletedCaptures ==
            consecutiveAppliedRangeCompletedCaptures &&
        other.isRecording == isRecording &&
        other.isRecordingActive == isRecordingActive &&
        other.appliedRange == appliedRange &&
        other.observedRangeBefore == observedRangeBefore &&
        other.observedRangeAfter == observedRangeAfter &&
        listEquals(other.availableRanges, availableRanges) &&
        other.recordingActiveAtApply == recordingActiveAtApply &&
        other.isRecordingAtApply == isRecordingAtApply &&
        other.completedCaptureCountBefore == completedCaptureCountBefore &&
        other.completedCaptureCountAfter == completedCaptureCountAfter &&
        other.outcome == outcome &&
        listEquals(other.reasons, reasons) &&
        other.proofBoundary == proofBoundary &&
        mapEquals(other.nonClaims, nonClaims);
  }

  @override
  int get hashCode => Object.hash(
    running,
    textureId,
    bindGeneration,
    bindCount,
    surfaceRequestCount,
    cameraProviderIdentity,
    completedCaptureCount,
    Object.hash(
      observedAeTargetFpsLower,
      observedAeTargetFpsUpper,
      appliedAeTargetFpsLower,
      appliedAeTargetFpsUpper,
      consecutiveAppliedRangeCompletedCaptures,
      isRecording,
      isRecordingActive,
    ),
    Object.hash(
      appliedRange,
      observedRangeBefore,
      observedRangeAfter,
      Object.hashAll(availableRanges),
      recordingActiveAtApply,
      isRecordingAtApply,
      completedCaptureCountBefore,
      completedCaptureCountAfter,
      outcome,
      Object.hashAll(reasons),
      proofBoundary,
    ),
  );

  @override
  String toString() =>
      'VGCameraXThermalFpsDiagnostics('
      'running: $running, '
      'textureId: $textureId, '
      'bindGeneration: $bindGeneration, '
      'bindCount: $bindCount, '
      'surfaceRequestCount: $surfaceRequestCount, '
      'cameraProviderIdentity: $cameraProviderIdentity, '
      'completedCaptureCount: $completedCaptureCount, '
      'observedAeTargetFpsLower: $observedAeTargetFpsLower, '
      'observedAeTargetFpsUpper: $observedAeTargetFpsUpper, '
      'appliedAeTargetFpsLower: $appliedAeTargetFpsLower, '
      'appliedAeTargetFpsUpper: $appliedAeTargetFpsUpper, '
      'consecutiveAppliedRangeCompletedCaptures: $consecutiveAppliedRangeCompletedCaptures, '
      'isRecording: $isRecording, '
      'isRecordingActive: $isRecordingActive, '
      'appliedRange: $appliedRange, '
      'observedRangeBefore: $observedRangeBefore, '
      'observedRangeAfter: $observedRangeAfter, '
      'availableRanges: $availableRanges, '
      'recordingActiveAtApply: $recordingActiveAtApply, '
      'isRecordingAtApply: $isRecordingAtApply, '
      'completedCaptureCountBefore: $completedCaptureCountBefore, '
      'completedCaptureCountAfter: $completedCaptureCountAfter, '
      'outcome: $outcome, '
      'reasons: $reasons, '
      'proofBoundary: $proofBoundary, '
      'nonClaims: $nonClaims)';
}

/// Typed MethodChannel client for the native Android
/// P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE routes. Android-only; on other
/// platforms native calls throw [MissingPluginException] (not caught here --
/// callers are expected to be Android-specific, mirroring
/// [VGCamera2ThermalFpsActionSmokeReport]).
class VGCameraXThermalFpsBridge {
  VGCameraXThermalFpsBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  static const String _applyMethod = 'applyAndroidCameraXThermalTargetFps';
  static const String _diagnosticsMethod =
      'getAndroidCameraXThermalFpsDiagnostics';

  /// Applies [targetFps] as a reduced CameraX repeating-request AE target FPS
  /// range. [targetFps] must already be the output of a Dart thermal policy
  /// authority (e.g. [VGCamera2ThermalLoadSheddingPlanner]) -- this client
  /// performs no policy of its own.
  ///
  /// Throws [PlatformException] (native error codes include `NO_CAMERA`,
  /// `NOT_RUNNING`, `STOPPED`, `NO_CAMERA_DEVICE`, `NO_ACTUATOR`,
  /// `INVALID_TARGET_FPS`, `MISSING_OBSERVED_RANGE`, `NO_AVAILABLE_RANGES`,
  /// `NO_REDUCTION`, `APPLY_FAILED`, `STALE_APPLY`, `APPLY_IN_PROGRESS`) when
  /// the native side rejects the request, an earlier apply on this session is
  /// still in flight (`APPLY_IN_PROGRESS`), or this apply resolves after a
  /// rebind/teardown made it stale (no hardware state is mutated for a stale
  /// outcome).
  Future<VGCameraXThermalFpsApplyResult> applyAndroidCameraXThermalTargetFps(
    int targetFps,
  ) async {
    final raw = await _channel.invokeMethod<Object?>(_applyMethod, {
      'targetFps': targetFps,
    });
    final result = VGCameraXThermalFpsApplyResult.fromMap(raw);
    if (result == null) {
      throw PlatformException(
        code: 'BAD_NATIVE_RESULT',
        message:
            'applyAndroidCameraXThermalTargetFps: native result was not a '
            'well-formed apply-result map: $raw',
      );
    }
    return result;
  }

  /// Fetches a snapshot of the native thermal FPS actuation diagnostics.
  ///
  /// Throws [PlatformException] with code `NO_CAMERA` when no camera session
  /// is currently active (e.g. before `startCamera` or after `stopCamera`)
  /// -- this is not a "safe to call anytime" no-op; the router only returns
  /// a populated map while a session exists.
  Future<VGCameraXThermalFpsDiagnostics>
  getAndroidCameraXThermalFpsDiagnostics() async {
    final raw = await _channel.invokeMethod<Object?>(_diagnosticsMethod);
    final diagnostics = VGCameraXThermalFpsDiagnostics.fromMap(raw);
    if (diagnostics == null) {
      throw PlatformException(
        code: 'BAD_NATIVE_RESULT',
        message:
            'getAndroidCameraXThermalFpsDiagnostics: native result was not '
            'a well-formed diagnostics map: $raw',
      );
    }
    return diagnostics;
  }
}
