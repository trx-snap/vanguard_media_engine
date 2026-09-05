// vg_duet_camera_session.dart
// vanguard_media_engine - P3-CAM-DUET-SESSION-ADMISSION-ROUTE: Duet/Dual Camera
// session admission wrapper and launcher.
//
// Routes Duet/Dual Camera session admission through
// [VGDuetDualCameraCapabilityEvaluator] before ever touching the native
// camera surface. Production stays fail-closed on unsupported Android
// hardware (no [VGCameraSession.create] / `startCamera`, no
// [VGCameraSession.startMultiCamPreview] call). Diagnostic continuation is
// explicit opt-in and opens a single physical camera only, never claiming
// physical dual-camera. Real dual-camera flags are only ever true when the
// policy already reports genuine hardware-validated concurrent capture AND a
// real [VGMultiCamRenderTextureSession] was actually acquired -- this slice
// does not add Android production concurrent capture, so on Android that
// route observes the existing legacy/iOS-only `startMultiCamPreview` native
// gap and fails closed (returns `null`) rather than synthesizing success.
//
// Boundary: duet_dual_camera_session_admission_gated_routing_single_cam_diagnostic_fallback_no_real_concurrent_hardware_proof.

import 'package:flutter/services.dart';

import 'vg_camera_session.dart';
import 'vg_dual_camera_capability_policy.dart';
import 'vg_live_preview_config.dart';

/// Immutable admission result of [VGDuetCameraSessionLauncher.startSession].
///
/// Obtain instances via [VGDuetCameraSessionLauncher.startSession]. Exactly
/// one of [singleCameraSession] or [multiCamSession] is non-null:
///   - Diagnostic synthetic mode populates [singleCameraSession] only.
///   - Production real dual-camera mode populates [multiCamSession] only.
///
/// Call [dispose] to release whichever underlying resource was acquired.
final class VGDuetCameraSession {
  VGDuetCameraSession._({
    required this.sessionId,
    required this.textureId,
    required this.policy,
    required this.isPhysicalDualCamera,
    required this.isProductionRealDualCamera,
    required this.isDiagnosticSyntheticMode,
    this.singleCameraSession,
    this.multiCamSession,
  });

  /// Dart-side session identifier. Opaque; derived from the underlying
  /// single-camera or MultiCam texture session.
  final String sessionId;

  /// Flutter texture ID. Pass to `Texture(textureId: textureId)` to display frames.
  final int textureId;

  /// The capability policy this session was admitted under.
  final VGDuetDualCameraCapabilityPolicy policy;

  /// Whether verified physical dual-camera hardware capture backs this session.
  ///
  /// `true` only when [policy].decision is
  /// [VGDuetDualCameraCapabilityDecision.productionRealDualCamera] and a real
  /// [multiCamSession] was actually acquired. Always `false` for diagnostic
  /// synthetic single-camera sessions.
  final bool isPhysicalDualCamera;

  /// Whether this session is a production-visible real dual-camera capture.
  ///
  /// `true` only under the same conditions as [isPhysicalDualCamera].
  final bool isProductionRealDualCamera;

  /// Whether this session is an explicit-opt-in diagnostic single-camera
  /// continuation on unsupported hardware. Never implies physical dual camera.
  final bool isDiagnosticSyntheticMode;

  /// The underlying single-camera session, populated only for diagnostic
  /// synthetic sessions.
  final VGCameraSession? singleCameraSession;

  /// The underlying MultiCam render texture session, populated only for
  /// production real dual-camera sessions.
  final VGMultiCamRenderTextureSession? multiCamSession;

  bool _disposed = false;

  /// Whether this session has been disposed.
  bool get isDisposed => _disposed;

  /// Releases whichever native resource this session holds.
  ///
  /// Idempotent: subsequent calls are silent no-ops.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (singleCameraSession != null) {
      await singleCameraSession!.dispose();
    }
    if (multiCamSession != null) {
      await VGCameraSession.stopMultiCamPreview();
    }
  }

  @override
  String toString() =>
      'VGDuetCameraSession(sessionId: $sessionId, textureId: $textureId, '
      'isPhysicalDualCamera: $isPhysicalDualCamera, '
      'isProductionRealDualCamera: $isProductionRealDualCamera, '
      'isDiagnosticSyntheticMode: $isDiagnosticSyntheticMode, '
      'disposed: $_disposed)';
}

