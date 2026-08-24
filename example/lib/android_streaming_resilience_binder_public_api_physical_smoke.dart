// Copyright (c) Connects — Vanguard Phase 4C7BF.
// Public streaming playback resilience binder -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Generation of preflight request directly from sourceSet under CONSTRAINED profile.
//   3. Preflight evaluation via VGStreamingPreflightClient.
//   4. Pure-Dart VGStreamingPlaybackDecisionPlanner planning.
//   5. Execution of adaptive streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   6. Attaching VGStreamingPlaybackStatusPoller with 500ms interval and emitInitialSummary true over VGStreamingPlaybackController.
//   7. Attaching VGStreamingPlaybackResilienceMonitor over VGStreamingPlaybackStatusPoller.summaries.
//   8. Creating pure-Dart VGStreamingPlaybackResilienceCoordinator with bounded retry journal & budget configs.
//   9. Creating pure-Dart VGStreamingPlaybackResilienceBinder over monitor.snapshots with coordinator and deterministic nowProvider.
//  10. Starting binder, calling binder.start() a second time (verifying idempotent no duplicate subscription), then starting monitor and poller.
//  11. Waiting up to 20s for at least two snapshots, at least two binder evaluations, and real playback evidence.
//  12. Asserting all binder evaluation & coordinator invariants:
//      - evaluation.advisoryOnly == true
//      - evaluation.playbackMutation == false
//      - evaluation.decision.advisoryOnly == true
//      - evaluation.decision.playbackMutation == false
//      - evaluation.retryBudget.advisoryOnly == true
//      - evaluation.retryBudget.playbackMutation == false
//      - evaluation.journalSnapshot.advisoryOnly == true
//      - evaluation.journalSnapshot.playbackMutation == false
//      - evaluation.diagnostics['streamKey'] == 'hls_resilience_binder_smoke'
//      - evaluation.toJson() advisoryOnly true and playbackMutation false
//      - coordinator.length == 0 and coordinator.journalSnapshot().count == 0 (no automatic attempt recording)
//      - binder.latest is not null and matches latest collected evaluation
//  13. Stopping binder and asserting binder.isRunning false and binder.isDisposed false.
//  14. While stopped, triggering monitor.evaluateOnce(latest status) and verifying binder evaluation count does not increase.
//  15. Calling binder.evaluateOnce(latest monitor snapshot) while stopped; asserting it emits one new evaluation, updates latest, preserves advisory/no-mutation invariants, and coordinator journal remains zero.
//  16. Restarting binder, triggering monitor.evaluateOnce(latest status), and verifying exactly one additional binder evaluation arrives.
//  17. Disposing binder and asserting binder.isDisposed true, binder.isRunning false, and monitor/poller/controller remain undisposed. Verifying start after dispose is a no-op.
//  18. Disposing monitor, then poller, then stopping/disposing controller cleanly.
//  19. Verified non-claim: no real retry is executed and recordHostRetryAttempted() is not called in this smoke.
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
  runApp(const AndroidStreamingResilienceBinderPhysicalSmokeApp());
}

class AndroidStreamingResilienceBinderPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingResilienceBinderPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingResilienceBinderPhysicalSmokeApp> createState() =>
      _AndroidStreamingResilienceBinderPhysicalSmokeAppState();
}

