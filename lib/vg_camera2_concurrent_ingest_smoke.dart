// vg_camera2_concurrent_ingest_smoke.dart
// vanguard_media_engine — P3-CAM-CONCURRENT: Android Camera2 dual-camera
// concurrent PRIVATE AHardwareBuffer ingest smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3CameraConcurrentIngestSmoke` MethodChannel route.
// Diagnostic-only — validates concurrent dual-camera selection, concurrent
// session eligibility, simultaneous opening of two cameras, PRIVATE
// ImageReader session configuration, repeating preview capture, sync fence
// handling, and native AHardwareBuffer ingest/destruction.
// No PiP, split layout, compositor, recording, or export.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 3 Camera2 concurrent ingest smoke harness.
enum VGCamera2ConcurrentIngestSmokeDecision {
  /// Both cameras opened, configured, produced HardwareBuffer frames, and
  /// passed native ingest and teardown validation.
  ingested,

  /// `Build.VERSION.SDK_INT` is below 30 (R); concurrent APIs unsupported.
  unsupportedApi,

  /// `Manifest.permission.CAMERA` was not granted; no open was attempted.
  permissionRequired,

  /// `CameraManager` was unavailable from the system service.
  cameraManagerUnavailable,

  /// No concurrent camera combination advertised or concurrent session configuration unsupported.
  concurrentNotSupported,

  /// One or both selected cameras expose no positive PRIVATE output sizes.
  unsupportedStream,

  /// `onDisconnected` fired during camera open.
  openDisconnected,

  /// `onError` fired during camera open or open threw.
  openError,

  /// Camera open did not reach terminal callback state in time.
  openTimeout,

  /// Session creation threw or `onConfigureFailed` fired.
  sessionConfigurationRejected,

  /// Session configuration did not complete in time.
  configureTimeout,

  /// No frame arrived via `onImageAvailable` in time for one or both cameras.
  frameTimeout,

  /// Native session create, frame ingest, or admission validation failed.
  nativeIngestFailed,

  /// Native session destroy failed.
  destroyFailed,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw native decision string to the matching enum value, falling
  /// back to [harnessException] for unrecognised/missing values.
  static VGCamera2ConcurrentIngestSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGCamera2ConcurrentIngestSmokeDecision.harnessException;
    }
    for (final value in VGCamera2ConcurrentIngestSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGCamera2ConcurrentIngestSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGCamera2ConcurrentIngestSmokeReport.runAndroidCamera2ConcurrentIngestSmoke],
