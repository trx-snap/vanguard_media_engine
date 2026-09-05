// android_multicam_capability_routes_physical_smoke.dart
// Vanguard Media Engine - P3-CAM-CONCURRENT-ANDROID-MULTICAM-CAPABILITY-WIRING:
// Android static MultiCam capability routes physical smoke harness.
//
// Proof lanes:
//   - Probes Camera2 hardware capabilities non-promptingly without camera open.
//   - Queries static VGCameraSession.isMultiCamSupported() and VGCameraSession.getMultiCamDeviceSets().
//   - Verifies static routes are read-only and consistent with the canonical Camera2 capability probe.
//   - On unsupported hardware (e.g. SM-A566B), confirms static supported is false and device sets are empty.
//   - On supported hardware, confirms static supported is true and device sets match probe concurrent sets >= 2.
//   - Confirms every device descriptor has valid uniqueId, localizedName, position, and deviceType.
//   - Emits structured JSON summary, start/pass/fail markers, sets visible text, waits briefly, and exits 0 on pass or 1 on fail.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidMultiCamCapabilityRoutesPhysicalSmokeApp());
}

class AndroidMultiCamCapabilityRoutesPhysicalSmokeApp extends StatefulWidget {
  const AndroidMultiCamCapabilityRoutesPhysicalSmokeApp({super.key});

  @override
  State<AndroidMultiCamCapabilityRoutesPhysicalSmokeApp> createState() =>
      _AndroidMultiCamCapabilityRoutesPhysicalSmokeAppState();
}

class _AndroidMultiCamCapabilityRoutesPhysicalSmokeAppState
    extends State<AndroidMultiCamCapabilityRoutesPhysicalSmokeApp> {
  String _status = 'Initializing MultiCam Capability Routes Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kAndroidMultiCamCapabilityRoutesStartMarker);
    try {
      final report = await VGAndroidMultiCamCapabilityRoutesSmokeRunner.run();
      final payload = report.toMap();
      print(
        '$kAndroidMultiCamCapabilityRoutesJsonPrefix${jsonEncode(payload)}',
      );

      if (report.pass) {
        print(kAndroidMultiCamCapabilityRoutesPassMarker);
      } else {
        print(kAndroidMultiCamCapabilityRoutesFailMarker);
      }

      if (mounted) {
        setState(() {
          _status = report.pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(report.pass ? 0 : 1);
    } catch (e, st) {
      print('ANDROID_DAG_PHASE3_MULTICAM_CAPABILITY_ROUTES_ERROR: $e\n$st');
      print(kAndroidMultiCamCapabilityRoutesFailMarker);
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
