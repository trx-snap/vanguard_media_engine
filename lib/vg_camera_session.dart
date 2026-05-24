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
import 'vg_filter_spec.dart';

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
    return VGCameraSession._(
      sessionId: 'camera-$id',
      textureId: id,
    );
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
    await _channel.invokeMethod<void>('switchCamera', {'position': positionInt});
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
      throw StateError('[VGCameraSession] takePhoto called on a disposed session');
    }
    final filePath = await _channel.invokeMethod<String>('takePhoto', {'path': path});
    if (filePath == null) {
      throw PlatformException(
        code: 'ENCODE_FAIL',
        message: '[VGCameraSession] takePhoto returned null path',
      );
    }
    return filePath;
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
  /// Returns a map with keys:
  ///   `'filePath'`      — the completed output file path
  ///   `'droppedFrames'` — frames dropped by the hardware encoder
  ///   `'totalFrames'`   — total frames presented
  ///   `'dropRate'`      — `droppedFrames / totalFrames`
  ///
  /// Throws [StateError] if this session has been [dispose]d.
  Future<Map<String, dynamic>> stopRecording() async {
    if (_disposed) {
      throw StateError('[VGCameraSession] stopRecording called on a disposed session');
    }
    final raw = await _channel.invokeMethod<Map>('stopRecording');
    return Map<String, dynamic>.from(raw ?? {});
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
      throw StateError('[VGCameraSession] openNativePreview called on a disposed session');
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
