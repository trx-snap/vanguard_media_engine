// vg_android_multicam_diagnostic_fail_closed_smoke.dart
// vanguard_media_engine - P3-CAM-CONCURRENT-DIAGNOSTIC-FAIL-CLOSED-ANDROID-HANDLER:
// Android MultiCam legacy diagnostic MethodChannel routes
// (measureMultiCamHardwareCost, runMultiCamStreamingDiagnostic,
// runMultiCamSyncDiagnostic, runMultiCamSourceLifecycleDiagnostic)
// fail-closed route smoke foundation.
//
// Pure Dart typed report and runner proving the four remaining Android
// MultiCam legacy diagnostic routes fail closed instead of falling through
// to plugin notImplemented: invalid args reject before any capability
// lookup or state check, and valid non-blank device ids fail closed with
// CONCURRENT_NOT_SUPPORTED (no matching concurrent hardware combo) or
// CONCURRENT_DIAGNOSTIC_NOT_READY (a combo exists, but this package has no
// production Android concurrent camera diagnostic lifecycle owner). This
// slice does NOT prove real concurrent capture, streaming, sync, source
// lifecycle, or hardware-cost measurement -- see the non-claim booleans
// below.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_camera_session.dart';

/// Proof boundary identifier for the Android MultiCam diagnostic fail-closed
/// route smoke.
const String kAndroidMultiCamDiagnosticFailClosedProofBoundary =
    'android_multicam_diagnostic_fail_closed_route_handling_capability_gated_no_camera_open_no_stream_no_sync';

/// Physical smoke START marker token.
const String kAndroidMultiCamDiagnosticFailClosedStartMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_DIAGNOSTIC_FAIL_CLOSED_PHYSICAL_SMOKE_START';

/// Physical smoke PASS marker token.
const String kAndroidMultiCamDiagnosticFailClosedPassMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_DIAGNOSTIC_FAIL_CLOSED_PHYSICAL_SMOKE_PASS';

/// Physical smoke FAIL marker token.
const String kAndroidMultiCamDiagnosticFailClosedFailMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_DIAGNOSTIC_FAIL_CLOSED_PHYSICAL_SMOKE_FAIL';

/// JSON payload log prefix.
const String kAndroidMultiCamDiagnosticFailClosedJsonPrefix =
    'ANDROID_DAG_PHASE3_MULTICAM_DIAGNOSTIC_FAIL_CLOSED_JSON:';

/// Error codes the direct diagnostic routes are allowed to return for a
/// valid (non-blank) device-id pair on hardware with no production
/// concurrent-diagnostic lifecycle owner.
const List<String> kAndroidMultiCamDiagnosticFailClosedAllowedErrorCodes =
    <String>['CONCURRENT_NOT_SUPPORTED', 'CONCURRENT_DIAGNOSTIC_NOT_READY'];

