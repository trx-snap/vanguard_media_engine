// Vanguard iOS True-DAG Phase 4C8O: Public streaming source selector all-up physical smoke.
//
// Route:
//   VGStreamingSourceSet ->
//   VGStreamingPreflightClient.evaluate(...) [actual iOS native preflight] ->
//   VGStreamingStartupPlanner.fromPreflight(...) ->
//   VGStreamingSourceSelector.select(...) [pure-Dart capability & preference resolution] ->
//   VGStreamingPlaybackClient.open(options) [actual AVPlayer native playback]
//
// Scenarios:
//   1. Compatible source-set preflight:
//      - Build VGStreamingSourceSet with [hls, ll_hls].
//      - sourceSet.toPreflightRequest(preferLowLatency: true, requestedNetworkProfile: auto).
//      - Evaluate via VGStreamingPreflightClient.evaluate timeout.
//      - Assert report.pass == true, advisoryOnly == true, playbackMutation == false, totalReports == 2, failedReports == 0, phase contains Phase4C8C, llHlsAvailable == true.
//      - Build VGStreamingStartupPlanner.fromPreflight(report); assert shouldProceed == true.
//   2. HLS fallback selector + physical playback:
//      - Fallback source set ordered [dash, hls].
//      - VGStreamingSourceSelector.select(preference: preferDash, clientCapabilities: appleAvPlayer()).
//      - Assert selected == true, selectedKey == 'hls', decision == 'source_selected', playbackOptions != null, warnings contains 'source_incompatible:dash:dash_not_supported', diagnostics clientType == 'apple_avplayer'.
//      - Open/play/getStatus poll renderedFrames > 0 & dims > 0 / pause / optional seek if duration > 2000 / stop / dispose in finally.
//   3. LL-HLS selector + physical playback:
//      - Source set [hls, ll_hls], plan from scenario 1.
//      - VGStreamingSourceSelector.select(preferredKeys: ['ll_hls'], preference: preferLowLatency, clientCapabilities: appleAvPlayer(preferLowLatency: true)).
//      - Assert selected == true, selectedKey == 'll_hls', source.requireLlHlsTags == true, decision == 'source_selected', playbackOptions != null.
//      - Open/play/getStatus poll renderedFrames > 0 & dims > 0 / stop / dispose in finally.
//   4. DASH typed deferral and selector capability block:
//      - Evaluate dashSourceSet.toPreflightRequest(requestedNetworkProfile: auto).
//      - Assert report.pass == false, failedReports >= 1, warnings contains 'unsupported_format_dash', advisoryOnly == true, playbackMutation == false, plan shouldProceed == false.
//      - Selector on dash-only with failed plan + preferDash + appleAvPlayer() -> assert selected == false, decision == 'startup_plan_blocked', warnings contains 'startup_plan_blocked', playbackOptions == null.
//      - Selector on dash-only with scenario 1 plan + preferDash + appleAvPlayer() + requirePlanToProceed: false -> assert selected == false, decision == 'no_compatible_source', warnings contains 'source_incompatible:dash:dash_not_supported' & 'no_compatible_source', playbackOptions == null.
//      - Zero playback mutation / never open playback for DASH.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kPhase = 'Phase4C8O';
const String _kTarget = 'ios_physical';
const String _kPassMarker =
    'IOS_STREAMING_SOURCE_SELECTOR_PUBLIC_API_PHYSICAL_PASS';
const String _kFailMarker =
    'IOS_STREAMING_SOURCE_SELECTOR_PUBLIC_API_PHYSICAL_FAIL';

const String _kHlsUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const String _kLlHlsUrl =
    'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8';
const String _kDashUrl =
    'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd';

const Duration _kPreflightTimeout = Duration(seconds: 25);
const Duration _kStatusDeadline = Duration(seconds: 20);

void main() {
  runApp(const IosStreamingSourceSelectorPublicApiPhysicalSmokeApp());
}

class IosStreamingSourceSelectorPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingSourceSelectorPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingSourceSelectorPublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingSourceSelectorPublicApiPhysicalSmokeAppState();
}

