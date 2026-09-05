// vg_android_multicam_preview_routes_smoke.dart
// vanguard_media_engine - P3-CAM-CONCURRENT-STARTMULTICAM-FAIL-CLOSED-ANDROID-HANDLER:
// Android startMultiCamPreview/stopMultiCamPreview fail-closed route smoke foundation.
//
// Pure Dart typed report and runner proving the Android startMultiCamPreview /
// stopMultiCamPreview MethodChannel routes fail closed: invalid args reject
// before any capability lookup, hardware without a matching concurrent combo
// (or without a production concurrent-preview lifecycle owner) rejects before
// any camera is opened, any TextureRegistry/SurfaceTexture is allocated, or
// any capture session is created, and stopMultiCamPreview is an idempotent
// no-op. This slice does NOT prove real concurrent camera capture, render, or
// recording/export -- see the non-claim booleans below.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_camera_session.dart';

/// Proof boundary identifier for the Android startMultiCamPreview /
/// stopMultiCamPreview fail-closed route smoke.
const String kAndroidMultiCamPreviewRoutesFailClosedProofBoundary =
    'android_multicam_preview_fail_closed_route_handling_capability_gated_no_camera_open_no_texture_no_capture';

/// Physical smoke START marker token.
const String kAndroidMultiCamPreviewRoutesFailClosedStartMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_PREVIEW_FAIL_CLOSED_ROUTES_PHYSICAL_SMOKE_START';

/// Physical smoke PASS marker token.
const String kAndroidMultiCamPreviewRoutesFailClosedPassMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_PREVIEW_FAIL_CLOSED_ROUTES_PHYSICAL_SMOKE_PASS';

/// Physical smoke FAIL marker token.
const String kAndroidMultiCamPreviewRoutesFailClosedFailMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_PREVIEW_FAIL_CLOSED_ROUTES_PHYSICAL_SMOKE_FAIL';

/// JSON payload log prefix.
const String kAndroidMultiCamPreviewRoutesFailClosedJsonPrefix =
    'ANDROID_DAG_PHASE3_MULTICAM_PREVIEW_FAIL_CLOSED_ROUTES_JSON:';

/// Error codes the direct `startMultiCamPreview` route is allowed to return
/// for a valid (non-blank) device-id pair on hardware with no production
/// concurrent-preview lifecycle owner.
const List<String> kAndroidMultiCamPreviewFailClosedAllowedStartErrorCodes =
    <String>['CONCURRENT_NOT_SUPPORTED', 'CONCURRENT_PREVIEW_NOT_READY'];

/// Immutable typed smoke report produced by [VGAndroidMultiCamPreviewRoutesSmokeRunner].
@immutable
class VGAndroidMultiCamPreviewRoutesSmokeReport {
  const VGAndroidMultiCamPreviewRoutesSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.directStopIdempotentOk,
    required this.directInvalidArgOk,
    required this.directStartFailClosedOk,
    required this.directStartErrorCode,
    required this.publicStartNullOk,
    required this.publicStopNullOk,
    required this.physicalConcurrentCaptureProven,
    required this.textureAllocated,
    required this.cameraOpenedByMultiCamRoute,
    required this.renderProven,
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
  final bool directStopIdempotentOk;

  /// Whether a direct `startMultiCamPreview` call with missing/blank
  /// `frontDeviceId`/`backDeviceId` fails with `PlatformException` code
  /// `INVALID_ARG`.
  final bool directInvalidArgOk;

  /// Whether a direct `startMultiCamPreview` call with valid non-blank
  /// device ids fails closed with `CONCURRENT_NOT_SUPPORTED` or
  /// `CONCURRENT_PREVIEW_NOT_READY` (never a fake success).
  final bool directStartFailClosedOk;

  /// The raw `PlatformException.code` observed for the valid-device-id
  /// direct `startMultiCamPreview` call, or `null` if none was thrown.
  final String? directStartErrorCode;

  /// Whether the public `VGCameraSession.startMultiCamPreview` returns
  /// `null` (its documented `PlatformException` contract).
  final bool publicStartNullOk;

  /// Whether the public `VGCameraSession.stopMultiCamPreview` returns
  /// `null`.
  final bool publicStopNullOk;

  /// Always `false` in this slice: no real concurrent camera capture is
  /// implemented or proven.
  final bool physicalConcurrentCaptureProven;

  /// Always `false` in this slice: neither route allocates a
  /// TextureRegistry/SurfaceTexture.
  final bool textureAllocated;

  /// Always `false` in this slice: neither route opens a camera.
  final bool cameraOpenedByMultiCamRoute;

