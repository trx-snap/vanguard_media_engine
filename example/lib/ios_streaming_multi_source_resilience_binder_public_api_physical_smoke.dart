// Copyright (c) Connects — Vanguard Phase 4C8L.
// iOS Public streaming playback multi-source resilience binder -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream set (DASH, HLS, LL-HLS) via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Composition with synthetic advisory preflight report for selector/controller/poller/monitor/coordinator/binder composition.
//      (Synthetic preflight report is used solely for composition proof; this harness does not re-prove native preflight).
//   3. Case 1 (HLS fallback):
//      - Decision planning with preferDash under appleAvPlayer capabilities.
//      - Asserts decision is playback_ready, selects 'hls' with HLS formatHint, and emits dash_not_supported warning.
//      - Opens controller with startPlayback: true.
//      - Refreshes until renderedFrames > 0, positive display dimensions, and valid state.
//      - Attaches VGStreamingPlaybackStatusPoller (300ms interval, emitInitialSummary: true).
//      - Attaches VGStreamingPlaybackResilienceMonitor (constrained profile, maxHistory 8, allowAutomaticRetry false).
//      - Instantiates fresh pure-Dart VGStreamingPlaybackResilienceCoordinator with bounded retry journal and retry budget config.
//      - Instantiates fresh pure-Dart VGStreamingPlaybackResilienceBinder over monitor.snapshots with coordinator, streamKey 'hls_fallback', and deterministic nowProvider.
//      - Starts binder twice (asserting idempotent no duplicate subscription), then starts monitor, then poller.
//      - Collects >= 2 monitor snapshots and >= 2 binder evaluations within bounded timeout.
//      - Asserts status session/dimensions/progress evidence and standard monitor advisory/no-mutation/history/status-bounds invariants.
//      - Asserts every binder evaluation: evaluation/decision/retryBudget/journalSnapshot advisoryOnly true and playbackMutation false; diagnostics streamKey equals caseKey; action is in VGStreamingPlaybackResilienceDecisionAction.values; toJson() preserves advisory/no-mutation.
//      - Asserts coordinator.length == 0 and coordinator.journalSnapshot().count == 0 (no automatic attempt recording).
//      - Asserts binder.latest is non-null and matches latest collected evaluation.
//      - Stops poller before count-sensitive lifecycle checks.
//      - Stops binder; asserts isRunning == false and isDisposed == false.
//      - While stopped, calls monitor.evaluateOnce(latest.status) and asserts binder evaluation count does not increase.
//      - Calls binder.evaluateOnce(latestSnapshot) while stopped; asserts it emits exactly one new evaluation, updates latest, preserves advisory/no-mutation, and coordinator journal remains zero.
//      - Restarts binder; calls monitor.evaluateOnce(latest.status) and asserts exactly one additional evaluation arrives.
//      - Disposes binder; asserts binder disposed/running false and monitor/poller/controller remain alive. binder.start() after dispose must be a no-op.
//      - Disposes monitor; asserts poller/controller alive. Disposes poller; asserts controller alive. Stops/disposes controller.
//   4. Case 2 (LL-HLS selection):
//      - Decision planning with preferredKeys: ['ll_hls'] and appleAvPlayer(preferLowLatency: true).
//      - Asserts decision is playback_ready, selects 'll_hls' with HLS formatHint.
//      - Opens controller with startPlayback: true.
//      - Refreshes until renderedFrames > 0, positive display dimensions, and valid state.
//      - Attaches VGStreamingPlaybackStatusPoller (300ms interval, emitInitialSummary: true).
//      - Attaches VGStreamingPlaybackResilienceMonitor (constrained profile, maxHistory 8, allowAutomaticRetry false).
//      - Instantiates fresh pure-Dart VGStreamingPlaybackResilienceCoordinator with bounded retry journal and retry budget config.
//      - Instantiates fresh pure-Dart VGStreamingPlaybackResilienceBinder over monitor.snapshots with coordinator, streamKey 'll_hls', and deterministic nowProvider.
//      - Starts binder twice (asserting idempotent no duplicate subscription), then starts monitor, then poller.
//      - Collects >= 2 monitor snapshots and >= 2 binder evaluations within bounded timeout.
//      - Asserts status session/dimensions/progress evidence and standard monitor advisory/no-mutation/history/status-bounds invariants.
//      - Asserts every binder evaluation: evaluation/decision/retryBudget/journalSnapshot advisoryOnly true and playbackMutation false; diagnostics streamKey equals caseKey; action is in VGStreamingPlaybackResilienceDecisionAction.values; toJson() preserves advisory/no-mutation.
//      - Asserts coordinator.length == 0 and coordinator.journalSnapshot().count == 0 (no automatic attempt recording).
//      - Asserts binder.latest is non-null and matches latest collected evaluation.
//      - Stops poller before count-sensitive lifecycle checks.
//      - Stops binder; asserts isRunning == false and isDisposed == false.
//      - While stopped, calls monitor.evaluateOnce(latest.status) and asserts binder evaluation count does not increase.
//      - Calls binder.evaluateOnce(latestSnapshot) while stopped; asserts it emits exactly one new evaluation, updates latest, preserves advisory/no-mutation, and coordinator journal remains zero.
//      - Restarts binder; calls monitor.evaluateOnce(latest.status) and asserts exactly one additional evaluation arrives.
//      - Disposes binder; asserts binder disposed/running false and monitor/poller/controller remain alive. binder.start() after dispose must be a no-op.
//      - Disposes monitor; asserts poller/controller alive. Disposes poller; asserts controller alive. Stops/disposes controller.
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
// - Synthetic preflight report used for selector/controller/poller/monitor/coordinator/binder composition only (no native preflight claim).
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
const Duration _kCollectionTimeout = Duration(seconds: 20);

