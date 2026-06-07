// vg_camera_session.dart
// Vanguard Media Engine — Phase 6D.1A
//
// VGCameraSession is a thin value object that wraps the native camera
// method channel surface behind a typed, lifecycle-managed session object.
//
// Design constraints honoured:
//   C-pattern — mirrors VGPlaybackSession exactly:
//     thin value object, sessionId + textureId, idempotent dispose, _disposed guard.
//   C-native  — calls the same 'vanguard_media_engine' method channel endpoints
//     as VanguardEngine static camera methods. No new native surface added.
//   C-coexist — VanguardEngine.startCamera() is not modified. Both paths can
//     coexist because the native plugin handles startCamera→startCamera transitions
//     (tears down the previous source before creating a new one).
//   C-agnostic — zero references to any Connects feature surface.
//
// Creation:
//   final session = await VGCameraSession.create(position: VGCameraPosition.back);
//   // Display with: VGCameraPreview(session: session)
//   // or raw:       Texture(textureId: session.textureId)
//
// Disposal:
//   await session.dispose(); // calls 'stopCamera'; idempotent.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'vg_camera_zoom_capabilities.dart';
import 'vg_filter_spec.dart';
import 'vg_graph_transaction.dart';
import 'vg_recording_stats.dart';
import 'vg_photo_capture_result.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────────────────────────────────────

/// Physical camera sensor position.
enum VGCameraPosition {
  /// Rear-facing (world-facing) sensor. Maps to native position int 1.
  back,

  /// Front-facing (self-facing) sensor. Maps to native position int 2.
  front,
}

/// Continuous video torch (light) mode.
///
/// Controls the hardware torch, not the photo flash.
/// Not all devices or sensors support a torch (e.g. most front cameras).
/// Native side silently no-ops when the device has no torch.
enum VGTorchMode {
  /// Torch off. Maps to native string 'off'.
  off,

  /// Torch on. Maps to native string 'on'.
  on,
}

// ─────────────────────────────────────────────────────────────────────────────
// VGCameraSession
// ─────────────────────────────────────────────────────────────────────────────

/// A single active camera session backed by the native AVCaptureSession pipeline.
///
/// Obtain instances via [VGCameraSession.create].
/// Call [dispose] when done to release the hardware camera.
///
/// ## Preview
/// Display the live camera feed with [VGCameraPreview] or with the raw Flutter
/// `Texture` widget:
/// ```dart
/// Texture(textureId: session.textureId)
/// ```
///
/// ## Native MTKView overlay
/// For a fullscreen Metal-rendered overlay, call [openNativePreview]. This
/// presents a native view controller that owns orientation decisions.
/// Dismiss it with [closeNativePreview].
///
/// ## Coexistence with VanguardEngine static API
/// [VGCameraSession.create] calls the same `startCamera` native endpoint as
/// `VanguardEngine.startCamera()`. Both paths cannot be active simultaneously —
/// calling one while the other is active will cause the native side to tear
/// down the previous session before starting a new one. This is the same
/// behaviour as calling `VanguardEngine.startCamera()` twice.

// ─────────────────────────────────────────────────────────────────────────────
// MC-3: VGMultiCamCostReport
// ─────────────────────────────────────────────────────────────────────────────

/// Reports the ISP bandwidth cost of a configured (non-running)
/// `AVCaptureMultiCamSession` for a given front/back device pair.
///
/// Produced by [VGCameraSession.measureMultiCamHardwareCost].
///
/// ## Fields
/// - [hardwareCost]: The fraction of the hardware ISP bandwidth budget consumed
///   by this configuration (0.0–1.0+). Must be ≤ 1.0 for the session to be
///   runnable.
/// - [isWithinBudget]: `true` if [hardwareCost] ≤ 1.0.
///
/// ## Note on systemPressureCost
/// `systemPressureCost` is intentionally excluded. It reflects runtime thermal
/// and power factors and is only meaningful on a running session (MC-4+).
@immutable
class VGMultiCamCostReport {
  const VGMultiCamCostReport({
    required this.hardwareCost,
    required this.isWithinBudget,
  });

  /// ISP bandwidth cost in the range 0.0–1.0+.
  /// Must be ≤ 1.0 for the session to be capable of running.
  final double hardwareCost;

  /// `true` if [hardwareCost] ≤ 1.0, meaning the session configuration is
  /// within the hardware bandwidth budget.
  final bool isWithinBudget;

  /// Parses a [VGMultiCamCostReport] from the native channel response map.
  ///
  /// Returns `null` if [map] is `null` or does not contain a valid
  /// `hardwareCost` numeric value.
  static VGMultiCamCostReport? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final rawCost = map['hardwareCost'];
    if (rawCost == null) return null;
    final double cost;
    if (rawCost is double) {
      cost = rawCost;
    } else if (rawCost is int) {
      cost = rawCost.toDouble();
    } else {
      return null;
    }
    // Prefer the native isWithinBudget if present; compute locally as fallback.
    final rawBudget = map['isWithinBudget'];
    final bool withinBudget;
    if (rawBudget is bool) {
      withinBudget = rawBudget;
    } else {
      withinBudget = cost <= 1.0;
    }
    return VGMultiCamCostReport(
      hardwareCost: cost,
      isWithinBudget: withinBudget,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGMultiCamCostReport &&
          runtimeType == other.runtimeType &&
          hardwareCost == other.hardwareCost &&
          isWithinBudget == other.isWithinBudget;

  @override
  int get hashCode => Object.hash(hardwareCost, isWithinBudget);

  @override
  String toString() =>
      'VGMultiCamCostReport(hardwareCost: $hardwareCost, '
      'isWithinBudget: $isWithinBudget)';
}

// ─────────────────────────────────────────────────────────────────────────────
// MC-4: VGMultiCamStreamingReport
// ─────────────────────────────────────────────────────────────────────────────

/// Reports the results of a live 3-second `AVCaptureMultiCamSession` streaming
/// diagnostic for a given front/back device pair.
///
/// Produced by [VGCameraSession.runMultiCamStreamingDiagnostic].
///
/// ## Fields
/// - [frontFramesReceived]: Count of sample-buffer callbacks from the front camera.
/// - [backFramesReceived]: Count of sample-buffer callbacks from the back camera.
/// - [peakSystemPressureCost]: Maximum `systemPressureCost` sampled while the
///   session was running. 0.0 if no frames were delivered. Values > 1.0 indicate
///   unsustainable thermal/power load.
/// - [hardwareCost]: ISP bandwidth cost fraction re-read from the running session.
///   Should closely match the MC-3 reading. Values > 1.0 mean the session cannot
///   sustain.
/// - [durationSeconds]: Actual elapsed time of the diagnostic window in seconds.
///
/// ## Derived properties
/// - [frontFPS]: `frontFramesReceived / durationSeconds`
/// - [backFPS]: `backFramesReceived / durationSeconds`
@immutable
class VGMultiCamStreamingReport {
  const VGMultiCamStreamingReport({
    required this.frontFramesReceived,
    required this.backFramesReceived,
    required this.peakSystemPressureCost,
    required this.hardwareCost,
    required this.durationSeconds,
  });

  /// Number of sample-buffer delegate callbacks from the front camera.
  final int frontFramesReceived;

  /// Number of sample-buffer delegate callbacks from the back camera.
  final int backFramesReceived;

  /// Peak `systemPressureCost` observed while the session was running.
  /// 0.0 if no frames were delivered. Values > 1.0 indicate unsustainable load.
  final double peakSystemPressureCost;

  /// ISP bandwidth cost re-read from the running (or configured) session.
  /// Should match the MC-3 `hardwareCost` reading closely.
  final double hardwareCost;

  /// Actual elapsed duration of the diagnostic window, in seconds.
  final double durationSeconds;

  /// Estimated front camera frame rate in frames per second.
  ///
  /// Returns 0.0 if [durationSeconds] is 0.
  double get frontFPS =>
      durationSeconds > 0 ? frontFramesReceived / durationSeconds : 0.0;

