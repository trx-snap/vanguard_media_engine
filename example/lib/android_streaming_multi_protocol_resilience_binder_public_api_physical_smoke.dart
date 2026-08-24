// Copyright (c) Connects — Vanguard Phase 4C7BG.
// Public multi-protocol streaming playback resilience binder -> physical playback smoke.
//
// Sequentially verifies across HLS, DASH, and LL-HLS:
//   1. Definition of candidate streams via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Generation of preflight request directly from sourceSet under CONSTRAINED profile.
//   3. Preflight evaluation via VGStreamingPreflightClient across HLS, DASH, and LL-HLS.
//   4. Pure-Dart VGStreamingPlaybackDecisionPlanner planning per protocol.
//   5. Execution of adaptive streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   6. Starting VGStreamingPlaybackStatusPoller (500ms interval, emitInitialSummary true) over VGStreamingPlaybackController.
//   7. Starting VGStreamingPlaybackResilienceMonitor over VGStreamingPlaybackStatusPoller.summaries.
//   8. Creating pure-Dart VGStreamingPlaybackResilienceCoordinator with retry journal (maxStoredAttempts 10) and retry budget (maxAttempts 3, windowMs 30000, minimumDelayMs 1000).
//   9. Creating pure-Dart VGStreamingPlaybackResilienceBinder over monitor.snapshots with coordinator, config streamKey == case.key, and deterministic nowProvider.
//  10. Starting binder, calling binder.start() a second time (verifying idempotent no duplicate subscription), then starting monitor and poller.
//  11. Waiting up to 30s for at least 2 monitor snapshots, at least 2 binder evaluations, and real playback evidence (renderedFrames > 0 || isPlaying || positionMs > 0 || bufferedPositionMs > 0) plus positive display dimensions.
//  12. Asserting binder evaluation & coordinator invariants across all emitted evaluations:
//      - evaluation.advisoryOnly == true
//      - evaluation.playbackMutation == false
//      - evaluation.decision.advisoryOnly == true
//      - evaluation.decision.playbackMutation == false
//      - evaluation.retryBudget.advisoryOnly == true
//      - evaluation.retryBudget.playbackMutation == false
//      - evaluation.journalSnapshot.advisoryOnly == true
//      - evaluation.journalSnapshot.playbackMutation == false
//      - evaluation.diagnostics['streamKey'] == case.key
//      - evaluation.action is in VGStreamingPlaybackResilienceDecisionAction.values
//      - evaluation.toJson() advisoryOnly true and playbackMutation false
//      - coordinator.length == 0 and coordinator.journalSnapshot().count == 0 (no automatic attempt recording)
//      - binder.latest is not null and matches latest collected evaluation
//  13. Stopping poller before count-sensitive lifecycle checks.
//  14. Stopping binder and asserting binder.isRunning false and binder.isDisposed false.
//  15. While stopped, triggering monitor.evaluateOnce(latest status) and verifying binder evaluation count does not increase.
//  16. Calling binder.evaluateOnce(latest monitor snapshot) while stopped; asserting it emits one new evaluation, updates latest, preserves advisory/no-mutation invariants, and coordinator journal remains zero.
//  17. Restarting binder, triggering monitor.evaluateOnce(latest status), and verifying exactly one additional binder evaluation arrives.
//  18. Disposing binder and asserting binder.isDisposed true, binder.isRunning false, and monitor/poller/controller remain undisposed. Verifying start after dispose is a no-op.
//  19. Disposing monitor, then poller, then stopping/disposing controller cleanly.
//  20. Verified non-claims: no real retry is executed and recordHostRetryAttempted() is not called in this smoke.
//
// Verification Invariants & Boundaries:
// - Imports ONLY dart:async, dart:convert, dart:io, package:flutter/material.dart, and package:vanguard_media_engine/vanguard_media_engine.dart.
// - Does NOT import package:flutter/services.dart.
// - Does NOT construct raw MethodChannel.
// - Tests all three Android HTTP adaptive playback protocols (HLS, DASH, LL-HLS) sequentially with real playback progress evidence.
// - Pure advisory evaluation wrapper; does not make product feed decisions, ABR policy, or caching policy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingMultiProtocolResilienceBinderPhysicalSmokeApp());
}

