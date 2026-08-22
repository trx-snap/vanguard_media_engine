// Vanguard Android True-DAG Phase 4C3D: Physical RTC video contract smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidRtcVideoCoordinator ->
//   RtcVideoContractSmokeHarness.run(width, height, frameCount) ->
//   NoOpRtcVideoFramePublisher (HardwareBuffer scoped-borrow + delivery contracts).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int _width = int.fromEnvironment('WIDTH', defaultValue: 64);
const int _height = int.fromEnvironment('HEIGHT', defaultValue: 64);
const int _frameCount = int.fromEnvironment('FRAME_COUNT', defaultValue: 3);

void main() {
  runApp(const AndroidRtcVideoContractPhysicalSmokeApp());
}

class AndroidRtcVideoContractPhysicalSmokeApp extends StatefulWidget {
  const AndroidRtcVideoContractPhysicalSmokeApp({super.key});

  @override
  State<AndroidRtcVideoContractPhysicalSmokeApp> createState() =>
      _AndroidRtcVideoContractPhysicalSmokeAppState();
}

class _AndroidRtcVideoContractPhysicalSmokeAppState
    extends State<AndroidRtcVideoContractPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android RTC video contract smoke…';

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
        'runAndroidDagPhase4C3DRtcContractSmoke',
        <String, dynamic>{
          'width': _width,
          'height': _height,
          'frameCount': _frameCount,
        },
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C3DRtcContractSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final primaryAcceptedCount =
          (diagMap['primaryAcceptedCount'] as num?)?.toInt() ?? 0;

      final primarySnapshot = diagMap['primarySnapshot'] is Map
          ? Map<String, dynamic>.from(diagMap['primarySnapshot'] as Map)
          : <String, dynamic>{};
      final secondarySnapshot = diagMap['secondarySnapshot'] is Map
          ? Map<String, dynamic>.from(diagMap['secondarySnapshot'] as Map)
          : <String, dynamic>{};

      final primaryAcceptedFrames =
          (primarySnapshot['acceptedFrames'] as num?)?.toInt() ?? 0;
      final secondaryAcceptedFrames =
          (secondarySnapshot['acceptedFrames'] as num?)?.toInt() ?? 0;
      final secondaryDroppedBackpressure =
          (secondarySnapshot['droppedBackpressureFrames'] as num?)?.toInt() ??
          -1;
      final secondaryDroppedNotReady =
          (secondarySnapshot['droppedNotReadyFrames'] as num?)?.toInt() ?? -1;

      // Pass criteria:
      // 1. Overall pass is true
      // 2. Primary publisher accepted exactly _frameCount frames
      // 3. Secondary publisher backpressure (1) and not-ready (1) subchecks pass if present
      final primaryCountMatch =
          primaryAcceptedCount == _frameCount &&
          primaryAcceptedFrames == _frameCount;
      final secondarySubchecksPass =
          secondaryAcceptedFrames == 1 &&
          secondaryDroppedBackpressure == 1 &&
          secondaryDroppedNotReady == 1;

      pass = overallPass && primaryCountMatch && secondarySubchecksPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_RTC_VIDEO_CONTRACT_PHYSICAL_ERROR: $error\n$stack');
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
    print('ANDROID_RTC_VIDEO_CONTRACT_PHYSICAL_JSON:${jsonEncode(diagMap)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_RTC_VIDEO_CONTRACT_PHYSICAL_PASS'
          : 'ANDROID_RTC_VIDEO_CONTRACT_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (accepted: ${diagMap['primaryAcceptedCount']}/$_frameCount, backpressure/notReady verified)'
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
