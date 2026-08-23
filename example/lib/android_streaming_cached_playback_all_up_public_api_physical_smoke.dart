// Copyright (c) Connects — Vanguard Phase 4C6M.
// Public cache prewarm -> playback controller/view all-up physical smoke.
//
// Sequentially verifies:
//   1. Definition of candidate streams via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor:
//      - 'hls' (Mux HLS with cache enabled)
//      - 'dash' (Shaka DASH with cache enabled)
//      - 'll_hls' (Mux LL-HLS with requireLlHlsTags: true)
//   2. Bounded cache prewarm planning via VGStreamingCachePrewarmPlanner:
//      - sourceKeys: ['hls', 'll_hls'], lowLatencyPolicy: skipLowLatency, requestIdPrefix: 'phase4c6m'
//      - asserts exactly 1 planned request for 'hls', 'll_hls' skipped with constraint warning
//   3. Dispatching planned prewarm request via VGStreamingCacheClient.prewarmRequest extension:
//      - polling getPrewarmStatus until succeeded
//      - asserting bytesCached > 0, cacheAvailable == true
//      - asserting getStatus cacheSpaceBytes >= bytesCached and resourceCount >= 1
//   4. Streaming preflight evaluation via VGStreamingPreflightClient under CONSTRAINED network profile:
//      - asserts phase Phase4C5G, pass true, totalReports 3, failedReports 0, advisoryOnly true, playbackMutation false
//   5. Streaming playback decision planning via VGStreamingPlaybackDecisionPlanner:
//      - preferredKeys: ['hls']
//      - asserts canOpenPlayback == true, decision == 'playback_ready', selectedKey == 'hls', playbackOptions.cacheOptions.cacheEnabled == true
//   6. Adaptive streaming playback execution via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView:
//      - open(decision, startPlayback: true) allocating textureId
//      - presentation via VGStreamingPlaybackTextureView
//      - polling controller.refresh() until renderedFrames > 0
//      - pause(), optional safe seek(), play(), stop(), dispose()
//      - asserting controller snapshot state is disposed
//   7. Resource cleanup and teardown in finally block (controller disposal + cache clear).
//
// Verification Invariants & Boundaries:
// - Imports ONLY package:vanguard_media_engine/vanguard_media_engine.dart.
// - No direct MethodChannel or package:flutter/services.dart imports.
// - Presentation via VGStreamingPlaybackTextureView (no direct raw Flutter Texture widget).
// - Proof of public API composition and bounded cache prewarm, not proof that ExoPlayer subsequently reads all segments from cache.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingCachedPlaybackAllUpPublicApiPhysicalSmokeApp());
}

