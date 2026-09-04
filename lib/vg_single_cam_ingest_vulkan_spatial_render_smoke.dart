// vg_single_cam_ingest_vulkan_spatial_render_smoke.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-SINGLE-CAM-INGEST-VULKAN-SPATIAL-RENDER:
// Android True-DAG Phase 3 bounded diagnostic proof that one real Camera2
// `ImageReader(YUV_420_888)` buffer-queue frame plus one synthetic RGBA8
// Vulkan scratch image are laid out by a caller-supplied Dart layout descriptor
// through native `ComputeMultiCamLayout()`, rendered by the existing
// `VulkanMultiCamSpatialCompositor`, structurally read back, and torn down
// synchronously.
//
// Unlike the GLES sibling route (which presents to a Flutter
// `TextureRegistry.SurfaceProducer`), this Vulkan route is offscreen readback-only
// and never presents to a Flutter texture. Each start invocation is keyed by a
// monotonic `runId`.
//
// Proof boundary (exact):
// single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_vulkan_render_readback_only_no_concurrent_camera_no_gles_no_recording_no_export_no_product
//
// Non-claims: no concurrent/dual camera, no GLES/OES, no recording/export,
// and no product/editor UI. Camera-side readback assertions are structural only
// (import succeeded, render/readback success, probe pixel has fully opaque alpha);
// the synthetic secondary additionally asserts deterministic solid blue.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_multicam_dynamic_descriptor_spatial_render_smoke.dart'
    show VGMultiCamDynamicDescriptorSpatialRenderInput;

export 'vg_multicam_dynamic_descriptor_spatial_render_smoke.dart'
    show VGMultiCamDynamicDescriptorSpatialRenderInput;

/// Decision produced by the native Phase 3 single-camera-ingest Vulkan
/// spatial render smoke harness.
enum VGSingleCamIngestVulkanSpatialRenderSmokeDecision {
  /// Full pass: camera frame ingested, descriptor accepted, Vulkan
  /// render/readback/teardown all succeeded.
  singleCamIngestVulkanSpatialRenderPassed,

  /// `Build.VERSION.SDK_INT` is below 29 (Q); no open was attempted.
  apiUnsupported,

  /// The caller's descriptor map failed shape/type validation (missing key
  /// or wrong type); no camera open or method channel invocation was attempted.
  malformedDescriptorShape,

  /// `CameraManager` was unavailable from the system service.
  cameraManagerUnavailable,

  /// `CameraManager.getCameraIdList()` returned no cameras.
  noCamera,

  /// The requested camera id was not present in `getCameraIdList()`.
  cameraUnavailable,

  /// `Manifest.permission.CAMERA` was not granted; no open was attempted.
  cameraPermissionDenied,

  /// The selected camera exposes no positive `YUV_420_888` output sizes.
  noSupportedYuvSize,

  /// Allocation of the `ImageReader` failed.
  imageReaderAllocationFailed,

  /// `onDisconnected` fired during the open attempt.
  openDisconnected,

  /// `onError` fired during the open attempt.
  openError,

  /// The open attempt did not reach a terminal callback state in time.
  cameraOpenTimeout,

  /// `onConfigureFailed` fired for the capture session, or session creation threw.
  sessionConfigureFailed,

  /// The capture session did not reach a terminal configuration state in time.
  sessionConfigureTimeout,

  /// `setRepeatingRequest` threw.
  repeatingRequestFailed,

  /// No frame arrived via `onImageAvailable` in time.
  noFrameWithinTimeout,

  /// `onCaptureFailed` fired for the repeating request.
  captureFailed,

  /// The acquired `Image.getHardwareBuffer()` was null, or native could not
  /// import the camera buffer -- device/format cannot ingest this camera's
  /// `YUV_420_888` buffer.
  cameraIngestUnsupported,

  /// Native Vulkan setup failed due to unsupported device or missing extensions.
  nativeUnsupported,

  /// Native's strict layoutMode/pipAnchor/splitDirection resolver rejected
  /// an unrecognized descriptor value before any Vulkan work began -- the camera
  /// frame was still fully captured first.
  descriptorRejected,

  /// A native lane failed for a reason other than camera-ingest, native
  /// unsupported, or descriptor rejection.
  nativeRenderFailed,

  /// The run was cancelled via dispose before or while it was still active.
  disposed,

  /// Unhandled exception in Dart harness, timeout, or malformed native payload.
  harnessException;

