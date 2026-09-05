// android_duet_dual_camera_capability_physical_smoke.dart
// Vanguard Media Engine - P3-CAM-DUET-CAPABILITY-ADMISSION-ROUTE: Duet/Dual Camera
// Capability Admission Route Physical Smoke Harness.
//
// Proof lanes:
//   - Probes hardware capabilities non-promptingly without camera open.
//   - Evaluates production policy ([allowDiagnosticSyntheticMode] = false).
//   - Evaluates diagnostic policy ([allowDiagnosticSyntheticMode] = true).
//   - On unsupported hardware (e.g. SM-A566B), confirms production real dual camera
//     is hidden/disabled and fail-closed, while diagnostic synthetic mode is
//     admitted only when explicitly requested and reports isPhysicalDualCamera=false.
//   - Emits structured JSON summary, start/pass/fail markers, and exits 0 on pass or 1 on fail.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidDuetDualCameraCapabilityPhysicalSmokeApp());
}

class AndroidDuetDualCameraCapabilityPhysicalSmokeApp extends StatefulWidget {
  const AndroidDuetDualCameraCapabilityPhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetDualCameraCapabilityPhysicalSmokeApp> createState() =>
      _AndroidDuetDualCameraCapabilityPhysicalSmokeAppState();
}

class _AndroidDuetDualCameraCapabilityPhysicalSmokeAppState
    extends State<AndroidDuetDualCameraCapabilityPhysicalSmokeApp> {
  String _status = 'Initializing Duet Dual Camera Capability Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kDuetDualCameraCapabilityAdmissionStartMarker);
    try {
      final report = await VGDuetDualCameraCapabilitySmokeRunner.run();
      final payload = report.toMap();
      print(
        'ANDROID_DAG_PHASE3_DUET_CAPABILITY_ADMISSION_JSON:${jsonEncode(payload)}',
      );

      if (report.pass) {
        print(kDuetDualCameraCapabilityAdmissionPassMarker);
      } else {
        print(kDuetDualCameraCapabilityAdmissionFailMarker);
      }

      if (mounted) {
        setState(() {
          _status = report.pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(report.pass ? 0 : 1);
    } catch (e, st) {
      print('ANDROID_DAG_PHASE3_DUET_CAPABILITY_ADMISSION_ERROR: $e\n$st');
      print(kDuetDualCameraCapabilityAdmissionFailMarker);
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
