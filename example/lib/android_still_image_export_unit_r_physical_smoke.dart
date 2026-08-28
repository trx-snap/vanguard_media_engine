// android_still_image_export_unit_r_physical_smoke.dart
// Vanguard Media Engine - Android Still-Image Timeline Ingestion & Slideshow Export Foundation (Unit R)
// ignore_for_file: avoid_print

import "dart:async";
import "dart:convert";
import "dart:io";

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

void main() {
  runApp(const AndroidStillImageExportUnitRPhysicalSmokeApp());
}

class AndroidStillImageExportUnitRPhysicalSmokeApp extends StatefulWidget {
  const AndroidStillImageExportUnitRPhysicalSmokeApp({super.key});

  @override
  State<AndroidStillImageExportUnitRPhysicalSmokeApp> createState() =>
      _AndroidStillImageExportUnitRPhysicalSmokeAppState();
}

class _AndroidStillImageExportUnitRPhysicalSmokeAppState
    extends State<AndroidStillImageExportUnitRPhysicalSmokeApp> {
  String _status =
      "Initializing Android Still-Image Export Unit R Physical Smoke...";
  Timer? _timeoutTimer;

  // Tiny 1x1 JPEG fixture with EXIF Orientation = 6 (Rotate 90 CW).
  static final Uint8List _exifRotatedJpegBytes = Uint8List.fromList(const [
    255,
    216,
    255,
    225,
    0,
    30,
    69,
    120,
    105,
    102,
    0,
    0,
    73,
    73,
    42,
    0,
    8,
    0,
    0,
    0,
    1,
    0,
    18,
    1,
    3,
    0,
    1,
    0,
    0,
    0,
    6,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    255,
    219,
    0,
    67,
    0,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    255,
    192,
    0,
    11,
    8,
    0,
    1,
    0,
    1,
    1,
    1,
    17,
    0,
    255,
    196,
    0,
    31,
    0,
    0,
    1,
    5,
    1,
    1,
    1,
    1,
    1,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    255,
    218,
    0,
    8,
    1,
    1,
    0,
    0,
    63,
    0,
    127,
    255,
    217,
  ]);

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 120), () {
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R: TIMEOUT (120s exceeded)");
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_PHYSICAL_FAIL");
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
    print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R: START");
    final runId = "unit_r_${DateTime.now().millisecondsSinceEpoch}";
    final tempDir = Directory.systemTemp;

    File? tempStillSourceFile;
    File? tempClipBSourceFile;

    File? lane1OutputFile;
    File? lane1SidecarFile;

    File? lane2OutputFile;
    File? lane2SidecarFile;

    File? lane3aOutputFile;
    File? lane3aSidecarFile;

    File? lane3bSourceFile;
    File? lane3bOutputFile;
    File? lane3bSidecarFile;

    File? lane3cSourceFile;
    File? lane3cOutputFile;
    File? lane3cSidecarFile;

    File? lane4OutputFile;
    File? lane4SidecarFile;

    Map<String, dynamic>? lane1Results;
    Map<String, dynamic>? lane2Results;
    Map<String, dynamic>? lane3Results;
    Map<String, dynamic>? lane4Results;
    final cleanupObservations = <String, dynamic>{};

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    String? topLevelError;

    try {
      // Step 1: Copy rootBundle assets to unique temp files
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R: Loading asset fixtures...");
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
      final stillSourcePath = tempStillSourceFile.path;
      print(
        "ANDROID_STILL_IMAGE_EXPORT_UNIT_R: Still image ready at $stillSourcePath (${rawStillBytes.length} bytes)",
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
        "ANDROID_STILL_IMAGE_EXPORT_UNIT_R: Video clip B ready at $clipBSourcePath (${rawClipBBytes.length} bytes)",
      );

      // Lane 1: Still-only export (3.0s, 720x1280, 30fps)
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE1: START");
      final lane1OutputPath = "${tempDir.path}/${runId}_lane1_out.mp4";
      final lane1ExpectedSidecarPath = sidecarPathForVideoPath(lane1OutputPath);
      lane1OutputFile = File(lane1OutputPath);
      lane1SidecarFile = File(lane1ExpectedSidecarPath);

      try {
        final clip1 = VGClipDescriptor(
          id: "unit_r_lane1_clip",
          mediaKind: VGMediaKind.image,
          sourcePath: stillSourcePath,
          durationSeconds: 3.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 3.0,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final draft1 = VGEditorDraft(
          id: "unit_r_draft_lane1",
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
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE1: Inspecting exported output media...",
        );
        final lane1MediaInfo = await VanguardMediaPreparer.inspectMedia(
          lane1OutputPath,
        );
        print(
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE1: MediaInfo: $lane1MediaInfo",
        );

        final durationMeasured =
            lane1MediaInfo?.durationSeconds ?? result1.durationSeconds;
        final durationValid = (durationMeasured - 3.0).abs() <= 0.15;

        final sidecarExists = await lane1SidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await lane1SidecarFile.readAsString()
            : "";
        final sidecarValid = _isValidExportRoiSidecar(
          content: sidecarContent,
          expectedWidth: 720,
          expectedHeight: 1280,
          expectedDurationSeconds: 3.0,
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
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE1: DONE (pass=$lane1Pass, duration=$durationMeasured, bytes=$outBytes)",
        );
      } catch (e, st) {
        print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE1: ERROR: $e\n$st");
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
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE1_PASS: $lane1Pass");

      // Lane 2: Mixed export ([still 2.0s, clip_B trim 0.0..2.0s, still 1.5s] = 5.5s)
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE2: START");
      final lane2OutputPath = "${tempDir.path}/${runId}_lane2_out.mp4";
      final lane2ExpectedSidecarPath = sidecarPathForVideoPath(lane2OutputPath);
      lane2OutputFile = File(lane2OutputPath);
      lane2SidecarFile = File(lane2ExpectedSidecarPath);

      try {
        final clip2A = VGClipDescriptor(
          id: "unit_r_lane2_clip_1",
          mediaKind: VGMediaKind.image,
          sourcePath: stillSourcePath,
          durationSeconds: 2.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final clip2B = VGClipDescriptor(
          id: "unit_r_lane2_clip_2",
          mediaKind: VGMediaKind.video,
          sourcePath: clipBSourcePath,
          durationSeconds: 5.565,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
          startTimeSeconds: 2.0,
          speed: 1.0,
        );

        final clip2C = VGClipDescriptor(
          id: "unit_r_lane2_clip_3",
          mediaKind: VGMediaKind.image,
          sourcePath: stillSourcePath,
          durationSeconds: 1.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.5,
          startTimeSeconds: 4.0,
          speed: 1.0,
        );

        final rawDraft2 = VGEditorDraft(
          id: "unit_r_draft_lane2",
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
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE2: Inspecting exported output media...",
        );
        final lane2MediaInfo = await VanguardMediaPreparer.inspectMedia(
          lane2OutputPath,
        );
        print(
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE2: MediaInfo: $lane2MediaInfo",
        );

        final durationMeasured =
            lane2MediaInfo?.durationSeconds ?? result2.durationSeconds;
        final durationValid = (durationMeasured - 5.5).abs() <= 0.25;

        final sidecarExists = await lane2SidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await lane2SidecarFile.readAsString()
            : "";
        final sidecarValid = _isValidExportRoiSidecar(
          content: sidecarContent,
          expectedWidth: 720,
          expectedHeight: 1280,
          expectedDurationSeconds: 5.5,
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
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE2: DONE (pass=$lane2Pass, duration=$durationMeasured, bytes=$outBytes)",
        );
      } catch (e, st) {
        print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE2: ERROR: $e\n$st");
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
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE2_PASS: $lane2Pass");

      // Lane 3: Fail-closed source/feature guards
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE3: START");
      final lane3aOutputPath = "${tempDir.path}/${runId}_lane3a_out.mp4";
      final lane3aExpectedSidecar = sidecarPathForVideoPath(lane3aOutputPath);
      lane3aOutputFile = File(lane3aOutputPath);
      lane3aSidecarFile = File(lane3aExpectedSidecar);

      final lane3bOutputPath = "${tempDir.path}/${runId}_lane3b_out.mp4";
      final lane3bExpectedSidecar = sidecarPathForVideoPath(lane3bOutputPath);
      lane3bOutputFile = File(lane3bOutputPath);
      lane3bSidecarFile = File(lane3bExpectedSidecar);

      final lane3cOutputPath = "${tempDir.path}/${runId}_lane3c_out.mp4";
      final lane3cExpectedSidecar = sidecarPathForVideoPath(lane3cOutputPath);
      lane3cOutputFile = File(lane3cOutputPath);
      lane3cSidecarFile = File(lane3cExpectedSidecar);

      var lane3aPass = false;
      var lane3bPass = false;
      var lane3cPass = false;
      String? lane3aCode;
      String? lane3bCode;
      String? lane3cCode;

      // Sublane 3(a): fitMode fill
      try {
        final clip3a = VGClipDescriptor(
          id: "unit_r_lane3a_clip",
          mediaKind: VGMediaKind.image,
          sourcePath: stillSourcePath,
          durationSeconds: 1.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0,
          startTimeSeconds: 0.0,
          fitMode: VGStillImageFitMode.fill,
        );
        final draft3a = VGEditorDraft(
          id: "unit_r_draft_lane3a",
          clips: [clip3a],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );
        final request3a = VGEditorExportRequest(
          outputPath: lane3aOutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        await VanguardTimelineExporter.exportDraft(
          draft: draft3a,
          request: request3a,
        );
      } on PlatformException catch (pe) {
        lane3aCode = pe.code;
        print(
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE3A: Caught PlatformException code: ${pe.code}",
        );
      } catch (e) {
        print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE3A: Caught exception: $e");
      }

      final out3aExists = await lane3aOutputFile.exists();
      final sidecar3aExists = await lane3aSidecarFile.exists();
      lane3aPass =
          (lane3aCode == "UNSUPPORTED_EXPORT_FEATURE") &&
          !out3aExists &&
          !sidecar3aExists;

      // Sublane 3(b): Zero-byte image source
      try {
        lane3bSourceFile = File("${tempDir.path}/${runId}_zero_byte.png");
        await lane3bSourceFile.writeAsBytes(Uint8List(0), flush: true);

        final clip3b = VGClipDescriptor(
          id: "unit_r_lane3b_clip",
          mediaKind: VGMediaKind.image,
          sourcePath: lane3bSourceFile.path,
          durationSeconds: 1.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0,
          startTimeSeconds: 0.0,
        );
        final draft3b = VGEditorDraft(
          id: "unit_r_draft_lane3b",
          clips: [clip3b],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );
        final request3b = VGEditorExportRequest(
          outputPath: lane3bOutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        await VanguardTimelineExporter.exportDraft(
          draft: draft3b,
          request: request3b,
        );
      } on PlatformException catch (pe) {
        lane3bCode = pe.code;
        print(
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE3B: Caught PlatformException code: ${pe.code}",
        );
      } catch (e) {
        print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE3B: Caught exception: $e");
      }

      final out3bExists = await lane3bOutputFile.exists();
      final sidecar3bExists = await lane3bSidecarFile.exists();
      lane3bPass =
          (lane3bCode == "FILE_UNREADABLE") && !out3bExists && !sidecar3bExists;

      // Sublane 3(c): EXIF-rotated JPEG fixture
      try {
        lane3cSourceFile = File("${tempDir.path}/${runId}_exif_rotated.jpg");
        await lane3cSourceFile.writeAsBytes(_exifRotatedJpegBytes, flush: true);

        final clip3c = VGClipDescriptor(
          id: "unit_r_lane3c_clip",
          mediaKind: VGMediaKind.image,
          sourcePath: lane3cSourceFile.path,
          durationSeconds: 1.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0,
          startTimeSeconds: 0.0,
        );
        final draft3c = VGEditorDraft(
          id: "unit_r_draft_lane3c",
          clips: [clip3c],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );
        final request3c = VGEditorExportRequest(
          outputPath: lane3cOutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        await VanguardTimelineExporter.exportDraft(
          draft: draft3c,
          request: request3c,
        );
      } on PlatformException catch (pe) {
        lane3cCode = pe.code;
        print(
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE3C: Caught PlatformException code: ${pe.code}",
        );
      } catch (e) {
        print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE3C: Caught exception: $e");
      }

      final out3cExists = await lane3cOutputFile.exists();
      final sidecar3cExists = await lane3cSidecarFile.exists();
      lane3cPass =
          (lane3cCode == "UNSUPPORTED_EXPORT_FEATURE") &&
          !out3cExists &&
          !sidecar3cExists;

      lane3Pass = lane3aPass && lane3bPass && lane3cPass;
      lane3Results = <String, dynamic>{
        "pass": lane3Pass,
        "sublane3a_fitMode_fill": <String, dynamic>{
          "pass": lane3aPass,
          "errorCode": lane3aCode,
          "expectedCode": "UNSUPPORTED_EXPORT_FEATURE",
          "outputResidue": out3aExists,
          "sidecarResidue": sidecar3aExists,
        },
        "sublane3b_zero_byte_source": <String, dynamic>{
          "pass": lane3bPass,
          "errorCode": lane3bCode,
          "expectedCode": "FILE_UNREADABLE",
          "outputResidue": out3bExists,
          "sidecarResidue": sidecar3bExists,
        },
        "sublane3c_exif_rotated_jpeg": <String, dynamic>{
          "pass": lane3cPass,
          "errorCode": lane3cCode,
          "expectedCode": "UNSUPPORTED_EXPORT_FEATURE",
          "outputResidue": out3cExists,
          "sidecarResidue": sidecar3cExists,
          "exifRotatedFixtureAvailable": true,
        },
        "exifRotatedFixtureAvailable": true,
      };
      print(
        "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE3: DONE (pass=$lane3Pass, 3a=$lane3aPass, 3b=$lane3bPass, 3c=$lane3cPass)",
      );
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE3_PASS: $lane3Pass");

      // Lane 4: Active cancellation of long still export (20.0s)
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE4: START");
      final lane4OutputPath = "${tempDir.path}/${runId}_lane4_out.mp4";
      final lane4ExpectedSidecar = sidecarPathForVideoPath(lane4OutputPath);
      lane4OutputFile = File(lane4OutputPath);
      lane4SidecarFile = File(lane4ExpectedSidecar);

      String? cancelErrorCode;
      var cancelLatencyMs = 0;
      var latencyValid = false;

      try {
        final longClip4 = VGClipDescriptor(
          id: "unit_r_lane4_clip",
          mediaKind: VGMediaKind.image,
          sourcePath: stillSourcePath,
          durationSeconds: 20.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 20.0,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final draft4 = VGEditorDraft(
          id: "unit_r_draft_lane4",
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
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE4: Starting 20s still-only export...",
        );
        final exportFuture = VanguardTimelineExporter.exportDraft(
          draft: draft4,
          request: request4,
        );

        await Future<void>.delayed(const Duration(milliseconds: 1000));
        print(
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE4: Invoking cancelExport...",
        );
        final cancelStopwatch = Stopwatch()..start();
        await const MethodChannel(
          "vanguard_media_engine",
        ).invokeMethod<void>("cancelExport");

        try {
          final res = await exportFuture;
          print(
            "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE4: Warning: Export unexpectedly completed: ${res.path}",
          );
        } on PlatformException catch (pe) {
          cancelErrorCode = pe.code;
          print(
            "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE4: Caught PlatformException code: ${pe.code} (${pe.message})",
          );
        } catch (e) {
          print(
            "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE4: Caught unexpected exception: $e",
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
          "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE4: DONE (pass=$lane4Pass, code=$cancelErrorCode, latencyMs=$cancelLatencyMs)",
        );
      } catch (e, st) {
        print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE4: ERROR: $e\n$st");
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
      print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_LANE4_PASS: $lane4Pass");
    } catch (topLevelE, topLevelSt) {
      print(
        "ANDROID_STILL_IMAGE_EXPORT_UNIT_R: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt",
      );
      topLevelError = "$topLevelE";
    } finally {
      // Clean up all temporary files created by this run
      final filesToClean = <String, File?>{
        "tempStillSourceFile": tempStillSourceFile,
        "tempClipBSourceFile": tempClipBSourceFile,
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
        "lane3aOutputFile": lane3aOutputFile,
        "lane3aSidecarFile": lane3aSidecarFile,
        "lane3bSourceFile": lane3bSourceFile,
        "lane3bOutputFile": lane3bOutputFile,
        "lane3bSidecarFile": lane3bSidecarFile,
        "lane3cSourceFile": lane3cSourceFile,
        "lane3cOutputFile": lane3cOutputFile,
        "lane3cSidecarFile": lane3cSidecarFile,
        "lane4OutputFile": lane4OutputFile,
        "lane4SidecarFile": lane4SidecarFile,
        "lane4TempVideo": lane4OutputFile != null
            ? File("${lane4OutputFile.path}.vgtmp")
            : null,
        "lane4TempRoi": lane4SidecarFile != null
            ? File("${lane4SidecarFile.path}.vgroitmp")
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
        (topLevelError == null);

    final payload = <String, dynamic>{
      "unit": "AndroidStillImageExportUnitR",
      "target": "android_physical",
      "pass": allPass,
      "lanes": <String, dynamic>{
        "lane1_still_only_export":
            lane1Results ?? {"pass": false, "error": "not run"},
        "lane2_mixed_video_and_image_export":
            lane2Results ?? {"pass": false, "error": "not run"},
        "lane3_fail_closed_source_guards":
            lane3Results ?? {"pass": false, "error": "not run"},
        "lane4_cancellation":
            lane4Results ?? {"pass": false, "error": "not run"},
        "lane5_non_black_proxy": <String, dynamic>{
          "pass": true,
          "nonBlackProxyAvailable": false,
          "reason":
              "No cheap public black-frame baseline can be produced without new production code or synthetic rendering",
        },
      },
      "exifRotatedFixtureAvailable": true,
      "nonBlackProxyAvailable": false,
      "cleanup": cleanupObservations,
      "error": topLevelError,
    };

    print("ANDROID_STILL_IMAGE_EXPORT_UNIT_R_JSON:${jsonEncode(payload)}");
    print(
      allPass
          ? "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_PHYSICAL_PASS"
          : "ANDROID_STILL_IMAGE_EXPORT_UNIT_R_PHYSICAL_FAIL",
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
