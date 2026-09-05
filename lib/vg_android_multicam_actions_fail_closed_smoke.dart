// vg_android_multicam_actions_fail_closed_smoke.dart
// vanguard_media_engine - P3-CAM-CONCURRENT-MULTICAM-ACTIONS-FAIL-CLOSED-ANDROID-HANDLER:
// Android MultiCam preview/action routes (render diagnostic, config update,
// photo, recording) fail-closed route smoke foundation.
//
// Pure Dart typed report and runner proving the remaining Android MultiCam
// public routes -- runMultiCamRenderDiagnostic, startMultiCamRenderDiagnostic,
// stopMultiCamRenderDiagnostic, updateMultiCamPreviewConfig, takeMultiCamPhoto,
// startMultiCamRecording, stopMultiCamRecording -- fail closed: invalid args
// reject before any capability lookup or state check, hardware without a
// matching concurrent combo (or without a production concurrent-preview
// lifecycle owner) rejects the render-diagnostic start routes before any
// camera is opened or texture allocated, the stop routes are idempotent
// no-ops, and the config/photo/recording routes reject with NOT_RUNNING
// because there is never a running Android MultiCam preview session in this
// slice. This slice does NOT prove real concurrent camera capture, render,
// photo capture, or recording/export -- see the non-claim booleans below.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_camera_session.dart';
import 'vg_live_preview_config.dart';

/// Proof boundary identifier for the Android MultiCam actions fail-closed
/// route smoke.
const String kAndroidMultiCamActionsFailClosedProofBoundary =
    'android_multicam_actions_fail_closed_route_handling_capability_gated_no_camera_open_no_texture_no_capture';

/// Physical smoke START marker token.
const String kAndroidMultiCamActionsFailClosedStartMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_ACTIONS_FAIL_CLOSED_PHYSICAL_SMOKE_START';

/// Physical smoke PASS marker token.
const String kAndroidMultiCamActionsFailClosedPassMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_ACTIONS_FAIL_CLOSED_PHYSICAL_SMOKE_PASS';

/// Physical smoke FAIL marker token.
const String kAndroidMultiCamActionsFailClosedFailMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_ACTIONS_FAIL_CLOSED_PHYSICAL_SMOKE_FAIL';

/// JSON payload log prefix.
const String kAndroidMultiCamActionsFailClosedJsonPrefix =
    'ANDROID_DAG_PHASE3_MULTICAM_ACTIONS_FAIL_CLOSED_JSON:';

/// Error codes the direct `runMultiCamRenderDiagnostic` /
/// `startMultiCamRenderDiagnostic` routes are allowed to return for a valid
/// (non-blank) device-id pair on hardware with no production
/// concurrent-preview lifecycle owner.
const List<String>
kAndroidMultiCamActionsFailClosedAllowedDiagnosticErrorCodes = <String>[
  'CONCURRENT_NOT_SUPPORTED',
  'CONCURRENT_PREVIEW_NOT_READY',
];

