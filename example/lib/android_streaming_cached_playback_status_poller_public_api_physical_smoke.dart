// Copyright (c) Connects — Vanguard Phase 4C7AE.
// Public cached streaming playback status poller -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor with cache enabled.
//   2. Bounded cache prewarm planning via VGStreamingCachePrewarmPlanner.
//   3. Dispatching prewarm request via VGStreamingCacheClient, polling prewarm status until succeeded (bytesCached > 0),
//      and verifying cache status metrics (cacheSpaceBytes >= bytesCached, resourceCount >= 1).
//   4. Preflight advisory evaluation via VGStreamingPreflightClient under CONSTRAINED profile.
//   5. Pure-Dart VGStreamingPlaybackDecisionPlanner planning.
//   6. Execution of adaptive streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   7. Attaching VGStreamingPlaybackStatusPoller over VGStreamingPlaybackController.
//   8. Starting the poller and collecting emitted summaries from broadcast Stream<VGStreamingPlaybackStatusSummary>.
//   9. Asserting all status summary invariants:
//      - at least two emitted summaries collected
//      - at least one summary has hasSession == true
//      - durationMs >= -1
//      - positionMs >= 0
//      - bufferedPositionMs >= 0
//      - bufferedPercent in 0..100
//      - progressFraction in 0.0..1.0
//      - bufferedFraction in 0.0..1.0
//      - playbackCacheEnabled == true
//      - playbackCacheTelemetryAttached == true
//      - playbackCacheBytesRead >= 0
//      - playbackCacheSizeBytes >= 0
//      - playbackCacheIgnoredCount >= 0
//      - playbackCacheReadObserved = (playbackCacheBytesRead > 0)
//  10. Stopping and disposing poller cleanly without disposing underlying controller.
//  11. Verifying disposed poller refreshOnce() does not throw.
//  12. Controller teardown (stop, dispose) and final cache clear verification.
//
// Verification Invariants & Boundaries:
// - Imports ONLY package:vanguard_media_engine/vanguard_media_engine.dart.
// - Does NOT import package:flutter/services.dart.
// - Does NOT construct raw MethodChannel.
// - Presentation via VGStreamingPlaybackTextureView.
// - Observation only: does NOT make product feed decisions, ABR decisions, retry policy, or caching policy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingCachedPlaybackStatusPollerPhysicalSmokeApp());
}

class AndroidStreamingCachedPlaybackStatusPollerPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingCachedPlaybackStatusPollerPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCachedPlaybackStatusPollerPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingCachedPlaybackStatusPollerPhysicalSmokeAppState();
}

