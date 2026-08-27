// vg_camera2_native_render_frame_smoke.dart
// vanguard_media_engine — Phase 3-Unit K: Android Camera2 PRIVATE ImageReader
// HardwareBuffer native-render frame smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3UnitKCameraNativeRenderSmoke` MethodChannel route.
// Diagnostic-only — proves that, with CAMERA already granted, Vanguard can
// create an existing Phase 4A native DAG/Vulkan smoke session against an
// offscreen output surface, open one selected Camera2 device, configure a
// single ImageFormat.PRIVATE ImageReader with
// HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE, receive one image, obtain its
// non-null HardwareBuffer, synchronously render it through the native
// session, and tear down render session/buffer/image/capture
// session/device/reader/offscreen surface deterministically. Not preview,
// not recording, not CameraX, not dual/concurrent open, not new C++/JNI, not
// ConnectsApp wiring.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 3-Unit K Camera2 native-render
/// frame smoke harness.
enum VGCamera2NativeRenderFrameSmokeDecision {
  /// A frame was received, a non-null HardwareBuffer was obtained, and it
  /// was synchronously rendered through the native Phase 4A DAG/Vulkan
  /// session (`status=PASS;`).
  nativeRenderPassed,

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

  /// `Image.getHardwareBuffer()` returned null for the acquired image.
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

  /// No frame arrived via `onImageAvailable` in time.
  frameTimeout,

  /// The native render call did not return `status=PASS;` for the acquired
  /// HardwareBuffer.
  nativeRenderFailed,

  /// `onCaptureFailed` fired for the repeating request.
  captureFailed;

  /// Maps a raw native decision string to the matching enum value, falling
  /// back to [captureFailed] for unrecognised/missing values.
  static VGCamera2NativeRenderFrameSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGCamera2NativeRenderFrameSmokeDecision.captureFailed;
    }
    for (final value in VGCamera2NativeRenderFrameSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGCamera2NativeRenderFrameSmokeDecision.captureFailed;
  }
}

/// Typed report returned by
/// [VGCamera2NativeRenderFrameSmokeReport.runAndroidCamera2NativeRenderFrameSmoke],
/// mirroring the native harness's result map.
@immutable
class VGCamera2NativeRenderFrameSmokeReport {
  const VGCamera2NativeRenderFrameSmokeReport({
    required this.success,
    required this.apiLevel,
    required this.hasCameraPermission,
    required this.attemptedOpen,
    required this.opened,
    required this.sessionConfigured,
    required this.repeatingStarted,
    required this.frameReceived,
    required this.hardwareBufferAvailable,
    required this.hardwareBufferClosed,
    required this.imageClosed,
    required this.sessionClosed,
    required this.deviceClosed,
    required this.imageReaderClosed,
    this.cameraId,
    required this.selectedLensFacing,
    required this.selectedWidth,
    required this.selectedHeight,
    required this.imageFormatName,
    this.frameTimestampNs,
    this.hardwareBufferWidth,
    this.hardwareBufferHeight,
    this.hardwareBufferFormat,
    this.hardwareBufferLayers,
    this.hardwareBufferUsage,
    required this.syncFenceAwaited,
    required this.syncFenceClosed,
    required this.nativeSessionCreated,
    required this.nativeSessionDestroyed,
    required this.nativeRenderAttempted,
    required this.nativeRenderPassed,
    this.nativeRenderRaw,
    required this.outputSurfaceReleased,
    required this.surfaceTextureReleased,
    required this.decision,
    required this.reasons,
    required this.events,
    required this.diagnostics,
    required this.durationMs,
  });

  /// Whether the native harness reached
  /// [VGCamera2NativeRenderFrameSmokeDecision.nativeRenderPassed] with a
  /// confirmed HardwareBuffer close, image close, native session destroy,
  /// capture session close, device close, ImageReader close, and offscreen
  /// output surface/SurfaceTexture release.
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

  /// Whether `onImageAvailable` delivered at least one frame.
  final bool frameReceived;

