// Vanguard Android True-DAG Phase 4C3Z: Public RTC video diagnostics physical smoke test.
//
// Imports strictly from `package:vanguard_media_engine/vanguard_media_engine.dart`.
// Zero raw MethodChannel or `package:flutter/services.dart` imports.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const int _width = int.fromEnvironment('WIDTH', defaultValue: 64);
const int _height = int.fromEnvironment('HEIGHT', defaultValue: 64);
const int _frameCount = int.fromEnvironment('FRAME_COUNT', defaultValue: 3);

void main() {
  runApp(const AndroidRtcVideoDiagnosticsPublicApiPhysicalSmokeApp());
}

class AndroidRtcVideoDiagnosticsPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRtcVideoDiagnosticsPublicApiPhysicalSmokeApp({super.key});

  @override
  State<AndroidRtcVideoDiagnosticsPublicApiPhysicalSmokeApp> createState() =>
      _AndroidRtcVideoDiagnosticsPublicApiPhysicalSmokeAppState();
}

class _AndroidRtcVideoDiagnosticsPublicApiPhysicalSmokeAppState
    extends State<AndroidRtcVideoDiagnosticsPublicApiPhysicalSmokeApp> {
  String _status =
      'Initializing Android RTC Video Diagnostics Public API physical smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 2));

    if (mounted) {
      setState(() {
        _status = 'Running VGRtcVideoDiagnosticsClient.runAll…';
      });
    }

    final client = VGRtcVideoDiagnosticsClient();
    final report = await client.runAll(
      request: const VGRtcVideoDiagnosticsRequest(
        width: _width,
        height: _height,
        frameCount: _frameCount,
      ),
    );

    final bool physicalPass =
        report.pass &&
        report.videoOnlyBoundaryPreserved &&
        report.roomAudioBoundaryPreserved &&
        report.transportAgnostic &&
        report.checks.length == 7 &&
        report.checks.values.every((c) => c.pass);

    // Print diagnostic JSON payload
    // ignore: avoid_print
    print(
      'ANDROID_RTC_VIDEO_DIAGNOSTICS_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(report.toMap())}',
    );

    // Print terminal pass/fail marker
    // ignore: avoid_print
    print(
      physicalPass
          ? 'ANDROID_RTC_VIDEO_DIAGNOSTICS_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_RTC_VIDEO_DIAGNOSTICS_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = physicalPass
            ? 'PASS (all 7 RTC diagnostics routes verified via public API)'
            : 'FAIL (pass=${report.pass}, checks=${report.checks.map((k, v) => MapEntry(k, v.pass))})';
      });
    }

    // Exit process after marker so flutter run can finish unattended
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(physicalPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
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
