// vg_single_cam_ingest_spatial_render_smoke.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-SINGLE-CAM-INGEST-DESCRIPTOR-
// SPATIAL-RENDER: Android True-DAG V4.3 Phase 3 bounded diagnostic proof that
// one real Camera2 `ImageReader(YUV_420_888)` buffer-queue frame plus one
// synthetic `RGBA_8888` HardwareBuffer are laid out by a caller-supplied Dart
// layout descriptor through the existing `ComputeMultiCamLayout()`, rendered
// by the existing GLES/OES spatial compositor, structurally read back, and
// presented to a Flutter `TextureRegistry.SurfaceProducer`.
//
// Pure Dart typed model + invocation wrapper over the native
// `startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke` /
// `disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke` MethodChannel
// routes. Reuses the existing
// [VGMultiCamDynamicDescriptorSpatialRenderInput] typed descriptor (same
// primitive field shape: layoutMode, pipAnchor, pipCenterX, pipCenterY,
// pipWidthFraction, pipAspectRatio, pipMarginFraction, splitDirection,
// splitRatio) since native's descriptor-parse/layout pipeline is identical.
//
// Unlike that dynamic-descriptor route (whose primary/secondary texture
// assignment flips with layoutMode), this route's assignment is fixed: the
// real camera YUV_420_888 buffer is always the OES primary; the synthetic
// RGBA_8888 buffer (native-filled solid opaque blue) is always the 2D
// secondary, regardless of layoutMode. Camera-side readback assertions are
// structural only (resolved OES target, render/readback success) -- never
// hue/luma/content, since the real camera frame's pixel content is
// unconstrained; the synthetic secondary additionally asserts deterministic
// blue.
//
// Proof boundary (exact):
// single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_concurrent_camera_no_vulkan_no_recording_no_export_no_product
//
// No concurrent/dual camera, no Vulkan, no recording/export, and no
// product/editor UI.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_multicam_dynamic_descriptor_spatial_render_smoke.dart'
    show VGMultiCamDynamicDescriptorSpatialRenderInput;

export 'vg_multicam_dynamic_descriptor_spatial_render_smoke.dart'
    show VGMultiCamDynamicDescriptorSpatialRenderInput;

/// Decision produced by the native Phase 3 single-camera-ingest dynamic-
/// descriptor spatial render smoke harness.
enum VGSingleCamIngestSpatialRenderSmokeDecision {
  /// Full pass: camera frame ingested, descriptor accepted, native
  /// render/readback/present/release/shutdown all succeeded.
  singleCamIngestSpatialRenderPassed,

  /// `Build.VERSION.SDK_INT` is below 29 (Q); no open was attempted.
  apiUnsupported,

  /// The caller's descriptor map failed Kotlin's shape/type guard (missing
  /// key or wrong type); no camera open was attempted.
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

  /// The Flutter `SurfaceProducer`'s `Surface` could not be obtained.
  surfaceUnavailable,

  /// The synthetic secondary `RGBA_8888` `HardwareBuffer` could not be
  /// allocated.
  syntheticBufferAllocationFailed,

  /// `onDisconnected` fired during the open attempt.
  openDisconnected,

  /// `onError` fired during the open attempt.
  openError,

  /// The open attempt did not reach a terminal callback state in time.
  cameraOpenTimeout,

  /// `onConfigureFailed` fired for the capture session, or session creation
  /// threw.
  sessionConfigureFailed,

  /// The capture session did not reach a terminal configuration state in
  /// time.
  sessionConfigureTimeout,

  /// `setRepeatingRequest` threw.
  repeatingRequestFailed,

  /// No frame arrived via `onImageAvailable` in time.
  noFrameWithinTimeout,

  /// `onCaptureFailed` fired for the repeating request.
  captureFailed,

  /// The acquired `Image.getHardwareBuffer()` was null, or native could not
  /// describe/import the camera buffer as `GL_TEXTURE_EXTERNAL_OES` --
  /// device/format cannot ingest this camera's `YUV_420_888` buffer.
  cameraIngestUnsupported,

