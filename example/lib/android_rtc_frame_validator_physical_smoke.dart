// Vanguard Android True-DAG Phase 4C3Q: Physical RTC video frame validator smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidRtcVideoCoordinator ->
//   RtcVideoFrameValidatorSmokeHarness.run()

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidRtcFrameValidatorPhysicalSmokeApp());
}

class AndroidRtcFrameValidatorPhysicalSmokeApp extends StatefulWidget {
  const AndroidRtcFrameValidatorPhysicalSmokeApp({super.key});

  @override
  State<AndroidRtcFrameValidatorPhysicalSmokeApp> createState() =>
      _AndroidRtcFrameValidatorPhysicalSmokeAppState();
}

class _AndroidRtcFrameValidatorPhysicalSmokeAppState
    extends State<AndroidRtcFrameValidatorPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android RTC frame validator smoke…';

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
        'runAndroidDagPhase4C3QRtcFrameValidatorSmoke',
        <String, dynamic>{'width': 64, 'height': 64},
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C3QRtcFrameValidatorSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final validFramePass = diagMap['validFramePass'] == true;
      final mismatchedWidthPass = diagMap['mismatchedWidthPass'] == true;
      final mismatchedHeightPass = diagMap['mismatchedHeightPass'] == true;
      final missingUsagePass = diagMap['missingUsagePass'] == true;
      final closedBufferPass = diagMap['closedBufferPass'] == true;
      final constructorValidationPass =
          diagMap['constructorValidationPass'] == true;

      pass =
          overallPass &&
          validFramePass &&
          mismatchedWidthPass &&
          mismatchedHeightPass &&
          missingUsagePass &&
          closedBufferPass &&
          constructorValidationPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_RTC_FRAME_VALIDATOR_PHYSICAL_ERROR: $error\n$stack');
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
    print('ANDROID_RTC_FRAME_VALIDATOR_PHYSICAL_JSON:${jsonEncode(diagMap)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_RTC_FRAME_VALIDATOR_PHYSICAL_PASS'
          : 'ANDROID_RTC_FRAME_VALIDATOR_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (validFrame, mismatchedWidth, mismatchedHeight, missingUsage, closedBuffer, constructor bounds verified)'
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
