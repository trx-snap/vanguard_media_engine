// vg_camerax_thermal_load_shedding_coordinator.dart
// vanguard_media_engine -- P3-CAM-THERMAL-ACT-DART-CALLBACK-CAMERAX-WIRING:
// Android True-DAG foundation wiring from the Dart thermal callback path
// (VGThermalMonitor.onThermalStateChanged) through the advisory load-shedding
// planner to the verified CameraX FPS actuator (VGCameraXThermalFpsBridge).
//
// Claim boundary: this slice proves the Dart thermal callback path reaches
// the CameraX FPS actuator with a correct decision/skip/error contract. It
// does NOT claim real OS thermal delivery -- VGThermalMonitor events are
// either native `onThermalStateChanged` callbacks or debug-only
// `simulateThermalState` synthetic events; this coordinator treats both
// identically and proves neither.
//
// Pure Dart coordinator: no MethodChannel of its own (delegates to the
// injected/default VGCameraXThermalFpsBridge callables), no camera session
// mutation, no resolution rebind, no product/UI wiring.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_camera2_thermal_load_shedding_monitor.dart';
import 'vg_camerax_thermal_fps_bridge.dart';
import 'vanguard_media_engine.dart' show VGThermalMonitor, VGThermalState;

/// Immutable outcome snapshot for a single thermal event processed by
/// [VGCameraXThermalLoadSheddingCoordinator].
///
/// Exactly one of the following is true for a given report: [applied],
/// [skipped], or an error occurred ([errorCode] non-null).
@immutable
class VGCameraXThermalLoadSheddingCoordinatorReport {
  const VGCameraXThermalLoadSheddingCoordinatorReport({
    required this.thermalState,
    this.evaluation,
    this.diagnosticsBefore,
    this.diagnosticsAfter,
    this.applyResult,
    required this.applied,
    required this.skipped,
    this.reason,
    this.errorCode,
    this.errorMessage,
  });

  /// Proof-boundary identifier for this slice's Dart-callback-to-actuator
  /// wiring claim.
  static const String proofBoundary =
      'dart_thermal_callback_path_to_camerax_fps_mid_recording_synthetic_no_forced_heat_no_rebind_no_product';

  /// Explicit non-claims this slice does not prove (all `false`).
  static const Map<String, bool> nonClaims = <String, bool>{
    'realForcedOverheat': false,
    'osThermalListenerDeliveryProven': false,
    'powerManagerThermalStateMutated': false,
    'resolutionReconfigured': false,
    'secondaryCameraDisabled': false,
    'productUiWired': false,
  };

  /// Instance accessor for [proofBoundary].
  String get boundary => proofBoundary;

  /// Instance accessor for [nonClaims].
  Map<String, bool> get claims => nonClaims;

  /// The thermal state that triggered this report.
  final VGThermalState thermalState;

  /// The advisory load-shedding evaluation for this event, or `null` when the
  /// diagnostics fetch that precedes evaluation failed.
  final VGCamera2ThermalLoadSheddingEvaluation? evaluation;

  /// CameraX thermal FPS diagnostics fetched immediately before evaluation,
  /// or `null` when the fetch failed.
  final VGCameraXThermalFpsDiagnostics? diagnosticsBefore;

  /// CameraX thermal FPS diagnostics fetched immediately after a successful
  /// apply, or `null` when not applicable or the fetch failed.
  final VGCameraXThermalFpsDiagnostics? diagnosticsAfter;

  /// The bridge apply result, present only when [applied] is `true`.
  final VGCameraXThermalFpsApplyResult? applyResult;

  /// Whether this event resulted in a successful `applyTargetFps` call.
  final bool applied;

  /// Whether this event was skipped without attempting an apply.
  final bool skipped;

  /// Stable reason code for a [skipped] report (e.g. `apply_in_progress`,
  /// `no_action`, `no_reduction`, `unsupported_decision`).
  final String? reason;

  /// Native or internal error code when diagnostics/apply failed.
  final String? errorCode;