void main() {
  runApp(
    const IosStreamingMultiSourceResilienceBinderPublicApiPhysicalSmokeApp(),
  );
}

class IosStreamingMultiSourceResilienceBinderPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingMultiSourceResilienceBinderPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<IosStreamingMultiSourceResilienceBinderPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingMultiSourceResilienceBinderPublicApiPhysicalSmokeAppState();
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
    this.evaluationsCount = 0,
    this.latestSnapshotJson,
    this.latestHealthJson,
    this.latestRecoveryJson,
    this.latestStatusJson,
    this.latestBinderEvalJson,
    this.coordinatorLengthAfterEvaluate = 0,
    this.binderDisposedMonitorAlive = false,
    this.binderDisposedPollerAlive = false,
    this.binderDisposedControllerAlive = false,
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
  final int evaluationsCount;
  final Map<String, dynamic>? latestSnapshotJson;
  final Map<String, dynamic>? latestHealthJson;
  final Map<String, dynamic>? latestRecoveryJson;
  final Map<String, dynamic>? latestStatusJson;
  final Map<String, dynamic>? latestBinderEvalJson;
  final int coordinatorLengthAfterEvaluate;
  final bool binderDisposedMonitorAlive;
  final bool binderDisposedPollerAlive;
  final bool binderDisposedControllerAlive;
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
        'evaluationsCount': evaluationsCount,
        'latestSnapshot': latestSnapshotJson,
        'latestHealth': latestHealthJson,
        'latestRecovery': latestRecoveryJson,
        'latestStatus': latestStatusJson,
        'binderEvaluation': latestBinderEvalJson,
        'coordinatorLengthAfterEvaluate': coordinatorLengthAfterEvaluate,
        'binderDisposedMonitorAlive': binderDisposedMonitorAlive,
        'binderDisposedPollerAlive': binderDisposedPollerAlive,
        'binderDisposedControllerAlive': binderDisposedControllerAlive,
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

