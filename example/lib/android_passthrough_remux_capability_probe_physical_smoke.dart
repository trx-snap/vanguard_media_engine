// android_passthrough_remux_capability_probe_physical_smoke.dart
// Vanguard Media Engine - Phase 2-Unit Z
// Android native passthrough remux source capability probe physical proof.
//
// Proves native MediaExtractor track-format compatibility probe without muxing,
// without decoding, without reading samples, and without production
// exportTimeline bypass.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidPassthroughRemuxCapabilityProbePhysicalSmokeApp());
}

class AndroidPassthroughRemuxCapabilityProbePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidPassthroughRemuxCapabilityProbePhysicalSmokeApp({super.key});

  @override
  State<AndroidPassthroughRemuxCapabilityProbePhysicalSmokeApp> createState() =>
      _AndroidPassthroughRemuxCapabilityProbePhysicalSmokeAppState();
}

class _AndroidPassthroughRemuxCapabilityProbePhysicalSmokeAppState
    extends State<AndroidPassthroughRemuxCapabilityProbePhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Initializing Android Passthrough Remux Capability Probe Smoke (Unit Z)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z: TIMEOUT (30s exceeded)',
      );
      print('ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z_PHYSICAL_FAIL');
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
    print('ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z: START');
    Map<String, dynamic> resultMap = <String, dynamic>{};
    var overallPass = false;
    File? fixtureFile;
    File? invalidFile;

    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final runId = DateTime.now().millisecondsSinceEpoch;

      // 1. Valid fixture preparation
      fixtureFile = File(
        '${tempDir.path}/passthrough_remux_capability_unit_z_${runId}_clip_b.mov',
      );
      await fixtureFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      // 2. Invalid text file preparation
      invalidFile = File(
        '${tempDir.path}/passthrough_remux_capability_unit_z_${runId}_invalid.txt',
      );
      await invalidFile.writeAsString(
        'This is not a valid media file.',
        flush: true,
      );

      // 3. Unique missing path
      final missingPath =
          '${tempDir.path}/passthrough_remux_capability_unit_z_${runId}_missing.mp4';

      // -- Lane 1: Valid fixture lane -----------------------------------------
      final lane1Response = await _channel.invokeMethod<Object?>(
        'runAndroidPassthroughRemuxCapabilityProbeSmoke',
        <String, Object>{'sourcePath': fixtureFile.path},
      );
      final lane1Map = lane1Response is Map
          ? _deepStringKeyed(lane1Response)
          : <String, dynamic>{};

      final lane1CanRemux = lane1Map['canPassthroughRemux'] == true;
      final lane1ExtractorOpened = lane1Map['extractorOpened'] == true;
      final lane1FileExists = lane1Map['fileExists'] == true;
      final lane1FileReadable = lane1Map['fileReadable'] == true;
      final lane1TrackCount = (lane1Map['trackCount'] as num? ?? 0) > 0;
      final lane1Boundary =
          lane1Map['proofBoundary'] ==
          'native_passthrough_remux_capability_probe_no_mux_no_decode_no_samples';

      final lane1Video =
          lane1Map['video'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final lane1VideoMime = lane1Video['mime'] as String? ?? '';
      final lane1VideoSupported =
          lane1Video['supported'] == true &&
          (lane1VideoMime == 'video/avc' || lane1VideoMime == 'video/hevc');

      final lane1Audio = lane1Map['audio'] as Map<String, dynamic>?;
      final lane1AudioSupported =
          lane1Audio == null ||
          (lane1Audio['supported'] == true &&
              lane1Audio['mime'] == 'audio/mp4a-latm');

      final lane1NonClaims =
          lane1Map['nonClaims'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final lane1NonClaimsPass =
          lane1NonClaims['mediaMuxerStarted'] == false &&
          lane1NonClaims['mediaCodecAllocated'] == false &&
          lane1NonClaims['samplesRead'] == false &&
          lane1NonClaims['outputFileWritten'] == false &&
          lane1NonClaims['productionExportTimelineBypass'] == false &&
          lane1NonClaims['cppPassthroughRemuxSinkNode'] == false &&
          lane1NonClaims['connectAppTouched'] == false;

      final lane1Pass =
          lane1CanRemux &&
          lane1ExtractorOpened &&
          lane1FileExists &&
          lane1FileReadable &&
          lane1TrackCount &&
          lane1Boundary &&
          lane1VideoSupported &&
          lane1AudioSupported &&
          lane1NonClaimsPass;

      // -- Lane 2: Missing source lane ----------------------------------------
      final lane2Response = await _channel.invokeMethod<Object?>(
        'runAndroidPassthroughRemuxCapabilityProbeSmoke',
        <String, Object>{'sourcePath': missingPath},
      );
      final lane2Map = lane2Response is Map
          ? _deepStringKeyed(lane2Response)
          : <String, dynamic>{};

      final lane2Reason = lane2Map['reason'] as String? ?? '';
      final lane2Pass =
          lane2Map['canPassthroughRemux'] == false &&
          lane2Map['fileExists'] == false &&
          lane2Map['extractorOpened'] == false &&
          lane2Reason.startsWith('source_missing_or_unreadable');

      // -- Lane 3: Invalid file lane ------------------------------------------
      final lane3Response = await _channel.invokeMethod<Object?>(
        'runAndroidPassthroughRemuxCapabilityProbeSmoke',
        <String, Object>{'sourcePath': invalidFile.path},
      );
      final lane3Map = lane3Response is Map
          ? _deepStringKeyed(lane3Response)
          : <String, dynamic>{};

      final lane3Reason = lane3Map['reason'] as String? ?? '';
      final lane3Video = lane3Map['video'] as Map<String, dynamic>?;
      final lane3Pass =
          lane3Map['canPassthroughRemux'] == false &&
          lane3Map['fileExists'] == true &&
          (lane3Map['extractorOpened'] == false ||
              lane3Video == null ||
              lane3Video['supported'] != true) &&
          lane3Reason.isNotEmpty;

      overallPass = lane1Pass && lane2Pass && lane3Pass;

      resultMap = <String, dynamic>{
        'pass': overallPass,
        'lane1_valid': lane1Map,
        'lane2_missing': lane2Map,
        'lane3_invalid': lane3Map,
      };

      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z_LANE1_PASS: $lane1Pass',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z_LANE2_PASS: $lane2Pass',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z_LANE3_PASS: $lane3Pass',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z_PROOF_BOUNDARY: $lane1Boundary',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z_NON_CLAIMS: $lane1NonClaimsPass',
      );
    } catch (e, st) {
      print('ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z: ERROR: $e\n$st');
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
      if (invalidFile != null) {
        try {
          if (await invalidFile.exists()) {
            await invalidFile.delete();
          }
        } catch (_) {}
      }
    }

    final payload = <String, dynamic>{
      'unit': 'Phase2UnitZ',
      'target': 'android_physical',
      'pass': overallPass,
      'result': resultMap,
    };

    print(
      'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z_JSON:${jsonEncode(payload)}',
    );
    print(
      overallPass
          ? 'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z_PHYSICAL_PASS'
          : 'ANDROID_PASSTHROUGH_REMUX_CAPABILITY_UNIT_Z_PHYSICAL_FAIL',
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

  Map<String, dynamic> _deepStringKeyed(Map<Object?, Object?> map) {
    final out = <String, dynamic>{};
    map.forEach((key, value) {
      out['$key'] = value is Map<Object?, Object?>
          ? _deepStringKeyed(value)
          : value;
    });
    return out;
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
