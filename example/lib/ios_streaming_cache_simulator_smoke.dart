// Vanguard iOS True-DAG Phase 4C6H: Streaming cache simulator public API smoke test.
//
// Route:
//   VGStreamingCacheClient (Dart typed public API) ->
//   MethodChannel("vanguard_media_engine") ->
//   iOS Streaming Cache Simulator Substrate / Coordinator
//
// Platform Facts & Verification Invariants:
// - iOS Simulator proof only.
// - Exercises the public Dart API (VGStreamingCacheClient), NOT raw MethodChannel.
// - Does not claim physical proof, offline playback, background completion, or real device behavior.
// - Emits prefix IOS_STREAMING_CACHE_SIMULATOR_PUBLIC_API_JSON: with execution metrics.
// - Terminal pass marker: IOS_STREAMING_CACHE_SIMULATOR_PUBLIC_API_PASS on exit(0).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_streaming_cache_client.dart';

const String _kHlsTestUri =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8';
const String _kMpdTestUri = 'https://example.com/live/manifest.mpd';

const String _kBlockedRequestId = 'phase4c6h-ios-sim-blocked-01';
const String _kMpdRequestId = 'phase4c6h-ios-sim-mpd-01';
const String _kHlsRequestId = 'phase4c6h-ios-sim-hls-01';
const String _kMissingRequestId = 'missing-ios-sim-smoke';

const int _kImpossibleMinFreeBytes = 1 << 62;
const int _kSmallMaxBytes = 64 * 1024;

const Duration _kPollTimeout = Duration(seconds: 15);
const Duration _kPollInterval = Duration(milliseconds: 300);

void main() {
  runApp(const IosStreamingCacheSimulatorSmokeApp());
}

class IosStreamingCacheSimulatorSmokeApp extends StatefulWidget {
  const IosStreamingCacheSimulatorSmokeApp({super.key});

  @override
  State<IosStreamingCacheSimulatorSmokeApp> createState() =>
      _IosStreamingCacheSimulatorSmokeAppState();
}

