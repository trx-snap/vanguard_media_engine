// vg_camera2_open_close_smoke.dart
// vanguard_media_engine — Phase 3-Unit H: Android Camera2 single-camera
// open/close lifecycle smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3UnitHCameraOpenCloseSmoke` MethodChannel route.
// Diagnostic-only — proves that, with CAMERA already granted, Vanguard can
// open one selected Camera2 device and close it deterministically. Not
// preview, not capture, not CameraX, not C++ ingest, and not ConnectsApp UI
// wiring.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 3-Unit H Camera2 open/close smoke
/// harness.
enum VGCamera2OpenCloseSmokeDecision {
  /// `openCamera` succeeded and the device was closed and confirmed closed.
  openedAndClosed,

  /// `Manifest.permission.CAMERA` was not granted; no open was attempted.
  permissionRequired,

  /// `CameraManager.getCameraIdList()` returned no cameras.
  noCamera,

  /// `CameraManager` was unavailable from the system service.
  cameraManagerUnavailable,

  /// The requested camera id was not present in `getCameraIdList()`.
  cameraUnavailable,

  /// `onDisconnected` fired during the open attempt.
  openDisconnected,

  /// `onError` fired during the open attempt.
  openError,

  /// The open attempt did not reach a terminal callback state in time.
  openTimeout,

  /// The open attempt failed for another reason (e.g. a thrown exception).
  openFailed;

  /// Maps a raw native decision string to the matching enum value, falling
  /// back to [openFailed] for unrecognised/missing values.
  static VGCamera2OpenCloseSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) return VGCamera2OpenCloseSmokeDecision.openFailed;
    for (final value in VGCamera2OpenCloseSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGCamera2OpenCloseSmokeDecision.openFailed;
  }
}

/// Typed report returned by
/// [VGCamera2OpenCloseSmokeReport.runAndroidCamera2OpenCloseSmoke], mirroring
/// the native harness's result map.
@immutable
class VGCamera2OpenCloseSmokeReport {
  const VGCamera2OpenCloseSmokeReport({
    required this.success,
    required this.apiLevel,
    required this.hasCameraPermission,
    required this.attemptedOpen,
    required this.opened,
    required this.closed,
    this.cameraId,
    required this.selectedLensFacing,
    required this.decision,
    required this.reasons,
    required this.events,
    required this.diagnostics,
    required this.durationMs,
  });

  /// Whether the native harness reached [VGCamera2OpenCloseSmokeDecision.openedAndClosed].
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

  /// Whether `onClosed` fired for the selected camera device.
  final bool closed;

  /// The selected/requested camera id, or `null` when no camera could be
  /// selected.
  final String? cameraId;

  /// `front` / `back` / `external` / `unknown`.
  final String selectedLensFacing;

  /// The lifecycle decision.
  final VGCamera2OpenCloseSmokeDecision decision;

  /// Stable snake_case reason codes explaining [decision].
  final List<String> reasons;

  /// Ordered lifecycle event trace (e.g. `openCameraRequested`, `onOpened`).
  final List<String> events;

  /// Additional diagnostic key/value pairs (e.g. native error details).
  final Map<String, Object?> diagnostics;

  /// Wall-clock duration of the harness run, in milliseconds.
  final int durationMs;

  /// Whether [decision] is [VGCamera2OpenCloseSmokeDecision.permissionRequired].
  bool get isPermissionRequired =>
      decision == VGCamera2OpenCloseSmokeDecision.permissionRequired;

  /// Whether [decision] is [VGCamera2OpenCloseSmokeDecision.openedAndClosed].
  bool get isOpenedAndClosed =>
      decision == VGCamera2OpenCloseSmokeDecision.openedAndClosed;

  /// Whether the native harness actually attempted `openCamera`.
  bool get isAttempted => attemptedOpen;

  /// Whether the selected camera device was confirmed closed.
  bool get isClosed => closed;

  /// Parses a report from the raw native map. Defensive against both
  /// `Map<Object?, Object?>` and `Map<String, Object?>` shapes, and against
  /// missing/malformed fields — unrecognised shapes fall back to
  /// [VGCamera2OpenCloseSmokeDecision.openFailed] with the raw map preserved
  /// in [diagnostics].
  static VGCamera2OpenCloseSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGCamera2OpenCloseSmokeReport(
        success: false,
        apiLevel: 0,
        hasCameraPermission: false,
        attemptedOpen: false,
        opened: false,
        closed: false,
        cameraId: null,
        selectedLensFacing: 'unknown',
        decision: VGCamera2OpenCloseSmokeDecision.openFailed,
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

    return VGCamera2OpenCloseSmokeReport(
      success: raw['success'] as bool? ?? false,
      apiLevel: (raw['apiLevel'] as num?)?.toInt() ?? 0,
      hasCameraPermission: raw['hasCameraPermission'] as bool? ?? false,
      attemptedOpen: raw['attemptedOpen'] as bool? ?? false,
      opened: raw['opened'] as bool? ?? false,
      closed: raw['closed'] as bool? ?? false,
      cameraId: raw['cameraId'] as String?,
      selectedLensFacing: (raw['selectedLensFacing'] as String?) ?? 'unknown',
      decision: VGCamera2OpenCloseSmokeDecision.fromRaw(raw['decision']),
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
      'closed': closed,
      'cameraId': cameraId,
      'selectedLensFacing': selectedLensFacing,
      'decision': decision.name,
      'reasons': reasons,
      'events': events,
      'diagnostics': diagnostics,
      'durationMs': durationMs,
    };
  }

  static const String _method = 'runAndroidDagPhase3UnitHCameraOpenCloseSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android-backed native Camera2 open/close smoke harness and
  /// parses the result.
  ///
  /// [cameraId] selects a specific camera id; omit or pass blank to let the
  /// native harness select the first back-facing camera (falling back to the
  /// first camera in `getCameraIdList()`).
  ///
  /// [timeout] bounds how long the harness waits for the open/close lifecycle
  /// to reach a terminal state; the native side clamps this to 1–15 seconds.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGCamera2OpenCloseSmokeReport> runAndroidCamera2OpenCloseSmoke({
    String? cameraId,
    Duration timeout = const Duration(seconds: 5),
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final args = <String, Object?>{
      if (cameraId != null && cameraId.trim().isNotEmpty) 'cameraId': cameraId,
      'timeoutMs': timeout.inMilliseconds,
    };
    final raw = await ch.invokeMethod<Object?>(_method, args);
    return VGCamera2OpenCloseSmokeReport.fromMap(raw);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2OpenCloseSmokeReport &&
        other.success == success &&
        other.apiLevel == apiLevel &&
        other.hasCameraPermission == hasCameraPermission &&
        other.attemptedOpen == attemptedOpen &&
        other.opened == opened &&
        other.closed == closed &&
        other.cameraId == cameraId &&
        other.selectedLensFacing == selectedLensFacing &&
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
    closed,
    cameraId,
    selectedLensFacing,
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
      'VGCamera2OpenCloseSmokeReport('
      'success: $success, '
      'apiLevel: $apiLevel, '
      'hasCameraPermission: $hasCameraPermission, '
      'attemptedOpen: $attemptedOpen, '
      'opened: $opened, '
      'closed: $closed, '
      'cameraId: $cameraId, '
      'selectedLensFacing: $selectedLensFacing, '
      'decision: $decision, '
      'reasons: $reasons, '
      'events: $events, '
      'diagnostics: $diagnostics, '
      'durationMs: $durationMs)';
}
