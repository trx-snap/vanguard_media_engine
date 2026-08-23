// Copyright (c) Connects — Vanguard Phase 4C6L.
// Android streaming cache prewarm planner public API physical smoke.
//
// Verifies:
// 1. Definition of candidate streaming sources via VGStreamingSourceSet and VGStreamingSourceDescriptor.
// 2. Planning bounded cache prewarm requests via pure Dart VGStreamingCachePrewarmPlanner.
// 3. Low-latency tagging enforcement (skipLowLatency vs allowBoundedManifestOnly).
// 4. Dispatching planned prewarm requests through VGStreamingCacheClient.prewarmRequest extension.
// 5. Polling and completing bounded prewarm job against real Media3 Android SimpleCache substrate.
// 6. Validating cache metrics (cacheSpaceBytes >= bytesCached, resourceCount >= 1) via getStatus.
// 7. Clearing cache lifecycle state before and after execution.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingCachePrewarmPlanPublicApiPhysicalSmokeApp());
}

class AndroidStreamingCachePrewarmPlanPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingCachePrewarmPlanPublicApiPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCachePrewarmPlanPublicApiPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingCachePrewarmPlanPublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingCachePrewarmPlanPublicApiPhysicalSmokeAppState
    extends State<AndroidStreamingCachePrewarmPlanPublicApiPhysicalSmokeApp> {
  final VGStreamingCacheClient _cacheClient = VGStreamingCacheClient();

  String _status =
      'Initializing Android streaming cache prewarm plan public API physical smoke…';

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

    bool pass = false;
    final diagMap = <String, dynamic>{};

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/4: Building source set and planning prewarm…';
        });
      }

      // Step 1: Build source set containing HLS, DASH, and LL-HLS descriptors
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'hls',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
            initialWidth: 1080,
            initialHeight: 1920,
            cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
          ),
          VGStreamingSourceDescriptor(
            key: 'dash',
            uri: Uri.parse(
              'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
            ),
            formatHint: VGStreamingFormatHint.dash,
            initialWidth: 1080,
            initialHeight: 1920,
            cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
          ),
          VGStreamingSourceDescriptor(
            key: 'll_hls',
            uri: Uri.parse(
              'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
            ),
            formatHint: VGStreamingFormatHint.hls,
            initialWidth: 1080,
            initialHeight: 1920,
            requireLlHlsTags: true,
          ),
        ],
      );

      // Step 2: Build plan with sourceKeys ['hls', 'll_hls'] and skipLowLatency policy
      final plan = VGStreamingCachePrewarmPlanner.planForSourceSet(
        sourceSet: sourceSet,
        requestIdPrefix: 'phase4c6l',
        sourceKeys: const ['hls', 'll_hls'],
        maxBytes: 2 * 1024 * 1024,
        lowLatencyPolicy:
            VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
      );

      diagMap['planRequestCount'] = plan.requests.length;
      diagMap['planSkippedKeys'] = plan.skippedKeys;
      diagMap['planWarnings'] = plan.warnings;
      diagMap['planDiagnostics'] = plan.diagnostics;

      // Assert plan assertions
      if (plan.requests.length != 1) {
        throw Exception(
          'Expected plan to have exactly 1 request, got ${plan.requests.length}',
        );
      }
      final prewarmReq = plan.requests.single;
      if (prewarmReq.requestId != 'phase4c6l_hls_0') {
        throw Exception(
          'Expected requestId "phase4c6l_hls_0", got "${prewarmReq.requestId}"',
        );
      }
      if (!plan.skippedKeys.contains('ll_hls')) {
        throw Exception(
          'Expected skippedKeys to contain "ll_hls", got ${plan.skippedKeys}',
        );
      }
      if (!plan.warnings.contains('low_latency_cache_constrained:ll_hls')) {
        throw Exception(
          'Expected warnings to contain "low_latency_cache_constrained:ll_hls", got ${plan.warnings}',
        );
      }

      // Step 3: Clear cache before starting
      if (mounted) {
        setState(() {
          _status = 'Step 2/4: Clearing cache and starting prewarm job…';
        });
      }

      final initialClear = await _cacheClient.clear();
      diagMap['initialClearPass'] = initialClear.pass;
      diagMap['initialClearState'] = initialClear.state;
      diagMap['initialClearCacheAvailable'] = initialClear.cacheAvailable;

      // Step 4: Dispatch prewarmRequest extension
      final startResult = await _cacheClient.prewarmRequest(prewarmReq);
      diagMap['startPhase'] = startResult.phase;
      diagMap['startState'] = startResult.state.name;
      diagMap['startPass'] = startResult.pass;
      diagMap['startRequestId'] = startResult.requestId;
      diagMap['startRaw'] = startResult.raw;

      if (startResult.state != VGPlaybackPrewarmStartState.accepted &&
          startResult.state != VGPlaybackPrewarmStartState.duplicate) {
        throw Exception(
          'prewarmRequest failed to start: state=${startResult.state.name}, raw=${startResult.raw}',
        );
      }

      // Step 5: Poll getPrewarmStatus until succeeded or timeout
      if (mounted) {
        setState(() {
          _status =
              'Step 3/4: Polling prewarm status for ${prewarmReq.requestId}…';
        });
      }

      VGPlaybackPrewarmStatus? finalStatus;
      const pollTimeout = Duration(seconds: 30);
      const pollInterval = Duration(milliseconds: 800);
      final deadline = DateTime.now().add(pollTimeout);

      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);
        final pollStatus = await _cacheClient.getPrewarmStatus(
          prewarmReq.requestId,
        );
        diagMap['lastPollState'] = pollStatus.state.name;
        diagMap['lastBytesCached'] = pollStatus.bytesCached;
        diagMap['pollCacheAvailable'] = pollStatus.cacheAvailable;

        if (pollStatus.state == VGPlaybackPrewarmJobState.succeeded ||
            pollStatus.state == VGPlaybackPrewarmJobState.failed ||
            pollStatus.state == VGPlaybackPrewarmJobState.cancelled) {
          finalStatus = pollStatus;
          break;
        }
      }

      if (finalStatus == null) {
        throw Exception('Prewarm poll timed out after 30s');
      }

      diagMap['finalState'] = finalStatus.state.name;
      diagMap['finalBytesCached'] = finalStatus.bytesCached;
      diagMap['finalCacheAvailable'] = finalStatus.cacheAvailable;
      diagMap['finalRaw'] = finalStatus.raw;

      if (finalStatus.state != VGPlaybackPrewarmJobState.succeeded) {
        throw Exception(
          'Prewarm final state is not succeeded: ${finalStatus.state.name} (${finalStatus.raw})',
        );
      }
      if (finalStatus.bytesCached <= 0) {
        throw Exception(
          'Prewarm succeeded but bytesCached is ${finalStatus.bytesCached} (expected > 0)',
        );
      }
      if (!finalStatus.cacheAvailable) {
        throw Exception('Prewarm succeeded but cacheAvailable is false');
      }

      // Step 6: Verify getStatus
      if (mounted) {
        setState(() {
          _status = 'Step 4/4: Querying cache backend metrics…';
        });
      }

      final statusMetrics = await _cacheClient.getStatus();
      diagMap['statusPhase'] = statusMetrics.phase;
      diagMap['statusPass'] = statusMetrics.pass;
      diagMap['statusCacheAvailable'] = statusMetrics.cacheAvailable;
      diagMap['statusCacheSpaceBytes'] = statusMetrics.cacheSpaceBytes;
      diagMap['statusResourceCount'] = statusMetrics.resourceCount;
      diagMap['statusRaw'] = statusMetrics.raw;

      if (!statusMetrics.pass || !statusMetrics.cacheAvailable) {
        throw Exception(
          'getStatus failed: pass=${statusMetrics.pass}, cacheAvailable=${statusMetrics.cacheAvailable}',
        );
      }
      if (statusMetrics.cacheSpaceBytes < finalStatus.bytesCached) {
        throw Exception(
          'cacheSpaceBytes (${statusMetrics.cacheSpaceBytes}) is less than bytesCached (${finalStatus.bytesCached})',
        );
      }
      if (statusMetrics.resourceCount < 1) {
        throw Exception(
          'resourceCount (${statusMetrics.resourceCount}) is less than 1',
        );
      }

      diagMap['phase'] = 'Phase4C6L';
      diagMap['pass'] = true;
      diagMap['raw'] =
          'status=PASS;bytesCached=${finalStatus.bytesCached};'
          'cacheSpaceBytes=${statusMetrics.cacheSpaceBytes};'
          'resourceCount=${statusMetrics.resourceCount}';
      pass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHE_PREWARM_PLAN_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      diagMap['pass'] = false;
      diagMap['phase'] = 'Phase4C6L';
      diagMap['raw'] = 'status=FAIL;reason=dart_exception:$error';
      pass = false;
    } finally {
      // Best-effort final cache clear
      try {
        final finalClear = await _cacheClient.clear();
        diagMap['finalClearPass'] = finalClear.pass;
        diagMap['finalClearState'] = finalClear.state;
      } catch (e) {
        diagMap['finalClearError'] = e.toString();
      }
    }

    final rawStatus = diagMap['raw'] ?? 'unknown';

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_CACHE_PREWARM_PLAN_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_CACHE_PREWARM_PLAN_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_CACHE_PREWARM_PLAN_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS (Raw=$rawStatus)' : 'FAIL: $rawStatus';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
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
