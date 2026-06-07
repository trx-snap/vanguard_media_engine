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
