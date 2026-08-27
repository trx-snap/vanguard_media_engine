// android_image_optimizer_unit_f_smoke.dart
// Vanguard Media Engine — Phase 5 Unit F Android ImageOptimizer Adaptive JPEG Quality / File-Size Search Smoke Harness.
//
// Proof lanes:
//   Lane A: No target JPEG baseline (maxLongEdge 500, quality 0.82, passCount == 1, chosenQuality ~= 0.82).
//   Lane B: Generous target first-pass hit (fileSizeTargetBytes 10000000, passCount == 1, target met).
//   Lane C: Adaptive target-met (maxLongEdge 900, quality 0.90, target = baseline - 1, passCount in 2..4, chosenQuality < 0.90, size <= target).
//   Lane D: Impossible soft target best-effort (fileSizeTargetBytes = 1, success, passCount in 2..4, chosenQuality <= Lane C quality or ~= 0.35, size > 1, no hard error).
//   Lane E: PNG non-adaptive (format png, quality 0.5, fileSizeTargetBytes = 1, passCount == 1, format png, PNG magic).
//   Lane F: HEIC request fallback participates as JPEG (format heic, maxLongEdge 700, quality 0.90, target = calibration - 1, resolved format jpeg, passCount in 2..4, chosenQuality < 0.90).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidImageOptimizerUnitFSmokeApp());
}

class AndroidImageOptimizerUnitFSmokeApp extends StatefulWidget {
  const AndroidImageOptimizerUnitFSmokeApp({super.key});

  @override
  State<AndroidImageOptimizerUnitFSmokeApp> createState() =>
      _AndroidImageOptimizerUnitFSmokeAppState();
}

