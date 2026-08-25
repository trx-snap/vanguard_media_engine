// Copyright (c) Connects — Vanguard Phase 4C6H2D.
// iOS cached streaming playback status poller public API physical smoke harness.
//
// Sequentially verifies:
//   1. Initial Clear: Clears playback cache via VGStreamingCacheClient.clear() to establish
//      a clean deterministic baseline (asserting pass, state=="cleared", cacheAvailable==true,
//      failedResourceCount==0, afterBytes==0).
//   2. Source Set + Prewarm Planning: Builds VGStreamingSourceSet with 'hls' (cached) and
//      'll_hls' (low-latency, cached) and plans bounded prewarm via VGStreamingCachePrewarmPlanner.
//      Asserts exactly 1 request for 'hls', requestId 'phase4c6h2d_ios_hls_0', skippedKeys contains 'll_hls',
//      and low-latency constraint warning 'low_latency_cache_constrained:ll_hls'.
//      (Does NOT dispatch or await AVAssetDownload prewarm completion).
//   3. Preflight Advisory: Evaluates HLS manifest under CONSTRAINED network profile via
//      VGStreamingPreflightClient.evaluate(), asserting pass, advisoryOnly, playbackMutation==false, failedReports==0.
//   4. Playback Decision: Plans playback decision via VGStreamingPlaybackDecisionPlanner with
//      appleAvPlayer client capability and preferHls, asserting canOpenPlayback==true, decision=="playback_ready",
//      selectedKey=="hls", and cacheEnabled==true.
//   5. Cold Store Pass with Status Poller: Creates first VGStreamingPlaybackController, opens decision,
//      renders via VGStreamingPlaybackTextureView, attaches VGStreamingPlaybackStatusPoller (300ms, emitInitialSummary),
//      collects summaries, and polls until >= 2 summaries collected, active session, renderedFrames > 0, dimensions > 0,
//      playbackCacheEnabled == true, playbackCacheTelemetryAttached == true, ignored count == 0,
//      playbackCacheSizeBytes > 0, and proxyCacheMisses > 0.
//      Validates summary invariants, stops/disposes poller without disposing controller, and disposes controller in finally.
//   6. Warm Hit Pass with Status Poller: Creates a second fresh VGStreamingPlaybackController, opens same decision,
//      renders via VGStreamingPlaybackTextureView, attaches a fresh VGStreamingPlaybackStatusPoller (300ms, emitInitialSummary),
//      collects summaries, and polls until >= 2 summaries collected, active session, renderedFrames > 0, dimensions > 0,
//      playbackCacheEnabled == true, playbackCacheTelemetryAttached == true, ignored count == 0,
//      playbackCacheSizeBytes > 0, playbackCacheReadObserved == true, proxyCacheHits > 0, and proxyCacheBytesRead > 0.
//      Exercises playback controls: pause(), optional seek(1000), play(), stop(), stops/disposes poller and controller cleanly,
//      and verifies disposed poller refreshOnce() returns safely without throwing.
//   7. Final Cleanup: Clears playback cache in finally block (asserting pass,
//      state=="cleared", cacheAvailable==true, failedResourceCount==0, afterBytes==0).
//
// Verification Invariants & Boundaries:
// - Imports ONLY pure Dart/Flutter standard libraries and package:vanguard_media_engine.
// - No direct MethodChannel or package:flutter/services.dart imports.
// - Presentation via VGStreamingPlaybackTextureView (no direct raw Flutter Texture widget).
// - All async operations bound by timeouts.
// - Guaranteed cleanup in finally blocks.
// - Non-claims: offlinePlaybackClaimed: false, zeroNetworkFetchClaimed: false,
//   avAssetDownloadCompletionClaimed: false, connectsAppPolicyClaimed: false,
//   dashPlaybackClaimed: false, webRtcCachingClaimed: false.
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
const int _kInitialWidth = 640;
const int _kInitialHeight = 360;
const int _kPrewarmMaxBytes = 65536;

const Duration _kOperationTimeout = Duration(seconds: 25);
const Duration _kControlTimeout = Duration(seconds: 8);
const Duration _kPollInterval = Duration(milliseconds: 300);
const Duration _kStatusDeadline = Duration(seconds: 25);

void main() {
  runApp(const IosStreamingCachedPlaybackStatusPollerPhysicalSmokeApp());
}

class IosStreamingCachedPlaybackStatusPollerPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingCachedPlaybackStatusPollerPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingCachedPlaybackStatusPollerPhysicalSmokeApp> createState() =>
      _IosStreamingCachedPlaybackStatusPollerPhysicalSmokeAppState();
}

class _IosStreamingCachedPlaybackStatusPollerPhysicalSmokeAppState
    extends State<IosStreamingCachedPlaybackStatusPollerPhysicalSmokeApp> {
  final VGStreamingCacheClient _cacheClient = VGStreamingCacheClient();
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Bootstrapping iOS cached streaming playback status poller physical smoke...';
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
    print('IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_BOOTSTRAP: START');
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

  Future<void> _runSmoke() async {
    // Allow Flutter host connection to settle.
    await Future<void>.delayed(const Duration(seconds: 1));

    final results = <String, dynamic>{
      'phase': 'Phase4C6H2D',
      'target': 'ios_physical',
      'offlinePlaybackClaimed': false,
      'zeroNetworkFetchClaimed': false,
      'avAssetDownloadCompletionClaimed': false,
      'connectsAppPolicyClaimed': false,
      'dashPlaybackClaimed': false,
      'webRtcCachingClaimed': false,
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
    StreamSubscription<VGStreamingPlaybackStatusSummary>? firstPollerSub;
    final firstCollectedSummaries = <VGStreamingPlaybackStatusSummary>[];

    VGStreamingPlaybackController? secondController;
    VGStreamingPlaybackStatusPoller? secondPoller;
    StreamSubscription<VGStreamingPlaybackStatusSummary>? secondPollerSub;
    final secondCollectedSummaries = <VGStreamingPlaybackStatusSummary>[];

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 1: Initial deterministic cache clear
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_INITIAL_CLEAR: START',
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
        'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_INITIAL_CLEAR: DONE '
        '(beforeBytes=${initialClear.beforeBytes}, afterBytes=${initialClear.afterBytes})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 2: Source set + cache prewarm planner composition
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SOURCE_SET: START',
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
        requestIdPrefix: 'phase4c6h2d_ios',
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
      if (prewarmReq.requestId != 'phase4c6h2d_ios_hls_0') {
        throw Exception(
          'Expected prewarm requestId "phase4c6h2d_ios_hls_0", got "${prewarmReq.requestId}"',
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
        'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SOURCE_SET: DONE',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 3: Preflight evaluation & Playback decision planning
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_PREFLIGHT: START',
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
      print('IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_PREFLIGHT: DONE');

      // ignore: avoid_print
      print('IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_DECISION: START');
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
      print('IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_DECISION: DONE');

      // ═══════════════════════════════════════════════════════════════════════
      // Step 4: First Controller Playback & Status Poller (Store Path)
      // ═══════════════════════════════════════════════════════════════════════
      try {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_FIRST_OPEN: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Step 4/6: Opening first controller & status poller (store path)…';
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
                'First playback active (textureId=${firstOpenSnapshot.textureId}), polling store summaries…';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_FIRST_OPEN: DONE '
          '(textureId=${firstOpenSnapshot.textureId})',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_FIRST_POLLER: START',
        );

        firstPoller = VGStreamingPlaybackStatusPoller(
          controller: firstController,
          config: VGStreamingPlaybackStatusPollerConfig(
            interval: const Duration(milliseconds: 300),
            emitInitialSummary: true,
          ),
        );

        firstPollerSub = firstPoller.summaries.listen((summary) {
          firstCollectedSummaries.add(summary);
          if (mounted &&
              firstController != null &&
              !firstController.isDisposed) {
            setState(() {
              _currentSnapshot = firstController!.snapshot;
            });
          }
        });

        firstPoller.start();

        if (!firstPoller.isRunning) {
          throw Exception('First poller failed to start (isRunning is false)');
        }

        final firstDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackStatusSummary? firstFinalSummary;

        while (DateTime.now().isBefore(firstDeadline)) {
          await Future<void>.delayed(_kPollInterval);

          final latest = firstPoller.latest;
          final currentSession = firstController.snapshot.session;
          final renderedFrames = currentSession?.renderedFrames ?? 0;
          final hasDimensions =
              latest.effectiveDisplayWidth > 0 &&
              latest.effectiveDisplayHeight > 0;
          final raw = latest.raw.isNotEmpty
              ? latest.raw
              : (currentSession?.raw ?? '');
          final misses = _extractNumericRawToken(raw, 'proxyCacheMisses');

          if (firstCollectedSummaries.length >= 2 &&
              (latest.hasSession ||
                  firstCollectedSummaries.any((s) => s.hasSession)) &&
              renderedFrames > 0 &&
              hasDimensions &&
              latest.playbackCacheEnabled &&
              latest.playbackCacheTelemetryAttached &&
              latest.playbackCacheIgnoredCount == 0 &&
              latest.playbackCacheSizeBytes > 0 &&
              misses > 0) {
            firstFinalSummary = latest;
            break;
          }
        }

        if (firstFinalSummary == null) {
          final lastLatest = firstPoller.latest;
          final lastSnap = firstController.snapshot;
          throw Exception(
            'First controller status poller verification timed out: '
            'collectedCount=${firstCollectedSummaries.length}, '
            'hasSession=${lastLatest.hasSession}, '
            'renderedFrames=${lastSnap.session?.renderedFrames}, '
            'dims=${lastLatest.effectiveDisplayWidth}x${lastLatest.effectiveDisplayHeight}, '
            'cacheEnabled=${lastLatest.playbackCacheEnabled}, '
            'cacheTelemetryAttached=${lastLatest.playbackCacheTelemetryAttached}, '
            'cacheSizeBytes=${lastLatest.playbackCacheSizeBytes}, '
            'ignoredCount=${lastLatest.playbackCacheIgnoredCount}, '
            'raw=${lastLatest.raw}',
          );
        }

        // Validate invariants on all collected summaries
        bool hasActiveSessionSummary = false;
        bool hasCacheTelemetryAttached = false;
        bool hasPlaybackCacheEnabled = false;

        for (final summary in firstCollectedSummaries) {
          if (summary.hasSession) {
            hasActiveSessionSummary = true;
          }
          if (summary.playbackCacheEnabled) {
            hasPlaybackCacheEnabled = true;
          }
          if (summary.playbackCacheTelemetryAttached) {
            hasCacheTelemetryAttached = true;
          }

          final durationValid = summary.durationMs >= -1;
          final positionValid = summary.positionMs >= 0;
          final bufferedPosValid = summary.bufferedPositionMs >= 0;
          final bufferedPercentValid =
              summary.bufferedPercent >= 0 && summary.bufferedPercent <= 100;
          final progressFractionValid =
              summary.progressFraction >= 0.0 &&
              summary.progressFraction <= 1.0;
          final bufferedFractionValid =
              summary.bufferedFraction >= 0.0 &&
              summary.bufferedFraction <= 1.0;
          final cacheBytesReadValid = summary.playbackCacheBytesRead >= 0;
          final cacheSizeBytesValid = summary.playbackCacheSizeBytes >= 0;
          final cacheIgnoredCountValid = summary.playbackCacheIgnoredCount >= 0;

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
              'First summary invariant violation: duration=${summary.durationMs}, '
              'position=${summary.positionMs}, bufferedPos=${summary.bufferedPositionMs}, '
              'bufferedPercent=${summary.bufferedPercent}, progressFraction=${summary.progressFraction}, '
              'bufferedFraction=${summary.bufferedFraction}, cacheBytesRead=${summary.playbackCacheBytesRead}, '
              'cacheSizeBytes=${summary.playbackCacheSizeBytes}, cacheIgnoredCount=${summary.playbackCacheIgnoredCount}',
            );
          }
        }

        if (!hasActiveSessionSummary ||
            !hasPlaybackCacheEnabled ||
            !hasCacheTelemetryAttached) {
          throw Exception(
            'First pass summary invariant missing required flags: '
            'hasActiveSession=$hasActiveSessionSummary, '
            'cacheEnabled=$hasPlaybackCacheEnabled, '
            'telemetryAttached=$hasCacheTelemetryAttached',
          );
        }

        final firstRaw = firstFinalSummary.raw.isNotEmpty
            ? firstFinalSummary.raw
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

        results['firstPlayback'] = <String, dynamic>{
          'pass': true,
          'textureId': firstController.snapshot.textureId,
          'renderedFrames': firstController.snapshot.session?.renderedFrames,
          'state': firstController.snapshot.state.name,
          'effectiveDisplayWidth': firstFinalSummary.effectiveDisplayWidth,
          'effectiveDisplayHeight': firstFinalSummary.effectiveDisplayHeight,
          'durationMs': firstFinalSummary.durationMs,
          'positionMs': firstFinalSummary.positionMs,
          'bufferedPositionMs': firstFinalSummary.bufferedPositionMs,
          'bufferedPercent': firstFinalSummary.bufferedPercent,
          'hasPlaybackTelemetry': firstController.snapshot.hasPlaybackTelemetry,
          'playbackCacheEnabled': firstFinalSummary.playbackCacheEnabled,
          'playbackCacheTelemetryAttached':
              firstFinalSummary.playbackCacheTelemetryAttached,
          'playbackCacheSizeBytes': firstFinalSummary.playbackCacheSizeBytes,
          'playbackCacheBytesRead': firstFinalSummary.playbackCacheBytesRead,
          'playbackCacheIgnoredCount':
              firstFinalSummary.playbackCacheIgnoredCount,
          'playbackCacheReadObserved':
              firstFinalSummary.playbackCacheReadObserved,
          'collectedSummariesCount': firstCollectedSummaries.length,
          'proxyCacheMisses': firstMisses,
          'proxyCacheHits': firstHits,
          'proxyCacheBytesRead': firstBytesRead,
          'proxyDiskSizeBytes': firstDiskSizeBytes,
          'raw': firstRaw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_FIRST_POLLER: DONE '
          '(collectedCount=${firstCollectedSummaries.length}, '
          'cacheSizeBytes=${firstFinalSummary.playbackCacheSizeBytes}, '
          'proxyCacheMisses=$firstMisses, proxyCacheHits=$firstHits)',
        );

        // Stop & dispose poller without disposing underlying controller
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
      } finally {
        await firstPollerSub?.cancel();
        firstPollerSub = null;
        if (firstPoller != null && !firstPoller.isDisposed) {
          try {
            await firstPoller.dispose();
          } catch (_) {}
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_FIRST_DISPOSE: START',
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
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_FIRST_DISPOSE: DONE',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 5: Second Controller Playback & Status Poller (Hit Path) & Controls
      // ═══════════════════════════════════════════════════════════════════════
      final controlsMap = <String, dynamic>{};
      try {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_OPEN: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Step 5/6: Opening second controller & status poller (hit path)…';
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
                'Second playback active (textureId=${secondOpenSnapshot.textureId}), polling hit summaries…';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_OPEN: DONE '
          '(textureId=${secondOpenSnapshot.textureId})',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_POLLER: START',
        );

        secondPoller = VGStreamingPlaybackStatusPoller(
          controller: secondController,
          config: VGStreamingPlaybackStatusPollerConfig(
            interval: const Duration(milliseconds: 300),
            emitInitialSummary: true,
          ),
        );

        secondPollerSub = secondPoller.summaries.listen((summary) {
          secondCollectedSummaries.add(summary);
          if (mounted &&
              secondController != null &&
              !secondController.isDisposed) {
            setState(() {
              _currentSnapshot = secondController!.snapshot;
            });
          }
        });

        secondPoller.start();

        if (!secondPoller.isRunning) {
          throw Exception('Second poller failed to start (isRunning is false)');
        }

        final secondDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackStatusSummary? secondFinalSummary;

        while (DateTime.now().isBefore(secondDeadline)) {
          await Future<void>.delayed(_kPollInterval);

          final latest = secondPoller.latest;
          final currentSession = secondController.snapshot.session;
          final renderedFrames = currentSession?.renderedFrames ?? 0;
          final hasDimensions =
              latest.effectiveDisplayWidth > 0 &&
              latest.effectiveDisplayHeight > 0;
          final raw = latest.raw.isNotEmpty
              ? latest.raw
              : (currentSession?.raw ?? '');
          final hits = _extractNumericRawToken(raw, 'proxyCacheHits');
          final bytesRead = _extractNumericRawToken(raw, 'proxyCacheBytesRead');

          if (secondCollectedSummaries.length >= 2 &&
              (latest.hasSession ||
                  secondCollectedSummaries.any((s) => s.hasSession)) &&
              renderedFrames > 0 &&
              hasDimensions &&
              latest.playbackCacheEnabled &&
              latest.playbackCacheTelemetryAttached &&
              latest.playbackCacheIgnoredCount == 0 &&
              latest.playbackCacheSizeBytes > 0 &&
              (latest.playbackCacheReadObserved ||
                  secondCollectedSummaries.any(
                    (s) => s.playbackCacheReadObserved,
                  )) &&
              hits > 0 &&
              bytesRead > 0) {
            secondFinalSummary = latest;
            break;
          }
        }

        if (secondFinalSummary == null) {
          final lastLatest = secondPoller.latest;
          final lastSnap = secondController.snapshot;
          throw Exception(
            'Second controller status poller verification timed out: '
            'collectedCount=${secondCollectedSummaries.length}, '
            'hasSession=${lastLatest.hasSession}, '
            'renderedFrames=${lastSnap.session?.renderedFrames}, '
            'dims=${lastLatest.effectiveDisplayWidth}x${lastLatest.effectiveDisplayHeight}, '
            'cacheEnabled=${lastLatest.playbackCacheEnabled}, '
            'cacheTelemetryAttached=${lastLatest.playbackCacheTelemetryAttached}, '
            'cacheSizeBytes=${lastLatest.playbackCacheSizeBytes}, '
            'cacheBytesRead=${lastLatest.playbackCacheBytesRead}, '
            'cacheReadObserved=${lastLatest.playbackCacheReadObserved}, '
            'ignoredCount=${lastLatest.playbackCacheIgnoredCount}, '
            'raw=${lastLatest.raw}',
          );
        }

        // Validate invariants on all collected summaries in second pass
        bool secondHasActiveSessionSummary = false;
        bool secondHasCacheTelemetryAttached = false;
        bool secondHasPlaybackCacheEnabled = false;

        for (final summary in secondCollectedSummaries) {
          if (summary.hasSession) {
            secondHasActiveSessionSummary = true;
          }
          if (summary.playbackCacheEnabled) {
            secondHasPlaybackCacheEnabled = true;
          }
          if (summary.playbackCacheTelemetryAttached) {
            secondHasCacheTelemetryAttached = true;
          }

          final durationValid = summary.durationMs >= -1;
          final positionValid = summary.positionMs >= 0;
          final bufferedPosValid = summary.bufferedPositionMs >= 0;
          final bufferedPercentValid =
              summary.bufferedPercent >= 0 && summary.bufferedPercent <= 100;
          final progressFractionValid =
              summary.progressFraction >= 0.0 &&
              summary.progressFraction <= 1.0;
          final bufferedFractionValid =
              summary.bufferedFraction >= 0.0 &&
              summary.bufferedFraction <= 1.0;
          final cacheBytesReadValid = summary.playbackCacheBytesRead >= 0;
          final cacheSizeBytesValid = summary.playbackCacheSizeBytes >= 0;
          final cacheIgnoredCountValid = summary.playbackCacheIgnoredCount >= 0;

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
              'Second summary invariant violation: duration=${summary.durationMs}, '
              'position=${summary.positionMs}, bufferedPos=${summary.bufferedPositionMs}, '
              'bufferedPercent=${summary.bufferedPercent}, progressFraction=${summary.progressFraction}, '
              'bufferedFraction=${summary.bufferedFraction}, cacheBytesRead=${summary.playbackCacheBytesRead}, '
              'cacheSizeBytes=${summary.playbackCacheSizeBytes}, cacheIgnoredCount=${summary.playbackCacheIgnoredCount}',
            );
          }
        }

        if (!secondHasActiveSessionSummary ||
            !secondHasPlaybackCacheEnabled ||
            !secondHasCacheTelemetryAttached) {
          throw Exception(
            'Second pass summary invariant missing required flags: '
            'hasActiveSession=$secondHasActiveSessionSummary, '
            'cacheEnabled=$secondHasPlaybackCacheEnabled, '
            'telemetryAttached=$secondHasCacheTelemetryAttached',
          );
        }

        final secondRaw = secondFinalSummary.raw.isNotEmpty
            ? secondFinalSummary.raw
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

        results['secondPlayback'] = <String, dynamic>{
          'pass': true,
          'textureId': secondController.snapshot.textureId,
          'renderedFrames': secondController.snapshot.session?.renderedFrames,
          'state': secondController.snapshot.state.name,
          'effectiveDisplayWidth': secondFinalSummary.effectiveDisplayWidth,
          'effectiveDisplayHeight': secondFinalSummary.effectiveDisplayHeight,
          'durationMs': secondFinalSummary.durationMs,
          'positionMs': secondFinalSummary.positionMs,
          'bufferedPositionMs': secondFinalSummary.bufferedPositionMs,
          'bufferedPercent': secondFinalSummary.bufferedPercent,
          'hasPlaybackTelemetry':
              secondController.snapshot.hasPlaybackTelemetry,
          'playbackCacheEnabled': secondFinalSummary.playbackCacheEnabled,
          'playbackCacheTelemetryAttached':
              secondFinalSummary.playbackCacheTelemetryAttached,
          'playbackCacheSizeBytes': secondFinalSummary.playbackCacheSizeBytes,
          'playbackCacheBytesRead': secondFinalSummary.playbackCacheBytesRead,
          'playbackCacheIgnoredCount':
              secondFinalSummary.playbackCacheIgnoredCount,
          'playbackCacheReadObserved':
              secondFinalSummary.playbackCacheReadObserved,
          'collectedSummariesCount': secondCollectedSummaries.length,
          'proxyCacheHits': secondHits,
          'proxyCacheMisses': secondMisses,
          'proxyCacheBytesRead': secondBytesRead,
          'proxyDiskSizeBytes': secondDiskSizeBytes,
          'raw': secondRaw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_POLLER: DONE '
          '(collectedCount=${secondCollectedSummaries.length}, '
          'cacheSizeBytes=${secondFinalSummary.playbackCacheSizeBytes}, '
          'proxyCacheHits=$secondHits, proxyCacheBytesRead=$secondBytesRead)',
        );

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
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_PAUSE: START',
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
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_PAUSE: DONE',
        );

        // 2. Optional Seek (1000 ms if durationMs > 2000)
        final effectiveDurationMs = secondFinalSummary.durationMs > 0
            ? secondFinalSummary.durationMs
            : secondController.snapshot.durationMs;
        if (effectiveDurationMs > 2000) {
          // ignore: avoid_print
          print(
            'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_SEEK: START',
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
            'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_SEEK: DONE',
          );
        } else {
          controlsMap['seek'] = <String, dynamic>{
            'pass': true,
            'skipped': true,
            'reason': 'durationMs <= 2000 (durationMs=$effectiveDurationMs)',
          };
          // ignore: avoid_print
          print(
            'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_SEEK: SKIPPED '
            '(durationMs=$effectiveDurationMs)',
          );
        }

        // 3. Play
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_PLAY: START',
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
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_PLAY: DONE',
        );

        // 4. Stop
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_STOP: START',
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
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_STOP: DONE',
        );

        results['controls'] = controlsMap;

        // Stop & dispose poller
        secondPoller.stop();
        await secondPoller.dispose();

        // Verify disposed poller refreshOnce() returns safely without throwing
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_DISPOSED_REFRESH: START',
        );
        final safeDisposedSummary = await secondPoller.refreshOnce();
        results['disposedRefreshSummaryHasSession'] =
            safeDisposedSummary.hasSession;
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_DISPOSED_REFRESH: DONE',
        );
      } finally {
        await secondPollerSub?.cancel();
        secondPollerSub = null;
        if (secondPoller != null && !secondPoller.isDisposed) {
          try {
            await secondPoller.dispose();
          } catch (_) {}
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_DISPOSE: START',
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
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_SECOND_DISPOSE: DONE',
        );
      }

      allPass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      results['error'] = error.toString();
      allPass = false;
    } finally {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 6: Final cleanup
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_FINAL_CLEAR: START',
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
            'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_FINAL_CLEAR: FAILED ($clearErrorMsg)',
          );
        } else {
          // ignore: avoid_print
          print(
            'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_FINAL_CLEAR: DONE '
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
          'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_STEP_FINAL_CLEAR: ERROR ($clearError)',
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
        'initialClearPass=${results["initialClear"]?["pass"]};'
        'finalClearPass=${results["finalClear"]?["pass"]}';
    results['raw'] = rawStatus;

    // Emit terminal JSON line
    // ignore: avoid_print
    print(
      'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_PASS',
      );
    } else {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_FAIL',
      );
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (Poller store: size=${firstDiskSizeBytes}B, misses=$firstMisses; Poller hit: hits=$secondHits, read=${secondBytesRead}B)'
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