  /// Maps a raw native/Kotlin decision string to the matching enum value.
  static VGSingleCamIngestVulkanSpatialRenderSmokeDecision fromRaw(
    Object? raw,
  ) {
    if (raw is! String) {
      return VGSingleCamIngestVulkanSpatialRenderSmokeDecision.harnessException;
    }
    final trimmed = raw.trim();
    switch (trimmed) {
      case 'singleCamIngestVulkanSpatialRenderPassed':
      case 'pass':
      case 'PASS':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .singleCamIngestVulkanSpatialRenderPassed;
      case 'nativeRenderFailed':
      case 'fail':
      case 'FAIL':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .nativeRenderFailed;
      case 'nativeUnsupported':
      case 'unsupported':
      case 'UNSUPPORTED':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .nativeUnsupported;
      case 'cameraIngestUnsupported':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .cameraIngestUnsupported;
      case 'descriptorRejected':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .descriptorRejected;
      case 'apiUnsupported':
      case 'api_unsupported':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision.apiUnsupported;
      case 'malformedDescriptorShape':
      case 'malformed_descriptor_shape':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .malformedDescriptorShape;
      case 'cameraManagerUnavailable':
      case 'camera_manager_unavailable':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .cameraManagerUnavailable;
      case 'noCamera':
      case 'no_camera':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision.noCamera;
      case 'cameraUnavailable':
      case 'camera_unavailable':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .cameraUnavailable;
      case 'cameraPermissionDenied':
      case 'camera_permission_denied':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .cameraPermissionDenied;
      case 'noSupportedYuvSize':
      case 'no_supported_yuv_size':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .noSupportedYuvSize;
      case 'imageReaderAllocationFailed':
      case 'image_reader_allocation_failed':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .imageReaderAllocationFailed;
      case 'openDisconnected':
      case 'open_disconnected':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .openDisconnected;
      case 'openError':
      case 'open_error':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision.openError;
      case 'cameraOpenTimeout':
      case 'camera_open_timeout':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .cameraOpenTimeout;
      case 'sessionConfigureFailed':
      case 'session_configure_failed':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .sessionConfigureFailed;
      case 'sessionConfigureTimeout':
      case 'session_configure_timeout':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .sessionConfigureTimeout;
      case 'repeatingRequestFailed':
      case 'repeating_request_failed':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .repeatingRequestFailed;
      case 'noFrameWithinTimeout':
      case 'no_frame_within_timeout':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .noFrameWithinTimeout;
      case 'captureFailed':
      case 'capture_failed':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision.captureFailed;
      case 'disposed':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision.disposed;
      case 'harnessException':
      case 'harness_exception':
        return VGSingleCamIngestVulkanSpatialRenderSmokeDecision
            .harnessException;
    }
    for (final value
        in VGSingleCamIngestVulkanSpatialRenderSmokeDecision.values) {
      if (value.name == trimmed) return value;
    }
    return VGSingleCamIngestVulkanSpatialRenderSmokeDecision.nativeRenderFailed;
  }
}

/// Validates that [descriptor] has the exact 9 layout primitive fields
/// expected by the native layout engine with matching types.
///
/// Fails closed for missing keys, null map, or unexpected value types.
bool isValidDescriptorShape(Map<String, Object?>? descriptor) {
  if (descriptor == null) return false;
  final layoutMode = descriptor['layoutMode'];
  final pipAnchor = descriptor['pipAnchor'];
  final splitDirection = descriptor['splitDirection'];
  final pipCenterX = descriptor['pipCenterX'];
  final pipCenterY = descriptor['pipCenterY'];
  final pipWidthFraction = descriptor['pipWidthFraction'];
  final pipAspectRatio = descriptor['pipAspectRatio'];
  final pipMarginFraction = descriptor['pipMarginFraction'];
  final splitRatio = descriptor['splitRatio'];

  return layoutMode is String &&
      pipAnchor is String &&
      splitDirection is String &&
      pipCenterX is num &&
      pipCenterY is num &&
      pipWidthFraction is num &&
      pipAspectRatio is num &&
      pipMarginFraction is num &&
      splitRatio is num;
}

