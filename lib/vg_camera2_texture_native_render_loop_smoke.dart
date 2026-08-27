// vg_camera2_texture_native_render_loop_smoke.dart
// vanguard_media_engine — Phase 3-Unit M: Android Camera2 PRIVATE ImageReader
// HardwareBuffer Flutter Texture Native Render Loop Smoke Foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `startAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke` /
// `disposeAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke`
// MethodChannel routes. Diagnostic-only — extends the Unit L offscreen-surface
// native-render loop into a Flutter-visible proof: Camera2 produces PRIVATE
// ImageReader HardwareBuffers which the native side renders through the
// existing Phase 4B1 texture playback session into a real Flutter
// `TextureRegistry.SurfaceProducer` surface. Not preview UI wiring, not
// recording, not new C++/JNI.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 3-Unit M Camera2 texture native-render
/// loop smoke harness.
enum VGCamera2TextureNativeRenderLoopSmokeDecision {
  /// All target frames were received, non-null HardwareBuffers were obtained,
  /// and each was synchronously rendered through the native Phase 4B1 DAG/Vulkan
  /// texture playback session onto the Flutter surface (`status=PASS;`).
  textureNativeRenderLoopPassed,

  /// `Build.VERSION.SDK_INT` is below 29 (Q); no open was attempted.
  apiUnsupported,

  /// The native Phase 4B1 DAG/Vulkan texture playback session could not be
  /// created (or its `sessionId`/generation could not be parsed); no camera
  /// open was attempted.
  nativeSessionFailed,

  /// `Manifest.permission.CAMERA` was not granted; no open was attempted.
  permissionRequired,

  /// `CameraManager.getCameraIdList()` returned no cameras.
  noCamera,

  /// `CameraManager` was unavailable from the system service.
  cameraManagerUnavailable,

  /// The requested camera id was not present in `getCameraIdList()`.
  cameraUnavailable,

  /// The selected camera exposes no positive PRIVATE output sizes.
  unsupportedStream,

  /// `Image.getHardwareBuffer()` returned null for an acquired image.
  hardwareBufferUnavailable,

  /// `onDisconnected` fired during the open attempt.
  openDisconnected,

  /// `onError` fired during the open attempt.
  openError,

  /// The open attempt did not reach a terminal callback state in time.
  openTimeout,

  /// `onConfigureFailed` fired for the capture session, or session creation
  /// threw.
  sessionConfigureFailed,

  /// The capture session did not reach a terminal configuration state in
  /// time.
  sessionConfigureTimeout,

  /// `setRepeatingRequest` threw.
  repeatingRequestFailed,

  /// Not all target frames arrived via `onImageAvailable` in time.
  frameTimeout,

  /// A native render call did not return `status=PASS;` for an acquired
  /// HardwareBuffer.
  nativeRenderFailed,

  /// `onCaptureFailed` fired for the repeating request.
  captureFailed,

  /// The run was cancelled via dispose before/while it was still active.
  disposed,

  /// All target frames were rendered but the selected camera's
  /// `CameraCharacteristics.SENSOR_ORIENTATION` was missing or not one of
  /// 0/90/180/270; the run is not reported as passed.
  invalidSensorOrientation;

  /// Maps a raw native decision string to the matching enum value, falling
  /// back to [captureFailed] for unrecognised/missing values.
  static VGCamera2TextureNativeRenderLoopSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGCamera2TextureNativeRenderLoopSmokeDecision.captureFailed;
    }
    for (final value in VGCamera2TextureNativeRenderLoopSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGCamera2TextureNativeRenderLoopSmokeDecision.captureFailed;
  }
}

