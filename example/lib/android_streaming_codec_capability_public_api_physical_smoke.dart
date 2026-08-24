// Vanguard Android True-DAG Phase 4C5J/4C5K:
// Public streaming codec capability physical smoke test.
//
// Invariants:
// - Uses public VGStreamingCodecCapabilityClient API from package:vanguard_media_engine.
// - Zero raw MethodChannel and zero package:flutter/services.dart imports.
// - Probes device decoders for AVC, HEVC, and AV1 via MediaCodecList metadata.
// - Confirms baseline AVC decoder availability.
// - Enforces additive server ladder policy: add_hevc_av1_renditions_but_keep_avc_fallback.
// - Telemetry on HEVC/AV1 is advisory and does not fail smoke if absent.
// - Zero playback mutation, zero ExoPlayer allocation, zero MediaCodec decoding, zero network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingCodecCapabilityPublicApiPhysicalSmokeApp());
}

class AndroidStreamingCodecCapabilityPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingCodecCapabilityPublicApiPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingCodecCapabilityPublicApiPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingCodecCapabilityPublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingCodecCapabilityPublicApiPhysicalSmokeAppState
    extends State<AndroidStreamingCodecCapabilityPublicApiPhysicalSmokeApp> {
  String _status = 'Initializing public streaming codec capability smoke…';

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
      final client = VGStreamingCodecCapabilityClient();
      final report = await client.probe();

      diagMap = <String, dynamic>{
        'phase': report.phase,
        'pass': report.pass,
        'avcPass': report.avcPass,
        'codecCountPass': report.codecCountPass,
        'fallbackPolicyPass': report.fallbackPolicyPass,
        'iosMirrorNotePass': report.iosMirrorNotePass,
        'avcSupported': report.avcSupported,
        'hevcSupported': report.hevcSupported,
        'av1Supported': report.av1Supported,
        'androidSdk': report.androidSdk,
        'serverLadderPolicy': report.serverLadderPolicy,
        'iosMirrorNote': report.iosMirrorNote,
        'codecs': report.codecs.map((c) => c.toMap()).toList(),
        'probe': report.probe,
        'raw': report.raw,
        'diagnostics': report.diagnostics,
      };

      final phaseMatch = report.phase == 'Phase4C5A';
      final overallPass = report.pass == true;
      final avcPassMatch = report.avcPass == true;
      final codecCountMatch = report.codecCountPass == true;
      final fallbackPolicyMatch = report.fallbackPolicyPass == true;
      final iosMirrorNoteMatch = report.iosMirrorNotePass == true;
      final avcSupportedMatch = report.avcSupported == true;
      final codecListCountMatch = report.codecs.length == 3;
      final policyTextMatch = report.serverLadderPolicy.contains(
        'add_hevc_av1_renditions_but_keep_avc_fallback',
      );

      pass =
          phaseMatch &&
          overallPass &&
          avcPassMatch &&
          codecCountMatch &&
          fallbackPolicyMatch &&
          iosMirrorNoteMatch &&
          avcSupportedMatch &&
          codecListCountMatch &&
          policyTextMatch;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_CODEC_CAPABILITY_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    final hevcSupported = diagMap['hevcSupported'] == true;
    final av1Supported = diagMap['av1Supported'] == true;

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_CODEC_CAPABILITY_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_CODEC_CAPABILITY_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_CODEC_CAPABILITY_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (AVC=true, HEVC=$hevcSupported, AV1=$av1Supported)'
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
