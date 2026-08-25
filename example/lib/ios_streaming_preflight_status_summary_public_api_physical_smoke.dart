// Vanguard iOS True-DAG Phase 4C8P: Public streaming native preflight status summary all-up physical smoke.
//
// Route:
//   VGStreamingSourceSet ->
//   VGStreamingPreflightClient.evaluate(...) [actual native iOS preflight] ->
//   VGStreamingPlaybackDecisionPlanner.plan(...) [capability-filtered decision] ->
//   VGStreamingPlaybackController.open/play/pause/stop/dispose ->
//   VGStreamingPlaybackTextureView presentation ->
//   VGStreamingPlaybackStatusSummary.fromControllerSnapshot(...) [read model assertions]
//
// Scenarios:
//   1. Compatible native source-set preflight:
//      - Build VGStreamingSourceSet with [hls, ll_hls].
//      - sourceSet.toPreflightRequest(preferLowLatency: true, requestedNetworkProfile: auto).
//      - Evaluate via VGStreamingPreflightClient.evaluate.
//      - Assert report.pass == true, advisoryOnly == true, playbackMutation == false, totalReports == 2, failedReports == 0, phase contains Phase4C8C, llHlsAvailable == true.
//      - Build VGStreamingStartupPlanner.fromPreflight(report); assert shouldProceed == true.
//   2. HLS fallback decision -> controller -> status summary:
//      - Fallback source set ordered [dash, hls].
//      - VGStreamingPlaybackDecisionPlanner.plan(preflightReport: report from scenario 1, preference: preferDash, clientCapabilities: appleAvPlayer()).
//      - Assert decision.canOpenPlayback == true, decision.decision == 'playback_ready', selectedKey == 'hls', playbackOptions != null, warnings contains 'source_incompatible:dash:dash_not_supported'.
//      - Open fresh VGStreamingPlaybackController with startPlayback: true, poll refresh until renderedFrames > 0 and effectiveDisplayWidth/Height > 0.
//      - Build VGStreamingPlaybackStatusSummary.fromControllerSnapshot(finalSnapshot); assert all status summary invariants.
//      - Exercise pause, play, stop, dispose. After dispose, build summary from dispose snapshot and assert hasSession == false, isPlaying == false, isTerminal == true.
//   3. LL-HLS decision -> controller -> status summary:
//      - Use compatible source set [hls, ll_hls] and report from scenario 1.
//      - Plan with preferredKeys: ['ll_hls'], preference: preferLowLatency, clientCapabilities: appleAvPlayer(preferLowLatency: true).
//      - Assert decision.canOpenPlayback == true, selectedKey == 'll_hls', selectedSource.requireLlHlsTags == true.
//      - Open fresh controller, poll positive rendered frames/dimensions, build and assert status summary invariants, stop/dispose in finally.
//   4. DASH typed deferral:
//      - Run actual DASH-only preflight using dashSourceSet.toPreflightRequest(requestedNetworkProfile: auto).
//      - Assert report.pass == false, failedReports >= 1, warnings contains 'unsupported_format_dash', advisoryOnly == true, playbackMutation == false, startup plan shouldProceed == false.
//      - Plan dash-only decision with VGStreamingPlaybackDecisionPlanner.plan, preference preferDash, clientCapabilities appleAvPlayer(); assert canOpenPlayback == false, decision == 'startup_plan_blocked', playbackOptions == null.
//      - Zero playback mutation / never open playback controller for DASH.
//
// Verification Invariants & Boundaries:
// - Imports ONLY:
//   - dart:async
//   - dart:convert
//   - dart:io
//   - package:flutter/material.dart
//   - package:vanguard_media_engine/vanguard_media_engine.dart
// - No raw MethodChannel or package:flutter/services.dart.
// - Actual native iOS preflight and actual AVPlayer playback.
// - Typed DASH deferral without attempting playback.
// - All controllers cleaned up in finally blocks.
// - Emits structured step markers and terminal JSON payload.
// - Exit 0 on pass, exit 1 on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kPhase = 'Phase4C8P';
const String _kTarget = 'ios_physical';
const String _kPassMarker =
    'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_PUBLIC_API_PHYSICAL_PASS';
const String _kFailMarker =
    'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_PUBLIC_API_PHYSICAL_FAIL';

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

void main() {
  runApp(const IosStreamingPreflightStatusSummaryPublicApiPhysicalSmokeApp());
}

class IosStreamingPreflightStatusSummaryPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingPreflightStatusSummaryPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<IosStreamingPreflightStatusSummaryPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingPreflightStatusSummaryPublicApiPhysicalSmokeAppState();
}

class _IosStreamingPreflightStatusSummaryPublicApiPhysicalSmokeAppState
    extends State<IosStreamingPreflightStatusSummaryPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Bootstrapping iOS streaming preflight status summary smoke...';
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
    print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_BOOTSTRAP_ERROR: $error\n$stack',
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
    final isPlayingValid = summary.isPlaying == true || !summary.isTerminal;
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
        isPlayingValid &&
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
        'hasSession=$hasSessionValid, isPlaying=$isPlayingValid, isTerminal=$isTerminalValid, '
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
    bool hlsStatusSummaryPass = false;
    bool llHlsStatusSummaryPass = false;
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
        'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_SOURCE_SET_PREFLIGHT: START',
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
        'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_SOURCE_SET_PREFLIGHT: DONE',
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
      // Scenario 2: HLS Fallback decision -> controller -> status summary
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_DECISION: START');
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
      print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_DECISION: DONE');

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

      // Create fresh controller for Scenario 2
      final hlsController = VGStreamingPlaybackController();

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_OPEN: START');
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
          'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_OPEN: DONE (textureId=${hlsOpenSnapshot.textureId})',
        );

        // Poll controller.refresh() until renderedFrames > 0 and effectiveDisplayWidth/Height > 0
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_STATUS: START');
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
          'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_STATUS: DONE (renderedFrames=$hlsRenderedFrames, dims=${hlsDisplayWidth}x$hlsDisplayHeight)',
        );

        // Build status summary & assert invariants
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_SUMMARY: START');
        final hlsSummary =
            VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
              finalHlsSnapshot,
            );
        _assertSummaryInvariants(hlsSummary, scenarioName: 'Scenario 2 HLS');

        results['hls'] = <String, dynamic>{
          'pass': true,
          'selectedKey': hlsDecision.selectedKey,
          'textureId': finalHlsSnapshot.textureId,
          'renderedFrames': hlsSession.renderedFrames,
          'effectiveDisplayWidth': hlsDisplayWidth,
          'effectiveDisplayHeight': hlsDisplayHeight,
          'state': finalHlsSnapshot.state.name,
          'summary': hlsSummary.toJson(),
          'warnings': hlsDecision.warnings,
          'raw': hlsSession.raw,
        };

        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_SUMMARY: DONE');

        // Exercise pause
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_PAUSE: START');
        final pauseSnapshot = await hlsController.pause().timeout(
          _kControlTimeout,
        );
        if (!pauseSnapshot.pass ||
            pauseSnapshot.state != VGStreamingPlaybackControllerState.paused) {
          throw Exception(
            'Scenario 2 failed: HLS controller pause failed: pass=${pauseSnapshot.pass}, '
            'state=${pauseSnapshot.state.name}, reason=${pauseSnapshot.reason}',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = pauseSnapshot;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_PAUSE: DONE');

        // Exercise play
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_PLAY: START');
        final playSnapshot = await hlsController.play().timeout(
          _kControlTimeout,
        );
        if (!playSnapshot.pass ||
            playSnapshot.state == VGStreamingPlaybackControllerState.failed) {
          throw Exception(
            'Scenario 2 failed: HLS controller play resume failed: pass=${playSnapshot.pass}, '
            'state=${playSnapshot.state.name}, reason=${playSnapshot.reason}',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = playSnapshot;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_PLAY: DONE');

        // Exercise stop
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_STOP: START');
        final stopSnapshot = await hlsController.stop().timeout(
          _kControlTimeout,
        );
        if (!stopSnapshot.pass ||
            stopSnapshot.state != VGStreamingPlaybackControllerState.stopped) {
          throw Exception(
            'Scenario 2 failed: HLS controller stop failed: pass=${stopSnapshot.pass}, '
            'state=${stopSnapshot.state.name}, reason=${stopSnapshot.reason}',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = stopSnapshot;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_STOP: DONE');

        hlsStatusSummaryPass = true;
      } finally {
        // Dispose HLS controller
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_DISPOSE: START');
        if (!hlsController.isDisposed) {
          final disposeSnapshot = await hlsController.dispose().timeout(
            _kControlTimeout,
          );
          if (mounted) {
            setState(() {
              _currentSnapshot = disposeSnapshot;
            });
          }
          final disposedSummary =
              VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
                disposeSnapshot,
              );
          if (disposedSummary.hasSession ||
              !disposedSummary.isTerminal ||
              disposedSummary.isPlaying) {
            throw Exception(
              'Scenario 2 failed: Disposed HLS summary invariant failed: '
              'hasSession=${disposedSummary.hasSession}, isTerminal=${disposedSummary.isTerminal}, '
              'isPlaying=${disposedSummary.isPlaying}',
            );
          }
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_HLS_DISPOSE: DONE');
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 3: LL-HLS decision -> controller -> status summary
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_LL_HLS_DECISION: START',
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
        'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_LL_HLS_DECISION: DONE',
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

      // Create fresh controller for Scenario 3
      final llHlsController = VGStreamingPlaybackController();

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_LL_HLS_OPEN: START');
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
          'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_LL_HLS_OPEN: DONE (textureId=${llHlsOpenSnapshot.textureId})',
        );

        // Poll controller.refresh() until renderedFrames > 0 and effectiveDisplayWidth/Height > 0
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_LL_HLS_STATUS: START',
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
          'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_LL_HLS_STATUS: DONE (renderedFrames=$llHlsRenderedFrames, dims=${llHlsDisplayWidth}x$llHlsDisplayHeight)',
        );

        // Build status summary & assert invariants
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_LL_HLS_SUMMARY: START',
        );
        final llHlsSummary =
            VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
              finalLlHlsSnapshot,
            );
        _assertSummaryInvariants(
          llHlsSummary,
          scenarioName: 'Scenario 3 LL-HLS',
        );

        results['llHls'] = <String, dynamic>{
          'pass': true,
          'selectedKey': llHlsDecision.selectedKey,
          'textureId': finalLlHlsSnapshot.textureId,
          'renderedFrames': llHlsSession.renderedFrames,
          'effectiveDisplayWidth': llHlsDisplayWidth,
          'effectiveDisplayHeight': llHlsDisplayHeight,
          'state': finalLlHlsSnapshot.state.name,
          'summary': llHlsSummary.toJson(),
          'warnings': llHlsDecision.warnings,
          'raw': llHlsSession.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_LL_HLS_SUMMARY: DONE',
        );

        llHlsStatusSummaryPass = true;
      } finally {
        // Dispose LL-HLS controller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_LL_HLS_DISPOSE: START',
        );
        if (!llHlsController.isDisposed) {
          final disposeSnapshot = await llHlsController.dispose().timeout(
            _kControlTimeout,
          );
          if (mounted) {
            setState(() {
              _currentSnapshot = disposeSnapshot;
            });
          }
          final disposedSummary =
              VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
                disposeSnapshot,
              );
          if (disposedSummary.hasSession ||
              !disposedSummary.isTerminal ||
              disposedSummary.isPlaying) {
            throw Exception(
              'Scenario 3 failed: Disposed LL-HLS summary invariant failed: '
              'hasSession=${disposedSummary.hasSession}, isTerminal=${disposedSummary.isTerminal}, '
              'isPlaying=${disposedSummary.isPlaying}',
            );
          }
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_LL_HLS_DISPOSE: DONE',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 4: DASH typed deferral
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_DASH_DEFERRAL: START');
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
      print('IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_STEP_DASH_DEFERRAL: DONE');

      // Verify overall assertions
      results['advisoryOnlyVerified'] =
          report.advisoryOnly && dashReport.advisoryOnly;
      results['playbackMutationZeroVerified'] =
          !report.playbackMutation && !dashReport.playbackMutation;

      allPass =
          sourceSetPreflightPass &&
          hlsStatusSummaryPass &&
          llHlsStatusSummaryPass &&
          dashTypedDeferralPass;

      results['pass'] = allPass;
      results['sourceSetPreflightPass'] = sourceSetPreflightPass;
      results['hlsStatusSummaryPass'] = hlsStatusSummaryPass;
      results['llHlsStatusSummaryPass'] = llHlsStatusSummaryPass;
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
        'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_PHYSICAL_ERROR: $error\n$stack',
      );
      results['pass'] = false;
      results['error'] = error.toString();
      allPass = false;
    }

    // Emit terminal JSON line
    // ignore: avoid_print
    print(
      'IOS_STREAMING_PREFLIGHT_STATUS_SUMMARY_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
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
