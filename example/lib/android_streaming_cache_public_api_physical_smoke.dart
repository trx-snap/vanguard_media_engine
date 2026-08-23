// Vanguard Android True-DAG Phase 4C6E: Public streaming cache API physical smoke test.
//
// Route:
//   VGStreamingCacheClient (Dart typed API) ->
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AndroidDagPlaybackPrewarmEngine / AndroidDagPlaybackCacheManager
//
// Platform Facts & Verification Invariants:
// - Exercises the public Dart API (VGStreamingCacheClient), NOT raw MethodChannel.
// - Starts a prewarm against a small public HLS manifest (same target as Phase 4C6C).
// - Polls until state == "succeeded" or timeout (30s).
// - Asserts bytesCached > 0 on success.
// - Calls getStatus and verifies cacheAvailable == true.
// - Cancels a missing job safely (no crash, pass == true).
// - Prints ANDROID_STREAMING_CACHE_PUBLIC_API_PHYSICAL_PASS only on full pass.
// - No playback mutation, no surface/decoder, no ExoPlayer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_streaming_cache_client.dart';

// Small public HLS manifest — same URI used by Phase 4C6C/4C6D smoke tests.
const String _kTestUri =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8';
const String _kRequestId = 'phase4c6e-smoke-prewarm-01';
const int _kMaxBytes = 2 * 1024 * 1024; // 2 MiB
const Duration _kPollTimeout = Duration(seconds: 30);
const Duration _kPollInterval = Duration(milliseconds: 800);

void main() {
  runApp(const AndroidStreamingCachePublicApiPhysicalSmokeApp());
}

class AndroidStreamingCachePublicApiPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingCachePublicApiPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCachePublicApiPhysicalSmokeApp> createState() =>
      _AndroidStreamingCachePublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingCachePublicApiPhysicalSmokeAppState
    extends State<AndroidStreamingCachePublicApiPhysicalSmokeApp> {
  String _status = 'Initializing Phase 4C6E public API smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Wait for Flutter host connection to settle.
    await Future<void>.delayed(const Duration(seconds: 1));

    final client = VGStreamingCacheClient();
    final diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      // ── Step 1: Start prewarm via public Dart API ────────────────────────
      final startResult = await client.prewarm(
        requestId: _kRequestId,
        uri: Uri.parse(_kTestUri),
        maxBytes: _kMaxBytes,
      );

      diagMap['startPhase'] = startResult.phase;
      diagMap['startState'] = startResult.state.name;
      diagMap['startPass'] = startResult.pass;
      diagMap['startRaw'] = startResult.raw;

      if (!startResult.pass ||
          startResult.state != VGPlaybackPrewarmStartState.accepted) {
        throw Exception(
          'prewarm() not accepted: state=${startResult.state.name} '
          'raw=${startResult.raw}',
        );
      }

      // ── Step 2: Poll until succeeded or timeout ──────────────────────────
      VGPlaybackPrewarmStatus? finalStatus;
      final deadline = DateTime.now().add(_kPollTimeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(_kPollInterval);
        final status = await client.getPrewarmStatus(_kRequestId);
        diagMap['lastPollState'] = status.state.name;
        diagMap['lastBytesCached'] = status.bytesCached;
        diagMap['pollCacheAvailable'] = status.cacheAvailable;

        if (status.state == VGPlaybackPrewarmJobState.succeeded ||
            status.state == VGPlaybackPrewarmJobState.failed ||
            status.state == VGPlaybackPrewarmJobState.cancelled) {
          finalStatus = status;
          break;
        }
      }

      if (finalStatus == null) {
        throw Exception(
          'prewarm poll timed out after ${_kPollTimeout.inSeconds}s',
        );
      }

      diagMap['finalState'] = finalStatus.state.name;
      diagMap['finalBytesCached'] = finalStatus.bytesCached;
      diagMap['finalCacheAvailable'] = finalStatus.cacheAvailable;
      diagMap['finalRaw'] = finalStatus.raw;

      final prewarmSucceeded =
          finalStatus.state == VGPlaybackPrewarmJobState.succeeded;
      final bytesCachedPositive = finalStatus.bytesCached > 0;

      if (!prewarmSucceeded) {
        throw Exception(
          'prewarm final state is not succeeded: ${finalStatus.state.name}',
        );
      }
      if (!bytesCachedPositive) {
        throw Exception(
          'prewarm succeeded but bytesCached=${finalStatus.bytesCached} is not > 0',
        );
      }

      // ── Step 3: Call getStatus and verify cacheAvailable ────────────────
      final cacheStatus = await client.getStatus();
      diagMap['statusPhase'] = cacheStatus.phase;
      diagMap['statusPass'] = cacheStatus.pass;
      diagMap['statusCacheAvailable'] = cacheStatus.cacheAvailable;
      diagMap['statusState'] = cacheStatus.state;
      diagMap['statusRaw'] = cacheStatus.raw;

      if (!cacheStatus.pass || !cacheStatus.cacheAvailable) {
        throw Exception(
          'getStatus: pass=${cacheStatus.pass} cacheAvailable=${cacheStatus.cacheAvailable}',
        );
      }

      // ── Step 4: Cancel a missing job safely ─────────────────────────────
      final cancelResult = await client.cancelPrewarm(
        'phase4c6e-missing-id-99',
      );
      diagMap['cancelMissingPhase'] = cancelResult.phase;
      diagMap['cancelMissingPass'] = cancelResult.pass;
      diagMap['cancelMissingState'] = cancelResult.state;

      // Cancelling a missing job should be safe (pass == true per contract).
      if (!cancelResult.pass) {
        throw Exception(
          'cancelPrewarm(missing) returned pass=false: state=${cancelResult.state}',
        );
      }

      diagMap['phase'] = 'Phase4C6E';
      diagMap['pass'] = true;
      diagMap['raw'] =
          'status=PASS;bytesCached=${finalStatus.bytesCached};'
          'cacheAvailable=${cacheStatus.cacheAvailable}';
      pass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      diagMap['pass'] = false;
      diagMap['phase'] = 'Phase4C6E';
      diagMap['raw'] = 'status=FAIL;reason=dart_exception:$error';
      pass = false;
    }

    final rawStatus = diagMap['raw'] ?? 'unknown';

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_CACHE_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_CACHE_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_CACHE_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS (Raw=$rawStatus)' : 'FAIL: $rawStatus';
      });
    }

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
