// Copyright (c) Connects — Vanguard Phase 4C6T.
// iOS streaming cache prewarm planner public API physical smoke harness.
//
// Verifies:
// 1. Definition of candidate streaming sources via VGStreamingSourceSet and VGStreamingSourceDescriptor.
// 2. Planning bounded cache prewarm requests via pure Dart VGStreamingCachePrewarmPlanner.
// 3. Low-latency tagging enforcement (skipLowLatency policy skips ll_hls).
// 4. Dispatching planned prewarm requests through VGStreamingCacheClient.prewarmRequest extension.
// 5. Initial clear pass=true.
// 6. prewarmRequest(plannedRequest) returns pass=true and accepted state (retry once with deterministic suffix if duplicate).
// 7. getPrewarmStatus for accepted request does not immediately return notFound before cancel.
// 8. cancelPrewarm returns pass=true and cancel_requested or not_found_or_terminal, polling until cancelled (or succeeded/cancelled if OS finished early).
// 9. cancelPrewarm for missing request id returns pass=true/not_found_or_terminal.
// 10. getStatus returns pass=true, cacheAvailable=true, non-negative cacheSpaceBytes and resourceCount.
// 11. Final clear in finally block must pass or smoke fails.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kHlsTestUri =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8';
const String _kLlHlsTestUri =
    'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8';
const String _kMissingRequestId = 'missing_phase4c6t_ios_phys_smoke';

const int _kSmallMaxBytes = 64 * 1024;
const Duration _kPollTimeout = Duration(seconds: 15);
const Duration _kPollInterval = Duration(milliseconds: 300);

void main() {
  runApp(const IosStreamingCachePrewarmPlanPublicApiPhysicalSmokeApp());
}

class IosStreamingCachePrewarmPlanPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingCachePrewarmPlanPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingCachePrewarmPlanPublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingCachePrewarmPlanPublicApiPhysicalSmokeAppState();
}

