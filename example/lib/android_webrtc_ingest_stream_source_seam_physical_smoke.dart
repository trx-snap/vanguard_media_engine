// Vanguard Android True-DAG P6-WEBRTC-INGEST-STREAM-SOURCE-SEAM-A: physical
// smoke test for the diagnostic, video-only RTC ingest seam from
// RealtimeVideoInputAdapter/RtcVideoFrameSink into the existing native C++
// StreamSourceNode metadata session.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidRtcVideoCoordinator ->
//   NativeStreamSourceRtcIngestSmokeHarness.run()

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidWebRtcIngestStreamSourceSeamPhysicalSmokeApp());
}

class AndroidWebRtcIngestStreamSourceSeamPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidWebRtcIngestStreamSourceSeamPhysicalSmokeApp({super.key});

  @override
  State<AndroidWebRtcIngestStreamSourceSeamPhysicalSmokeApp> createState() =>
      _AndroidWebRtcIngestStreamSourceSeamPhysicalSmokeAppState();
}

class _AndroidWebRtcIngestStreamSourceSeamPhysicalSmokeAppState
    extends State<AndroidWebRtcIngestStreamSourceSeamPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Initializing Android WebRTC ingest StreamSourceNode seam smoke…';

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
      'ANDROID_DAG_PHASE6_WEBRTC_INGEST_STREAM_SOURCE_SEAM_PHYSICAL_SMOKE_START',
    );

    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 2));

    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase6WebRtcIngestStreamSourceSeamSmoke',
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase6WebRtcIngestStreamSourceSeamSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final createLifecyclePass = diagMap['createLifecyclePass'] == true;
      final preStartPass = diagMap['preStartPass'] == true;
      final startedAcceptPass = diagMap['startedAcceptPass'] == true;
      final backpressurePass = diagMap['backpressurePass'] == true;
      final drainRestoresIngressPass =
          diagMap['drainRestoresIngressPass'] == true;
      final mismatchedDimensionPass =
          diagMap['mismatchedDimensionPass'] == true;
      final pauseResumeLifecyclePass =
          diagMap['pauseResumeLifecyclePass'] == true;
      final scopedBorrowPass = diagMap['scopedBorrowPass'] == true;
      final idempotentClosePass = diagMap['idempotentClosePass'] == true;
      final proofBoundaryPass = diagMap['proofBoundaryPass'] == true;

      pass =
          overallPass &&
          createLifecyclePass &&
          preStartPass &&
          startedAcceptPass &&
          backpressurePass &&
          drainRestoresIngressPass &&
          mismatchedDimensionPass &&
          pauseResumeLifecyclePass &&
          scopedBorrowPass &&
          idempotentClosePass &&
          proofBoundaryPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE6_WEBRTC_INGEST_STREAM_SOURCE_SEAM_PHYSICAL_ERROR: $error\n$stack',
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
      'ANDROID_DAG_PHASE6_WEBRTC_INGEST_STREAM_SOURCE_SEAM_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE6_WEBRTC_INGEST_STREAM_SOURCE_SEAM_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE6_WEBRTC_INGEST_STREAM_SOURCE_SEAM_PHYSICAL_SMOKE_FAIL',
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
