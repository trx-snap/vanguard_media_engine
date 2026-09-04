// vg_camera2_thermal_resolution_reconfigure_smoke.dart
// vanguard_media_engine - P3-CAM-THERMAL-ACT-RESOLUTION-RECONFIG-DIAGNOSTIC:
// Android Camera2 single-camera session resolution reconfiguration smoke
// foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3ThermalResolutionReconfigureSmoke` MethodChannel
// route. Diagnostic-only - proves that, with CAMERA already granted, an
// opt-in Dart thermal policy `reduceResolution` decision (derived via
// vg_camera2_thermal_load_shedding_policy.dart, never invented natively) can
// drive a real single-camera Camera2 session reconfiguration to a strictly
// smaller supported YUV_420_888 output while the same CameraDevice stays
// open. Not recording, not encoder/renderer wiring, not a second camera,
// not a real OS thermal event, not production CameraX actuation, and not
// ConnectsApp/product UI wiring.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native
/// P3-CAM-THERMAL-ACT-RESOLUTION-RECONFIG-DIAGNOSTIC Camera2 thermal
/// resolution reconfigure smoke harness.
enum VGCamera2ThermalResolutionReconfigureSmokeDecision {
  /// The second (reduced) session was configured, started a repeating
  /// request, and observed at least one frame on the same still-open
  /// `CameraDevice`, with the first session/reader closed beforehand.
  resolutionReconfigured,

  /// `Manifest.permission.CAMERA` was not granted; no open was attempted.
  permissionRequired,

  /// `CameraManager` was unavailable from the system service.
  cameraManagerUnavailable,

  /// `CameraManager.getCameraIdList()` returned no cameras.
  noCamera,

  /// The requested camera id was not present in `getCameraIdList()`.
  cameraUnavailable,

  /// The selected camera exposes fewer than two positive YUV_420_888
  /// output sizes.
  unsupportedStream,

  /// No supported YUV_420_888 size has a strictly lower area than the
  /// selected initial size.
  noLowerResolutionAvailable,

  /// The supplied `policyDecision`/`policyTargetResolutionScale` did not
  /// satisfy `policyDecision == 'reduceResolution'` and
  /// `0.0 < policyTargetResolutionScale <= 1.0`.
  invalidPolicyDecision,

  /// `onDisconnected` fired during the open attempt.
  openDisconnected,

  /// `onError` fired during the open attempt.
  openError,

  /// The open attempt did not reach a terminal callback state in time.
  openTimeout,

  /// `onConfigureFailed` fired for the first capture session, or session
  /// creation threw.
  firstSessionConfigureFailed,

  /// The first capture session did not reach a terminal configuration
  /// state in time.
  firstSessionConfigureTimeout,

  /// The first `setRepeatingRequest` call threw.
  firstRepeatingRequestFailed,

  /// No frame arrived on the first `ImageReader` in time.
  firstFrameNeverObserved,

  /// The first capture session did not confirm `onClosed` in time before
  /// the second session was configured.
  firstSessionCloseTimeout,

  /// `onConfigureFailed` fired for the second capture session, or session
  /// creation threw.
  secondSessionConfigureFailed,

  /// The second capture session did not reach a terminal configuration
  /// state in time.
  secondSessionConfigureTimeout,

  /// The second `setRepeatingRequest` call threw.
  secondRepeatingRequestFailed,

  /// No frame arrived on the second `ImageReader` in time.
  secondFrameNeverObserved,

  /// `onCaptureFailed` fired for either repeating request before success.
  captureFailed;

  /// Maps a raw native decision string to the matching enum value, falling
  /// back to [captureFailed] for unrecognised/missing values.
  static VGCamera2ThermalResolutionReconfigureSmokeDecision fromRaw(
    Object? raw,
  ) {
    if (raw is! String) {
      return VGCamera2ThermalResolutionReconfigureSmokeDecision.captureFailed;
    }
    for (final value
        in VGCamera2ThermalResolutionReconfigureSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGCamera2ThermalResolutionReconfigureSmokeDecision.captureFailed;
  }
}

/// Immutable `{width, height}` Camera2 output size, as reported by the
/// native harness.
@immutable
class VGCamera2ResolutionSize {
  const VGCamera2ResolutionSize({required this.width, required this.height});

  final int width;
  final int height;

  /// The pixel area (`width * height`).
  int get area => width * height;