class _IosStreamingSourceSelectorPublicApiPhysicalSmokeAppState
    extends State<IosStreamingSourceSelectorPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();
  final VGStreamingPlaybackClient _playbackClient = VGStreamingPlaybackClient();

  int? _textureId;
  String _status =
      'Initializing iOS streaming source selector public API physical smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSourceSelectorSmoke();
    });
  }

  Future<void> _runSourceSelectorSmoke() async {
    await Future<void>.delayed(const Duration(seconds: 1));

    final Map<String, dynamic> summaryDiag = <String, dynamic>{};
    bool sourceSetPreflightPass = false;
    bool hlsFallbackSelectorPass = false;
    bool llHlsSelectorPass = false;
    bool dashTypedDeferralPass = false;
    String failureReason = '';

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 1: Compatible source-set preflight & startup plan synthesis
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_SELECTOR_STEP_SOURCE_SET_PREFLIGHT: START');
      if (mounted) {
        setState(() {
          _status = 'Step 1: Building compatible source set and preflighting…';
        });
      }

      final hlsDescriptor = VGStreamingSourceDescriptor(
        key: 'hls',
        uri: Uri.parse(_kHlsUrl),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: 1080,
        initialHeight: 1920,
        allowMediaPlaylist: true,
      );

      final llHlsDescriptor = VGStreamingSourceDescriptor(
        key: 'll_hls',
        uri: Uri.parse(_kLlHlsUrl),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: 1080,
        initialHeight: 1920,
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
      print('IOS_STREAMING_SOURCE_SELECTOR_STEP_SOURCE_SET_PREFLIGHT: DONE');

      if (!report.pass) {
        throw Exception(
          'Step 1 failed: report.pass is false (${report.diagnostics})',
        );
      }
      if (!report.advisoryOnly) {
        throw Exception('Step 1 failed: report.advisoryOnly is not true');
      }
      if (report.playbackMutation) {
        throw Exception('Step 1 failed: report.playbackMutation is true');
      }
      if (report.totalReports != 2) {
        throw Exception(
          'Step 1 failed: report.totalReports was ${report.totalReports} (expected 2)',
        );
      }
      if (report.failedReports != 0) {
        throw Exception(
          'Step 1 failed: report.failedReports was ${report.failedReports} (expected 0)',
        );
      }
      if (!report.phase.contains('Phase4C8C')) {
        throw Exception(
          'Step 1 failed: report.phase "${report.phase}" did not contain Phase4C8C',
        );
      }
      if (!report.llHlsAvailable) {
        throw Exception('Step 1 failed: report.llHlsAvailable is not true');
      }

      final plan = VGStreamingStartupPlanner.fromPreflight(report);
      if (!plan.shouldProceed) {
        throw Exception(
          'Step 1 failed: startup plan shouldProceed is false (reason: ${plan.reason})',
        );
      }

      sourceSetPreflightPass = true;
      summaryDiag['sourceSetPreflight'] = {
        'pass': true,
        'reportPass': report.pass,
        'advisoryOnly': report.advisoryOnly,
        'playbackMutation': report.playbackMutation,
        'totalReports': report.totalReports,
        'failedReports': report.failedReports,
        'phase': report.phase,
        'llHlsAvailable': report.llHlsAvailable,
        'advisoryDecision': report.advisoryDecision,
        'recommendedNetworkProfile': plan.recommendedNetworkProfile.toNative(),
        'shouldProceed': plan.shouldProceed,
      };

      // ═══════════════════════════════════════════════════════════════════════
      // Step 2: HLS Fallback selector + physical playback
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_SELECTOR_STEP_HLS_FALLBACK_SELECT: START');
      if (mounted) {
        setState(() {
          _status = 'Step 2: Selecting HLS fallback under appleAvPlayer…';
        });
      }

      final dashDescriptor = VGStreamingSourceDescriptor(
        key: 'dash',
        uri: Uri.parse(_kDashUrl),
        formatHint: VGStreamingFormatHint.dash,
        initialWidth: 1080,
        initialHeight: 1920,
      );

      final fallbackSourceSet = VGStreamingSourceSet(
        sources: [dashDescriptor, hlsDescriptor],
      );

      final hlsSelection = VGStreamingSourceSelector.select(
        VGStreamingSourceSelectionRequest(
          sourceSet: fallbackSourceSet,
          startupPlan: plan,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_SELECTOR_STEP_HLS_FALLBACK_SELECT: DONE');

      if (!hlsSelection.selected) {
        throw Exception(
          'Step 2 failed: HLS fallback selection failed: decision=${hlsSelection.decision}, warnings=${hlsSelection.warnings}',
        );
      }
      if (hlsSelection.selectedKey != 'hls') {
        throw Exception(
          'Step 2 failed: expected selectedKey "hls", got "${hlsSelection.selectedKey}"',
        );
      }
      if (hlsSelection.decision != 'source_selected') {
        throw Exception(
          'Step 2 failed: expected decision "source_selected", got "${hlsSelection.decision}"',
        );
      }
      if (hlsSelection.playbackOptions == null) {
        throw Exception('Step 2 failed: playbackOptions is null');
      }
      if (!hlsSelection.warnings.contains(
        'source_incompatible:dash:dash_not_supported',
      )) {
        throw Exception(
          'Step 2 failed: warnings did not contain source_incompatible:dash:dash_not_supported: ${hlsSelection.warnings}',
        );
      }
      if (hlsSelection.diagnostics['clientType'] != 'apple_avplayer') {
        throw Exception(
          'Step 2 failed: diagnostics clientType was ${hlsSelection.diagnostics['clientType']} (expected apple_avplayer)',
        );
      }

      VGStreamingPlaybackSession? hlsSession;
      Map<String, dynamic> hlsPlaybackDiag = {};
      try {
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_SELECTOR_STEP_HLS_OPEN: START');
        if (mounted) {
          setState(() {
            _status = 'Step 2: Opening HLS fallback playback session…';
          });
        }

        hlsSession = await _playbackClient.open(hlsSelection.playbackOptions!);
        if (!hlsSession.pass || hlsSession.textureId < 0) {
          throw Exception(
            'Step 2 failed: HLS open returned pass=${hlsSession.pass}, textureId=${hlsSession.textureId}, raw=${hlsSession.raw}',
          );
        }

        if (mounted) {
          setState(() {
            _textureId = hlsSession!.textureId;
            _status =
                'Step 2: HLS streaming active (textureId=${hlsSession.textureId}), waiting for frames…';
          });
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_SOURCE_SELECTOR_STEP_HLS_OPEN: DONE (textureId=${hlsSession.textureId})',
        );

        hlsSession = await _playbackClient.play(hlsSession);

        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_SELECTOR_STEP_HLS_STATUS: START');
        final hlsDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackSession hlsStatus = hlsSession;
        while (DateTime.now().isBefore(hlsDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          hlsStatus = await _playbackClient.getStatus(hlsSession);
          if (hlsStatus.renderedFrames > 0 &&
              hlsStatus.effectiveDisplayWidth > 0 &&
              hlsStatus.effectiveDisplayHeight > 0) {
            break;
          }
        }

        if (hlsStatus.renderedFrames <= 0 ||
            hlsStatus.effectiveDisplayWidth <= 0 ||
            hlsStatus.effectiveDisplayHeight <= 0) {
          throw Exception(
            'Step 2 failed: HLS rendered frames/dimensions not positive within deadline: '
            'frames=${hlsStatus.renderedFrames}, dims=${hlsStatus.effectiveDisplayWidth}x${hlsStatus.effectiveDisplayHeight}, '
            'state=${hlsStatus.state.name}',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_SOURCE_SELECTOR_STEP_HLS_STATUS: DONE (frames=${hlsStatus.renderedFrames}, dims=${hlsStatus.effectiveDisplayWidth}x${hlsStatus.effectiveDisplayHeight})',
        );

        // Pause
        hlsSession = await _playbackClient.pause(hlsStatus);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // Optional seek if durationMs > 2000
        if (hlsStatus.durationMs > 2000) {
          final seekTargetMs = (hlsStatus.durationMs ~/ 4).clamp(1000, 8000);
          hlsSession = await _playbackClient.seek(hlsSession, seekTargetMs);
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }

        // Stop
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_SELECTOR_STEP_HLS_STOP: START');
        hlsSession = await _playbackClient.stop(hlsSession);
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_SELECTOR_STEP_HLS_STOP: DONE');

        hlsPlaybackDiag = {
          'pass': true,
          'selectedKey': hlsSelection.selectedKey,
          'decision': hlsSelection.decision,
          'warnings': hlsSelection.warnings,
          'textureId': hlsStatus.textureId,
          'renderedFrames': hlsStatus.renderedFrames,
          'effectiveDisplayWidth': hlsStatus.effectiveDisplayWidth,
          'effectiveDisplayHeight': hlsStatus.effectiveDisplayHeight,
          'durationMs': hlsStatus.durationMs,
          'state': hlsStatus.state.name,
          'format': hlsStatus.format.toNative(),
        };
        hlsFallbackSelectorPass = true;
      } finally {
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_SELECTOR_STEP_HLS_DISPOSE: START');
        if (hlsSession != null && hlsSession.textureId >= 0) {
          try {
            await _playbackClient.dispose(hlsSession);
          } catch (e) {
            // ignore: avoid_print
            print('HLS dispose error: $e');
          }
        }
        if (mounted) {
          setState(() {
            _textureId = null;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_SELECTOR_STEP_HLS_DISPOSE: DONE');
      }

      summaryDiag['hlsFallback'] = hlsPlaybackDiag;

      // ═══════════════════════════════════════════════════════════════════════
      // Step 3: LL-HLS Selector + physical playback
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_SELECTOR_STEP_LL_HLS_SELECT: START');
      if (mounted) {
        setState(() {
          _status = 'Step 3: Selecting LL-HLS descriptor…';
        });
      }

      final llHlsSelection = VGStreamingSourceSelector.select(
        VGStreamingSourceSelectionRequest(
          sourceSet: compatibleSourceSet,
          startupPlan: plan,
          preferredKeys: const ['ll_hls'],
          preference: VGStreamingSourceSelectionPreference.preferLowLatency,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(
                preferLowLatency: true,
              ),
        ),
      );

      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_SELECTOR_STEP_LL_HLS_SELECT: DONE');

      if (!llHlsSelection.selected) {
        throw Exception(
          'Step 3 failed: LL-HLS selection failed: decision=${llHlsSelection.decision}, warnings=${llHlsSelection.warnings}',
        );
      }
      if (llHlsSelection.selectedKey != 'll_hls') {
        throw Exception(
          'Step 3 failed: expected selectedKey "ll_hls", got "${llHlsSelection.selectedKey}"',
        );
      }
      if (llHlsSelection.source?.requireLlHlsTags != true) {
        throw Exception(
          'Step 3 failed: expected requireLlHlsTags == true on selected source',
        );
      }
      if (llHlsSelection.decision != 'source_selected') {
        throw Exception(
          'Step 3 failed: expected decision "source_selected", got "${llHlsSelection.decision}"',
        );
      }
      if (llHlsSelection.playbackOptions == null) {
        throw Exception('Step 3 failed: playbackOptions is null');
      }

      VGStreamingPlaybackSession? llHlsSession;
      Map<String, dynamic> llHlsPlaybackDiag = {};
      try {
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_SELECTOR_STEP_LL_HLS_OPEN: START');
        if (mounted) {
          setState(() {
            _status = 'Step 3: Opening LL-HLS playback session…';
          });
        }

        llHlsSession = await _playbackClient.open(
          llHlsSelection.playbackOptions!,
        );
        if (!llHlsSession.pass || llHlsSession.textureId < 0) {
          throw Exception(
            'Step 3 failed: LL-HLS open returned pass=${llHlsSession.pass}, textureId=${llHlsSession.textureId}, raw=${llHlsSession.raw}',
          );
        }

        if (mounted) {
          setState(() {
            _textureId = llHlsSession!.textureId;
            _status =
                'Step 3: LL-HLS streaming active (textureId=${llHlsSession.textureId}), waiting for frames…';
          });
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_SOURCE_SELECTOR_STEP_LL_HLS_OPEN: DONE (textureId=${llHlsSession.textureId})',
        );

        llHlsSession = await _playbackClient.play(llHlsSession);

        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_SELECTOR_STEP_LL_HLS_STATUS: START');
        final llHlsDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackSession llHlsStatus = llHlsSession;
        while (DateTime.now().isBefore(llHlsDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          llHlsStatus = await _playbackClient.getStatus(llHlsSession);
          if (llHlsStatus.renderedFrames > 0 &&
              llHlsStatus.effectiveDisplayWidth > 0 &&
              llHlsStatus.effectiveDisplayHeight > 0) {
            break;
          }
        }

        if (llHlsStatus.renderedFrames <= 0 ||
            llHlsStatus.effectiveDisplayWidth <= 0 ||
            llHlsStatus.effectiveDisplayHeight <= 0) {
          throw Exception(
            'Step 3 failed: LL-HLS rendered frames/dimensions not positive within deadline: '
            'frames=${llHlsStatus.renderedFrames}, dims=${llHlsStatus.effectiveDisplayWidth}x${llHlsStatus.effectiveDisplayHeight}, '
            'state=${llHlsStatus.state.name}',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_SOURCE_SELECTOR_STEP_LL_HLS_STATUS: DONE (frames=${llHlsStatus.renderedFrames}, dims=${llHlsStatus.effectiveDisplayWidth}x${llHlsStatus.effectiveDisplayHeight})',
        );

        // Stop
        llHlsSession = await _playbackClient.stop(llHlsSession);

        llHlsPlaybackDiag = {
          'pass': true,
          'selectedKey': llHlsSelection.selectedKey,
          'decision': llHlsSelection.decision,
          'textureId': llHlsStatus.textureId,
          'renderedFrames': llHlsStatus.renderedFrames,
          'effectiveDisplayWidth': llHlsStatus.effectiveDisplayWidth,
          'effectiveDisplayHeight': llHlsStatus.effectiveDisplayHeight,
          'durationMs': llHlsStatus.durationMs,
          'state': llHlsStatus.state.name,
          'format': llHlsStatus.format.toNative(),
        };
        llHlsSelectorPass = true;
      } finally {
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_SELECTOR_STEP_LL_HLS_DISPOSE: START');
        if (llHlsSession != null && llHlsSession.textureId >= 0) {
          try {
            await _playbackClient.dispose(llHlsSession);
          } catch (e) {
            // ignore: avoid_print
            print('LL-HLS dispose error: $e');
          }
        }
        if (mounted) {
          setState(() {
            _textureId = null;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_SELECTOR_STEP_LL_HLS_DISPOSE: DONE');
      }

      summaryDiag['llHls'] = llHlsPlaybackDiag;

      // ═══════════════════════════════════════════════════════════════════════
      // Step 4: DASH typed deferral and selector capability block
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_SELECTOR_STEP_DASH_PREFLIGHT: START');
      if (mounted) {
        setState(() {
          _status =
              'Step 4: Evaluating DASH typed deferral and selector block…';
        });
      }

      final dashSourceSet = VGStreamingSourceSet(sources: [dashDescriptor]);

      final dashPreflightRequest = dashSourceSet.toPreflightRequest(
        requestedNetworkProfile: VGStreamingNetworkProfile.auto,
      );

      final dashReport = await _preflightClient
          .evaluate(dashPreflightRequest)
          .timeout(_kPreflightTimeout);

      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_SELECTOR_STEP_DASH_PREFLIGHT: DONE');

      if (dashReport.pass) {
        throw Exception(
          'Step 4 failed: DASH report.pass was true (expected false)',
        );
      }
      if (dashReport.failedReports < 1) {
        throw Exception(
          'Step 4 failed: DASH failedReports was ${dashReport.failedReports} (expected >= 1)',
        );
      }
      if (!dashReport.warnings.contains('unsupported_format_dash')) {
        throw Exception(
          'Step 4 failed: DASH warnings did not contain unsupported_format_dash: ${dashReport.warnings}',
        );
      }
      if (!dashReport.advisoryOnly) {
        throw Exception('Step 4 failed: DASH advisoryOnly was not true');
      }
      if (dashReport.playbackMutation) {
        throw Exception('Step 4 failed: DASH playbackMutation was true');
      }

      final dashPlan = VGStreamingStartupPlanner.fromPreflight(dashReport);
      if (dashPlan.shouldProceed) {
        throw Exception(
          'Step 4 failed: DASH startup plan shouldProceed was true (expected false)',
        );
      }

      // 4b. Selector with failed DASH startup plan
      final dashFailedPlanSelection = VGStreamingSourceSelector.select(
        VGStreamingSourceSelectionRequest(
          sourceSet: dashSourceSet,
          startupPlan: dashPlan,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      if (dashFailedPlanSelection.selected) {
        throw Exception(
          'Step 4 failed: dashFailedPlanSelection.selected was true (expected false)',
        );
      }
      if (dashFailedPlanSelection.decision != 'startup_plan_blocked') {
        throw Exception(
          'Step 4 failed: expected decision "startup_plan_blocked", got "${dashFailedPlanSelection.decision}"',
        );
      }
      if (!dashFailedPlanSelection.warnings.contains('startup_plan_blocked')) {
        throw Exception(
          'Step 4 failed: warnings did not contain startup_plan_blocked: ${dashFailedPlanSelection.warnings}',
        );
      }
      if (dashFailedPlanSelection.playbackOptions != null) {
        throw Exception(
          'Step 4 failed: dashFailedPlanSelection.playbackOptions was non-null',
        );
      }

      // 4c. Selector with successful plan but requirePlanToProceed: false and appleAvPlayer capability block
      final dashCapabilityBlockSelection = VGStreamingSourceSelector.select(
        VGStreamingSourceSelectionRequest(
          sourceSet: dashSourceSet,
          startupPlan: plan,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          requirePlanToProceed: false,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      if (dashCapabilityBlockSelection.selected) {
        throw Exception(
          'Step 4 failed: dashCapabilityBlockSelection.selected was true (expected false)',
        );
      }
      if (dashCapabilityBlockSelection.decision != 'no_compatible_source') {
        throw Exception(
          'Step 4 failed: expected decision "no_compatible_source", got "${dashCapabilityBlockSelection.decision}"',
        );
      }
      if (!dashCapabilityBlockSelection.warnings.contains(
            'source_incompatible:dash:dash_not_supported',
          ) ||
          !dashCapabilityBlockSelection.warnings.contains(
            'no_compatible_source',
          )) {
        throw Exception(
          'Step 4 failed: warnings did not contain expected compatibility warnings: ${dashCapabilityBlockSelection.warnings}',
        );
      }
      if (dashCapabilityBlockSelection.playbackOptions != null) {
        throw Exception(
          'Step 4 failed: dashCapabilityBlockSelection.playbackOptions was non-null',
        );
      }

      dashTypedDeferralPass = true;
      summaryDiag['dash'] = {
        'pass': true,
        'reportPass': dashReport.pass,
        'failedReports': dashReport.failedReports,
        'warnings': dashReport.warnings,
        'advisoryOnly': dashReport.advisoryOnly,
        'playbackMutation': dashReport.playbackMutation,
        'shouldProceed': dashPlan.shouldProceed,
        'failedPlanDecision': dashFailedPlanSelection.decision,
        'failedPlanWarnings': dashFailedPlanSelection.warnings,
        'capabilityBlockDecision': dashCapabilityBlockSelection.decision,
        'capabilityBlockWarnings': dashCapabilityBlockSelection.warnings,
      };

      // ───────────────────────────────────────────────────────────────────────
      // Summary & Terminal Markers
      // ───────────────────────────────────────────────────────────────────────
      final overallPass =
          sourceSetPreflightPass &&
          hlsFallbackSelectorPass &&
          llHlsSelectorPass &&
          dashTypedDeferralPass;

      final payload = {
        'phase': _kPhase,
        'target': _kTarget,
        'pass': overallPass,
        'sourceSetPreflightPass': sourceSetPreflightPass,
        'hlsFallbackSelectorPass': hlsFallbackSelectorPass,
        'llHlsSelectorPass': llHlsSelectorPass,
        'dashTypedDeferralPass': dashTypedDeferralPass,
        'advisoryOnlyVerified': true,
        'playbackMutationZeroVerified': true,
        'selectedKeys': [hlsSelection.selectedKey, llHlsSelection.selectedKey],
        'warnings': [
          ...hlsSelection.warnings,
          ...llHlsSelection.warnings,
          ...dashReport.warnings,
          ...dashFailedPlanSelection.warnings,
          ...dashCapabilityBlockSelection.warnings,
        ],
        'scenarios': summaryDiag,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_SOURCE_SELECTOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(payload)}',
      );

      if (mounted) {
        setState(() {
          _status =
              'PASS: All Phase 4C8O streaming source selector physical scenarios verified.';
        });
      }

      // ignore: avoid_print
      print(_kPassMarker);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e, st) {
      failureReason = '$e\n$st';
      // ignore: avoid_print
      print('Scenario failure: $failureReason');
      final failPayload = {
        'phase': _kPhase,
        'target': _kTarget,
        'pass': false,
        'sourceSetPreflightPass': sourceSetPreflightPass,
        'hlsFallbackSelectorPass': hlsFallbackSelectorPass,
        'llHlsSelectorPass': llHlsSelectorPass,
        'dashTypedDeferralPass': dashTypedDeferralPass,
        'error': e.toString(),
        'scenarios': summaryDiag,
      };
      // ignore: avoid_print
      print(
        'IOS_STREAMING_SOURCE_SELECTOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(failPayload)}',
      );
      // ignore: avoid_print
      print(_kFailMarker);
      if (mounted) {
        setState(() {
          _status = 'FAIL: $e';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
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
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.grey[900],
                width: double.infinity,
                child: const Text(
                  'iOS Streaming Source Selector Public API Smoke ($_kPhase)',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              if (_textureId != null)
                SizedBox(
                  width: 320,
                  height: 180,
                  child: Texture(textureId: _textureId!),
                )
              else
                Container(
                  width: 320,
                  height: 180,
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: const Text(
                    'No Active Texture',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
