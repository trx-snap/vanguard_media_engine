// Vanguard Android True-DAG Phase 4C5A: Streaming codec capability physical smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AdaptiveStreamingCodecCapabilitySmokeHarness.run() ->
//   AdaptiveStreamingCodecCapabilityProbe.probe()
//
// Platform Facts & Verification Invariants:
// - Android platform supported media formats docs list H.264/AVC decoder support as baseline,
//   HEVC/H.265 decoder support from Android 5.0+, and AV1 decoder support from Android 10+ with
//   encoder/decoder mandatory beginning Android 14.
// - Android docs state actual device support may vary by device, profile, level, and form factor;
//   app code must inspect device codecs instead of assuming a server-only ladder is safe.
// - Media3 ExoPlayer supports HLS and DASH containers, but contained audio/video sample formats
//   must also be supported by the device.
// - Product policy: future server HEVC/AV1 renditions must be additive. Do not remove H.264 fallback
//   until telemetry proves it is safe.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidStreamingCodecCapabilityPhysicalSmokeApp());
}

class AndroidStreamingCodecCapabilityPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingCodecCapabilityPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCodecCapabilityPhysicalSmokeApp> createState() =>
      _AndroidStreamingCodecCapabilityPhysicalSmokeAppState();
}

class _AndroidStreamingCodecCapabilityPhysicalSmokeAppState
    extends State<AndroidStreamingCodecCapabilityPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android streaming codec capability smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C5AStreamingCodecCapabilitySmoke',
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C5AStreamingCodecCapabilitySmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final avcPass = diagMap['avcPass'] == true;
      final codecCountPass = diagMap['codecCountPass'] == true;
      final fallbackPolicyPass = diagMap['fallbackPolicyPass'] == true;
      final iosMirrorNotePass = diagMap['iosMirrorNotePass'] == true;

      pass = overallPass &&
          avcPass &&
          codecCountPass &&
          fallbackPolicyPass &&
          iosMirrorNotePass;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_STREAMING_CODEC_CAPABILITY_PHYSICAL_ERROR: $error\n$stack');
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    final hevcSupported = diagMap['hevcSupported'] == true;
    final av1Supported = diagMap['av1Supported'] == true;

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_CODEC_CAPABILITY_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_CODEC_CAPABILITY_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_CODEC_CAPABILITY_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (AVC=true, HEVC=$hevcSupported, AV1=$av1Supported)'
            : 'FAIL: ${diagMap['raw']}';
      });
    }

    // Exit process after marker so flutter run can finish unattended
    await Future<void>.delayed(const Duration(seconds: 1));
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
