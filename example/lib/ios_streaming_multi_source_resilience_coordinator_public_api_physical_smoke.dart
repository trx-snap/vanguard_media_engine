// Copyright (c) Connects — Vanguard Phase 4C8K.
// iOS Public streaming playback multi-source resilience coordinator -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream set (DASH, HLS, LL-HLS) via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Composition with synthetic advisory preflight report for selector/controller/poller/monitor/coordinator composition.
//      (Synthetic preflight report is used solely for composition proof; this harness does not re-prove native preflight).
//   3. Case 1 (HLS fallback):
//      - Decision planning with preferDash under appleAvPlayer capabilities.
//      - Asserts decision is playback_ready, selects 'hls' with HLS formatHint, and emits dash_not_supported warning.
//      - Opens controller with startPlayback: true.
//      - Refreshes until renderedFrames > 0, positive display dimensions, and valid state.
//      - Attaches VGStreamingPlaybackStatusPoller (300ms interval, emitInitialSummary: true).
//      - Attaches VGStreamingPlaybackResilienceMonitor (constrained profile, maxHistory 8, allowAutomaticRetry false).
//      - Instantiates fresh pure-Dart VGStreamingPlaybackResilienceCoordinator with bounded retry journal and retry budget config.
//      - Starts monitor then poller, collects >= 2 snapshots.
//      - Asserts monitor invariants: advisoryOnly/playbackMutation, history length, status bounds, and progress evidence.
//      - Evaluates every collected snapshot through coordinator with deterministic nowMs + i * 500.
//      - Asserts coordinator evaluation invariants: advisoryOnly/playbackMutation across evaluation, decision, retryBudget, and journalSnapshot.
//      - Asserts coordinator.length remains 0 after evaluate (no automatic attempt recording).
//      - Asserts valid coordinator action enum and JSON serialization preservation.
//      - Stops and disposes monitor (asserting poller/controller stay alive), tests evaluateOnce(), stops/disposes poller (asserting controller stays alive), stops/disposes controller.
//   4. Case 2 (LL-HLS selection):
//      - Decision planning with preferredKeys: ['ll_hls'] and appleAvPlayer(preferLowLatency: true).
//      - Asserts decision is playback_ready, selects 'll_hls' with HLS formatHint.
//      - Opens controller with startPlayback: true.
//      - Refreshes until renderedFrames > 0, positive display dimensions, and valid state.
//      - Attaches VGStreamingPlaybackStatusPoller (300ms interval, emitInitialSummary: true).
//      - Attaches VGStreamingPlaybackResilienceMonitor (constrained profile, maxHistory 8, allowAutomaticRetry false).
//      - Instantiates fresh pure-Dart VGStreamingPlaybackResilienceCoordinator with bounded retry journal and retry budget config.
//      - Starts monitor then poller, collects >= 2 snapshots.
//      - Asserts monitor invariants: advisoryOnly/playbackMutation, history length, status bounds, and progress evidence.
//      - Evaluates every collected snapshot through coordinator with deterministic nowMs + i * 500.
//      - Asserts coordinator evaluation invariants: advisoryOnly/playbackMutation across evaluation, decision, retryBudget, and journalSnapshot.
//      - Asserts coordinator.length remains 0 after evaluate (no automatic attempt recording).
//      - Asserts valid coordinator action enum and JSON serialization preservation.
//      - Stops and disposes monitor (asserting poller/controller stay alive), tests evaluateOnce(), stops/disposes poller (asserting controller stays alive), stops/disposes controller.
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
// - Synthetic preflight report used for selector/controller/poller/monitor/coordinator composition only (no native preflight claim).
// - Bounded timeouts across all operations.
// - Per-case finally blocks for guaranteed subscription cancellation and safe cleanup.
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
const Duration _kSnapshotCollectionTimeout = Duration(seconds: 15);

void main() {
  runApp(
    const IosStreamingMultiSourceResilienceCoordinatorPublicApiPhysicalSmokeApp(),
  );
}

