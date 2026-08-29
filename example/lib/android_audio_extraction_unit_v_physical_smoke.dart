// android_audio_extraction_unit_v_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit V / Phase 4-Unit D
// Managed Android Asynchronous Audio Extraction Parity Physical Smoke Test.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioExtractionUnitVPhysicalSmokeApp());
}

class AndroidAudioExtractionUnitVPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioExtractionUnitVPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioExtractionUnitVPhysicalSmokeApp> createState() =>
      _AndroidAudioExtractionUnitVPhysicalSmokeAppState();
}

class _AndroidAudioExtractionUnitVPhysicalSmokeAppState
    extends State<AndroidAudioExtractionUnitVPhysicalSmokeApp> {
  String _status =
      'Initializing Android Audio Extraction Physical Smoke (Unit V)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 90), () {
      print('ANDROID_AUDIO_EXTRACTION_UNIT_V: TIMEOUT (90s exceeded)');
      print('ANDROID_AUDIO_EXTRACTION_UNIT_V_PHYSICAL_FAIL');
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
    print('ANDROID_AUDIO_EXTRACTION_UNIT_V: START');
    final runId = 'unit_v_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? aacFixtureFile;
    File? mp3FixtureFile;
    File? lane1OutputFile;
    File? lane2OutputFile;
    File? lane3OutputFile1;
    File? lane3OutputFile2;
    File? lane4OutputFile;
    File? lane5RetryOutputFile;
    File? lane6PreexistingFile;
    File? lane8OutputFile;
    File? lane9OutputFile;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    const lane7Status = 'NOT_VERIFIED';
    const lane7Reason =
        'No standalone video-only container asset available in pre-existing test fixtures without project/dependency mutation';
    var lane8Pass = false;
    var lane9Pass = false;

    Map<String, dynamic> lane1Map = <String, dynamic>{};
    Map<String, dynamic> lane2Map = <String, dynamic>{};
    Map<String, dynamic> lane3Map = <String, dynamic>{};
    Map<String, dynamic> lane4Map = <String, dynamic>{};
    Map<String, dynamic> lane5Map = <String, dynamic>{};
    Map<String, dynamic> lane6Map = <String, dynamic>{};
    final Map<String, dynamic> lane7Map = <String, dynamic>{
      'status': lane7Status,
      'reason': lane7Reason,
      'verified': false,
    };
    Map<String, dynamic> lane8Map = <String, dynamic>{};
    Map<String, dynamic> lane9Map = <String, dynamic>{};

    String? topLevelError;

    try {
      // ── Copy Asset Fixtures to Temp ─────────────────────────────────────────
      print('ANDROID_AUDIO_EXTRACTION_UNIT_V: Copying clip_A.mov to temp...');
      final clipByteData = await rootBundle.load(
        'assets/manual_test_clips/clip_A.mov',
      );
      final aacBytes = clipByteData.buffer.asUint8List(
        clipByteData.offsetInBytes,
        clipByteData.lengthInBytes,
      );
      aacFixtureFile = File('${tempDir.path}/${runId}_source_clip_A.mov');
      await aacFixtureFile.writeAsBytes(aacBytes, flush: true);
      final aacSourcePath = aacFixtureFile.path;
      print(
        'ANDROID_AUDIO_EXTRACTION_UNIT_V: AAC fixture ready at $aacSourcePath (${aacBytes.length} bytes)',
      );

      print('ANDROID_AUDIO_EXTRACTION_UNIT_V: Copying clip_A.mp3 to temp...');
      final mp3ByteData = await rootBundle.load(
        'assets/manual_test_clips/clip_A.mp3',
      );
      final mp3Bytes = mp3ByteData.buffer.asUint8List(
        mp3ByteData.offsetInBytes,
        mp3ByteData.lengthInBytes,
      );
      mp3FixtureFile = File('${tempDir.path}/${runId}_source_clip_A.mp3');
      await mp3FixtureFile.writeAsBytes(mp3Bytes, flush: true);
      final mp3SourcePath = mp3FixtureFile.path;
      print(
        'ANDROID_AUDIO_EXTRACTION_UNIT_V: MP3 fixture ready at $mp3SourcePath (${mp3Bytes.length} bytes)',
      );

      // ── Lane 1: Happy path AAC source extraction ────────────────────────────
      print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE1: START (happy path AAC)');
      final lane1OutputPath = '${tempDir.path}/${runId}_lane1_happy.m4a';
      lane1OutputFile = File(lane1OutputPath);
      final lane1TempFile = File('$lane1OutputPath.vgatmp');
      try {
        final begin1 = VGAudioExtractionService.begin(
          operationId: '${runId}_lane1',
          sourcePath: aacSourcePath,
          outputPath: lane1OutputPath,
        );

        if (begin1 is! VGAudioExtractionBeginStarted) {
          throw StateError(
            'Expected VGAudioExtractionBeginStarted, got $begin1',
          );
        }

        final res1 = await begin1.operation.result;
        final outExists = await lane1OutputFile.exists();
        final outBytes = outExists ? await lane1OutputFile.length() : 0;
        final tempExists = await lane1TempFile.exists();

        final isSuccess = res1 is VGAudioExtractionSuccess;
        final pathMatches = isSuccess && res1.outputPath == lane1OutputPath;

        lane1Pass =
            isSuccess &&
            pathMatches &&
            outExists &&
            (outBytes > 0) &&
            !tempExists;

        lane1Map = <String, dynamic>{
          'pass': lane1Pass,
          'isSuccess': isSuccess,
          'pathMatches': pathMatches,
          'outExists': outExists,
          'outBytes': outBytes,
          'tempExists': tempExists,
        };
        print(
          'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE1: DONE (pass=$lane1Pass, bytes=$outBytes, tempExists=$tempExists)',
        );
      } catch (e, st) {
        print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE1: ERROR: $e\n$st');
        lane1Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane1Pass = false;
      }

      // ── Lane 2: Trimmed extraction [start, end) ─────────────────────────────
      print(
        'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE2: START (trimmed extraction)',
      );
      final lane2OutputPath = '${tempDir.path}/${runId}_lane2_trim.m4a';
      lane2OutputFile = File(lane2OutputPath);
      final lane2TempFile = File('$lane2OutputPath.vgatmp');
      try {
        final begin2 = VGAudioExtractionService.begin(
          operationId: '${runId}_lane2',
          sourcePath: aacSourcePath,
          outputPath: lane2OutputPath,
          trimStartSeconds: 1.0,
          trimEndSeconds: 3.5,
        );

        if (begin2 is! VGAudioExtractionBeginStarted) {
          throw StateError(
            'Expected VGAudioExtractionBeginStarted, got $begin2',
          );
        }

        final res2 = await begin2.operation.result;
        final outExists = await lane2OutputFile.exists();
        final outBytes = outExists ? await lane2OutputFile.length() : 0;
        final tempExists = await lane2TempFile.exists();

        final isSuccess = res2 is VGAudioExtractionSuccess;
        final pathMatches = isSuccess && res2.outputPath == lane2OutputPath;
        final lane1Bytes = lane1OutputFile.existsSync()
            ? lane1OutputFile.lengthSync()
            : 0;
        final isTrimmedSmaller =
            outBytes > 0 && (lane1Bytes == 0 || outBytes < lane1Bytes);

        lane2Pass =
            isSuccess &&
            pathMatches &&
            outExists &&
            (outBytes > 0) &&
            isTrimmedSmaller &&
            !tempExists;

        lane2Map = <String, dynamic>{
          'pass': lane2Pass,
          'isSuccess': isSuccess,
          'pathMatches': pathMatches,
          'outExists': outExists,
          'outBytes': outBytes,
          'isTrimmedSmaller': isTrimmedSmaller,
          'tempExists': tempExists,
        };
        print(
          'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE2: DONE (pass=$lane2Pass, bytes=$outBytes, fullBytes=$lane1Bytes)',
        );
      } catch (e, st) {
        print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE2: ERROR: $e\n$st');
        lane2Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane2Pass = false;
      }

      // ── Lane 3: Duplicate active operationId rejection ──────────────────────
      print(
        'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE3: START (duplicate operationId)',
      );
      final lane3OutputPath1 = '${tempDir.path}/${runId}_lane3_dup1.m4a';
      final lane3OutputPath2 = '${tempDir.path}/${runId}_lane3_dup2.m4a';
      lane3OutputFile1 = File(lane3OutputPath1);
      lane3OutputFile2 = File(lane3OutputPath2);
      final lane3TempFile2 = File('$lane3OutputPath2.vgatmp');
      try {
        final dupOpId = '${runId}_lane3_dup_op';
        final begin3A = VGAudioExtractionService.begin(
          operationId: dupOpId,
          sourcePath: aacSourcePath,
          outputPath: lane3OutputPath1,
        );
        final begin3B = VGAudioExtractionService.begin(
          operationId: dupOpId,
          sourcePath: aacSourcePath,
          outputPath: lane3OutputPath2,
        );

        if (begin3A is! VGAudioExtractionBeginStarted ||
            begin3B is! VGAudioExtractionBeginStarted) {
          throw StateError(
            'Expected VGAudioExtractionBeginStarted for both begin calls',
          );
        }

        final res3B = await begin3B.operation.result;
        final res3A = await begin3A.operation.result;

        final is3BAlreadyExists =
            res3B is VGAudioExtractionFailure &&
            res3B.error == VGAudioExtractionError.operationAlreadyExists;
        final is3ASuccess = res3A is VGAudioExtractionSuccess;
        final out1Exists = await lane3OutputFile1.exists();
        final out2Exists = await lane3OutputFile2.exists();
        final temp2Exists = await lane3TempFile2.exists();

        lane3Pass =
            is3BAlreadyExists &&
            is3ASuccess &&
            out1Exists &&
            !out2Exists &&
            !temp2Exists;

        lane3Map = <String, dynamic>{
          'pass': lane3Pass,
          'is3BAlreadyExists': is3BAlreadyExists,
          'is3ASuccess': is3ASuccess,
          'out1Exists': out1Exists,
          'out2Exists': out2Exists,
          'temp2Exists': temp2Exists,
        };
        print(
          'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE3: DONE (pass=$lane3Pass, dupRejected=$is3BAlreadyExists, primarySuccess=$is3ASuccess)',
        );
      } catch (e, st) {
        print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE3: ERROR: $e\n$st');
        lane3Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane3Pass = false;
      }

      // ── Lane 4: Active cancel ───────────────────────────────────────────────
      print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE4: START (active cancel)');
      final lane4OutputPath = '${tempDir.path}/${runId}_lane4_cancel.m4a';
      lane4OutputFile = File(lane4OutputPath);
      final lane4TempFile = File('$lane4OutputPath.vgatmp');
      try {
        final begin4 = VGAudioExtractionService.begin(
          operationId: '${runId}_lane4',
          sourcePath: aacSourcePath,
          outputPath: lane4OutputPath,
        );

        if (begin4 is! VGAudioExtractionBeginStarted) {
          throw StateError(
            'Expected VGAudioExtractionBeginStarted, got $begin4',
          );
        }

        // Cancel immediately while extraction is in progress
        final cancelDisp = await begin4.operation.cancel();
        final res4 = await begin4.operation.result;

        final outExists = await lane4OutputFile.exists();
        final tempExists = await lane4TempFile.exists();

        final dispValid =
            cancelDisp ==
            VGAudioExtractionCancelDisposition.cancellationCompleted;
        final isCancelled =
            res4 is VGAudioExtractionFailure &&
            res4.error == VGAudioExtractionError.cancelled;

        lane4Pass = dispValid && isCancelled && !outExists && !tempExists;

        lane4Map = <String, dynamic>{
          'pass': lane4Pass,
          'disposition': cancelDisp.name,
          'dispValid': dispValid,
          'isCancelled': isCancelled,
          'outExists': outExists,
          'tempExists': tempExists,
        };
        print(
          'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE4: DONE (pass=$lane4Pass, disp=${cancelDisp.name}, isCancelled=$isCancelled, outExists=$outExists)',
        );
      } catch (e, st) {
        print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE4: ERROR: $e\n$st');
        lane4Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane4Pass = false;
      }

      // ── Lane 5: Late cancel, unknown cancel, retry with same ID ─────────────
      print(
        'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE5: START (late cancel, unknown cancel, retry)',
      );
      final lane5RetryOutputPath = '${tempDir.path}/${runId}_lane5_retry.m4a';
      lane5RetryOutputFile = File(lane5RetryOutputPath);
      try {
        // Part A: Late cancel on already completed terminal operation (from Lane 1)
        final begin1 =
            VGAudioExtractionService.begin(
                  operationId: '${runId}_lane5_completed',
                  sourcePath: aacSourcePath,
                  outputPath: '${tempDir.path}/${runId}_lane5_temp_comp.m4a',
                )
                as VGAudioExtractionBeginStarted;
        await begin1.operation.result;
        final lateDisp = await begin1.operation.cancel();
        final latePass =
            lateDisp == VGAudioExtractionCancelDisposition.alreadyTerminal;

        // Part B: Unknown cancel on non-existent operation ID via MethodChannel
        final rawNotFound = await const MethodChannel('vanguard_media_engine')
            .invokeMethod<Map<Object?, Object?>>('cancelAudioExtraction', {
              'operationId': '${runId}_never_registered',
            });
        final notFoundPass = rawNotFound?['disposition'] == 'notFound';

        // Part C: Retry with same terminal ID is accepted and succeeds
        final beginRetry = VGAudioExtractionService.begin(
          operationId: '${runId}_lane5_completed',
          sourcePath: aacSourcePath,
          outputPath: lane5RetryOutputPath,
        );
        if (beginRetry is! VGAudioExtractionBeginStarted) {
          throw StateError('Expected VGAudioExtractionBeginStarted on retry');
        }
        final resRetry = await beginRetry.operation.result;
        final retryPass =
            resRetry is VGAudioExtractionSuccess &&
            resRetry.outputPath == lane5RetryOutputPath &&
            await lane5RetryOutputFile.exists() &&
            (await lane5RetryOutputFile.length()) > 0;

        lane5Pass = latePass && notFoundPass && retryPass;

        lane5Map = <String, dynamic>{
          'pass': lane5Pass,
          'lateDisp': lateDisp.name,
          'latePass': latePass,
          'notFoundRaw': rawNotFound?['disposition'],
          'notFoundPass': notFoundPass,
          'retryPass': retryPass,
        };
        print(
          'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE5: DONE (pass=$lane5Pass, late=$latePass, notFound=$notFoundPass, retry=$retryPass)',
        );
      } catch (e, st) {
        print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE5: ERROR: $e\n$st');
        lane5Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane5Pass = false;
      }

      // ── Lane 6: Pre-existing output path rejection ──────────────────────────
      print(
        'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE6: START (pre-existing output path)',
      );
      final lane6PreexistingPath =
          '${tempDir.path}/${runId}_lane6_preexisting.m4a';
      lane6PreexistingFile = File(lane6PreexistingPath);
      final lane6TempFile = File('$lane6PreexistingPath.vgatmp');
      try {
        const canaryBytes = 'CANARY_PREEXISTING_BYTES_PROTECTION_CHECK';
        await lane6PreexistingFile.writeAsString(canaryBytes, flush: true);

        final begin6 = VGAudioExtractionService.begin(
          operationId: '${runId}_lane6',
          sourcePath: aacSourcePath,
          outputPath: lane6PreexistingPath,
        );

        if (begin6 is! VGAudioExtractionBeginStarted) {
          throw StateError(
            'Expected VGAudioExtractionBeginStarted, got $begin6',
          );
        }

        final res6 = await begin6.operation.result;
        final fileExists = await lane6PreexistingFile.exists();
        final contentMatches =
            fileExists &&
            (await lane6PreexistingFile.readAsString()) == canaryBytes;
        final tempExists = await lane6TempFile.exists();

        final isWriteFailure =
            res6 is VGAudioExtractionFailure &&
            res6.error == VGAudioExtractionError.writeFailure;

        lane6Pass =
            isWriteFailure && fileExists && contentMatches && !tempExists;

        lane6Map = <String, dynamic>{
          'pass': lane6Pass,
          'isWriteFailure': isWriteFailure,
          'fileExists': fileExists,
          'contentMatches': contentMatches,
          'tempExists': tempExists,
        };
        print(
          'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE6: DONE (pass=$lane6Pass, isWriteFailure=$isWriteFailure, canaryIntact=$contentMatches)',
        );
      } catch (e, st) {
        print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE6: ERROR: $e\n$st');
        lane6Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane6Pass = false;
      }

      // ── Lane 7: No-audio source (documented as NOT_VERIFIED per contract) ───
      print(
        'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE7: $lane7Status ($lane7Reason)',
      );

      // ── Lane 8: Zero-sample trim start past EOF ─────────────────────────────
      print(
        'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE8: START (trim start past EOF)',
      );
      final lane8OutputPath = '${tempDir.path}/${runId}_lane8_past_eof.m4a';
      lane8OutputFile = File(lane8OutputPath);
      final lane8TempFile = File('$lane8OutputPath.vgatmp');
      try {
        final begin8 = VGAudioExtractionService.begin(
          operationId: '${runId}_lane8',
          sourcePath: aacSourcePath,
          outputPath: lane8OutputPath,
          trimStartSeconds: 99999.0,
          trimEndSeconds: 999999.0,
        );

        if (begin8 is! VGAudioExtractionBeginStarted) {
          throw StateError(
            'Expected VGAudioExtractionBeginStarted, got $begin8',
          );
        }

        final res8 = await begin8.operation.result;
        final outExists = await lane8OutputFile.exists();
        final tempExists = await lane8TempFile.exists();

        final isInvalidArgument =
            res8 is VGAudioExtractionFailure &&
            res8.error == VGAudioExtractionError.invalidArgument;

        lane8Pass = isInvalidArgument && !outExists && !tempExists;

        lane8Map = <String, dynamic>{
          'pass': lane8Pass,
          'isInvalidArgument': isInvalidArgument,
          'outExists': outExists,
          'tempExists': tempExists,
        };
        print(
          'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE8: DONE (pass=$lane8Pass, isInvalidArgument=$isInvalidArgument, outExists=$outExists)',
        );
      } catch (e, st) {
        print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE8: ERROR: $e\n$st');
        lane8Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane8Pass = false;
      }

      // ── Lane 9: Unsupported non-AAC audio (MP3 fixture) ─────────────────────
      print(
        'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE9: START (unsupported non-AAC MP3)',
      );
      final lane9OutputPath = '${tempDir.path}/${runId}_lane9_mp3.m4a';
      lane9OutputFile = File(lane9OutputPath);
      final lane9TempFile = File('$lane9OutputPath.vgatmp');
      try {
        final begin9 = VGAudioExtractionService.begin(
          operationId: '${runId}_lane9',
          sourcePath: mp3SourcePath,
          outputPath: lane9OutputPath,
        );

        if (begin9 is! VGAudioExtractionBeginStarted) {
          throw StateError(
            'Expected VGAudioExtractionBeginStarted, got $begin9',
          );
        }

        final res9 = await begin9.operation.result;
        final outExists = await lane9OutputFile.exists();
        final tempExists = await lane9TempFile.exists();

        final isInvalidArgument =
            res9 is VGAudioExtractionFailure &&
            res9.error == VGAudioExtractionError.invalidArgument;

        lane9Pass = isInvalidArgument && !outExists && !tempExists;

        lane9Map = <String, dynamic>{
          'pass': lane9Pass,
          'isInvalidArgument': isInvalidArgument,
          'outExists': outExists,
          'tempExists': tempExists,
        };
        print(
          'ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE9: DONE (pass=$lane9Pass, isInvalidArgument=$isInvalidArgument, outExists=$outExists)',
        );
      } catch (e, st) {
        print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE9: ERROR: $e\n$st');
        lane9Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane9Pass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_AUDIO_EXTRACTION_UNIT_V: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // ── Guaranteed Cleanup of Harness-Owned Files ───────────────────────────
      final filesToClean = [
        aacFixtureFile,
        mp3FixtureFile,
        lane1OutputFile,
        lane2OutputFile,
        lane3OutputFile1,
        lane3OutputFile2,
        lane4OutputFile,
        lane5RetryOutputFile,
        lane6PreexistingFile,
        lane8OutputFile,
        lane9OutputFile,
        File('${tempDir.path}/${runId}_lane5_temp_comp.m4a'),
        if (lane1OutputFile != null) File('${lane1OutputFile.path}.vgatmp'),
        if (lane2OutputFile != null) File('${lane2OutputFile.path}.vgatmp'),
        if (lane3OutputFile1 != null) File('${lane3OutputFile1.path}.vgatmp'),
        if (lane3OutputFile2 != null) File('${lane3OutputFile2.path}.vgatmp'),
        if (lane4OutputFile != null) File('${lane4OutputFile.path}.vgatmp'),
        if (lane5RetryOutputFile != null)
          File('${lane5RetryOutputFile.path}.vgatmp'),
        if (lane6PreexistingFile != null)
          File('${lane6PreexistingFile.path}.vgatmp'),
        if (lane8OutputFile != null) File('${lane8OutputFile.path}.vgatmp'),
        if (lane9OutputFile != null) File('${lane9OutputFile.path}.vgatmp'),
      ];

      for (final f in filesToClean) {
        if (f != null) {
          try {
            if (await f.exists()) {
              await f.delete();
            }
          } catch (_) {}
        }
      }
    }

    print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE1_PASS: $lane1Pass');
    print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE2_PASS: $lane2Pass');
    print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE3_PASS: $lane3Pass');
    print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE4_PASS: $lane4Pass');
    print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE5_PASS: $lane5Pass');
    print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE6_PASS: $lane6Pass');
    print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE7_STATUS: $lane7Status');
    print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE8_PASS: $lane8Pass');
    print('ANDROID_AUDIO_EXTRACTION_UNIT_V_LANE9_PASS: $lane9Pass');

    final allRequiredPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        lane5Pass &&
        lane6Pass &&
        lane8Pass &&
        lane9Pass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase5UnitV_Phase4UnitD',
      'target': 'android_audio_extraction_physical',
      'pass': allRequiredPass,
      'lanes': <String, dynamic>{
        'lane1_happy_path_aac': lane1Map,
        'lane2_trimmed_extraction': lane2Map,
        'lane3_duplicate_operation_id': lane3Map,
        'lane4_active_cancel': lane4Map,
        'lane5_late_cancel_unknown_retry': lane5Map,
        'lane6_preexisting_output_path': lane6Map,
        'lane7_no_audio_source': lane7Map,
        'lane8_trim_past_eof': lane8Map,
        'lane9_unsupported_non_aac': lane9Map,
      },
      'error': topLevelError,
    };

    print('ANDROID_AUDIO_EXTRACTION_UNIT_V_JSON:${jsonEncode(payload)}');
    print(
      allRequiredPass
          ? 'ANDROID_AUDIO_EXTRACTION_UNIT_V_PHYSICAL_PASS'
          : 'ANDROID_AUDIO_EXTRACTION_UNIT_V_PHYSICAL_FAIL',
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