  /// Whether `Image.getHardwareBuffer()` returned non-null for the acquired
  /// image.
  final bool hardwareBufferAvailable;

  /// Whether the acquired `HardwareBuffer` was closed.
  final bool hardwareBufferClosed;

  /// Whether the first acquired image was closed.
  final bool imageClosed;

  /// Whether the capture session was confirmed closed via `onClosed`.
  final bool sessionClosed;

  /// Whether the camera device was confirmed closed via `onClosed`.
  final bool deviceClosed;

  /// Whether `ImageReader.close()` was invoked.
  final bool imageReaderClosed;

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

  /// The first frame's `Image.timestamp` in nanoseconds, or `null` if no
  /// frame was received.
  final int? frameTimestampNs;

  /// The acquired `HardwareBuffer.getWidth()`, or `null` if unavailable.
  final int? hardwareBufferWidth;

  /// The acquired `HardwareBuffer.getHeight()`, or `null` if unavailable.
  final int? hardwareBufferHeight;

  /// The acquired `HardwareBuffer.getFormat()`, or `null` if unavailable.
  final int? hardwareBufferFormat;

  /// The acquired `HardwareBuffer.getLayers()`, or `null` if unavailable.
  final int? hardwareBufferLayers;

  /// The acquired `HardwareBuffer.getUsage()`, or `null` if unavailable.
  final int? hardwareBufferUsage;

  /// Whether the API 33+ `Image.getFence()` sync fence was awaited.
  final bool syncFenceAwaited;

  /// Whether the API 33+ `Image.getFence()` sync fence was closed.
  final bool syncFenceClosed;

  /// Whether the native Phase 4A DAG/Vulkan smoke session was created
  /// against the offscreen output surface.
  final bool nativeSessionCreated;

  /// Whether the native Phase 4A DAG/Vulkan smoke session was destroyed
  /// during cleanup.
  final bool nativeSessionDestroyed;

  /// Whether a native render call was attempted for the acquired
  /// HardwareBuffer.
  final bool nativeRenderAttempted;

  /// Whether the native render call returned `status=PASS;`.
  final bool nativeRenderPassed;

  /// The raw native render result string, or `null` if no render was
  /// attempted.
  final String? nativeRenderRaw;

  /// Whether the offscreen output `Surface` was released during cleanup.
  final bool outputSurfaceReleased;

  /// Whether the offscreen `SurfaceTexture` was released during cleanup.
  final bool surfaceTextureReleased;

  /// The lifecycle decision.
  final VGCamera2NativeRenderFrameSmokeDecision decision;

  /// Stable snake_case reason codes explaining [decision].
  final List<String> reasons;

  /// Ordered lifecycle event trace (e.g. `onOpened`, `onConfigured`,
  /// `onImageAvailable`, `nativeRenderAttempted`).
  final List<String> events;

  /// Additional diagnostic key/value pairs (e.g. native error details).
  final Map<String, Object?> diagnostics;

  /// Wall-clock duration of the harness run, in milliseconds.
  final int durationMs;

  /// Whether [decision] is
  /// [VGCamera2NativeRenderFrameSmokeDecision.permissionRequired].
  bool get isPermissionRequired =>
      decision == VGCamera2NativeRenderFrameSmokeDecision.permissionRequired;

  /// Whether [decision] is
  /// [VGCamera2NativeRenderFrameSmokeDecision.nativeRenderPassed].
  bool get isNativeRenderPassed =>
      decision == VGCamera2NativeRenderFrameSmokeDecision.nativeRenderPassed;

