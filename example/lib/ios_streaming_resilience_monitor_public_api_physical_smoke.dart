// Copyright (c) Connects — Vanguard Phase 4C8I.
// iOS Public streaming playback resilience monitor -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream set (DASH, HLS) via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Composition with synthetic advisory preflight report for selector/controller/poller/monitor composition.
//      (Synthetic preflight report is used solely for composition proof; this harness does not re-prove native preflight).
//   3. Decision planning with VGStreamingPlaybackDecisionPlanner (preferDash + appleAvPlayer) falling back to HLS.
//   4. Execution of streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   5. Polling controller.refresh() until rendered frames > 0, positive display dimensions, and valid non-failed state.
//   6. Attaching VGStreamingPlaybackStatusPoller over VGStreamingPlaybackController (interval 300ms, emitInitialSummary true).
//   7. Attaching VGStreamingPlaybackResilienceMonitor over VGStreamingPlaybackStatusPoller.summaries (constrained profile, maxHistory 8).
//   8. Starting monitor, then poller, and collecting emitted composite VGStreamingPlaybackResilienceSnapshot events.
//   9. Asserting all resilience snapshot invariants:
//      - at least 2 emitted snapshots collected
//      - latest snapshot status has session == true, positive effective display dimensions, and real progress/render evidence
//      - all snapshots: advisoryOnly == true, playbackMutation == false
//      - all healthAdvice: advisoryOnly == true, playbackMutation == false
//      - all recoveryPlan: advisoryOnly == true, playbackMutation == false
//      - historyLength in 1..8
//      - status summary bounds: durationMs >= -1, positionMs >= 0, bufferedPositionMs >= 0,
//        bufferedPercent in 0..100, progressFraction in 0.0..1.0, bufferedFraction in 0.0..1.0
//  10. Stopping and disposing monitor: asserting poller and controller remain alive.
//  11. Stopping and disposing poller: asserting controller remains alive.
//  12. Verifying disposed monitor evaluateOnce() returns safely with advisory-only invariants.
//  13. Stopping and cleanly disposing controller.
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
// - Synthetic preflight report used for selector/controller/poller/monitor composition only (no native preflight claim).
// - Bounded timeouts across all operations.
// - Single-source resilience monitor proof over Apple capability HLS fallback (no direct iOS DASH playback).
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
  runApp(const IosStreamingResilienceMonitorPublicApiPhysicalSmokeApp());
}

class IosStreamingResilienceMonitorPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingResilienceMonitorPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingResilienceMonitorPublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingResilienceMonitorPublicApiPhysicalSmokeAppState();
}

