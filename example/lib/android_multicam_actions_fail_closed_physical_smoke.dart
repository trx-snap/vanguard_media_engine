// android_multicam_actions_fail_closed_physical_smoke.dart
// Vanguard Media Engine - P3-CAM-CONCURRENT-MULTICAM-ACTIONS-FAIL-CLOSED-ANDROID-HANDLER:
// Android MultiCam preview/action routes fail-closed physical smoke harness.
//
// Proof lanes:
//   - Direct MethodChannel `stopMultiCamPreview` / `stopMultiCamRenderDiagnostic`
//     with no active session complete without throwing (idempotent no-op
//     success).
//   - Direct MethodChannel `runMultiCamRenderDiagnostic` /
//     `startMultiCamRenderDiagnostic` with missing/blank device ids fail
//     with PlatformException code INVALID_ARG, before any capability lookup.
//   - Direct MethodChannel `runMultiCamRenderDiagnostic` /
//     `startMultiCamRenderDiagnostic` with valid non-blank device ids fail
//     closed with CONCURRENT_NOT_SUPPORTED (no matching hardware combo) or
//     CONCURRENT_PREVIEW_NOT_READY (a combo exists, but Android has no
//     production concurrent-preview lifecycle owner in this slice). Either
//     outcome passes; only CONCURRENT_NOT_SUPPORTED proves the no-combo case
//     on devices like SM-A566B.
//   - Direct MethodChannel `updateMultiCamPreviewConfig` rejects with
//     INVALID_ARG when no config map is supplied, and NOT_RUNNING when a
//     config map is supplied (there is never a running Android MultiCam
//     preview session in this slice).
//   - Direct MethodChannel `takeMultiCamPhoto` / `startMultiCamRecording`
//     reject with INVALID_ARG for a missing/blank path and NOT_RUNNING for a
//     valid path. `stopMultiCamRecording` always rejects with NOT_RUNNING.
//   - Public VGCameraSession wrappers for all of the above return
//     null/false on this device (their documented PlatformException
//     contracts), or complete silently without throwing, never a fake
//     result.
//   - This harness proves route reachability and fail-closed behavior only.
//     It does NOT prove real concurrent camera capture, texture allocation,
//     camera open, render, photo capture, or recording/export -- see the
//     hardcoded `false` fields in the emitted JSON.
//   - Emits structured JSON summary, start/pass/fail markers, sets visible
//     text, waits briefly, and exits 0 on pass or 1 on fail.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidMultiCamActionsFailClosedPhysicalSmokeApp());
}

class AndroidMultiCamActionsFailClosedPhysicalSmokeApp extends StatefulWidget {
  const AndroidMultiCamActionsFailClosedPhysicalSmokeApp({super.key});

  @override
  State<AndroidMultiCamActionsFailClosedPhysicalSmokeApp> createState() =>
      _AndroidMultiCamActionsFailClosedPhysicalSmokeAppState();
}

