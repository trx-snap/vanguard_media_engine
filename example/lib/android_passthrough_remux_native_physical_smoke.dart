// android_passthrough_remux_native_physical_smoke.dart
// Vanguard Media Engine - Phase 2-Unit X
// Android native passthrough remux diagnostic route and physical proof foundation.
//
// Proves native MediaExtractor + MediaMuxer single-source stream copy via
// AndroidAudioRemuxer without MediaCodec allocation and without production
// exportTimeline bypass.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidPassthroughRemuxNativePhysicalSmokeApp());
}

class AndroidPassthroughRemuxNativePhysicalSmokeApp extends StatefulWidget {
  const AndroidPassthroughRemuxNativePhysicalSmokeApp({super.key});

  @override
  State<AndroidPassthroughRemuxNativePhysicalSmokeApp> createState() =>
      _AndroidPassthroughRemuxNativePhysicalSmokeAppState();
}

class _AndroidPassthroughRemuxNativePhysicalSmokeAppState
    extends State<AndroidPassthroughRemuxNativePhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Initializing Android Passthrough Remux Native Smoke (Unit X)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      print('ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X: TIMEOUT (30s exceeded)');
      print('ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X_PHYSICAL_FAIL');
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
    print('ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X: START');
    Map<String, dynamic> resultMap = <String, dynamic>{};
    var overallPass = false;
    File? fixtureFile;
    String? primaryOutputPath;
    String? guardOutputPath;

    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      final runId = DateTime.now().millisecondsSinceEpoch;
      fixtureFile = File(
        '${tempDir.path}/passthrough_remux_unit_x_${runId}_clip_b.mov',
      );
      await fixtureFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      final response = await _channel.invokeMethod<Object?>(
        'runAndroidPassthroughRemuxNativeSmoke',
        <String, Object>{
          'sourcePath': fixtureFile.path,
          'outputDir': tempDir.path,
        },
      );

      if (response is Map) {
        resultMap = _deepStringKeyed(response);
      } else {
        resultMap = <String, dynamic>{
          'pass': false,
          'error': 'Unexpected response type: ${response.runtimeType}',
        };
      }

      final nativePass = resultMap['pass'] == true;
      final proofBoundary =
          resultMap['proofBoundary'] ==
          'native_passthrough_remux_diagnostic_mediaextractor_mediamuxer_no_codec_no_exporttimeline';

      final primary =
          resultMap['primary'] as Map<String, dynamic>? ?? <String, dynamic>{};
      primaryOutputPath = primary['outputPath'] as String?;
      final primaryPass =
          primary['pass'] == true &&
          primary['outputExists'] == true &&
          (primary['outputSizeBytes'] as num? ?? 0) > 0 &&
          primary['reportedOutputSizeBytes'] == primary['outputSizeBytes'] &&
          (primary['videoSamples'] as num? ?? 0) > 0 &&
          (primary['audioSamples'] as num? ?? 0) > 0 &&
          primary['extractorOpened'] == true &&
          primary['muxerStarted'] == true &&
          primary['sourceFileRead'] == true &&
          primary['outputFileWritten'] == true &&
          primary['codecAllocated'] == false;

      final guard =
          resultMap['guard'] as Map<String, dynamic>? ?? <String, dynamic>{};
      guardOutputPath = guard['outputPath'] as String?;
      final guardPass =
          guard['pass'] == true &&
          guard['outputExists'] == false &&
          (guard['reason'] as String? ?? '').isNotEmpty;

      final nonClaims =
          resultMap['nonClaims'] as Map<String, dynamic>? ??
          <String, dynamic>{};
      final nonClaimsPass =
          nonClaims['productionExportTimelineBypass'] == false &&
          nonClaims['cppPassthroughRemuxSinkNode'] == false &&
          nonClaims['codecAllocated'] == false &&
          nonClaims['videoDecoded'] == false &&
          nonClaims['audioDecoded'] == false &&
          nonClaims['bitExactPayloadCompared'] == false &&
          nonClaims['connectAppTouched'] == false;

      overallPass =
          nativePass &&
          proofBoundary &&
          primaryPass &&
          guardPass &&
          nonClaimsPass;

      print('ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X_NATIVE_PASS: $nativePass');
      print(
        'ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X_PROOF_BOUNDARY: $proofBoundary',
      );
      print(
        'ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X_PRIMARY_PASS: $primaryPass',
      );
      print('ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X_GUARD_PASS: $guardPass');
      print(
        'ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X_NON_CLAIMS_PASS: $nonClaimsPass',
      );
    } catch (e, st) {
      print('ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X: ERROR: $e\n$st');
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
      if (primaryOutputPath != null) {
        try {
          final f = File(primaryOutputPath);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }
      if (guardOutputPath != null) {
        try {
          final f = File(guardOutputPath);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }
    }

    final payload = <String, dynamic>{
      'unit': 'Phase2UnitX',
      'target': 'android_physical',
      'pass': overallPass,
      'result': resultMap,
    };

    print(
      'ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X_JSON:${jsonEncode(payload)}',
    );
    print(
      overallPass
          ? 'ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X_PHYSICAL_PASS'
          : 'ANDROID_PASSTHROUGH_REMUX_NATIVE_UNIT_X_PHYSICAL_FAIL',
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