/// Typed report returned by
/// [VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke]'s
/// completion callback, mirroring the native harness's result map.
@immutable
class VGCamera2TextureNativeRenderLoopSmokeReport {
  const VGCamera2TextureNativeRenderLoopSmokeReport({
    required this.success,
    required this.started,
    required this.textureId,
    required this.apiLevel,
    required this.hasCameraPermission,
    required this.attemptedOpen,
    required this.opened,
    required this.sessionConfigured,
    required this.repeatingStarted,
    this.cameraId,
    required this.selectedLensFacing,
    required this.selectedWidth,
    required this.selectedHeight,
    required this.selectedSensorOrientationDegrees,
    required this.renderedRotationDegrees,
    required this.imageFormatName,
    required this.targetFrameCount,
    required this.renderedFrames,
    required this.hardwareBufferFrameCount,
    required this.hardwareBufferClosedCount,
    required this.imageClosedCount,
    required this.syncFenceAwaitedCount,
    required this.syncFenceClosedCount,
    this.firstFrameTimestampNs,
    this.lastFrameTimestampNs,
    required this.monotonicFrameTimestamps,
    required this.nativeRenderRawFrames,
    this.finalNativeRenderRaw,
    required this.nativeSessionCreated,
    required this.nativeGenerationId,
    required this.nativeSessionDestroyed,
    required this.sessionClosed,
    required this.deviceClosed,
    required this.imageReaderClosed,
    required this.surfaceProducerReleased,
    required this.decision,
    required this.reasons,
    required this.events,
    required this.diagnostics,
    required this.durationMs,
  });

  /// Whether the native harness reached
  /// [VGCamera2TextureNativeRenderLoopSmokeDecision.textureNativeRenderLoopPassed]
  /// with exactly [targetFrameCount] frames rendered, confirmed HardwareBuffer
  /// closes, image closes, native session destroy, capture session close,
  /// device close, and ImageReader close.
  final bool success;

  /// Whether the native harness actually began running (always `true` for a
  /// completion report — a report only exists because a run started).
  final bool started;

  /// The Flutter `TextureRegistry.SurfaceProducer` texture id this run
  /// rendered into.
  final int textureId;

  /// `Build.VERSION.SDK_INT` on the probing device.
  final int apiLevel;

  /// Current `Manifest.permission.CAMERA` grant state — queried without
  /// prompting.
  final bool hasCameraPermission;

  /// Whether the native harness actually called `CameraManager.openCamera`.
  final bool attemptedOpen;

  /// Whether `onOpened` fired for the selected camera device.
  final bool opened;

  /// Whether the capture session reached `onConfigured`.
  final bool sessionConfigured;

  /// Whether `setRepeatingRequest` was called successfully.
  final bool repeatingStarted;

  /// The selected/requested camera id, or `null` when no camera could be
  /// selected.
  final String? cameraId;

  /// `front` / `back` / `external` / `unknown`.
  final String selectedLensFacing;

  /// The selected `ImageReader` output width in pixels.
  final int selectedWidth;

  /// The selected `ImageReader` output height in pixels.
  final int selectedHeight;

  /// The selected camera's `CameraCharacteristics.SENSOR_ORIENTATION` in
  /// degrees, or `-1` if unavailable.
  final int selectedSensorOrientationDegrees;

  /// The effective rotation degrees (0, 90, 180, 270) passed to the native
  /// Vulkan render call.
  final int renderedRotationDegrees;

  /// Always `PRIVATE` for this harness.
  final String imageFormatName;

  /// The target number of consecutive frames to render through the native
  /// session.
  final int targetFrameCount;

  /// The number of frames successfully rendered through the native session.
  final int renderedFrames;

  /// Total count of non-null `HardwareBuffer` instances obtained.
  final int hardwareBufferFrameCount;

  /// Total count of `HardwareBuffer.close()` invocations.
  final int hardwareBufferClosedCount;

  /// Total count of `Image.close()` invocations.
  final int imageClosedCount;

  /// Total count of API 33+ `Image.getFence()` sync fences awaited.
  final int syncFenceAwaitedCount;

  /// Total count of API 33+ `Image.getFence()` sync fences closed.
  final int syncFenceClosedCount;

  /// The first rendered frame's `Image.timestamp` in nanoseconds, or `null` if
  /// no frame was rendered.
  final int? firstFrameTimestampNs;

  /// The last rendered frame's `Image.timestamp` in nanoseconds, or `null` if
  /// no frame was rendered.
  final int? lastFrameTimestampNs;

