// Copyright (c) Connects — Vanguard Phase 4C7AO.
// Public streaming playback resilience monitor -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Generation of preflight request directly from sourceSet under CONSTRAINED profile.
//   3. Preflight evaluation via VGStreamingPreflightClient.
//   4. Pure-Dart VGStreamingPlaybackDecisionPlanner planning.
//   5. Execution of adaptive streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   6. Attaching VGStreamingPlaybackStatusPoller over VGStreamingPlaybackController.
//   7. Attaching VGStreamingPlaybackResilienceMonitor over VGStreamingPlaybackStatusPoller.summaries.
//   8. Starting monitor, then poller, and collecting emitted composite VGStreamingPlaybackResilienceSnapshot events.
//   9. Asserting all resilience snapshot invariants:
//      - at least two emitted resilience snapshots collected
//      - latest snapshot status has hasSession == true
//      - latest snapshot status has positive effective display dimensions
//      - latest healthAdvice has advisoryOnly == true & playbackMutation == false
//      - latest recoveryPlan has advisoryOnly == true & playbackMutation == false
//      - latest snapshot has advisoryOnly == true & playbackMutation == false
//      - observable playback progress / render evidence
//  10. Stopping and disposing resilience monitor cleanly without disposing underlying poller or controller.
//  11. Stopping and disposing poller cleanly without disposing underlying controller.
//  12. Verifying disposed monitor evaluateOnce() does not mutate state or throw.
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
  runApp(const AndroidStreamingResilienceMonitorPhysicalSmokeApp());
}

class AndroidStreamingResilienceMonitorPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingResilienceMonitorPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingResilienceMonitorPhysicalSmokeApp> createState() =>
      _AndroidStreamingResilienceMonitorPhysicalSmokeAppState();
}