  /// Estimated back camera frame rate in frames per second.
  ///
  /// Returns 0.0 if [durationSeconds] is 0.
  double get backFPS =>
      durationSeconds > 0 ? backFramesReceived / durationSeconds : 0.0;

  /// Parses a [VGMultiCamStreamingReport] from the native channel response map.
  ///
  /// Returns `null` if [map] is `null` or any required numeric field is absent
  /// or of an unexpected type.
  static VGMultiCamStreamingReport? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;

    // frontFramesReceived — required int
    final rawFront = map['frontFramesReceived'];
    if (rawFront == null) return null;
    final int frontFrames;
    if (rawFront is int) {
      frontFrames = rawFront;
    } else if (rawFront is double) {
      frontFrames = rawFront.toInt();
    } else {
      return null;
    }

    // backFramesReceived — required int
    final rawBack = map['backFramesReceived'];
    if (rawBack == null) return null;
    final int backFrames;
    if (rawBack is int) {
      backFrames = rawBack;
    } else if (rawBack is double) {
      backFrames = rawBack.toInt();
    } else {
      return null;
    }

    // peakSystemPressureCost — required double
    final rawPeak = map['peakSystemPressureCost'];
    if (rawPeak == null) return null;
    final double peakPressure;
    if (rawPeak is double) {
      peakPressure = rawPeak;
    } else if (rawPeak is int) {
      peakPressure = rawPeak.toDouble();
    } else {
      return null;
    }

    // hardwareCost — required double
    final rawHW = map['hardwareCost'];
    if (rawHW == null) return null;
    final double hw;
    if (rawHW is double) {
      hw = rawHW;
    } else if (rawHW is int) {
      hw = rawHW.toDouble();
    } else {
      return null;
    }

    // durationSeconds — required double
    final rawDuration = map['durationSeconds'];
    if (rawDuration == null) return null;
    final double duration;
    if (rawDuration is double) {
      duration = rawDuration;
    } else if (rawDuration is int) {
      duration = rawDuration.toDouble();
    } else {
      return null;
    }

    return VGMultiCamStreamingReport(
      frontFramesReceived: frontFrames,
      backFramesReceived: backFrames,
      peakSystemPressureCost: peakPressure,
      hardwareCost: hw,
      durationSeconds: duration,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGMultiCamStreamingReport &&
          runtimeType == other.runtimeType &&
          frontFramesReceived == other.frontFramesReceived &&
          backFramesReceived == other.backFramesReceived &&
          peakSystemPressureCost == other.peakSystemPressureCost &&
          hardwareCost == other.hardwareCost &&
          durationSeconds == other.durationSeconds;

  @override
  int get hashCode => Object.hash(
        frontFramesReceived,
        backFramesReceived,
        peakSystemPressureCost,
        hardwareCost,
        durationSeconds,
      );

  @override
  String toString() =>
      'VGMultiCamStreamingReport('
      'frontFramesReceived: $frontFramesReceived, '
      'backFramesReceived: $backFramesReceived, '
      'frontFPS: ${frontFPS.toStringAsFixed(1)}, '
      'backFPS: ${backFPS.toStringAsFixed(1)}, '
      'peakSystemPressureCost: $peakSystemPressureCost, '
      'hardwareCost: $hardwareCost, '
      'durationSeconds: $durationSeconds)';
}

// ─────────────────────────────────────────────────────────────────────────────
// MC-5: VGMultiCamSyncReport
// ─────────────────────────────────────────────────────────────────────────────

/// Reports the results of a live 3-second MultiCam software timestamp-pairing
/// diagnostic for a given front/back device pair.
///
/// Produced by [VGCameraSession.runMultiCamSyncDiagnostic].
///
/// ## Purpose
/// MC-4 ([VGMultiCamStreamingReport]) proved independent per-camera frame
/// delivery. MC-5 extends that by measuring how closely the independent
/// front and back frames are temporally aligned. A software nearest-neighbour
/// algorithm pairs each newly arrived frame with the most recent unmatched
/// frame from the other camera if their PTS difference is within
/// [pairingThresholdSeconds] (1/30 s ≈ 33.3 ms).
///
/// ## Why not AVCaptureDataOutputSynchronizer?
/// Physical-device testing confirmed that `AVCaptureDataOutputSynchronizer`
/// produces zero paired frames for independent front/back cameras:
/// `alwaysDiscardsLateVideoFrames` (honored by the synchronizer per Apple docs)
/// causes the secondary camera's frames to be discarded before pairing. MC-5
/// therefore uses independent `setSampleBufferDelegate` callbacks on a shared
/// serial queue, matching the proven MC-4 approach.
///
/// ## Fields
/// - [pairedFramesReceived]: Frames software-paired within [pairingThresholdSeconds].
/// - [frontFramesReceived]: Total front frames delivered by AVFoundation.
/// - [backFramesReceived]: Total back frames delivered by AVFoundation.
/// - [unmatchedFrontFrames]: Front frames that expired without a back partner.
/// - [unmatchedBackFrames]: Back frames that expired without a front partner.
/// - [maxDriftSeconds]: Peak |frontPTS − backPTS| across all paired frames.
/// - [averageDriftSeconds]: Mean |frontPTS − backPTS| across all paired frames.
/// - [peakSystemPressureCost]: Maximum `systemPressureCost` while running.
/// - [hardwareCost]: ISP bandwidth cost read from the configured session.
/// - [durationSeconds]: Actual elapsed time of the diagnostic window.
/// - [pairingThresholdSeconds]: The threshold used for pairing (1/30 s).
///
/// ## Derived properties
/// - [pairedFPS]: `pairedFramesReceived / durationSeconds`
/// - [maxDriftMilliseconds]: `maxDriftSeconds * 1000.0`
/// - [averageDriftMilliseconds]: `averageDriftSeconds * 1000.0`
/// - [pairingThresholdMilliseconds]: `pairingThresholdSeconds * 1000.0`
@immutable
class VGMultiCamSyncReport {
  const VGMultiCamSyncReport({
    required this.pairedFramesReceived,
    required this.frontFramesReceived,
    required this.backFramesReceived,
    required this.unmatchedFrontFrames,
    required this.unmatchedBackFrames,
    required this.maxDriftSeconds,
    required this.averageDriftSeconds,
    required this.peakSystemPressureCost,
    required this.hardwareCost,
    required this.durationSeconds,
    required this.pairingThresholdSeconds,
    // MC-8 optional fields — default to safe values for MC-5/MC-7 maps
    this.delegatePairedFramesReceived = 0,
    this.frontBufferWidth = 0,
    this.frontBufferHeight = 0,
    this.backBufferWidth = 0,
    this.backBufferHeight = 0,
    this.buffersValid = false,
  });

  /// Frames software-paired within [pairingThresholdSeconds].
  final int pairedFramesReceived;

  /// Total front frames delivered by AVFoundation during the run window.
  final int frontFramesReceived;

  /// Total back frames delivered by AVFoundation during the run window.
  final int backFramesReceived;

  /// Front frames that arrived but found no back partner within the threshold.
  final int unmatchedFrontFrames;

  /// Back frames that arrived but found no front partner within the threshold.
  final int unmatchedBackFrames;

  /// Peak absolute PTS difference between a paired front and back frame,
  /// in seconds. 0.0 if no pairs were received.
  final double maxDriftSeconds;

  /// Mean PTS difference across all paired frames, in seconds.
  /// 0.0 if no pairs were received.
  final double averageDriftSeconds;

  /// Peak `systemPressureCost` observed while the session was running.
  /// Values > 1.0 indicate unsustainable load.
  final double peakSystemPressureCost;

  /// ISP bandwidth cost read from the session after configuration.
  final double hardwareCost;

  /// Actual elapsed duration of the diagnostic window, in seconds.
  final double durationSeconds;