class _IosStreamingMultiSourceResilienceBinderPublicApiPhysicalSmokeAppState
    extends
        State<
          IosStreamingMultiSourceResilienceBinderPublicApiPhysicalSmokeApp
        > {
  String _status =
      'Bootstrapping iOS multi-source streaming playback resilience binder smoke...';
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
    print('IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_BOOTSTRAP_ERROR: $error\n$stack',
        );
        // ignore: avoid_print
        print(
          'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_FAIL',
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
    VGStreamingPlaybackResilienceBinder? binder;
    StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? monitorSub;
    StreamSubscription<VGStreamingPlaybackResilienceCoordinatorEvaluation>?
    binderSub;
    final collectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
    final collectedEvaluations =
        <VGStreamingPlaybackResilienceCoordinatorEvaluation>[];

    bool binderDisposedMonitorAlive = false;
    bool binderDisposedPollerAlive = false;
    bool binderDisposedControllerAlive = false;
    bool monitorDisposedPollerAlive = false;
    bool monitorDisposedControllerAlive = false;
    bool pollerDisposedControllerAlive = false;

    try {
      // 1. Plan
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_PLAN: START',
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
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_PLAN: DONE',
      );

      // 2. Open
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_OPEN: START',
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
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_OPEN: DONE (textureId=${openSnapshot.textureId})',
      );

      // 3. Status Wait
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_STATUS: START',
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
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_STATUS: DONE (renderedFrames=${initialSession.renderedFrames}, dims=${initialSession.effectiveDisplayWidth}x${initialSession.effectiveDisplayHeight})',
      );

      // 4. Poller, Resilience Monitor, Coordinator & Resilience Binder Setup & Start
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_BINDER_START: START',
      );
      _updateUi(
        '${config.humanTitle}: Instantiating and starting poller, monitor, coordinator, and binder...',
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

      int nowCounter = 1700000000000;
      int deterministicNow() {
        nowCounter += 500;
        return nowCounter;
      }

      binder = VGStreamingPlaybackResilienceBinder(
        snapshots: monitor.snapshots,
        coordinator: coordinator,
        config: VGStreamingPlaybackResilienceBinderConfig(
          streamKey: config.caseKey,
        ),
        nowProvider: deterministicNow,
      );

      monitorSub = monitor.snapshots.listen((snapshot) {
        collectedSnapshots.add(snapshot);
        if (mounted && controller != null) {
          _updateUi(_status, snapshot: controller.snapshot);
        }
      });

      binderSub = binder.evaluations.listen((evaluation) {
        collectedEvaluations.add(evaluation);
      });

      // Start binder, assert idempotent second start(), then start monitor, then poller
      binder.start();
      if (!binder.isRunning) {
        throw Exception(
          '${config.caseName} binder failed to start (isRunning is false)',
        );
      }
      binder.start();
      if (!binder.isRunning) {
        throw Exception(
          '${config.caseName} binder isRunning became false after second start()',
        );
      }

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
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_BINDER_START: DONE',
      );

      // 5. Collect Snapshots & Binder Evaluations
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_COLLECT: START',
      );
      _updateUi(
        '${config.humanTitle}: Collecting monitor snapshots and binder evaluations...',
      );

      final collectionDeadline = DateTime.now().add(_kCollectionTimeout);
      while (DateTime.now().isBefore(collectionDeadline)) {
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
          '${config.caseName} expected >= 2 emitted snapshots, got ${collectedSnapshots.length}',
        );
      }

      if (collectedEvaluations.length < 2) {
        throw Exception(
          '${config.caseName} expected >= 2 emitted binder evaluations, got ${collectedEvaluations.length}',
        );
      }

      final latestSnap = monitor.latest;
      if (latestSnap == null) {
        throw Exception('${config.caseName} monitor latest snapshot is null');
      }

      // Assert status invariants
      if (!latestSnap.status.hasSession) {
        throw Exception(
          '${config.caseName} latest snapshot hasSession is false',
        );
      }
      if (latestSnap.status.effectiveDisplayWidth <= 0 ||
          latestSnap.status.effectiveDisplayHeight <= 0) {
        throw Exception(
          '${config.caseName} latest snapshot effective dimensions non-positive: '
          '${latestSnap.status.effectiveDisplayWidth}x${latestSnap.status.effectiveDisplayHeight}',
        );
      }

      final hasProgress =
          (controller.snapshot.session?.renderedFrames ?? 0) > 0 ||
          latestSnap.status.isPlaying ||
          latestSnap.status.positionMs > 0 ||
          latestSnap.status.bufferedPositionMs > 0;

      if (!hasProgress) {
        throw Exception(
          '${config.caseName} no playback progress or rendering evidence observed',
        );
      }

      // Assert monitor invariants across collected snapshots
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

      // Stop poller now so background timer ticks do not race with baseline counts
      poller.stop();

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_COLLECT: DONE (snapshots=${collectedSnapshots.length}, evals=${collectedEvaluations.length})',
      );

      // 6. Binder & Coordinator Invariants Verification
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_BINDER_EVALUATE: START',
      );
      _updateUi(
        '${config.humanTitle}: Verifying binder and coordinator evaluation invariants...',
      );

      for (final eval in collectedEvaluations) {
        if (!eval.advisoryOnly || eval.playbackMutation) {
          throw Exception(
            '${config.caseName} binder evaluation advisory/mutation invariant violation: '
            'advisoryOnly=${eval.advisoryOnly}, playbackMutation=${eval.playbackMutation}',
          );
        }
        if (!eval.decision.advisoryOnly || eval.decision.playbackMutation) {
          throw Exception(
            '${config.caseName} binder decision advisory/mutation invariant violation: '
            'advisoryOnly=${eval.decision.advisoryOnly}, playbackMutation=${eval.decision.playbackMutation}',
          );
        }
        if (!eval.retryBudget.advisoryOnly ||
            eval.retryBudget.playbackMutation) {
          throw Exception(
            '${config.caseName} binder retryBudget advisory/mutation invariant violation: '
            'advisoryOnly=${eval.retryBudget.advisoryOnly}, playbackMutation=${eval.retryBudget.playbackMutation}',
          );
        }
        if (!eval.journalSnapshot.advisoryOnly ||
            eval.journalSnapshot.playbackMutation) {
          throw Exception(
            '${config.caseName} binder journalSnapshot advisory/mutation invariant violation: '
            'advisoryOnly=${eval.journalSnapshot.advisoryOnly}, playbackMutation=${eval.journalSnapshot.playbackMutation}',
          );
        }
        if (eval.diagnostics['streamKey'] != config.caseKey) {
          throw Exception(
            '${config.caseName} binder diagnostics streamKey invariant violation: ${eval.diagnostics['streamKey']}',
          );
        }
        if (!VGStreamingPlaybackResilienceDecisionAction.values.contains(
          eval.action,
        )) {
          throw Exception(
            '${config.caseName} invalid binder decision action: ${eval.action}',
          );
        }

        final evalJson = eval.toJson();
        if (evalJson['advisoryOnly'] != true ||
            evalJson['playbackMutation'] != false) {
          throw Exception(
            '${config.caseName} binder evaluation JSON serialization invariant violated',
          );
        }
      }

      // Assert coordinator journal remains zero (no automatic attempt recording)
      if (coordinator.length != 0 || coordinator.journalSnapshot().count != 0) {
        throw Exception(
          '${config.caseName} coordinator journal modified during binder evaluations: '
          'length=${coordinator.length}, journalCount=${coordinator.journalSnapshot().count}',
        );
      }

      // Assert binder.latest is not null and matches the latest collected evaluation
      if (binder.latest == null) {
        throw Exception(
          '${config.caseName} binder.latest is null after receiving evaluations',
        );
      }
      final latestEval = binder.latest!;
      final lastCollected = collectedEvaluations.last;
      if (latestEval.action != lastCollected.action ||
          latestEval.reasons.join(',') != lastCollected.reasons.join(',')) {
        throw Exception(
          '${config.caseName} binder.latest does not match last collected evaluation: '
          'latest=${latestEval.action}, lastCollected=${lastCollected.action}',
        );
      }

      final binderEvalDiag = <String, dynamic>{
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

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_BINDER_EVALUATE: DONE (action=${latestEval.action.name}, length=${coordinator.length})',
      );

      // 7. Binder Stop, evaluateOnce & Restart Lifecycle
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_LIFECYCLE_TEST: START',
      );
      _updateUi(
        '${config.humanTitle}: Testing stop, evaluateOnce & restart lifecycle...',
      );

      binder.stop();
      if (binder.isRunning) {
        throw Exception(
          '${config.caseName} binder stop failed: isRunning is still true',
        );
      }
      if (binder.isDisposed) {
        throw Exception(
          '${config.caseName} binder stop erroneously set isDisposed to true',
        );
      }

      final countBeforeStoppedMonitorEval = collectedEvaluations.length;
      // Trigger monitor.evaluateOnce on latest status while binder is stopped
      monitor.evaluateOnce(latestSnap.status);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (collectedEvaluations.length != countBeforeStoppedMonitorEval) {
        throw Exception(
          '${config.caseName} binder evaluation count increased while stopped: before=$countBeforeStoppedMonitorEval, after=${collectedEvaluations.length}',
        );
      }

      // Call binder.evaluateOnce directly while stopped
      final manualEval = binder.evaluateOnce(latestSnap);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!manualEval.advisoryOnly || manualEval.playbackMutation) {
        throw Exception(
          '${config.caseName} manual evaluateOnce violated advisory invariant',
        );
      }
      if (coordinator.length != 0 || coordinator.journalSnapshot().count != 0) {
        throw Exception(
          '${config.caseName} coordinator journal modified during manual evaluateOnce',
        );
      }
      if (binder.latest != manualEval) {
        throw Exception(
          '${config.caseName} binder.latest not updated by manual evaluateOnce',
        );
      }
      if (collectedEvaluations.length != countBeforeStoppedMonitorEval + 1) {
        throw Exception(
          '${config.caseName} expected 1 manual evaluation emitted onto stream, but count is ${collectedEvaluations.length} (before=$countBeforeStoppedMonitorEval)',
        );
      }

      // Restart binder and verify resumed listening
      binder.start();
      if (!binder.isRunning) {
        throw Exception(
          '${config.caseName} binder restart failed: isRunning is false',
        );
      }
      final countBeforeRestartedMonitorEval = collectedEvaluations.length;
      monitor.evaluateOnce(latestSnap.status);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (collectedEvaluations.length != countBeforeRestartedMonitorEval + 1) {
        throw Exception(
          '${config.caseName} expected exactly 1 additional evaluation after monitor evaluateOnce on restarted binder, '
          'before=$countBeforeRestartedMonitorEval, after=${collectedEvaluations.length}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_LIFECYCLE_TEST: DONE',
      );

      // 8. Binder Dispose Lifecycle
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_BINDER_DISPOSE: START',
      );
      _updateUi(
        '${config.humanTitle}: Testing binder dispose & full pipeline teardown...',
      );

      binder.dispose();
      if (!binder.isDisposed) {
        throw Exception(
          '${config.caseName} binder dispose failed: isDisposed is false',
        );
      }
      if (binder.isRunning) {
        throw Exception(
          '${config.caseName} binder isRunning is true after dispose',
        );
      }

      binderDisposedMonitorAlive = !monitor.isDisposed;
      binderDisposedPollerAlive = !poller.isDisposed;
      binderDisposedControllerAlive = !controller.isDisposed;

      if (!binderDisposedMonitorAlive) {
        throw Exception(
          '${config.caseName} binder disposal improperly disposed underlying monitor',
        );
      }
      if (!binderDisposedPollerAlive) {
        throw Exception(
          '${config.caseName} binder disposal improperly disposed underlying poller',
        );
      }
      if (!binderDisposedControllerAlive) {
        throw Exception(
          '${config.caseName} binder disposal improperly disposed underlying controller',
        );
      }

      // Calling start() after dispose must be a no-op
      binder.start();
      if (binder.isRunning) {
        throw Exception(
          '${config.caseName} calling start() after dispose unexpectedly set isRunning to true',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_BINDER_DISPOSE: DONE',
      );

      // 9. Monitor Stop and Dispose Lifecycle
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_MONITOR_DISPOSE: START',
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
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_MONITOR_DISPOSE: DONE',
      );

      // 10. Poller Stop and Dispose Lifecycle
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_POLLER_DISPOSE: START',
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
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_POLLER_DISPOSE: DONE',
      );

      // 11. Controller Teardown
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_CONTROLLER_DISPOSE: START',
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
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_STEP_${config.caseName}_CONTROLLER_DISPOSE: DONE',
      );

      return _CaseExecutionResult(
        pass: true,
        decision: decision,
        textureId: openSnapshot.textureId,
        renderedFrames: initialRenderedSnapshot.session?.renderedFrames ?? 0,
        snapshotsCount: collectedSnapshots.length,
        evaluationsCount: collectedEvaluations.length,
        latestSnapshotJson: latestSnap.toJson(),
        latestHealthJson: latestHealthDiag,
        latestRecoveryJson: latestRecoveryDiag,
        latestStatusJson: latestStatusDiag,
        latestBinderEvalJson: binderEvalDiag,
        coordinatorLengthAfterEvaluate: coordinator.length,
        binderDisposedMonitorAlive: binderDisposedMonitorAlive,
        binderDisposedPollerAlive: binderDisposedPollerAlive,
        binderDisposedControllerAlive: binderDisposedControllerAlive,
        monitorDisposedPollerAlive: monitorDisposedPollerAlive,
        monitorDisposedControllerAlive: monitorDisposedControllerAlive,
        pollerDisposedControllerAlive: pollerDisposedControllerAlive,
        rawSession: initialRenderedSnapshot.session?.raw,
      );
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_${config.caseName}_ERROR: $error\n$stack',
      );
      return _CaseExecutionResult(pass: false, error: error.toString());
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

    // Synthetic preflight report used for selector/controller/poller/monitor/coordinator/binder composition only
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
        caseKey: 'hls',
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
      'phase': 'Phase4C8L',
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
      'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_PASS',
      );
    } else {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_FAIL',
      );
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Multi-Source Resilience Binder Verified (HLS Fallback: OK, LL-HLS: OK)'
            : 'FAIL: Multi-Source Resilience Binder Smoke Failed (HLS: $hlsFallbackPass, LL-HLS: $llHlsPass)';
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
