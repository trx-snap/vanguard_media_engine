// Vanguard Android True-DAG Phase 4C6F2: Public streaming cache status metrics physical smoke test.
//
// Route:
//   VGStreamingCacheClient (Dart typed API) ->
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AndroidDagPlaybackCacheManager (diagnosticStatus / cacheSpaceBytes / cachedResourceKeys / clearAllCachedResources)
//
// Platform Facts & Verification Invariants:
// - Exercises the public Dart API (VGStreamingCacheClient), NOT raw MethodChannel.
// - Clears cache first and asserts getStatus().cacheAvailable == true and cacheSpaceBytes >= 0.
// - Starts a prewarm against a small public HLS manifest with a unique request ID.
// - Polls until state == succeeded and bytesCached > 0.
// - Calls getStatus() and asserts cacheSpaceBytes > 0 and resourceCount > 0.
// - Calls clear() again and asserts getStatus() reflects reduced/zero cache space and resource count.
// - Prints prefix ANDROID_STREAMING_CACHE_STATUS_METRICS_PHYSICAL_JSON: and terminal marker
//   ANDROID_STREAMING_CACHE_STATUS_METRICS_PHYSICAL_PASS only on full pass.
// - No playback mutation, no surface/decoder, no ExoPlayer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_streaming_cache_client.dart';

// Small public HLS manifest — same URI used by Phase 4C6C/4C6D/4C6E/4C6F smoke tests.
const String _kTestUri =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8';

// Unique request ID for this phase so it does not collide with previous jobs.
const String _kRequestId = 'phase4c6f2-metrics-smoke-01';
const int _kMaxBytes = 2 * 1024 * 1024; // 2 MiB
const Duration _kPollTimeout = Duration(seconds: 30);
const Duration _kPollInterval = Duration(milliseconds: 800);

void main() {
  runApp(const AndroidStreamingCacheStatusMetricsPhysicalSmokeApp());
}

class AndroidStreamingCacheStatusMetricsPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingCacheStatusMetricsPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCacheStatusMetricsPhysicalSmokeApp> createState() =>
      _AndroidStreamingCacheStatusMetricsPhysicalSmokeAppState();
}