class _AndroidStreamingResilienceMonitorPhysicalSmokeAppState
    extends State<AndroidStreamingResilienceMonitorPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android streaming playback resilience monitor physical smoke…';
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
      _runResilienceMonitorSmoke();
    });
  }

  Future<void> _runResilienceMonitorSmoke() async {
    // Settle window for Flutter host
    await Future<void>.delayed(const Duration(seconds: 1));

    bool preflightPass = false;
    bool decisionPass = false;
    bool openPass = false;
    bool monitorPass = false;
    bool lifecyclePass = false;
    bool allPass = false;

    bool monitorDisposedPollerAlive = false;
    bool monitorDisposedControllerAlive = false;
    bool pollerDisposedControllerAlive = false;

    Map<String, dynamic> preflightDiag = <String, dynamic>{};
    Map<String, dynamic> decisionDiag = <String, dynamic>{};
    Map<String, dynamic> openDiag = <String, dynamic>{};
    Map<String, dynamic> latestHealthDiag = <String, dynamic>{};
    Map<String, dynamic> latestRecoveryDiag = <String, dynamic>{};
    Map<String, dynamic> latestStatusDiag = <String, dynamic>{};

    VGStreamingPlaybackController? controller;
    VGStreamingPlaybackStatusPoller? poller;
    VGStreamingPlaybackResilienceMonitor? monitor;
    StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? monitorSub;

    final collectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/5: Building source set and running preflight…';
        });
      }

      // Step 1: Define stable HLS streaming source
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'hls_resilience_smoke',
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
      preflightDiag = {
        'phase': report.phase,
        'pass': report.pass,
        'totalReports': report.totalReports,
        'failedReports': report.failedReports,
        'advisoryOnly': report.advisoryOnly,
        'playbackMutation': report.playbackMutation,
      };

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
              'Step 2/5: Planning playback decision and opening controller…';
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

      decisionDiag = {
        'decision': decision.decision,
        'canOpenPlayback': decision.canOpenPlayback,
        'selectedKey': decision.selectedSource?.key,
      };

      decisionPass =
          decision.canOpenPlayback &&
          decision.decision == 'playback_ready' &&
          decision.selectedSource?.key == 'hls_resilience_smoke';

      if (!decisionPass) {
        throw Exception(
          'Decision planning failed: canOpenPlayback=${decision.canOpenPlayback}, '
          'decision=${decision.decision}, selectedKey=${decision.selectedSource?.key}',
        );
      }

      controller = VGStreamingPlaybackController();
      final openSnapshot = await controller.open(decision, startPlayback: true);

      openDiag = {
        'pass': openSnapshot.pass,
        'state': openSnapshot.state.name,
        'textureId': openSnapshot.textureId,
        'reason': openSnapshot.reason,
      };

      openPass = openSnapshot.pass && openSnapshot.textureId != null;

      if (!openPass) {
        throw Exception(
          'Controller open failed: pass=${openSnapshot.pass}, '
          'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}',
        );
      }

      if (mounted) {
        setState(() {
          _currentSnapshot = openSnapshot;
          _status = 'Step 3/5: Setting up poller and resilience monitor…';
        });
      }

      // Step 3: Instantiate poller & resilience monitor
      poller = VGStreamingPlaybackStatusPoller(
        controller: controller,
        config: VGStreamingPlaybackStatusPollerConfig(
          interval: const Duration(milliseconds: 500),
          emitInitialSummary: true,
        ),
      );

      monitor = VGStreamingPlaybackResilienceMonitor(
        summaries: poller.summaries,
        config: VGStreamingPlaybackResilienceMonitorConfig(
          currentOptions: decision.playbackOptions,
          preflightReport: report,
          currentNetworkProfile: VGStreamingNetworkProfile.constrained,
          maxHistoryLength: 8,
          allowAutomaticRetry: false,
        ),
      );

      monitorSub = monitor.snapshots.listen((snapshot) {
        collectedSnapshots.add(snapshot);
        if (mounted && controller != null) {
          setState(() {
            _currentSnapshot = controller!.snapshot;
          });
        }
      });

      // Start monitor, then poller
      monitor.start();
      poller.start();

      if (!monitor.isRunning) {
        throw Exception(
          'Resilience monitor failed to start (isRunning is false)',
        );
      }
      if (!poller.isRunning) {
        throw Exception('Status poller failed to start (isRunning is false)');
      }

      if (mounted) {
        setState(() {
          _status = 'Step 4/5: Collecting resilience snapshots…';
        });
      }

      // Step 4: Wait for at least 2 resilience snapshots and valid metrics (timeout 20s)
      const maxWaitSeconds = 20;
      final stopwatch = Stopwatch()..start();

      while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final latest = monitor.latest;
        if (collectedSnapshots.length >= 2 &&
            latest != null &&
            latest.status.hasSession &&
            latest.status.effectiveDisplayWidth > 0 &&
            latest.status.effectiveDisplayHeight > 0) {
          final progressObserved =
              (controller.snapshot.session?.renderedFrames ?? 0) > 0 ||
              latest.status.isPlaying ||
              latest.status.positionMs > 0 ||
              latest.status.bufferedPositionMs > 0;
          if (progressObserved) {
            break;
          }
        }
      }

      if (collectedSnapshots.length < 2) {
        throw Exception(
          'Expected at least 2 emitted snapshots, but collected ${collectedSnapshots.length}',
        );
      }

      final latestSnap = monitor.latest;
      if (latestSnap == null) {
        throw Exception('Monitor latest snapshot is null after collection');
      }

      // Invariants check
      if (!latestSnap.status.hasSession) {
        throw Exception('Latest snapshot status hasSession is false');
      }
      if (latestSnap.status.effectiveDisplayWidth <= 0 ||
          latestSnap.status.effectiveDisplayHeight <= 0) {
        throw Exception(
          'Latest snapshot effective dimensions non-positive: '
          '${latestSnap.status.effectiveDisplayWidth}x${latestSnap.status.effectiveDisplayHeight}',
        );
      }

      if (!latestSnap.healthAdvice.advisoryOnly ||
          latestSnap.healthAdvice.playbackMutation) {
        throw Exception(
          'Health advice mutation invariants violated: '
          'advisoryOnly=${latestSnap.healthAdvice.advisoryOnly}, '
          'playbackMutation=${latestSnap.healthAdvice.playbackMutation}',
        );
      }

      if (!latestSnap.recoveryPlan.advisoryOnly ||
          latestSnap.recoveryPlan.playbackMutation) {
        throw Exception(
          'Recovery plan mutation invariants violated: '
          'advisoryOnly=${latestSnap.recoveryPlan.advisoryOnly}, '
          'playbackMutation=${latestSnap.recoveryPlan.playbackMutation}',
        );
      }

      if (!latestSnap.advisoryOnly || latestSnap.playbackMutation) {
        throw Exception(
          'Resilience snapshot mutation invariants violated: '
          'advisoryOnly=${latestSnap.advisoryOnly}, '
          'playbackMutation=${latestSnap.playbackMutation}',
        );
      }

      final hasProgressEvidence =
          (controller.snapshot.session?.renderedFrames ?? 0) > 0 ||
          latestSnap.status.isPlaying ||
          latestSnap.status.positionMs > 0 ||
          latestSnap.status.bufferedPositionMs > 0;

      if (!hasProgressEvidence) {
        throw Exception('No playback progress or rendering evidence observed');
      }

      // Assert invariants across all collected snapshots
      for (final snap in collectedSnapshots) {
        if (!snap.advisoryOnly || snap.playbackMutation) {
          throw Exception('Snapshot advisory/mutation invariant violation');
        }
        if (!snap.healthAdvice.advisoryOnly ||
            snap.healthAdvice.playbackMutation) {
          throw Exception(
            'Health advice advisory/mutation invariant violation',
          );
        }
        if (!snap.recoveryPlan.advisoryOnly ||
            snap.recoveryPlan.playbackMutation) {
          throw Exception(
            'Recovery plan advisory/mutation invariant violation',
          );
        }
        if (snap.historyLength < 1 || snap.historyLength > 8) {
          throw Exception(
            'Snapshot historyLength out of bounds: ${snap.historyLength}',
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

        if (!durationValid ||
            !positionValid ||
            !bufferedPosValid ||
            !bufferedPercentValid ||
            !progressFractionValid ||
            !bufferedFractionValid) {
          throw Exception(
            'Status summary metric bounds violation: '
            'duration=${status.durationMs}, position=${status.positionMs}, '
            'bufferedPos=${status.bufferedPositionMs}, bufferedPercent=${status.bufferedPercent}',
          );
        }
      }

      latestHealthDiag = {
        'severity': latestSnap.healthAdvice.severity.name,
        'action': latestSnap.healthAdvice.recommendedAction.name,
        'recommendedNetworkProfile':
            latestSnap.healthAdvice.recommendedNetworkProfile.name,
        'shouldLeaveLowLatency': latestSnap.healthAdvice.shouldLeaveLowLatency,
        'shouldRetry': latestSnap.healthAdvice.shouldRetry,
        'advisoryOnly': latestSnap.healthAdvice.advisoryOnly,
        'playbackMutation': latestSnap.healthAdvice.playbackMutation,
      };

      latestRecoveryDiag = {
        'intent': latestSnap.recoveryPlan.intent.name,
        'urgency': latestSnap.recoveryPlan.urgency.name,
        'shouldReopenPlayback': latestSnap.recoveryPlan.shouldReopenPlayback,
        'requiresHostAction': latestSnap.recoveryPlan.requiresHostAction,
        'canBuildPlaybackOptions':
            latestSnap.recoveryPlan.canBuildPlaybackOptions,
        'advisoryOnly': latestSnap.recoveryPlan.advisoryOnly,
        'playbackMutation': latestSnap.recoveryPlan.playbackMutation,
      };

      latestStatusDiag = {
        'hasSession': latestSnap.status.hasSession,
        'isPlaying': latestSnap.status.isPlaying,
        'positionMs': latestSnap.status.positionMs,
        'bufferedPositionMs': latestSnap.status.bufferedPositionMs,
        'bufferedPercent': latestSnap.status.bufferedPercent,
        'effectiveDisplayWidth': latestSnap.status.effectiveDisplayWidth,
        'effectiveDisplayHeight': latestSnap.status.effectiveDisplayHeight,
        'renderedFrames': controller.snapshot.session?.renderedFrames,
      };

      monitorPass = true;

      if (mounted) {
        setState(() {
          _status = 'Step 5/5: Verifying lifecycle boundaries and teardown…';
        });
      }

      // Step 5: Test monitor stop & dispose without disposing poller or controller
      monitor.stop();
      if (monitor.isRunning) {
        throw Exception('Monitor stop failed: isRunning is still true');
      }

      await monitor.dispose();
      if (!monitor.isDisposed) {
        throw Exception('Monitor dispose failed: isDisposed is false');
      }

      monitorDisposedPollerAlive = !poller.isDisposed;
      monitorDisposedControllerAlive = !controller.isDisposed;

      if (!monitorDisposedPollerAlive) {
        throw Exception('Monitor disposal disposed underlying poller');
      }
      if (!monitorDisposedControllerAlive) {
        throw Exception('Monitor disposal disposed underlying controller');
      }

      // Stop & dispose poller without disposing controller
      poller.stop();
      if (poller.isRunning) {
        throw Exception('Poller stop failed: isRunning is still true');
      }

      await poller.dispose();
      if (!poller.isDisposed) {
        throw Exception('Poller dispose failed: isDisposed is false');
      }

      pollerDisposedControllerAlive = !controller.isDisposed;
      if (!pollerDisposedControllerAlive) {
        throw Exception('Poller disposal disposed underlying controller');
      }

      // Test disposed monitor evaluateOnce does not throw
      final safeDisposedSnap = monitor.evaluateOnce(poller.latest);
      if (!safeDisposedSnap.advisoryOnly || safeDisposedSnap.playbackMutation) {
        throw Exception('Disposed monitor evaluateOnce invariant violated');
      }

      // Stop & dispose controller
      await controller.stop();
      await controller.dispose();

      lifecyclePass =
          monitor.isDisposed &&
          poller.isDisposed &&
          controller.isDisposed &&
          monitorDisposedPollerAlive &&
          monitorDisposedControllerAlive &&
          pollerDisposedControllerAlive;

      allPass =
          preflightPass &&
          decisionPass &&
          openPass &&
          monitorPass &&
          lifecyclePass;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      allPass = false;
    } finally {
      await monitorSub?.cancel();
      if (monitor != null && !monitor.isDisposed) {
        try {
          await monitor.dispose();
        } catch (_) {}
      }
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
      'decisionPass': decisionPass,
      'openPass': openPass,
      'monitorPass': monitorPass,
      'lifecyclePass': lifecyclePass,
      'snapshotsCount': collectedSnapshots.length,
      'preflight': preflightDiag,
      'decision': decisionDiag,
      'open': openDiag,
      'latestHealth': latestHealthDiag,
      'latestRecovery': latestRecoveryDiag,
      'latestStatus': latestStatusDiag,
      'lifecycleBoundaries': {
        'monitorDisposedPollerAlive': monitorDisposedPollerAlive,
        'monitorDisposedControllerAlive': monitorDisposedControllerAlive,
        'pollerDisposedControllerAlive': pollerDisposedControllerAlive,
        'monitorDisposed': monitor?.isDisposed ?? false,
        'pollerDisposed': poller?.isDisposed ?? false,
        'controllerDisposed': controller?.isDisposed ?? false,
      },
    };

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Streaming Playback Resilience Monitor Verified (Preflight: OK, Decision: OK, Monitor: OK, Lifecycle: OK)'
            : 'FAIL: Resilience Monitor Smoke Failed';
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