/// Typed report returned by the
/// `onAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmokeComplete` completion
/// callback and runner methods, mirroring the native harness's result map.
@immutable
class VGSingleCamIngestVulkanSpatialRenderSmokeReport {
  const VGSingleCamIngestVulkanSpatialRenderSmokeReport({
    required this.success,
    required this.started,
    required this.runId,
    required this.apiLevel,
    required this.hasCameraPermission,
    required this.attemptedOpen,
    required this.opened,
    required this.sessionConfigured,
    required this.repeatingStarted,
    required this.frameReceived,
    this.cameraId,
    required this.selectedLensFacing,
    required this.selectedWidth,
    required this.selectedHeight,
    required this.imageFormatName,
    required this.hardwareBufferAvailable,
    required this.hardwareBufferClosed,
    required this.imageClosed,
    required this.syncFenceAwaited,
    required this.syncFenceClosed,
    required this.nativeInvoked,
    required this.sessionClosed,
    required this.deviceClosed,
    required this.imageReaderClosed,
    required this.pass,
    required this.decision,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    this.lastError = '',
    required this.reasons,
    required this.events,
    required this.diagnostics,
    required this.durationMs,
    required this.raw,
    required this.gates,
    required this.details,
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_vulkan_render_readback_only_no_concurrent_camera_no_gles_no_recording_no_export_no_product';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_FAIL';

  /// MethodChannel method names owned by this route.
  static const String startMethodName =
      'startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke';
  static const String disposeMethodName =
      'disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke';
  static const String callbackMethodName =
      'onAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmokeComplete';

  /// Descriptor pass gate keys (strict resolution succeeded).
  static const List<String> descriptorPassGateKeys = <String>[
    'descriptorParseOk',
  ];

  /// Descriptor rejection gate keys (fail-closed rejection proven before any
  /// Vulkan scratch context or resource creation).
  static const List<String> descriptorRejectionGateKeys = <String>[
    'descriptorRejectedBeforeVulkanOk',
  ];

  /// Descriptor resolution gate keys.
  static const List<String> descriptorGateKeys = <String>[
    ...descriptorPassGateKeys,
    ...descriptorRejectionGateKeys,
  ];

  /// Setup gate keys (Vulkan scratch context & synthetic image creation).
  static const List<String> setupGateKeys = <String>[
    'vulkanSetupOk',
    'cameraImportOk',
    'syntheticImportOk',
  ];

  /// Render gate keys (layout conversion & render readback).
  static const List<String> renderGateKeys = <String>[
    'layoutConvertOk',
    'renderReadbackOk',
  ];

  /// Resource lifecycle gate keys.
  static const List<String> resourceLifecycleGateKeys = <String>[
    'helperResourcesReleasedOk',
    'diagnosticTeardownOk',
  ];

  /// Gate keys required to pass for a valid descriptor invocation.
  /// Note: [descriptorRejectedBeforeVulkanOk] is strictly excluded.
  static const List<String> validPassGateKeys = <String>[
    ...descriptorPassGateKeys,
    ...setupGateKeys,
    ...renderGateKeys,
    ...resourceLifecycleGateKeys,
  ];

  /// All gate keys in native emission order.
  static const List<String> allGateKeys = <String>[
    'descriptorParseOk',
    'descriptorRejectedBeforeVulkanOk',
    'vulkanSetupOk',
    'cameraImportOk',
    'syntheticImportOk',
    'layoutConvertOk',
    'renderReadbackOk',
    'helperResourcesReleasedOk',
    'diagnosticTeardownOk',
  ];

  /// Overall success flag computed from harness state.
  final bool success;

  /// Whether the native harness actually began running.
  final bool started;

  /// Unique monotonic run ID assigned by the coordinator.
  final int runId;

  /// `Build.VERSION.SDK_INT` on the probing device.
  final int apiLevel;

  /// Current `Manifest.permission.CAMERA` grant state.
  final bool hasCameraPermission;

  /// Whether the harness actually called `CameraManager.openCamera`.
  final bool attemptedOpen;

  /// Whether `onOpened` fired for the selected camera device.
  final bool opened;

  /// Whether the capture session reached `onConfigured`.
  final bool sessionConfigured;

  /// Whether `setRepeatingRequest` was called successfully.
  final bool repeatingStarted;

  /// Whether a single camera frame was received via `onImageAvailable`.
  final bool frameReceived;

  /// The selected/requested camera id, or `null` when unavailable.
  final String? cameraId;

  /// `front` / `back` / `external` / `unknown`.
  final String selectedLensFacing;

  /// The selected `ImageReader` output width in pixels.
  final int selectedWidth;

  /// The selected `ImageReader` output height in pixels.
  final int selectedHeight;

  /// Always `YUV_420_888` for this harness.
  final String imageFormatName;

  /// Whether `Image.getHardwareBuffer()` returned non-null for the acquired frame.
  final bool hardwareBufferAvailable;

  /// Whether the camera frame's `HardwareBuffer.close()` was invoked.
  final bool hardwareBufferClosed;

  /// Whether `Image.close()` was invoked.
  final bool imageClosed;

  /// Whether the API 33+ `Image.getFence()` sync fence was awaited.
  final bool syncFenceAwaited;

  /// Whether the API 33+ `Image.getFence()` sync fence was closed.
  final bool syncFenceClosed;

  /// Whether the native Vulkan route was actually invoked.
  final bool nativeInvoked;

  /// Whether the capture session was confirmed closed via `onClosed`.
  final bool sessionClosed;

  /// Whether the camera device was confirmed closed via `onClosed`.
  final bool deviceClosed;

  /// Whether `ImageReader.close()` was invoked.
  final bool imageReaderClosed;

  /// Native pass flag.
  final bool pass;

  /// Lifecycle decision enum value.
  final VGSingleCamIngestVulkanSpatialRenderSmokeDecision decision;

  /// Raw status string (`PASS`, `FAIL`, `UNSUPPORTED`, etc.).
  final String status;

  /// PASS/FAIL marker string emitted by native.
  final String marker;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Failure reason reported by native/harness, empty on pass.
  final String failureReason;

  /// Last error string, if any.
  final String lastError;

  /// Stable snake_case reason codes.
  final List<String> reasons;

  /// Ordered lifecycle event trace.
  final List<String> events;

  /// Diagnostic key/value pairs.
  final Map<String, Object?> diagnostics;

  /// Wall-clock duration of the harness run, in milliseconds.
  final int durationMs;

  /// Raw native return string (JSON).
  final String raw;

  /// Per-gate boolean results keyed by gate name.
  final Map<String, bool> gates;

  /// Diagnostic details map.
  final Map<String, Object?> details;

  // -- Gate getters --

  bool get descriptorParseOk => gates['descriptorParseOk'] == true;
  bool get descriptorRejectedBeforeVulkanOk =>
      gates['descriptorRejectedBeforeVulkanOk'] == true;
  bool get vulkanSetupOk => gates['vulkanSetupOk'] == true;
  bool get cameraImportOk => gates['cameraImportOk'] == true;
  bool get syntheticImportOk => gates['syntheticImportOk'] == true;
  bool get layoutConvertOk => gates['layoutConvertOk'] == true;
  bool get renderReadbackOk => gates['renderReadbackOk'] == true;
  bool get helperResourcesReleasedOk =>
      gates['helperResourcesReleasedOk'] == true;
  bool get diagnosticTeardownOk => gates['diagnosticTeardownOk'] == true;

  // Group getters
  bool get setupPass => setupGateKeys.every((k) => gates[k] == true);
  bool get renderPass => renderGateKeys.every((k) => gates[k] == true);
  bool get resourceLifecyclePass =>
      resourceLifecycleGateKeys.every((k) => gates[k] == true);

  // -- Convenience decision getters --

  bool get isPass =>
      decision ==
      VGSingleCamIngestVulkanSpatialRenderSmokeDecision
          .singleCamIngestVulkanSpatialRenderPassed;
  bool get isFail =>
      decision ==
      VGSingleCamIngestVulkanSpatialRenderSmokeDecision.nativeRenderFailed;
  bool get isUnsupported =>
      decision ==
      VGSingleCamIngestVulkanSpatialRenderSmokeDecision.nativeUnsupported;
  bool get isCameraIngestUnsupported =>
      decision ==
      VGSingleCamIngestVulkanSpatialRenderSmokeDecision.cameraIngestUnsupported;
  bool get isDescriptorRejected =>
      decision ==
      VGSingleCamIngestVulkanSpatialRenderSmokeDecision.descriptorRejected;
  bool get isMalformedDescriptorShape =>
      decision ==
      VGSingleCamIngestVulkanSpatialRenderSmokeDecision
          .malformedDescriptorShape;
  bool get isDisposed =>
      decision == VGSingleCamIngestVulkanSpatialRenderSmokeDecision.disposed;
  bool get isHarnessException =>
      decision ==
      VGSingleCamIngestVulkanSpatialRenderSmokeDecision.harnessException;
  bool get isPermissionDenied =>
      decision ==
      VGSingleCamIngestVulkanSpatialRenderSmokeDecision.cameraPermissionDenied;

  // -- Details getters --

  String get layoutModeResolved =>
      details['layoutModeResolved'] as String? ?? '';
  String get pipAnchorResolved => details['pipAnchorResolved'] as String? ?? '';
  String get splitDirectionResolved =>
      details['splitDirectionResolved'] as String? ?? '';
  String get rejectionReason => details['rejectionReason'] as String? ?? '';

  // -- Verification getters --

  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;
  bool get hasPassMarker => marker == passMarker;
  bool get hasFailMarker => marker == failMarker;

  /// Whether all camera resources were confirmed closed.
  bool get isCleanedUp => sessionClosed && deviceClosed && imageReaderClosed;

  /// Whether all valid-pass gates passed Dart-side, with descriptor rejection gate false.
  bool get allNativeLanesPass =>
      validPassGateKeys.every((k) => gates[k] == true) &&
      !descriptorRejectedBeforeVulkanOk;

  /// Valid PASS requires native pass=true and all valid-pass gates true;
  /// descriptorRejectedBeforeVulkanOk must NOT be required for valid pass.
  bool get isValidPass =>
      pass && validPassGateKeys.every((k) => gates[k] == true);

  /// Full verified PASS for a well-formed descriptor invocation.
  bool get isVerifiedPass =>
      pass &&
      success &&
      isPass &&
      allNativeLanesPass &&
      hasPassMarker &&
      hasCanonicalProofBoundary &&
      failureReason.isEmpty &&
      descriptorParseOk &&
      !descriptorRejectedBeforeVulkanOk &&
      vulkanSetupOk &&
      cameraImportOk &&
      syntheticImportOk &&
      layoutConvertOk &&
      renderReadbackOk &&
      helperResourcesReleasedOk &&
      diagnosticTeardownOk &&
      frameReceived &&
      hardwareBufferAvailable &&
      hardwareBufferClosed &&
      imageClosed &&
      nativeInvoked &&
      sessionClosed &&
      deviceClosed &&
      imageReaderClosed;

  /// Full verified descriptor rejection for a deliberately malformed/unknown
  /// descriptor that fails closed at native layout parse.
  bool get isVerifiedDescriptorRejection =>
      !pass &&
      !success &&
      (isDescriptorRejected || isFail) &&
      !descriptorParseOk &&
      descriptorRejectedBeforeVulkanOk &&
      !vulkanSetupOk &&
      !cameraImportOk &&
      !syntheticImportOk &&
      !layoutConvertOk &&
      !renderReadbackOk &&
      hasFailMarker &&
      !hasPassMarker &&
      hasCanonicalProofBoundary;

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// Factory for an unsupported route/driver report.
  factory VGSingleCamIngestVulkanSpatialRenderSmokeReport.unsupported(
    String reason, {
    int runId = -1,
  }) {
    return VGSingleCamIngestVulkanSpatialRenderSmokeReport(
      success: false,
      started: false,
      runId: runId,
      apiLevel: 0,
      hasCameraPermission: false,
      attemptedOpen: false,
      opened: false,
      sessionConfigured: false,
      repeatingStarted: false,
      frameReceived: false,
      cameraId: null,
      selectedLensFacing: 'unknown',
      selectedWidth: 0,
      selectedHeight: 0,
      imageFormatName: 'YUV_420_888',
      hardwareBufferAvailable: false,
      hardwareBufferClosed: false,
      imageClosed: false,
      syncFenceAwaited: false,
      syncFenceClosed: false,
      nativeInvoked: false,
      sessionClosed: false,
      deviceClosed: false,
      imageReaderClosed: false,
      pass: false,
      decision:
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision.nativeUnsupported,
      status: 'UNSUPPORTED',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      lastError: reason,
      reasons: <String>[reason],
      events: const <String>[],
      diagnostics: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
      }),
      durationMs: 0,
      raw: '{"pass":false,"status":"UNSUPPORTED","failureReason":"$reason"}',
      gates: _allFalseGates(),
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
        'vulkanUnsupported': true,
      }),
    );
  }

  /// Factory for a harness failure (exception, timeout, malformed payload).
  factory VGSingleCamIngestVulkanSpatialRenderSmokeReport.harnessFailure(
    String reason, {
    int runId = -1,
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGSingleCamIngestVulkanSpatialRenderSmokeReport(
      success: false,
      started: false,
      runId: runId,
      apiLevel: 0,
      hasCameraPermission: false,
      attemptedOpen: false,
      opened: false,
      sessionConfigured: false,
      repeatingStarted: false,
      frameReceived: false,
      cameraId: null,
      selectedLensFacing: 'unknown',
      selectedWidth: 0,
      selectedHeight: 0,
      imageFormatName: 'YUV_420_888',
      hardwareBufferAvailable: false,
      hardwareBufferClosed: false,
      imageClosed: false,
      syncFenceAwaited: false,
      syncFenceClosed: false,
      nativeInvoked: false,
      sessionClosed: false,
      deviceClosed: false,
      imageReaderClosed: false,
      pass: false,
      decision:
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision.harnessException,
      status: 'FAIL',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      lastError: reason,
      reasons: <String>[reason],
      events: const <String>[],
      diagnostics: Map<String, Object?>.unmodifiable(<String, Object?>{
        'error': reason,
      }),
      durationMs: 0,
      raw: '{"pass":false,"status":"FAIL","failureReason":"$reason"}',
      gates: _allFalseGates(),
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
        ...extraDetails,
      }),
    );
  }

  /// Factory for a shape-malformed descriptor failure (failed before channel invocation).
  factory VGSingleCamIngestVulkanSpatialRenderSmokeReport.malformedDescriptorShape(
    String reason, {
    int runId = -1,
  }) {
    return VGSingleCamIngestVulkanSpatialRenderSmokeReport(
      success: false,
      started: false,
      runId: runId,
      apiLevel: 0,
      hasCameraPermission: false,
      attemptedOpen: false,
      opened: false,
      sessionConfigured: false,
      repeatingStarted: false,
      frameReceived: false,
      cameraId: null,
      selectedLensFacing: 'unknown',
      selectedWidth: 0,
      selectedHeight: 0,
      imageFormatName: 'YUV_420_888',
      hardwareBufferAvailable: false,
      hardwareBufferClosed: false,
      imageClosed: false,
      syncFenceAwaited: false,
      syncFenceClosed: false,
      nativeInvoked: false,
      sessionClosed: false,
      deviceClosed: false,
      imageReaderClosed: false,
      pass: false,
      decision: VGSingleCamIngestVulkanSpatialRenderSmokeDecision
          .malformedDescriptorShape,
      status: 'FAIL',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      lastError: reason,
      reasons: <String>[reason],
      events: const <String>[],
      diagnostics: const <String, Object?>{},
      durationMs: 0,
      raw: '{"pass":false,"status":"FAIL","failureReason":"$reason"}',
      gates: _allFalseGates(),
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
      }),
    );
  }

  /// Parses a report from a raw map. Defensive against non-map, null, or missing fields.
  static VGSingleCamIngestVulkanSpatialRenderSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGSingleCamIngestVulkanSpatialRenderSmokeReport.harnessFailure(
        'native_result_not_a_map',
      );
    }

    final pass = raw['pass'] as bool? ?? false;
    final success = raw['success'] as bool? ?? false;
    final started = raw['started'] as bool? ?? false;
    final runId = (raw['runId'] as num?)?.toInt() ?? -1;
    final apiLevel = (raw['apiLevel'] as num?)?.toInt() ?? 0;
    final hasCameraPermission = raw['hasCameraPermission'] as bool? ?? false;
    final attemptedOpen = raw['attemptedOpen'] as bool? ?? false;
    final opened = raw['opened'] as bool? ?? false;
    final sessionConfigured = raw['sessionConfigured'] as bool? ?? false;
    final repeatingStarted = raw['repeatingStarted'] as bool? ?? false;
    final frameReceived = raw['frameReceived'] as bool? ?? false;
    final cameraId = raw['cameraId'] as String?;
    final selectedLensFacing =
        (raw['selectedLensFacing'] as String?) ?? 'unknown';
    final selectedWidth = (raw['selectedWidth'] as num?)?.toInt() ?? 0;
    final selectedHeight = (raw['selectedHeight'] as num?)?.toInt() ?? 0;
    final imageFormatName =
        (raw['imageFormatName'] as String?) ?? 'YUV_420_888';
    final hardwareBufferAvailable =
        raw['hardwareBufferAvailable'] as bool? ?? false;
    final hardwareBufferClosed = raw['hardwareBufferClosed'] as bool? ?? false;
    final imageClosed = raw['imageClosed'] as bool? ?? false;
    final syncFenceAwaited = raw['syncFenceAwaited'] as bool? ?? false;
    final syncFenceClosed = raw['syncFenceClosed'] as bool? ?? false;
    final nativeInvoked = raw['nativeInvoked'] as bool? ?? false;
    final sessionClosed = raw['sessionClosed'] as bool? ?? false;
    final deviceClosed = raw['deviceClosed'] as bool? ?? false;
    final imageReaderClosed = raw['imageReaderClosed'] as bool? ?? false;

    final status = (raw['status'] as String?) ?? (pass ? 'PASS' : 'FAIL');
    final marker =
        (raw['marker'] as String?) ?? (pass ? passMarker : failMarker);
    final proofBoundary = (raw['proofBoundary'] as String?) ?? '';
    final failureReason = (raw['failureReason'] as String?) ?? '';
    final lastError = (raw['lastError'] as String?) ?? failureReason;
    final durationMs = (raw['durationMs'] as num?)?.toInt() ?? 0;
    final rawString = (raw['raw'] as String?) ?? '';

    final decision = VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw(
      raw['decision'] ??
          (pass ? 'pass' : (status == 'UNSUPPORTED' ? 'unsupported' : 'fail')),
    );

    final reasonsRaw = raw['reasons'];
    final reasons = reasonsRaw is List
        ? reasonsRaw
              .whereType<Object>()
              .map((e) => e.toString())
              .toList(growable: false)
        : const <String>[];

    final eventsRaw = raw['events'];
    final events = eventsRaw is List
        ? eventsRaw
              .whereType<Object>()
              .map((e) => e.toString())
              .toList(growable: false)
        : const <String>[];

    final diagnosticsRaw = raw['diagnostics'];
    final diagnostics = diagnosticsRaw is Map
        ? Map<String, Object?>.from(diagnosticsRaw)
        : const <String, Object?>{};

    final detailsRaw = raw['details'];
    final details = detailsRaw is Map
        ? Map<String, Object?>.from(detailsRaw)
        : const <String, Object?>{};

    final gates = <String, bool>{};
    for (final key in allGateKeys) {
      gates[key] = raw[key] == true || raw[key] == 'true';
    }

    return VGSingleCamIngestVulkanSpatialRenderSmokeReport(
      success: success,
      started: started,
      runId: runId,
      apiLevel: apiLevel,
      hasCameraPermission: hasCameraPermission,
      attemptedOpen: attemptedOpen,
      opened: opened,
      sessionConfigured: sessionConfigured,
      repeatingStarted: repeatingStarted,
      frameReceived: frameReceived,
      cameraId: cameraId,
      selectedLensFacing: selectedLensFacing,
      selectedWidth: selectedWidth,
      selectedHeight: selectedHeight,
      imageFormatName: imageFormatName,
      hardwareBufferAvailable: hardwareBufferAvailable,
      hardwareBufferClosed: hardwareBufferClosed,
      imageClosed: imageClosed,
      syncFenceAwaited: syncFenceAwaited,
      syncFenceClosed: syncFenceClosed,
      nativeInvoked: nativeInvoked,
      sessionClosed: sessionClosed,
      deviceClosed: deviceClosed,
      imageReaderClosed: imageReaderClosed,
      pass: pass,
      decision: decision,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      lastError: lastError,
      reasons: reasons,
      events: events,
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
      durationMs: durationMs,
      raw: rawString,
      gates: Map<String, bool>.unmodifiable(gates),
      details: Map<String, Object?>.unmodifiable(details),
    );
  }

  /// Serializes the report to a Map (round-trips through [fromMap]).
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'success': success,
      'started': started,
      'runId': runId,
      'apiLevel': apiLevel,
      'hasCameraPermission': hasCameraPermission,
      'attemptedOpen': attemptedOpen,
      'opened': opened,
      'sessionConfigured': sessionConfigured,
      'repeatingStarted': repeatingStarted,
      'frameReceived': frameReceived,
      'cameraId': cameraId,
      'selectedLensFacing': selectedLensFacing,
      'selectedWidth': selectedWidth,
      'selectedHeight': selectedHeight,
      'imageFormatName': imageFormatName,
      'hardwareBufferAvailable': hardwareBufferAvailable,
      'hardwareBufferClosed': hardwareBufferClosed,
      'imageClosed': imageClosed,
      'syncFenceAwaited': syncFenceAwaited,
      'syncFenceClosed': syncFenceClosed,
      'nativeInvoked': nativeInvoked,
      'sessionClosed': sessionClosed,
      'deviceClosed': deviceClosed,
      'imageReaderClosed': imageReaderClosed,
      'pass': pass,
      'decision': decision.name,
      'status': status,
      'marker': marker,
      'proofBoundary': proofBoundary,
      'failureReason': failureReason,
      'lastError': lastError,
      'reasons': reasons,
      'events': events,
      'diagnostics': diagnostics,
      'durationMs': durationMs,
      'raw': raw,
      for (final key in allGateKeys) key: gates[key] == true,
      'details': details,
    };
  }

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Starts the Android True-DAG Phase 3 single-camera-ingest Vulkan spatial render smoke harness.
  ///
  /// [descriptor] is the raw primitive Dart layout descriptor map.
  /// Validates descriptor shape and fails before channel invocation if malformed.
  ///
  /// Returns a record with the allocated [runId], [maxWidth], and [maxHeight].
  static Future<({int runId, int maxWidth, int maxHeight})>
  startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke({
    required Map<String, Object?> descriptor,
    String? cameraId,
    int maxWidth = 640,
    int maxHeight = 480,
    Duration timeout = const Duration(seconds: 10),
    MethodChannel? channel,
  }) async {
    if (!isValidDescriptorShape(descriptor)) {
      throw ArgumentError(
        'Descriptor shape is malformed: all 9 layout descriptor fields must be provided with valid types',
      );
    }
    final ch = channel ?? _defaultChannel;
    final raw = await ch
        .invokeMethod<Object?>(startMethodName, <String, Object?>{
          'descriptor': descriptor,
          'cameraId': ?cameraId,
          'maxWidth': maxWidth,
          'maxHeight': maxHeight,
          'timeoutMs': timeout.inMilliseconds,
        });
    final map = raw is Map ? raw : const <Object?, Object?>{};
    final runId = (map['runId'] as num?)?.toInt() ?? -1;
    return (runId: runId, maxWidth: maxWidth, maxHeight: maxHeight);
  }

  /// Disposes the active single-camera-ingest Vulkan spatial render smoke run for [runId].
  ///
  /// [runId] is required and must not be null.
  /// Returns `true` on successful disposal confirmation or idempotent already-disposed state.
  static Future<bool>
  disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke({
    required int? runId,
    MethodChannel? channel,
  }) async {
    if (runId == null) {
      throw ArgumentError.notNull('runId');
    }
    final ch = channel ?? _defaultChannel;
    final raw = await ch.invokeMethod<Object?>(
      disposeMethodName,
      <String, Object?>{'runId': runId},
    );
    final map = raw is Map ? raw : const <Object?, Object?>{};
    return map['pass'] as bool? ?? false;
  }

  /// One-shot execution of the Phase 3 single-camera-ingest Vulkan spatial render smoke
  /// using a typed [VGMultiCamDynamicDescriptorSpatialRenderInput].
  static Future<VGSingleCamIngestVulkanSpatialRenderSmokeReport>
  runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke({
    required VGMultiCamDynamicDescriptorSpatialRenderInput descriptor,
    String? cameraId,
    int maxWidth = 640,
    int maxHeight = 480,
    Duration timeout = const Duration(seconds: 10),
    MethodChannel? channel,
  }) {
    return runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmokeWithRawDescriptor(
      descriptor.toMap(),
      cameraId: cameraId,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      timeout: timeout,
      channel: channel,
    );
  }

  /// One-shot execution of the smoke using a raw descriptor map.
  ///
  /// Allows exercising the native fail-closed rejection lane with well-typed
  /// but unrecognized enum values. Shape-malformed descriptors fail closed
  /// before invoking the method channel.
  static Future<VGSingleCamIngestVulkanSpatialRenderSmokeReport>
  runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmokeWithRawDescriptor(
    Map<String, Object?> rawDescriptor, {
    String? cameraId,
    int maxWidth = 640,
    int maxHeight = 480,
    Duration timeout = const Duration(seconds: 10),
    MethodChannel? channel,
  }) async {
    if (!isValidDescriptorShape(rawDescriptor)) {
      return VGSingleCamIngestVulkanSpatialRenderSmokeReport.malformedDescriptorShape(
        'malformed_descriptor_shape',
      );
    }

    final ch = channel ?? _defaultChannel;
    final completer = Completer<Map<String, Object?>>();
    int? activeRunId;

    ch.setMethodCallHandler((call) async {
      if (call.method == callbackMethodName) {
        if (!completer.isCompleted) {
          final args = call.arguments;
          completer.complete(
            args is Map ? Map<String, Object?>.from(args) : <String, Object?>{},
          );
        }
      }
    });

    try {
      final startResult =
          await startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
            descriptor: rawDescriptor,
            cameraId: cameraId,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            timeout: timeout,
            channel: ch,
          );
      activeRunId = startResult.runId;

      final completionPayload = await completer.future.timeout(
        timeout + const Duration(seconds: 5),
      );
      return VGSingleCamIngestVulkanSpatialRenderSmokeReport.fromMap(
        completionPayload,
      );
    } on TimeoutException catch (te) {
      return VGSingleCamIngestVulkanSpatialRenderSmokeReport.harnessFailure(
        'timeout',
        runId: activeRunId ?? -1,
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGSingleCamIngestVulkanSpatialRenderSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
        runId: activeRunId ?? -1,
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGSingleCamIngestVulkanSpatialRenderSmokeReport.unsupported(
          'platform_exception:${pe.code}',
          runId: activeRunId ?? -1,
        );
      }
      return VGSingleCamIngestVulkanSpatialRenderSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        runId: activeRunId ?? -1,
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGSingleCamIngestVulkanSpatialRenderSmokeReport.harnessFailure(
        'exception:$e',
        runId: activeRunId ?? -1,
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    } finally {
      ch.setMethodCallHandler(null);
      if (activeRunId != null && activeRunId > 0) {
        try {
          await disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
            runId: activeRunId,
            channel: ch,
          );
        } catch (_) {}
      }
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGSingleCamIngestVulkanSpatialRenderSmokeReport &&
        other.success == success &&
        other.started == started &&
        other.runId == runId &&
        other.apiLevel == apiLevel &&
        other.hasCameraPermission == hasCameraPermission &&
        other.attemptedOpen == attemptedOpen &&
        other.opened == opened &&
        other.sessionConfigured == sessionConfigured &&
        other.repeatingStarted == repeatingStarted &&
        other.frameReceived == frameReceived &&
        other.cameraId == cameraId &&
        other.selectedLensFacing == selectedLensFacing &&
        other.selectedWidth == selectedWidth &&
        other.selectedHeight == selectedHeight &&
        other.imageFormatName == imageFormatName &&
        other.hardwareBufferAvailable == hardwareBufferAvailable &&
        other.hardwareBufferClosed == hardwareBufferClosed &&
        other.imageClosed == imageClosed &&
        other.syncFenceAwaited == syncFenceAwaited &&
        other.syncFenceClosed == syncFenceClosed &&
        other.nativeInvoked == nativeInvoked &&
        other.sessionClosed == sessionClosed &&
        other.deviceClosed == deviceClosed &&
        other.imageReaderClosed == imageReaderClosed &&
        other.pass == pass &&
        other.decision == decision &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.lastError == lastError &&
        listEquals(other.reasons, reasons) &&
        listEquals(other.events, events) &&
        mapEquals(other.diagnostics, diagnostics) &&
        other.durationMs == durationMs &&
        other.raw == raw &&
        mapEquals(other.gates, gates) &&
        mapEquals(other.details, details);
  }

  @override
  int get hashCode {
    final identityHash = Object.hash(
      success,
      started,
      runId,
      apiLevel,
      hasCameraPermission,
      attemptedOpen,
      opened,
      sessionConfigured,
      repeatingStarted,
      frameReceived,
      cameraId,
      selectedLensFacing,
      selectedWidth,
      selectedHeight,
      imageFormatName,
    );
    final bufferHash = Object.hash(
      hardwareBufferAvailable,
      hardwareBufferClosed,
      imageClosed,
      syncFenceAwaited,
      syncFenceClosed,
      nativeInvoked,
    );
    final lifecycleHash = Object.hash(
      sessionClosed,
      deviceClosed,
      imageReaderClosed,
      pass,
      decision,
      status,
      marker,
      proofBoundary,
      failureReason,
      lastError,
      Object.hashAll(reasons),
      Object.hashAll(events),
      _stableMapHash(diagnostics),
      durationMs,
    );
    final gateHash = Object.hash(
      raw,
      _stableMapHash(gates),
      _stableMapHash(details),
    );
    return Object.hash(identityHash, bufferHash, lifecycleHash, gateHash);
  }

  static int _stableMapHash(Map<Object?, Object?> map) {
    final sortedKeys = map.keys.toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGSingleCamIngestVulkanSpatialRenderSmokeReport('
      'success: $success, '
      'started: $started, '
      'runId: $runId, '
      'pass: $pass, '
      'decision: $decision, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'gates: $gates, '
      'details: $details)';
}