  /// Human-readable error message when diagnostics/apply failed.
  final String? errorMessage;

  Map<String, Object?> toMap() => <String, Object?>{
    'thermalState': thermalState.name,
    'evaluation': evaluation?.toMap(),
    'diagnosticsBefore': diagnosticsBefore?.toMap(),
    'diagnosticsAfter': diagnosticsAfter?.toMap(),
    'applyResult': applyResult?.toMap(),
    'applied': applied,
    'skipped': skipped,
    'reason': reason,
    'errorCode': errorCode,
    'errorMessage': errorMessage,
    'proofBoundary': proofBoundary,
    'nonClaims': nonClaims,
  };

  @override
  String toString() =>
      'VGCameraXThermalLoadSheddingCoordinatorReport('
      'thermalState: $thermalState, '
      'applied: $applied, '
      'skipped: $skipped, '
      'reason: $reason, '
      'errorCode: $errorCode, '
      'errorMessage: $errorMessage, '
      'proofBoundary: $proofBoundary)';
}

/// Pure Dart coordinator wiring [VGThermalMonitor.onThermalStateChanged] (or
/// an injected thermal state stream) through [VGCamera2ThermalLoadSheddingPlanner]
/// advisory evaluation to [VGCameraXThermalFpsBridge] actuation.
///
/// The internal [VGCamera2ThermalLoadSheddingMonitor] is used only for its
/// `evaluateOnce`/history bookkeeping -- this coordinator never calls
/// `monitor.start()`; it owns its own subscription to the thermal state
/// stream so it can serialize diagnostics-fetch/apply per event.
final class VGCameraXThermalLoadSheddingCoordinator {
  VGCameraXThermalLoadSheddingCoordinator({
    Stream<VGThermalState>? thermalStates,
    Future<VGCameraXThermalFpsDiagnostics> Function()? getDiagnostics,
    Future<VGCameraXThermalFpsApplyResult> Function(int targetFps)?
    applyTargetFps,
    VGCamera2ThermalLoadSheddingPlanner? planner,
    VGCamera2ThermalLoadSheddingMonitor? monitor,
    VGCamera2ThermalLoadSheddingMonitorConfig? config,
    this.applyTimeout = const Duration(seconds: 10),
  }) : _thermalStates = thermalStates ?? VGThermalMonitor.onThermalStateChanged,
       _getDiagnostics =
           getDiagnostics ??
           VGCameraXThermalFpsBridge().getAndroidCameraXThermalFpsDiagnostics,
       _applyTargetFps =
           applyTargetFps ??
           VGCameraXThermalFpsBridge().applyAndroidCameraXThermalTargetFps,
       _monitor =
           monitor ??
           VGCamera2ThermalLoadSheddingMonitor(
             planner: planner ?? const VGCamera2ThermalLoadSheddingPlanner(),
             config: config,
           );

  /// Skip reason: another event was still being handled/applied.
  static const String reasonApplyInProgress = 'apply_in_progress';

  /// Skip reason: the planner decided `maintain` or `monitor`.
  static const String reasonNoAction = 'no_action';

  /// Skip reason: the planner decided `reduceFrameRate` but the target FPS
  /// was not below the current FPS.
  static const String reasonNoReduction = 'no_reduction';

  /// Skip reason: the planner decided a mitigation this coordinator does not
  /// actuate (`dropSecondaryCamera`, `stopRecording`, `reduceResolution`).
  static const String reasonUnsupportedDecision = 'unsupported_decision';

  /// Timeout applied to each `getDiagnostics`/`applyTargetFps` call.
  final Duration applyTimeout;

  final Stream<VGThermalState> _thermalStates;
  final Future<VGCameraXThermalFpsDiagnostics> Function() _getDiagnostics;
  final Future<VGCameraXThermalFpsApplyResult> Function(int targetFps)
  _applyTargetFps;
  final VGCamera2ThermalLoadSheddingMonitor _monitor;