  /// The pairing threshold used by the native algorithm, in seconds.
  /// Fixed at 1/30 s ≈ 33.3 ms.
  final double pairingThresholdSeconds;

  // ── Derived ───────────────────────────────────────────────────────────────

  /// Estimated paired frame rate in frames per second.
  double get pairedFPS =>
      durationSeconds > 0 ? pairedFramesReceived / durationSeconds : 0.0;

  /// Peak PTS drift between front and back cameras, in milliseconds.
  double get maxDriftMilliseconds => maxDriftSeconds * 1000.0;

  /// Mean PTS drift between front and back cameras, in milliseconds.
  double get averageDriftMilliseconds => averageDriftSeconds * 1000.0;

  /// Pairing threshold in milliseconds.
  double get pairingThresholdMilliseconds => pairingThresholdSeconds * 1000.0;

  // ── MC-8 buffer verification fields ──────────────────────────────────────

  /// MC-8: Number of paired frames delivered via the
  /// `VanguardMultiCamMediaSourceDelegate` callback during the diagnostic.
  /// Should equal [pairedFramesReceived] when buffer retention is active.
  /// Defaults to 0 for MC-5/MC-7 reports (field absent from native map).
  final int delegatePairedFramesReceived;

  /// MC-8: Width in pixels of the front-camera buffer from the first valid
  /// paired frame. 0 if no paired frames were delivered.
  final int frontBufferWidth;

  /// MC-8: Height in pixels of the front-camera buffer from the first valid
  /// paired frame. 0 if no paired frames were delivered.
  final int frontBufferHeight;

  /// MC-8: Width in pixels of the back-camera buffer from the first valid
  /// paired frame. 0 if no paired frames were delivered.
  final int backBufferWidth;

  /// MC-8: Height in pixels of the back-camera buffer from the first valid
  /// paired frame. 0 if no paired frames were delivered.
  final int backBufferHeight;

  /// MC-8: `true` if at least one paired frame arrived with non-zero dimensions
  /// on both the front and back buffers. `false` for MC-5/MC-7 reports.
  final bool buffersValid;

  // ── Parsing ───────────────────────────────────────────────────────────────

  /// Parses a [VGMultiCamSyncReport] from the native channel response map.
  ///
  /// Returns `null` if [map] is `null` or any required field is absent or
  /// of an unexpected type.
  static VGMultiCamSyncReport? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;

    // pairedFramesReceived — required int
    final rawPaired = map['pairedFramesReceived'];
    if (rawPaired == null) return null;
    final int paired;
    if (rawPaired is int) {
      paired = rawPaired;
    } else if (rawPaired is double) {
      paired = rawPaired.toInt();
    } else {
      return null;
    }

    // frontFramesReceived — required int
    final rawFront = map['frontFramesReceived'];
    if (rawFront == null) return null;
    final int frontFrames;
    if (rawFront is int) {
      frontFrames = rawFront;
    } else if (rawFront is double) {
      frontFrames = rawFront.toInt();
    } else {
      return null;
    }

    // backFramesReceived — required int
    final rawBack = map['backFramesReceived'];
    if (rawBack == null) return null;
    final int backFrames;
    if (rawBack is int) {
      backFrames = rawBack;
    } else if (rawBack is double) {
      backFrames = rawBack.toInt();
    } else {
      return null;
    }

    // unmatchedFrontFrames — required int
    final rawUnmatchedFront = map['unmatchedFrontFrames'];
    if (rawUnmatchedFront == null) return null;
    final int unmatchedFront;
    if (rawUnmatchedFront is int) {
      unmatchedFront = rawUnmatchedFront;
    } else if (rawUnmatchedFront is double) {
      unmatchedFront = rawUnmatchedFront.toInt();
    } else {
      return null;
    }

    // unmatchedBackFrames — required int
    final rawUnmatchedBack = map['unmatchedBackFrames'];
    if (rawUnmatchedBack == null) return null;
    final int unmatchedBack;
    if (rawUnmatchedBack is int) {
      unmatchedBack = rawUnmatchedBack;
    } else if (rawUnmatchedBack is double) {
      unmatchedBack = rawUnmatchedBack.toInt();
    } else {
      return null;
    }

    // maxDriftSeconds — required double
    final rawMaxDrift = map['maxDriftSeconds'];
    if (rawMaxDrift == null) return null;
    final double maxDrift;
    if (rawMaxDrift is double) {
      maxDrift = rawMaxDrift;
    } else if (rawMaxDrift is int) {
      maxDrift = rawMaxDrift.toDouble();
    } else {
      return null;
    }

    // averageDriftSeconds — required double
    final rawAvgDrift = map['averageDriftSeconds'];
    if (rawAvgDrift == null) return null;
    final double avgDrift;
    if (rawAvgDrift is double) {
      avgDrift = rawAvgDrift;
    } else if (rawAvgDrift is int) {
      avgDrift = rawAvgDrift.toDouble();
    } else {
      return null;
    }

    // peakSystemPressureCost — required double
    final rawPeak = map['peakSystemPressureCost'];
    if (rawPeak == null) return null;
    final double peakPressure;
    if (rawPeak is double) {
      peakPressure = rawPeak;
    } else if (rawPeak is int) {
      peakPressure = rawPeak.toDouble();
    } else {
      return null;
    }

    // hardwareCost — required double
    final rawHW = map['hardwareCost'];
    if (rawHW == null) return null;
    final double hw;
    if (rawHW is double) {
      hw = rawHW;
    } else if (rawHW is int) {
      hw = rawHW.toDouble();
    } else {
      return null;
    }

    // durationSeconds — required double
    final rawDuration = map['durationSeconds'];
    if (rawDuration == null) return null;
    final double duration;
    if (rawDuration is double) {
      duration = rawDuration;
    } else if (rawDuration is int) {
      duration = rawDuration.toDouble();
    } else {
      return null;
    }

    // pairingThresholdSeconds — required double
    final rawThreshold = map['pairingThresholdSeconds'];
    if (rawThreshold == null) return null;
    final double threshold;
    if (rawThreshold is double) {
      threshold = rawThreshold;
    } else if (rawThreshold is int) {
      threshold = rawThreshold.toDouble();
    } else {
      return null;
    }

    return VGMultiCamSyncReport(
      pairedFramesReceived: paired,
      frontFramesReceived: frontFrames,
      backFramesReceived: backFrames,
      unmatchedFrontFrames: unmatchedFront,
      unmatchedBackFrames: unmatchedBack,
      maxDriftSeconds: maxDrift,
      averageDriftSeconds: avgDrift,
      peakSystemPressureCost: peakPressure,
      hardwareCost: hw,
      durationSeconds: duration,
      pairingThresholdSeconds: threshold,
      // MC-8 optional fields — absent in MC-5/MC-7 native maps, default safely.
      delegatePairedFramesReceived: _parseInt(map['delegatePairedFramesReceived']) ?? 0,
      frontBufferWidth:             _parseInt(map['frontBufferWidth'])             ?? 0,
      frontBufferHeight:            _parseInt(map['frontBufferHeight'])            ?? 0,
      backBufferWidth:              _parseInt(map['backBufferWidth'])              ?? 0,
      backBufferHeight:             _parseInt(map['backBufferHeight'])             ?? 0,
      buffersValid:                 map['buffersValid'] as bool?                   ?? false,
    );
  }

