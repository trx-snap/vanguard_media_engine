// Copyright (c) Connects — Vanguard Phase 4C8T.
// iOS Public streaming native preflight resilience binder all-up physical smoke.
//
// Route:
//   VGStreamingSourceSet ->
//   VGStreamingPreflightClient.evaluate(...) [actual native iOS preflight] ->
//   VGStreamingStartupPlanner.fromPreflight(...) ->
//   VGStreamingPlaybackDecisionPlanner.plan(...) [capability-filtered decision] ->
//   VGStreamingPlaybackController.open/refresh/stop/dispose ->
//   VGStreamingPlaybackTextureView presentation ->
//   VGStreamingPlaybackStatusPoller [Stream<VGStreamingPlaybackStatusSummary>] ->
//   VGStreamingPlaybackResilienceMonitor [Stream<VGStreamingPlaybackResilienceSnapshot>] ->
//   VGStreamingPlaybackResilienceCoordinator [pure-Dart stateful advisory retry coordination] ->
//   VGStreamingPlaybackResilienceBinder [Stream<VGStreamingPlaybackResilienceCoordinatorEvaluation>]
//
// Scenarios:
//   1. Compatible native source-set preflight:
//      - Build VGStreamingSourceSet with [hls, ll_hls].
//      - sourceSet.toPreflightRequest(preferLowLatency: true, requestedNetworkProfile: auto).
//      - Evaluate via VGStreamingPreflightClient.evaluate.
//      - Assert report.pass == true, advisoryOnly == true, playbackMutation == false,
//        totalReports == 2, failedReports == 0, phase contains Phase4C8C, llHlsAvailable == true.
//      - Build VGStreamingStartupPlanner.fromPreflight(report); assert shouldProceed == true.
//      - Emit IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_SOURCE_SET_PREFLIGHT: START/DONE.
//   2. HLS fallback decision -> controller -> status poller -> resilience monitor -> coordinator -> binder:
//      - Fallback source set ordered [dash, hls].
//      - VGStreamingPlaybackDecisionPlanner.plan(preflightReport: report from scenario 1,
//        preference: preferDash, clientCapabilities: appleAvPlayer()).
//      - Assert decision.canOpenPlayback == true, decision.decision == 'playback_ready',
//        selectedKey == 'hls', playbackOptions != null,
//        warnings contains 'source_incompatible:dash:dash_not_supported'.
//      - Open fresh VGStreamingPlaybackController with startPlayback: true.
//      - Poll controller.refresh() until renderedFrames > 0 and effectiveDisplayWidth/Height > 0.
//      - Attach VGStreamingPlaybackStatusPoller (300ms interval, emitInitialSummary: true).
//      - Attach VGStreamingPlaybackResilienceMonitor over poller.summaries (preflightReport: report,
//        currentOptions: decision.playbackOptions, currentNetworkProfile: constrained, maxHistoryLength: 8,
//        allowAutomaticRetry: false).
//      - Instantiate fresh VGStreamingPlaybackResilienceCoordinator (maxStoredAttempts: 10,
//        maxAttempts: 3, windowMs: 30000, minimumDelayMs: 1000, streamKey: 'hls').
//      - Instantiate fresh VGStreamingPlaybackResilienceBinder over monitor.snapshots with coordinator,
//        VGStreamingPlaybackResilienceBinderConfig(streamKey: 'hls'), and deterministic nowProvider (+500ms).
//      - Subscribe to monitor snapshots and binder evaluations.
//      - Start binder twice (asserting idempotent running state), then start monitor, then poller.
//      - Collect >= 2 monitor snapshots and >= 2 binder evaluations.
//      - Assert monitor snapshot invariants: snapshot/health/recovery advisory-only and no mutation,
//        valid history length, bounded status counters/fractions, progress/render evidence, JSON encodes.
//      - Assert every binder evaluation, decision, retryBudget, and journalSnapshot is advisory-only and no mutation;
//        diagnostics streamKey is 'hls'; action is valid enum; toJson() preserves advisory/no-mutation.
//      - Assert coordinator journal remains zero: coordinator.length == 0 and coordinator.journalSnapshot().count == 0 (no auto-record).
//      - Assert binder.latest is non-null and matches latest collected evaluation.
//      - Stop poller before count-sensitive lifecycle checks.
//      - Stop binder and assert isRunning == false, isDisposed == false.
//      - While binder is stopped, call monitor.evaluateOnce(latest.status) and assert binder evaluation count does not increase.
//      - Call binder.evaluateOnce(latestSnapshot) while stopped; assert exactly 1 new evaluation, latest updated, advisory/no-mutation preserved, journal remains 0.
//      - Restart binder; call monitor.evaluateOnce(latest.status) and assert exactly 1 additional evaluation arrives.
//      - Dispose binder; assert binder disposed/running false and monitor/poller/controller remain alive. binder.start() after dispose is a no-op.
//      - Dispose monitor; assert poller/controller alive. Dispose poller; assert controller alive. Stop/dispose controller in finally.
//      - Emit START/DONE markers for HLS decision, open, status, binder start, collect, binder evaluate/lifecycle, binder dispose, monitor dispose, poller dispose, controller dispose.
//   3. LL-HLS decision -> controller -> status poller -> resilience monitor -> coordinator -> binder:
//      - Use compatible source set [hls, ll_hls] and report from scenario 1.
//      - Plan with preferredKeys: ['ll_hls'], preference: preferLowLatency,
//        clientCapabilities: appleAvPlayer(preferLowLatency: true).
//      - Assert decision.canOpenPlayback == true, selectedKey == 'll_hls',
//        selectedSource.requireLlHlsTags == true.
//      - Repeat real controller + public poller + monitor + coordinator + binder assertions from HLS with streamKey 'll_hls'.
//      - Emit equivalent LL-HLS markers.
//   4. DASH typed deferral:
//      - Run actual DASH-only native preflight via dashSourceSet.toPreflightRequest(requestedNetworkProfile: auto).
//      - Assert report.pass == false, failedReports >= 1, warnings contains 'unsupported_format_dash',
//        advisoryOnly == true, playbackMutation == false, startup plan shouldProceed == false.
//      - Plan dash-only decision with VGStreamingPlaybackDecisionPlanner.plan,
//        preference preferDash, clientCapabilities appleAvPlayer();
//        assert canOpenPlayback == false, decision == 'startup_plan_blocked', playbackOptions == null.
//      - Zero playback mutation / never open playback controller, poller, monitor, coordinator, or binder for DASH.
//      - Emit IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_DASH_DEFERRAL: START/DONE.
//
// Verification Invariants & Boundaries:
// - Imports ONLY:
//   - dart:async
//   - dart:convert
//   - dart:io
//   - package:flutter/material.dart
//   - package:vanguard_media_engine/vanguard_media_engine.dart
// - No raw MethodChannel or package:flutter/services.dart.
// - Render through VGStreamingPlaybackTextureView only (no raw Texture widget).
// - Actual native iOS preflight and actual AVPlayer playback.
// - Pure Dart advisory binder & coordinator over real monitor snapshots with zero automatic attempt mutation.
// - Typed DASH deferral without attempting playback, poller, monitor, coordinator, or binder instantiation.
// - All controllers, pollers, monitors, binders, and stream subscriptions cleaned up in finally blocks.
// - Emits structured step markers and terminal JSON payload.
// - Exit 0 on pass, exit 1 on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kPhase = 'Phase4C8T';
const String _kTarget = 'ios_physical';
const String _kPassMarker =
    'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_PASS';
