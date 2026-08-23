// Vanguard Android True-DAG Phase 4C5D: Streaming manifest policy validation physical smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AdaptiveStreamingManifestPolicySmokeHarness.runHostManifestPolicyValidation() ->
//   AdaptiveStreamingManifestPolicyValidator.validateSpecs() ->
//   AdaptiveStreamingManifestRenditionInspector.inspectUri()
//
// Platform Facts & Verification Invariants:
// - Media3 ExoPlayer supports HLS, Apple LL-HLS, and DASH containers.
// - Multivariant adaptation in HLS depends on variant #EXT-X-STREAM-INF entries plus device capabilities.
// - DASH adaptation relies on Period -> AdaptationSet -> Representation hierarchies.
// - Product Policy: Future server ladders may add HEVC and AV1 renditions, but AVC/H.264 fallback
//   must remain mandatory so older Android devices and iOS mirrors do not hiccup.
// - Host-supplied manifest validation allows arbitrary server/CDN manifests to be verified against ladder policy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidStreamingManifestPolicyPhysicalSmokeApp());
}

class AndroidStreamingManifestPolicyPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingManifestPolicyPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingManifestPolicyPhysicalSmokeApp> createState() =>
      _AndroidStreamingManifestPolicyPhysicalSmokeAppState();
}

class _AndroidStreamingManifestPolicyPhysicalSmokeAppState
    extends State<AndroidStreamingManifestPolicyPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android streaming manifest policy validation smoke…';

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
        'runAndroidDagPhase4C5DManifestPolicyValidation',
        <String, dynamic>{
          'manifests': hostManifests,
        },
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C5DManifestPolicyValidation returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final segmentRejectionPass = diagMap['segmentRejectionPass'] == true;
      final totalManifests = (diagMap['totalManifestsValidated'] as num?)?.toInt() ?? 0;
      final passedManifests = (diagMap['passedManifests'] as num?)?.toInt() ?? 0;
      final failedManifests = (diagMap['failedManifests'] as num?)?.toInt() ?? 0;

      pass = overallPass &&
          segmentRejectionPass &&
          totalManifests == 3 &&
          passedManifests == 3 &&
          failedManifests == 0;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_STREAMING_MANIFEST_POLICY_PHYSICAL_ERROR: $error\n$stack');
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    final totalManifests = diagMap['totalManifestsValidated'] ?? 0;
    final passedManifests = diagMap['passedManifests'] ?? 0;
    final failedManifests = diagMap['failedManifests'] ?? 0;
    final segmentRejection = diagMap['segmentRejectionPass'] ?? false;

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_MANIFEST_POLICY_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_MANIFEST_POLICY_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_MANIFEST_POLICY_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (Validated=$totalManifests, Passed=$passedManifests, Failed=$failedManifests, SegRejection=$segmentRejection)'
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