  /// Native's strict layoutMode/pipAnchor/splitDirection resolver rejected
  /// an unrecognized descriptor value before any AHardwareBuffer import or
  /// GLES work began -- the camera frame was still fully captured first.
  descriptorRejected,

  /// A native lane failed for a reason other than the camera-ingest or
  /// descriptor-parse cases above.
  nativeRenderFailed,

  /// The run was cancelled via dispose before/while it was still active.
  disposed;

  /// Maps a raw native/Kotlin decision string to the matching enum value,
  /// falling back to [nativeRenderFailed] for unrecognised/missing values.
  static VGSingleCamIngestSpatialRenderSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGSingleCamIngestSpatialRenderSmokeDecision.nativeRenderFailed;
    }
    switch (raw) {
      case 'no_supported_yuv_size':
        return VGSingleCamIngestSpatialRenderSmokeDecision.noSupportedYuvSize;
      case 'camera_open_timeout':
        return VGSingleCamIngestSpatialRenderSmokeDecision.cameraOpenTimeout;
      case 'no_frame_within_timeout':
        return VGSingleCamIngestSpatialRenderSmokeDecision.noFrameWithinTimeout;
    }
    for (final value in VGSingleCamIngestSpatialRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGSingleCamIngestSpatialRenderSmokeDecision.nativeRenderFailed;
  }
}