class _IosStreamingCachePrewarmPlanPublicApiPhysicalSmokeAppState
    extends State<IosStreamingCachePrewarmPlanPublicApiPhysicalSmokeApp> {
  final VGStreamingCacheClient _cacheClient = VGStreamingCacheClient();
  String _status = 'Initializing Phase 4C6T iOS physical smoke…';

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

    bool pass = false;
    VGStreamingCachePrewarmPlan? plan;
    final diagMap = <String, dynamic>{
      'phase': 'Phase4C6T',
      'target': 'ios_physical',
    };

    Future<T> runWithTimeout<T>(
      String stepName,
      Future<T> future, {
      Duration timeout = const Duration(seconds: 8),
    }) async {
      try {
        return await future.timeout(timeout);
      } on TimeoutException {
        diagMap['timeoutStep'] = stepName;
        throw TimeoutException(
          'Timeout after ${timeout.inSeconds}s at step $stepName',
          timeout,
        );
      }
    }

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/6: Building source set and planning prewarm...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_PLAN: START');

      // Step 1: Build source set containing HLS and LL-HLS descriptors
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'hls',
            uri: Uri.parse(_kHlsTestUri),
            formatHint: VGStreamingFormatHint.hls,
            initialWidth: 1080,
            initialHeight: 1920,
            cacheOptions: const VGPlaybackCacheOptions(
              cacheEnabled: true,
              minimumFreeBytesAfterPrewarm: 0,
            ),
          ),
          VGStreamingSourceDescriptor(
            key: 'll_hls',
            uri: Uri.parse(_kLlHlsTestUri),
            formatHint: VGStreamingFormatHint.hls,
            initialWidth: 1080,
            initialHeight: 1920,
            requireLlHlsTags: true,
          ),
        ],
      );

      // Step 2: Build plan with sourceKeys ['hls', 'll_hls'], prefix 'phase4c6t_ios', maxBytes 64KB, skipLowLatency, minFreeBytes 0
      final generatedPlan = VGStreamingCachePrewarmPlanner.planForSourceSet(
        sourceSet: sourceSet,
        requestIdPrefix: 'phase4c6t_ios',
        sourceKeys: const ['hls', 'll_hls'],
        maxBytes: _kSmallMaxBytes,
        lowLatencyPolicy:
            VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
        options: const VGPlaybackCacheOptions(minimumFreeBytesAfterPrewarm: 0),
      );
      plan = generatedPlan;

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
      final plannedRequest = plan.requests.single;
      if (plannedRequest.requestId != 'phase4c6t_ios_hls_0') {
        throw Exception(
          'Expected requestId "phase4c6t_ios_hls_0", got "${plannedRequest.requestId}"',
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

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_PLAN: DONE');

      // Step 3: Clear cache before starting
      if (mounted) {
        setState(() {
          _status = 'Step 2/6: Clearing cache before prewarm...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_INITIAL_CLEAR: START');
      final initialClear = await runWithTimeout(
        'initial_clear',
        _cacheClient.clear(),
        timeout: const Duration(seconds: 8),
      );
      diagMap['initialClearPass'] = initialClear.pass;
      diagMap['initialClearState'] = initialClear.state;
      diagMap['initialClearCacheAvailable'] = initialClear.cacheAvailable;

      if (!initialClear.pass) {
        throw Exception(
          'Initial cache clear failed: state=${initialClear.state}, raw=${initialClear.raw}',
        );
      }
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_INITIAL_CLEAR: DONE');

      // Step 4: Dispatch prewarmRequest extension
      if (mounted) {
        setState(() {
          _status = 'Step 3/6: Dispatching planned prewarm request...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_PREWARM: START');
      var activeRequest = plannedRequest;
      var startResult = await runWithTimeout(
        'prewarm_request',
        _cacheClient.prewarmRequest(activeRequest),
        timeout: const Duration(seconds: 12),
      );
      diagMap['startPhase'] = startResult.phase;
      diagMap['startState'] = startResult.state.name;
      diagMap['startPass'] = startResult.pass;
      diagMap['startRequestId'] = startResult.requestId;
      diagMap['startRaw'] = startResult.raw;

      if (startResult.state == VGPlaybackPrewarmStartState.duplicate) {
        // Clear and retry once with deterministic suffix
        await runWithTimeout(
          'prewarm_retry_clear',
          _cacheClient.clear(),
          timeout: const Duration(seconds: 8),
        );
        activeRequest = VGPlaybackPrewarmRequest(
          requestId: '${plannedRequest.requestId}_retry',
          uri: plannedRequest.uri,
          httpHeaders: plannedRequest.httpHeaders,
          maxBytes: plannedRequest.maxBytes,
          options: plannedRequest.options,
        );
        startResult = await runWithTimeout(
          'prewarm_retry_request',
          _cacheClient.prewarmRequest(activeRequest),
          timeout: const Duration(seconds: 12),
        );
        diagMap['retryStartState'] = startResult.state.name;
        diagMap['retryStartPass'] = startResult.pass;
        diagMap['retryStartRequestId'] = startResult.requestId;
        diagMap['retryStartRaw'] = startResult.raw;
      }

      if (!startResult.pass ||
          startResult.state != VGPlaybackPrewarmStartState.accepted) {
        throw Exception(
          'prewarmRequest failed: pass=${startResult.pass}, state=${startResult.state.name}, raw=${startResult.raw}',
        );
      }
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_PREWARM: DONE');

      // Step 5: Check prewarm status before cancel (must not immediately return notFound)
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_STATUS_BEFORE_CANCEL: START',
      );
      final statusBeforeCancel = await runWithTimeout(
        'status_before_cancel',
        _cacheClient.getPrewarmStatus(activeRequest.requestId),
        timeout: const Duration(seconds: 8),
      );
      diagMap['statusBeforeCancelState'] = statusBeforeCancel.state.name;
      if (statusBeforeCancel.state == VGPlaybackPrewarmJobState.notFound) {
        throw Exception(
          'getPrewarmStatus for accepted request returned notFound before cancellation',
        );
      }
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_STATUS_BEFORE_CANCEL: DONE');

      // Step 6: Cancel prewarm and poll until terminal
      if (mounted) {
        setState(() {
          _status = 'Step 4/6: Cancelling prewarm request...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_CANCEL: START');
      final cancelResult = await runWithTimeout(
        'cancel_prewarm',
        _cacheClient.cancelPrewarm(activeRequest.requestId),
        timeout: const Duration(seconds: 8),
      );
      diagMap['cancelPass'] = cancelResult.pass;
      diagMap['cancelState'] = cancelResult.state;
      diagMap['cancelRaw'] = cancelResult.raw;

      if (!cancelResult.pass ||
          (cancelResult.state != 'cancel_requested' &&
              cancelResult.state != 'not_found_or_terminal')) {
        throw Exception(
          'cancelPrewarm failed: pass=${cancelResult.pass}, state=${cancelResult.state}, raw=${cancelResult.raw}',
        );
      }

      if (cancelResult.state == 'cancel_requested') {
        VGPlaybackPrewarmStatus? finalPollStatus;
        final deadline = DateTime.now().add(_kPollTimeout);
        while (DateTime.now().isBefore(deadline)) {
          final pollStatus = await runWithTimeout(
            'poll_cancel_status',
            _cacheClient.getPrewarmStatus(activeRequest.requestId),
            timeout: const Duration(seconds: 8),
          );
          diagMap['lastPollCancelState'] = pollStatus.state.name;
          if (pollStatus.state == VGPlaybackPrewarmJobState.failed) {
            throw Exception(
              'Prewarm job entered failed state during cancellation: raw=${pollStatus.raw}',
            );
          }
          if (pollStatus.state == VGPlaybackPrewarmJobState.cancelled ||
              pollStatus.state == VGPlaybackPrewarmJobState.succeeded) {
            finalPollStatus = pollStatus;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (finalPollStatus == null) {
          throw Exception('Timed out waiting for cancelled/terminal state');
        }
        diagMap['finalPollState'] = finalPollStatus.state.name;
      } else {
        // not_found_or_terminal: verify status is terminal succeeded or cancelled (any failed is a failure)
        final terminalStatus = await runWithTimeout(
          'status_after_immediate_cancel',
          _cacheClient.getPrewarmStatus(activeRequest.requestId),
          timeout: const Duration(seconds: 8),
        );
        diagMap['immediateTerminalState'] = terminalStatus.state.name;
        if (terminalStatus.state == VGPlaybackPrewarmJobState.failed) {
          throw Exception(
            'Prewarm job is in failed state: raw=${terminalStatus.raw}',
          );
        }
      }
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_CANCEL: DONE');

      // Step 7: Cancel for missing request ID
      if (mounted) {
        setState(() {
          _status = 'Step 5/6: Testing missing request cancellation...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_MISSING_CANCEL: START');
      final missingCancelResult = await runWithTimeout(
        'missing_cancel',
        _cacheClient.cancelPrewarm(_kMissingRequestId),
        timeout: const Duration(seconds: 8),
      );
      diagMap['missingCancelPass'] = missingCancelResult.pass;
      diagMap['missingCancelState'] = missingCancelResult.state;
      diagMap['missingCancelRaw'] = missingCancelResult.raw;

      if (!missingCancelResult.pass ||
          missingCancelResult.state != 'not_found_or_terminal') {
        throw Exception(
          'cancelPrewarm for missing ID failed: pass=${missingCancelResult.pass}, state=${missingCancelResult.state}',
        );
      }
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_MISSING_CANCEL: DONE');

      // Step 8: getStatus verification
      if (mounted) {
        setState(() {
          _status = 'Step 6/6: Verifying cache status metrics...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_STATUS: START');
      final statusMetrics = await runWithTimeout(
        'get_status',
        _cacheClient.getStatus(),
        timeout: const Duration(seconds: 8),
      );
      diagMap['statusPhase'] = statusMetrics.phase;
      diagMap['statusPass'] = statusMetrics.pass;
      diagMap['statusCacheAvailable'] = statusMetrics.cacheAvailable;
      diagMap['statusCacheSpaceBytes'] = statusMetrics.cacheSpaceBytes;
      diagMap['statusResourceCount'] = statusMetrics.resourceCount;
      diagMap['statusRaw'] = statusMetrics.raw;

      if (!statusMetrics.pass ||
          !statusMetrics.cacheAvailable ||
          statusMetrics.cacheSpaceBytes < 0 ||
          statusMetrics.resourceCount < 0) {
        throw Exception(
          'getStatus failed acceptance: pass=${statusMetrics.pass}, cacheAvailable=${statusMetrics.cacheAvailable}, space=${statusMetrics.cacheSpaceBytes}, count=${statusMetrics.resourceCount}',
        );
      }
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_STATUS: DONE');

      pass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_PREWARM_PLAN_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      diagMap['error'] = error.toString();
      pass = false;
    } finally {
      // Final clear must run and be recorded
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_FINAL_CLEAR: START');
      try {
        final finalClear = await runWithTimeout(
          'final_clear',
          _cacheClient.clear(),
          timeout: const Duration(seconds: 8),
        );
        diagMap['finalClearPass'] = finalClear.pass;
        diagMap['finalClearState'] = finalClear.state;
        diagMap['finalClearBeforeBytes'] = finalClear.beforeBytes;
        diagMap['finalClearAfterBytes'] = finalClear.afterBytes;
        diagMap['finalClearFailedCount'] = finalClear.failedResourceCount;

        if (!finalClear.pass || finalClear.failedResourceCount != 0) {
          diagMap['finalClearFailed'] = true;
          pass = false;
        }
        // ignore: avoid_print
        print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_FINAL_CLEAR: DONE');
      } catch (e) {
        diagMap['finalClearError'] = e.toString();
        pass = false;
        // ignore: avoid_print
        print('IOS_STREAMING_CACHE_PREWARM_PLAN_STEP_FINAL_CLEAR: ERROR ($e)');
      }
    }

    diagMap['pass'] = pass;

    final summary =
        'IOS_STREAMING_CACHE_PREWARM_PLAN_PUBLIC_API_PHYSICAL_SUMMARY:'
        'phase=${diagMap['phase']};'
        'target=${diagMap['target']};'
        'planRequestCount=${diagMap['planRequestCount']};'
        'skippedLlHls=${plan?.skippedKeys.contains('ll_hls') ?? false};'
        'initialClearPass=${diagMap['initialClearPass']};'
        'startState=${diagMap['startState']};'
        'statusBeforeCancelState=${diagMap['statusBeforeCancelState']};'
        'cancelState=${diagMap['cancelState']};'
        'finalPollState=${diagMap['finalPollState']};'
        'missingCancelState=${diagMap['missingCancelState']};'
        'statusPass=${diagMap['statusPass']};'
        'cacheAvailable=${diagMap['statusCacheAvailable']};'
        'finalClearPass=${diagMap['finalClearPass']};'
        'finalClearFailedCount=${diagMap['finalClearFailedCount']};'
        'pass=$pass';
    // ignore: avoid_print
    print(summary);

    // ignore: avoid_print
    print(
      'IOS_STREAMING_CACHE_PREWARM_PLAN_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );

    if (pass) {
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PREWARM_PLAN_PUBLIC_API_PHYSICAL_FAIL');
    }

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS'
            : 'FAIL: ${diagMap['error'] ?? diagMap['finalClearError'] ?? "final_clear_failed"}';
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
