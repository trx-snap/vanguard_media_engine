// Copyright (c) Connects — Vanguard Phase 4C8R.
// iOS Public streaming native preflight resilience monitor all-up physical smoke.
//
// Route:
//   VGStreamingSourceSet ->
//   VGStreamingPreflightClient.evaluate(...) [actual native iOS preflight] ->
//   VGStreamingStartupPlanner.fromPreflight(...) ->
//   VGStreamingPlaybackDecisionPlanner.plan(...) [capability-filtered decision] ->
//   VGStreamingPlaybackController.open/refresh/stop/dispose ->
//   VGStreamingPlaybackTextureView presentation ->
//   VGStreamingPlaybackStatusPoller [Stream<VGStreamingPlaybackStatusSummary>] ->
//   VGStreamingPlaybackResilienceMonitor [Stream<VGStreamingPlaybackResilienceSnapshot>]
//
// Scenarios:
//   1. Compatible native source-set preflight:
//      - Build VGStreamingSourceSet with [hls, ll_hls].
//      - sourceSet.toPreflightRequest(preferLowLatency: true, requestedNetworkProfile: auto).
//      - Evaluate via VGStreamingPreflightClient.evaluate.
//      - Assert report.pass == true, advisoryOnly == true, playbackMutation == false,
//        totalReports == 2, failedReports == 0, phase contains Phase4C8C, llHlsAvailable == true.
//      - Build VGStreamingStartupPlanner.fromPreflight(report); assert shouldProceed == true.
//   2. HLS fallback decision -> controller -> status poller -> resilience monitor:
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
//        currentOptions: decision.playbackOptions, currentNetworkProfile: constrained, maxHistoryLength: 8).
//      - Subscribe to monitor.snapshots, start monitor then poller, assert both isRunning == true.
//      - Collect >= 2 snapshots; assert snapshot/health/recovery/status invariants.
//      - Stop/dispose monitor, verify poller and controller remain alive, assert evaluateOnce post-dispose.
//      - Stop/dispose poller, verify controller remains alive, stop/dispose controller in finally.
//   3. LL-HLS decision -> controller -> status poller -> resilience monitor:
//      - Use compatible source set [hls, ll_hls] and report from scenario 1.
//      - Plan with preferredKeys: ['ll_hls'], preference: preferLowLatency,
//        clientCapabilities: appleAvPlayer(preferLowLatency: true).
//      - Assert decision.canOpenPlayback == true, selectedKey == 'll_hls',
//        selectedSource.requireLlHlsTags == true.
//      - Open fresh controller, poll positive rendered frames/dimensions, attach poller + resilience monitor,
//        collect >= 2 snapshots, assert invariants, verify monitor stop/dispose and safe evaluateOnce,
//        poller stop/dispose, and controller stop/dispose in finally.
//   4. DASH typed deferral:
//      - Run actual DASH-only native preflight via dashSourceSet.toPreflightRequest(requestedNetworkProfile: auto).
//      - Assert report.pass == false, failedReports >= 1, warnings contains 'unsupported_format_dash',
//        advisoryOnly == true, playbackMutation == false, startup plan shouldProceed == false.
//      - Plan dash-only decision with VGStreamingPlaybackDecisionPlanner.plan,
//        preference preferDash, clientCapabilities appleAvPlayer();
//        assert canOpenPlayback == false, decision == 'startup_plan_blocked', playbackOptions == null.
//      - Zero playback mutation / never open playback controller, poller, or monitor for DASH.
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
// - Typed DASH deferral without attempting playback, poller, or monitor instantiation.
// - All controllers, pollers, monitors, and stream subscriptions cleaned up in finally blocks.
// - Emits structured step markers and terminal JSON payload.
// - Exit 0 on pass, exit 1 on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kPhase = 'Phase4C8R';
const String _kTarget = 'ios_physical';
const String _kPassMarker =
    'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_PASS';
const String _kFailMarker =
    'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_FAIL';

