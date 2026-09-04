// vg_camera2_thermal_fps_action_smoke.dart
// vanguard_media_engine - P3-CAM-THERMAL-ACT-FPS-REQUEST-ACTION: Android
// Camera2 repeating-request AE target FPS range mutation smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3ThermalFpsActionSmoke` MethodChannel route.
// Diagnostic-only - proves that, with CAMERA already granted, Vanguard can
// open one selected Camera2 device, start a repeating request with an
// initial CONTROL_AE_TARGET_FPS_RANGE, then - using a synthetic
// serious-thermal policy tuple mirrored from
// vg_camera2_thermal_load_shedding_policy.dart (thermalState=serious,
// wasRecording=true, hadSecondaryCamera=false) - mutate the same repeating
// request to a strictly-lower-upper AE FPS range and observe at least two
// consecutive completed captures tagged with the updated request. Not
// recording, not encoder/renderer wiring, not a second camera, not a real
// OS thermal event, and not ConnectsApp/product UI wiring.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native P3-CAM-THERMAL-ACT-FPS-REQUEST-ACTION
/// Camera2 thermal FPS action smoke harness.
enum VGCamera2ThermalFpsActionSmokeDecision {
  /// The updated (reduced) AE target FPS range repeating request was
  /// observed via at least two consecutive completed captures tagged with
  /// the updated request.
  fpsRangeMutated,

  /// `Manifest.permission.CAMERA` was not granted; no open was attempted.
  permissionRequired,

  /// `CameraManager` was unavailable from the system service.
  cameraManagerUnavailable,

  /// `CameraManager.getCameraIdList()` returned no cameras.
  noCamera,

  /// The requested camera id was not present in `getCameraIdList()`.
  cameraUnavailable,

  /// The selected camera exposes no positive YUV_420_888 output sizes.
  unsupportedStream,

  /// The selected camera advertises no `CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES`.
  unsupportedAeFpsRanges,

  /// No advertised AE FPS range has an upper bound strictly lower than the
  /// selected initial range's upper bound.
  noLowerFpsRangeAvailable,

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

  /// The initial `setRepeatingRequest` call threw.
  initialRepeatingRequestFailed,

  /// The updated `setRepeatingRequest` call threw.
  updatedRepeatingRequestFailed,

  /// No completed capture matching the initial request tag arrived in time.
  initialRangeNeverObserved,

  /// Fewer than two consecutive completed captures matching the updated
  /// request tag arrived in time.
  updatedRangeNeverObserved,

  /// `onCaptureFailed` fired for the repeating request.
  captureFailed;

  /// Maps a raw native decision string to the matching enum value, falling
  /// back to [captureFailed] for unrecognised/missing values.
  static VGCamera2ThermalFpsActionSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGCamera2ThermalFpsActionSmokeDecision.captureFailed;
    }
    for (final value in VGCamera2ThermalFpsActionSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGCamera2ThermalFpsActionSmokeDecision.captureFailed;
  }
}

/// Immutable `{lower, upper}` AE target FPS range, as reported by the native
/// harness.
@immutable
class VGCamera2AeFpsRange {
  const VGCamera2AeFpsRange({required this.lower, required this.upper});

  final int lower;
  final int upper;

  /// Parses a range from a raw native map (`{"lower": int, "upper": int}`),
  /// defensively against both `Map<Object?, Object?>` and
  /// `Map<String, Object?>` shapes. Returns `null` when [raw] is not a map.
  static VGCamera2AeFpsRange? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final lower = (raw['lower'] as num?)?.toInt();
    final upper = (raw['upper'] as num?)?.toInt();
    if (lower == null || upper == null) return null;
    return VGCamera2AeFpsRange(lower: lower, upper: upper);
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'lower': lower,
    'upper': upper,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2AeFpsRange &&
        other.lower == lower &&
        other.upper == upper;
  }

  @override
  int get hashCode => Object.hash(lower, upper);

  @override
  String toString() => 'VGCamera2AeFpsRange(lower: $lower, upper: $upper)';
}

