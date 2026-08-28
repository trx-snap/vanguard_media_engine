// vg_camera2_thermal_load_shedding_monitor.dart
// vanguard_media_engine — Phase 3-Unit V: Android Camera2 Thermal Load-Shedding
// Monitor & Telemetry Coordinator Foundation.
//
// Pure Dart reactive coordinator on top of Unit T thermal events (VGThermalState /
// VGThermalMonitor) and Unit U advisory planner (VGCamera2ThermalLoadSheddingPlanner).
//
// Pure Dart monitor: consumes VGThermalState events, tracks dynamic session state,
// maintains a bounded chronological evaluation history, and emits immutable advisory
// evaluation snapshots.
//
// No MethodChannel, no dart:io, no Flutter widgets, no native calls, no camera
// session mutations, no capture request modifications, no timers, no background
// isolates, and no renderer or encoder changes.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'vg_camera2_thermal_load_shedding_policy.dart';
import 'vanguard_media_engine.dart' show VGThermalMonitor, VGThermalState;

export 'vg_camera2_thermal_load_shedding_policy.dart';

/// Immutable representation of current camera recording and session configuration.
@immutable
class VGCamera2ThermalSessionState {
  const VGCamera2ThermalSessionState({
    this.wasRecording = false,
    this.hadSecondaryCamera = false,
    this.currentFps = 30,
    this.currentResolutionScale = 1.0,
    this.canPreserveEncoderContract = true,
  });

  /// Whether a video recording is actively in progress.
  final bool wasRecording;

  /// Whether a secondary (e.g. concurrent dual) camera stream is active.
  final bool hadSecondaryCamera;

  /// Current operating capture frame rate in FPS (>= 1).
  final int currentFps;

  /// Current resolution scale relative to initial configuration (> 0.0).
  final double currentResolutionScale;

  /// Whether the video encoder output contract (e.g. container track format/dimensions)
  /// can be safely preserved during mid-stream load shedding.
  final bool canPreserveEncoderContract;

  /// Creates a normalized copy with safety bounds applied (fps >= 1, resolutionScale > 0.0).
  static VGCamera2ThermalSessionState normalized({
    bool wasRecording = false,
    bool hadSecondaryCamera = false,
    int currentFps = 30,
    double currentResolutionScale = 1.0,
    bool canPreserveEncoderContract = true,
  }) {
    final safeFps = currentFps < 1 ? 1 : currentFps;
    final safeResolution = currentResolutionScale <= 0.0
        ? 1.0
        : currentResolutionScale;
    return VGCamera2ThermalSessionState(
      wasRecording: wasRecording,
      hadSecondaryCamera: hadSecondaryCamera,
      currentFps: safeFps,
      currentResolutionScale: safeResolution,
      canPreserveEncoderContract: canPreserveEncoderContract,
    );
  }

  /// Returns a copy of this session state with the given fields replaced.
  VGCamera2ThermalSessionState copyWith({
    bool? wasRecording,
    bool? hadSecondaryCamera,
    int? currentFps,
    double? currentResolutionScale,
    bool? canPreserveEncoderContract,
  }) {
    final newFps = currentFps ?? this.currentFps;
    final newResolution = currentResolutionScale ?? this.currentResolutionScale;
    return VGCamera2ThermalSessionState(
      wasRecording: wasRecording ?? this.wasRecording,
      hadSecondaryCamera: hadSecondaryCamera ?? this.hadSecondaryCamera,
      currentFps: newFps < 1 ? 1 : newFps,
      currentResolutionScale: newResolution <= 0.0 ? 1.0 : newResolution,
      canPreserveEncoderContract:
          canPreserveEncoderContract ?? this.canPreserveEncoderContract,
    );
  }

  /// Converts this session state into a [VGCamera2ThermalLoadSheddingInput] for evaluation.
  VGCamera2ThermalLoadSheddingInput toInput(VGThermalState thermalState) {
    return VGCamera2ThermalLoadSheddingInput(
      thermalState: thermalState,
      wasRecording: wasRecording,
      hadSecondaryCamera: hadSecondaryCamera,
      currentFps: currentFps,
      currentResolutionScale: currentResolutionScale,
      canPreserveEncoderContract: canPreserveEncoderContract,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'wasRecording': wasRecording,
      'hadSecondaryCamera': hadSecondaryCamera,
      'currentFps': currentFps,
      'currentResolutionScale': currentResolutionScale,
      'canPreserveEncoderContract': canPreserveEncoderContract,
    };
  }

