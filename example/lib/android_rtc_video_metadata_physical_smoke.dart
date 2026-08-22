// Vanguard Android True-DAG Phase 4C3K: Physical RTC video metadata (timestamp & orientation) smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidRtcVideoCoordinator ->
//   RtcVideoTimestampMapperSmokeHarness.run() +
//   RtcVideoOrientationPolicySmokeHarness.run()

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidRtcVideoMetadataPhysicalSmokeApp());
}

class AndroidRtcVideoMetadataPhysicalSmokeApp extends StatefulWidget {
  const AndroidRtcVideoMetadataPhysicalSmokeApp({super.key});

  @override
  State<AndroidRtcVideoMetadataPhysicalSmokeApp> createState() =>
      _AndroidRtcVideoMetadataPhysicalSmokeAppState();
}

class _AndroidRtcVideoMetadataPhysicalSmokeAppState
    extends State<AndroidRtcVideoMetadataPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android RTC video metadata smoke…';

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

    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C3KRtcMetadataSmoke',
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C3KRtcMetadataSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final timestampMap = diagMap['timestamp'] is Map
          ? Map<String, dynamic>.from(diagMap['timestamp'] as Map)
          : <String, dynamic>{};
      final orientationMap = diagMap['orientation'] is Map
          ? Map<String, dynamic>.from(diagMap['orientation'] as Map)
          : <String, dynamic>{};

      final timestampPass = timestampMap['pass'] == true;
      final orientationPass = orientationMap['pass'] == true;

      pass = overallPass && timestampPass && orientationPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_RTC_VIDEO_METADATA_PHYSICAL_ERROR: $error\n$stack');
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print('ANDROID_RTC_VIDEO_METADATA_PHYSICAL_JSON:${jsonEncode(diagMap)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_RTC_VIDEO_METADATA_PHYSICAL_PASS'
          : 'ANDROID_RTC_VIDEO_METADATA_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (timestampPass=true, orientationPass=true)'
            : 'FAIL: ${diagMap['raw']}';
      });
    }

    // Exit process after marker so flutter run can finish unattended
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(pass ? 0 : 1);
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