class AndroidStreamingCachedPlaybackAllUpPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingCachedPlaybackAllUpPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<AndroidStreamingCachedPlaybackAllUpPublicApiPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingCachedPlaybackAllUpPublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingCachedPlaybackAllUpPublicApiPhysicalSmokeAppState
    extends
        State<AndroidStreamingCachedPlaybackAllUpPublicApiPhysicalSmokeApp> {
  final VGStreamingCacheClient _cacheClient = VGStreamingCacheClient();
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android streaming cached playback all-up public API smoke…';
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
      _runAllUpSmoke();
    });
  }

  Future<void> _runAllUpSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    bool pass = false;
    final diagMap = <String, dynamic>{};
    VGStreamingPlaybackController? controller;

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/6: Defining streaming candidate source set…';
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

      // Step 2: Cache Proof Path - Initial Clear & Prewarm Planning
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
        requestIdPrefix: 'phase4c6m',
        sourceKeys: const ['hls', 'll_hls'],
        maxBytes: 2 * 1024 * 1024,
        lowLatencyPolicy:
            VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
      );

      diagMap['prewarmPlanRequestCount'] = prewarmPlan.requests.length;
      diagMap['prewarmPlanSkippedKeys'] = prewarmPlan.skippedKeys;
      diagMap['prewarmPlanWarnings'] = prewarmPlan.warnings;
      diagMap['prewarmPlanDiagnostics'] = prewarmPlan.diagnostics;

      if (prewarmPlan.requests.length != 1) {
        throw Exception(
          'Expected prewarm plan to have exactly 1 request, got ${prewarmPlan.requests.length}',
        );
      }
      final prewarmReq = prewarmPlan.requests.single;
      if (prewarmReq.requestId != 'phase4c6m_hls_0') {
        throw Exception(
          'Expected prewarm requestId "phase4c6m_hls_0", got "${prewarmReq.requestId}"',
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

      // Step 3: Dispatch prewarmRequest and poll status
      final startResult = await _cacheClient.prewarmRequest(prewarmReq);
      diagMap['prewarmStartPhase'] = startResult.phase;
      diagMap['prewarmStartState'] = startResult.state.name;
      diagMap['prewarmStartPass'] = startResult.pass;
      diagMap['prewarmStartRequestId'] = startResult.requestId;

      if (startResult.state != VGPlaybackPrewarmStartState.accepted &&
          startResult.state != VGPlaybackPrewarmStartState.duplicate) {
        throw Exception(
          'prewarmRequest failed to start: state=${startResult.state.name}, raw=${startResult.raw}',
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
        diagMap['lastPollState'] = pollStatus.state.name;
        diagMap['lastBytesCached'] = pollStatus.bytesCached;
        diagMap['pollCacheAvailable'] = pollStatus.cacheAvailable;

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
          'Prewarm final state is not succeeded: ${finalPrewarmStatus.state.name} (${finalPrewarmStatus.raw})',
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

      // Verify getStatus metrics
      final statusMetrics = await _cacheClient.getStatus();
      diagMap['cacheStatusPass'] = statusMetrics.pass;
      diagMap['cacheStatusAvailable'] = statusMetrics.cacheAvailable;
      diagMap['cacheSpaceBytes'] = statusMetrics.cacheSpaceBytes;
      diagMap['resourceCount'] = statusMetrics.resourceCount;

      if (!statusMetrics.pass || !statusMetrics.cacheAvailable) {
        throw Exception(
          'getStatus failed: pass=${statusMetrics.pass}, cacheAvailable=${statusMetrics.cacheAvailable}',
        );
      }
      if (statusMetrics.cacheSpaceBytes < finalPrewarmStatus.bytesCached) {
        throw Exception(
          'cacheSpaceBytes (${statusMetrics.cacheSpaceBytes}) is less than bytesCached (${finalPrewarmStatus.bytesCached})',
        );
      }
      if (statusMetrics.resourceCount < 1) {
        throw Exception(
          'resourceCount (${statusMetrics.resourceCount}) is less than 1',
        );
      }

      // Step 4: Evaluate Preflight Advisory
      if (mounted) {
        setState(() {
          _status = 'Step 3/6: Evaluating preflight advisory…';
        });
      }

      final manifestSpecs = sourceSet.sources.map((source) {
        return VGStreamingManifestSpec(
          key: source.key,
          uri: source.uri,
          formatHint: source.formatHint,
          requireAdaptiveLadder: source.requireAdaptiveLadder,
          requireAvcFallback: source.requireAvcFallback,
          requireLlHlsTags: false,
          allowMediaPlaylist: source.allowMediaPlaylist,
        );
      }).toList();

      final preflightRequest = VGStreamingPreflightRequest(
        manifests: manifestSpecs,
        requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
        preferLowLatency: false,
        allowLowLatencyOnConstrained: false,
      );

      final preflightReport = await _preflightClient.evaluate(preflightRequest);
      diagMap['preflightPhase'] = preflightReport.phase;
      diagMap['preflightPass'] = preflightReport.pass;
      diagMap['preflightTotalReports'] = preflightReport.totalReports;
      diagMap['preflightFailedReports'] = preflightReport.failedReports;
      diagMap['preflightAdvisoryOnly'] = preflightReport.advisoryOnly;
      diagMap['preflightPlaybackMutation'] = preflightReport.playbackMutation;

      final preflightPass =
          preflightReport.phase == 'Phase4C5G' &&
          preflightReport.pass == true &&
          preflightReport.totalReports == 3 &&
          preflightReport.failedReports == 0 &&
          preflightReport.advisoryOnly == true &&
          preflightReport.playbackMutation == false;

      if (!preflightPass) {
        throw Exception(
          'Preflight assertion failed: phase=${preflightReport.phase}, pass=${preflightReport.pass}, '
          'total=${preflightReport.totalReports}, failed=${preflightReport.failedReports}, '
          'advisoryOnly=${preflightReport.advisoryOnly}, playbackMutation=${preflightReport.playbackMutation}',
        );
      }

      // Step 5: Plan Playback Decision
      if (mounted) {
        setState(() {
          _status = 'Step 4/6: Planning playback decision…';
        });
      }

      final decision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: preflightReport,
          preference: VGStreamingSourceSelectionPreference.preserveOrder,
          preferredKeys: const ['hls'],
        ),
      );

      diagMap['decisionCanOpen'] = decision.canOpenPlayback;
      diagMap['decisionValue'] = decision.decision;
      diagMap['decisionSelectedKey'] = decision.selectedKey;
      diagMap['decisionWarnings'] = decision.warnings;
      diagMap['decisionCacheEnabled'] =
          decision.playbackOptions?.cacheOptions?.cacheEnabled;

      if (!decision.canOpenPlayback) {
        throw Exception(
          'Planner canOpenPlayback was false: decision=${decision.decision}, warnings=${decision.warnings}',
        );
      }
      if (decision.decision != 'playback_ready') {
        throw Exception(
          'Planner decision was "${decision.decision}" (expected "playback_ready")',
        );
      }
      if (decision.selectedKey != 'hls') {
        throw Exception(
          'Planner key mismatch: selectedKey=${decision.selectedKey} (expected "hls")',
        );
      }
      if (decision.playbackOptions?.cacheOptions?.cacheEnabled != true) {
        throw Exception(
          'Expected playbackOptions.cacheOptions.cacheEnabled to be true, got ${decision.playbackOptions?.cacheOptions?.cacheEnabled}',
        );
      }

      // Step 6: Execute Playback via Controller & Presentation via View
      if (mounted) {
        setState(() {
          _status =
              'Step 5/6: Opening playback session for ${decision.selectedKey}…';
        });
      }

      controller = VGStreamingPlaybackController();
      final openSnapshot = await controller.open(decision, startPlayback: true);

      diagMap['openPass'] = openSnapshot.pass;
      diagMap['openState'] = openSnapshot.state.name;
      diagMap['openTextureId'] = openSnapshot.textureId;
      diagMap['openReason'] = openSnapshot.reason;

      if (!openSnapshot.pass || openSnapshot.textureId == null) {
        throw Exception(
          'Controller open failed: pass=${openSnapshot.pass}, '
          'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}, textureId=${openSnapshot.textureId}',
        );
      }

      final activeTextureId = openSnapshot.textureId!;
      if (mounted) {
        setState(() {
          _currentSnapshot = openSnapshot;
          _status =
              'Playback active (textureId=$activeTextureId), waiting for frames…';
        });
      }

      // Poll controller.refresh() until renderedFrames > 0 (up to 12s)
      const maxWaitSeconds = 12;
      final stopwatch = Stopwatch()..start();
      VGStreamingPlaybackControllerSnapshot refreshSnapshot = openSnapshot;
      int renderedFrames = 0;
      int durationMs = -1;

      while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        refreshSnapshot = await controller.refresh();
        renderedFrames = refreshSnapshot.session?.renderedFrames ?? 0;
        durationMs = refreshSnapshot.session?.durationMs ?? -1;
        if (mounted) {
          setState(() {
            _currentSnapshot = refreshSnapshot;
          });
        }
        if (renderedFrames > 0) {
          break;
        }
      }

      diagMap['playbackRenderedFrames'] = renderedFrames;
      diagMap['playbackDurationMs'] = durationMs;
      diagMap['playbackRefreshState'] = refreshSnapshot.state.name;

      if (renderedFrames <= 0) {
        throw Exception(
          'No rendered frames after ${stopwatch.elapsed.inSeconds}s (renderedFrames=$renderedFrames)',
        );
      }

      // Pause
      if (mounted) {
        setState(() {
          _status = 'Step 6/6: Exercising pause, seek, play, stop, dispose…';
        });
      }

      final pauseSnapshot = await controller.pause();
      if (!pauseSnapshot.pass) {
        throw Exception(
          'Controller pause failed: reason=${pauseSnapshot.reason}',
        );
      }
      if (mounted) {
        setState(() {
          _currentSnapshot = pauseSnapshot;
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Optional safe seek if duration allows
      if (durationMs > 2000) {
        final seekTargetMs = (durationMs ~/ 4).clamp(1000, 8000);
        final seekSnapshot = await controller.seek(seekTargetMs);
        if (!seekSnapshot.pass) {
          throw Exception(
            'Controller seek failed: reason=${seekSnapshot.reason}',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = seekSnapshot;
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      // Play resume
      final playSnapshot = await controller.play();
      if (!playSnapshot.pass) {
        throw Exception(
          'Controller play resume failed: reason=${playSnapshot.reason}',
        );
      }
      if (mounted) {
        setState(() {
          _currentSnapshot = playSnapshot;
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Stop
      final stopSnapshot = await controller.stop();
      if (!stopSnapshot.pass) {
        throw Exception(
          'Controller stop failed: reason=${stopSnapshot.reason}',
        );
      }
      if (mounted) {
        setState(() {
          _currentSnapshot = stopSnapshot;
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Dispose
      final disposeSnapshot = await controller.dispose();
      if (!disposeSnapshot.pass ||
          disposeSnapshot.state !=
              VGStreamingPlaybackControllerState.disposed) {
        throw Exception(
          'Controller dispose failed: state=${disposeSnapshot.state}, pass=${disposeSnapshot.pass}',
        );
      }
      if (mounted) {
        setState(() {
          _currentSnapshot = disposeSnapshot;
        });
      }

      final statusPass = refreshSnapshot.pass;
      final isFailed =
          refreshSnapshot.state == VGStreamingPlaybackControllerState.failed;
      final isDisposed =
          disposeSnapshot.state == VGStreamingPlaybackControllerState.disposed;

      pass = statusPass && renderedFrames > 0 && !isFailed && isDisposed;

      diagMap['phase'] = 'Phase4C6M';
      diagMap['pass'] = pass;
      diagMap['raw'] =
          'status=PASS;bytesCached=${finalPrewarmStatus.bytesCached};'
          'cacheSpaceBytes=${statusMetrics.cacheSpaceBytes};'
          'resourceCount=${statusMetrics.resourceCount};'
          'selectedKey=${decision.selectedKey};'
          'renderedFrames=$renderedFrames;'
          'finalState=${disposeSnapshot.state.name}';
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CACHED_PLAYBACK_ALL_UP_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      diagMap['pass'] = false;
      diagMap['phase'] = 'Phase4C6M';
      diagMap['raw'] = 'status=FAIL;reason=dart_exception:$error';
      pass = false;
    } finally {
      // Always ensure controller is disposed
      if (controller != null && !controller.isDisposed) {
        try {
          await controller.dispose();
        } catch (e) {
          // ignore: avoid_print
          print('Dispose error in finally: $e');
        }
      }
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
      'ANDROID_STREAMING_CACHED_PLAYBACK_ALL_UP_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_CACHED_PLAYBACK_ALL_UP_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_CACHED_PLAYBACK_ALL_UP_PUBLIC_API_PHYSICAL_FAIL',
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