/// Immutable typed smoke report produced by
/// [VGAndroidMultiCamDiagnosticFailClosedSmokeRunner].
@immutable
class VGAndroidMultiCamDiagnosticFailClosedSmokeReport {
  const VGAndroidMultiCamDiagnosticFailClosedSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.directMeasureCostInvalidArgOk,
    required this.directMeasureCostFailClosedOk,
    required this.directMeasureCostErrorCode,
    required this.directStreamingDiagnosticInvalidArgOk,
    required this.directStreamingDiagnosticFailClosedOk,
    required this.directStreamingDiagnosticErrorCode,
    required this.directSyncDiagnosticInvalidArgOk,
    required this.directSyncDiagnosticFailClosedOk,
    required this.directSyncDiagnosticErrorCode,
    required this.directSourceLifecycleDiagnosticInvalidArgOk,
    required this.directSourceLifecycleDiagnosticFailClosedOk,
    required this.directSourceLifecycleDiagnosticErrorCode,
    required this.publicMeasureCostNullOk,
    required this.publicStreamingDiagnosticNullOk,
    required this.publicSyncDiagnosticNullOk,
    required this.publicSourceLifecycleDiagnosticNullOk,
    required this.physicalConcurrentCaptureProven,
    required this.hardwareCostMeasured,
    required this.streamingFramesProven,
    required this.syncProven,
    required this.sourceLifecycleProven,
    required this.cameraOpenedByDiagnosticRoute,
    required this.textureAllocated,
    required this.productUiWired,
    required this.reasons,
    required this.diagnostics,
  });

  /// Whether all verification lanes passed.
  final bool pass;

  /// Exact proof boundary token.
  final String proofBoundary;

  /// Whether a direct `measureMultiCamHardwareCost` call with missing/blank
  /// device ids fails with `PlatformException` code `INVALID_ARG`.
  final bool directMeasureCostInvalidArgOk;

  /// Whether a direct `measureMultiCamHardwareCost` call with valid
  /// non-blank device ids fails closed with `CONCURRENT_NOT_SUPPORTED` or
  /// `CONCURRENT_DIAGNOSTIC_NOT_READY` (never a fake cost report).
  final bool directMeasureCostFailClosedOk;

  /// The raw `PlatformException.code` observed for the valid-device-id
  /// direct `measureMultiCamHardwareCost` call, or `null` if none was
  /// thrown.
  final String? directMeasureCostErrorCode;

  /// Whether a direct `runMultiCamStreamingDiagnostic` call with
  /// missing/blank device ids fails with `PlatformException` code
  /// `INVALID_ARG`.
  final bool directStreamingDiagnosticInvalidArgOk;

  /// Whether a direct `runMultiCamStreamingDiagnostic` call with valid
  /// non-blank device ids fails closed with `CONCURRENT_NOT_SUPPORTED` or
  /// `CONCURRENT_DIAGNOSTIC_NOT_READY` (never a fake streaming report).
  final bool directStreamingDiagnosticFailClosedOk;

  /// The raw `PlatformException.code` observed for the valid-device-id
  /// direct `runMultiCamStreamingDiagnostic` call, or `null` if none was
  /// thrown.
  final String? directStreamingDiagnosticErrorCode;

  /// Whether a direct `runMultiCamSyncDiagnostic` call with missing/blank
  /// device ids fails with `PlatformException` code `INVALID_ARG`.
  final bool directSyncDiagnosticInvalidArgOk;

  /// Whether a direct `runMultiCamSyncDiagnostic` call with valid non-blank
  /// device ids fails closed with `CONCURRENT_NOT_SUPPORTED` or
  /// `CONCURRENT_DIAGNOSTIC_NOT_READY` (never a fake sync report).
  final bool directSyncDiagnosticFailClosedOk;

  /// The raw `PlatformException.code` observed for the valid-device-id
  /// direct `runMultiCamSyncDiagnostic` call, or `null` if none was thrown.
  final String? directSyncDiagnosticErrorCode;

  /// Whether a direct `runMultiCamSourceLifecycleDiagnostic` call with
  /// missing/blank device ids fails with `PlatformException` code
  /// `INVALID_ARG`.
  final bool directSourceLifecycleDiagnosticInvalidArgOk;

  /// Whether a direct `runMultiCamSourceLifecycleDiagnostic` call with valid
  /// non-blank device ids fails closed with `CONCURRENT_NOT_SUPPORTED` or
  /// `CONCURRENT_DIAGNOSTIC_NOT_READY` (never a fake source-lifecycle
  /// report).
  final bool directSourceLifecycleDiagnosticFailClosedOk;

  /// The raw `PlatformException.code` observed for the valid-device-id
  /// direct `runMultiCamSourceLifecycleDiagnostic` call, or `null` if none
  /// was thrown.
  final String? directSourceLifecycleDiagnosticErrorCode;

  /// Whether the public `VGCameraSession.measureMultiCamHardwareCost`
  /// returns `null`.
  final bool publicMeasureCostNullOk;

  /// Whether the public `VGCameraSession.runMultiCamStreamingDiagnostic`
  /// returns `null`.
  final bool publicStreamingDiagnosticNullOk;

  /// Whether the public `VGCameraSession.runMultiCamSyncDiagnostic` returns
  /// `null`.
  final bool publicSyncDiagnosticNullOk;

  /// Whether the public
  /// `VGCameraSession.runMultiCamSourceLifecycleDiagnostic` returns `null`.
  final bool publicSourceLifecycleDiagnosticNullOk;

  /// Always `false` in this slice: no real concurrent camera capture is
  /// implemented or proven.
  final bool physicalConcurrentCaptureProven;

  /// Always `false` in this slice: no ISP bandwidth/hardware cost is ever
  /// measured.
  final bool hardwareCostMeasured;

  /// Always `false` in this slice: no frames are ever streamed.
  final bool streamingFramesProven;

  /// Always `false` in this slice: no timestamp-pairing sync diagnostic is
  /// ever run.
  final bool syncProven;

  /// Always `false` in this slice: no media source lifecycle diagnostic is
  /// ever run.
  final bool sourceLifecycleProven;

  /// Always `false` in this slice: no route opens a camera.
  final bool cameraOpenedByDiagnosticRoute;

  /// Always `false` in this slice: no route allocates a
  /// TextureRegistry/SurfaceTexture.
  final bool textureAllocated;

  /// Always `false` in this slice: no product UI is wired to these routes.
  final bool productUiWired;

  /// Structured reason codes explaining the verdict.
  final List<String> reasons;

  /// Additional diagnostics capturing route evaluation state.
  final Map<String, Object?> diagnostics;

  /// Serializes this smoke report to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'proofBoundary': proofBoundary,
      'directMeasureCostInvalidArgOk': directMeasureCostInvalidArgOk,
      'directMeasureCostFailClosedOk': directMeasureCostFailClosedOk,
      'directMeasureCostErrorCode': directMeasureCostErrorCode,
      'directStreamingDiagnosticInvalidArgOk':
          directStreamingDiagnosticInvalidArgOk,
      'directStreamingDiagnosticFailClosedOk':
          directStreamingDiagnosticFailClosedOk,
      'directStreamingDiagnosticErrorCode': directStreamingDiagnosticErrorCode,
      'directSyncDiagnosticInvalidArgOk': directSyncDiagnosticInvalidArgOk,
      'directSyncDiagnosticFailClosedOk': directSyncDiagnosticFailClosedOk,
      'directSyncDiagnosticErrorCode': directSyncDiagnosticErrorCode,
      'directSourceLifecycleDiagnosticInvalidArgOk':
          directSourceLifecycleDiagnosticInvalidArgOk,
      'directSourceLifecycleDiagnosticFailClosedOk':
          directSourceLifecycleDiagnosticFailClosedOk,
      'directSourceLifecycleDiagnosticErrorCode':
          directSourceLifecycleDiagnosticErrorCode,
      'publicMeasureCostNullOk': publicMeasureCostNullOk,
      'publicStreamingDiagnosticNullOk': publicStreamingDiagnosticNullOk,
      'publicSyncDiagnosticNullOk': publicSyncDiagnosticNullOk,
      'publicSourceLifecycleDiagnosticNullOk':
          publicSourceLifecycleDiagnosticNullOk,
      'physicalConcurrentCaptureProven': physicalConcurrentCaptureProven,
      'hardwareCostMeasured': hardwareCostMeasured,
      'streamingFramesProven': streamingFramesProven,
      'syncProven': syncProven,
      'sourceLifecycleProven': sourceLifecycleProven,
      'cameraOpenedByDiagnosticRoute': cameraOpenedByDiagnosticRoute,
      'textureAllocated': textureAllocated,
      'productUiWired': productUiWired,
      'reasons': reasons,
      'diagnostics': diagnostics,
    };
  }

  /// Deserializes a smoke report from a raw map, returning `null` if invalid.
  static VGAndroidMultiCamDiagnosticFailClosedSmokeReport? fromMap(
    Object? raw,
  ) {
    if (raw is! Map) return null;
    final reasonsRaw = raw['reasons'];
    final reasons = reasonsRaw is List
        ? reasonsRaw
              .whereType<Object>()
              .map((e) => e.toString())
              .toList(growable: false)
        : const <String>[];

    final diagMapRaw = raw['diagnostics'];
    final diagnostics = diagMapRaw is Map
        ? Map<String, Object?>.from(diagMapRaw)
        : const <String, Object?>{};

    return VGAndroidMultiCamDiagnosticFailClosedSmokeReport(
      pass: raw['pass'] as bool? ?? false,
      proofBoundary: raw['proofBoundary'] as String? ?? '',
      directMeasureCostInvalidArgOk:
          raw['directMeasureCostInvalidArgOk'] as bool? ?? false,
      directMeasureCostFailClosedOk:
          raw['directMeasureCostFailClosedOk'] as bool? ?? false,
      directMeasureCostErrorCode: raw['directMeasureCostErrorCode'] as String?,
      directStreamingDiagnosticInvalidArgOk:
          raw['directStreamingDiagnosticInvalidArgOk'] as bool? ?? false,
      directStreamingDiagnosticFailClosedOk:
          raw['directStreamingDiagnosticFailClosedOk'] as bool? ?? false,
      directStreamingDiagnosticErrorCode:
          raw['directStreamingDiagnosticErrorCode'] as String?,
      directSyncDiagnosticInvalidArgOk:
          raw['directSyncDiagnosticInvalidArgOk'] as bool? ?? false,
      directSyncDiagnosticFailClosedOk:
          raw['directSyncDiagnosticFailClosedOk'] as bool? ?? false,
      directSyncDiagnosticErrorCode:
          raw['directSyncDiagnosticErrorCode'] as String?,
      directSourceLifecycleDiagnosticInvalidArgOk:
          raw['directSourceLifecycleDiagnosticInvalidArgOk'] as bool? ?? false,
      directSourceLifecycleDiagnosticFailClosedOk:
          raw['directSourceLifecycleDiagnosticFailClosedOk'] as bool? ?? false,
      directSourceLifecycleDiagnosticErrorCode:
          raw['directSourceLifecycleDiagnosticErrorCode'] as String?,
      publicMeasureCostNullOk: raw['publicMeasureCostNullOk'] as bool? ?? false,
      publicStreamingDiagnosticNullOk:
          raw['publicStreamingDiagnosticNullOk'] as bool? ?? false,
      publicSyncDiagnosticNullOk:
          raw['publicSyncDiagnosticNullOk'] as bool? ?? false,
      publicSourceLifecycleDiagnosticNullOk:
          raw['publicSourceLifecycleDiagnosticNullOk'] as bool? ?? false,
      physicalConcurrentCaptureProven:
          raw['physicalConcurrentCaptureProven'] as bool? ?? false,
      hardwareCostMeasured: raw['hardwareCostMeasured'] as bool? ?? false,
      streamingFramesProven: raw['streamingFramesProven'] as bool? ?? false,
      syncProven: raw['syncProven'] as bool? ?? false,
      sourceLifecycleProven: raw['sourceLifecycleProven'] as bool? ?? false,
      cameraOpenedByDiagnosticRoute:
          raw['cameraOpenedByDiagnosticRoute'] as bool? ?? false,
      textureAllocated: raw['textureAllocated'] as bool? ?? false,
      productUiWired: raw['productUiWired'] as bool? ?? false,
      reasons: reasons,
      diagnostics: diagnostics,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAndroidMultiCamDiagnosticFailClosedSmokeReport &&
        other.pass == pass &&
        other.proofBoundary == proofBoundary &&
        other.directMeasureCostInvalidArgOk == directMeasureCostInvalidArgOk &&
        other.directMeasureCostFailClosedOk == directMeasureCostFailClosedOk &&
        other.directMeasureCostErrorCode == directMeasureCostErrorCode &&
        other.directStreamingDiagnosticInvalidArgOk ==
            directStreamingDiagnosticInvalidArgOk &&
        other.directStreamingDiagnosticFailClosedOk ==
            directStreamingDiagnosticFailClosedOk &&
        other.directStreamingDiagnosticErrorCode ==
            directStreamingDiagnosticErrorCode &&
        other.directSyncDiagnosticInvalidArgOk ==
            directSyncDiagnosticInvalidArgOk &&
        other.directSyncDiagnosticFailClosedOk ==
            directSyncDiagnosticFailClosedOk &&
        other.directSyncDiagnosticErrorCode == directSyncDiagnosticErrorCode &&
        other.directSourceLifecycleDiagnosticInvalidArgOk ==
            directSourceLifecycleDiagnosticInvalidArgOk &&
        other.directSourceLifecycleDiagnosticFailClosedOk ==
            directSourceLifecycleDiagnosticFailClosedOk &&
        other.directSourceLifecycleDiagnosticErrorCode ==
            directSourceLifecycleDiagnosticErrorCode &&
        other.publicMeasureCostNullOk == publicMeasureCostNullOk &&
        other.publicStreamingDiagnosticNullOk ==
            publicStreamingDiagnosticNullOk &&
        other.publicSyncDiagnosticNullOk == publicSyncDiagnosticNullOk &&
        other.publicSourceLifecycleDiagnosticNullOk ==
            publicSourceLifecycleDiagnosticNullOk &&
        other.physicalConcurrentCaptureProven ==
            physicalConcurrentCaptureProven &&
        other.hardwareCostMeasured == hardwareCostMeasured &&
        other.streamingFramesProven == streamingFramesProven &&
        other.syncProven == syncProven &&
        other.sourceLifecycleProven == sourceLifecycleProven &&
        other.cameraOpenedByDiagnosticRoute == cameraOpenedByDiagnosticRoute &&
        other.textureAllocated == textureAllocated &&
        other.productUiWired == productUiWired &&
        listEquals(other.reasons, reasons) &&
        mapEquals(other.diagnostics, diagnostics);
  }

  @override
  int get hashCode => Object.hash(
    pass,
    proofBoundary,
    Object.hash(
      directMeasureCostInvalidArgOk,
      directMeasureCostFailClosedOk,
      directMeasureCostErrorCode,
      directStreamingDiagnosticInvalidArgOk,
      directStreamingDiagnosticFailClosedOk,
    ),
    Object.hash(
      directStreamingDiagnosticErrorCode,
      directSyncDiagnosticInvalidArgOk,
      directSyncDiagnosticFailClosedOk,
      directSyncDiagnosticErrorCode,
      directSourceLifecycleDiagnosticInvalidArgOk,
    ),
    Object.hash(
      directSourceLifecycleDiagnosticFailClosedOk,
      directSourceLifecycleDiagnosticErrorCode,
      publicMeasureCostNullOk,
      publicStreamingDiagnosticNullOk,
      publicSyncDiagnosticNullOk,
    ),
    Object.hash(
      publicSourceLifecycleDiagnosticNullOk,
      physicalConcurrentCaptureProven,
      hardwareCostMeasured,
      streamingFramesProven,
      syncProven,
    ),
    Object.hash(
      sourceLifecycleProven,
      cameraOpenedByDiagnosticRoute,
      textureAllocated,
      productUiWired,
      Object.hashAll(reasons),
    ),
    _stableMapHash(diagnostics),
  );

  static int _stableMapHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGAndroidMultiCamDiagnosticFailClosedSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'directMeasureCostErrorCode: $directMeasureCostErrorCode, '
      'directStreamingDiagnosticErrorCode: $directStreamingDiagnosticErrorCode, '
      'directSyncDiagnosticErrorCode: $directSyncDiagnosticErrorCode, '
      'directSourceLifecycleDiagnosticErrorCode: $directSourceLifecycleDiagnosticErrorCode, '
      'reasons: $reasons)';
}

