// Vanguard Android True-DAG P6-MEDIA3-INGEST-STREAM-SOURCE-SEAM-A: physical
// smoke test for the diagnostic, video-only Media3 decoded-frame ingest seam
// from HttpAdaptiveFrameListener into the existing native C++
// StreamSourceNode metadata session.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidMedia3StreamSourceCoordinator ->
//   NativeStreamSourceMedia3IngestSmokeHarness.run()

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidMedia3IngestStreamSourceSeamPhysicalSmokeApp());
}

class AndroidMedia3IngestStreamSourceSeamPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidMedia3IngestStreamSourceSeamPhysicalSmokeApp({super.key});

  @override
  State<AndroidMedia3IngestStreamSourceSeamPhysicalSmokeApp> createState() =>
      _AndroidMedia3IngestStreamSourceSeamPhysicalSmokeAppState();
}

class _AndroidMedia3IngestStreamSourceSeamPhysicalSmokeAppState
    extends State<AndroidMedia3IngestStreamSourceSeamPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Initializing Android Media3 ingest StreamSourceNode seam smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // ignore: avoid_print
    print(
      'ANDROID_DAG_PHASE6_MEDIA3_INGEST_STREAM_SOURCE_SEAM_PHYSICAL_SMOKE_START',
    );

    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 2));

    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase6Media3IngestStreamSourceSeamSmoke',
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase6Media3IngestStreamSourceSeamSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final createLifecyclePass = diagMap['createLifecyclePass'] == true;
      final preStartDropPass = diagMap['preStartDropPass'] == true;
      final startedAcceptPass = diagMap['startedAcceptPass'] == true;
      final backpressurePass = diagMap['backpressurePass'] == true;
      final drainRestoresIngressPass =
          diagMap['drainRestoresIngressPass'] == true;
      final mismatchedDimensionPass =
          diagMap['mismatchedDimensionPass'] == true;
      final invalidTimestampOrIndexPass =
          diagMap['invalidTimestampOrIndexPass'] == true;
      final pauseResumeLifecyclePass =
          diagMap['pauseResumeLifecyclePass'] == true;
      final scopedBorrowPass = diagMap['scopedBorrowPass'] == true;
      final idempotentClosePass = diagMap['idempotentClosePass'] == true;
      final proofBoundaryPass = diagMap['proofBoundaryPass'] == true;

      pass =
          overallPass &&
          createLifecyclePass &&
          preStartDropPass &&
          startedAcceptPass &&
          backpressurePass &&
          drainRestoresIngressPass &&
          mismatchedDimensionPass &&
          invalidTimestampOrIndexPass &&
          pauseResumeLifecyclePass &&
          scopedBorrowPass &&
          idempotentClosePass &&
          proofBoundaryPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE6_MEDIA3_INGEST_STREAM_SOURCE_SEAM_PHYSICAL_ERROR: $error\n$stack',
      );
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    // ignore: avoid_print
    print(
      'ANDROID_DAG_PHASE6_MEDIA3_INGEST_STREAM_SOURCE_SEAM_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE6_MEDIA3_INGEST_STREAM_SOURCE_SEAM_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE6_MEDIA3_INGEST_STREAM_SOURCE_SEAM_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: ${diagMap['raw']}';
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
