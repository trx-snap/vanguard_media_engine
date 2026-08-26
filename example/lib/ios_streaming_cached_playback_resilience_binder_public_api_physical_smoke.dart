// Copyright (c) Connects — Vanguard Phase 4C6H2G.
// iOS cached streaming playback resilience binder public API physical smoke harness.
//
// Sequentially verifies:
//   1. Initial Clear: Clears playback cache via VGStreamingCacheClient.clear() to establish
//      a clean deterministic baseline (asserting pass, state=="cleared", cacheAvailable==true,
//      failedResourceCount==0, afterBytes==0).
//   2. Source Set + Prewarm Planning: Builds VGStreamingSourceSet with 'hls' (cached) and
//      'll_hls' (low-latency, cached) and plans bounded prewarm via VGStreamingCachePrewarmPlanner.
//      Asserts exactly 1 request for 'hls', requestId 'phase4c6h2g_ios_hls_0', skippedKeys contains 'll_hls',
//      and low-latency constraint warning 'low_latency_cache_constrained:ll_hls'.
//      (Does NOT dispatch or await AVAssetDownload prewarm completion).
//   3. Preflight Advisory: Evaluates HLS manifest under CONSTRAINED network profile via
//      VGStreamingPreflightClient.evaluate(), asserting pass, advisoryOnly, playbackMutation==false, failedReports==0.
//   4. Playback Decision: Plans playback decision via VGStreamingPlaybackDecisionPlanner with
//      appleAvPlayer client capability and preferHls, asserting canOpenPlayback==true, decision=="playback_ready",
//      selectedKey=="hls", and cacheEnabled==true.
//   5. Cold Store Pass with Resilience Monitor & Binder: Creates first VGStreamingPlaybackController, opens decision,
//      renders via VGStreamingPlaybackTextureView, attaches VGStreamingPlaybackStatusPoller (300ms, emitInitialSummary),
//      attaches VGStreamingPlaybackResilienceMonitor (constrained, maxHistory 8, allowAutomaticRetry false, preserveCacheOptions true),
//      instantiates VGStreamingPlaybackResilienceCoordinator (streamKey 'phase4c6h2g_ios_hls', maxStoredAttempts 10, maxAttempts 3, windowMs 30000, minimumDelayMs 1000),
//      instantiates VGStreamingPlaybackResilienceBinder over monitor.snapshots with coordinator, VGStreamingPlaybackResilienceBinderConfig(streamKey: 'phase4c6h2g_ios_hls'), and deterministic nowProvider (+500ms),
//      starts binder idempotently (asserting isRunning true after repeated start), then starts monitor, then starts poller,
//      collects snapshots and evaluations until >= 2 snapshots and >= 2 evaluations collected, active session,
//      renderedFrames > 0, dimensions > 0, playbackCacheEnabled == true, playbackCacheTelemetryAttached == true,
//      ignored count == 0, playbackCacheSizeBytes > 0, and proxyCacheMisses > 0.
//      Asserts advisory-only and no-mutation invariants across all snapshots and binder evaluations:
//      evaluation/decision/retryBudget/journalSnapshot advisoryOnly true and playbackMutation false,
//      diagnostics streamKey equals 'phase4c6h2g_ios_hls', action in enum, length == 0, journalSnapshot count == 0,
//      and recordHostRetryAttempted is NOT called.
//      Stops and disposes binder without disposing monitor/poller/controller, stops and disposes monitor without
//      disposing poller/controller, stops and disposes poller without disposing controller, and disposes controller in finally.
//   6. Warm Hit Pass with Resilience Monitor, Binder, Controls & Lifecycle Checks: Creates a second fresh VGStreamingPlaybackController,
//      opens same decision, renders via VGStreamingPlaybackTextureView, attaches fresh poller, fresh resilience monitor,
//      fresh resilience coordinator, and fresh resilience binder, starts binder idempotently, starts monitor, starts poller,
//      collects snapshots and evaluations until >= 2 snapshots and >= 2 evaluations collected, active session,
//      renderedFrames > 0, dimensions > 0, playbackCacheEnabled == true, playbackCacheTelemetryAttached == true,
//      ignored count == 0, playbackCacheSizeBytes > 0, playbackCacheReadObserved == true at least once,
//      proxyCacheHits > 0, and proxyCacheBytesRead > 0.
//      Asserts all resilience, coordinator, and binder evaluation invariants across all events.
//      Exercises playback controls: pause(), optional seek(1000), play(), stop().
//      Performs binder lifecycle checks: stop makes isRunning false and does not dispose binder;
//      monitor.evaluateOnce while binder stopped does not increase evaluation count; binder.evaluateOnce manually
//      while stopped emits exactly one evaluation and updates latest; restart resumes stream evaluations;
//      dispose makes isDisposed true and does not dispose monitor/poller/controller or clear coordinator.
//      Verifies disposed monitor evaluateOnce returns safely with advisory-only invariants,
//      and cleanly stops and disposes monitor, poller, and controller.
//   7. Final Cleanup: Clears playback cache in finally block (asserting pass,
//      state=="cleared", cacheAvailable==true, failedResourceCount==0, afterBytes==0).
//
// Verification Invariants & Boundaries:
// - Imports ONLY pure Dart/Flutter standard libraries and package:vanguard_media_engine.
// - No direct MethodChannel or package:flutter/services.dart imports.
// - Presentation via VGStreamingPlaybackTextureView (no direct raw Flutter Texture widget).
// - Resilience monitor, health advisor, recovery planner, resilience coordinator, and resilience binder are advisory only
//   (zero mutation, no automatic retry/reopen, coordinator.length == 0, recordHostRetryAttempted NOT called).
// - All async operations bound by timeouts.
// - Guaranteed cleanup in finally blocks.
// - Non-claims: offlinePlaybackClaimed: false, zeroNetworkFetchClaimed: false,
//   avAssetDownloadCompletionClaimed: false, connectsAppPolicyClaimed: false,
//   dashPlaybackClaimed: false, webRtcCachingClaimed: false, retryExecutionClaimed: false,
//   recordHostRetryAttemptedCalled: false.
// - Structured log markers and terminal JSON payload.
// - Exit 0 on pass, exit 1 on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kHlsTestUri = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const String _kLlHlsTestUri =
    'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8';
const String _kStreamKey = 'phase4c6h2g_ios_hls';
const int _kInitialWidth = 640;
const int _kInitialHeight = 360;
const int _kPrewarmMaxBytes = 65536;

const Duration _kOperationTimeout = Duration(seconds: 25);
const Duration _kControlTimeout = Duration(seconds: 8);
const Duration _kPollInterval = Duration(milliseconds: 300);
const Duration _kStatusDeadline = Duration(seconds: 25);

void main() {
  runApp(const IosStreamingCachedPlaybackResilienceBinderPhysicalSmokeApp());
}

class IosStreamingCachedPlaybackResilienceBinderPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingCachedPlaybackResilienceBinderPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingCachedPlaybackResilienceBinderPhysicalSmokeApp>
  createState() =>
      _IosStreamingCachedPlaybackResilienceBinderPhysicalSmokeAppState();
}