class _AndroidStreamingCacheStatusMetricsPhysicalSmokeAppState
    extends State<AndroidStreamingCacheStatusMetricsPhysicalSmokeApp> {
  String _status = 'Initializing Phase 4C6F2 status metrics smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Allow Flutter host connection to settle before first channel call.
    await Future<void>.delayed(const Duration(seconds: 1));

    final client = VGStreamingCacheClient();
    final diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      // ── Step 1: Clear cache first to establish clean baseline ─────────────
      final clearResult1 = await client.clear();
      diagMap['clear1Phase'] = clearResult1.phase;
      diagMap['clear1Pass'] = clearResult1.pass;
      diagMap['clear1State'] = clearResult1.state;
      diagMap['clear1BeforeBytes'] = clearResult1.beforeBytes;
      diagMap['clear1AfterBytes'] = clearResult1.afterBytes;

      if (!clearResult1.pass) {
        throw Exception(
          'Initial clear() returned pass=false: state=${clearResult1.state} '
          'raw=${clearResult1.raw}',
        );
      }

      // ── Step 2: Query getStatus() and assert baseline invariants ──────────
      final status1 = await client.getStatus();
      diagMap['status1Phase'] = status1.phase;
      diagMap['status1MetricsPhase'] = status1.metricsPhase;
      diagMap['status1Pass'] = status1.pass;
      diagMap['status1CacheAvailable'] = status1.cacheAvailable;
      diagMap['status1CacheSpaceBytes'] = status1.cacheSpaceBytes;
      diagMap['status1ResourceCount'] = status1.resourceCount;
      diagMap['status1Raw'] = status1.raw;

      if (!status1.pass || !status1.cacheAvailable) {
        throw Exception(
          'getStatus (baseline) returned pass=${status1.pass} '
          'cacheAvailable=${status1.cacheAvailable}',
        );
      }
      if (status1.cacheSpaceBytes < 0) {
        throw Exception(
          'getStatus (baseline) cacheSpaceBytes=${status1.cacheSpaceBytes} is negative',
        );
      }

      // ── Step 3: Prewarm the public manifest with a unique request ID ─────
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

      // ── Step 4: Poll until succeeded and bytesCached > 0 ─────────────────
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

      if (finalStatus.state != VGPlaybackPrewarmJobState.succeeded) {
        throw Exception(
          'prewarm final state is not succeeded: ${finalStatus.state.name}',
        );
      }
      if (finalStatus.bytesCached <= 0) {
        throw Exception(
          'prewarm succeeded but bytesCached=${finalStatus.bytesCached} is not > 0',
        );
      }

      // ── Step 5: Assert getStatus() reports cacheSpaceBytes > 0 & resourceCount > 0 ──
      final status2 = await client.getStatus();
      diagMap['status2Phase'] = status2.phase;
      diagMap['status2MetricsPhase'] = status2.metricsPhase;
      diagMap['status2Pass'] = status2.pass;
      diagMap['status2CacheAvailable'] = status2.cacheAvailable;
      diagMap['status2CacheSpaceBytes'] = status2.cacheSpaceBytes;
      diagMap['status2ResourceCount'] = status2.resourceCount;
      diagMap['status2Raw'] = status2.raw;

      if (!status2.pass || !status2.cacheAvailable) {
        throw Exception(
          'getStatus (after prewarm) returned pass=${status2.pass} '
          'cacheAvailable=${status2.cacheAvailable}',
        );
      }
      if (status2.cacheSpaceBytes <= 0) {
        throw Exception(
          'getStatus (after prewarm) expected cacheSpaceBytes > 0, '
          'got ${status2.cacheSpaceBytes}',
        );
      }
      if (status2.resourceCount <= 0) {
        throw Exception(
          'getStatus (after prewarm) expected resourceCount > 0, '
          'got ${status2.resourceCount}',
        );
      }

      // ── Step 6: Clear again and assert metrics decrease / zero out ────────
      final clearResult2 = await client.clear();
      diagMap['clear2Phase'] = clearResult2.phase;
      diagMap['clear2Pass'] = clearResult2.pass;
      diagMap['clear2State'] = clearResult2.state;
      diagMap['clear2BeforeBytes'] = clearResult2.beforeBytes;
      diagMap['clear2AfterBytes'] = clearResult2.afterBytes;
      diagMap['clear2ResourceCountBefore'] = clearResult2.resourceCountBefore;
      diagMap['clear2RemovedResourceCount'] = clearResult2.removedResourceCount;
      diagMap['clear2FailedResourceCount'] = clearResult2.failedResourceCount;

      if (!clearResult2.pass) {
        throw Exception(
          'Second clear() failed: state=${clearResult2.state} '
          'raw=${clearResult2.raw}',
        );
      }
      if (clearResult2.afterBytes > clearResult2.beforeBytes) {
        throw Exception(
          'Second clear() afterBytes=${clearResult2.afterBytes} > '
          'beforeBytes=${clearResult2.beforeBytes}',
        );
      }

      // ── Step 7: Final getStatus() check ───────────────────────────────────
      final status3 = await client.getStatus();
      diagMap['status3Phase'] = status3.phase;
      diagMap['status3MetricsPhase'] = status3.metricsPhase;
      diagMap['status3Pass'] = status3.pass;
      diagMap['status3CacheAvailable'] = status3.cacheAvailable;
      diagMap['status3CacheSpaceBytes'] = status3.cacheSpaceBytes;
      diagMap['status3ResourceCount'] = status3.resourceCount;
      diagMap['status3Raw'] = status3.raw;

      if (!status3.pass || !status3.cacheAvailable) {
        throw Exception(
          'getStatus (after second clear) returned pass=${status3.pass} '
          'cacheAvailable=${status3.cacheAvailable}',
        );
      }
      if (status3.cacheSpaceBytes > status2.cacheSpaceBytes) {
        throw Exception(
          'getStatus (after second clear) cacheSpaceBytes=${status3.cacheSpaceBytes} '
          '> status2 cacheSpaceBytes=${status2.cacheSpaceBytes}',
        );
      }
      if (status3.resourceCount > status2.resourceCount) {
        throw Exception(
          'getStatus (after second clear) resourceCount=${status3.resourceCount} '
          '> status2 resourceCount=${status2.resourceCount}',
        );
      }

      diagMap['phase'] = 'Phase4C6F2';
      diagMap['pass'] = true;
      diagMap['raw'] =
          'status=PASS;bytesCached=${finalStatus.bytesCached};'
          'prewarmSpace=${status2.cacheSpaceBytes};prewarmResources=${status2.resourceCount};'
          'afterClearSpace=${status3.cacheSpaceBytes};afterClearResources=${status3.resourceCount}';
      pass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_STATUS_METRICS_PHYSICAL_ERROR: $error\n$stack',
      );
      diagMap['pass'] = false;
      diagMap['phase'] = 'Phase4C6F2';
      diagMap['raw'] = 'status=FAIL;reason=dart_exception:$error';
      pass = false;
    }

    final rawStatus = diagMap['raw'] ?? 'unknown';

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_CACHE_STATUS_METRICS_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    if (pass) {
      print('ANDROID_STREAMING_CACHE_STATUS_METRICS_PHYSICAL_PASS');
    }

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
            padding: const EdgeInsets.all(24.0),
            child: Text(
              _status,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
