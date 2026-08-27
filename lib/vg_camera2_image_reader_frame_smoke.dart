// vg_camera2_image_reader_frame_smoke.dart
// vanguard_media_engine — Phase 3-Unit I: Android Camera2 single-camera
// ImageReader frame smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3UnitIImageReaderFrameSmoke` MethodChannel route.
// Diagnostic-only — proves that, with CAMERA already granted, Vanguard can
// open one selected Camera2 device, configure a single YUV_420_888
// ImageReader capture session, receive one image, close it, and tear down
// session/device/reader deterministically. Not preview, not recording, not
// CameraX, not dual/concurrent open, not C++/AHardwareBuffer ingest, and not
// ConnectsApp wiring.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 3-Unit I Camera2 ImageReader frame
/// smoke harness.
enum VGCamera2ImageReaderFrameSmokeDecision {
  /// A frame was received, the image was closed, the ImageReader was closed,
  /// and the device was confirmed closed.
  frameCaptured,

  /// `Manifest.permission.CAMERA` was not granted; no open was attempted.
  permissionRequired,

  /// `CameraManager.getCameraIdList()` returned no cameras.
  noCamera,

  /// `CameraManager` was unavailable from the system service.
  cameraManagerUnavailable,

  /// The requested camera id was not present in `getCameraIdList()`.
  cameraUnavailable,

  /// The selected camera exposes no positive YUV_420_888 output sizes.
  unsupportedStream,

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

  /// `onCaptureFailed` fired for the repeating request.
  captureFailed;

  /// Maps a raw native decision string to the matching enum value, falling
  /// back to [captureFailed] for unrecognised/missing values.
  static VGCamera2ImageReaderFrameSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGCamera2ImageReaderFrameSmokeDecision.captureFailed;
    }
    for (final value in VGCamera2ImageReaderFrameSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGCamera2ImageReaderFrameSmokeDecision.captureFailed;
  }
}

/// Typed report returned by
/// [VGCamera2ImageReaderFrameSmokeReport.runAndroidCamera2ImageReaderFrameSmoke],
/// mirroring the native harness's result map.
@immutable
class VGCamera2ImageReaderFrameSmokeReport {
  const VGCamera2ImageReaderFrameSmokeReport({
    required this.success,
    required this.apiLevel,
    required this.hasCameraPermission,
    required this.attemptedOpen,
    required this.opened,
    required this.sessionConfigured,
    required this.repeatingStarted,
    required this.frameReceived,
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
    this.framePlaneCount,
    required this.decision,
    required this.reasons,
    required this.events,
    required this.diagnostics,
    required this.durationMs,
  });

  /// Whether the native harness reached
  /// [VGCamera2ImageReaderFrameSmokeDecision.frameCaptured] with a confirmed
  /// image close, ImageReader close, and device close.
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

  /// Always `YUV_420_888` for this harness.
  final String imageFormatName;

  /// The first frame's `Image.timestamp` in nanoseconds, or `null` if no
  /// frame was received.
  final int? frameTimestampNs;

  /// The first frame's plane count, or `null` if no frame was received.
  final int? framePlaneCount;

  /// The lifecycle decision.
  final VGCamera2ImageReaderFrameSmokeDecision decision;

  /// Stable snake_case reason codes explaining [decision].
  final List<String> reasons;

  /// Ordered lifecycle event trace (e.g. `onOpened`, `onConfigured`,
  /// `onImageAvailable`).
  final List<String> events;

  /// Additional diagnostic key/value pairs (e.g. native error details).
  final Map<String, Object?> diagnostics;

  /// Wall-clock duration of the harness run, in milliseconds.
  final int durationMs;

  /// Whether [decision] is
  /// [VGCamera2ImageReaderFrameSmokeDecision.permissionRequired].
  bool get isPermissionRequired =>
      decision == VGCamera2ImageReaderFrameSmokeDecision.permissionRequired;

  /// Whether [decision] is
  /// [VGCamera2ImageReaderFrameSmokeDecision.frameCaptured].
  bool get isFrameCaptured =>
      decision == VGCamera2ImageReaderFrameSmokeDecision.frameCaptured;

  /// Whether the native harness actually attempted `openCamera`.
  bool get isAttempted => attemptedOpen;

  /// Whether the capture session, device, and ImageReader were all confirmed
  /// torn down.
  bool get isCleanedUp => sessionClosed && deviceClosed && imageReaderClosed;