  /// Whether the native harness actually attempted `openCamera`.
  bool get isAttempted => attemptedOpen;

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
  /// [VGCamera2NativeRenderFrameSmokeDecision.captureFailed] with the raw
  /// map preserved in [diagnostics].
  static VGCamera2NativeRenderFrameSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGCamera2NativeRenderFrameSmokeReport(
        success: false,
        apiLevel: 0,
        hasCameraPermission: false,
        attemptedOpen: false,
        opened: false,
        sessionConfigured: false,
        repeatingStarted: false,
        frameReceived: false,
        hardwareBufferAvailable: false,
        hardwareBufferClosed: false,
        imageClosed: false,
        sessionClosed: false,
        deviceClosed: false,
        imageReaderClosed: false,
        cameraId: null,
        selectedLensFacing: 'unknown',
        selectedWidth: 0,
        selectedHeight: 0,
        imageFormatName: 'PRIVATE',
        frameTimestampNs: null,
        hardwareBufferWidth: null,
        hardwareBufferHeight: null,
        hardwareBufferFormat: null,
        hardwareBufferLayers: null,
        hardwareBufferUsage: null,
        syncFenceAwaited: false,
        syncFenceClosed: false,
        nativeSessionCreated: false,
        nativeSessionDestroyed: false,
        nativeRenderAttempted: false,
        nativeRenderPassed: false,
        nativeRenderRaw: null,
        outputSurfaceReleased: false,
        surfaceTextureReleased: false,
        decision: VGCamera2NativeRenderFrameSmokeDecision.captureFailed,
        reasons: const <String>['native_result_not_a_map'],
        events: const <String>[],
        diagnostics: <String, Object?>{'raw': raw},
        durationMs: 0,
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

    return VGCamera2NativeRenderFrameSmokeReport(
      success: raw['success'] as bool? ?? false,
      apiLevel: (raw['apiLevel'] as num?)?.toInt() ?? 0,
      hasCameraPermission: raw['hasCameraPermission'] as bool? ?? false,
      attemptedOpen: raw['attemptedOpen'] as bool? ?? false,
      opened: raw['opened'] as bool? ?? false,
      sessionConfigured: raw['sessionConfigured'] as bool? ?? false,
      repeatingStarted: raw['repeatingStarted'] as bool? ?? false,
      frameReceived: raw['frameReceived'] as bool? ?? false,
      hardwareBufferAvailable: raw['hardwareBufferAvailable'] as bool? ?? false,
      hardwareBufferClosed: raw['hardwareBufferClosed'] as bool? ?? false,
      imageClosed: raw['imageClosed'] as bool? ?? false,
      sessionClosed: raw['sessionClosed'] as bool? ?? false,
      deviceClosed: raw['deviceClosed'] as bool? ?? false,
      imageReaderClosed: raw['imageReaderClosed'] as bool? ?? false,
      cameraId: raw['cameraId'] as String?,
      selectedLensFacing: (raw['selectedLensFacing'] as String?) ?? 'unknown',
      selectedWidth: (raw['selectedWidth'] as num?)?.toInt() ?? 0,
      selectedHeight: (raw['selectedHeight'] as num?)?.toInt() ?? 0,
      imageFormatName: (raw['imageFormatName'] as String?) ?? 'PRIVATE',
      frameTimestampNs: (raw['frameTimestampNs'] as num?)?.toInt(),
      hardwareBufferWidth: (raw['hardwareBufferWidth'] as num?)?.toInt(),
      hardwareBufferHeight: (raw['hardwareBufferHeight'] as num?)?.toInt(),
      hardwareBufferFormat: (raw['hardwareBufferFormat'] as num?)?.toInt(),
      hardwareBufferLayers: (raw['hardwareBufferLayers'] as num?)?.toInt(),
      hardwareBufferUsage: (raw['hardwareBufferUsage'] as num?)?.toInt(),
      syncFenceAwaited: raw['syncFenceAwaited'] as bool? ?? false,
      syncFenceClosed: raw['syncFenceClosed'] as bool? ?? false,
      nativeSessionCreated: raw['nativeSessionCreated'] as bool? ?? false,
      nativeSessionDestroyed: raw['nativeSessionDestroyed'] as bool? ?? false,
      nativeRenderAttempted: raw['nativeRenderAttempted'] as bool? ?? false,
      nativeRenderPassed: raw['nativeRenderPassed'] as bool? ?? false,
      nativeRenderRaw: raw['nativeRenderRaw'] as String?,
      outputSurfaceReleased: raw['outputSurfaceReleased'] as bool? ?? false,
      surfaceTextureReleased: raw['surfaceTextureReleased'] as bool? ?? false,
      decision: VGCamera2NativeRenderFrameSmokeDecision.fromRaw(
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
      'apiLevel': apiLevel,
      'hasCameraPermission': hasCameraPermission,
      'attemptedOpen': attemptedOpen,
      'opened': opened,
      'sessionConfigured': sessionConfigured,
      'repeatingStarted': repeatingStarted,
      'frameReceived': frameReceived,
      'hardwareBufferAvailable': hardwareBufferAvailable,
      'hardwareBufferClosed': hardwareBufferClosed,
      'imageClosed': imageClosed,
      'sessionClosed': sessionClosed,
      'deviceClosed': deviceClosed,
      'imageReaderClosed': imageReaderClosed,
      'cameraId': cameraId,
      'selectedLensFacing': selectedLensFacing,
      'selectedWidth': selectedWidth,
      'selectedHeight': selectedHeight,
      'imageFormatName': imageFormatName,
      'frameTimestampNs': frameTimestampNs,
      'hardwareBufferWidth': hardwareBufferWidth,
      'hardwareBufferHeight': hardwareBufferHeight,
      'hardwareBufferFormat': hardwareBufferFormat,
      'hardwareBufferLayers': hardwareBufferLayers,
      'hardwareBufferUsage': hardwareBufferUsage,
      'syncFenceAwaited': syncFenceAwaited,
      'syncFenceClosed': syncFenceClosed,
      'nativeSessionCreated': nativeSessionCreated,
      'nativeSessionDestroyed': nativeSessionDestroyed,
      'nativeRenderAttempted': nativeRenderAttempted,
      'nativeRenderPassed': nativeRenderPassed,
      'nativeRenderRaw': nativeRenderRaw,
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
      'runAndroidDagPhase3UnitKCameraNativeRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android-backed native Camera2 native-render frame smoke
  /// harness and parses the result.
  ///
  /// [cameraId] selects a specific camera id; omit or pass blank to let the
  /// native harness select the first back-facing camera (falling back to the
  /// first camera in `getCameraIdList()`).
  ///
  /// [timeout] bounds how long the harness waits for each lifecycle stage to
  /// reach a terminal state; the native side clamps this to 2–20 seconds.
  ///
  /// [maxWidth] / [maxHeight] bound the selected `ImageReader` output size;
  /// the native side clamps these to 160–1920.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGCamera2NativeRenderFrameSmokeReport>
  runAndroidCamera2NativeRenderFrameSmoke({
    String? cameraId,
    Duration timeout = const Duration(seconds: 8),
    int maxWidth = 640,
    int maxHeight = 480,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final args = <String, Object?>{
      if (cameraId != null && cameraId.trim().isNotEmpty) 'cameraId': cameraId,
      'timeoutMs': timeout.inMilliseconds,
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
    };
    final raw = await ch.invokeMethod<Object?>(_method, args);
    return VGCamera2NativeRenderFrameSmokeReport.fromMap(raw);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2NativeRenderFrameSmokeReport &&
        other.success == success &&
        other.apiLevel == apiLevel &&
        other.hasCameraPermission == hasCameraPermission &&
        other.attemptedOpen == attemptedOpen &&
        other.opened == opened &&
        other.sessionConfigured == sessionConfigured &&
        other.repeatingStarted == repeatingStarted &&
        other.frameReceived == frameReceived &&
        other.hardwareBufferAvailable == hardwareBufferAvailable &&
        other.hardwareBufferClosed == hardwareBufferClosed &&
        other.imageClosed == imageClosed &&
        other.sessionClosed == sessionClosed &&
        other.deviceClosed == deviceClosed &&
        other.imageReaderClosed == imageReaderClosed &&
        other.cameraId == cameraId &&
        other.selectedLensFacing == selectedLensFacing &&
        other.selectedWidth == selectedWidth &&
        other.selectedHeight == selectedHeight &&
        other.imageFormatName == imageFormatName &&
        other.frameTimestampNs == frameTimestampNs &&
        other.hardwareBufferWidth == hardwareBufferWidth &&
        other.hardwareBufferHeight == hardwareBufferHeight &&
        other.hardwareBufferFormat == hardwareBufferFormat &&
        other.hardwareBufferLayers == hardwareBufferLayers &&
        other.hardwareBufferUsage == hardwareBufferUsage &&
        other.syncFenceAwaited == syncFenceAwaited &&
        other.syncFenceClosed == syncFenceClosed &&
        other.nativeSessionCreated == nativeSessionCreated &&
        other.nativeSessionDestroyed == nativeSessionDestroyed &&
        other.nativeRenderAttempted == nativeRenderAttempted &&
        other.nativeRenderPassed == nativeRenderPassed &&
        other.nativeRenderRaw == nativeRenderRaw &&
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
    frameReceived,
    Object.hash(
      hardwareBufferAvailable,
      hardwareBufferClosed,
      imageClosed,
      sessionClosed,
      deviceClosed,
      imageReaderClosed,
      cameraId,
      selectedLensFacing,
    ),
    Object.hash(
      selectedWidth,
      selectedHeight,
      imageFormatName,
      frameTimestampNs,
      hardwareBufferWidth,
      hardwareBufferHeight,
      hardwareBufferFormat,
      hardwareBufferLayers,
    ),
    Object.hash(hardwareBufferUsage, syncFenceAwaited, syncFenceClosed),
    Object.hash(
      nativeSessionCreated,
      nativeSessionDestroyed,
      nativeRenderAttempted,
      nativeRenderPassed,
      nativeRenderRaw,
      outputSurfaceReleased,
      surfaceTextureReleased,
    ),
    decision,
    Object.hashAll(reasons),
    Object.hashAll(events),
    _stableDiagnosticsHash(diagnostics),
    durationMs,
  );

  static int _stableDiagnosticsHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGCamera2NativeRenderFrameSmokeReport('
      'success: $success, '
      'apiLevel: $apiLevel, '
      'hasCameraPermission: $hasCameraPermission, '
      'attemptedOpen: $attemptedOpen, '
      'opened: $opened, '
      'sessionConfigured: $sessionConfigured, '
      'repeatingStarted: $repeatingStarted, '
      'frameReceived: $frameReceived, '
      'hardwareBufferAvailable: $hardwareBufferAvailable, '
      'hardwareBufferClosed: $hardwareBufferClosed, '
      'imageClosed: $imageClosed, '
      'sessionClosed: $sessionClosed, '
      'deviceClosed: $deviceClosed, '
      'imageReaderClosed: $imageReaderClosed, '
      'cameraId: $cameraId, '
      'selectedLensFacing: $selectedLensFacing, '
      'selectedWidth: $selectedWidth, '
      'selectedHeight: $selectedHeight, '
      'imageFormatName: $imageFormatName, '
      'frameTimestampNs: $frameTimestampNs, '
      'hardwareBufferWidth: $hardwareBufferWidth, '
      'hardwareBufferHeight: $hardwareBufferHeight, '
      'hardwareBufferFormat: $hardwareBufferFormat, '
      'hardwareBufferLayers: $hardwareBufferLayers, '
      'hardwareBufferUsage: $hardwareBufferUsage, '
      'syncFenceAwaited: $syncFenceAwaited, '
      'syncFenceClosed: $syncFenceClosed, '
      'nativeSessionCreated: $nativeSessionCreated, '
      'nativeSessionDestroyed: $nativeSessionDestroyed, '
      'nativeRenderAttempted: $nativeRenderAttempted, '
      'nativeRenderPassed: $nativeRenderPassed, '
      'nativeRenderRaw: $nativeRenderRaw, '
      'outputSurfaceReleased: $outputSurfaceReleased, '
      'surfaceTextureReleased: $surfaceTextureReleased, '
      'decision: $decision, '
      'reasons: $reasons, '
      'events: $events, '
      'diagnostics: $diagnostics, '
      'durationMs: $durationMs)';
}