class _AndroidStreamingCachedPlaybackStatusPollerPhysicalSmokeAppState
    extends State<AndroidStreamingCachedPlaybackStatusPollerPhysicalSmokeApp> {
  final VGStreamingCacheClient _cacheClient = VGStreamingCacheClient();
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android cached streaming playback status poller physical smoke…';
  VGStreamingPlaybackControllerSnapshot _currentSnapshot =
      const VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.idle,
        pass: true,
        reason: 'idle',
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runCachedStatusPollerSmoke();
    });
  }

  Future<void> _runCachedStatusPollerSmoke() async {
    // Settle window for Flutter host
    await Future<void>.delayed(const Duration(seconds: 1));

    bool prewarmPass = false;
    bool preflightPass = false;
    bool playbackPass = false;
    bool pollerPass = false;
    bool allPass = false;

    final diagMap = <String, dynamic>{};
    VGStreamingPlaybackController? controller;
    VGStreamingPlaybackStatusPoller? poller;
    StreamSubscription<VGStreamingPlaybackStatusSummary>? pollerSub;

    final collectedSummaries = <VGStreamingPlaybackStatusSummary>[];

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/6: Defining streaming candidate source set…';
        });
      }

      // Step 1: Define stable HLS streaming source with playback cache enabled
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'hls_cached',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
            initialWidth: 1080,
            initialHeight: 1920,
            cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
          ),
        ],
      );

      // Step 2: Initial cache clear and prewarm planning
      if (mounted) {
        setState(() {
          _status = 'Step 2/6: Planning and executing bounded cache prewarm…';
        });
      }

      final initialClear = await _cacheClient.clear();
      diagMap['initialClearPass'] = initialClear.pass;
      diagMap['initialClearState'] = initialClear.state;
      diagMap['initialClearCacheAvailable'] = initialClear.cacheAvailable;

      final prewarmPlan = VGStreamingCachePrewarmPlanner.planForSourceSet(
        sourceSet: sourceSet,
        requestIdPrefix: 'phase4c7ae',
        sourceKeys: const ['hls_cached'],
        maxBytes: 2 * 1024 * 1024,
      );

      diagMap['prewarmPlanRequestCount'] = prewarmPlan.requests.length;
      diagMap['prewarmPlanSkippedKeys'] = prewarmPlan.skippedKeys;
      diagMap['prewarmPlanWarnings'] = prewarmPlan.warnings;

      if (prewarmPlan.requests.length != 1) {
        throw Exception(
          'Expected prewarm plan to have 1 request, got ${prewarmPlan.requests.length}',
        );
      }

      final prewarmReq = prewarmPlan.requests.single;
      final startResult = await _cacheClient.prewarmRequest(prewarmReq);
      diagMap['prewarmStartPhase'] = startResult.phase;
      diagMap['prewarmStartState'] = startResult.state.name;
      diagMap['prewarmStartPass'] = startResult.pass;
      diagMap['prewarmStartRequestId'] = startResult.requestId;

      if (startResult.state != VGPlaybackPrewarmStartState.accepted &&
          startResult.state != VGPlaybackPrewarmStartState.duplicate) {
        throw Exception(
          'prewarmRequest failed to start: state=${startResult.state.name}',
        );
      }

      VGPlaybackPrewarmStatus? finalPrewarmStatus;
      const pollTimeout = Duration(seconds: 30);
      const pollInterval = Duration(milliseconds: 800);
      final deadline = DateTime.now().add(pollTimeout);

      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);
        final pollStatus = await _cacheClient.getPrewarmStatus(
          prewarmReq.requestId,
        );
        diagMap['lastPrewarmPollState'] = pollStatus.state.name;
        diagMap['lastPrewarmBytesCached'] = pollStatus.bytesCached;

        if (pollStatus.state == VGPlaybackPrewarmJobState.succeeded ||
            pollStatus.state == VGPlaybackPrewarmJobState.failed ||
            pollStatus.state == VGPlaybackPrewarmJobState.cancelled) {
          finalPrewarmStatus = pollStatus;
          break;
        }
      }

      if (finalPrewarmStatus == null) {
        throw Exception('Prewarm poll timed out after 30s');
      }

      diagMap['finalPrewarmState'] = finalPrewarmStatus.state.name;
      diagMap['finalPrewarmBytesCached'] = finalPrewarmStatus.bytesCached;
      diagMap['finalPrewarmCacheAvailable'] = finalPrewarmStatus.cacheAvailable;

      if (finalPrewarmStatus.state != VGPlaybackPrewarmJobState.succeeded) {
        throw Exception(
          'Prewarm final state is not succeeded: ${finalPrewarmStatus.state.name}',
        );
      }
      if (finalPrewarmStatus.bytesCached <= 0) {
        throw Exception(
          'Prewarm succeeded but bytesCached is ${finalPrewarmStatus.bytesCached} (expected > 0)',
        );
      }
      if (!finalPrewarmStatus.cacheAvailable) {
        throw Exception('Prewarm succeeded but cacheAvailable is false');
      }

      final cacheStatusMetrics = await _cacheClient.getStatus();
      diagMap['cacheStatusPass'] = cacheStatusMetrics.pass;
      diagMap['cacheStatusAvailable'] = cacheStatusMetrics.cacheAvailable;
      diagMap['cacheSpaceBytes'] = cacheStatusMetrics.cacheSpaceBytes;
      diagMap['resourceCount'] = cacheStatusMetrics.resourceCount;

      if (!cacheStatusMetrics.pass || !cacheStatusMetrics.cacheAvailable) {
        throw Exception(
          'getStatus failed: pass=${cacheStatusMetrics.pass}, cacheAvailable=${cacheStatusMetrics.cacheAvailable}',
        );
      }
      if (cacheStatusMetrics.cacheSpaceBytes < finalPrewarmStatus.bytesCached) {
        throw Exception(
          'cacheSpaceBytes (${cacheStatusMetrics.cacheSpaceBytes}) is less than bytesCached (${finalPrewarmStatus.bytesCached})',
        );
      }
      if (cacheStatusMetrics.resourceCount < 1) {
        throw Exception(
          'resourceCount (${cacheStatusMetrics.resourceCount}) is less than 1',
        );
      }

      prewarmPass = true;

      // Step 3: Evaluate Preflight Advisory & Plan Playback Decision
      if (mounted) {
        setState(() {
          _status = 'Step 3/6: Evaluating preflight advisory & planning…';
        });
      }

      final preflightRequest = sourceSet.toPreflightRequest(
        requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
      );

      final preflightReport = await _preflightClient.evaluate(preflightRequest);
      diagMap['preflightPhase'] = preflightReport.phase;
      diagMap['preflightPass'] = preflightReport.pass;
      diagMap['preflightTotalReports'] = preflightReport.totalReports;
      diagMap['preflightFailedReports'] = preflightReport.failedReports;
      diagMap['preflightAdvisoryOnly'] = preflightReport.advisoryOnly;
      diagMap['preflightPlaybackMutation'] = preflightReport.playbackMutation;

      preflightPass =
          preflightReport.phase == 'Phase4C5G' &&
          preflightReport.pass == true &&
          preflightReport.totalReports == 1 &&
          preflightReport.failedReports == 0 &&
          preflightReport.advisoryOnly == true &&
          preflightReport.playbackMutation == false;

      if (!preflightPass) {
        throw Exception(
          'Preflight assertion failed: phase=${preflightReport.phase}, pass=${preflightReport.pass}',
        );
      }

      final decision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: preflightReport,
          preference: VGStreamingSourceSelectionPreference.preserveOrder,
          preferredKeys: const ['hls_cached'],
        ),
      );

      diagMap['decisionCanOpen'] = decision.canOpenPlayback;
      diagMap['decisionValue'] = decision.decision;
      diagMap['decisionSelectedKey'] = decision.selectedKey;
      diagMap['decisionCacheEnabled'] =
          decision.playbackOptions?.cacheOptions?.cacheEnabled;

      if (!decision.canOpenPlayback ||
          decision.decision != 'playback_ready' ||
          decision.selectedKey != 'hls_cached') {
        throw Exception(
          'Playback decision failed: canOpenPlayback=${decision.canOpenPlayback}, '
          'decision=${decision.decision}, key=${decision.selectedKey}',
        );
      }
      if (decision.playbackOptions?.cacheOptions?.cacheEnabled != true) {
        throw Exception(
          'Expected playbackOptions.cacheOptions.cacheEnabled to be true, got ${decision.playbackOptions?.cacheOptions?.cacheEnabled}',
        );
      }

      // Step 4: Open controller & attach status poller
      if (mounted) {
        setState(() {
          _status = 'Step 4/6: Opening playback controller and poller…';
        });
      }

      controller = VGStreamingPlaybackController();
      final openSnapshot = await controller.open(decision, startPlayback: true);

      diagMap['openPass'] = openSnapshot.pass;
      diagMap['openState'] = openSnapshot.state.name;
      diagMap['openTextureId'] = openSnapshot.textureId;

      if (!openSnapshot.pass || openSnapshot.textureId == null) {
        throw Exception(
          'Controller open failed: pass=${openSnapshot.pass}, '
          'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}',
        );
      }

      if (mounted) {
        setState(() {
          _currentSnapshot = openSnapshot;
          _status = 'Step 5/6: Polling status summaries & telemetry…';
        });
      }

      poller = VGStreamingPlaybackStatusPoller(
        controller: controller,
        config: VGStreamingPlaybackStatusPollerConfig(
          interval: const Duration(milliseconds: 500),
          emitInitialSummary: true,
        ),
      );

      pollerSub = poller.summaries.listen((summary) {
        collectedSummaries.add(summary);
        if (mounted && controller != null) {
          setState(() {
            _currentSnapshot = controller!.snapshot;
          });
        }
      });

      poller.start();

      if (!poller.isRunning) {
        throw Exception('Poller failed to start (isRunning is false)');
      }

      // Step 5: Wait for rendered frames / positive display dimensions and at least 2 summaries
      const maxWaitSeconds = 15;
      final stopwatch = Stopwatch()..start();

      while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final latest = poller.latest;
        final renderedFrames = controller.snapshot.session?.renderedFrames ?? 0;
        final hasDimensions =
            latest.effectiveDisplayWidth > 0 &&
            latest.effectiveDisplayHeight > 0;

        if (collectedSummaries.length >= 2 &&
            latest.hasSession &&
            (renderedFrames > 0 || hasDimensions)) {
          break;
        }
      }

      if (collectedSummaries.length < 2) {
        throw Exception(
          'Expected at least 2 emitted summaries, but collected ${collectedSummaries.length}',
        );
      }

      final activeSnapshot = controller.snapshot;
      final renderedFrames = activeSnapshot.session?.renderedFrames ?? 0;
      final hasDisplayDimensions =
          poller.latest.effectiveDisplayWidth > 0 &&
          poller.latest.effectiveDisplayHeight > 0;

      playbackPass =
          activeSnapshot.pass && (renderedFrames > 0 || hasDisplayDimensions);

      if (!playbackPass) {
        throw Exception(
          'Playback verification failed: pass=${activeSnapshot.pass}, '
          'renderedFrames=$renderedFrames, hasDisplayDimensions=$hasDisplayDimensions',
        );
      }

      // Step 6: Validate all status summary invariants and cache telemetry
      bool hasActiveSessionSummary = false;
      bool hasCacheTelemetryAttached = false;
      bool hasPlaybackCacheEnabled = false;

      for (final summary in collectedSummaries) {
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
            summary.progressFraction >= 0.0 && summary.progressFraction <= 1.0;
        final bufferedFractionValid =
            summary.bufferedFraction >= 0.0 && summary.bufferedFraction <= 1.0;
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
            'Summary invariant violation: duration=${summary.durationMs}, '
            'position=${summary.positionMs}, bufferedPos=${summary.bufferedPositionMs}, '
            'bufferedPercent=${summary.bufferedPercent}, progressFraction=${summary.progressFraction}, '
            'bufferedFraction=${summary.bufferedFraction}, cacheBytesRead=${summary.playbackCacheBytesRead}, '
            'cacheSizeBytes=${summary.playbackCacheSizeBytes}, cacheIgnoredCount=${summary.playbackCacheIgnoredCount}',
          );
        }
      }

      if (!hasActiveSessionSummary) {
        throw Exception('None of the collected summaries had hasSession=true');
      }
      if (!hasPlaybackCacheEnabled) {
        throw Exception(
          'None of the collected summaries had playbackCacheEnabled=true',
        );
      }
      if (!hasCacheTelemetryAttached) {
        throw Exception(
          'None of the collected summaries had playbackCacheTelemetryAttached=true',
        );
      }

      final latestSummary = poller.latest;
      final playbackCacheReadObserved =
          latestSummary.playbackCacheBytesRead > 0;

      diagMap['pollerCollectedCount'] = collectedSummaries.length;
      diagMap['hasActiveSession'] = hasActiveSessionSummary;
      diagMap['playbackCacheEnabled'] = latestSummary.playbackCacheEnabled;
      diagMap['playbackCacheTelemetryAttached'] =
          latestSummary.playbackCacheTelemetryAttached;
      diagMap['playbackCacheBytesRead'] = latestSummary.playbackCacheBytesRead;
      diagMap['playbackCacheSizeBytes'] = latestSummary.playbackCacheSizeBytes;
      diagMap['playbackCacheIgnoredCount'] =
          latestSummary.playbackCacheIgnoredCount;
      diagMap['playbackCacheLastIgnoredReason'] =
          latestSummary.playbackCacheLastIgnoredReason;
      diagMap['playbackCacheReadObserved'] = playbackCacheReadObserved;
      diagMap['renderedFrames'] = renderedFrames;
      diagMap['effectiveDisplayWidth'] = latestSummary.effectiveDisplayWidth;
      diagMap['effectiveDisplayHeight'] = latestSummary.effectiveDisplayHeight;

      // Step 7: Test poller stop & dispose without disposing controller
      if (mounted) {
        setState(() {
          _status = 'Step 6/6: Testing poller stop/dispose and final teardown…';
        });
      }

      poller.stop();
      if (poller.isRunning) {
        throw Exception('Poller stop failed: isRunning is still true');
      }

      await poller.dispose();
      if (!poller.isDisposed) {
        throw Exception('Poller dispose failed: isDisposed is false');
      }

      // Underlying controller must not be disposed by poller dispose
      if (controller.isDisposed) {
        throw Exception('Poller dispose disposed the underlying controller');
      }

      // Safe refreshOnce on disposed poller
      final safeDisposedSummary = await poller.refreshOnce();
      diagMap['disposedRefreshSummaryHasSession'] =
          safeDisposedSummary.hasSession;

      // Stop & dispose controller
      final stopSnapshot = await controller.stop();
      if (!stopSnapshot.pass) {
        throw Exception(
          'Controller stop failed: reason=${stopSnapshot.reason}',
        );
      }

      final disposeSnapshot = await controller.dispose();
      if (!disposeSnapshot.pass ||
          disposeSnapshot.state !=
              VGStreamingPlaybackControllerState.disposed) {
        throw Exception('Controller dispose failed');
      }

      pollerPass =
          hasActiveSessionSummary &&
          hasPlaybackCacheEnabled &&
          hasCacheTelemetryAttached &&
          collectedSummaries.length >= 2;

      allPass = prewarmPass && preflightPass && playbackPass && pollerPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      diagMap['error'] = error.toString();
      allPass = false;
    } finally {
      await pollerSub?.cancel();
      if (poller != null && !poller.isDisposed) {
        try {
          await poller.dispose();
        } catch (_) {}
      }
      if (controller != null && !controller.isDisposed) {
        try {
          await controller.dispose();
        } catch (_) {}
      }

      // Final cache clear verification
      try {
        final finalClear = await _cacheClient.clear();
        final finalStatus = await _cacheClient.getStatus();
        diagMap['finalClearPass'] = finalClear.pass;
        diagMap['finalClearState'] = finalClear.state;
        diagMap['finalCacheStatusPass'] = finalStatus.pass;
        diagMap['finalCacheSpaceBytes'] = finalStatus.cacheSpaceBytes;
        diagMap['finalResourceCount'] = finalStatus.resourceCount;
      } catch (e) {
        diagMap['finalClearError'] = e.toString();
      }
    }

    diagMap['pass'] = allPass;
    diagMap['phase'] = 'Phase4C7AE';

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_CACHED_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Cached Streaming Playback Status Poller Verified'
            : 'FAIL: Cached Streaming Playback Status Poller Smoke Failed';
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