  /// Parses a report from the raw native map. Defensive against both
  /// `Map<Object?, Object?>` and `Map<String, Object?>` shapes, and against
  /// missing/malformed fields — unrecognised shapes fall back to
  /// [VGCamera2ImageReaderFrameSmokeDecision.captureFailed] with the raw map
  /// preserved in [diagnostics].
  static VGCamera2ImageReaderFrameSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGCamera2ImageReaderFrameSmokeReport(
        success: false,
        apiLevel: 0,
        hasCameraPermission: false,
        attemptedOpen: false,
        opened: false,
        sessionConfigured: false,
        repeatingStarted: false,
        frameReceived: false,
        imageClosed: false,
        sessionClosed: false,
        deviceClosed: false,
        imageReaderClosed: false,
        cameraId: null,
        selectedLensFacing: 'unknown',
        selectedWidth: 0,
        selectedHeight: 0,
        imageFormatName: 'YUV_420_888',
        frameTimestampNs: null,
        framePlaneCount: null,
        decision: VGCamera2ImageReaderFrameSmokeDecision.captureFailed,
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

    return VGCamera2ImageReaderFrameSmokeReport(
      success: raw['success'] as bool? ?? false,
      apiLevel: (raw['apiLevel'] as num?)?.toInt() ?? 0,
      hasCameraPermission: raw['hasCameraPermission'] as bool? ?? false,
      attemptedOpen: raw['attemptedOpen'] as bool? ?? false,
      opened: raw['opened'] as bool? ?? false,
      sessionConfigured: raw['sessionConfigured'] as bool? ?? false,
      repeatingStarted: raw['repeatingStarted'] as bool? ?? false,
      frameReceived: raw['frameReceived'] as bool? ?? false,
      imageClosed: raw['imageClosed'] as bool? ?? false,
      sessionClosed: raw['sessionClosed'] as bool? ?? false,
      deviceClosed: raw['deviceClosed'] as bool? ?? false,
      imageReaderClosed: raw['imageReaderClosed'] as bool? ?? false,
      cameraId: raw['cameraId'] as String?,
      selectedLensFacing: (raw['selectedLensFacing'] as String?) ?? 'unknown',
      selectedWidth: (raw['selectedWidth'] as num?)?.toInt() ?? 0,
      selectedHeight: (raw['selectedHeight'] as num?)?.toInt() ?? 0,
      imageFormatName: (raw['imageFormatName'] as String?) ?? 'YUV_420_888',
      frameTimestampNs: (raw['frameTimestampNs'] as num?)?.toInt(),
      framePlaneCount: (raw['framePlaneCount'] as num?)?.toInt(),
      decision: VGCamera2ImageReaderFrameSmokeDecision.fromRaw(raw['decision']),
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
      'framePlaneCount': framePlaneCount,
      'decision': decision.name,
      'reasons': reasons,
      'events': events,
      'diagnostics': diagnostics,
      'durationMs': durationMs,
    };
  }

  static const String _method = 'runAndroidDagPhase3UnitIImageReaderFrameSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android-backed native Camera2 ImageReader frame smoke
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
  static Future<VGCamera2ImageReaderFrameSmokeReport>
  runAndroidCamera2ImageReaderFrameSmoke({
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
    return VGCamera2ImageReaderFrameSmokeReport.fromMap(raw);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ImageReaderFrameSmokeReport &&
        other.success == success &&
        other.apiLevel == apiLevel &&
        other.hasCameraPermission == hasCameraPermission &&
        other.attemptedOpen == attemptedOpen &&
        other.opened == opened &&
        other.sessionConfigured == sessionConfigured &&
        other.repeatingStarted == repeatingStarted &&
        other.frameReceived == frameReceived &&
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
        other.framePlaneCount == framePlaneCount &&
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
    imageClosed,
    Object.hash(
      sessionClosed,
      deviceClosed,
      imageReaderClosed,
      cameraId,
      selectedLensFacing,
      selectedWidth,
      selectedHeight,
      imageFormatName,
      frameTimestampNs,
      framePlaneCount,
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
      'VGCamera2ImageReaderFrameSmokeReport('
      'success: $success, '
      'apiLevel: $apiLevel, '
      'hasCameraPermission: $hasCameraPermission, '
      'attemptedOpen: $attemptedOpen, '
      'opened: $opened, '
      'sessionConfigured: $sessionConfigured, '
      'repeatingStarted: $repeatingStarted, '
      'frameReceived: $frameReceived, '
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
      'framePlaneCount: $framePlaneCount, '
      'decision: $decision, '
      'reasons: $reasons, '
      'events: $events, '
      'diagnostics: $diagnostics, '
      'durationMs: $durationMs)';
}