  /// Parses a size from a raw native map (`{"width": int, "height": int}`),
  /// defensively against both `Map<Object?, Object?>` and
  /// `Map<String, Object?>` shapes. Returns `null` when [raw] is not a map.
  static VGCamera2ResolutionSize? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final width = (raw['width'] as num?)?.toInt();
    final height = (raw['height'] as num?)?.toInt();
    if (width == null || height == null) return null;
    return VGCamera2ResolutionSize(width: width, height: height);
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'width': width,
    'height': height,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ResolutionSize &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() =>
      'VGCamera2ResolutionSize(width: $width, height: $height)';
}

/// Typed report returned by
/// [VGCamera2ThermalResolutionReconfigureSmokeReport.runAndroidCamera2ThermalResolutionReconfigureSmoke],
/// mirroring the native harness's result map.
@immutable
class VGCamera2ThermalResolutionReconfigureSmokeReport {
  const VGCamera2ThermalResolutionReconfigureSmokeReport({
    required this.success,
    required this.decision,
    required this.reasons,
    required this.events,
    required this.diagnostics,
    required this.proofBoundary,
    required this.apiLevel,
    required this.hasCameraPermission,
    required this.attemptedOpen,
    required this.opened,
    required this.cameraDeviceOpenCount,
    required this.sameCameraDeviceReused,
    this.cameraId,
    required this.selectedLensFacing,
    this.initialSize,
    this.reducedSize,
    this.initialArea,
    this.reducedArea,
    required this.policyDecision,
    required this.policyTargetResolutionScale,
    required this.policyDerivedResolutionTarget,
    required this.syntheticPolicyInput,
    required this.thermalStateRaw,
    required this.wasRecordingPolicyInput,
    required this.hadSecondaryCameraPolicyInput,
    required this.recordingActive,
    required this.firstSessionConfigured,
    required this.firstRepeatingStarted,
    required this.firstFrameObserved,
    required this.firstSessionClosed,
    required this.firstReaderClosed,
    required this.secondSessionConfigured,
    required this.secondRepeatingStarted,
    required this.secondFrameObserved,
    required this.secondSessionClosed,
    required this.secondReaderClosed,
    required this.deviceClosed,
    required this.sessionConfigureCount,
    required this.surfaceCountPerSession,
    required this.resolutionReconfigured,
    required this.cameraSessionReconfigured,
    required this.frameCadenceChangeProven,
    required this.durationMs,
    required this.realForcedOverheat,
    required this.powerManagerThermalStateMutated,
    required this.osThermalListenerTriggered,
    required this.mediaRecorderCreated,
    required this.encoderTouched,
    required this.rendererTouched,
    required this.productUiTouched,
    required this.secondaryCameraOpened,
    required this.secondaryCameraDisabled,
    required this.productCameraSessionTouched,
    required this.cameraXPathProven,
    required this.productionRecordingRebindProven,
  });

  /// Whether the native harness reached
  /// [VGCamera2ThermalResolutionReconfigureSmokeDecision.resolutionReconfigured]
  /// with all lifecycle/cleanup confirmations coherent.
  final bool success;

  /// The lifecycle decision.
  final VGCamera2ThermalResolutionReconfigureSmokeDecision decision;

  /// Stable snake_case reason codes explaining [decision].
  final List<String> reasons;

  /// Ordered lifecycle event trace (e.g. `onOpened`, `onFirstConfigured`,
  /// `policyDerivedReconfigureTriggered`, `onSecondConfigured`).
  final List<String> events;

  /// Additional diagnostic key/value pairs (e.g. native error details).
  final Map<String, Object?> diagnostics;

  /// The proof-boundary string this harness asserts verbatim:
  /// `single_camera_resolution_session_reconfigure_policy_derived_no_forced_heat_no_recording_no_encoder_no_product`.
  final String proofBoundary;

  /// `Build.VERSION.SDK_INT` on the probing device.
  final int apiLevel;

  /// Current `Manifest.permission.CAMERA` grant state - queried without
  /// prompting.
  final bool hasCameraPermission;

  /// Whether the native harness actually called `CameraManager.openCamera`.
  final bool attemptedOpen;

  /// Whether `onOpened` fired for the selected camera device.
  final bool opened;

  /// The number of times `CameraManager.openCamera` reached `onOpened`;
  /// must be `1` (the device is reconfigured, never reopened).
  final int cameraDeviceOpenCount;

  /// Whether the same `CameraDevice` was reused across both sessions;
  /// always equal to `cameraDeviceOpenCount == 1`.
  final bool sameCameraDeviceReused;