/// Typed report returned by
/// [VGCamera2ThermalFpsActionSmokeReport.runAndroidCamera2ThermalFpsActionSmoke],
/// mirroring the native harness's result map.
@immutable
class VGCamera2ThermalFpsActionSmokeReport {
  const VGCamera2ThermalFpsActionSmokeReport({
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
    required this.sessionConfigured,
    required this.initialRepeatingStarted,
    required this.updatedRepeatingStarted,
    required this.initialCaptureCompleted,
    required this.updatedCaptureCompleted,
    required this.updatedConsecutiveCaptureCount,
    this.cameraId,
    required this.selectedLensFacing,
    required this.selectedWidth,
    required this.selectedHeight,
    required this.imageFormatName,
    required this.templateUsed,
    this.initialAeTargetFpsRange,
    this.reducedAeTargetFpsRange,
    required this.policyTargetFps,
    required this.syntheticPolicyInput,
    required this.thermalStateRaw,
    required this.wasRecordingPolicyInput,
    required this.hadSecondaryCameraPolicyInput,
    required this.recordingActive,
    required this.aeTargetFpsRangeMutated,
    required this.captureRequestUpdated,
    required this.repeatingRequestMutated,
    required this.hardwareAppliedRangeConfirmed,
    required this.frameCadenceChangeProven,
    required this.sessionConfigureCount,
    required this.surfaceCount,
    required this.reusedRequestBuilder,
    required this.sessionClosed,
    required this.deviceClosed,
    required this.imageReaderClosed,
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
    required this.cameraSessionReconfigured,
  });

  /// Whether the native harness reached
  /// [VGCamera2ThermalFpsActionSmokeDecision.fpsRangeMutated] with all
  /// lifecycle/cleanup confirmations coherent.
  final bool success;

  /// The lifecycle decision.
  final VGCamera2ThermalFpsActionSmokeDecision decision;

  /// Stable snake_case reason codes explaining [decision].
  final List<String> reasons;

  /// Ordered lifecycle event trace (e.g. `onOpened`, `onConfigured`,
  /// `initialRepeatingRequestStarted`, `onCaptureCompleted:updated`).
  final List<String> events;

  /// Additional diagnostic key/value pairs (e.g. native error details).
  final Map<String, Object?> diagnostics;

  /// The proof-boundary string this harness asserts verbatim:
  /// `single_camera_repeating_request_ae_fps_range_mutation_synthetic_thermal_no_forced_heat_no_recording_no_encoder`.
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

  /// Whether the capture session reached `onConfigured`.
  final bool sessionConfigured;

  /// Whether the initial `setRepeatingRequest` call succeeded.
  final bool initialRepeatingStarted;

  /// Whether the updated (post-thermal-action) `setRepeatingRequest` call
  /// succeeded.
  final bool updatedRepeatingStarted;

  /// Whether at least one completed capture matched the initial request tag.
  final bool initialCaptureCompleted;

  /// Whether at least one completed capture matched the updated request tag.
  final bool updatedCaptureCompleted;

  /// The number of *consecutive* completed captures observed matching the
  /// updated request tag; must be `>= 2` for [success].
  final int updatedConsecutiveCaptureCount;

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

  /// Always `TEMPLATE_PREVIEW` for this harness.
  final String templateUsed;

  /// The initial `CONTROL_AE_TARGET_FPS_RANGE` applied to the repeating
  /// request, or `null` if never selected.
  final VGCamera2AeFpsRange? initialAeTargetFpsRange;

  /// The reduced `CONTROL_AE_TARGET_FPS_RANGE` applied after the synthetic
  /// thermal action, or `null` if never selected.
  final VGCamera2AeFpsRange? reducedAeTargetFpsRange;

  /// The frame-rate target computed by mirroring
  /// `VGCamera2ThermalLoadSheddingPlanner._calculateReducedFps` (minFpsFloor
  /// = 15) against the initial range's upper bound.
  final int policyTargetFps;

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

  /// Whether the updated AE target FPS range repeating request was proven
  /// mutated (i.e. [decision] is
  /// [VGCamera2ThermalFpsActionSmokeDecision.fpsRangeMutated] and
  /// [updatedConsecutiveCaptureCount] `>= 2`).
  final bool aeTargetFpsRangeMutated;

  /// Whether the capture request was proven updated to the reduced AE target
  /// FPS range; always equal to [aeTargetFpsRangeMutated].
  final bool captureRequestUpdated;

  /// Whether the repeating request was proven mutated to the reduced AE
  /// target FPS range; always equal to [aeTargetFpsRangeMutated].
  final bool repeatingRequestMutated;

