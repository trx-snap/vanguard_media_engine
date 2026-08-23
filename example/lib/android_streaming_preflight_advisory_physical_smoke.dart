// Vanguard Android True-DAG Phase 4C5G: Streaming preflight advisory physical smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AdaptiveStreamingPreflightAdvisorySmokeHarness.runHostPreflightAdvisory() ->
//   AdaptiveStreamingPreflightAdvisory.buildAdvisory() ->
//   AdaptiveStreamingCompatibilityDecisionReport.buildReports() & AdaptiveStreamingNetworkPolicy.forProfile()
//
// Platform Facts & Verification Invariants:
// - Media3 supports HLS, Apple LL-HLS, and DASH containers; contained sample formats must be supported by the device.
// - Media3/ExoPlayer adaptive track selection updates selected tracks dynamically; preflight is advisory-only.
// - Advises host which Vanguard AdaptiveStreamingNetworkProfile to apply before playback.
// - Physical pass requires: phase Phase4C5G, pass true, totalReports=3, failedReports=0,
//   recommendedNetworkProfile CONSTRAINED, recommendedNetworkPolicy.profile CONSTRAINED,
//   advisoryOnly true, playbackMutation false.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidStreamingPreflightAdvisoryPhysicalSmokeApp());
}

class AndroidStreamingPreflightAdvisoryPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingPreflightAdvisoryPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingPreflightAdvisoryPhysicalSmokeApp> createState() =>
      _AndroidStreamingPreflightAdvisoryPhysicalSmokeAppState();
}

class _AndroidStreamingPreflightAdvisoryPhysicalSmokeAppState
    extends State<AndroidStreamingPreflightAdvisoryPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android streaming preflight advisory smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      final hostManifests = <Map<String, dynamic>>[
        <String, dynamic>{
          'key': 'mux_hls_test',
          'uri': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
          'formatHint': 'HLS',
          'requireAdaptiveLadder': true,
          'requireAvcFallback': true,
          'requireLlHlsTags': false,
          'allowMediaPlaylist': false,
        },
        <String, dynamic>{
          'key': 'shaka_angel_one_dash',
          'uri':
              'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
          'formatHint': 'DASH',
          'requireAdaptiveLadder': true,
          'requireAvcFallback': true,
          'requireLlHlsTags': false,
          'allowMediaPlaylist': false,
        },
        <String, dynamic>{
          'key': 'mux_ll_hls_test',
          'uri':
              'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
          'formatHint': 'HLS',
          'requireAdaptiveLadder': true,
          'requireAvcFallback': true,
          'requireLlHlsTags': false,
          'allowMediaPlaylist': false,
        },
      ];

      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C5GPreflightAdvisorySmoke',
        <String, dynamic>{
          'manifests': hostManifests,
          'requestedNetworkProfile': 'CONSTRAINED',
          'preferLowLatency': false,
          'allowLowLatencyOnConstrained': false,
        },
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C5GPreflightAdvisorySmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final phaseMatch = diagMap['phase'] == 'Phase4C5G';
      final overallPass = diagMap['pass'] == true;
      final totalReports = (diagMap['totalReports'] as num?)?.toInt() ?? 0;
      final passedReports = (diagMap['passedReports'] as num?)?.toInt() ?? 0;
      final failedReports = (diagMap['failedReports'] as num?)?.toInt() ?? 0;
      final recommendedNetworkProfile =
          diagMap['recommendedNetworkProfile'] as String? ?? '';
      final advisoryOnly = diagMap['advisoryOnly'] == true;
      final playbackMutation = diagMap['playbackMutation'] == false;

      final recommendedPolicy =
          diagMap['recommendedNetworkPolicy'] as Map? ?? <dynamic, dynamic>{};
      final policyProfile = recommendedPolicy['profile'] as String? ?? '';

      final compatibilityReports =
          (diagMap['compatibilityReports'] as List?)?.cast<Map>() ?? <Map>[];
      final allReportsValid =
          compatibilityReports.length == 3 &&
          compatibilityReports.every((r) {
            final rPass = r['pass'] == true;
            final decision = r['decision'] as String? ?? '';
            final preferred = r['preferredCodecFamily'] as String? ?? '';
            return rPass &&
                !decision.startsWith('blocked_') &&
                preferred.isNotEmpty &&
                preferred != 'none';
          });

      pass =
          phaseMatch &&
          overallPass &&
          totalReports == 3 &&
          passedReports == 3 &&
          failedReports == 0 &&
          recommendedNetworkProfile == 'CONSTRAINED' &&
          policyProfile == 'CONSTRAINED' &&
          advisoryOnly &&
          playbackMutation &&
          allReportsValid;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_PREFLIGHT_ADVISORY_PHYSICAL_ERROR: $error\n$stack',
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
      'ANDROID_STREAMING_PREFLIGHT_ADVISORY_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_PREFLIGHT_ADVISORY_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_PREFLIGHT_ADVISORY_PHYSICAL_FAIL',
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
