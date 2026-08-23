// Vanguard Android True-DAG Phase 4C5C: Streaming manifest and rendition ladder physical smoke test.
//
// Route:
//   MethodChannel("vanguard_media_engine") ->
//   AndroidDagStreamingPlaybackCoordinator ->
//   AdaptiveStreamingManifestRenditionSmokeHarness.run() ->
//   AdaptiveStreamingManifestRenditionInspector.inspectUri()
//
// Platform Facts & Verification Invariants:
// - Media3 ExoPlayer supports HLS, Apple LL-HLS, and DASH containers.
// - Multivariant adaptation in HLS depends on variant #EXT-X-STREAM-INF entries plus device capabilities.
// - DASH adaptation relies on Period -> AdaptationSet -> Representation hierarchies.
// - Product Policy: Future server ladders may add HEVC and AV1 renditions, but AVC/H.264 fallback
//   must remain mandatory so older Android devices and iOS mirrors do not hiccup.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidStreamingManifestRenditionPhysicalSmokeApp());
}

class AndroidStreamingManifestRenditionPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingManifestRenditionPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingManifestRenditionPhysicalSmokeApp> createState() =>
      _AndroidStreamingManifestRenditionPhysicalSmokeAppState();
}

class _AndroidStreamingManifestRenditionPhysicalSmokeAppState
    extends State<AndroidStreamingManifestRenditionPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android streaming manifest rendition smoke…';

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
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C5CManifestRenditionSmoke',
      );

      if (response == null || response is! Map) {
        throw Exception(
          'runAndroidDagPhase4C5CManifestRenditionSmoke returned invalid response: $response',
        );
      }

      diagMap = Map<String, dynamic>.from(response);

      final overallPass = diagMap['pass'] == true;
      final hlsPass = diagMap['hlsPass'] == true;
      final dashPass = diagMap['dashPass'] == true;
      final llHlsPass = diagMap['llHlsPass'] == true;
      final allServerPoliciesPass = diagMap['allServerPoliciesPass'] == true;
      final totalVariants = (diagMap['totalVariantsDiscovered'] as num?)?.toInt() ?? 0;

      pass = overallPass &&
          hlsPass &&
          dashPass &&
          llHlsPass &&
          allServerPoliciesPass &&
          totalVariants > 0;
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_STREAMING_MANIFEST_RENDITION_PHYSICAL_ERROR: $error\n$stack');
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    final hlsVariants = diagMap['hlsVariantCount'] ?? 0;
    final dashReps = diagMap['dashRepresentationCount'] ?? 0;
    final llHlsVariants = diagMap['llHlsVariantCount'] ?? 0;
    final totalVariants = diagMap['totalVariantsDiscovered'] ?? 0;

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_MANIFEST_RENDITION_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_MANIFEST_RENDITION_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_MANIFEST_RENDITION_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (HLS=$hlsVariants, DASH=$dashReps, LL-HLS=$llHlsVariants, Total=$totalVariants)'
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