class AndroidStreamingMultiProtocolResilienceBinderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingMultiProtocolResilienceBinderPhysicalSmokeApp({
    super.key,
  });

  @override
  State<AndroidStreamingMultiProtocolResilienceBinderPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingMultiProtocolResilienceBinderPhysicalSmokeAppState();
}

class _AndroidStreamingMultiProtocolResilienceBinderPhysicalSmokeAppState
    extends
        State<AndroidStreamingMultiProtocolResilienceBinderPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android multi-protocol streaming playback resilience binder physical smoke…';
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
      _runMultiProtocolResilienceBinderSmoke();
    });
  }

  Future<void> _runMultiProtocolResilienceBinderSmoke() async {
    // Settle window for Flutter host
    await Future<void>.delayed(const Duration(seconds: 1));

    bool preflightPass = false;
    bool allCasesPass = true;
    final caseResults = <String, dynamic>{};
    Map<String, dynamic> preflightDiag = <String, dynamic>{};

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/2: Building source set and running preflight…';
        });
      }

      // Step 1: Define candidate streams covering HLS, DASH, and LL-HLS
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'hls',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
            initialWidth: 1080,
            initialHeight: 1920,
          ),
          VGStreamingSourceDescriptor(
            key: 'dash',
            uri: Uri.parse(
              'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
            ),
            formatHint: VGStreamingFormatHint.dash,
            initialWidth: 1080,
            initialHeight: 1920,
          ),
          VGStreamingSourceDescriptor(
            key: 'll_hls',
            uri: Uri.parse(
              'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
            ),
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
          report.totalReports == 3 &&
          report.failedReports == 0 &&
          report.advisoryOnly == true &&
          report.playbackMutation == false;

      if (!preflightPass) {
        throw Exception(
          'Preflight failed: pass=${report.pass}, phase=${report.phase}, '
          'total=${report.totalReports}, failed=${report.failedReports}',
        );
      }

      // Step 2: Sequentially evaluate resilience binder for each protocol
      final testCases = [
        (key: 'hls', label: 'HLS', preferredKeys: const ['hls']),
        (key: 'dash', label: 'DASH', preferredKeys: const ['dash']),
        (key: 'll_hls', label: 'LL-HLS', preferredKeys: const ['ll_hls']),
      ];

      for (int i = 0; i < testCases.length; i++) {
        final testCase = testCases[i];
        final stepIndex = i + 1;
        final totalSteps = testCases.length;

        if (mounted) {
          setState(() {
            _currentSnapshot = const VGStreamingPlaybackControllerSnapshot(
              state: VGStreamingPlaybackControllerState.idle,
              pass: true,
              reason: 'idle',
            );
            _status =
                'Case $stepIndex/$totalSteps: Planning & opening ${testCase.label} playback…';
          });
        }

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

        bool casePass = false;
        bool binderPass = false;
        bool lifecyclePass = false;

        bool binderDisposedMonitorAlive = false;
        bool binderDisposedPollerAlive = false;
        bool binderDisposedControllerAlive = false;
        bool monitorDisposedPollerAlive = false;
        bool monitorDisposedControllerAlive = false;
        bool pollerDisposedControllerAlive = false;

        Map<String, dynamic> decisionDiag = <String, dynamic>{};
        Map<String, dynamic> openDiag = <String, dynamic>{};
        Map<String, dynamic> latestEvaluationDiag = <String, dynamic>{};
        Map<String, dynamic> latestStatusDiag = <String, dynamic>{};

        int maxRenderedFrames = 0;
        int maxPositionMs = 0;
        int maxBufferedPositionMs = 0;
        bool sawPlaying = false;
        bool playbackProgressObserved = false;

        int nowCounter = 1700000000000 + (i * 100000);
        int deterministicNow() {
          nowCounter += 500;
          return nowCounter;
        }

        try {
          // 2a. Build decision & open controller
          final decision = VGStreamingPlaybackDecisionPlanner.plan(
            VGStreamingPlaybackDecisionRequest(
              sourceSet: sourceSet,
              preflightReport: report,
              preference: VGStreamingSourceSelectionPreference.preserveOrder,
              preferredKeys: testCase.preferredKeys,
            ),
          );

          decisionDiag = {
            'decision': decision.decision,
            'canOpenPlayback': decision.canOpenPlayback,
            'selectedKey': decision.selectedKey,
          };

          if (!decision.canOpenPlayback ||
              decision.decision != 'playback_ready' ||
              decision.selectedKey != testCase.key) {
            throw Exception(
              'Decision planning failed for ${testCase.label}: canOpenPlayback=${decision.canOpenPlayback}, '
              'decision=${decision.decision}, selectedKey=${decision.selectedKey}',
            );
          }

          controller = VGStreamingPlaybackController();
          final openSnapshot = await controller.open(
            decision,
            startPlayback: true,
          );

          openDiag = {
            'pass': openSnapshot.pass,
            'state': openSnapshot.state.name,
            'textureId': openSnapshot.textureId,
            'reason': openSnapshot.reason,
          };

          if (!openSnapshot.pass || openSnapshot.textureId == null) {
            throw Exception(
              'Controller open failed for ${testCase.label}: pass=${openSnapshot.pass}, '
              'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}',
            );
          }

          if (mounted) {
            setState(() {
              _currentSnapshot = openSnapshot;
              _status =
                  'Case $stepIndex/$totalSteps: Setting up poller, monitor, coordinator & binder for ${testCase.label}…';
            });
          }

          // 2b. Instantiate poller, resilience monitor, coordinator & binder
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
            config: VGStreamingPlaybackResilienceCoordinatorConfig(
              journalConfig: const VGStreamingPlaybackRetryJournalConfig(
                maxStoredAttempts: 10,
              ),
              retryBudgetConfig: const VGStreamingPlaybackRetryBudgetConfig(
                maxAttempts: 3,
                windowMs: 30000,
                minimumDelayMs: 1000,
              ),
              streamKey: testCase.key,
            ),
          );

          binder = VGStreamingPlaybackResilienceBinder(
            snapshots: monitor.snapshots,
            coordinator: coordinator,
            config: VGStreamingPlaybackResilienceBinderConfig(
              streamKey: testCase.key,
            ),
            nowProvider: deterministicNow,
          );

          monitorSub = monitor.snapshots.listen((snapshot) {
            collectedSnapshots.add(snapshot);
            if (snapshot.status.isPlaying) {
              sawPlaying = true;
            }
            if (snapshot.status.positionMs > maxPositionMs) {
              maxPositionMs = snapshot.status.positionMs;
            }
            if (snapshot.status.bufferedPositionMs > maxBufferedPositionMs) {
              maxBufferedPositionMs = snapshot.status.bufferedPositionMs;
            }
            if (mounted && controller != null) {
              final frames = controller.snapshot.session?.renderedFrames ?? 0;
              if (frames > maxRenderedFrames) {
                maxRenderedFrames = frames;
              }
              setState(() {
                _currentSnapshot = controller!.snapshot;
              });
            }
          });

          binderSub = binder.evaluations.listen((evaluation) {
            collectedEvaluations.add(evaluation);
          });

          // Start binder, call binder.start() a second time (idempotent), then start monitor and poller
          binder.start();
          if (!binder.isRunning) {
            throw Exception(
              'Binder failed to start for ${testCase.label} (isRunning is false)',
            );
          }
          binder.start();
          if (!binder.isRunning) {
            throw Exception(
              'Binder isRunning became false after second start() for ${testCase.label}',
            );
          }

          monitor.start();
          poller.start();

          if (!monitor.isRunning) {
            throw Exception(
              'Resilience monitor failed to start for ${testCase.label} (isRunning is false)',
            );
          }
          if (!poller.isRunning) {
            throw Exception(
              'Status poller failed to start for ${testCase.label} (isRunning is false)',
            );
          }

          if (mounted) {
            setState(() {
              _status =
                  'Case $stepIndex/$totalSteps: Collecting resilience snapshots & binder evaluations for ${testCase.label}…';
            });
          }

          // 2c. Wait for at least 2 emitted snapshots, at least 2 binder evaluations, display metrics, and real playback progress evidence (timeout 30s)
          const maxWaitSeconds = 30;
          final stopwatch = Stopwatch()..start();

          while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            final currentFrames =
                controller.snapshot.session?.renderedFrames ?? 0;
            if (currentFrames > maxRenderedFrames) {
              maxRenderedFrames = currentFrames;
            }
            final latestSnap = monitor.latest;
            if (latestSnap != null) {
              if (latestSnap.status.isPlaying) {
                sawPlaying = true;
              }
              if (latestSnap.status.positionMs > maxPositionMs) {
                maxPositionMs = latestSnap.status.positionMs;
              }
              if (latestSnap.status.bufferedPositionMs >
                  maxBufferedPositionMs) {
                maxBufferedPositionMs = latestSnap.status.bufferedPositionMs;
              }
            }

            playbackProgressObserved =
                maxRenderedFrames > 0 ||
                sawPlaying ||
                (latestSnap?.status.isPlaying ?? false) ||
                maxPositionMs > 0 ||
                (latestSnap?.status.positionMs ?? 0) > 0 ||
                maxBufferedPositionMs > 0 ||
                (latestSnap?.status.bufferedPositionMs ?? 0) > 0;

            if (collectedSnapshots.length >= 2 &&
                collectedEvaluations.length >= 2 &&
                latestSnap != null &&
                latestSnap.status.hasSession &&
                latestSnap.status.effectiveDisplayWidth > 0 &&
                latestSnap.status.effectiveDisplayHeight > 0 &&
                playbackProgressObserved) {
              if (maxRenderedFrames > 0 ||
                  stopwatch.elapsed >= const Duration(seconds: 6)) {
                break;
              }
            }
          }

          final currentFrames =
              controller.snapshot.session?.renderedFrames ?? 0;
          if (currentFrames > maxRenderedFrames) {
            maxRenderedFrames = currentFrames;
          }
          final latestSnap = monitor.latest;
          if (latestSnap != null) {
            if (latestSnap.status.isPlaying) {
              sawPlaying = true;
            }
            if (latestSnap.status.positionMs > maxPositionMs) {
              maxPositionMs = latestSnap.status.positionMs;
            }
            if (latestSnap.status.bufferedPositionMs > maxBufferedPositionMs) {
              maxBufferedPositionMs = latestSnap.status.bufferedPositionMs;
            }
          }

          playbackProgressObserved =
              maxRenderedFrames > 0 ||
              sawPlaying ||
              (latestSnap?.status.isPlaying ?? false) ||
              maxPositionMs > 0 ||
              (latestSnap?.status.positionMs ?? 0) > 0 ||
              maxBufferedPositionMs > 0 ||
              (latestSnap?.status.bufferedPositionMs ?? 0) > 0;

          if (collectedSnapshots.length < 2) {
            throw Exception(
              'Expected at least 2 emitted snapshots for ${testCase.label}, but collected ${collectedSnapshots.length}',
            );
          }

          if (collectedEvaluations.length < 2) {
            throw Exception(
              'Expected at least 2 emitted binder evaluations for ${testCase.label}, but collected ${collectedEvaluations.length}',
            );
          }

          if (latestSnap == null) {
            throw Exception(
              'Monitor latest snapshot is null after collection for ${testCase.label}',
            );
          }

          if (!latestSnap.status.hasSession) {
            throw Exception(
              'Latest snapshot status hasSession is false for ${testCase.label}',
            );
          }

          if (latestSnap.status.effectiveDisplayWidth <= 0 ||
              latestSnap.status.effectiveDisplayHeight <= 0) {
            throw Exception(
              'Latest snapshot effective dimensions non-positive for ${testCase.label}: '
              '${latestSnap.status.effectiveDisplayWidth}x${latestSnap.status.effectiveDisplayHeight}',
            );
          }

          if (!playbackProgressObserved) {
            throw Exception(
              'Playback progress evidence not observed for ${testCase.label}: '
              'maxRenderedFrames=$maxRenderedFrames, sawPlaying=$sawPlaying, '
              'maxPositionMs=$maxPositionMs, maxBufferedPositionMs=$maxBufferedPositionMs, '
              'latest=${latestSnap.status.toJson()}',
            );
          }

          // Stop poller now so background timer ticks do not race with baseline counts
          poller.stop();

          // 2d. Assert invariants across all collected binder evaluations
          for (final eval in collectedEvaluations) {
            if (!eval.advisoryOnly || eval.playbackMutation) {
              throw Exception(
                'Binder evaluation advisory/mutation invariant violation for ${testCase.label}: '
                'advisoryOnly=${eval.advisoryOnly}, playbackMutation=${eval.playbackMutation}',
              );
            }
            if (!eval.decision.advisoryOnly || eval.decision.playbackMutation) {
              throw Exception(
                'Binder decision advisory/mutation invariant violation for ${testCase.label}: '
                'advisoryOnly=${eval.decision.advisoryOnly}, playbackMutation=${eval.decision.playbackMutation}',
              );
            }
            if (!eval.retryBudget.advisoryOnly ||
                eval.retryBudget.playbackMutation) {
              throw Exception(
                'Binder retryBudget advisory/mutation invariant violation for ${testCase.label}: '
                'advisoryOnly=${eval.retryBudget.advisoryOnly}, playbackMutation=${eval.retryBudget.playbackMutation}',
              );
            }
            if (!eval.journalSnapshot.advisoryOnly ||
                eval.journalSnapshot.playbackMutation) {
              throw Exception(
                'Binder journalSnapshot advisory/mutation invariant violation for ${testCase.label}: '
                'advisoryOnly=${eval.journalSnapshot.advisoryOnly}, playbackMutation=${eval.journalSnapshot.playbackMutation}',
              );
            }
            if (eval.diagnostics['streamKey'] != testCase.key) {
              throw Exception(
                'Binder diagnostics streamKey invariant violation for ${testCase.label}: ${eval.diagnostics['streamKey']}',
              );
            }
            if (!VGStreamingPlaybackResilienceDecisionAction.values.contains(
              eval.action,
            )) {
              throw Exception(
                'Binder evaluation action is not a valid enum value for ${testCase.label}: ${eval.action}',
              );
            }

            final evalJson = eval.toJson();
            if (evalJson['advisoryOnly'] != true ||
                evalJson['playbackMutation'] != false) {
              throw Exception(
                'Binder evaluation JSON serialization invariant violated for ${testCase.label}',
              );
            }
          }

          // Assert coordinator journal remains zero (no automatic attempt recording)
          if (coordinator.length != 0 ||
              coordinator.journalSnapshot().count != 0) {
            throw Exception(
              'Coordinator journal was modified during binder evaluations for ${testCase.label}: '
              'length=${coordinator.length}, journalCount=${coordinator.journalSnapshot().count}',
            );
          }

          // Assert binder.latest is not null and matches the latest collected evaluation
          if (binder.latest == null) {
            throw Exception(
              'binder.latest is null after receiving evaluations for ${testCase.label}',
            );
          }
          final latestEval = binder.latest!;
          final lastCollected = collectedEvaluations.last;
          if (latestEval.action != lastCollected.action ||
              latestEval.reasons.join(',') != lastCollected.reasons.join(',')) {
            throw Exception(
              'binder.latest does not match last collected evaluation for ${testCase.label}: '
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
              _status =
                  'Case $stepIndex/$totalSteps: Testing stop, evaluateOnce & restart lifecycle for ${testCase.label}…';
            });
          }

          // 2e. Test stop, evaluateOnce while stopped, restart, and subscription lifecycle
          poller.stop();

          binder.stop();
          if (binder.isRunning) {
            throw Exception(
              'Binder stop failed for ${testCase.label}: isRunning is still true',
            );
          }
          if (binder.isDisposed) {
            throw Exception(
              'Binder stop erroneously set isDisposed to true for ${testCase.label}',
            );
          }

          final countBeforeStoppedMonitorEval = collectedEvaluations.length;
          // Trigger monitor.evaluateOnce on latest status while binder is stopped
          monitor.evaluateOnce(latestSnap.status);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (collectedEvaluations.length != countBeforeStoppedMonitorEval) {
            throw Exception(
              'Binder evaluation count increased while stopped for ${testCase.label}: '
              'before=$countBeforeStoppedMonitorEval, after=${collectedEvaluations.length}',
            );
          }

          // Call binder.evaluateOnce directly while stopped
          final manualEval = binder.evaluateOnce(latestSnap);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (!manualEval.advisoryOnly || manualEval.playbackMutation) {
            throw Exception(
              'manual evaluateOnce violated advisory invariant for ${testCase.label}',
            );
          }
          if (!manualEval.decision.advisoryOnly ||
              manualEval.decision.playbackMutation ||
              !manualEval.retryBudget.advisoryOnly ||
              manualEval.retryBudget.playbackMutation ||
              !manualEval.journalSnapshot.advisoryOnly ||
              manualEval.journalSnapshot.playbackMutation) {
            throw Exception(
              'manual evaluateOnce child components violated advisory invariant for ${testCase.label}',
            );
          }
          if (coordinator.length != 0 ||
              coordinator.journalSnapshot().count != 0) {
            throw Exception(
              'Coordinator journal modified during manual evaluateOnce for ${testCase.label}',
            );
          }
          if (binder.latest != manualEval) {
            throw Exception(
              'binder.latest not updated by manual evaluateOnce for ${testCase.label}',
            );
          }
          if (collectedEvaluations.length !=
              countBeforeStoppedMonitorEval + 1) {
            throw Exception(
              'Expected 1 manual evaluation emitted onto stream for ${testCase.label}, '
              'but count is ${collectedEvaluations.length} (before=$countBeforeStoppedMonitorEval)',
            );
          }

          // Restart binder and verify resumed listening
          binder.start();
          if (!binder.isRunning) {
            throw Exception(
              'Binder restart failed for ${testCase.label}: isRunning is false',
            );
          }
          final countBeforeRestartedMonitorEval = collectedEvaluations.length;
          monitor.evaluateOnce(latestSnap.status);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (collectedEvaluations.length !=
              countBeforeRestartedMonitorEval + 1) {
            throw Exception(
              'Expected exactly 1 additional evaluation after monitor evaluateOnce on restarted binder for ${testCase.label}, '
              'before=$countBeforeRestartedMonitorEval, after=${collectedEvaluations.length}',
            );
          }

          binderPass = true;

          if (mounted) {
            setState(() {
              _status =
                  'Case $stepIndex/$totalSteps: Testing binder dispose & teardown for ${testCase.label}…';
            });
          }

          // 2f. Dispose binder and verify isolated lifecycle
          binder.dispose();
          if (!binder.isDisposed) {
            throw Exception(
              'Binder dispose failed for ${testCase.label}: isDisposed is false',
            );
          }
          if (binder.isRunning) {
            throw Exception(
              'Binder isRunning is true after dispose for ${testCase.label}',
            );
          }

          binderDisposedMonitorAlive = !monitor.isDisposed;
          binderDisposedPollerAlive = !poller.isDisposed;
          binderDisposedControllerAlive = !controller.isDisposed;

          if (!binderDisposedMonitorAlive) {
            throw Exception(
              'Binder disposal disposed underlying monitor for ${testCase.label}',
            );
          }
          if (!binderDisposedPollerAlive) {
            throw Exception(
              'Binder disposal disposed underlying poller for ${testCase.label}',
            );
          }
          if (!binderDisposedControllerAlive) {
            throw Exception(
              'Binder disposal disposed underlying controller for ${testCase.label}',
            );
          }

          // Calling start() after dispose must be a no-op
          binder.start();
          if (binder.isRunning) {
            throw Exception(
              'Calling start() after dispose unexpectedly set isRunning to true for ${testCase.label}',
            );
          }

          // Stop & dispose monitor
          monitor.stop();
          if (monitor.isRunning) {
            throw Exception(
              'Monitor stop failed for ${testCase.label}: isRunning is still true',
            );
          }
          await monitor.dispose();
          if (!monitor.isDisposed) {
            throw Exception(
              'Monitor dispose failed for ${testCase.label}: isDisposed is false',
            );
          }

          monitorDisposedPollerAlive = !poller.isDisposed;
          monitorDisposedControllerAlive = !controller.isDisposed;
          if (!monitorDisposedPollerAlive) {
            throw Exception(
              'Monitor disposal disposed underlying poller for ${testCase.label}',
            );
          }
          if (!monitorDisposedControllerAlive) {
            throw Exception(
              'Monitor disposal disposed underlying controller for ${testCase.label}',
            );
          }

          // Stop & dispose poller
          poller.stop();
          if (poller.isRunning) {
            throw Exception(
              'Poller stop failed for ${testCase.label}: isRunning is still true',
            );
          }
          await poller.dispose();
          if (!poller.isDisposed) {
            throw Exception(
              'Poller dispose failed for ${testCase.label}: isDisposed is false',
            );
          }

          pollerDisposedControllerAlive = !controller.isDisposed;
          if (!pollerDisposedControllerAlive) {
            throw Exception(
              'Poller disposal disposed underlying controller for ${testCase.label}',
            );
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

          casePass = binderPass && lifecyclePass;
        } catch (caseError, caseStack) {
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_MULTI_PROTOCOL_RESILIENCE_BINDER_CASE_ERROR (${testCase.label}): $caseError\n$caseStack',
          );
          casePass = false;
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

        caseResults[testCase.key] = {
          'pass': casePass,
          'binderPass': binderPass,
          'lifecyclePass': lifecyclePass,
          'snapshotsCount': collectedSnapshots.length,
          'evaluationsCount': collectedEvaluations.length,
          'maxRenderedFrames': maxRenderedFrames,
          'maxPositionMs': maxPositionMs,
          'maxBufferedPositionMs': maxBufferedPositionMs,
          'sawPlaying': sawPlaying,
          'playbackProgressObserved': playbackProgressObserved,
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
        };

        if (!casePass) {
          allCasesPass = false;
        }
      }
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_MULTI_PROTOCOL_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      allCasesPass = false;
    }

    final hlsPass = caseResults['hls']?['pass'] == true;
    final dashPass = caseResults['dash']?['pass'] == true;
    final llHlsPass = caseResults['ll_hls']?['pass'] == true;
    final allPass =
        preflightPass && allCasesPass && hlsPass && dashPass && llHlsPass;

    final aggregatedMap = <String, dynamic>{
      'pass': allPass,
      'preflightPass': preflightPass,
      'allCasesPass': allCasesPass,
      'hlsPass': hlsPass,
      'dashPass': dashPass,
      'llHlsPass': llHlsPass,
      'hlsSnapshotsCount': caseResults['hls']?['snapshotsCount'] ?? 0,
      'dashSnapshotsCount': caseResults['dash']?['snapshotsCount'] ?? 0,
      'llHlsSnapshotsCount': caseResults['ll_hls']?['snapshotsCount'] ?? 0,
      'hlsEvaluationsCount': caseResults['hls']?['evaluationsCount'] ?? 0,
      'dashEvaluationsCount': caseResults['dash']?['evaluationsCount'] ?? 0,
      'llHlsEvaluationsCount': caseResults['ll_hls']?['evaluationsCount'] ?? 0,
      'hlsMaxRenderedFrames': caseResults['hls']?['maxRenderedFrames'] ?? 0,
      'dashMaxRenderedFrames': caseResults['dash']?['maxRenderedFrames'] ?? 0,
      'llHlsMaxRenderedFrames':
          caseResults['ll_hls']?['maxRenderedFrames'] ?? 0,
      'hlsMaxPositionMs': caseResults['hls']?['maxPositionMs'] ?? 0,
      'dashMaxPositionMs': caseResults['dash']?['maxPositionMs'] ?? 0,
      'llHlsMaxPositionMs': caseResults['ll_hls']?['maxPositionMs'] ?? 0,
      'hlsMaxBufferedPositionMs':
          caseResults['hls']?['maxBufferedPositionMs'] ?? 0,
      'dashMaxBufferedPositionMs':
          caseResults['dash']?['maxBufferedPositionMs'] ?? 0,
      'llHlsMaxBufferedPositionMs':
          caseResults['ll_hls']?['maxBufferedPositionMs'] ?? 0,
      'hlsSawPlaying': caseResults['hls']?['sawPlaying'] == true,
      'dashSawPlaying': caseResults['dash']?['sawPlaying'] == true,
      'llHlsSawPlaying': caseResults['ll_hls']?['sawPlaying'] == true,
      'preflight': preflightDiag,
      'cases': caseResults,
      'nonClaims': {
        'realRetryExecuted': false,
        'recordHostRetryAttemptedCalled': false,
        'protocolCoverage': 'hls_dash_ll_hls',
        'advisoryOnly': true,
      },
    };

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_MULTI_PROTOCOL_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_MULTI_PROTOCOL_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_MULTI_PROTOCOL_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Multi-Protocol Resilience Binder Verified (HLS: OK, DASH: OK, LL-HLS: OK)'
            : 'FAIL: Multi-Protocol Resilience Binder Smoke Failed';
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
