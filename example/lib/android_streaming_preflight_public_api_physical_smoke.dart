// Vanguard Android True-DAG Phase 4C7F: Public streaming preflight advisory API physical smoke test.
//
// Route:
//   VGStreamingPreflightClient.evaluate(...) ->
//   MethodChannel("vanguard_media_engine").invokeMethod("evaluateStreamingPreflightAdvisory", ...) ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AdaptiveStreamingPreflightAdvisory.buildAdvisory()
//
// Platform Facts & Verification Invariants:
// - Imports only package:vanguard_media_engine/vanguard_media_engine.dart.
// - No direct MethodChannel or services.dart imports.
// - Evaluates 3 streaming manifest specs (HLS, DASH, LL-HLS) under CONSTRAINED network profile.
// - Pure advisory validation: advisoryOnly == true, playbackMutation == false.
// - Physical pass requires: phase Phase4C5G, pass true, totalReports=3, passedReports=3,
//   failedReports=0, recommendedNetworkProfile CONSTRAINED,
//   recommendedNetworkPolicy.profile CONSTRAINED, advisoryOnly true, playbackMutation false.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingPreflightPublicApiPhysicalSmokeApp());
}

class AndroidStreamingPreflightPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingPreflightPublicApiPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingPreflightPublicApiPhysicalSmokeApp> createState() =>
      _AndroidStreamingPreflightPublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingPreflightPublicApiPhysicalSmokeAppState
    extends State<AndroidStreamingPreflightPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _client = VGStreamingPreflightClient();
  String _status =
      'Initializing Android streaming preflight public API physical smoke…';

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

    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      final manifests = <VGStreamingManifestSpec>[
        VGStreamingManifestSpec(
          key: 'mux_hls_test',
          uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
          formatHint: VGStreamingFormatHint.hls,
          requireAdaptiveLadder: true,
          requireAvcFallback: true,
          requireLlHlsTags: false,
          allowMediaPlaylist: false,
        ),
        VGStreamingManifestSpec(
          key: 'shaka_angel_one_dash',
          uri: Uri.parse(
            'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
          ),
          formatHint: VGStreamingFormatHint.dash,
          requireAdaptiveLadder: true,
          requireAvcFallback: true,
          requireLlHlsTags: false,
          allowMediaPlaylist: false,
        ),
        VGStreamingManifestSpec(
          key: 'mux_ll_hls_test',
          uri: Uri.parse(
            'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
          ),
          formatHint: VGStreamingFormatHint.hls,
          requireAdaptiveLadder: true,
          requireAvcFallback: true,
          requireLlHlsTags: false,
          allowMediaPlaylist: false,
        ),
      ];

      final request = VGStreamingPreflightRequest(
        manifests: manifests,
        requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
        preferLowLatency: false,
        allowLowLatencyOnConstrained: false,
      );

      final report = await _client.evaluate(request);

      diagMap = Map<String, dynamic>.from(report.diagnostics);

      final phaseMatch = report.phase == 'Phase4C5G';
      final overallPass = report.pass == true;
      final totalReportsMatch = report.totalReports == 3;
      final passedReportsMatch = report.passedReports == 3;
      final failedReportsMatch = report.failedReports == 0;
      final recommendedNetworkProfileMatch =
          report.recommendedNetworkProfile == 'CONSTRAINED';
      final policyProfileMatch =
          report.recommendedNetworkPolicy['profile'] == 'CONSTRAINED';
      final advisoryOnlyMatch = report.advisoryOnly == true;
      final playbackMutationMatch = report.playbackMutation == false;
      final diagnosticsNotEmpty = report.diagnostics.isNotEmpty;
      final hasCompatibilityOrPolicyData =
          report.diagnostics.containsKey('compatibilityReports') ||
          report.diagnostics.containsKey('recommendedNetworkPolicy') ||
          report.diagnostics.containsKey('advisoryDecision');

      pass =
          phaseMatch &&
          overallPass &&
          totalReportsMatch &&
          passedReportsMatch &&
          failedReportsMatch &&
          recommendedNetworkProfileMatch &&
          policyProfileMatch &&
          advisoryOnlyMatch &&
          playbackMutationMatch &&
          diagnosticsNotEmpty &&
          hasCompatibilityOrPolicyData;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_PREFLIGHT_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'phase': 'Phase4C5G',
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    final totalReports = diagMap['totalReports'] ?? 0;
    final passedReports = diagMap['passedReports'] ?? 0;
    final failedReports = diagMap['failedReports'] ?? 0;
    final recommended = diagMap['recommendedNetworkProfile'] ?? 'unknown';

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_PREFLIGHT_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_PREFLIGHT_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_PREFLIGHT_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (Reports=$totalReports, Passed=$passedReports, Failed=$failedReports, Recommended=$recommended)'
            : 'FAIL: ${diagMap['raw']}';
      });
    }

    // Exit process after marker so flutter run can finish unattended
    await Future<void>.delayed(const Duration(seconds: 1));
    exit(pass ? 0 : 1);
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