  Map<String, Object?> toJson() => toMap();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ThermalSessionState &&
        other.wasRecording == wasRecording &&
        other.hadSecondaryCamera == hadSecondaryCamera &&
        other.currentFps == currentFps &&
        other.currentResolutionScale == currentResolutionScale &&
        other.canPreserveEncoderContract == canPreserveEncoderContract;
  }

  @override
  int get hashCode => Object.hash(
    wasRecording,
    hadSecondaryCamera,
    currentFps,
    currentResolutionScale,
    canPreserveEncoderContract,
  );

  @override
  String toString() =>
      'VGCamera2ThermalSessionState('
      'wasRecording: $wasRecording, '
      'hadSecondaryCamera: $hadSecondaryCamera, '
      'currentFps: $currentFps, '
      'currentResolutionScale: $currentResolutionScale, '
      'canPreserveEncoderContract: $canPreserveEncoderContract)';
}

/// Immutable configuration options for [VGCamera2ThermalLoadSheddingMonitor].
@immutable
class VGCamera2ThermalLoadSheddingMonitorConfig {
  /// Maximum number of historical evaluations retained in bounded FIFO order. Defaults to 16.
  final int maxHistoryLength;

  /// Whether adjacent duplicate thermal state events from the input stream are suppressed.
  /// Defaults to true.
  final bool suppressDuplicateThermalStates;

  /// Initial camera recording and session configuration state.
  final VGCamera2ThermalSessionState initialSessionState;

  VGCamera2ThermalLoadSheddingMonitorConfig({
    this.maxHistoryLength = 16,
    this.suppressDuplicateThermalStates = true,
    this.initialSessionState = const VGCamera2ThermalSessionState(),
  }) {
    if (maxHistoryLength <= 0) {
      throw ArgumentError.value(
        maxHistoryLength,
        'maxHistoryLength',
        'must be greater than 0',
      );
    }
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'maxHistoryLength': maxHistoryLength,
      'suppressDuplicateThermalStates': suppressDuplicateThermalStates,
      'initialSessionState': initialSessionState.toMap(),
    };
  }

  Map<String, Object?> toJson() => toMap();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ThermalLoadSheddingMonitorConfig &&
        other.maxHistoryLength == maxHistoryLength &&
        other.suppressDuplicateThermalStates ==
            suppressDuplicateThermalStates &&
        other.initialSessionState == initialSessionState;
  }

  @override
  int get hashCode => Object.hash(
    maxHistoryLength,
    suppressDuplicateThermalStates,
    initialSessionState,
  );

  @override
  String toString() =>
      'VGCamera2ThermalLoadSheddingMonitorConfig('
      'maxHistoryLength: $maxHistoryLength, '
      'suppressDuplicateThermalStates: $suppressDuplicateThermalStates, '
      'initialSessionState: $initialSessionState)';
}

/// Immutable advisory evaluation snapshot produced by [VGCamera2ThermalLoadSheddingMonitor].
@immutable
class VGCamera2ThermalLoadSheddingEvaluation {
  const VGCamera2ThermalLoadSheddingEvaluation({
    required this.sequence,
    required this.thermalState,
    required this.input,
    required this.plan,
    required this.historyLength,
    this.advisoryOnly = true,
    this.cameraSessionMutated = false,
    this.captureRequestUpdated = false,
    this.rendererTouched = false,
    this.encoderTouched = false,
    required this.diagnostics,
  });

  /// Monotonically increasing sequence number for this evaluation (1-indexed).
  final int sequence;

  /// The observed device thermal state triggering this evaluation.
  final VGThermalState thermalState;

  /// The evaluated input session parameters.
  final VGCamera2ThermalLoadSheddingInput input;

  /// The deterministic load-shedding mitigation plan generated by the planner.
  final VGCamera2ThermalLoadSheddingPlan plan;

  /// Number of historical evaluation snapshots retained in bounded history.
  final int historyLength;

