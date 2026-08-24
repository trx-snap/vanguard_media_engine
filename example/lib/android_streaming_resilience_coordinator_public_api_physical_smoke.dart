// Copyright (c) Connects — Vanguard Phase 4C7AY.
// Public streaming playback resilience coordinator -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Generation of preflight request directly from sourceSet under CONSTRAINED profile.
//   3. Preflight evaluation via VGStreamingPreflightClient.
//   4. Pure-Dart VGStreamingPlaybackDecisionPlanner planning.
//   5. Execution of adaptive streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   6. Attaching VGStreamingPlaybackStatusPoller over VGStreamingPlaybackController.
//   7. Attaching VGStreamingPlaybackResilienceMonitor over VGStreamingPlaybackStatusPoller.summaries.
//   8. Creating pure-Dart VGStreamingPlaybackResilienceCoordinator with bounded retry journal & budget configs.
//   9. Starting monitor, then poller, and collecting emitted composite VGStreamingPlaybackResilienceSnapshot events.
//  10. Evaluating collected snapshots against VGStreamingPlaybackResilienceCoordinator using deterministic nowMs.
//  11. Asserting all coordinator evaluation & component invariants:
//      - at least two emitted resilience snapshots collected
//      - evaluation.advisoryOnly == true
//      - evaluation.playbackMutation == false
//      - evaluation.decision.advisoryOnly == true
//      - evaluation.decision.playbackMutation == false
//      - evaluation.retryBudget.advisoryOnly == true
//      - evaluation.retryBudget.playbackMutation == false
//      - evaluation.journalSnapshot.advisoryOnly == true
//      - evaluation.journalSnapshot.playbackMutation == false
//      - coordinator.length remains 0 after evaluate (no automatic attempt recording)
//      - evaluation.action is one of the public enum values
//      - diagnostics JSON serializes
//      - at least one latest status has session, positive effective display dimensions, and progress/render evidence (renderedFrames > 0 || isPlaying || positionMs > 0 || bufferedPositionMs > 0)
//  12. Stopping and disposing resilience monitor cleanly without disposing underlying poller or controller.
//  13. Stopping and disposing poller cleanly without disposing underlying controller.
//  14. Stopping and disposing controller cleanly.
//  15. Verified non-claim: no real retry is executed and recordHostRetryAttempted() is not called in this smoke.
//
// Verification Invariants & Boundaries:
// - Imports ONLY package:vanguard_media_engine/vanguard_media_engine.dart.
// - Does NOT import package:flutter/services.dart.
// - Does NOT construct raw MethodChannel.
// - Tests one stable HLS source without claiming broad protocol proof.
// - Pure advisory evaluation wrapper; does not make product feed decisions, ABR policy, or caching policy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingResilienceCoordinatorPhysicalSmokeApp());
}

class AndroidStreamingResilienceCoordinatorPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingResilienceCoordinatorPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingResilienceCoordinatorPhysicalSmokeApp> createState() =>
      _AndroidStreamingResilienceCoordinatorPhysicalSmokeAppState();
}