class IosStreamingMultiSourceResilienceCoordinatorPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingMultiSourceResilienceCoordinatorPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<IosStreamingMultiSourceResilienceCoordinatorPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingMultiSourceResilienceCoordinatorPublicApiPhysicalSmokeAppState();
}

class _CaseConfig {
  const _CaseConfig({
    required this.caseName,
    required this.caseKey,
    required this.humanTitle,
    required this.request,
    required this.validateDecision,
  });

  final String caseName;
  final String caseKey;
  final String humanTitle;
  final VGStreamingPlaybackDecisionRequest request;
  final void Function(VGStreamingPlaybackDecision decision) validateDecision;
}

class _CaseExecutionResult {
  const _CaseExecutionResult({
    required this.pass,
    this.decision,
    this.textureId,
    this.renderedFrames = 0,
    this.snapshotsCount = 0,
    this.latestSnapshotJson,
    this.latestHealthJson,
    this.latestRecoveryJson,
    this.latestStatusJson,
    this.latestCoordinatorEvalJson,
    this.coordinatorLengthAfterEvaluate = 0,
    this.monitorDisposedPollerAlive = false,
    this.monitorDisposedControllerAlive = false,
    this.pollerDisposedControllerAlive = false,
    this.rawSession,
    this.error,
  });

  final bool pass;
  final VGStreamingPlaybackDecision? decision;
  final int? textureId;
  final int renderedFrames;
  final int snapshotsCount;
  final Map<String, dynamic>? latestSnapshotJson;
  final Map<String, dynamic>? latestHealthJson;
  final Map<String, dynamic>? latestRecoveryJson;
  final Map<String, dynamic>? latestStatusJson;
  final Map<String, dynamic>? latestCoordinatorEvalJson;
  final int coordinatorLengthAfterEvaluate;
  final bool monitorDisposedPollerAlive;
  final bool monitorDisposedControllerAlive;
  final bool pollerDisposedControllerAlive;
  final String? rawSession;
  final String? error;

  Map<String, dynamic> toJson() {
    if (pass) {
      return <String, dynamic>{
        'pass': true,
        'selectedKey': decision?.selectedKey,
        'textureId': textureId,
        'renderedFrames': renderedFrames,
        'snapshotsCount': snapshotsCount,
        'latestSnapshot': latestSnapshotJson,
        'latestHealth': latestHealthJson,
        'latestRecovery': latestRecoveryJson,
        'latestStatus': latestStatusJson,
        'coordinatorEvaluation': latestCoordinatorEvalJson,
        'coordinatorLengthAfterEvaluate': coordinatorLengthAfterEvaluate,
        'monitorDisposedPollerAlive': monitorDisposedPollerAlive,
        'monitorDisposedControllerAlive': monitorDisposedControllerAlive,
        'pollerDisposedControllerAlive': pollerDisposedControllerAlive,
        'warnings': decision?.warnings ?? const <String>[],
        'raw': rawSession,
      };
    }
    return <String, dynamic>{'pass': false, 'error': error};
  }
}

