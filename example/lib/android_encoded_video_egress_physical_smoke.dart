// Vanguard Android True-DAG P6-STREAM-EGRESS-ENCODED-SEAM-A: physical smoke test
// for the transport-neutral encoded video egress foundation seam.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidRtcVideoCoordinator ->
//   RealtimeEncodedVideoOutputSmokeHarness.run()

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidEncodedVideoEgressPhysicalSmokeApp());
}

class AndroidEncodedVideoEgressPhysicalSmokeApp extends StatefulWidget {
  const AndroidEncodedVideoEgressPhysicalSmokeApp({super.key});

  @override
  State<AndroidEncodedVideoEgressPhysicalSmokeApp> createState() =>
      _AndroidEncodedVideoEgressPhysicalSmokeAppState();
}

class _AndroidEncodedVideoEgressPhysicalSmokeAppState
    extends State<AndroidEncodedVideoEgressPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Initializing Android encoded video egress foundation seam smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // ignore: avoid_print
    print('ANDROID_DAG_PHASE6_ENCODED_VIDEO_EGRESS_SEAM_PHYSICAL_SMOKE_START');

    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 2));

    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase6EncodedVideoEgressSeamSmoke',
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase6EncodedVideoEgressSeamSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final lifecyclePass = diagMap['lifecyclePass'] == true;
      final preStartDropPass = diagMap['preStartDropPass'] == true;
      final keyframeGatingPass = diagMap['keyframeGatingPass'] == true;
      final sequentialDeliveryPass = diagMap['sequentialDeliveryPass'] == true;
      final backpressurePass = diagMap['backpressurePass'] == true;
      final pauseDropPass = diagMap['pauseDropPass'] == true;
      final resumeRecoveryPass = diagMap['resumeRecoveryPass'] == true;
      final idempotentDisposePass = diagMap['idempotentDisposePass'] == true;
      final scopedBorrowPass = diagMap['scopedBorrowPass'] == true;
      final proofBoundaryPass = diagMap['proofBoundaryPass'] == true;

      pass =
          overallPass &&
          lifecyclePass &&
          preStartDropPass &&
          keyframeGatingPass &&
          sequentialDeliveryPass &&
          backpressurePass &&
          pauseDropPass &&
          resumeRecoveryPass &&
          idempotentDisposePass &&
          scopedBorrowPass &&
          proofBoundaryPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE6_ENCODED_VIDEO_EGRESS_SEAM_PHYSICAL_ERROR: $error\n$stack',
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
      'ANDROID_DAG_PHASE6_ENCODED_VIDEO_EGRESS_SEAM_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE6_ENCODED_VIDEO_EGRESS_SEAM_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE6_ENCODED_VIDEO_EGRESS_SEAM_PHYSICAL_SMOKE_FAIL',
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
