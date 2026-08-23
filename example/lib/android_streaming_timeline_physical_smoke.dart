// Vanguard Android True-DAG Phase 4C4I: Physical adaptive streaming timeline smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AdaptiveStreamTimelineSmokeHarness.run(frameCount)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int kFrameCount = int.fromEnvironment('FRAME_COUNT', defaultValue: 5);

void main() {
  runApp(const AndroidStreamingTimelinePhysicalSmokeApp());
}

class AndroidStreamingTimelinePhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingTimelinePhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingTimelinePhysicalSmokeApp> createState() =>
      _AndroidStreamingTimelinePhysicalSmokeAppState();
}

class _AndroidStreamingTimelinePhysicalSmokeAppState
    extends State<AndroidStreamingTimelinePhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android adaptive streaming timeline smoke…';

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
        'runAndroidDagPhase4C4GAdaptiveStreamTimelineSmoke',
        <String, dynamic>{'frameCount': kFrameCount},
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C4GAdaptiveStreamTimelineSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final sequentialPass = diagMap['sequentialPass'] == true;
      final duplicatePass = diagMap['duplicatePass'] == true;
      final outOfOrderPass = diagMap['outOfOrderPass'] == true;
      final latePass = diagMap['latePass'] == true;
      final futurePass = diagMap['futurePass'] == true;
      final futureRetryPass = diagMap['futureRetryPass'] == true;
      final seekRebasePass = diagMap['seekRebasePass'] == true;
      final renditionRebasePass = diagMap['renditionRebasePass'] == true;
      final liveOffsetPolicyPass = diagMap['liveOffsetPolicyPass'] == true;
      final negativeInputPass = diagMap['negativeInputPass'] == true;
      final resetPass = diagMap['resetPass'] == true;

      pass = overallPass &&
          sequentialPass &&
          duplicatePass &&
          outOfOrderPass &&
          latePass &&
          futurePass &&
          futureRetryPass &&
          seekRebasePass &&
          renditionRebasePass &&
          liveOffsetPolicyPass &&
          negativeInputPass &&
          resetPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_STREAMING_TIMELINE_PHYSICAL_ERROR: $error\n$stack');
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
    print('ANDROID_STREAMING_TIMELINE_PHYSICAL_JSON:${jsonEncode(diagMap)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_TIMELINE_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_TIMELINE_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (all 11 stream timeline invariants verified)'
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
