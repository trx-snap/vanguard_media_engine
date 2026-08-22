// Vanguard Android True-DAG Phase 4C3G: Physical Realtime Video Adapter smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidRtcVideoCoordinator ->
//   RealtimeVideoOutputAdapterSmokeHarness.run(width, height, frameCount) +
//   RealtimeVideoInputAdapterSmokeHarness.run(width, height, frameCount)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int _width = int.fromEnvironment('WIDTH', defaultValue: 64);
const int _height = int.fromEnvironment('HEIGHT', defaultValue: 64);
const int _frameCount = int.fromEnvironment('FRAME_COUNT', defaultValue: 3);

void main() {
  runApp(const AndroidRealtimeVideoAdapterPhysicalSmokeApp());
}

class AndroidRealtimeVideoAdapterPhysicalSmokeApp extends StatefulWidget {
  const AndroidRealtimeVideoAdapterPhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimeVideoAdapterPhysicalSmokeApp> createState() =>
      _AndroidRealtimeVideoAdapterPhysicalSmokeAppState();
}

class _AndroidRealtimeVideoAdapterPhysicalSmokeAppState
    extends State<AndroidRealtimeVideoAdapterPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android realtime video adapter smoke…';

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
        'runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke',
        <String, dynamic>{
          'width': _width,
          'height': _height,
          'frameCount': _frameCount,
        },
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final outputMap = diagMap['output'] is Map
          ? Map<String, dynamic>.from(diagMap['output'] as Map)
          : <String, dynamic>{};
      final inputMap = diagMap['input'] is Map
          ? Map<String, dynamic>.from(diagMap['input'] as Map)
          : <String, dynamic>{};

      final outputPass = outputMap['pass'] == true;
      final inputPass = inputMap['pass'] == true;

      pass = overallPass && outputPass && inputPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_REALTIME_VIDEO_ADAPTER_PHYSICAL_ERROR: $error\n$stack');
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
    print(
      'ANDROID_REALTIME_VIDEO_ADAPTER_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_REALTIME_VIDEO_ADAPTER_PHYSICAL_PASS'
          : 'ANDROID_REALTIME_VIDEO_ADAPTER_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (outputPass=true, inputPass=true, frameCount=$_frameCount)'
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