const String _kHlsUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const String _kLlHlsUrl =
    'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8';
const String _kDashUrl =
    'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd';

const int _initialWidth = 640;
const int _initialHeight = 360;
const Duration _kPreflightTimeout = Duration(seconds: 25);
const Duration _kOperationTimeout = Duration(seconds: 20);
const Duration _kControlTimeout = Duration(seconds: 8);
const Duration _kPollInterval = Duration(milliseconds: 300);
const Duration _kStatusDeadline = Duration(seconds: 20);
const Duration _kSnapshotCollectionTimeout = Duration(seconds: 15);

void main() {
  runApp(
    const IosStreamingPreflightResilienceMonitorPublicApiPhysicalSmokeApp(),
  );
}

class IosStreamingPreflightResilienceMonitorPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingPreflightResilienceMonitorPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<IosStreamingPreflightResilienceMonitorPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingPreflightResilienceMonitorPublicApiPhysicalSmokeAppState();
}

class _IosStreamingPreflightResilienceMonitorPublicApiPhysicalSmokeAppState
    extends
        State<IosStreamingPreflightResilienceMonitorPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Bootstrapping iOS streaming preflight resilience monitor smoke...';
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
    print('IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_BOOTSTRAP_ERROR: $error\n$stack',
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
    bool hlsResilienceMonitorPass = false;
    bool llHlsResilienceMonitorPass = false;
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
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_SOURCE_SET_PREFLIGHT: START',
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
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_SOURCE_SET_PREFLIGHT: DONE',
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
      // Scenario 2: HLS Fallback decision -> controller -> status poller -> resilience monitor
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_DECISION: START',
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
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_DECISION: DONE',
      );

      if (!hlsDecision.canOpenPlayback ||
          hlsDecision.decision != 'playback_ready' ||
          hlsDecision.selectedKey != 'hls' ||
          hlsDecision.playbackOptions == null ||
          hlsDecision.playbackOptions?.formatHint !=
              VGStreamingFormatHint.hls ||
          !hlsDecision.warnings.contains(
            'source_incompatible:dash:dash_not_supported',
          )) {
        throw Exception(
          'Scenario 2 failed: HLS decision assertion failed: '
          'canOpenPlayback=${hlsDecision.canOpenPlayback}, decision=${hlsDecision.decision}, '
          'selectedKey=${hlsDecision.selectedKey}, formatHint=${hlsDecision.playbackOptions?.formatHint}, '
          'warnings=${hlsDecision.warnings}',
        );
      }

      selectedKeys.add(hlsDecision.selectedKey!);
      allWarnings.addAll(hlsDecision.warnings);

      // Create fresh controller, poller, & monitor variables for Scenario 2
      final hlsController = VGStreamingPlaybackController();
      VGStreamingPlaybackStatusPoller? hlsPoller;
      VGStreamingPlaybackResilienceMonitor? hlsMonitor;
      StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? hlsMonitorSub;
      final hlsCollectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];

      try {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_OPEN: START',
        );
        if (mounted) {
          setState(() {
            _status = 'Scenario 2: Opening selected HLS playback controller…';
          });
        }

        final hlsOpenSnapshot = await hlsController
            .open(hlsDecision, startPlayback: true)
            .timeout(_kOperationTimeout);

        if (!hlsOpenSnapshot.pass || hlsOpenSnapshot.textureId == null) {
          throw Exception(
            'Scenario 2 failed: HLS controller open failed: pass=${hlsOpenSnapshot.pass}, '
            'reason=${hlsOpenSnapshot.reason}, lastError=${hlsOpenSnapshot.lastError}, '
            'textureId=${hlsOpenSnapshot.textureId}',
          );
        }

        if (mounted) {
          setState(() {
            _currentSnapshot = hlsOpenSnapshot;
            _status =
                'Scenario 2: HLS streaming active (textureId=${hlsOpenSnapshot.textureId})…';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_OPEN: DONE (textureId=${hlsOpenSnapshot.textureId})',
        );

        // Poll controller.refresh() until renderedFrames > 0 and effectiveDisplayWidth/Height > 0
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_STATUS: START',
        );
        final hlsDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackControllerSnapshot? finalHlsSnapshot;

        while (DateTime.now().isBefore(hlsDeadline)) {
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
            finalHlsSnapshot = refreshed;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (finalHlsSnapshot == null) {
          final lastRefreshed = await hlsController.refresh().timeout(
            _kControlTimeout,
          );
          throw Exception(
            'Scenario 2 failed: HLS status verification timed out: renderedFrames=${lastRefreshed.session?.renderedFrames}, '
            'state=${lastRefreshed.state.name}, dims=${lastRefreshed.session?.effectiveDisplayWidth}x${lastRefreshed.session?.effectiveDisplayHeight}, '
            'raw=${lastRefreshed.session?.raw}',
          );
        }

        final hlsSession = finalHlsSnapshot.session!;
        hlsRenderedFrames = hlsSession.renderedFrames;
        hlsDisplayWidth = hlsSession.effectiveDisplayWidth;
        hlsDisplayHeight = hlsSession.effectiveDisplayHeight;

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_STATUS: DONE (renderedFrames=$hlsRenderedFrames, dims=${hlsDisplayWidth}x$hlsDisplayHeight)',
        );

        // Attach VGStreamingPlaybackStatusPoller and VGStreamingPlaybackResilienceMonitor
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_MONITOR_START: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Scenario 2: Instantiating and starting poller and resilience monitor…';
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

        hlsMonitorSub = hlsMonitor.snapshots.listen((snapshot) {
          hlsCollectedSnapshots.add(snapshot);
          if (mounted) {
            setState(() {
              _currentSnapshot = hlsController.snapshot;
            });
          }
        });

        // Start monitor then poller
        hlsMonitor.start();
        hlsPoller.start();

        if (!hlsMonitor.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS resilience monitor failed to start (isRunning is false)',
          );
        }
        if (!hlsPoller.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS status poller failed to start (isRunning is false)',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_MONITOR_START: DONE',
        );

        // Collect >= 2 snapshots and assert invariants
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_MONITOR_COLLECT: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Scenario 2: Collecting resilience snapshots from HLS monitor…';
          });
        }

        final hlsCollectDeadline = DateTime.now().add(
          _kSnapshotCollectionTimeout,
        );
        while (DateTime.now().isBefore(hlsCollectDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final latest = hlsMonitor.latest;
          if (hlsCollectedSnapshots.length >= 2 &&
              latest != null &&
              latest.status.hasSession &&
              latest.status.effectiveDisplayWidth > 0 &&
              latest.status.effectiveDisplayHeight > 0) {
            final progressObserved =
                (hlsController.snapshot.session?.renderedFrames ?? 0) > 0 ||
                latest.status.isPlaying ||
                latest.status.positionMs > 0 ||
                latest.status.bufferedPositionMs > 0;
            if (progressObserved) {
              break;
            }
          }
        }

        if (hlsCollectedSnapshots.length < 2) {
          throw Exception(
            'Scenario 2 failed: HLS monitor expected at least 2 emitted snapshots, but collected ${hlsCollectedSnapshots.length}',
          );
        }

        final latestHlsSnap = hlsMonitor.latest;
        if (latestHlsSnap == null) {
          throw Exception(
            'Scenario 2 failed: HLS monitor latest snapshot is null after collection',
          );
        }

        if (!latestHlsSnap.status.hasSession) {
          throw Exception(
            'Scenario 2 failed: Latest HLS snapshot status hasSession is false',
          );
        }
        if (latestHlsSnap.status.effectiveDisplayWidth <= 0 ||
            latestHlsSnap.status.effectiveDisplayHeight <= 0) {
          throw Exception(
            'Scenario 2 failed: Latest HLS snapshot effective dimensions non-positive: '
            '${latestHlsSnap.status.effectiveDisplayWidth}x${latestHlsSnap.status.effectiveDisplayHeight}',
          );
        }

        final hlsHasProgressEvidence =
            (hlsController.snapshot.session?.renderedFrames ?? 0) > 0 ||
            latestHlsSnap.status.isPlaying ||
            latestHlsSnap.status.positionMs > 0 ||
            latestHlsSnap.status.bufferedPositionMs > 0;

        if (!hlsHasProgressEvidence) {
          throw Exception(
            'Scenario 2 failed: No playback progress or rendering evidence observed in HLS snapshot',
          );
        }

        for (final snap in hlsCollectedSnapshots) {
          _assertSnapshotInvariants(snap, scenarioName: 'Scenario 2 HLS');
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_MONITOR_COLLECT: DONE (collectedCount=${hlsCollectedSnapshots.length})',
        );

        // Stop & Dispose monitor, verify poller and controller remain alive
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_MONITOR_DISPOSE: START',
        );
        hlsMonitor.stop();
        if (hlsMonitor.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS monitor stop failed (isRunning is still true)',
          );
        }

        await hlsMonitorSub.cancel();
        hlsMonitorSub = null;

        await hlsMonitor.dispose();
        if (!hlsMonitor.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS monitor dispose failed (isDisposed is false)',
          );
        }

        if (hlsPoller.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS monitor disposal improperly disposed underlying poller',
          );
        }
        if (hlsController.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS monitor disposal improperly disposed underlying controller',
          );
        }

        // Safe evaluateOnce() on disposed monitor must not throw and must return advisory-only snapshot
        final safeDisposedHlsSnap = hlsMonitor.evaluateOnce(hlsPoller.latest);
        if (!safeDisposedHlsSnap.advisoryOnly ||
            safeDisposedHlsSnap.playbackMutation) {
          throw Exception(
            'Scenario 2 failed: Disposed HLS monitor evaluateOnce invariant violated',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_MONITOR_DISPOSE: DONE',
        );

        // Stop & Dispose poller, verify controller remains alive
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_POLLER_DISPOSE: START',
        );
        hlsPoller.stop();
        if (hlsPoller.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS poller stop failed (isRunning is still true)',
          );
        }

        await hlsPoller.dispose();
        if (!hlsPoller.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS poller dispose failed (isDisposed is false)',
          );
        }

        if (hlsController.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS poller disposal improperly disposed underlying controller',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_POLLER_DISPOSE: DONE',
        );

        results['hls'] = <String, dynamic>{
          'pass': true,
          'selectedKey': hlsDecision.selectedKey,
          'textureId': finalHlsSnapshot.textureId,
          'renderedFrames': hlsSession.renderedFrames,
          'effectiveDisplayWidth': hlsDisplayWidth,
          'effectiveDisplayHeight': hlsDisplayHeight,
          'state': finalHlsSnapshot.state.name,
          'snapshotsCount': hlsCollectedSnapshots.length,
          'latestSnapshot': latestHlsSnap.toJson(),
          'latestHealth': latestHlsSnap.healthAdvice.toJson(),
          'latestRecovery': latestHlsSnap.recoveryPlan.toJson(),
          'latestStatus': latestHlsSnap.status.toJson(),
          'warnings': hlsDecision.warnings,
          'raw': hlsSession.raw,
        };

        hlsResilienceMonitorPass = true;
      } finally {
        await hlsMonitorSub?.cancel();
        if (hlsMonitor != null && !hlsMonitor.isDisposed) {
          try {
            await hlsMonitor.dispose();
          } catch (_) {}
        }
        if (hlsPoller != null && !hlsPoller.isDisposed) {
          try {
            await hlsPoller.dispose();
          } catch (_) {}
        }

        // Stop & Dispose HLS controller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_CONTROLLER_DISPOSE: START',
        );
        if (!hlsController.isDisposed) {
          try {
            await hlsController.stop().timeout(_kControlTimeout);
          } catch (_) {}
          final disposeSnapshot = await hlsController.dispose().timeout(
            _kControlTimeout,
          );
          if (mounted) {
            setState(() {
              _currentSnapshot = disposeSnapshot;
            });
          }
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_HLS_CONTROLLER_DISPOSE: DONE',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 3: LL-HLS decision -> controller -> status poller -> resilience monitor
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_DECISION: START',
      );
      if (mounted) {
        setState(() {
          _status =
              'Scenario 3: Planning LL-HLS low-latency decision under appleAvPlayer…';
        });
      }

      final llHlsDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: compatibleSourceSet,
          preflightReport: report,
          preference: VGStreamingSourceSelectionPreference.preferLowLatency,
          preferredKeys: const ['ll_hls'],
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(
                preferLowLatency: true,
              ),
        ),
      );

      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_DECISION: DONE',
      );

      if (!llHlsDecision.canOpenPlayback ||
          llHlsDecision.decision != 'playback_ready' ||
          llHlsDecision.selectedKey != 'll_hls' ||
          llHlsDecision.playbackOptions == null ||
          llHlsDecision.playbackOptions?.formatHint !=
              VGStreamingFormatHint.hls ||
          llHlsDecision.selectedSource?.requireLlHlsTags != true) {
        throw Exception(
          'Scenario 3 failed: LL-HLS decision assertion failed: '
          'canOpenPlayback=${llHlsDecision.canOpenPlayback}, decision=${llHlsDecision.decision}, '
          'selectedKey=${llHlsDecision.selectedKey}, formatHint=${llHlsDecision.playbackOptions?.formatHint}, '
          'requireLlHlsTags=${llHlsDecision.selectedSource?.requireLlHlsTags}, '
          'warnings=${llHlsDecision.warnings}',
        );
      }

      selectedKeys.add(llHlsDecision.selectedKey!);
      allWarnings.addAll(llHlsDecision.warnings);

      // Create fresh controller, poller, & monitor variables for Scenario 3
      final llHlsController = VGStreamingPlaybackController();
      VGStreamingPlaybackStatusPoller? llHlsPoller;
      VGStreamingPlaybackResilienceMonitor? llHlsMonitor;
      StreamSubscription<VGStreamingPlaybackResilienceSnapshot>?
      llHlsMonitorSub;
      final llHlsCollectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];

      try {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_OPEN: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Scenario 3: Opening selected LL-HLS playback controller…';
          });
        }

        final llHlsOpenSnapshot = await llHlsController
            .open(llHlsDecision, startPlayback: true)
            .timeout(_kOperationTimeout);

        if (!llHlsOpenSnapshot.pass || llHlsOpenSnapshot.textureId == null) {
          throw Exception(
            'Scenario 3 failed: LL-HLS controller open failed: pass=${llHlsOpenSnapshot.pass}, '
            'reason=${llHlsOpenSnapshot.reason}, lastError=${llHlsOpenSnapshot.lastError}, '
            'textureId=${llHlsOpenSnapshot.textureId}',
          );
        }

        if (mounted) {
          setState(() {
            _currentSnapshot = llHlsOpenSnapshot;
            _status =
                'Scenario 3: LL-HLS streaming active (textureId=${llHlsOpenSnapshot.textureId})…';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_OPEN: DONE (textureId=${llHlsOpenSnapshot.textureId})',
        );

        // Poll controller.refresh() until renderedFrames > 0 and effectiveDisplayWidth/Height > 0
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_STATUS: START',
        );
        final llHlsDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackControllerSnapshot? finalLlHlsSnapshot;

        while (DateTime.now().isBefore(llHlsDeadline)) {
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
            finalLlHlsSnapshot = refreshed;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (finalLlHlsSnapshot == null) {
          final lastRefreshed = await llHlsController.refresh().timeout(
            _kControlTimeout,
          );
          throw Exception(
            'Scenario 3 failed: LL-HLS status verification timed out: renderedFrames=${lastRefreshed.session?.renderedFrames}, '
            'state=${lastRefreshed.state.name}, dims=${lastRefreshed.session?.effectiveDisplayWidth}x${lastRefreshed.session?.effectiveDisplayHeight}, '
            'raw=${lastRefreshed.session?.raw}',
          );
        }

        final llHlsSession = finalLlHlsSnapshot.session!;
        llHlsRenderedFrames = llHlsSession.renderedFrames;
        llHlsDisplayWidth = llHlsSession.effectiveDisplayWidth;
        llHlsDisplayHeight = llHlsSession.effectiveDisplayHeight;

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_STATUS: DONE (renderedFrames=$llHlsRenderedFrames, dims=${llHlsDisplayWidth}x$llHlsDisplayHeight)',
        );

        // Attach VGStreamingPlaybackStatusPoller and VGStreamingPlaybackResilienceMonitor
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_MONITOR_START: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Scenario 3: Instantiating and starting poller and resilience monitor…';
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

        llHlsMonitorSub = llHlsMonitor.snapshots.listen((snapshot) {
          llHlsCollectedSnapshots.add(snapshot);
          if (mounted) {
            setState(() {
              _currentSnapshot = llHlsController.snapshot;
            });
          }
        });

        // Start monitor then poller
        llHlsMonitor.start();
        llHlsPoller.start();

        if (!llHlsMonitor.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS resilience monitor failed to start (isRunning is false)',
          );
        }
        if (!llHlsPoller.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS status poller failed to start (isRunning is false)',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_MONITOR_START: DONE',
        );

        // Collect >= 2 snapshots and assert invariants
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_MONITOR_COLLECT: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Scenario 3: Collecting resilience snapshots from LL-HLS monitor…';
          });
        }

        final llHlsCollectDeadline = DateTime.now().add(
          _kSnapshotCollectionTimeout,
        );
        while (DateTime.now().isBefore(llHlsCollectDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final latest = llHlsMonitor.latest;
          if (llHlsCollectedSnapshots.length >= 2 &&
              latest != null &&
              latest.status.hasSession &&
              latest.status.effectiveDisplayWidth > 0 &&
              latest.status.effectiveDisplayHeight > 0) {
            final progressObserved =
                (llHlsController.snapshot.session?.renderedFrames ?? 0) > 0 ||
                latest.status.isPlaying ||
                latest.status.positionMs > 0 ||
                latest.status.bufferedPositionMs > 0;
            if (progressObserved) {
              break;
            }
          }
        }

        if (llHlsCollectedSnapshots.length < 2) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor expected at least 2 emitted snapshots, but collected ${llHlsCollectedSnapshots.length}',
          );
        }

        final latestLlHlsSnap = llHlsMonitor.latest;
        if (latestLlHlsSnap == null) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor latest snapshot is null after collection',
          );
        }

        if (!latestLlHlsSnap.status.hasSession) {
          throw Exception(
            'Scenario 3 failed: Latest LL-HLS snapshot status hasSession is false',
          );
        }
        if (latestLlHlsSnap.status.effectiveDisplayWidth <= 0 ||
            latestLlHlsSnap.status.effectiveDisplayHeight <= 0) {
          throw Exception(
            'Scenario 3 failed: Latest LL-HLS snapshot effective dimensions non-positive: '
            '${latestLlHlsSnap.status.effectiveDisplayWidth}x${latestLlHlsSnap.status.effectiveDisplayHeight}',
          );
        }

        final llHlsHasProgressEvidence =
            (llHlsController.snapshot.session?.renderedFrames ?? 0) > 0 ||
            latestLlHlsSnap.status.isPlaying ||
            latestLlHlsSnap.status.positionMs > 0 ||
            latestLlHlsSnap.status.bufferedPositionMs > 0;

        if (!llHlsHasProgressEvidence) {
          throw Exception(
            'Scenario 3 failed: No playback progress or rendering evidence observed in LL-HLS snapshot',
          );
        }

        for (final snap in llHlsCollectedSnapshots) {
          _assertSnapshotInvariants(snap, scenarioName: 'Scenario 3 LL-HLS');
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_MONITOR_COLLECT: DONE (collectedCount=${llHlsCollectedSnapshots.length})',
        );

        // Stop & Dispose monitor, verify poller and controller remain alive
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_MONITOR_DISPOSE: START',
        );
        llHlsMonitor.stop();
        if (llHlsMonitor.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor stop failed (isRunning is still true)',
          );
        }

        await llHlsMonitorSub.cancel();
        llHlsMonitorSub = null;

        await llHlsMonitor.dispose();
        if (!llHlsMonitor.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor dispose failed (isDisposed is false)',
          );
        }

        if (llHlsPoller.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor disposal improperly disposed underlying poller',
          );
        }
        if (llHlsController.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS monitor disposal improperly disposed underlying controller',
          );
        }

        // Safe evaluateOnce() on disposed monitor must not throw and must return advisory-only snapshot
        final safeDisposedLlHlsSnap = llHlsMonitor.evaluateOnce(
          llHlsPoller.latest,
        );
        if (!safeDisposedLlHlsSnap.advisoryOnly ||
            safeDisposedLlHlsSnap.playbackMutation) {
          throw Exception(
            'Scenario 3 failed: Disposed LL-HLS monitor evaluateOnce invariant violated',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_MONITOR_DISPOSE: DONE',
        );

        // Stop & Dispose poller, verify controller remains alive
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_POLLER_DISPOSE: START',
        );
        llHlsPoller.stop();
        if (llHlsPoller.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller stop failed (isRunning is still true)',
          );
        }

        await llHlsPoller.dispose();
        if (!llHlsPoller.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller dispose failed (isDisposed is false)',
          );
        }

        if (llHlsController.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller disposal improperly disposed underlying controller',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_POLLER_DISPOSE: DONE',
        );

        results['ll_hls'] = <String, dynamic>{
          'pass': true,
          'selectedKey': llHlsDecision.selectedKey,
          'textureId': finalLlHlsSnapshot.textureId,
          'renderedFrames': llHlsSession.renderedFrames,
          'effectiveDisplayWidth': llHlsDisplayWidth,
          'effectiveDisplayHeight': llHlsDisplayHeight,
          'state': finalLlHlsSnapshot.state.name,
          'snapshotsCount': llHlsCollectedSnapshots.length,
          'latestSnapshot': latestLlHlsSnap.toJson(),
          'latestHealth': latestLlHlsSnap.healthAdvice.toJson(),
          'latestRecovery': latestLlHlsSnap.recoveryPlan.toJson(),
          'latestStatus': latestLlHlsSnap.status.toJson(),
          'warnings': llHlsDecision.warnings,
          'raw': llHlsSession.raw,
        };

        llHlsResilienceMonitorPass = true;
      } finally {
        await llHlsMonitorSub?.cancel();
        if (llHlsMonitor != null && !llHlsMonitor.isDisposed) {
          try {
            await llHlsMonitor.dispose();
          } catch (_) {}
        }
        if (llHlsPoller != null && !llHlsPoller.isDisposed) {
          try {
            await llHlsPoller.dispose();
          } catch (_) {}
        }

        // Stop & Dispose LL-HLS controller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_CONTROLLER_DISPOSE: START',
        );
        if (!llHlsController.isDisposed) {
          try {
            await llHlsController.stop().timeout(_kControlTimeout);
          } catch (_) {}
          final disposeSnapshot = await llHlsController.dispose().timeout(
            _kControlTimeout,
          );
          if (mounted) {
            setState(() {
              _currentSnapshot = disposeSnapshot;
            });
          }
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_LL_HLS_CONTROLLER_DISPOSE: DONE',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 4: DASH typed deferral
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_DASH_DEFERRAL: START',
      );
      if (mounted) {
        setState(() {
          _status = 'Scenario 4: Evaluating DASH typed deferral…';
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
          'Scenario 4 failed: dashReport.pass is true (expected false on iOS)',
        );
      }
      if (dashReport.failedReports < 1) {
        throw Exception(
          'Scenario 4 failed: dashReport.failedReports was ${dashReport.failedReports} (expected >= 1)',
        );
      }
      if (!dashReport.warnings.contains('unsupported_format_dash')) {
        throw Exception(
          'Scenario 4 failed: dashReport.warnings did not contain "unsupported_format_dash" (${dashReport.warnings})',
        );
      }
      if (!dashReport.advisoryOnly) {
        throw Exception(
          'Scenario 4 failed: dashReport.advisoryOnly is not true',
        );
      }
      if (dashReport.playbackMutation) {
        throw Exception(
          'Scenario 4 failed: dashReport.playbackMutation is true',
        );
      }

      final dashStartupPlan = VGStreamingStartupPlanner.fromPreflight(
        dashReport,
      );
      if (dashStartupPlan.shouldProceed) {
        throw Exception(
          'Scenario 4 failed: dashStartupPlan.shouldProceed is true (expected false)',
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
          'Scenario 4 failed: dashDecision.canOpenPlayback is true (expected false)',
        );
      }
      if (dashDecision.decision != 'startup_plan_blocked') {
        throw Exception(
          'Scenario 4 failed: dashDecision.decision was "${dashDecision.decision}" (expected "startup_plan_blocked")',
        );
      }
      if (dashDecision.playbackOptions != null) {
        throw Exception(
          'Scenario 4 failed: dashDecision.playbackOptions is non-null (expected null)',
        );
      }

      dashTypedDeferralPass = true;
      results['dashTypedDeferralPass'] = true;
      results['dash'] = <String, dynamic>{
        'pass': false,
        'reportPass': dashReport.pass,
        'failedReports': dashReport.failedReports,
        'warnings': dashReport.warnings,
        'advisoryOnly': dashReport.advisoryOnly,
        'playbackMutation': dashReport.playbackMutation,
        'startupPlanShouldProceed': dashStartupPlan.shouldProceed,
        'canOpenPlayback': dashDecision.canOpenPlayback,
        'decision': dashDecision.decision,
        'playbackOptions': dashDecision.playbackOptions?.toArgs(),
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_STEP_DASH_DEFERRAL: DONE',
      );

      allPass =
          sourceSetPreflightPass &&
          hlsResilienceMonitorPass &&
          llHlsResilienceMonitorPass &&
          dashTypedDeferralPass;

      results['pass'] = allPass;
      results['sourceSetPreflightPass'] = sourceSetPreflightPass;
      results['hlsResilienceMonitorPass'] = hlsResilienceMonitorPass;
      results['llHlsResilienceMonitorPass'] = llHlsResilienceMonitorPass;
      results['dashTypedDeferralPass'] = dashTypedDeferralPass;
      results['advisoryOnlyVerified'] = true;
      results['playbackMutationZeroVerified'] = true;
      results['selectedKeys'] = selectedKeys;
      results['allWarnings'] = allWarnings;
      results['hlsRenderedFrames'] = hlsRenderedFrames;
      results['llHlsRenderedFrames'] = llHlsRenderedFrames;
      results['hlsDimensions'] = '${hlsDisplayWidth}x$hlsDisplayHeight';
      results['llHlsDimensions'] = '${llHlsDisplayWidth}x$llHlsDisplayHeight';
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_PHYSICAL_ERROR: $error\n$stack',
      );
      results['pass'] = false;
      results['error'] = error.toString();
      allPass = false;
    }

    // Emit final JSON payload
    // ignore: avoid_print
    print(
      'IOS_STREAMING_PREFLIGHT_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal pass/fail marker
    if (allPass) {
      // ignore: avoid_print
      print(_kPassMarker);
    } else {
      // ignore: avoid_print
      print(_kFailMarker);
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (All 4 scenarios verified with actual native iOS preflight and resilience monitor)'
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