class _AndroidMultiCamActionsFailClosedPhysicalSmokeAppState
    extends State<AndroidMultiCamActionsFailClosedPhysicalSmokeApp> {
  String _status = 'Initializing MultiCam Actions Fail-Closed Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kAndroidMultiCamActionsFailClosedStartMarker);
    try {
      // SM-A566B has no concurrent camera combo for ids "0"/"1"; the direct
      // run/start diagnostic routes are expected to return
      // CONCURRENT_NOT_SUPPORTED there. On a device where "0"/"1" happens to
      // be a real concurrent combo, the routes are still expected to fail
      // closed with CONCURRENT_PREVIEW_NOT_READY -- either outcome passes
      // this smoke, but only the former proves the no-combo case.
      final report = await VGAndroidMultiCamActionsFailClosedSmokeRunner.run();
      final sections = <Map<String, Object?>>[
        <String, Object?>{
          'section': 'core',
          'pass': report.pass,
          'proofBoundary': report.proofBoundary,
        },
        <String, Object?>{
          'section': 'direct',
          'directStopPreviewIdempotentOk': report.directStopPreviewIdempotentOk,
          'directStopRenderDiagnosticIdempotentOk':
              report.directStopRenderDiagnosticIdempotentOk,
          'directRunDiagnosticInvalidArgOk':
              report.directRunDiagnosticInvalidArgOk,
          'directStartDiagnosticInvalidArgOk':
              report.directStartDiagnosticInvalidArgOk,
          'directRunDiagnosticFailClosedOk':
              report.directRunDiagnosticFailClosedOk,
          'directRunDiagnosticErrorCode': report.directRunDiagnosticErrorCode,
          'directStartDiagnosticFailClosedOk':
              report.directStartDiagnosticFailClosedOk,
          'directStartDiagnosticErrorCode':
              report.directStartDiagnosticErrorCode,
          'directUpdateConfigMissingInvalidArgOk':
              report.directUpdateConfigMissingInvalidArgOk,
          'directUpdateConfigWithConfigNotRunningOk':
              report.directUpdateConfigWithConfigNotRunningOk,
          'directTakePhotoMissingInvalidArgOk':
              report.directTakePhotoMissingInvalidArgOk,
          'directTakePhotoValidPathNotRunningOk':
              report.directTakePhotoValidPathNotRunningOk,
          'directStartRecordingMissingInvalidArgOk':
              report.directStartRecordingMissingInvalidArgOk,
          'directStartRecordingValidPathNotRunningOk':
              report.directStartRecordingValidPathNotRunningOk,
          'directStopRecordingNotRunningOk':
              report.directStopRecordingNotRunningOk,
        },
        <String, Object?>{
          'section': 'public',
          'publicRunDiagnosticNullOk': report.publicRunDiagnosticNullOk,
          'publicStartDiagnosticNullOk': report.publicStartDiagnosticNullOk,
          'publicStopDiagnosticNullOk': report.publicStopDiagnosticNullOk,
          'publicTakePhotoNullOk': report.publicTakePhotoNullOk,
          'publicStartRecordingFalseOk': report.publicStartRecordingFalseOk,
          'publicStopRecordingNullOk': report.publicStopRecordingNullOk,
          'publicUpdateConfigNoThrowOk': report.publicUpdateConfigNoThrowOk,
        },
        <String, Object?>{
          'section': 'nonClaims',
          'physicalConcurrentCaptureProven':
              report.physicalConcurrentCaptureProven,
          'textureAllocated': report.textureAllocated,
          'cameraOpenedByMultiCamRoute': report.cameraOpenedByMultiCamRoute,
          'renderProven': report.renderProven,
          'photoCaptureProven': report.photoCaptureProven,
          'recordingExportProven': report.recordingExportProven,
          'productUiWired': report.productUiWired,
        },
        <String, Object?>{
          'section': 'diagnostics',
          'proofBoundary': report.proofBoundary,
          'frontDeviceId': report.diagnostics['frontDeviceId'],
          'backDeviceId': report.diagnostics['backDeviceId'],
          'directRunDiagnosticErrorCode': report.directRunDiagnosticErrorCode,
          'directStartDiagnosticErrorCode':
              report.directStartDiagnosticErrorCode,
          'reasons': report.reasons,
        },
      ];
      for (final section in sections) {
        print(
          '$kAndroidMultiCamActionsFailClosedJsonPrefix${jsonEncode(section)}',
        );
      }

      if (report.pass) {
        print(kAndroidMultiCamActionsFailClosedPassMarker);
      } else {
        print(kAndroidMultiCamActionsFailClosedFailMarker);
      }

      if (mounted) {
        setState(() {
          _status = report.pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(report.pass ? 0 : 1);
    } catch (e, st) {
      print('ANDROID_DAG_PHASE3_MULTICAM_ACTIONS_FAIL_CLOSED_ERROR: $e\n$st');
      print(kAndroidMultiCamActionsFailClosedFailMarker);
      if (mounted) {
        setState(() {
          _status = 'FAIL';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
