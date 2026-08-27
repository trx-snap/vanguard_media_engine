// vg_camera2_native_render_loop_smoke.dart
// vanguard_media_engine — Phase 3-Unit L: Android Camera2 PRIVATE ImageReader
// HardwareBuffer native-render multi-frame render loop smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke` MethodChannel route.
// Diagnostic-only — proves that, with CAMERA already granted, Vanguard can
// create an existing Phase 4A native DAG/Vulkan smoke session against an
// offscreen output surface, open one selected Camera2 device, configure a
// single ImageFormat.PRIVATE ImageReader with
// HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE, receive multiple consecutive frames,
// obtain their non-null HardwareBuffers, synchronously render them in sequence
// through the single native session, verify timestamp monotonicity, and tear
// down render session/buffers/images/capture session/device/reader/offscreen
// surface deterministically. Not preview, not recording, not CameraX, not
// dual/concurrent open, not new C++/JNI, not ConnectsApp wiring.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 3-Unit L Camera2 native-render
/// loop smoke harness.
enum VGCamera2NativeRenderLoopSmokeDecision {
  /// All target frames were received, non-null HardwareBuffers were obtained,
  /// and each was synchronously rendered through the native Phase 4A DAG/Vulkan
  /// session (`status=PASS;`).
  nativeRenderLoopPassed,

  /// `Build.VERSION.SDK_INT` is below 29 (Q); no open was attempted.
  apiUnsupported,

  /// The native Phase 4A DAG/Vulkan smoke session could not be created (or
  /// its `sessionId` could not be parsed); no camera open was attempted.
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
  captureFailed;

  /// Maps a raw native decision string to the matching enum value, falling
  /// back to [captureFailed] for unrecognised/missing values.
  static VGCamera2NativeRenderLoopSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGCamera2NativeRenderLoopSmokeDecision.captureFailed;
    }
    for (final value in VGCamera2NativeRenderLoopSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGCamera2NativeRenderLoopSmokeDecision.captureFailed;
  }
}

/// Typed report returned by
/// [VGCamera2NativeRenderLoopSmokeReport.runAndroidCamera2NativeRenderLoopSmoke],
/// mirroring the native harness's result map.
@immutable
class VGCamera2NativeRenderLoopSmokeReport {
  const VGCamera2NativeRenderLoopSmokeReport({
    required this.success,
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
    required this.sessionClosed,
    required this.deviceClosed,
    required this.imageReaderClosed,
    required this.nativeSessionCreated,
    required this.nativeSessionDestroyed,
    required this.outputSurfaceReleased,
    required this.surfaceTextureReleased,
    required this.decision,
    required this.reasons,
    required this.events,
    required this.diagnostics,
    required this.durationMs,
  });

  /// Whether the native harness reached
  /// [VGCamera2NativeRenderLoopSmokeDecision.nativeRenderLoopPassed] with
  /// exactly [targetFrameCount] frames rendered, confirmed HardwareBuffer
  /// closes, image closes, native session destroy, capture session close,
  /// device close, ImageReader close, and offscreen output surface/SurfaceTexture
  /// release.
  final bool success;

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

  /// Whether the capture session was confirmed closed via `onClosed`.
  final bool sessionClosed;

  /// Whether the camera device was confirmed closed via `onClosed`.
  final bool deviceClosed;

  /// Whether `ImageReader.close()` was invoked.
  final bool imageReaderClosed;

  /// Whether the native Phase 4A DAG/Vulkan smoke session was created
  /// against the offscreen output surface.
  final bool nativeSessionCreated;

  /// Whether the native Phase 4A DAG/Vulkan smoke session was destroyed
  /// during cleanup.
  final bool nativeSessionDestroyed;

  /// Whether the offscreen output `Surface` was released during cleanup.
  final bool outputSurfaceReleased;

  /// Whether the offscreen `SurfaceTexture` was released during cleanup.
  final bool surfaceTextureReleased;

  /// The lifecycle decision.
  final VGCamera2NativeRenderLoopSmokeDecision decision;

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
  /// [VGCamera2NativeRenderLoopSmokeDecision.permissionRequired].
  bool get isPermissionRequired =>
      decision == VGCamera2NativeRenderLoopSmokeDecision.permissionRequired;

  /// Whether [decision] is
  /// [VGCamera2NativeRenderLoopSmokeDecision.nativeRenderLoopPassed].
  bool get isNativeRenderLoopPassed =>
      decision == VGCamera2NativeRenderLoopSmokeDecision.nativeRenderLoopPassed;

  /// Whether the native harness actually attempted `openCamera`.
  bool get isAttempted => attemptedOpen;

  /// Whether the harness rendered at least the target number of frames.
  bool get completedTargetFrames => renderedFrames >= targetFrameCount;

  /// Whether the capture session, device, ImageReader, native session, and
  /// offscreen output surface/SurfaceTexture were all confirmed torn down.
  bool get isCleanedUp =>
      sessionClosed &&
      deviceClosed &&
      imageReaderClosed &&
      nativeSessionDestroyed &&
      outputSurfaceReleased &&
      surfaceTextureReleased;