  /// Whether `CaptureResult.CONTROL_AE_TARGET_FPS_RANGE` was readable on the
  /// first updated-tag completed capture and matched
  /// [reducedAeTargetFpsRange]. `false` (with a
  /// `ae_fps_range_result_key_missing` reason) when the result key was
  /// unavailable on this device.
  final bool hardwareAppliedRangeConfirmed;

  /// Always `false` - this harness does not measure or claim an observed
  /// frame-cadence change; [aeTargetFpsRangeMutated] is the only claim.
  final bool frameCadenceChangeProven;

  /// The number of times `createCaptureSession` reached `onConfigured`;
  /// must be `1` (no session reconfiguration).
  final int sessionConfigureCount;

  /// The number of surfaces attached to the capture session; must be `1`
  /// (the `ImageReader` surface only).
  final int surfaceCount;

  /// Whether the same `CaptureRequest.Builder` was reused to mutate/re-tag
  /// both the initial and updated repeating requests.
  final bool reusedRequestBuilder;

  /// Whether the capture session was confirmed closed via `onClosed`.
  final bool sessionClosed;

  /// Whether the camera device was confirmed closed via `onClosed`.
  final bool deviceClosed;

  /// Whether `ImageReader.close()` was invoked.
  final bool imageReaderClosed;

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

  /// Always `false` - the capture session was never reconfigured; backed by
  /// [sessionConfigureCount] `== 1`, [surfaceCount] `== 1`, and
  /// [reusedRequestBuilder] `== true`.
  final bool cameraSessionReconfigured;

  /// Whether [decision] is
  /// [VGCamera2ThermalFpsActionSmokeDecision.permissionRequired].
  bool get isPermissionRequired =>
      decision == VGCamera2ThermalFpsActionSmokeDecision.permissionRequired;

  /// Whether [decision] is
  /// [VGCamera2ThermalFpsActionSmokeDecision.fpsRangeMutated].
  bool get isFpsRangeMutated =>
      decision == VGCamera2ThermalFpsActionSmokeDecision.fpsRangeMutated;

  /// Whether the native harness actually attempted `openCamera`.
  bool get isAttempted => attemptedOpen;

  /// Whether the capture session, device, and ImageReader were all confirmed
  /// torn down.
  bool get isCleanedUp => sessionClosed && deviceClosed && imageReaderClosed;

  /// Whether the reduced range's upper bound is strictly lower than the
  /// initial range's upper bound (`false` when either range is missing).
  bool get isReducedRangeStrictlyLower {
    final initial = initialAeTargetFpsRange;
    final reduced = reducedAeTargetFpsRange;
    if (initial == null || reduced == null) return false;
    return reduced.upper < initial.upper;
  }

