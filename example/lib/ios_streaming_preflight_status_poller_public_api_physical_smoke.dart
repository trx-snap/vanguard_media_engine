// Copyright (c) Connects — Vanguard Phase 4C8Q.
// iOS Public streaming native preflight status poller all-up physical smoke.
//
// Route:
//   VGStreamingSourceSet ->
//   VGStreamingPreflightClient.evaluate(...) [actual native iOS preflight] ->
//   VGStreamingPlaybackDecisionPlanner.plan(...) [capability-filtered decision] ->
//   VGStreamingPlaybackController.open/refresh/stop/dispose ->
//   VGStreamingPlaybackTextureView presentation ->
//   VGStreamingPlaybackStatusPoller [Stream<VGStreamingPlaybackStatusSummary>]
//
// Scenarios:
//   1. Compatible native source-set preflight:
//      - Build VGStreamingSourceSet with [hls, ll_hls].
//      - sourceSet.toPreflightRequest(preferLowLatency: true, requestedNetworkProfile: auto).
//      - Evaluate via VGStreamingPreflightClient.evaluate.
//      - Assert report.pass == true, advisoryOnly == true, playbackMutation == false,
//        totalReports == 2, failedReports == 0, phase contains Phase4C8C, llHlsAvailable == true.
//      - Build VGStreamingStartupPlanner.fromPreflight(report); assert shouldProceed == true.
//   2. HLS fallback decision -> controller -> status poller:
//      - Fallback source set ordered [dash, hls].
//      - VGStreamingPlaybackDecisionPlanner.plan(preflightReport: report from scenario 1,
//        preference: preferDash, clientCapabilities: appleAvPlayer()).
//      - Assert decision.canOpenPlayback == true, decision.decision == 'playback_ready',
//        selectedKey == 'hls', playbackOptions != null,
//        warnings contains 'source_incompatible:dash:dash_not_supported'.
//      - Open fresh VGStreamingPlaybackController with startPlayback: true.
//      - Poll controller.refresh() until renderedFrames > 0 and effectiveDisplayWidth/Height > 0.
//      - Attach VGStreamingPlaybackStatusPoller (300ms interval, emitInitialSummary: true).
//      - Listen to poller.summaries, start it, assert isRunning == true, collect >= 2 summaries.
//      - Assert status summary invariants on collected/latest summaries.
//      - Stop poller (isRunning == false), dispose poller (isDisposed == true),
//        verify poller disposal did not dispose controller, assert poller.refreshOnce() returns safely.
//      - Stop/dispose controller in finally.
//   3. LL-HLS decision -> controller -> status poller:
//      - Use compatible source set [hls, ll_hls] and report from scenario 1.
//      - Plan with preferredKeys: ['ll_hls'], preference: preferLowLatency,
//        clientCapabilities: appleAvPlayer(preferLowLatency: true).
//      - Assert decision.canOpenPlayback == true, selectedKey == 'll_hls',
//        selectedSource.requireLlHlsTags == true.
//      - Open fresh controller, poll positive rendered frames/dimensions,
//        attach public status poller, collect >= 2 summaries, assert summary invariants,
//        verify poller stop/dispose and safe refreshOnce, stop/dispose controller in finally.
//   4. DASH typed deferral:
//      - Run actual DASH-only native preflight via dashSourceSet.toPreflightRequest(requestedNetworkProfile: auto).
//      - Assert report.pass == false, failedReports >= 1, warnings contains 'unsupported_format_dash',
//        advisoryOnly == true, playbackMutation == false, startup plan shouldProceed == false.
//      - Plan dash-only decision with VGStreamingPlaybackDecisionPlanner.plan,
//        preference preferDash, clientCapabilities appleAvPlayer();
//        assert canOpenPlayback == false, decision == 'startup_plan_blocked', playbackOptions == null.
//      - Zero playback mutation / never open playback controller or poller for DASH.
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
// - Typed DASH deferral without attempting playback or poller instantiation.
// - All controllers, pollers, and stream subscriptions cleaned up in finally blocks.
// - Emits structured step markers and terminal JSON payload.
// - Exit 0 on pass, exit 1 on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kPhase = 'Phase4C8Q';
const String _kTarget = 'ios_physical';
const String _kPassMarker =
    'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_PUBLIC_API_PHYSICAL_PASS';
const String _kFailMarker =
    'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_PUBLIC_API_PHYSICAL_FAIL';

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
const Duration _kPollerCollectionTimeout = Duration(seconds: 15);

void main() {
  runApp(const IosStreamingPreflightStatusPollerPublicApiPhysicalSmokeApp());
}

class IosStreamingPreflightStatusPollerPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingPreflightStatusPollerPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingPreflightStatusPollerPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingPreflightStatusPollerPublicApiPhysicalSmokeAppState();
}

class _IosStreamingPreflightStatusPollerPublicApiPhysicalSmokeAppState
    extends State<IosStreamingPreflightStatusPollerPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Bootstrapping iOS streaming preflight status poller smoke...';
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
    print('IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_BOOTSTRAP_ERROR: $error\n$stack',
        );
        // ignore: avoid_print
        print(_kFailMarker);
        exit(1);
      }
    });
  }

  void _assertSummaryInvariants(
    VGStreamingPlaybackStatusSummary summary, {
    required String scenarioName,
  }) {
    final hasSessionValid = summary.hasSession == true;
    final isTerminalValid = summary.isTerminal == false;
    final durationValid = summary.durationMs >= -1;
    final positionValid = summary.positionMs >= 0;
    final bufferedPosValid = summary.bufferedPositionMs >= 0;
    final bufferedPercentValid =
        summary.bufferedPercent >= 0 && summary.bufferedPercent <= 100;
    final progressFractionValid =
        summary.progressFraction >= 0.0 && summary.progressFraction <= 1.0;
    final bufferedFractionValid =
        summary.bufferedFraction >= 0.0 && summary.bufferedFraction <= 1.0;
    final widthValid = summary.effectiveDisplayWidth > 0;
    final heightValid = summary.effectiveDisplayHeight > 0;
    final cacheBytesValid = summary.playbackCacheBytesRead >= 0;
    final cacheSizeValid = summary.playbackCacheSizeBytes >= 0;
    final cacheIgnoredValid = summary.playbackCacheIgnoredCount >= 0;
    final jsonMap = summary.toJson();
    final jsonString = jsonEncode(jsonMap);
    final jsonValid = jsonString.isNotEmpty;

    final summaryPass =
        hasSessionValid &&
        isTerminalValid &&
        durationValid &&
        positionValid &&
        bufferedPosValid &&
        bufferedPercentValid &&
        progressFractionValid &&
        bufferedFractionValid &&
        widthValid &&
        heightValid &&
        cacheBytesValid &&
        cacheSizeValid &&
        cacheIgnoredValid &&
        jsonValid;

    if (!summaryPass) {
      throw Exception(
        'Status summary invariant assertion failed ($scenarioName): '
        'hasSession=$hasSessionValid, isTerminal=$isTerminalValid, '
        'duration=$durationValid (${summary.durationMs}), position=$positionValid (${summary.positionMs}), '
        'bufferedPos=$bufferedPosValid (${summary.bufferedPositionMs}), bufferedPercent=$bufferedPercentValid (${summary.bufferedPercent}), '
        'progressFraction=$progressFractionValid (${summary.progressFraction}), bufferedFraction=$bufferedFractionValid (${summary.bufferedFraction}), '
        'width=$widthValid (${summary.effectiveDisplayWidth}), height=$heightValid (${summary.effectiveDisplayHeight}), '
        'cacheBytes=$cacheBytesValid, cacheSize=$cacheSizeValid, cacheIgnored=$cacheIgnoredValid, json=$jsonValid',
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
    bool hlsStatusPollerPass = false;
    bool llHlsStatusPollerPass = false;
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
        'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_SOURCE_SET_PREFLIGHT: START',
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
        'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_SOURCE_SET_PREFLIGHT: DONE',
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
      // Scenario 2: HLS Fallback decision -> controller -> status poller
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_DECISION: START');
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
      print('IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_DECISION: DONE');

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

      // Create fresh controller & poller variables for Scenario 2
      final hlsController = VGStreamingPlaybackController();
      VGStreamingPlaybackStatusPoller? hlsPoller;
      StreamSubscription<VGStreamingPlaybackStatusSummary>? hlsPollerSub;
      final hlsCollectedSummaries = <VGStreamingPlaybackStatusSummary>[];

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_OPEN: START');
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
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_OPEN: DONE (textureId=${hlsOpenSnapshot.textureId})',
        );

        // Poll controller.refresh() until renderedFrames > 0 and effectiveDisplayWidth/Height > 0
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_STATUS: START');
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
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_STATUS: DONE (renderedFrames=$hlsRenderedFrames, dims=${hlsDisplayWidth}x$hlsDisplayHeight)',
        );

        // Attach VGStreamingPlaybackStatusPoller and start polling
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_POLLER_START: START',
        );
        if (mounted) {
          setState(() {
            _status = 'Scenario 2: Instantiating and starting status poller…';
          });
        }

        hlsPoller = VGStreamingPlaybackStatusPoller(
          controller: hlsController,
          config: VGStreamingPlaybackStatusPollerConfig(
            interval: const Duration(milliseconds: 300),
            emitInitialSummary: true,
          ),
        );

        hlsPollerSub = hlsPoller.summaries.listen((summary) {
          hlsCollectedSummaries.add(summary);
          if (mounted) {
            setState(() {
              _currentSnapshot = hlsController.snapshot;
            });
          }
        });

        hlsPoller.start();
        if (!hlsPoller.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS poller failed to start (isRunning is false)',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_POLLER_START: DONE',
        );

        // Collect >= 2 summaries and assert invariants
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_POLLER_COLLECT: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Scenario 2: Collecting status summaries from HLS poller…';
          });
        }

        final hlsCollectDeadline = DateTime.now().add(
          _kPollerCollectionTimeout,
        );
        while (DateTime.now().isBefore(hlsCollectDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final latest = hlsPoller.latest;
          if (hlsCollectedSummaries.length >= 2 &&
              latest.hasSession &&
              latest.effectiveDisplayWidth > 0 &&
              latest.effectiveDisplayHeight > 0) {
            break;
          }
        }

        if (hlsCollectedSummaries.length < 2) {
          throw Exception(
            'Scenario 2 failed: HLS poller expected at least 2 emitted summaries, but collected ${hlsCollectedSummaries.length}',
          );
        }

        bool hlsHasValidSessionSummary = false;
        for (final summary in hlsCollectedSummaries) {
          _assertSummaryInvariants(summary, scenarioName: 'Scenario 2 HLS');
          if (summary.hasSession &&
              summary.effectiveDisplayWidth > 0 &&
              summary.effectiveDisplayHeight > 0) {
            hlsHasValidSessionSummary = true;
          }
        }

        if (!hlsHasValidSessionSummary) {
          throw Exception(
            'Scenario 2 failed: None of the collected HLS summaries satisfied hasSession==true with positive dimensions',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_POLLER_COLLECT: DONE (collectedCount=${hlsCollectedSummaries.length})',
        );

        // Stop poller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_POLLER_STOP: START',
        );
        hlsPoller.stop();
        if (hlsPoller.isRunning) {
          throw Exception(
            'Scenario 2 failed: HLS poller stop failed (isRunning is still true)',
          );
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_POLLER_STOP: DONE',
        );

        // Dispose poller & verify non-owning lifecycle
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_POLLER_DISPOSE: START',
        );
        await hlsPollerSub.cancel();
        hlsPollerSub = null;
        await hlsPoller.dispose();
        if (!hlsPoller.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS poller dispose failed (isDisposed is false)',
          );
        }

        if (hlsController.isDisposed) {
          throw Exception(
            'Scenario 2 failed: HLS poller dispose improperly disposed the underlying controller',
          );
        }

        // Safe refreshOnce after poller dispose must return safely
        final postDisposeSummary = await hlsPoller.refreshOnce();
        if (!postDisposeSummary.hasSession) {
          throw Exception(
            'Scenario 2 failed: Post-dispose poller refreshOnce did not return latest valid summary',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_POLLER_DISPOSE: DONE',
        );

        results['hls'] = <String, dynamic>{
          'pass': true,
          'selectedKey': hlsDecision.selectedKey,
          'textureId': finalHlsSnapshot.textureId,
          'renderedFrames': hlsSession.renderedFrames,
          'effectiveDisplayWidth': hlsDisplayWidth,
          'effectiveDisplayHeight': hlsDisplayHeight,
          'state': finalHlsSnapshot.state.name,
          'summariesCount': hlsCollectedSummaries.length,
          'latestSummary': hlsPoller.latest.toJson(),
          'warnings': hlsDecision.warnings,
          'raw': hlsSession.raw,
        };

        hlsStatusPollerPass = true;
      } finally {
        await hlsPollerSub?.cancel();
        if (hlsPoller != null && !hlsPoller.isDisposed) {
          try {
            await hlsPoller.dispose();
          } catch (_) {}
        }

        // Stop & Dispose HLS controller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_CONTROLLER_DISPOSE: START',
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
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_HLS_CONTROLLER_DISPOSE: DONE',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 3: LL-HLS decision -> controller -> status poller
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_DECISION: START',
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
      print('IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_DECISION: DONE');

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

      // Create fresh controller & poller variables for Scenario 3
      final llHlsController = VGStreamingPlaybackController();
      VGStreamingPlaybackStatusPoller? llHlsPoller;
      StreamSubscription<VGStreamingPlaybackStatusSummary>? llHlsPollerSub;
      final llHlsCollectedSummaries = <VGStreamingPlaybackStatusSummary>[];

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_OPEN: START');
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
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_OPEN: DONE (textureId=${llHlsOpenSnapshot.textureId})',
        );

        // Poll controller.refresh() until renderedFrames > 0 and effectiveDisplayWidth/Height > 0
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_STATUS: START',
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
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_STATUS: DONE (renderedFrames=$llHlsRenderedFrames, dims=${llHlsDisplayWidth}x$llHlsDisplayHeight)',
        );

        // Attach VGStreamingPlaybackStatusPoller and start polling
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_POLLER_START: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Scenario 3: Instantiating and starting LL-HLS status poller…';
          });
        }

        llHlsPoller = VGStreamingPlaybackStatusPoller(
          controller: llHlsController,
          config: VGStreamingPlaybackStatusPollerConfig(
            interval: const Duration(milliseconds: 300),
            emitInitialSummary: true,
          ),
        );

        llHlsPollerSub = llHlsPoller.summaries.listen((summary) {
          llHlsCollectedSummaries.add(summary);
          if (mounted) {
            setState(() {
              _currentSnapshot = llHlsController.snapshot;
            });
          }
        });

        llHlsPoller.start();
        if (!llHlsPoller.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller failed to start (isRunning is false)',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_POLLER_START: DONE',
        );

        // Collect >= 2 summaries and assert invariants
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_POLLER_COLLECT: START',
        );
        if (mounted) {
          setState(() {
            _status =
                'Scenario 3: Collecting status summaries from LL-HLS poller…';
          });
        }

        final llHlsCollectDeadline = DateTime.now().add(
          _kPollerCollectionTimeout,
        );
        while (DateTime.now().isBefore(llHlsCollectDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final latest = llHlsPoller.latest;
          if (llHlsCollectedSummaries.length >= 2 &&
              latest.hasSession &&
              latest.effectiveDisplayWidth > 0 &&
              latest.effectiveDisplayHeight > 0) {
            break;
          }
        }

        if (llHlsCollectedSummaries.length < 2) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller expected at least 2 emitted summaries, but collected ${llHlsCollectedSummaries.length}',
          );
        }

        bool llHlsHasValidSessionSummary = false;
        for (final summary in llHlsCollectedSummaries) {
          _assertSummaryInvariants(summary, scenarioName: 'Scenario 3 LL-HLS');
          if (summary.hasSession &&
              summary.effectiveDisplayWidth > 0 &&
              summary.effectiveDisplayHeight > 0) {
            llHlsHasValidSessionSummary = true;
          }
        }

        if (!llHlsHasValidSessionSummary) {
          throw Exception(
            'Scenario 3 failed: None of the collected LL-HLS summaries satisfied hasSession==true with positive dimensions',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_POLLER_COLLECT: DONE (collectedCount=${llHlsCollectedSummaries.length})',
        );

        // Stop poller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_POLLER_STOP: START',
        );
        llHlsPoller.stop();
        if (llHlsPoller.isRunning) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller stop failed (isRunning is still true)',
          );
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_POLLER_STOP: DONE',
        );

        // Dispose poller & verify non-owning lifecycle
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_POLLER_DISPOSE: START',
        );
        await llHlsPollerSub.cancel();
        llHlsPollerSub = null;
        await llHlsPoller.dispose();
        if (!llHlsPoller.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller dispose failed (isDisposed is false)',
          );
        }

        if (llHlsController.isDisposed) {
          throw Exception(
            'Scenario 3 failed: LL-HLS poller dispose improperly disposed the underlying controller',
          );
        }

        // Safe refreshOnce after poller dispose must return safely
        final postDisposeSummary = await llHlsPoller.refreshOnce();
        if (!postDisposeSummary.hasSession) {
          throw Exception(
            'Scenario 3 failed: Post-dispose LL-HLS poller refreshOnce did not return latest valid summary',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_POLLER_DISPOSE: DONE',
        );

        results['llHls'] = <String, dynamic>{
          'pass': true,
          'selectedKey': llHlsDecision.selectedKey,
          'textureId': finalLlHlsSnapshot.textureId,
          'renderedFrames': llHlsSession.renderedFrames,
          'effectiveDisplayWidth': llHlsDisplayWidth,
          'effectiveDisplayHeight': llHlsDisplayHeight,
          'state': finalLlHlsSnapshot.state.name,
          'summariesCount': llHlsCollectedSummaries.length,
          'latestSummary': llHlsPoller.latest.toJson(),
          'warnings': llHlsDecision.warnings,
          'raw': llHlsSession.raw,
        };

        llHlsStatusPollerPass = true;
      } finally {
        await llHlsPollerSub?.cancel();
        if (llHlsPoller != null && !llHlsPoller.isDisposed) {
          try {
            await llHlsPoller.dispose();
          } catch (_) {}
        }

        // Stop & Dispose LL-HLS controller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_CONTROLLER_DISPOSE: START',
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
          'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_LL_HLS_CONTROLLER_DISPOSE: DONE',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 4: DASH typed deferral
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_DASH_DEFERRAL: START');
      if (mounted) {
        setState(() {
          _status = 'Scenario 4: Evaluating DASH-only typed deferral…';
        });
      }

      final dashOnlySourceSet = VGStreamingSourceSet(sources: [dashDescriptor]);

      final dashPreflightRequest = dashOnlySourceSet.toPreflightRequest(
        requestedNetworkProfile: VGStreamingNetworkProfile.auto,
      );

      final dashReport = await _preflightClient
          .evaluate(dashPreflightRequest)
          .timeout(_kPreflightTimeout);

      if (dashReport.pass != false) {
        throw Exception(
          'Scenario 4 failed: dashReport.pass was true (expected false for unsupported DASH)',
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
        throw Exception('Scenario 4 failed: dashReport.advisoryOnly was false');
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
          sourceSet: dashOnlySourceSet,
          preflightReport: dashReport,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      if (dashDecision.canOpenPlayback != false ||
          dashDecision.decision != 'startup_plan_blocked' ||
          dashDecision.playbackOptions != null) {
        throw Exception(
          'Scenario 4 failed: DASH decision assertion failed: '
          'canOpenPlayback=${dashDecision.canOpenPlayback} (expected false), '
          'decision=${dashDecision.decision} (expected startup_plan_blocked), '
          'playbackOptions=${dashDecision.playbackOptions} (expected null)',
        );
      }

      allWarnings.addAll(dashDecision.warnings);
      allWarnings.addAll(dashReport.warnings);

      dashTypedDeferralPass = true;
      results['dashTypedDeferral'] = <String, dynamic>{
        'pass': true,
        'reportPass': dashReport.pass,
        'failedReports': dashReport.failedReports,
        'warnings': dashReport.warnings,
        'advisoryOnly': dashReport.advisoryOnly,
        'playbackMutation': dashReport.playbackMutation,
        'startupPlanShouldProceed': dashStartupPlan.shouldProceed,
        'decision': dashDecision.decision,
        'canOpenPlayback': dashDecision.canOpenPlayback,
        'playbackOptionsNull': dashDecision.playbackOptions == null,
      };

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_STATUS_POLLER_STEP_DASH_DEFERRAL: DONE');

      // Verify overall assertions
      results['advisoryOnlyVerified'] =
          report.advisoryOnly && dashReport.advisoryOnly;
      results['playbackMutationZeroVerified'] =
          !report.playbackMutation && !dashReport.playbackMutation;

      allPass =
          sourceSetPreflightPass &&
          hlsStatusPollerPass &&
          llHlsStatusPollerPass &&
          dashTypedDeferralPass;

      results['pass'] = allPass;
      results['sourceSetPreflightPass'] = sourceSetPreflightPass;
      results['hlsStatusPollerPass'] = hlsStatusPollerPass;
      results['llHlsStatusPollerPass'] = llHlsStatusPollerPass;
      results['dashTypedDeferralPass'] = dashTypedDeferralPass;
      results['selectedKeys'] = selectedKeys;
      results['renderedFrames'] = <String, int>{
        'hls': hlsRenderedFrames,
        'llHls': llHlsRenderedFrames,
      };
      results['displayDimensions'] = <String, String>{
        'hls': '${hlsDisplayWidth}x$hlsDisplayHeight',
        'llHls': '${llHlsDisplayWidth}x$llHlsDisplayHeight',
      };
      results['warnings'] = allWarnings.toSet().toList();
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_PHYSICAL_ERROR: $error\n$stack',
      );
      results['pass'] = false;
      results['error'] = error.toString();
      allPass = false;
    }

    // Emit terminal JSON line
    // ignore: avoid_print
    print(
      'IOS_STREAMING_PREFLIGHT_STATUS_POLLER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
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
            ? 'PASS (HLS: $hlsRenderedFrames frames [${hlsDisplayWidth}x$hlsDisplayHeight], LL-HLS: $llHlsRenderedFrames frames [${llHlsDisplayWidth}x$llHlsDisplayHeight])'
            : 'FAIL: ${results['error']}';
      });
    }

    await Future<void>.delayed(const Duration(seconds: 1));
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