  /// The selected/requested camera id, or `null` when no camera could be
  /// selected.
  final String? cameraId;

  /// `front` / `back` / `external` / `unknown`.
  final String selectedLensFacing;

  /// The first session's `ImageReader` output size, or `null` if never
  /// selected.
  final VGCamera2ResolutionSize? initialSize;

  /// The second (policy-derived, reduced) session's `ImageReader` output
  /// size, or `null` if never selected.
  final VGCamera2ResolutionSize? reducedSize;

  /// `initialSize.area`, or `null` if unavailable.
  final int? initialArea;

  /// `reducedSize.area`, or `null` if unavailable.
  final int? reducedArea;

  /// The Dart-supplied policy decision string; must be `reduceResolution`
  /// for the harness to proceed.
  final String policyDecision;

  /// The Dart-supplied policy target resolution scale (`0.0` exclusive to
  /// `1.0` inclusive) used to bound the reduced-size selection.
  final double policyTargetResolutionScale;

  /// Always `true` - the reduced-size target is derived from the supplied
  /// Dart policy input, never invented natively.
  final bool policyDerivedResolutionTarget;

  /// Always `true` - the thermal input tuple below is synthetic, not a real
  /// OS thermal event.
  final bool syntheticPolicyInput;

  /// The synthetic raw thermal state fed to the mirrored policy (`2` =
  /// serious).
  final int thermalStateRaw;

  /// The synthetic `wasRecording` input fed to the mirrored policy (always
  /// `true` for this harness).
  final bool wasRecordingPolicyInput;

  /// The synthetic `hadSecondaryCamera` input fed to the mirrored policy
  /// (always `false` for this harness).
  final bool hadSecondaryCameraPolicyInput;

  /// Always `false` - this harness never starts a real recording.
  final bool recordingActive;

  /// Whether the first capture session reached `onConfigured`.
  final bool firstSessionConfigured;

  /// Whether the first `setRepeatingRequest` call succeeded.
  final bool firstRepeatingStarted;

  /// Whether at least one frame was observed on the first `ImageReader`.
  final bool firstFrameObserved;

  /// Whether the first capture session was confirmed closed via `onClosed`
  /// before the second session was configured.
  final bool firstSessionClosed;

  /// Whether `ImageReader.close()` was invoked on the first reader.
  final bool firstReaderClosed;

  /// Whether the second capture session reached `onConfigured`.
  final bool secondSessionConfigured;

  /// Whether the second `setRepeatingRequest` call succeeded.
  final bool secondRepeatingStarted;

  /// Whether at least one frame was observed on the second `ImageReader`.
  final bool secondFrameObserved;

  /// Whether the second capture session was confirmed closed via
  /// `onClosed` during cleanup.
  final bool secondSessionClosed;

  /// Whether `ImageReader.close()` was invoked on the second reader.
  final bool secondReaderClosed;

  /// Whether the camera device was confirmed closed via `onClosed`.
  final bool deviceClosed;

  /// The number of times `createCaptureSession` reached `onConfigured`;
  /// must be `2` on success (first, then second/reconfigured).
  final int sessionConfigureCount;

  /// The number of surfaces attached to each capture session; always `1`
  /// (a single `ImageReader` surface per session).
  final int surfaceCountPerSession;

  /// Whether the session was proven reconfigured to a strictly smaller
  /// resolution on the same `CameraDevice`; `true` only on
  /// [VGCamera2ThermalResolutionReconfigureSmokeDecision.resolutionReconfigured]
  /// success.
  final bool resolutionReconfigured;

  /// Whether the camera session was proven reconfigured; always equal to
  /// [resolutionReconfigured].
  final bool cameraSessionReconfigured;

  /// Always `false` - this harness does not measure or claim an observed
  /// frame-cadence change; [resolutionReconfigured] is the only claim.
  final bool frameCadenceChangeProven;

  /// Wall-clock duration of the harness run, in milliseconds.
  final int durationMs;

  /// Always `false` - no real device overheating was forced or claimed.
  final bool realForcedOverheat;

  /// Always `false` - `PowerManager` thermal state was never mutated.
  final bool powerManagerThermalStateMutated;

  /// Always `false` - the OS thermal listener was never triggered.
  final bool osThermalListenerTriggered;

  /// Always `false` - no `MediaRecorder` was created.
  final bool mediaRecorderCreated;

  /// Always `false` - no encoder was touched.
  final bool encoderTouched;

