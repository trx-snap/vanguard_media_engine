// Vanguard Android True-DAG Phase 4C6F3: Streaming cache low-storage prewarm
// admission guard physical smoke test.
//
// Route:
//   VGStreamingCacheClient (Dart typed API) ->
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator (startPlaybackCachePrewarm) ->
//   AndroidDagPlaybackStorageGuard.evaluate() ->
//   AndroidDagPlaybackPrewarmEngine (only when guard passes)
//
// Platform Facts & Verification Invariants:
// - Exercises the public Dart API (VGStreamingCacheClient), NOT raw MethodChannel.
// - Clears cache at start and in finally/cleanup.
// - BLOCKED path: prewarm with minimumFreeBytesAfterPrewarm = 1 << 62 (impossibly large);
//   expects state == blockedLowStorage and pass == false; no job should be created.
// - ALLOWED path: prewarm with minimumFreeBytesAfterPrewarm = 0 (guard disabled) and
//   a small maxBytes against the standard HLS test clip; polls until succeeded.
// - Prints ANDROID_STREAMING_CACHE_STORAGE_GUARD_PHYSICAL_PASS only after both paths pass.
// - No playback mutation, no surface/decoder, no ExoPlayer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_streaming_cache_client.dart';

// Small public HLS manifest — same URI used by Phase 4C6C/4C6D/4C6E/4C6F smoke tests.
const String _kTestUri =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8';

// Unique request IDs for this phase.
const String _kBlockedRequestId = 'phase4c6f3-storage-guard-blocked-01';
const String _kAllowedRequestId = 'phase4c6f3-storage-guard-allowed-01';

// Deliberately impossible storage reserve (1 << 62 bytes ≈ 4.6 EiB).
const int _kImpossibleMinFreeBytes = 1 << 62;

// Small maxBytes for the allowed path (64 KiB) to keep the test fast.
const int _kAllowedMaxBytes = 64 * 1024;

const Duration _kPollTimeout = Duration(seconds: 30);
const Duration _kPollInterval = Duration(milliseconds: 800);

void main() {
  runApp(const AndroidStreamingCacheStorageGuardPhysicalSmokeApp());
}

class AndroidStreamingCacheStorageGuardPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingCacheStorageGuardPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCacheStorageGuardPhysicalSmokeApp> createState() =>
      _AndroidStreamingCacheStorageGuardPhysicalSmokeAppState();
}

