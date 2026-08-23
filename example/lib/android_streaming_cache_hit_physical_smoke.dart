// Vanguard Android True-DAG Phase 4C6D: Playback cache hit proof physical smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AndroidDagPlaybackCacheHitSmokeHarness.run() ->
//   AndroidDagPlaybackPrewarmEngine & CacheDataSource / FailingNetworkDataSource
//
// Platform Facts & Verification Invariants:
// - Proves AndroidX Media3 SimpleCache read-through cache hit proof on background thread.
// - Performs bounded prewarm of public HLS manifest via CacheWriter.
// - Verifies that subsequent CacheDataSource read is satisfied entirely from cache with
//   failing network upstream (networkOpenCount == 0).
// - Proves cache hit for bounded single resource without full ExoPlayer playback hit.
// - No ExoPlayer, Surface, MediaCodec, Vulkan, WebRTC, or ConnectsApp state mutation.
// - Adaptive segment graph prefetch is NOT claimed (adaptiveSegmentGraphPrefetch == false).
// - WebRTC/LiveKit caching is excluded per ADR-AND-10 (webRtcCache == false).
// - Physical pass requires: phase == "Phase4C6D", pass == true, completedPrewarm == true,
//   cacheReadSucceeded == true, cacheReadBytes > 0, networkOpenCount == 0,
//   cacheHitProof == true, fullPlaybackHitProof == false,
//   adaptiveSegmentGraphPrefetch == false, playbackMutation == false, webRtcCache == false.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidStreamingCacheHitPhysicalSmokeApp());
}

class AndroidStreamingCacheHitPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingCacheHitPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCacheHitPhysicalSmokeApp> createState() =>
      _AndroidStreamingCacheHitPhysicalSmokeAppState();
}

class _AndroidStreamingCacheHitPhysicalSmokeAppState
    extends State<AndroidStreamingCacheHitPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android streaming cache hit smoke…';

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
        'runAndroidDagPhase4C6DCacheHitSmoke',
        <String, dynamic>{'maxBytes': 65536},
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C6DCacheHitSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final phaseMatch = diagMap['phase'] == 'Phase4C6D';
      final overallPass = diagMap['pass'] == true;
      final completedPrewarm = diagMap['completedPrewarm'] == true;
      final cacheReadSucceeded = diagMap['cacheReadSucceeded'] == true;
      final cacheReadBytes = (diagMap['cacheReadBytes'] as num?)?.toInt() ?? 0;
      final networkOpenCount =
          (diagMap['networkOpenCount'] as num?)?.toInt() ?? -1;
      final cacheHitProof = diagMap['cacheHitProof'] == true;
      final fullPlaybackHitProof = diagMap['fullPlaybackHitProof'] == false;
      final adaptiveSegmentGraphPrefetch =
          diagMap['adaptiveSegmentGraphPrefetch'] == false;
      final playbackMutation = diagMap['playbackMutation'] == false;
      final webRtcCache = diagMap['webRtcCache'] == false;

      pass =
          phaseMatch &&
          overallPass &&
          completedPrewarm &&
          cacheReadSucceeded &&
          cacheReadBytes > 0 &&
          networkOpenCount == 0 &&
          cacheHitProof &&
          fullPlaybackHitProof &&
          adaptiveSegmentGraphPrefetch &&
          playbackMutation &&
          webRtcCache;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_HIT_PHYSICAL_ERROR: $error\n$stack',
      );
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'phase': 'Phase4C6D',
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    final rawStatus = diagMap['raw'] ?? 'unknown';

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_CACHE_HIT_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_CACHE_HIT_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_CACHE_HIT_PHYSICAL_FAIL',
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