class _AndroidStreamingResilienceBinderPhysicalSmokeAppState
    extends State<AndroidStreamingResilienceBinderPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android streaming playback resilience binder physical smoke…';
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
      _runResilienceBinderSmoke();
    });
  }

  Future<void> _runResilienceBinderSmoke() async {
    // Settle window for Flutter host
    await Future<void>.delayed(const Duration(seconds: 1));

    bool preflightPass = false;
    bool decisionPass = false;
    bool openPass = false;
    bool binderPass = false;
    bool lifecyclePass = false;
    bool allPass = false;

    bool binderDisposedMonitorAlive = false;
    bool binderDisposedPollerAlive = false;
    bool binderDisposedControllerAlive = false;
    bool monitorDisposedPollerAlive = false;
    bool monitorDisposedControllerAlive = false;
    bool pollerDisposedControllerAlive = false;

    Map<String, dynamic> preflightDiag = <String, dynamic>{};
    Map<String, dynamic> decisionDiag = <String, dynamic>{};
    Map<String, dynamic> openDiag = <String, dynamic>{};
    Map<String, dynamic> latestEvaluationDiag = <String, dynamic>{};
    Map<String, dynamic> latestStatusDiag = <String, dynamic>{};

    VGStreamingPlaybackController? controller;
    VGStreamingPlaybackStatusPoller? poller;
    VGStreamingPlaybackResilienceMonitor? monitor;
    VGStreamingPlaybackResilienceCoordinator? coordinator;
    VGStreamingPlaybackResilienceBinder? binder;
    StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? monitorSub;
    StreamSubscription<VGStreamingPlaybackResilienceCoordinatorEvaluation>?
    binderSub;

    final collectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
    final collectedEvaluations =
        <VGStreamingPlaybackResilienceCoordinatorEvaluation>[];

    int nowCounter = 1700000000000;
    int deterministicNow() {
      nowCounter += 500;
      return nowCounter;
    }

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/7: Building source set and running preflight…';
        });
      }

      // Step 1: Define stable HLS streaming source
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'hls_resilience_binder_smoke',
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
              'Step 2/7: Planning playback decision and opening controller…';
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
          decision.selectedSource?.key == 'hls_resilience_binder_smoke';

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
              'Step 3/7: Creating poller, resilience monitor, coordinator & binder…';
        });
      }

      // Step 3: Instantiate poller, resilience monitor, coordinator & binder
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
          streamKey: 'hls_resilience_binder_smoke',
        ),
      );

      binder = VGStreamingPlaybackResilienceBinder(
        snapshots: monitor.snapshots,
        coordinator: coordinator,
        config: const VGStreamingPlaybackResilienceBinderConfig(
          streamKey: 'hls_resilience_binder_smoke',
        ),
        nowProvider: deterministicNow,
      );

      monitorSub = monitor.snapshots.listen((snapshot) {
        collectedSnapshots.add(snapshot);
        if (mounted && controller != null) {
          setState(() {
            _currentSnapshot = controller!.snapshot;
          });
        }
      });

      binderSub = binder.evaluations.listen((evaluation) {
        collectedEvaluations.add(evaluation);
      });

      // Step 4: Start binder, test idempotent start(), then start monitor and poller
      binder.start();
      if (!binder.isRunning) {
        throw Exception('Binder failed to start (isRunning is false)');
      }
      // Call binder.start() a second time to verify idempotent no duplicate subscription
      binder.start();
      if (!binder.isRunning) {
        throw Exception('Binder isRunning became false after second start()');
      }

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
          _status =
              'Step 4/7: Collecting resilience snapshots & binder evaluations…';
        });
      }

      // Step 5: Wait for at least 2 snapshots, at least 2 evaluations, and playback evidence (timeout 20s)
      const maxWaitSeconds = 20;
      final stopwatch = Stopwatch()..start();

      while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final latestSnap = monitor.latest;
        if (collectedSnapshots.length >= 2 &&
            collectedEvaluations.length >= 2 &&
            latestSnap != null &&
            latestSnap.status.hasSession &&
            latestSnap.status.effectiveDisplayWidth > 0 &&
            latestSnap.status.effectiveDisplayHeight > 0) {
          final progressObserved =
              (controller.snapshot.session?.renderedFrames ?? 0) > 0 ||
              latestSnap.status.isPlaying ||
              latestSnap.status.positionMs > 0 ||
              latestSnap.status.bufferedPositionMs > 0;
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

      if (collectedEvaluations.length < 2) {
        throw Exception(
          'Expected at least 2 emitted binder evaluations, but collected ${collectedEvaluations.length}',
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

      // Stop poller now so background timer ticks do not race with baseline counts
      poller.stop();

      // Step 6: Assert invariants across all collected binder evaluations
      for (final eval in collectedEvaluations) {
        if (!eval.advisoryOnly || eval.playbackMutation) {
          throw Exception(
            'Binder evaluation advisory/mutation invariant violation: '
            'advisoryOnly=${eval.advisoryOnly}, playbackMutation=${eval.playbackMutation}',
          );
        }
        if (!eval.decision.advisoryOnly || eval.decision.playbackMutation) {
          throw Exception(
            'Binder decision advisory/mutation invariant violation: '
            'advisoryOnly=${eval.decision.advisoryOnly}, playbackMutation=${eval.decision.playbackMutation}',
          );
        }
        if (!eval.retryBudget.advisoryOnly ||
            eval.retryBudget.playbackMutation) {
          throw Exception(
            'Binder retryBudget advisory/mutation invariant violation: '
            'advisoryOnly=${eval.retryBudget.advisoryOnly}, playbackMutation=${eval.retryBudget.playbackMutation}',
          );
        }
        if (!eval.journalSnapshot.advisoryOnly ||
            eval.journalSnapshot.playbackMutation) {
          throw Exception(
            'Binder journalSnapshot advisory/mutation invariant violation: '
            'advisoryOnly=${eval.journalSnapshot.advisoryOnly}, playbackMutation=${eval.journalSnapshot.playbackMutation}',
          );
        }
        if (eval.diagnostics['streamKey'] != 'hls_resilience_binder_smoke') {
          throw Exception(
            'Binder diagnostics streamKey invariant violation: ${eval.diagnostics['streamKey']}',
          );
        }

        final evalJson = eval.toJson();
        if (evalJson['advisoryOnly'] != true ||
            evalJson['playbackMutation'] != false) {
          throw Exception(
            'Binder evaluation JSON serialization invariant violated',
          );
        }
      }

      // Assert coordinator journal remains zero (no automatic attempt recording)
      if (coordinator.length != 0 || coordinator.journalSnapshot().count != 0) {
        throw Exception(
          'Coordinator journal was modified during binder evaluations: '
          'length=${coordinator.length}, journalCount=${coordinator.journalSnapshot().count}',
        );
      }

      // Assert binder.latest is not null and matches the latest collected evaluation
      if (binder.latest == null) {
        throw Exception('binder.latest is null after receiving evaluations');
      }
      final latestEval = binder.latest!;
      final lastCollected = collectedEvaluations.last;
      if (latestEval.action != lastCollected.action ||
          latestEval.reasons.join(',') != lastCollected.reasons.join(',')) {
        throw Exception(
          'binder.latest does not match last collected evaluation: '
          'latest=${latestEval.action}, lastCollected=${lastCollected.action}',
        );
      }

      latestEvaluationDiag = {
        'action': latestEval.action.name,
        'canRetryNow': latestEval.canRetryNow,
        'shouldRecordAttemptOnHostRetry':
            latestEval.shouldRecordAttemptOnHostRetry,
        'requiresHostAction': latestEval.requiresHostAction,
        'retryAfterMs': latestEval.retryAfterMs,
        'reasons': latestEval.reasons,
        'attemptsInWindow': latestEval.retryBudget.attemptsInWindow,
        'remainingAttempts': latestEval.retryBudget.remainingAttempts,
        'journalCount': latestEval.journalSnapshot.count,
        'coordinatorLength': coordinator.length,
        'advisoryOnly': latestEval.advisoryOnly,
        'playbackMutation': latestEval.playbackMutation,
        'diagnostics': latestEval.diagnostics,
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

      if (mounted) {
        setState(() {
          _status = 'Step 5/7: Testing stop, evaluateOnce & restart lifecycle…';
        });
      }

      // Step 7: Test stop, evaluateOnce while stopped, restart, and subscription lifecycle
      poller.stop();

      binder.stop();
      if (binder.isRunning) {
        throw Exception('Binder stop failed: isRunning is still true');
      }
      if (binder.isDisposed) {
        throw Exception('Binder stop erroneously set isDisposed to true');
      }

      final countBeforeStoppedMonitorEval = collectedEvaluations.length;
      // Trigger monitor.evaluateOnce on latest status while binder is stopped
      monitor.evaluateOnce(latestSnap.status);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (collectedEvaluations.length != countBeforeStoppedMonitorEval) {
        throw Exception(
          'Binder evaluation count increased while stopped: before=$countBeforeStoppedMonitorEval, after=${collectedEvaluations.length}',
        );
      }

      // Call binder.evaluateOnce directly while stopped
      final manualEval = binder.evaluateOnce(latestSnap);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!manualEval.advisoryOnly || manualEval.playbackMutation) {
        throw Exception('manual evaluateOnce violated advisory invariant');
      }
      if (coordinator.length != 0 || coordinator.journalSnapshot().count != 0) {
        throw Exception(
          'Coordinator journal modified during manual evaluateOnce',
        );
      }
      if (binder.latest != manualEval) {
        throw Exception('binder.latest not updated by manual evaluateOnce');
      }
      if (collectedEvaluations.length != countBeforeStoppedMonitorEval + 1) {
        throw Exception(
          'Expected 1 manual evaluation emitted onto stream, but count is ${collectedEvaluations.length} (before=$countBeforeStoppedMonitorEval)',
        );
      }

      // Restart binder and verify resumed listening
      binder.start();
      if (!binder.isRunning) {
        throw Exception('Binder restart failed: isRunning is false');
      }
      final countBeforeRestartedMonitorEval = collectedEvaluations.length;
      monitor.evaluateOnce(latestSnap.status);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (collectedEvaluations.length != countBeforeRestartedMonitorEval + 1) {
        throw Exception(
          'Expected exactly 1 additional evaluation after monitor evaluateOnce on restarted binder, '
          'before=$countBeforeRestartedMonitorEval, after=${collectedEvaluations.length}',
        );
      }

      binderPass = true;

      if (mounted) {
        setState(() {
          _status =
              'Step 6/7: Testing binder dispose & full pipeline teardown…';
        });
      }

      // Step 8: Dispose binder and verify isolated lifecycle
      binder.dispose();
      if (!binder.isDisposed) {
        throw Exception('Binder dispose failed: isDisposed is false');
      }
      if (binder.isRunning) {
        throw Exception('Binder isRunning is true after dispose');
      }

      binderDisposedMonitorAlive = !monitor.isDisposed;
      binderDisposedPollerAlive = !poller.isDisposed;
      binderDisposedControllerAlive = !controller.isDisposed;

      if (!binderDisposedMonitorAlive) {
        throw Exception('Binder disposal disposed underlying monitor');
      }
      if (!binderDisposedPollerAlive) {
        throw Exception('Binder disposal disposed underlying poller');
      }
      if (!binderDisposedControllerAlive) {
        throw Exception('Binder disposal disposed underlying controller');
      }

      // Calling start() after dispose must be a no-op
      binder.start();
      if (binder.isRunning) {
        throw Exception(
          'Calling start() after dispose unexpectedly set isRunning to true',
        );
      }

      // Stop & dispose monitor
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

      // Stop & dispose poller
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
          binder.isDisposed &&
          monitor.isDisposed &&
          poller.isDisposed &&
          controller.isDisposed &&
          binderDisposedMonitorAlive &&
          binderDisposedPollerAlive &&
          binderDisposedControllerAlive &&
          monitorDisposedPollerAlive &&
          monitorDisposedControllerAlive &&
          pollerDisposedControllerAlive;

      allPass =
          preflightPass &&
          decisionPass &&
          openPass &&
          binderPass &&
          lifecyclePass;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      allPass = false;
    } finally {
      await binderSub?.cancel();
      await monitorSub?.cancel();
      if (binder != null && !binder.isDisposed) {
        try {
          binder.dispose();
        } catch (_) {}
      }
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
      'binderPass': binderPass,
      'lifecyclePass': lifecyclePass,
      'snapshotsCount': collectedSnapshots.length,
      'evaluationsCount': collectedEvaluations.length,
      'preflight': preflightDiag,
      'decision': decisionDiag,
      'open': openDiag,
      'latestEvaluation': latestEvaluationDiag,
      'latestStatus': latestStatusDiag,
      'lifecycleBoundaries': {
        'binderDisposedMonitorAlive': binderDisposedMonitorAlive,
        'binderDisposedPollerAlive': binderDisposedPollerAlive,
        'binderDisposedControllerAlive': binderDisposedControllerAlive,
        'monitorDisposedPollerAlive': monitorDisposedPollerAlive,
        'monitorDisposedControllerAlive': monitorDisposedControllerAlive,
        'pollerDisposedControllerAlive': pollerDisposedControllerAlive,
        'binderDisposed': binder?.isDisposed ?? false,
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
      'ANDROID_STREAMING_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Streaming Playback Resilience Binder Verified (Preflight: OK, Decision: OK, Monitor: OK, Coordinator: OK, Binder: OK, Lifecycle: OK)'
            : 'FAIL: Resilience Binder Smoke Failed';
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