  /// Parses a report from the raw native map. Defensive against both
  /// `Map<Object?, Object?>` and `Map<String, Object?>` shapes, and against
  /// missing/malformed fields - unrecognised shapes fall back to
  /// [VGCamera2ThermalFpsActionSmokeDecision.captureFailed] with the raw map
  /// preserved in [diagnostics].
  static VGCamera2ThermalFpsActionSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGCamera2ThermalFpsActionSmokeReport(
        success: false,
        decision: VGCamera2ThermalFpsActionSmokeDecision.captureFailed,
        reasons: const <String>['native_result_not_a_map'],
        events: const <String>[],
        diagnostics: <String, Object?>{'raw': raw},
        proofBoundary: '',
        apiLevel: 0,
        hasCameraPermission: false,
        attemptedOpen: false,
        opened: false,
        sessionConfigured: false,
        initialRepeatingStarted: false,
        updatedRepeatingStarted: false,
        initialCaptureCompleted: false,
        updatedCaptureCompleted: false,
        updatedConsecutiveCaptureCount: 0,
        cameraId: null,
        selectedLensFacing: 'unknown',
        selectedWidth: 0,
        selectedHeight: 0,
        imageFormatName: 'YUV_420_888',
        templateUsed: 'TEMPLATE_PREVIEW',
        initialAeTargetFpsRange: null,
        reducedAeTargetFpsRange: null,
        policyTargetFps: 0,
        syntheticPolicyInput: true,
        thermalStateRaw: 2,
        wasRecordingPolicyInput: true,
        hadSecondaryCameraPolicyInput: false,
        recordingActive: false,
        aeTargetFpsRangeMutated: false,
        captureRequestUpdated: false,
        repeatingRequestMutated: false,
        hardwareAppliedRangeConfirmed: false,
        frameCadenceChangeProven: false,
        sessionConfigureCount: 0,
        surfaceCount: 0,
        reusedRequestBuilder: false,
        sessionClosed: false,
        deviceClosed: false,
        imageReaderClosed: false,
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
        cameraSessionReconfigured: false,
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

    return VGCamera2ThermalFpsActionSmokeReport(
      success: raw['success'] as bool? ?? raw['pass'] as bool? ?? false,
      decision: VGCamera2ThermalFpsActionSmokeDecision.fromRaw(raw['decision']),
      reasons: reasons,
      events: events,
      diagnostics: diagnostics,
      proofBoundary: (raw['proofBoundary'] as String?) ?? '',
      apiLevel: (raw['apiLevel'] as num?)?.toInt() ?? 0,
      hasCameraPermission: raw['hasCameraPermission'] as bool? ?? false,
      attemptedOpen: raw['attemptedOpen'] as bool? ?? false,
      opened: raw['opened'] as bool? ?? false,
      sessionConfigured: raw['sessionConfigured'] as bool? ?? false,
      initialRepeatingStarted: raw['initialRepeatingStarted'] as bool? ?? false,
      updatedRepeatingStarted: raw['updatedRepeatingStarted'] as bool? ?? false,
      initialCaptureCompleted: raw['initialCaptureCompleted'] as bool? ?? false,
      updatedCaptureCompleted: raw['updatedCaptureCompleted'] as bool? ?? false,
      updatedConsecutiveCaptureCount:
          (raw['updatedConsecutiveCaptureCount'] as num?)?.toInt() ?? 0,
      cameraId: raw['cameraId'] as String?,
      selectedLensFacing: (raw['selectedLensFacing'] as String?) ?? 'unknown',
      selectedWidth: (raw['selectedWidth'] as num?)?.toInt() ?? 0,
      selectedHeight: (raw['selectedHeight'] as num?)?.toInt() ?? 0,
      imageFormatName: (raw['imageFormatName'] as String?) ?? 'YUV_420_888',
      templateUsed: (raw['templateUsed'] as String?) ?? 'TEMPLATE_PREVIEW',
      initialAeTargetFpsRange: VGCamera2AeFpsRange.fromMap(
        raw['initialAeTargetFpsRange'],
      ),
      reducedAeTargetFpsRange: VGCamera2AeFpsRange.fromMap(
        raw['reducedAeTargetFpsRange'],
      ),
      policyTargetFps: (raw['policyTargetFps'] as num?)?.toInt() ?? 0,
      syntheticPolicyInput: raw['syntheticPolicyInput'] as bool? ?? true,
      thermalStateRaw: (raw['thermalStateRaw'] as num?)?.toInt() ?? 2,
      wasRecordingPolicyInput: raw['wasRecordingPolicyInput'] as bool? ?? true,
      hadSecondaryCameraPolicyInput:
          raw['hadSecondaryCameraPolicyInput'] as bool? ?? false,
      recordingActive: raw['recordingActive'] as bool? ?? false,
      aeTargetFpsRangeMutated: raw['aeTargetFpsRangeMutated'] as bool? ?? false,
      captureRequestUpdated: raw['captureRequestUpdated'] as bool? ?? false,
      repeatingRequestMutated: raw['repeatingRequestMutated'] as bool? ?? false,
      hardwareAppliedRangeConfirmed:
          raw['hardwareAppliedRangeConfirmed'] as bool? ?? false,
      frameCadenceChangeProven:
          raw['frameCadenceChangeProven'] as bool? ?? false,
      sessionConfigureCount:
          (raw['sessionConfigureCount'] as num?)?.toInt() ?? 0,
      surfaceCount: (raw['surfaceCount'] as num?)?.toInt() ?? 0,
      reusedRequestBuilder: raw['reusedRequestBuilder'] as bool? ?? false,
      sessionClosed: raw['sessionClosed'] as bool? ?? false,
      deviceClosed: raw['deviceClosed'] as bool? ?? false,
      imageReaderClosed: raw['imageReaderClosed'] as bool? ?? false,
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
      cameraSessionReconfigured:
          raw['cameraSessionReconfigured'] as bool? ?? false,
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
      'sessionConfigured': sessionConfigured,
      'initialRepeatingStarted': initialRepeatingStarted,
      'updatedRepeatingStarted': updatedRepeatingStarted,
      'initialCaptureCompleted': initialCaptureCompleted,
      'updatedCaptureCompleted': updatedCaptureCompleted,
      'updatedConsecutiveCaptureCount': updatedConsecutiveCaptureCount,
      'cameraId': cameraId,
      'selectedLensFacing': selectedLensFacing,
      'selectedWidth': selectedWidth,
      'selectedHeight': selectedHeight,
      'imageFormatName': imageFormatName,
      'templateUsed': templateUsed,
      'initialAeTargetFpsRange': initialAeTargetFpsRange?.toMap(),
      'reducedAeTargetFpsRange': reducedAeTargetFpsRange?.toMap(),
      'policyTargetFps': policyTargetFps,
      'syntheticPolicyInput': syntheticPolicyInput,
      'thermalStateRaw': thermalStateRaw,
      'wasRecordingPolicyInput': wasRecordingPolicyInput,
      'hadSecondaryCameraPolicyInput': hadSecondaryCameraPolicyInput,
      'recordingActive': recordingActive,
      'aeTargetFpsRangeMutated': aeTargetFpsRangeMutated,
      'captureRequestUpdated': captureRequestUpdated,
      'repeatingRequestMutated': repeatingRequestMutated,
      'hardwareAppliedRangeConfirmed': hardwareAppliedRangeConfirmed,
      'frameCadenceChangeProven': frameCadenceChangeProven,
      'sessionConfigureCount': sessionConfigureCount,
      'surfaceCount': surfaceCount,
      'reusedRequestBuilder': reusedRequestBuilder,
      'sessionClosed': sessionClosed,
      'deviceClosed': deviceClosed,
      'imageReaderClosed': imageReaderClosed,
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
      'cameraSessionReconfigured': cameraSessionReconfigured,
    };
  }