  /// Always `false` - no renderer was touched.
  final bool rendererTouched;

  /// Always `false` - no product/ConnectsApp UI was touched.
  final bool productUiTouched;

  /// Always `false` - no secondary camera was opened.
  final bool secondaryCameraOpened;

  /// Always `false` - no secondary camera was disabled.
  final bool secondaryCameraDisabled;

  /// Always `false` - no product camera session was touched.
  final bool productCameraSessionTouched;

  /// Always `false` - this diagnostic never actuates the production
  /// CameraX-backed `VanguardCameraSource` path.
  final bool cameraXPathProven;

  /// Always `false` - this diagnostic never proves a recording-safe
  /// CameraX rebind.
  final bool productionRecordingRebindProven;

  /// Whether [decision] is
  /// [VGCamera2ThermalResolutionReconfigureSmokeDecision.permissionRequired].
  bool get isPermissionRequired =>
      decision ==
      VGCamera2ThermalResolutionReconfigureSmokeDecision.permissionRequired;

  /// Whether [decision] is
  /// [VGCamera2ThermalResolutionReconfigureSmokeDecision.resolutionReconfigured].
  bool get isResolutionReconfigured =>
      decision ==
      VGCamera2ThermalResolutionReconfigureSmokeDecision.resolutionReconfigured;

  /// Whether the native harness actually attempted `openCamera`.
  bool get isAttempted => attemptedOpen;

  /// Whether both sessions/readers and the device were all confirmed torn
  /// down.
  bool get isCleanedUp =>
      firstSessionClosed &&
      firstReaderClosed &&
      secondSessionClosed &&
      secondReaderClosed &&
      deviceClosed;

  /// Whether the reduced size's area is strictly lower than the initial
  /// size's area (`false` when either size is missing).
  bool get isReducedAreaStrictlyLower {
    final initial = initialArea;
    final reduced = reducedArea;
    if (initial == null || reduced == null) return false;
    return reduced < initial;
  }

