// android_still_image_roi_unit_u_physical_smoke.dart
// Vanguard Media Engine — Android Still-Image ROI Ingestion & Slideshow Export Mapping Parity (Phase 5-Unit U)
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

  // APP1 EXIF segment (34 bytes total payload + length)
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
  runApp(const AndroidStillImageRoiUnitUPhysicalSmokeApp());
}

class AndroidStillImageRoiUnitUPhysicalSmokeApp extends StatefulWidget {
  const AndroidStillImageRoiUnitUPhysicalSmokeApp({super.key});

  @override
  State<AndroidStillImageRoiUnitUPhysicalSmokeApp> createState() =>
      _AndroidStillImageRoiUnitUPhysicalSmokeAppState();
}

class _AndroidStillImageRoiUnitUPhysicalSmokeAppState
    extends State<AndroidStillImageRoiUnitUPhysicalSmokeApp> {
  String _status =
      "Initializing Android Still-Image ROI Unit U Physical Smoke...";
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 120), () {
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U: TIMEOUT (120s exceeded)");
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U_PHYSICAL_FAIL");
      exit(1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSmoke());
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  VGROISidecar _makeSourceSidecar({
    required int displayWidth,
    required int displayHeight,
    required int durationMs,
    required List<VGROISample> samples,
    String coordinateSpace = "display_source_normalized",
  }) => VGROISidecar(
    version: 1,
    sourceType: "app_recorded",
    platform: "android",
    coordinateSpace: coordinateSpace,
    recordingSessionId: "source-session-unit-u",
    videoIdentity: VGROIIdentity(
      durationMs: durationMs,
      width: displayWidth,
      height: displayHeight,
    ),
    coverage: VGROICoverage(coveragePercent: 1.0, missingIntervals: const []),
    samples: samples,
    finalized: true,
  );

  VGROISample _makeSample({
    required int timestampMs,
    required VGROIBox box,
    int framePtsMs = 0,
    int recordingRelativeMs = 0,
  }) => VGROISample(
    timestampMs: timestampMs,
    framePtsMs: framePtsMs == 0 ? timestampMs : framePtsMs,
    recordingRelativeMs: recordingRelativeMs == 0
        ? timestampMs
        : recordingRelativeMs,
    box: box,
    quality: "detected",
    confidence: 0.95,
  );

  Future<void> _runSmoke() async {
    print("ANDROID_STILL_IMAGE_ROI_UNIT_U_START");
    print(
      "DEVICE: ${Platform.operatingSystem} ${Platform.operatingSystemVersion} locale=${Platform.localeName}",
    );

    const channel = MethodChannel("vanguard_media_engine");
    final runId = "unit_u_${DateTime.now().millisecondsSinceEpoch}";
    final tempDir = Directory.systemTemp;

    final ownedFiles = <File>[];
    final ownedDirs = <Directory>[];

    Map<String, dynamic>? lane0Results;
    Map<String, dynamic>? lane1Results;
    Map<String, dynamic>? lane2Results;
    Map<String, dynamic>? lane3Results;
    Map<String, dynamic>? lane4Results;
    final cleanupObservations = <String, dynamic>{};

    var lane0Pass = false;
    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    String? topLevelError;

    try {
      // ── Step 0: Prepare asset fixtures & EXIF rotated JPEG ───────────────────
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U: Loading asset fixtures...");
      final stillByteData = await rootBundle.load(
        "assets/manual_test_clips/still_C.png",
      );
      final rawStillBytes = stillByteData.buffer.asUint8List(
        stillByteData.offsetInBytes,
        stillByteData.lengthInBytes,
      );
      final tempStillPngFile = File(
        "${tempDir.path}/${runId}_source_still_C.png",
      );
      ownedFiles.add(tempStillPngFile);
      await tempStillPngFile.writeAsBytes(
        Uint8List.fromList(rawStillBytes),
        flush: true,
      );

      final clipBByteData = await rootBundle.load(
        "assets/manual_test_clips/clip_B.mov",
      );
      final rawClipBBytes = clipBByteData.buffer.asUint8List(
        clipBByteData.offsetInBytes,
        clipBByteData.lengthInBytes,
      );
      final tempClipBMovFile = File(
        "${tempDir.path}/${runId}_source_clip_B.mov",
      );
      ownedFiles.add(tempClipBMovFile);
      await tempClipBMovFile.writeAsBytes(
        Uint8List.fromList(rawClipBBytes),
        flush: true,
      );

      // Baseline JPEG conversion
      final tempBaseJpegFile = File("${tempDir.path}/${runId}_base_still.jpg");
      ownedFiles.add(tempBaseJpegFile);
      final optResult = await VanguardImageOptimizer.optimizeImage(
        request: VGImageOptimizationRequest(
          sourcePath: tempStillPngFile.path,
          outputPath: tempBaseJpegFile.path,
          format: "jpeg",
          quality: 0.90,
        ),
      );
      print(
        "ANDROID_STILL_IMAGE_ROI_UNIT_U: Base JPEG created: ${optResult.outputPath} (${optResult.width}x${optResult.height})",
      );

      final baseJpegBytes = await tempBaseJpegFile.readAsBytes();
      final tempExif6JpegFile = File("${tempDir.path}/${runId}_exif_6.jpg");
      ownedFiles.add(tempExif6JpegFile);
      await tempExif6JpegFile.writeAsBytes(
        createExifOrientedJpegBytes(baseJpegBytes, 6),
        flush: true,
      );

      // ── LANE 0: Native inspectMedia Proof for Stills & EXIF ──────────────────
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE0: START");
      final baseInspectRaw = await channel.invokeMethod<Map<dynamic, dynamic>>(
        "inspectMedia",
        {"path": tempBaseJpegFile.path},
      );
      if (baseInspectRaw == null) {
        throw StateError("inspectMedia returned null for base JPEG");
      }
      final baseInspect = Map<String, dynamic>.from(baseInspectRaw);
      print(
        "ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE0: Base still inspect: $baseInspect",
      );

      final exifInspectRaw = await channel.invokeMethod<Map<dynamic, dynamic>>(
        "inspectMedia",
        {"path": tempExif6JpegFile.path},
      );
      if (exifInspectRaw == null) {
        throw StateError("inspectMedia returned null for EXIF rotate90 JPEG");
      }
      final exifInspect = Map<String, dynamic>.from(exifInspectRaw);
      print(
        "ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE0: EXIF rotate90 inspect: $exifInspect",
      );

      final baseWidth = baseInspect["width"] as int;
      final baseHeight = baseInspect["height"] as int;
      final baseDisplayWidth = baseInspect["displayWidth"] as int;
      final baseDisplayHeight = baseInspect["displayHeight"] as int;
      final baseKind = baseInspect["kind"] as String;
      final baseHasVideo = baseInspect["hasVideo"] as bool;
      final baseHasAudio = baseInspect["hasAudio"] as bool;
      final baseDuration = (baseInspect["durationSeconds"] as num).toDouble();

      final exifWidth = exifInspect["width"] as int;
      final exifHeight = exifInspect["height"] as int;
      final exifDisplayWidth = exifInspect["displayWidth"] as int;
      final exifDisplayHeight = exifInspect["displayHeight"] as int;
      final exifRotation = exifInspect["rotationDegrees"] as int?;
      final exifStatus = exifInspect["orientationStatus"] as String;
      final exifHasTransform = exifInspect["hasRotationTransform"] as bool;

      if (baseKind == "image" &&
          baseWidth > 0 &&
          baseHeight > 0 &&
          baseDisplayWidth == baseWidth &&
          baseDisplayHeight == baseHeight &&
          !baseHasVideo &&
          !baseHasAudio &&
          baseDuration == 0.0 &&
          exifWidth == baseWidth &&
          exifHeight == baseHeight &&
          exifDisplayWidth == baseHeight &&
          exifDisplayHeight == baseWidth &&
          exifRotation == 90 &&
          exifStatus == "valid" &&
          exifHasTransform) {
        lane0Pass = true;
        lane0Results = {"pass": true, "base": baseInspect, "exif": exifInspect};
        print("LANE0_PASS");
      } else {
        throw StateError("Lane 0 inspection contract assertion failed");
      }

      // ── LANE 1: Single Still ROI Export Mapping ──────────────────────────────
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE1: START");
      final lane1Dir = Directory("${tempDir.path}/${runId}_l1_dir")
        ..createSync(recursive: true);
      ownedDirs.add(lane1Dir);
      final lane1ExplicitSidecarFile = File(
        "${lane1Dir.path}/l1_still.roi.json",
      );
      ownedFiles.add(lane1ExplicitSidecarFile);

      final l1SourceBox = VGROIBox(x: 0.2, y: 0.3, w: 0.4, h: 0.4);
      final l1Sidecar = _makeSourceSidecar(
        displayWidth: baseDisplayWidth,
        displayHeight: baseDisplayHeight,
        durationMs: 3000,
        samples: [_makeSample(timestampMs: 500, box: l1SourceBox)],
      );
      await lane1ExplicitSidecarFile.writeAsString(
        jsonEncode(l1Sidecar.toJson()),
        flush: true,
      );

      final lane1OutputFile = File("${tempDir.path}/${runId}_l1_out.mp4");
      final lane1OutputSidecarFile = File(
        sidecarPathForVideoPath(lane1OutputFile.path),
      );
      ownedFiles.add(lane1OutputFile);
      ownedFiles.add(lane1OutputSidecarFile);

      const canvasWidth1 = 720;
      const canvasHeight1 = 1280;

      final draft1 = VGEditorDraft(
        id: "unit_u_l1_draft",
        clips: [
          VGClipDescriptor(
            id: "u_l1_c1",
            sourcePath: tempBaseJpegFile.path,
            sourceRoiSidecarPath: lane1ExplicitSidecarFile.path,
            mediaKind: VGMediaKind.image,
            durationSeconds: 3.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 3.0,
          ),
        ],
        canvasWidth: canvasWidth1,
        canvasHeight: canvasHeight1,
        fps: 30,
      );

      final result1 = await VanguardTimelineExporter.exportDraft(
        draft: draft1,
        request: VGEditorExportRequest(outputPath: lane1OutputFile.path),
        channel: channel,
      );

      if (!await lane1OutputFile.exists() ||
          await lane1OutputFile.length() <= 0) {
        throw StateError("Lane 1 export output MP4 missing or empty");
      }
      if (!await lane1OutputSidecarFile.exists()) {
        throw StateError("Lane 1 export output sidecar missing");
      }

      final l1ExportSidecarDecoded = jsonDecode(
        await lane1OutputSidecarFile.readAsString(),
      );
      final l1ExportSidecar = VGROISidecar.fromJson(l1ExportSidecarDecoded);

      // Compute expected aspect-fit box
      final scale1 =
          ((canvasWidth1 / baseDisplayWidth) <
              (canvasHeight1 / baseDisplayHeight))
          ? (canvasWidth1 / baseDisplayWidth)
          : (canvasHeight1 / baseDisplayHeight);
      final fw1 = baseDisplayWidth * scale1;
      final fh1 = baseDisplayHeight * scale1;
      final ox1 = (canvasWidth1 - fw1) / 2.0;
      final oy1 = (canvasHeight1 - fh1) / 2.0;
      final expX1 = (ox1 + l1SourceBox.x * fw1) / canvasWidth1;
      final expY1 = (oy1 + l1SourceBox.y * fh1) / canvasHeight1;
      final expW1 = (l1SourceBox.w * fw1) / canvasWidth1;
      final expH1 = (l1SourceBox.h * fh1) / canvasHeight1;

      final actualBox1 = l1ExportSidecar.samples.first.box!;
      final l1BoxMatch =
          (actualBox1.x - expX1).abs() < 1e-3 &&
          (actualBox1.y - expY1).abs() < 1e-3 &&
          (actualBox1.w - expW1).abs() < 1e-3 &&
          (actualBox1.h - expH1).abs() < 1e-3;

      print(
        "ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE1: samples=${l1ExportSidecar.samples.length}, "
        "actualBox=[${actualBox1.x.toStringAsFixed(4)}, ${actualBox1.y.toStringAsFixed(4)}, ${actualBox1.w.toStringAsFixed(4)}, ${actualBox1.h.toStringAsFixed(4)}], "
        "expectedBox=[${expX1.toStringAsFixed(4)}, ${expY1.toStringAsFixed(4)}, ${expW1.toStringAsFixed(4)}, ${expH1.toStringAsFixed(4)}]",
      );

      if (l1ExportSidecar.coordinateSpace == "export_output_normalized" &&
          l1ExportSidecar.videoIdentity.width == canvasWidth1 &&
          l1ExportSidecar.videoIdentity.height == canvasHeight1 &&
          l1ExportSidecar.samples.length == 1 &&
          l1BoxMatch) {
        lane1Pass = true;
        lane1Results = {
          "pass": true,
          "result": result1.toMap(),
          "actualBox": actualBox1.toJson(),
          "expectedBox": {"x": expX1, "y": expY1, "w": expW1, "h": expH1},
        };
        print("LANE1_PASS");
      } else {
        throw StateError("Lane 1 single still export mapping assertion failed");
      }

      // ── LANE 2: EXIF Display Bounds ROI Export Mapping ───────────────────────
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE2: START");
      final lane2Dir = Directory("${tempDir.path}/${runId}_l2_dir")
        ..createSync(recursive: true);
      ownedDirs.add(lane2Dir);
      final lane2ExplicitSidecarFile = File(
        "${lane2Dir.path}/l2_exif.roi.json",
      );
      ownedFiles.add(lane2ExplicitSidecarFile);

      final l2SourceBox = VGROIBox(x: 0.15, y: 0.25, w: 0.35, h: 0.45);
      final l2Sidecar = _makeSourceSidecar(
        displayWidth: exifDisplayWidth,
        displayHeight: exifDisplayHeight,
        durationMs: 3000,
        samples: [_makeSample(timestampMs: 500, box: l2SourceBox)],
      );
      await lane2ExplicitSidecarFile.writeAsString(
        jsonEncode(l2Sidecar.toJson()),
        flush: true,
      );

      final lane2OutputFile = File("${tempDir.path}/${runId}_l2_out.mp4");
      final lane2OutputSidecarFile = File(
        sidecarPathForVideoPath(lane2OutputFile.path),
      );
      ownedFiles.add(lane2OutputFile);
      ownedFiles.add(lane2OutputSidecarFile);

      final draft2 = VGEditorDraft(
        id: "unit_u_l2_draft",
        clips: [
          VGClipDescriptor(
            id: "u_l2_c1",
            sourcePath: tempExif6JpegFile.path,
            sourceRoiSidecarPath: lane2ExplicitSidecarFile.path,
            mediaKind: VGMediaKind.image,
            durationSeconds: 3.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 3.0,
          ),
        ],
        canvasWidth: canvasWidth1,
        canvasHeight: canvasHeight1,
        fps: 30,
      );

      final result2 = await VanguardTimelineExporter.exportDraft(
        draft: draft2,
        request: VGEditorExportRequest(outputPath: lane2OutputFile.path),
        channel: channel,
      );

      if (!await lane2OutputFile.exists() ||
          await lane2OutputFile.length() <= 0) {
        throw StateError("Lane 2 export output MP4 missing or empty");
      }
      if (!await lane2OutputSidecarFile.exists()) {
        throw StateError("Lane 2 export output sidecar missing");
      }

      final l2ExportSidecarDecoded = jsonDecode(
        await lane2OutputSidecarFile.readAsString(),
      );
      final l2ExportSidecar = VGROISidecar.fromJson(l2ExportSidecarDecoded);

      // Compute expected aspect-fit box using swapped display dimensions (exifDisplayWidth x exifDisplayHeight)
      final scale2 =
          ((canvasWidth1 / exifDisplayWidth) <
              (canvasHeight1 / exifDisplayHeight))
          ? (canvasWidth1 / exifDisplayWidth)
          : (canvasHeight1 / exifDisplayHeight);
      final fw2 = exifDisplayWidth * scale2;
      final fh2 = exifDisplayHeight * scale2;
      final ox2 = (canvasWidth1 - fw2) / 2.0;
      final oy2 = (canvasHeight1 - fh2) / 2.0;
      final expX2 = (ox2 + l2SourceBox.x * fw2) / canvasWidth1;
      final expY2 = (oy2 + l2SourceBox.y * fh2) / canvasHeight1;
      final expW2 = (l2SourceBox.w * fw2) / canvasWidth1;
      final expH2 = (l2SourceBox.h * fh2) / canvasHeight1;

      final actualBox2 = l2ExportSidecar.samples.first.box!;
      final l2BoxMatch =
          (actualBox2.x - expX2).abs() < 1e-3 &&
          (actualBox2.y - expY2).abs() < 1e-3 &&
          (actualBox2.w - expW2).abs() < 1e-3 &&
          (actualBox2.h - expH2).abs() < 1e-3;

      print(
        "ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE2: samples=${l2ExportSidecar.samples.length}, "
        "actualBox=[${actualBox2.x.toStringAsFixed(4)}, ${actualBox2.y.toStringAsFixed(4)}, ${actualBox2.w.toStringAsFixed(4)}, ${actualBox2.h.toStringAsFixed(4)}], "
        "expectedBox=[${expX2.toStringAsFixed(4)}, ${expY2.toStringAsFixed(4)}, ${expW2.toStringAsFixed(4)}, ${expH2.toStringAsFixed(4)}]",
      );

      if (l2ExportSidecar.coordinateSpace == "export_output_normalized" &&
          l2ExportSidecar.videoIdentity.width == canvasWidth1 &&
          l2ExportSidecar.videoIdentity.height == canvasHeight1 &&
          l2ExportSidecar.samples.length == 1 &&
          l2BoxMatch) {
        lane2Pass = true;
        lane2Results = {
          "pass": true,
          "result": result2.toMap(),
          "actualBox": actualBox2.toJson(),
          "expectedBox": {"x": expX2, "y": expY2, "w": expW2, "h": expH2},
        };
        print("LANE2_PASS");
      } else {
        throw StateError(
          "Lane 2 EXIF display bounds export mapping assertion failed",
        );
      }

      // ── LANE 3: Multi-clip Timeline Aggregation (still + still + video) ─────
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE3: START");
      final lane3Dir = Directory("${tempDir.path}/${runId}_l3_dir")
        ..createSync(recursive: true);
      ownedDirs.add(lane3Dir);

      final l3C1SidecarFile = File("${lane3Dir.path}/l3_c1.roi.json");
      final l3C2SidecarFile = File("${lane3Dir.path}/l3_c2.roi.json");
      final l3C3SidecarFile = File("${lane3Dir.path}/l3_c3.roi.json");
      ownedFiles.addAll([l3C1SidecarFile, l3C2SidecarFile, l3C3SidecarFile]);

      final l3Box1 = VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2);
      final l3Box2 = VGROIBox(x: 0.2, y: 0.2, w: 0.3, h: 0.3);
      final l3Box3 = VGROIBox(x: 0.3, y: 0.3, w: 0.2, h: 0.2);

      await l3C1SidecarFile.writeAsString(
        jsonEncode(
          _makeSourceSidecar(
            displayWidth: baseDisplayWidth,
            displayHeight: baseDisplayHeight,
            durationMs: 3000,
            samples: [_makeSample(timestampMs: 500, box: l3Box1)],
          ).toJson(),
        ),
        flush: true,
      );

      await l3C2SidecarFile.writeAsString(
        jsonEncode(
          _makeSourceSidecar(
            displayWidth: exifDisplayWidth,
            displayHeight: exifDisplayHeight,
            durationMs: 2500,
            samples: [_makeSample(timestampMs: 600, box: l3Box2)],
          ).toJson(),
        ),
        flush: true,
      );

      final clipBInspect = await VanguardMediaPreparer.inspectMedia(
        tempClipBMovFile.path,
      );
      final clipBWidth = clipBInspect?.displayWidth ?? 1080;
      final clipBHeight = clipBInspect?.displayHeight ?? 1920;

      await l3C3SidecarFile.writeAsString(
        jsonEncode(
          _makeSourceSidecar(
            displayWidth: clipBWidth,
            displayHeight: clipBHeight,
            durationMs: 2000,
            samples: [_makeSample(timestampMs: 700, box: l3Box3)],
          ).toJson(),
        ),
        flush: true,
      );

      final lane3OutputFile = File("${tempDir.path}/${runId}_l3_out.mp4");
      final lane3OutputSidecarFile = File(
        sidecarPathForVideoPath(lane3OutputFile.path),
      );
      ownedFiles.add(lane3OutputFile);
      ownedFiles.add(lane3OutputSidecarFile);

      final draft3 = VGEditorDraft(
        id: "unit_u_l3_draft",
        clips: [
          VGClipDescriptor(
            id: "u_l3_c1",
            sourcePath: tempBaseJpegFile.path,
            sourceRoiSidecarPath: l3C1SidecarFile.path,
            mediaKind: VGMediaKind.image,
            durationSeconds: 3.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 3.0,
          ),
          VGClipDescriptor(
            id: "u_l3_c2",
            sourcePath: tempExif6JpegFile.path,
            sourceRoiSidecarPath: l3C2SidecarFile.path,
            mediaKind: VGMediaKind.image,
            durationSeconds: 2.5,
            trimStartSeconds: 0.0,
            trimEndSeconds: 2.5,
          ),
          VGClipDescriptor(
            id: "u_l3_c3",
            sourcePath: tempClipBMovFile.path,
            sourceRoiSidecarPath: l3C3SidecarFile.path,
            mediaKind: VGMediaKind.video,
            durationSeconds: 2.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 2.0,
          ),
        ],
        canvasWidth: canvasWidth1,
        canvasHeight: canvasHeight1,
        fps: 30,
      );

      final result3 = await VanguardTimelineExporter.exportDraft(
        draft: draft3,
        request: VGEditorExportRequest(outputPath: lane3OutputFile.path),
        channel: channel,
      );

      if (!await lane3OutputFile.exists() ||
          await lane3OutputFile.length() <= 0) {
        throw StateError("Lane 3 export output MP4 missing or empty");
      }
      if (!await lane3OutputSidecarFile.exists()) {
        throw StateError("Lane 3 export output sidecar missing");
      }

      final l3ExportSidecarDecoded = jsonDecode(
        await lane3OutputSidecarFile.readAsString(),
      );
      final l3ExportSidecar = VGROISidecar.fromJson(l3ExportSidecarDecoded);

      final s0Ms = l3ExportSidecar.samples[0].timestampMs;
      final s1Ms = l3ExportSidecar.samples[1].timestampMs;
      final s2Ms = l3ExportSidecar.samples[2].timestampMs;

      print(
        "ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE3: samples=${l3ExportSidecar.samples.length}, "
        "timestamps=[$s0Ms, $s1Ms, $s2Ms], durationMs=${l3ExportSidecar.videoIdentity.durationMs}",
      );

      // Expected timestamps:
      // Clip 1: 500ms
      // Clip 2: 600ms + 3000ms = 3600ms
      // Clip 3: 700ms + 3000ms + 2500ms = 6200ms
      if (l3ExportSidecar.coordinateSpace == "export_output_normalized" &&
          l3ExportSidecar.samples.length == 3 &&
          s0Ms == 500 &&
          s1Ms == 3600 &&
          s2Ms == 6200 &&
          (s0Ms < s1Ms && s1Ms < s2Ms)) {
        lane3Pass = true;
        lane3Results = {
          "pass": true,
          "result": result3.toMap(),
          "sampleTimestamps": [s0Ms, s1Ms, s2Ms],
        };
        print("LANE3_PASS");
      } else {
        throw StateError(
          "Lane 3 multi-clip timeline aggregation assertion failed",
        );
      }

      // ── LANE 4: Fail-closed Handling for Broken Sidecar ──────────────────────
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE4: START");
      final lane4Dir = Directory("${tempDir.path}/${runId}_l4_dir")
        ..createSync(recursive: true);
      ownedDirs.add(lane4Dir);
      final lane4BrokenSidecarFile = File(
        "${lane4Dir.path}/l4_broken.roi.json",
      );
      ownedFiles.add(lane4BrokenSidecarFile);
      await lane4BrokenSidecarFile.writeAsString(
        "{not valid json!",
        flush: true,
      );

      final lane4OutputFile = File("${tempDir.path}/${runId}_l4_out.mp4");
      final lane4OutputSidecarFile = File(
        sidecarPathForVideoPath(lane4OutputFile.path),
      );
      ownedFiles.add(lane4OutputFile);
      ownedFiles.add(lane4OutputSidecarFile);

      final draft4 = VGEditorDraft(
        id: "unit_u_l4_draft",
        clips: [
          VGClipDescriptor(
            id: "u_l4_c1",
            sourcePath: tempBaseJpegFile.path,
            sourceRoiSidecarPath: lane4BrokenSidecarFile.path,
            mediaKind: VGMediaKind.image,
            durationSeconds: 3.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 3.0,
          ),
        ],
        canvasWidth: canvasWidth1,
        canvasHeight: canvasHeight1,
        fps: 30,
      );

      final result4 = await VanguardTimelineExporter.exportDraft(
        draft: draft4,
        request: VGEditorExportRequest(outputPath: lane4OutputFile.path),
        channel: channel,
      );

      if (!await lane4OutputFile.exists() ||
          await lane4OutputFile.length() <= 0) {
        throw StateError("Lane 4 export output MP4 missing or empty");
      }
      if (!await lane4OutputSidecarFile.exists()) {
        throw StateError("Lane 4 fallback output sidecar missing");
      }

      final l4FallbackDecoded = jsonDecode(
        await lane4OutputSidecarFile.readAsString(),
      );
      final l4FallbackSidecar = VGROISidecar.fromJson(l4FallbackDecoded);

      print(
        "ANDROID_STILL_IMAGE_ROI_UNIT_U_LANE4: fallback samples=${l4FallbackSidecar.samples.length}, "
        "finalized=${l4FallbackSidecar.finalized}, coordinateSpace=${l4FallbackSidecar.coordinateSpace}",
      );

      if (l4FallbackSidecar.samples.isEmpty &&
          l4FallbackSidecar.coordinateSpace == "export_output_normalized" &&
          l4FallbackSidecar.finalized == true) {
        lane4Pass = true;
        lane4Results = {
          "pass": true,
          "result": result4.toMap(),
          "fallbackSamples": l4FallbackSidecar.samples.length,
        };
        print("LANE4_PASS");
      } else {
        throw StateError("Lane 4 fail-closed fallback assertion failed");
      }
    } catch (e, st) {
      topLevelError = "$e\n$st";
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U: ERROR: $topLevelError");
    } finally {
      // Clean all owned temp files and directories
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U: Cleaning owned temp files...");
      var cleanedCount = 0;
      var failedCleanCount = 0;

      // Scan temp dir for any residue files matching unit_u
      try {
        final entries = tempDir.listSync(recursive: false);
        for (final entry in entries) {
          if (entry.path.contains("unit_u")) {
            try {
              if (entry is File) {
                entry.deleteSync();
                cleanedCount++;
              } else if (entry is Directory) {
                entry.deleteSync(recursive: true);
                cleanedCount++;
              }
            } catch (_) {
              failedCleanCount++;
            }
          }
        }
      } catch (_) {}

      for (final file in ownedFiles) {
        try {
          if (await file.exists()) {
            await file.delete();
            cleanedCount++;
          }
        } catch (_) {
          failedCleanCount++;
        }
      }

      for (final dir in ownedDirs) {
        try {
          if (await dir.exists()) {
            await dir.delete(recursive: true);
            cleanedCount++;
          }
        } catch (_) {
          failedCleanCount++;
        }
      }

      cleanupObservations["filesCleaned"] = cleanedCount;
      cleanupObservations["failedCleanCount"] = failedCleanCount;
      print(
        "ANDROID_STILL_IMAGE_ROI_UNIT_U: Cleaned $cleanedCount files/dirs ($failedCleanCount errors)",
      );
    }

    final allPass =
        lane0Pass &&
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      "unit": "AndroidStillImageRoiUnitU",
      "target": "android_physical",
      "pass": allPass,
      "lanes": <String, dynamic>{
        "lane0_native_inspect":
            lane0Results ?? {"pass": false, "error": "not run"},
        "lane1_single_still_roi_export":
            lane1Results ?? {"pass": false, "error": "not run"},
        "lane2_exif_display_bounds_roi_export":
            lane2Results ?? {"pass": false, "error": "not run"},
        "lane3_multi_clip_timeline_aggregation":
            lane3Results ?? {"pass": false, "error": "not run"},
        "lane4_fail_closed_handling":
            lane4Results ?? {"pass": false, "error": "not run"},
      },
      "cleanup": cleanupObservations,
      "error": topLevelError,
    };

    print("ANDROID_STILL_IMAGE_ROI_UNIT_U_JSON:${jsonEncode(payload)}");
    if (allPass) {
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U_PHYSICAL_PASS");
    } else {
      print("ANDROID_STILL_IMAGE_ROI_UNIT_U_PHYSICAL_FAIL");
    }

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