  /// Parses an optional int field from a map value (int or double → int).
  /// Returns null if the value is null or is neither int nor double.
  static int? _parseInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is double) return raw.toInt();
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGMultiCamSyncReport &&
          runtimeType == other.runtimeType &&
          pairedFramesReceived == other.pairedFramesReceived &&
          frontFramesReceived == other.frontFramesReceived &&
          backFramesReceived == other.backFramesReceived &&
          unmatchedFrontFrames == other.unmatchedFrontFrames &&
          unmatchedBackFrames == other.unmatchedBackFrames &&
          maxDriftSeconds == other.maxDriftSeconds &&
          averageDriftSeconds == other.averageDriftSeconds &&
          peakSystemPressureCost == other.peakSystemPressureCost &&
          hardwareCost == other.hardwareCost &&
          durationSeconds == other.durationSeconds &&
          pairingThresholdSeconds == other.pairingThresholdSeconds &&
          delegatePairedFramesReceived == other.delegatePairedFramesReceived &&
          frontBufferWidth == other.frontBufferWidth &&
          frontBufferHeight == other.frontBufferHeight &&
          backBufferWidth == other.backBufferWidth &&
          backBufferHeight == other.backBufferHeight &&
          buffersValid == other.buffersValid;

  @override
  int get hashCode => Object.hash(
        pairedFramesReceived,
        frontFramesReceived,
        backFramesReceived,
        unmatchedFrontFrames,
        unmatchedBackFrames,
        maxDriftSeconds,
        averageDriftSeconds,
        peakSystemPressureCost,
        hardwareCost,
        durationSeconds,
        pairingThresholdSeconds,
        delegatePairedFramesReceived,
        frontBufferWidth,
        frontBufferHeight,
        backBufferWidth,
        backBufferHeight,
        buffersValid,
      );

  @override
  String toString() =>
      'VGMultiCamSyncReport('
      'pairedFramesReceived: $pairedFramesReceived, '
      'frontFramesReceived: $frontFramesReceived, '
      'backFramesReceived: $backFramesReceived, '
      'unmatchedFrontFrames: $unmatchedFrontFrames, '
      'unmatchedBackFrames: $unmatchedBackFrames, '
      'pairedFPS: ${pairedFPS.toStringAsFixed(1)}, '
      'maxDriftMs: ${maxDriftMilliseconds.toStringAsFixed(3)}, '
      'avgDriftMs: ${averageDriftMilliseconds.toStringAsFixed(3)}, '
      'pairingThresholdMs: ${pairingThresholdMilliseconds.toStringAsFixed(2)}, '
      'peakSystemPressureCost: $peakSystemPressureCost, '
      'hardwareCost: $hardwareCost, '
      'durationSeconds: $durationSeconds, '
      'delegatePairedFramesReceived: $delegatePairedFramesReceived, '
      'frontBuffer: ${frontBufferWidth}x${frontBufferHeight}, '
      'backBuffer: ${backBufferWidth}x${backBufferHeight}, '
      'buffersValid: $buffersValid)';
}

// ─────────────────────────────────────────────────────────────────────────────
// MC-9: VGMultiCamRenderReport
// ─────────────────────────────────────────────────────────────────────────────

/// Reports the results of a 3-second offscreen MultiCam render diagnostic.
///
/// Produced by [VGCameraSession.runMultiCamRenderDiagnostic].
///
/// ## Purpose
/// MC-9 proves that real-time CoreImage offscreen composition of two 1080p
/// camera streams (~26–30 fps) is feasible within the device's thermal and
/// memory budget, before any Flutter texture integration (MC-10+).
///
/// ## Fields — render metrics
/// - [renderedFrames]: Frames successfully composited into the output pool.
/// - [droppedRenderFrames]: Frames dropped because the renderQ was busy.
/// - [averageRenderMs]: Mean CoreImage render time per composited frame (ms).
/// - [peakRenderMs]: Worst-case render time for any single frame (ms).
/// - [outputWidth]: Width of the output composite buffer (pixels).
/// - [outputHeight]: Height of the output composite buffer (pixels).
///
/// ## Fields — capture-side metrics (from VanguardMultiCamMediaSource)
/// - [pairedFramesReceived]: Frames software-paired within the threshold.
/// - [frontFramesReceived]: Total front frames delivered by AVFoundation.
/// - [backFramesReceived]: Total back frames delivered by AVFoundation.
/// - [peakSystemPressureCost]: Maximum systemPressureCost while running.
/// - [hardwareCost]: ISP bandwidth cost after session configuration.
/// - [durationSeconds]: Elapsed time of the diagnostic window.
///
/// ## Derived properties
/// - [renderedFPS]: `renderedFrames / durationSeconds`
@immutable
class VGMultiCamRenderReport {
  const VGMultiCamRenderReport({
    required this.renderedFrames,
    required this.droppedRenderFrames,
    required this.averageRenderMs,
    required this.peakRenderMs,
    required this.outputWidth,
    required this.outputHeight,
    required this.pairedFramesReceived,
    required this.frontFramesReceived,
    required this.backFramesReceived,
    required this.peakSystemPressureCost,
    required this.hardwareCost,
    required this.durationSeconds,
  });

  // ── Render metrics ────────────────────────────────────────────────────────

  /// Frames successfully composited into the output CVPixelBuffer pool.
  final int renderedFrames;

  /// Frames dropped because the render queue was busy with the previous frame.
  final int droppedRenderFrames;

  /// Mean CoreImage render time per composited frame, in milliseconds.
  final double averageRenderMs;

  /// Peak (worst-case) CoreImage render time for any single frame, in ms.
  final double peakRenderMs;

  /// Width of the output composite buffer in pixels.
  /// 0 if no frames were rendered.
  final int outputWidth;

  /// Height of the output composite buffer in pixels.
  /// 0 if no frames were rendered.
  final int outputHeight;

  // ── Capture-side metrics ──────────────────────────────────────────────────

  /// Frames software-paired within the pairing threshold.
  final int pairedFramesReceived;

  /// Total front frames delivered by AVFoundation.
  final int frontFramesReceived;

  /// Total back frames delivered by AVFoundation.
  final int backFramesReceived;

  /// Peak systemPressureCost observed while the session was running.
  final double peakSystemPressureCost;

  /// ISP bandwidth cost read from the session after configuration.
  final double hardwareCost;

  /// Elapsed duration of the diagnostic window in seconds.
  final double durationSeconds;

  // ── Derived ───────────────────────────────────────────────────────────────

  /// Estimated rendered frame rate in frames per second.
  double get renderedFPS =>
      durationSeconds > 0 ? renderedFrames / durationSeconds : 0.0;

  // ── Parsing ───────────────────────────────────────────────────────────────

  /// Parses a [VGMultiCamRenderReport] from the native channel response map.
  ///
  /// Returns `null` if [map] is `null` or any required field is absent or
  /// of an unexpected type. Handles int-to-double coercion for timing fields.
  static VGMultiCamRenderReport? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;

    // renderedFrames — required int
    final int? rendered = _parseInt(map['renderedFrames']);
    if (rendered == null) return null;

    // droppedRenderFrames — required int
    final int? dropped = _parseInt(map['droppedRenderFrames']);
    if (dropped == null) return null;

    // averageRenderMs — required double
    final double? avgRender = _parseDouble(map['averageRenderMs']);
    if (avgRender == null) return null;

    // peakRenderMs — required double
    final double? peakRender = _parseDouble(map['peakRenderMs']);
    if (peakRender == null) return null;

    // outputWidth — required int
    final int? outW = _parseInt(map['outputWidth']);
    if (outW == null) return null;

    // outputHeight — required int
    final int? outH = _parseInt(map['outputHeight']);
    if (outH == null) return null;

    // pairedFramesReceived — required int
    final int? paired = _parseInt(map['pairedFramesReceived']);
    if (paired == null) return null;

    // frontFramesReceived — required int
    final int? frontFrames = _parseInt(map['frontFramesReceived']);
    if (frontFrames == null) return null;

    // backFramesReceived — required int
    final int? backFrames = _parseInt(map['backFramesReceived']);
    if (backFrames == null) return null;

    // peakSystemPressureCost — required double
    final double? peakPressure = _parseDouble(map['peakSystemPressureCost']);
    if (peakPressure == null) return null;

    // hardwareCost — required double
    final double? hw = _parseDouble(map['hardwareCost']);
    if (hw == null) return null;

