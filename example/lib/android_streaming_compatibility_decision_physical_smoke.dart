// Vanguard Android True-DAG Phase 4C5E: Streaming codec + manifest compatibility decision report physical smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AdaptiveStreamingCompatibilityDecisionSmokeHarness.runHostCompatibilityDecision() ->
//   AdaptiveStreamingCompatibilityDecisionReport.buildReports() ->
//   AdaptiveStreamingCodecCapabilityProbe.probe() & AdaptiveStreamingManifestPolicyValidator.validateSpec()
//
// Platform Facts & Verification Invariants:
// - Android platform supported media formats: AVC decoder is baseline; HEVC/AV1 availability is hardware/OS dependent.
// - Media3 ExoPlayer supports HLS/DASH containers; contained sample formats must be supported by the device.
// - Compatibility Decision Brain: Evaluates device-safe codec choices, preferred codec selection, and baseline AVC fallback.
// - Physical pass requires 3 reports (HLS, DASH, LL-HLS), all passing, probe pass, AVC supported, and valid non-blocked decisions.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidStreamingCompatibilityDecisionPhysicalSmokeApp());
}

class AndroidStreamingCompatibilityDecisionPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingCompatibilityDecisionPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCompatibilityDecisionPhysicalSmokeApp> createState() =>
      _AndroidStreamingCompatibilityDecisionPhysicalSmokeAppState();
}

class _AndroidStreamingCompatibilityDecisionPhysicalSmokeAppState
    extends State<AndroidStreamingCompatibilityDecisionPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android streaming compatibility decision smoke…';

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
          'uri': 'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
          'formatHint': 'DASH',
          'requireAdaptiveLadder': true,
          'requireAvcFallback': true,
          'requireLlHlsTags': false,
          'allowMediaPlaylist': false,
        },
        <String, dynamic>{
          'key': 'mux_ll_hls_test',
          'uri': 'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
          'formatHint': 'HLS',
          'requireAdaptiveLadder': true,
          'requireAvcFallback': true,
          'requireLlHlsTags': false,
          'allowMediaPlaylist': false,
        },
      ];

      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C5ECompatibilityDecisionSmoke',
        <String, dynamic>{
          'manifests': hostManifests,
        },
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C5ECompatibilityDecisionSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final totalReports = (diagMap['totalReports'] as num?)?.toInt() ?? 0;
      final passedReports = (diagMap['passedReports'] as num?)?.toInt() ?? 0;
      final failedReports = (diagMap['failedReports'] as num?)?.toInt() ?? 0;
      final codecProbePass = diagMap['codecProbePass'] == true;
      final avcSupported = diagMap['avcSupported'] == true;

      final reports = (diagMap['reports'] as List?)?.cast<Map>() ?? <Map>[];
      final allReportsValid = reports.length == 3 &&
          reports.every((r) {
            final rPass = r['pass'] == true;
            final decision = r['decision'] as String? ?? '';
            final preferred = r['preferredCodecFamily'] as String? ?? '';
            return rPass &&
                !decision.startsWith('blocked_') &&
                preferred.isNotEmpty &&
                preferred != 'none';
          });

      pass = overallPass &&
          totalReports == 3 &&
          passedReports == 3 &&
          failedReports == 0 &&
          codecProbePass &&
          avcSupported &&
          allReportsValid;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_STREAMING_COMPATIBILITY_DECISION_PHYSICAL_ERROR: $error\n$stack');
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    final totalReports = diagMap['totalReports'] ?? 0;
    final passedReports = diagMap['passedReports'] ?? 0;
    final failedReports = diagMap['failedReports'] ?? 0;

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_COMPATIBILITY_DECISION_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_COMPATIBILITY_DECISION_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_COMPATIBILITY_DECISION_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (Reports=$totalReports, Passed=$passedReports, Failed=$failedReports)'
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
