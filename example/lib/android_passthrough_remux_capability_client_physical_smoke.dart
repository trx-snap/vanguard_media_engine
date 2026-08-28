// android_passthrough_remux_capability_client_physical_smoke.dart
// Vanguard Media Engine -- Phase 2-Unit AA
// Android passthrough remux capability client physical smoke test.
//
// Invariants:
// - Uses public VGPassthroughRemuxCapabilityClient API from package:vanguard_media_engine.
// - Pure metadata inspection via platform MediaExtractor.
// - Zero sample reads, zero MediaMuxer/MediaCodec allocations, zero exportTimeline bypass.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidPassthroughRemuxCapabilityClientPhysicalSmokeApp());
}

class AndroidPassthroughRemuxCapabilityClientPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidPassthroughRemuxCapabilityClientPhysicalSmokeApp({super.key});

  @override
  State<AndroidPassthroughRemuxCapabilityClientPhysicalSmokeApp>
  createState() =>
      _AndroidPassthroughRemuxCapabilityClientPhysicalSmokeAppState();
}

class _AndroidPassthroughRemuxCapabilityClientPhysicalSmokeAppState
    extends State<AndroidPassthroughRemuxCapabilityClientPhysicalSmokeApp> {
  String _status =
      'Initializing Android Passthrough Remux Capability Client Smoke (Unit AA)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA: TIMEOUT (30s exceeded)',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA_PHYSICAL_FAIL',
      );
      exit(1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA: START');
    Map<String, dynamic> resultMap = <String, dynamic>{};
    var overallPass = false;
    File? fixtureFile;

    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final runId = DateTime.now().millisecondsSinceEpoch;

      fixtureFile = File(
        '${tempDir.path}/passthrough_remux_client_unit_aa_${runId}_clip_b.mov',
      );
      await fixtureFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      final client = VGPassthroughRemuxCapabilityClient();
      final report = await client.probe(fixtureFile.path);

      final canRemux = report.canPassthroughRemux == true;
      final proofBoundaryMatches = report.proofBoundaryMatches == true;
      final diagnosticNonClaimsHold = report.diagnosticNonClaimsHold == true;
      final hasSupportedVideo = report.hasSupportedVideo == true;
      final hasSupportedAudioOrNoAudio =
          report.hasSupportedAudioOrNoAudio == true;
      final videoMime = report.video?.mime ?? '';
      final videoMimeValid =
          videoMime == 'video/avc' || videoMime == 'video/hevc';
      final audioMime = report.audio?.mime;
      final audioMimeValid =
          audioMime == null || audioMime == 'audio/mp4a-latm';
      final fileExists = report.fileExists == true;
      final fileReadable = report.fileReadable == true;
      final extractorOpened = report.extractorOpened == true;
      final trackCountValid = report.trackCount > 0;

      overallPass =
          canRemux &&
          proofBoundaryMatches &&
          diagnosticNonClaimsHold &&
          hasSupportedVideo &&
          hasSupportedAudioOrNoAudio &&
          videoMimeValid &&
          audioMimeValid &&
          fileExists &&
          fileReadable &&
          extractorOpened &&
          trackCountValid;

      resultMap = <String, dynamic>{
        'pass': overallPass,
        'canPassthroughRemux': canRemux,
        'proofBoundaryMatches': proofBoundaryMatches,
        'diagnosticNonClaimsHold': diagnosticNonClaimsHold,
        'hasSupportedVideo': hasSupportedVideo,
        'hasSupportedAudioOrNoAudio': hasSupportedAudioOrNoAudio,
        'videoMimeValid': videoMimeValid,
        'audioMimeValid': audioMimeValid,
        'fileExists': fileExists,
        'fileReadable': fileReadable,
        'extractorOpened': extractorOpened,
        'trackCount': report.trackCount,
        'report': report.toMap(),
      };

      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA_CAN_REMUX: $canRemux',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA_PROOF_BOUNDARY: $proofBoundaryMatches',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA_NON_CLAIMS: $diagnosticNonClaimsHold',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA_VIDEO: $hasSupportedVideo (mime: $videoMime)',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA_AUDIO: $hasSupportedAudioOrNoAudio (mime: $audioMime)',
      );
    } catch (e, st) {
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA: ERROR: $e\n$st',
      );
      resultMap = <String, dynamic>{'pass': false, 'error': '$e'};
      overallPass = false;
    } finally {
      if (fixtureFile != null) {
        try {
          if (await fixtureFile.exists()) {
            await fixtureFile.delete();
          }
        } catch (_) {}
      }
    }

    final payload = <String, dynamic>{
      'unit': 'Phase2UnitAA',
      'target': 'android_passthrough_remux_capability_client_physical',
      'pass': overallPass,
      'result': resultMap,
    };

    print(
      'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA_JSON:${jsonEncode(payload)}',
    );
    print(
      overallPass
          ? 'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA_PHYSICAL_PASS'
          : 'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_CLIENT_UNIT_AA_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass ? 'PASS' : 'FAIL';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(overallPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_status, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
