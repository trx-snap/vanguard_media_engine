// android_image_compression_unit_ae_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit AE / Phase 10-C-3M
// Android Image Compression Bridge Parity Physical Smoke Test.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, PlatformException, rootBundle;
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

/// Creates a valid EXIF-oriented JPEG byte array by injecting an APP1 EXIF segment
/// with the specified orientation tag (1..8) immediately after the SOI marker (0xFF, 0xD8).
Uint8List createExifOrientedJpegBytes(
  Uint8List baseJpegBytes,
  int orientation,
) {
  if (baseJpegBytes.length < 2 ||
      baseJpegBytes[0] != 0xFF ||
      baseJpegBytes[1] != 0xD8) {
    throw StateError(
      'Base image is not a valid JPEG (missing SOI marker 0xFF 0xD8)',
    );
  }

  // Structurally correct APP1 EXIF segment:
  // Marker: 0xFF 0xE1
  // Length: 0x00 0x22 (34 bytes: 2 length bytes + 32 payload bytes)
  // Payload: "Exif\0\0" (6 bytes)
  // Little-endian TIFF header: "II" (0x49, 0x49), 42 (0x2A, 0x00), offset to IFD0 8 (0x08, 0x00, 0x00, 0x00)
  // IFD0: 1 entry (0x01, 0x00)
  // Entry 0: tag 0x0112 (0x12, 0x01), type SHORT (0x03, 0x00), count 1 (0x01, 0x00, 0x00, 0x00), value (orientation, 0x00, 0x00, 0x00)
  // Next IFD offset: 0 (0x00, 0x00, 0x00, 0x00)
  final app1Segment = Uint8List.fromList([
    0xFF,
    0xE1,
    0x00,
    0x22,
    0x45,
    0x78,
    0x69,
    0x66,
    0x00,
    0x00,
    0x49,
    0x49,
    0x2A,
    0x00,
    0x08,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x12,
    0x01,
    0x03,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    orientation & 0xFF,
    (orientation >> 8) & 0xFF,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
  ]);

  final builder = BytesBuilder(copy: false);
  builder.add(baseJpegBytes.sublist(0, 2)); // SOI: FF D8
  builder.add(app1Segment);
  builder.add(baseJpegBytes.sublist(2));
  return builder.toBytes();
}

