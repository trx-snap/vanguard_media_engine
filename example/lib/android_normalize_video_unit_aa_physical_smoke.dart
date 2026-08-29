// android_normalize_video_unit_aa_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit AA / Phase 2-Unit AI
// Android normalizeVideo native remux bridge physical smoke harness.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, PlatformException, rootBundle;
import 'package:vanguard_media_engine/vanguard_media_preparer.dart';

void main() {
  runApp(const AndroidNormalizeVideoUnitAAPhysicalSmokeApp());
}

class AndroidNormalizeVideoUnitAAPhysicalSmokeApp extends StatefulWidget {
  const AndroidNormalizeVideoUnitAAPhysicalSmokeApp({super.key});

  @override
  State<AndroidNormalizeVideoUnitAAPhysicalSmokeApp> createState() =>
      _AndroidNormalizeVideoUnitAAPhysicalSmokeAppState();
}

class _AndroidNormalizeVideoUnitAAPhysicalSmokeAppState
    extends State<AndroidNormalizeVideoUnitAAPhysicalSmokeApp> {
  String _status =
      'Initializing Android Normalize Video Physical Smoke (Unit AA)...';
  Timer? _timeoutTimer;

  static const MethodChannel _rawChannel = MethodChannel(
    'vanguard_media_engine',
  );

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 100), () {
      print('ANDROID_NORMALIZE_VIDEO_UNIT_AA: TIMEOUT (100s exceeded)');
      print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_PHYSICAL_FAIL');
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
    print('ANDROID_NORMALIZE_VIDEO_UNIT_AA: START');
    final runTimestamp = DateTime.now().millisecondsSinceEpoch;
    final tempDir = Directory.systemTemp.path;

    final stagedMovPath = '$tempDir/unit_aa_${runTimestamp}_staged_fixture.mov';
    final rawOutPath = '$tempDir/unit_aa_${runTimestamp}_lane_a_out.mp4';
    final existsOutPath = '$tempDir/unit_aa_${runTimestamp}_lane_b_exists.mp4';
    final missingInputPath =
        '$tempDir/unit_aa_${runTimestamp}_lane_c_missing.mov';
    final missingOutPath = '$tempDir/unit_aa_${runTimestamp}_lane_c_out.mp4';
    final lockOut1Path = '$tempDir/unit_aa_${runTimestamp}_lane_d_out1.mp4';
    final lockOut2Path = '$tempDir/unit_aa_${runTimestamp}_lane_d_out2.mp4';
    final cancelOutPath = '$tempDir/unit_aa_${runTimestamp}_lane_e_cancel.mp4';
    final laneFInputPath = '$tempDir/unit_aa_${runTimestamp}_lane_f_input.mov';
    final laneFDeterministicOutPath =
        '$tempDir/unit_aa_${runTimestamp}_lane_f_input_vg_normalized.mp4';

    final createdFiles = <String>{};

    void trackFile(String path) {
      createdFiles.add(path);
      createdFiles.add('$path.vgnormtmp');
    }

    trackFile(stagedMovPath);
    trackFile(rawOutPath);
    trackFile(existsOutPath);
    trackFile(missingOutPath);
    trackFile(lockOut1Path);
    trackFile(lockOut2Path);
    trackFile(cancelOutPath);
    trackFile(laneFInputPath);
    trackFile(laneFDeterministicOutPath);

    var laneAPass = false;
    var laneBPass = false;
    var laneCPass = false;
    var laneDPass = false;
    var laneEPass = false;
    var laneFPass = false;

    final laneAMap = <String, dynamic>{};
    final laneBMap = <String, dynamic>{};
    final laneCMap = <String, dynamic>{};
    final laneDMap = <String, dynamic>{};
    final laneEMap = <String, dynamic>{};
    final laneFMap = <String, dynamic>{};

    String? topLevelError;

    try {
      // Step 1: Stage test fixture clip_A.mov
      print(
        'ANDROID_NORMALIZE_VIDEO_UNIT_AA: Staging fixture to $stagedMovPath',
      );
      final byteData = await rootBundle.load(
        'assets/manual_test_clips/clip_A.mov',
      );
      final stagedBytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final stagedFile = File(stagedMovPath);
      await stagedFile.writeAsBytes(stagedBytes, flush: true);
      print(
        'ANDROID_NORMALIZE_VIDEO_UNIT_AA: Staged fixture size=${stagedFile.lengthSync()} bytes',
      );
      final stagedInfo = await VanguardMediaPreparer.inspectMedia(
        stagedMovPath,
      );
      print('ANDROID_NORMALIZE_VIDEO_UNIT_AA: Staged fixture info=$stagedInfo');

      // ── Lane A: Raw normalizeVideo succeeds + assertions ────────────────────
      print(
        'ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_A: START (raw normalizeVideo)',
      );
      try {
        final result = await _rawChannel.invokeMapMethod<String, dynamic>(
          'normalizeVideo',
          {'inputPath': stagedMovPath, 'outputPath': rawOutPath},
        );

        final returnedPath =
            result?['outputPath'] as String? ?? result?['path'] as String?;
        final pathMatches = returnedPath == rawOutPath;
        final rawFile = File(rawOutPath);
        final fileExists = rawFile.existsSync();
        final fileSize = fileExists ? rawFile.lengthSync() : 0;
        final videoSamples = (result?['videoSamples'] as num?)?.toInt() ?? 0;
        final proofBoundary = result?['proofBoundary'] as String?;
        final expectedBoundary =
            'native_normalize_video_execution_session_no_codec_no_exporttimeline_bypass';
        final proofBoundaryMatches = proofBoundary == expectedBoundary;

        final rawNonClaims = result?['nonClaims'] as Map<dynamic, dynamic>?;
        final nonClaims = rawNonClaims != null
            ? Map<String, dynamic>.from(rawNonClaims)
            : null;
        final roiSidecarEmitted = nonClaims?['roiSidecarEmitted'] == false;
        final faststartGuaranteed = nonClaims?['faststartGuaranteed'] == false;
        final selectiveMetadataFiltering =
            nonClaims?['selectiveMetadataFiltering'] == false;
        final connectAppTouched = nonClaims?['connectAppTouched'] == false;

        final info = await VanguardMediaPreparer.inspectMedia(rawOutPath);
        final inspectOk =
            info != null &&
            info.hasVideo &&
            (info.container == 'mp4' || info.container.isNotEmpty) &&
            info.kind == MediaKind.video;

        laneAPass =
            pathMatches &&
            fileExists &&
            fileSize > 0 &&
            videoSamples > 0 &&
            proofBoundaryMatches &&
            roiSidecarEmitted &&
            faststartGuaranteed &&
            selectiveMetadataFiltering &&
            connectAppTouched &&
            inspectOk;

        laneAMap.addAll({
          'pass': laneAPass,
          'returnedPath': returnedPath,
          'pathMatches': pathMatches,
          'fileExists': fileExists,
          'fileSize': fileSize,
          'videoSamples': videoSamples,
          'proofBoundary': proofBoundary,
          'proofBoundaryMatches': proofBoundaryMatches,
          'roiSidecarEmitted': roiSidecarEmitted,
          'faststartGuaranteed': faststartGuaranteed,
          'selectiveMetadataFiltering': selectiveMetadataFiltering,
          'connectAppTouched': connectAppTouched,
          'inspectKind': info?.kind.name,
          'inspectContainer': info?.container,
          'inspectHasVideo': info?.hasVideo,
        });
        print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_A: DONE (pass=$laneAPass)');
      } catch (e, st) {
        print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_A: ERROR: $e\n$st');
        laneAMap.addAll({'pass': false, 'error': '$e'});
      }

      // ── Lane B: Pre-existing output protection ──────────────────────────────
      print(
        'ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_B: START (OUTPUT_EXISTS protection)',
      );
      try {
        final sentinelBytes = utf8.encode(
          'SENTINEL_OUTPUT_EXISTS_PROTECTION_UNIT_AA',
        );
        final existsFile = File(existsOutPath);
        await existsFile.writeAsBytes(sentinelBytes, flush: true);

        String? caughtCode;
        try {
          await _rawChannel.invokeMapMethod<String, dynamic>('normalizeVideo', {
            'inputPath': stagedMovPath,
            'outputPath': existsOutPath,
          });
        } on PlatformException catch (pe) {
          caughtCode = pe.code;
        }

        final codeMatches = caughtCode == 'OUTPUT_EXISTS';
        final readBack = existsFile.existsSync()
            ? await existsFile.readAsBytes()
            : <int>[];
        final bytesUnchanged = const ListEquality<int>().equals(
          readBack,
          sentinelBytes,
        );
        final tempAbsent = !File('$existsOutPath.vgnormtmp').existsSync();

        laneBPass = codeMatches && bytesUnchanged && tempAbsent;
        laneBMap.addAll({
          'pass': laneBPass,
          'caughtCode': caughtCode,
          'codeMatches': codeMatches,
          'bytesUnchanged': bytesUnchanged,
          'tempAbsent': tempAbsent,
        });
        print(
          'ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_B: DONE (pass=$laneBPass, code=$caughtCode)',
        );
      } catch (e, st) {
        print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_B: ERROR: $e\n$st');
        laneBMap.addAll({'pass': false, 'error': '$e'});
      }

      // ── Lane C: Missing source failure ──────────────────────────────────────
      print(
        'ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_C: START (FILE_UNREADABLE failure)',
      );
      try {
        String? caughtCode;
        try {
          await _rawChannel.invokeMapMethod<String, dynamic>('normalizeVideo', {
            'inputPath': missingInputPath,
            'outputPath': missingOutPath,
          });
        } on PlatformException catch (pe) {
          caughtCode = pe.code;
        }

        final codeMatches = caughtCode == 'FILE_UNREADABLE';
        final outAbsent = !File(missingOutPath).existsSync();
        final tempAbsent = !File('$missingOutPath.vgnormtmp').existsSync();

        laneCPass = codeMatches && outAbsent && tempAbsent;
        laneCMap.addAll({
          'pass': laneCPass,
          'caughtCode': caughtCode,
          'codeMatches': codeMatches,
          'outAbsent': outAbsent,
          'tempAbsent': tempAbsent,
        });
        print(
          'ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_C: DONE (pass=$laneCPass, code=$caughtCode)',
        );
      } catch (e, st) {
        print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_C: ERROR: $e\n$st');
        laneCMap.addAll({'pass': false, 'error': '$e'});
      }

      // ── Lane D: Shared export lock ──────────────────────────────────────────
      print(
        'ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_D: START (shared export lock)',
      );
      try {
        // Start first call with diagnostic hold
        final call1Future = _rawChannel
            .invokeMapMethod<String, dynamic>('normalizeVideo', {
              'inputPath': stagedMovPath,
              'outputPath': lockOut1Path,
              'diagnosticHoldBeforeRemuxMs': 1500,
            });

        // Wait 200ms into the hold
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // Start second call — must be rejected with EXPORT_IN_PROGRESS
        String? secondCallCode;
        try {
          await _rawChannel.invokeMapMethod<String, dynamic>('normalizeVideo', {
            'inputPath': stagedMovPath,
            'outputPath': lockOut2Path,
          });
        } on PlatformException catch (pe) {
          secondCallCode = pe.code;
        }

        // Await first call to finish successfully
        final call1Result = await call1Future;
        final call1Success = call1Result?['success'] == true;
        final out1File = File(lockOut1Path);
        final out1Exists = out1File.existsSync() && out1File.lengthSync() > 0;
        final lockCodeMatches = secondCallCode == 'EXPORT_IN_PROGRESS';
        final out2Absent = !File(lockOut2Path).existsSync();

        laneDPass = lockCodeMatches && call1Success && out1Exists && out2Absent;
        laneDMap.addAll({
          'pass': laneDPass,
          'secondCallCode': secondCallCode,
          'lockCodeMatches': lockCodeMatches,
          'call1Success': call1Success,
          'out1Exists': out1Exists,
          'out2Absent': out2Absent,
        });
        print(
          'ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_D: DONE (pass=$laneDPass, secondCallCode=$secondCallCode)',
        );
      } catch (e, st) {
        print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_D: ERROR: $e\n$st');
        laneDMap.addAll({'pass': false, 'error': '$e'});
      }

      // ── Lane E: Cancel during diagnostic hold ────────────────────────────────
      print(
        'ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_E: START (cancel during hold)',
      );
      try {
        final cancelFuture = _rawChannel
            .invokeMapMethod<String, dynamic>('normalizeVideo', {
              'inputPath': stagedMovPath,
              'outputPath': cancelOutPath,
              'diagnosticHoldBeforeRemuxMs': 3000,
            });

        // Wait 200ms into hold then request cancelExport
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await _rawChannel.invokeMethod<dynamic>('cancelExport');

        String? caughtCode;
        try {
          await cancelFuture;
        } on PlatformException catch (pe) {
          caughtCode = pe.code;
        }

        final cancelCodeMatches = caughtCode == 'EXPORT_CANCELLED';
        final cancelOutAbsent = !File(cancelOutPath).existsSync();
        final cancelTempAbsent = !File('$cancelOutPath.vgnormtmp').existsSync();

        laneEPass = cancelCodeMatches && cancelOutAbsent && cancelTempAbsent;
        laneEMap.addAll({
          'pass': laneEPass,
          'caughtCode': caughtCode,
          'cancelCodeMatches': cancelCodeMatches,
          'cancelOutAbsent': cancelOutAbsent,
          'cancelTempAbsent': cancelTempAbsent,
        });
        print(
          'ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_E: DONE (pass=$laneEPass, code=$caughtCode)',
        );
      } catch (e, st) {
        print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_E: ERROR: $e\n$st');
        laneEMap.addAll({'pass': false, 'error': '$e'});
      }

      // ── Lane F: VanguardMediaPreparer integration + stale delete + cleanup ──
      print(
        'ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_F: START (prepareForUpload integration)',
      );
      try {
        // Stage input copy for Lane F
        final laneFInputFile = File(laneFInputPath);
        await laneFInputFile.writeAsBytes(stagedBytes, flush: true);

        // Create pre-existing stale deterministic derived output with sentinel bytes
        final sentinelBytes = utf8.encode(
          'STALE_DERIVED_NORMALIZED_VIDEO_SENTINEL_BYTES',
        );
        final staleOutFile = File(laneFDeterministicOutPath);
        await staleOutFile.writeAsBytes(sentinelBytes, flush: true);
        final staleCreated =
            staleOutFile.existsSync() &&
            staleOutFile.lengthSync() == sentinelBytes.length;

        // Run prepareForUpload with strict policy and constraints accommodating fixture bounds
        final prepResult = await VanguardMediaPreparer.prepareForUpload(
          laneFInputFile,
          const UploadConstraints(
            maxDurationSeconds: 180,
            maxShortSidePx: 1080,
            maxBitrateKbps: 5000,
            maxFileSizeMb: 200,
            targetBitrateKbps: 1000,
            imageMaxWidthPx: 1080,
            imageJpegQuality: 0.82,
          ),
          const UploadPolicy.strict(),
        );

        final outcomeMatches = prepResult.outcome == PrepareOutcome.normalized;
        final succeeded = prepResult.succeeded;
        final resultFileExists = prepResult.file.existsSync();
        final tempPathNonNull = prepResult.tempPath != null;
        final tempPathMatches =
            prepResult.tempPath != null &&
            prepResult.tempPath!.endsWith('_vg_normalized.mp4');
        final notOriginalInput = prepResult.file.path != laneFInputPath;
        final outputSizeLargerThanSentinel =
            resultFileExists &&
            prepResult.file.lengthSync() > sentinelBytes.length;

        // Test cleanupTempFiles removes the temp output
        await VanguardMediaPreparer.cleanupTempFiles();
        final tempCleanedUp =
            prepResult.tempPath != null &&
            !File(prepResult.tempPath!).existsSync();

        laneFPass =
            staleCreated &&
            outcomeMatches &&
            succeeded &&
            resultFileExists &&
            tempPathNonNull &&
            tempPathMatches &&
            notOriginalInput &&
            outputSizeLargerThanSentinel &&
            tempCleanedUp;

        laneFMap.addAll({
          'pass': laneFPass,
          'staleCreated': staleCreated,
          'outcome': prepResult.outcome.name,
          'outcomeMatches': outcomeMatches,
          'succeeded': succeeded,
          'resultFileExists': resultFileExists,
          'tempPath': prepResult.tempPath,
          'tempPathMatches': tempPathMatches,
          'notOriginalInput': notOriginalInput,
          'outputSizeLargerThanSentinel': outputSizeLargerThanSentinel,
          'tempCleanedUp': tempCleanedUp,
        });
        print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_F: DONE (pass=$laneFPass)');
      } catch (e, st) {
        print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_LANE_F: ERROR: $e\n$st');
        laneFMap.addAll({'pass': false, 'error': '$e'});
      }
    } catch (t, st) {
      topLevelError = '$t\n$st';
      print('ANDROID_NORMALIZE_VIDEO_UNIT_AA: TOP-LEVEL ERROR: $topLevelError');
    } finally {
      // Guaranteed cleanup of all created files
      for (final p in createdFiles) {
        try {
          final f = File(p);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }

      final allPass =
          laneAPass &&
          laneBPass &&
          laneCPass &&
          laneDPass &&
          laneEPass &&
          laneFPass &&
          topLevelError == null;

      final summary = {
        'suite': 'ANDROID_NORMALIZE_VIDEO_UNIT_AA_PHYSICAL_SMOKE',
        'deviceModel': 'SM-A566B',
        'allPass': allPass,
        'lanes': {
          'laneA_rawNormalize': laneAMap,
          'laneB_outputExistsProtection': laneBMap,
          'laneC_missingSourceFailure': laneCMap,
          'laneD_sharedExportLock': laneDMap,
          'laneE_cancelDuringHold': laneEMap,
          'laneF_preparerIntegrationStaleDeleteCleanup': laneFMap,
        },
        'topLevelError': ?topLevelError,
      };

      print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_SUMMARY: ${jsonEncode(summary)}');

      if (allPass) {
        print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_PHYSICAL_PASS');
        if (mounted) {
          setState(() {
            _status = 'PASS (All 6 lanes passed)';
          });
        }
        _timeoutTimer?.cancel();
        exit(0);
      } else {
        print('ANDROID_NORMALIZE_VIDEO_UNIT_AA_PHYSICAL_FAIL');
        if (mounted) {
          setState(() {
            _status = 'FAIL';
          });
        }
        _timeoutTimer?.cancel();
        exit(1);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Android Normalize Video Unit AA Smoke'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              _status,
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

// Equality helper
class ListEquality<E> {
  const ListEquality();
  bool equals(List<E>? list1, List<E>? list2) {
    if (identical(list1, list2)) return true;
    if (list1 == null || list2 == null) return false;
    final length = list1.length;
    if (length != list2.length) return false;
    for (var i = 0; i < length; i++) {
      if (list1[i] != list2[i]) return false;
    }
    return true;
  }
}