  /// Whether observed frame timestamps were strictly monotonically increasing.
  final bool monotonicFrameTimestamps;

  /// List of raw native render result strings for each attempted frame.
  final List<String> nativeRenderRawFrames;

  /// The raw native render result string of the final rendered frame, or
  /// `null` if no frame was rendered.
  final String? finalNativeRenderRaw;

  /// Whether the native Phase 4B1 DAG/Vulkan texture playback session was
  /// created against the Flutter surface.
  final bool nativeSessionCreated;

  /// The generation id bumped once at session creation and used for every
  /// rendered frame; `0` if never successfully bumped.
  final int nativeGenerationId;

  /// Whether the native Phase 4B1 DAG/Vulkan texture playback session was
  /// destroyed during cleanup.
  final bool nativeSessionDestroyed;

  /// Whether the capture session was confirmed closed via `onClosed`.
  final bool sessionClosed;

  /// Whether the camera device was confirmed closed via `onClosed`.
  final bool deviceClosed;

  /// Whether `ImageReader.close()` was invoked.
  final bool imageReaderClosed;

  /// Whether the Flutter `SurfaceProducer` was released. Always `false` on a
  /// normal completion report — the coordinator's dispose call is the sole
  /// releaser.
  final bool surfaceProducerReleased;

  /// The lifecycle decision.
  final VGCamera2TextureNativeRenderLoopSmokeDecision decision;

  /// Stable snake_case reason codes explaining [decision].
  final List<String> reasons;

  /// Ordered lifecycle event trace (e.g. `onOpened`, `onConfigured`,
  /// `repeatingRequestStarted`, `nativeRenderAttempted:frameIndex=0`).
  final List<String> events;

  /// Additional diagnostic key/value pairs (e.g. native error details).
  final Map<String, Object?> diagnostics;

  /// Wall-clock duration of the harness run, in milliseconds.
  final int durationMs;

  /// Whether [decision] is
  /// [VGCamera2TextureNativeRenderLoopSmokeDecision.permissionRequired].
  bool get isPermissionRequired =>
      decision ==
      VGCamera2TextureNativeRenderLoopSmokeDecision.permissionRequired;

  /// Whether [decision] is
  /// [VGCamera2TextureNativeRenderLoopSmokeDecision.textureNativeRenderLoopPassed].
  bool get isTextureNativeRenderLoopPassed =>
      decision ==
      VGCamera2TextureNativeRenderLoopSmokeDecision
          .textureNativeRenderLoopPassed;

  /// Whether [decision] is
  /// [VGCamera2TextureNativeRenderLoopSmokeDecision.disposed].
  bool get isDisposed =>
      decision == VGCamera2TextureNativeRenderLoopSmokeDecision.disposed;

  /// Whether the native harness actually attempted `openCamera`.
  bool get isAttempted => attemptedOpen;

  /// Whether the harness rendered at least the target number of frames.
  bool get completedTargetFrames => renderedFrames >= targetFrameCount;

  /// Whether [selectedSensorOrientationDegrees] is one of 0/90/180/270.
  bool get hasValidSensorOrientation =>
      const <int>{0, 90, 180, 270}.contains(selectedSensorOrientationDegrees);

  /// Whether [renderedRotationDegrees] equals [selectedSensorOrientationDegrees].
  bool get hasExpectedRenderRotation =>
      renderedRotationDegrees == selectedSensorOrientationDegrees;

  /// Whether the capture session, device, ImageReader, and native session
  /// were all confirmed torn down.
  bool get isCleanedUp =>
      sessionClosed &&
      deviceClosed &&
      imageReaderClosed &&
      nativeSessionDestroyed;

