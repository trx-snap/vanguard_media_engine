// Vanguard Android True-DAG P6-STREAM-EGRESS-HW-ENCODER-BRIDGE-A: physical smoke test
// for the bounded hardware MediaCodec encoder output bridge seam.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidRtcVideoCoordinator ->
//   MediaCodecEncodedVideoOutputSmokeHarness.run()

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidMediaCodecEncoderEgressPhysicalSmokeApp());
}

class AndroidMediaCodecEncoderEgressPhysicalSmokeApp extends StatefulWidget {
  const AndroidMediaCodecEncoderEgressPhysicalSmokeApp({super.key});

  @override
  State<AndroidMediaCodecEncoderEgressPhysicalSmokeApp> createState() =>
      _AndroidMediaCodecEncoderEgressPhysicalSmokeAppState();
}

class _AndroidMediaCodecEncoderEgressPhysicalSmokeAppState
    extends State<AndroidMediaCodecEncoderEgressPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Initializing Android MediaCodec encoder egress bridge smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // ignore: avoid_print
    print('ANDROID_DAG_PHASE6_MEDIACODEC_ENCODER_EGRESS_PHYSICAL_SMOKE_START');

    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 2));

    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase6MediaCodecEncoderEgressSmoke',
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase6MediaCodecEncoderEgressSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final lifecyclePass = diagMap['lifecyclePass'] == true;
      final inputSurfaceFeedPass = diagMap['inputSurfaceFeedPass'] == true;
      final outputFormatCsdExtractionPass =
          diagMap['outputFormatCsdExtractionPass'] == true;
      final firstKeyframeGatingPass =
          diagMap['firstKeyframeGatingPass'] == true;
      final scopedBorrowBufferReleasePass =
          diagMap['scopedBorrowBufferReleasePass'] == true;
      final sequentialPtsDtsPass = diagMap['sequentialPtsDtsPass'] == true;
      final backpressureHandlingPass =
          diagMap['backpressureHandlingPass'] == true;
      final pauseResumeKeyframeRegatingPass =
          diagMap['pauseResumeKeyframeRegatingPass'] == true;
      final eosDrainPass = diagMap['eosDrainPass'] == true;
      final idempotentDisposePass = diagMap['idempotentDisposePass'] == true;
      final proofBoundaryPass = diagMap['proofBoundaryPass'] == true;

      pass =
          overallPass &&
          lifecyclePass &&
          inputSurfaceFeedPass &&
          outputFormatCsdExtractionPass &&
          firstKeyframeGatingPass &&
          scopedBorrowBufferReleasePass &&
          sequentialPtsDtsPass &&
          backpressureHandlingPass &&
          pauseResumeKeyframeRegatingPass &&
          eosDrainPass &&
          idempotentDisposePass &&
          proofBoundaryPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE6_MEDIACODEC_ENCODER_EGRESS_PHYSICAL_ERROR: $error\n$stack',
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
      'ANDROID_DAG_PHASE6_MEDIACODEC_ENCODER_EGRESS_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE6_MEDIACODEC_ENCODER_EGRESS_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE6_MEDIACODEC_ENCODER_EGRESS_PHYSICAL_SMOKE_FAIL',
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
