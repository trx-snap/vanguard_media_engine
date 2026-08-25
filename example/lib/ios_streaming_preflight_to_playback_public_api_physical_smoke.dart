// Vanguard iOS Phase 4C8M: Public streaming preflight-to-playback all-up physical smoke test.
//
// Route:
//   VGStreamingPreflightClient.evaluate(...) [actual iOS native preflight] ->
//   VGStreamingStartupPlanner.fromPreflight(...) ->
//   VGStreamingPlaybackDecisionPlanner.plan(...) ->
//   VGStreamingPlaybackController.open(...) [actual AVPlayer native playback] +
//   VGStreamingPlaybackTextureView(...) [Flutter texture rendering]
//
// Scenarios:
//   1. HLS fallback all-up:
//      - Source set: DASH then HLS (DASH formatHint=dash, HLS formatHint=hls + allowMediaPlaylist=true).
//      - Actual evaluate against HLS only.
//      - Assert preflight report pass=true, advisoryOnly=true, playbackMutation=false, failedReports=0,
//        phase contains 'Phase4C8C'.
//      - Plan decision with preference=preferDash, clientCapabilities=appleAvPlayer().
//      - Assert decision canOpenPlayback=true, decision='playback_ready', selectedKey='hls',
//        warning contains 'source_incompatible:dash:dash_not_supported'.
//      - Open fresh VGStreamingPlaybackController with startPlayback=true, poll refresh until
//        renderedFrames > 0 and dimensions > 0, exercise pause/play/stop, and dispose.
//   2. LL-HLS all-up:
//      - Descriptor: LL-HLS with requireLlHlsTags=true.
//      - Actual evaluate against LL-HLS with preferLowLatency=true.
//      - Assert report pass=true, advisoryOnly=true, playbackMutation=false, llHlsAvailable=true,
//        advisoryDecision='advise_low_latency', startup plan shouldProceed=true.
//      - Plan decision with preferredKeys=['ll_hls'], preference=preferLowLatency,
//        clientCapabilities=appleAvPlayer(preferLowLatency: true).
//      - Assert decision canOpenPlayback=true, selectedKey='ll_hls', selected source requireLlHlsTags=true.
//      - Open fresh VGStreamingPlaybackController, poll renderedFrames > 0 and dimensions > 0, dispose.
//   3. DASH typed deferral:
//      - Actual evaluate against DASH only.
//      - Assert report pass=false, failedReports >= 1, warnings contains 'unsupported_format_dash',
//        advisoryOnly=true, playbackMutation=false.
//      - Assert startup plan shouldProceed=false and decision canOpenPlayback=false if planned DASH-only.
//      - Do not open playback for DASH.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kPhase = 'Phase4C8M';
const String _kTarget = 'ios_physical';
const String _kPassMarker =
    'IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_PUBLIC_API_PHYSICAL_PASS';
const String _kFailMarker =
    'IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_PUBLIC_API_PHYSICAL_FAIL';

const String _kDashUrl =
    'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd';
const String _kHlsUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const String _kLlHlsUrl =
    'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8';

const Duration _kPreflightTimeout = Duration(seconds: 25);
const Duration _kOperationTimeout = Duration(seconds: 25);
const Duration _kControlTimeout = Duration(seconds: 5);
const Duration _kStatusDeadline = Duration(seconds: 20);

void main() {
  runApp(const IosStreamingPreflightToPlaybackPublicApiPhysicalSmokeApp());
}

class IosStreamingPreflightToPlaybackPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingPreflightToPlaybackPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingPreflightToPlaybackPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingPreflightToPlaybackPublicApiPhysicalSmokeAppState();
}