/// Typed report returned by the
/// `onAndroidDagPhase3SingleCamIngestSpatialRenderSmokeComplete` completion
/// callback, mirroring the native harness's result map.
@immutable
class VGSingleCamIngestSpatialRenderSmokeReport {
  const VGSingleCamIngestSpatialRenderSmokeReport({
    required this.success,
    required this.started,
    required this.textureId,
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
    required this.syntheticBufferAllocated,
    required this.syntheticBufferClosed,
    required this.nativeInvoked,
    required this.sessionClosed,
    required this.deviceClosed,
    required this.imageReaderClosed,
    required this.surfaceProducerReleased,
    required this.decision,
    required this.reasons,
    required this.events,
    required this.diagnostics,
    required this.durationMs,
    required this.proofBoundary,
    required this.raw,
    required this.metrics,
    this.lastError = '',
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_concurrent_camera_no_vulkan_no_recording_no_export_no_product';

  /// Whether the native harness reached
  /// [VGSingleCamIngestSpatialRenderSmokeDecision.singleCamIngestSpatialRenderPassed]
  /// with the camera frame ingested and every native lane passing.
  final bool success;

  /// Whether the native harness actually began running.
  final bool started;

  /// The Flutter `TextureRegistry.SurfaceProducer` texture id this run
  /// rendered into.
  final int textureId;

  /// `Build.VERSION.SDK_INT` on the probing device.
  final int apiLevel;

  /// Current `Manifest.permission.CAMERA` grant state -- queried without
  /// prompting.
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

  /// The selected/requested camera id, or `null` when no camera could be
  /// selected.
  final String? cameraId;

  /// `front` / `back` / `external` / `unknown`.
  final String selectedLensFacing;

  /// The selected `ImageReader` output width in pixels.
  final int selectedWidth;

  /// The selected `ImageReader` output height in pixels.
  final int selectedHeight;

  /// Always `YUV_420_888` for this harness.
  final String imageFormatName;

  /// Whether `Image.getHardwareBuffer()` returned non-null for the acquired
  /// frame.
  final bool hardwareBufferAvailable;

  /// Whether the camera frame's `HardwareBuffer.close()` was invoked.
  final bool hardwareBufferClosed;

  /// Whether `Image.close()` was invoked.
  final bool imageClosed;

  /// Whether the API 33+ `Image.getFence()` sync fence was awaited.
  final bool syncFenceAwaited;

  /// Whether the API 33+ `Image.getFence()` sync fence was closed.
  final bool syncFenceClosed;

  /// Whether the synthetic secondary `RGBA_8888` `HardwareBuffer` was
  /// allocated.
  final bool syntheticBufferAllocated;

  /// Whether the synthetic secondary `HardwareBuffer.close()` was invoked.
  final bool syntheticBufferClosed;

  /// Whether the native route was actually invoked for the captured frame.
  final bool nativeInvoked;

  /// Whether the capture session was confirmed closed via `onClosed`.
  final bool sessionClosed;

  /// Whether the camera device was confirmed closed via `onClosed`.
  final bool deviceClosed;

  /// Whether `ImageReader.close()` was invoked.
  final bool imageReaderClosed;

  /// Whether the Flutter `SurfaceProducer` was released. Always `false` on a
  /// normal completion report -- the coordinator's dispose call is the sole
  /// releaser.
  final bool surfaceProducerReleased;

  /// The lifecycle decision.
  final VGSingleCamIngestSpatialRenderSmokeDecision decision;

  /// Stable snake_case reason codes explaining [decision].
  final List<String> reasons;

  /// Ordered lifecycle event trace.
  final List<String> events;

  /// Additional diagnostic key/value pairs.
  final Map<String, Object?> diagnostics;

  /// Wall-clock duration of the harness run, in milliseconds.
  final int durationMs;

  /// Proof boundary string emitted alongside the native raw result.
  final String proofBoundary;

  /// Raw native return string, or `""` if native was never invoked.
  final String raw;

  /// Key/value metrics map parsed from [raw].
  final Map<String, String> metrics;

  /// Last error string from native execution, if any.
  final String lastError;

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  // -- Camera-side native lanes --

  bool get cameraDescribePass => metrics['cameraDescribe'] == 'success';
  bool get cameraFormatIsYcbcr420 =>
      metrics['cameraFormatIsYcbcr420'] == 'true';
  bool get importCameraPass => metrics['importCamera'] == 'success';

  // -- Synthetic-secondary native lanes --

  bool get rgbaDescribePass => metrics['rgbaDescribe'] == 'success';
  bool get rgbaFillPass => metrics['rgbaFill'] == 'success';
  bool get importRgbaPass => metrics['importRgba'] == 'success';

  bool get initializePass => metrics['initialize'] == 'success';
  bool get attachPass => metrics['attach'] == 'success';

  // -- Descriptor Parse & Layout Conversion Lanes --

  /// Whether native accepted the descriptor's layoutMode/pipAnchor/
  /// splitDirection strings (fails closed for unrecognized values).
  bool get descriptorParsePass => metrics['descriptorParse'] == 'success';

  /// Resolved layout mode string ("pip"/"splitScreen"), or "" if unresolved.
  String get layoutModeResolved => metrics['layoutModeResolved'] ?? '';

  /// Resolved PiP anchor string, or "" if unresolved.
  String get anchorResolved => metrics['anchorResolved'] ?? '';

  /// Resolved split direction string, or "" if unresolved.
  String get directionResolved => metrics['directionResolved'] ?? '';

  /// Whether native's normalized-to-pixel-rect layout conversion succeeded.
  bool get layoutConvertPass => metrics['layoutConvert'] == 'success';

  int get primaryRectX => int.tryParse(metrics['primaryRectX'] ?? '') ?? 0;
  int get primaryRectY => int.tryParse(metrics['primaryRectY'] ?? '') ?? 0;
  int get primaryRectWidth => int.tryParse(metrics['primaryRectW'] ?? '') ?? 0;
  int get primaryRectHeight => int.tryParse(metrics['primaryRectH'] ?? '') ?? 0;
  int get secondaryRectX => int.tryParse(metrics['secondaryRectX'] ?? '') ?? 0;
  int get secondaryRectY => int.tryParse(metrics['secondaryRectY'] ?? '') ?? 0;
  int get secondaryRectWidth =>
      int.tryParse(metrics['secondaryRectW'] ?? '') ?? 0;
  int get secondaryRectHeight =>
      int.tryParse(metrics['secondaryRectH'] ?? '') ?? 0;

  // -- Render / Readback Lanes --

  /// Whether the descriptor-driven spatial composite draw call succeeded.
  bool get renderDrawPass => metrics['renderDraw'] == 'success';

  /// Whether the resolved GL texture target for the camera (always
  /// primary) handle was `GL_TEXTURE_EXTERNAL_OES`.
  bool get primaryTargetOkPass => metrics['primaryTargetOk'] == 'true';

  /// Whether the resolved GL texture target for the synthetic (always
  /// secondary) handle was `GL_TEXTURE_2D`.
  bool get secondaryTargetOkPass => metrics['secondaryTargetOk'] == 'true';

  /// Whether the camera-side (structural-only) sample point read back
  /// successfully.
  bool get primarySampleReadOkPass => metrics['primarySampleReadOk'] == 'true';

  /// Whether the synthetic-side sample point read back successfully.
  bool get secondarySampleReadOkPass =>
      metrics['secondarySampleReadOk'] == 'true';

  /// Whether the synthetic secondary's sampled color matched the expected
  /// deterministic solid blue. Never asserted for the camera side.
  bool get secondaryColorOkPass => metrics['secondaryColorOk'] == 'true';

  /// Whether the final draw+swap present lane succeeded.
  bool get presentLanePass => metrics['presentLane'] == 'success';

  // -- Release & Teardown Lanes --

  bool get releaseCameraPass => metrics['releaseCamera'] == 'success';
  bool get releaseRgbaPass => metrics['releaseRgba'] == 'success';
  bool get hasCameraAfterReleasePass =>
      metrics['hasCameraAfterRelease'] == 'false';
  bool get hasRgbaAfterReleasePass => metrics['hasRgbaAfterRelease'] == 'false';

  /// Whether the post-release invalid-handle lane correctly rejected a
  /// render attempt using already-released handles.
  bool get postReleaseLanePass =>
      metrics['postReleaseLane'] == 'rejected_as_expected';

  bool get detachPass => metrics['detach'] == 'success';
  bool get shutdownPass => metrics['shutdown'] == 'success';
  bool get idempotentShutdownPass => metrics['idempotentShutdown'] == 'success';

  /// Whether all native diagnostic lanes for a well-formed descriptor
  /// passed. Not meaningful for the intentionally malformed descriptor
  /// lane, whose expected outcome is [descriptorParsePass] == false with
  /// [decision] == [VGSingleCamIngestSpatialRenderSmokeDecision.descriptorRejected].
  bool get allNativeLanesPass =>
      cameraDescribePass &&
      cameraFormatIsYcbcr420 &&
      rgbaDescribePass &&
      rgbaFillPass &&
      initializePass &&
      attachPass &&
      importCameraPass &&
      importRgbaPass &&
      descriptorParsePass &&
      layoutConvertPass &&
      renderDrawPass &&
      primaryTargetOkPass &&
      secondaryTargetOkPass &&
      primarySampleReadOkPass &&
      secondarySampleReadOkPass &&
      secondaryColorOkPass &&
      presentLanePass &&
      releaseCameraPass &&
      releaseRgbaPass &&
      hasCameraAfterReleasePass &&
      hasRgbaAfterReleasePass &&
      postReleaseLanePass &&
      detachPass &&
      shutdownPass &&
      idempotentShutdownPass;

  /// Convenience getter for whether [decision] is
  /// [VGSingleCamIngestSpatialRenderSmokeDecision.singleCamIngestSpatialRenderPassed].
  bool get isPass =>
      decision ==
      VGSingleCamIngestSpatialRenderSmokeDecision
          .singleCamIngestSpatialRenderPassed;

  /// Convenience getter for whether [decision] is
  /// [VGSingleCamIngestSpatialRenderSmokeDecision.cameraPermissionDenied].
  bool get isPermissionDenied =>
      decision ==
      VGSingleCamIngestSpatialRenderSmokeDecision.cameraPermissionDenied;

  /// Convenience getter for whether [decision] is
  /// [VGSingleCamIngestSpatialRenderSmokeDecision.descriptorRejected].
  bool get isDescriptorRejected =>
      decision ==
      VGSingleCamIngestSpatialRenderSmokeDecision.descriptorRejected;

  /// Convenience getter for whether [decision] is
  /// [VGSingleCamIngestSpatialRenderSmokeDecision.cameraIngestUnsupported].
  bool get isCameraIngestUnsupported =>
      decision ==
      VGSingleCamIngestSpatialRenderSmokeDecision.cameraIngestUnsupported;

  /// Convenience getter for whether [decision] is
  /// [VGSingleCamIngestSpatialRenderSmokeDecision.disposed].
  bool get isDisposed =>
      decision == VGSingleCamIngestSpatialRenderSmokeDecision.disposed;

  /// Whether the capture session, device, ImageReader, and synthetic buffer
  /// were all confirmed torn down.
  bool get isCleanedUp =>
      sessionClosed &&
      deviceClosed &&
      imageReaderClosed &&
      syntheticBufferClosed;

  /// Parses a report from the raw native map. Defensive against both
  /// `Map<Object?, Object?>` and `Map<String, Object?>` shapes, and against
  /// missing/malformed fields.
  static VGSingleCamIngestSpatialRenderSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGSingleCamIngestSpatialRenderSmokeReport(
        success: false,
        started: false,
        textureId: -1,
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
        syntheticBufferAllocated: false,
        syntheticBufferClosed: false,
        nativeInvoked: false,
        sessionClosed: false,
        deviceClosed: false,
        imageReaderClosed: false,
        surfaceProducerReleased: false,
        decision:
            VGSingleCamIngestSpatialRenderSmokeDecision.nativeRenderFailed,
        reasons: const <String>['native_result_not_a_map'],
        events: const <String>[],
        diagnostics: <String, Object?>{'raw': raw},
        durationMs: 0,
        proofBoundary: '',
        raw: '',
        metrics: const <String, String>{},
        lastError: 'native_result_not_a_map',
      );
    }

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

    final metricsRaw = raw['metrics'];
    final metrics = <String, String>{};
    if (metricsRaw is Map) {
      for (final entry in metricsRaw.entries) {
        final k = entry.key?.toString();
        final v = entry.value?.toString();
        if (k != null && v != null) {
          metrics[k] = v;
        }
      }
    }

    return VGSingleCamIngestSpatialRenderSmokeReport(
      success: raw['success'] as bool? ?? false,
      started: raw['started'] as bool? ?? false,
      textureId: (raw['textureId'] as num?)?.toInt() ?? -1,
      apiLevel: (raw['apiLevel'] as num?)?.toInt() ?? 0,
      hasCameraPermission: raw['hasCameraPermission'] as bool? ?? false,
      attemptedOpen: raw['attemptedOpen'] as bool? ?? false,
      opened: raw['opened'] as bool? ?? false,
      sessionConfigured: raw['sessionConfigured'] as bool? ?? false,
      repeatingStarted: raw['repeatingStarted'] as bool? ?? false,
      frameReceived: raw['frameReceived'] as bool? ?? false,
      cameraId: raw['cameraId'] as String?,
      selectedLensFacing: (raw['selectedLensFacing'] as String?) ?? 'unknown',
      selectedWidth: (raw['selectedWidth'] as num?)?.toInt() ?? 0,
      selectedHeight: (raw['selectedHeight'] as num?)?.toInt() ?? 0,
      imageFormatName: (raw['imageFormatName'] as String?) ?? 'YUV_420_888',
      hardwareBufferAvailable: raw['hardwareBufferAvailable'] as bool? ?? false,
      hardwareBufferClosed: raw['hardwareBufferClosed'] as bool? ?? false,
      imageClosed: raw['imageClosed'] as bool? ?? false,
      syncFenceAwaited: raw['syncFenceAwaited'] as bool? ?? false,
      syncFenceClosed: raw['syncFenceClosed'] as bool? ?? false,
      syntheticBufferAllocated:
          raw['syntheticBufferAllocated'] as bool? ?? false,
      syntheticBufferClosed: raw['syntheticBufferClosed'] as bool? ?? false,
      nativeInvoked: raw['nativeInvoked'] as bool? ?? false,
      sessionClosed: raw['sessionClosed'] as bool? ?? false,
      deviceClosed: raw['deviceClosed'] as bool? ?? false,
      imageReaderClosed: raw['imageReaderClosed'] as bool? ?? false,
      surfaceProducerReleased: raw['surfaceProducerReleased'] as bool? ?? false,
      decision: VGSingleCamIngestSpatialRenderSmokeDecision.fromRaw(
        raw['decision'],
      ),
      reasons: reasons,
      events: events,
      diagnostics: diagnostics,
      durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
      proofBoundary: (raw['proofBoundary'] as String?) ?? '',
      raw: (raw['raw'] as String?) ?? '',
      metrics: Map<String, String>.unmodifiable(metrics),
      lastError: (raw['lastError'] as String?) ?? '',
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'success': success,
      'started': started,
      'textureId': textureId,
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
      'syntheticBufferAllocated': syntheticBufferAllocated,
      'syntheticBufferClosed': syntheticBufferClosed,
      'nativeInvoked': nativeInvoked,
      'sessionClosed': sessionClosed,
      'deviceClosed': deviceClosed,
      'imageReaderClosed': imageReaderClosed,
      'surfaceProducerReleased': surfaceProducerReleased,
      'decision': decision.name,
      'reasons': reasons,
      'events': events,
      'diagnostics': diagnostics,
      'durationMs': durationMs,
      'proofBoundary': proofBoundary,
      'raw': raw,
      'metrics': Map<String, String>.from(metrics),
      'lastError': lastError,
    };
  }

