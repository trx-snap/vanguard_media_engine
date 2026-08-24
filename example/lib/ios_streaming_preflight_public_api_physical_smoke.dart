// Vanguard iOS Phase 4C8D: Public streaming preflight advisory API physical smoke test.
//
// Route:
//   VGStreamingPreflightClient.evaluate(...) ->
//   MethodChannel("vanguard_media_engine").invokeMethod("evaluateStreamingPreflightAdvisory", ...) ->
//   VGStreamingPreflightCoordinator.swift
//
// Platform Facts & Verification Invariants:
// - Imports only package:vanguard_media_engine/vanguard_media_engine.dart.
// - No direct MethodChannel or services.dart imports.
// - Evaluates 3 scenarios:
//   1. HLS preflight pass:
//      - URI: https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
//      - formatHint: VGStreamingFormatHint.hls
//      - allowMediaPlaylist: true only if needed by this harness to avoid single-playlist false negatives
//      - Assert: report.pass == true, advisoryOnly == true, playbackMutation == false, failedReports == 0,
//        startup plan shouldProceed == true, decision canOpenPlayback == true.
//   2. LL-HLS preflight pass:
//      - URI: https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8
//      - formatHint: VGStreamingFormatHint.hls
//      - requireLlHlsTags: true
//      - request preferLowLatency: true
//      - Assert: report.pass == true, llHlsAvailable == true, advisoryDecision == 'advise_low_latency',
//        startup plan shouldProceed == true, decision canOpenPlayback == true.
//   3. DASH typed failure:
//      - URI: https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd
//      - formatHint: VGStreamingFormatHint.dash
//      - Assert: report.pass == false, failedReports >= 1, warnings contain 'unsupported_format_dash',
//        advisoryDecision == 'blocked_compatibility_failed', startup plan shouldProceed == false.
// - Pure advisory validation: zero playback sessions opened/mutated.
// - Bounded awaits with 25-second timeouts per native evaluate call.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const IosStreamingPreflightPublicApiPhysicalSmokeApp());
}

class IosStreamingPreflightPublicApiPhysicalSmokeApp extends StatefulWidget {
  const IosStreamingPreflightPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingPreflightPublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingPreflightPublicApiPhysicalSmokeAppState();
}

