// Copyright (c) Connects — Vanguard Phase 4C6U.
// iOS streaming cache priority plan public API physical smoke harness.
//
// Verifies:
// 1. Definition of candidate streaming sources via VGStreamingSourceSet and VGStreamingSourceDescriptor.
// 2. Initial cache clear pass=true and status before plan pass=true, cacheAvailable=true, non-negative metrics.
// 3. Priority and budget arbitration via pure Dart VGStreamingCachePriorityPlanner.planForSourceSet
//    using the live iOS cache status, proving skipLowLatency and unknown source key warnings,
//    and budget_exceeded drop for lower priority candidates.
// 4. Dispatching only the admitted high-priority request through VGStreamingCacheClient.prewarmRequest.
// 5. Accepted start state (retry once with deterministic suffix if duplicate).
// 6. getPrewarmStatus for accepted request does not immediately return notFound before cancel.
// 7. cancelPrewarm returns pass=true and cancel_requested or not_found_or_terminal, polling until cancelled/terminal without failure.
// 8. cancelPrewarm for missing request id returns pass=true/not_found_or_terminal.
// 9. getStatus returns pass=true, cacheAvailable=true, non-negative cacheSpaceBytes and resourceCount.
// 10. Final clear in finally block must pass with failedResourceCount == 0 or smoke fails.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kHlsTestUri =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8';
const String _kLlHlsTestUri =
    'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8';
const String _kMissingRequestId = 'missing_phase4c6u_ios_phys_smoke';

const int _kSmallMaxBytes = 64 * 1024;
const Duration _kPollTimeout = Duration(seconds: 15);
const Duration _kPollInterval = Duration(milliseconds: 300);

void main() {
  runApp(const IosStreamingCachePriorityPlanPublicApiPhysicalSmokeApp());
}

class IosStreamingCachePriorityPlanPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingCachePriorityPlanPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingCachePriorityPlanPublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingCachePriorityPlanPublicApiPhysicalSmokeAppState();
}