  /// Parses a report from the raw native map. Defensive against both
  /// `Map<Object?, Object?>` and `Map<String, Object?>` shapes, and against
  /// missing/malformed fields - unrecognised shapes fall back to
  /// [VGCamera2ThermalResolutionReconfigureSmokeDecision.captureFailed]
  /// with the raw map preserved in [diagnostics].
  static VGCamera2ThermalResolutionReconfigureSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGCamera2ThermalResolutionReconfigureSmokeReport(
        success: false,
        decision:
            VGCamera2ThermalResolutionReconfigureSmokeDecision.captureFailed,
        reasons: const <String>['native_result_not_a_map'],
        events: const <String>[],
        diagnostics: <String, Object?>{'raw': raw},
        proofBoundary: '',
        apiLevel: 0,
        hasCameraPermission: false,
        attemptedOpen: false,
        opened: false,
        cameraDeviceOpenCount: 0,
        sameCameraDeviceReused: false,
        cameraId: null,
        selectedLensFacing: 'unknown',
        initialSize: null,
        reducedSize: null,
        initialArea: null,
        reducedArea: null,
        policyDecision: 'reduceResolution',
        policyTargetResolutionScale: 0.5,
        policyDerivedResolutionTarget: true,
        syntheticPolicyInput: true,
        thermalStateRaw: 2,
        wasRecordingPolicyInput: true,
        hadSecondaryCameraPolicyInput: false,
        recordingActive: false,
        firstSessionConfigured: false,
        firstRepeatingStarted: false,
        firstFrameObserved: false,
        firstSessionClosed: false,
        firstReaderClosed: false,
        secondSessionConfigured: false,
        secondRepeatingStarted: false,
        secondFrameObserved: false,
        secondSessionClosed: false,
        secondReaderClosed: false,
        deviceClosed: false,
        sessionConfigureCount: 0,
        surfaceCountPerSession: 0,
        resolutionReconfigured: false,
        cameraSessionReconfigured: false,
        frameCadenceChangeProven: false,
        durationMs: 0,
        realForcedOverheat: false,
        powerManagerThermalStateMutated: false,
        osThermalListenerTriggered: false,
        mediaRecorderCreated: false,
        encoderTouched: false,
        rendererTouched: false,
        productUiTouched: false,
        secondaryCameraOpened: false,
        secondaryCameraDisabled: false,
        productCameraSessionTouched: false,
        cameraXPathProven: false,
        productionRecordingRebindProven: false,
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

    return VGCamera2ThermalResolutionReconfigureSmokeReport(
      success: raw['success'] as bool? ?? raw['pass'] as bool? ?? false,
      decision: VGCamera2ThermalResolutionReconfigureSmokeDecision.fromRaw(
        raw['decision'],
      ),
      reasons: reasons,
      events: events,
      diagnostics: diagnostics,
      proofBoundary: (raw['proofBoundary'] as String?) ?? '',
      apiLevel: (raw['apiLevel'] as num?)?.toInt() ?? 0,
      hasCameraPermission: raw['hasCameraPermission'] as bool? ?? false,
      attemptedOpen: raw['attemptedOpen'] as bool? ?? false,
      opened: raw['opened'] as bool? ?? false,
      cameraDeviceOpenCount:
          (raw['cameraDeviceOpenCount'] as num?)?.toInt() ?? 0,
      sameCameraDeviceReused: raw['sameCameraDeviceReused'] as bool? ?? false,
      cameraId: raw['cameraId'] as String?,
      selectedLensFacing: (raw['selectedLensFacing'] as String?) ?? 'unknown',
      initialSize: VGCamera2ResolutionSize.fromMap(raw['initialSize']),
      reducedSize: VGCamera2ResolutionSize.fromMap(raw['reducedSize']),
      initialArea: (raw['initialArea'] as num?)?.toInt(),
      reducedArea: (raw['reducedArea'] as num?)?.toInt(),
      policyDecision: (raw['policyDecision'] as String?) ?? 'reduceResolution',
      policyTargetResolutionScale:
          (raw['policyTargetResolutionScale'] as num?)?.toDouble() ?? 0.5,
      policyDerivedResolutionTarget:
          raw['policyDerivedResolutionTarget'] as bool? ?? true,
      syntheticPolicyInput: raw['syntheticPolicyInput'] as bool? ?? true,
      thermalStateRaw: (raw['thermalStateRaw'] as num?)?.toInt() ?? 2,
      wasRecordingPolicyInput: raw['wasRecordingPolicyInput'] as bool? ?? true,
      hadSecondaryCameraPolicyInput:
          raw['hadSecondaryCameraPolicyInput'] as bool? ?? false,
      recordingActive: raw['recordingActive'] as bool? ?? false,
      firstSessionConfigured: raw['firstSessionConfigured'] as bool? ?? false,
      firstRepeatingStarted: raw['firstRepeatingStarted'] as bool? ?? false,
      firstFrameObserved: raw['firstFrameObserved'] as bool? ?? false,
      firstSessionClosed: raw['firstSessionClosed'] as bool? ?? false,
      firstReaderClosed: raw['firstReaderClosed'] as bool? ?? false,
      secondSessionConfigured: raw['secondSessionConfigured'] as bool? ?? false,
      secondRepeatingStarted: raw['secondRepeatingStarted'] as bool? ?? false,
      secondFrameObserved: raw['secondFrameObserved'] as bool? ?? false,
      secondSessionClosed: raw['secondSessionClosed'] as bool? ?? false,
      secondReaderClosed: raw['secondReaderClosed'] as bool? ?? false,
      deviceClosed: raw['deviceClosed'] as bool? ?? false,
      sessionConfigureCount:
          (raw['sessionConfigureCount'] as num?)?.toInt() ?? 0,
      surfaceCountPerSession:
          (raw['surfaceCountPerSession'] as num?)?.toInt() ?? 0,
      resolutionReconfigured: raw['resolutionReconfigured'] as bool? ?? false,
      cameraSessionReconfigured:
          raw['cameraSessionReconfigured'] as bool? ?? false,
      frameCadenceChangeProven:
          raw['frameCadenceChangeProven'] as bool? ?? false,
      durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
      realForcedOverheat: raw['realForcedOverheat'] as bool? ?? false,
      powerManagerThermalStateMutated:
          raw['powerManagerThermalStateMutated'] as bool? ?? false,
      osThermalListenerTriggered:
          raw['osThermalListenerTriggered'] as bool? ?? false,
      mediaRecorderCreated: raw['mediaRecorderCreated'] as bool? ?? false,
      encoderTouched: raw['encoderTouched'] as bool? ?? false,
      rendererTouched: raw['rendererTouched'] as bool? ?? false,
      productUiTouched: raw['productUiTouched'] as bool? ?? false,
      secondaryCameraOpened: raw['secondaryCameraOpened'] as bool? ?? false,
      secondaryCameraDisabled: raw['secondaryCameraDisabled'] as bool? ?? false,
      productCameraSessionTouched:
          raw['productCameraSessionTouched'] as bool? ?? false,
      cameraXPathProven: raw['cameraXPathProven'] as bool? ?? false,
      productionRecordingRebindProven:
          raw['productionRecordingRebindProven'] as bool? ?? false,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'success': success,
      'decision': decision.name,
      'reasons': reasons,
      'events': events,
      'diagnostics': diagnostics,
      'proofBoundary': proofBoundary,
      'apiLevel': apiLevel,
      'hasCameraPermission': hasCameraPermission,
      'attemptedOpen': attemptedOpen,
      'opened': opened,
      'cameraDeviceOpenCount': cameraDeviceOpenCount,
      'sameCameraDeviceReused': sameCameraDeviceReused,
      'cameraId': cameraId,
      'selectedLensFacing': selectedLensFacing,
      'initialSize': initialSize?.toMap(),
      'reducedSize': reducedSize?.toMap(),
      'initialArea': initialArea,
      'reducedArea': reducedArea,
      'policyDecision': policyDecision,
      'policyTargetResolutionScale': policyTargetResolutionScale,
      'policyDerivedResolutionTarget': policyDerivedResolutionTarget,
      'syntheticPolicyInput': syntheticPolicyInput,
      'thermalStateRaw': thermalStateRaw,
      'wasRecordingPolicyInput': wasRecordingPolicyInput,
      'hadSecondaryCameraPolicyInput': hadSecondaryCameraPolicyInput,
      'recordingActive': recordingActive,
      'firstSessionConfigured': firstSessionConfigured,
      'firstRepeatingStarted': firstRepeatingStarted,
      'firstFrameObserved': firstFrameObserved,
      'firstSessionClosed': firstSessionClosed,
      'firstReaderClosed': firstReaderClosed,
      'secondSessionConfigured': secondSessionConfigured,
      'secondRepeatingStarted': secondRepeatingStarted,
      'secondFrameObserved': secondFrameObserved,
      'secondSessionClosed': secondSessionClosed,
      'secondReaderClosed': secondReaderClosed,
      'deviceClosed': deviceClosed,
      'sessionConfigureCount': sessionConfigureCount,
      'surfaceCountPerSession': surfaceCountPerSession,
      'resolutionReconfigured': resolutionReconfigured,
      'cameraSessionReconfigured': cameraSessionReconfigured,
      'frameCadenceChangeProven': frameCadenceChangeProven,
      'durationMs': durationMs,
      'realForcedOverheat': realForcedOverheat,
      'powerManagerThermalStateMutated': powerManagerThermalStateMutated,
      'osThermalListenerTriggered': osThermalListenerTriggered,
      'mediaRecorderCreated': mediaRecorderCreated,
      'encoderTouched': encoderTouched,
      'rendererTouched': rendererTouched,
      'productUiTouched': productUiTouched,
      'secondaryCameraOpened': secondaryCameraOpened,
      'secondaryCameraDisabled': secondaryCameraDisabled,
      'productCameraSessionTouched': productCameraSessionTouched,
      'cameraXPathProven': cameraXPathProven,
      'productionRecordingRebindProven': productionRecordingRebindProven,
    };
  }

