// Copyright (c) Connects — Vanguard Phase 4C8G.
// iOS Public streaming playback status poller -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream set (DASH, HLS) via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Composition with synthetic advisory preflight report for selector/controller/poller composition.
//   3. Decision planning with VGStreamingPlaybackDecisionPlanner (preferDash + appleAvPlayer) falling back to HLS.
//   4. Execution of streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   5. Polling controller.refresh() until rendered frames > 0, positive display dimensions, and valid state.
//   6. Attaching VGStreamingPlaybackStatusPoller over VGStreamingPlaybackController.
//   7. Starting the poller and collecting emitted summaries from broadcast Stream<VGStreamingPlaybackStatusSummary>.
//   8. Asserting all status summary invariants:
//      - at least 2 emitted summaries collected
//      - at least one summary has hasSession == true, effectiveDisplayWidth > 0, effectiveDisplayHeight > 0
//      - durationMs >= -1
//      - positionMs >= 0
//      - bufferedPositionMs >= 0
//      - bufferedPercent in 0..100
//      - progressFraction in 0.0..1.0
//      - bufferedFraction in 0.0..1.0
//   9. Asserting poller lifecycle invariants:
//      - isRunning == true after start
//      - stop() makes isRunning == false
//      - await dispose() makes isDisposed == true
//      - poller dispose does NOT dispose underlying controller
//      - await poller.refreshOnce() after dispose returns safely without throwing
//  10. Stopping and cleanly disposing controller.
//
// Verification Invariants & Boundaries:
// - Imports ONLY:
//   - dart:async
//   - dart:convert
//   - dart:io
//   - package:flutter/material.dart
//   - package:vanguard_media_engine/vanguard_media_engine.dart
// - Does NOT import package:flutter/services.dart.
// - Does NOT construct raw MethodChannel.
// - Render through VGStreamingPlaybackTextureView only (no raw Texture widget).
// - Synthetic preflight report used for selector/controller/poller composition only (no native preflight claim).
// - Bounded timeouts across all operations.
// - Emits structured step markers and terminal JSON payload.
// - Exit 0 on pass, exit 1 on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const int _initialWidth = 640;
const int _initialHeight = 360;
const Duration _kOperationTimeout = Duration(seconds: 20);
const Duration _kControlTimeout = Duration(seconds: 8);
const Duration _kPollInterval = Duration(milliseconds: 300);
const Duration _kStatusDeadline = Duration(seconds: 20);
const Duration _kPollerCollectionTimeout = Duration(seconds: 15);

void main() {
  runApp(const IosStreamingPlaybackStatusPollerPublicApiPhysicalSmokeApp());
}

class IosStreamingPlaybackStatusPollerPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingPlaybackStatusPollerPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingPlaybackStatusPollerPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingPlaybackStatusPollerPublicApiPhysicalSmokeAppState();
}