/// Runner that executes Android MultiCam legacy diagnostic routes
/// fail-closed verification.
class VGAndroidMultiCamDiagnosticFailClosedSmokeRunner {
  const VGAndroidMultiCamDiagnosticFailClosedSmokeRunner({
    this.frontDeviceId = '0',
    this.backDeviceId = '1',
  });

  /// Non-blank front-camera device id used for the "valid args" direct-route
  /// and public-API checks.
  final String frontDeviceId;

  /// Non-blank back-camera device id used for the "valid args" direct-route
  /// and public-API checks.
  final String backDeviceId;

  /// Executes the fail-closed route smoke verification.
  Future<VGAndroidMultiCamDiagnosticFailClosedSmokeReport> runSmoke({
    MethodChannel? channel,
  }) async {
    final effectiveChannel =
        channel ?? const MethodChannel('vanguard_media_engine');

    try {
      final reasons = <String>[];

      // 1. measureMultiCamHardwareCost with missing ids -> INVALID_ARG.
      String? measureCostInvalidArgCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'measureMultiCamHardwareCost',
          <String, Object?>{},
        );
      } on PlatformException catch (e) {
        measureCostInvalidArgCode = e.code;
      }
      final directMeasureCostInvalidArgOk =
          measureCostInvalidArgCode == 'INVALID_ARG';
      if (!directMeasureCostInvalidArgOk) {
        reasons.add(
          'direct_measure_cost_invalid_arg_not_rejected: code=$measureCostInvalidArgCode',
        );
      }

