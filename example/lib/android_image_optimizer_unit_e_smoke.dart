// android_image_optimizer_unit_e_smoke.dart
// Vanguard Media Engine — Phase 5 Unit E Android ImageOptimizer Baseline Native Route Smoke Harness.
//
// Proof lanes:
//   Lane A: JPEG resize (maxLongEdge 500, quality 0.82, format jpeg).
//   Lane B: PNG encode (maxWidth 256, maxHeight 300, quality 0.5, format png).
//   Lane C: HEIC encode or fallback (maxLongEdge 384, format heic -> resolved heic or fallback jpeg).
//   Lane D: ROI unsupported-platform metadata (roi enabled -> roiApplied=false, unsupported_platform).
//   Lane E: Unsupported format sentinel preservation (format webp -> UNSUPPORTED_FORMAT, sentinel unchanged).
//   Lane F: Missing/blank source errors (FILE_UNREADABLE and MISSING_SOURCE_PATH).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidImageOptimizerUnitESmokeApp());
}

class AndroidImageOptimizerUnitESmokeApp extends StatefulWidget {
  const AndroidImageOptimizerUnitESmokeApp({super.key});

  @override
  State<AndroidImageOptimizerUnitESmokeApp> createState() =>
      _AndroidImageOptimizerUnitESmokeAppState();
}