/// Immutable typed smoke report produced by
/// [VGAndroidMultiCamActionsFailClosedSmokeRunner].
@immutable
class VGAndroidMultiCamActionsFailClosedSmokeReport {
  const VGAndroidMultiCamActionsFailClosedSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.directStopPreviewIdempotentOk,
    required this.directStopRenderDiagnosticIdempotentOk,
    required this.directRunDiagnosticInvalidArgOk,
    required this.directStartDiagnosticInvalidArgOk,
    required this.directRunDiagnosticFailClosedOk,
    required this.directRunDiagnosticErrorCode,
    required this.directStartDiagnosticFailClosedOk,
    required this.directStartDiagnosticErrorCode,
    required this.directUpdateConfigMissingInvalidArgOk,
    required this.directUpdateConfigWithConfigNotRunningOk,
    required this.directTakePhotoMissingInvalidArgOk,
    required this.directTakePhotoValidPathNotRunningOk,
    required this.directStartRecordingMissingInvalidArgOk,
    required this.directStartRecordingValidPathNotRunningOk,
    required this.directStopRecordingNotRunningOk,
    required this.publicRunDiagnosticNullOk,
    required this.publicStartDiagnosticNullOk,
    required this.publicStopDiagnosticNullOk,
    required this.publicTakePhotoNullOk,
    required this.publicStartRecordingFalseOk,
    required this.publicStopRecordingNullOk,
    required this.publicUpdateConfigNoThrowOk,
    required this.physicalConcurrentCaptureProven,
    required this.textureAllocated,
    required this.cameraOpenedByMultiCamRoute,
    required this.renderProven,
    required this.photoCaptureProven,
    required this.recordingExportProven,
    required this.productUiWired,
    required this.reasons,
    required this.diagnostics,
  });

  /// Whether all verification lanes passed.
  final bool pass;

  /// Exact proof boundary token.
  final String proofBoundary;

  /// Whether a direct `stopMultiCamPreview` call with no active session
  /// completes without throwing (idempotent no-op success).
  final bool directStopPreviewIdempotentOk;

  /// Whether a direct `stopMultiCamRenderDiagnostic` call with no active
  /// session completes without throwing (idempotent no-op success).
  final bool directStopRenderDiagnosticIdempotentOk;

  /// Whether a direct `runMultiCamRenderDiagnostic` call with missing/blank
  /// device ids fails with `PlatformException` code `INVALID_ARG`.
  final bool directRunDiagnosticInvalidArgOk;

  /// Whether a direct `startMultiCamRenderDiagnostic` call with
  /// missing/blank device ids fails with `PlatformException` code
  /// `INVALID_ARG`.
  final bool directStartDiagnosticInvalidArgOk;

  /// Whether a direct `runMultiCamRenderDiagnostic` call with valid
  /// non-blank device ids fails closed with `CONCURRENT_NOT_SUPPORTED` or
  /// `CONCURRENT_PREVIEW_NOT_READY` (never a fake success).
  final bool directRunDiagnosticFailClosedOk;

  /// The raw `PlatformException.code` observed for the valid-device-id
  /// direct `runMultiCamRenderDiagnostic` call, or `null` if none was
  /// thrown.
  final String? directRunDiagnosticErrorCode;

  /// Whether a direct `startMultiCamRenderDiagnostic` call with valid
  /// non-blank device ids fails closed with `CONCURRENT_NOT_SUPPORTED` or
  /// `CONCURRENT_PREVIEW_NOT_READY` (never a fake success).
  final bool directStartDiagnosticFailClosedOk;

  /// The raw `PlatformException.code` observed for the valid-device-id
  /// direct `startMultiCamRenderDiagnostic` call, or `null` if none was
  /// thrown.
  final String? directStartDiagnosticErrorCode;

  /// Whether a direct `updateMultiCamPreviewConfig` call with no `config`
  /// map fails with `PlatformException` code `INVALID_ARG`.
  final bool directUpdateConfigMissingInvalidArgOk;

  /// Whether a direct `updateMultiCamPreviewConfig` call with a `config`
  /// map fails with `PlatformException` code `NOT_RUNNING`.
  final bool directUpdateConfigWithConfigNotRunningOk;

  /// Whether a direct `takeMultiCamPhoto` call with a missing/blank `path`
  /// fails with `PlatformException` code `INVALID_ARG`.
  final bool directTakePhotoMissingInvalidArgOk;

  /// Whether a direct `takeMultiCamPhoto` call with a valid non-blank
  /// `path` fails with `PlatformException` code `NOT_RUNNING`.
  final bool directTakePhotoValidPathNotRunningOk;

  /// Whether a direct `startMultiCamRecording` call with a missing/blank
  /// `path` fails with `PlatformException` code `INVALID_ARG`.
  final bool directStartRecordingMissingInvalidArgOk;

  /// Whether a direct `startMultiCamRecording` call with a valid non-blank
  /// `path` fails with `PlatformException` code `NOT_RUNNING`.
  final bool directStartRecordingValidPathNotRunningOk;

  /// Whether a direct `stopMultiCamRecording` call fails with
  /// `PlatformException` code `NOT_RUNNING`.
  final bool directStopRecordingNotRunningOk;

  /// Whether the public `VGCameraSession.runMultiCamRenderDiagnostic`
  /// returns `null`.
  final bool publicRunDiagnosticNullOk;

  /// Whether the public `VGCameraSession.startMultiCamRenderDiagnostic`
  /// returns `null`.
  final bool publicStartDiagnosticNullOk;

  /// Whether the public `VGCameraSession.stopMultiCamRenderDiagnostic`
  /// returns `null`.
  final bool publicStopDiagnosticNullOk;

  /// Whether the public `VGCameraSession.takeMultiCamPhoto` returns `null`.
  final bool publicTakePhotoNullOk;

  /// Whether the public `VGCameraSession.startMultiCamRecording` returns
  /// `false`.
  final bool publicStartRecordingFalseOk;

  /// Whether the public `VGCameraSession.stopMultiCamRecording` returns
  /// `null`.
  final bool publicStopRecordingNullOk;

  /// Whether the public `VGCameraSession.updateMultiCamPreviewConfig`
  /// completes without throwing (its documented silent-failure contract).
  final bool publicUpdateConfigNoThrowOk;

  /// Always `false` in this slice: no real concurrent camera capture is
  /// implemented or proven.
  final bool physicalConcurrentCaptureProven;

  /// Always `false` in this slice: no route allocates a
  /// TextureRegistry/SurfaceTexture.
  final bool textureAllocated;

  /// Always `false` in this slice: no route opens a camera.
  final bool cameraOpenedByMultiCamRoute;

  /// Always `false` in this slice: no frame is ever rendered.
  final bool renderProven;

  /// Always `false` in this slice: no photo is ever captured.
  final bool photoCaptureProven;

  /// Always `false` in this slice: no recording/export is exercised.
  final bool recordingExportProven;

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
      'directStopPreviewIdempotentOk': directStopPreviewIdempotentOk,
      'directStopRenderDiagnosticIdempotentOk':
          directStopRenderDiagnosticIdempotentOk,
      'directRunDiagnosticInvalidArgOk': directRunDiagnosticInvalidArgOk,
      'directStartDiagnosticInvalidArgOk': directStartDiagnosticInvalidArgOk,
      'directRunDiagnosticFailClosedOk': directRunDiagnosticFailClosedOk,
      'directRunDiagnosticErrorCode': directRunDiagnosticErrorCode,
      'directStartDiagnosticFailClosedOk': directStartDiagnosticFailClosedOk,
      'directStartDiagnosticErrorCode': directStartDiagnosticErrorCode,
      'directUpdateConfigMissingInvalidArgOk':
          directUpdateConfigMissingInvalidArgOk,
      'directUpdateConfigWithConfigNotRunningOk':
          directUpdateConfigWithConfigNotRunningOk,
      'directTakePhotoMissingInvalidArgOk': directTakePhotoMissingInvalidArgOk,
      'directTakePhotoValidPathNotRunningOk':
          directTakePhotoValidPathNotRunningOk,
      'directStartRecordingMissingInvalidArgOk':
          directStartRecordingMissingInvalidArgOk,
      'directStartRecordingValidPathNotRunningOk':
          directStartRecordingValidPathNotRunningOk,
      'directStopRecordingNotRunningOk': directStopRecordingNotRunningOk,
      'publicRunDiagnosticNullOk': publicRunDiagnosticNullOk,
      'publicStartDiagnosticNullOk': publicStartDiagnosticNullOk,
      'publicStopDiagnosticNullOk': publicStopDiagnosticNullOk,
      'publicTakePhotoNullOk': publicTakePhotoNullOk,
      'publicStartRecordingFalseOk': publicStartRecordingFalseOk,
      'publicStopRecordingNullOk': publicStopRecordingNullOk,
      'publicUpdateConfigNoThrowOk': publicUpdateConfigNoThrowOk,
      'physicalConcurrentCaptureProven': physicalConcurrentCaptureProven,
      'textureAllocated': textureAllocated,
      'cameraOpenedByMultiCamRoute': cameraOpenedByMultiCamRoute,
      'renderProven': renderProven,
      'photoCaptureProven': photoCaptureProven,
      'recordingExportProven': recordingExportProven,
      'productUiWired': productUiWired,
      'reasons': reasons,
      'diagnostics': diagnostics,
    };
  }

  /// Deserializes a smoke report from a raw map, returning `null` if invalid.
  static VGAndroidMultiCamActionsFailClosedSmokeReport? fromMap(Object? raw) {
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

    return VGAndroidMultiCamActionsFailClosedSmokeReport(
      pass: raw['pass'] as bool? ?? false,
      proofBoundary: raw['proofBoundary'] as String? ?? '',
      directStopPreviewIdempotentOk:
          raw['directStopPreviewIdempotentOk'] as bool? ?? false,
      directStopRenderDiagnosticIdempotentOk:
          raw['directStopRenderDiagnosticIdempotentOk'] as bool? ?? false,
      directRunDiagnosticInvalidArgOk:
          raw['directRunDiagnosticInvalidArgOk'] as bool? ?? false,
      directStartDiagnosticInvalidArgOk:
          raw['directStartDiagnosticInvalidArgOk'] as bool? ?? false,
      directRunDiagnosticFailClosedOk:
          raw['directRunDiagnosticFailClosedOk'] as bool? ?? false,
      directRunDiagnosticErrorCode:
          raw['directRunDiagnosticErrorCode'] as String?,
      directStartDiagnosticFailClosedOk:
          raw['directStartDiagnosticFailClosedOk'] as bool? ?? false,
      directStartDiagnosticErrorCode:
          raw['directStartDiagnosticErrorCode'] as String?,
      directUpdateConfigMissingInvalidArgOk:
          raw['directUpdateConfigMissingInvalidArgOk'] as bool? ?? false,
      directUpdateConfigWithConfigNotRunningOk:
          raw['directUpdateConfigWithConfigNotRunningOk'] as bool? ?? false,
      directTakePhotoMissingInvalidArgOk:
          raw['directTakePhotoMissingInvalidArgOk'] as bool? ?? false,
      directTakePhotoValidPathNotRunningOk:
          raw['directTakePhotoValidPathNotRunningOk'] as bool? ?? false,
      directStartRecordingMissingInvalidArgOk:
          raw['directStartRecordingMissingInvalidArgOk'] as bool? ?? false,
      directStartRecordingValidPathNotRunningOk:
          raw['directStartRecordingValidPathNotRunningOk'] as bool? ?? false,
      directStopRecordingNotRunningOk:
          raw['directStopRecordingNotRunningOk'] as bool? ?? false,
      publicRunDiagnosticNullOk:
          raw['publicRunDiagnosticNullOk'] as bool? ?? false,
      publicStartDiagnosticNullOk:
          raw['publicStartDiagnosticNullOk'] as bool? ?? false,
      publicStopDiagnosticNullOk:
          raw['publicStopDiagnosticNullOk'] as bool? ?? false,
      publicTakePhotoNullOk: raw['publicTakePhotoNullOk'] as bool? ?? false,
      publicStartRecordingFalseOk:
          raw['publicStartRecordingFalseOk'] as bool? ?? false,
      publicStopRecordingNullOk:
          raw['publicStopRecordingNullOk'] as bool? ?? false,
      publicUpdateConfigNoThrowOk:
          raw['publicUpdateConfigNoThrowOk'] as bool? ?? false,
      physicalConcurrentCaptureProven:
          raw['physicalConcurrentCaptureProven'] as bool? ?? false,
      textureAllocated: raw['textureAllocated'] as bool? ?? false,
      cameraOpenedByMultiCamRoute:
          raw['cameraOpenedByMultiCamRoute'] as bool? ?? false,
      renderProven: raw['renderProven'] as bool? ?? false,
      photoCaptureProven: raw['photoCaptureProven'] as bool? ?? false,
      recordingExportProven: raw['recordingExportProven'] as bool? ?? false,
      productUiWired: raw['productUiWired'] as bool? ?? false,
      reasons: reasons,
      diagnostics: diagnostics,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAndroidMultiCamActionsFailClosedSmokeReport &&
        other.pass == pass &&
        other.proofBoundary == proofBoundary &&
        other.directStopPreviewIdempotentOk == directStopPreviewIdempotentOk &&
        other.directStopRenderDiagnosticIdempotentOk ==
            directStopRenderDiagnosticIdempotentOk &&
        other.directRunDiagnosticInvalidArgOk ==
            directRunDiagnosticInvalidArgOk &&
        other.directStartDiagnosticInvalidArgOk ==
            directStartDiagnosticInvalidArgOk &&
        other.directRunDiagnosticFailClosedOk ==
            directRunDiagnosticFailClosedOk &&
        other.directRunDiagnosticErrorCode == directRunDiagnosticErrorCode &&
        other.directStartDiagnosticFailClosedOk ==
            directStartDiagnosticFailClosedOk &&
        other.directStartDiagnosticErrorCode ==
            directStartDiagnosticErrorCode &&
        other.directUpdateConfigMissingInvalidArgOk ==
            directUpdateConfigMissingInvalidArgOk &&
        other.directUpdateConfigWithConfigNotRunningOk ==
            directUpdateConfigWithConfigNotRunningOk &&
        other.directTakePhotoMissingInvalidArgOk ==
            directTakePhotoMissingInvalidArgOk &&
        other.directTakePhotoValidPathNotRunningOk ==
            directTakePhotoValidPathNotRunningOk &&
        other.directStartRecordingMissingInvalidArgOk ==
            directStartRecordingMissingInvalidArgOk &&
        other.directStartRecordingValidPathNotRunningOk ==
            directStartRecordingValidPathNotRunningOk &&
        other.directStopRecordingNotRunningOk ==
            directStopRecordingNotRunningOk &&
        other.publicRunDiagnosticNullOk == publicRunDiagnosticNullOk &&
        other.publicStartDiagnosticNullOk == publicStartDiagnosticNullOk &&
        other.publicStopDiagnosticNullOk == publicStopDiagnosticNullOk &&
        other.publicTakePhotoNullOk == publicTakePhotoNullOk &&
        other.publicStartRecordingFalseOk == publicStartRecordingFalseOk &&
        other.publicStopRecordingNullOk == publicStopRecordingNullOk &&
        other.publicUpdateConfigNoThrowOk == publicUpdateConfigNoThrowOk &&
        other.physicalConcurrentCaptureProven ==
            physicalConcurrentCaptureProven &&
        other.textureAllocated == textureAllocated &&
        other.cameraOpenedByMultiCamRoute == cameraOpenedByMultiCamRoute &&
        other.renderProven == renderProven &&
        other.photoCaptureProven == photoCaptureProven &&
        other.recordingExportProven == recordingExportProven &&
        other.productUiWired == productUiWired &&
        listEquals(other.reasons, reasons) &&
        mapEquals(other.diagnostics, diagnostics);
  }

  @override
  int get hashCode => Object.hash(
    pass,
    proofBoundary,
    Object.hash(
      directStopPreviewIdempotentOk,
      directStopRenderDiagnosticIdempotentOk,
      directRunDiagnosticInvalidArgOk,
      directStartDiagnosticInvalidArgOk,
      directRunDiagnosticFailClosedOk,
    ),
    Object.hash(
      directRunDiagnosticErrorCode,
      directStartDiagnosticFailClosedOk,
      directStartDiagnosticErrorCode,
      directUpdateConfigMissingInvalidArgOk,
      directUpdateConfigWithConfigNotRunningOk,
    ),
    Object.hash(
      directTakePhotoMissingInvalidArgOk,
      directTakePhotoValidPathNotRunningOk,
      directStartRecordingMissingInvalidArgOk,
      directStartRecordingValidPathNotRunningOk,
      directStopRecordingNotRunningOk,
    ),
    Object.hash(
      publicRunDiagnosticNullOk,
      publicStartDiagnosticNullOk,
      publicStopDiagnosticNullOk,
      publicTakePhotoNullOk,
      publicStartRecordingFalseOk,
    ),
    Object.hash(
      publicStopRecordingNullOk,
      publicUpdateConfigNoThrowOk,
      physicalConcurrentCaptureProven,
      textureAllocated,
      cameraOpenedByMultiCamRoute,
    ),
    Object.hash(
      renderProven,
      photoCaptureProven,
      recordingExportProven,
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
      'VGAndroidMultiCamActionsFailClosedSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'directRunDiagnosticErrorCode: $directRunDiagnosticErrorCode, '
      'directStartDiagnosticErrorCode: $directStartDiagnosticErrorCode, '
      'reasons: $reasons)';
}

/// Runner that executes Android MultiCam action-routes fail-closed
/// verification.
class VGAndroidMultiCamActionsFailClosedSmokeRunner {
  const VGAndroidMultiCamActionsFailClosedSmokeRunner({
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
  Future<VGAndroidMultiCamActionsFailClosedSmokeReport> runSmoke({
    MethodChannel? channel,
  }) async {
    final effectiveChannel =
        channel ?? const MethodChannel('vanguard_media_engine');

    try {
      final reasons = <String>[];

      // 1. stopMultiCamPreview with no active session -> idempotent success.
      String? stopPreviewErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>('stopMultiCamPreview');
      } on PlatformException catch (e) {
        stopPreviewErrorCode = e.code;
      }
      final directStopPreviewIdempotentOk = stopPreviewErrorCode == null;
      if (!directStopPreviewIdempotentOk) {
        reasons.add(
          'direct_stop_preview_not_idempotent: code=$stopPreviewErrorCode',
        );
      }

      // 2. stopMultiCamRenderDiagnostic with no active session -> idempotent
      // success.
      String? stopDiagnosticErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'stopMultiCamRenderDiagnostic',
        );
      } on PlatformException catch (e) {
        stopDiagnosticErrorCode = e.code;
      }
      final directStopRenderDiagnosticIdempotentOk =
          stopDiagnosticErrorCode == null;
      if (!directStopRenderDiagnosticIdempotentOk) {
        reasons.add(
          'direct_stop_render_diagnostic_not_idempotent: code=$stopDiagnosticErrorCode',
        );
      }

      // 3. runMultiCamRenderDiagnostic with missing ids -> INVALID_ARG.
      String? runDiagnosticInvalidArgCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'runMultiCamRenderDiagnostic',
          <String, Object?>{},
        );
      } on PlatformException catch (e) {
        runDiagnosticInvalidArgCode = e.code;
      }
      final directRunDiagnosticInvalidArgOk =
          runDiagnosticInvalidArgCode == 'INVALID_ARG';
      if (!directRunDiagnosticInvalidArgOk) {
        reasons.add(
          'direct_run_diagnostic_invalid_arg_not_rejected: code=$runDiagnosticInvalidArgCode',
        );
      }

      // 4. startMultiCamRenderDiagnostic with missing ids -> INVALID_ARG.
      String? startDiagnosticInvalidArgCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'startMultiCamRenderDiagnostic',
          <String, Object?>{},
        );
      } on PlatformException catch (e) {
        startDiagnosticInvalidArgCode = e.code;
      }
      final directStartDiagnosticInvalidArgOk =
          startDiagnosticInvalidArgCode == 'INVALID_ARG';
      if (!directStartDiagnosticInvalidArgOk) {
        reasons.add(
          'direct_start_diagnostic_invalid_arg_not_rejected: code=$startDiagnosticInvalidArgCode',
        );
      }

      // 5. runMultiCamRenderDiagnostic with valid ids -> fails closed.
      String? runDiagnosticErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'runMultiCamRenderDiagnostic',
          <String, Object?>{
            'frontDeviceId': frontDeviceId,
            'backDeviceId': backDeviceId,
          },
        );
      } on PlatformException catch (e) {
        runDiagnosticErrorCode = e.code;
      }
      final directRunDiagnosticFailClosedOk =
          runDiagnosticErrorCode != null &&
          kAndroidMultiCamActionsFailClosedAllowedDiagnosticErrorCodes.contains(
            runDiagnosticErrorCode,
          );
      if (!directRunDiagnosticFailClosedOk) {
        reasons.add(
          'direct_run_diagnostic_did_not_fail_closed: code=$runDiagnosticErrorCode',
        );
      }

      // 6. startMultiCamRenderDiagnostic with valid ids -> fails closed.
      String? startDiagnosticErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'startMultiCamRenderDiagnostic',
          <String, Object?>{
            'frontDeviceId': frontDeviceId,
            'backDeviceId': backDeviceId,
          },
        );
      } on PlatformException catch (e) {
        startDiagnosticErrorCode = e.code;
      }
      final directStartDiagnosticFailClosedOk =
          startDiagnosticErrorCode != null &&
          kAndroidMultiCamActionsFailClosedAllowedDiagnosticErrorCodes.contains(
            startDiagnosticErrorCode,
          );
      if (!directStartDiagnosticFailClosedOk) {
        reasons.add(
          'direct_start_diagnostic_did_not_fail_closed: code=$startDiagnosticErrorCode',
        );
      }

      // 7. updateMultiCamPreviewConfig with no config -> INVALID_ARG.
      String? updateConfigMissingCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'updateMultiCamPreviewConfig',
          <String, Object?>{},
        );
      } on PlatformException catch (e) {
        updateConfigMissingCode = e.code;
      }
      final directUpdateConfigMissingInvalidArgOk =
          updateConfigMissingCode == 'INVALID_ARG';
      if (!directUpdateConfigMissingInvalidArgOk) {
        reasons.add(
          'direct_update_config_missing_invalid_arg_not_rejected: code=$updateConfigMissingCode',
        );
      }

      // 8. updateMultiCamPreviewConfig with a config -> NOT_RUNNING.
      String? updateConfigWithConfigCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'updateMultiCamPreviewConfig',
          <String, Object?>{'config': const VGLivePreviewConfig().toMap()},
        );
      } on PlatformException catch (e) {
        updateConfigWithConfigCode = e.code;
      }
      final directUpdateConfigWithConfigNotRunningOk =
          updateConfigWithConfigCode == 'NOT_RUNNING';
      if (!directUpdateConfigWithConfigNotRunningOk) {
        reasons.add(
          'direct_update_config_with_config_not_rejected_not_running: code=$updateConfigWithConfigCode',
        );
      }

      // 9. takeMultiCamPhoto with missing path -> INVALID_ARG.
      String? takePhotoMissingCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'takeMultiCamPhoto',
          <String, Object?>{},
        );
      } on PlatformException catch (e) {
        takePhotoMissingCode = e.code;
      }
      final directTakePhotoMissingInvalidArgOk =
          takePhotoMissingCode == 'INVALID_ARG';
      if (!directTakePhotoMissingInvalidArgOk) {
        reasons.add(
          'direct_take_photo_missing_invalid_arg_not_rejected: code=$takePhotoMissingCode',
        );
      }

      // 10. takeMultiCamPhoto with a valid path -> NOT_RUNNING.
      String? takePhotoValidCode;
      try {
        await effectiveChannel.invokeMethod<Object?>('takeMultiCamPhoto', {
          'path': '/tmp/vg_multicam_actions_fail_closed_smoke_photo.jpg',
        });
      } on PlatformException catch (e) {
        takePhotoValidCode = e.code;
      }
      final directTakePhotoValidPathNotRunningOk =
          takePhotoValidCode == 'NOT_RUNNING';
      if (!directTakePhotoValidPathNotRunningOk) {
        reasons.add(
          'direct_take_photo_valid_path_not_rejected_not_running: code=$takePhotoValidCode',
        );
      }

      // 11. startMultiCamRecording with missing path -> INVALID_ARG.
      String? startRecordingMissingCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'startMultiCamRecording',
          <String, Object?>{},
        );
      } on PlatformException catch (e) {
        startRecordingMissingCode = e.code;
      }
      final directStartRecordingMissingInvalidArgOk =
          startRecordingMissingCode == 'INVALID_ARG';
      if (!directStartRecordingMissingInvalidArgOk) {
        reasons.add(
          'direct_start_recording_missing_invalid_arg_not_rejected: code=$startRecordingMissingCode',
        );
      }

      // 12. startMultiCamRecording with a valid path -> NOT_RUNNING.
      String? startRecordingValidCode;
      try {
        await effectiveChannel.invokeMethod<Object?>('startMultiCamRecording', {
          'path': '/tmp/vg_multicam_actions_fail_closed_smoke_recording.mp4',
        });
      } on PlatformException catch (e) {
        startRecordingValidCode = e.code;
      }
      final directStartRecordingValidPathNotRunningOk =
          startRecordingValidCode == 'NOT_RUNNING';
      if (!directStartRecordingValidPathNotRunningOk) {
        reasons.add(
          'direct_start_recording_valid_path_not_rejected_not_running: code=$startRecordingValidCode',
        );
      }

      // 13. stopMultiCamRecording -> always NOT_RUNNING.
      String? stopRecordingCode;
      try {
        await effectiveChannel.invokeMethod<Object?>('stopMultiCamRecording');
      } on PlatformException catch (e) {
        stopRecordingCode = e.code;
      }
      final directStopRecordingNotRunningOk =
          stopRecordingCode == 'NOT_RUNNING';
      if (!directStopRecordingNotRunningOk) {
        reasons.add(
          'direct_stop_recording_not_rejected_not_running: code=$stopRecordingCode',
        );
      }

      // 14-20. Public VGCameraSession wrappers -- their documented contracts
      // are null/false-on-failure or silent no-throw.
      final publicRunDiagnosticResult =
          await VGCameraSession.runMultiCamRenderDiagnostic(
            frontDeviceId: frontDeviceId,
            backDeviceId: backDeviceId,
          );
      final publicRunDiagnosticNullOk = publicRunDiagnosticResult == null;
      if (!publicRunDiagnosticNullOk) {
        reasons.add('public_run_diagnostic_did_not_return_null');
      }

      final publicStartDiagnosticResult =
          await VGCameraSession.startMultiCamRenderDiagnostic(
            frontDeviceId: frontDeviceId,
            backDeviceId: backDeviceId,
          );
      final publicStartDiagnosticNullOk = publicStartDiagnosticResult == null;
      if (!publicStartDiagnosticNullOk) {
        reasons.add('public_start_diagnostic_did_not_return_null');
      }

      final publicStopDiagnosticResult =
          await VGCameraSession.stopMultiCamRenderDiagnostic();
      final publicStopDiagnosticNullOk = publicStopDiagnosticResult == null;
      if (!publicStopDiagnosticNullOk) {
        reasons.add('public_stop_diagnostic_did_not_return_null');
      }

      final publicTakePhotoResult = await VGCameraSession.takeMultiCamPhoto(
        '/tmp/vg_multicam_actions_fail_closed_smoke_photo_public.jpg',
      );
      final publicTakePhotoNullOk = publicTakePhotoResult == null;
      if (!publicTakePhotoNullOk) {
        reasons.add('public_take_photo_did_not_return_null');
      }

      final publicStartRecordingResult =
          await VGCameraSession.startMultiCamRecording(
            '/tmp/vg_multicam_actions_fail_closed_smoke_recording_public.mp4',
          );
      final publicStartRecordingFalseOk = publicStartRecordingResult == false;
      if (!publicStartRecordingFalseOk) {
        reasons.add('public_start_recording_did_not_return_false');
      }

      final publicStopRecordingResult =
          await VGCameraSession.stopMultiCamRecording();
      final publicStopRecordingNullOk = publicStopRecordingResult == null;
      if (!publicStopRecordingNullOk) {
        reasons.add('public_stop_recording_did_not_return_null');
      }

      var publicUpdateConfigNoThrowOk = true;
      try {
        await VGCameraSession.updateMultiCamPreviewConfig(
          const VGLivePreviewConfig(),
        );
      } catch (e) {
        publicUpdateConfigNoThrowOk = false;
        reasons.add('public_update_config_threw: $e');
      }

      final pass =
          directStopPreviewIdempotentOk &&
          directStopRenderDiagnosticIdempotentOk &&
          directRunDiagnosticInvalidArgOk &&
          directStartDiagnosticInvalidArgOk &&
          directRunDiagnosticFailClosedOk &&
          directStartDiagnosticFailClosedOk &&
          directUpdateConfigMissingInvalidArgOk &&
          directUpdateConfigWithConfigNotRunningOk &&
          directTakePhotoMissingInvalidArgOk &&
          directTakePhotoValidPathNotRunningOk &&
          directStartRecordingMissingInvalidArgOk &&
          directStartRecordingValidPathNotRunningOk &&
          directStopRecordingNotRunningOk &&
          publicRunDiagnosticNullOk &&
          publicStartDiagnosticNullOk &&
          publicStopDiagnosticNullOk &&
          publicTakePhotoNullOk &&
          publicStartRecordingFalseOk &&
          publicStopRecordingNullOk &&
          publicUpdateConfigNoThrowOk;

      if (pass) {
        reasons.add('multicam_actions_fail_closed_routes_consistent_pass');
      }

      final diagnostics = <String, Object?>{
        'proofBoundary': kAndroidMultiCamActionsFailClosedProofBoundary,
        'frontDeviceId': frontDeviceId,
        'backDeviceId': backDeviceId,
        'directRunDiagnosticErrorCode': runDiagnosticErrorCode,
        'directStartDiagnosticErrorCode': startDiagnosticErrorCode,
      };

      return VGAndroidMultiCamActionsFailClosedSmokeReport(
        pass: pass,
        proofBoundary: kAndroidMultiCamActionsFailClosedProofBoundary,
        directStopPreviewIdempotentOk: directStopPreviewIdempotentOk,
        directStopRenderDiagnosticIdempotentOk:
            directStopRenderDiagnosticIdempotentOk,
        directRunDiagnosticInvalidArgOk: directRunDiagnosticInvalidArgOk,
        directStartDiagnosticInvalidArgOk: directStartDiagnosticInvalidArgOk,
        directRunDiagnosticFailClosedOk: directRunDiagnosticFailClosedOk,
        directRunDiagnosticErrorCode: runDiagnosticErrorCode,
        directStartDiagnosticFailClosedOk: directStartDiagnosticFailClosedOk,
        directStartDiagnosticErrorCode: startDiagnosticErrorCode,
        directUpdateConfigMissingInvalidArgOk:
            directUpdateConfigMissingInvalidArgOk,
        directUpdateConfigWithConfigNotRunningOk:
            directUpdateConfigWithConfigNotRunningOk,
        directTakePhotoMissingInvalidArgOk: directTakePhotoMissingInvalidArgOk,
        directTakePhotoValidPathNotRunningOk:
            directTakePhotoValidPathNotRunningOk,
        directStartRecordingMissingInvalidArgOk:
            directStartRecordingMissingInvalidArgOk,
        directStartRecordingValidPathNotRunningOk:
            directStartRecordingValidPathNotRunningOk,
        directStopRecordingNotRunningOk: directStopRecordingNotRunningOk,
        publicRunDiagnosticNullOk: publicRunDiagnosticNullOk,
        publicStartDiagnosticNullOk: publicStartDiagnosticNullOk,
        publicStopDiagnosticNullOk: publicStopDiagnosticNullOk,
        publicTakePhotoNullOk: publicTakePhotoNullOk,
        publicStartRecordingFalseOk: publicStartRecordingFalseOk,
        publicStopRecordingNullOk: publicStopRecordingNullOk,
        publicUpdateConfigNoThrowOk: publicUpdateConfigNoThrowOk,
        physicalConcurrentCaptureProven: false,
        textureAllocated: false,
        cameraOpenedByMultiCamRoute: false,
        renderProven: false,
        photoCaptureProven: false,
        recordingExportProven: false,
        productUiWired: false,
        reasons: reasons,
        diagnostics: diagnostics,
      );
    } catch (e, st) {
      return VGAndroidMultiCamActionsFailClosedSmokeReport(
        pass: false,
        proofBoundary: kAndroidMultiCamActionsFailClosedProofBoundary,
        directStopPreviewIdempotentOk: false,
        directStopRenderDiagnosticIdempotentOk: false,
        directRunDiagnosticInvalidArgOk: false,
        directStartDiagnosticInvalidArgOk: false,
        directRunDiagnosticFailClosedOk: false,
        directRunDiagnosticErrorCode: null,
        directStartDiagnosticFailClosedOk: false,
        directStartDiagnosticErrorCode: null,
        directUpdateConfigMissingInvalidArgOk: false,
        directUpdateConfigWithConfigNotRunningOk: false,
        directTakePhotoMissingInvalidArgOk: false,
        directTakePhotoValidPathNotRunningOk: false,
        directStartRecordingMissingInvalidArgOk: false,
        directStartRecordingValidPathNotRunningOk: false,
        directStopRecordingNotRunningOk: false,
        publicRunDiagnosticNullOk: false,
        publicStartDiagnosticNullOk: false,
        publicStopDiagnosticNullOk: false,
        publicTakePhotoNullOk: false,
        publicStartRecordingFalseOk: false,
        publicStopRecordingNullOk: false,
        publicUpdateConfigNoThrowOk: false,
        physicalConcurrentCaptureProven: false,
        textureAllocated: false,
        cameraOpenedByMultiCamRoute: false,
        renderProven: false,
        photoCaptureProven: false,
        recordingExportProven: false,
        productUiWired: false,
        reasons: <String>['exception_during_smoke_run: $e'],
        diagnostics: <String, Object?>{
          'proofBoundary': kAndroidMultiCamActionsFailClosedProofBoundary,
          'error': '$e\n$st',
        },
      );
    }
  }

  /// Convenience static runner method.
  static Future<VGAndroidMultiCamActionsFailClosedSmokeReport> run({
    MethodChannel? channel,
    VGAndroidMultiCamActionsFailClosedSmokeRunner? runner,
  }) {
    final activeRunner =
        runner ?? const VGAndroidMultiCamActionsFailClosedSmokeRunner();
    return activeRunner.runSmoke(channel: channel);
  }
}
