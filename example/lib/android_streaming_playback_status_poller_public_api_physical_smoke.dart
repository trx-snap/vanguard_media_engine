// Copyright (c) Connects — Vanguard Phase 4C7AD.
// Public streaming playback status poller -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Generation of preflight request directly from sourceSet under CONSTRAINED profile.
//   3. Preflight evaluation via VGStreamingPreflightClient.
//   4. Pure-Dart VGStreamingPlaybackDecisionPlanner planning.
//   5. Execution of adaptive streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   6. Attaching VGStreamingPlaybackStatusPoller over VGStreamingPlaybackController.
//   7. Starting the poller and collecting emitted summaries from broadcast Stream<VGStreamingPlaybackStatusSummary>.
//   8. Asserting all status summary invariants:
//      - at least two emitted summaries collected
//      - at least one summary has hasSession == true
//      - durationMs >= -1
//      - positionMs >= 0
//      - bufferedPositionMs >= 0
//      - bufferedPercent in 0..100
//      - progressFraction in 0.0..1.0
//      - bufferedFraction in 0.0..1.0
//      - effectiveDisplayWidth > 0 and effectiveDisplayHeight > 0
//   9. Stopping and disposing poller cleanly without disposing underlying controller.
//  10. Verifying disposed poller refreshOnce() does not throw.
//
// Verification Invariants & Boundaries:
// - Imports ONLY package:vanguard_media_engine/vanguard_media_engine.dart.
// - Does NOT import package:flutter/services.dart.
// - Does NOT construct raw MethodChannel.
// - Tests one stable HLS source without claiming broad protocol proof.
// - Bounded convenience verification only; does not make product feed decisions, ABR policy, or caching policy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingPlaybackStatusPollerPhysicalSmokeApp());
}

class AndroidStreamingPlaybackStatusPollerPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingPlaybackStatusPollerPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingPlaybackStatusPollerPhysicalSmokeApp> createState() =>
      _AndroidStreamingPlaybackStatusPollerPhysicalSmokeAppState();
}

class _AndroidStreamingPlaybackStatusPollerPhysicalSmokeAppState
    extends State<AndroidStreamingPlaybackStatusPollerPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android streaming playback status poller physical smoke…';
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
      _runStatusPollerSmoke();
    });
  }

  Future<void> _runStatusPollerSmoke() async {
    // Settle window for Flutter host
    await Future<void>.delayed(const Duration(seconds: 1));

    bool preflightPass = false;
    bool pollerPass = false;
    bool allPass = false;

    Map<String, dynamic> preflightDiag = <String, dynamic>{};
    Map<String, dynamic> pollerDiag = <String, dynamic>{};
    VGStreamingPlaybackController? controller;
    VGStreamingPlaybackStatusPoller? poller;
    StreamSubscription<VGStreamingPlaybackStatusSummary>? pollerSub;

    final collectedSummaries = <VGStreamingPlaybackStatusSummary>[];

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/4: Building source set and running preflight…';
        });
      }

      // Step 1: Define stable HLS streaming source
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'hls_smoke',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
            initialWidth: 1080,
            initialHeight: 1920,
          ),
        ],
      );

      final preflightRequest = sourceSet.toPreflightRequest(
        requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
      );

      final report = await _preflightClient.evaluate(preflightRequest);
      preflightDiag = Map<String, dynamic>.from(report.diagnostics);

      preflightPass =
          report.phase == 'Phase4C5G' &&
          report.pass == true &&
          report.totalReports == 1 &&
          report.failedReports == 0 &&
          report.advisoryOnly == true &&
          report.playbackMutation == false;

      if (!preflightPass) {
        throw Exception(
          'Preflight failed: pass=${report.pass}, phase=${report.phase}, '
          'failedReports=${report.failedReports}',
        );
      }

      if (mounted) {
        setState(() {
          _status =
              'Step 2/4: Planning playback decision and opening controller…';
        });
      }

      // Step 2: Build decision & open controller
      final decision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: report,
          preference: VGStreamingSourceSelectionPreference.preserveOrder,
        ),
      );

      if (!decision.canOpenPlayback || decision.decision != 'playback_ready') {
        throw Exception(
          'Decision planning failed: canOpenPlayback=${decision.canOpenPlayback}, '
          'decision=${decision.decision}',
        );
      }

      controller = VGStreamingPlaybackController();
      final openSnapshot = await controller.open(decision, startPlayback: true);

      if (!openSnapshot.pass || openSnapshot.textureId == null) {
        throw Exception(
          'Controller open failed: pass=${openSnapshot.pass}, '
          'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}',
        );
      }

      if (mounted) {
        setState(() {
          _currentSnapshot = openSnapshot;
          _status =
              'Step 3/4: Starting status poller and collecting summaries…';
        });
      }

      // Step 3: Instantiate and start VGStreamingPlaybackStatusPoller
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

      // Step 4: Wait for at least 2 emitted summaries and valid display metrics (timeout 15s)
      const maxWaitSeconds = 15;
      final stopwatch = Stopwatch()..start();

      while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
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

      // Assert all status summary invariants
      bool hasActiveSessionSummary = false;
      bool hasDisplayDimensions = false;

      for (final summary in collectedSummaries) {
        if (summary.hasSession) {
          hasActiveSessionSummary = true;
        }
        if (summary.effectiveDisplayWidth > 0 &&
            summary.effectiveDisplayHeight > 0) {
          hasDisplayDimensions = true;
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
      }

      if (!hasActiveSessionSummary) {
        throw Exception('None of the collected summaries had hasSession=true');
      }

      if (!hasDisplayDimensions) {
        throw Exception(
          'None of the collected summaries had effectiveDisplayWidth > 0',
        );
      }

      pollerDiag = {
        'collectedCount': collectedSummaries.length,
        'hasActiveSession': hasActiveSessionSummary,
        'hasDisplayDimensions': hasDisplayDimensions,
        'latest': poller.latest.toJson(),
      };

      if (mounted) {
        setState(() {
          _status = 'Step 4/4: Testing poller stop, dispose, and teardown…';
        });
      }

      // Step 5: Test poller stop & dispose
      poller.stop();
      if (poller.isRunning) {
        throw Exception('Poller stop failed: isRunning is still true');
      }

      await poller.dispose();
      if (!poller.isDisposed) {
        throw Exception('Poller dispose failed: isDisposed is false');
      }

      // Controller should NOT be disposed by poller dispose
      if (controller.isDisposed) {
        throw Exception('Poller dispose disposed the underlying controller');
      }

      // Disposed refreshOnce should not throw
      final safeDisposedSummary = await poller.refreshOnce();
      if (!safeDisposedSummary.hasSession && collectedSummaries.isNotEmpty) {
        // Returned safe latest
      }

      // Stop & dispose controller
      await controller.stop();
      await controller.dispose();

      pollerPass =
          hasActiveSessionSummary &&
          hasDisplayDimensions &&
          collectedSummaries.length >= 2;
      allPass = preflightPass && pollerPass;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
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

    final aggregatedMap = <String, dynamic>{
      'pass': allPass,
      'preflightPass': preflightPass,
      'pollerPass': pollerPass,
      'summariesCount': collectedSummaries.length,
      'preflight': preflightDiag,
      'poller': pollerDiag,
    };

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_PLAYBACK_STATUS_POLLER_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Streaming Playback Status Poller Verified (Preflight: OK, Poller: OK, Dispose: OK)'
            : 'FAIL: Status Poller Smoke Failed';
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
