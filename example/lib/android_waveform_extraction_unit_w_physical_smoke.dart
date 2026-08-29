// android_waveform_extraction_unit_w_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit W / Phase 4-Unit E
// Android Offline Audio Waveform Extraction Parity Physical Smoke Test.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, PlatformException, rootBundle;
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidWaveformExtractionUnitWPhysicalSmokeApp());
}

class AndroidWaveformExtractionUnitWPhysicalSmokeApp extends StatefulWidget {
  const AndroidWaveformExtractionUnitWPhysicalSmokeApp({super.key});

  @override
  State<AndroidWaveformExtractionUnitWPhysicalSmokeApp> createState() =>
      _AndroidWaveformExtractionUnitWPhysicalSmokeAppState();
}

class _AndroidWaveformExtractionUnitWPhysicalSmokeAppState
    extends State<AndroidWaveformExtractionUnitWPhysicalSmokeApp> {
  String _status =
      'Initializing Android Waveform Extraction Physical Smoke (Unit W)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 90), () {
      print('ANDROID_WAVEFORM_UNIT_W: TIMEOUT (90s exceeded)');
      print('ANDROID_WAVEFORM_UNIT_W_PHYSICAL_FAIL');
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
    print('ANDROID_WAVEFORM_UNIT_W: START');
    final runId = 'unit_w_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? clipFixtureFile;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    const lane6Status = 'UNIT_TEST_ONLY';
    const lane6Reason =
        'Waveform disk cache backing is a separate slice; cache routing and bypass contract is verified in vg_waveform_extractor_test.dart (WAVE-16..27)';
    const lane7Status = 'NOT_VERIFIED';
    const lane7Reason =
        'No standalone video-only container asset available in pre-existing test fixtures without project/dependency mutation';

    Map<String, dynamic> lane1Map = <String, dynamic>{};
    Map<String, dynamic> lane2Map = <String, dynamic>{};
    Map<String, dynamic> lane3Map = <String, dynamic>{};
    Map<String, dynamic> lane4Map = <String, dynamic>{};
    Map<String, dynamic> lane5Map = <String, dynamic>{};
    final Map<String, dynamic> lane6Map = <String, dynamic>{
      'status': lane6Status,
      'reason': lane6Reason,
      'verifiedInUnitTests': true,
    };
    final Map<String, dynamic> lane7Map = <String, dynamic>{
      'status': lane7Status,
      'reason': lane7Reason,
      'verified': false,
    };

    String? topLevelError;

    try {
      // ── Copy Asset Fixture to Temp ──────────────────────────────────────────
      print('ANDROID_WAVEFORM_UNIT_W: Copying clip_A.mov to temp...');
      final clipByteData = await rootBundle.load(
        'assets/manual_test_clips/clip_A.mov',
      );
      final clipBytes = clipByteData.buffer.asUint8List(
        clipByteData.offsetInBytes,
        clipByteData.lengthInBytes,
      );
      clipFixtureFile = File('${tempDir.path}/${runId}_source_clip_A.mov');
      await clipFixtureFile.writeAsBytes(clipBytes, flush: true);
      final sourcePath = clipFixtureFile.path;
      print(
        'ANDROID_WAVEFORM_UNIT_W: Fixture ready at $sourcePath (${clipBytes.length} bytes)',
      );

      // ── Lane 1: Happy Path Extraction (50 samples/sec) ──────────────────────
      print('ANDROID_WAVEFORM_UNIT_W_LANE1: START (happy path 50 sps)');
      try {
        final res1 = await VGAudioWaveformExtractor.extract(
          path: sourcePath,
          samplesPerSecond: 50,
          maxDurationSeconds: 600.0,
        );

        final samplesNotNull = (res1.samples as Object?) is Float32List;
        final pointCountValid = res1.pointCount > 0;
        final durationValid = res1.durationSeconds > 0;
        final spsMatches = res1.samplesPerSecond == 50;
        final countMatchesLength = res1.pointCount == res1.samples.length;

        var allInRange = true;
        var minVal = 1.0;
        var maxVal = 0.0;
        for (final sample in res1.samples) {
          if (sample < 0.0 || sample > 1.0) {
            allInRange = false;
          }
          if (sample < minVal) minVal = sample.toDouble();
          if (sample > maxVal) maxVal = sample.toDouble();
        }

        lane1Pass =
            samplesNotNull &&
            pointCountValid &&
            durationValid &&
            spsMatches &&
            countMatchesLength &&
            allInRange;

        lane1Map = <String, dynamic>{
          'pass': lane1Pass,
          'samplesNotNull': samplesNotNull,
          'pointCount': res1.pointCount,
          'durationSeconds': res1.durationSeconds,
          'samplesPerSecond': res1.samplesPerSecond,
          'allInRange': allInRange,
          'minSample': minVal,
          'maxSample': maxVal,
        };
        print(
          'ANDROID_WAVEFORM_UNIT_W_LANE1: DONE (pass=$lane1Pass, pointCount=${res1.pointCount}, duration=${res1.durationSeconds.toStringAsFixed(2)}s, min=$minVal, max=$maxVal)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_UNIT_W_LANE1: ERROR: $e\n$st');
        lane1Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane1Pass = false;
      }

      // ── Lane 2: Density Variation (100 samples/sec) ─────────────────────────
      print('ANDROID_WAVEFORM_UNIT_W_LANE2: START (density variation 100 sps)');
      try {
        final res2 = await VGAudioWaveformExtractor.extract(
          path: sourcePath,
          samplesPerSecond: 100,
          maxDurationSeconds: 600.0,
        );

        final pointCountIncreased =
            lane1Map['pointCount'] != null &&
            res2.pointCount > (lane1Map['pointCount'] as int);
        final spsMatches = res2.samplesPerSecond == 100;
        final countMatchesLength = res2.pointCount == res2.samples.length;

        var allInRange = true;
        for (final sample in res2.samples) {
          if (sample < 0.0 || sample > 1.0) {
            allInRange = false;
          }
        }

        lane2Pass =
            pointCountIncreased &&
            spsMatches &&
            countMatchesLength &&
            allInRange;

        lane2Map = <String, dynamic>{
          'pass': lane2Pass,
          'pointCount': res2.pointCount,
          'durationSeconds': res2.durationSeconds,
          'samplesPerSecond': res2.samplesPerSecond,
          'pointCountIncreased': pointCountIncreased,
          'allInRange': allInRange,
        };
        print(
          'ANDROID_WAVEFORM_UNIT_W_LANE2: DONE (pass=$lane2Pass, pointCount=${res2.pointCount} vs ${lane1Map['pointCount']}, duration=${res2.durationSeconds.toStringAsFixed(2)}s)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_UNIT_W_LANE2: ERROR: $e\n$st');
        lane2Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane2Pass = false;
      }

      // ── Lane 3: Duration Exceeded Error ─────────────────────────────────────
      print('ANDROID_WAVEFORM_UNIT_W_LANE3: START (duration exceeded check)');
      try {
        var threwExpected = false;
        String? caughtCode;
        try {
          await VGAudioWaveformExtractor.extract(
            path: sourcePath,
            samplesPerSecond: 50,
            maxDurationSeconds: 0.001,
          );
        } on PlatformException catch (e) {
          caughtCode = e.code;
          threwExpected = e.code == 'DURATION_EXCEEDED';
        }

        lane3Pass = threwExpected;
        lane3Map = <String, dynamic>{
          'pass': lane3Pass,
          'caughtCode': caughtCode,
          'expectedCode': 'DURATION_EXCEEDED',
        };
        print(
          'ANDROID_WAVEFORM_UNIT_W_LANE3: DONE (pass=$lane3Pass, caughtCode=$caughtCode)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_UNIT_W_LANE3: ERROR: $e\n$st');
        lane3Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane3Pass = false;
      }

      // ── Lane 4: Invalid Native Arguments via Direct MethodChannel ───────────
      print('ANDROID_WAVEFORM_UNIT_W_LANE4: START (native INVALID_ARG check)');
      try {
        const channel = MethodChannel('vanguard_media_engine');

        // Part A: Blank path
        String? codeBlankPath;
        try {
          await channel.invokeMapMethod<String, dynamic>('extractWaveform', {
            'path': '',
            'samplesPerSecond': 50,
            'maxDurationSeconds': 600.0,
          });
        } on PlatformException catch (e) {
          codeBlankPath = e.code;
        }

        // Part B: Invalid samplesPerSecond (0)
        String? codeInvalidSps;
        try {
          await channel.invokeMapMethod<String, dynamic>('extractWaveform', {
            'path': sourcePath,
            'samplesPerSecond': 0,
            'maxDurationSeconds': 600.0,
          });
        } on PlatformException catch (e) {
          codeInvalidSps = e.code;
        }

        // Part C: Invalid maxDurationSeconds (-1.0)
        String? codeInvalidDuration;
        try {
          await channel.invokeMapMethod<String, dynamic>('extractWaveform', {
            'path': sourcePath,
            'samplesPerSecond': 50,
            'maxDurationSeconds': -1.0,
          });
        } on PlatformException catch (e) {
          codeInvalidDuration = e.code;
        }

        final blankPass = codeBlankPath == 'INVALID_ARG';
        final spsPass = codeInvalidSps == 'INVALID_ARG';
        final durPass = codeInvalidDuration == 'INVALID_ARG';

        lane4Pass = blankPass && spsPass && durPass;
        lane4Map = <String, dynamic>{
          'pass': lane4Pass,
          'codeBlankPath': codeBlankPath,
          'codeInvalidSps': codeInvalidSps,
          'codeInvalidDuration': codeInvalidDuration,
        };
        print(
          'ANDROID_WAVEFORM_UNIT_W_LANE4: DONE (pass=$lane4Pass, blank=$codeBlankPath, sps=$codeInvalidSps, dur=$codeInvalidDuration)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_UNIT_W_LANE4: ERROR: $e\n$st');
        lane4Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane4Pass = false;
      }

      // ── Lane 5: Missing Source Path Error ───────────────────────────────────
      print('ANDROID_WAVEFORM_UNIT_W_LANE5: START (missing source path check)');
      try {
        final missingPath = '${tempDir.path}/${runId}_missing_audio_file.mov';
        var threwExpected = false;
        String? caughtCode;
        try {
          await VGAudioWaveformExtractor.extract(
            path: missingPath,
            samplesPerSecond: 50,
            maxDurationSeconds: 600.0,
          );
        } on PlatformException catch (e) {
          caughtCode = e.code;
          threwExpected = e.code == 'READER_SETUP_FAILED';
        }

        lane5Pass = threwExpected;
        lane5Map = <String, dynamic>{
          'pass': lane5Pass,
          'caughtCode': caughtCode,
          'expectedCode': 'READER_SETUP_FAILED',
        };
        print(
          'ANDROID_WAVEFORM_UNIT_W_LANE5: DONE (pass=$lane5Pass, caughtCode=$caughtCode)',
        );
      } catch (e, st) {
        print('ANDROID_WAVEFORM_UNIT_W_LANE5: ERROR: $e\n$st');
        lane5Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane5Pass = false;
      }

      // ── Lane 6: Cache Integration Check (Unit-test only per contract) ─────
      print('ANDROID_WAVEFORM_UNIT_W_LANE6: $lane6Status ($lane6Reason)');

      // ── Lane 7: No-Audio Source Check (Documented NOT_VERIFIED) ─────────────
      print('ANDROID_WAVEFORM_UNIT_W_LANE7: $lane7Status ($lane7Reason)');
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_WAVEFORM_UNIT_W: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // ── Guaranteed Cleanup of Harness-Owned Temp Files ──────────────────────
      if (clipFixtureFile != null) {
        try {
          if (await clipFixtureFile.exists()) {
            await clipFixtureFile.delete();
          }
        } catch (_) {}
      }
    }

    print('ANDROID_WAVEFORM_UNIT_W_LANE1_PASS: $lane1Pass');
    print('ANDROID_WAVEFORM_UNIT_W_LANE2_PASS: $lane2Pass');
    print('ANDROID_WAVEFORM_UNIT_W_LANE3_PASS: $lane3Pass');
    print('ANDROID_WAVEFORM_UNIT_W_LANE4_PASS: $lane4Pass');
    print('ANDROID_WAVEFORM_UNIT_W_LANE5_PASS: $lane5Pass');
    print('ANDROID_WAVEFORM_UNIT_W_LANE6_STATUS: $lane6Status');
    print('ANDROID_WAVEFORM_UNIT_W_LANE7_STATUS: $lane7Status');

    final allRequiredPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        lane5Pass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase5UnitW_Phase4UnitE',
      'target': 'android_waveform_extraction_physical',
      'pass': allRequiredPass,
      'lanes': <String, dynamic>{
        'lane1_happy_path': lane1Map,
        'lane2_density_variation': lane2Map,
        'lane3_duration_exceeded': lane3Map,
        'lane4_invalid_native_args': lane4Map,
        'lane5_missing_path': lane5Map,
        'lane6_cache_integration': lane6Map,
        'lane7_no_audio_source': lane7Map,
      },
      'error': topLevelError,
    };

    print('ANDROID_WAVEFORM_UNIT_W_JSON:${jsonEncode(payload)}');
    print(
      allRequiredPass
          ? 'ANDROID_WAVEFORM_UNIT_W_PHYSICAL_PASS'
          : 'ANDROID_WAVEFORM_UNIT_W_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allRequiredPass ? 'PASS' : 'FAIL';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(allRequiredPass ? 0 : 1);
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