  /// Parses a report from the raw native map. Defensive against both
  /// `Map<Object?, Object?>` and `Map<String, Object?>` shapes, and against
  /// missing/malformed fields — unrecognised shapes fall back to
  /// [VGCamera2TextureNativeRenderLoopSmokeDecision.captureFailed] with the
  /// raw map preserved in [diagnostics].
  static VGCamera2TextureNativeRenderLoopSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGCamera2TextureNativeRenderLoopSmokeReport(
        success: false,
        started: false,
        textureId: -1,
        apiLevel: 0,
        hasCameraPermission: false,
        attemptedOpen: false,
        opened: false,
        sessionConfigured: false,
        repeatingStarted: false,
        cameraId: null,
        selectedLensFacing: 'unknown',
        selectedWidth: 0,
        selectedHeight: 0,
        selectedSensorOrientationDegrees: -1,
        renderedRotationDegrees: 0,
        imageFormatName: 'PRIVATE',
        targetFrameCount: 0,
        renderedFrames: 0,
        hardwareBufferFrameCount: 0,
        hardwareBufferClosedCount: 0,
        imageClosedCount: 0,
        syncFenceAwaitedCount: 0,
        syncFenceClosedCount: 0,
        firstFrameTimestampNs: null,
        lastFrameTimestampNs: null,
        monotonicFrameTimestamps: true,
        nativeRenderRawFrames: const <String>[],
        finalNativeRenderRaw: null,
        nativeSessionCreated: false,
        nativeGenerationId: 0,
        nativeSessionDestroyed: false,
        sessionClosed: false,
        deviceClosed: false,
        imageReaderClosed: false,
        surfaceProducerReleased: false,
        decision: VGCamera2TextureNativeRenderLoopSmokeDecision.captureFailed,
        reasons: const <String>['native_result_not_a_map'],
        events: const <String>[],
        diagnostics: <String, Object?>{'raw': raw},
        durationMs: 0,
      );
    }

    final nativeRenderRawFramesRaw = raw['nativeRenderRawFrames'];
    final nativeRenderRawFrames = nativeRenderRawFramesRaw is List
        ? nativeRenderRawFramesRaw
              .whereType<Object>()
              .map((e) => e.toString())
              .toList(growable: false)
        : const <String>[];

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

    return VGCamera2TextureNativeRenderLoopSmokeReport(
      success: raw['success'] as bool? ?? false,
      started: raw['started'] as bool? ?? false,
      textureId: (raw['textureId'] as num?)?.toInt() ?? -1,
      apiLevel: (raw['apiLevel'] as num?)?.toInt() ?? 0,
      hasCameraPermission: raw['hasCameraPermission'] as bool? ?? false,
      attemptedOpen: raw['attemptedOpen'] as bool? ?? false,
      opened: raw['opened'] as bool? ?? false,
      sessionConfigured: raw['sessionConfigured'] as bool? ?? false,
      repeatingStarted: raw['repeatingStarted'] as bool? ?? false,
      cameraId: raw['cameraId'] as String?,
      selectedLensFacing: (raw['selectedLensFacing'] as String?) ?? 'unknown',
      selectedWidth: (raw['selectedWidth'] as num?)?.toInt() ?? 0,
      selectedHeight: (raw['selectedHeight'] as num?)?.toInt() ?? 0,
      selectedSensorOrientationDegrees:
          (raw['selectedSensorOrientationDegrees'] as num?)?.toInt() ?? -1,
      renderedRotationDegrees:
          (raw['renderedRotationDegrees'] as num?)?.toInt() ?? 0,
      imageFormatName: (raw['imageFormatName'] as String?) ?? 'PRIVATE',
      targetFrameCount: (raw['targetFrameCount'] as num?)?.toInt() ?? 0,
      renderedFrames: (raw['renderedFrames'] as num?)?.toInt() ?? 0,
      hardwareBufferFrameCount:
          (raw['hardwareBufferFrameCount'] as num?)?.toInt() ?? 0,
      hardwareBufferClosedCount:
          (raw['hardwareBufferClosedCount'] as num?)?.toInt() ?? 0,
      imageClosedCount: (raw['imageClosedCount'] as num?)?.toInt() ?? 0,
      syncFenceAwaitedCount:
          (raw['syncFenceAwaitedCount'] as num?)?.toInt() ?? 0,
      syncFenceClosedCount: (raw['syncFenceClosedCount'] as num?)?.toInt() ?? 0,
      firstFrameTimestampNs: (raw['firstFrameTimestampNs'] as num?)?.toInt(),
      lastFrameTimestampNs: (raw['lastFrameTimestampNs'] as num?)?.toInt(),
      monotonicFrameTimestamps:
          raw['monotonicFrameTimestamps'] as bool? ?? true,
      nativeRenderRawFrames: nativeRenderRawFrames,
      finalNativeRenderRaw: raw['finalNativeRenderRaw'] as String?,
      nativeSessionCreated: raw['nativeSessionCreated'] as bool? ?? false,
      nativeGenerationId: (raw['nativeGenerationId'] as num?)?.toInt() ?? 0,
      nativeSessionDestroyed: raw['nativeSessionDestroyed'] as bool? ?? false,
      sessionClosed: raw['sessionClosed'] as bool? ?? false,
      deviceClosed: raw['deviceClosed'] as bool? ?? false,
      imageReaderClosed: raw['imageReaderClosed'] as bool? ?? false,
      surfaceProducerReleased: raw['surfaceProducerReleased'] as bool? ?? false,
      decision: VGCamera2TextureNativeRenderLoopSmokeDecision.fromRaw(
        raw['decision'],
      ),
      reasons: reasons,
      events: events,
      diagnostics: diagnostics,
      durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
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
      'cameraId': cameraId,
      'selectedLensFacing': selectedLensFacing,
      'selectedWidth': selectedWidth,
      'selectedHeight': selectedHeight,
      'selectedSensorOrientationDegrees': selectedSensorOrientationDegrees,
      'renderedRotationDegrees': renderedRotationDegrees,
      'imageFormatName': imageFormatName,
      'targetFrameCount': targetFrameCount,
      'renderedFrames': renderedFrames,
      'hardwareBufferFrameCount': hardwareBufferFrameCount,
      'hardwareBufferClosedCount': hardwareBufferClosedCount,
      'imageClosedCount': imageClosedCount,
      'syncFenceAwaitedCount': syncFenceAwaitedCount,
      'syncFenceClosedCount': syncFenceClosedCount,
      'firstFrameTimestampNs': firstFrameTimestampNs,
      'lastFrameTimestampNs': lastFrameTimestampNs,
      'monotonicFrameTimestamps': monotonicFrameTimestamps,
      'nativeRenderRawFrames': nativeRenderRawFrames,
      'finalNativeRenderRaw': finalNativeRenderRaw,
      'nativeSessionCreated': nativeSessionCreated,
      'nativeGenerationId': nativeGenerationId,
      'nativeSessionDestroyed': nativeSessionDestroyed,
      'sessionClosed': sessionClosed,
      'deviceClosed': deviceClosed,
      'imageReaderClosed': imageReaderClosed,
      'surfaceProducerReleased': surfaceProducerReleased,
      'decision': decision.name,
      'reasons': reasons,
      'events': events,
      'diagnostics': diagnostics,
      'durationMs': durationMs,
    };
  }

  static const String _startMethod =
      'startAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke';
  static const String _disposeMethod =
      'disposeAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Starts the Android-backed native Camera2 texture native-render loop
  /// smoke harness and returns once the native side has acknowledged the
  /// start (texture created, run launched on a background thread). The full
  /// [VGCamera2TextureNativeRenderLoopSmokeReport] arrives later via the
  /// `vanguard_media_engine` MethodChannel's
  /// `onAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmokeComplete`
  /// callback — callers observe it via their own channel handler (this
  /// library does not install one on the shared channel, which is owned by
  /// `VanguardChannelDispatcher`).
  ///
  /// [cameraId] selects a specific camera id taking precedence over [lensFacing];
  /// omit or pass blank to let [lensFacing] or the default fallback determine
  /// the camera.
  ///
  /// [lensFacing] optionally selects camera facing (`front`, `back`, `external`,
  /// `unknown`); ignored when [cameraId] is nonblank. Omit or pass blank to
  /// default to back-facing selection.
  ///
  /// [timeout] bounds how long the harness waits for each lifecycle stage to
  /// reach a terminal state; the native side clamps this to 3–30 seconds.
  ///
  /// [maxWidth] / [maxHeight] bound the selected `ImageReader` output size;
  /// the native side clamps these to 160–1920.
  ///
  /// [frameCount] specifies how many consecutive frames to render through
  /// the native Phase 4B1 texture playback session; the native side clamps
  /// this to 2–30.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<({int textureId, int targetFrameCount})>
  startAndroidCamera2TextureNativeRenderLoopSmoke({
    String? cameraId,
    String? lensFacing,
    bool applySensorOrientationTransform = true,
    Duration timeout = const Duration(seconds: 10),
    int maxWidth = 640,
    int maxHeight = 480,
    int frameCount = 5,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final trimmedCameraId = cameraId?.trim();
    final normalizedLensFacing = lensFacing?.trim().toLowerCase();
    final args = <String, Object?>{
      if (trimmedCameraId != null && trimmedCameraId.isNotEmpty)
        'cameraId': trimmedCameraId,
      if (normalizedLensFacing != null && normalizedLensFacing.isNotEmpty)
        'lensFacing': normalizedLensFacing,
      'applySensorOrientationTransform': applySensorOrientationTransform,
      'timeoutMs': timeout.inMilliseconds,
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
      'frameCount': frameCount,
    };
    final raw = await ch.invokeMethod<Object?>(_startMethod, args);
    final map = raw is Map ? raw : const <Object?, Object?>{};
    final textureId = (map['textureId'] as num?)?.toInt() ?? -1;
    final targetFrameCount = (map['targetFrameCount'] as num?)?.toInt() ?? 0;
    return (textureId: textureId, targetFrameCount: targetFrameCount);
  }

  /// Disposes the active run for [textureId]: signals best-effort
  /// cancellation to the native harness if still running, and releases the
  /// Flutter `SurfaceProducer` exactly once. Safe to call multiple times or
  /// after the run has already completed.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<bool> disposeAndroidCamera2TextureNativeRenderLoopSmoke({
    required int textureId,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final raw = await ch.invokeMethod<Object?>(_disposeMethod, {
      'textureId': textureId,
    });
    final map = raw is Map ? raw : const <Object?, Object?>{};
    return map['surfaceProducerReleased'] as bool? ?? false;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2TextureNativeRenderLoopSmokeReport &&
        other.success == success &&
        other.started == started &&
        other.textureId == textureId &&
        other.apiLevel == apiLevel &&
        other.hasCameraPermission == hasCameraPermission &&
        other.attemptedOpen == attemptedOpen &&
        other.opened == opened &&
        other.sessionConfigured == sessionConfigured &&
        other.repeatingStarted == repeatingStarted &&
        other.cameraId == cameraId &&
        other.selectedLensFacing == selectedLensFacing &&
        other.selectedWidth == selectedWidth &&
        other.selectedHeight == selectedHeight &&
        other.selectedSensorOrientationDegrees ==
            selectedSensorOrientationDegrees &&
        other.renderedRotationDegrees == renderedRotationDegrees &&
        other.imageFormatName == imageFormatName &&
        other.targetFrameCount == targetFrameCount &&
        other.renderedFrames == renderedFrames &&
        other.hardwareBufferFrameCount == hardwareBufferFrameCount &&
        other.hardwareBufferClosedCount == hardwareBufferClosedCount &&
        other.imageClosedCount == imageClosedCount &&
        other.syncFenceAwaitedCount == syncFenceAwaitedCount &&
        other.syncFenceClosedCount == syncFenceClosedCount &&
        other.firstFrameTimestampNs == firstFrameTimestampNs &&
        other.lastFrameTimestampNs == lastFrameTimestampNs &&
        other.monotonicFrameTimestamps == monotonicFrameTimestamps &&
        listEquals(other.nativeRenderRawFrames, nativeRenderRawFrames) &&
        other.finalNativeRenderRaw == finalNativeRenderRaw &&
        other.nativeSessionCreated == nativeSessionCreated &&
        other.nativeGenerationId == nativeGenerationId &&
        other.nativeSessionDestroyed == nativeSessionDestroyed &&
        other.sessionClosed == sessionClosed &&
        other.deviceClosed == deviceClosed &&
        other.imageReaderClosed == imageReaderClosed &&
        other.surfaceProducerReleased == surfaceProducerReleased &&
        other.decision == decision &&
        listEquals(other.reasons, reasons) &&
        listEquals(other.events, events) &&
        mapEquals(other.diagnostics, diagnostics) &&
        other.durationMs == durationMs;
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
      cameraId,
      selectedLensFacing,
      selectedWidth,
      selectedHeight,
      selectedSensorOrientationDegrees,
      renderedRotationDegrees,
      imageFormatName,
      targetFrameCount,
      renderedFrames,
    );
    final frameHash = Object.hash(
      hardwareBufferFrameCount,
      hardwareBufferClosedCount,
      imageClosedCount,
      syncFenceAwaitedCount,
      syncFenceClosedCount,
      firstFrameTimestampNs,
      lastFrameTimestampNs,
      monotonicFrameTimestamps,
      Object.hashAll(nativeRenderRawFrames),
      finalNativeRenderRaw,
    );
    final lifecycleHash = Object.hash(
      nativeSessionCreated,
      nativeGenerationId,
      nativeSessionDestroyed,
      sessionClosed,
      deviceClosed,
      imageReaderClosed,
      surfaceProducerReleased,
      decision,
      Object.hashAll(reasons),
      Object.hashAll(events),
      _stableDiagnosticsHash(diagnostics),
      durationMs,
    );
    return Object.hash(identityHash, frameHash, lifecycleHash);
  }

  static int _stableDiagnosticsHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGCamera2TextureNativeRenderLoopSmokeReport('
      'success: $success, '
      'started: $started, '
      'textureId: $textureId, '
      'apiLevel: $apiLevel, '
      'hasCameraPermission: $hasCameraPermission, '
      'attemptedOpen: $attemptedOpen, '
      'opened: $opened, '
      'sessionConfigured: $sessionConfigured, '
      'repeatingStarted: $repeatingStarted, '
      'cameraId: $cameraId, '
      'selectedLensFacing: $selectedLensFacing, '
      'selectedWidth: $selectedWidth, '
      'selectedHeight: $selectedHeight, '
      'selectedSensorOrientationDegrees: $selectedSensorOrientationDegrees, '
      'renderedRotationDegrees: $renderedRotationDegrees, '
      'imageFormatName: $imageFormatName, '
      'targetFrameCount: $targetFrameCount, '
      'renderedFrames: $renderedFrames, '
      'hardwareBufferFrameCount: $hardwareBufferFrameCount, '
      'hardwareBufferClosedCount: $hardwareBufferClosedCount, '
      'imageClosedCount: $imageClosedCount, '
      'syncFenceAwaitedCount: $syncFenceAwaitedCount, '
      'syncFenceClosedCount: $syncFenceClosedCount, '
      'firstFrameTimestampNs: $firstFrameTimestampNs, '
      'lastFrameTimestampNs: $lastFrameTimestampNs, '
      'monotonicFrameTimestamps: $monotonicFrameTimestamps, '
      'nativeRenderRawFrames: $nativeRenderRawFrames, '
      'finalNativeRenderRaw: $finalNativeRenderRaw, '
      'nativeSessionCreated: $nativeSessionCreated, '
      'nativeGenerationId: $nativeGenerationId, '
      'nativeSessionDestroyed: $nativeSessionDestroyed, '
      'sessionClosed: $sessionClosed, '
      'deviceClosed: $deviceClosed, '
      'imageReaderClosed: $imageReaderClosed, '
      'surfaceProducerReleased: $surfaceProducerReleased, '
      'decision: $decision, '
      'reasons: $reasons, '
      'events: $events, '
      'diagnostics: $diagnostics, '
      'durationMs: $durationMs)';
}