  /// Always `false` in this slice: no frame is ever rendered.
  final bool renderProven;

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
      'directStopIdempotentOk': directStopIdempotentOk,
      'directInvalidArgOk': directInvalidArgOk,
      'directStartFailClosedOk': directStartFailClosedOk,
      'directStartErrorCode': directStartErrorCode,
      'publicStartNullOk': publicStartNullOk,
      'publicStopNullOk': publicStopNullOk,
      'physicalConcurrentCaptureProven': physicalConcurrentCaptureProven,
      'textureAllocated': textureAllocated,
      'cameraOpenedByMultiCamRoute': cameraOpenedByMultiCamRoute,
      'renderProven': renderProven,
      'recordingExportProven': recordingExportProven,
      'productUiWired': productUiWired,
      'reasons': reasons,
      'diagnostics': diagnostics,
    };
  }

  /// Deserializes a smoke report from a raw map, returning `null` if invalid.
  static VGAndroidMultiCamPreviewRoutesSmokeReport? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final pass = raw['pass'] as bool? ?? false;
    final proofBoundary = raw['proofBoundary'] as String? ?? '';
    final directStopIdempotentOk =
        raw['directStopIdempotentOk'] as bool? ?? false;
    final directInvalidArgOk = raw['directInvalidArgOk'] as bool? ?? false;
    final directStartFailClosedOk =
        raw['directStartFailClosedOk'] as bool? ?? false;
    final directStartErrorCode = raw['directStartErrorCode'] as String?;
    final publicStartNullOk = raw['publicStartNullOk'] as bool? ?? false;
    final publicStopNullOk = raw['publicStopNullOk'] as bool? ?? false;
    final physicalConcurrentCaptureProven =
        raw['physicalConcurrentCaptureProven'] as bool? ?? false;
    final textureAllocated = raw['textureAllocated'] as bool? ?? false;
    final cameraOpenedByMultiCamRoute =
        raw['cameraOpenedByMultiCamRoute'] as bool? ?? false;
    final renderProven = raw['renderProven'] as bool? ?? false;
    final recordingExportProven =
        raw['recordingExportProven'] as bool? ?? false;
    final productUiWired = raw['productUiWired'] as bool? ?? false;

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

    return VGAndroidMultiCamPreviewRoutesSmokeReport(
      pass: pass,
      proofBoundary: proofBoundary,
      directStopIdempotentOk: directStopIdempotentOk,
      directInvalidArgOk: directInvalidArgOk,
      directStartFailClosedOk: directStartFailClosedOk,
      directStartErrorCode: directStartErrorCode,
      publicStartNullOk: publicStartNullOk,
      publicStopNullOk: publicStopNullOk,
      physicalConcurrentCaptureProven: physicalConcurrentCaptureProven,
      textureAllocated: textureAllocated,
      cameraOpenedByMultiCamRoute: cameraOpenedByMultiCamRoute,
      renderProven: renderProven,
      recordingExportProven: recordingExportProven,
      productUiWired: productUiWired,
      reasons: reasons,
      diagnostics: diagnostics,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAndroidMultiCamPreviewRoutesSmokeReport &&
        other.pass == pass &&
        other.proofBoundary == proofBoundary &&
        other.directStopIdempotentOk == directStopIdempotentOk &&
        other.directInvalidArgOk == directInvalidArgOk &&
        other.directStartFailClosedOk == directStartFailClosedOk &&
        other.directStartErrorCode == directStartErrorCode &&
        other.publicStartNullOk == publicStartNullOk &&
        other.publicStopNullOk == publicStopNullOk &&
        other.physicalConcurrentCaptureProven ==
            physicalConcurrentCaptureProven &&
        other.textureAllocated == textureAllocated &&
        other.cameraOpenedByMultiCamRoute == cameraOpenedByMultiCamRoute &&
        other.renderProven == renderProven &&
        other.recordingExportProven == recordingExportProven &&
        other.productUiWired == productUiWired &&
        listEquals(other.reasons, reasons) &&
        mapEquals(other.diagnostics, diagnostics);
  }

  @override
  int get hashCode => Object.hash(
    pass,
    proofBoundary,
    directStopIdempotentOk,
    directInvalidArgOk,
    directStartFailClosedOk,
    directStartErrorCode,
    publicStartNullOk,
    publicStopNullOk,
    physicalConcurrentCaptureProven,
    textureAllocated,
    Object.hash(
      cameraOpenedByMultiCamRoute,
      renderProven,
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
      'VGAndroidMultiCamPreviewRoutesSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'directStopIdempotentOk: $directStopIdempotentOk, '
      'directInvalidArgOk: $directInvalidArgOk, '
      'directStartFailClosedOk: $directStartFailClosedOk, '
      'directStartErrorCode: $directStartErrorCode, '
      'publicStartNullOk: $publicStartNullOk, '
      'publicStopNullOk: $publicStopNullOk, '
      'reasons: $reasons)';
}

/// Runner that executes Android startMultiCamPreview/stopMultiCamPreview
/// fail-closed route verification.
class VGAndroidMultiCamPreviewRoutesSmokeRunner {
  const VGAndroidMultiCamPreviewRoutesSmokeRunner({
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
  Future<VGAndroidMultiCamPreviewRoutesSmokeReport> runSmoke({
    MethodChannel? channel,
  }) async {
    final effectiveChannel =
        channel ?? const MethodChannel('vanguard_media_engine');

    try {
      // 1. stopMultiCamPreview with no active session -> idempotent success.
      String? stopErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>('stopMultiCamPreview');
      } on PlatformException catch (e) {
        stopErrorCode = e.code;
      }
      final directStopIdempotentOk = stopErrorCode == null;

      // 2. startMultiCamPreview with missing/blank ids -> INVALID_ARG.
      String? invalidArgErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'startMultiCamPreview',
          <String, Object?>{},
        );
      } on PlatformException catch (e) {
        invalidArgErrorCode = e.code;
      }
      final directInvalidArgOk = invalidArgErrorCode == 'INVALID_ARG';

      // 3. startMultiCamPreview with valid ids -> fails closed before any
      // camera open / texture allocation / capture session creation.
      String? startErrorCode;
      try {
        await effectiveChannel.invokeMethod<Object?>(
          'startMultiCamPreview',
          <String, Object?>{
            'frontDeviceId': frontDeviceId,
            'backDeviceId': backDeviceId,
          },
        );
      } on PlatformException catch (e) {
        startErrorCode = e.code;
      }
      final directStartFailClosedOk =
          startErrorCode != null &&
          kAndroidMultiCamPreviewFailClosedAllowedStartErrorCodes.contains(
            startErrorCode,
          );

      // 4. Public VGCameraSession.startMultiCamPreview -> null on failure.
      final publicStartResult = await VGCameraSession.startMultiCamPreview(
        frontDeviceId: frontDeviceId,
        backDeviceId: backDeviceId,
      );
      final publicStartNullOk = publicStartResult == null;

      // 5. Public VGCameraSession.stopMultiCamPreview -> null (idempotent).
      final publicStopResult = await VGCameraSession.stopMultiCamPreview();
      final publicStopNullOk = publicStopResult == null;

      final reasons = <String>[];
      if (!directStopIdempotentOk) {
        reasons.add('direct_stop_not_idempotent: code=$stopErrorCode');
      }
      if (!directInvalidArgOk) {
        reasons.add(
          'direct_start_invalid_arg_not_rejected: code=$invalidArgErrorCode',
        );
      }
      if (!directStartFailClosedOk) {
        reasons.add('direct_start_did_not_fail_closed: code=$startErrorCode');
      }
      if (!publicStartNullOk) {
        reasons.add('public_start_did_not_return_null');
      }
      if (!publicStopNullOk) {
        reasons.add('public_stop_did_not_return_null');
      }

      final pass =
          directStopIdempotentOk &&
          directInvalidArgOk &&
          directStartFailClosedOk &&
          publicStartNullOk &&
          publicStopNullOk;

      if (pass) {
        reasons.add('multicam_preview_fail_closed_routes_consistent_pass');
      }

      final diagnostics = <String, Object?>{
        'proofBoundary': kAndroidMultiCamPreviewRoutesFailClosedProofBoundary,
        'frontDeviceId': frontDeviceId,
        'backDeviceId': backDeviceId,
        'directStopIdempotentOk': directStopIdempotentOk,
        'directInvalidArgErrorCode': invalidArgErrorCode,
        'directStartErrorCode': startErrorCode,
      };

      return VGAndroidMultiCamPreviewRoutesSmokeReport(
        pass: pass,
        proofBoundary: kAndroidMultiCamPreviewRoutesFailClosedProofBoundary,
        directStopIdempotentOk: directStopIdempotentOk,
        directInvalidArgOk: directInvalidArgOk,
        directStartFailClosedOk: directStartFailClosedOk,
        directStartErrorCode: startErrorCode,
        publicStartNullOk: publicStartNullOk,
        publicStopNullOk: publicStopNullOk,
        physicalConcurrentCaptureProven: false,
        textureAllocated: false,
        cameraOpenedByMultiCamRoute: false,
        renderProven: false,
        recordingExportProven: false,
        productUiWired: false,
        reasons: reasons,
        diagnostics: diagnostics,
      );
    } catch (e, st) {
      return VGAndroidMultiCamPreviewRoutesSmokeReport(
        pass: false,
        proofBoundary: kAndroidMultiCamPreviewRoutesFailClosedProofBoundary,
        directStopIdempotentOk: false,
        directInvalidArgOk: false,
        directStartFailClosedOk: false,
        directStartErrorCode: null,
        publicStartNullOk: false,
        publicStopNullOk: false,
        physicalConcurrentCaptureProven: false,
        textureAllocated: false,
        cameraOpenedByMultiCamRoute: false,
        renderProven: false,
        recordingExportProven: false,
        productUiWired: false,
        reasons: <String>['exception_during_smoke_run: $e'],
        diagnostics: <String, Object?>{
          'proofBoundary': kAndroidMultiCamPreviewRoutesFailClosedProofBoundary,
          'error': '$e\n$st',
        },
      );
    }
  }

  /// Convenience static runner method.
  static Future<VGAndroidMultiCamPreviewRoutesSmokeReport> run({
    MethodChannel? channel,
    VGAndroidMultiCamPreviewRoutesSmokeRunner? runner,
  }) {
    final activeRunner =
        runner ?? const VGAndroidMultiCamPreviewRoutesSmokeRunner();
    return activeRunner.runSmoke(channel: channel);
  }
}
