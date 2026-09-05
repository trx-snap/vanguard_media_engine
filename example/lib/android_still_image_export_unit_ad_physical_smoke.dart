// android_still_image_export_unit_ad_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit AD / Phase 10-C-3L
// Android Still Image Export Session Bridge Parity Physical Smoke Test.

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

/// Decodes bytes to a ui.Image using instantiateImageCodec.
Future<ui.Image> decodeImageFromBytes(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frameInfo = await codec.getNextFrame();
  return frameInfo.image;
}

/// Verifies [file] begins with an ISO-BMFF `ftyp` box whose major or
/// compatible brand advertises an HEIC-family container (`heic`, `heix`,
/// `hevc`, `hevx`, `mif1`, `msf1`).
Future<bool> isIsoBmffHeicLike(File file) async {
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
  runApp(const AndroidStillImageExportUnitADPhysicalSmokeApp());
}

class AndroidStillImageExportUnitADPhysicalSmokeApp extends StatefulWidget {
  const AndroidStillImageExportUnitADPhysicalSmokeApp({super.key});

  @override
  State<AndroidStillImageExportUnitADPhysicalSmokeApp> createState() =>
      _AndroidStillImageExportUnitADPhysicalSmokeAppState();
}

class _AndroidStillImageExportUnitADPhysicalSmokeAppState
    extends State<AndroidStillImageExportUnitADPhysicalSmokeApp> {
  String _status =
      'Initializing Android Still Image Export Physical Smoke (Unit AD)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 90), () {
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD: TIMEOUT (90s exceeded)');
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_PHYSICAL_FAIL');
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
    print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD: START');
    final runId = 'unit_ad_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? tempPngSourceFile;
    File? tempNonSquarePngFile;
    File? tempBaseJpegFile;
    File? tempExif6SourceFile;

    File? lane1OutputFile;
    File? lane2OutputFile;
    File? lane3OutputFile;
    File? lane4OutputFile;
    File? lane5TransformOutputFile;
    File? lane5OverlayOutputFile;
    File? lane6HeicOutputFile;
    File? lane6WebpOutputFile;
    File? lane6ApplyRotateOutputFile;
    File? lane6InvalidPolicyOutputFile;
    File? lane7OutputFile;
    File? lane8OutputFile;

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
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD: Copying still_C.png to temp...',
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
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD: Source PNG ready at $pngSourcePath (${rawPngBytes.length} bytes)',
      );

      // Decode source PNG to get baseline dimensions
      final sourceUiImage = await decodeImageFromBytes(rawPngBytes);
      final sourcePngWidth = sourceUiImage.width;
      final sourcePngHeight = sourceUiImage.height;
      print(
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD: Decoded source PNG dimensions: ${sourcePngWidth}x$sourcePngHeight',
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
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD: Baseline non-square JPEG ready: ${optResult.outputPath} (${baseJpegWidth}x$baseJpegHeight, ${rawBaseJpegBytes.length} bytes)',
      );

      // ── Step 3: Create EXIF orientation 6 JPEG fixture ────────────────────
      final exif6Bytes = createExifOrientedJpegBytes(rawBaseJpegBytes, 6);
      tempExif6SourceFile = File('${tempDir.path}/${runId}_exif6_source.jpg');
      filesToClean.add(tempExif6SourceFile);
      await tempExif6SourceFile.writeAsBytes(exif6Bytes, flush: true);
      print(
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD: EXIF-6 fixture ready at ${tempExif6SourceFile.path} (${exif6Bytes.length} bytes)',
      );

      // ══════════════════════════════════════════════════════════════════════
      // Lane 1: PNG-to-JPEG happy path
      // ══════════════════════════════════════════════════════════════════════
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE1: START (PNG to JPEG)');
      final lane1OutputPath = '${tempDir.path}/${runId}_lane1_out.jpg';
      lane1OutputFile = File(lane1OutputPath);
      filesToClean.add(lane1OutputFile);

      try {
        final result1 = await VanguardEngine.exportImage(
          sourcePath: pngSourcePath,
          outputPath: lane1OutputPath,
          format: 'jpeg',
          quality: 0.85,
          orientationPolicy: 'preserve',
        );

        final outExists = await lane1OutputFile.exists();
        final outBytes = outExists ? await lane1OutputFile.length() : 0;
        final successKey = result1['success'] == true;
        final pathKey = result1['path'] == lane1OutputPath;
        final formatKey = result1['format'] == 'jpeg';
        final sizeKey = (result1['fileSizeBytes'] as num?)?.toInt() == outBytes;
        final widthKey = (result1['width'] as num?)?.toInt() ?? 0;
        final heightKey = (result1['height'] as num?)?.toInt() ?? 0;

        final decodedUiImage = await decodeImageFromBytes(
          await lane1OutputFile.readAsBytes(),
        );
        final decodedWidth = decodedUiImage.width;
        final decodedHeight = decodedUiImage.height;

        final dimsMatch =
            decodedWidth == widthKey &&
            decodedHeight == heightKey &&
            widthKey == sourcePngWidth &&
            heightKey == sourcePngHeight;

        lane1Pass =
            outExists &&
            outBytes > 0 &&
            successKey &&
            pathKey &&
            formatKey &&
            sizeKey &&
            dimsMatch;

        lane1Map = <String, dynamic>{
          'pass': lane1Pass,
          'outputPath': lane1OutputPath,
          'outputBytes': outBytes,
          'result': result1,
          'decodedDimensions': '${decodedWidth}x$decodedHeight',
          'sourceDimensions': '${sourcePngWidth}x$sourcePngHeight',
        };
        print(
          'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE1: DONE (pass=$lane1Pass, bytes=$outBytes, dims=${decodedWidth}x$decodedHeight)',
        );
      } catch (e, st) {
        print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE1: ERROR: $e\n$st');
        lane1Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane1Pass = false;
      }
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE1_PASS: $lane1Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 2: EXIF-6 preserve lane (baked pixels, swapped dimensions)
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE2: START (EXIF 6 preserve)',
      );
      final lane2OutputPath = '${tempDir.path}/${runId}_lane2_exif6_out.jpg';
      lane2OutputFile = File(lane2OutputPath);
      filesToClean.add(lane2OutputFile);

      try {
        final result2 = await VanguardEngine.exportImage(
          sourcePath: tempExif6SourceFile.path,
          outputPath: lane2OutputPath,
          format: 'jpeg',
          quality: 0.85,
          orientationPolicy: 'preserve',
        );

        final outExists = await lane2OutputFile.exists();
        final outBytes = outExists ? await lane2OutputFile.length() : 0;
        final successKey = result2['success'] == true;
        final pathKey = result2['path'] == lane2OutputPath;
        final formatKey = result2['format'] == 'jpeg';
        final sizeKey = (result2['fileSizeBytes'] as num?)?.toInt() == outBytes;
        final resultWidth = (result2['width'] as num?)?.toInt() ?? 0;
        final resultHeight = (result2['height'] as num?)?.toInt() ?? 0;

        final decodedUiImage = await decodeImageFromBytes(
          await lane2OutputFile.readAsBytes(),
        );
        final decodedWidth = decodedUiImage.width;
        final decodedHeight = decodedUiImage.height;

        // Orientation 6 rotates 90 CW: raw width/height (baseJpegWidth x baseJpegHeight) become swapped
        final isNonSquareBaseline =
            baseJpegWidth > 0 &&
            baseJpegHeight > 0 &&
            baseJpegWidth != baseJpegHeight;
        final dimsSwapped =
            resultWidth == baseJpegHeight && resultHeight == baseJpegWidth;
        final decodedMatch =
            decodedWidth == resultWidth && decodedHeight == resultHeight;

        lane2Pass =
            outExists &&
            outBytes > 0 &&
            successKey &&
            pathKey &&
            formatKey &&
            sizeKey &&
            isNonSquareBaseline &&
            dimsSwapped &&
            decodedMatch;

        lane2Map = <String, dynamic>{
          'pass': lane2Pass,
          'outputPath': lane2OutputPath,
          'outputBytes': outBytes,
          'result': result2,
          'baselineDimensions': '${baseJpegWidth}x$baseJpegHeight',
          'resultDimensions': '${resultWidth}x$resultHeight',
          'decodedDimensions': '${decodedWidth}x$decodedHeight',
          'isNonSquareBaseline': isNonSquareBaseline,
          'dimsSwapped': dimsSwapped,
        };
        print(
          'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE2: DONE (pass=$lane2Pass, bytes=$outBytes, baseline=${baseJpegWidth}x$baseJpegHeight, baked=${resultWidth}x$resultHeight)',
        );
      } catch (e, st) {
        print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE2: ERROR: $e\n$st');
        lane2Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane2Pass = false;
      }
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE2_PASS: $lane2Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 3: Valid colorMatrix lane (RGB zeroed, alpha preserved)
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE3: START (valid colorMatrix)',
      );
      final lane3OutputPath =
          '${tempDir.path}/${runId}_lane3_colormatrix_out.png';
      lane3OutputFile = File(lane3OutputPath);
      filesToClean.add(lane3OutputFile);

      try {
        final zeroRgbFilter = <Map<String, dynamic>>[
          {
            'type': 'colorMatrix',
            'enabled': true,
            'parameters': {
              'matrix': <double>[
                0.0, 0.0, 0.0, 0.0, 0.0, // R = 0
                0.0, 0.0, 0.0, 0.0, 0.0, // G = 0
                0.0, 0.0, 0.0, 0.0, 0.0, // B = 0
                0.0, 0.0, 0.0, 1.0, 0.0, // A = 1*A
              ],
            },
          },
        ];

        final result3 = await VanguardEngine.exportImage(
          sourcePath: pngSourcePath,
          outputPath: lane3OutputPath,
          format: 'png',
          filters: zeroRgbFilter,
          orientationPolicy: 'preserve',
        );

        final outExists = await lane3OutputFile.exists();
        final outBytes = outExists ? await lane3OutputFile.length() : 0;
        final successKey = result3['success'] == true;

        final decodedUiImage = await decodeImageFromBytes(
          await lane3OutputFile.readAsBytes(),
        );
        final byteData = await decodedUiImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final pixelBytes = byteData!.buffer.asUint8List();

        var totalR = 0;
        var totalG = 0;
        var totalB = 0;
        var totalA = 0;
        var maxA = 0;
        final numPixels = decodedUiImage.width * decodedUiImage.height;

        // Sample up to 1000 pixels uniformly
        final step = (numPixels / 1000).ceil().clamp(1, numPixels);
        var sampledCount = 0;
        for (var i = 0; i < numPixels; i += step) {
          final offset = i * 4;
          final r = pixelBytes[offset];
          final g = pixelBytes[offset + 1];
          final b = pixelBytes[offset + 2];
          final a = pixelBytes[offset + 3];

          totalR += r;
          totalG += g;
          totalB += b;
          totalA += a;
          if (a > maxA) maxA = a;
          sampledCount++;
        }

        final avgR = totalR / sampledCount;
        final avgG = totalG / sampledCount;
        final avgB = totalB / sampledCount;
        final avgA = totalA / sampledCount;

        // RGB must be black (0) and alpha preserved (maxA >= 200 and avgA >= 50)
        final rgbIsBlack = avgR <= 2.0 && avgG <= 2.0 && avgB <= 2.0;
        final alphaPreserved = maxA >= 200 && avgA >= 50.0;

        lane3Pass =
            outExists &&
            outBytes > 0 &&
            successKey &&
            rgbIsBlack &&
            alphaPreserved;

        lane3Map = <String, dynamic>{
          'pass': lane3Pass,
          'outputPath': lane3OutputPath,
          'outputBytes': outBytes,
          'result': result3,
          'avgR': avgR,
          'avgG': avgG,
          'avgB': avgB,
          'avgA': avgA,
          'maxA': maxA,
          'rgbIsBlack': rgbIsBlack,
          'alphaPreserved': alphaPreserved,
        };
        print(
          'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE3: DONE (pass=$lane3Pass, bytes=$outBytes, avgR=$avgR, avgG=$avgG, avgB=$avgB, maxA=$maxA)',
        );
      } catch (e, st) {
        print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE3: ERROR: $e\n$st');
        lane3Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane3Pass = false;
      }
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE3_PASS: $lane3Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 4: Malformed colorMatrix + unknown filter lane
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE4: START (malformed + unknown filter skip)',
      );
      final lane4OutputPath =
          '${tempDir.path}/${runId}_lane4_malformed_out.jpg';
      lane4OutputFile = File(lane4OutputPath);
      filesToClean.add(lane4OutputFile);

      try {
        final mixedFilters = <Map<String, dynamic>>[
          {
            'type': 'colorMatrix',
            'enabled': true,
            'parameters': {
              'matrix': <double>[1.0, 2.0, 3.0], // malformed: size != 20
            },
          },
          {
            'type': 'colorMatrix',
            'enabled': true,
            'parameters': {
              'matrix': 'not_a_list', // malformed: not a list
            },
          },
          {
            'type': 'colorMatrix',
            'enabled': true,
            // missing parameters
          },
          {
            'type': 'customUnknownLutFilter',
            'enabled': true,
            'parameters': {'strength': 1.0},
          },
          {
            'type': 'transform',
            'enabled': false, // disabled transform -> skipped
          },
          {
            'type': 'overlay',
            'enabled': false, // disabled overlay -> skipped
          },
        ];

        final result4 = await VanguardEngine.exportImage(
          sourcePath: pngSourcePath,
          outputPath: lane4OutputPath,
          format: 'jpeg',
          quality: 0.85,
          filters: mixedFilters,
          orientationPolicy: 'preserve',
        );

        final outExists = await lane4OutputFile.exists();
        final outBytes = outExists ? await lane4OutputFile.length() : 0;
        final successKey = result4['success'] == true;

        final decodedUiImage = await decodeImageFromBytes(
          await lane4OutputFile.readAsBytes(),
        );
        final decodedWidth = decodedUiImage.width;
        final decodedHeight = decodedUiImage.height;
        final dimsValid =
            decodedWidth == sourcePngWidth && decodedHeight == sourcePngHeight;

        lane4Pass = outExists && outBytes > 0 && successKey && dimsValid;

        lane4Map = <String, dynamic>{
          'pass': lane4Pass,
          'outputPath': lane4OutputPath,
          'outputBytes': outBytes,
          'result': result4,
          'decodedDimensions': '${decodedWidth}x$decodedHeight',
        };
        print(
          'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE4: DONE (pass=$lane4Pass, bytes=$outBytes, dims=${decodedWidth}x$decodedHeight)',
        );
      } catch (e, st) {
        print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE4: ERROR: $e\n$st');
        lane4Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane4Pass = false;
      }
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE4_PASS: $lane4Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 5: Enabled transform / overlay rejection lane
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE5: START (enabled transform/overlay rejection)',
      );
      final lane5TransformPath =
          '${tempDir.path}/${runId}_lane5_transform_out.jpg';
      final lane5OverlayPath = '${tempDir.path}/${runId}_lane5_overlay_out.jpg';
      lane5TransformOutputFile = File(lane5TransformPath);
      lane5OverlayOutputFile = File(lane5OverlayPath);
      filesToClean.add(lane5TransformOutputFile);
      filesToClean.add(lane5OverlayOutputFile);

      try {
        String? transformErrorCode;
        try {
          await VanguardEngine.exportImage(
            sourcePath: pngSourcePath,
            outputPath: lane5TransformPath,
            format: 'jpeg',
            filters: [
              {'type': 'transform', 'enabled': true},
            ],
            orientationPolicy: 'preserve',
          );
        } on PlatformException catch (pe) {
          transformErrorCode = pe.code;
        }

        final transformFileExists = await lane5TransformOutputFile.exists();

        String? overlayErrorCode;
        try {
          await VanguardEngine.exportImage(
            sourcePath: pngSourcePath,
            outputPath: lane5OverlayPath,
            format: 'jpeg',
            filters: [
              {'type': 'overlay', 'enabled': true},
            ],
            orientationPolicy: 'preserve',
          );
        } on PlatformException catch (pe) {
          overlayErrorCode = pe.code;
        }

        final overlayFileExists = await lane5OverlayOutputFile.exists();

        final transformRejected =
            transformErrorCode == 'EXPORT_IMAGE_UNSUPPORTED_FILTER' &&
            !transformFileExists;
        final overlayRejected =
            overlayErrorCode == 'EXPORT_IMAGE_UNSUPPORTED_FILTER' &&
            !overlayFileExists;

        lane5Pass = transformRejected && overlayRejected;

        lane5Map = <String, dynamic>{
          'pass': lane5Pass,
          'transformErrorCode': transformErrorCode,
          'transformFileExists': transformFileExists,
          'transformRejected': transformRejected,
          'overlayErrorCode': overlayErrorCode,
          'overlayFileExists': overlayFileExists,
          'overlayRejected': overlayRejected,
        };
        print(
          'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE5: DONE (pass=$lane5Pass, transformCode=$transformErrorCode, overlayCode=$overlayErrorCode)',
        );
      } catch (e, st) {
        print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE5: ERROR: $e\n$st');
        lane5Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane5Pass = false;
      }
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE5_PASS: $lane5Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 6: Unsupported format & orientation policy rejection lane
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE6: START (HEIC success + unsupported format/policy rejection)',
      );
      final lane6HeicPath = '${tempDir.path}/${runId}_lane6_out.heic';
      final lane6WebpPath = '${tempDir.path}/${runId}_lane6_out.webp';
      final lane6ApplyRotatePath =
          '${tempDir.path}/${runId}_lane6_applyrotate_out.jpg';
      final lane6InvalidPolicyPath =
          '${tempDir.path}/${runId}_lane6_invalid_policy_out.jpg';

      lane6HeicOutputFile = File(lane6HeicPath);
      lane6WebpOutputFile = File(lane6WebpPath);
      lane6ApplyRotateOutputFile = File(lane6ApplyRotatePath);
      lane6InvalidPolicyOutputFile = File(lane6InvalidPolicyPath);

      filesToClean.add(lane6HeicOutputFile);
      filesToClean.add(lane6WebpOutputFile);
      filesToClean.add(lane6ApplyRotateOutputFile);
      filesToClean.add(lane6InvalidPolicyOutputFile);

      try {
        // 6a: HEIC format (supported on capable SM-A566B -- must succeed)
        Map<String, dynamic>? heicResult;
        String? heicErrorCode;
        try {
          heicResult = await VanguardEngine.exportImage(
            sourcePath: pngSourcePath,
            outputPath: lane6HeicPath,
            format: 'heic',
            quality: 0.85,
            orientationPolicy: 'preserve',
          );
        } on PlatformException catch (pe) {
          heicErrorCode = pe.code;
        }
        final heicFileExists = await lane6HeicOutputFile.exists();
        final heicOutputBytes = heicFileExists
            ? await lane6HeicOutputFile.length()
            : 0;
        final heicIsHeicLike = heicFileExists
            ? await isIsoBmffHeicLike(lane6HeicOutputFile)
            : false;
        final heicResultWidth = (heicResult?['width'] as num?)?.toInt() ?? 0;
        final heicResultHeight = (heicResult?['height'] as num?)?.toInt() ?? 0;
        final heicFormatField = heicResult?['format'] as String?;

        // Best-effort decode: some Skia builds cannot decode HEIC directly,
        // so a decode failure does not fail the lane -- the ftyp brand check
        // and the platform-reported result dimensions above remain the
        // required proof.
        int? heicDecodedWidth;
        int? heicDecodedHeight;
        if (heicFileExists && heicOutputBytes > 0) {
          try {
            final decodedHeicImage = await decodeImageFromBytes(
              await lane6HeicOutputFile.readAsBytes(),
            );
            heicDecodedWidth = decodedHeicImage.width;
            heicDecodedHeight = decodedHeicImage.height;
          } catch (_) {
            heicDecodedWidth = null;
            heicDecodedHeight = null;
          }
        }
        final heicDecodedDimensionsPositive =
            heicDecodedWidth == null ||
            heicDecodedHeight == null ||
            (heicDecodedWidth > 0 && heicDecodedHeight > 0);

        final heicPass =
            heicErrorCode == null &&
            heicResult?['success'] == true &&
            heicFileExists &&
            heicOutputBytes > 0 &&
            heicIsHeicLike &&
            heicResultWidth > 0 &&
            heicResultHeight > 0 &&
            heicDecodedDimensionsPositive &&
            heicFormatField == 'heic';

        // 6b: WEBP format
        String? webpErrorCode;
        try {
          await VanguardEngine.exportImage(
            sourcePath: pngSourcePath,
            outputPath: lane6WebpPath,
            format: 'webp',
            orientationPolicy: 'preserve',
          );
        } on PlatformException catch (pe) {
          webpErrorCode = pe.code;
        }
        final webpFileExists = await lane6WebpOutputFile.exists();
        final webpRejected =
            webpErrorCode == 'EXPORT_IMAGE_UNSUPPORTED_FORMAT' &&
            !webpFileExists;

        // 6c: applyAndRotate policy
        String? applyRotateErrorCode;
        try {
          await VanguardEngine.exportImage(
            sourcePath: pngSourcePath,
            outputPath: lane6ApplyRotatePath,
            format: 'jpeg',
            orientationPolicy: 'applyAndRotate',
          );
        } on PlatformException catch (pe) {
          applyRotateErrorCode = pe.code;
        }
        final applyRotateFileExists = await lane6ApplyRotateOutputFile.exists();
        final applyRotateRejected =
            applyRotateErrorCode == 'EXPORT_IMAGE_FAILED' &&
            !applyRotateFileExists;

        // 6d: unknown orientation policy
        String? invalidPolicyErrorCode;
        try {
          await VanguardEngine.exportImage(
            sourcePath: pngSourcePath,
            outputPath: lane6InvalidPolicyPath,
            format: 'jpeg',
            orientationPolicy: 'unknownPolicy123',
          );
        } on PlatformException catch (pe) {
          invalidPolicyErrorCode = pe.code;
        }
        final invalidPolicyFileExists = await lane6InvalidPolicyOutputFile
            .exists();
        final invalidPolicyRejected =
            invalidPolicyErrorCode == 'EXPORT_IMAGE_INVALID_ARGUMENTS' &&
            !invalidPolicyFileExists;

        lane6Pass =
            heicPass &&
            webpRejected &&
            applyRotateRejected &&
            invalidPolicyRejected;

        lane6Map = <String, dynamic>{
          'pass': lane6Pass,
          'heicPass': heicPass,
          'heicErrorCode': heicErrorCode,
          'heicFileExists': heicFileExists,
          'heicOutputBytes': heicOutputBytes,
          'heicIsHeicLike': heicIsHeicLike,
          'heicResultWidth': heicResultWidth,
          'heicResultHeight': heicResultHeight,
          'heicDecodedDimensions':
              (heicDecodedWidth != null && heicDecodedHeight != null)
              ? '${heicDecodedWidth}x$heicDecodedHeight'
              : null,
          'heicFormatField': heicFormatField,
          'heicResult': heicResult,
          'webpErrorCode': webpErrorCode,
          'webpFileExists': webpFileExists,
          'webpRejected': webpRejected,
          'applyRotateErrorCode': applyRotateErrorCode,
          'applyRotateFileExists': applyRotateFileExists,
          'applyRotateRejected': applyRotateRejected,
          'invalidPolicyErrorCode': invalidPolicyErrorCode,
          'invalidPolicyFileExists': invalidPolicyFileExists,
          'invalidPolicyRejected': invalidPolicyRejected,
        };
        print(
          'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE6: DONE (pass=$lane6Pass, heicPass=$heicPass, heicBytes=$heicOutputBytes, webp=$webpErrorCode, applyRotate=$applyRotateErrorCode, invalidPolicy=$invalidPolicyErrorCode)',
        );
      } catch (e, st) {
        print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE6: ERROR: $e\n$st');
        lane6Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane6Pass = false;
      }
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE6_PASS: $lane6Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 7: Existing-output replacement lane
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE7: START (existing output replacement)',
      );
      final lane7OutputPath =
          '${tempDir.path}/${runId}_lane7_replacement_out.jpg';
      lane7OutputFile = File(lane7OutputPath);
      filesToClean.add(lane7OutputFile);

      try {
        const sentinelData =
            'SENTINEL_DUMMY_DATA_PREEXISTING_OUTPUT_FILE_1234567890';
        await lane7OutputFile.writeAsString(sentinelData, flush: true);
        final initialExists = await lane7OutputFile.exists();
        final initialLength = await lane7OutputFile.length();

        final result7 = await VanguardEngine.exportImage(
          sourcePath: pngSourcePath,
          outputPath: lane7OutputPath,
          format: 'jpeg',
          quality: 0.85,
          orientationPolicy: 'preserve',
        );

        final outExists = await lane7OutputFile.exists();
        final outBytes = outExists ? await lane7OutputFile.length() : 0;
        final successKey = result7['success'] == true;
        final contentChanged = outBytes != initialLength;

        final decodedUiImage = await decodeImageFromBytes(
          await lane7OutputFile.readAsBytes(),
        );
        final decodedWidth = decodedUiImage.width;
        final decodedHeight = decodedUiImage.height;
        final dimsValid =
            decodedWidth == sourcePngWidth && decodedHeight == sourcePngHeight;

        lane7Pass =
            initialExists &&
            outExists &&
            contentChanged &&
            outBytes > 0 &&
            successKey &&
            dimsValid;

        lane7Map = <String, dynamic>{
          'pass': lane7Pass,
          'outputPath': lane7OutputPath,
          'initialLength': initialLength,
          'outputBytes': outBytes,
          'result': result7,
          'decodedDimensions': '${decodedWidth}x$decodedHeight',
        };
        print(
          'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE7: DONE (pass=$lane7Pass, initialBytes=$initialLength, newBytes=$outBytes)',
        );
      } catch (e, st) {
        print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE7: ERROR: $e\n$st');
        lane7Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane7Pass = false;
      }
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE7_PASS: $lane7Pass');

      // ══════════════════════════════════════════════════════════════════════
      // Lane 8: Invalid argument lane
      // ══════════════════════════════════════════════════════════════════════
      print(
        'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE8: START (invalid arguments via raw channel)',
      );
      final lane8OutputPath = '${tempDir.path}/${runId}_lane8_out.jpg';
      lane8OutputFile = File(lane8OutputPath);
      filesToClean.add(lane8OutputFile);

      try {
        const rawChannel = MethodChannel('vanguard_media_engine');

        // 8a: empty sourcePath
        String? err8a;
        try {
          await rawChannel.invokeMethod('exportImage', {
            'sourcePath': '',
            'outputPath': lane8OutputPath,
            'format': 'jpeg',
            'quality': 0.85,
            'orientationPolicy': 'preserve',
          });
        } on PlatformException catch (pe) {
          err8a = pe.code;
        }

        // 8b: empty outputPath
        String? err8b;
        try {
          await rawChannel.invokeMethod('exportImage', {
            'sourcePath': pngSourcePath,
            'outputPath': '',
            'format': 'jpeg',
            'quality': 0.85,
            'orientationPolicy': 'preserve',
          });
        } on PlatformException catch (pe) {
          err8b = pe.code;
        }

        // 8c: non-existent source
        String? err8c;
        try {
          await rawChannel.invokeMethod('exportImage', {
            'sourcePath': '${tempDir.path}/nonexistent_$runId.png',
            'outputPath': lane8OutputPath,
            'format': 'jpeg',
            'quality': 0.85,
            'orientationPolicy': 'preserve',
          });
        } on PlatformException catch (pe) {
          err8c = pe.code;
        }

        // 8d: non-list filters
        String? err8d;
        try {
          await rawChannel.invokeMethod('exportImage', {
            'sourcePath': pngSourcePath,
            'outputPath': lane8OutputPath,
            'format': 'jpeg',
            'quality': 0.85,
            'orientationPolicy': 'preserve',
            'filters': 'not_a_list',
          });
        } on PlatformException catch (pe) {
          err8d = pe.code;
        }

        // 8e: non-number quality
        String? err8e;
        try {
          await rawChannel.invokeMethod('exportImage', {
            'sourcePath': pngSourcePath,
            'outputPath': lane8OutputPath,
            'format': 'jpeg',
            'quality': 'high_quality_string',
            'orientationPolicy': 'preserve',
          });
        } on PlatformException catch (pe) {
          err8e = pe.code;
        }

        // 8f: invalid parent directory
        String? err8f;
        try {
          await rawChannel.invokeMethod('exportImage', {
            'sourcePath': pngSourcePath,
            'outputPath': '/invalid_nonexistent_dir_xyz_12345/out.jpg',
            'format': 'jpeg',
            'quality': 0.85,
            'orientationPolicy': 'preserve',
          });
        } on PlatformException catch (pe) {
          err8f = pe.code;
        }

        const expectedCode = 'EXPORT_IMAGE_INVALID_ARGUMENTS';
        final pass8a = err8a == expectedCode;
        final pass8b = err8b == expectedCode;
        final pass8c = err8c == expectedCode;
        final pass8d = err8d == expectedCode;
        final pass8e = err8e == expectedCode;
        final pass8f = err8f == expectedCode;

        lane8Pass = pass8a && pass8b && pass8c && pass8d && pass8e && pass8f;

        lane8Map = <String, dynamic>{
          'pass': lane8Pass,
          'err8a_emptySource': err8a,
          'err8b_emptyOutput': err8b,
          'err8c_nonExistentSource': err8c,
          'err8d_nonListFilters': err8d,
          'err8e_nonNumberQuality': err8e,
          'err8f_invalidParentDir': err8f,
        };
        print(
          'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE8: DONE (pass=$lane8Pass, 8a=$err8a, 8b=$err8b, 8c=$err8c, 8d=$err8d, 8e=$err8e, 8f=$err8f)',
        );
      } catch (e, st) {
        print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE8: ERROR: $e\n$st');
        lane8Map = <String, dynamic>{
          'pass': false,
          'error': '$e',
          'stack': '$st',
        };
        lane8Pass = false;
      }
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_LANE8_PASS: $lane8Pass');
    } catch (e, st) {
      print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD: TOP-LEVEL ERROR: $e\n$st');
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
      'unit': 'Phase5UnitAD_Phase10C3L',
      'target': 'android_still_image_export_physical',
      'pass': allRequiredPass,
      'lanes': <String, dynamic>{
        'lane1_png_to_jpeg_happy_path': lane1Map,
        'lane2_exif6_preserve_baked_orientation': lane2Map,
        'lane3_valid_colormatrix_filter': lane3Map,
        'lane4_malformed_and_unknown_filters_skipped': lane4Map,
        'lane5_enabled_transform_overlay_rejected': lane5Map,
        'lane6_unsupported_format_and_policy_rejected': lane6Map,
        'lane7_existing_output_replaced': lane7Map,
        'lane8_invalid_arguments_rejected': lane8Map,
      },
      'error': topLevelError,
    };

    print('ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_JSON:${jsonEncode(payload)}');
    print(
      allRequiredPass
          ? 'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_PHYSICAL_PASS'
          : 'ANDROID_STILL_IMAGE_EXPORT_UNIT_AD_PHYSICAL_FAIL',
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