const String _kFailMarker =
    'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_FAIL';

const String _kHlsUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const String _kLlHlsUrl =
    'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8';
const String _kDashUrl =
    'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd';

const int _initialWidth = 640;
const int _initialHeight = 360;
const Duration _kPreflightTimeout = Duration(seconds: 25);
const Duration _kControlTimeout = Duration(seconds: 8);
const Duration _kPollInterval = Duration(milliseconds: 300);
const Duration _kStatusDeadline = Duration(seconds: 20);
const Duration _kSnapshotCollectionTimeout = Duration(seconds: 15);

void main() {
  runApp(
    const IosStreamingPreflightResilienceBinderPublicApiPhysicalSmokeApp(),
  );
}

class IosStreamingPreflightResilienceBinderPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingPreflightResilienceBinderPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<IosStreamingPreflightResilienceBinderPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingPreflightResilienceBinderPublicApiPhysicalSmokeAppState();
}

class _IosStreamingPreflightResilienceBinderPublicApiPhysicalSmokeAppState
    extends
        State<IosStreamingPreflightResilienceBinderPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Bootstrapping iOS streaming preflight resilience binder smoke...';
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
    print('IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_BOOTSTRAP_ERROR: $error\n$stack',
        );
        // ignore: avoid_print
        print(_kFailMarker);
        exit(1);
      }
    });
  }

  void _assertSnapshotInvariants(
    VGStreamingPlaybackResilienceSnapshot snapshot, {
    required String scenarioName,
  }) {
    if (!snapshot.advisoryOnly || snapshot.playbackMutation) {
      throw Exception(
        'Snapshot mutation invariants violated ($scenarioName): '
        'advisoryOnly=${snapshot.advisoryOnly}, playbackMutation=${snapshot.playbackMutation}',
      );
    }

    if (!snapshot.healthAdvice.advisoryOnly ||
        snapshot.healthAdvice.playbackMutation) {
      throw Exception(
        'Health advice mutation invariants violated ($scenarioName): '
        'advisoryOnly=${snapshot.healthAdvice.advisoryOnly}, playbackMutation=${snapshot.healthAdvice.playbackMutation}',
      );
    }

    if (!snapshot.recoveryPlan.advisoryOnly ||
        snapshot.recoveryPlan.playbackMutation) {
      throw Exception(
        'Recovery plan mutation invariants violated ($scenarioName): '
        'advisoryOnly=${snapshot.recoveryPlan.advisoryOnly}, playbackMutation=${snapshot.recoveryPlan.playbackMutation}',
      );
    }

    if (snapshot.historyLength < 1 || snapshot.historyLength > 8) {
      throw Exception(
        'Snapshot historyLength out of bounds ($scenarioName): ${snapshot.historyLength}',
      );
    }

    final status = snapshot.status;
    final durationValid = status.durationMs >= -1;
    final positionValid = status.positionMs >= 0;
    final bufferedPosValid = status.bufferedPositionMs >= 0;
    final bufferedPercentValid =
        status.bufferedPercent >= 0 && status.bufferedPercent <= 100;
    final progressFractionValid =
        status.progressFraction >= 0.0 && status.progressFraction <= 1.0;
    final bufferedFractionValid =
        status.bufferedFraction >= 0.0 && status.bufferedFraction <= 1.0;

    final jsonMap = snapshot.toJson();
    final jsonString = jsonEncode(jsonMap);
    final jsonValid = jsonString.isNotEmpty;

    if (!durationValid ||
        !positionValid ||
        !bufferedPosValid ||
        !bufferedPercentValid ||
        !progressFractionValid ||
        !bufferedFractionValid ||
        !jsonValid) {
      throw Exception(
        'Status metrics bounds or JSON serialization failed ($scenarioName): '
        'duration=${status.durationMs}, position=${status.positionMs}, '
        'bufferedPos=${status.bufferedPositionMs}, bufferedPercent=${status.bufferedPercent}, '
        'progressFraction=${status.progressFraction}, bufferedFraction=${status.bufferedFraction}, '
        'jsonValid=$jsonValid',
      );
    }
  }

  void _assertBinderEvaluationInvariants(
    VGStreamingPlaybackResilienceCoordinatorEvaluation evaluation,
    VGStreamingPlaybackResilienceCoordinator coordinator, {
    required String scenarioName,
    required String expectedStreamKey,
  }) {
    if (!evaluation.advisoryOnly || evaluation.playbackMutation) {
      throw Exception(
        'Binder evaluation advisory/mutation invariant violation ($scenarioName): '
        'advisoryOnly=${evaluation.advisoryOnly}, playbackMutation=${evaluation.playbackMutation}',
      );
    }
    if (!evaluation.decision.advisoryOnly ||
        evaluation.decision.playbackMutation) {
      throw Exception(
        'Binder decision advisory/mutation invariant violation ($scenarioName): '
        'advisoryOnly=${evaluation.decision.advisoryOnly}, playbackMutation=${evaluation.decision.playbackMutation}',
      );
    }
    if (!evaluation.retryBudget.advisoryOnly ||
        evaluation.retryBudget.playbackMutation) {
      throw Exception(
        'Binder retryBudget advisory/mutation invariant violation ($scenarioName): '
        'advisoryOnly=${evaluation.retryBudget.advisoryOnly}, playbackMutation=${evaluation.retryBudget.playbackMutation}',
      );
    }
    if (!evaluation.journalSnapshot.advisoryOnly ||
        evaluation.journalSnapshot.playbackMutation) {
      throw Exception(
        'Binder journalSnapshot advisory/mutation invariant violation ($scenarioName): '
        'advisoryOnly=${evaluation.journalSnapshot.advisoryOnly}, playbackMutation=${evaluation.journalSnapshot.playbackMutation}',
      );
    }
    if (evaluation.diagnostics['streamKey'] != expectedStreamKey) {
      throw Exception(
        'Binder diagnostics streamKey invariant violation ($scenarioName): ${evaluation.diagnostics['streamKey']} (expected $expectedStreamKey)',
      );
    }

    if (coordinator.length != 0 || coordinator.journalSnapshot().count != 0) {
      throw Exception(
        'Coordinator journal was modified during binder evaluate ($scenarioName): '
        'length=${coordinator.length}, journalCount=${coordinator.journalSnapshot().count}',
      );
    }

    if (!VGStreamingPlaybackResilienceDecisionAction.values.contains(
      evaluation.action,
    )) {
      throw Exception(
        'Invalid binder action ($scenarioName): ${evaluation.action}',
      );
    }

    final evalJson = evaluation.toJson();
    if (evalJson['advisoryOnly'] != true ||
        evalJson['playbackMutation'] != false) {
      throw Exception(
        'Binder evaluation JSON serialization invariant violated ($scenarioName)',
      );
    }
  }

  Future<void> _runSmoke() async {
    await Future<void>.delayed(const Duration(seconds: 1));

    final results = <String, dynamic>{
      'phase': _kPhase,
      'target': _kTarget,
      'advisoryOnlyVerified': false,
      'playbackMutationZeroVerified': false,
    };
    bool allPass = false;

    bool sourceSetPreflightPass = false;
    bool hlsResilienceBinderPass = false;
    bool llHlsResilienceBinderPass = false;
    bool dashTypedDeferralPass = false;

    int hlsRenderedFrames = 0;
    int llHlsRenderedFrames = 0;
    int hlsDisplayWidth = 0;
    int hlsDisplayHeight = 0;
    int llHlsDisplayWidth = 0;
    int llHlsDisplayHeight = 0;

    final selectedKeys = <String>[];
    final allWarnings = <String>[];

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 1: Compatible native source-set preflight
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_SOURCE_SET_PREFLIGHT: START',
      );
      if (mounted) {
        setState(() {
          _status = 'Scenario 1: Evaluating native source-set preflight…';
        });
      }

      final hlsDescriptor = VGStreamingSourceDescriptor(
        key: 'hls',
        uri: Uri.parse(_kHlsUrl),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: _initialWidth,
        initialHeight: _initialHeight,
        allowMediaPlaylist: true,
      );

      final llHlsDescriptor = VGStreamingSourceDescriptor(
        key: 'll_hls',
        uri: Uri.parse(_kLlHlsUrl),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: _initialWidth,
        initialHeight: _initialHeight,
        requireLlHlsTags: true,
      );

      final compatibleSourceSet = VGStreamingSourceSet(
        sources: [hlsDescriptor, llHlsDescriptor],
      );

      final preflightRequest = compatibleSourceSet.toPreflightRequest(
        preferLowLatency: true,
        requestedNetworkProfile: VGStreamingNetworkProfile.auto,
      );

      final report = await _preflightClient
          .evaluate(preflightRequest)
          .timeout(_kPreflightTimeout);

      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_SOURCE_SET_PREFLIGHT: DONE',
      );

      if (!report.pass) {
        throw Exception(
          'Scenario 1 failed: report.pass is false (${report.diagnostics})',
        );
      }
      if (!report.advisoryOnly) {
        throw Exception('Scenario 1 failed: report.advisoryOnly is not true');
      }
      if (report.playbackMutation) {
        throw Exception('Scenario 1 failed: report.playbackMutation is true');
      }
      if (report.totalReports != 2) {
        throw Exception(
          'Scenario 1 failed: report.totalReports was ${report.totalReports} (expected 2)',
        );
      }
      if (report.failedReports != 0) {
        throw Exception(
          'Scenario 1 failed: report.failedReports was ${report.failedReports} (expected 0)',
        );
      }
      if (!report.phase.contains('Phase4C8C')) {
        throw Exception(
          'Scenario 1 failed: report.phase "${report.phase}" did not contain Phase4C8C',
        );
      }
      if (!report.llHlsAvailable) {
        throw Exception('Scenario 1 failed: report.llHlsAvailable is not true');
      }

      final startupPlan = VGStreamingStartupPlanner.fromPreflight(report);
      if (!startupPlan.shouldProceed) {
        throw Exception(
          'Scenario 1 failed: startup plan shouldProceed is false (reason: ${startupPlan.reason})',
        );
      }

      sourceSetPreflightPass = true;
      results['sourceSetPreflightPass'] = true;
      results['sourceSetPreflight'] = <String, dynamic>{
        'pass': true,
        'reportPass': report.pass,
        'advisoryOnly': report.advisoryOnly,
        'playbackMutation': report.playbackMutation,
        'totalReports': report.totalReports,
        'failedReports': report.failedReports,
        'phase': report.phase,
        'llHlsAvailable': report.llHlsAvailable,
        'advisoryDecision': report.advisoryDecision,
        'recommendedNetworkProfile': startupPlan.recommendedNetworkProfile
            .toNative(),
        'shouldProceed': startupPlan.shouldProceed,
      };

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 2: HLS Fallback decision -> controller -> status poller -> resilience monitor -> coordinator -> binder
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_DECISION: START',
      );
      if (mounted) {
        setState(() {
          _status =
              'Scenario 2: Planning HLS fallback decision under appleAvPlayer…';
        });
      }

      final dashDescriptor = VGStreamingSourceDescriptor(
        key: 'dash',
        uri: Uri.parse(_kDashUrl),
        formatHint: VGStreamingFormatHint.dash,
        initialWidth: _initialWidth,
        initialHeight: _initialHeight,
      );

      final fallbackSourceSet = VGStreamingSourceSet(
        sources: [dashDescriptor, hlsDescriptor],
      );

      final hlsDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: fallbackSourceSet,
          preflightReport: report,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_DECISION: DONE',
      );

      if (!hlsDecision.canOpenPlayback ||
          hlsDecision.decision != 'playback_ready' ||
          hlsDecision.selectedKey != 'hls' ||
          hlsDecision.playbackOptions == null) {
        throw Exception(
          'Scenario 2 failed: HLS decision was not playback_ready (decision=${hlsDecision.decision}, key=${hlsDecision.selectedKey})',
        );
      }
      if (!hlsDecision.warnings.contains(
        'source_incompatible:dash:dash_not_supported',
      )) {
        throw Exception(
          'Scenario 2 failed: HLS decision missing dash_not_supported warning (${hlsDecision.warnings})',
        );
      }
      selectedKeys.add(hlsDecision.selectedKey!);
      allWarnings.addAll(hlsDecision.warnings);

      VGStreamingPlaybackController? hlsController;
      VGStreamingPlaybackStatusPoller? hlsPoller;
      VGStreamingPlaybackResilienceMonitor? hlsMonitor;
      VGStreamingPlaybackResilienceBinder? hlsBinder;
      StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? hlsMonitorSub;
      StreamSubscription<VGStreamingPlaybackResilienceCoordinatorEvaluation>?
      hlsBinderSub;
      final hlsCollectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
      final hlsCollectedEvaluations =
          <VGStreamingPlaybackResilienceCoordinatorEvaluation>[];

      bool hlsBinderDisposedMonitorAlive = false;
      bool hlsBinderDisposedPollerAlive = false;
      bool hlsBinderDisposedControllerAlive = false;
      bool hlsMonitorDisposedPollerAlive = false;
      bool hlsMonitorDisposedControllerAlive = false;
      bool hlsPollerDisposedControllerAlive = false;

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_OPEN: START');
        if (mounted) {
          setState(() {
            _status = 'Scenario 2: Opening HLS controller…';
          });
        }

        hlsController = VGStreamingPlaybackController();
        final openSnapshot = await hlsController.open(
          hlsDecision,
          startPlayback: true,
        );

        if (!openSnapshot.pass || openSnapshot.textureId == null) {
          throw Exception(
            'Scenario 2 failed: HLS controller open failed (${openSnapshot.reason}, ${openSnapshot.lastError})',
          );
        }

        if (mounted) {
          setState(() {
            _currentSnapshot = openSnapshot;
            _status =
                'Scenario 2: HLS controller active (textureId=${openSnapshot.textureId})';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_OPEN: DONE (textureId=${openSnapshot.textureId})',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_STATUS: START',
        );
        final deadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackControllerSnapshot? renderedSnapshot;

        while (DateTime.now().isBefore(deadline)) {
          final refreshed = await hlsController.refresh().timeout(
            _kControlTimeout,
          );
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
              refreshed.state !=
                  VGStreamingPlaybackControllerState.unsupported) {
            renderedSnapshot = refreshed;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (renderedSnapshot == null) {
          throw Exception(
            'Scenario 2 failed: HLS initial status wait timed out for rendered frames / dims',
          );
        }

        final hlsSession = renderedSnapshot.session!;
        hlsRenderedFrames = hlsSession.renderedFrames;
        hlsDisplayWidth = hlsSession.effectiveDisplayWidth;
        hlsDisplayHeight = hlsSession.effectiveDisplayHeight;

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_STATUS: DONE (renderedFrames=$hlsRenderedFrames, dims=${hlsDisplayWidth}x$hlsDisplayHeight)',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_BINDER_START: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Scenario 2: Instantiating and starting HLS poller, monitor, coordinator, and binder…';
          });
        }

        hlsPoller = VGStreamingPlaybackStatusPoller(
          controller: hlsController,
          config: VGStreamingPlaybackStatusPollerConfig(
            interval: const Duration(milliseconds: 300),
            emitInitialSummary: true,
          ),
        );

        hlsMonitor = VGStreamingPlaybackResilienceMonitor(
          summaries: hlsPoller.summaries,
          config: VGStreamingPlaybackResilienceMonitorConfig(
            currentOptions: hlsDecision.playbackOptions,
            preflightReport: report,
            currentNetworkProfile: VGStreamingNetworkProfile.constrained,
            maxHistoryLength: 8,
            allowAutomaticRetry: false,
          ),
        );

        final hlsCoordinator = VGStreamingPlaybackResilienceCoordinator(
          config: const VGStreamingPlaybackResilienceCoordinatorConfig(
            journalConfig: VGStreamingPlaybackRetryJournalConfig(
              maxStoredAttempts: 10,
            ),
            retryBudgetConfig: VGStreamingPlaybackRetryBudgetConfig(
              maxAttempts: 3,
              windowMs: 30000,
              minimumDelayMs: 1000,
            ),
            streamKey: 'hls',
          ),
        );

        int hlsNowMs = 1700000000000;
        int hlsDeterministicNow() {
          hlsNowMs += 500;
          return hlsNowMs;
        }

        hlsBinder = VGStreamingPlaybackResilienceBinder(
          snapshots: hlsMonitor.snapshots,
          coordinator: hlsCoordinator,
          config: const VGStreamingPlaybackResilienceBinderConfig(
            streamKey: 'hls',
          ),
          nowProvider: hlsDeterministicNow,
        );

        hlsMonitorSub = hlsMonitor.snapshots.listen((snapshot) {
          hlsCollectedSnapshots.add(snapshot);
        });

        hlsBinderSub = hlsBinder.evaluations.listen((evaluation) {
          hlsCollectedEvaluations.add(evaluation);
        });

        // Start binder twice and assert idempotent running state
        hlsBinder.start();
        if (!hlsBinder.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS binder isRunning is false after start()',
          );
        }
        hlsBinder.start();
        if (!hlsBinder.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS binder isRunning is false after second start()',
          );
        }

        hlsMonitor.start();
        hlsPoller.start();

        if (!hlsMonitor.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS monitor isRunning is false after start()',
          );
        }
        if (!hlsPoller.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS poller isRunning is false after start()',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_BINDER_START: DONE',
        );

        // Collect snapshots and binder evaluations
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_COLLECT: START',
        );
        final collectDeadline = DateTime.now().add(_kSnapshotCollectionTimeout);
        while (DateTime.now().isBefore(collectDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final latestSnap = hlsMonitor.latest;
          if (hlsCollectedSnapshots.length >= 2 &&
              hlsCollectedEvaluations.length >= 2 &&
              latestSnap != null &&
              latestSnap.status.hasSession &&
              latestSnap.status.effectiveDisplayWidth > 0 &&
              latestSnap.status.effectiveDisplayHeight > 0) {
            final progress =
                (hlsController.snapshot.session?.renderedFrames ?? 0) > 0 ||
                latestSnap.status.isPlaying ||
                latestSnap.status.positionMs > 0 ||
                latestSnap.status.bufferedPositionMs > 0;
            if (progress) {
              break;
            }
          }
        }

        if (hlsCollectedSnapshots.length < 2) {
          throw Exception(
            'Scenario 2 failed: expected >= 2 HLS snapshots, got ${hlsCollectedSnapshots.length}',
          );
        }
        if (hlsCollectedEvaluations.length < 2) {
          throw Exception(
            'Scenario 2 failed: expected >= 2 HLS binder evaluations, got ${hlsCollectedEvaluations.length}',
          );
        }

        final hlsLatestSnapshot = hlsMonitor.latest;
        if (hlsLatestSnapshot == null) {
          throw Exception('Scenario 2 failed: HLS monitor.latest is null');
        }

        for (final snap in hlsCollectedSnapshots) {
          _assertSnapshotInvariants(snap, scenarioName: 'HLS');
        }

        // Stop poller before count-sensitive lifecycle checks
        hlsPoller.stop();

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_COLLECT: DONE (snapshots=${hlsCollectedSnapshots.length}, evals=${hlsCollectedEvaluations.length})',
        );

        // Binder and coordinator invariant checks
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_BINDER_EVALUATE: START',
        );
        for (final eval in hlsCollectedEvaluations) {
          _assertBinderEvaluationInvariants(
            eval,
            hlsCoordinator,
            scenarioName: 'HLS',
            expectedStreamKey: 'hls',
          );
        }

        if (hlsCoordinator.length != 0 ||
            hlsCoordinator.journalSnapshot().count != 0) {
          throw Exception(
            'Scenario 2 failed: HLS coordinator length or journal was non-zero: '
            'length=${hlsCoordinator.length}, journalCount=${hlsCoordinator.journalSnapshot().count}',
          );
        }

        if (hlsBinder.latest == null) {
          throw Exception('Scenario 2 failed: HLS binder.latest is null');
        }
        final lastCollectedHlsEval = hlsCollectedEvaluations.last;
        if (hlsBinder.latest!.action != lastCollectedHlsEval.action ||
            hlsBinder.latest!.reasons.join(',') !=
                lastCollectedHlsEval.reasons.join(',')) {
          throw Exception(
            'Scenario 2 failed: HLS binder.latest does not match last collected evaluation',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_BINDER_EVALUATE: DONE (action=${hlsBinder.latest!.action.name}, length=${hlsCoordinator.length})',
        );

        // Binder Stop, evaluateOnce & Restart Lifecycle checks
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_LIFECYCLE_TEST: START',
        );

        hlsBinder.stop();
        if (hlsBinder.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS binder isRunning is true after stop()',
          );
        }
        if (hlsBinder.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS binder isDisposed is true after stop()',
          );
        }

        final hlsCountBeforeStoppedMonitorEval = hlsCollectedEvaluations.length;
        hlsMonitor.evaluateOnce(hlsLatestSnapshot.status);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (hlsCollectedEvaluations.length !=
            hlsCountBeforeStoppedMonitorEval) {
          throw Exception(
            'Scenario 2 failed: HLS binder evaluation count increased while stopped: '
            'before=$hlsCountBeforeStoppedMonitorEval, after=${hlsCollectedEvaluations.length}',
          );
        }

        // Call binder.evaluateOnce directly while stopped
        final manualHlsEval = hlsBinder.evaluateOnce(hlsLatestSnapshot);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!manualHlsEval.advisoryOnly || manualHlsEval.playbackMutation) {
          throw Exception(
            'Scenario 2 failed: HLS manual evaluateOnce violated advisory invariant',
          );
        }
        if (hlsCoordinator.length != 0 ||
            hlsCoordinator.journalSnapshot().count != 0) {
          throw Exception(
            'Scenario 2 failed: HLS coordinator journal modified during manual evaluateOnce',
          );
        }
        if (hlsBinder.latest != manualHlsEval) {
          throw Exception(
            'Scenario 2 failed: HLS binder.latest not updated by manual evaluateOnce',
          );
        }
        if (hlsCollectedEvaluations.length !=
            hlsCountBeforeStoppedMonitorEval + 1) {
          throw Exception(
            'Scenario 2 failed: expected 1 manual evaluation emitted onto stream, but count is ${hlsCollectedEvaluations.length}',
          );
        }

        // Restart binder and verify resumed listening
        hlsBinder.start();
        if (!hlsBinder.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS binder restart failed (isRunning is false)',
          );
        }
        final hlsCountBeforeRestartedMonitorEval =
            hlsCollectedEvaluations.length;
        hlsMonitor.evaluateOnce(hlsLatestSnapshot.status);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (hlsCollectedEvaluations.length !=
            hlsCountBeforeRestartedMonitorEval + 1) {
          throw Exception(
            'Scenario 2 failed: expected exactly 1 additional evaluation after monitor evaluateOnce on restarted binder, '
            'before=$hlsCountBeforeRestartedMonitorEval, after=${hlsCollectedEvaluations.length}',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_LIFECYCLE_TEST: DONE',
        );

        // Binder Dispose
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_BINDER_DISPOSE: START',
        );
        hlsBinder.dispose();
        if (!hlsBinder.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS binder isDisposed is false after dispose()',
          );
        }
        if (hlsBinder.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS binder isRunning is true after dispose()',
          );
        }

        hlsBinderDisposedMonitorAlive = !hlsMonitor.isDisposed;
        hlsBinderDisposedPollerAlive = !hlsPoller.isDisposed;
        hlsBinderDisposedControllerAlive = !hlsController.isDisposed;

        if (!hlsBinderDisposedMonitorAlive) {
          throw Exception(
            'Scenario 2 failed: HLS binder disposal improperly disposed underlying monitor',
          );
        }
        if (!hlsBinderDisposedPollerAlive) {
          throw Exception(
            'Scenario 2 failed: HLS binder disposal improperly disposed underlying poller',
          );
        }
        if (!hlsBinderDisposedControllerAlive) {
          throw Exception(
            'Scenario 2 failed: HLS binder disposal improperly disposed underlying controller',
          );
        }

        // Calling start() after dispose must be a no-op
        hlsBinder.start();
        if (hlsBinder.isRunning) {
          throw Exception(
            'Scenario 2 failed: calling start() after dispose unexpectedly set isRunning to true',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_BINDER_DISPOSE: DONE',
        );

        // Monitor Dispose
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_MONITOR_DISPOSE: START',
        );
        hlsMonitor.stop();
        if (hlsMonitor.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS monitor stop failed: isRunning is still true',
          );
        }
        await hlsMonitorSub.cancel();
        hlsMonitorSub = null;

        await hlsMonitor.dispose();
        if (!hlsMonitor.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS monitor isDisposed is false after dispose()',
          );
        }
        hlsMonitorDisposedPollerAlive = !hlsPoller.isDisposed;
        hlsMonitorDisposedControllerAlive = !hlsController.isDisposed;
        if (!hlsMonitorDisposedPollerAlive) {
          throw Exception(
            'Scenario 2 failed: HLS monitor disposal improperly disposed underlying poller',
          );
        }
        if (!hlsMonitorDisposedControllerAlive) {
          throw Exception(
            'Scenario 2 failed: HLS monitor disposal improperly disposed underlying controller',
          );
        }

        // Safe evaluateOnce on disposed monitor
        final postDisposeHlsSnapshot = hlsMonitor.evaluateOnce(
          hlsLatestSnapshot.status,
        );
        _assertSnapshotInvariants(
          postDisposeHlsSnapshot,
          scenarioName: 'HLS post-dispose',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_MONITOR_DISPOSE: DONE',
        );

        // Poller Dispose
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_POLLER_DISPOSE: START',
        );
        await hlsPoller.dispose();
        if (!hlsPoller.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS poller isDisposed is false after dispose()',
          );
        }
        hlsPollerDisposedControllerAlive = !hlsController.isDisposed;
        if (!hlsPollerDisposedControllerAlive) {
          throw Exception(
            'Scenario 2 failed: HLS poller disposal improperly disposed underlying controller',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_POLLER_DISPOSE: DONE',
        );

        // Controller Dispose
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_CONTROLLER_DISPOSE: START',
        );
        await hlsController.stop();
        await hlsController.dispose();
        if (!hlsController.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS controller isDisposed is false after dispose()',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_HLS_CONTROLLER_DISPOSE: DONE',
        );

        hlsResilienceBinderPass = true;
        results['hlsResilienceBinderPass'] = true;
        results['hlsResilienceBinder'] = <String, dynamic>{
          'pass': true,
          'selectedKey': hlsDecision.selectedKey,
          'textureId': openSnapshot.textureId,
          'renderedFrames': hlsRenderedFrames,
          'effectiveDisplayWidth': hlsDisplayWidth,
          'effectiveDisplayHeight': hlsDisplayHeight,
          'snapshotsCount': hlsCollectedSnapshots.length,
          'evaluationsCount': hlsCollectedEvaluations.length,
          'latestSnapshot': hlsLatestSnapshot.toJson(),
          'latestHealthAdvice': hlsLatestSnapshot.healthAdvice.toJson(),
          'latestRecoveryPlan': hlsLatestSnapshot.recoveryPlan.toJson(),
          'latestStatus': hlsLatestSnapshot.status.toJson(),
          'latestBinderEvaluation': hlsBinder.latest!.toJson(),
          'coordinatorLengthAfterEvaluate': hlsCoordinator.length,
          'binderDisposedMonitorAlive': hlsBinderDisposedMonitorAlive,
          'binderDisposedPollerAlive': hlsBinderDisposedPollerAlive,
          'binderDisposedControllerAlive': hlsBinderDisposedControllerAlive,
          'monitorDisposedPollerAlive': hlsMonitorDisposedPollerAlive,
          'monitorDisposedControllerAlive': hlsMonitorDisposedControllerAlive,
          'pollerDisposedControllerAlive': hlsPollerDisposedControllerAlive,
        };
      } finally {
        await hlsMonitorSub?.cancel();
        await hlsBinderSub?.cancel();
        hlsBinder?.dispose();
        if (hlsMonitor != null && !hlsMonitor.isDisposed) {
          await hlsMonitor.dispose();
        }
        if (hlsPoller != null && !hlsPoller.isDisposed) {
          await hlsPoller.dispose();
        }
        if (hlsController != null && !hlsController.isDisposed) {
          await hlsController.stop();
          await hlsController.dispose();
        }
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 3: LL-HLS decision -> controller -> status poller -> resilience monitor -> coordinator -> binder
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_DECISION: START',
      );
      if (mounted) {
        setState(() {
          _status = 'Scenario 3: Planning LL-HLS selection decision…';
        });
      }

      final llHlsDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: compatibleSourceSet,
          preflightReport: report,
          preferredKeys: const ['ll_hls'],
          preference: VGStreamingSourceSelectionPreference.preferLowLatency,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(
                preferLowLatency: true,
              ),
        ),
      );

      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_DECISION: DONE',
      );

      if (!llHlsDecision.canOpenPlayback ||
          llHlsDecision.decision != 'playback_ready' ||
          llHlsDecision.selectedKey != 'll_hls' ||
          llHlsDecision.playbackOptions == null) {
        throw Exception(
          'Scenario 3 failed: LL-HLS decision was not playback_ready (decision=${llHlsDecision.decision}, key=${llHlsDecision.selectedKey})',
        );
      }
      if (llHlsDecision.selectedSource?.requireLlHlsTags != true) {
        throw Exception(
          'Scenario 3 failed: LL-HLS selectedSource requireLlHlsTags is not true',
        );
      }
      selectedKeys.add(llHlsDecision.selectedKey!);
      allWarnings.addAll(llHlsDecision.warnings);

      VGStreamingPlaybackController? llHlsController;
      VGStreamingPlaybackStatusPoller? llHlsPoller;
      VGStreamingPlaybackResilienceMonitor? llHlsMonitor;
      VGStreamingPlaybackResilienceBinder? llHlsBinder;
      StreamSubscription<VGStreamingPlaybackResilienceSnapshot>?
      llHlsMonitorSub;
      StreamSubscription<VGStreamingPlaybackResilienceCoordinatorEvaluation>?
      llHlsBinderSub;
      final llHlsCollectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
      final llHlsCollectedEvaluations =
          <VGStreamingPlaybackResilienceCoordinatorEvaluation>[];

      bool llHlsBinderDisposedMonitorAlive = false;
      bool llHlsBinderDisposedPollerAlive = false;
      bool llHlsBinderDisposedControllerAlive = false;
      bool llHlsMonitorDisposedPollerAlive = false;
      bool llHlsMonitorDisposedControllerAlive = false;
      bool llHlsPollerDisposedControllerAlive = false;

      try {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_OPEN: START',
        );
        if (mounted) {
          setState(() {
            _status = 'Scenario 3: Opening LL-HLS controller…';
          });
        }

        llHlsController = VGStreamingPlaybackController();
        final openSnapshot = await llHlsController.open(
          llHlsDecision,
          startPlayback: true,
        );

        if (!openSnapshot.pass || openSnapshot.textureId == null) {
          throw Exception(
            'Scenario 3 failed: LL-HLS controller open failed (${openSnapshot.reason}, ${openSnapshot.lastError})',
          );
        }

        if (mounted) {
          setState(() {
            _currentSnapshot = openSnapshot;
            _status =
                'Scenario 3: LL-HLS controller active (textureId=${openSnapshot.textureId})';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_OPEN: DONE (textureId=${openSnapshot.textureId})',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_STATUS: START',
        );
        final deadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackControllerSnapshot? renderedSnapshot;

        while (DateTime.now().isBefore(deadline)) {
          final refreshed = await llHlsController.refresh().timeout(
            _kControlTimeout,
          );
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
              refreshed.state !=
                  VGStreamingPlaybackControllerState.unsupported) {
            renderedSnapshot = refreshed;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (renderedSnapshot == null) {
          throw Exception(
            'Scenario 3 failed: LL-HLS initial status wait timed out for rendered frames / dims',
          );
        }

        final llHlsSession = renderedSnapshot.session!;
        llHlsRenderedFrames = llHlsSession.renderedFrames;
        llHlsDisplayWidth = llHlsSession.effectiveDisplayWidth;
        llHlsDisplayHeight = llHlsSession.effectiveDisplayHeight;

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_STATUS: DONE (renderedFrames=$llHlsRenderedFrames, dims=${llHlsDisplayWidth}x$llHlsDisplayHeight)',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_BINDER_START: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Scenario 3: Instantiating and starting LL-HLS poller, monitor, coordinator, and binder…';
          });
        }

        llHlsPoller = VGStreamingPlaybackStatusPoller(
          controller: llHlsController,
          config: VGStreamingPlaybackStatusPollerConfig(
            interval: const Duration(milliseconds: 300),
            emitInitialSummary: true,
          ),
        );

        llHlsMonitor = VGStreamingPlaybackResilienceMonitor(
          summaries: llHlsPoller.summaries,
          config: VGStreamingPlaybackResilienceMonitorConfig(
            currentOptions: llHlsDecision.playbackOptions,
            preflightReport: report,
            currentNetworkProfile: VGStreamingNetworkProfile.constrained,
            maxHistoryLength: 8,
            allowAutomaticRetry: false,
          ),
        );

        final llHlsCoordinator = VGStreamingPlaybackResilienceCoordinator(
          config: const VGStreamingPlaybackResilienceCoordinatorConfig(
            journalConfig: VGStreamingPlaybackRetryJournalConfig(
              maxStoredAttempts: 10,
            ),
            retryBudgetConfig: VGStreamingPlaybackRetryBudgetConfig(
              maxAttempts: 3,
              windowMs: 30000,
              minimumDelayMs: 1000,
            ),
            streamKey: 'll_hls',
          ),
        );

        int llHlsNowMs = 1700000000000;
        int llHlsDeterministicNow() {
          llHlsNowMs += 500;
          return llHlsNowMs;
        }

        llHlsBinder = VGStreamingPlaybackResilienceBinder(
          snapshots: llHlsMonitor.snapshots,
          coordinator: llHlsCoordinator,
          config: const VGStreamingPlaybackResilienceBinderConfig(
            streamKey: 'll_hls',
          ),
          nowProvider: llHlsDeterministicNow,
        );

        llHlsMonitorSub = llHlsMonitor.snapshots.listen((snapshot) {
          llHlsCollectedSnapshots.add(snapshot);
        });

        llHlsBinderSub = llHlsBinder.evaluations.listen((evaluation) {
          llHlsCollectedEvaluations.add(evaluation);
        });

        // Start binder twice and assert idempotent running state
        llHlsBinder.start();
        if (!llHlsBinder.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder isRunning is false after start()',
          );
        }
        llHlsBinder.start();
        if (!llHlsBinder.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder isRunning is false after second start()',
          );
        }

        llHlsMonitor.start();
        llHlsPoller.start();

        if (!llHlsMonitor.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor isRunning is false after start()',
          );
        }
        if (!llHlsPoller.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller isRunning is false after start()',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_BINDER_START: DONE',
        );

        // Collect snapshots and binder evaluations
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_COLLECT: START',
        );
        final collectDeadline = DateTime.now().add(_kSnapshotCollectionTimeout);
        while (DateTime.now().isBefore(collectDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final latestSnap = llHlsMonitor.latest;
          if (llHlsCollectedSnapshots.length >= 2 &&
              llHlsCollectedEvaluations.length >= 2 &&
              latestSnap != null &&
              latestSnap.status.hasSession &&
              latestSnap.status.effectiveDisplayWidth > 0 &&
              latestSnap.status.effectiveDisplayHeight > 0) {
            final progress =
                (llHlsController.snapshot.session?.renderedFrames ?? 0) > 0 ||
                latestSnap.status.isPlaying ||
                latestSnap.status.positionMs > 0 ||
                latestSnap.status.bufferedPositionMs > 0;
            if (progress) {
              break;
            }
          }
        }

        if (llHlsCollectedSnapshots.length < 2) {
          throw Exception(
            'Scenario 3 failed: expected >= 2 LL-HLS snapshots, got ${llHlsCollectedSnapshots.length}',
          );
        }
        if (llHlsCollectedEvaluations.length < 2) {
          throw Exception(
            'Scenario 3 failed: expected >= 2 LL-HLS binder evaluations, got ${llHlsCollectedEvaluations.length}',
          );
        }

        final llHlsLatestSnapshot = llHlsMonitor.latest;
        if (llHlsLatestSnapshot == null) {
          throw Exception('Scenario 3 failed: LL-HLS monitor.latest is null');
        }

        for (final snap in llHlsCollectedSnapshots) {
          _assertSnapshotInvariants(snap, scenarioName: 'LL-HLS');
        }

        // Stop poller before count-sensitive lifecycle checks
        llHlsPoller.stop();

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_COLLECT: DONE (snapshots=${llHlsCollectedSnapshots.length}, evals=${llHlsCollectedEvaluations.length})',
        );

        // Binder and coordinator invariant checks
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_BINDER_EVALUATE: START',
        );
        for (final eval in llHlsCollectedEvaluations) {
          _assertBinderEvaluationInvariants(
            eval,
            llHlsCoordinator,
            scenarioName: 'LL-HLS',
            expectedStreamKey: 'll_hls',
          );
        }

        if (llHlsCoordinator.length != 0 ||
            llHlsCoordinator.journalSnapshot().count != 0) {
          throw Exception(
            'Scenario 3 failed: LL-HLS coordinator length or journal was non-zero: '
            'length=${llHlsCoordinator.length}, journalCount=${llHlsCoordinator.journalSnapshot().count}',
          );
        }

        if (llHlsBinder.latest == null) {
          throw Exception('Scenario 3 failed: LL-HLS binder.latest is null');
        }
        final lastCollectedLlHlsEval = llHlsCollectedEvaluations.last;
        if (llHlsBinder.latest!.action != lastCollectedLlHlsEval.action ||
            llHlsBinder.latest!.reasons.join(',') !=
                lastCollectedLlHlsEval.reasons.join(',')) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder.latest does not match last collected evaluation',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_BINDER_EVALUATE: DONE (action=${llHlsBinder.latest!.action.name}, length=${llHlsCoordinator.length})',
        );

        // Binder Stop, evaluateOnce & Restart Lifecycle checks
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_LIFECYCLE_TEST: START',
        );

        llHlsBinder.stop();
        if (llHlsBinder.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder isRunning is true after stop()',
          );
        }
        if (llHlsBinder.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder isDisposed is true after stop()',
          );
        }

        final llHlsCountBeforeStoppedMonitorEval =
            llHlsCollectedEvaluations.length;
        llHlsMonitor.evaluateOnce(llHlsLatestSnapshot.status);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (llHlsCollectedEvaluations.length !=
            llHlsCountBeforeStoppedMonitorEval) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder evaluation count increased while stopped: '
            'before=$llHlsCountBeforeStoppedMonitorEval, after=${llHlsCollectedEvaluations.length}',
          );
        }

        // Call binder.evaluateOnce directly while stopped
        final manualLlHlsEval = llHlsBinder.evaluateOnce(llHlsLatestSnapshot);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!manualLlHlsEval.advisoryOnly || manualLlHlsEval.playbackMutation) {
          throw Exception(
            'Scenario 3 failed: LL-HLS manual evaluateOnce violated advisory invariant',
          );
        }
        if (llHlsCoordinator.length != 0 ||
            llHlsCoordinator.journalSnapshot().count != 0) {
          throw Exception(
            'Scenario 3 failed: LL-HLS coordinator journal modified during manual evaluateOnce',
          );
        }
        if (llHlsBinder.latest != manualLlHlsEval) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder.latest not updated by manual evaluateOnce',
          );
        }
        if (llHlsCollectedEvaluations.length !=
            llHlsCountBeforeStoppedMonitorEval + 1) {
          throw Exception(
            'Scenario 3 failed: expected 1 manual evaluation emitted onto stream, but count is ${llHlsCollectedEvaluations.length}',
          );
        }

        // Restart binder and verify resumed listening
        llHlsBinder.start();
        if (!llHlsBinder.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder restart failed (isRunning is false)',
          );
        }
        final llHlsCountBeforeRestartedMonitorEval =
            llHlsCollectedEvaluations.length;
        llHlsMonitor.evaluateOnce(llHlsLatestSnapshot.status);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (llHlsCollectedEvaluations.length !=
            llHlsCountBeforeRestartedMonitorEval + 1) {
          throw Exception(
            'Scenario 3 failed: expected exactly 1 additional evaluation after monitor evaluateOnce on restarted binder, '
            'before=$llHlsCountBeforeRestartedMonitorEval, after=${llHlsCollectedEvaluations.length}',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_LIFECYCLE_TEST: DONE',
        );

        // Binder Dispose
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_BINDER_DISPOSE: START',
        );
        llHlsBinder.dispose();
        if (!llHlsBinder.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder isDisposed is false after dispose()',
          );
        }
        if (llHlsBinder.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder isRunning is true after dispose()',
          );
        }

        llHlsBinderDisposedMonitorAlive = !llHlsMonitor.isDisposed;
        llHlsBinderDisposedPollerAlive = !llHlsPoller.isDisposed;
        llHlsBinderDisposedControllerAlive = !llHlsController.isDisposed;

        if (!llHlsBinderDisposedMonitorAlive) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder disposal improperly disposed underlying monitor',
          );
        }
        if (!llHlsBinderDisposedPollerAlive) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder disposal improperly disposed underlying poller',
          );
        }
        if (!llHlsBinderDisposedControllerAlive) {
          throw Exception(
            'Scenario 3 failed: LL-HLS binder disposal improperly disposed underlying controller',
          );
        }

        // Calling start() after dispose must be a no-op
        llHlsBinder.start();
        if (llHlsBinder.isRunning) {
          throw Exception(
            'Scenario 3 failed: calling start() after dispose unexpectedly set isRunning to true',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_BINDER_DISPOSE: DONE',
        );

        // Monitor Dispose
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_MONITOR_DISPOSE: START',
        );
        llHlsMonitor.stop();
        if (llHlsMonitor.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor stop failed: isRunning is still true',
          );
        }
        await llHlsMonitorSub.cancel();
        llHlsMonitorSub = null;

        await llHlsMonitor.dispose();
        if (!llHlsMonitor.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor isDisposed is false after dispose()',
          );
        }
        llHlsMonitorDisposedPollerAlive = !llHlsPoller.isDisposed;
        llHlsMonitorDisposedControllerAlive = !llHlsController.isDisposed;
        if (!llHlsMonitorDisposedPollerAlive) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor disposal improperly disposed underlying poller',
          );
        }
        if (!llHlsMonitorDisposedControllerAlive) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor disposal improperly disposed underlying controller',
          );
        }

        // Safe evaluateOnce on disposed monitor
        final postDisposeLlHlsSnapshot = llHlsMonitor.evaluateOnce(
          llHlsLatestSnapshot.status,
        );
        _assertSnapshotInvariants(
          postDisposeLlHlsSnapshot,
          scenarioName: 'LL-HLS post-dispose',
        );

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_MONITOR_DISPOSE: DONE',
        );

        // Poller Dispose
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_POLLER_DISPOSE: START',
        );
        await llHlsPoller.dispose();
        if (!llHlsPoller.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller isDisposed is false after dispose()',
          );
        }
        llHlsPollerDisposedControllerAlive = !llHlsController.isDisposed;
        if (!llHlsPollerDisposedControllerAlive) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller disposal improperly disposed underlying controller',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_POLLER_DISPOSE: DONE',
        );

        // Controller Dispose
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_CONTROLLER_DISPOSE: START',
        );
        await llHlsController.stop();
        await llHlsController.dispose();
        if (!llHlsController.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS controller isDisposed is false after dispose()',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_LL_HLS_CONTROLLER_DISPOSE: DONE',
        );

        llHlsResilienceBinderPass = true;
        results['llHlsResilienceBinderPass'] = true;
        results['llHlsResilienceBinder'] = <String, dynamic>{
          'pass': true,
          'selectedKey': llHlsDecision.selectedKey,
          'textureId': openSnapshot.textureId,
          'renderedFrames': llHlsRenderedFrames,
          'effectiveDisplayWidth': llHlsDisplayWidth,
          'effectiveDisplayHeight': llHlsDisplayHeight,
          'snapshotsCount': llHlsCollectedSnapshots.length,
          'evaluationsCount': llHlsCollectedEvaluations.length,
          'latestSnapshot': llHlsLatestSnapshot.toJson(),
          'latestHealthAdvice': llHlsLatestSnapshot.healthAdvice.toJson(),
          'latestRecoveryPlan': llHlsLatestSnapshot.recoveryPlan.toJson(),
          'latestStatus': llHlsLatestSnapshot.status.toJson(),
          'latestBinderEvaluation': llHlsBinder.latest!.toJson(),
          'coordinatorLengthAfterEvaluate': llHlsCoordinator.length,
          'binderDisposedMonitorAlive': llHlsBinderDisposedMonitorAlive,
          'binderDisposedPollerAlive': llHlsBinderDisposedPollerAlive,
          'binderDisposedControllerAlive': llHlsBinderDisposedControllerAlive,
          'monitorDisposedPollerAlive': llHlsMonitorDisposedPollerAlive,
          'monitorDisposedControllerAlive': llHlsMonitorDisposedControllerAlive,
          'pollerDisposedControllerAlive': llHlsPollerDisposedControllerAlive,
        };
      } finally {
        await llHlsMonitorSub?.cancel();
        await llHlsBinderSub?.cancel();
        llHlsBinder?.dispose();
        if (llHlsMonitor != null && !llHlsMonitor.isDisposed) {
          await llHlsMonitor.dispose();
        }
        if (llHlsPoller != null && !llHlsPoller.isDisposed) {
          await llHlsPoller.dispose();
        }
        if (llHlsController != null && !llHlsController.isDisposed) {
          await llHlsController.stop();
          await llHlsController.dispose();
        }
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 4: DASH typed deferral
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_DASH_DEFERRAL: START',
      );
      if (mounted) {
        setState(() {
          _status = 'Scenario 4: Validating native DASH typed deferral…';
        });
      }

      final dashSourceSet = VGStreamingSourceSet(sources: [dashDescriptor]);
      final dashPreflightRequest = dashSourceSet.toPreflightRequest(
        requestedNetworkProfile: VGStreamingNetworkProfile.auto,
      );

      final dashReport = await _preflightClient
          .evaluate(dashPreflightRequest)
          .timeout(_kPreflightTimeout);

      if (dashReport.pass) {
        throw Exception(
          'Scenario 4 failed: dashReport.pass was true on iOS (expected typed failure)',
        );
      }
      if (dashReport.failedReports < 1) {
        throw Exception(
          'Scenario 4 failed: dashReport.failedReports was ${dashReport.failedReports} (expected >= 1)',
        );
      }
      if (!dashReport.warnings.contains('unsupported_format_dash')) {
        throw Exception(
          'Scenario 4 failed: dashReport.warnings missing unsupported_format_dash (${dashReport.warnings})',
        );
      }
      if (!dashReport.advisoryOnly) {
        throw Exception(
          'Scenario 4 failed: dashReport.advisoryOnly was not true',
        );
      }
      if (dashReport.playbackMutation) {
        throw Exception(
          'Scenario 4 failed: dashReport.playbackMutation was true',
        );
      }

      final dashStartupPlan = VGStreamingStartupPlanner.fromPreflight(
        dashReport,
      );
      if (dashStartupPlan.shouldProceed) {
        throw Exception(
          'Scenario 4 failed: dashStartupPlan.shouldProceed was true (expected false)',
        );
      }

      final dashDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: dashSourceSet,
          preflightReport: dashReport,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      if (dashDecision.canOpenPlayback) {
        throw Exception(
          'Scenario 4 failed: dashDecision.canOpenPlayback was true on DASH-only set',
        );
      }
      if (dashDecision.decision != 'startup_plan_blocked') {
        throw Exception(
          'Scenario 4 failed: dashDecision.decision was "${dashDecision.decision}" (expected "startup_plan_blocked")',
        );
      }
      if (dashDecision.playbackOptions != null) {
        throw Exception(
          'Scenario 4 failed: dashDecision.playbackOptions was non-null',
        );
      }

      dashTypedDeferralPass = true;
      results['dashTypedDeferralPass'] = true;
      results['dashTypedDeferral'] = <String, dynamic>{
        'pass': true,
        'reportPass': dashReport.pass,
        'failedReports': dashReport.failedReports,
        'warnings': dashReport.warnings,
        'advisoryOnly': dashReport.advisoryOnly,
        'playbackMutation': dashReport.playbackMutation,
        'startupPlanShouldProceed': dashStartupPlan.shouldProceed,
        'startupPlanReason': dashStartupPlan.reason,
        'canOpenPlayback': dashDecision.canOpenPlayback,
        'decision': dashDecision.decision,
        'playbackOptions': dashDecision.playbackOptions,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_STEP_DASH_DEFERRAL: DONE',
      );

      allPass =
          sourceSetPreflightPass &&
          hlsResilienceBinderPass &&
          llHlsResilienceBinderPass &&
          dashTypedDeferralPass;

      results['pass'] = allPass;
      results['advisoryOnlyVerified'] = true;
      results['playbackMutationZeroVerified'] = true;
      results['selectedKeys'] = selectedKeys;
      results['allWarnings'] = allWarnings;
    } catch (e, stack) {
      results['pass'] = false;
      results['error'] = e.toString();
      results['stack'] = stack.toString();
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_ERROR: $e\n$stack');
    }

    final jsonPayload = jsonEncode(results);
    // ignore: avoid_print
    print(
      'IOS_STREAMING_PREFLIGHT_RESILIENCE_BINDER_PUBLIC_API_PHYSICAL_JSON:$jsonPayload',
    );

    if (allPass) {
      // ignore: avoid_print
      print(_kPassMarker);
      if (mounted) {
        setState(() {
          _status = 'Physical smoke test passed successfully!';
        });
      }
      exit(0);
    } else {
      // ignore: avoid_print
      print(_kFailMarker);
      if (mounted) {
        setState(() {
          _status = 'Physical smoke test failed!';
        });
      }
      exit(1);
    }
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