  static const String _method = 'runAndroidDagPhase3ThermalFpsActionSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Invokes the Android-backed native Camera2 thermal FPS action smoke
  /// harness and parses the result.
  ///
  /// [cameraId] selects a specific camera id; omit or pass blank to let the
  /// native harness select the first back-facing camera (falling back to the
  /// first camera in `getCameraIdList()`).
  ///
  /// [timeout] bounds how long the harness waits for each lifecycle stage to
  /// reach a terminal state; the native side clamps this to 2-20 seconds.
  ///
  /// [maxWidth] / [maxHeight] bound the selected `ImageReader` output size;
  /// the native side clamps these to 160-1920.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGCamera2ThermalFpsActionSmokeReport>
  runAndroidCamera2ThermalFpsActionSmoke({
    String? cameraId,
    Duration timeout = const Duration(seconds: 10),
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
    return VGCamera2ThermalFpsActionSmokeReport.fromMap(raw);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCamera2ThermalFpsActionSmokeReport &&
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
        other.sessionConfigured == sessionConfigured &&
        other.initialRepeatingStarted == initialRepeatingStarted &&
        other.updatedRepeatingStarted == updatedRepeatingStarted &&
        other.initialCaptureCompleted == initialCaptureCompleted &&
        other.updatedCaptureCompleted == updatedCaptureCompleted &&
        other.updatedConsecutiveCaptureCount ==
            updatedConsecutiveCaptureCount &&
        other.cameraId == cameraId &&
        other.selectedLensFacing == selectedLensFacing &&
        other.selectedWidth == selectedWidth &&
        other.selectedHeight == selectedHeight &&
        other.imageFormatName == imageFormatName &&
        other.templateUsed == templateUsed &&
        other.initialAeTargetFpsRange == initialAeTargetFpsRange &&
        other.reducedAeTargetFpsRange == reducedAeTargetFpsRange &&
        other.policyTargetFps == policyTargetFps &&
        other.syntheticPolicyInput == syntheticPolicyInput &&
        other.thermalStateRaw == thermalStateRaw &&
        other.wasRecordingPolicyInput == wasRecordingPolicyInput &&
        other.hadSecondaryCameraPolicyInput == hadSecondaryCameraPolicyInput &&
        other.recordingActive == recordingActive &&
        other.aeTargetFpsRangeMutated == aeTargetFpsRangeMutated &&
        other.captureRequestUpdated == captureRequestUpdated &&
        other.repeatingRequestMutated == repeatingRequestMutated &&
        other.hardwareAppliedRangeConfirmed == hardwareAppliedRangeConfirmed &&
        other.frameCadenceChangeProven == frameCadenceChangeProven &&
        other.sessionConfigureCount == sessionConfigureCount &&
        other.surfaceCount == surfaceCount &&
        other.reusedRequestBuilder == reusedRequestBuilder &&
        other.sessionClosed == sessionClosed &&
        other.deviceClosed == deviceClosed &&
        other.imageReaderClosed == imageReaderClosed &&
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
        other.cameraSessionReconfigured == cameraSessionReconfigured;
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
      sessionConfigured,
      initialRepeatingStarted,
      updatedRepeatingStarted,
      initialCaptureCompleted,
      updatedCaptureCompleted,
      updatedConsecutiveCaptureCount,
      cameraId,
    ),
    Object.hash(
      selectedLensFacing,
      selectedWidth,
      selectedHeight,
      imageFormatName,
      templateUsed,
      initialAeTargetFpsRange,
      reducedAeTargetFpsRange,
      policyTargetFps,
    ),
    Object.hash(
      syntheticPolicyInput,
      thermalStateRaw,
      wasRecordingPolicyInput,
      hadSecondaryCameraPolicyInput,
      recordingActive,
      aeTargetFpsRangeMutated,
      captureRequestUpdated,
      repeatingRequestMutated,
      hardwareAppliedRangeConfirmed,
      frameCadenceChangeProven,
    ),
    Object.hash(
      sessionConfigureCount,
      surfaceCount,
      reusedRequestBuilder,
      sessionClosed,
      deviceClosed,
      imageReaderClosed,
      durationMs,
      realForcedOverheat,
    ),
    Object.hash(
      powerManagerThermalStateMutated,
      osThermalListenerTriggered,
      mediaRecorderCreated,
      encoderTouched,
      rendererTouched,
      productUiTouched,
      secondaryCameraOpened,
      secondaryCameraDisabled,
    ),
    Object.hash(productCameraSessionTouched, cameraSessionReconfigured),
  );

