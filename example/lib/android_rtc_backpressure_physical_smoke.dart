// Vanguard Android True-DAG Phase 4C3N: Physical RTC video backpressure controller smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidRtcVideoCoordinator ->
//   RtcVideoBackpressureSmokeHarness.run()

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidRtcBackpressurePhysicalSmokeApp());
}

class AndroidRtcBackpressurePhysicalSmokeApp extends StatefulWidget {
  const AndroidRtcBackpressurePhysicalSmokeApp({super.key});

  @override
  State<AndroidRtcBackpressurePhysicalSmokeApp> createState() =>
      _AndroidRtcBackpressurePhysicalSmokeAppState();
}

class _AndroidRtcBackpressurePhysicalSmokeAppState
    extends State<AndroidRtcBackpressurePhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android RTC backpressure smoke…';

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
        'runAndroidDagPhase4C3NRtcBackpressureSmoke',
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C3NRtcBackpressureSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final dropWhenBusyPass = diagMap['dropWhenBusyPass'] == true;
      final latestFrameWinsPass = diagMap['latestFrameWinsPass'] == true;
      final maxInFlight2Pass = diagMap['maxInFlight2Pass'] == true;
      final invalidFrameIndexPass = diagMap['invalidFrameIndexPass'] == true;
      final constructorValidationPass =
          diagMap['constructorValidationPass'] == true;
      final resetPass = diagMap['resetPass'] == true;

      pass =
          overallPass &&
          dropWhenBusyPass &&
          latestFrameWinsPass &&
          maxInFlight2Pass &&
          invalidFrameIndexPass &&
          constructorValidationPass &&
          resetPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_RTC_BACKPRESSURE_PHYSICAL_ERROR: $error\n$stack');
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
    print('ANDROID_RTC_BACKPRESSURE_PHYSICAL_JSON:${jsonEncode(diagMap)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_RTC_BACKPRESSURE_PHYSICAL_PASS'
          : 'ANDROID_RTC_BACKPRESSURE_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (dropWhenBusy, latestFrameWins, maxInFlight2, invalidIndex, constructor, reset verified)'
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