class _IosStreamingCacheSimulatorSmokeAppState
    extends State<IosStreamingCacheSimulatorSmokeApp> {
  String _status = 'Initializing Phase 4C6H iOS simulator smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Allow Flutter host connection to settle.
    await Future<void>.delayed(const Duration(seconds: 1));

    final client = VGStreamingCacheClient();
    final diagMap = <String, dynamic>{
      'phase': 'Phase4C6H',
      'target': 'ios_simulator',
    };
    bool pass = false;

    try {
      // ── Step 1: getStatus() contract check ──────────────────────────────────
      final statusResult = await client.getStatus();
      diagMap['statusPhase'] = statusResult.phase;
      diagMap['statusPass'] = statusResult.pass;
      diagMap['statusCacheAvailable'] = statusResult.cacheAvailable;
      diagMap['statusState'] = statusResult.state;
      diagMap['statusCacheSpaceBytes'] = statusResult.cacheSpaceBytes;
      diagMap['statusResourceCount'] = statusResult.resourceCount;
      diagMap['statusRaw'] = statusResult.raw;

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_SIMULATOR_GET_STATUS: '
        'pass=${statusResult.pass} cacheAvailable=${statusResult.cacheAvailable} '
        'state=${statusResult.state} space=${statusResult.cacheSpaceBytes} '
        'count=${statusResult.resourceCount}',
      );

      if (!statusResult.pass ||
          !statusResult.cacheAvailable ||
          statusResult.state != 'available' ||
          statusResult.cacheSpaceBytes < 0 ||
          statusResult.resourceCount < 0) {
        throw Exception(
          'Step 1 failed getStatus() acceptance: pass=${statusResult.pass}, '
          'cacheAvailable=${statusResult.cacheAvailable}, state=${statusResult.state}, '
          'cacheSpaceBytes=${statusResult.cacheSpaceBytes}, resourceCount=${statusResult.resourceCount}',
        );
      }

      // ── Step 2: prewarm() blockedLowStorage guard check ─────────────────────
      final blockedResult = await client.prewarm(
        requestId: _kBlockedRequestId,
        uri: Uri.parse(_kHlsTestUri),
        maxBytes: _kSmallMaxBytes,
        options: const VGPlaybackCacheOptions(
          minimumFreeBytesAfterPrewarm: _kImpossibleMinFreeBytes,
        ),
      );

      diagMap['blockedPass'] = blockedResult.pass;
      diagMap['blockedState'] = blockedResult.state.name;
      diagMap['blockedStorageGuardPass'] = blockedResult.storageGuardPass;
      diagMap['blockedRaw'] = blockedResult.raw;

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_SIMULATOR_BLOCKED_RESULT: '
        'state=${blockedResult.state.name} pass=${blockedResult.pass} '
        'storageGuardPass=${blockedResult.storageGuardPass}',
      );

      if (blockedResult.pass ||
          blockedResult.state !=
              VGPlaybackPrewarmStartState.blockedLowStorage ||
          blockedResult.storageGuardPass != false) {
        throw Exception(
          'Step 2 failed prewarm() blockedLowStorage acceptance: pass=${blockedResult.pass}, '
          'state=${blockedResult.state.name}, storageGuardPass=${blockedResult.storageGuardPass}',
        );
      }

      // Polling blocked requestId must return notFound.
      final blockedJobStatus = await client.getPrewarmStatus(
        _kBlockedRequestId,
      );
      diagMap['blockedJobState'] = blockedJobStatus.state.name;

      if (blockedJobStatus.state != VGPlaybackPrewarmJobState.notFound) {
        throw Exception(
          'Step 2 failed getPrewarmStatus() on blocked requestId: '
          'expected notFound but got ${blockedJobStatus.state.name}',
        );
      }

      // ── Step 3: prewarm() invalid MPD check ─────────────────────────────────
      final mpdResult = await client.prewarm(
        requestId: _kMpdRequestId,
        uri: Uri.parse(_kMpdTestUri),
        maxBytes: _kSmallMaxBytes,
      );

      diagMap['mpdPass'] = mpdResult.pass;
      diagMap['mpdState'] = mpdResult.state.name;
      diagMap['mpdRaw'] = mpdResult.raw;

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_SIMULATOR_MPD_RESULT: '
        'state=${mpdResult.state.name} pass=${mpdResult.pass}',
      );

      if (mpdResult.pass ||
          mpdResult.state != VGPlaybackPrewarmStartState.invalid) {
        throw Exception(
          'Step 3 failed prewarm() MPD check: pass=${mpdResult.pass}, '
          'state=${mpdResult.state.name}',
        );
      }

      // ── Step 4: prewarm() HLS accept + immediate cancelPrewarm() ────────────
      final hlsResult = await client.prewarm(
        requestId: _kHlsRequestId,
        uri: Uri.parse(_kHlsTestUri),
        maxBytes: _kSmallMaxBytes,
        options: const VGPlaybackCacheOptions(minimumFreeBytesAfterPrewarm: 0),
      );

      diagMap['hlsPrewarmPass'] = hlsResult.pass;
      diagMap['hlsPrewarmState'] = hlsResult.state.name;
      diagMap['hlsPrewarmRaw'] = hlsResult.raw;

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_SIMULATOR_HLS_PREWARM_RESULT: '
        'state=${hlsResult.state.name} pass=${hlsResult.pass}',
      );

      if (!hlsResult.pass ||
          hlsResult.state != VGPlaybackPrewarmStartState.accepted) {
        throw Exception(
          'Step 4 failed prewarm() accepted check: pass=${hlsResult.pass}, '
          'state=${hlsResult.state.name}',
        );
      }

      final cancelResult = await client.cancelPrewarm(_kHlsRequestId);
      diagMap['cancelPass'] = cancelResult.pass;
      diagMap['cancelState'] = cancelResult.state;
      diagMap['cancelRaw'] = cancelResult.raw;

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_SIMULATOR_CANCEL_RESULT: '
        'state=${cancelResult.state} pass=${cancelResult.pass}',
      );

      if (!cancelResult.pass || cancelResult.state != 'cancel_requested') {
        throw Exception(
          'Step 4 failed cancelPrewarm() check: pass=${cancelResult.pass}, '
          'state=${cancelResult.state}',
        );
      }

      // Poll until cancelled; notFound indicates terminal cancellation retention regressed.
      VGPlaybackPrewarmStatus? finalCancelledStatus;
      final deadline = DateTime.now().add(_kPollTimeout);
      while (DateTime.now().isBefore(deadline)) {
        final pollStatus = await client.getPrewarmStatus(_kHlsRequestId);
        diagMap['pollCancelState'] = pollStatus.state.name;
        if (pollStatus.state == VGPlaybackPrewarmJobState.notFound) {
          throw Exception(
            'Step 4 failed: terminal cancellation retention regressed for "$_kHlsRequestId" (returned notFound)',
          );
        }
        if (pollStatus.state == VGPlaybackPrewarmJobState.cancelled) {
          finalCancelledStatus = pollStatus;
          break;
        }
        await Future<void>.delayed(_kPollInterval);
      }

      if (finalCancelledStatus == null) {
        throw Exception(
          'Step 4 timed out waiting for cancelled state after cancellation',
        );
      }

      diagMap['finalCancelledJobState'] = finalCancelledStatus.state.name;
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_SIMULATOR_CANCELLED_JOB_STATUS: '
        'state=${finalCancelledStatus.state.name}',
      );

      // ── Step 5: cancelPrewarm(missingRequestId) check ────────────────────────
      final missingCancelResult = await client.cancelPrewarm(
        _kMissingRequestId,
      );
      diagMap['missingCancelPass'] = missingCancelResult.pass;
      diagMap['missingCancelState'] = missingCancelResult.state;
      diagMap['missingCancelRaw'] = missingCancelResult.raw;

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_SIMULATOR_MISSING_CANCEL_RESULT: '
        'state=${missingCancelResult.state} pass=${missingCancelResult.pass}',
      );

      if (!missingCancelResult.pass ||
          missingCancelResult.state != 'not_found_or_terminal') {
        throw Exception(
          'Step 5 failed cancelPrewarm("$_kMissingRequestId"): '
          'pass=${missingCancelResult.pass}, state=${missingCancelResult.state}',
        );
      }

      // ── Step 6: clear() check ────────────────────────────────────────────────
      final clearResult = await client.clear();
      diagMap['clearPass'] = clearResult.pass;
      diagMap['clearState'] = clearResult.state;
      diagMap['clearBeforeBytes'] = clearResult.beforeBytes;
      diagMap['clearAfterBytes'] = clearResult.afterBytes;
      diagMap['clearFailedResourceCount'] = clearResult.failedResourceCount;
      diagMap['clearRaw'] = clearResult.raw;

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_SIMULATOR_CLEAR_RESULT: '
        'pass=${clearResult.pass} state=${clearResult.state} '
        'beforeBytes=${clearResult.beforeBytes} afterBytes=${clearResult.afterBytes} '
        'failedCount=${clearResult.failedResourceCount}',
      );

      if (!clearResult.pass ||
          clearResult.failedResourceCount != 0 ||
          clearResult.afterBytes > clearResult.beforeBytes) {
        throw Exception(
          'Step 6 failed clear() acceptance: pass=${clearResult.pass}, '
          'failedResourceCount=${clearResult.failedResourceCount}, '
          'beforeBytes=${clearResult.beforeBytes}, afterBytes=${clearResult.afterBytes}',
        );
      }

      diagMap['pass'] = true;
      pass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_SIMULATOR_PUBLIC_API_ERROR: $error\n$stack');
      diagMap['pass'] = false;
      diagMap['error'] = error.toString();
      pass = false;
    }

    // ignore: avoid_print
    print(
      'IOS_STREAMING_CACHE_SIMULATOR_PUBLIC_API_JSON:${jsonEncode(diagMap)}',
    );

    if (pass) {
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_SIMULATOR_PUBLIC_API_PASS');
    }

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: ${diagMap['error']}';
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
