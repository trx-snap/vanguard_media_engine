// android_still_image_exif_unit_s_physical_smoke.dart
// Vanguard Media Engine - Android Still-Image EXIF Orientation Normalization & Transform Mapping (Unit S)
// ignore_for_file: avoid_print

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:vanguard_media_engine/vanguard_media_engine.dart";

String sidecarPathForVideoPath(String videoPath) {
  final lastSeparator = videoPath.lastIndexOf("/");
  final lastDot = videoPath.lastIndexOf(".");
  if (lastDot <= lastSeparator) {
    return "$videoPath.roi.json";
  }
  return "${videoPath.substring(0, lastDot)}.roi.json";
}

bool _isValidExportRoiSidecar({
  required String content,
  required int expectedWidth,
  required int expectedHeight,
  required double expectedDurationSeconds,
  double durationToleranceSeconds = 0.25,
}) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) return false;
    final sidecar = VGROISidecar.fromJson(decoded);
    final width = sidecar.videoIdentity.width;
    final height = sidecar.videoIdentity.height;
    final durationMs = sidecar.videoIdentity.durationMs;
    final durationSeconds = durationMs / 1000.0;
    final durationValid =
        (durationSeconds - expectedDurationSeconds).abs() <=
        durationToleranceSeconds;

    return sidecar.version == 1 &&
        sidecar.sourceType == "export" &&
        sidecar.platform == "android" &&
        sidecar.coordinateSpace == "export_output_normalized" &&
        width == expectedWidth &&
        height == expectedHeight &&
        durationMs > 0 &&
        durationValid &&
        sidecar.samples.isEmpty &&
        sidecar.finalized == true;
  } catch (_) {
    return false;
  }
}

Map<String, dynamic> _mediaInfoToMap(MediaInfo info) {
  return <String, dynamic>{
    "kind": info.kind.name,
    "container": info.container,
    "videoCodec": info.videoCodec,
    "audioCodec": info.audioCodec,
    "width": info.width,
    "height": info.height,
    "durationSeconds": info.durationSeconds,
    "bitrateKbps": info.bitrateKbps,
    "fps": info.fps,
    "fileSizeBytes": info.fileSizeBytes,
    "hasVideo": info.hasVideo,
    "hasAudio": info.hasAudio,
    "isHDR": info.isHDR,
    "hasMoovAtFront": info.hasMoovAtFront,
    "hasRotationTransform": info.hasRotationTransform,
    "hasEmbeddedMetadata": info.hasEmbeddedMetadata,
    "encodedWidth": info.encodedWidth,
    "encodedHeight": info.encodedHeight,
    "displayWidth": info.displayWidth,
    "displayHeight": info.displayHeight,
    "rotationDegrees": info.rotationDegrees,
    "transformA": info.transformA,
    "transformB": info.transformB,
    "transformC": info.transformC,
    "transformD": info.transformD,
    "transformTx": info.transformTx,
    "transformTy": info.transformTy,
    "orientationStatus": info.orientationStatus,
  };
}

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
      "Base image is not a valid JPEG (missing SOI marker 0xFF 0xD8)",
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

void main() {
  runApp(const AndroidStillImageExifUnitSPhysicalSmokeApp());
}

class AndroidStillImageExifUnitSPhysicalSmokeApp extends StatefulWidget {
  const AndroidStillImageExifUnitSPhysicalSmokeApp({super.key});

  @override
  State<AndroidStillImageExifUnitSPhysicalSmokeApp> createState() =>
      _AndroidStillImageExifUnitSPhysicalSmokeAppState();
}