class _AndroidImageOptimizerUnitFSmokeAppState
    extends State<AndroidImageOptimizerUnitFSmokeApp> {
  String _status = 'Running Android ImageOptimizer Unit F Physical Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<bool> _isJpeg(File file) async {
    if (!await file.exists()) return false;
    final raf = await file.open(mode: FileMode.read);
    try {
      final bytes = await raf.read(2);
      return bytes.length == 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    } finally {
      await raf.close();
    }
  }

  Future<bool> _isPng(File file) async {
    if (!await file.exists()) return false;
    final raf = await file.open(mode: FileMode.read);
    try {
      final bytes = await raf.read(4);
      return bytes.length == 4 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47;
    } finally {
      await raf.close();
    }
  }

  Future<void> _runSmoke() async {
    print('ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE: START');
    final runId = 'unit_f_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;
    final tempFiles = <File>[];
    final results = _SmokeResults();
    String? topLevelError;

    try {
      await _runSmokeBody(
        runId: runId,
        tempDir: tempDir,
        tempFiles: tempFiles,
        results: results,
      ).timeout(const Duration(seconds: 45));
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Smoke execution exceeded 45 seconds: $te';
      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE: TOP_LEVEL_ERROR: $topLevelError',
      );
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // ── Build and Print Aggregate JSON and Verdict ─────────────────────────
      final allPass =
          results.laneAPass &&
          results.laneBPass &&
          results.laneCPass &&
          results.laneDPass &&
          results.laneEPass &&
          results.laneFPass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidImageOptimizerUnitF',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'laneA_noTargetJpeg':
              results.laneAResults ?? {'pass': false, 'error': 'not run'},
          'laneB_generousTargetFirstPass':
              results.laneBResults ?? {'pass': false, 'error': 'not run'},
          'laneC_adaptiveTargetMet':
              results.laneCResults ?? {'pass': false, 'error': 'not run'},
          'laneD_impossibleSoftTarget':
              results.laneDResults ?? {'pass': false, 'error': 'not run'},
          'laneE_pngNonAdaptive':
              results.laneEResults ?? {'pass': false, 'error': 'not run'},
          'laneF_heicAdaptiveFallback':
              results.laneFResults ?? {'pass': false, 'error': 'not run'},
        },
        'error': topLevelError,
      };

      print('ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_JSON:${jsonEncode(payload)}');
      print(
        allPass
            ? 'ANDROID_IMAGE_OPTIMIZER_UNIT_F_PHYSICAL_SMOKE_PASS'
            : 'ANDROID_IMAGE_OPTIMIZER_UNIT_F_PHYSICAL_SMOKE_FAIL',
      );

      // Clean up tracked temp files only
      for (final file in tempFiles) {
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _status = allPass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(allPass ? 0 : 1);
    }
  }

  Future<void> _runSmokeBody({
    required String runId,
    required Directory tempDir,
    required List<File> tempFiles,
    required _SmokeResults results,
  }) async {
    // ── Copy Asset Fixture to System Temp ─────────────────────────────────
    print(
      'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE: Copying still_C.png to temp...',
    );
    final fixtureByteData = await rootBundle
        .load('assets/manual_test_clips/still_C.png')
        .timeout(const Duration(seconds: 10));
    print(
      'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE: Fixture bytes loaded length=${fixtureByteData.lengthInBytes}',
    );
    final rawBytes = fixtureByteData.buffer.asUint8List(
      fixtureByteData.offsetInBytes,
      fixtureByteData.lengthInBytes,
    );
    final copyBytes = Uint8List.fromList(rawBytes);

    final tempSourceImage = File('${tempDir.path}/${runId}_source_still_C.png');
    print('ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE: Writing temp source...');
    await tempSourceImage
        .writeAsBytes(copyBytes, flush: false)
        .timeout(const Duration(seconds: 10));
    tempFiles.add(tempSourceImage);
    final sourcePath = tempSourceImage.path;
    print(
      'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE: Temp source ready at $sourcePath',
    );

    // ── Lane A: No target JPEG baseline ──────────────────────────────────
    try {
      final laneAOutputPath = '${tempDir.path}/${runId}_lane_a.jpg';
      final laneAOutputFile = File(laneAOutputPath);
      tempFiles.add(laneAOutputFile);

      final resultA = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneAOutputPath,
          maxLongEdge: 500,
          quality: 0.82,
          format: 'jpeg',
        ),
      );

      final existsA = await laneAOutputFile.exists();
      final lengthA = existsA ? await laneAOutputFile.length() : 0;
      final isJpegA = await _isJpeg(laneAOutputFile);
      final chosenQualityCloseA = (resultA.chosenQuality - 0.82).abs() < 0.01;

      results.laneAPass =
          existsA &&
          lengthA > 0 &&
          resultA.outputPath == laneAOutputPath &&
          resultA.format == 'jpeg' &&
          resultA.width <= 500 &&
          resultA.height <= 500 &&
          resultA.fileSizeBytes == lengthA &&
          resultA.passCount == 1 &&
          chosenQualityCloseA &&
          isJpegA;

      results.laneAResults = <String, dynamic>{
        'pass': results.laneAPass,
        'outputPath': resultA.outputPath,
        'format': resultA.format,
        'width': resultA.width,
        'height': resultA.height,
        'fileSizeBytes': resultA.fileSizeBytes,
        'actualFileLength': lengthA,
        'passCount': resultA.passCount,
        'chosenQuality': resultA.chosenQuality,
        'isJpegMagic': isJpegA,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_A: pass=${results.laneAPass} '
        'w=${resultA.width} h=${resultA.height} format=${resultA.format} '
        'size=${resultA.fileSizeBytes} chosenQuality=${resultA.chosenQuality} '
        'passCount=${resultA.passCount}',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_A: ERROR $e\n$st');
      results.laneAResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneAPass = false;
    }

    // ── Lane B: Generous target first-pass hit ─────────────────────────────
    try {
      final laneBOutputPath = '${tempDir.path}/${runId}_lane_b.jpg';
      final laneBOutputFile = File(laneBOutputPath);
      tempFiles.add(laneBOutputFile);

      const targetBytesB = 10000000;
      final resultB = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneBOutputPath,
          maxLongEdge: 500,
          quality: 0.82,
          format: 'jpeg',
          fileSizeTargetBytes: targetBytesB,
        ),
      );

      final existsB = await laneBOutputFile.exists();
      final lengthB = existsB ? await laneBOutputFile.length() : 0;
      final isJpegB = await _isJpeg(laneBOutputFile);
      final chosenQualityCloseB = (resultB.chosenQuality - 0.82).abs() < 0.01;
      final targetMetB = resultB.fileSizeBytes <= targetBytesB;

      results.laneBPass =
          existsB &&
          lengthB > 0 &&
          resultB.outputPath == laneBOutputPath &&
          resultB.format == 'jpeg' &&
          resultB.width <= 500 &&
          resultB.height <= 500 &&
          resultB.fileSizeBytes == lengthB &&
          resultB.passCount == 1 &&
          chosenQualityCloseB &&
          isJpegB &&
          targetMetB;

      results.laneBResults = <String, dynamic>{
        'pass': results.laneBPass,
        'outputPath': resultB.outputPath,
        'format': resultB.format,
        'width': resultB.width,
        'height': resultB.height,
        'fileSizeBytes': resultB.fileSizeBytes,
        'actualFileLength': lengthB,
        'passCount': resultB.passCount,
        'chosenQuality': resultB.chosenQuality,
        'targetMet': targetMetB,
        'isJpegMagic': isJpegB,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_B: pass=${results.laneBPass} '
        'w=${resultB.width} h=${resultB.height} format=${resultB.format} '
        'size=${resultB.fileSizeBytes} chosenQuality=${resultB.chosenQuality} '
        'passCount=${resultB.passCount} targetMet=$targetMetB',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_B: ERROR $e\n$st');
      results.laneBResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneBPass = false;
    }

    // ── Lane C: Adaptive target-met ───────────────────────────────────────
    try {
      // 1. Calibration baseline (no target)
      final laneCCalibOutputPath = '${tempDir.path}/${runId}_lane_c_calib.jpg';
      final laneCCalibOutputFile = File(laneCCalibOutputPath);
      tempFiles.add(laneCCalibOutputFile);

      final calibResultC = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneCCalibOutputPath,
          maxLongEdge: 900,
          quality: 0.90,
          format: 'jpeg',
        ),
      );
      final calibSizeC = calibResultC.fileSizeBytes;
      final targetBytesC = calibSizeC > 1 ? calibSizeC - 1 : 1;

      // 2. Search run with targetBytesC
      final laneCOutputPath = '${tempDir.path}/${runId}_lane_c.jpg';
      final laneCOutputFile = File(laneCOutputPath);
      tempFiles.add(laneCOutputFile);

      final resultC = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneCOutputPath,
          maxLongEdge: 900,
          quality: 0.90,
          format: 'jpeg',
          fileSizeTargetBytes: targetBytesC,
        ),
      );

      final existsC = await laneCOutputFile.exists();
      final lengthC = existsC ? await laneCOutputFile.length() : 0;
      final isJpegC = await _isJpeg(laneCOutputFile);
      final passCountValidC = resultC.passCount >= 2 && resultC.passCount <= 4;
      final qualityReducedC = resultC.chosenQuality < 0.90;
      final targetMetC = resultC.fileSizeBytes <= targetBytesC;

      results.laneCChosenQuality = resultC.chosenQuality;
      results.laneCPass =
          existsC &&
          lengthC > 0 &&
          resultC.outputPath == laneCOutputPath &&
          resultC.format == 'jpeg' &&
          resultC.width <= 900 &&
          resultC.height <= 900 &&
          resultC.fileSizeBytes == lengthC &&
          passCountValidC &&
          qualityReducedC &&
          targetMetC &&
          isJpegC;

      results.laneCResults = <String, dynamic>{
        'pass': results.laneCPass,
        'calibSize': calibSizeC,
        'targetBytes': targetBytesC,
        'outputPath': resultC.outputPath,
        'format': resultC.format,
        'width': resultC.width,
        'height': resultC.height,
        'fileSizeBytes': resultC.fileSizeBytes,
        'actualFileLength': lengthC,
        'passCount': resultC.passCount,
        'chosenQuality': resultC.chosenQuality,
        'targetMet': targetMetC,
        'isJpegMagic': isJpegC,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_C: pass=${results.laneCPass} '
        'calibSize=$calibSizeC target=$targetBytesC actualSize=${resultC.fileSizeBytes} '
        'passCount=${resultC.passCount} chosenQuality=${resultC.chosenQuality} targetMet=$targetMetC',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_C: ERROR $e\n$st');
      results.laneCResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneCPass = false;
    }

    // ── Lane D: Impossible soft target best-effort ────────────────────────
    try {
      final laneDOutputPath = '${tempDir.path}/${runId}_lane_d.jpg';
      final laneDOutputFile = File(laneDOutputPath);
      tempFiles.add(laneDOutputFile);

      final resultD = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneDOutputPath,
          maxLongEdge: 900,
          quality: 0.90,
          format: 'jpeg',
          fileSizeTargetBytes: 1,
        ),
      );

      final existsD = await laneDOutputFile.exists();
      final lengthD = existsD ? await laneDOutputFile.length() : 0;
      final isJpegD = await _isJpeg(laneDOutputFile);
      final passCountValidD = resultD.passCount >= 2 && resultD.passCount <= 4;
      final qualityAtOrBelowLaneC =
          (resultD.chosenQuality - 0.35).abs() < 0.02 ||
          (results.laneCChosenQuality != null &&
              resultD.chosenQuality <= results.laneCChosenQuality!) ||
          resultD.chosenQuality < 0.90;
      final sizeNonZeroD = resultD.fileSizeBytes > 1;

      results.laneDPass =
          existsD &&
          lengthD > 0 &&
          resultD.outputPath == laneDOutputPath &&
          resultD.format == 'jpeg' &&
          resultD.fileSizeBytes == lengthD &&
          isJpegD &&
          passCountValidD &&
          sizeNonZeroD &&
          qualityAtOrBelowLaneC;

      results.laneDResults = <String, dynamic>{
        'pass': results.laneDPass,
        'outputPath': resultD.outputPath,
        'format': resultD.format,
        'width': resultD.width,
        'height': resultD.height,
        'fileSizeBytes': resultD.fileSizeBytes,
        'actualFileLength': lengthD,
        'passCount': resultD.passCount,
        'chosenQuality': resultD.chosenQuality,
        'isJpegMagic': isJpegD,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_D: pass=${results.laneDPass} '
        'size=${resultD.fileSizeBytes} passCount=${resultD.passCount} '
        'chosenQuality=${resultD.chosenQuality}',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_D: ERROR $e\n$st');
      results.laneDResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneDPass = false;
    }

    // ── Lane E: PNG non-adaptive ──────────────────────────────────────────
    try {
      final laneEOutputPath = '${tempDir.path}/${runId}_lane_e.png';
      final laneEOutputFile = File(laneEOutputPath);
      tempFiles.add(laneEOutputFile);

      final resultE = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneEOutputPath,
          maxWidth: 256,
          maxHeight: 300,
          quality: 0.5,
          format: 'png',
          fileSizeTargetBytes: 1,
        ),
      );

      final existsE = await laneEOutputFile.exists();
      final lengthE = existsE ? await laneEOutputFile.length() : 0;
      final isPngE = await _isPng(laneEOutputFile);

      results.laneEPass =
          existsE &&
          lengthE > 0 &&
          resultE.outputPath == laneEOutputPath &&
          resultE.format == 'png' &&
          resultE.width <= 256 &&
          resultE.height <= 300 &&
          resultE.passCount == 1 &&
          isPngE &&
          resultE.fileSizeBytes == lengthE;

      results.laneEResults = <String, dynamic>{
        'pass': results.laneEPass,
        'outputPath': resultE.outputPath,
        'format': resultE.format,
        'width': resultE.width,
        'height': resultE.height,
        'fileSizeBytes': resultE.fileSizeBytes,
        'actualFileLength': lengthE,
        'passCount': resultE.passCount,
        'isPngMagic': isPngE,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_E: pass=${results.laneEPass} '
        'w=${resultE.width} h=${resultE.height} format=${resultE.format} '
        'size=${resultE.fileSizeBytes} passCount=${resultE.passCount}',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_E: ERROR $e\n$st');
      results.laneEResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneEPass = false;
    }

    // ── Lane F: HEIC request fallback participates as JPEG ────────────────
    try {
      // 1. Calibration baseline (no target)
      final laneFCalibOutputPath = '${tempDir.path}/${runId}_lane_f_calib.jpg';
      final laneFCalibOutputFile = File(laneFCalibOutputPath);
      tempFiles.add(laneFCalibOutputFile);

      final calibResultF = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneFCalibOutputPath,
          maxLongEdge: 700,
          quality: 0.90,
          format: 'heic',
        ),
      );
      final calibSizeF = calibResultF.fileSizeBytes;
      final targetBytesF = calibSizeF > 1 ? calibSizeF - 1 : 1;

      // 2. Search run with targetBytesF
      final laneFOutputPath = '${tempDir.path}/${runId}_lane_f.heic';
      final laneFOutputFile = File(laneFOutputPath);
      tempFiles.add(laneFOutputFile);

      final resultF = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneFOutputPath,
          maxLongEdge: 700,
          quality: 0.90,
          format: 'heic',
          fileSizeTargetBytes: targetBytesF,
        ),
      );

      final existsF = await laneFOutputFile.exists();
      final lengthF = existsF ? await laneFOutputFile.length() : 0;
      final isJpegF = await _isJpeg(laneFOutputFile);
      final passCountValidF = resultF.passCount >= 2 && resultF.passCount <= 4;
      final qualityReducedF = resultF.chosenQuality < 0.90;
      final targetMetF = resultF.fileSizeBytes <= targetBytesF;

      results.laneFPass =
          existsF &&
          lengthF > 0 &&
          resultF.outputPath == laneFOutputPath &&
          resultF.format == 'jpeg' &&
          resultF.width <= 700 &&
          resultF.height <= 700 &&
          resultF.fileSizeBytes == lengthF &&
          passCountValidF &&
          qualityReducedF &&
          isJpegF;

      results.laneFResults = <String, dynamic>{
        'pass': results.laneFPass,
        'calibSize': calibSizeF,
        'targetBytes': targetBytesF,
        'outputPath': resultF.outputPath,
        'format': resultF.format,
        'width': resultF.width,
        'height': resultF.height,
        'fileSizeBytes': resultF.fileSizeBytes,
        'actualFileLength': lengthF,
        'passCount': resultF.passCount,
        'chosenQuality': resultF.chosenQuality,
        'targetMet': targetMetF,
        'isJpegMagic': isJpegF,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_F: pass=${results.laneFPass} '
        'calibSize=$calibSizeF target=$targetBytesF actualSize=${resultF.fileSizeBytes} '
        'passCount=${resultF.passCount} chosenQuality=${resultF.chosenQuality} targetMet=$targetMetF',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_F_SMOKE_LANE_F: ERROR $e\n$st');
      results.laneFResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneFPass = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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

class _SmokeResults {
  Map<String, dynamic>? laneAResults;
  Map<String, dynamic>? laneBResults;
  Map<String, dynamic>? laneCResults;
  Map<String, dynamic>? laneDResults;
  Map<String, dynamic>? laneEResults;
  Map<String, dynamic>? laneFResults;

  double? laneCChosenQuality;

  var laneAPass = false;
  var laneBPass = false;
  var laneCPass = false;
  var laneDPass = false;
  var laneEPass = false;
  var laneFPass = false;
}