class _AndroidImageOptimizerUnitESmokeAppState
    extends State<AndroidImageOptimizerUnitESmokeApp> {
  String _status = 'Running Android ImageOptimizer Unit E Physical Smoke...';

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

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<bool> _isIsoBmffHeicLike(File file) async {
    if (!await file.exists()) return false;
    final fileLength = await file.length();
    if (fileLength < 8) return false;

    final raf = await file.open(mode: FileMode.read);
    try {
      final header = await raf.read(8);
      if (header.length < 8) return false;

      final boxSize =
          (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
      final boxType = String.fromCharCodes(header.sublist(4, 8));
      if (boxType != 'ftyp') return false;

      // Determine valid box boundary without over-parsing beyond available bytes
      final availableBoxBytes = (boxSize >= 8 && boxSize <= fileLength)
          ? boxSize
          : (boxSize == 0 ? fileLength : 0);
      if (availableBoxBytes < 8) return false;

      final remaining = availableBoxBytes - 8;
      if (remaining < 4) return false;

      final body = await raf.read(remaining);

      const targetBrands = <String>{
        'heic',
        'heix',
        'hevc',
        'hevx',
        'mif1',
        'msf1',
      };

      // Check all 4-byte aligned brands in the ftyp box body.
      // Standard ISOBMFF layout:
      //   body[0..3]: major_brand (file bytes 8..11)
      //   body[4..7]: minor_version (file bytes 12..15)
      //   body[8..]: compatible_brands list (file bytes 16..)
      for (var offset = 0; offset + 4 <= body.length; offset += 4) {
        final brand = String.fromCharCodes(
          body.sublist(offset, offset + 4),
        ).toLowerCase();
        if (targetBrands.contains(brand)) {
          return true;
        }
      }

      return false;
    } catch (_) {
      return false;
    } finally {
      await raf.close();
    }
  }

  Future<void> _runSmoke() async {
    print('ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE: START');
    final runId = 'unit_e_${DateTime.now().millisecondsSinceEpoch}';
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
        'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE: TOP_LEVEL_ERROR: $topLevelError',
      );
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
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
        'unit': 'AndroidImageOptimizerUnitE',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'laneA_jpegResize':
              results.laneAResults ?? {'pass': false, 'error': 'not run'},
          'laneB_pngEncode':
              results.laneBResults ?? {'pass': false, 'error': 'not run'},
          'laneC_heicEncodeOrFallback':
              results.laneCResults ?? {'pass': false, 'error': 'not run'},
          'laneD_roiUnsupportedPlatform':
              results.laneDResults ?? {'pass': false, 'error': 'not run'},
          'laneE_unsupportedFormatSentinel':
              results.laneEResults ?? {'pass': false, 'error': 'not run'},
          'laneF_missingBlankSourceErrors':
              results.laneFResults ?? {'pass': false, 'error': 'not run'},
        },
        'error': topLevelError,
      };

      print('ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_JSON:${jsonEncode(payload)}');
      print(
        allPass
            ? 'ANDROID_IMAGE_OPTIMIZER_UNIT_E_PHYSICAL_SMOKE_PASS'
            : 'ANDROID_IMAGE_OPTIMIZER_UNIT_E_PHYSICAL_SMOKE_FAIL',
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
      'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE: Copying still_C.png to temp...',
    );
    final fixtureByteData = await rootBundle
        .load('assets/manual_test_clips/still_C.png')
        .timeout(const Duration(seconds: 10));
    print(
      'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE: Fixture bytes loaded length=${fixtureByteData.lengthInBytes}',
    );
    final rawBytes = fixtureByteData.buffer.asUint8List(
      fixtureByteData.offsetInBytes,
      fixtureByteData.lengthInBytes,
    );
    final copyBytes = Uint8List.fromList(rawBytes);

    final tempSourceImage = File('${tempDir.path}/${runId}_source_still_C.png');
    print('ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE: Writing temp source...');
    await tempSourceImage
        .writeAsBytes(copyBytes, flush: false)
        .timeout(const Duration(seconds: 10));
    tempFiles.add(tempSourceImage);
    final sourcePath = tempSourceImage.path;
    print(
      'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE: Temp source ready at $sourcePath',
    );

    // ── Lane A: JPEG resize ───────────────────────────────────────────────
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
          resultA.width == resultA.height &&
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
        'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_A: pass=${results.laneAPass} '
        'w=${resultA.width} h=${resultA.height} format=${resultA.format} '
        'size=${resultA.fileSizeBytes} chosenQuality=${resultA.chosenQuality}',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_A: ERROR $e\n$st');
      results.laneAResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneAPass = false;
    }

    // ── Lane B: PNG encode ────────────────────────────────────────────────
    try {
      final laneBOutputPath = '${tempDir.path}/${runId}_lane_b.png';
      final laneBOutputFile = File(laneBOutputPath);
      tempFiles.add(laneBOutputFile);

      final resultB = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneBOutputPath,
          maxWidth: 256,
          maxHeight: 300,
          quality: 0.5,
          format: 'png',
        ),
      );

      final existsB = await laneBOutputFile.exists();
      final lengthB = existsB ? await laneBOutputFile.length() : 0;
      final isPngB = await _isPng(laneBOutputFile);

      results.laneBPass =
          existsB &&
          lengthB > 0 &&
          resultB.outputPath == laneBOutputPath &&
          resultB.format == 'png' &&
          resultB.width <= 256 &&
          resultB.height <= 300 &&
          resultB.width == resultB.height &&
          resultB.passCount == 1 &&
          isPngB &&
          resultB.fileSizeBytes == lengthB;

      results.laneBResults = <String, dynamic>{
        'pass': results.laneBPass,
        'outputPath': resultB.outputPath,
        'format': resultB.format,
        'width': resultB.width,
        'height': resultB.height,
        'fileSizeBytes': resultB.fileSizeBytes,
        'actualFileLength': lengthB,
        'passCount': resultB.passCount,
        'isPngMagic': isPngB,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_B: pass=${results.laneBPass} '
        'w=${resultB.width} h=${resultB.height} format=${resultB.format} '
        'size=${resultB.fileSizeBytes} passCount=${resultB.passCount}',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_B: ERROR $e\n$st');
      results.laneBResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneBPass = false;
    }

    // ── Lane C: HEIC encode or fallback ───────────────────────────────────
    try {
      final laneCOutputPath = '${tempDir.path}/${runId}_lane_c.heic';
      final laneCOutputFile = File(laneCOutputPath);
      tempFiles.add(laneCOutputFile);

      final resultC = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneCOutputPath,
          maxLongEdge: 384,
          quality: 0.7,
          format: 'heic',
        ),
      );

      final actualOutputFileC = File(resultC.outputPath);
      if (!tempFiles.any((f) => f.path == actualOutputFileC.path)) {
        tempFiles.add(actualOutputFileC);
      }

      final existsC = await actualOutputFileC.exists();
      final lengthC = existsC ? await actualOutputFileC.length() : 0;
      final isJpegC = await _isJpeg(actualOutputFileC);
      final isHeicLikeC = await _isIsoBmffHeicLike(actualOutputFileC);

      final isHeicPass =
          resultC.format == 'heic' &&
          existsC &&
          lengthC > 0 &&
          resultC.width <= 384 &&
          resultC.height <= 384 &&
          resultC.fileSizeBytes == lengthC &&
          isHeicLikeC;

      final isFallbackPass =
          resultC.format == 'jpeg' &&
          existsC &&
          lengthC > 0 &&
          resultC.width <= 384 &&
          resultC.height <= 384 &&
          resultC.fileSizeBytes == lengthC &&
          isJpegC;

      final fallbackObservedC = resultC.format == 'jpeg';
      final pathKindC = resultC.format == 'heic'
          ? 'heic'
          : (resultC.format == 'jpeg' ? 'fallback_jpeg' : resultC.format);

      results.laneCPass = isHeicPass || isFallbackPass;

      results.laneCResults = <String, dynamic>{
        'pass': results.laneCPass,
        'outputPath': resultC.outputPath,
        'format': resultC.format,
        'pathKind': pathKindC,
        'width': resultC.width,
        'height': resultC.height,
        'fileSizeBytes': resultC.fileSizeBytes,
        'actualFileLength': lengthC,
        'isHeicLike': isHeicLikeC,
        'isJpegMagic': isJpegC,
        'fallbackObserved': fallbackObservedC,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_C: pass=${results.laneCPass} '
        'pathKind=$pathKindC w=${resultC.width} h=${resultC.height} format=${resultC.format} '
        'size=${resultC.fileSizeBytes} isHeicLike=$isHeicLikeC isJpegMagic=$isJpegC '
        'fallbackObserved=$fallbackObservedC outputPath=${resultC.outputPath}',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_C: ERROR $e\n$st');
      results.laneCResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneCPass = false;
    }

    // ── Lane D: ROI unsupported-platform metadata ─────────────────────────
    try {
      final laneDOutputPath = '${tempDir.path}/${runId}_lane_d.jpg';
      final laneDOutputFile = File(laneDOutputPath);
      tempFiles.add(laneDOutputFile);

      final resultD = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: sourcePath,
          outputPath: laneDOutputPath,
          format: 'jpeg',
          roi: const VGImageROIConfig(enabled: true),
        ),
      );

      final existsD = await laneDOutputFile.exists();
      final lengthD = existsD ? await laneDOutputFile.length() : 0;

      results.laneDPass =
          existsD &&
          lengthD > 0 &&
          resultD.roiApplied == false &&
          resultD.roiFallbackReason == 'unsupported_platform' &&
          resultD.roiFaceCount == 0 &&
          resultD.roiSuppressionPass == 1;

      results.laneDResults = <String, dynamic>{
        'pass': results.laneDPass,
        'outputPath': resultD.outputPath,
        'roiApplied': resultD.roiApplied,
        'roiFallbackReason': resultD.roiFallbackReason,
        'roiFaceCount': resultD.roiFaceCount,
        'roiSuppressionPass': resultD.roiSuppressionPass,
        'fileSizeBytes': resultD.fileSizeBytes,
        'actualFileLength': lengthD,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_D: pass=${results.laneDPass} '
        'roiApplied=${resultD.roiApplied} fallbackReason=${resultD.roiFallbackReason} '
        'faceCount=${resultD.roiFaceCount} suppressionPass=${resultD.roiSuppressionPass}',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_D: ERROR $e\n$st');
      results.laneDResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneDPass = false;
    }

    // ── Lane E: Unsupported format sentinel preservation ──────────────────
    try {
      final sentinelPath = '${tempDir.path}/${runId}_sentinel.out';
      final sentinelFile = File(sentinelPath);
      tempFiles.add(sentinelFile);

      const sentinelContent =
          'SENTINEL_IMAGE_OPTIMIZER_UNIT_E_PRESERVATION_CHECK_123456';
      await sentinelFile.writeAsString(sentinelContent, flush: true);
      final initialSentinelBytes = await sentinelFile.readAsBytes();

      String? laneEErrorCode;
      var caughtExpectedE = false;

      try {
        await VanguardImageOptimizer.optimizeImage(
          request: VGImageOptimizationRequest(
            sourcePath: sourcePath,
            outputPath: sentinelPath,
            format: 'webp',
          ),
        );
      } on PlatformException catch (pe) {
        laneEErrorCode = pe.code;
        caughtExpectedE = (pe.code == 'UNSUPPORTED_FORMAT');
      } catch (e) {
        laneEErrorCode = '$e';
      }

      final sentinelExistsAfter = await sentinelFile.exists();
      final afterBytes = sentinelExistsAfter
          ? await sentinelFile.readAsBytes()
          : Uint8List(0);
      final sentinelIdentical = _bytesEqual(initialSentinelBytes, afterBytes);

      results.laneEPass =
          caughtExpectedE &&
          laneEErrorCode == 'UNSUPPORTED_FORMAT' &&
          sentinelExistsAfter &&
          sentinelIdentical;

      results.laneEResults = <String, dynamic>{
        'pass': results.laneEPass,
        'exceptionCode': laneEErrorCode,
        'sentinelPreserved': sentinelIdentical,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_E: pass=${results.laneEPass} '
        'code=$laneEErrorCode sentinelPreserved=$sentinelIdentical',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_E: ERROR $e\n$st');
      results.laneEResults = <String, dynamic>{'pass': false, 'error': '$e'};
      results.laneEPass = false;
    }

    // ── Lane F: Missing/blank source errors ────────────────────────────────
    try {
      final nonExistentPath = '${tempDir.path}/${runId}_does_not_exist.jpg';
      String? f1ErrorCode;
      var f1Pass = false;

      try {
        await VanguardImageOptimizer.optimizeImage(
          request: VGImageOptimizationRequest(
            sourcePath: nonExistentPath,
            format: 'jpeg',
          ),
        );
      } on PlatformException catch (pe) {
        f1ErrorCode = pe.code;
        f1Pass = (pe.code == 'FILE_UNREADABLE');
      } catch (e) {
        f1ErrorCode = '$e';
      }

      String? f2ErrorCode;
      var f2Pass = false;

      try {
        await VanguardImageOptimizer.optimizeImage(
          request: const VGImageOptimizationRequest(
            sourcePath: '',
            format: 'jpeg',
          ),
        );
      } on PlatformException catch (pe) {
        f2ErrorCode = pe.code;
        f2Pass = (pe.code == 'MISSING_SOURCE_PATH');
      } catch (e) {
        f2ErrorCode = '$e';
      }

      results.laneFPass = f1Pass && f2Pass;

      results.laneFResults = <String, dynamic>{
        'pass': results.laneFPass,
        'missingFileExceptionCode': f1ErrorCode,
        'blankSourceExceptionCode': f2ErrorCode,
      };

      print(
        'ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_F: pass=${results.laneFPass} '
        'missingCode=$f1ErrorCode blankCode=$f2ErrorCode',
      );
    } catch (e, st) {
      print('ANDROID_IMAGE_OPTIMIZER_UNIT_E_SMOKE_LANE_F: ERROR $e\n$st');
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

  var laneAPass = false;
  var laneBPass = false;
  var laneCPass = false;
  var laneDPass = false;
  var laneEPass = false;
  var laneFPass = false;
}