  /// Invariant: always `true` (pure advisory; zero native or session mutation).
  final bool advisoryOnly;

  /// Invariant: always `false` (zero Camera2 session mutation).
  final bool cameraSessionMutated;

  /// Invariant: always `false` (zero capture request update).
  final bool captureRequestUpdated;

  /// Invariant: always `false` (zero renderer manipulation).
  final bool rendererTouched;

  /// Invariant: always `false` (zero encoder manipulation).
  final bool encoderTouched;

  /// Telemetry diagnostics dictionary for verification and logging.
  final Map<String, Object?> diagnostics;

  /// Recommended mitigation decision.
  VGCamera2ThermalLoadSheddingDecision get decision => plan.decision;

  /// Reason codes explaining the decision.
  List<String> get reasons => plan.reasons;

  /// Whether Dart / application layer must be notified of this thermal change.
  bool get notifyDart => plan.notifyDart;

  /// Whether the mitigation action must be executed strictly at a safe graph boundary.
  bool get requiresSafeGraphBoundary => plan.requiresSafeGraphBoundary;

  /// Whether the encoder output contract remains preserved under this plan.
  bool get preservesEncoderContract => plan.preservesEncoderContract;

  /// Whether the secondary camera stream should be dropped.
  bool get shouldDropSecondaryCamera => plan.shouldDropSecondaryCamera;

  /// Whether the active recording should be stopped.
  bool get shouldStopRecording => plan.shouldStopRecording;

  bool get isMaintaining => plan.isMaintaining;
  bool get isMonitoring => plan.isMonitoring;
  bool get isReducingFrameRate => plan.isReducingFrameRate;
  bool get isDroppingSecondaryCamera => plan.isDroppingSecondaryCamera;
  bool get isStoppingRecording => plan.isStoppingRecording;

  int get targetFps => plan.targetFps;
  double get targetResolutionScale => plan.targetResolutionScale;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'sequence': sequence,
      'thermalState': thermalState.name,
      'input': input.toMap(),
      'plan': plan.toMap(),
      'historyLength': historyLength,
      'advisoryOnly': advisoryOnly,
      'cameraSessionMutated': cameraSessionMutated,
      'captureRequestUpdated': captureRequestUpdated,
      'rendererTouched': rendererTouched,
      'encoderTouched': encoderTouched,
      'diagnostics': diagnostics,
    };
  }

  Map<String, Object?> toJson() => toMap();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ThermalLoadSheddingEvaluation &&
        other.sequence == sequence &&
        other.thermalState == thermalState &&
        other.input == input &&
        other.plan == plan &&
        other.historyLength == historyLength &&
        other.advisoryOnly == advisoryOnly &&
        other.cameraSessionMutated == cameraSessionMutated &&
        other.captureRequestUpdated == captureRequestUpdated &&
        other.rendererTouched == rendererTouched &&
        other.encoderTouched == encoderTouched &&
        _deepMapEquals(other.diagnostics, diagnostics);
  }

  @override
  int get hashCode => Object.hash(
    sequence,
    thermalState,
    input,
    plan,
    historyLength,
    advisoryOnly,
    cameraSessionMutated,
    captureRequestUpdated,
    rendererTouched,
    encoderTouched,
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
      'VGCamera2ThermalLoadSheddingEvaluation('
      'sequence: $sequence, '
      'thermalState: $thermalState, '
      'decision: ${plan.decision}, '
      'historyLength: $historyLength, '
      'advisoryOnly: $advisoryOnly)';
}

/// Pure Dart reactive coordinator for Android Camera2 thermal load-shedding telemetry.
///
/// Subscribes to thermal state changes (defaulting to [VGThermalMonitor.onThermalStateChanged]),
/// maintains dynamic camera recording session state, bounded history, and evaluates
/// advisory load-shedding plans using [VGCamera2ThermalLoadSheddingPlanner].
///
/// Pure advisory foundation: does NOT mutate real Camera2 sessions, capture requests,
/// renderers, encoders, or product UI.
final class VGCamera2ThermalLoadSheddingMonitor {
  VGCamera2ThermalLoadSheddingMonitor({
    Stream<VGThermalState>? thermalStates,
    VGCamera2ThermalLoadSheddingPlanner? planner,
    VGCamera2ThermalLoadSheddingMonitorConfig? config,
  }) : _thermalStates = thermalStates ?? VGThermalMonitor.onThermalStateChanged,
       _planner = planner ?? const VGCamera2ThermalLoadSheddingPlanner(),
       _config = config ?? VGCamera2ThermalLoadSheddingMonitorConfig(),
       _sessionState = (config ?? VGCamera2ThermalLoadSheddingMonitorConfig())
           .initialSessionState;

