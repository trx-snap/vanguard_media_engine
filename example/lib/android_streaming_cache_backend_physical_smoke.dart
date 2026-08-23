// Vanguard Android True-DAG Phase 4C6B: Playback cache backend physical smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AndroidDagPlaybackCacheSmokeHarness.run() ->
//   AndroidDagPlaybackCacheManager.getOrCreate() & SimpleCache / DataSource.Factory
//
// Platform Facts & Verification Invariants:
// - Verifies AndroidX Media3 SimpleCache singleton directory ownership and fallback DataSource creation.
// - Default playback remains cache-disabled (cacheEnabledDefault == false).
// - Smoke leg exercises cache initialization and factory creation (cacheEnabledSmoke == true).
// - Fallback on error is guaranteed (fallbackOnError == true).
// - No network fetching, no playback mutation, no surface/decoder creation in this harness.
// - Prewarm is deferred to Phase 4C6C (prewarmImplemented == false).
// - WebRTC/LiveKit caching is excluded per ADR-AND-10 (webRtcCache == false).
// - Physical pass requires: phase == "Phase4C6B", pass == true, cacheEnabledDefault == false,
//   cacheEnabledSmoke == true, fallbackOnError == true, playbackMutation == false,
//   prewarmImplemented == false, webRtcCache == false.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidStreamingCacheBackendPhysicalSmokeApp());
}

class AndroidStreamingCacheBackendPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingCacheBackendPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCacheBackendPhysicalSmokeApp> createState() =>
      _AndroidStreamingCacheBackendPhysicalSmokeAppState();
}

class _AndroidStreamingCacheBackendPhysicalSmokeAppState
    extends State<AndroidStreamingCacheBackendPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android streaming cache backend smoke…';

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
        'runAndroidDagPhase4C6BPlaybackCacheBackendSmoke',
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C6BPlaybackCacheBackendSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final phaseMatch = diagMap['phase'] == 'Phase4C6B';
      final overallPass = diagMap['pass'] == true;
      final cacheEnabledDefault = diagMap['cacheEnabledDefault'] == false;
      final cacheEnabledSmoke = diagMap['cacheEnabledSmoke'] == true;
      final fallbackOnError = diagMap['fallbackOnError'] == true;
      final playbackMutation = diagMap['playbackMutation'] == false;
      final prewarmImplemented = diagMap['prewarmImplemented'] == false;
      final webRtcCache = diagMap['webRtcCache'] == false;

      pass =
          phaseMatch &&
          overallPass &&
          cacheEnabledDefault &&
          cacheEnabledSmoke &&
          fallbackOnError &&
          playbackMutation &&
          prewarmImplemented &&
          webRtcCache;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_BACKEND_PHYSICAL_ERROR: $error\n$stack',
      );
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'phase': 'Phase4C6B',
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    final cacheAvailable = diagMap['cacheAvailable'] ?? false;
    final rawStatus = diagMap['raw'] ?? 'unknown';

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_CACHE_BACKEND_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_CACHE_BACKEND_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_CACHE_BACKEND_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (CacheAvailable=$cacheAvailable, Raw=$rawStatus)'
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