class _AndroidStreamingCacheStorageGuardPhysicalSmokeAppState
    extends State<AndroidStreamingCacheStorageGuardPhysicalSmokeApp> {
  String _status = 'Initializing Phase 4C6F3 storage guard smoke…';

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
    final diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      // ── Step 0: Clear cache at start ────────────────────────────────────────
      final clearStart = await client.clear();
      diagMap['clearStartPass'] = clearStart.pass;
      diagMap['clearStartState'] = clearStart.state;
      diagMap['clearStartRaw'] = clearStart.raw;
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_STORAGE_GUARD_CLEAR_START: '
        'pass=${clearStart.pass} state=${clearStart.state}',
      );

      // ── Step 1: BLOCKED path — impossible minimumFreeBytesAfterPrewarm ──────
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_STORAGE_GUARD_BLOCKED_START: '
        'requestId=$_kBlockedRequestId '
        'minimumFreeBytesAfterPrewarm=$_kImpossibleMinFreeBytes',
      );

      final blockedResult = await client.prewarm(
        requestId: _kBlockedRequestId,
        uri: Uri.parse(_kTestUri),
        maxBytes: _kAllowedMaxBytes,
        options: const VGPlaybackCacheOptions(
          minimumFreeBytesAfterPrewarm: _kImpossibleMinFreeBytes,
        ),
      );

      diagMap['blockedPhase'] = blockedResult.phase;
      diagMap['blockedState'] = blockedResult.state.name;
      diagMap['blockedPass'] = blockedResult.pass;
      diagMap['blockedStorageGuardPhase'] = blockedResult.storageGuardPhase;
      diagMap['blockedStorageGuardPass'] = blockedResult.storageGuardPass;
      diagMap['blockedAvailableBytes'] = blockedResult.availableBytes;
      diagMap['blockedRequestedBytes'] = blockedResult.requestedBytes;
      diagMap['blockedMinimumFreeBytesAfterPrewarm'] =
          blockedResult.minimumFreeBytesAfterPrewarm;
      diagMap['blockedProjectedAvailableBytes'] =
          blockedResult.projectedAvailableBytes;
      diagMap['blockedRaw'] = blockedResult.raw;

      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_STORAGE_GUARD_BLOCKED_RESULT: '
        'state=${blockedResult.state.name} pass=${blockedResult.pass} '
        'storageGuardPass=${blockedResult.storageGuardPass} '
        'availableBytes=${blockedResult.availableBytes} '
        'raw=${blockedResult.raw}',
      );

      // Verify the blocked path: must have state=blockedLowStorage and pass=false.
      if (blockedResult.pass) {
        throw Exception(
          'BLOCKED path: expected pass=false but got pass=true '
          '(state=${blockedResult.state.name})',
        );
      }
      // NOTE (Phase 4C6F3 P1): The blocked path must resolve to blockedLowStorage,
      // NOT storageGuardError. storageGuardError means the StatFs measurement itself
      // failed (e.g. no mounted path found), which would be a failure in a normal
      // connected-device smoke — not an acceptable substitute for the blocked path.
      // On a normal connected device with a real filesystem, StatFs succeeds and the
      // impossibly-large reserve (1 << 62) drives the Blocked branch.
      if (blockedResult.state !=
          VGPlaybackPrewarmStartState.blockedLowStorage) {
        throw Exception(
          'BLOCKED path: expected state=blockedLowStorage but got '
          'state=${blockedResult.state.name} raw=${blockedResult.raw}',
        );
      }
      if (blockedResult.storageGuardPass != false) {
        throw Exception(
          'BLOCKED path: expected storageGuardPass=false but got '
          'storageGuardPass=${blockedResult.storageGuardPass}',
        );
      }

      // Verify no job was created: poll prewarm status and expect notFound.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final blockedJobStatus = await client.getPrewarmStatus(
        _kBlockedRequestId,
      );
      diagMap['blockedJobStatusState'] = blockedJobStatus.state.name;
      diagMap['blockedJobBytesCached'] = blockedJobStatus.bytesCached;

      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_STORAGE_GUARD_BLOCKED_JOB_STATUS: '
        'state=${blockedJobStatus.state.name} bytesCached=${blockedJobStatus.bytesCached}',
      );

      if (blockedJobStatus.state != VGPlaybackPrewarmJobState.notFound) {
        throw Exception(
          'BLOCKED path: expected job state=notFound after blocked prewarm but got '
          'state=${blockedJobStatus.state.name} bytesCached=${blockedJobStatus.bytesCached}',
        );
      }

      diagMap['blockedPathPass'] = true;
      // ignore: avoid_print
      print('ANDROID_STREAMING_CACHE_STORAGE_GUARD_BLOCKED_PATH_PASS');

      // ── Step 2: ALLOWED path — minimumFreeBytesAfterPrewarm = 0 (guard off) ─
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_STORAGE_GUARD_ALLOWED_START: '
        'requestId=$_kAllowedRequestId minimumFreeBytesAfterPrewarm=0',
      );

      final allowedResult = await client.prewarm(
        requestId: _kAllowedRequestId,
        uri: Uri.parse(_kTestUri),
        maxBytes: _kAllowedMaxBytes,
        options: const VGPlaybackCacheOptions(minimumFreeBytesAfterPrewarm: 0),
      );

      diagMap['allowedPhase'] = allowedResult.phase;
      diagMap['allowedState'] = allowedResult.state.name;
      diagMap['allowedPass'] = allowedResult.pass;
      diagMap['allowedStorageGuardPhase'] = allowedResult.storageGuardPhase;
      diagMap['allowedStorageGuardPass'] = allowedResult.storageGuardPass;
      diagMap['allowedAvailableBytes'] = allowedResult.availableBytes;
      diagMap['allowedRaw'] = allowedResult.raw;

      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_STORAGE_GUARD_ALLOWED_RESULT: '
        'state=${allowedResult.state.name} pass=${allowedResult.pass} '
        'storageGuardPass=${allowedResult.storageGuardPass} '
        'raw=${allowedResult.raw}',
      );

      if (!allowedResult.pass ||
          allowedResult.state != VGPlaybackPrewarmStartState.accepted) {
        throw Exception(
          'ALLOWED path: expected accepted but got state=${allowedResult.state.name} '
          'pass=${allowedResult.pass} raw=${allowedResult.raw}',
        );
      }

      // Poll until the allowed prewarm succeeds.
      VGPlaybackPrewarmStatus? finalAllowedStatus;
      final deadline = DateTime.now().add(_kPollTimeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(_kPollInterval);
        final status = await client.getPrewarmStatus(_kAllowedRequestId);
        diagMap['allowedLastPollState'] = status.state.name;
        diagMap['allowedLastBytesCached'] = status.bytesCached;

        if (status.state == VGPlaybackPrewarmJobState.succeeded ||
            status.state == VGPlaybackPrewarmJobState.failed ||
            status.state == VGPlaybackPrewarmJobState.cancelled) {
          finalAllowedStatus = status;
          break;
        }
      }

      if (finalAllowedStatus == null) {
        throw Exception(
          'ALLOWED path: prewarm poll timed out after ${_kPollTimeout.inSeconds}s',
        );
      }

      diagMap['allowedFinalState'] = finalAllowedStatus.state.name;
      diagMap['allowedFinalBytesCached'] = finalAllowedStatus.bytesCached;
      diagMap['allowedFinalCacheAvailable'] = finalAllowedStatus.cacheAvailable;
      diagMap['allowedFinalRaw'] = finalAllowedStatus.raw;

      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_STORAGE_GUARD_ALLOWED_FINAL: '
        'state=${finalAllowedStatus.state.name} '
        'bytesCached=${finalAllowedStatus.bytesCached}',
      );

      if (finalAllowedStatus.state != VGPlaybackPrewarmJobState.succeeded) {
        throw Exception(
          'ALLOWED path: expected prewarm state=succeeded but got '
          '${finalAllowedStatus.state.name}',
        );
      }

      diagMap['allowedPathPass'] = true;
      // ignore: avoid_print
      print('ANDROID_STREAMING_CACHE_STORAGE_GUARD_ALLOWED_PATH_PASS');

      diagMap['phase'] = 'Phase4C6F3';
      diagMap['pass'] = true;
      diagMap['raw'] =
          'status=PASS;blockedPath=pass;allowedPath=pass;'
          'bytesCached=${finalAllowedStatus.bytesCached};'
          'availableBytes=${blockedResult.availableBytes}';
      pass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_STORAGE_GUARD_PHYSICAL_ERROR: $error\n$stack',
      );
      diagMap['pass'] = false;
      diagMap['phase'] = 'Phase4C6F3';
      diagMap['raw'] = 'status=FAIL;reason=dart_exception:$error';
      pass = false;
    } finally {
      // ── Cleanup: clear cache regardless of outcome ───────────────────────
      try {
        final clearFinal = await client.clear();
        diagMap['clearFinalPass'] = clearFinal.pass;
        diagMap['clearFinalState'] = clearFinal.state;
        // ignore: avoid_print
        print(
          'ANDROID_STREAMING_CACHE_STORAGE_GUARD_CLEAR_FINAL: '
          'pass=${clearFinal.pass} state=${clearFinal.state}',
        );
      } catch (cleanupError) {
        // ignore: avoid_print
        print(
          'ANDROID_STREAMING_CACHE_STORAGE_GUARD_CLEAR_FINAL_ERROR: $cleanupError',
        );
      }
    }

    final rawStatus = diagMap['raw'] ?? 'unknown';

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_CACHE_STORAGE_GUARD_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_CACHE_STORAGE_GUARD_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_CACHE_STORAGE_GUARD_PHYSICAL_FAIL',
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