/// Evaluates Duet/Dual Camera capability policy and routes admission to the
/// appropriate -- or no -- native camera session.
///
/// The [evaluator] is injectable so tests can force a specific
/// [VGDuetDualCameraCapabilityPolicy] without a real Camera2 probe or a
/// running Android device.
final class VGDuetCameraSessionLauncher {
  const VGDuetCameraSessionLauncher({
    this.evaluator = const VGDuetDualCameraCapabilityEvaluator(),
    this.channel,
  });

  /// Capability evaluator used to derive the admission policy. Override in
  /// tests with a fake subclass of [VGDuetDualCameraCapabilityEvaluator].
  final VGDuetDualCameraCapabilityEvaluator evaluator;

  /// Optional method channel forwarded to [evaluator]. When `null`, the
  /// evaluator uses its own default channel.
  final MethodChannel? channel;

  /// Evaluates admission policy and starts a Duet/Dual Camera session
  /// according to the fail-closed / diagnostic / production-real rules.
  ///
  /// Returns `null` when:
  ///   - The policy is [VGDuetDualCameraCapabilityDecision.blocked] or
  ///     [VGDuetDualCameraCapabilityDecision.productionHiddenSingleCameraFallback]
  ///     - fails closed before any [VGCameraSession.create] or
  ///     [VGCameraSession.startMultiCamPreview] call.
  ///   - The diagnostic single-camera [VGCameraSession.create] call fails.
  ///   - The policy is
  ///     [VGDuetDualCameraCapabilityDecision.productionRealDualCamera] but no
  ///     concurrent camera IDs were selected, or
  ///     [VGCameraSession.startMultiCamPreview] returns `null` (e.g. the
  ///     native handler is absent on Android in this slice).
  ///
  /// [allowDiagnosticSyntheticMode] must be explicitly `true` to admit
  /// diagnostic single-camera continuation on unsupported hardware; it is
  /// never used for production.
  Future<VGDuetCameraSession?> startSession({
    bool allowDiagnosticSyntheticMode = false,
    VGCameraPosition position = VGCameraPosition.back,
    int fps = 30,
    VGLivePreviewConfig? config,
  }) async {
    final policy = await evaluator.evaluateDevicePolicy(
      allowDiagnosticSyntheticMode: allowDiagnosticSyntheticMode,
      channel: channel,
    );

    switch (policy.decision) {
      case VGDuetDualCameraCapabilityDecision.blocked:
      case VGDuetDualCameraCapabilityDecision
          .productionHiddenSingleCameraFallback:
        return null;

      case VGDuetDualCameraCapabilityDecision.diagnosticSyntheticSingleCamera:
        return _startDiagnosticSession(policy, position: position, fps: fps);

      case VGDuetDualCameraCapabilityDecision.productionRealDualCamera:
        return _startProductionRealDualSession(policy, config: config);
    }
  }

  Future<VGDuetCameraSession?> _startDiagnosticSession(
    VGDuetDualCameraCapabilityPolicy policy, {
    required VGCameraPosition position,
    required int fps,
  }) async {
    final VGCameraSession single;
    try {
      single = await VGCameraSession.create(position: position, fps: fps);
    } catch (_) {
      // create() either throws before allocating a Dart-side session object
      // (bad/missing texture id) or the native call itself failed
      // (PlatformException). Either way there is nothing on the Dart side to
      // dispose -- fail closed.
      return null;
    }

    return VGDuetCameraSession._(
      sessionId: single.sessionId,
      textureId: single.textureId,
      policy: policy,
      isPhysicalDualCamera: false,
      isProductionRealDualCamera: false,
      isDiagnosticSyntheticMode: true,
      singleCameraSession: single,
    );
  }

  Future<VGDuetCameraSession?> _startProductionRealDualSession(
    VGDuetDualCameraCapabilityPolicy policy, {
    VGLivePreviewConfig? config,
  }) async {
    final backDeviceId = policy.selectedPrimaryCameraId;
    final frontDeviceId = policy.selectedSecondaryCameraId;
    if (backDeviceId == null || frontDeviceId == null) {
      return null;
    }

    final multi = await VGCameraSession.startMultiCamPreview(
      frontDeviceId: frontDeviceId,
      backDeviceId: backDeviceId,
      config: config,
    );
    if (multi == null) {
      // Native returned no session (e.g. PlatformException, or the
      // Android native handler is absent in this slice). Do not synthesize
      // real dual-camera flags -- fail closed.
      return null;
    }

    return VGDuetCameraSession._(
      sessionId: 'duet-${multi.textureId}',
      textureId: multi.textureId,
      policy: policy,
      isPhysicalDualCamera: true,
      isProductionRealDualCamera: true,
      isDiagnosticSyntheticMode: false,
      multiCamSession: multi,
    );
  }
}