class _IosStreamingCachedPlaybackResilienceBinderPhysicalSmokeAppState
    extends State<IosStreamingCachedPlaybackResilienceBinderPhysicalSmokeApp> {
  final VGStreamingCacheClient _cacheClient = VGStreamingCacheClient();
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Bootstrapping iOS cached streaming playback resilience binder physical smoke...';
  VGStreamingPlaybackControllerSnapshot _currentSnapshot =
      const VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.idle,
        pass: true,
        reason: 'idle',
      );

  @override
  void initState() {
    super.initState();
    // ignore: avoid_print
    print(
      'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_BOOTSTRAP: START',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  int _extractNumericRawToken(String raw, String key) {
    final match = RegExp('$key=(\\d+)').firstMatch(raw);
    if (match != null) {
      return int.tryParse(match.group(1)!) ?? 0;
    }
    return 0;
  }

  void _validateSnapshotInvariants(
    List<VGStreamingPlaybackResilienceSnapshot> snapshots, {
    required String passLabel,
  }) {
    if (snapshots.isEmpty) {
      throw Exception('$passLabel: no resilience snapshots collected');
    }

    for (final snap in snapshots) {
      if (!snap.advisoryOnly || snap.playbackMutation) {
        throw Exception(
          '$passLabel: snapshot advisory/mutation invariant violation '
          '(advisoryOnly=${snap.advisoryOnly}, playbackMutation=${snap.playbackMutation})',
        );
      }
      if (!snap.healthAdvice.advisoryOnly ||
          snap.healthAdvice.playbackMutation) {
        throw Exception(
          '$passLabel: health advice advisory/mutation invariant violation '
          '(advisoryOnly=${snap.healthAdvice.advisoryOnly}, playbackMutation=${snap.healthAdvice.playbackMutation})',
        );
      }
      if (!snap.recoveryPlan.advisoryOnly ||
          snap.recoveryPlan.playbackMutation) {
        throw Exception(
          '$passLabel: recovery plan advisory/mutation invariant violation '
          '(advisoryOnly=${snap.recoveryPlan.advisoryOnly}, playbackMutation=${snap.recoveryPlan.playbackMutation})',
        );
      }
      if (snap.historyLength < 1 || snap.historyLength > 8) {
        throw Exception(
          '$passLabel: snapshot historyLength out of bounds: ${snap.historyLength} (expected 1..8)',
        );
      }

      final status = snap.status;
      final durationValid = status.durationMs >= -1;
      final positionValid = status.positionMs >= 0;
      final bufferedPosValid = status.bufferedPositionMs >= 0;
      final bufferedPercentValid =
          status.bufferedPercent >= 0 && status.bufferedPercent <= 100;
      final progressFractionValid =
          status.progressFraction >= 0.0 && status.progressFraction <= 1.0;
      final bufferedFractionValid =
          status.bufferedFraction >= 0.0 && status.bufferedFraction <= 1.0;
      final cacheBytesReadValid = status.playbackCacheBytesRead >= 0;
      final cacheSizeBytesValid = status.playbackCacheSizeBytes >= 0;
      final cacheIgnoredCountValid = status.playbackCacheIgnoredCount >= 0;

      if (!durationValid ||
          !positionValid ||
          !bufferedPosValid ||
          !bufferedPercentValid ||
          !progressFractionValid ||
          !bufferedFractionValid ||
          !cacheBytesReadValid ||
          !cacheSizeBytesValid ||
          !cacheIgnoredCountValid) {
        throw Exception(
          '$passLabel: status metric bounds violation: '
          'duration=${status.durationMs}, position=${status.positionMs}, '
          'bufferedPos=${status.bufferedPositionMs}, bufferedPercent=${status.bufferedPercent}, '
          'progressFraction=${status.progressFraction}, bufferedFraction=${status.bufferedFraction}, '
          'cacheBytesRead=${status.playbackCacheBytesRead}, cacheSizeBytes=${status.playbackCacheSizeBytes}, '
          'cacheIgnoredCount=${status.playbackCacheIgnoredCount}',
        );
      }

      if (snap.recoveryPlan.diagnostics['preserveCacheOptions'] != true) {
        throw Exception(
          '$passLabel: recovery plan diagnostics preserveCacheOptions expected true, '
          'got ${snap.recoveryPlan.diagnostics['preserveCacheOptions']}',
        );
      }

      if (snap.recoveryPlan.playbackOptions != null &&
          snap.recoveryPlan.playbackOptions?.cacheOptions?.cacheEnabled !=
              true) {
        throw Exception(
          '$passLabel: recovery plan playbackOptions cacheEnabled expected true, '
          'got ${snap.recoveryPlan.playbackOptions?.cacheOptions?.cacheEnabled}',
        );
      }
    }
  }

  void _validateBinderEvaluationInvariants(
    VGStreamingPlaybackResilienceCoordinatorEvaluation evaluation,
    VGStreamingPlaybackResilienceCoordinator coordinator, {
    required String passLabel,
    required String expectedStreamKey,
  }) {
    if (!evaluation.advisoryOnly || evaluation.playbackMutation) {
      throw Exception(
        '$passLabel: binder evaluation advisory/mutation invariant violation '
        '(advisoryOnly=${evaluation.advisoryOnly}, playbackMutation=${evaluation.playbackMutation})',
      );
    }
    if (!evaluation.decision.advisoryOnly ||
        evaluation.decision.playbackMutation) {
      throw Exception(
        '$passLabel: binder decision advisory/mutation invariant violation '
        '(advisoryOnly=${evaluation.decision.advisoryOnly}, playbackMutation=${evaluation.decision.playbackMutation})',
      );
    }
    if (!evaluation.retryBudget.advisoryOnly ||
        evaluation.retryBudget.playbackMutation) {
      throw Exception(
        '$passLabel: binder retryBudget advisory/mutation invariant violation '
        '(advisoryOnly=${evaluation.retryBudget.advisoryOnly}, playbackMutation=${evaluation.retryBudget.playbackMutation})',
      );
    }
    if (!evaluation.journalSnapshot.advisoryOnly ||
        evaluation.journalSnapshot.playbackMutation) {
      throw Exception(
        '$passLabel: binder journalSnapshot advisory/mutation invariant violation '
        '(advisoryOnly=${evaluation.journalSnapshot.advisoryOnly}, playbackMutation=${evaluation.journalSnapshot.playbackMutation})',
      );
    }
    if (evaluation.diagnostics['streamKey'] != expectedStreamKey) {
      throw Exception(
        '$passLabel: binder diagnostics streamKey invariant violation: '
        '${evaluation.diagnostics['streamKey']} (expected $expectedStreamKey)',
      );
    }

    if (!VGStreamingPlaybackResilienceDecisionAction.values.contains(
      evaluation.action,
    )) {
      throw Exception(
        '$passLabel: invalid binder action: ${evaluation.action}',
      );
    }

    final evalJson = evaluation.toJson();
    if (evalJson['advisoryOnly'] != true ||
        evalJson['playbackMutation'] != false) {
      throw Exception(
        '$passLabel: binder evaluation JSON serialization invariant violated '
        '(advisoryOnly=${evalJson['advisoryOnly']}, playbackMutation=${evalJson['playbackMutation']})',
      );
    }

    if (coordinator.length != 0) {
      throw Exception(
        '$passLabel: coordinator.length was modified during binder evaluate: length=${coordinator.length} (expected 0)',
      );
    }

    if (coordinator.journalSnapshot().count != 0) {
      throw Exception(
        '$passLabel: coordinator.journalSnapshot().count was modified during binder evaluate: count=${coordinator.journalSnapshot().count} (expected 0)',
      );
    }
  }

  Future<void> _runSmoke() async {
    // Allow Flutter host connection to settle.
    await Future<void>.delayed(const Duration(seconds: 1));

    final results = <String, dynamic>{
      'phase': 'Phase4C6H2G',
      'target': 'ios_physical',
      'streamKey': _kStreamKey,
      'offlinePlaybackClaimed': false,
      'zeroNetworkFetchClaimed': false,
      'avAssetDownloadCompletionClaimed': false,
      'connectsAppPolicyClaimed': false,
      'dashPlaybackClaimed': false,
      'webRtcCachingClaimed': false,
      'retryExecutionClaimed': false,
      'recordHostRetryAttemptedCalled': false,
    };
    bool allPass = false;

    int firstMisses = 0;
    int firstHits = 0;
    int firstBytesRead = 0;
    int firstDiskSizeBytes = 0;

    int secondHits = 0;
    int secondMisses = 0;
    int secondBytesRead = 0;
    int secondDiskSizeBytes = 0;

    VGStreamingPlaybackController? firstController;
    VGStreamingPlaybackStatusPoller? firstPoller;
    VGStreamingPlaybackResilienceMonitor? firstMonitor;
    VGStreamingPlaybackResilienceCoordinator? firstCoordinator;
    VGStreamingPlaybackResilienceBinder? firstBinder;
    StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? firstMonitorSub;
    StreamSubscription<VGStreamingPlaybackResilienceCoordinatorEvaluation>?
    firstBinderSub;
    final firstCollectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
    final firstCollectedEvaluations =
        <VGStreamingPlaybackResilienceCoordinatorEvaluation>[];

    VGStreamingPlaybackController? secondController;
    VGStreamingPlaybackStatusPoller? secondPoller;
    VGStreamingPlaybackResilienceMonitor? secondMonitor;
    VGStreamingPlaybackResilienceCoordinator? secondCoordinator;
    VGStreamingPlaybackResilienceBinder? secondBinder;
    StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? secondMonitorSub;
    StreamSubscription<VGStreamingPlaybackResilienceCoordinatorEvaluation>?
    secondBinderSub;
    final secondCollectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
    final secondCollectedEvaluations =
        <VGStreamingPlaybackResilienceCoordinatorEvaluation>[];

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 1: Initial deterministic cache clear
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_INITIAL_CLEAR: START',
      );
      if (mounted) {
        setState(() {
          _status = 'Step 1/6: Clearing playback cache baseline…';
        });
      }

      final initialClear = await _cacheClient.clear().timeout(_kControlTimeout);
      results['initialClear'] = <String, dynamic>{
        'pass': initialClear.pass,
        'state': initialClear.state,
        'cacheAvailable': initialClear.cacheAvailable,
        'beforeBytes': initialClear.beforeBytes,
        'afterBytes': initialClear.afterBytes,
        'removedResourceCount': initialClear.removedResourceCount,
        'failedResourceCount': initialClear.failedResourceCount,
        'raw': initialClear.raw,
      };

      if (!initialClear.pass ||
          initialClear.state != 'cleared' ||
          !initialClear.cacheAvailable ||
          initialClear.failedResourceCount != 0 ||
          initialClear.afterBytes != 0) {
        throw Exception(
          'Initial cache clear failed acceptance: pass=${initialClear.pass}, '
          'state=${initialClear.state}, cacheAvailable=${initialClear.cacheAvailable}, '
          'failedCount=${initialClear.failedResourceCount}, afterBytes=${initialClear.afterBytes}, '
          'raw=${initialClear.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_INITIAL_CLEAR: DONE '
        '(beforeBytes=${initialClear.beforeBytes}, afterBytes=${initialClear.afterBytes})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 2: Source set + cache prewarm planner composition
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SOURCE_SET: START',
      );
      if (mounted) {
        setState(() {
          _status = 'Step 2/6: Composing source set & prewarm plan…';
        });
      }

      final hlsSource = VGStreamingSourceDescriptor(
        key: 'hls',
        uri: Uri.parse(_kHlsTestUri),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: _kInitialWidth,
        initialHeight: _kInitialHeight,
        cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
      );

      final llHlsSource = VGStreamingSourceDescriptor(
        key: 'll_hls',
        uri: Uri.parse(_kLlHlsTestUri),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: _kInitialWidth,
        initialHeight: _kInitialHeight,
        requireLlHlsTags: true,
        cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
      );

      final sourceSet = VGStreamingSourceSet(sources: [hlsSource, llHlsSource]);

      final prewarmPlan = VGStreamingCachePrewarmPlanner.planForSourceSet(
        sourceSet: sourceSet,
        requestIdPrefix: 'phase4c6h2g_ios',
        sourceKeys: const ['hls', 'll_hls'],
        maxBytes: _kPrewarmMaxBytes,
        lowLatencyPolicy:
            VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
      );

      results['prewarmPlan'] = <String, dynamic>{
        'requestCount': prewarmPlan.requests.length,
        'requestId': prewarmPlan.requests.firstOrNull?.requestId,
        'skippedKeys': prewarmPlan.skippedKeys,
        'warnings': prewarmPlan.warnings,
        'diagnostics': prewarmPlan.diagnostics,
      };

      if (prewarmPlan.requests.length != 1) {
        throw Exception(
          'Expected prewarm plan to have exactly 1 request, got ${prewarmPlan.requests.length}',
        );
      }
      final prewarmReq = prewarmPlan.requests.single;
      if (prewarmReq.requestId != 'phase4c6h2g_ios_hls_0') {
        throw Exception(
          'Expected prewarm requestId "phase4c6h2g_ios_hls_0", got "${prewarmReq.requestId}"',
        );
      }
      if (!prewarmPlan.skippedKeys.contains('ll_hls')) {
        throw Exception(
          'Expected skippedKeys to contain "ll_hls", got ${prewarmPlan.skippedKeys}',
        );
      }
      if (!prewarmPlan.warnings.contains(
        'low_latency_cache_constrained:ll_hls',
      )) {
        throw Exception(
          'Expected warnings to contain "low_latency_cache_constrained:ll_hls", got ${prewarmPlan.warnings}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SOURCE_SET: DONE',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 3: Real Native Preflight evaluation
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_PREFLIGHT: START',
      );
      if (mounted) {
        setState(() {
          _status = 'Step 3/6: Evaluating preflight advisory report…';
        });
      }

      final preflightReport = await _preflightClient
          .evaluate(
            VGStreamingPreflightRequest(
              manifests: [hlsSource.toManifestSpec()],
              requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
            ),
          )
          .timeout(_kOperationTimeout);

      results['preflight'] = <String, dynamic>{
        'pass': preflightReport.pass,
        'phase': preflightReport.phase,
        'advisoryDecision': preflightReport.advisoryDecision,
        'requestedNetworkProfile': preflightReport.requestedNetworkProfile,
        'recommendedNetworkProfile': preflightReport.recommendedNetworkProfile,
        'totalReports': preflightReport.totalReports,
        'passedReports': preflightReport.passedReports,
        'failedReports': preflightReport.failedReports,
        'advisoryOnly': preflightReport.advisoryOnly,
        'playbackMutation': preflightReport.playbackMutation,
        'warnings': preflightReport.warnings,
        'raw': preflightReport.raw,
      };

      if (!preflightReport.pass ||
          !preflightReport.advisoryOnly ||
          preflightReport.playbackMutation ||
          preflightReport.failedReports != 0) {
        throw Exception(
          'Preflight report assertion failed: pass=${preflightReport.pass}, '
          'advisoryOnly=${preflightReport.advisoryOnly}, '
          'playbackMutation=${preflightReport.playbackMutation}, '
          'failedReports=${preflightReport.failedReports}, '
          'raw=${preflightReport.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_PREFLIGHT: DONE',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 4: Playback decision planning
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_DECISION: START',
      );
      final decision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: VGStreamingSourceSet(sources: [hlsSource]),
          preflightReport: preflightReport,
          preference: VGStreamingSourceSelectionPreference.preferHls,
          preferredKeys: const ['hls'],
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      results['decision'] = <String, dynamic>{
        'canOpenPlayback': decision.canOpenPlayback,
        'decision': decision.decision,
        'selectedKey': decision.selectedKey,
        'cacheEnabled': decision.playbackOptions?.cacheOptions?.cacheEnabled,
        'warnings': decision.warnings,
        'diagnostics': decision.diagnostics,
      };

      if (!decision.canOpenPlayback ||
          decision.decision != 'playback_ready' ||
          decision.selectedKey != 'hls' ||
          decision.playbackOptions?.cacheOptions?.cacheEnabled != true) {
        throw Exception(
          'Playback decision assertion failed: canOpenPlayback=${decision.canOpenPlayback}, '
          'decision=${decision.decision}, selectedKey=${decision.selectedKey}, '
          'cacheEnabled=${decision.playbackOptions?.cacheOptions?.cacheEnabled}, '
          'warnings=${decision.warnings}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_DECISION: DONE',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 5: Cold Store Pass with Resilience Monitor & Binder
      // ═══════════════════════════════════════════════════════════════════════
      try {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_OPEN: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Step 4/6: Opening first controller, resilience monitor & binder (store path)…';
          });
        }

        firstController = VGStreamingPlaybackController();
        final firstOpenSnapshot = await firstController
            .open(decision, startPlayback: true)
            .timeout(_kOperationTimeout);

        if (!firstOpenSnapshot.pass || firstOpenSnapshot.textureId == null) {
          throw Exception(
            'First controller open failed: pass=${firstOpenSnapshot.pass}, '
            'reason=${firstOpenSnapshot.reason}, lastError=${firstOpenSnapshot.lastError}, '
            'textureId=${firstOpenSnapshot.textureId}',
          );
        }

        if (mounted) {
          setState(() {
            _currentSnapshot = firstOpenSnapshot;
            _status =
                'First playback active (textureId=${firstOpenSnapshot.textureId}), collecting store resilience events…';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_OPEN: DONE '
          '(textureId=${firstOpenSnapshot.textureId})',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_MONITOR_BINDER_START: START',
        );

        firstPoller = VGStreamingPlaybackStatusPoller(
          controller: firstController,
          config: VGStreamingPlaybackStatusPollerConfig(
            interval: const Duration(milliseconds: 300),
            emitInitialSummary: true,
          ),
        );

        firstMonitor = VGStreamingPlaybackResilienceMonitor(
          summaries: firstPoller.summaries,
          config: VGStreamingPlaybackResilienceMonitorConfig(
            currentOptions: decision.playbackOptions,
            preflightReport: preflightReport,
            currentNetworkProfile: VGStreamingNetworkProfile.constrained,
            maxHistoryLength: 8,
            allowAutomaticRetry: false,
            preserveCacheOptions: true,
          ),
        );

        firstCoordinator = VGStreamingPlaybackResilienceCoordinator(
          config: const VGStreamingPlaybackResilienceCoordinatorConfig(
            journalConfig: VGStreamingPlaybackRetryJournalConfig(
              maxStoredAttempts: 10,
            ),
            retryBudgetConfig: VGStreamingPlaybackRetryBudgetConfig(
              maxAttempts: 3,
              windowMs: 30000,
              minimumDelayMs: 1000,
            ),
            streamKey: _kStreamKey,
          ),
        );

        int firstNowMs = 1700000000000;
        int firstDeterministicNow() {
          firstNowMs += 500;
          return firstNowMs;
        }

        firstBinder = VGStreamingPlaybackResilienceBinder(
          snapshots: firstMonitor.snapshots,
          coordinator: firstCoordinator,
          config: const VGStreamingPlaybackResilienceBinderConfig(
            streamKey: _kStreamKey,
          ),
          nowProvider: firstDeterministicNow,
        );

        firstBinderSub = firstBinder.evaluations.listen((evaluation) {
          firstCollectedEvaluations.add(evaluation);
        });

        firstMonitorSub = firstMonitor.snapshots.listen((snapshot) {
          firstCollectedSnapshots.add(snapshot);
          if (mounted &&
              firstController != null &&
              !firstController.isDisposed) {
            setState(() {
              _currentSnapshot = firstController!.snapshot;
            });
          }
        });

        // Start binder idempotently before starting monitor and poller
        firstBinder.start();
        if (!firstBinder.isRunning) {
          throw Exception('First binder failed to start (isRunning is false)');
        }
        firstBinder.start();
        if (!firstBinder.isRunning) {
          throw Exception(
            'First binder failed repeated start (isRunning is false)',
          );
        }

        // Start monitor, then poller
        firstMonitor.start();
        firstPoller.start();

        if (!firstMonitor.isRunning) {
          throw Exception('First monitor failed to start (isRunning is false)');
        }
        if (!firstPoller.isRunning) {
          throw Exception('First poller failed to start (isRunning is false)');
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_MONITOR_BINDER_START: DONE',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_MONITOR_BINDER_COLLECT: START',
        );

        final firstDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackResilienceSnapshot? firstFinalSnapshot;

        while (DateTime.now().isBefore(firstDeadline)) {
          await Future<void>.delayed(_kPollInterval);

          final latest = firstMonitor.latest;
          if (latest == null) continue;

          final currentSession = firstController.snapshot.session;
          final renderedFrames = currentSession?.renderedFrames ?? 0;
          final hasDimensions =
              latest.status.effectiveDisplayWidth > 0 &&
              latest.status.effectiveDisplayHeight > 0;
          final raw = latest.status.raw.isNotEmpty
              ? latest.status.raw
              : (currentSession?.raw ?? '');
          final misses = _extractNumericRawToken(raw, 'proxyCacheMisses');

          if (firstCollectedSnapshots.length >= 2 &&
              firstCollectedEvaluations.length >= 2 &&
              (latest.status.hasSession ||
                  firstCollectedSnapshots.any((s) => s.status.hasSession)) &&
              renderedFrames > 0 &&
              hasDimensions &&
              latest.status.playbackCacheEnabled &&
              latest.status.playbackCacheTelemetryAttached &&
              latest.status.playbackCacheIgnoredCount == 0 &&
              latest.status.playbackCacheSizeBytes > 0 &&
              misses > 0) {
            firstFinalSnapshot = latest;
            break;
          }
        }

        if (firstFinalSnapshot == null) {
          final lastLatest = firstMonitor.latest;
          final lastSnap = firstController.snapshot;
          throw Exception(
            'First controller resilience monitor/binder verification timed out: '
            'collectedSnapshots=${firstCollectedSnapshots.length}, '
            'collectedEvaluations=${firstCollectedEvaluations.length}, '
            'hasSession=${lastLatest?.status.hasSession}, '
            'renderedFrames=${lastSnap.session?.renderedFrames}, '
            'dims=${lastLatest?.status.effectiveDisplayWidth}x${lastLatest?.status.effectiveDisplayHeight}, '
            'cacheEnabled=${lastLatest?.status.playbackCacheEnabled}, '
            'cacheTelemetryAttached=${lastLatest?.status.playbackCacheTelemetryAttached}, '
            'cacheSizeBytes=${lastLatest?.status.playbackCacheSizeBytes}, '
            'ignoredCount=${lastLatest?.status.playbackCacheIgnoredCount}, '
            'raw=${lastLatest?.status.raw}',
          );
        }

        // Validate invariants on all collected snapshots in first pass
        _validateSnapshotInvariants(
          firstCollectedSnapshots,
          passLabel: 'First pass (store)',
        );

        bool hasActiveSessionSnapshot = false;
        bool hasCacheTelemetryAttached = false;
        bool hasPlaybackCacheEnabled = false;

        for (final snap in firstCollectedSnapshots) {
          if (snap.status.hasSession) {
            hasActiveSessionSnapshot = true;
          }
          if (snap.status.playbackCacheEnabled) {
            hasPlaybackCacheEnabled = true;
          }
          if (snap.status.playbackCacheTelemetryAttached) {
            hasCacheTelemetryAttached = true;
          }
        }

        if (!hasActiveSessionSnapshot ||
            !hasPlaybackCacheEnabled ||
            !hasCacheTelemetryAttached) {
          throw Exception(
            'First pass resilience snapshot invariant missing required flags: '
            'hasActiveSession=$hasActiveSessionSnapshot, '
            'cacheEnabled=$hasPlaybackCacheEnabled, '
            'telemetryAttached=$hasCacheTelemetryAttached',
          );
        }

        final firstRaw = firstFinalSnapshot.status.raw.isNotEmpty
            ? firstFinalSnapshot.status.raw
            : (firstController.snapshot.session?.raw ?? '');
        firstMisses = _extractNumericRawToken(firstRaw, 'proxyCacheMisses');
        firstHits = _extractNumericRawToken(firstRaw, 'proxyCacheHits');
        firstBytesRead = _extractNumericRawToken(
          firstRaw,
          'proxyCacheBytesRead',
        );
        firstDiskSizeBytes = _extractNumericRawToken(
          firstRaw,
          'proxyDiskSizeBytes',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_MONITOR_BINDER_COLLECT: DONE '
          '(collectedSnapshots=${firstCollectedSnapshots.length}, '
          'collectedEvaluations=${firstCollectedEvaluations.length}, '
          'cacheSizeBytes=${firstFinalSnapshot.status.playbackCacheSizeBytes}, '
          'proxyCacheMisses=$firstMisses, proxyCacheHits=$firstHits)',
        );

        // ─────────────────────────────────────────────────────────────────────
        // Assert all collected evaluations through the Resilience Binder
        // ─────────────────────────────────────────────────────────────────────
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_BINDER_EVALUATE: START',
        );
        for (int i = 0; i < firstCollectedEvaluations.length; i++) {
          final eval = firstCollectedEvaluations[i];
          _validateBinderEvaluationInvariants(
            eval,
            firstCoordinator,
            passLabel: 'First pass binder evaluation index $i',
            expectedStreamKey: _kStreamKey,
          );
        }

        if (firstBinder.latest == null) {
          throw Exception('First pass failed: firstBinder.latest is null');
        }

        final firstLatestEvaluation = firstBinder.latest!;
        final lastCollectedFirstEval = firstCollectedEvaluations.last;
        if (firstLatestEvaluation.action != lastCollectedFirstEval.action ||
            firstLatestEvaluation.reasons.join(',') !=
                lastCollectedFirstEval.reasons.join(',')) {
          throw Exception(
            'First pass failed: firstBinder.latest does not match last collected evaluation',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_BINDER_EVALUATE: DONE '
          '(action=${firstLatestEvaluation.action.name}, '
          'canRetryNow=${firstLatestEvaluation.canRetryNow}, '
          'length=${firstCoordinator.length})',
        );

        results['firstPlayback'] = <String, dynamic>{
          'pass': true,
          'textureId': firstController.snapshot.textureId,
          'renderedFrames': firstController.snapshot.session?.renderedFrames,
          'state': firstController.snapshot.state.name,
          'effectiveDisplayWidth':
              firstFinalSnapshot.status.effectiveDisplayWidth,
          'effectiveDisplayHeight':
              firstFinalSnapshot.status.effectiveDisplayHeight,
          'durationMs': firstFinalSnapshot.status.durationMs,
          'positionMs': firstFinalSnapshot.status.positionMs,
          'bufferedPositionMs': firstFinalSnapshot.status.bufferedPositionMs,
          'bufferedPercent': firstFinalSnapshot.status.bufferedPercent,
          'hasPlaybackTelemetry': firstController.snapshot.hasPlaybackTelemetry,
          'playbackCacheEnabled':
              firstFinalSnapshot.status.playbackCacheEnabled,
          'playbackCacheTelemetryAttached':
              firstFinalSnapshot.status.playbackCacheTelemetryAttached,
          'playbackCacheSizeBytes':
              firstFinalSnapshot.status.playbackCacheSizeBytes,
          'playbackCacheBytesRead':
              firstFinalSnapshot.status.playbackCacheBytesRead,
          'playbackCacheIgnoredCount':
              firstFinalSnapshot.status.playbackCacheIgnoredCount,
          'playbackCacheReadObserved':
              firstFinalSnapshot.status.playbackCacheReadObserved,
          'collectedSnapshotsCount': firstCollectedSnapshots.length,
          'collectedEvaluationsCount': firstCollectedEvaluations.length,
          'latestHealthSeverity': firstFinalSnapshot.healthAdvice.severity.name,
          'latestHealthAction':
              firstFinalSnapshot.healthAdvice.recommendedAction.name,
          'latestRecoveryIntent': firstFinalSnapshot.recoveryPlan.intent.name,
          'latestRecoveryUrgency': firstFinalSnapshot.recoveryPlan.urgency.name,
          'preserveCacheOptionsDiagnostic': firstFinalSnapshot
              .recoveryPlan
              .diagnostics['preserveCacheOptions'],
          'binderEvaluation': firstLatestEvaluation.toJson(),
          'binderAction': firstLatestEvaluation.action.name,
          'binderCanRetryNow': firstLatestEvaluation.canRetryNow,
          'binderShouldRecordAttempt':
              firstLatestEvaluation.shouldRecordAttemptOnHostRetry,
          'binderRequiresHostAction': firstLatestEvaluation.requiresHostAction,
          'binderRetryAfterMs': firstLatestEvaluation.retryAfterMs,
          'binderJournalCount': firstLatestEvaluation.journalSnapshot.count,
          'coordinatorLengthAfterEvaluate': firstCoordinator.length,
          'proxyCacheMisses': firstMisses,
          'proxyCacheHits': firstHits,
          'proxyCacheBytesRead': firstBytesRead,
          'proxyDiskSizeBytes': firstDiskSizeBytes,
          'raw': firstRaw,
        };

        // Stop & dispose binder without disposing monitor, poller, or controller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_BINDER_DISPOSE: START',
        );
        firstBinder.stop();
        if (firstBinder.isRunning) {
          throw Exception('First binder stop failed: isRunning is still true');
        }
        firstBinder.dispose();
        if (!firstBinder.isDisposed) {
          throw Exception('First binder dispose failed: isDisposed is false');
        }
        if (firstMonitor.isDisposed) {
          throw Exception(
            'First binder dispose erroneously disposed underlying monitor',
          );
        }
        if (firstPoller.isDisposed) {
          throw Exception(
            'First binder dispose erroneously disposed underlying poller',
          );
        }
        if (firstController.isDisposed) {
          throw Exception(
            'First binder dispose erroneously disposed underlying controller',
          );
        }
        if (firstCoordinator.length != 0) {
          throw Exception(
            'First coordinator length was modified during binder dispose',
          );
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_BINDER_DISPOSE: DONE',
        );

        // Stop & dispose monitor without disposing underlying poller or controller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_MONITOR_DISPOSE: START',
        );
        firstMonitor.stop();
        if (firstMonitor.isRunning) {
          throw Exception('First monitor stop failed: isRunning is still true');
        }
        await firstMonitor.dispose();
        if (!firstMonitor.isDisposed) {
          throw Exception('First monitor dispose failed: isDisposed is false');
        }
        if (firstPoller.isDisposed) {
          throw Exception(
            'First monitor dispose erroneously disposed the underlying poller',
          );
        }
        if (firstController.isDisposed) {
          throw Exception(
            'First monitor dispose erroneously disposed the underlying controller',
          );
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_MONITOR_DISPOSE: DONE',
        );

        // Stop & dispose poller without disposing underlying controller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_POLLER_DISPOSE: START',
        );
        firstPoller.stop();
        if (firstPoller.isRunning) {
          throw Exception('First poller stop failed: isRunning is still true');
        }
        await firstPoller.dispose();
        if (!firstPoller.isDisposed) {
          throw Exception('First poller dispose failed: isDisposed is false');
        }
        if (firstController.isDisposed) {
          throw Exception(
            'First poller dispose erroneously disposed the underlying controller',
          );
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_POLLER_DISPOSE: DONE',
        );
      } finally {
        await firstBinderSub?.cancel();
        firstBinderSub = null;
        await firstMonitorSub?.cancel();
        firstMonitorSub = null;
        if (firstBinder != null && !firstBinder.isDisposed) {
          try {
            firstBinder.dispose();
          } catch (_) {}
        }
        if (firstMonitor != null && !firstMonitor.isDisposed) {
          try {
            await firstMonitor.dispose();
          } catch (_) {}
        }
        if (firstPoller != null && !firstPoller.isDisposed) {
          try {
            await firstPoller.dispose();
          } catch (_) {}
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_DISPOSE: START',
        );
        if (firstController != null && !firstController.isDisposed) {
          final disposeSnap = await firstController.dispose().timeout(
            _kControlTimeout,
          );
          if (mounted) {
            setState(() {
              _currentSnapshot = disposeSnap;
            });
          }
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FIRST_DISPOSE: DONE',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 6: Warm Hit Pass with Resilience Monitor, Binder, Controls & Lifecycle Checks
      // ═══════════════════════════════════════════════════════════════════════
      final controlsMap = <String, dynamic>{};
      final lifecycleMap = <String, dynamic>{};
      try {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_OPEN: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Step 5/6: Opening second controller, resilience monitor & binder (hit path)…';
          });
        }

        secondController = VGStreamingPlaybackController();
        final secondOpenSnapshot = await secondController
            .open(decision, startPlayback: true)
            .timeout(_kOperationTimeout);

        if (!secondOpenSnapshot.pass || secondOpenSnapshot.textureId == null) {
          throw Exception(
            'Second controller open failed: pass=${secondOpenSnapshot.pass}, '
            'reason=${secondOpenSnapshot.reason}, lastError=${secondOpenSnapshot.lastError}, '
            'textureId=${secondOpenSnapshot.textureId}',
          );
        }

        if (mounted) {
          setState(() {
            _currentSnapshot = secondOpenSnapshot;
            _status =
                'Second playback active (textureId=${secondOpenSnapshot.textureId}), collecting hit resilience events…';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_OPEN: DONE '
          '(textureId=${secondOpenSnapshot.textureId})',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_MONITOR_BINDER_START: START',
        );

        secondPoller = VGStreamingPlaybackStatusPoller(
          controller: secondController,
          config: VGStreamingPlaybackStatusPollerConfig(
            interval: const Duration(milliseconds: 300),
            emitInitialSummary: true,
          ),
        );

        secondMonitor = VGStreamingPlaybackResilienceMonitor(
          summaries: secondPoller.summaries,
          config: VGStreamingPlaybackResilienceMonitorConfig(
            currentOptions: decision.playbackOptions,
            preflightReport: preflightReport,
            currentNetworkProfile: VGStreamingNetworkProfile.constrained,
            maxHistoryLength: 8,
            allowAutomaticRetry: false,
            preserveCacheOptions: true,
          ),
        );

        secondCoordinator = VGStreamingPlaybackResilienceCoordinator(
          config: const VGStreamingPlaybackResilienceCoordinatorConfig(
            journalConfig: VGStreamingPlaybackRetryJournalConfig(
              maxStoredAttempts: 10,
            ),
            retryBudgetConfig: VGStreamingPlaybackRetryBudgetConfig(
              maxAttempts: 3,
              windowMs: 30000,
              minimumDelayMs: 1000,
            ),
            streamKey: _kStreamKey,
          ),
        );

        int secondNowMs = 1700000000000;
        int secondDeterministicNow() {
          secondNowMs += 500;
          return secondNowMs;
        }

        secondBinder = VGStreamingPlaybackResilienceBinder(
          snapshots: secondMonitor.snapshots,
          coordinator: secondCoordinator,
          config: const VGStreamingPlaybackResilienceBinderConfig(
            streamKey: _kStreamKey,
          ),
          nowProvider: secondDeterministicNow,
        );

        secondBinderSub = secondBinder.evaluations.listen((evaluation) {
          secondCollectedEvaluations.add(evaluation);
        });

        secondMonitorSub = secondMonitor.snapshots.listen((snapshot) {
          secondCollectedSnapshots.add(snapshot);
          if (mounted &&
              secondController != null &&
              !secondController.isDisposed) {
            setState(() {
              _currentSnapshot = secondController!.snapshot;
            });
          }
        });

        // Start binder idempotently before starting monitor and poller
        secondBinder.start();
        if (!secondBinder.isRunning) {
          throw Exception('Second binder failed to start (isRunning is false)');
        }
        secondBinder.start();
        if (!secondBinder.isRunning) {
          throw Exception(
            'Second binder failed repeated start (isRunning is false)',
          );
        }

        // Start monitor, then poller
        secondMonitor.start();
        secondPoller.start();

        if (!secondMonitor.isRunning) {
          throw Exception(
            'Second monitor failed to start (isRunning is false)',
          );
        }
        if (!secondPoller.isRunning) {
          throw Exception('Second poller failed to start (isRunning is false)');
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_MONITOR_BINDER_START: DONE',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_MONITOR_BINDER_COLLECT: START',
        );

        final secondDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackResilienceSnapshot? secondFinalSnapshot;

        while (DateTime.now().isBefore(secondDeadline)) {
          await Future<void>.delayed(_kPollInterval);

          final latest = secondMonitor.latest;
          if (latest == null) continue;

          final currentSession = secondController.snapshot.session;
          final renderedFrames = currentSession?.renderedFrames ?? 0;
          final hasDimensions =
              latest.status.effectiveDisplayWidth > 0 &&
              latest.status.effectiveDisplayHeight > 0;
          final raw = latest.status.raw.isNotEmpty
              ? latest.status.raw
              : (currentSession?.raw ?? '');
          final hits = _extractNumericRawToken(raw, 'proxyCacheHits');
          final bytesRead = _extractNumericRawToken(raw, 'proxyCacheBytesRead');

          if (secondCollectedSnapshots.length >= 2 &&
              secondCollectedEvaluations.length >= 2 &&
              (latest.status.hasSession ||
                  secondCollectedSnapshots.any((s) => s.status.hasSession)) &&
              renderedFrames > 0 &&
              hasDimensions &&
              latest.status.playbackCacheEnabled &&
              latest.status.playbackCacheTelemetryAttached &&
              latest.status.playbackCacheIgnoredCount == 0 &&
              latest.status.playbackCacheSizeBytes > 0 &&
              (latest.status.playbackCacheReadObserved ||
                  secondCollectedSnapshots.any(
                    (s) => s.status.playbackCacheReadObserved,
                  )) &&
              hits > 0 &&
              bytesRead > 0) {
            secondFinalSnapshot = latest;
            break;
          }
        }

        if (secondFinalSnapshot == null) {
          final lastLatest = secondMonitor.latest;
          final lastSnap = secondController.snapshot;
          throw Exception(
            'Second controller resilience monitor/binder verification timed out: '
            'collectedSnapshots=${secondCollectedSnapshots.length}, '
            'collectedEvaluations=${secondCollectedEvaluations.length}, '
            'hasSession=${lastLatest?.status.hasSession}, '
            'renderedFrames=${lastSnap.session?.renderedFrames}, '
            'dims=${lastLatest?.status.effectiveDisplayWidth}x${lastLatest?.status.effectiveDisplayHeight}, '
            'cacheEnabled=${lastLatest?.status.playbackCacheEnabled}, '
            'cacheTelemetryAttached=${lastLatest?.status.playbackCacheTelemetryAttached}, '
            'cacheSizeBytes=${lastLatest?.status.playbackCacheSizeBytes}, '
            'cacheBytesRead=${lastLatest?.status.playbackCacheBytesRead}, '
            'cacheReadObserved=${lastLatest?.status.playbackCacheReadObserved}, '
            'ignoredCount=${lastLatest?.status.playbackCacheIgnoredCount}, '
            'raw=${lastLatest?.status.raw}',
          );
        }

        // Validate invariants on all collected snapshots in second pass
        _validateSnapshotInvariants(
          secondCollectedSnapshots,
          passLabel: 'Second pass (hit)',
        );

        bool secondHasActiveSessionSnapshot = false;
        bool secondHasCacheTelemetryAttached = false;
        bool secondHasPlaybackCacheEnabled = false;
        bool secondHasPlaybackCacheReadObserved = false;

        for (final snap in secondCollectedSnapshots) {
          if (snap.status.hasSession) {
            secondHasActiveSessionSnapshot = true;
          }
          if (snap.status.playbackCacheEnabled) {
            secondHasPlaybackCacheEnabled = true;
          }
          if (snap.status.playbackCacheTelemetryAttached) {
            secondHasCacheTelemetryAttached = true;
          }
          if (snap.status.playbackCacheReadObserved) {
            secondHasPlaybackCacheReadObserved = true;
          }
        }

        if (!secondHasActiveSessionSnapshot ||
            !secondHasPlaybackCacheEnabled ||
            !secondHasCacheTelemetryAttached ||
            !secondHasPlaybackCacheReadObserved) {
          throw Exception(
            'Second pass resilience snapshot invariant missing required flags: '
            'hasActiveSession=$secondHasActiveSessionSnapshot, '
            'cacheEnabled=$secondHasPlaybackCacheEnabled, '
            'telemetryAttached=$secondHasCacheTelemetryAttached, '
            'readObserved=$secondHasPlaybackCacheReadObserved',
          );
        }

        final secondRaw = secondFinalSnapshot.status.raw.isNotEmpty
            ? secondFinalSnapshot.status.raw
            : (secondController.snapshot.session?.raw ?? '');
        secondHits = _extractNumericRawToken(secondRaw, 'proxyCacheHits');
        secondMisses = _extractNumericRawToken(secondRaw, 'proxyCacheMisses');
        secondBytesRead = _extractNumericRawToken(
          secondRaw,
          'proxyCacheBytesRead',
        );
        secondDiskSizeBytes = _extractNumericRawToken(
          secondRaw,
          'proxyDiskSizeBytes',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_MONITOR_BINDER_COLLECT: DONE '
          '(collectedSnapshots=${secondCollectedSnapshots.length}, '
          'collectedEvaluations=${secondCollectedEvaluations.length}, '
          'cacheSizeBytes=${secondFinalSnapshot.status.playbackCacheSizeBytes}, '
          'proxyCacheHits=$secondHits, proxyCacheBytesRead=$secondBytesRead)',
        );

        // ─────────────────────────────────────────────────────────────────────
        // Assert all collected evaluations through the Resilience Binder
        // ─────────────────────────────────────────────────────────────────────
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_BINDER_EVALUATE: START',
        );
        for (int i = 0; i < secondCollectedEvaluations.length; i++) {
          final eval = secondCollectedEvaluations[i];
          _validateBinderEvaluationInvariants(
            eval,
            secondCoordinator,
            passLabel: 'Second pass binder evaluation index $i',
            expectedStreamKey: _kStreamKey,
          );
        }

        if (secondBinder.latest == null) {
          throw Exception('Second pass failed: secondBinder.latest is null');
        }

        final secondLatestEvaluation = secondBinder.latest!;
        final lastCollectedSecondEval = secondCollectedEvaluations.last;
        if (secondLatestEvaluation.action != lastCollectedSecondEval.action ||
            secondLatestEvaluation.reasons.join(',') !=
                lastCollectedSecondEval.reasons.join(',')) {
          throw Exception(
            'Second pass failed: secondBinder.latest does not match last collected evaluation',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_BINDER_EVALUATE: DONE '
          '(action=${secondLatestEvaluation.action.name}, '
          'canRetryNow=${secondLatestEvaluation.canRetryNow}, '
          'length=${secondCoordinator.length})',
        );

        results['secondPlayback'] = <String, dynamic>{
          'pass': true,
          'textureId': secondController.snapshot.textureId,
          'renderedFrames': secondController.snapshot.session?.renderedFrames,
          'state': secondController.snapshot.state.name,
          'effectiveDisplayWidth':
              secondFinalSnapshot.status.effectiveDisplayWidth,
          'effectiveDisplayHeight':
              secondFinalSnapshot.status.effectiveDisplayHeight,
          'durationMs': secondFinalSnapshot.status.durationMs,
          'positionMs': secondFinalSnapshot.status.positionMs,
          'bufferedPositionMs': secondFinalSnapshot.status.bufferedPositionMs,
          'bufferedPercent': secondFinalSnapshot.status.bufferedPercent,
          'hasPlaybackTelemetry':
              secondController.snapshot.hasPlaybackTelemetry,
          'playbackCacheEnabled':
              secondFinalSnapshot.status.playbackCacheEnabled,
          'playbackCacheTelemetryAttached':
              secondFinalSnapshot.status.playbackCacheTelemetryAttached,
          'playbackCacheSizeBytes':
              secondFinalSnapshot.status.playbackCacheSizeBytes,
          'playbackCacheBytesRead':
              secondFinalSnapshot.status.playbackCacheBytesRead,
          'playbackCacheIgnoredCount':
              secondFinalSnapshot.status.playbackCacheIgnoredCount,
          'playbackCacheReadObserved':
              secondFinalSnapshot.status.playbackCacheReadObserved,
          'collectedSnapshotsCount': secondCollectedSnapshots.length,
          'collectedEvaluationsCount': secondCollectedEvaluations.length,
          'latestHealthSeverity':
              secondFinalSnapshot.healthAdvice.severity.name,
          'latestHealthAction':
              secondFinalSnapshot.healthAdvice.recommendedAction.name,
          'latestRecoveryIntent': secondFinalSnapshot.recoveryPlan.intent.name,
          'latestRecoveryUrgency':
              secondFinalSnapshot.recoveryPlan.urgency.name,
          'preserveCacheOptionsDiagnostic': secondFinalSnapshot
              .recoveryPlan
              .diagnostics['preserveCacheOptions'],
          'binderEvaluation': secondLatestEvaluation.toJson(),
          'binderAction': secondLatestEvaluation.action.name,
          'binderCanRetryNow': secondLatestEvaluation.canRetryNow,
          'binderShouldRecordAttempt':
              secondLatestEvaluation.shouldRecordAttemptOnHostRetry,
          'binderRequiresHostAction': secondLatestEvaluation.requiresHostAction,
          'binderRetryAfterMs': secondLatestEvaluation.retryAfterMs,
          'binderJournalCount': secondLatestEvaluation.journalSnapshot.count,
          'coordinatorLengthAfterEvaluate': secondCoordinator.length,
          'proxyCacheHits': secondHits,
          'proxyCacheMisses': secondMisses,
          'proxyCacheBytesRead': secondBytesRead,
          'proxyDiskSizeBytes': secondDiskSizeBytes,
          'raw': secondRaw,
        };

        // ═════════════════════════════════════════════════════════════════════
        // Exercise Controls: pause(), optional seek(), play(), stop()
        // ═════════════════════════════════════════════════════════════════════
        if (mounted) {
          setState(() {
            _status = 'Step 6/6: Exercising pause, seek, play, stop controls…';
          });
        }

        // 1. Pause
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_PAUSE: START',
        );
        final pauseSnapshot = await secondController.pause().timeout(
          _kControlTimeout,
        );
        if (!pauseSnapshot.pass ||
            pauseSnapshot.state != VGStreamingPlaybackControllerState.paused) {
          throw Exception(
            'Second controller pause failed: pass=${pauseSnapshot.pass}, '
            'state=${pauseSnapshot.state.name}, reason=${pauseSnapshot.reason}',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = pauseSnapshot;
          });
        }
        controlsMap['pause'] = <String, dynamic>{
          'pass': pauseSnapshot.pass,
          'state': pauseSnapshot.state.name,
        };
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_PAUSE: DONE',
        );

        // 2. Optional Seek (1000 ms if durationMs > 2000)
        final effectiveDurationMs = secondFinalSnapshot.status.durationMs > 0
            ? secondFinalSnapshot.status.durationMs
            : secondController.snapshot.durationMs;
        if (effectiveDurationMs > 2000) {
          // ignore: avoid_print
          print(
            'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_SEEK: START',
          );
          final seekSnapshot = await secondController
              .seek(1000)
              .timeout(_kControlTimeout);
          if (!seekSnapshot.pass ||
              seekSnapshot.state == VGStreamingPlaybackControllerState.failed) {
            throw Exception(
              'Second controller seek failed: pass=${seekSnapshot.pass}, '
              'state=${seekSnapshot.state.name}, reason=${seekSnapshot.reason}',
            );
          }
          if (mounted) {
            setState(() {
              _currentSnapshot = seekSnapshot;
            });
          }
          controlsMap['seek'] = <String, dynamic>{
            'pass': seekSnapshot.pass,
            'state': seekSnapshot.state.name,
            'positionMs': 1000,
            'skipped': false,
          };
          // ignore: avoid_print
          print(
            'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_SEEK: DONE',
          );
        } else {
          controlsMap['seek'] = <String, dynamic>{
            'pass': true,
            'skipped': true,
            'reason': 'durationMs <= 2000 (durationMs=$effectiveDurationMs)',
          };
          // ignore: avoid_print
          print(
            'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_SEEK: SKIPPED '
            '(durationMs=$effectiveDurationMs)',
          );
        }

        // 3. Play
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_PLAY: START',
        );
        final playSnapshot = await secondController.play().timeout(
          _kControlTimeout,
        );
        if (!playSnapshot.pass ||
            playSnapshot.state == VGStreamingPlaybackControllerState.failed) {
          throw Exception(
            'Second controller play resume failed: pass=${playSnapshot.pass}, '
            'state=${playSnapshot.state.name}, reason=${playSnapshot.reason}',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = playSnapshot;
          });
        }
        controlsMap['play'] = <String, dynamic>{
          'pass': playSnapshot.pass,
          'state': playSnapshot.state.name,
        };
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_PLAY: DONE',
        );

        // 4. Stop
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_STOP: START',
        );
        final stopSnapshot = await secondController.stop().timeout(
          _kControlTimeout,
        );
        if (!stopSnapshot.pass ||
            stopSnapshot.state != VGStreamingPlaybackControllerState.stopped) {
          throw Exception(
            'Second controller stop failed: pass=${stopSnapshot.pass}, '
            'state=${stopSnapshot.state.name}, reason=${stopSnapshot.reason}',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = stopSnapshot;
          });
        }
        controlsMap['stop'] = <String, dynamic>{
          'pass': stopSnapshot.pass,
          'state': stopSnapshot.state.name,
        };
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_STOP: DONE',
        );

        results['controls'] = controlsMap;

        // ═════════════════════════════════════════════════════════════════════
        // Second Pass Binder Lifecycle Checks
        // ═════════════════════════════════════════════════════════════════════
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_BINDER_LIFECYCLE_TEST: START',
        );

        // Stop poller before count-sensitive lifecycle checks
        secondPoller.stop();

        // 1. Stop binder
        secondBinder.stop();
        if (secondBinder.isRunning) {
          throw Exception('Second binder stop failed: isRunning is still true');
        }
        if (secondBinder.isDisposed) {
          throw Exception(
            'Second binder stop failed: isDisposed is true after stop()',
          );
        }
        lifecycleMap['binderStopPass'] = true;

        // 2. While binder is stopped, monitor.evaluateOnce does not increase binder evaluation count
        final secondCountBeforeStoppedMonitorEval =
            secondCollectedEvaluations.length;
        secondMonitor.evaluateOnce(secondFinalSnapshot.status);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (secondCollectedEvaluations.length !=
            secondCountBeforeStoppedMonitorEval) {
          throw Exception(
            'Second binder evaluation count increased while stopped: '
            'before=$secondCountBeforeStoppedMonitorEval, after=${secondCollectedEvaluations.length}',
          );
        }
        lifecycleMap['binderStoppedCountUnchanged'] = true;

        // 3. Call binder.evaluateOnce directly while stopped
        final manualSecondEval = secondBinder.evaluateOnce(secondFinalSnapshot);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        _validateBinderEvaluationInvariants(
          manualSecondEval,
          secondCoordinator,
          passLabel: 'Second pass manual evaluateOnce while stopped',
          expectedStreamKey: _kStreamKey,
        );
        if (secondBinder.latest != manualSecondEval) {
          throw Exception(
            'Second binder.latest not updated by manual evaluateOnce',
          );
        }
        if (secondCollectedEvaluations.length !=
            secondCountBeforeStoppedMonitorEval + 1) {
          throw Exception(
            'Second binder manual evaluateOnce did not emit exactly 1 evaluation onto stream: '
            'before=$secondCountBeforeStoppedMonitorEval, after=${secondCollectedEvaluations.length}',
          );
        }
        lifecycleMap['binderManualEvalPass'] = true;

        // 4. Restart binder and verify resumed listening
        secondBinder.start();
        if (!secondBinder.isRunning) {
          throw Exception('Second binder restart failed: isRunning is false');
        }
        final secondCountBeforeRestartedMonitorEval =
            secondCollectedEvaluations.length;
        secondMonitor.evaluateOnce(secondFinalSnapshot.status);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (secondCollectedEvaluations.length !=
            secondCountBeforeRestartedMonitorEval + 1) {
          throw Exception(
            'Second binder restart failed to receive evaluation after monitor.evaluateOnce: '
            'before=$secondCountBeforeRestartedMonitorEval, after=${secondCollectedEvaluations.length}',
          );
        }
        lifecycleMap['binderRestartResumedPass'] = true;

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_BINDER_LIFECYCLE_TEST: DONE',
        );

        // 5. Dispose binder
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_BINDER_DISPOSE: START',
        );
        secondBinder.dispose();
        if (!secondBinder.isDisposed) {
          throw Exception(
            'Second binder dispose failed: isDisposed is false after dispose()',
          );
        }
        if (secondBinder.isRunning) {
          throw Exception(
            'Second binder dispose failed: isRunning is true after dispose()',
          );
        }
        if (secondMonitor.isDisposed) {
          throw Exception(
            'Second binder dispose erroneously disposed underlying monitor',
          );
        }
        if (secondPoller.isDisposed) {
          throw Exception(
            'Second binder dispose erroneously disposed underlying poller',
          );
        }
        if (secondController.isDisposed) {
          throw Exception(
            'Second binder dispose erroneously disposed underlying controller',
          );
        }
        if (secondCoordinator.length != 0) {
          throw Exception(
            'Second coordinator length was modified during binder dispose',
          );
        }

        // Calling start() after dispose must be a no-op
        secondBinder.start();
        if (secondBinder.isRunning) {
          throw Exception(
            'Second binder calling start() after dispose unexpectedly set isRunning to true',
          );
        }
        lifecycleMap['binderDisposePass'] = true;
        lifecycleMap['binderStartAfterDisposeNoopPass'] = true;

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_BINDER_DISPOSE: DONE',
        );

        // 6. Stop & dispose monitor
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_MONITOR_DISPOSE: START',
        );
        secondMonitor.stop();
        if (secondMonitor.isRunning) {
          throw Exception(
            'Second monitor stop failed: isRunning is still true',
          );
        }
        await secondMonitorSub.cancel();
        secondMonitorSub = null;

        await secondMonitor.dispose();
        if (!secondMonitor.isDisposed) {
          throw Exception(
            'Second monitor dispose failed: isDisposed is false after dispose()',
          );
        }
        if (secondPoller.isDisposed) {
          throw Exception(
            'Second monitor dispose erroneously disposed underlying poller',
          );
        }
        if (secondController.isDisposed) {
          throw Exception(
            'Second monitor dispose erroneously disposed underlying controller',
          );
        }
        lifecycleMap['monitorDisposePass'] = true;

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_MONITOR_DISPOSE: DONE',
        );

        // 7. Verify disposed monitor evaluateOnce returns safely with advisory-only invariants
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_DISPOSED_EVALUATE: START',
        );
        final safeDisposedSnap = secondMonitor.evaluateOnce(
          secondFinalSnapshot.status,
        );
        if (!safeDisposedSnap.advisoryOnly ||
            safeDisposedSnap.playbackMutation) {
          throw Exception(
            'Disposed monitor evaluateOnce invariant violated: '
            'advisoryOnly=${safeDisposedSnap.advisoryOnly}, playbackMutation=${safeDisposedSnap.playbackMutation}',
          );
        }
        lifecycleMap['disposedEvaluateAdvisoryOnly'] =
            safeDisposedSnap.advisoryOnly;
        lifecycleMap['disposedEvaluatePlaybackMutation'] =
            safeDisposedSnap.playbackMutation;
        results['disposedEvaluateSummaryHasSession'] =
            safeDisposedSnap.status.hasSession;
        results['disposedEvaluateAdvisoryOnly'] = safeDisposedSnap.advisoryOnly;
        results['disposedEvaluatePlaybackMutation'] =
            safeDisposedSnap.playbackMutation;
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_DISPOSED_EVALUATE: DONE',
        );

        // 8. Stop & dispose poller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_POLLER_DISPOSE: START',
        );
        secondPoller.stop();
        await secondPoller.dispose();
        if (!secondPoller.isDisposed) {
          throw Exception(
            'Second poller dispose failed: isDisposed is false after dispose()',
          );
        }
        if (secondController.isDisposed) {
          throw Exception(
            'Second poller dispose erroneously disposed underlying controller',
          );
        }
        lifecycleMap['pollerDisposePass'] = true;

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_POLLER_DISPOSE: DONE',
        );

        results['lifecycle'] = lifecycleMap;
      } finally {
        await secondBinderSub?.cancel();
        secondBinderSub = null;
        await secondMonitorSub?.cancel();
        secondMonitorSub = null;
        if (secondBinder != null && !secondBinder.isDisposed) {
          try {
            secondBinder.dispose();
          } catch (_) {}
        }
        if (secondMonitor != null && !secondMonitor.isDisposed) {
          try {
            await secondMonitor.dispose();
          } catch (_) {}
        }
        if (secondPoller != null && !secondPoller.isDisposed) {
          try {
            await secondPoller.dispose();
          } catch (_) {}
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_DISPOSE: START',
        );
        if (secondController != null && !secondController.isDisposed) {
          final disposeSnap = await secondController.dispose().timeout(
            _kControlTimeout,
          );
          if (mounted) {
            setState(() {
              _currentSnapshot = disposeSnap;
            });
          }
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_SECOND_DISPOSE: DONE',
        );
      }

      allPass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      results['error'] = error.toString();
      allPass = false;
    } finally {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 7: Final cleanup
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FINAL_CLEAR: START',
      );
      try {
        final finalClear = await _cacheClient.clear().timeout(_kControlTimeout);
        final finalClearPass =
            finalClear.pass &&
            finalClear.state == 'cleared' &&
            finalClear.cacheAvailable &&
            finalClear.failedResourceCount == 0 &&
            finalClear.afterBytes == 0;

        results['finalClear'] = <String, dynamic>{
          'pass': finalClearPass,
          'state': finalClear.state,
          'cacheAvailable': finalClear.cacheAvailable,
          'beforeBytes': finalClear.beforeBytes,
          'afterBytes': finalClear.afterBytes,
          'removedResourceCount': finalClear.removedResourceCount,
          'failedResourceCount': finalClear.failedResourceCount,
          'raw': finalClear.raw,
        };

        if (!finalClearPass) {
          allPass = false;
          final clearErrorMsg =
              'Final cache clear failed acceptance: pass=${finalClear.pass}, '
              'state=${finalClear.state}, cacheAvailable=${finalClear.cacheAvailable}, '
              'failedCount=${finalClear.failedResourceCount}, afterBytes=${finalClear.afterBytes}, '
              'raw=${finalClear.raw}';
          results['error'] ??= clearErrorMsg;
          // ignore: avoid_print
          print(
            'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FINAL_CLEAR: FAILED ($clearErrorMsg)',
          );
        } else {
          // ignore: avoid_print
          print(
            'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FINAL_CLEAR: DONE '
            '(pass=${finalClear.pass}, state=${finalClear.state}, '
            'beforeBytes=${finalClear.beforeBytes}, afterBytes=${finalClear.afterBytes})',
          );
        }
      } catch (clearError) {
        allPass = false;
        results['finalClear'] = <String, dynamic>{
          'pass': false,
          'error': clearError.toString(),
        };
        results['error'] ??= clearError.toString();
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_STEP_FINAL_CLEAR: ERROR ($clearError)',
        );
      }
    }

    results['pass'] = allPass;
    final rawStatus =
        'status=${allPass ? "PASS" : "FAIL"};'
        'firstMisses=$firstMisses;'
        'secondHits=$secondHits;'
        'secondBytesRead=$secondBytesRead;'
        'firstDiskSize=$firstDiskSizeBytes;'
        'secondDiskSize=$secondDiskSizeBytes;'
        'firstBinderAction=${results["firstPlayback"]?["binderAction"]};'
        'secondBinderAction=${results["secondPlayback"]?["binderAction"]};'
        'initialClearPass=${results["initialClear"]?["pass"]};'
        'finalClearPass=${results["finalClear"]?["pass"]}';
    results['raw'] = rawStatus;

    // Emit terminal JSON line
    // ignore: avoid_print
    print(
      'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_PASS',
      );
    } else {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_FAIL',
      );
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (Resilience binder store: size=${firstDiskSizeBytes}B, misses=$firstMisses; hit: hits=$secondHits, read=${secondBytesRead}B)'
            : 'FAIL: ${results['error']}';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(allPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 320,
                height: 180,
                child: VGStreamingPlaybackTextureView(
                  snapshot: _currentSnapshot,
                  fit: BoxFit.contain,
                  placeholderBuilder: (context, snap) {
                    return Container(
                      color: const Color(0xFF1E1E1E),
                      alignment: Alignment.center,
                      child: Text(
                        'No texture (${snap.state.name})',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
