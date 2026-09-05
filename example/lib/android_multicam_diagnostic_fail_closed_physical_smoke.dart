// android_multicam_diagnostic_fail_closed_physical_smoke.dart
// Vanguard Media Engine - P3-CAM-CONCURRENT-DIAGNOSTIC-FAIL-CLOSED-ANDROID-HANDLER:
// Android MultiCam legacy diagnostic routes fail-closed physical smoke
// harness.
//
// Proof lanes:
//   - Direct MethodChannel `measureMultiCamHardwareCost` /
//     `runMultiCamStreamingDiagnostic` / `runMultiCamSyncDiagnostic` /
//     `runMultiCamSourceLifecycleDiagnostic` with missing/blank device ids
//     fail with PlatformException code INVALID_ARG, before any capability
//     lookup.
//   - The same four routes with valid non-blank device ids fail closed with
//     CONCURRENT_NOT_SUPPORTED (no matching hardware combo) or
//     CONCURRENT_DIAGNOSTIC_NOT_READY (a combo exists, but Android has no
//     production concurrent-diagnostic lifecycle owner in this slice).
//     Either outcome passes; on SM-A566B (cameraCount=4,
//     supportsConcurrentCamera=false), CONCURRENT_NOT_SUPPORTED is expected.
//     CONCURRENT_DIAGNOSTIC_NOT_READY is only expected on a future device
//     with a real supported concurrent combination.
//   - Public VGCameraSession wrappers for all four routes return `null` on
//     this device (their documented PlatformException / malformed-response
//     contract), never a fake cost/streaming/sync/lifecycle report.
//   - This harness proves route reachability and fail-closed behavior only.
//     It does NOT prove real concurrent camera capture, hardware-cost
//     measurement, streaming, sync, source lifecycle, render, texture
//     allocation, camera open, or product UI wiring -- see the hardcoded
//     `false` fields in the emitted JSON.
//   - Emits sectioned structured JSON (core/direct/public/nonClaims/
//     diagnostics) so logcat lines stay short, start/pass/fail markers,
//     sets visible text, waits briefly, and exits 0 on pass or 1 on fail.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidMultiCamDiagnosticFailClosedPhysicalSmokeApp());
}

class AndroidMultiCamDiagnosticFailClosedPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidMultiCamDiagnosticFailClosedPhysicalSmokeApp({super.key});

  @override
  State<AndroidMultiCamDiagnosticFailClosedPhysicalSmokeApp> createState() =>
      _AndroidMultiCamDiagnosticFailClosedPhysicalSmokeAppState();
}

class _AndroidMultiCamDiagnosticFailClosedPhysicalSmokeAppState
    extends State<AndroidMultiCamDiagnosticFailClosedPhysicalSmokeApp> {
  String _status = 'Initializing MultiCam Diagnostic Fail-Closed Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kAndroidMultiCamDiagnosticFailClosedStartMarker);
    try {
      // SM-A566B has no concurrent camera combo for ids "0"/"1"; the direct
      // diagnostic routes are expected to return CONCURRENT_NOT_SUPPORTED
      // there. On a device where "0"/"1" happens to be a real concurrent
      // combo, the routes are still expected to fail closed with
      // CONCURRENT_DIAGNOSTIC_NOT_READY -- either outcome passes this smoke,
      // but only the former proves the no-combo case.
      final report =
          await VGAndroidMultiCamDiagnosticFailClosedSmokeRunner.run();
      final sections = <Map<String, Object?>>[
        <String, Object?>{
          'section': 'core',
          'pass': report.pass,
          'proofBoundary': report.proofBoundary,
        },
        <String, Object?>{
          'section': 'direct',
          'directMeasureCostInvalidArgOk': report.directMeasureCostInvalidArgOk,
          'directMeasureCostFailClosedOk': report.directMeasureCostFailClosedOk,
          'directMeasureCostErrorCode': report.directMeasureCostErrorCode,
          'directStreamingDiagnosticInvalidArgOk':
              report.directStreamingDiagnosticInvalidArgOk,
          'directStreamingDiagnosticFailClosedOk':
              report.directStreamingDiagnosticFailClosedOk,
          'directStreamingDiagnosticErrorCode':
              report.directStreamingDiagnosticErrorCode,
          'directSyncDiagnosticInvalidArgOk':
              report.directSyncDiagnosticInvalidArgOk,
          'directSyncDiagnosticFailClosedOk':
              report.directSyncDiagnosticFailClosedOk,
          'directSyncDiagnosticErrorCode': report.directSyncDiagnosticErrorCode,
          'directSourceLifecycleDiagnosticInvalidArgOk':
              report.directSourceLifecycleDiagnosticInvalidArgOk,
          'directSourceLifecycleDiagnosticFailClosedOk':
              report.directSourceLifecycleDiagnosticFailClosedOk,
          'directSourceLifecycleDiagnosticErrorCode':
              report.directSourceLifecycleDiagnosticErrorCode,
        },
        <String, Object?>{
          'section': 'public',
          'publicMeasureCostNullOk': report.publicMeasureCostNullOk,
          'publicStreamingDiagnosticNullOk':
              report.publicStreamingDiagnosticNullOk,
          'publicSyncDiagnosticNullOk': report.publicSyncDiagnosticNullOk,
          'publicSourceLifecycleDiagnosticNullOk':
              report.publicSourceLifecycleDiagnosticNullOk,
        },
        <String, Object?>{
          'section': 'nonClaims',
          'physicalConcurrentCaptureProven':
              report.physicalConcurrentCaptureProven,
          'hardwareCostMeasured': report.hardwareCostMeasured,
          'streamingFramesProven': report.streamingFramesProven,
          'syncProven': report.syncProven,
          'sourceLifecycleProven': report.sourceLifecycleProven,
          'cameraOpenedByDiagnosticRoute': report.cameraOpenedByDiagnosticRoute,
          'textureAllocated': report.textureAllocated,
          'productUiWired': report.productUiWired,
        },
        <String, Object?>{
          'section': 'diagnostics',
          'proofBoundary': report.proofBoundary,
          'frontDeviceId': report.diagnostics['frontDeviceId'],
          'backDeviceId': report.diagnostics['backDeviceId'],
          'directMeasureCostErrorCode': report.directMeasureCostErrorCode,
          'directStreamingDiagnosticErrorCode':
              report.directStreamingDiagnosticErrorCode,
          'directSyncDiagnosticErrorCode': report.directSyncDiagnosticErrorCode,
          'directSourceLifecycleDiagnosticErrorCode':
              report.directSourceLifecycleDiagnosticErrorCode,
          'reasons': report.reasons,
        },
      ];
      for (final section in sections) {
        print(
          '$kAndroidMultiCamDiagnosticFailClosedJsonPrefix${jsonEncode(section)}',
        );
      }

      if (report.pass) {
        print(kAndroidMultiCamDiagnosticFailClosedPassMarker);
      } else {
        print(kAndroidMultiCamDiagnosticFailClosedFailMarker);
      }

      if (mounted) {
        setState(() {
          _status = report.pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(report.pass ? 0 : 1);
    } catch (e, st) {
      print(
        'ANDROID_DAG_PHASE3_MULTICAM_DIAGNOSTIC_FAIL_CLOSED_ERROR: $e\n$st',
      );
      print(kAndroidMultiCamDiagnosticFailClosedFailMarker);
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