  final StreamController<VGCameraXThermalLoadSheddingCoordinatorReport>
  _reportsController =
      StreamController<
        VGCameraXThermalLoadSheddingCoordinatorReport
      >.broadcast();

  StreamSubscription<VGThermalState>? _subscription;
  bool _busy = false;
  bool _isDisposed = false;
  int _generation = 0;
  VGCameraXThermalLoadSheddingCoordinatorReport? _latestReport;

  /// Broadcast stream of per-event outcome reports.
  Stream<VGCameraXThermalLoadSheddingCoordinatorReport> get reports =>
      _reportsController.stream;

  /// Most recently emitted report, or `null` if none has been emitted yet.
  VGCameraXThermalLoadSheddingCoordinatorReport? get latestReport =>
      _latestReport;

  /// The internal advisory monitor, exposed read-only for `evaluateOnce`
  /// history inspection.
  VGCamera2ThermalLoadSheddingMonitor get monitor => _monitor;

  /// Whether this coordinator is actively subscribed to the thermal state
  /// stream.
  bool get isRunning => _subscription != null;

  /// Whether this coordinator has been disposed.
  bool get isDisposed => _isDisposed;

  /// Starts listening to the thermal state stream. Idempotent: a no-op if
  /// already running or disposed.
  void start() {
    if (_isDisposed || _subscription != null) return;
    _subscription = _thermalStates.listen(
      _onThermalEvent,
      onError: (Object _, StackTrace _) {},
      cancelOnError: false,
    );
  }

  /// Stops listening to the thermal state stream without closing [reports].
  /// Idempotent. Invalidates any in-flight event processing so its
  /// completion neither emits a report nor calls apply.
  void stop() {
    if (_subscription == null) return;
    _subscription!.cancel();
    _subscription = null;
    _generation++;
  }