  static const String _startMethod =
      'startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke';
  static const String _disposeMethod =
      'disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Starts the Android True-DAG Phase 3 single-camera-ingest dynamic-
  /// descriptor spatial render smoke harness.
  ///
  /// [descriptor] is the raw primitive Dart layout descriptor map -- build
  /// it via [VGMultiCamDynamicDescriptorSpatialRenderInput.toMap] for a
  /// well-formed lane, or hand-construct a deliberately malformed/unknown
  /// map to exercise the fail-closed lane. Native is the sole layout-value
  /// authority; Kotlin only validates map shape/type.
  ///
  /// [maxWidth] / [maxHeight] bound the selected `ImageReader` output size;
  /// the native side clamps these to 160-1920. The `SurfaceProducer` size is
  /// set to the actual selected camera dimensions, not these bounds.
  ///
  /// [timeout] bounds how long the harness waits for each camera lifecycle
  /// stage to reach a terminal state; the native side clamps this to
  /// 3-30 seconds.
  ///
  /// Launches the harness on a background thread and returns once native has
  /// acknowledged the start (texture created, run launched). The full
  /// [VGSingleCamIngestSpatialRenderSmokeReport] arrives later via the
  /// `vanguard_media_engine` MethodChannel's
  /// `onAndroidDagPhase3SingleCamIngestSpatialRenderSmokeComplete` callback.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<({int textureId, int maxWidth, int maxHeight})>
  startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke({
    required Map<String, Object?> descriptor,
    int maxWidth = 640,
    int maxHeight = 480,
    Duration timeout = const Duration(seconds: 10),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final raw = await ch.invokeMethod<Object?>(_startMethod, <String, Object?>{
      'descriptor': descriptor,
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
      'timeoutMs': timeout.inMilliseconds,
    });
    final map = raw is Map ? raw : const <Object?, Object?>{};
    final textureId = (map['textureId'] as num?)?.toInt() ?? -1;
    return (textureId: textureId, maxWidth: maxWidth, maxHeight: maxHeight);
  }

  /// Disposes the active single-camera-ingest spatial render smoke run for
  /// [textureId].
  ///
  /// Requests cancellation if still running and releases the Flutter
  /// `SurfaceProducer`. Returns `true` if `surfaceProducerReleased` was
  /// confirmed by the native coordinator.
  ///
  /// [channel] may be injected for testing; defaults to
  /// `vanguard_media_engine`.
  static Future<bool> disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke({
    required int textureId,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final raw = await ch.invokeMethod<Object?>(
      _disposeMethod,
      <String, Object?>{'textureId': textureId},
    );
    final map = raw is Map ? raw : const <Object?, Object?>{};
    return map['surfaceProducerReleased'] as bool? ?? false;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGSingleCamIngestSpatialRenderSmokeReport &&
        other.success == success &&
        other.started == started &&
        other.textureId == textureId &&
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
        other.syntheticBufferAllocated == syntheticBufferAllocated &&
        other.syntheticBufferClosed == syntheticBufferClosed &&
        other.nativeInvoked == nativeInvoked &&
        other.sessionClosed == sessionClosed &&
        other.deviceClosed == deviceClosed &&
        other.imageReaderClosed == imageReaderClosed &&
        other.surfaceProducerReleased == surfaceProducerReleased &&
        other.decision == decision &&
        listEquals(other.reasons, reasons) &&
        listEquals(other.events, events) &&
        mapEquals(other.diagnostics, diagnostics) &&
        other.durationMs == durationMs &&
        other.proofBoundary == proofBoundary &&
        other.raw == raw &&
        mapEquals(other.metrics, metrics) &&
        other.lastError == lastError;
  }

  @override
  int get hashCode {
    final identityHash = Object.hash(
      success,
      started,
      textureId,
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
      syntheticBufferAllocated,
      syntheticBufferClosed,
      nativeInvoked,
    );
    final lifecycleHash = Object.hash(
      sessionClosed,
      deviceClosed,
      imageReaderClosed,
      surfaceProducerReleased,
      decision,
      Object.hashAll(reasons),
      Object.hashAll(events),
      _stableMapHash(diagnostics),
      durationMs,
    );
    final nativeHash = Object.hash(
      proofBoundary,
      raw,
      _stableMapHash(metrics),
      lastError,
    );
    return Object.hash(identityHash, bufferHash, lifecycleHash, nativeHash);
  }

  static int _stableMapHash(Map<Object?, Object?> map) {
    final sortedKeys = map.keys.toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGSingleCamIngestSpatialRenderSmokeReport('
      'success: $success, '
      'started: $started, '
      'textureId: $textureId, '
      'apiLevel: $apiLevel, '
      'hasCameraPermission: $hasCameraPermission, '
      'attemptedOpen: $attemptedOpen, '
      'opened: $opened, '
      'sessionConfigured: $sessionConfigured, '
      'repeatingStarted: $repeatingStarted, '
      'frameReceived: $frameReceived, '
      'cameraId: $cameraId, '
      'selectedLensFacing: $selectedLensFacing, '
      'selectedWidth: $selectedWidth, '
      'selectedHeight: $selectedHeight, '
      'imageFormatName: $imageFormatName, '
      'hardwareBufferAvailable: $hardwareBufferAvailable, '
      'hardwareBufferClosed: $hardwareBufferClosed, '
      'imageClosed: $imageClosed, '
      'syncFenceAwaited: $syncFenceAwaited, '
      'syncFenceClosed: $syncFenceClosed, '
      'syntheticBufferAllocated: $syntheticBufferAllocated, '
      'syntheticBufferClosed: $syntheticBufferClosed, '
      'nativeInvoked: $nativeInvoked, '
      'sessionClosed: $sessionClosed, '
      'deviceClosed: $deviceClosed, '
      'imageReaderClosed: $imageReaderClosed, '
      'surfaceProducerReleased: $surfaceProducerReleased, '
      'decision: $decision, '
      'reasons: $reasons, '
      'events: $events, '
      'diagnostics: $diagnostics, '
      'durationMs: $durationMs, '
      'proofBoundary: $proofBoundary, '
      'raw: $raw, '
      'metrics: $metrics, '
      'lastError: $lastError)';
}