      // 2. measureMultiCamHardwareCost with valid ids -> fails closed.
      String? measureCostErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'measureMultiCamHardwareCost',
          <String, Object?>{
            'frontDeviceId': frontDeviceId,
            'backDeviceId': backDeviceId,
          },
        );
      } on PlatformException catch (e) {
        measureCostErrorCode = e.code;
      }
      final directMeasureCostFailClosedOk =
          measureCostErrorCode != null &&
          kAndroidMultiCamDiagnosticFailClosedAllowedErrorCodes.contains(
            measureCostErrorCode,
          );
      if (!directMeasureCostFailClosedOk) {
        reasons.add(
          'direct_measure_cost_did_not_fail_closed: code=$measureCostErrorCode',
        );
      }

      // 3. runMultiCamStreamingDiagnostic with missing ids -> INVALID_ARG.
      String? streamingInvalidArgCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'runMultiCamStreamingDiagnostic',
          <String, Object?>{},
        );
      } on PlatformException catch (e) {
        streamingInvalidArgCode = e.code;
      }
      final directStreamingDiagnosticInvalidArgOk =
          streamingInvalidArgCode == 'INVALID_ARG';
      if (!directStreamingDiagnosticInvalidArgOk) {
        reasons.add(
          'direct_streaming_diagnostic_invalid_arg_not_rejected: code=$streamingInvalidArgCode',
        );
      }

      // 4. runMultiCamStreamingDiagnostic with valid ids -> fails closed.
      String? streamingErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'runMultiCamStreamingDiagnostic',
          <String, Object?>{
            'frontDeviceId': frontDeviceId,
            'backDeviceId': backDeviceId,
          },
        );
      } on PlatformException catch (e) {
        streamingErrorCode = e.code;
      }
      final directStreamingDiagnosticFailClosedOk =
          streamingErrorCode != null &&
          kAndroidMultiCamDiagnosticFailClosedAllowedErrorCodes.contains(
            streamingErrorCode,
          );
      if (!directStreamingDiagnosticFailClosedOk) {
        reasons.add(
          'direct_streaming_diagnostic_did_not_fail_closed: code=$streamingErrorCode',
        );
      }

      // 5. runMultiCamSyncDiagnostic with missing ids -> INVALID_ARG.
      String? syncInvalidArgCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'runMultiCamSyncDiagnostic',
          <String, Object?>{},
        );
      } on PlatformException catch (e) {
        syncInvalidArgCode = e.code;
      }
      final directSyncDiagnosticInvalidArgOk =
          syncInvalidArgCode == 'INVALID_ARG';
      if (!directSyncDiagnosticInvalidArgOk) {
        reasons.add(
          'direct_sync_diagnostic_invalid_arg_not_rejected: code=$syncInvalidArgCode',
        );
      }

      // 6. runMultiCamSyncDiagnostic with valid ids -> fails closed.
      String? syncErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'runMultiCamSyncDiagnostic',
          <String, Object?>{
            'frontDeviceId': frontDeviceId,
            'backDeviceId': backDeviceId,
          },
        );
      } on PlatformException catch (e) {
        syncErrorCode = e.code;
      }
      final directSyncDiagnosticFailClosedOk =
          syncErrorCode != null &&
          kAndroidMultiCamDiagnosticFailClosedAllowedErrorCodes.contains(
            syncErrorCode,
          );
      if (!directSyncDiagnosticFailClosedOk) {
        reasons.add(
          'direct_sync_diagnostic_did_not_fail_closed: code=$syncErrorCode',
        );
      }

      // 7. runMultiCamSourceLifecycleDiagnostic with missing ids ->
      // INVALID_ARG.
      String? sourceLifecycleInvalidArgCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'runMultiCamSourceLifecycleDiagnostic',
          <String, Object?>{},
        );
      } on PlatformException catch (e) {
        sourceLifecycleInvalidArgCode = e.code;
      }
      final directSourceLifecycleDiagnosticInvalidArgOk =
          sourceLifecycleInvalidArgCode == 'INVALID_ARG';
      if (!directSourceLifecycleDiagnosticInvalidArgOk) {
        reasons.add(
          'direct_source_lifecycle_diagnostic_invalid_arg_not_rejected: code=$sourceLifecycleInvalidArgCode',
        );
      }

      // 8. runMultiCamSourceLifecycleDiagnostic with valid ids -> fails
      // closed.
      String? sourceLifecycleErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'runMultiCamSourceLifecycleDiagnostic',
          <String, Object?>{
            'frontDeviceId': frontDeviceId,
            'backDeviceId': backDeviceId,
          },
        );
      } on PlatformException catch (e) {
        sourceLifecycleErrorCode = e.code;
      }
      final directSourceLifecycleDiagnosticFailClosedOk =
          sourceLifecycleErrorCode != null &&
          kAndroidMultiCamDiagnosticFailClosedAllowedErrorCodes.contains(
            sourceLifecycleErrorCode,
          );
      if (!directSourceLifecycleDiagnosticFailClosedOk) {
        reasons.add(
          'direct_source_lifecycle_diagnostic_did_not_fail_closed: code=$sourceLifecycleErrorCode',
        );
      }

      // 9-12. Public VGCameraSession wrappers -- their documented contracts
      // return null on PlatformException or malformed/null native response.
      final publicMeasureCostResult =
          await VGCameraSession.measureMultiCamHardwareCost(
            frontDeviceId: frontDeviceId,
            backDeviceId: backDeviceId,
          );
      final publicMeasureCostNullOk = publicMeasureCostResult == null;
      if (!publicMeasureCostNullOk) {
        reasons.add('public_measure_cost_did_not_return_null');
      }

      final publicStreamingDiagnosticResult =
          await VGCameraSession.runMultiCamStreamingDiagnostic(
            frontDeviceId: frontDeviceId,
            backDeviceId: backDeviceId,
          );
      final publicStreamingDiagnosticNullOk =
          publicStreamingDiagnosticResult == null;
      if (!publicStreamingDiagnosticNullOk) {
        reasons.add('public_streaming_diagnostic_did_not_return_null');
      }

      final publicSyncDiagnosticResult =
          await VGCameraSession.runMultiCamSyncDiagnostic(
            frontDeviceId: frontDeviceId,
            backDeviceId: backDeviceId,
          );
      final publicSyncDiagnosticNullOk = publicSyncDiagnosticResult == null;
      if (!publicSyncDiagnosticNullOk) {
        reasons.add('public_sync_diagnostic_did_not_return_null');
      }

      final publicSourceLifecycleDiagnosticResult =
          await VGCameraSession.runMultiCamSourceLifecycleDiagnostic(
            frontDeviceId: frontDeviceId,
            backDeviceId: backDeviceId,
          );
      final publicSourceLifecycleDiagnosticNullOk =
          publicSourceLifecycleDiagnosticResult == null;
      if (!publicSourceLifecycleDiagnosticNullOk) {
        reasons.add('public_source_lifecycle_diagnostic_did_not_return_null');
      }

      final pass =
          directMeasureCostInvalidArgOk &&
          directMeasureCostFailClosedOk &&
          directStreamingDiagnosticInvalidArgOk &&
          directStreamingDiagnosticFailClosedOk &&
          directSyncDiagnosticInvalidArgOk &&
          directSyncDiagnosticFailClosedOk &&
          directSourceLifecycleDiagnosticInvalidArgOk &&
          directSourceLifecycleDiagnosticFailClosedOk &&
          publicMeasureCostNullOk &&
          publicStreamingDiagnosticNullOk &&
          publicSyncDiagnosticNullOk &&
          publicSourceLifecycleDiagnosticNullOk;

      if (pass) {
        reasons.add('multicam_diagnostic_fail_closed_routes_consistent_pass');
      }

      final diagnostics = <String, Object?>{
        'proofBoundary': kAndroidMultiCamDiagnosticFailClosedProofBoundary,
        'frontDeviceId': frontDeviceId,
        'backDeviceId': backDeviceId,
        'directMeasureCostErrorCode': measureCostErrorCode,
        'directStreamingDiagnosticErrorCode': streamingErrorCode,
        'directSyncDiagnosticErrorCode': syncErrorCode,
        'directSourceLifecycleDiagnosticErrorCode': sourceLifecycleErrorCode,
      };

      return VGAndroidMultiCamDiagnosticFailClosedSmokeReport(
        pass: pass,
        proofBoundary: kAndroidMultiCamDiagnosticFailClosedProofBoundary,
        directMeasureCostInvalidArgOk: directMeasureCostInvalidArgOk,
        directMeasureCostFailClosedOk: directMeasureCostFailClosedOk,
        directMeasureCostErrorCode: measureCostErrorCode,
        directStreamingDiagnosticInvalidArgOk:
            directStreamingDiagnosticInvalidArgOk,
        directStreamingDiagnosticFailClosedOk:
            directStreamingDiagnosticFailClosedOk,
        directStreamingDiagnosticErrorCode: streamingErrorCode,
        directSyncDiagnosticInvalidArgOk: directSyncDiagnosticInvalidArgOk,
        directSyncDiagnosticFailClosedOk: directSyncDiagnosticFailClosedOk,
        directSyncDiagnosticErrorCode: syncErrorCode,
        directSourceLifecycleDiagnosticInvalidArgOk:
            directSourceLifecycleDiagnosticInvalidArgOk,
        directSourceLifecycleDiagnosticFailClosedOk:
            directSourceLifecycleDiagnosticFailClosedOk,
        directSourceLifecycleDiagnosticErrorCode: sourceLifecycleErrorCode,
        publicMeasureCostNullOk: publicMeasureCostNullOk,
        publicStreamingDiagnosticNullOk: publicStreamingDiagnosticNullOk,
        publicSyncDiagnosticNullOk: publicSyncDiagnosticNullOk,
        publicSourceLifecycleDiagnosticNullOk:
            publicSourceLifecycleDiagnosticNullOk,
        physicalConcurrentCaptureProven: false,
        hardwareCostMeasured: false,
        streamingFramesProven: false,
        syncProven: false,
        sourceLifecycleProven: false,
        cameraOpenedByDiagnosticRoute: false,
        textureAllocated: false,
        productUiWired: false,
        reasons: reasons,
        diagnostics: diagnostics,
      );
    } catch (e, st) {
      return VGAndroidMultiCamDiagnosticFailClosedSmokeReport(
        pass: false,
        proofBoundary: kAndroidMultiCamDiagnosticFailClosedProofBoundary,
        directMeasureCostInvalidArgOk: false,
        directMeasureCostFailClosedOk: false,
        directMeasureCostErrorCode: null,
        directStreamingDiagnosticInvalidArgOk: false,
        directStreamingDiagnosticFailClosedOk: false,
        directStreamingDiagnosticErrorCode: null,
        directSyncDiagnosticInvalidArgOk: false,
        directSyncDiagnosticFailClosedOk: false,
        directSyncDiagnosticErrorCode: null,
        directSourceLifecycleDiagnosticInvalidArgOk: false,
        directSourceLifecycleDiagnosticFailClosedOk: false,
        directSourceLifecycleDiagnosticErrorCode: null,
        publicMeasureCostNullOk: false,
        publicStreamingDiagnosticNullOk: false,
        publicSyncDiagnosticNullOk: false,
        publicSourceLifecycleDiagnosticNullOk: false,
        physicalConcurrentCaptureProven: false,
        hardwareCostMeasured: false,
        streamingFramesProven: false,
        syncProven: false,
        sourceLifecycleProven: false,
        cameraOpenedByDiagnosticRoute: false,
        textureAllocated: false,
        productUiWired: false,
        reasons: <String>['exception_during_smoke_run: $e'],
        diagnostics: <String, Object?>{
          'proofBoundary': kAndroidMultiCamDiagnosticFailClosedProofBoundary,
          'error': '$e\n$st',
        },
      );
    }
  }

  /// Convenience static runner method.
  static Future<VGAndroidMultiCamDiagnosticFailClosedSmokeReport> run({
    MethodChannel? channel,
    VGAndroidMultiCamDiagnosticFailClosedSmokeRunner? runner,
  }) {
    final activeRunner =
        runner ?? const VGAndroidMultiCamDiagnosticFailClosedSmokeRunner();
    return activeRunner.runSmoke(channel: channel);
  }
}
