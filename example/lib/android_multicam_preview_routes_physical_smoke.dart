// android_multicam_preview_routes_physical_smoke.dart
// Vanguard Media Engine - P3-CAM-CONCURRENT-STARTMULTICAM-FAIL-CLOSED-ANDROID-HANDLER:
// Android startMultiCamPreview/stopMultiCamPreview fail-closed route physical
// smoke harness.
//
// Proof lanes:
//   - Direct MethodChannel `stopMultiCamPreview` with no active session
//     completes without throwing (idempotent no-op success).
//   - Direct MethodChannel `startMultiCamPreview` with missing/blank device
//     ids fails with PlatformException code INVALID_ARG, before any
//     capability lookup.
//   - Direct MethodChannel `startMultiCamPreview` with valid non-blank
//     device ids fails closed with CONCURRENT_NOT_SUPPORTED (no matching
//     hardware combo) or CONCURRENT_PREVIEW_NOT_READY (a combo exists, but
//     Android has no production concurrent-preview lifecycle owner in this
//     slice). Either outcome passes; only CONCURRENT_NOT_SUPPORTED proves the
//     no-combo case on devices like SM-A566B.
//   - Public VGCameraSession.startMultiCamPreview / stopMultiCamPreview both
//     return null on this device (their documented PlatformException
//     contract), never a fake session.
//   - This harness proves route reachability and fail-closed behavior only.
//     It does NOT prove real concurrent camera capture, texture allocation,
//     camera open, render, or recording/export -- see the hardcoded `false`
//     fields in the emitted JSON.
//   - Emits structured JSON summary, start/pass/fail markers, sets visible
//     text, waits briefly, and exits 0 on pass or 1 on fail.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidMultiCamPreviewRoutesPhysicalSmokeApp());
}

class AndroidMultiCamPreviewRoutesPhysicalSmokeApp extends StatefulWidget {
  const AndroidMultiCamPreviewRoutesPhysicalSmokeApp({super.key});

  @override
  State<AndroidMultiCamPreviewRoutesPhysicalSmokeApp> createState() =>
      _AndroidMultiCamPreviewRoutesPhysicalSmokeAppState();
}

class _AndroidMultiCamPreviewRoutesPhysicalSmokeAppState
    extends State<AndroidMultiCamPreviewRoutesPhysicalSmokeApp> {
  String _status = 'Initializing MultiCam Preview Fail-Closed Routes Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kAndroidMultiCamPreviewRoutesFailClosedStartMarker);
    try {
      // SM-A566B has no concurrent camera combo for ids "0"/"1"; the direct
      // start route is expected to return CONCURRENT_NOT_SUPPORTED there. On
      // a device where "0"/"1" happens to be a real concurrent combo, the
      // route is still expected to fail closed with
      // CONCURRENT_PREVIEW_NOT_READY -- either outcome passes this smoke,
      // but only the former proves the no-combo case.
      final report = await VGAndroidMultiCamPreviewRoutesSmokeRunner.run();
      final payload = report.toMap();
      print(
        '$kAndroidMultiCamPreviewRoutesFailClosedJsonPrefix${jsonEncode(payload)}',
      );

      if (report.pass) {
        print(kAndroidMultiCamPreviewRoutesFailClosedPassMarker);
      } else {
        print(kAndroidMultiCamPreviewRoutesFailClosedFailMarker);
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
        'ANDROID_DAG_PHASE3_MULTICAM_PREVIEW_FAIL_CLOSED_ROUTES_ERROR: $e\n$st',
      );
      print(kAndroidMultiCamPreviewRoutesFailClosedFailMarker);
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
