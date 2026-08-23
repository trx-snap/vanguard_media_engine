// Vanguard Android True-DAG Phase 4C6C: Prewarm engine physical smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AndroidDagPlaybackPrewarmSmokeHarness.run() ->
//   AndroidDagPlaybackPrewarmEngine.start() & CacheWriter / SimpleCache
//
// Platform Facts & Verification Invariants:
// - Verifies AndroidX Media3 CacheWriter prewarm engine execution on background thread.
// - Exercises bounded network prewarm of public HLS manifest without ExoPlayer / Surface instantiation.
// - Validates cancel idempotency and safety.
// - No playback mutation, no surface/decoder creation in this harness.
// - Segment graph prefetch is not claimed (adaptiveSegmentGraphPrefetch == false).
// - WebRTC/LiveKit caching is excluded per ADR-AND-10 (webRtcCache == false).
// - Physical pass requires: phase == "Phase4C6C", pass == true, completedPrewarm == true,
//   cancelMissingSafe == true, prewarmImplemented == true, adaptiveSegmentGraphPrefetch == false,
//   playbackMutation == false, webRtcCache == false.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidStreamingPrewarmPhysicalSmokeApp());
}

class AndroidStreamingPrewarmPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingPrewarmPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingPrewarmPhysicalSmokeApp> createState() =>
      _AndroidStreamingPrewarmPhysicalSmokeAppState();
}

class _AndroidStreamingPrewarmPhysicalSmokeAppState
    extends State<AndroidStreamingPrewarmPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android streaming prewarm smoke…';

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
        'runAndroidDagPhase4C6CPrewarmSmoke',
        <String, dynamic>{'maxBytes': 65536},
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C6CPrewarmSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final phaseMatch = diagMap['phase'] == 'Phase4C6C';
      final overallPass = diagMap['pass'] == true;
      final completedPrewarm = diagMap['completedPrewarm'] == true;
      final cancelMissingSafe = diagMap['cancelMissingSafe'] == true;
      final prewarmImplemented = diagMap['prewarmImplemented'] == true;
      final adaptiveSegmentGraphPrefetch =
          diagMap['adaptiveSegmentGraphPrefetch'] == false;
      final playbackMutation = diagMap['playbackMutation'] == false;
      final webRtcCache = diagMap['webRtcCache'] == false;

      pass =
          phaseMatch &&
          overallPass &&
          completedPrewarm &&
          cancelMissingSafe &&
          prewarmImplemented &&
          adaptiveSegmentGraphPrefetch &&
          playbackMutation &&
          webRtcCache;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_PREWARM_PHYSICAL_ERROR: $error\n$stack',
      );
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'phase': 'Phase4C6C',
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    final rawStatus = diagMap['raw'] ?? 'unknown';

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_PREWARM_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_PREWARM_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_PREWARM_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (Raw=$rawStatus)'
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
