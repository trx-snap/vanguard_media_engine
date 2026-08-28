// android_passthrough_remux_client_physical_smoke.dart
// Vanguard Media Engine -- Phase 2-Unit AE
// Public Dart Android Passthrough Remux Execution Client Physical Smoke Test.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidPassthroughRemuxClientPhysicalSmokeApp());
}

class AndroidPassthroughRemuxClientPhysicalSmokeApp extends StatefulWidget {
  const AndroidPassthroughRemuxClientPhysicalSmokeApp({super.key});

  @override
  State<AndroidPassthroughRemuxClientPhysicalSmokeApp> createState() =>
      _AndroidPassthroughRemuxClientPhysicalSmokeAppState();
}

class _AndroidPassthroughRemuxClientPhysicalSmokeAppState
    extends State<AndroidPassthroughRemuxClientPhysicalSmokeApp> {
  String _status =
      'Initializing Android Passthrough Remux Client Physical Smoke (Unit AE)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE: TIMEOUT (45s exceeded)');
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_PHYSICAL_FAIL');
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
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE: START');
    final runId = 'unit_ae_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? fixtureFile;
    File? lane1OutputFile;
    File? lane2OutputFile;
    File? lane3SentinelFile;
    File? lane4EmptySourceOutputFile;
    File? lane5FirstOutputFile;
    File? lane5SecondOutputFile;

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
        'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE: Copying clip_B.mov to temp...',
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
        'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE: Source fixture ready at $sourcePath (${rawBytes.length} bytes)',
      );

      final client = VGPassthroughRemuxClient();

      // -- Lane 1: Primary valid client remux ---------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE1: START');
      final lane1OutputPath = '${tempDir.path}/${runId}_lane1_out.mp4';
      lane1OutputFile = File(lane1OutputPath);
      try {
        final lane1Report = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: sourcePath,
            outputPath: lane1OutputPath,
          ),
        );
        lane1Map = lane1Report.toMap();

        final outExists = await lane1OutputFile.exists();
        final outDiskBytes = outExists ? await lane1OutputFile.length() : 0;
        final outputSizeBytes = lane1Report.outputSizeBytes ?? -1;
        final diskBytesMatch =
            outExists &&
            (outDiskBytes == outputSizeBytes) &&
            (outDiskBytes > 0);

        final successFlag = lane1Report.success;
        final pathMatch =
            (lane1Report.path == lane1OutputPath) &&
            (lane1Report.outputPath == lane1OutputPath) &&
            (lane1Report.sourcePath == sourcePath);
        final videoSamples = lane1Report.videoSamples ?? 0;
        final audioSamples = lane1Report.audioSamples ?? 0;
        final width = lane1Report.width ?? 0;
        final height = lane1Report.height ?? 0;
        final durationSeconds = lane1Report.durationSeconds ?? 0.0;
        final hasAudioTrack = lane1Report.hasAudioTrack == true;
        final proofBoundaryMatch = lane1Report.proofBoundaryMatches;
        final nonClaimsMatch = lane1Report.diagnosticNonClaimsHold;
        final outputWritten = lane1Report.outputWritten;

        lane1Pass =
            successFlag &&
            outExists &&
            diskBytesMatch &&
            outputWritten &&
            pathMatch &&
            videoSamples > 0 &&
            audioSamples > 0 &&
            width > 0 &&
            height > 0 &&
            durationSeconds > 0 &&
            hasAudioTrack &&
            proofBoundaryMatch &&
            nonClaimsMatch;

        lane1Map['computed_pass'] = lane1Pass;
        lane1Map['outDiskBytes'] = outDiskBytes;
        lane1Map['outExists'] = outExists;
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE1: DONE (pass=$lane1Pass, videoSamples=$videoSamples, audioSamples=$audioSamples, bytes=$outDiskBytes)',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE1: ERROR: $e\n$st');
        lane1Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane1Pass = false;
      }

      // -- Lane 2: Missing source through client ------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE2: START');
      final missingSourcePath =
          '${tempDir.path}/${runId}_missing_nonexistent.mov';
      final lane2OutputPath = '${tempDir.path}/${runId}_lane2_out.mp4';
      lane2OutputFile = File(lane2OutputPath);
      final lane2TempFile = File('$lane2OutputPath.vgptmp');
      try {
        final lane2Report = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: missingSourcePath,
            outputPath: lane2OutputPath,
          ),
        );
        lane2Map = lane2Report.toMap();

        final outExists = await lane2OutputFile.exists();
        final tempExists = await lane2TempFile.exists();
        final codeMatch = lane2Report.errorCode == 'FILE_UNREADABLE';
        lane2Pass =
            !lane2Report.success && codeMatch && !outExists && !tempExists;

        lane2Map['computed_pass'] = lane2Pass;
        lane2Map['outExists'] = outExists;
        lane2Map['tempExists'] = tempExists;
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE2: DONE (pass=$lane2Pass, code=${lane2Report.errorCode}, outExists=$outExists, tempExists=$tempExists)',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE2: ERROR: $e\n$st');
        lane2Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane2Pass = false;
      }

      // -- Lane 3: Existing output sentinel through client --------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE3: START');
      final lane3OutputPath = '${tempDir.path}/${runId}_lane3_sentinel.mp4';
      lane3SentinelFile = File(lane3OutputPath);
      final lane3TempFile = File('$lane3OutputPath.vgptmp');
      const sentinelContent =
          'SENTINEL_PRE_EXISTING_UNIT_AE_OUTPUT_BYTES_GUARD';
      try {
        await lane3SentinelFile.writeAsString(sentinelContent, flush: true);

        final lane3Report = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: sourcePath,
            outputPath: lane3OutputPath,
          ),
        );
        lane3Map = lane3Report.toMap();

        final sentinelStillExists = await lane3SentinelFile.exists();
        final currentSentinelContent = sentinelStillExists
            ? await lane3SentinelFile.readAsString()
            : '';
        final sentinelPreserved =
            sentinelStillExists && (currentSentinelContent == sentinelContent);
        final tempExists = await lane3TempFile.exists();
        final codeMatch = lane3Report.errorCode == 'OUTPUT_EXISTS';

        lane3Pass =
            !lane3Report.success &&
            codeMatch &&
            sentinelPreserved &&
            !tempExists;

        lane3Map['computed_pass'] = lane3Pass;
        lane3Map['sentinelPreserved'] = sentinelPreserved;
        lane3Map['tempExists'] = tempExists;
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE3: DONE (pass=$lane3Pass, code=${lane3Report.errorCode}, sentinelPreserved=$sentinelPreserved, tempExists=$tempExists)',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE3: ERROR: $e\n$st');
        lane3Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane3Pass = false;
      }

      // -- Lane 4: Local validation -------------------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE4: START');
      final lane4EmptySourceOutputPath =
          '${tempDir.path}/${runId}_lane4_blank_source_out.mp4';
      lane4EmptySourceOutputFile = File(lane4EmptySourceOutputPath);
      final lane4EmptySourceTempFile = File(
        '$lane4EmptySourceOutputPath.vgptmp',
      );
      try {
        final blankSourceRequest = VGPassthroughRemuxRequest(
          sourcePath: '   ',
          outputPath: lane4EmptySourceOutputPath,
        );
        final blankSourceReport = await client.export(blankSourceRequest);

        final blankOutputRequest = VGPassthroughRemuxRequest(
          sourcePath: sourcePath,
          outputPath: '  \t\n  ',
        );
        final blankOutputReport = await client.export(blankOutputRequest);

        final emptySourceOutExists = await lane4EmptySourceOutputFile.exists();
        final emptySourceTempExists = await lane4EmptySourceTempFile.exists();

        final blankSourcePass =
            !blankSourceReport.success &&
            (blankSourceReport.errorCode == 'source_path_empty') &&
            !emptySourceOutExists &&
            !emptySourceTempExists;

        final blankOutputPass =
            !blankOutputReport.success &&
            (blankOutputReport.errorCode == 'output_path_empty');

        lane4Pass = blankSourcePass && blankOutputPass;

        lane4Map = <String, dynamic>{
          'pass': lane4Pass,
          'blankSourcePass': blankSourcePass,
          'blankOutputPass': blankOutputPass,
          'blankSourceErrorCode': blankSourceReport.errorCode,
          'blankOutputErrorCode': blankOutputReport.errorCode,
          'emptySourceOutExists': emptySourceOutExists,
          'emptySourceTempExists': emptySourceTempExists,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE4: DONE (pass=$lane4Pass, blankSourceCode=${blankSourceReport.errorCode}, blankOutputCode=${blankOutputReport.errorCode})',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE4: ERROR: $e\n$st');
        lane4Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane4Pass = false;
      }

      // -- Lane 5: Concurrency through client ---------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE5: START');
      final lane5FirstOutputPath =
          '${tempDir.path}/${runId}_lane5_first_out.mp4';
      final lane5SecondOutputPath =
          '${tempDir.path}/${runId}_lane5_second_out.mp4';
      lane5FirstOutputFile = File(lane5FirstOutputPath);
      lane5SecondOutputFile = File(lane5SecondOutputPath);
      final lane5SecondTempFile = File('$lane5SecondOutputPath.vgptmp');
      try {
        final firstFuture = client.export(
          VGPassthroughRemuxRequest(
            sourcePath: sourcePath,
            outputPath: lane5FirstOutputPath,
            diagnosticHoldBeforeRemuxMs: 1200,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        final secondReport = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: sourcePath,
            outputPath: lane5SecondOutputPath,
          ),
        );

        final firstReport = await firstFuture;

        final firstSuccess = firstReport.success;
        final firstOutExists = await lane5FirstOutputFile.exists();
        final firstOutBytes = firstOutExists
            ? await lane5FirstOutputFile.length()
            : 0;
        final secondCodeMatch = secondReport.errorCode == 'EXPORT_IN_PROGRESS';
        final secondSuccessFalse = !secondReport.success;
        final secondOutExists = await lane5SecondOutputFile.exists();
        final secondTempExists = await lane5SecondTempFile.exists();

        lane5Pass =
            secondCodeMatch &&
            secondSuccessFalse &&
            firstSuccess &&
            firstOutExists &&
            firstOutBytes > 0 &&
            !secondOutExists &&
            !secondTempExists;

        lane5Map = <String, dynamic>{
          'pass': lane5Pass,
          'secondErrorCode': secondReport.errorCode,
          'firstSuccess': firstSuccess,
          'firstOutExists': firstOutExists,
          'firstOutBytes': firstOutBytes,
          'secondOutExists': secondOutExists,
          'secondTempExists': secondTempExists,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE5: DONE (pass=$lane5Pass, secondCode=${secondReport.errorCode}, firstSuccess=$firstSuccess, firstBytes=$firstOutBytes)',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE5: ERROR: $e\n$st');
        lane5Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane5Pass = false;
      }

      // -- Lane 6: Proof and non-claims summary -------------------------------
      print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE6: START');
      try {
        final lane1ProofBoundary = lane1Map['proofBoundary'] as String? ?? '';
        final lane1NonClaims = lane1Map['nonClaims'] is Map
            ? (lane1Map['nonClaims'] as Map).cast<String, dynamic>()
            : <String, dynamic>{};

        final boundaryValid =
            (lane1ProofBoundary ==
            VGPassthroughRemuxExecutionReport.expectedProofBoundary);
        final nonClaimsOnlyFour = lane1NonClaims.length == 4;
        final nonClaimsValuesFalse =
            lane1NonClaims['mediaCodecAllocated'] == false &&
            lane1NonClaims['productionExportTimelineBypass'] == false &&
            lane1NonClaims['cppPassthroughRemuxSinkNode'] == false &&
            lane1NonClaims['connectAppTouched'] == false;

        final nonClaimsValid = nonClaimsOnlyFour && nonClaimsValuesFalse;

        lane6Pass = lane1Pass && boundaryValid && nonClaimsValid;

        lane6Map = <String, dynamic>{
          'pass': lane6Pass,
          'proofBoundary': lane1ProofBoundary,
          'proofBoundaryValid': boundaryValid,
          'nonClaims': lane1NonClaims,
          'nonClaimsValid': nonClaimsValid,
        };
        print(
          'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE6: DONE (pass=$lane6Pass, boundaryValid=$boundaryValid, nonClaimsValid=$nonClaimsValid)',
        );
      } catch (e, st) {
        print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE6: ERROR: $e\n$st');
        lane6Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane6Pass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // -- Clean up only harness-owned temp files -----------------------------
      for (final f in [
        fixtureFile,
        lane1OutputFile,
        lane2OutputFile,
        lane3SentinelFile,
        lane4EmptySourceOutputFile,
        lane5FirstOutputFile,
        lane5SecondOutputFile,
        if (lane1OutputFile != null) File('${lane1OutputFile.path}.vgptmp'),
        if (lane2OutputFile != null) File('${lane2OutputFile.path}.vgptmp'),
        if (lane3SentinelFile != null) File('${lane3SentinelFile.path}.vgptmp'),
        if (lane4EmptySourceOutputFile != null)
          File('${lane4EmptySourceOutputFile.path}.vgptmp'),
        if (lane5FirstOutputFile != null)
          File('${lane5FirstOutputFile.path}.vgptmp'),
        if (lane5SecondOutputFile != null)
          File('${lane5SecondOutputFile.path}.vgptmp'),
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

    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE1_PASS: $lane1Pass');
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE2_PASS: $lane2Pass');
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE3_PASS: $lane3Pass');
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE4_PASS: $lane4Pass');
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE5_PASS: $lane5Pass');
    print('ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_LANE6_PASS: $lane6Pass');

    final allPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        lane5Pass &&
        lane6Pass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase2UnitAE',
      'target': 'android_passthrough_remux_client_physical',
      'pass': allPass,
      'lanes': <String, dynamic>{
        'lane1_primary_remux': lane1Map,
        'lane2_missing_source_guard': lane2Map,
        'lane3_output_exists_guard': lane3Map,
        'lane4_local_validation_guard': lane4Map,
        'lane5_concurrency_guard': lane5Map,
        'lane6_proof_nonclaims_summary': lane6Map,
      },
      'proofBoundary': VGPassthroughRemuxExecutionReport.expectedProofBoundary,
      'error': topLevelError,
    };

    print(
      'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_JSON:${jsonEncode(payload)}',
    );
    print(
      allPass
          ? 'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_PHYSICAL_PASS'
          : 'ANDROID_PASSTHROUGH_REMUX_CLIENT_UNIT_AE_PHYSICAL_FAIL',
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
