// Vanguard iOS True-DAG Phase 4C8N: Public streaming source descriptor / source set all-up physical smoke.
//
// Route:
//   VGStreamingSourceSet.toPreflightRequest(...) ->
//   VGStreamingPreflightClient.evaluate(...) [actual iOS native preflight] ->
//   VGStreamingStartupPlanner.fromPreflight(...) ->
//   VGStreamingSourceDescriptor.toPlaybackOptions(plan) ->
//   VGStreamingPlaybackClient.open(options) [actual AVPlayer native playback]
//
// Scenarios:
//   1. Compatible source-set preflight:
//      - Build VGStreamingSourceSet with two compatible descriptors:
//        - hls: formatHint hls, initialWidth 1080, initialHeight 1920, allowMediaPlaylist true.
//        - ll_hls: formatHint hls, initialWidth 1080, initialHeight 1920, requireLlHlsTags true.
//      - Generate preflight request only via sourceSet.toPreflightRequest(preferLowLatency: true, requestedNetworkProfile: auto).
//      - Run actual VGStreamingPreflightClient.evaluate with timeout.
//      - Assert report.pass == true, advisoryOnly == true, playbackMutation == false, totalReports == 2, failedReports == 0,
//        phase contains 'Phase4C8C', llHlsAvailable == true.
//      - Build VGStreamingStartupPlanner.fromPreflight(report); assert shouldProceed == true.
//   2. Descriptor to playback options + physical playback for HLS:
//      - Call hlsDescriptor.toPlaybackOptions(plan).
//      - Assert options.uri, initialWidth, initialHeight, formatHint, autoPlay, and networkProfile match descriptor/plan.
//      - Open via VGStreamingPlaybackClient.open(options), play, poll getStatus until renderedFrames > 0 and dimensions > 0,
//        pause, optional seek only if durationMs > 2000, stop, dispose in finally.
//   3. Descriptor to playback options + physical playback for LL-HLS:
//      - Call llHlsDescriptor.toPlaybackOptions(plan).
//      - Assert options URI/dims/format/autoPlay/networkProfile.
//      - Open via VGStreamingPlaybackClient.open(options), play, poll getStatus until renderedFrames > 0 and dimensions > 0,
//        stop, dispose in finally.
//   4. DASH descriptor typed deferral:
//      - Build dashDescriptor and dashSourceSet.
//      - Generate request using dashSourceSet.toPreflightRequest().
//      - Run actual evaluate with timeout.
//      - Assert pass == false, failedReports >= 1, warnings contains 'unsupported_format_dash',
//        advisoryOnly == true, playbackMutation == false.
//      - Build startup plan; assert shouldProceed == false.
//      - Assert dashDescriptor.toPlaybackOptions(dashPlan) throws StateError and do not open playback.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kPhase = 'Phase4C8N';
const String _kTarget = 'ios_physical';
const String _kPassMarker =
    'IOS_STREAMING_SOURCE_DESCRIPTOR_PUBLIC_API_PHYSICAL_PASS';
const String _kFailMarker =
    'IOS_STREAMING_SOURCE_DESCRIPTOR_PUBLIC_API_PHYSICAL_FAIL';

const String _kHlsUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const String _kLlHlsUrl =
    'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8';
const String _kDashUrl =
    'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd';

const Duration _kPreflightTimeout = Duration(seconds: 25);
const Duration _kStatusDeadline = Duration(seconds: 20);

void main() {
  runApp(const IosStreamingSourceDescriptorPublicApiPhysicalSmokeApp());
}

class IosStreamingSourceDescriptorPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingSourceDescriptorPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingSourceDescriptorPublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingSourceDescriptorPublicApiPhysicalSmokeAppState();
}