    // durationSeconds — required double
    final double? duration = _parseDouble(map['durationSeconds']);
    if (duration == null) return null;

    return VGMultiCamRenderReport(
      renderedFrames:       rendered,
      droppedRenderFrames:  dropped,
      averageRenderMs:      avgRender,
      peakRenderMs:         peakRender,
      outputWidth:          outW,
      outputHeight:         outH,
      pairedFramesReceived: paired,
      frontFramesReceived:  frontFrames,
      backFramesReceived:   backFrames,
      peakSystemPressureCost: peakPressure,
      hardwareCost:         hw,
      durationSeconds:      duration,
    );
  }

  /// Parses an int from a map value (int or double → int).
  /// Returns null if the value is null or not numeric.
  static int? _parseInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is double) return raw.toInt();
    return null;
  }

  /// Parses a double from a map value (double or int → double).
  /// Returns null if the value is null or not numeric.
  static double? _parseDouble(Object? raw) {
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGMultiCamRenderReport &&
          runtimeType == other.runtimeType &&
          renderedFrames == other.renderedFrames &&
          droppedRenderFrames == other.droppedRenderFrames &&
          averageRenderMs == other.averageRenderMs &&
          peakRenderMs == other.peakRenderMs &&
          outputWidth == other.outputWidth &&
          outputHeight == other.outputHeight &&
          pairedFramesReceived == other.pairedFramesReceived &&
          frontFramesReceived == other.frontFramesReceived &&
          backFramesReceived == other.backFramesReceived &&
          peakSystemPressureCost == other.peakSystemPressureCost &&
          hardwareCost == other.hardwareCost &&
          durationSeconds == other.durationSeconds;

  @override
  int get hashCode => Object.hash(
        renderedFrames,
        droppedRenderFrames,
        averageRenderMs,
        peakRenderMs,
        outputWidth,
        outputHeight,
        pairedFramesReceived,
        frontFramesReceived,
        backFramesReceived,
        peakSystemPressureCost,
        hardwareCost,
        durationSeconds,
      );

  @override
  String toString() =>
      'VGMultiCamRenderReport('
      'renderedFrames: $renderedFrames, '
      'droppedRenderFrames: $droppedRenderFrames, '
      'renderedFPS: ${renderedFPS.toStringAsFixed(1)}, '
      'averageRenderMs: ${averageRenderMs.toStringAsFixed(2)}, '
      'peakRenderMs: ${peakRenderMs.toStringAsFixed(2)}, '
      'output: ${outputWidth}x${outputHeight}, '
      'pairedFramesReceived: $pairedFramesReceived, '
      'peakSystemPressureCost: $peakSystemPressureCost, '
      'hardwareCost: $hardwareCost, '
      'durationSeconds: $durationSeconds)';
}

final class VGCameraSession {

  // ── Channel ──────────────────────────────────────────────────────────────────

  static const _channel = MethodChannel('vanguard_media_engine');

  // ── Identity ─────────────────────────────────────────────────────────────────

  /// Dart-side session identifier.
  ///
  /// Currently a synthetic string derived from [textureId] (`'camera-$textureId'`).
  /// In a future phase when the native camera gains a session registry, this will
  /// carry a real UUID returned from native. Treat it as opaque.
  final String sessionId;

  /// Flutter texture ID. Pass to `Texture(textureId: textureId)` to display frames.
  final int textureId;

  // ── State ────────────────────────────────────────────────────────────────────

  /// Guards against duplicate [dispose] calls. Idempotent.
  bool _disposed = false;

  /// Whether this session has been disposed.
  bool get isDisposed => _disposed;

  // ── Constructor ──────────────────────────────────────────────────────────────

  /// Internal constructor. Use [VGCameraSession.create] to obtain instances.
  VGCameraSession._({required this.sessionId, required this.textureId});

  // ── Factory ──────────────────────────────────────────────────────────────────

  /// Creates a new camera session and starts the native AVCaptureSession.
  ///
  /// Calls the native `startCamera` handler, which:
  ///   1. Transitions the plugin to camera mode.
  ///   2. Creates a [VanguardCameraMediaSource] for the requested [position].
  ///   3. Registers a GPU preview texture with Flutter's texture registry.
  ///   4. Returns the [textureId] for use with `Texture(textureId: ...)`.
  ///
  /// [position] — sensor to use; defaults to [VGCameraPosition.back].
  /// [fps]      — target frame rate; 30 is recommended for all devices.
  ///
  /// Throws [StateError] if native returns a null or negative texture ID.
  /// Throws [PlatformException] for native-reported errors (e.g. no camera permission).
  static Future<VGCameraSession> create({
    VGCameraPosition position = VGCameraPosition.back,
    int fps = 30,
  }) async {
    final positionInt = position == VGCameraPosition.front ? 2 : 1;
    final id = await _channel.invokeMethod<int>('startCamera', {
      'position': positionInt,
      'fps': fps,
    });
    if (id == null || id < 0) {
      throw StateError(
        '[VGCameraSession] startCamera: native returned no texture id',
      );
    }
    return VGCameraSession._(sessionId: 'camera-$id', textureId: id);
  }

  // ── Camera control ───────────────────────────────────────────────────────────

  /// Swaps to the given [position] without tearing down the session (~150 ms).
  ///
  /// The [textureId] returned by [create] remains valid — no widget rebuild needed.
  ///
  /// Throws [PlatformException] with code `'RECORDING_ACTIVE'` if called while
  /// a recording is in progress. Disable the switch control while recording.
  ///
  /// No-op if this session has been [dispose]d.
  Future<void> switchCamera(VGCameraPosition position) async {
    if (_disposed) return;
    final positionInt = position == VGCameraPosition.front ? 2 : 1;
    await _channel.invokeMethod<void>('switchCamera', {
      'position': positionInt,
    });
  }