  /// Parses a report from the raw native map. Defensive against both
  /// `Map<Object?, Object?>` and `Map<String, Object?>` shapes, and against
  /// missing/malformed fields — unrecognised shapes fall back to
  /// [VGCamera2NativeRenderLoopSmokeDecision.captureFailed] with the raw
  /// map preserved in [diagnostics].
  static VGCamera2NativeRenderLoopSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGCamera2NativeRenderLoopSmokeReport(
        success: false,
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
        sessionClosed: false,
        deviceClosed: false,
        imageReaderClosed: false,
        nativeSessionCreated: false,
        nativeSessionDestroyed: false,
        outputSurfaceReleased: false,
        surfaceTextureReleased: false,
        decision: VGCamera2NativeRenderLoopSmokeDecision.captureFailed,
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

    return VGCamera2NativeRenderLoopSmokeReport(
      success: raw['success'] as bool? ?? false,
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
      sessionClosed: raw['sessionClosed'] as bool? ?? false,
      deviceClosed: raw['deviceClosed'] as bool? ?? false,
      imageReaderClosed: raw['imageReaderClosed'] as bool? ?? false,
      nativeSessionCreated: raw['nativeSessionCreated'] as bool? ?? false,
      nativeSessionDestroyed: raw['nativeSessionDestroyed'] as bool? ?? false,
      outputSurfaceReleased: raw['outputSurfaceReleased'] as bool? ?? false,
      surfaceTextureReleased: raw['surfaceTextureReleased'] as bool? ?? false,
      decision: VGCamera2NativeRenderLoopSmokeDecision.fromRaw(raw['decision']),
      reasons: reasons,
      events: events,
      diagnostics: diagnostics,
      durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'success': success,
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
      'sessionClosed': sessionClosed,
      'deviceClosed': deviceClosed,
      'imageReaderClosed': imageReaderClosed,
      'nativeSessionCreated': nativeSessionCreated,
      'nativeSessionDestroyed': nativeSessionDestroyed,
      'outputSurfaceReleased': outputSurfaceReleased,
      'surfaceTextureReleased': surfaceTextureReleased,
      'decision': decision.name,
      'reasons': reasons,
      'events': events,
      'diagnostics': diagnostics,
      'durationMs': durationMs,
    };
  }

  static const String _method =
      'runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android-backed native Camera2 native-render loop smoke
  /// harness and parses the result.
  ///
  /// [cameraId] selects a specific camera id; omit or pass blank to let the
  /// native harness select the first back-facing camera (falling back to the
  /// first camera in `getCameraIdList()`).
  ///
  /// [timeout] bounds how long the harness waits for each lifecycle stage to
  /// reach a terminal state; the native side clamps this to 3–30 seconds.
  ///
  /// [maxWidth] / [maxHeight] bound the selected `ImageReader` output size;
  /// the native side clamps these to 160–1920.
  ///
  /// [frameCount] specifies how many consecutive frames to render through
  /// the native DAG session; the native side clamps this to 2–30.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGCamera2NativeRenderLoopSmokeReport>
  runAndroidCamera2NativeRenderLoopSmoke({
    String? cameraId,
    Duration timeout = const Duration(seconds: 10),
    int maxWidth = 640,
    int maxHeight = 480,
    int frameCount = 5,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final args = <String, Object?>{
      if (cameraId != null && cameraId.trim().isNotEmpty) 'cameraId': cameraId,
      'timeoutMs': timeout.inMilliseconds,
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
      'frameCount': frameCount,
    };
    final raw = await ch.invokeMethod<Object?>(_method, args);
    return VGCamera2NativeRenderLoopSmokeReport.fromMap(raw);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2NativeRenderLoopSmokeReport &&
        other.success == success &&
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
        other.sessionClosed == sessionClosed &&
        other.deviceClosed == deviceClosed &&
        other.imageReaderClosed == imageReaderClosed &&
        other.nativeSessionCreated == nativeSessionCreated &&
        other.nativeSessionDestroyed == nativeSessionDestroyed &&
        other.outputSurfaceReleased == outputSurfaceReleased &&
        other.surfaceTextureReleased == surfaceTextureReleased &&
        other.decision == decision &&
        listEquals(other.reasons, reasons) &&
        listEquals(other.events, events) &&
        mapEquals(other.diagnostics, diagnostics) &&
        other.durationMs == durationMs;
  }

  @override
  int get hashCode => Object.hash(
    success,
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
    imageFormatName,
    targetFrameCount,
    renderedFrames,
    hardwareBufferFrameCount,
    hardwareBufferClosedCount,
    imageClosedCount,
    syncFenceAwaitedCount,
    syncFenceClosedCount,
    Object.hash(
      firstFrameTimestampNs,
      lastFrameTimestampNs,
      monotonicFrameTimestamps,
      Object.hashAll(nativeRenderRawFrames),
      finalNativeRenderRaw,
      sessionClosed,
      deviceClosed,
      imageReaderClosed,
      nativeSessionCreated,
      nativeSessionDestroyed,
      outputSurfaceReleased,
      surfaceTextureReleased,
      decision,
      Object.hashAll(reasons),
      Object.hashAll(events),
      _stableDiagnosticsHash(diagnostics),
      durationMs,
    ),
  );

  static int _stableDiagnosticsHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGCamera2NativeRenderLoopSmokeReport('
      'success: $success, '
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
      'sessionClosed: $sessionClosed, '
      'deviceClosed: $deviceClosed, '
      'imageReaderClosed: $imageReaderClosed, '
      'nativeSessionCreated: $nativeSessionCreated, '
      'nativeSessionDestroyed: $nativeSessionDestroyed, '
      'outputSurfaceReleased: $outputSurfaceReleased, '
      'surfaceTextureReleased: $surfaceTextureReleased, '
      'decision: $decision, '
      'reasons: $reasons, '
      'events: $events, '
      'diagnostics: $diagnostics, '
      'durationMs: $durationMs)';
}