  /// Idempotently stops listening and closes [reports].
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    stop();
    if (!_reportsController.isClosed) {
      await _reportsController.close();
    }
  }

  bool _isCurrentGeneration(int generation) =>
      !_isDisposed && generation == _generation;

  void _emit(
    int generation,
    VGCameraXThermalLoadSheddingCoordinatorReport report,
  ) {
    if (!_isCurrentGeneration(generation)) return;
    if (_reportsController.isClosed) return;
    _latestReport = report;
    _reportsController.add(report);
  }

  void _onThermalEvent(VGThermalState state) {
    if (_isDisposed) return;
    final generation = _generation;
    if (_busy) {
      _emit(
        generation,
        VGCameraXThermalLoadSheddingCoordinatorReport(
          thermalState: state,
          applied: false,
          skipped: true,
          reason: reasonApplyInProgress,
        ),
      );
      return;
    }
    _busy = true;
    unawaited(
      _processEvent(state, generation)
          .catchError((Object error, StackTrace stackTrace) {
            _emit(
              generation,
              VGCameraXThermalLoadSheddingCoordinatorReport(
                thermalState: state,
                applied: false,
                skipped: false,
                errorCode: 'UNEXPECTED_ERROR',
                errorMessage: error.toString(),
              ),
            );
          })
          .whenComplete(() {
            _busy = false;
          }),
    );
  }

  Future<void> _processEvent(VGThermalState state, int generation) async {
    VGCameraXThermalFpsDiagnostics diagnosticsBefore;
    try {
      diagnosticsBefore = await _getDiagnostics().timeout(applyTimeout);
    } on TimeoutException catch (e) {
      _emit(
        generation,
        VGCameraXThermalLoadSheddingCoordinatorReport(
          thermalState: state,
          applied: false,
          skipped: false,
          errorCode: 'TIMEOUT',
          errorMessage: e.toString(),
        ),
      );
      return;
    } catch (e) {
      _emit(
        generation,
        VGCameraXThermalLoadSheddingCoordinatorReport(
          thermalState: state,
          applied: false,
          skipped: false,
          errorCode: _errorCodeOf(e),
          errorMessage: _errorMessageOf(e),
        ),
      );
      return;
    }

    if (!_isCurrentGeneration(generation)) return;

    _monitor.updateSessionState(
      wasRecording:
          diagnosticsBefore.isRecordingActive || diagnosticsBefore.isRecording,
      hadSecondaryCamera: false,
      currentFps:
          diagnosticsBefore.observedAeTargetFpsUpper ??
          diagnosticsBefore.appliedAeTargetFpsUpper ??
          30,
      canPreserveEncoderContract: true,
    );

    final evaluation = _monitor.evaluateOnce(state);
    final plan = evaluation.plan;

    final canApply =
        plan.decision == VGCamera2ThermalLoadSheddingDecision.reduceFrameRate &&
        plan.targetFps < plan.currentFps;

    if (!canApply) {
      _emit(
        generation,
        VGCameraXThermalLoadSheddingCoordinatorReport(
          thermalState: state,
          evaluation: evaluation,
          diagnosticsBefore: diagnosticsBefore,
          applied: false,
          skipped: true,
          reason: _skipReasonFor(plan),
        ),
      );
      return;
    }

    if (!_isCurrentGeneration(generation)) return;

    VGCameraXThermalFpsApplyResult applyResult;
    try {
      applyResult = await _applyTargetFps(plan.targetFps).timeout(applyTimeout);
    } on TimeoutException catch (e) {
      _emit(
        generation,
        VGCameraXThermalLoadSheddingCoordinatorReport(
          thermalState: state,
          evaluation: evaluation,
          diagnosticsBefore: diagnosticsBefore,
          applied: false,
          skipped: false,
          errorCode: 'TIMEOUT',
          errorMessage: e.toString(),
        ),
      );
      return;
    } catch (e) {
      _emit(
        generation,
        VGCameraXThermalLoadSheddingCoordinatorReport(
          thermalState: state,
          evaluation: evaluation,
          diagnosticsBefore: diagnosticsBefore,
          applied: false,
          skipped: false,
          errorCode: _errorCodeOf(e),
          errorMessage: _errorMessageOf(e),
        ),
      );
      return;
    }

    if (!_isCurrentGeneration(generation)) return;

    VGCameraXThermalFpsDiagnostics? diagnosticsAfter;
    try {
      diagnosticsAfter = await _getDiagnostics().timeout(applyTimeout);
    } catch (_) {
      diagnosticsAfter = null;
    }

    if (!_isCurrentGeneration(generation)) return;

    _emit(
      generation,
      VGCameraXThermalLoadSheddingCoordinatorReport(
        thermalState: state,
        evaluation: evaluation,
        diagnosticsBefore: diagnosticsBefore,
        diagnosticsAfter: diagnosticsAfter,
        applyResult: applyResult,
        applied: true,
        skipped: false,
      ),
    );
  }

  String _skipReasonFor(VGCamera2ThermalLoadSheddingPlan plan) {
    switch (plan.decision) {
      case VGCamera2ThermalLoadSheddingDecision.maintain:
      case VGCamera2ThermalLoadSheddingDecision.monitor:
        return reasonNoAction;
      case VGCamera2ThermalLoadSheddingDecision.reduceFrameRate:
        return reasonNoReduction;
      case VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera:
      case VGCamera2ThermalLoadSheddingDecision.stopRecording:
      case VGCamera2ThermalLoadSheddingDecision.reduceResolution:
        return reasonUnsupportedDecision;
    }
  }

  String _errorCodeOf(Object error) {
    if (error is PlatformException) return error.code;
    return 'UNKNOWN_ERROR';
  }

  String _errorMessageOf(Object error) {
    if (error is PlatformException) {
      return error.message ?? error.toString();
    }
    return error.toString();
  }

  @override
  String toString() =>
      'VGCameraXThermalLoadSheddingCoordinator('
      'isRunning=$isRunning, '
      'isDisposed=$isDisposed, '
      'latestReport=$_latestReport)';
}