  static int _stableDiagnosticsHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((key) => Object.hash(key, map[key])));
  }

  @override
  String toString() =>
      'VGCamera2ThermalFpsActionSmokeReport('
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
      'sessionConfigured: $sessionConfigured, '
      'initialRepeatingStarted: $initialRepeatingStarted, '
      'updatedRepeatingStarted: $updatedRepeatingStarted, '
      'initialCaptureCompleted: $initialCaptureCompleted, '
      'updatedCaptureCompleted: $updatedCaptureCompleted, '
      'updatedConsecutiveCaptureCount: $updatedConsecutiveCaptureCount, '
      'cameraId: $cameraId, '
      'selectedLensFacing: $selectedLensFacing, '
      'selectedWidth: $selectedWidth, '
      'selectedHeight: $selectedHeight, '
      'imageFormatName: $imageFormatName, '
      'templateUsed: $templateUsed, '
      'initialAeTargetFpsRange: $initialAeTargetFpsRange, '
      'reducedAeTargetFpsRange: $reducedAeTargetFpsRange, '
      'policyTargetFps: $policyTargetFps, '
      'syntheticPolicyInput: $syntheticPolicyInput, '
      'thermalStateRaw: $thermalStateRaw, '
      'wasRecordingPolicyInput: $wasRecordingPolicyInput, '
      'hadSecondaryCameraPolicyInput: $hadSecondaryCameraPolicyInput, '
      'recordingActive: $recordingActive, '
      'aeTargetFpsRangeMutated: $aeTargetFpsRangeMutated, '
      'captureRequestUpdated: $captureRequestUpdated, '
      'repeatingRequestMutated: $repeatingRequestMutated, '
      'hardwareAppliedRangeConfirmed: $hardwareAppliedRangeConfirmed, '
      'frameCadenceChangeProven: $frameCadenceChangeProven, '
      'sessionConfigureCount: $sessionConfigureCount, '
      'surfaceCount: $surfaceCount, '
      'reusedRequestBuilder: $reusedRequestBuilder, '
      'sessionClosed: $sessionClosed, '
      'deviceClosed: $deviceClosed, '
      'imageReaderClosed: $imageReaderClosed, '
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
      'cameraSessionReconfigured: $cameraSessionReconfigured)';
}
