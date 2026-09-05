// android_image_optimizer_heic_physical_smoke.dart
// Vanguard Media Engine — Phase 5 HEIC Encode Android ImageOptimizer Physical Smoke Harness.
//
// Proof scenarios:
//   Scenario 1 (Positive Supported Path): format heic, isIsoBmffHeicLike, width/height <= 384, chosenQuality ~= 0.82, passCount == 1.
//   Scenario 2 (Conservative Fallback Path): format jpeg, isJpeg magic, width/height <= 384, chosenQuality ~= 0.82, passCount == 1, fallback=true.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidImageOptimizerHeicPhysicalSmokeApp());
}

class AndroidImageOptimizerHeicPhysicalSmokeApp extends StatefulWidget {
  const AndroidImageOptimizerHeicPhysicalSmokeApp({super.key});

  @override
  State<AndroidImageOptimizerHeicPhysicalSmokeApp> createState() =>
      _AndroidImageOptimizerHeicPhysicalSmokeAppState();
}

class _AndroidImageOptimizerHeicPhysicalSmokeAppState
    extends State<AndroidImageOptimizerHeicPhysicalSmokeApp> {
  String _status = 'Running Android ImageOptimizer HEIC Physical Smoke...';

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
    print('ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE: START');
    final runId = 'heic_${DateTime.now().millisecondsSinceEpoch}';
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
        'ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE: TOP_LEVEL_ERROR: $topLevelError',
      );
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      final allPass = results.pass && (topLevelError == null);

      final payload = <String, dynamic>{
        'pass': allPass,
        'pathKind': results.pathKind,
        'outputPath': results.outputPath,
        'format': results.format,
        'width': results.width,
        'height': results.height,
        'fileSizeBytes': results.fileSizeBytes,
        'actualFileLength': results.actualFileLength,
        'isHeicLike': results.isHeicLike,
        'isJpegMagic': results.isJpegMagic,
        'passCount': results.passCount,
        'chosenQuality': results.chosenQuality,
        'fallback': results.fallbackObserved,
        'fallbackObserved': results.fallbackObserved,
        'error': topLevelError ?? results.error,
      };

      print('ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE_JSON:${jsonEncode(payload)}');
      print(
        allPass
            ? 'ANDROID_IMAGE_OPTIMIZER_HEIC_PHYSICAL_SMOKE_PASS'
            : 'ANDROID_IMAGE_OPTIMIZER_HEIC_PHYSICAL_SMOKE_FAIL',
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
    print('ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE: Copying still_C.png to temp...');
    final fixtureByteData = await rootBundle
        .load('assets/manual_test_clips/still_C.png')
        .timeout(const Duration(seconds: 10));
    print(
      'ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE: Fixture bytes loaded length=${fixtureByteData.lengthInBytes}',
    );
    final rawBytes = fixtureByteData.buffer.asUint8List(
      fixtureByteData.offsetInBytes,
      fixtureByteData.lengthInBytes,
    );
    final copyBytes = Uint8List.fromList(rawBytes);

    final tempSourceImage = File('${tempDir.path}/${runId}_source_still_C.png');
    print('ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE: Writing temp source...');
    await tempSourceImage
        .writeAsBytes(copyBytes, flush: false)
        .timeout(const Duration(seconds: 10));
    tempFiles.add(tempSourceImage);
    final sourcePath = tempSourceImage.path;
    print(
      'ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE: Temp source ready at $sourcePath',
    );

    // ── Output path ending in .heic ───────────────────────────────────────
    final outputPath = '${tempDir.path}/${runId}_output.heic';
    final outputFile = File(outputPath);
    tempFiles.add(outputFile);

    print(
      'ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE: Calling optimizeImage (format: heic, maxLongEdge: 384, quality: 0.82)...',
    );
    final result = await VanguardImageOptimizer.optimizeImage(
      request: VGImageOptimizationRequest(
        sourcePath: sourcePath,
        outputPath: outputPath,
        maxLongEdge: 384,
        quality: 0.82,
        format: 'heic',
      ),
    );

    // Ensure actual result outputPath is tracked for cleanup if different
    final actualOutputFile = File(result.outputPath);
    if (!tempFiles.any((f) => f.path == actualOutputFile.path)) {
      tempFiles.add(actualOutputFile);
    }

    final exists = await actualOutputFile.exists();
    final length = exists ? await actualOutputFile.length() : 0;
    final isJpeg = await _isJpeg(actualOutputFile);
    final isHeic = await _isIsoBmffHeicLike(actualOutputFile);

    final chosenQualityClose = (result.chosenQuality - 0.82).abs() < 0.01;
    final boundsValid =
        result.width <= 384 &&
        result.height <= 384 &&
        result.width > 0 &&
        result.height > 0;
    final sizeMatches = exists && length > 0 && result.fileSizeBytes == length;
    final singlePass = result.passCount == 1;

    final isPositiveHeicPass =
        result.format == 'heic' &&
        exists &&
        length > 0 &&
        boundsValid &&
        sizeMatches &&
        singlePass &&
        chosenQualityClose &&
        isHeic;

    final isFallbackPass =
        result.format == 'jpeg' &&
        exists &&
        length > 0 &&
        boundsValid &&
        sizeMatches &&
        singlePass &&
        chosenQualityClose &&
        isJpeg;

    final fallbackObserved = result.format == 'jpeg';
    final pathKind = result.format == 'heic'
        ? 'heic'
        : (result.format == 'jpeg' ? 'fallback_jpeg' : result.format);

    results.pass = isPositiveHeicPass || isFallbackPass;
    results.pathKind = pathKind;
    results.outputPath = result.outputPath;
    results.format = result.format;
    results.width = result.width;
    results.height = result.height;
    results.fileSizeBytes = result.fileSizeBytes;
    results.actualFileLength = length;
    results.isHeicLike = isHeic;
    results.isJpegMagic = isJpeg;
    results.passCount = result.passCount;
    results.chosenQuality = result.chosenQuality;
    results.fallbackObserved = fallbackObserved;

    if (!results.pass) {
      results.error =
          'Acceptance failed: format=${result.format}, '
          'exists=$exists, length=$length, width=${result.width}, height=${result.height}, '
          'fileSizeBytes=${result.fileSizeBytes}, passCount=${result.passCount}, '
          'chosenQuality=${result.chosenQuality}, isHeicLike=$isHeic, isJpegMagic=$isJpeg';
      print('ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE: ${results.error}');
    } else {
      print(
        'ANDROID_IMAGE_OPTIMIZER_HEIC_SMOKE: PASS pathKind=$pathKind '
        'w=${result.width} h=${result.height} format=${result.format} '
        'size=${result.fileSizeBytes} chosenQuality=${result.chosenQuality} '
        'fallbackObserved=$fallbackObserved isHeicLike=$isHeic isJpegMagic=$isJpeg',
      );
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
  bool pass = false;
  String pathKind = 'unknown';
  String? outputPath;
  String? format;
  int? width;
  int? height;
  int? fileSizeBytes;
  int actualFileLength = 0;
  bool isHeicLike = false;
  bool isJpegMagic = false;
  int? passCount;
  double? chosenQuality;
  bool fallbackObserved = false;
  String? error;
}