class _IosStreamingMultiSourceResilienceCoordinatorPublicApiPhysicalSmokeAppState
    extends
        State<
          IosStreamingMultiSourceResilienceCoordinatorPublicApiPhysicalSmokeApp
        > {
  String _status =
      'Bootstrapping iOS multi-source streaming playback resilience coordinator smoke...';
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
      'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_BOOTSTRAP: START',
    );
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_BOOTSTRAP_ERROR: $error\n$stack',
        );
        // ignore: avoid_print
        print(
          'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_FAIL',
        );
        exit(1);
      }
    });
  }

  void _updateUi(
    String status, {
    VGStreamingPlaybackControllerSnapshot? snapshot,
  }) {
    if (mounted) {
      setState(() {
        _status = status;
        if (snapshot != null) {
          _currentSnapshot = snapshot;
        }
      });
    }
  }

  Future<_CaseExecutionResult> _runTestCase(
    _CaseConfig config,
    VGStreamingPreflightReport syntheticPreflightReport,
  ) async {
    VGStreamingPlaybackController? controller;
    VGStreamingPlaybackStatusPoller? poller;
    VGStreamingPlaybackResilienceMonitor? monitor;
    VGStreamingPlaybackResilienceCoordinator? coordinator;
    StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? monitorSub;
    final collectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];

    bool monitorDisposedPollerAlive = false;
    bool monitorDisposedControllerAlive = false;
    bool pollerDisposedControllerAlive = false;

    try {
      // 1. Plan
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_PLAN: START',
      );
      _updateUi(
        '${config.humanTitle}: Planning decision...',
        snapshot: const VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.idle,
          pass: true,
          reason: 'idle',
        ),
      );

      final decision = VGStreamingPlaybackDecisionPlanner.plan(config.request);
      config.validateDecision(decision);

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_PLAN: DONE',
      );

      // 2. Open
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_OPEN: START',
      );
      _updateUi('${config.humanTitle}: Opening playback controller...');

      controller = VGStreamingPlaybackController();
      final openSnapshot = await controller
          .open(decision, startPlayback: true)
          .timeout(_kOperationTimeout);

      if (!openSnapshot.pass || openSnapshot.textureId == null) {
        throw Exception(
          '${config.caseName} controller open failed: pass=${openSnapshot.pass}, '
          'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}, '
          'textureId=${openSnapshot.textureId}',
        );
      }

      _updateUi(
        '${config.humanTitle}: Controller active (textureId=${openSnapshot.textureId}), waiting for rendered frames...',
        snapshot: openSnapshot,
      );

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_OPEN: DONE (textureId=${openSnapshot.textureId})',
      );

      // 3. Status Wait
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_STATUS: START',
      );
      final deadline = DateTime.now().add(_kStatusDeadline);
      VGStreamingPlaybackControllerSnapshot? initialRenderedSnapshot;

      while (DateTime.now().isBefore(deadline)) {
        final refreshed = await controller.refresh().timeout(_kControlTimeout);
        _updateUi(_status, snapshot: refreshed);

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
          '${config.caseName} initial status wait timed out: renderedFrames=${lastRefreshed.session?.renderedFrames}, '
          'state=${lastRefreshed.state.name}, dims=${lastRefreshed.session?.effectiveDisplayWidth}x${lastRefreshed.session?.effectiveDisplayHeight}, '
          'raw=${lastRefreshed.session?.raw}',
        );
      }

      final initialSession = initialRenderedSnapshot.session!;
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_STATUS: DONE (renderedFrames=${initialSession.renderedFrames}, dims=${initialSession.effectiveDisplayWidth}x${initialSession.effectiveDisplayHeight})',
      );

      // 4. Poller, Resilience Monitor & Resilience Coordinator Setup & Start
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_MONITOR_START: START',
      );
      _updateUi(
        '${config.humanTitle}: Instantiating and starting poller, monitor, and coordinator...',
      );

      poller = VGStreamingPlaybackStatusPoller(
        controller: controller,
        config: VGStreamingPlaybackStatusPollerConfig(
          interval: const Duration(milliseconds: 300),
          emitInitialSummary: true,
        ),
      );

      monitor = VGStreamingPlaybackResilienceMonitor(
        summaries: poller.summaries,
        config: VGStreamingPlaybackResilienceMonitorConfig(
          currentOptions: decision.playbackOptions,
          preflightReport: syntheticPreflightReport,
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
          streamKey: config.caseKey,
        ),
      );

      monitorSub = monitor.snapshots.listen((snapshot) {
        collectedSnapshots.add(snapshot);
        if (mounted && controller != null) {
          _updateUi(_status, snapshot: controller.snapshot);
        }
      });

      // Start monitor, then poller
      monitor.start();
      poller.start();

      if (!monitor.isRunning) {
        throw Exception(
          '${config.caseName} resilience monitor failed to start (isRunning is false)',
        );
      }
      if (!poller.isRunning) {
        throw Exception(
          '${config.caseName} status poller failed to start (isRunning is false)',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_MONITOR_START: DONE',
      );

      // 5. Collect Snapshots & Check Invariants
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_COLLECT: START',
      );
      _updateUi(
        '${config.humanTitle}: Collecting resilience snapshots from monitor...',
      );

      final collectDeadline = DateTime.now().add(_kSnapshotCollectionTimeout);
      while (DateTime.now().isBefore(collectDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
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
          '${config.caseName} expected at least 2 emitted resilience snapshots, but collected ${collectedSnapshots.length}',
        );
      }

      final latestSnap = monitor.latest;
      if (latestSnap == null) {
        throw Exception(
          '${config.caseName} monitor latest snapshot is null after collection',
        );
      }

      // Latest snapshot invariants
      if (!latestSnap.status.hasSession) {
        throw Exception(
          '${config.caseName} latest snapshot status hasSession is false',
        );
      }
      if (latestSnap.status.effectiveDisplayWidth <= 0 ||
          latestSnap.status.effectiveDisplayHeight <= 0) {
        throw Exception(
          '${config.caseName} latest snapshot effective dimensions non-positive: '
          '${latestSnap.status.effectiveDisplayWidth}x${latestSnap.status.effectiveDisplayHeight}',
        );
      }

      if (!latestSnap.healthAdvice.advisoryOnly ||
          latestSnap.healthAdvice.playbackMutation) {
        throw Exception(
          '${config.caseName} health advice mutation invariants violated: '
          'advisoryOnly=${latestSnap.healthAdvice.advisoryOnly}, '
          'playbackMutation=${latestSnap.healthAdvice.playbackMutation}',
        );
      }

      if (!latestSnap.recoveryPlan.advisoryOnly ||
          latestSnap.recoveryPlan.playbackMutation) {
        throw Exception(
          '${config.caseName} recovery plan mutation invariants violated: '
          'advisoryOnly=${latestSnap.recoveryPlan.advisoryOnly}, '
          'playbackMutation=${latestSnap.recoveryPlan.playbackMutation}',
        );
      }

      if (!latestSnap.advisoryOnly || latestSnap.playbackMutation) {
        throw Exception(
          '${config.caseName} resilience snapshot mutation invariants violated: '
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
        throw Exception(
          '${config.caseName} no playback progress or rendering evidence observed',
        );
      }

      // Assert invariants across all collected snapshots
      for (final snap in collectedSnapshots) {
        if (!snap.advisoryOnly || snap.playbackMutation) {
          throw Exception(
            '${config.caseName} snapshot advisory/mutation invariant violation',
          );
        }
        if (!snap.healthAdvice.advisoryOnly ||
            snap.healthAdvice.playbackMutation) {
          throw Exception(
            '${config.caseName} health advice advisory/mutation invariant violation',
          );
        }
        if (!snap.recoveryPlan.advisoryOnly ||
            snap.recoveryPlan.playbackMutation) {
          throw Exception(
            '${config.caseName} recovery plan advisory/mutation invariant violation',
          );
        }
        if (snap.historyLength < 1 || snap.historyLength > 8) {
          throw Exception(
            '${config.caseName} snapshot historyLength out of bounds: ${snap.historyLength}',
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
            '${config.caseName} status summary metric bounds violation: '
            'duration=${status.durationMs}, position=${status.positionMs}, '
            'bufferedPos=${status.bufferedPositionMs}, bufferedPercent=${status.bufferedPercent}',
          );
        }
      }

      final latestHealthDiag = <String, dynamic>{
        'severity': latestSnap.healthAdvice.severity.name,
        'action': latestSnap.healthAdvice.recommendedAction.name,
        'recommendedNetworkProfile':
            latestSnap.healthAdvice.recommendedNetworkProfile.name,
        'shouldLeaveLowLatency': latestSnap.healthAdvice.shouldLeaveLowLatency,
        'shouldRetry': latestSnap.healthAdvice.shouldRetry,
        'advisoryOnly': latestSnap.healthAdvice.advisoryOnly,
        'playbackMutation': latestSnap.healthAdvice.playbackMutation,
      };

      final latestRecoveryDiag = <String, dynamic>{
        'intent': latestSnap.recoveryPlan.intent.name,
        'urgency': latestSnap.recoveryPlan.urgency.name,
        'shouldReopenPlayback': latestSnap.recoveryPlan.shouldReopenPlayback,
        'requiresHostAction': latestSnap.recoveryPlan.requiresHostAction,
        'canBuildPlaybackOptions':
            latestSnap.recoveryPlan.canBuildPlaybackOptions,
        'advisoryOnly': latestSnap.recoveryPlan.advisoryOnly,
        'playbackMutation': latestSnap.recoveryPlan.playbackMutation,
      };

      final latestStatusDiag = <String, dynamic>{
        'hasSession': latestSnap.status.hasSession,
        'isPlaying': latestSnap.status.isPlaying,
        'positionMs': latestSnap.status.positionMs,
        'bufferedPositionMs': latestSnap.status.bufferedPositionMs,
        'bufferedPercent': latestSnap.status.bufferedPercent,
        'effectiveDisplayWidth': latestSnap.status.effectiveDisplayWidth,
        'effectiveDisplayHeight': latestSnap.status.effectiveDisplayHeight,
        'renderedFrames': controller.snapshot.session?.renderedFrames,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_COLLECT: DONE (collectedCount=${collectedSnapshots.length})',
      );

      // 6. Coordinator Evaluation & Invariants
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_COORDINATOR_EVALUATE: START',
      );
      _updateUi(
        '${config.humanTitle}: Evaluating snapshots through resilience coordinator...',
      );

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
            '${config.caseName} coordinator evaluation advisory/mutation invariant violation: '
            'advisoryOnly=${eval.advisoryOnly}, playbackMutation=${eval.playbackMutation}',
          );
        }
        if (!eval.decision.advisoryOnly || eval.decision.playbackMutation) {
          throw Exception(
            '${config.caseName} coordinator decision advisory/mutation invariant violation: '
            'advisoryOnly=${eval.decision.advisoryOnly}, playbackMutation=${eval.decision.playbackMutation}',
          );
        }
        if (!eval.retryBudget.advisoryOnly ||
            eval.retryBudget.playbackMutation) {
          throw Exception(
            '${config.caseName} coordinator retryBudget advisory/mutation invariant violation: '
            'advisoryOnly=${eval.retryBudget.advisoryOnly}, playbackMutation=${eval.retryBudget.playbackMutation}',
          );
        }
        if (!eval.journalSnapshot.advisoryOnly ||
            eval.journalSnapshot.playbackMutation) {
          throw Exception(
            '${config.caseName} coordinator journalSnapshot advisory/mutation invariant violation: '
            'advisoryOnly=${eval.journalSnapshot.advisoryOnly}, playbackMutation=${eval.journalSnapshot.playbackMutation}',
          );
        }

        // Coordinator length must remain 0 (pure advisory evaluate does not auto-record attempts)
        if (coordinator.length != 0) {
          throw Exception(
            '${config.caseName} coordinator length was modified during evaluate: length=${coordinator.length}',
          );
        }

        // Action must be a valid public enum value
        if (!VGStreamingPlaybackResilienceDecisionAction.values.contains(
          eval.action,
        )) {
          throw Exception(
            '${config.caseName} invalid coordinator action: ${eval.action}',
          );
        }

        // Verify JSON serialization roundtrip
        final evalJson = eval.toJson();
        if (evalJson['advisoryOnly'] != true ||
            evalJson['playbackMutation'] != false) {
          throw Exception(
            '${config.caseName} coordinator evaluation JSON serialization invariant violated',
          );
        }

        latestEvaluation = eval;
      }

      if (latestEvaluation == null) {
        throw Exception(
          '${config.caseName} failed to produce coordinator evaluation',
        );
      }

      final coordinatorEvalDiag = <String, dynamic>{
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

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_COORDINATOR_EVALUATE: DONE (action=${latestEvaluation.action.name}, length=${coordinator.length})',
      );

      // 7. Monitor Stop and Dispose Lifecycle
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_MONITOR_DISPOSE: START',
      );
      _updateUi(
        '${config.humanTitle}: Verifying monitor stop/dispose lifecycle...',
      );

      monitor.stop();
      if (monitor.isRunning) {
        throw Exception(
          '${config.caseName} monitor stop failed: isRunning is still true',
        );
      }

      await monitorSub.cancel();
      monitorSub = null;

      await monitor.dispose();
      if (!monitor.isDisposed) {
        throw Exception(
          '${config.caseName} monitor dispose failed: isDisposed is false',
        );
      }

      if (poller.isDisposed) {
        throw Exception(
          '${config.caseName} monitor disposal improperly disposed underlying poller',
        );
      }
      monitorDisposedPollerAlive = !poller.isDisposed;

      if (controller.isDisposed) {
        throw Exception(
          '${config.caseName} monitor disposal improperly disposed underlying controller',
        );
      }
      monitorDisposedControllerAlive = !controller.isDisposed;

      // Safe evaluateOnce() on disposed monitor must not throw and must return advisory-only snapshot
      final safeDisposedSnap = monitor.evaluateOnce(poller.latest);
      if (!safeDisposedSnap.advisoryOnly || safeDisposedSnap.playbackMutation) {
        throw Exception(
          '${config.caseName} disposed monitor evaluateOnce invariant violated',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_MONITOR_DISPOSE: DONE',
      );

      // 8. Poller Stop and Dispose Lifecycle
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_POLLER_DISPOSE: START',
      );
      _updateUi(
        '${config.humanTitle}: Verifying poller stop/dispose lifecycle...',
      );

      poller.stop();
      if (poller.isRunning) {
        throw Exception(
          '${config.caseName} poller stop failed: isRunning is still true',
        );
      }

      await poller.dispose();
      if (!poller.isDisposed) {
        throw Exception(
          '${config.caseName} poller dispose failed: isDisposed is false',
        );
      }

      if (controller.isDisposed) {
        throw Exception(
          '${config.caseName} poller disposal improperly disposed underlying controller',
        );
      }
      pollerDisposedControllerAlive = !controller.isDisposed;

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_POLLER_DISPOSE: DONE',
      );

      // 9. Controller Teardown
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_CONTROLLER_DISPOSE: START',
      );
      await controller.stop().timeout(_kControlTimeout);
      final disposeSnapshot = await controller.dispose().timeout(
        _kControlTimeout,
      );
      _updateUi(_status, snapshot: disposeSnapshot);

      if (!controller.isDisposed) {
        throw Exception(
          '${config.caseName} controller dispose failed: isDisposed is false',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_STEP_${config.caseName}_CONTROLLER_DISPOSE: DONE',
      );

      return _CaseExecutionResult(
        pass: true,
        decision: decision,
        textureId: openSnapshot.textureId,
        renderedFrames: initialRenderedSnapshot.session?.renderedFrames ?? 0,
        snapshotsCount: collectedSnapshots.length,
        latestSnapshotJson: latestSnap.toJson(),
        latestHealthJson: latestHealthDiag,
        latestRecoveryJson: latestRecoveryDiag,
        latestStatusJson: latestStatusDiag,
        latestCoordinatorEvalJson: coordinatorEvalDiag,
        coordinatorLengthAfterEvaluate: coordinator.length,
        monitorDisposedPollerAlive: monitorDisposedPollerAlive,
        monitorDisposedControllerAlive: monitorDisposedControllerAlive,
        pollerDisposedControllerAlive: pollerDisposedControllerAlive,
        rawSession: initialRenderedSnapshot.session?.raw,
      );
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_${config.caseName}_ERROR: $error\n$stack',
      );
      return _CaseExecutionResult(pass: false, error: error.toString());
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
  }

  Future<void> _runSmoke() async {
    final caseResults = <String, dynamic>{};

    // Define Candidate Streams
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
        VGStreamingSourceDescriptor(
          key: 'll_hls',
          uri: Uri.parse(
            'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
          ),
          formatHint: VGStreamingFormatHint.hls,
          initialWidth: _initialWidth,
          initialHeight: _initialHeight,
        ),
      ],
    );

    // Synthetic preflight report used for selector/controller/poller/monitor/coordinator composition only
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
      totalReports: 3,
      passedReports: 3,
      failedReports: 0,
      warnings: <String>[],
      deviceWarnings: <String>[],
      llHlsAvailable: true,
      advisoryOnly: true,
      playbackMutation: false,
      serverLadderPolicy: 'valid',
      iosMirrorNote: 'synthetic_preflight_for_selector_composition',
      raw: 'status=OK;phase=Phase4C5G',
      diagnostics: <String, Object?>{'pass': true, 'phase': 'Phase4C5G'},
    );

    // Case 1: HLS Fallback from preferDash
    final hlsCase = await _runTestCase(
      _CaseConfig(
        caseName: 'HLS_FALLBACK',
        caseKey: 'hls_fallback',
        humanTitle: 'Case 1/2 (HLS fallback)',
        request: VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: syntheticPreflightReport,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
        validateDecision: (decision) {
          if (!decision.canOpenPlayback ||
              decision.decision != 'playback_ready' ||
              decision.selectedKey != 'hls' ||
              decision.playbackOptions?.formatHint !=
                  VGStreamingFormatHint.hls ||
              !decision.warnings.contains(
                'source_incompatible:dash:dash_not_supported',
              )) {
            throw Exception(
              'HLS fallback planning assertion failed: canOpenPlayback=${decision.canOpenPlayback}, '
              'decision=${decision.decision}, selectedKey=${decision.selectedKey}, '
              'formatHint=${decision.playbackOptions?.formatHint}, warnings=${decision.warnings}',
            );
          }
        },
      ),
      syntheticPreflightReport,
    );
    caseResults['hls_fallback'] = hlsCase.toJson();
    final hlsFallbackPass = hlsCase.pass;

    // Case 2: LL-HLS Selection
    final llHlsCase = await _runTestCase(
      _CaseConfig(
        caseName: 'LL_HLS',
        caseKey: 'll_hls',
        humanTitle: 'Case 2/2 (LL-HLS)',
        request: VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: syntheticPreflightReport,
          preference: VGStreamingSourceSelectionPreference.preferHls,
          preferredKeys: const ['ll_hls'],
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(
                preferLowLatency: true,
              ),
        ),
        validateDecision: (decision) {
          if (!decision.canOpenPlayback ||
              decision.decision != 'playback_ready' ||
              decision.selectedKey != 'll_hls' ||
              decision.playbackOptions?.formatHint !=
                  VGStreamingFormatHint.hls) {
            throw Exception(
              'LL-HLS planning assertion failed: canOpenPlayback=${decision.canOpenPlayback}, '
              'decision=${decision.decision}, selectedKey=${decision.selectedKey}, '
              'formatHint=${decision.playbackOptions?.formatHint}, warnings=${decision.warnings}',
            );
          }
        },
      ),
      syntheticPreflightReport,
    );
    caseResults['ll_hls'] = llHlsCase.toJson();
    final llHlsPass = llHlsCase.pass;

    final allPass = hlsFallbackPass && llHlsPass;
    final results = <String, dynamic>{
      'phase': 'Phase4C8K',
      'target': 'ios_physical',
      'pass': allPass,
      'hlsFallbackPass': hlsFallbackPass,
      'llHlsPass': llHlsPass,
      'hlsFallback': caseResults['hls_fallback'],
      'llHls': caseResults['ll_hls'],
      'cases': caseResults,
      'nonClaims': <String, dynamic>{
        'noRealRetryExecuted': true,
        'recordHostRetryAttemptedCalled': false,
        'directIosDashPlaybackUnsupportedDeferred': true,
        'syntheticPreflightForCompositionOnly': true,
      },
    };

    // Emit final JSON marker
    // ignore: avoid_print
    print(
      'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_PASS',
      );
    } else {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_FAIL',
      );
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Multi-Source Resilience Coordinator Verified (HLS Fallback: OK, LL-HLS: OK)'
            : 'FAIL: Multi-Source Resilience Coordinator Smoke Failed (HLS: $hlsFallbackPass, LL-HLS: $llHlsPass)';
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
