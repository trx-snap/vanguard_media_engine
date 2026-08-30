// android_passthrough_remux_session_physical_smoke.dart
// Vanguard Media Engine -- Phase 2-Unit AD
// Android Native Passthrough Remux Production Execution Session Foundation Physical Smoke.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidPassthroughRemuxSessionPhysicalSmokeApp());
}

class AndroidPassthroughRemuxSessionPhysicalSmokeApp extends StatefulWidget {
  const AndroidPassthroughRemuxSessionPhysicalSmokeApp({super.key});

  @override
  State<AndroidPassthroughRemuxSessionPhysicalSmokeApp> createState() =>
      _AndroidPassthroughRemuxSessionPhysicalSmokeAppState();
}

class _AndroidPassthroughRemuxSessionPhysicalSmokeAppState
    extends State<AndroidPassthroughRemuxSessionPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  static const String _expectedProofBoundary =
      'native_passthrough_remux_execution_session_cpp_sink_validated_no_codec_no_exporttimeline_bypass';

  String _status =
      'Initializing Android Passthrough Remux Session Physical Smoke (Unit AD)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      print(
        'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD: TIMEOUT (45s exceeded)',
      );
      print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_PHYSICAL_FAIL');
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
    print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD: START');
    final runId = 'unit_ad_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? fixtureFile;
    File? lane1OutputFile;
    File? lane2OutputFile;
    File? lane3SentinelFile;
    File? lane4FirstOutputFile;
    File? lane4SecondOutputFile;
    File? lane5OutputFile;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;

    Map<String, dynamic> lane1Map = <String, dynamic>{};
    Map<String, dynamic> lane2Map = <String, dynamic>{};
    Map<String, dynamic> lane3Map = <String, dynamic>{};
    Map<String, dynamic> lane4Map = <String, dynamic>{};
    Map<String, dynamic> lane5Map = <String, dynamic>{};
    Map<String, dynamic> lane6Map = <String, dynamic>{};

    String? topLevelError;

    try {
      // -- Copy Asset Fixture to System Temp ---------------------------------
      print(
        'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD: Copying clip_B.mov to temp...',
      );
      final clipByteData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final rawBytes = clipByteData.buffer.asUint8List(
        clipByteData.offsetInBytes,
        clipByteData.lengthInBytes,
      );

      fixtureFile = File('${tempDir.path}/${runId}_source_clip_B.mov');
      await fixtureFile.writeAsBytes(rawBytes, flush: true);
      final sourcePath = fixtureFile.path;
      print(
        'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD: Source fixture ready at $sourcePath (${rawBytes.length} bytes)',
      );

      // -- Lane 1: Primary remux ---------------------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE1: START');
      final lane1OutputPath = '${tempDir.path}/${runId}_lane1_out.mp4';
      lane1OutputFile = File(lane1OutputPath);
      try {
        final lane1Response = await _channel.invokeMethod<Object?>(
          'exportPassthroughRemux',
          <String, Object>{
            'sourcePath': sourcePath,
            'outputPath': lane1OutputPath,
          },
        );
        lane1Map = lane1Response is Map
            ? _deepStringKeyed(lane1Response)
            : <String, dynamic>{};

        final outExists = await lane1OutputFile.exists();
        final outDiskBytes = outExists ? await lane1OutputFile.length() : 0;
        final outputSizeBytes =
            (lane1Map['outputSizeBytes'] as num?)?.toInt() ?? -1;
        final diskBytesMatch =
            outExists &&
            (outDiskBytes == outputSizeBytes) &&
            (outDiskBytes > 0);

        final successFlag = lane1Map['success'] == true;
        final pathMatch =
            (lane1Map['path'] == lane1OutputPath) &&
            (lane1Map['outputPath'] == lane1OutputPath);
        final videoSamples = (lane1Map['videoSamples'] as num?)?.toInt() ?? 0;
        final audioSamples = (lane1Map['audioSamples'] as num?)?.toInt() ?? 0;
        final width = (lane1Map['width'] as num?)?.toInt() ?? 0;
        final height = (lane1Map['height'] as num?)?.toInt() ?? 0;
        final durationSeconds =
            (lane1Map['durationSeconds'] as num?)?.toDouble() ?? 0.0;
        final hasAudioTrack = lane1Map['hasAudioTrack'] == true;
        final proofBoundary = lane1Map['proofBoundary'] as String? ?? '';
        final proofBoundaryMatch = proofBoundary == _expectedProofBoundary;

        final nonClaims = lane1Map['nonClaims'] is Map
            ? _deepStringKeyed(lane1Map['nonClaims'] as Map)
            : <String, dynamic>{};
        final nonClaimsMatch =
            nonClaims['mediaCodecAllocated'] == false &&
            nonClaims['productionExportTimelineBypass'] == false &&
            nonClaims['cppPassthroughRemuxSinkNodeOwnsMuxing'] == false &&
            nonClaims['connectAppTouched'] == false;

        final cppSinkValidated =
            lane1Map['cppPassthroughRemuxSinkNodeValidated'] == true;
        final validationRaw =
            lane1Map['nativePassthroughSinkValidationRaw'] as String? ?? '';
        final validationRawMatch =
            validationRaw.contains('status=PASS') &&
            validationRaw.contains('directPath=true') &&
            validationRaw.contains('sinkActive=true');
        final destroyRaw =
            lane1Map['nativePassthroughSinkDestroyRaw'] as String? ?? '';
        final destroyRawMatch = destroyRaw.contains('status=PASS');
        final durationUsCoerced =
            (lane1Map['nativePassthroughSinkDurationUsCoerced'] as num?)
                ?.toInt() ??
            0;
        final durationUsCoercedMatch = durationUsCoerced > 0;

        lane1Pass =
            successFlag &&
            pathMatch &&
            outExists &&
            diskBytesMatch &&
            videoSamples > 0 &&
            audioSamples > 0 &&
            width > 0 &&
            height > 0 &&
            durationSeconds > 0 &&
            hasAudioTrack &&
            proofBoundaryMatch &&
            cppSinkValidated &&
            validationRawMatch &&
            destroyRawMatch &&
            durationUsCoercedMatch &&
            nonClaimsMatch;

        lane1Map['computed_pass'] = lane1Pass;
        lane1Map['outDiskBytes'] = outDiskBytes;
        lane1Map['outExists'] = outExists;
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE1: DONE (pass=$lane1Pass, videoSamples=$videoSamples, audioSamples=$audioSamples, bytes=$outDiskBytes)',
        );
      } catch (e, st) {
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE1: ERROR: $e\n$st',
        );
        lane1Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane1Pass = false;
      }

      // -- Lane 2: Missing source guard --------------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE2: START');
      final missingSourcePath =
          '${tempDir.path}/${runId}_missing_nonexistent.mov';
      final lane2OutputPath = '${tempDir.path}/${runId}_lane2_out.mp4';
      lane2OutputFile = File(lane2OutputPath);
      final lane2TempFile = File('$lane2OutputPath.vgptmp');
      try {
        String? lane2ErrorCode;
        try {
          await _channel.invokeMethod<Object?>(
            'exportPassthroughRemux',
            <String, Object>{
              'sourcePath': missingSourcePath,
              'outputPath': lane2OutputPath,
            },
          );
        } on PlatformException catch (pe) {
          lane2ErrorCode = pe.code;
        }

        final outExists = await lane2OutputFile.exists();
        final tempExists = await lane2TempFile.exists();
        final codeMatch = lane2ErrorCode == 'FILE_UNREADABLE';
        lane2Pass = codeMatch && !outExists && !tempExists;

        lane2Map = <String, dynamic>{
          'pass': lane2Pass,
          'errorCode': lane2ErrorCode,
          'outExists': outExists,
          'tempExists': tempExists,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE2: DONE (pass=$lane2Pass, code=$lane2ErrorCode, outExists=$outExists, tempExists=$tempExists)',
        );
      } catch (e, st) {
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE2: ERROR: $e\n$st',
        );
        lane2Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane2Pass = false;
      }

      // -- Lane 3: Output exists guard ---------------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE3: START');
      final lane3OutputPath = '${tempDir.path}/${runId}_lane3_sentinel.mp4';
      lane3SentinelFile = File(lane3OutputPath);
      final lane3TempFile = File('$lane3OutputPath.vgptmp');
      const sentinelContent =
          'SENTINEL_PRE_EXISTING_UNIT_AD_OUTPUT_BYTES_GUARD';
      try {
        await lane3SentinelFile.writeAsString(sentinelContent, flush: true);

        String? lane3ErrorCode;
        try {
          await _channel.invokeMethod<Object?>(
            'exportPassthroughRemux',
            <String, Object>{
              'sourcePath': sourcePath,
              'outputPath': lane3OutputPath,
            },
          );
        } on PlatformException catch (pe) {
          lane3ErrorCode = pe.code;
        }

        final sentinelStillExists = await lane3SentinelFile.exists();
        final currentSentinelContent = sentinelStillExists
            ? await lane3SentinelFile.readAsString()
            : '';
        final sentinelPreserved =
            sentinelStillExists && (currentSentinelContent == sentinelContent);
        final tempExists = await lane3TempFile.exists();
        final codeMatch = lane3ErrorCode == 'OUTPUT_EXISTS';

        lane3Pass = codeMatch && sentinelPreserved && !tempExists;

        lane3Map = <String, dynamic>{
          'pass': lane3Pass,
          'errorCode': lane3ErrorCode,
          'sentinelPreserved': sentinelPreserved,
          'tempExists': tempExists,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE3: DONE (pass=$lane3Pass, code=$lane3ErrorCode, sentinelPreserved=$sentinelPreserved, tempExists=$tempExists)',
        );
      } catch (e, st) {
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE3: ERROR: $e\n$st',
        );
        lane3Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane3Pass = false;
      }

      // -- Lane 4: Concurrency guard -----------------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE4: START');
      final lane4FirstOutputPath =
          '${tempDir.path}/${runId}_lane4_first_out.mp4';
      final lane4SecondOutputPath =
          '${tempDir.path}/${runId}_lane4_second_out.mp4';
      lane4FirstOutputFile = File(lane4FirstOutputPath);
      lane4SecondOutputFile = File(lane4SecondOutputPath);
      final lane4SecondTempFile = File('$lane4SecondOutputPath.vgptmp');
      try {
        final firstFuture = _channel
            .invokeMethod<Object?>('exportPassthroughRemux', <String, Object>{
              'sourcePath': sourcePath,
              'outputPath': lane4FirstOutputPath,
              'diagnosticHoldBeforeRemuxMs': 1200,
            });

        await Future<void>.delayed(const Duration(milliseconds: 100));

        String? secondErrorCode;
        try {
          await _channel.invokeMethod<Object?>(
            'exportPassthroughRemux',
            <String, Object>{
              'sourcePath': sourcePath,
              'outputPath': lane4SecondOutputPath,
            },
          );
        } on PlatformException catch (pe) {
          secondErrorCode = pe.code;
        }

        final firstResponse = await firstFuture;
        final firstResultMap = firstResponse is Map
            ? _deepStringKeyed(firstResponse)
            : <String, dynamic>{};

        final firstSuccess = firstResultMap['success'] == true;
        final firstOutExists = await lane4FirstOutputFile.exists();
        final firstOutBytes = firstOutExists
            ? await lane4FirstOutputFile.length()
            : 0;
        final secondCodeMatch = secondErrorCode == 'EXPORT_IN_PROGRESS';
        final secondOutExists = await lane4SecondOutputFile.exists();
        final secondTempExists = await lane4SecondTempFile.exists();

        lane4Pass =
            secondCodeMatch &&
            firstSuccess &&
            firstOutExists &&
            firstOutBytes > 0 &&
            !secondOutExists &&
            !secondTempExists;

        lane4Map = <String, dynamic>{
          'pass': lane4Pass,
          'secondErrorCode': secondErrorCode,
          'firstSuccess': firstSuccess,
          'firstOutExists': firstOutExists,
          'firstOutBytes': firstOutBytes,
          'secondOutExists': secondOutExists,
          'secondTempExists': secondTempExists,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE4: DONE (pass=$lane4Pass, secondCode=$secondErrorCode, firstSuccess=$firstSuccess, firstBytes=$firstOutBytes)',
        );
      } catch (e, st) {
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE4: ERROR: $e\n$st',
        );
        lane4Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane4Pass = false;
      }

      // -- Lane 5: Cancellation before remux ---------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE5: START');
      final lane5OutputPath =
          '${tempDir.path}/${runId}_lane5_cancelled_out.mp4';
      lane5OutputFile = File(lane5OutputPath);
      final lane5TempFile = File('$lane5OutputPath.vgptmp');
      try {
        final cancelTargetFuture = _channel
            .invokeMethod<Object?>('exportPassthroughRemux', <String, Object>{
              'sourcePath': sourcePath,
              'outputPath': lane5OutputPath,
              'diagnosticHoldBeforeRemuxMs': 1500,
            });

        await Future<void>.delayed(const Duration(milliseconds: 100));

        await _channel.invokeMethod<Object?>('cancelExport');

        String? cancelErrorCode;
        try {
          await cancelTargetFuture;
        } on PlatformException catch (pe) {
          cancelErrorCode = pe.code;
        }

        final lane5OutExists = await lane5OutputFile.exists();
        final lane5TempExists = await lane5TempFile.exists();
        final cancelCodeMatch = cancelErrorCode == 'EXPORT_CANCELLED';

        lane5Pass = cancelCodeMatch && !lane5OutExists && !lane5TempExists;

        lane5Map = <String, dynamic>{
          'pass': lane5Pass,
          'errorCode': cancelErrorCode,
          'outExists': lane5OutExists,
          'tempExists': lane5TempExists,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE5: DONE (pass=$lane5Pass, code=$cancelErrorCode, outExists=$lane5OutExists, tempExists=$lane5TempExists)',
        );
      } catch (e, st) {
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE5: ERROR: $e\n$st',
        );
        lane5Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane5Pass = false;
      }

      // -- Lane 6: Proof and nonclaims summary -------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE6: START');
      try {
        final lane1ProofBoundary = lane1Map['proofBoundary'] as String? ?? '';
        final lane1NonClaims = lane1Map['nonClaims'] is Map
            ? _deepStringKeyed(lane1Map['nonClaims'] as Map)
            : <String, dynamic>{};

        final boundaryValid = lane1ProofBoundary == _expectedProofBoundary;
        final nonClaimsValid =
            lane1NonClaims['mediaCodecAllocated'] == false &&
            lane1NonClaims['productionExportTimelineBypass'] == false &&
            lane1NonClaims['cppPassthroughRemuxSinkNodeOwnsMuxing'] == false &&
            lane1NonClaims['connectAppTouched'] == false;

        final cppSinkValidated =
            lane1Map['cppPassthroughRemuxSinkNodeValidated'] == true;
        final validationRaw =
            lane1Map['nativePassthroughSinkValidationRaw'] as String? ?? '';
        final validationRawValid =
            validationRaw.contains('status=PASS') &&
            validationRaw.contains('directPath=true') &&
            validationRaw.contains('sinkActive=true');
        final destroyRaw =
            lane1Map['nativePassthroughSinkDestroyRaw'] as String? ?? '';
        final destroyRawValid = destroyRaw.contains('status=PASS');
        final durationUsCoerced =
            (lane1Map['nativePassthroughSinkDurationUsCoerced'] as num?)
                ?.toInt() ??
            0;
        final durationUsCoercedValid = durationUsCoerced > 0;

        final positiveValidationValid =
            cppSinkValidated &&
            validationRawValid &&
            destroyRawValid &&
            durationUsCoercedValid;

        lane6Pass =
            lane1Pass &&
            boundaryValid &&
            nonClaimsValid &&
            positiveValidationValid;

        lane6Map = <String, dynamic>{
          'pass': lane6Pass,
          'proofBoundary': lane1ProofBoundary,
          'proofBoundaryValid': boundaryValid,
          'nonClaims': lane1NonClaims,
          'nonClaimsValid': nonClaimsValid,
          'cppPassthroughRemuxSinkNodeValidated': cppSinkValidated,
          'nativePassthroughSinkValidationRaw': validationRaw,
          'nativePassthroughSinkDestroyRaw': destroyRaw,
          'nativePassthroughSinkDurationUsCoerced': durationUsCoerced,
          'positiveValidationValid': positiveValidationValid,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE6: DONE (pass=$lane6Pass, boundaryValid=$boundaryValid, nonClaimsValid=$nonClaimsValid, positiveValidationValid=$positiveValidationValid)',
        );
      } catch (e, st) {
        print(
          'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE6: ERROR: $e\n$st',
        );
        lane6Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane6Pass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // -- Clean up only harness-owned temp files -----------------------------
      for (final f in [
        fixtureFile,
        lane1OutputFile,
        lane2OutputFile,
        lane3SentinelFile,
        lane4FirstOutputFile,
        lane4SecondOutputFile,
        lane5OutputFile,
        if (lane1OutputFile != null) File('${lane1OutputFile.path}.vgptmp'),
        if (lane2OutputFile != null) File('${lane2OutputFile.path}.vgptmp'),
        if (lane3SentinelFile != null) File('${lane3SentinelFile.path}.vgptmp'),
        if (lane4FirstOutputFile != null)
          File('${lane4FirstOutputFile.path}.vgptmp'),
        if (lane4SecondOutputFile != null)
          File('${lane4SecondOutputFile.path}.vgptmp'),
        if (lane5OutputFile != null) File('${lane5OutputFile.path}.vgptmp'),
      ]) {
        if (f != null) {
          try {
            if (await f.exists()) {
              await f.delete();
            }
          } catch (_) {}
        }
      }
    }

    print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE1_PASS: $lane1Pass');
    print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE2_PASS: $lane2Pass');
    print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE3_PASS: $lane3Pass');
    print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE4_PASS: $lane4Pass');
    print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE5_PASS: $lane5Pass');
    print('ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_LANE6_PASS: $lane6Pass');

    final allPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        lane5Pass &&
        lane6Pass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase2UnitAD',
      'target': 'android_physical',
      'pass': allPass,
      'lanes': <String, dynamic>{
        'lane1_primary_remux': lane1Map,
        'lane2_missing_source_guard': lane2Map,
        'lane3_output_exists_guard': lane3Map,
        'lane4_concurrency_guard': lane4Map,
        'lane5_cancellation_guard': lane5Map,
        'lane6_proof_nonclaims_summary': lane6Map,
      },
      'proofBoundary': _expectedProofBoundary,
      'error': topLevelError,
    };

    print(
      'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_JSON:${jsonEncode(payload)}',
    );
    print(
      allPass
          ? 'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_PHYSICAL_PASS'
          : 'ANDROID_PASSTHROUGH_REMUX_SESSION_UNIT_AD_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass ? 'PASS' : 'FAIL';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(allPass ? 0 : 1);
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