  static const String proofBoundary =
      'thermal_load_shedding_monitor_advisory_no_camera_session_mutation';

  static const Map<String, bool> nonClaims = <String, bool>{
    'cameraSessionMutated': false,
    'captureRequestUpdated': false,
    'cameraOpened': false,
    'rendererTouched': false,
    'encoderTouched': false,
    'realForcedOverheat': false,
  };

  final Stream<VGThermalState> _thermalStates;
  final VGCamera2ThermalLoadSheddingPlanner _planner;
  final VGCamera2ThermalLoadSheddingMonitorConfig _config;

  final StreamController<VGCamera2ThermalLoadSheddingEvaluation>
  _evaluationsController =
      StreamController<VGCamera2ThermalLoadSheddingEvaluation>.broadcast();

  StreamSubscription<VGThermalState>? _subscription;
  final List<VGCamera2ThermalLoadSheddingEvaluation> _history =
      <VGCamera2ThermalLoadSheddingEvaluation>[];

  VGCamera2ThermalSessionState _sessionState;
  VGCamera2ThermalLoadSheddingEvaluation? _latest;
  VGThermalState? _lastObservedThermalState;
  int _sequenceCounter = 0;
  bool _isDisposed = false;
  String? _lastStreamError;

  /// Broadcast stream of evaluated [VGCamera2ThermalLoadSheddingEvaluation] snapshots.
  Stream<VGCamera2ThermalLoadSheddingEvaluation> get evaluations =>
      _evaluationsController.stream;

  /// Most recently evaluated load-shedding snapshot, or `null` if none evaluated yet.
  VGCamera2ThermalLoadSheddingEvaluation? get latest => _latest;

  /// Unmodifiable view of historical evaluations retained in FIFO order.
  List<VGCamera2ThermalLoadSheddingEvaluation> get history =>
      List<VGCamera2ThermalLoadSheddingEvaluation>.unmodifiable(_history);

  /// Current number of items in the bounded history window.
  int get historyLength => _history.length;

  /// Whether the monitor is actively subscribed to the input thermal state stream.
  bool get isRunning => _subscription != null;

  /// Whether this monitor has been disposed.
  bool get isDisposed => _isDisposed;

  /// Last error string observed on the input thermal state stream, if any.
  String? get lastStreamError => _lastStreamError;

  /// Current session parameters used for subsequent evaluations.
  VGCamera2ThermalSessionState get sessionState => _sessionState;

  /// Active monitor configuration.
  VGCamera2ThermalLoadSheddingMonitorConfig get config => _config;

  /// Active policy planner.
  VGCamera2ThermalLoadSheddingPlanner get planner => _planner;

  /// Updates current camera recording and session parameters.
  ///
  /// Clamps/normalizes values (e.g. currentFps >= 1, currentResolutionScale > 0.0).
  void updateSessionState({
    bool? wasRecording,
    bool? hadSecondaryCamera,
    int? currentFps,
    double? currentResolutionScale,
    bool? canPreserveEncoderContract,
  }) {
    if (_isDisposed) return;
    _sessionState = _sessionState.copyWith(
      wasRecording: wasRecording,
      hadSecondaryCamera: hadSecondaryCamera,
      currentFps: currentFps,
      currentResolutionScale: currentResolutionScale,
      canPreserveEncoderContract: canPreserveEncoderContract,
    );
  }