class _IosStreamingCachePriorityPlanPublicApiPhysicalSmokeAppState
    extends State<IosStreamingCachePriorityPlanPublicApiPhysicalSmokeApp> {
  final VGStreamingCacheClient _cacheClient = VGStreamingCacheClient();
  String _status = 'Initializing Phase 4C6U iOS physical smoke…';

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
    VGStreamingCachePriorityPlan? plan;
    final diagMap = <String, dynamic>{
      'phase': 'Phase4C6U',
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
      // Step 1: Initial Clear
      if (mounted) {
        setState(() {
          _status = 'Step 1/8: Initial cache clear...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_INITIAL_CLEAR: START');
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
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_INITIAL_CLEAR: DONE');

      // Step 2: Get status before planning
      if (mounted) {
        setState(() {
          _status = 'Step 2/8: Checking cache status before planning...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_STATUS_BEFORE_PLAN: START');
      final statusBeforePlan = await runWithTimeout(
        'status_before_plan',
        _cacheClient.getStatus(),
        timeout: const Duration(seconds: 8),
      );
      diagMap['statusBeforePlanPass'] = statusBeforePlan.pass;
      diagMap['statusBeforePlanCacheAvailable'] =
          statusBeforePlan.cacheAvailable;
      diagMap['statusBeforePlanCacheSpaceBytes'] =
          statusBeforePlan.cacheSpaceBytes;
      diagMap['statusBeforePlanResourceCount'] = statusBeforePlan.resourceCount;

      if (!statusBeforePlan.pass ||
          !statusBeforePlan.cacheAvailable ||
          statusBeforePlan.cacheSpaceBytes < 0 ||
          statusBeforePlan.resourceCount < 0) {
        throw Exception(
          'Status before plan failed acceptance: pass=${statusBeforePlan.pass}, cacheAvailable=${statusBeforePlan.cacheAvailable}, space=${statusBeforePlan.cacheSpaceBytes}, count=${statusBeforePlan.resourceCount}',
        );
      }
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_STATUS_BEFORE_PLAN: DONE');

      // Step 3: Priority planning with VGStreamingCachePriorityPlanner.planForSourceSet
      if (mounted) {
        setState(() {
          _status = 'Step 3/8: Building source set and planning priorities...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_PLAN: START');

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
            key: 'backup_hls',
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

      final planRequest = VGStreamingCacheSourcePriorityPlanRequest(
        sourceSet: sourceSet,
        requestIdPrefix: 'phase4c6u_ios',
        sourceKeys: const ['hls', 'backup_hls', 'll_hls', 'missing'],
        maxBytes: _kSmallMaxBytes,
        maxTotalBytesBudget: _kSmallMaxBytes,
        lowLatencyPolicy:
            VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
        prioritiesBySourceKey: const {
          'hls': VGStreamingCachePrewarmPriority.high,
          'backup_hls': VGStreamingCachePrewarmPriority.low,
        },
        weightsBySourceKey: const {'hls': 2.0, 'backup_hls': 1.0},
        reasonsBySourceKey: const {
          'hls': 'primary_feed_playback',
          'backup_hls': 'fallback_source',
        },
        cacheStatus: statusBeforePlan,
      );

      final generatedPlan = VGStreamingCachePriorityPlanner.planForSourceSet(
        planRequest,
      );
      plan = generatedPlan;

      diagMap['admittedCount'] = plan.admittedRequests.length;
      diagMap['droppedCount'] = plan.droppedCandidates.length;
      diagMap['totalAdmittedBytes'] = plan.totalAdmittedBytes;
      diagMap['totalRequestedBytes'] = plan.totalRequestedBytes;
      diagMap['warnings'] = plan.warnings;
      diagMap['diagnostics'] = plan.diagnostics;

      // Assert plan expectations
      if (plan.admittedRequests.length != 1) {
        throw Exception(
          'Expected plan to have exactly 1 admitted request, got ${plan.admittedRequests.length}',
        );
      }
      final admittedRequest = plan.admittedRequests.single;
      if (admittedRequest.requestId != 'phase4c6u_ios_hls_0') {
        throw Exception(
          'Expected admitted requestId "phase4c6u_ios_hls_0", got "${admittedRequest.requestId}"',
        );
      }

      if (!plan.warnings.contains('low_latency_cache_constrained:ll_hls')) {
        throw Exception(
          'Expected warnings to contain "low_latency_cache_constrained:ll_hls", got ${plan.warnings}',
        );
      }
      if (!plan.warnings.contains('unknown_source_key:missing')) {
        throw Exception(
          'Expected warnings to contain "unknown_source_key:missing", got ${plan.warnings}',
        );
      }

      final droppedBackup = plan.droppedCandidates.any(
        (dc) =>
            dc.candidate.request.requestId == 'phase4c6u_ios_backup_hls_1' &&
            dc.reason == 'budget_exceeded',
      );
      if (!droppedBackup) {
        throw Exception(
          'Expected droppedCandidates to contain backup_hls with reason budget_exceeded, got ${plan.droppedCandidates}',
        );
      }

      final planDiag = plan.diagnostics;
      if (planDiag['cacheStatusProvided'] != true ||
          planDiag['admittedCount'] != 1 ||
          ((planDiag['droppedCount'] as int? ?? 0) < 1) ||
          planDiag['skippedSourceCount'] != 1 ||
          planDiag['lowLatencyPolicy'] != 'skipLowLatency' ||
          planDiag['totalAdmittedBytes'] != _kSmallMaxBytes ||
          planDiag['maxTotalBytesBudget'] != _kSmallMaxBytes) {
        throw Exception('Diagnostics assertion failed: $planDiag');
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_PLAN: DONE');

      // Step 4: Dispatch prewarmRequest
      if (mounted) {
        setState(() {
          _status = 'Step 4/8: Dispatching admitted prewarm request...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_PREWARM: START');
      var activeRequest = admittedRequest;
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
          requestId: '${admittedRequest.requestId}_retry',
          uri: admittedRequest.uri,
          httpHeaders: admittedRequest.httpHeaders,
          maxBytes: admittedRequest.maxBytes,
          options: admittedRequest.options,
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
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_PREWARM: DONE');

      // Step 5: Check prewarm status before cancel (must not return notFound)
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_STATUS_BEFORE_CANCEL: START',
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
      print(
        'IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_STATUS_BEFORE_CANCEL: DONE',
      );

      // Step 6: Cancel prewarm and poll until terminal
      if (mounted) {
        setState(() {
          _status = 'Step 5/8: Cancelling prewarm request...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_CANCEL: START');
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
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_CANCEL: DONE');

      // Step 7: Cancel for missing request ID
      if (mounted) {
        setState(() {
          _status = 'Step 6/8: Testing missing request cancellation...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_MISSING_CANCEL: START');
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
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_MISSING_CANCEL: DONE');

      // Step 8: getStatus verification
      if (mounted) {
        setState(() {
          _status = 'Step 7/8: Verifying cache status metrics...';
        });
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_STATUS: START');
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
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_STATUS: DONE');

      pass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHE_PRIORITY_PLAN_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      diagMap['error'] = error.toString();
      pass = false;
    } finally {
      // Final clear must run and be recorded
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_FINAL_CLEAR: START');
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
        print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_FINAL_CLEAR: DONE');
      } catch (e) {
        diagMap['finalClearError'] = e.toString();
        pass = false;
        // ignore: avoid_print
        print('IOS_STREAMING_CACHE_PRIORITY_PLAN_STEP_FINAL_CLEAR: ERROR ($e)');
      }
    }

    diagMap['pass'] = pass;

    final summary =
        'IOS_STREAMING_CACHE_PRIORITY_PLAN_PUBLIC_API_PHYSICAL_SUMMARY:'
        'phase=${diagMap['phase']};'
        'target=${diagMap['target']};'
        'admittedCount=${diagMap['admittedCount']};'
        'droppedCount=${diagMap['droppedCount']};'
        'initialClearPass=${diagMap['initialClearPass']};'
        'statusBeforePlanPass=${diagMap['statusBeforePlanPass']};'
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
      'IOS_STREAMING_CACHE_PRIORITY_PLAN_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );

    if (pass) {
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_CACHE_PRIORITY_PLAN_PUBLIC_API_PHYSICAL_FAIL');
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