class _AndroidStreamingResilienceCoordinatorPhysicalSmokeAppState
    extends State<AndroidStreamingResilienceCoordinatorPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android streaming playback resilience coordinator physical smoke…';
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
      _runResilienceCoordinatorSmoke();
    });
  }

  Future<void> _runResilienceCoordinatorSmoke() async {
    // Settle window for Flutter host
    await Future<void>.delayed(const Duration(seconds: 1));

    bool preflightPass = false;
    bool decisionPass = false;
    bool openPass = false;
    bool monitorPass = false;
    bool coordinatorPass = false;
    bool lifecyclePass = false;
    bool allPass = false;

    bool monitorDisposedPollerAlive = false;
    bool monitorDisposedControllerAlive = false;
    bool pollerDisposedControllerAlive = false;

    Map<String, dynamic> preflightDiag = <String, dynamic>{};
    Map<String, dynamic> decisionDiag = <String, dynamic>{};
    Map<String, dynamic> openDiag = <String, dynamic>{};
    Map<String, dynamic> coordinatorEvalDiag = <String, dynamic>{};
    Map<String, dynamic> latestStatusDiag = <String, dynamic>{};

    VGStreamingPlaybackController? controller;
    VGStreamingPlaybackStatusPoller? poller;
    VGStreamingPlaybackResilienceMonitor? monitor;
    VGStreamingPlaybackResilienceCoordinator? coordinator;
    StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? monitorSub;

    final collectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/6: Building source set and running preflight…';
        });
      }

      // Step 1: Define stable HLS streaming source
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'hls_resilience_coordinator_smoke',
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
              'Step 2/6: Planning playback decision and opening controller…';
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
          decision.selectedSource?.key == 'hls_resilience_coordinator_smoke';

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
          _status =
              'Step 3/6: Setting up poller, resilience monitor & coordinator…';
        });
      }

      // Step 3: Instantiate poller, resilience monitor & coordinator
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

      coordinator = VGStreamingPlaybackResilienceCoordinator(
        config: const VGStreamingPlaybackResilienceCoordinatorConfig(
          journalConfig: VGStreamingPlaybackRetryJournalConfig(
            maxStoredAttempts: 10,
          ),
          retryBudgetConfig: VGStreamingPlaybackRetryBudgetConfig(
            maxAttempts: 3,
            windowMs: 30000,
            minimumDelayMs: 1000,
          ),
          streamKey: 'hls_resilience_coordinator_smoke',
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
          _status = 'Step 4/6: Collecting resilience snapshots…';
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

      // Assert status invariants
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

      final hasProgressEvidence =
          (controller.snapshot.session?.renderedFrames ?? 0) > 0 ||
          latestSnap.status.isPlaying ||
          latestSnap.status.positionMs > 0 ||
          latestSnap.status.bufferedPositionMs > 0;

      if (!hasProgressEvidence) {
        throw Exception('No playback progress or rendering evidence observed');
      }

      monitorPass = true;

      if (mounted) {
        setState(() {
          _status =
              'Step 5/6: Evaluating snapshots through resilience coordinator…';
        });
      }

      // Step 5: Evaluate collected snapshots through coordinator and assert coordinator invariants
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      VGStreamingPlaybackResilienceCoordinatorEvaluation? latestEvaluation;

      for (int i = 0; i < collectedSnapshots.length; i++) {
        final snap = collectedSnapshots[i];
        final eval = coordinator.evaluate(
          snapshot: snap,
          nowMs: nowMs + (i * 500),
        );

        if (!eval.advisoryOnly || eval.playbackMutation) {
          throw Exception(
            'Coordinator evaluation advisory/mutation invariant violation: '
            'advisoryOnly=${eval.advisoryOnly}, playbackMutation=${eval.playbackMutation}',
          );
        }
        if (!eval.decision.advisoryOnly || eval.decision.playbackMutation) {
          throw Exception(
            'Coordinator decision advisory/mutation invariant violation: '
            'advisoryOnly=${eval.decision.advisoryOnly}, playbackMutation=${eval.decision.playbackMutation}',
          );
        }
        if (!eval.retryBudget.advisoryOnly ||
            eval.retryBudget.playbackMutation) {
          throw Exception(
            'Coordinator retryBudget advisory/mutation invariant violation: '
            'advisoryOnly=${eval.retryBudget.advisoryOnly}, playbackMutation=${eval.retryBudget.playbackMutation}',
          );
        }
        if (!eval.journalSnapshot.advisoryOnly ||
            eval.journalSnapshot.playbackMutation) {
          throw Exception(
            'Coordinator journalSnapshot advisory/mutation invariant violation: '
            'advisoryOnly=${eval.journalSnapshot.advisoryOnly}, playbackMutation=${eval.journalSnapshot.playbackMutation}',
          );
        }

        // Coordinator length must remain 0 (pure advisory evaluate does not auto-record attempts)
        if (coordinator.length != 0) {
          throw Exception(
            'Coordinator length was modified during evaluate: length=${coordinator.length}',
          );
        }

        // Action must be a valid public enum value
        if (!VGStreamingPlaybackResilienceDecisionAction.values.contains(
          eval.action,
        )) {
          throw Exception('Invalid coordinator action: ${eval.action}');
        }

        // Verify JSON serialization roundtrip
        final evalJson = eval.toJson();
        if (evalJson['advisoryOnly'] != true ||
            evalJson['playbackMutation'] != false) {
          throw Exception(
            'Coordinator evaluation JSON serialization invariant violated',
          );
        }

        latestEvaluation = eval;
      }

      if (latestEvaluation == null) {
        throw Exception('Failed to produce coordinator evaluation');
      }

      coordinatorEvalDiag = {
        'action': latestEvaluation.action.name,
        'canRetryNow': latestEvaluation.canRetryNow,
        'shouldRecordAttemptOnHostRetry':
            latestEvaluation.shouldRecordAttemptOnHostRetry,
        'requiresHostAction': latestEvaluation.requiresHostAction,
        'retryAfterMs': latestEvaluation.retryAfterMs,
        'reasons': latestEvaluation.reasons,
        'attemptsInWindow': latestEvaluation.retryBudget.attemptsInWindow,
        'remainingAttempts': latestEvaluation.retryBudget.remainingAttempts,
        'journalCount': latestEvaluation.journalSnapshot.count,
        'coordinatorLength': coordinator.length,
        'advisoryOnly': latestEvaluation.advisoryOnly,
        'playbackMutation': latestEvaluation.playbackMutation,
        'diagnostics': latestEvaluation.diagnostics,
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

      coordinatorPass = true;

      if (mounted) {
        setState(() {
          _status = 'Step 6/6: Verifying lifecycle boundaries and teardown…';
        });
      }

      // Step 6: Test monitor stop & dispose without disposing poller or controller
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
          coordinatorPass &&
          lifecyclePass;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
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
      'coordinatorPass': coordinatorPass,
      'lifecyclePass': lifecyclePass,
      'snapshotsCount': collectedSnapshots.length,
      'preflight': preflightDiag,
      'decision': decisionDiag,
      'open': openDiag,
      'coordinatorEvaluation': coordinatorEvalDiag,
      'latestStatus': latestStatusDiag,
      'lifecycleBoundaries': {
        'monitorDisposedPollerAlive': monitorDisposedPollerAlive,
        'monitorDisposedControllerAlive': monitorDisposedControllerAlive,
        'pollerDisposedControllerAlive': pollerDisposedControllerAlive,
        'monitorDisposed': monitor?.isDisposed ?? false,
        'pollerDisposed': poller?.isDisposed ?? false,
        'controllerDisposed': controller?.isDisposed ?? false,
      },
      'nonClaims': {
        'realRetryExecuted': false,
        'recordHostRetryAttemptedCalled': false,
        'protocolCoverage': 'one_hls_stream_only',
        'advisoryOnly': true,
      },
    };

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Streaming Playback Resilience Coordinator Verified (Preflight: OK, Decision: OK, Monitor: OK, Coordinator: OK, Lifecycle: OK)'
            : 'FAIL: Resilience Coordinator Smoke Failed';
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