class _IosStreamingPreflightPublicApiPhysicalSmokeAppState
    extends State<IosStreamingPreflightPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();
  String _status =
      'Initializing iOS streaming preflight public API physical smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runPublicApiSmoke();
    });
  }

  Future<void> _runPublicApiSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    final Map<String, dynamic> summaryDiag = <String, dynamic>{};
    bool allScenariosPassed = false;
    String failureReason = '';

    try {
      // ───────────────────────────────────────────────────────────────────────
      // Scenario 1: HLS preflight pass
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_PUBLIC_API_STEP_HLS: START');
      if (mounted) {
        setState(() {
          _status = 'Running Scenario 1: HLS preflight pass…';
        });
      }

      final hlsSourceDescriptor = VGStreamingSourceDescriptor(
        key: 'mux_hls_test',
        uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        initialWidth: 1080,
        initialHeight: 1920,
        formatHint: VGStreamingFormatHint.hls,
        allowMediaPlaylist: true,
      );

      final hlsSourceSet = VGStreamingSourceSet(sources: [hlsSourceDescriptor]);

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
          .timeout(const Duration(seconds: 25));

      final hlsStartupPlan = VGStreamingStartupPlanner.fromPreflight(hlsReport);

      final hlsDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: hlsSourceSet,
          preflightReport: hlsReport,
        ),
      );

      summaryDiag['hls'] = {
        'pass': hlsReport.pass,
        'advisoryOnly': hlsReport.advisoryOnly,
        'playbackMutation': hlsReport.playbackMutation,
        'failedReports': hlsReport.failedReports,
        'startupShouldProceed': hlsStartupPlan.shouldProceed,
        'canOpenPlayback': hlsDecision.canOpenPlayback,
        'diagnostics': hlsReport.diagnostics,
      };

      if (!hlsReport.pass) {
        throw Exception('HLS preflight report.pass was false');
      }
      if (!hlsReport.advisoryOnly) {
        throw Exception('HLS preflight advisoryOnly was not true');
      }
      if (hlsReport.playbackMutation) {
        throw Exception('HLS preflight playbackMutation was true');
      }
      if (hlsReport.failedReports != 0) {
        throw Exception(
          'HLS preflight failedReports was ${hlsReport.failedReports} (expected 0)',
        );
      }
      if (!hlsStartupPlan.shouldProceed) {
        throw Exception('HLS startup plan shouldProceed was false');
      }
      if (!hlsDecision.canOpenPlayback) {
        throw Exception('HLS decision canOpenPlayback was false');
      }

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_PUBLIC_API_STEP_HLS: DONE');

      // ───────────────────────────────────────────────────────────────────────
      // Scenario 2: LL-HLS preflight pass
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_PUBLIC_API_STEP_LL_HLS: START');
      if (mounted) {
        setState(() {
          _status = 'Running Scenario 2: LL-HLS preflight pass…';
        });
      }

      final llHlsSourceDescriptor = VGStreamingSourceDescriptor(
        key: 'mux_ll_hls_test',
        uri: Uri.parse(
          'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
        ),
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
        preferLowLatency: true,
      );

      final llHlsReport = await _preflightClient
          .evaluate(llHlsPreflightRequest)
          .timeout(const Duration(seconds: 25));

      final llHlsStartupPlan = VGStreamingStartupPlanner.fromPreflight(
        llHlsReport,
      );

      final llHlsDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: llHlsSourceSet,
          preflightReport: llHlsReport,
        ),
      );

      summaryDiag['llHls'] = {
        'pass': llHlsReport.pass,
        'llHlsAvailable': llHlsReport.llHlsAvailable,
        'advisoryDecision': llHlsReport.advisoryDecision,
        'startupShouldProceed': llHlsStartupPlan.shouldProceed,
        'canOpenPlayback': llHlsDecision.canOpenPlayback,
        'diagnostics': llHlsReport.diagnostics,
      };

      if (!llHlsReport.pass) {
        throw Exception('LL-HLS preflight report.pass was false');
      }
      if (!llHlsReport.llHlsAvailable) {
        throw Exception('LL-HLS preflight llHlsAvailable was false');
      }
      if (llHlsReport.advisoryDecision != 'advise_low_latency') {
        throw Exception(
          'LL-HLS advisoryDecision was "${llHlsReport.advisoryDecision}" (expected "advise_low_latency")',
        );
      }
      if (!llHlsStartupPlan.shouldProceed) {
        throw Exception('LL-HLS startup plan shouldProceed was false');
      }
      if (!llHlsDecision.canOpenPlayback) {
        throw Exception('LL-HLS decision canOpenPlayback was false');
      }

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_PUBLIC_API_STEP_LL_HLS: DONE');

      // ───────────────────────────────────────────────────────────────────────
      // Scenario 3: DASH typed failure
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_PUBLIC_API_STEP_DASH: START');
      if (mounted) {
        setState(() {
          _status = 'Running Scenario 3: DASH typed failure…';
        });
      }

      final dashSourceDescriptor = VGStreamingSourceDescriptor(
        key: 'shaka_angel_one_dash',
        uri: Uri.parse(
          'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
        ),
        initialWidth: 1080,
        initialHeight: 1920,
        formatHint: VGStreamingFormatHint.dash,
      );

      final dashSourceSet = VGStreamingSourceSet(
        sources: [dashSourceDescriptor],
      );

      final dashManifestSpec = VGStreamingManifestSpec(
        key: dashSourceDescriptor.key,
        uri: dashSourceDescriptor.uri,
        formatHint: dashSourceDescriptor.formatHint,
      );

      final dashPreflightRequest = VGStreamingPreflightRequest(
        manifests: [dashManifestSpec],
      );

      final dashReport = await _preflightClient
          .evaluate(dashPreflightRequest)
          .timeout(const Duration(seconds: 25));

      final dashStartupPlan = VGStreamingStartupPlanner.fromPreflight(
        dashReport,
      );

      final dashDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: dashSourceSet,
          preflightReport: dashReport,
        ),
      );

      summaryDiag['dash'] = {
        'pass': dashReport.pass,
        'failedReports': dashReport.failedReports,
        'warnings': dashReport.warnings,
        'advisoryDecision': dashReport.advisoryDecision,
        'startupShouldProceed': dashStartupPlan.shouldProceed,
        'canOpenPlayback': dashDecision.canOpenPlayback,
        'diagnostics': dashReport.diagnostics,
      };

      if (dashReport.pass) {
        throw Exception('DASH preflight report.pass was true (expected false)');
      }
      if (dashReport.failedReports < 1) {
        throw Exception(
          'DASH preflight failedReports was ${dashReport.failedReports} (expected >= 1)',
        );
      }
      if (!dashReport.warnings.contains('unsupported_format_dash')) {
        throw Exception(
          'DASH preflight warnings did not contain "unsupported_format_dash": ${dashReport.warnings}',
        );
      }
      if (dashReport.advisoryDecision != 'blocked_compatibility_failed') {
        throw Exception(
          'DASH preflight advisoryDecision was "${dashReport.advisoryDecision}" (expected "blocked_compatibility_failed")',
        );
      }
      if (dashStartupPlan.shouldProceed) {
        throw Exception(
          'DASH startup plan shouldProceed was true (expected false)',
        );
      }

      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_PUBLIC_API_STEP_DASH: DONE');

      allScenariosPassed = true;
    } catch (error, stack) {
      failureReason = '$error';
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PREFLIGHT_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      allScenariosPassed = false;
    }

    // Print diagnostic map and terminal markers
    // ignore: avoid_print
    print(
      'IOS_STREAMING_PREFLIGHT_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(summaryDiag)}',
    );

    if (allScenariosPassed) {
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_PUBLIC_API_PHYSICAL_PASS');
      if (mounted) {
        setState(() {
          _status = 'PASS: All 3 preflight scenarios verified successfully.';
        });
      }
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_PREFLIGHT_PUBLIC_API_PHYSICAL_FAIL:$failureReason');
      if (mounted) {
        setState(() {
          _status = 'FAIL: $failureReason';
        });
      }
    }

    // Exit process after marker so physical automated runner finishes cleanly
    await Future<void>.delayed(const Duration(seconds: 1));
    exit(allScenariosPassed ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