class _IosStreamingPlaybackStatusPollerPublicApiPhysicalSmokeAppState
    extends State<IosStreamingPlaybackStatusPollerPublicApiPhysicalSmokeApp> {
  String _status =
      'Bootstrapping iOS streaming playback status poller smoke...';
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
    print('IOS_STREAMING_STATUS_POLLER_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print('IOS_STREAMING_STATUS_POLLER_BOOTSTRAP_ERROR: $error\n$stack');
        // ignore: avoid_print
        print('IOS_STREAMING_STATUS_POLLER_PUBLIC_API_PHYSICAL_FAIL');
        exit(1);
      }
    });
  }

  Future<void> _runSmoke() async {
    final results = <String, dynamic>{
      'phase': 'Phase4C8G',
      'target': 'ios_physical',
    };
    bool allPass = false;

    VGStreamingPlaybackController? controller;
    VGStreamingPlaybackStatusPoller? poller;
    StreamSubscription<VGStreamingPlaybackStatusSummary>? pollerSub;
    final collectedSummaries = <VGStreamingPlaybackStatusSummary>[];

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 1: Define Candidate Sources & Synthetic Preflight Report
      // ═══════════════════════════════════════════════════════════════════════
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'dash',
            uri: Uri.parse(
              'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
            ),
            formatHint: VGStreamingFormatHint.dash,
            initialWidth: _initialWidth,
            initialHeight: _initialHeight,
          ),
          VGStreamingSourceDescriptor(
            key: 'hls',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
            initialWidth: _initialWidth,
            initialHeight: _initialHeight,
          ),
        ],
      );

      const syntheticPreflightReport = VGStreamingPreflightReport(
        pass: true,
        phase: 'Phase4C5G',
        advisoryDecision: 'advise_stable',
        requestedNetworkProfile: 'AUTO',
        recommendedNetworkProfile: 'STABLE',
        recommendedNetworkPolicy: <String, Object?>{
          'profile': 'STABLE',
          'pass': true,
        },
        totalReports: 2,
        passedReports: 2,
        failedReports: 0,
        warnings: <String>[],
        deviceWarnings: <String>[],
        llHlsAvailable: false,
        advisoryOnly: true,
        playbackMutation: false,
        serverLadderPolicy: 'valid',
        iosMirrorNote: 'synthetic_preflight_for_selector_composition',
        raw: 'status=OK;phase=Phase4C5G',
        diagnostics: <String, Object?>{'pass': true, 'phase': 'Phase4C5G'},
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 2: Plan HLS Fallback Decision
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_PLAN: START');
      if (mounted) {
        setState(() {
          _status = 'Planning HLS fallback from preferDash...';
        });
      }

      final decision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: syntheticPreflightReport,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      if (!decision.canOpenPlayback ||
          decision.decision != 'playback_ready' ||
          decision.selectedKey != 'hls' ||
          decision.playbackOptions?.formatHint != VGStreamingFormatHint.hls ||
          !decision.warnings.contains(
            'source_incompatible:dash:dash_not_supported',
          )) {
        throw Exception(
          'Decision planning assertion failed: canOpenPlayback=${decision.canOpenPlayback}, '
          'decision=${decision.decision}, selectedKey=${decision.selectedKey}, '
          'formatHint=${decision.playbackOptions?.formatHint}, warnings=${decision.warnings}',
        );
      }

      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_PLAN: DONE');

      // ═══════════════════════════════════════════════════════════════════════
      // Step 3: Open Controller & Start Playback
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_OPEN: START');
      if (mounted) {
        setState(() {
          _status = 'Opening streaming playback controller...';
        });
      }

      controller = VGStreamingPlaybackController();
      final openSnapshot = await controller
          .open(decision, startPlayback: true)
          .timeout(_kOperationTimeout);

      if (!openSnapshot.pass || openSnapshot.textureId == null) {
        throw Exception(
          'Controller open failed: pass=${openSnapshot.pass}, '
          'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}, '
          'textureId=${openSnapshot.textureId}',
        );
      }

      if (mounted) {
        setState(() {
          _currentSnapshot = openSnapshot;
          _status =
              'Controller active (textureId=${openSnapshot.textureId}), waiting for initial rendered frames...';
        });
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_STATUS_POLLER_STEP_OPEN: DONE (textureId=${openSnapshot.textureId})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 4: Poll controller.refresh() until frames > 0
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_STATUS: START');
      final deadline = DateTime.now().add(_kStatusDeadline);
      VGStreamingPlaybackControllerSnapshot? initialRenderedSnapshot;

      while (DateTime.now().isBefore(deadline)) {
        final refreshed = await controller.refresh().timeout(_kControlTimeout);
        if (mounted) {
          setState(() {
            _currentSnapshot = refreshed;
          });
        }

        final session = refreshed.session;
        if (session != null &&
            session.renderedFrames > 0 &&
            session.effectiveDisplayWidth > 0 &&
            session.effectiveDisplayHeight > 0 &&
            refreshed.state != VGStreamingPlaybackControllerState.failed &&
            refreshed.state != VGStreamingPlaybackControllerState.unsupported) {
          initialRenderedSnapshot = refreshed;
          break;
        }
        await Future<void>.delayed(_kPollInterval);
      }

      if (initialRenderedSnapshot == null) {
        final lastRefreshed = await controller.refresh().timeout(
          _kControlTimeout,
        );
        throw Exception(
          'Initial status verification timed out: renderedFrames=${lastRefreshed.session?.renderedFrames}, '
          'state=${lastRefreshed.state.name}, dims=${lastRefreshed.session?.effectiveDisplayWidth}x${lastRefreshed.session?.effectiveDisplayHeight}, '
          'raw=${lastRefreshed.session?.raw}',
        );
      }

      final initialSession = initialRenderedSnapshot.session!;
      // ignore: avoid_print
      print(
        'IOS_STREAMING_STATUS_POLLER_STEP_STATUS: DONE (renderedFrames=${initialSession.renderedFrames}, dims=${initialSession.effectiveDisplayWidth}x${initialSession.effectiveDisplayHeight})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 5: Create and Start Status Poller
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_START: START');
      if (mounted) {
        setState(() {
          _status =
              'Instantiating and starting VGStreamingPlaybackStatusPoller...';
        });
      }

      poller = VGStreamingPlaybackStatusPoller(
        controller: controller,
        config: VGStreamingPlaybackStatusPollerConfig(
          interval: const Duration(milliseconds: 300),
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

      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_START: DONE');

      // ═══════════════════════════════════════════════════════════════════════
      // Step 6: Collect Summaries and Assert Invariants
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_COLLECT: START');
      if (mounted) {
        setState(() {
          _status = 'Collecting status summaries from poller...';
        });
      }

      final collectDeadline = DateTime.now().add(_kPollerCollectionTimeout);
      while (DateTime.now().isBefore(collectDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final latest = poller.latest;
        if (collectedSummaries.length >= 2 &&
            latest.hasSession &&
            latest.effectiveDisplayWidth > 0 &&
            latest.effectiveDisplayHeight > 0) {
          break;
        }
      }

      if (collectedSummaries.length < 2) {
        throw Exception(
          'Expected at least 2 emitted summaries, but collected ${collectedSummaries.length}',
        );
      }

      bool hasValidSessionSummary = false;
      for (final summary in collectedSummaries) {
        final durationValid = summary.durationMs >= -1;
        final positionValid = summary.positionMs >= 0;
        final bufferedPosValid = summary.bufferedPositionMs >= 0;
        final bufferedPercentValid =
            summary.bufferedPercent >= 0 && summary.bufferedPercent <= 100;
        final progressFractionValid =
            summary.progressFraction >= 0.0 && summary.progressFraction <= 1.0;
        final bufferedFractionValid =
            summary.bufferedFraction >= 0.0 && summary.bufferedFraction <= 1.0;

        if (!durationValid ||
            !positionValid ||
            !bufferedPosValid ||
            !bufferedPercentValid ||
            !progressFractionValid ||
            !bufferedFractionValid) {
          throw Exception(
            'Summary bounds violation: duration=${summary.durationMs}, '
            'position=${summary.positionMs}, bufferedPos=${summary.bufferedPositionMs}, '
            'bufferedPercent=${summary.bufferedPercent}, progressFraction=${summary.progressFraction}, '
            'bufferedFraction=${summary.bufferedFraction}',
          );
        }

        if (summary.hasSession &&
            summary.effectiveDisplayWidth > 0 &&
            summary.effectiveDisplayHeight > 0) {
          hasValidSessionSummary = true;
        }
      }

      if (!hasValidSessionSummary) {
        throw Exception(
          'None of the collected summaries satisfied hasSession==true with positive dimensions',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_STATUS_POLLER_STEP_COLLECT: DONE (collectedCount=${collectedSummaries.length})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 7: Poller Stop Lifecycle
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_STOP: START');
      poller.stop();
      if (poller.isRunning) {
        throw Exception('Poller stop failed: isRunning is still true');
      }
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_STOP: DONE');

      // ═══════════════════════════════════════════════════════════════════════
      // Step 8: Poller Dispose Lifecycle
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_DISPOSE: START');
      await poller.dispose();
      if (!poller.isDisposed) {
        throw Exception('Poller dispose failed: isDisposed is false');
      }

      if (controller.isDisposed) {
        throw Exception('Poller dispose disposed the underlying controller');
      }

      // Safe refreshOnce() on disposed poller must not throw
      final safeDisposedSummary = await poller.refreshOnce();
      if (!safeDisposedSummary.hasSession && collectedSummaries.isNotEmpty) {
        // Returned safe summary
      }
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_DISPOSE: DONE');

      // ═══════════════════════════════════════════════════════════════════════
      // Step 9: Controller Teardown
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_CONTROLLER_DISPOSE: START');
      await controller.stop().timeout(_kControlTimeout);
      final disposeSnapshot = await controller.dispose().timeout(
        _kControlTimeout,
      );
      if (mounted) {
        setState(() {
          _currentSnapshot = disposeSnapshot;
        });
      }
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_STEP_CONTROLLER_DISPOSE: DONE');

      allPass = true;
      results['pass'] = true;
      results['selectedKey'] = decision.selectedKey;
      results['textureId'] = openSnapshot.textureId;
      results['renderedFrames'] =
          initialRenderedSnapshot.session?.renderedFrames ?? 0;
      results['summariesCount'] = collectedSummaries.length;
      results['latestSummary'] = poller.latest.toJson();
      results['warnings'] = decision.warnings;
      results['raw'] = initialRenderedSnapshot.session?.raw;
    } catch (error, stack) {
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_PHYSICAL_ERROR: $error\n$stack');
      results['pass'] = false;
      results['error'] = error.toString();
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
    }

    // Emit final JSON marker
    // ignore: avoid_print
    print(
      'IOS_STREAMING_STATUS_POLLER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_STATUS_POLLER_PUBLIC_API_PHYSICAL_FAIL');
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (Poller collected ${collectedSummaries.length} summaries, lifecycle verified)'
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