/// mirroring the native harness's result map.
@immutable
class VGCamera2ConcurrentIngestSmokeReport {
  const VGCamera2ConcurrentIngestSmokeReport({
    required this.pass,
    required this.decision,
    required this.reasons,
    required this.apiLevel,
    required this.hasCameraPermission,
    required this.selectedCameraIds,
    required this.openedCameraCount,
    required this.configuredSessionCount,
    required this.capturedFrameCount,
    required this.nativeIngestPassCount,
    required this.syncFenceAwaitedCount,
    required this.syncFenceClosedCount,
    required this.nativeCreateRaw,
    required this.nativeDestroyRaw,
    required this.events,
    required this.diagnostics,
    required this.proofBoundary,
    required this.durationMs,
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'android_camera2_dual_camera_concurrent_private_ahardwarebuffer_ingest_validation_'
      'no_pip_no_split_no_compositor_no_recording_no_export';

  /// Primary success field emitted by the native harness.
  final bool pass;

  /// The lifecycle decision.
  final VGCamera2ConcurrentIngestSmokeDecision decision;

  /// Stable snake_case reason codes explaining [decision].
  final List<String> reasons;

  /// `Build.VERSION.SDK_INT` on the probing device.
  final int apiLevel;

  /// Current `Manifest.permission.CAMERA` grant state — queried without prompting.
  final bool hasCameraPermission;

  /// The pair of selected camera IDs.
  final List<String> selectedCameraIds;

  /// Number of cameras confirmed opened via `onOpened`.
  final int openedCameraCount;

  /// Number of sessions confirmed configured via `onConfigured`.
  final int configuredSessionCount;

  /// Number of cameras from which at least one frame was captured.
  final int capturedFrameCount;

  /// Number of frames successfully ingested through native bridge.
  final int nativeIngestPassCount;

  /// Number of API 33+ sync fences successfully awaited.
  final int syncFenceAwaitedCount;

  /// Number of API 33+ sync fences closed.
  final int syncFenceClosedCount;

  /// Raw return string from native session creation.
  final String nativeCreateRaw;

  /// Raw return string from native session destruction.
  final String nativeDestroyRaw;

  /// Ordered lifecycle event trace.
  final List<String> events;

  /// Additional diagnostic key/value pairs.
  final Map<String, Object?> diagnostics;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Wall-clock duration of the harness run, in milliseconds.
  final int durationMs;

  /// Whether [decision] is
  /// [VGCamera2ConcurrentIngestSmokeDecision.permissionRequired].
  bool get isPermissionRequired =>
      decision == VGCamera2ConcurrentIngestSmokeDecision.permissionRequired;

  /// Whether [decision] is
  /// [VGCamera2ConcurrentIngestSmokeDecision.concurrentNotSupported].
  bool get isConcurrentUnsupported =>
      decision == VGCamera2ConcurrentIngestSmokeDecision.concurrentNotSupported;

  /// Whether [decision] is
  /// [VGCamera2ConcurrentIngestSmokeDecision.ingested].
  bool get isIngested =>
      decision == VGCamera2ConcurrentIngestSmokeDecision.ingested;

  /// Whether dual-camera proof requirements are satisfied (2 cameras selected,
  /// 2 opened, 2 sessions configured, 2 frames captured).
  bool get hasTwoCameraProof =>
      selectedCameraIds.length >= 2 &&
      openedCameraCount >= 2 &&
      configuredSessionCount >= 2 &&
      capturedFrameCount >= 2;

  /// Whether native proof requirements are satisfied (2 native ingests passed,
  /// native create passed, and native destroy passed).
  bool get hasNativeProof =>
      nativeIngestPassCount >= 2 &&
      nativeCreateRaw.startsWith('status=PASS') &&
      nativeDestroyRaw.startsWith('status=PASS');

  /// Whether API 33+ sync fence proof is satisfied (for API >= 33, both awaited
  /// and closed counts >= 2; for API < 33, true because no fence is expected).
  bool get hasApi33FenceProof => apiLevel >= 33
      ? (syncFenceAwaitedCount >= 2 && syncFenceClosedCount >= 2)
      : true;

  /// Parses a report from the raw native map. Defensive against both
  /// `Map<Object?, Object?>` and `Map<String, Object?>` shapes, and against
  /// missing/malformed fields — unrecognised shapes fall back to
  /// [VGCamera2ConcurrentIngestSmokeDecision.harnessException] with the raw
  /// input preserved in [diagnostics].
  static VGCamera2ConcurrentIngestSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGCamera2ConcurrentIngestSmokeReport(
        pass: false,
        decision: VGCamera2ConcurrentIngestSmokeDecision.harnessException,
        reasons: const <String>['native_result_not_a_map'],
        apiLevel: 0,
        hasCameraPermission: false,
        selectedCameraIds: const <String>[],
        openedCameraCount: 0,
        configuredSessionCount: 0,
        capturedFrameCount: 0,
        nativeIngestPassCount: 0,
        syncFenceAwaitedCount: 0,
        syncFenceClosedCount: 0,
        nativeCreateRaw: 'status=FAIL;reason=not_run',
        nativeDestroyRaw: 'status=FAIL;reason=not_run',
        events: const <String>[],
        diagnostics: <String, Object?>{'raw': raw},
        proofBoundary: '',
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

    final selectedCameraIdsRaw = raw['selectedCameraIds'];
    final selectedCameraIds = selectedCameraIdsRaw is List
        ? selectedCameraIdsRaw
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

    return VGCamera2ConcurrentIngestSmokeReport(
      pass: raw['pass'] as bool? ?? false,
      decision: VGCamera2ConcurrentIngestSmokeDecision.fromRaw(raw['decision']),
      reasons: reasons,
      apiLevel: (raw['apiLevel'] as num?)?.toInt() ?? 0,
      hasCameraPermission: raw['hasCameraPermission'] as bool? ?? false,
      selectedCameraIds: selectedCameraIds,
      openedCameraCount: (raw['openedCameraCount'] as num?)?.toInt() ?? 0,
      configuredSessionCount:
          (raw['configuredSessionCount'] as num?)?.toInt() ?? 0,
      capturedFrameCount: (raw['capturedFrameCount'] as num?)?.toInt() ?? 0,
      nativeIngestPassCount:
          (raw['nativeIngestPassCount'] as num?)?.toInt() ?? 0,
      syncFenceAwaitedCount:
          (raw['syncFenceAwaitedCount'] as num?)?.toInt() ?? 0,
      syncFenceClosedCount: (raw['syncFenceClosedCount'] as num?)?.toInt() ?? 0,
      nativeCreateRaw:
          (raw['nativeCreateRaw'] as String?) ?? 'status=FAIL;reason=not_run',
      nativeDestroyRaw:
          (raw['nativeDestroyRaw'] as String?) ?? 'status=FAIL;reason=not_run',
      events: events,
      diagnostics: diagnostics,
      proofBoundary: (raw['proofBoundary'] as String?) ?? '',
      durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'decision': decision.name,
      'reasons': reasons,
      'apiLevel': apiLevel,
      'hasCameraPermission': hasCameraPermission,
      'selectedCameraIds': selectedCameraIds,
      'openedCameraCount': openedCameraCount,
      'configuredSessionCount': configuredSessionCount,
      'capturedFrameCount': capturedFrameCount,
      'nativeIngestPassCount': nativeIngestPassCount,
      'syncFenceAwaitedCount': syncFenceAwaitedCount,
      'syncFenceClosedCount': syncFenceClosedCount,
      'nativeCreateRaw': nativeCreateRaw,
      'nativeDestroyRaw': nativeDestroyRaw,
      'events': events,
      'diagnostics': diagnostics,
      'proofBoundary': proofBoundary,
      'durationMs': durationMs,
    };
  }

  static const String _method =
      'runAndroidDagPhase3CameraConcurrentIngestSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android-backed native Camera2 dual-camera concurrent PRIVATE
  /// AHardwareBuffer ingest smoke harness and parses the result.
  ///
  /// [timeout] bounds how long the harness waits for each lifecycle stage to
  /// reach a terminal state; the native side clamps this to 2–20 seconds (default 10s).
  ///
  /// [maxWidth] / [maxHeight] bound the selected `ImageReader` output size;
  /// the native side clamps these to 160–1920 (default 640x480).
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGCamera2ConcurrentIngestSmokeReport>
  runAndroidCamera2ConcurrentIngestSmoke({
    Duration timeout = const Duration(seconds: 10),
    int maxWidth = 640,
    int maxHeight = 480,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final args = <String, Object?>{
      'timeoutMs': timeout.inMilliseconds,
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
    };
    final raw = await ch.invokeMethod<Object?>(_method, args);
    return VGCamera2ConcurrentIngestSmokeReport.fromMap(raw);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ConcurrentIngestSmokeReport &&
        other.pass == pass &&
        other.decision == decision &&
        listEquals(other.reasons, reasons) &&
        other.apiLevel == apiLevel &&
        other.hasCameraPermission == hasCameraPermission &&
        listEquals(other.selectedCameraIds, selectedCameraIds) &&
        other.openedCameraCount == openedCameraCount &&
        other.configuredSessionCount == configuredSessionCount &&
        other.capturedFrameCount == capturedFrameCount &&
        other.nativeIngestPassCount == nativeIngestPassCount &&
        other.syncFenceAwaitedCount == syncFenceAwaitedCount &&
        other.syncFenceClosedCount == syncFenceClosedCount &&
        other.nativeCreateRaw == nativeCreateRaw &&
        other.nativeDestroyRaw == nativeDestroyRaw &&
        listEquals(other.events, events) &&
        mapEquals(other.diagnostics, diagnostics) &&
        other.proofBoundary == proofBoundary &&
        other.durationMs == durationMs;
  }

  @override
  int get hashCode => Object.hash(
    pass,
    decision,
    Object.hashAll(reasons),
    apiLevel,
    hasCameraPermission,
    Object.hashAll(selectedCameraIds),
    openedCameraCount,
    configuredSessionCount,
    capturedFrameCount,
    nativeIngestPassCount,
    syncFenceAwaitedCount,
    syncFenceClosedCount,
    nativeCreateRaw,
    nativeDestroyRaw,
    Object.hashAll(events),
    _stableDiagnosticsHash(diagnostics),
    proofBoundary,
    durationMs,
  );

  static int _stableDiagnosticsHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGCamera2ConcurrentIngestSmokeReport('
      'pass: $pass, '
      'decision: $decision, '
      'reasons: $reasons, '
      'apiLevel: $apiLevel, '
      'hasCameraPermission: $hasCameraPermission, '
      'selectedCameraIds: $selectedCameraIds, '
      'openedCameraCount: $openedCameraCount, '
      'configuredSessionCount: $configuredSessionCount, '
      'capturedFrameCount: $capturedFrameCount, '
      'nativeIngestPassCount: $nativeIngestPassCount, '
      'syncFenceAwaitedCount: $syncFenceAwaitedCount, '
      'syncFenceClosedCount: $syncFenceClosedCount, '
      'nativeCreateRaw: $nativeCreateRaw, '
      'nativeDestroyRaw: $nativeDestroyRaw, '
      'events: $events, '
      'diagnostics: $diagnostics, '
      'proofBoundary: $proofBoundary, '
      'durationMs: $durationMs)';
}