  /// Starts listening to thermal state changes.
  ///
  /// Idempotent. If already running or disposed, this is a no-op.
  void start() {
    if (_isDisposed || isRunning) {
      return;
    }
    _subscription = _thermalStates.listen(
      (state) {
        if (_isDisposed) return;
        if (_config.suppressDuplicateThermalStates &&
            state == _lastObservedThermalState) {
          return;
        }
        evaluateOnce(state);
      },
      onError: (Object error, StackTrace stackTrace) {
        _lastStreamError = error.toString();
      },
      cancelOnError: false,
    );
  }

  /// Idempotently stops listening to the thermal state stream without closing the output stream.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// Idempotently stops listening and closes the output evaluations stream.
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    stop();
    await _evaluationsController.close();
  }

  /// Evaluates a single [VGThermalState] using current session state immediately,
  /// records bounded FIFO history, updates [latest], emits to [evaluations] unless disposed,
  /// and returns the evaluation.
  ///
  /// If disposed, returns [latest] if available or a deterministic nominal fallback
  /// without emitting to the stream.
  VGCamera2ThermalLoadSheddingEvaluation evaluateOnce(VGThermalState state) {
    if (_isDisposed) {
      if (_latest != null) {
        return _latest!;
      }
      final input = _sessionState.toInput(state);
      final plan = _planner.evaluateInput(input);
      final fallbackDiagnostics = <String, Object?>{
        'proofBoundary': proofBoundary,
        'policyProofBoundary':
            VGCamera2ThermalLoadSheddingPlanner.proofBoundary,
        'disposed': true,
        'isRunning': false,
        'isDisposed': true,
        'historyLength': _history.length,
        'nonClaims': Map<String, bool>.from(nonClaims),
      };
      return VGCamera2ThermalLoadSheddingEvaluation(
        sequence: _sequenceCounter,
        thermalState: state,
        input: input,
        plan: plan,
        historyLength: _history.length,
        advisoryOnly: true,
        cameraSessionMutated: false,
        captureRequestUpdated: false,
        rendererTouched: false,
        encoderTouched: false,
        diagnostics: Map<String, Object?>.unmodifiable(fallbackDiagnostics),
      );
    }

    _sequenceCounter++;
    _lastObservedThermalState = state;

    final input = _sessionState.toInput(state);
    final plan = _planner.evaluateInput(input);

    final nextHistoryLength = _history.length + 1 > _config.maxHistoryLength
        ? _config.maxHistoryLength
        : _history.length + 1;

    final diagnostics = <String, Object?>{
      'proofBoundary': proofBoundary,
      'policyProofBoundary': VGCamera2ThermalLoadSheddingPlanner.proofBoundary,
      'sequence': _sequenceCounter,
      'thermalState': state.name,
      'decision': plan.decision.name,
      'historyLength': nextHistoryLength,
      'maxHistoryLength': _config.maxHistoryLength,
      'suppressDuplicateThermalStates': _config.suppressDuplicateThermalStates,
      'isRunning': isRunning,
      'isDisposed': _isDisposed,
      'wasRecording': _sessionState.wasRecording,
      'hadSecondaryCamera': _sessionState.hadSecondaryCamera,
      'currentFps': _sessionState.currentFps,
      'currentResolutionScale': _sessionState.currentResolutionScale,
      'canPreserveEncoderContract': _sessionState.canPreserveEncoderContract,
      'nonClaims': Map<String, bool>.from(nonClaims),
      if (_lastStreamError != null) 'lastStreamError': _lastStreamError,
    };

    final evaluation = VGCamera2ThermalLoadSheddingEvaluation(
      sequence: _sequenceCounter,
      thermalState: state,
      input: input,
      plan: plan,
      historyLength: nextHistoryLength,
      advisoryOnly: true,
      cameraSessionMutated: false,
      captureRequestUpdated: false,
      rendererTouched: false,
      encoderTouched: false,
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
    );

    _history.add(evaluation);
    while (_history.length > _config.maxHistoryLength) {
      _history.removeAt(0);
    }

    _latest = evaluation;

    if (!_isDisposed && !_evaluationsController.isClosed) {
      _evaluationsController.add(evaluation);
    }

    return evaluation;
  }

  @override
  String toString() =>
      'VGCamera2ThermalLoadSheddingMonitor('
      'isRunning=$isRunning, '
      'isDisposed=$isDisposed, '
      'historyLength=${_history.length}, '
      'latest=$_latest)';
}