class _AndroidStillImageExifUnitSPhysicalSmokeAppState
    extends State<AndroidStillImageExifUnitSPhysicalSmokeApp> {
  String _status =
      "Initializing Android Still-Image EXIF Unit S Physical Smoke...";
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 120), () {
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S: TIMEOUT (120s exceeded)");
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_PHYSICAL_FAIL");
      exit(1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSmoke());
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _runSmoke() async {
    print("ANDROID_STILL_IMAGE_EXIF_UNIT_S: START");
    final runId = "unit_s_${DateTime.now().millisecondsSinceEpoch}";
    final tempDir = Directory.systemTemp;

    File? tempStillSourceFile;
    File? tempClipBSourceFile;
    File? tempBaseJpegFile;
    File? tempExif6File;
    File? tempExif3File;
    File? tempExif8File;
    File? tempExif2File;
    File? tempExif4File;
    File? tempExif5File;
    File? tempExif7File;
    File? tempCorruptFile;

    File? lane1OutputFile;
    File? lane1SidecarFile;

    File? lane2OutputFile;
    File? lane2SidecarFile;

    File? lane3OutputFile;
    File? lane3SidecarFile;

    File? lane4OutputFile;
    File? lane4SidecarFile;

    File? lane5OutputFile;
    File? lane5SidecarFile;

    Map<String, dynamic>? lane1Results;
    Map<String, dynamic>? lane2Results;
    Map<String, dynamic>? lane3Results;
    Map<String, dynamic>? lane4Results;
    Map<String, dynamic>? lane5Results;
    final cleanupObservations = <String, dynamic>{};

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    String? topLevelError;

    try {
      // Step 1: Copy rootBundle assets to temp files and create EXIF JPEG fixtures
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S: Loading asset fixtures...");
      final stillByteData = await rootBundle.load(
        "assets/manual_test_clips/still_C.png",
      );
      final rawStillBytes = stillByteData.buffer.asUint8List(
        stillByteData.offsetInBytes,
        stillByteData.lengthInBytes,
      );
      tempStillSourceFile = File("${tempDir.path}/${runId}_source_still_C.png");
      await tempStillSourceFile.writeAsBytes(
        Uint8List.fromList(rawStillBytes),
        flush: true,
      );
      print(
        "ANDROID_STILL_IMAGE_EXIF_UNIT_S: Still image PNG ready at ${tempStillSourceFile.path} (${rawStillBytes.length} bytes)",
      );

      final clipBByteData = await rootBundle.load(
        "assets/manual_test_clips/clip_B.mov",
      );
      final rawClipBBytes = clipBByteData.buffer.asUint8List(
        clipBByteData.offsetInBytes,
        clipBByteData.lengthInBytes,
      );
      tempClipBSourceFile = File("${tempDir.path}/${runId}_source_clip_B.mov");
      await tempClipBSourceFile.writeAsBytes(
        Uint8List.fromList(rawClipBBytes),
        flush: true,
      );
      final clipBSourcePath = tempClipBSourceFile.path;
      print(
        "ANDROID_STILL_IMAGE_EXIF_UNIT_S: Video clip B ready at $clipBSourcePath (${rawClipBBytes.length} bytes)",
      );

      // Step 2: Use VanguardImageOptimizer to produce a valid baseline JPEG fixture
      print(
        "ANDROID_STILL_IMAGE_EXIF_UNIT_S: Optimizing PNG to baseline JPEG...",
      );
      tempBaseJpegFile = File("${tempDir.path}/${runId}_base_still.jpg");
      final optResult = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: tempStillSourceFile.path,
          outputPath: tempBaseJpegFile.path,
          format: "jpeg",
          quality: 0.85,
        ),
      );
      print(
        "ANDROID_STILL_IMAGE_EXIF_UNIT_S: Baseline JPEG produced: ${optResult.outputPath} (${optResult.width}x${optResult.height}, ${optResult.fileSizeBytes} bytes)",
      );

      final baseJpegBytes = await tempBaseJpegFile.readAsBytes();
      if (baseJpegBytes.length < 2 ||
          baseJpegBytes[0] != 0xFF ||
          baseJpegBytes[1] != 0xD8) {
        throw StateError("Base JPEG fixture does not start with SOI 0xFF 0xD8");
      }

      // Step 3: Create EXIF-oriented JPEG fixtures (orientations 2..8)
      print(
        "ANDROID_STILL_IMAGE_EXIF_UNIT_S: Generating EXIF orientation fixtures...",
      );
      tempExif6File = File("${tempDir.path}/${runId}_exif_6.jpg");
      await tempExif6File.writeAsBytes(
        createExifOrientedJpegBytes(baseJpegBytes, 6),
        flush: true,
      );

      tempExif3File = File("${tempDir.path}/${runId}_exif_3.jpg");
      await tempExif3File.writeAsBytes(
        createExifOrientedJpegBytes(baseJpegBytes, 3),
        flush: true,
      );

      tempExif8File = File("${tempDir.path}/${runId}_exif_8.jpg");
      await tempExif8File.writeAsBytes(
        createExifOrientedJpegBytes(baseJpegBytes, 8),
        flush: true,
      );

      tempExif2File = File("${tempDir.path}/${runId}_exif_2.jpg");
      await tempExif2File.writeAsBytes(
        createExifOrientedJpegBytes(baseJpegBytes, 2),
        flush: true,
      );

      tempExif4File = File("${tempDir.path}/${runId}_exif_4.jpg");
      await tempExif4File.writeAsBytes(
        createExifOrientedJpegBytes(baseJpegBytes, 4),
        flush: true,
      );

      tempExif5File = File("${tempDir.path}/${runId}_exif_5.jpg");
      await tempExif5File.writeAsBytes(
        createExifOrientedJpegBytes(baseJpegBytes, 5),
        flush: true,
      );

      tempExif7File = File("${tempDir.path}/${runId}_exif_7.jpg");
      await tempExif7File.writeAsBytes(
        createExifOrientedJpegBytes(baseJpegBytes, 7),
        flush: true,
      );

      tempCorruptFile = File("${tempDir.path}/${runId}_corrupt.jpg");
      await tempCorruptFile.writeAsBytes(
        Uint8List.fromList([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
        flush: true,
      );
      print(
        "ANDROID_STILL_IMAGE_EXIF_UNIT_S: Fixtures initialized successfully.",
      );

      // Lane 1: Still-only export using EXIF orientation 6 (rotate 90 CW, 2.0s, 720x1280, 30fps)
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE1: START");
      final lane1OutputPath = "${tempDir.path}/${runId}_lane1_out.mp4";
      final lane1ExpectedSidecarPath = sidecarPathForVideoPath(lane1OutputPath);
      lane1OutputFile = File(lane1OutputPath);
      lane1SidecarFile = File(lane1ExpectedSidecarPath);

      try {
        final clip1 = VGClipDescriptor(
          id: "unit_s_lane1_clip",
          mediaKind: VGMediaKind.image,
          sourcePath: tempExif6File.path,
          durationSeconds: 2.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final draft1 = VGEditorDraft(
          id: "unit_s_draft_lane1",
          clips: [clip1],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final request1 = VGEditorExportRequest(
          outputPath: lane1OutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        final result1 = await VanguardTimelineExporter.exportDraft(
          draft: draft1,
          request: request1,
        );

        final outExists = await lane1OutputFile.exists();
        final outBytes = outExists ? await lane1OutputFile.length() : 0;
        final pathMatch = result1.path == lane1OutputPath;
        final dimsMatch =
            result1.width == 720 && result1.height == 1280 && result1.fps == 30;

        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE1: Inspecting exported output media...",
        );
        final lane1MediaInfo = await VanguardMediaPreparer.inspectMedia(
          lane1OutputPath,
        );
        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE1: MediaInfo: $lane1MediaInfo",
        );

        final durationMeasured =
            lane1MediaInfo?.durationSeconds ?? result1.durationSeconds;
        final durationValid = (durationMeasured - 2.0).abs() <= 0.15;

        final sidecarExists = await lane1SidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await lane1SidecarFile.readAsString()
            : "";
        final sidecarValid = _isValidExportRoiSidecar(
          content: sidecarContent,
          expectedWidth: 720,
          expectedHeight: 1280,
          expectedDurationSeconds: 2.0,
          durationToleranceSeconds: 0.15,
        );

        final mediaValid =
            lane1MediaInfo != null &&
            lane1MediaInfo.hasVideo &&
            lane1MediaInfo.width == 720 &&
            lane1MediaInfo.height == 1280;

        lane1Pass =
            outExists &&
            outBytes > 0 &&
            pathMatch &&
            dimsMatch &&
            durationValid &&
            sidecarExists &&
            sidecarValid &&
            mediaValid;

        lane1Results = <String, dynamic>{
          "pass": lane1Pass,
          "outputPath": result1.path,
          "outputBytes": outBytes,
          "durationSeconds": durationMeasured,
          "width": result1.width,
          "height": result1.height,
          "fps": result1.fps,
          "exportRoiSidecarPath": result1.exportRoiSidecarPath,
          "expectedRoiSidecarPath": lane1ExpectedSidecarPath,
          "sidecarExists": sidecarExists,
          "sidecarValid": sidecarValid,
          "mediaInfo": lane1MediaInfo != null
              ? _mediaInfoToMap(lane1MediaInfo)
              : null,
          "error": lane1Pass
              ? null
              : "Validation failed (exists=$outExists, bytes=$outBytes, pathMatch=$pathMatch, dimsMatch=$dimsMatch, durationValid=$durationValid, sidecarExists=$sidecarExists, sidecarValid=$sidecarValid, mediaValid=$mediaValid)",
        };
        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE1: DONE (pass=$lane1Pass, duration=$durationMeasured, bytes=$outBytes)",
        );
      } catch (e, st) {
        print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE1: ERROR: $e\n$st");
        lane1Results = <String, dynamic>{
          "pass": false,
          "outputPath": lane1OutputPath,
          "outputBytes": 0,
          "durationSeconds": 0.0,
          "width": 0,
          "height": 0,
          "fps": 0,
          "exportRoiSidecarPath": null,
          "expectedRoiSidecarPath": lane1ExpectedSidecarPath,
          "sidecarExists": false,
          "sidecarValid": false,
          "error": "$e",
        };
        lane1Pass = false;
      }
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE1_PASS: $lane1Pass");

      // Lane 2: Mixed hard-cut timeline (EXIF 3 image 1.0s, clip_B trim 0..1s, EXIF 8 image 1.0s = 3.0s)
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE2: START");
      final lane2OutputPath = "${tempDir.path}/${runId}_lane2_out.mp4";
      final lane2ExpectedSidecarPath = sidecarPathForVideoPath(lane2OutputPath);
      lane2OutputFile = File(lane2OutputPath);
      lane2SidecarFile = File(lane2ExpectedSidecarPath);

      try {
        final clip2A = VGClipDescriptor(
          id: "unit_s_lane2_clip_1",
          mediaKind: VGMediaKind.image,
          sourcePath: tempExif3File.path,
          durationSeconds: 1.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final clip2B = VGClipDescriptor(
          id: "unit_s_lane2_clip_2",
          mediaKind: VGMediaKind.video,
          sourcePath: clipBSourcePath,
          durationSeconds: 5.565,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0,
          startTimeSeconds: 1.0,
          speed: 1.0,
        );

        final clip2C = VGClipDescriptor(
          id: "unit_s_lane2_clip_3",
          mediaKind: VGMediaKind.image,
          sourcePath: tempExif8File.path,
          durationSeconds: 1.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0,
          startTimeSeconds: 2.0,
          speed: 1.0,
        );

        final rawDraft2 = VGEditorDraft(
          id: "unit_s_draft_lane2",
          clips: [clip2A, clip2B, clip2C],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final derivedDraft2 = rawDraft2
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final request2 = VGEditorExportRequest(
          outputPath: lane2OutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        final result2 = await VanguardTimelineExporter.exportDraft(
          draft: derivedDraft2,
          request: request2,
        );

        final outExists = await lane2OutputFile.exists();
        final outBytes = outExists ? await lane2OutputFile.length() : 0;
        final pathMatch = result2.path == lane2OutputPath;
        final dimsMatch =
            result2.width == 720 && result2.height == 1280 && result2.fps == 30;

        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE2: Inspecting exported output media...",
        );
        final lane2MediaInfo = await VanguardMediaPreparer.inspectMedia(
          lane2OutputPath,
        );
        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE2: MediaInfo: $lane2MediaInfo",
        );

        final durationMeasured =
            lane2MediaInfo?.durationSeconds ?? result2.durationSeconds;
        final durationValid = (durationMeasured - 3.0).abs() <= 0.25;

        final sidecarExists = await lane2SidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await lane2SidecarFile.readAsString()
            : "";
        final sidecarValid = _isValidExportRoiSidecar(
          content: sidecarContent,
          expectedWidth: 720,
          expectedHeight: 1280,
          expectedDurationSeconds: 3.0,
          durationToleranceSeconds: 0.25,
        );

        final mediaValid =
            lane2MediaInfo != null &&
            lane2MediaInfo.hasVideo &&
            lane2MediaInfo.width == 720 &&
            lane2MediaInfo.height == 1280;

        lane2Pass =
            outExists &&
            outBytes > 0 &&
            pathMatch &&
            dimsMatch &&
            durationValid &&
            sidecarExists &&
            sidecarValid &&
            mediaValid;

        lane2Results = <String, dynamic>{
          "pass": lane2Pass,
          "outputPath": result2.path,
          "outputBytes": outBytes,
          "durationSeconds": durationMeasured,
          "width": result2.width,
          "height": result2.height,
          "fps": result2.fps,
          "exportRoiSidecarPath": result2.exportRoiSidecarPath,
          "expectedRoiSidecarPath": lane2ExpectedSidecarPath,
          "sidecarExists": sidecarExists,
          "sidecarValid": sidecarValid,
          "mediaInfo": lane2MediaInfo != null
              ? _mediaInfoToMap(lane2MediaInfo)
              : null,
          "error": lane2Pass
              ? null
              : "Validation failed (exists=$outExists, bytes=$outBytes, pathMatch=$pathMatch, dimsMatch=$dimsMatch, durationValid=$durationValid, sidecarExists=$sidecarExists, sidecarValid=$sidecarValid, mediaValid=$mediaValid)",
        };
        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE2: DONE (pass=$lane2Pass, duration=$durationMeasured, bytes=$outBytes)",
        );
      } catch (e, st) {
        print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE2: ERROR: $e\n$st");
        lane2Results = <String, dynamic>{
          "pass": false,
          "outputPath": lane2OutputPath,
          "outputBytes": 0,
          "durationSeconds": 0.0,
          "width": 0,
          "height": 0,
          "fps": 0,
          "exportRoiSidecarPath": null,
          "expectedRoiSidecarPath": lane2ExpectedSidecarPath,
          "sidecarExists": false,
          "sidecarValid": false,
          "error": "$e",
        };
        lane2Pass = false;
      }
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE2_PASS: $lane2Pass");

      // Lane 3: Still-only sequential timeline over EXIF 2, 4, 5, 7 images (0.5s each = 2.0s)
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE3: START");
      final lane3OutputPath = "${tempDir.path}/${runId}_lane3_out.mp4";
      final lane3ExpectedSidecarPath = sidecarPathForVideoPath(lane3OutputPath);
      lane3OutputFile = File(lane3OutputPath);
      lane3SidecarFile = File(lane3ExpectedSidecarPath);

      try {
        final clip3A = VGClipDescriptor(
          id: "unit_s_lane3_clip_1",
          mediaKind: VGMediaKind.image,
          sourcePath: tempExif2File.path,
          durationSeconds: 0.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 0.5,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final clip3B = VGClipDescriptor(
          id: "unit_s_lane3_clip_2",
          mediaKind: VGMediaKind.image,
          sourcePath: tempExif4File.path,
          durationSeconds: 0.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 0.5,
          startTimeSeconds: 0.5,
          speed: 1.0,
        );

        final clip3C = VGClipDescriptor(
          id: "unit_s_lane3_clip_3",
          mediaKind: VGMediaKind.image,
          sourcePath: tempExif5File.path,
          durationSeconds: 0.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 0.5,
          startTimeSeconds: 1.0,
          speed: 1.0,
        );

        final clip3D = VGClipDescriptor(
          id: "unit_s_lane3_clip_4",
          mediaKind: VGMediaKind.image,
          sourcePath: tempExif7File.path,
          durationSeconds: 0.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 0.5,
          startTimeSeconds: 1.5,
          speed: 1.0,
        );

        final draft3 = VGEditorDraft(
          id: "unit_s_draft_lane3",
          clips: [clip3A, clip3B, clip3C, clip3D],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final request3 = VGEditorExportRequest(
          outputPath: lane3OutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        final result3 = await VanguardTimelineExporter.exportDraft(
          draft: draft3,
          request: request3,
        );

        final outExists = await lane3OutputFile.exists();
        final outBytes = outExists ? await lane3OutputFile.length() : 0;
        final pathMatch = result3.path == lane3OutputPath;
        final dimsMatch =
            result3.width == 720 && result3.height == 1280 && result3.fps == 30;

        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE3: Inspecting exported output media...",
        );
        final lane3MediaInfo = await VanguardMediaPreparer.inspectMedia(
          lane3OutputPath,
        );
        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE3: MediaInfo: $lane3MediaInfo",
        );

        final durationMeasured =
            lane3MediaInfo?.durationSeconds ?? result3.durationSeconds;
        final durationValid = (durationMeasured - 2.0).abs() <= 0.15;

        final sidecarExists = await lane3SidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await lane3SidecarFile.readAsString()
            : "";
        final sidecarValid = _isValidExportRoiSidecar(
          content: sidecarContent,
          expectedWidth: 720,
          expectedHeight: 1280,
          expectedDurationSeconds: 2.0,
          durationToleranceSeconds: 0.15,
        );

        final mediaValid =
            lane3MediaInfo != null &&
            lane3MediaInfo.hasVideo &&
            lane3MediaInfo.width == 720 &&
            lane3MediaInfo.height == 1280;

        lane3Pass =
            outExists &&
            outBytes > 0 &&
            pathMatch &&
            dimsMatch &&
            durationValid &&
            sidecarExists &&
            sidecarValid &&
            mediaValid;

        lane3Results = <String, dynamic>{
          "pass": lane3Pass,
          "outputPath": result3.path,
          "outputBytes": outBytes,
          "durationSeconds": durationMeasured,
          "width": result3.width,
          "height": result3.height,
          "fps": result3.fps,
          "exportRoiSidecarPath": result3.exportRoiSidecarPath,
          "expectedRoiSidecarPath": lane3ExpectedSidecarPath,
          "sidecarExists": sidecarExists,
          "sidecarValid": sidecarValid,
          "mediaInfo": lane3MediaInfo != null
              ? _mediaInfoToMap(lane3MediaInfo)
              : null,
          "error": lane3Pass
              ? null
              : "Validation failed (exists=$outExists, bytes=$outBytes, pathMatch=$pathMatch, dimsMatch=$dimsMatch, durationValid=$durationValid, sidecarExists=$sidecarExists, sidecarValid=$sidecarValid, mediaValid=$mediaValid)",
        };
        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE3: DONE (pass=$lane3Pass, duration=$durationMeasured, bytes=$outBytes)",
        );
      } catch (e, st) {
        print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE3: ERROR: $e\n$st");
        lane3Results = <String, dynamic>{
          "pass": false,
          "outputPath": lane3OutputPath,
          "outputBytes": 0,
          "durationSeconds": 0.0,
          "width": 0,
          "height": 0,
          "fps": 0,
          "exportRoiSidecarPath": null,
          "expectedRoiSidecarPath": lane3ExpectedSidecarPath,
          "sidecarExists": false,
          "sidecarValid": false,
          "error": "$e",
        };
        lane3Pass = false;
      }
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE3_PASS: $lane3Pass");

      // Lane 4: Active cancellation of a long EXIF 6 still export (20.0s)
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE4: START");
      final lane4OutputPath = "${tempDir.path}/${runId}_lane4_out.mp4";
      final lane4ExpectedSidecar = sidecarPathForVideoPath(lane4OutputPath);
      lane4OutputFile = File(lane4OutputPath);
      lane4SidecarFile = File(lane4ExpectedSidecar);

      String? cancelErrorCode;
      var cancelLatencyMs = 0;
      var latencyValid = false;

      try {
        final longClip4 = VGClipDescriptor(
          id: "unit_s_lane4_clip",
          mediaKind: VGMediaKind.image,
          sourcePath: tempExif6File.path,
          durationSeconds: 20.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 20.0,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final draft4 = VGEditorDraft(
          id: "unit_s_draft_lane4",
          clips: [longClip4],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final request4 = VGEditorExportRequest(
          outputPath: lane4OutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE4: Starting 20s still-only export...",
        );
        final exportFuture = VanguardTimelineExporter.exportDraft(
          draft: draft4,
          request: request4,
        );

        await Future<void>.delayed(const Duration(milliseconds: 1000));
        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE4: Invoking cancelExport...",
        );
        final cancelStopwatch = Stopwatch()..start();
        await const MethodChannel(
          "vanguard_media_engine",
        ).invokeMethod<void>("cancelExport");

        try {
          final res = await exportFuture;
          print(
            "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE4: Warning: Export unexpectedly completed: ${res.path}",
          );
        } on PlatformException catch (pe) {
          cancelErrorCode = pe.code;
          print(
            "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE4: Caught PlatformException code: ${pe.code} (${pe.message})",
          );
        } catch (e) {
          print(
            "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE4: Caught unexpected exception: $e",
          );
        }

        cancelStopwatch.stop();
        cancelLatencyMs = cancelStopwatch.elapsedMilliseconds;
        latencyValid = cancelLatencyMs < 2000;

        final out4Exists = await lane4OutputFile.exists();
        final sidecar4Exists = await lane4SidecarFile.exists();
        final out4Bytes = out4Exists ? await lane4OutputFile.length() : 0;

        final cancellationPass =
            (cancelErrorCode == "EXPORT_CANCELLED") &&
            (!out4Exists || out4Bytes == 0) &&
            !sidecar4Exists;

        lane4Pass = cancellationPass && latencyValid;

        lane4Results = <String, dynamic>{
          "pass": lane4Pass,
          "cancelErrorCode": cancelErrorCode,
          "expectedErrorCode": "EXPORT_CANCELLED",
          "cancelLatencyMs": cancelLatencyMs,
          "latencyValid": latencyValid,
          "outputExists": out4Exists,
          "outputBytes": out4Bytes,
          "sidecarExists": sidecar4Exists,
          "error": lane4Pass
              ? null
              : "Cancellation mismatch (code=$cancelErrorCode, latencyMs=$cancelLatencyMs, outExists=$out4Exists, sidecarExists=$sidecar4Exists)",
        };
        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE4: DONE (pass=$lane4Pass, code=$cancelErrorCode, latencyMs=$cancelLatencyMs)",
        );
      } catch (e, st) {
        print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE4: ERROR: $e\n$st");
        lane4Results = <String, dynamic>{
          "pass": false,
          "cancelErrorCode": cancelErrorCode,
          "cancelLatencyMs": cancelLatencyMs,
          "latencyValid": false,
          "outputExists": false,
          "outputBytes": 0,
          "sidecarExists": false,
          "error": "$e",
        };
        lane4Pass = false;
      }
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE4_PASS: $lane4Pass");

      // Lane 5: Corrupt image source using invalid bytes
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE5: START");
      final lane5OutputPath = "${tempDir.path}/${runId}_lane5_out.mp4";
      final lane5ExpectedSidecar = sidecarPathForVideoPath(lane5OutputPath);
      lane5OutputFile = File(lane5OutputPath);
      lane5SidecarFile = File(lane5ExpectedSidecar);

      String? lane5ErrorCode;

      try {
        final clip5 = VGClipDescriptor(
          id: "unit_s_lane5_clip",
          mediaKind: VGMediaKind.image,
          sourcePath: tempCorruptFile.path,
          durationSeconds: 1.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final draft5 = VGEditorDraft(
          id: "unit_s_draft_lane5",
          clips: [clip5],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final request5 = VGEditorExportRequest(
          outputPath: lane5OutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        await VanguardTimelineExporter.exportDraft(
          draft: draft5,
          request: request5,
        );
      } on PlatformException catch (pe) {
        lane5ErrorCode = pe.code;
        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE5: Caught PlatformException code: ${pe.code} (${pe.message})",
        );
      } catch (e) {
        print(
          "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE5: Caught unexpected exception: $e",
        );
      }

      final out5Exists = await lane5OutputFile.exists();
      final sidecar5Exists = await lane5SidecarFile.exists();
      lane5Pass =
          (lane5ErrorCode == "FILE_UNREADABLE" ||
              lane5ErrorCode == "EXPORT_FAILED") &&
          !out5Exists &&
          !sidecar5Exists;

      lane5Results = <String, dynamic>{
        "pass": lane5Pass,
        "errorCode": lane5ErrorCode,
        "expectedErrorCodes": const ["FILE_UNREADABLE", "EXPORT_FAILED"],
        "outputResidue": out5Exists,
        "sidecarResidue": sidecar5Exists,
        "error": lane5Pass
            ? null
            : "Corrupt source guard mismatch (code=$lane5ErrorCode, outExists=$out5Exists, sidecarExists=$sidecar5Exists)",
      };
      print(
        "ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE5: DONE (pass=$lane5Pass, code=$lane5ErrorCode)",
      );
      print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_LANE5_PASS: $lane5Pass");
    } catch (topLevelE, topLevelSt) {
      print(
        "ANDROID_STILL_IMAGE_EXIF_UNIT_S: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt",
      );
      topLevelError = "$topLevelE";
    } finally {
      // Clean up all temporary files created by this run
      final filesToClean = <String, File?>{
        "tempStillSourceFile": tempStillSourceFile,
        "tempClipBSourceFile": tempClipBSourceFile,
        "tempBaseJpegFile": tempBaseJpegFile,
        "tempExif6File": tempExif6File,
        "tempExif3File": tempExif3File,
        "tempExif8File": tempExif8File,
        "tempExif2File": tempExif2File,
        "tempExif4File": tempExif4File,
        "tempExif5File": tempExif5File,
        "tempExif7File": tempExif7File,
        "tempCorruptFile": tempCorruptFile,
        "lane1OutputFile": lane1OutputFile,
        "lane1SidecarFile": lane1SidecarFile,
        "lane1TempVideo": lane1OutputFile != null
            ? File("${lane1OutputFile.path}.vgtmp")
            : null,
        "lane1TempRoi": lane1SidecarFile != null
            ? File("${lane1SidecarFile.path}.vgroitmp")
            : null,
        "lane2OutputFile": lane2OutputFile,
        "lane2SidecarFile": lane2SidecarFile,
        "lane2TempVideo": lane2OutputFile != null
            ? File("${lane2OutputFile.path}.vgtmp")
            : null,
        "lane2TempRoi": lane2SidecarFile != null
            ? File("${lane2SidecarFile.path}.vgroitmp")
            : null,
        "lane3OutputFile": lane3OutputFile,
        "lane3SidecarFile": lane3SidecarFile,
        "lane3TempVideo": lane3OutputFile != null
            ? File("${lane3OutputFile.path}.vgtmp")
            : null,
        "lane3TempRoi": lane3SidecarFile != null
            ? File("${lane3SidecarFile.path}.vgroitmp")
            : null,
        "lane4OutputFile": lane4OutputFile,
        "lane4SidecarFile": lane4SidecarFile,
        "lane4TempVideo": lane4OutputFile != null
            ? File("${lane4OutputFile.path}.vgtmp")
            : null,
        "lane4TempRoi": lane4SidecarFile != null
            ? File("${lane4SidecarFile.path}.vgroitmp")
            : null,
        "lane5OutputFile": lane5OutputFile,
        "lane5SidecarFile": lane5SidecarFile,
        "lane5TempVideo": lane5OutputFile != null
            ? File("${lane5OutputFile.path}.vgtmp")
            : null,
        "lane5TempRoi": lane5SidecarFile != null
            ? File("${lane5SidecarFile.path}.vgroitmp")
            : null,
      };

      for (final entry in filesToClean.entries) {
        final f = entry.value;
        if (f != null) {
          try {
            if (await f.exists()) {
              final len = await f.length();
              await f.delete();
              cleanupObservations[entry.key] = {
                "path": f.path,
                "existed": true,
                "bytesBeforeDelete": len,
                "deleted": true,
              };
            } else {
              cleanupObservations[entry.key] = {
                "path": f.path,
                "existed": false,
                "deleted": false,
              };
            }
          } catch (cleanE) {
            cleanupObservations[entry.key] = {
              "path": f.path,
              "existed": true,
              "deleted": false,
              "cleanError": "$cleanE",
            };
          }
        }
      }
    }

    final allPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        lane5Pass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      "unit": "AndroidStillImageExifUnitS",
      "target": "android_physical",
      "pass": allPass,
      "lanes": <String, dynamic>{
        "lane1_still_only_exif6":
            lane1Results ?? {"pass": false, "error": "not run"},
        "lane2_mixed_timeline_exif3_video_exif8":
            lane2Results ?? {"pass": false, "error": "not run"},
        "lane3_sequential_still_exif2_4_5_7":
            lane3Results ?? {"pass": false, "error": "not run"},
        "lane4_cancellation_exif6":
            lane4Results ?? {"pass": false, "error": "not run"},
        "lane5_corrupt_image_source":
            lane5Results ?? {"pass": false, "error": "not run"},
      },
      "nonClaims": <String, String>{
        "noPixelPerfectVisualAssertion":
            "Visual pixel comparison is out of scope for export smoke harness",
        "noCropFill":
            "Canvas contentMode crop/fill is not supported in minimal exporter",
        "noExifSupportForVideo":
            "EXIF orientation applies to still image clips only",
        "noRemoteOrAssetUriDirectSources":
            "Direct remote/asset URI image sources not supported; local files only",
        "noCompositorTransitionsOrTransforms":
            "Transitions, overlays, and spatial transforms are out of scope",
        "noReverseSidecarEncoder": "Reverse sidecar encoding is not supported",
      },
      "cleanup": cleanupObservations,
      "error": topLevelError,
    };

    print("ANDROID_STILL_IMAGE_EXIF_UNIT_S_JSON:${jsonEncode(payload)}");
    print(
      allPass
          ? "ANDROID_STILL_IMAGE_EXIF_UNIT_S_PHYSICAL_PASS"
          : "ANDROID_STILL_IMAGE_EXIF_UNIT_S_PHYSICAL_FAIL",
    );

    if (mounted) {
      setState(() {
        _status = allPass ? "PASS" : "FAIL";
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(seconds: 2));
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