  /// Sets the zoom level. `1.0` = no zoom; clamped to the device maximum on the
  /// native side.
  ///
  /// Throttle callers to ≤ 30 Hz when driving from pinch gesture handlers to
  /// avoid flooding the method channel.
  ///
  /// No-op if this session has been [dispose]d.
  Future<void> setZoom(double factor) async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('setZoom', {'factor': factor});
  }

  /// Returns native zoom capabilities for the currently active camera device.
  ///
  /// Should be called after [create] succeeds. Internally queries the native
  /// side for `minAvailableVideoZoomFactor`, `maxAvailableVideoZoomFactor`,
  /// `displayVideoZoomFactorMultiplier` (iOS 18+; defaults to `1.0` on earlier
  /// OS versions), and `virtualDeviceSwitchOverVideoZoomFactors` (iOS 13+).
  ///
  /// ## Wide-angle-first phase
  /// In the current implementation, the native side is bound to
  /// `builtInWideAngleCamera` only. The returned capabilities therefore
  /// reflect only the wide-angle lens range:
  ///   - [VGCameraZoomCapabilities.virtualDeviceSwitchOverZoomFactors] is `[]`.
  ///   - [VGCameraZoomCapabilities.isVirtualDevice] is `false`.
  ///   - [VGCameraZoomCapabilities.supportsUltraWide] is `false`.
  ///   - [VGCameraZoomCapabilities.supportsTelephoto] is `false`.
  ///
  /// ## Android
  /// Android zoom capability exposure is not yet implemented. On Android the
  /// native handler is absent so [VGCameraZoomCapabilities.fallback] is
  /// returned silently.
  ///
  /// ## Failure behaviour
  /// Returns [VGCameraZoomCapabilities.fallback] on any of:
  ///   - This session is disposed.
  ///   - Native returns `null` (no active camera device).
  ///   - A [PlatformException] is thrown (e.g. `NO_CAMERA`, `NO_DEVICE`,
  ///     or `FlutterMethodNotImplemented` on Android).
  ///
  /// No-op if this session has been [dispose]d (returns fallback).
  Future<VGCameraZoomCapabilities> getZoomCapabilities() async {
    if (_disposed) return VGCameraZoomCapabilities.fallback;
    try {
      final raw =
          await _channel.invokeMethod<Map>('getCameraZoomCapabilities');
      if (raw == null) return VGCameraZoomCapabilities.fallback;
      return VGCameraZoomCapabilities.fromMap(
        Map<String, dynamic>.from(raw),
      );
    } on PlatformException {
      return VGCameraZoomCapabilities.fallback;
    }
  }

  /// Returns whether this iOS device supports simultaneous multi-camera capture
  /// via `AVCaptureMultiCamSession`.
  ///
  /// This is a pure hardware capability query. It does **not** start or modify
  /// any capture session, and it does **not** request camera permission.
  ///
  /// Returns `true` only on iOS 13+ devices with multi-camera hardware support
  /// (e.g., iPhone XS and later with A12 Bionic or newer).
  ///
  /// ## Android
  /// The native handler is absent on Android. Returns `false` silently via
  /// `PlatformException` fallback.
  ///
  /// ## Failure behaviour
  /// Returns `false` on any of:
  ///   - iOS < 13.0 (guarded natively with `#available`).
  ///   - A [PlatformException] is thrown (Android or unexpected native error).
  static Future<bool> isMultiCamSupported() async {
    try {
      final supported =
          await _channel.invokeMethod<bool>('isMultiCamSupported');
      return supported ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Returns the sets of camera devices that can be used simultaneously in an
  /// `AVCaptureMultiCamSession`, as enumerated by
  /// `AVCaptureDevice.DiscoverySession.supportedMultiCamDeviceSets`.
  ///
  /// This is a pure hardware capability query. It does **not** allocate an
  /// `AVCaptureMultiCamSession`, add any `AVCaptureDeviceInput`,
  /// create any `AVCaptureVideoDataOutput`, or request camera permission.
  ///
  /// ## Return value
  /// Returns a list of **device sets**. Each device set is a list of device
  /// descriptor maps with the following keys:
  ///
  /// | Key             | Type   | Example                       |
  /// |:--------------- |:------ |:----------------------------- |
  /// | `uniqueId`      | String | `"com.apple.avfoundation..."` |
  /// | `localizedName` | String | `"Back Camera"`               |
  /// | `position`      | String | `"back"` / `"front"` / etc.   |
  /// | `deviceType`    | String | `"builtInWideAngleCamera"`    |
  /// | `modelId`       | String | Device model string (optional)|
  /// | `manufacturer`  | String | `"Apple Inc."` (optional)     |
  ///
  /// On a supported iPhone 15 Pro, a typical result includes two-element sets
  /// pairing the front TrueDepth camera with a back camera.
  ///
  /// ## Android
  /// The native handler is absent on Android. Returns `[]` silently via
  /// `PlatformException` fallback.
  ///
  /// ## Failure behaviour
  /// Returns `[]` on any of:
  ///   - Device does not support MultiCam (natively detected before query).
  ///   - iOS < 13.0 (guarded natively with `#available`).
  ///   - A [PlatformException] is thrown (Android or unexpected native error).
  ///   - Malformed or null native response.
  static Future<List<List<Map<String, Object?>>>> getMultiCamDeviceSets() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('getMultiCamDeviceSets');
      if (raw == null) return [];
      return raw.map((setRaw) {
        if (setRaw is! List) return <Map<String, Object?>>[];
        return setRaw.map((deviceRaw) {
          if (deviceRaw is! Map) return <String, Object?>{};
          return Map<String, Object?>.from(deviceRaw);
        }).toList();
      }).toList();
    } on PlatformException {
      return [];
    }
  }

  /// MC-3: Measures the ISP bandwidth cost of configuring an
  /// `AVCaptureMultiCamSession` for the given front and back device IDs,
  /// without starting the session.
  ///
  /// Uses [VGMultiCamDeviceSet.selectFrontBackPair] and
  /// [VGCameraSession.getMultiCamDeviceSets] to obtain device IDs before
  /// calling this method.
  ///
  /// ## Authorization
  /// Returns `null` if the camera is not yet authorized. Does **not** trigger
  /// the permission prompt. The existing camera startup path handles that.
  ///
  /// ## What this does NOT do:
  ///   - Does NOT start the session.
  ///   - Does NOT stream frames.
  ///   - Does NOT report `systemPressureCost` (deferred to MC-4).
  ///   - Does NOT modify the running single-camera session.
  ///
  /// ## Android
  /// Returns `null` silently via `PlatformException` fallback.
  ///
  /// ## Failure behavior
  /// Returns `null` on any of:
  ///   - Camera authorization not granted.
  ///   - Device not found by uniqueID.
  ///   - `AVCaptureMultiCamSession` not supported on this device/OS.
  ///   - A [PlatformException] (Android or unexpected native error).
  ///   - Malformed or null native response.
  static Future<VGMultiCamCostReport?> measureMultiCamHardwareCost({
    required String frontDeviceId,
    required String backDeviceId,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'measureMultiCamHardwareCost',
        {
          'frontDeviceId': frontDeviceId,
          'backDeviceId': backDeviceId,
        },
      );
      return VGMultiCamCostReport.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  /// MC-4: Runs a live 3-second MultiCam streaming diagnostic for the given
  /// front and back device IDs.
  ///
  /// Starts a real `AVCaptureMultiCamSession`, streams frames from both cameras
  /// via sample-buffer delegates for a fixed 3-second window, samples
  /// `systemPressureCost` while running, then stops the session.
  ///
  /// ## Precondition
  /// The native plugin requires the engine to be **idle** (no single-camera
  /// session running). If the camera is active, this returns `null` (the native
  /// side returns a `CAMERA_ACTIVE` error, which this method silently converts
  /// to null). Stop the camera preview before calling this method.
  ///
  /// ## Authorization
  /// Returns `null` if the camera is not yet authorized. Does **not** trigger
  /// the permission prompt.
  ///
  /// ## What this does NOT do:
  ///   - Does NOT create a Flutter texture or Metal renderer.
  ///   - Does NOT composite frames.
  ///   - Does NOT create `AVCaptureDataOutputSynchronizer`.
  ///   - Does NOT modify the single-camera session.
  ///
  /// ## Android
  /// Returns `null` silently via `PlatformException` fallback.
  ///
  /// ## Failure behavior
  /// Returns `null` on any of:
  ///   - Engine is not idle (`CAMERA_ACTIVE` error from native).
  ///   - Camera authorization not granted.
  ///   - Device not found by uniqueID.
  ///   - `AVCaptureMultiCamSession` not supported on this device/OS.
  ///   - A [PlatformException] (Android or unexpected native error).
  ///   - Malformed or null native response.
  static Future<VGMultiCamStreamingReport?> runMultiCamStreamingDiagnostic({
    required String frontDeviceId,
    required String backDeviceId,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'runMultiCamStreamingDiagnostic',
        {
          'frontDeviceId': frontDeviceId,
          'backDeviceId': backDeviceId,
        },
      );
      return VGMultiCamStreamingReport.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  /// MC-5: Runs a live 3-second MultiCam software timestamp-pairing diagnostic
  /// for the given front and back device IDs.
  ///
  /// Uses independent `setSampleBufferDelegate:queue:` on each output (same as
  /// MC-4), with a shared serial queue for lock-free software pairing. On each
  /// callback, the presentation timestamp (PTS) is extracted and compared with
  /// the most recent unmatched PTS from the other camera. If the drift is within
  /// 1/30 s, the frames are counted as a pair and the drift is measured.
  ///
  /// ## Why not AVCaptureDataOutputSynchronizer?
  /// Physical-device testing showed zero paired frames with `AVCaptureDataOutputSynchronizer`:
  /// its `alwaysDiscardsLateVideoFrames` behavior causes the secondary camera's
  /// frames to be discarded before pairing. Software pairing is used instead.
  ///
  /// ## Key difference from MC-4
  /// MC-4 ([runMultiCamStreamingDiagnostic]) counts raw frame delivery only.
  /// MC-5 additionally measures temporal alignment between front and back frames
  /// via nearest-neighbour PTS matching.
  ///
  /// ## Precondition
  /// The native plugin requires the engine to be **idle** (no single-camera
  /// session running). If the camera is active, this returns `null` (the native
  /// side returns a `CAMERA_ACTIVE` error, which this method silently converts
  /// to null). Stop the camera preview before calling this method.
  ///
  /// ## Authorization
  /// Returns `null` if the camera is not yet authorized. Does **not** trigger
  /// the permission prompt.
  ///
  /// ## What this does NOT do:
  ///   - Does NOT create a Flutter texture or Metal renderer.
  ///   - Does NOT composite frames.
  ///   - Does NOT retain `CMSampleBuffer` or `CVPixelBuffer` beyond the callback.
  ///   - Does NOT create `VanguardMultiCamMediaSource`.
  ///   - Does NOT modify the single-camera session.
  ///
  /// ## Android
  /// Returns `null` silently via `PlatformException` fallback.
  ///
  /// ## Failure behavior
  /// Returns `null` on any of:
  ///   - Engine is not idle (`CAMERA_ACTIVE` error from native).
  ///   - Camera authorization not granted.
  ///   - Device not found by uniqueID.
  ///   - `AVCaptureMultiCamSession` not supported on this device/OS.
  ///   - A [PlatformException] (Android or unexpected native error).
  ///   - Malformed or null native response.
  static Future<VGMultiCamSyncReport?> runMultiCamSyncDiagnostic({
    required String frontDeviceId,
    required String backDeviceId,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'runMultiCamSyncDiagnostic',
        {
          'frontDeviceId': frontDeviceId,
          'backDeviceId': backDeviceId,
        },
      );
      return VGMultiCamSyncReport.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  /// MC-7: Runs a live 3-second MultiCam media source lifecycle diagnostic
  /// for the given front and back device IDs.
  ///
  /// Instantiates `VanguardMultiCamMediaSource` — the production MultiCam
  /// source scaffold created in MC-7 — starts it for 3 seconds, stops it,
  /// and returns the pairing + system metrics.
  ///
  /// ## Key difference from MC-5
  /// [runMultiCamSyncDiagnostic] (MC-5) uses a standalone diagnostic class
  /// with an internal pairing delegate.
  /// This method (MC-7) uses the production `VanguardMultiCamMediaSource`
  /// with the extracted `VanguardMultiCamFramePairer` (MC-6).
  ///
  /// ## Return value
  /// Returns the same [VGMultiCamSyncReport] type as MC-5. Both the native
  /// dictionary shape and the Dart report model are identical. MC-7 and MC-5
  /// results should be comparable within ±10%.
  ///
  /// ## Precondition
  /// The native plugin requires the engine to be **idle** (no single-camera
  /// session running). If the camera is active, this returns `null` (the
  /// native side returns a `CAMERA_ACTIVE` error, which this method silently
  /// converts to null). Stop the camera preview before calling this method.
  ///
  /// ## Authorization
  /// Returns `null` if the camera is not yet authorized. Does **not** trigger
  /// the permission prompt.
  ///
  /// ## What this does NOT do
  ///   - Does NOT create a Flutter texture or Metal renderer.
  ///   - Does NOT composite frames.
  ///   - Does NOT retain `CMSampleBuffer` or `CVPixelBuffer`.
  ///   - Does NOT conform to `<VanguardMediaSource>`.
  ///   - Does NOT add `VanguardEngineMode.multiCam`.
  ///   - Does NOT modify the single-camera session.
  ///
  /// ## Android
  /// Returns `null` silently via `PlatformException` fallback.
  ///
  /// ## Failure behavior
  /// Returns `null` on any of:
  ///   - Engine is not idle (`CAMERA_ACTIVE` error from native).
  ///   - Camera authorization not granted.
  ///   - Device not found by uniqueID.
  ///   - `AVCaptureMultiCamSession` not supported on this device/OS.
  ///   - A [PlatformException] (Android or unexpected native error).
  ///   - Malformed or null native response.
  static Future<VGMultiCamSyncReport?> runMultiCamSourceLifecycleDiagnostic({
    required String frontDeviceId,
    required String backDeviceId,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'runMultiCamSourceLifecycleDiagnostic',
        {
          'frontDeviceId': frontDeviceId,
          'backDeviceId': backDeviceId,
        },
      );
      return VGMultiCamSyncReport.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  /// Runs a 3-second offscreen MultiCam render diagnostic and returns the result.
  ///
  /// MC-9 diagnostic. Uses [VanguardMultiCamMediaSource] to capture paired
  /// front/back frames and [VanguardMultiCamRenderDiagnostic] to composite them
  /// offscreen using CoreImage into a CVPixelBuffer pool (PiP layout).
  ///
  /// No Flutter texture is created. No visible preview. Diagnostic-only.
  ///
  /// ## iOS
  /// Requires:
  ///   - iOS 13.0+ (`AVCaptureMultiCamSession`).
  ///   - Camera authorization granted.
  ///   - Hardware MultiCam support.
  ///   - Engine must be idle (no active camera session).
  ///
  /// ## Android
  /// Returns `null` silently via `PlatformException` fallback.
  ///
  /// ## Failure behavior
  /// Returns `null` on any of:
  ///   - Engine is not idle (`CAMERA_ACTIVE` error from native).
  ///   - Camera authorization not granted.
  ///   - Device not found by uniqueID.
  ///   - `AVCaptureMultiCamSession` not supported on this device/OS.
  ///   - A [PlatformException] (Android or unexpected native error).
  ///   - Malformed or null native response.
  static Future<VGMultiCamRenderReport?> runMultiCamRenderDiagnostic({
    required String frontDeviceId,
    required String backDeviceId,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'runMultiCamRenderDiagnostic',
        {
          'frontDeviceId': frontDeviceId,
          'backDeviceId': backDeviceId,
        },
      );
      return VGMultiCamRenderReport.fromMap(raw);
    } on PlatformException {
      return null;
    }
  }

  /// Tap-to-focus and tap-to-expose at a normalised point.
  ///
  /// [x] and [y] must be in the range `[0.0, 1.0]`, where `(0, 0)` is the
  /// top-left and `(1, 1)` is the bottom-right of the camera frame.
  ///
  /// No-op if this session has been [dispose]d.
  Future<void> setFocusPoint(double x, double y) async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('setFocusPoint', {'x': x, 'y': y});
  }

  /// Sets the continuous video torch mode.
  ///
  /// No-op on devices that have no torch (most front-facing cameras, simulator).
  /// No-op if this session has been [dispose]d.
  Future<void> setTorchMode(VGTorchMode mode) async {
    if (_disposed) return;
    final modeStr = mode == VGTorchMode.on ? 'on' : 'off';
    await _channel.invokeMethod<void>('setTorchMode', {'mode': modeStr});
  }

  /// Applies a filter chain to the live camera graph.
  ///
  /// Requires the native plugin to be compiled with `VG_USE_CAMERA_GRAPH=1`.
  /// An empty list removes all filters (passthrough).
  ///
  /// In debug mode, each spec is validated against the native allowlist via
  /// [VGFilterSpec.assertValid] before dispatch.
  ///
  /// Throws [PlatformException] with code `'GRAPH_MODE_DISABLED'` if camera
  /// graph mode is not compiled in.
  ///
  /// No-op if this session has been [dispose]d.
  Future<void> setFilterChain(List<VGFilterSpec> filters) async {
    if (_disposed) return;
    if (kDebugMode) {
      for (final filter in filters) {
        filter.assertValid();
      }
    }
    await _channel.invokeMethod<void>('setCameraFilterChain', {
      'filters': filters.map((f) => f.toJson()).toList(),
    });
  }

  // ── Capture ──────────────────────────────────────────────────────────────────

  /// Captures the current live camera frame as a JPEG and writes it to [path].
  ///
  /// [path] must be a writable absolute path with a `.jpg` extension.
  /// Safe to call while a video recording is active.
  ///
  /// Returns the absolute path of the written file on success.
  ///
  /// Throws [StateError] if this session has been [dispose]d.
  /// Throws [PlatformException] with one of:
  ///   `'NO_FRAME'`    — camera started but no frame delivered yet (~100 ms window)
  ///   `'SWITCHING'`   — a camera switch is in progress (~150 ms window)
  ///   `'ENCODE_FAIL'` — JPEG encoding or disk write failed
  ///   `'NO_CAMERA'`   — native has no active camera source
  Future<String> takePhoto(String path) async {
    if (_disposed) {
      throw StateError(
        '[VGCameraSession] takePhoto called on a disposed session',
      );
    }
    final filePath = await _channel.invokeMethod<String>('takePhoto', {
      'path': path,
    });
    if (filePath == null) {
      throw PlatformException(
        code: 'ENCODE_FAIL',
        message: '[VGCameraSession] takePhoto returned null path',
      );
    }
    return filePath;
  }

  /// Captures the current live camera frame as a JPEG and writes it to [path],
  /// returning a typed [VGPhotoCaptureResult].
  ///
  /// This is the typed companion to [takePhoto]. It calls [takePhoto] internally
  /// so all existing lifecycle guards (disposed check, null-path error) apply
  /// identically. Callers that only need the file path should prefer [takePhoto].
  ///
  /// Metadata fields ([VGPhotoCaptureResult.width], [VGPhotoCaptureResult.height],
  /// [VGPhotoCaptureResult.sizeBytes]) are `0` until the native handler is
  /// enriched to return a metadata map in a future release.
  ///
  /// Throws [StateError] if this session has been [dispose]d.
  /// Throws [PlatformException] with the same codes as [takePhoto].
  Future<VGPhotoCaptureResult> takePhotoResult(String path) async {
    final filePath = await takePhoto(path);
    return VGPhotoCaptureResult.fromPath(filePath);
  }

  /// Begins hardware-encoded video recording to [path].
  ///
  /// [path] must be a writable local path with a `.mp4` extension.
  /// Must be called after [create]; the native session must be active.
  ///
  /// No-op if this session has been [dispose]d.
  Future<void> startRecording(String path) async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('startRecording', {'path': path});
  }

  /// Stops the active recording and finalises the MP4.
  ///
  /// Returns a typed [VGRecordingStats] result containing the output file path
  /// and hardware-encoder frame statistics.
  ///
  /// Throws [StateError] if this session has been [dispose]d.
  Future<VGRecordingStats> stopRecording() async {
    if (_disposed) {
      throw StateError(
        '[VGCameraSession] stopRecording called on a disposed session',
      );
    }
    final raw = await _channel.invokeMethod<Map>('stopRecording');
    return VGRecordingStats.fromMap(Map<String, dynamic>.from(raw ?? const {}));
  }

  // ── Native MTKView preview ───────────────────────────────────────────────────

  /// Presents the fullscreen native MTKView camera overlay.
  ///
  /// This calls the native `openNativeCamera` handler, which creates a
  /// `VGNativeCameraViewController` and presents it over the Flutter root view.
  /// The native VC owns orientation decisions and locks the capture connection
  /// to portrait.
  ///
  /// Requires this session to be active (i.e. [create] has been called and
  /// [dispose] has not). The native side will return `NO_CAMERA` if no
  /// `cameraSource` exists.
  ///
  /// Dismiss with [closeNativePreview].
  ///
  /// Throws [StateError] if this session has been [dispose]d.
  /// Throws [PlatformException] if the native side cannot present the overlay
  /// (e.g. `'NO_CAMERA'`, `'NO_GRAPH_SESSION'`, `'NO_ROOT_VC'`).
  Future<void> openNativePreview() async {
    if (_disposed) {
      throw StateError(
        '[VGCameraSession] openNativePreview called on a disposed session',
      );
    }
    await _channel.invokeMethod<void>('openNativeCamera');
  }

  /// Dismisses the fullscreen native MTKView camera overlay.
  ///
  /// Unlocks the capture connection orientation restored by [openNativePreview].
  /// Safe to call when no overlay is active (native side no-ops).
  ///
  /// No-op if this session has been [dispose]d.
  Future<void> closeNativePreview() async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('closeNativeCamera');
  }

  // ── Transactions (Phase 6C.2A) ─────────────────────────────────────────────

  /// Returns a new, blank mutable [VGGraphTransaction] builder.
  ///
  /// This is a pure-Dart factory call.  It does not invoke any method channel
  /// or mutate the native graph state.  Use [prepareTransaction] for a
  /// callback-style alternative, or [applyTransaction] to dispatch the
  /// committed payload to the native camera graph.
  ///
  /// ```dart
  /// final tx = session.newTransaction();
  /// tx.setParameter('beauty', 'intensity', 0.8);
  /// final payload = tx.commit(); // ready for applyTransaction
  /// ```
  VGGraphTransaction newTransaction() => VGGraphTransaction();

  /// Ergonomic builder that assembles a transaction in memory and returns the
  /// frozen [VGGraphTransactionPayload] without dispatching to native.
  ///
  /// Internally creates a fresh [VGGraphTransaction], passes it to [builder],
  /// then calls [VGGraphTransaction.commit].  Validation and clamping errors
  /// thrown inside [builder] propagate normally to the caller.
  ///
  /// This is 100% side-effect-free.  It does not invoke any method channel or
  /// mutate the native graph state.
  ///
  /// ```dart
  /// final payload = session.prepareTransaction((tx) {
  ///   tx.setParameter('beauty', 'intensity', 0.8);
  ///   tx.setParameter('lut',    'intensity', 0.4);
  /// });
  /// // payload is ready for applyTransaction
  /// ```
  VGGraphTransactionPayload prepareTransaction(
    void Function(VGGraphTransaction tx) builder,
  ) {
    final tx = VGGraphTransaction();
    builder(tx);
    return tx.commit();
  }

  /// Applies a validated, committed [VGGraphTransactionPayload] to the active
  /// native camera graph.
  ///
  /// Phase 6C.2A supports **preset-only rebuild** transactions only:
  ///   - Empty payload: successful Dart-side no-op (no channel call).
  ///   - Preset-only (`requiresRebuild == true`, `parameterUpdates` empty):
  ///     dispatches `applyGraphTransaction` and rebuilds the filter chain.
  ///   - Non-empty `parameterUpdates`: dispatched to native, which rejects
  ///     with `UNSUPPORTED_TRANSACTION_POLICY` ([PlatformException]).
  ///
  /// Dart does not filter by policy — the native side owns policy rejection.
  ///
  /// Throws [PlatformException] if native reports an error (e.g.
  ///   `NO_CAMERA_GRAPH`, `UNSUPPORTED_TRANSACTION_POLICY`,
  ///   `GRAPH_MODE_DISABLED`).
  Future<void> applyTransaction(VGGraphTransactionPayload payload) async {
    if (payload.isEmpty) {
      return;
    }
    await _channel.invokeMethod<void>(
      'applyGraphTransaction',
      payload.toJson(),
    );
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  /// Stops the camera and releases native resources.
  ///
  /// Calls `stopCamera` on the native side, which:
  ///   - Invalidates the camera graph session (if VG_USE_CAMERA_GRAPH=1).
  ///   - Stops the AVCaptureSession.
  ///   - Releases the [VanguardCameraMediaSource] and streaming encoder.
  ///   - Transitions the plugin mode to `.idle`.
  ///
  /// Idempotent: subsequent calls are silent no-ops.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _channel.invokeMethod<void>('stopCamera');
  }

  // ── Debug ────────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'VGCameraSession(sessionId: $sessionId, textureId: $textureId, '
      'disposed: $_disposed)';
}
