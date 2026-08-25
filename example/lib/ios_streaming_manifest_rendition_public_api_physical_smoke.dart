// Vanguard iOS Phase 4C8V:
// Public streaming manifest rendition diagnostics physical smoke test.
//
// Invariants:
// - Uses public VGStreamingManifestRenditionClient API from package:vanguard_media_engine.
// - Zero raw MethodChannel and zero package:flutter/services.dart imports.
// - Inspects canonical HLS, DASH, and LL-HLS multivariant manifest ladders against server ladder policy.
// - Enforces additive server ladder policy: add_hevc_av1_renditions_but_keep_avc_fallback.
// - Zero playback mutation, zero AVPlayer allocation, zero VideoToolbox decoding.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const IosStreamingManifestRenditionPublicApiPhysicalSmokeApp());
}

class IosStreamingManifestRenditionPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingManifestRenditionPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingManifestRenditionPublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingManifestRenditionPublicApiPhysicalSmokeAppState();
}

class _IosStreamingManifestRenditionPublicApiPhysicalSmokeAppState
    extends State<IosStreamingManifestRenditionPublicApiPhysicalSmokeApp> {
  String _status = 'Initializing iOS streaming manifest rendition smoke…';

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

    // ignore: avoid_print
    print('IOS_STREAMING_MANIFEST_RENDITION_STEP_INSPECT: START');

    try {
      final client = VGStreamingManifestRenditionClient();
      final report = await client.inspectCanonicalStreams();

      // ignore: avoid_print
      print('IOS_STREAMING_MANIFEST_RENDITION_STEP_INSPECT: DONE');

      diagMap = <String, dynamic>{
        'phase': report.phase,
        'pass': report.pass,
        'hlsPass': report.hlsPass,
        'dashPass': report.dashPass,
        'llHlsPass': report.llHlsPass,
        'allServerPoliciesPass': report.allServerPoliciesPass,
        'totalStreamsInspected': report.totalStreamsInspected,
        'totalVariantsDiscovered': report.totalVariantsDiscovered,
        'hlsVariantCount': report.hlsVariantCount,
        'dashRepresentationCount': report.dashRepresentationCount,
        'llHlsVariantCount': report.llHlsVariantCount,
        'serverLadderPolicy': report.serverLadderPolicy,
        'iosMirrorNote': report.iosMirrorNote,
        'hls': report.hls.toMap(),
        'dash': report.dash.toMap(),
        'llHls': report.llHls.toMap(),
        'hasAnyAdvancedCodecRendition': report.hasAnyAdvancedCodecRendition,
        'hasAvcFallback': report.hasAvcFallback,
        'hasLlHlsIndicators': report.hasLlHlsIndicators,
        'raw': report.raw,
        'diagnostics': report.diagnostics,
      };

      final phaseMatch = report.phase == 'Phase4C8V';
      final overallPass = report.pass == true;
      final hlsMatch = report.hlsPass == true;
      final dashMatch = report.dashPass == true;
      final llHlsMatch = report.llHlsPass == true;
      final allServerPoliciesMatch = report.allServerPoliciesPass == true;
      final totalStreamsMatch = report.totalStreamsInspected == 3;
      final totalVariantsMatch = report.totalVariantsDiscovered > 0;
      final hlsVariantMatch = report.hlsVariantCount > 0;
      final dashRepMatch = report.dashRepresentationCount > 0;
      final llHlsVariantMatch = report.llHlsVariantCount > 0;
      final policyMatch =
          report.serverLadderPolicy ==
          'add_hevc_av1_renditions_but_keep_avc_fallback';
      final hlsStreamsValid =
          report.hls.fetchSuccess && report.hls.parseSuccess;
      final dashStreamsValid =
          report.dash.fetchSuccess && report.dash.parseSuccess;
      final llHlsStreamsValid =
          report.llHls.fetchSuccess && report.llHls.parseSuccess;
      final avcFallbackMatch = report.hasAvcFallback == true;

      pass =
          phaseMatch &&
          overallPass &&
          hlsMatch &&
          dashMatch &&
          llHlsMatch &&
          allServerPoliciesMatch &&
          totalStreamsMatch &&
          totalVariantsMatch &&
          hlsVariantMatch &&
          dashRepMatch &&
          llHlsVariantMatch &&
          policyMatch &&
          hlsStreamsValid &&
          dashStreamsValid &&
          llHlsStreamsValid &&
          avcFallbackMatch;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MANIFEST_RENDITION_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
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
      'IOS_STREAMING_MANIFEST_RENDITION_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'IOS_STREAMING_MANIFEST_RENDITION_PUBLIC_API_PHYSICAL_PASS'
          : 'IOS_STREAMING_MANIFEST_RENDITION_PUBLIC_API_PHYSICAL_FAIL',
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