class _IosStreamingResilienceMonitorPublicApiPhysicalSmokeAppState
    extends State<IosStreamingResilienceMonitorPublicApiPhysicalSmokeApp> {
  String _status =
      'Bootstrapping iOS streaming playback resilience monitor smoke...';
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
    print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_RESILIENCE_MONITOR_BOOTSTRAP_ERROR: $error\n$stack',
        );
        // ignore: avoid_print
        print('IOS_STREAMING_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_FAIL');
        exit(1);
      }
    });
  }

  Future<void> _runSmoke() async {
    final results = <String, dynamic>{
      'phase': 'Phase4C8I',
      'target': 'ios_physical',
    };
    bool allPass = false;

    bool planPass = false;
    bool openPass = false;
    bool statusPass = false;
    bool monitorStartPass = false;
    bool collectPass = false;
    bool monitorDisposePass = false;
    bool pollerDisposePass = false;
    bool controllerDisposePass = false;

    bool monitorDisposedPollerAlive = false;
    bool monitorDisposedControllerAlive = false;
    bool pollerDisposedControllerAlive = false;

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
      // ═══════════════════════════════════════════════════════════════════════
      // Step 1: Candidate Sources & Synthetic Preflight Report
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

      // Synthetic preflight report used solely for selector/controller/poller/monitor composition.
      const syntheticPreflightReport = VGStreamingPreflightReport(
        pass: true,
        phase: 'Phase4C5G',
        advisoryDecision: 'advise_constrained',
        requestedNetworkProfile: 'AUTO',
        recommendedNetworkProfile: 'CONSTRAINED',
        recommendedNetworkPolicy: <String, Object?>{
          'profile': 'CONSTRAINED',
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
      // Step 2: Plan Playback Decision (preferDash + appleAvPlayer -> HLS fallback)
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_PLAN: START');
      if (mounted) {
        setState(() {
          _status =
              'Step 1/6: Planning HLS fallback decision from preferDash...';
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

      decisionDiag = {
        'decision': decision.decision,
        'canOpenPlayback': decision.canOpenPlayback,
        'selectedKey': decision.selectedKey,
        'formatHint': decision.playbackOptions?.formatHint.name,
        'warnings': decision.warnings,
      };

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

      planPass = true;
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_PLAN: DONE');

      // ═══════════════════════════════════════════════════════════════════════
      // Step 3: Open Controller & Start Playback
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_OPEN: START');
      if (mounted) {
        setState(() {
          _status = 'Step 2/6: Opening streaming playback controller...';
        });
      }

      controller = VGStreamingPlaybackController();
      final openSnapshot = await controller
          .open(decision, startPlayback: true)
          .timeout(_kOperationTimeout);

      openDiag = {
        'pass': openSnapshot.pass,
        'state': openSnapshot.state.name,
        'textureId': openSnapshot.textureId,
        'reason': openSnapshot.reason,
      };

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
              'Step 3/6: Controller active (textureId=${openSnapshot.textureId}), awaiting initial render...';
        });
      }

      openPass = true;
      // ignore: avoid_print
      print(
        'IOS_STREAMING_RESILIENCE_MONITOR_STEP_OPEN: DONE (textureId=${openSnapshot.textureId})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 4: Refresh Status until frames > 0 and positive dimensions
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_STATUS: START');
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
      statusPass = true;
      // ignore: avoid_print
      print(
        'IOS_STREAMING_RESILIENCE_MONITOR_STEP_STATUS: DONE (renderedFrames=${initialSession.renderedFrames}, dims=${initialSession.effectiveDisplayWidth}x${initialSession.effectiveDisplayHeight})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 5: Setup Poller and Resilience Monitor
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_MONITOR_START: START');
      if (mounted) {
        setState(() {
          _status = 'Step 4/6: Setting up poller and resilience monitor...';
        });
      }

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

      monitorStartPass = true;
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_MONITOR_START: DONE');

      // ═══════════════════════════════════════════════════════════════════════
      // Step 6: Collect Resilience Snapshots and Assert Invariants
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_COLLECT: START');
      if (mounted) {
        setState(() {
          _status = 'Step 5/6: Collecting resilience snapshots...';
        });
      }

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
          'Expected at least 2 emitted resilience snapshots, but collected ${collectedSnapshots.length}',
        );
      }

      final latestSnap = monitor.latest;
      if (latestSnap == null) {
        throw Exception('Monitor latest snapshot is null after collection');
      }

      // Latest snapshot invariants
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

      collectPass = true;
      // ignore: avoid_print
      print(
        'IOS_STREAMING_RESILIENCE_MONITOR_STEP_COLLECT: DONE (collectedCount=${collectedSnapshots.length})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 7: Monitor Stop and Dispose Lifecycle
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_MONITOR_DISPOSE: START');
      if (mounted) {
        setState(() {
          _status = 'Step 6/6: Verifying lifecycle boundaries and teardown...';
        });
      }

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

      // Safe evaluateOnce() on disposed monitor must not throw and must return advisory-only snapshot
      final safeDisposedSnap = monitor.evaluateOnce(poller.latest);
      if (!safeDisposedSnap.advisoryOnly || safeDisposedSnap.playbackMutation) {
        throw Exception('Disposed monitor evaluateOnce invariant violated');
      }

      monitorDisposePass = true;
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_MONITOR_DISPOSE: DONE');

      // ═══════════════════════════════════════════════════════════════════════
      // Step 8: Poller Stop and Dispose Lifecycle
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_POLLER_DISPOSE: START');
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

      pollerDisposePass = true;
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_POLLER_DISPOSE: DONE');

      // ═══════════════════════════════════════════════════════════════════════
      // Step 9: Controller Teardown
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_CONTROLLER_DISPOSE: START');
      await controller.stop().timeout(_kControlTimeout);
      final disposeSnapshot = await controller.dispose().timeout(
        _kControlTimeout,
      );
      if (mounted) {
        setState(() {
          _currentSnapshot = disposeSnapshot;
        });
      }

      controllerDisposePass = controller.isDisposed;
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_STEP_CONTROLLER_DISPOSE: DONE');

      allPass =
          planPass &&
          openPass &&
          statusPass &&
          monitorStartPass &&
          collectPass &&
          monitorDisposePass &&
          pollerDisposePass &&
          controllerDisposePass &&
          monitorDisposedPollerAlive &&
          monitorDisposedControllerAlive &&
          pollerDisposedControllerAlive;

      results['pass'] = allPass;
      results['selectedKey'] = decision.selectedKey;
      results['textureId'] = openSnapshot.textureId;
      results['renderedFrames'] =
          initialRenderedSnapshot.session?.renderedFrames ?? 0;
      results['snapshotsCount'] = collectedSnapshots.length;
      results['latestStatus'] = latestStatusDiag;
      results['latestHealth'] = latestHealthDiag;
      results['latestRecovery'] = latestRecoveryDiag;
      results['decision'] = decisionDiag;
      results['open'] = openDiag;
      results['lifecycleBoundaries'] = {
        'monitorDisposedPollerAlive': monitorDisposedPollerAlive,
        'monitorDisposedControllerAlive': monitorDisposedControllerAlive,
        'pollerDisposedControllerAlive': pollerDisposedControllerAlive,
        'monitorDisposed': monitor.isDisposed,
        'pollerDisposed': poller.isDisposed,
        'controllerDisposed': controller.isDisposed,
      };
    } catch (error, stack) {
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_PHYSICAL_ERROR: $error\n$stack');
      results['pass'] = false;
      results['error'] = error.toString();
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

    // Emit final JSON payload
    // ignore: avoid_print
    print(
      'IOS_STREAMING_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal pass/fail marker
    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_RESILIENCE_MONITOR_PUBLIC_API_PHYSICAL_FAIL');
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (Resilience monitor collected ${collectedSnapshots.length} snapshots, lifecycle verified)'
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
