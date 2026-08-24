// Vanguard Android True-DAG Phase 4C5H/4C5I:
// Public streaming manifest policy validation physical smoke test.
//
// Invariants:
// - Uses public VGStreamingManifestPolicyClient API from package:vanguard_media_engine.
// - Zero raw MethodChannel and zero package:flutter/services.dart imports.
// - Validates HLS, DASH, and LL-HLS multivariant manifest ladders against server ladder policy.
// - Enforces additive server ladder policy: add_hevc_av1_renditions_but_keep_avc_fallback.
// - Validates segment rejection security assertion (pre-fetch rejection of segment URLs).
// - Zero playback mutation, zero ExoPlayer allocation, zero MediaCodec decoding.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingManifestPolicyPublicApiPhysicalSmokeApp());
}

class AndroidStreamingManifestPolicyPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingManifestPolicyPublicApiPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingManifestPolicyPublicApiPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingManifestPolicyPublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingManifestPolicyPublicApiPhysicalSmokeAppState
    extends State<AndroidStreamingManifestPolicyPublicApiPhysicalSmokeApp> {
  String _status =
      'Initializing public streaming manifest policy validation smoke…';

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
      final client = VGStreamingManifestPolicyClient();
      final request = VGStreamingManifestPolicyValidationRequest(
        manifests: [
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
        ],
      );

      final report = await client.validate(request);

      diagMap = <String, dynamic>{
        'phase': report.phase,
        'pass': report.pass,
        'totalManifestsValidated': report.totalManifestsValidated,
        'passedManifests': report.passedManifests,
        'failedManifests': report.failedManifests,
        'segmentRejectionPass': report.segmentRejectionPass,
        'serverLadderPolicy': report.serverLadderPolicy,
        'iosMirrorNote': report.iosMirrorNote,
        'results': report.results,
        'segmentRejectionResult': report.segmentRejectionResult,
        'raw': report.raw,
        'diagnostics': report.diagnostics,
      };

      final phaseMatch = report.phase == 'Phase4C5D';
      final overallPass = report.pass == true;
      final totalMatch = report.totalManifestsValidated == 3;
      final passedMatch = report.passedManifests == 3;
      final failedMatch = report.failedManifests == 0;
      final segmentRejectionMatch = report.segmentRejectionPass == true;
      final policyMatch = report.serverLadderPolicy.contains(
        'add_hevc_av1_renditions_but_keep_avc_fallback',
      );
      final resultsMatch = report.results.length == 3;

      pass =
          phaseMatch &&
          overallPass &&
          totalMatch &&
          passedMatch &&
          failedMatch &&
          segmentRejectionMatch &&
          policyMatch &&
          resultsMatch;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_MANIFEST_POLICY_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
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
      'ANDROID_STREAMING_MANIFEST_POLICY_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_MANIFEST_POLICY_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_MANIFEST_POLICY_PUBLIC_API_PHYSICAL_FAIL',
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