  static const String _method =
      'runAndroidDagPhase3ThermalResolutionReconfigureSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android-backed native Camera2 thermal resolution
  /// reconfigure smoke harness and parses the result.
  ///
  /// [cameraId] selects a specific camera id; omit or pass blank to let the
  /// native harness select the first back-facing camera (falling back to
  /// the first camera in `getCameraIdList()`).
  ///
  /// [policyTargetResolutionScale] and [policyDecision] must be derived from
  /// [VGCamera2ThermalLoadSheddingPlanner] with an opt-in
  /// `allowResolutionStep: true` planner; the native harness never invents
  /// thermal policy and validates these inputs before proceeding.
  ///
  /// [timeout] bounds how long the harness waits for each lifecycle stage to
  /// reach a terminal state; the native side clamps this to 2-20 seconds.
  ///
  /// [maxWidth] / [maxHeight] bound the selected first `ImageReader` output
  /// size; the native side clamps these to 160-1920.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGCamera2ThermalResolutionReconfigureSmokeReport>
  runAndroidCamera2ThermalResolutionReconfigureSmoke({
    String? cameraId,
    double policyTargetResolutionScale = 0.5,
    String policyDecision = 'reduceResolution',
    Duration timeout = const Duration(seconds: 10),
    int maxWidth = 640,
    int maxHeight = 480,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final args = <String, Object?>{
      if (cameraId != null && cameraId.trim().isNotEmpty) 'cameraId': cameraId,
      'policyTargetResolutionScale': policyTargetResolutionScale,
      'policyDecision': policyDecision,
      'timeoutMs': timeout.inMilliseconds,
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
    };
    final raw = await ch.invokeMethod<Object?>(_method, args);
    return VGCamera2ThermalResolutionReconfigureSmokeReport.fromMap(raw);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ThermalResolutionReconfigureSmokeReport &&
        other.success == success &&
        other.decision == decision &&
        listEquals(other.reasons, reasons) &&
        listEquals(other.events, events) &&
        mapEquals(other.diagnostics, diagnostics) &&
        other.proofBoundary == proofBoundary &&
        other.apiLevel == apiLevel &&
        other.hasCameraPermission == hasCameraPermission &&
        other.attemptedOpen == attemptedOpen &&
        other.opened == opened &&
        other.cameraDeviceOpenCount == cameraDeviceOpenCount &&
        other.sameCameraDeviceReused == sameCameraDeviceReused &&
        other.cameraId == cameraId &&
        other.selectedLensFacing == selectedLensFacing &&
        other.initialSize == initialSize &&
        other.reducedSize == reducedSize &&
        other.initialArea == initialArea &&
        other.reducedArea == reducedArea &&
        other.policyDecision == policyDecision &&
        other.policyTargetResolutionScale == policyTargetResolutionScale &&
        other.policyDerivedResolutionTarget == policyDerivedResolutionTarget &&
        other.syntheticPolicyInput == syntheticPolicyInput &&
        other.thermalStateRaw == thermalStateRaw &&
        other.wasRecordingPolicyInput == wasRecordingPolicyInput &&
        other.hadSecondaryCameraPolicyInput == hadSecondaryCameraPolicyInput &&
        other.recordingActive == recordingActive &&
        other.firstSessionConfigured == firstSessionConfigured &&
        other.firstRepeatingStarted == firstRepeatingStarted &&
        other.firstFrameObserved == firstFrameObserved &&
        other.firstSessionClosed == firstSessionClosed &&
        other.firstReaderClosed == firstReaderClosed &&
        other.secondSessionConfigured == secondSessionConfigured &&
        other.secondRepeatingStarted == secondRepeatingStarted &&
        other.secondFrameObserved == secondFrameObserved &&
        other.secondSessionClosed == secondSessionClosed &&
        other.secondReaderClosed == secondReaderClosed &&
        other.deviceClosed == deviceClosed &&
        other.sessionConfigureCount == sessionConfigureCount &&
        other.surfaceCountPerSession == surfaceCountPerSession &&
        other.resolutionReconfigured == resolutionReconfigured &&
        other.cameraSessionReconfigured == cameraSessionReconfigured &&
        other.frameCadenceChangeProven == frameCadenceChangeProven &&
        other.durationMs == durationMs &&
        other.realForcedOverheat == realForcedOverheat &&
        other.powerManagerThermalStateMutated ==
            powerManagerThermalStateMutated &&
        other.osThermalListenerTriggered == osThermalListenerTriggered &&
        other.mediaRecorderCreated == mediaRecorderCreated &&
        other.encoderTouched == encoderTouched &&
        other.rendererTouched == rendererTouched &&
        other.productUiTouched == productUiTouched &&
        other.secondaryCameraOpened == secondaryCameraOpened &&
        other.secondaryCameraDisabled == secondaryCameraDisabled &&
        other.productCameraSessionTouched == productCameraSessionTouched &&
        other.cameraXPathProven == cameraXPathProven &&
        other.productionRecordingRebindProven ==
            productionRecordingRebindProven;
  }

  @override
  int get hashCode => Object.hash(
    Object.hash(
      success,
      decision,
      Object.hashAll(reasons),
      Object.hashAll(events),
      _stableDiagnosticsHash(diagnostics),
      proofBoundary,
      apiLevel,
      hasCameraPermission,
      attemptedOpen,
    ),
    Object.hash(
      opened,
      cameraDeviceOpenCount,
      sameCameraDeviceReused,
      cameraId,
      selectedLensFacing,
      initialSize,
      reducedSize,
      initialArea,
      reducedArea,
    ),
    Object.hash(
      policyDecision,
      policyTargetResolutionScale,
      policyDerivedResolutionTarget,
      syntheticPolicyInput,
      thermalStateRaw,
      wasRecordingPolicyInput,
      hadSecondaryCameraPolicyInput,
      recordingActive,
    ),
    Object.hash(
      firstSessionConfigured,
      firstRepeatingStarted,
      firstFrameObserved,
      firstSessionClosed,
      firstReaderClosed,
      secondSessionConfigured,
      secondRepeatingStarted,
      secondFrameObserved,
    ),
    Object.hash(
      secondSessionClosed,
      secondReaderClosed,
      deviceClosed,
      sessionConfigureCount,
      surfaceCountPerSession,
      resolutionReconfigured,
      cameraSessionReconfigured,
      frameCadenceChangeProven,
    ),
    Object.hash(
      durationMs,
      realForcedOverheat,
      powerManagerThermalStateMutated,
      osThermalListenerTriggered,
      mediaRecorderCreated,
      encoderTouched,
      rendererTouched,
      productUiTouched,
    ),
    Object.hash(
      secondaryCameraOpened,
      secondaryCameraDisabled,
      productCameraSessionTouched,
      cameraXPathProven,
      productionRecordingRebindProven,
    ),
  );

  static int _stableDiagnosticsHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGCamera2ThermalResolutionReconfigureSmokeReport('
      'success: $success, '
      'decision: $decision, '
      'reasons: $reasons, '
      'events: $events, '
      'diagnostics: $diagnostics, '
      'proofBoundary: $proofBoundary, '
      'apiLevel: $apiLevel, '
      'hasCameraPermission: $hasCameraPermission, '
      'attemptedOpen: $attemptedOpen, '
      'opened: $opened, '
      'cameraDeviceOpenCount: $cameraDeviceOpenCount, '
      'sameCameraDeviceReused: $sameCameraDeviceReused, '
      'cameraId: $cameraId, '
      'selectedLensFacing: $selectedLensFacing, '
      'initialSize: $initialSize, '
      'reducedSize: $reducedSize, '
      'initialArea: $initialArea, '
      'reducedArea: $reducedArea, '
      'policyDecision: $policyDecision, '
      'policyTargetResolutionScale: $policyTargetResolutionScale, '
      'policyDerivedResolutionTarget: $policyDerivedResolutionTarget, '
      'syntheticPolicyInput: $syntheticPolicyInput, '
      'thermalStateRaw: $thermalStateRaw, '
      'wasRecordingPolicyInput: $wasRecordingPolicyInput, '
      'hadSecondaryCameraPolicyInput: $hadSecondaryCameraPolicyInput, '
      'recordingActive: $recordingActive, '
      'firstSessionConfigured: $firstSessionConfigured, '
      'firstRepeatingStarted: $firstRepeatingStarted, '
      'firstFrameObserved: $firstFrameObserved, '
      'firstSessionClosed: $firstSessionClosed, '
      'firstReaderClosed: $firstReaderClosed, '
      'secondSessionConfigured: $secondSessionConfigured, '
      'secondRepeatingStarted: $secondRepeatingStarted, '
      'secondFrameObserved: $secondFrameObserved, '
      'secondSessionClosed: $secondSessionClosed, '
      'secondReaderClosed: $secondReaderClosed, '
      'deviceClosed: $deviceClosed, '
      'sessionConfigureCount: $sessionConfigureCount, '
      'surfaceCountPerSession: $surfaceCountPerSession, '
      'resolutionReconfigured: $resolutionReconfigured, '
      'cameraSessionReconfigured: $cameraSessionReconfigured, '
      'frameCadenceChangeProven: $frameCadenceChangeProven, '
      'durationMs: $durationMs, '
      'realForcedOverheat: $realForcedOverheat, '
      'powerManagerThermalStateMutated: $powerManagerThermalStateMutated, '
      'osThermalListenerTriggered: $osThermalListenerTriggered, '
      'mediaRecorderCreated: $mediaRecorderCreated, '
      'encoderTouched: $encoderTouched, '
      'rendererTouched: $rendererTouched, '
      'productUiTouched: $productUiTouched, '
      'secondaryCameraOpened: $secondaryCameraOpened, '
      'secondaryCameraDisabled: $secondaryCameraDisabled, '
      'productCameraSessionTouched: $productCameraSessionTouched, '
      'cameraXPathProven: $cameraXPathProven, '
      'productionRecordingRebindProven: $productionRecordingRebindProven)';
}
