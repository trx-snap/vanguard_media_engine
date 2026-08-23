// Vanguard Android True-DAG Phase 4C6F: Public streaming cache lifecycle physical smoke test.
//
// Route:
//   VGStreamingCacheClient (Dart typed API) ->
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AndroidDagPlaybackCacheManager (cacheSpaceBytes / cachedResourceKeys /
//                                    clearAllCachedResources)
//
// Platform Facts & Verification Invariants:
// - Exercises the public Dart API (VGStreamingCacheClient), NOT raw MethodChannel.
// - Starts a prewarm against a small public HLS manifest with a unique request ID.
// - Polls until state == succeeded and bytesCached > 0, or times out.
// - Calls getStatus() and asserts cacheAvailable == true.
// - Calls clear() and asserts pass == true, failedResourceCount == 0,
//   afterBytes <= beforeBytes.
// - Calls getStatus() again and asserts cache remains available (even if space is now 0).
// - Prints JSON prefix ANDROID_STREAMING_CACHE_LIFECYCLE_PHYSICAL_JSON: and terminal
//   marker ANDROID_STREAMING_CACHE_LIFECYCLE_PHYSICAL_PASS only on full pass.
// - No playback mutation, no surface/decoder, no ExoPlayer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_streaming_cache_client.dart';

// Small public HLS manifest — same URI used by Phase 4C6C/4C6D/4C6E smoke tests.
const String _kTestUri =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8';

// Unique request ID for this phase so it does not collide with Phase 4C6E jobs.
const String _kRequestId = 'phase4c6f-lifecycle-smoke-01';
const int _kMaxBytes = 2 * 1024 * 1024; // 2 MiB
const Duration _kPollTimeout = Duration(seconds: 30);
const Duration _kPollInterval = Duration(milliseconds: 800);

void main() {
  runApp(const AndroidStreamingCacheLifecyclePhysicalSmokeApp());
}

class AndroidStreamingCacheLifecyclePhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingCacheLifecyclePhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCacheLifecyclePhysicalSmokeApp> createState() =>
      _AndroidStreamingCacheLifecyclePhysicalSmokeAppState();
}

class _AndroidStreamingCacheLifecyclePhysicalSmokeAppState
    extends State<AndroidStreamingCacheLifecyclePhysicalSmokeApp> {
  String _status = 'Initializing Phase 4C6F lifecycle smoke…';

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
      // ── Step 1: Prewarm the public manifest with a unique request ID ─────
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

      // ── Step 2: Poll until succeeded and bytesCached > 0 ─────────────────
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

      // ── Step 3: Call getStatus() and assert cacheAvailable == true ────────
      final statusBeforeClear = await client.getStatus();
      diagMap['statusBeforeClearPhase'] = statusBeforeClear.phase;
      diagMap['statusBeforeClearPass'] = statusBeforeClear.pass;
      diagMap['statusBeforeClearAvailable'] = statusBeforeClear.cacheAvailable;
      diagMap['statusBeforeClearState'] = statusBeforeClear.state;
      diagMap['statusBeforeClearRaw'] = statusBeforeClear.raw;

      if (!statusBeforeClear.pass || !statusBeforeClear.cacheAvailable) {
        throw Exception(
          'getStatus (before clear): pass=${statusBeforeClear.pass} '
          'cacheAvailable=${statusBeforeClear.cacheAvailable}',
        );
      }

      // ── Step 4: Call clear() and assert contract invariants ───────────────
      final clearResult = await client.clear();
      diagMap['clearPhase'] = clearResult.phase;
      diagMap['clearPass'] = clearResult.pass;
      diagMap['clearState'] = clearResult.state;
      diagMap['clearCacheAvailable'] = clearResult.cacheAvailable;
      diagMap['clearBeforeBytes'] = clearResult.beforeBytes;
      diagMap['clearAfterBytes'] = clearResult.afterBytes;
      diagMap['clearResourceCountBefore'] = clearResult.resourceCountBefore;
      diagMap['clearRemovedResourceCount'] = clearResult.removedResourceCount;
      diagMap['clearFailedResourceCount'] = clearResult.failedResourceCount;
      diagMap['clearRaw'] = clearResult.raw;

      if (!clearResult.pass) {
        throw Exception(
          'clear() returned pass=false: state=${clearResult.state} '
          'raw=${clearResult.raw}',
        );
      }

      // state must be "cleared" or "unavailable" (both are valid terminal states).
      const validClearStates = {'cleared', 'unavailable'};
      if (!validClearStates.contains(clearResult.state)) {
        throw Exception(
          'clear() unexpected state="${clearResult.state}" '
          '(expected one of: ${validClearStates.join(", ")})',
        );
      }

      if (clearResult.afterBytes > clearResult.beforeBytes) {
        throw Exception(
          'clear() afterBytes=${clearResult.afterBytes} > '
          'beforeBytes=${clearResult.beforeBytes}; expected afterBytes <= beforeBytes',
        );
      }

      if (clearResult.failedResourceCount != 0) {
        throw Exception(
          'clear() failedResourceCount=${clearResult.failedResourceCount} != 0',
        );
      }

      // ── Step 5: Call getStatus() again — cache must remain available ──────
      final statusAfterClear = await client.getStatus();
      diagMap['statusAfterClearPhase'] = statusAfterClear.phase;
      diagMap['statusAfterClearPass'] = statusAfterClear.pass;
      diagMap['statusAfterClearAvailable'] = statusAfterClear.cacheAvailable;
      diagMap['statusAfterClearState'] = statusAfterClear.state;
      diagMap['statusAfterClearRaw'] = statusAfterClear.raw;

      // Cache must remain available even when space is now 0 (the SimpleCache
      // singleton is still alive; clearing data does not destroy the cache).
      if (!statusAfterClear.pass || !statusAfterClear.cacheAvailable) {
        throw Exception(
          'getStatus (after clear): pass=${statusAfterClear.pass} '
          'cacheAvailable=${statusAfterClear.cacheAvailable} '
          '— cache must remain available after clear',
        );
      }

      diagMap['phase'] = 'Phase4C6F';
      diagMap['pass'] = true;
      diagMap['raw'] =
          'status=PASS;bytesCached=${finalStatus.bytesCached};'
          'clearState=${clearResult.state};'
          'afterBytes=${clearResult.afterBytes};'
          'cacheAvailableAfterClear=${statusAfterClear.cacheAvailable}';
      pass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_STREAMING_CACHE_LIFECYCLE_PHYSICAL_ERROR: $error\n$stack');
      diagMap['pass'] = false;
      diagMap['phase'] = 'Phase4C6F';
      diagMap['raw'] = 'status=FAIL;reason=dart_exception:$error';
      pass = false;
    }

    final rawStatus = diagMap['raw'] ?? 'unknown';

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_CACHE_LIFECYCLE_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    if (pass) {
      print('ANDROID_STREAMING_CACHE_LIFECYCLE_PHYSICAL_PASS');
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