class _IosStreamingSourceDescriptorPublicApiPhysicalSmokeAppState
    extends State<IosStreamingSourceDescriptorPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();
  final VGStreamingPlaybackClient _playbackClient = VGStreamingPlaybackClient();

  int? _textureId;
  String _status =
      'Initializing iOS streaming source descriptor public API physical smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSourceDescriptorSmoke();
    });
  }

  Future<void> _runSourceDescriptorSmoke() async {
    await Future<void>.delayed(const Duration(seconds: 1));

    final Map<String, dynamic> summaryDiag = <String, dynamic>{};
    bool sourceSetPreflightPass = false;
    bool hlsPass = false;
    bool llHlsPass = false;
    bool dashTypedDeferralPass = false;
    String failureReason = '';

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 1: Compatible source-set preflight & startup plan synthesis
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_SOURCE_SET_PREFLIGHT: START');
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

      final sourceSet = VGStreamingSourceSet(
        sources: [hlsDescriptor, llHlsDescriptor],
      );

      final preflightRequest = sourceSet.toPreflightRequest(
        preferLowLatency: true,
        requestedNetworkProfile: VGStreamingNetworkProfile.auto,
      );

      final report = await _preflightClient
          .evaluate(preflightRequest)
          .timeout(_kPreflightTimeout);

      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_SOURCE_SET_PREFLIGHT: DONE');

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
      // Step 2: HLS Descriptor to playback options + physical playback
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_HLS_OPTIONS: START');
      if (mounted) {
        setState(() {
          _status = 'Step 2: Building HLS playback options from descriptor…';
        });
      }

      final hlsOptions = hlsDescriptor.toPlaybackOptions(plan);

      if (hlsOptions.uri != hlsDescriptor.uri ||
          hlsOptions.initialWidth != hlsDescriptor.initialWidth ||
          hlsOptions.initialHeight != hlsDescriptor.initialHeight ||
          hlsOptions.formatHint != hlsDescriptor.formatHint ||
          hlsOptions.autoPlay != hlsDescriptor.autoPlay ||
          hlsOptions.networkProfile != plan.recommendedNetworkProfile) {
        throw Exception(
          'Step 2 failed: HLS playback options mismatch: '
          'uri=${hlsOptions.uri} vs ${hlsDescriptor.uri}, '
          'dims=${hlsOptions.initialWidth}x${hlsOptions.initialHeight} vs ${hlsDescriptor.initialWidth}x${hlsDescriptor.initialHeight}, '
          'format=${hlsOptions.formatHint} vs ${hlsDescriptor.formatHint}, '
          'autoPlay=${hlsOptions.autoPlay} vs ${hlsDescriptor.autoPlay}, '
          'profile=${hlsOptions.networkProfile} vs ${plan.recommendedNetworkProfile}',
        );
      }
      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_HLS_OPTIONS: DONE');

      VGStreamingPlaybackSession? hlsSession;
      Map<String, dynamic> hlsPlaybackDiag = {};
      try {
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_HLS_OPEN: START');
        if (mounted) {
          setState(() {
            _status = 'Step 2: Opening HLS playback session…';
          });
        }

        hlsSession = await _playbackClient.open(hlsOptions);
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
          'IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_HLS_OPEN: DONE (textureId=${hlsSession.textureId})',
        );

        hlsSession = await _playbackClient.play(hlsSession);

        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_HLS_STATUS: START');
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
          'IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_HLS_STATUS: DONE (frames=${hlsStatus.renderedFrames}, dims=${hlsStatus.effectiveDisplayWidth}x${hlsStatus.effectiveDisplayHeight})',
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
        print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_HLS_STOP: START');
        hlsSession = await _playbackClient.stop(hlsSession);
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_HLS_STOP: DONE');

        hlsPlaybackDiag = {
          'pass': true,
          'textureId': hlsStatus.textureId,
          'renderedFrames': hlsStatus.renderedFrames,
          'effectiveDisplayWidth': hlsStatus.effectiveDisplayWidth,
          'effectiveDisplayHeight': hlsStatus.effectiveDisplayHeight,
          'durationMs': hlsStatus.durationMs,
          'state': hlsStatus.state.name,
          'format': hlsStatus.format.toNative(),
        };
        hlsPass = true;
      } finally {
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_HLS_DISPOSE: START');
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
        print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_HLS_DISPOSE: DONE');
      }

      summaryDiag['hls'] = hlsPlaybackDiag;

      // ═══════════════════════════════════════════════════════════════════════
      // Step 3: LL-HLS Descriptor to playback options + physical playback
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_LL_HLS_OPTIONS: START');
      if (mounted) {
        setState(() {
          _status = 'Step 3: Building LL-HLS playback options from descriptor…';
        });
      }

      final llHlsOptions = llHlsDescriptor.toPlaybackOptions(plan);

      if (llHlsOptions.uri != llHlsDescriptor.uri ||
          llHlsOptions.initialWidth != llHlsDescriptor.initialWidth ||
          llHlsOptions.initialHeight != llHlsDescriptor.initialHeight ||
          llHlsOptions.formatHint != llHlsDescriptor.formatHint ||
          llHlsOptions.autoPlay != llHlsDescriptor.autoPlay ||
          llHlsOptions.networkProfile != plan.recommendedNetworkProfile) {
        throw Exception(
          'Step 3 failed: LL-HLS playback options mismatch: '
          'uri=${llHlsOptions.uri} vs ${llHlsDescriptor.uri}, '
          'dims=${llHlsOptions.initialWidth}x${llHlsOptions.initialHeight} vs ${llHlsDescriptor.initialWidth}x${llHlsDescriptor.initialHeight}, '
          'format=${llHlsOptions.formatHint} vs ${llHlsDescriptor.formatHint}, '
          'autoPlay=${llHlsOptions.autoPlay} vs ${llHlsDescriptor.autoPlay}, '
          'profile=${llHlsOptions.networkProfile} vs ${plan.recommendedNetworkProfile}',
        );
      }
      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_LL_HLS_OPTIONS: DONE');

      VGStreamingPlaybackSession? llHlsSession;
      Map<String, dynamic> llHlsPlaybackDiag = {};
      try {
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_LL_HLS_OPEN: START');
        if (mounted) {
          setState(() {
            _status = 'Step 3: Opening LL-HLS playback session…';
          });
        }

        llHlsSession = await _playbackClient.open(llHlsOptions);
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
          'IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_LL_HLS_OPEN: DONE (textureId=${llHlsSession.textureId})',
        );

        llHlsSession = await _playbackClient.play(llHlsSession);

        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_LL_HLS_STATUS: START');
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
          'IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_LL_HLS_STATUS: DONE (frames=${llHlsStatus.renderedFrames}, dims=${llHlsStatus.effectiveDisplayWidth}x${llHlsStatus.effectiveDisplayHeight})',
        );

        // Stop
        llHlsSession = await _playbackClient.stop(llHlsSession);

        llHlsPlaybackDiag = {
          'pass': true,
          'textureId': llHlsStatus.textureId,
          'renderedFrames': llHlsStatus.renderedFrames,
          'effectiveDisplayWidth': llHlsStatus.effectiveDisplayWidth,
          'effectiveDisplayHeight': llHlsStatus.effectiveDisplayHeight,
          'durationMs': llHlsStatus.durationMs,
          'state': llHlsStatus.state.name,
          'format': llHlsStatus.format.toNative(),
        };
        llHlsPass = true;
      } finally {
        // ignore: avoid_print
        print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_LL_HLS_DISPOSE: START');
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
        print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_LL_HLS_DISPOSE: DONE');
      }

      summaryDiag['llHls'] = llHlsPlaybackDiag;

      // ═══════════════════════════════════════════════════════════════════════
      // Step 4: DASH descriptor typed deferral
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_DASH_PREFLIGHT: START');
      if (mounted) {
        setState(() {
          _status = 'Step 4: Evaluating DASH descriptor typed deferral…';
        });
      }

      final dashDescriptor = VGStreamingSourceDescriptor(
        key: 'dash',
        uri: Uri.parse(_kDashUrl),
        formatHint: VGStreamingFormatHint.dash,
        initialWidth: 1080,
        initialHeight: 1920,
      );

      final dashSourceSet = VGStreamingSourceSet(sources: [dashDescriptor]);

      final dashPreflightRequest = dashSourceSet.toPreflightRequest(
        requestedNetworkProfile: VGStreamingNetworkProfile.auto,
      );

      final dashReport = await _preflightClient
          .evaluate(dashPreflightRequest)
          .timeout(_kPreflightTimeout);

      // ignore: avoid_print
      print('IOS_STREAMING_SOURCE_DESCRIPTOR_STEP_DASH_PREFLIGHT: DONE');

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

      bool stateErrorThrown = false;
      try {
        dashDescriptor.toPlaybackOptions(dashPlan);
      } on StateError {
        stateErrorThrown = true;
      }

      if (!stateErrorThrown) {
        throw Exception(
          'Step 4 failed: dashDescriptor.toPlaybackOptions(dashPlan) did not throw StateError',
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
        'stateErrorThrown': stateErrorThrown,
      };

      // ───────────────────────────────────────────────────────────────────────
      // Summary & Terminal Markers
      // ───────────────────────────────────────────────────────────────────────
      final overallPass =
          sourceSetPreflightPass &&
          hlsPass &&
          llHlsPass &&
          dashTypedDeferralPass;

      final payload = {
        'phase': _kPhase,
        'target': _kTarget,
        'pass': overallPass,
        'sourceSetPreflightPass': sourceSetPreflightPass,
        'hlsPass': hlsPass,
        'llHlsPass': llHlsPass,
        'dashTypedDeferralPass': dashTypedDeferralPass,
        'advisoryOnlyVerified': true,
        'playbackMutationZeroVerified': true,
        'selectedDescriptorKeys': ['hls', 'll_hls'],
        'scenarios': summaryDiag,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_SOURCE_DESCRIPTOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(payload)}',
      );

      if (mounted) {
        setState(() {
          _status =
              'PASS: All Phase 4C8N streaming source descriptor physical scenarios verified.';
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
        'hlsPass': hlsPass,
        'llHlsPass': llHlsPass,
        'dashTypedDeferralPass': dashTypedDeferralPass,
        'error': e.toString(),
        'scenarios': summaryDiag,
      };
      // ignore: avoid_print
      print(
        'IOS_STREAMING_SOURCE_DESCRIPTOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(failPayload)}',
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
                  'iOS Streaming Source Descriptor Public API Smoke ($_kPhase)',
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