/// Checks whether [bytes] contain the EXIF ASCII signature "Exif\0\0" (0x45, 0x78, 0x69, 0x66, 0x00, 0x00).
bool containsExifSignature(Uint8List bytes) {
  final target = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];
  if (bytes.length < target.length) return false;
  for (var i = 0; i <= bytes.length - target.length; i++) {
    var match = true;
    for (var j = 0; j < target.length; j++) {
      if (bytes[i + j] != target[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// Checks whether any files in [dir] contain [runId] and have `.tmp-` or `.bak-` in their name.
bool hasTempOrBakFiles(Directory dir, String runId) {
  try {
    final entries = dir.listSync();
    for (final entity in entries) {
      if (entity is File) {
        final name = entity.uri.pathSegments.last;
        if (name.contains(runId) &&
            (name.contains('.tmp-') || name.contains('.bak-'))) {
          return true;
        }
      }
    }
  } catch (_) {}
  return false;
}

/// Decodes bytes to a ui.Image using instantiateImageCodec.
Future<ui.Image> decodeImageFromBytes(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frameInfo = await codec.getNextFrame();
  return frameInfo.image;
}

/// Renders a source [ui.Image] onto a canvas of size [targetWidth] x [targetHeight]
/// and encodes the result to PNG bytes.
Future<Uint8List> renderNonSquarePngBytes({
  required ui.Image sourceImage,
  required int targetWidth,
  required int targetHeight,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final srcRect = ui.Rect.fromLTWH(
    0,
    0,
    sourceImage.width.toDouble(),
    sourceImage.height.toDouble(),
  );
  final dstRect = ui.Rect.fromLTWH(
    0,
    0,
    targetWidth.toDouble(),
    targetHeight.toDouble(),
  );
  final paint = ui.Paint();
  canvas.drawImageRect(sourceImage, srcRect, dstRect, paint);
  final picture = recorder.endRecording();
  final nonSquareUiImage = await picture.toImage(targetWidth, targetHeight);
  final byteData = await nonSquareUiImage.toByteData(
    format: ui.ImageByteFormat.png,
  );
  if (byteData == null) {
    throw StateError('Failed to encode non-square image to PNG');
  }
  return byteData.buffer.asUint8List(
    byteData.offsetInBytes,
    byteData.lengthInBytes,
  );
}

void main() {
  runApp(const AndroidImageCompressionUnitAEPhysicalSmokeApp());
}

class AndroidImageCompressionUnitAEPhysicalSmokeApp extends StatefulWidget {
  const AndroidImageCompressionUnitAEPhysicalSmokeApp({super.key});

  @override
  State<AndroidImageCompressionUnitAEPhysicalSmokeApp> createState() =>
      _AndroidImageCompressionUnitAEPhysicalSmokeAppState();
}

class _AndroidImageCompressionUnitAEPhysicalSmokeAppState
    extends State<AndroidImageCompressionUnitAEPhysicalSmokeApp> {
  String _status =
      'Initializing Android Image Compression Physical Smoke (Unit AE)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 90), () {
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE: TIMEOUT (90s exceeded)');
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_PHYSICAL_FAIL');
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
    print('ANDROID_IMAGE_COMPRESSION_UNIT_AE: START');
    final runId = 'unit_ae_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;
    const rawChannel = MethodChannel('vanguard_media_engine');

    File? tempPngSourceFile;
    File? tempNonSquarePngFile;
    File? tempBaseJpegFile;
    File? tempExif6SourceFile;

    File? lane1OutputFile;
    File? lane2OutputFile;
    File? lane3OutputFile;
    File? lane4LowOutputFile;
    File? lane4HighOutputFile;
    File? lane5OutputFile;
    File? lane6OutputFile;
    File? lane8Stress1File;
    File? lane8Stress2File;
    File? lane8Stress3File;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;

    Map<String, dynamic> lane1Map = <String, dynamic>{};
    Map<String, dynamic> lane2Map = <String, dynamic>{};
    Map<String, dynamic> lane3Map = <String, dynamic>{};
    Map<String, dynamic> lane4Map = <String, dynamic>{};
    Map<String, dynamic> lane5Map = <String, dynamic>{};
    Map<String, dynamic> lane6Map = <String, dynamic>{};
    Map<String, dynamic> lane7Map = <String, dynamic>{};
    Map<String, dynamic> lane8Map = <String, dynamic>{};

    String? topLevelError;

    final filesToClean = <File?>[];

    try {
      // ── Step 1: Copy rootBundle asset to temp ──────────────────────────────
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE: Copying still_C.png to temp...',
      );
      final pngByteData = await rootBundle.load(
        'assets/manual_test_clips/still_C.png',
      );
      final rawPngBytes = pngByteData.buffer.asUint8List(
        pngByteData.offsetInBytes,
        pngByteData.lengthInBytes,
      );
      tempPngSourceFile = File('${tempDir.path}/${runId}_source_still_C.png');
      filesToClean.add(tempPngSourceFile);
      await tempPngSourceFile.writeAsBytes(rawPngBytes, flush: true);
      final pngSourcePath = tempPngSourceFile.path;
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE: Source PNG ready at $pngSourcePath (${rawPngBytes.length} bytes)',
      );

      // Decode source PNG to get baseline dimensions
      final sourceUiImage = await decodeImageFromBytes(rawPngBytes);
      final sourcePngWidth = sourceUiImage.width;
      final sourcePngHeight = sourceUiImage.height;
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE: Decoded source PNG dimensions: ${sourcePngWidth}x$sourcePngHeight',
      );

      // ── Step 2: Create non-square baseline JPEG via VanguardImageOptimizer ─
      final nonSquarePngBytes = await renderNonSquarePngBytes(
        sourceImage: sourceUiImage,
        targetWidth: 640,
        targetHeight: 480,
      );
      tempNonSquarePngFile = File(
        '${tempDir.path}/${runId}_source_nonsquare.png',
      );
      filesToClean.add(tempNonSquarePngFile);
      await tempNonSquarePngFile.writeAsBytes(nonSquarePngBytes, flush: true);

      tempBaseJpegFile = File('${tempDir.path}/${runId}_base_nonsquare.jpg');
      filesToClean.add(tempBaseJpegFile);
      final optResult = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: tempNonSquarePngFile.path,
          outputPath: tempBaseJpegFile.path,
          format: 'jpeg',
          quality: 0.85,
        ),
      );
      final rawBaseJpegBytes = await tempBaseJpegFile.readAsBytes();
      final baseJpegWidth = optResult.width;
      final baseJpegHeight = optResult.height;
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE: Baseline non-square JPEG ready: ${optResult.outputPath} (${baseJpegWidth}x$baseJpegHeight, ${rawBaseJpegBytes.length} bytes)',
      );

      // ── Step 3: Create EXIF orientation 6 JPEG fixture ────────────────────
      final exif6Bytes = createExifOrientedJpegBytes(rawBaseJpegBytes, 6);
      tempExif6SourceFile = File('${tempDir.path}/${runId}_exif6_source.jpg');
      filesToClean.add(tempExif6SourceFile);
      await tempExif6SourceFile.writeAsBytes(exif6Bytes, flush: true);
      final hasSourceExif = containsExifSignature(exif6Bytes);
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE: EXIF-6 fixture ready at ${tempExif6SourceFile.path} (${exif6Bytes.length} bytes, hasExif=$hasSourceExif)',
      );

      // ══════════════════════════════════════════════════════════════════════
      // Lane 1: Basic PNG-to-JPEG downscale
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE1: START (PNG-to-JPEG downscale)',
      );
      final lane1OutputPath = '${tempDir.path}/${runId}_lane1_out.jpg';
      lane1OutputFile = File(lane1OutputPath);
      filesToClean.add(lane1OutputFile);

      try {
        final result1 = await rawChannel.invokeMethod<Map>('compressImage', {
          'inputPath': pngSourcePath,
          'outputPath': lane1OutputPath,
          'maxWidthPx': 512,
          'jpegQuality': 0.85,
        });

        final outExists = await lane1OutputFile.exists();
        final outBytes = outExists ? await lane1OutputFile.length() : 0;
        final pathMatches = result1?['outputPath'] == lane1OutputPath;

        final decodedUiImage = await decodeImageFromBytes(
          await lane1OutputFile.readAsBytes(),
        );
        final decodedWidth = decodedUiImage.width;
        final decodedHeight = decodedUiImage.height;

        final expectedHeight = (sourcePngHeight * (512.0 / sourcePngWidth))
            .toInt();
        final dimsMatch =
            decodedWidth == 512 && decodedHeight == expectedHeight;

        lane1Pass = outExists && outBytes > 0 && pathMatches && dimsMatch;

        lane1Map = <String, dynamic>{
          'pass': lane1Pass,
          'outputPath': lane1OutputPath,
          'resultOutputPath': result1?['outputPath'],
          'outputBytes': outBytes,
          'decodedDimensions': '${decodedWidth}x$decodedHeight',
          'expectedDimensions': '512x$expectedHeight',
          'sourceDimensions': '${sourcePngWidth}x$sourcePngHeight',
        };
        print(
          'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE1: DONE (pass=$lane1Pass, bytes=$outBytes, dims=${decodedWidth}x$decodedHeight)',
        );
      } catch (e, st) {
        print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE1: ERROR: $e\n$st');
        lane1Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane1Pass = false;
      }
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE1_PASS: $lane1Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 2: EXIF-6 non-square bake
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE2: START (EXIF-6 non-square bake)',
      );
      final lane2OutputPath = '${tempDir.path}/${runId}_lane2_exif6_out.jpg';
      lane2OutputFile = File(lane2OutputPath);
      filesToClean.add(lane2OutputFile);

      try {
        final result2 = await rawChannel.invokeMethod<Map>('compressImage', {
          'inputPath': tempExif6SourceFile.path,
          'outputPath': lane2OutputPath,
          'maxWidthPx': 480,
          'jpegQuality': 0.85,
        });

        final outExists = await lane2OutputFile.exists();
        final outBytes = outExists ? await lane2OutputFile.length() : 0;
        final pathMatches = result2?['outputPath'] == lane2OutputPath;

        final outputBytes = await lane2OutputFile.readAsBytes();
        final decodedUiImage = await decodeImageFromBytes(outputBytes);
        final decodedWidth = decodedUiImage.width;
        final decodedHeight = decodedUiImage.height;

        final hasExif = containsExifSignature(outputBytes);
        final dimsBaked = decodedWidth == 480 && decodedHeight == 640;

        lane2Pass =
            outExists && outBytes > 0 && pathMatches && dimsBaked && !hasExif;

        lane2Map = <String, dynamic>{
          'pass': lane2Pass,
          'outputPath': lane2OutputPath,
          'outputBytes': outBytes,
          'baselineDimensions': '640x480',
          'bakedDimensions': '${decodedWidth}x$decodedHeight',
          'hasExifSignature': hasExif,
        };
        print(
          'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE2: DONE (pass=$lane2Pass, bytes=$outBytes, baseline=640x480, baked=${decodedWidth}x$decodedHeight, hasExif=$hasExif)',
        );
      } catch (e, st) {
        print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE2: ERROR: $e\n$st');
        lane2Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane2Pass = false;
      }
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE2_PASS: $lane2Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 3: Metadata stripping
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE3: START (metadata stripping)',
      );
      final lane3OutputPath =
          '${tempDir.path}/${runId}_lane3_metadatastrip_out.jpg';
      lane3OutputFile = File(lane3OutputPath);
      filesToClean.add(lane3OutputFile);

      try {
        final result3 = await rawChannel.invokeMethod<Map>('compressImage', {
          'inputPath': tempExif6SourceFile.path,
          'outputPath': lane3OutputPath,
          'maxWidthPx': 640,
          'jpegQuality': 0.85,
        });

        final outExists = await lane3OutputFile.exists();
        final outBytes = outExists ? await lane3OutputFile.length() : 0;
        final pathMatches = result3?['outputPath'] == lane3OutputPath;

        final outputBytes = await lane3OutputFile.readAsBytes();
        final sourceHasExif = containsExifSignature(exif6Bytes);
        final outputHasExif = containsExifSignature(outputBytes);

        lane3Pass =
            outExists &&
            outBytes > 0 &&
            pathMatches &&
            sourceHasExif &&
            !outputHasExif;

        lane3Map = <String, dynamic>{
          'pass': lane3Pass,
          'outputPath': lane3OutputPath,
          'outputBytes': outBytes,
          'sourceHasExif': sourceHasExif,
          'outputHasExif': outputHasExif,
        };
        print(
          'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE3: DONE (pass=$lane3Pass, bytes=$outBytes, sourceExif=$sourceHasExif, outputExif=$outputHasExif)',
        );
      } catch (e, st) {
        print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE3: ERROR: $e\n$st');
        lane3Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane3Pass = false;
      }
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE3_PASS: $lane3Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 4: Quality parameter
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE4: START (quality parameter)',
      );
      final lane4LowPath = '${tempDir.path}/${runId}_lane4_low_out.jpg';
      final lane4HighPath = '${tempDir.path}/${runId}_lane4_high_out.jpg';
      lane4LowOutputFile = File(lane4LowPath);
      lane4HighOutputFile = File(lane4HighPath);
      filesToClean.add(lane4LowOutputFile);
      filesToClean.add(lane4HighOutputFile);

      try {
        final lowResult = await rawChannel.invokeMethod<Map>('compressImage', {
          'inputPath': pngSourcePath,
          'outputPath': lane4LowPath,
          'maxWidthPx': 512,
          'jpegQuality': 0.25,
        });

        final highResult = await rawChannel.invokeMethod<Map>('compressImage', {
          'inputPath': pngSourcePath,
          'outputPath': lane4HighPath,
          'maxWidthPx': 512,
          'jpegQuality': 0.95,
        });

        final lowExists = await lane4LowOutputFile.exists();
        final highExists = await lane4HighOutputFile.exists();
        final lowBytes = lowExists ? await lane4LowOutputFile.length() : 0;
        final highBytes = highExists ? await lane4HighOutputFile.length() : 0;

        final lowDecoded = await decodeImageFromBytes(
          await lane4LowOutputFile.readAsBytes(),
        );
        final highDecoded = await decodeImageFromBytes(
          await lane4HighOutputFile.readAsBytes(),
        );

        final dimsMatch =
            lowDecoded.width == highDecoded.width &&
            lowDecoded.height == highDecoded.height &&
            lowDecoded.width == 512;

        final sizeProgressionOk =
            lowBytes > 0 && highBytes > 0 && lowBytes <= highBytes;
        final pathsMatch =
            lowResult?['outputPath'] == lane4LowPath &&
            highResult?['outputPath'] == lane4HighPath;

        lane4Pass =
            lowExists &&
            highExists &&
            sizeProgressionOk &&
            dimsMatch &&
            pathsMatch;

        lane4Map = <String, dynamic>{
          'pass': lane4Pass,
          'lowBytes': lowBytes,
          'highBytes': highBytes,
          'sizeProgressionOk': sizeProgressionOk,
          'lowDimensions': '${lowDecoded.width}x${lowDecoded.height}',
          'highDimensions': '${highDecoded.width}x${highDecoded.height}',
        };
        print(
          'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE4: DONE (pass=$lane4Pass, lowBytes=$lowBytes, highBytes=$highBytes)',
        );
      } catch (e, st) {
        print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE4: ERROR: $e\n$st');
        lane4Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane4Pass = false;
      }
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE4_PASS: $lane4Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 5: Existing-output replacement
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE5: START (existing output replacement)',
      );
      final lane5OutputPath =
          '${tempDir.path}/${runId}_lane5_replacement_out.jpg';
      lane5OutputFile = File(lane5OutputPath);
      filesToClean.add(lane5OutputFile);

      try {
        const sentinelData =
            'SENTINEL_DUMMY_DATA_PREEXISTING_FILE_1234567890_TEST';
        await lane5OutputFile.writeAsString(sentinelData, flush: true);
        final initialExists = await lane5OutputFile.exists();
        final initialLength = await lane5OutputFile.length();

        final result5 = await rawChannel.invokeMethod<Map>('compressImage', {
          'inputPath': pngSourcePath,
          'outputPath': lane5OutputPath,
          'maxWidthPx': 512,
          'jpegQuality': 0.85,
        });

        final outExists = await lane5OutputFile.exists();
        final outBytes = outExists ? await lane5OutputFile.length() : 0;
        final pathMatches = result5?['outputPath'] == lane5OutputPath;

        final outRawBytes = await lane5OutputFile.readAsBytes();
        final outString = String.fromCharCodes(outRawBytes);
        final containsSentinel = outString.contains('SENTINEL_DUMMY_DATA');

        final decodedUiImage = await decodeImageFromBytes(outRawBytes);
        final decodedWidth = decodedUiImage.width;
        final decodedHeight = decodedUiImage.height;
        final dimsValid = decodedWidth == 512;

        lane5Pass =
            initialExists &&
            outExists &&
            outBytes > 0 &&
            pathMatches &&
            !containsSentinel &&
            dimsValid;

        lane5Map = <String, dynamic>{
          'pass': lane5Pass,
          'outputPath': lane5OutputPath,
          'initialLength': initialLength,
          'outputBytes': outBytes,
          'containsSentinel': containsSentinel,
          'decodedDimensions': '${decodedWidth}x$decodedHeight',
        };
        print(
          'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE5: DONE (pass=$lane5Pass, initialBytes=$initialLength, newBytes=$outBytes, containsSentinel=$containsSentinel)',
        );
      } catch (e, st) {
        print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE5: ERROR: $e\n$st');
        lane5Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane5Pass = false;
      }
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE5_PASS: $lane5Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 6: Invalid argument lane
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE6: START (invalid arguments rejection)',
      );
      final lane6OutputPath = '${tempDir.path}/${runId}_lane6_invalid_out.jpg';
      lane6OutputFile = File(lane6OutputPath);
      filesToClean.add(lane6OutputFile);

      try {
        // 6a: empty inputPath
        String? err6a;
        try {
          await rawChannel.invokeMethod('compressImage', {
            'inputPath': '',
            'outputPath': lane6OutputPath,
            'maxWidthPx': 512,
            'jpegQuality': 0.85,
          });
        } on PlatformException catch (pe) {
          err6a = pe.code;
        }

        // 6b: empty outputPath
        String? err6b;
        try {
          await rawChannel.invokeMethod('compressImage', {
            'inputPath': pngSourcePath,
            'outputPath': '',
            'maxWidthPx': 512,
            'jpegQuality': 0.85,
          });
        } on PlatformException catch (pe) {
          err6b = pe.code;
        }

        // 6c: non-existent source
        String? err6c;
        try {
          await rawChannel.invokeMethod('compressImage', {
            'inputPath': '${tempDir.path}/nonexistent_$runId.png',
            'outputPath': lane6OutputPath,
            'maxWidthPx': 512,
            'jpegQuality': 0.85,
          });
        } on PlatformException catch (pe) {
          err6c = pe.code;
        }

        // 6d: invalid parent directory
        String? err6d;
        try {
          await rawChannel.invokeMethod('compressImage', {
            'inputPath': pngSourcePath,
            'outputPath': '/invalid_nonexistent_dir_xyz_12345/out.jpg',
            'maxWidthPx': 512,
            'jpegQuality': 0.85,
          });
        } on PlatformException catch (pe) {
          err6d = pe.code;
        }

        // 6e: missing maxWidthPx
        String? err6e;
        try {
          await rawChannel.invokeMethod('compressImage', {
            'inputPath': pngSourcePath,
            'outputPath': lane6OutputPath,
            'jpegQuality': 0.85,
          });
        } on PlatformException catch (pe) {
          err6e = pe.code;
        }

        // 6f: maxWidthPx <= 0
        String? err6f;
        try {
          await rawChannel.invokeMethod('compressImage', {
            'inputPath': pngSourcePath,
            'outputPath': lane6OutputPath,
            'maxWidthPx': 0,
            'jpegQuality': 0.85,
          });
        } on PlatformException catch (pe) {
          err6f = pe.code;
        }

        // 6g: missing jpegQuality
        String? err6g;
        try {
          await rawChannel.invokeMethod('compressImage', {
            'inputPath': pngSourcePath,
            'outputPath': lane6OutputPath,
            'maxWidthPx': 512,
          });
        } on PlatformException catch (pe) {
          err6g = pe.code;
        }

        // 6h: non-numeric jpegQuality
        String? err6h;
        try {
          await rawChannel.invokeMethod('compressImage', {
            'inputPath': pngSourcePath,
            'outputPath': lane6OutputPath,
            'maxWidthPx': 512,
            'jpegQuality': 'high_quality_string',
          });
        } on PlatformException catch (pe) {
          err6h = pe.code;
        }

        const expectedCode = 'INVALID_ARG';
        final pass6a = err6a == expectedCode;
        final pass6b = err6b == expectedCode;
        final pass6c = err6c == expectedCode;
        final pass6d = err6d == expectedCode;
        final pass6e = err6e == expectedCode;
        final pass6f = err6f == expectedCode;
        final pass6g = err6g == expectedCode;
        final pass6h = err6h == expectedCode;

        lane6Pass =
            pass6a &&
            pass6b &&
            pass6c &&
            pass6d &&
            pass6e &&
            pass6f &&
            pass6g &&
            pass6h;

        lane6Map = <String, dynamic>{
          'pass': lane6Pass,
          'err6a_emptyInput': err6a,
          'err6b_emptyOutput': err6b,
          'err6c_nonExistentSource': err6c,
          'err6d_invalidParentDir': err6d,
          'err6e_missingMaxWidth': err6e,
          'err6f_nonPositiveMaxWidth': err6f,
          'err6g_missingQuality': err6g,
          'err6h_nonNumericQuality': err6h,
        };
        print(
          'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE6: DONE (pass=$lane6Pass, 6a=$err6a, 6b=$err6b, 6c=$err6c, 6d=$err6d, 6e=$err6e, 6f=$err6f, 6g=$err6g, 6h=$err6h)',
        );
      } catch (e, st) {
        print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE6: ERROR: $e\n$st');
        lane6Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane6Pass = false;
      }
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE6_PASS: $lane6Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 7: VanguardMediaPreparer.prepareForUpload integration lane
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE7: START (VanguardMediaPreparer.prepareForUpload integration)',
      );

      try {
        const constraints = UploadConstraints(
          maxDurationSeconds: 180,
          maxShortSidePx: 720,
          maxBitrateKbps: 1500,
          maxFileSizeMb: 200,
          targetBitrateKbps: 1000,
          imageMaxWidthPx: 256,
          imageJpegQuality: 0.85,
        );
        const policy = UploadPolicy.standard();

        final prepResult = await VanguardMediaPreparer.prepareForUpload(
          tempPngSourceFile,
          constraints,
          policy,
        );

        final outcomeIsTranscoded =
            prepResult.outcome == PrepareOutcome.transcoded;
        final tempPathNonNull = prepResult.tempPath != null;
        final tempPathSuffixOk =
            prepResult.tempPath?.endsWith('_vg_compressed.jpg') ?? false;
        final fileExistsBeforeCleanup = prepResult.file.existsSync();
        final fileBytesBeforeCleanup = fileExistsBeforeCleanup
            ? prepResult.file.lengthSync()
            : 0;

        ui.Image? prepDecoded;
        if (fileExistsBeforeCleanup && fileBytesBeforeCleanup > 0) {
          prepDecoded = await decodeImageFromBytes(
            await prepResult.file.readAsBytes(),
          );
        }
        final dimsMatch = prepDecoded != null && prepDecoded.width == 256;

        // Run cleanup
        await VanguardMediaPreparer.cleanupTempFiles();
        final fileDeletedAfterCleanup = !prepResult.file.existsSync();

        lane7Pass =
            prepResult.succeeded &&
            outcomeIsTranscoded &&
            tempPathNonNull &&
            tempPathSuffixOk &&
            fileExistsBeforeCleanup &&
            fileBytesBeforeCleanup > 0 &&
            dimsMatch &&
            fileDeletedAfterCleanup;

        lane7Map = <String, dynamic>{
          'pass': lane7Pass,
          'outcome': prepResult.outcome.toString(),
          'tempPath': prepResult.tempPath,
          'fileExistsBeforeCleanup': fileExistsBeforeCleanup,
          'fileBytesBeforeCleanup': fileBytesBeforeCleanup,
          'decodedDimensions': prepDecoded != null
              ? '${prepDecoded.width}x${prepDecoded.height}'
              : 'null',
          'fileDeletedAfterCleanup': fileDeletedAfterCleanup,
        };
        print(
          'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE7: DONE (pass=$lane7Pass, outcome=${prepResult.outcome}, tempPath=${prepResult.tempPath}, deletedAfterCleanup=$fileDeletedAfterCleanup)',
        );
      } catch (e, st) {
        print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE7: ERROR: $e\n$st');
        lane7Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane7Pass = false;
      }
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE7_PASS: $lane7Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 8: Sequential stress & temp cleanup lane
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE8: START (sequential stress & lifecycle cleanup)',
      );
      final lane8Stress1Path = '${tempDir.path}/${runId}_lane8_stress_1.jpg';
      final lane8Stress2Path = '${tempDir.path}/${runId}_lane8_stress_2.jpg';
      final lane8Stress3Path = '${tempDir.path}/${runId}_lane8_stress_3.jpg';

      lane8Stress1File = File(lane8Stress1Path);
      lane8Stress2File = File(lane8Stress2Path);
      lane8Stress3File = File(lane8Stress3Path);

      filesToClean.add(lane8Stress1File);
      filesToClean.add(lane8Stress2File);
      filesToClean.add(lane8Stress3File);

      try {
        final r1 = await rawChannel.invokeMethod<Map>('compressImage', {
          'inputPath': pngSourcePath,
          'outputPath': lane8Stress1Path,
          'maxWidthPx': 384,
          'jpegQuality': 0.80,
        });

        final r2 = await rawChannel.invokeMethod<Map>('compressImage', {
          'inputPath': pngSourcePath,
          'outputPath': lane8Stress2Path,
          'maxWidthPx': 256,
          'jpegQuality': 0.80,
        });

        final r3 = await rawChannel.invokeMethod<Map>('compressImage', {
          'inputPath': pngSourcePath,
          'outputPath': lane8Stress3Path,
          'maxWidthPx': 128,
          'jpegQuality': 0.80,
        });

        final f1Exists = await lane8Stress1File.exists();
        final f2Exists = await lane8Stress2File.exists();
        final f3Exists = await lane8Stress3File.exists();

        final f1Bytes = f1Exists ? await lane8Stress1File.length() : 0;
        final f2Bytes = f2Exists ? await lane8Stress2File.length() : 0;
        final f3Bytes = f3Exists ? await lane8Stress3File.length() : 0;

        final img1 = await decodeImageFromBytes(
          await lane8Stress1File.readAsBytes(),
        );
        final img2 = await decodeImageFromBytes(
          await lane8Stress2File.readAsBytes(),
        );
        final img3 = await decodeImageFromBytes(
          await lane8Stress3File.readAsBytes(),
        );

        final allDimsMatch =
            img1.width == 384 && img2.width == 256 && img3.width == 128;

        final orphanTempsPresent = hasTempOrBakFiles(tempDir, runId);

        lane8Pass =
            f1Exists &&
            f2Exists &&
            f3Exists &&
            f1Bytes > 0 &&
            f2Bytes > 0 &&
            f3Bytes > 0 &&
            allDimsMatch &&
            !orphanTempsPresent &&
            r1?['outputPath'] == lane8Stress1Path &&
            r2?['outputPath'] == lane8Stress2Path &&
            r3?['outputPath'] == lane8Stress3Path;

        lane8Map = <String, dynamic>{
          'pass': lane8Pass,
          'f1Bytes': f1Bytes,
          'f2Bytes': f2Bytes,
          'f3Bytes': f3Bytes,
          'img1Dims': '${img1.width}x${img1.height}',
          'img2Dims': '${img2.width}x${img2.height}',
          'img3Dims': '${img3.width}x${img3.height}',
          'orphanTempsPresent': orphanTempsPresent,
        };
        print(
          'ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE8: DONE (pass=$lane8Pass, f1=$f1Bytes, f2=$f2Bytes, f3=$f3Bytes, orphanTemps=$orphanTempsPresent)',
        );
      } catch (e, st) {
        print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE8: ERROR: $e\n$st');
        lane8Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane8Pass = false;
      }
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_LANE8_PASS: $lane8Pass');
    } catch (e, st) {
      print('ANDROID_IMAGE_COMPRESSION_UNIT_AE: TOP-LEVEL ERROR: $e\n$st');
      topLevelError = '$e';
    } finally {
      // Clean up temp files best-effort
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

    final allRequiredPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        lane5Pass &&
        lane6Pass &&
        lane7Pass &&
        lane8Pass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase5UnitAE_Phase10C3M',
      'target': 'android_image_compression_physical',
      'pass': allRequiredPass,
      'lanes': <String, dynamic>{
        'lane1_png_to_jpeg_downscale': lane1Map,
        'lane2_exif6_nonsquare_bake': lane2Map,
        'lane3_metadata_stripping': lane3Map,
        'lane4_quality_parameter': lane4Map,
        'lane5_existing_output_replacement': lane5Map,
        'lane6_invalid_argument_rejection': lane6Map,
        'lane7_preparer_integration': lane7Map,
        'lane8_sequential_stress_cleanup': lane8Map,
      },
      'error': topLevelError,
    };

    print('ANDROID_IMAGE_COMPRESSION_UNIT_AE_JSON:${jsonEncode(payload)}');
    print(
      allRequiredPass
          ? 'ANDROID_IMAGE_COMPRESSION_UNIT_AE_PHYSICAL_PASS'
          : 'ANDROID_IMAGE_COMPRESSION_UNIT_AE_PHYSICAL_FAIL',
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
