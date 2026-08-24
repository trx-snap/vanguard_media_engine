// Vanguard Android True-DAG Phase 4C4K: Public Adaptive Stream Timeline Diagnostics Physical Smoke Test.
//
// Invariants:
// - Consumes public package API only (VGStreamingTimelineDiagnosticsClient).
// - Zero raw MethodChannel creation; zero package:flutter/services.dart imports.
// - Asserts all 12 pass/invariant booleans from the diagnostic report.
// - Emits ANDROID_STREAMING_TIMELINE_PUBLIC_API_PHYSICAL_JSON:<json>.
// - Emits terminal marker ANDROID_STREAMING_TIMELINE_PUBLIC_API_PHYSICAL_PASS or FAIL.
// - Exits 0/1 after marker so unattended flutter run can complete.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const int kFrameCount = int.fromEnvironment('FRAME_COUNT', defaultValue: 5);

void main() {
  runApp(const AndroidStreamingTimelinePublicApiPhysicalSmokeApp());
}

class AndroidStreamingTimelinePublicApiPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingTimelinePublicApiPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingTimelinePublicApiPhysicalSmokeApp> createState() =>
      _AndroidStreamingTimelinePublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingTimelinePublicApiPhysicalSmokeAppState
    extends State<AndroidStreamingTimelinePublicApiPhysicalSmokeApp> {
  String _status =
      'Initializing Android adaptive streaming timeline public API smoke…';

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
      final client = VGStreamingTimelineDiagnosticsClient();
      final report = await client.run(
        request: const VGStreamingTimelineDiagnosticsRequest(
          frameCount: kFrameCount,
        ),
      );

      diagMap = report.toMap();

      final overallPass = report.pass;
      final sequentialPass = report.sequentialPass;
      final duplicatePass = report.duplicatePass;
      final outOfOrderPass = report.outOfOrderPass;
      final latePass = report.latePass;
      final futurePass = report.futurePass;
      final futureRetryPass = report.futureRetryPass;
      final seekRebasePass = report.seekRebasePass;
      final renditionRebasePass = report.renditionRebasePass;
      final liveOffsetPolicyPass = report.liveOffsetPolicyPass;
      final negativeInputPass = report.negativeInputPass;
      final resetPass = report.resetPass;

      pass =
          overallPass &&
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
      print(
        'ANDROID_STREAMING_TIMELINE_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
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
      'ANDROID_STREAMING_TIMELINE_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_TIMELINE_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_TIMELINE_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (all 12 public stream timeline invariants verified)'
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