class _IosStreamingPreflightToPlaybackPublicApiPhysicalSmokeAppState
    extends State<IosStreamingPreflightToPlaybackPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();
  VGStreamingPlaybackControllerSnapshot _currentSnapshot =
      const VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.idle,
        pass: true,
        reason: 'idle',
      );
  String _status =
      'Initializing iOS streaming preflight-to-playback public API physical smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runAllUpSmoke();
    });
  }

  Future<void> _runAllUpSmoke() async {
    await Future<void>.delayed(const Duration(seconds: 1));

    final Map<String, dynamic> summaryDiag = <String, dynamic>{};
    bool hlsFallbackPass = false;
    bool llHlsPass = false;
    bool dashTypedDeferralPass = false;
    String failureReason = '';

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 1: HLS fallback all-up (DASH+HLS -> Preflight HLS -> Plan -> Play)
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_PREFLIGHT: START');
      if (mounted) {
        setState(() {
          _status = 'Scenario 1: Evaluating HLS preflight...';
        });
      }

      final hlsSourceDescriptor = VGStreamingSourceDescriptor(
        key: 'hls',
        uri: Uri.parse(_kHlsUrl),
        initialWidth: 1080,
        initialHeight: 1920,
        formatHint: VGStreamingFormatHint.hls,
        allowMediaPlaylist: true,
      );

      final dashSourceDescriptor = VGStreamingSourceDescriptor(
        key: 'dash',
        uri: Uri.parse(_kDashUrl),
        initialWidth: 1080,
        initialHeight: 1920,
        formatHint: VGStreamingFormatHint.dash,
      );

      final fallbackSourceSet = VGStreamingSourceSet(
        sources: [dashSourceDescriptor, hlsSourceDescriptor],
      );

      final hlsManifestSpec = VGStreamingManifestSpec(
        key: hlsSourceDescriptor.key,
        uri: hlsSourceDescriptor.uri,
        formatHint: hlsSourceDescriptor.formatHint,
        allowMediaPlaylist: true,
      );

      final hlsPreflightRequest = VGStreamingPreflightRequest(
        manifests: [hlsManifestSpec],
        requestedNetworkProfile: VGStreamingNetworkProfile.auto,
      );

      final hlsReport = await _preflightClient
          .evaluate(hlsPreflightRequest)
          .timeout(_kPreflightTimeout);

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_PREFLIGHT: DONE');

      final hlsStartupPlan = VGStreamingStartupPlanner.fromPreflight(hlsReport);

      if (!hlsReport.pass) {
        throw Exception('Scenario 1: HLS preflight report.pass was false');
      }
      if (!hlsReport.advisoryOnly) {
        throw Exception('Scenario 1: HLS preflight advisoryOnly was not true');
      }
      if (hlsReport.playbackMutation) {
        throw Exception('Scenario 1: HLS preflight playbackMutation was true');
      }
      if (hlsReport.failedReports != 0) {
        throw Exception(
          'Scenario 1: HLS preflight failedReports was ${hlsReport.failedReports} (expected 0)',
        );
      }
      if (!hlsReport.phase.contains('Phase4C8C')) {
        throw Exception(
          'Scenario 1: HLS preflight phase "${hlsReport.phase}" did not contain Phase4C8C',
        );
      }
      if (!hlsStartupPlan.shouldProceed) {
        throw Exception('Scenario 1: HLS startup plan shouldProceed was false');
      }

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_PLAN: START');
      if (mounted) {
        setState(() {
          _status = 'Scenario 1: Planning decision with preferDash fallback...';
        });
      }

      final hlsDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: fallbackSourceSet,
          preflightReport: hlsReport,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_PLAN: DONE');

      if (!hlsDecision.canOpenPlayback ||
          hlsDecision.decision != 'playback_ready' ||
          hlsDecision.selectedKey != 'hls' ||
          !hlsDecision.warnings.contains(
            'source_incompatible:dash:dash_not_supported',
          )) {
        throw Exception(
          'Scenario 1: HLS decision failed invariants: canOpenPlayback=${hlsDecision.canOpenPlayback}, '
          'decision=${hlsDecision.decision}, selectedKey=${hlsDecision.selectedKey}, '
          'warnings=${hlsDecision.warnings}',
        );
      }

      final hlsController = VGStreamingPlaybackController();

      Map<String, dynamic> hlsPlaybackDiag = {};
      try {
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_OPEN: START');
        if (mounted) {
          setState(() {
            _status = 'Scenario 1: Opening HLS controller...';
          });
        }

        final openSnapshot = await hlsController
            .open(hlsDecision, startPlayback: true)
            .timeout(_kOperationTimeout);

        if (!openSnapshot.pass || openSnapshot.textureId == null) {
          throw Exception(
            'Scenario 1: HLS controller open failed: pass=${openSnapshot.pass}, '
            'textureId=${openSnapshot.textureId}, reason=${openSnapshot.reason}, '
            'lastError=${openSnapshot.lastError}',
          );
        }

        if (mounted) {
          setState(() {
            _currentSnapshot = openSnapshot;
            _status =
                'Scenario 1: HLS streaming active (textureId=${openSnapshot.textureId})...';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_OPEN: DONE (textureId=${openSnapshot.textureId})',
        );

        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_STATUS: START');
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
              session.effectiveDisplayHeight > 0) {
            finalHlsSnapshot = refreshed;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }

        if (finalHlsSnapshot == null ||
            finalHlsSnapshot.session == null ||
            finalHlsSnapshot.session!.renderedFrames <= 0) {
          throw Exception(
            'Scenario 1: HLS failed to render frames within deadline. Last snapshot: '
            'renderedFrames=${_currentSnapshot.session?.renderedFrames}, '
            'dimensions=${_currentSnapshot.session?.effectiveDisplayWidth}x${_currentSnapshot.session?.effectiveDisplayHeight}, '
            'state=${_currentSnapshot.state.name}',
          );
        }

        final hlsSession = finalHlsSnapshot.session!;
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_STATUS: DONE (frames=${hlsSession.renderedFrames}, size=${hlsSession.effectiveDisplayWidth}x${hlsSession.effectiveDisplayHeight})',
        );

        // Exercise pause/play/stop
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_PAUSE: START');
        final pauseSnapshot = await hlsController.pause().timeout(
          _kControlTimeout,
        );
        if (!pauseSnapshot.pass ||
            pauseSnapshot.state != VGStreamingPlaybackControllerState.paused) {
          throw Exception(
            'Scenario 1: Pause failed (pass=${pauseSnapshot.pass}, state=${pauseSnapshot.state.name})',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = pauseSnapshot;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_PAUSE: DONE');

        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_PLAY: START');
        final playSnapshot = await hlsController.play().timeout(
          _kControlTimeout,
        );
        if (!playSnapshot.pass ||
            playSnapshot.state == VGStreamingPlaybackControllerState.failed) {
          throw Exception(
            'Scenario 1: Play/resume failed (pass=${playSnapshot.pass}, state=${playSnapshot.state.name})',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = playSnapshot;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_PLAY: DONE');

        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_STOP: START');
        final stopSnapshot = await hlsController.stop().timeout(
          _kControlTimeout,
        );
        if (!stopSnapshot.pass ||
            stopSnapshot.state != VGStreamingPlaybackControllerState.stopped) {
          throw Exception(
            'Scenario 1: Stop failed (pass=${stopSnapshot.pass}, state=${stopSnapshot.state.name})',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = stopSnapshot;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_STOP: DONE');

        hlsPlaybackDiag = {
          'renderedFrames': hlsSession.renderedFrames,
          'effectiveDisplayWidth': hlsSession.effectiveDisplayWidth,
          'effectiveDisplayHeight': hlsSession.effectiveDisplayHeight,
          'state': finalHlsSnapshot.state.name,
          'textureId': finalHlsSnapshot.textureId,
        };
      } finally {
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_DISPOSE: START');
        if (!hlsController.isDisposed) {
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
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_HLS_DISPOSE: DONE');
      }

      summaryDiag['scenario1_hls'] = {
        'pass': true,
        'preflightPass': hlsReport.pass,
        'advisoryOnly': hlsReport.advisoryOnly,
        'playbackMutation': hlsReport.playbackMutation,
        'failedReports': hlsReport.failedReports,
        'preflightPhase': hlsReport.phase,
        'selectedKey': hlsDecision.selectedKey,
        'decision': hlsDecision.decision,
        'warnings': hlsDecision.warnings,
        'playback': hlsPlaybackDiag,
      };
      hlsFallbackPass = true;

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 2: LL-HLS all-up (Preflight -> Plan -> Play)
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_LL_HLS_PREFLIGHT: START');
      if (mounted) {
        setState(() {
          _status = 'Scenario 2: Evaluating LL-HLS preflight...';
        });
      }

      final llHlsSourceDescriptor = VGStreamingSourceDescriptor(
        key: 'll_hls',
        uri: Uri.parse(_kLlHlsUrl),
        initialWidth: 1080,
        initialHeight: 1920,
        formatHint: VGStreamingFormatHint.hls,
        requireLlHlsTags: true,
      );

      final llHlsSourceSet = VGStreamingSourceSet(
        sources: [llHlsSourceDescriptor],
      );

      final llHlsManifestSpec = VGStreamingManifestSpec(
        key: llHlsSourceDescriptor.key,
        uri: llHlsSourceDescriptor.uri,
        formatHint: llHlsSourceDescriptor.formatHint,
        requireLlHlsTags: true,
      );

      final llHlsPreflightRequest = VGStreamingPreflightRequest(
        manifests: [llHlsManifestSpec],
        requestedNetworkProfile: VGStreamingNetworkProfile.lowLatency,
        preferLowLatency: true,
      );

      final llHlsReport = await _preflightClient
          .evaluate(llHlsPreflightRequest)
          .timeout(_kPreflightTimeout);

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_LL_HLS_PREFLIGHT: DONE');

      final llHlsStartupPlan = VGStreamingStartupPlanner.fromPreflight(
        llHlsReport,
      );

      if (!llHlsReport.pass) {
        throw Exception('Scenario 2: LL-HLS preflight report.pass was false');
      }
      if (!llHlsReport.advisoryOnly) {
        throw Exception(
          'Scenario 2: LL-HLS preflight advisoryOnly was not true',
        );
      }
      if (llHlsReport.playbackMutation) {
        throw Exception(
          'Scenario 2: LL-HLS preflight playbackMutation was true',
        );
      }
      if (!llHlsReport.llHlsAvailable) {
        throw Exception(
          'Scenario 2: LL-HLS preflight llHlsAvailable was not true',
        );
      }
      if (llHlsReport.advisoryDecision != 'advise_low_latency') {
        throw Exception(
          'Scenario 2: LL-HLS advisoryDecision was "${llHlsReport.advisoryDecision}" (expected advise_low_latency)',
        );
      }
      if (!llHlsStartupPlan.shouldProceed) {
        throw Exception(
          'Scenario 2: LL-HLS startup plan shouldProceed was false',
        );
      }

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_LL_HLS_PLAN: START');
      if (mounted) {
        setState(() {
          _status = 'Scenario 2: Planning decision for LL-HLS...';
        });
      }

      final llHlsDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: llHlsSourceSet,
          preflightReport: llHlsReport,
          preferredKeys: const ['ll_hls'],
          preference: VGStreamingSourceSelectionPreference.preferLowLatency,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(
                preferLowLatency: true,
              ),
        ),
      );

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_LL_HLS_PLAN: DONE');

      if (!llHlsDecision.canOpenPlayback ||
          llHlsDecision.selectedKey != 'll_hls' ||
          llHlsDecision.selectedSource?.requireLlHlsTags != true) {
        throw Exception(
          'Scenario 2: LL-HLS decision failed invariants: canOpenPlayback=${llHlsDecision.canOpenPlayback}, '
          'selectedKey=${llHlsDecision.selectedKey}, '
          'requireLlHlsTags=${llHlsDecision.selectedSource?.requireLlHlsTags}',
        );
      }

      final llHlsController = VGStreamingPlaybackController();

      Map<String, dynamic> llHlsPlaybackDiag = {};
      try {
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_LL_HLS_OPEN: START');
        if (mounted) {
          setState(() {
            _status = 'Scenario 2: Opening LL-HLS controller...';
          });
        }

        final openSnapshot = await llHlsController
            .open(llHlsDecision, startPlayback: true)
            .timeout(_kOperationTimeout);

        if (!openSnapshot.pass || openSnapshot.textureId == null) {
          throw Exception(
            'Scenario 2: LL-HLS controller open failed: pass=${openSnapshot.pass}, '
            'textureId=${openSnapshot.textureId}, reason=${openSnapshot.reason}, '
            'lastError=${openSnapshot.lastError}',
          );
        }

        if (mounted) {
          setState(() {
            _currentSnapshot = openSnapshot;
            _status =
                'Scenario 2: LL-HLS streaming active (textureId=${openSnapshot.textureId})...';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_LL_HLS_OPEN: DONE (textureId=${openSnapshot.textureId})',
        );

        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_LL_HLS_STATUS: START');
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
              session.effectiveDisplayHeight > 0) {
            finalLlHlsSnapshot = refreshed;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }

        if (finalLlHlsSnapshot == null ||
            finalLlHlsSnapshot.session == null ||
            finalLlHlsSnapshot.session!.renderedFrames <= 0) {
          throw Exception(
            'Scenario 2: LL-HLS failed to render frames within deadline. Last snapshot: '
            'renderedFrames=${_currentSnapshot.session?.renderedFrames}, '
            'dimensions=${_currentSnapshot.session?.effectiveDisplayWidth}x${_currentSnapshot.session?.effectiveDisplayHeight}, '
            'state=${_currentSnapshot.state.name}',
          );
        }

        final llHlsSession = finalLlHlsSnapshot.session!;
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_LL_HLS_STATUS: DONE (frames=${llHlsSession.renderedFrames}, size=${llHlsSession.effectiveDisplayWidth}x${llHlsSession.effectiveDisplayHeight})',
        );

        llHlsPlaybackDiag = {
          'renderedFrames': llHlsSession.renderedFrames,
          'effectiveDisplayWidth': llHlsSession.effectiveDisplayWidth,
          'effectiveDisplayHeight': llHlsSession.effectiveDisplayHeight,
          'state': finalLlHlsSnapshot.state.name,
          'textureId': finalLlHlsSnapshot.textureId,
        };
      } finally {
        // ignore: avoid_print
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_LL_HLS_DISPOSE: START');
        if (!llHlsController.isDisposed) {
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
        print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_LL_HLS_DISPOSE: DONE');
      }

      summaryDiag['scenario2_ll_hls'] = {
        'pass': true,
        'preflightPass': llHlsReport.pass,
        'advisoryOnly': llHlsReport.advisoryOnly,
        'playbackMutation': llHlsReport.playbackMutation,
        'llHlsAvailable': llHlsReport.llHlsAvailable,
        'advisoryDecision': llHlsReport.advisoryDecision,
        'selectedKey': llHlsDecision.selectedKey,
        'decision': llHlsDecision.decision,
        'playback': llHlsPlaybackDiag,
      };
      llHlsPass = true;

      // ═══════════════════════════════════════════════════════════════════════
      // Scenario 3: DASH typed deferral (Preflight fails -> startup blocks -> no playback)
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_DASH_PREFLIGHT: START');
      if (mounted) {
        setState(() {
          _status = 'Scenario 3: Evaluating DASH preflight typed deferral...';
        });
      }

      final dashManifestSpec = VGStreamingManifestSpec(
        key: dashSourceDescriptor.key,
        uri: dashSourceDescriptor.uri,
        formatHint: dashSourceDescriptor.formatHint,
      );

      final dashPreflightRequest = VGStreamingPreflightRequest(
        manifests: [dashManifestSpec],
        requestedNetworkProfile: VGStreamingNetworkProfile.auto,
      );

      final dashReport = await _preflightClient
          .evaluate(dashPreflightRequest)
          .timeout(_kPreflightTimeout);

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_STEP_DASH_PREFLIGHT: DONE');

      final dashStartupPlan = VGStreamingStartupPlanner.fromPreflight(
        dashReport,
      );

      final dashOnlySourceSet = VGStreamingSourceSet(
        sources: [dashSourceDescriptor],
      );

      final dashDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: dashOnlySourceSet,
          preflightReport: dashReport,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      if (dashReport.pass) {
        throw Exception(
          'Scenario 3: DASH preflight report.pass was true (expected false)',
        );
      }
      if (dashReport.failedReports < 1) {
        throw Exception(
          'Scenario 3: DASH failedReports was ${dashReport.failedReports} (expected >= 1)',
        );
      }
      if (!dashReport.warnings.contains('unsupported_format_dash')) {
        throw Exception(
          'Scenario 3: DASH warnings did not contain "unsupported_format_dash": ${dashReport.warnings}',
        );
      }
      if (!dashReport.advisoryOnly) {
        throw Exception('Scenario 3: DASH advisoryOnly was not true');
      }
      if (dashReport.playbackMutation) {
        throw Exception('Scenario 3: DASH playbackMutation was true');
      }
      if (dashStartupPlan.shouldProceed) {
        throw Exception(
          'Scenario 3: DASH startup plan shouldProceed was true (expected false)',
        );
      }
      if (dashDecision.canOpenPlayback) {
        throw Exception(
          'Scenario 3: DASH decision canOpenPlayback was true (expected false)',
        );
      }

      summaryDiag['scenario3_dash'] = {
        'pass': true,
        'preflightPass': dashReport.pass,
        'failedReports': dashReport.failedReports,
        'warnings': dashReport.warnings,
        'advisoryOnly': dashReport.advisoryOnly,
        'playbackMutation': dashReport.playbackMutation,
        'startupShouldProceed': dashStartupPlan.shouldProceed,
        'canOpenPlayback': dashDecision.canOpenPlayback,
      };
      dashTypedDeferralPass = true;

      // ───────────────────────────────────────────────────────────────────────
      // Terminal summary and output
      // ───────────────────────────────────────────────────────────────────────
      final payload = {
        'phase': _kPhase,
        'target': _kTarget,
        'pass': true,
        'hlsFallbackPass': hlsFallbackPass,
        'llHlsPass': llHlsPass,
        'dashTypedDeferralPass': dashTypedDeferralPass,
        'advisoryOnlyVerified': true,
        'playbackMutationZeroVerified': true,
        'scenarios': summaryDiag,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(payload)}',
      );

      if (mounted) {
        setState(() {
          _status =
              'PASS: All Phase 4C8M preflight-to-playback scenarios verified.';
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
        'hlsFallbackPass': hlsFallbackPass,
        'llHlsPass': llHlsPass,
        'dashTypedDeferralPass': dashTypedDeferralPass,
        'error': e.toString(),
        'scenarios': summaryDiag,
      };
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_TO_PLAYBACK_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(failPayload)}',
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
                  'iOS Streaming Preflight-to-Playback Public API Smoke ($_kPhase)',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
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
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.grey[900],
                width: double.infinity,
                child: Text(
                  _status,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
