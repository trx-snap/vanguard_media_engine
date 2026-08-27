// android_dag_export_unit_g_smoke.dart
// Vanguard Media Engine — Android True-DAG Export Unit G Physical Smoke Harness.
// Rotation metadata and canvas scaling normalization proof.
//
// Proof lanes:
//   Lane A: ROTATED_RAW_TO_PORTRAIT — Raw unpatched 1920x1080 clip_B (-90 deg rotation) exported to 720x1280 portrait canvas with fit scaling.
//   Lane B: HETEROGENEOUS_MIXED_TO_SQUARE — Two mixed clips (1080x1920 rot 0 and 1920x1080 rot -90) exported to 1080x1080 square canvas with fit scaling.
//   Lane C: NON_FIT_GUARDRAIL_REJECTION — contentMode != fit (fill) is rejected with UNSUPPORTED_EXPORT_FEATURE and preserves pre-existing output and sidecar.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String expectedEmptyRoiSidecar = '{"version":1,"rois":[]}';

Map<String, dynamic> _mediaInfoToMap(MediaInfo info) {
  return <String, dynamic>{
    'kind': info.kind.name,
    'container': info.container,
    'videoCodec': info.videoCodec,
    'audioCodec': info.audioCodec,
    'width': info.width,
    'height': info.height,
    'durationSeconds': info.durationSeconds,
    'bitrateKbps': info.bitrateKbps,
    'fps': info.fps,
    'fileSizeBytes': info.fileSizeBytes,
    'hasVideo': info.hasVideo,
    'hasAudio': info.hasAudio,
    'isHDR': info.isHDR,
    'hasMoovAtFront': info.hasMoovAtFront,
    'hasRotationTransform': info.hasRotationTransform,
    'hasEmbeddedMetadata': info.hasEmbeddedMetadata,
    'encodedWidth': info.encodedWidth,
    'encodedHeight': info.encodedHeight,
    'displayWidth': info.displayWidth,
    'displayHeight': info.displayHeight,
    'rotationDegrees': info.rotationDegrees,
    'transformA': info.transformA,
    'transformB': info.transformB,
    'transformC': info.transformC,
    'transformD': info.transformD,
    'transformTx': info.transformTx,
    'transformTy': info.transformTy,
    'orientationStatus': info.orientationStatus,
  };
}

String sidecarPathForVideoPath(String videoPath) {
  final lastSeparator = videoPath.lastIndexOf('/');
  final lastDot = videoPath.lastIndexOf('.');
  if (lastDot <= lastSeparator) {
    return '$videoPath.roi.json';
  }
  return '${videoPath.substring(0, lastDot)}.roi.json';
}

void main() {
  runApp(const AndroidDagExportUnitGSmokeApp());
}

class AndroidDagExportUnitGSmokeApp extends StatefulWidget {
  const AndroidDagExportUnitGSmokeApp({super.key});

  @override
  State<AndroidDagExportUnitGSmokeApp> createState() =>
      _AndroidDagExportUnitGSmokeAppState();
}

class _AndroidDagExportUnitGSmokeAppState
    extends State<AndroidDagExportUnitGSmokeApp> {
  String _status = 'Running Android Export Unit G Physical Smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_EXPORT_UNIT_G_SMOKE: START');
    final runId = 'unit_g_${DateTime.now().millisecondsSinceEpoch}';

    File? tempSourceClipA;
    File? tempSourceClipB;
    File? laneAOutputFile;
    File? laneASidecarFile;
    File? laneBOutputFile;
    File? laneBSidecarFile;
    File? laneCSentinelVideoFile;
    File? laneCSentinelSidecarFile;

    MediaInfo? sourceClipBMediaInfo;
    Map<String, dynamic>? laneAResults;
    Map<String, dynamic>? laneBResults;
    Map<String, dynamic>? laneCResults;

    var laneAPass = false;
    var laneBPass = false;
    var laneCPass = false;
    String? topLevelError;

    try {
      final tempDir = Directory.systemTemp;

      // ── Copy Asset Fixtures to System Temp (Raw Unpatched) ────────────────
      print(
        'ANDROID_EXPORT_UNIT_G_SMOKE: Copying raw unpatched clip_B.mov to temp...',
      );
      final clipBByteData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final rawBytesB = clipBByteData.buffer.asUint8List(
        clipBByteData.offsetInBytes,
        clipBByteData.lengthInBytes,
      );
      tempSourceClipB = File('${tempDir.path}/${runId}_source_clip_B.mov');
      await tempSourceClipB.writeAsBytes(
        Uint8List.fromList(rawBytesB),
        flush: true,
      );
      final sourcePathB = tempSourceClipB.path;
      print(
        'ANDROID_EXPORT_UNIT_G_SMOKE: Raw source clip B ready at $sourcePathB (${rawBytesB.length} bytes)',
      );

      // ── Inspect and Validate Source Clip B Rotation Metadata ─────────────
      print(
        'ANDROID_EXPORT_UNIT_G_SMOKE: Inspecting raw source clip B for rotation metadata...',
      );
      final sourceInfoB = await VanguardMediaPreparer.inspectMedia(sourcePathB);
      print(
        'ANDROID_EXPORT_UNIT_G_SMOKE: Source clip B MediaInfo: $sourceInfoB',
      );
      final sourceBHasVideo = sourceInfoB != null && sourceInfoB.hasVideo;
      final sourceBEncodedDimsValid =
          sourceInfoB != null &&
          (sourceInfoB.width == 1920 || sourceInfoB.encodedWidth == 1920) &&
          (sourceInfoB.height == 1080 || sourceInfoB.encodedHeight == 1080);
      final sourceBDisplayDimsValid =
          sourceInfoB != null &&
          (sourceInfoB.displayWidth == 0 ||
              sourceInfoB.displayWidth == 1080 ||
              sourceInfoB.displayWidth == 1920) &&
          (sourceInfoB.displayHeight == 0 ||
              sourceInfoB.displayHeight == 1920 ||
              sourceInfoB.displayHeight == 1080);
      final sourceBRotationValid =
          sourceInfoB != null &&
          ((sourceInfoB.rotationDegrees == 270 ||
                  sourceInfoB.rotationDegrees == -90) ||
              (sourceInfoB.hasRotationTransform &&
                  sourceInfoB.orientationStatus == 'valid'));

      final sourceBValid =
          sourceBHasVideo &&
          sourceBEncodedDimsValid &&
          sourceBDisplayDimsValid &&
          sourceBRotationValid;

      if (sourceInfoB == null || !sourceBValid) {
        throw Exception(
          'Source clip B failed orientation/rotation metadata validation (hasVideo=$sourceBHasVideo, encodedDims=$sourceBEncodedDimsValid, displayDims=$sourceBDisplayDimsValid, rotation=$sourceBRotationValid, info=$sourceInfoB)',
        );
      }
      sourceClipBMediaInfo = sourceInfoB;

      print('ANDROID_EXPORT_UNIT_G_SMOKE: Copying raw clip_A.mov to temp...');
      final clipAByteData = await rootBundle.load(
        'assets/manual_test_clips/clip_A.mov',
      );
      final rawBytesA = clipAByteData.buffer.asUint8List(
        clipAByteData.offsetInBytes,
        clipAByteData.lengthInBytes,
      );
      tempSourceClipA = File('${tempDir.path}/${runId}_source_clip_A.mov');
      await tempSourceClipA.writeAsBytes(
        Uint8List.fromList(rawBytesA),
        flush: true,
      );
      final sourcePathA = tempSourceClipA.path;
      print(
        'ANDROID_EXPORT_UNIT_G_SMOKE: Raw source clip A ready at $sourcePathA (${rawBytesA.length} bytes)',
      );

      // ── Lane A: ROTATED_RAW_TO_PORTRAIT ──────────────────────────────────
      print('ANDROID_EXPORT_UNIT_G_SMOKE_LANE_A: START');
      final laneAOutputPath = '${tempDir.path}/${runId}_lane_a_out.mp4';
      final laneAExpectedSidecarPath = sidecarPathForVideoPath(laneAOutputPath);
      laneAOutputFile = File(laneAOutputPath);
      laneASidecarFile = File(laneAExpectedSidecarPath);

      try {
        final clipA = VGClipDescriptor(
          id: 'unit_g_lane_a_clip',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePathB,
          durationSeconds: 5.565,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.5,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final draftA = VGEditorDraft(
          id: 'unit_g_draft_lane_a',
          clips: [clipA],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final requestA = VGEditorExportRequest(
          outputPath: laneAOutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        final resultA = await VanguardTimelineExporter.exportDraft(
          draft: draftA,
          request: requestA,
        );

        final outExists = await laneAOutputFile.exists();
        final outBytes = outExists ? await laneAOutputFile.length() : 0;
        final pathMatch = resultA.path == laneAOutputPath;
        final dimsMatch =
            resultA.width == 720 && resultA.height == 1280 && resultA.fps == 30;
        final durationValid =
            resultA.durationSeconds >= 1.0 && resultA.durationSeconds <= 2.2;

        final sidecarPathNonNull = resultA.exportRoiSidecarPath != null;
        final sidecarPathMatch =
            resultA.exportRoiSidecarPath == laneAExpectedSidecarPath;
        final sidecarExists = await laneASidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await laneASidecarFile.readAsString()
            : '';
        final sidecarContentExact = sidecarContent == expectedEmptyRoiSidecar;

        print(
          'ANDROID_EXPORT_UNIT_G_SMOKE_LANE_A: Inspecting exported output media info...',
        );
        final laneAExportMediaInfo = await VanguardMediaPreparer.inspectMedia(
          laneAOutputPath,
        );
        print(
          'ANDROID_EXPORT_UNIT_G_SMOKE_LANE_A: Exported MediaInfo: $laneAExportMediaInfo',
        );

        final laneAMediaHasVideo =
            laneAExportMediaInfo != null && laneAExportMediaInfo.hasVideo;
        final laneAMediaDimsValid =
            laneAExportMediaInfo != null &&
            laneAExportMediaInfo.width == 720 &&
            laneAExportMediaInfo.height == 1280 &&
            (laneAExportMediaInfo.encodedWidth == 0 ||
                laneAExportMediaInfo.encodedWidth == 720) &&
            (laneAExportMediaInfo.encodedHeight == 0 ||
                laneAExportMediaInfo.encodedHeight == 1280) &&
            (laneAExportMediaInfo.displayWidth == 0 ||
                laneAExportMediaInfo.displayWidth == 720) &&
            (laneAExportMediaInfo.displayHeight == 0 ||
                laneAExportMediaInfo.displayHeight == 1280);
        final laneAMediaNoRotation =
            laneAExportMediaInfo != null &&
            (!laneAExportMediaInfo.hasRotationTransform ||
                laneAExportMediaInfo.rotationDegrees == 0 ||
                laneAExportMediaInfo.rotationDegrees == null);

        final laneAMediaValid =
            laneAMediaHasVideo && laneAMediaDimsValid && laneAMediaNoRotation;

        laneAPass =
            outExists &&
            outBytes > 0 &&
            pathMatch &&
            dimsMatch &&
            durationValid &&
            sidecarPathNonNull &&
            sidecarPathMatch &&
            sidecarExists &&
            sidecarContentExact &&
            laneAMediaValid;

        laneAResults = <String, dynamic>{
          'pass': laneAPass,
          'outputPath': resultA.path,
          'outputBytes': outBytes,
          'durationSeconds': resultA.durationSeconds,
          'width': resultA.width,
          'height': resultA.height,
          'fps': resultA.fps,
          'exportRoiSidecarPath': resultA.exportRoiSidecarPath,
          'expectedRoiSidecarPath': laneAExpectedSidecarPath,
          'sidecarExists': sidecarExists,
          'sidecarContentExact': sidecarContentExact,
          'exportedMediaInfo': laneAExportMediaInfo != null
              ? _mediaInfoToMap(laneAExportMediaInfo)
              : null,
          'error': laneAPass
              ? null
              : 'Validation failed (exists=$outExists, bytes=$outBytes, pathMatch=$pathMatch, dimsMatch=$dimsMatch, durationValid=$durationValid, sidecarNonNull=$sidecarPathNonNull, sidecarPathMatch=$sidecarPathMatch, sidecarExists=$sidecarExists, sidecarContentExact=$sidecarContentExact, mediaValid=$laneAMediaValid)',
        };
        print(
          'ANDROID_EXPORT_UNIT_G_SMOKE_LANE_A: DONE (pass=$laneAPass, duration=${resultA.durationSeconds}, bytes=$outBytes, sidecar=${resultA.exportRoiSidecarPath})',
        );
      } catch (e, st) {
        print('ANDROID_EXPORT_UNIT_G_SMOKE_LANE_A: ERROR: $e\n$st');
        laneAResults = <String, dynamic>{
          'pass': false,
          'outputPath': laneAOutputPath,
          'outputBytes': 0,
          'durationSeconds': 0.0,
          'width': 0,
          'height': 0,
          'fps': 0,
          'exportRoiSidecarPath': null,
          'expectedRoiSidecarPath': laneAExpectedSidecarPath,
          'sidecarExists': false,
          'sidecarContentExact': false,
          'exportedMediaInfo': null,
          'error': '$e',
        };
        laneAPass = false;
      }

      // ── Lane B: HETEROGENEOUS_MIXED_TO_SQUARE ─────────────────────────────
      print('ANDROID_EXPORT_UNIT_G_SMOKE_LANE_B: START');
      final laneBOutputPath = '${tempDir.path}/${runId}_lane_b_out.mp4';
      final laneBExpectedSidecarPath = sidecarPathForVideoPath(laneBOutputPath);
      laneBOutputFile = File(laneBOutputPath);
      laneBSidecarFile = File(laneBExpectedSidecarPath);

      try {
        final clipB1 = VGClipDescriptor(
          id: 'unit_g_lane_b_clip1',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePathA,
          durationSeconds: 9.833,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final clipB2 = VGClipDescriptor(
          id: 'unit_g_lane_b_clip2',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePathB,
          durationSeconds: 5.565,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0,
          startTimeSeconds: 1.0,
          speed: 1.0,
        );

        final draftB = VGEditorDraft(
          id: 'unit_g_draft_lane_b',
          clips: [clipB1, clipB2],
          canvasWidth: 1080,
          canvasHeight: 1080,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 1080,
            height: 1080,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final requestB = VGEditorExportRequest(
          outputPath: laneBOutputPath,
          width: 1080,
          height: 1080,
          fps: 30,
          bitrateBps: 4000000,
        );

        final resultB = await VanguardTimelineExporter.exportDraft(
          draft: draftB,
          request: requestB,
        );

        final outExists = await laneBOutputFile.exists();
        final outBytes = outExists ? await laneBOutputFile.length() : 0;
        final pathMatch = resultB.path == laneBOutputPath;
        final dimsMatch =
            resultB.width == 1080 &&
            resultB.height == 1080 &&
            resultB.fps == 30;
        final durationValid =
            resultB.durationSeconds >= 1.5 && resultB.durationSeconds <= 2.6;

        final sidecarPathNonNull = resultB.exportRoiSidecarPath != null;
        final sidecarPathMatch =
            resultB.exportRoiSidecarPath == laneBExpectedSidecarPath;
        final sidecarExists = await laneBSidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await laneBSidecarFile.readAsString()
            : '';
        final sidecarContentExact = sidecarContent == expectedEmptyRoiSidecar;

        print(
          'ANDROID_EXPORT_UNIT_G_SMOKE_LANE_B: Inspecting exported output media info...',
        );
        final laneBExportMediaInfo = await VanguardMediaPreparer.inspectMedia(
          laneBOutputPath,
        );
        print(
          'ANDROID_EXPORT_UNIT_G_SMOKE_LANE_B: Exported MediaInfo: $laneBExportMediaInfo',
        );

        final laneBMediaHasVideo =
            laneBExportMediaInfo != null && laneBExportMediaInfo.hasVideo;
        final laneBMediaDimsValid =
            laneBExportMediaInfo != null &&
            laneBExportMediaInfo.width == 1080 &&
            laneBExportMediaInfo.height == 1080 &&
            (laneBExportMediaInfo.encodedWidth == 0 ||
                laneBExportMediaInfo.encodedWidth == 1080) &&
            (laneBExportMediaInfo.encodedHeight == 0 ||
                laneBExportMediaInfo.encodedHeight == 1080) &&
            (laneBExportMediaInfo.displayWidth == 0 ||
                laneBExportMediaInfo.displayWidth == 1080) &&
            (laneBExportMediaInfo.displayHeight == 0 ||
                laneBExportMediaInfo.displayHeight == 1080);
        final laneBMediaNoRotation =
            laneBExportMediaInfo != null &&
            (!laneBExportMediaInfo.hasRotationTransform ||
                laneBExportMediaInfo.rotationDegrees == 0 ||
                laneBExportMediaInfo.rotationDegrees == null);

        final laneBMediaValid =
            laneBMediaHasVideo && laneBMediaDimsValid && laneBMediaNoRotation;

        laneBPass =
            outExists &&
            outBytes > 0 &&
            pathMatch &&
            dimsMatch &&
            durationValid &&
            sidecarPathNonNull &&
            sidecarPathMatch &&
            sidecarExists &&
            sidecarContentExact &&
            laneBMediaValid;

        laneBResults = <String, dynamic>{
          'pass': laneBPass,
          'outputPath': resultB.path,
          'outputBytes': outBytes,
          'durationSeconds': resultB.durationSeconds,
          'width': resultB.width,
          'height': resultB.height,
          'fps': resultB.fps,
          'exportRoiSidecarPath': resultB.exportRoiSidecarPath,
          'expectedRoiSidecarPath': laneBExpectedSidecarPath,
          'sidecarExists': sidecarExists,
          'sidecarContentExact': sidecarContentExact,
          'exportedMediaInfo': laneBExportMediaInfo != null
              ? _mediaInfoToMap(laneBExportMediaInfo)
              : null,
          'error': laneBPass
              ? null
              : 'Validation failed (exists=$outExists, bytes=$outBytes, pathMatch=$pathMatch, dimsMatch=$dimsMatch, durationValid=$durationValid, sidecarNonNull=$sidecarPathNonNull, sidecarPathMatch=$sidecarPathMatch, sidecarExists=$sidecarExists, sidecarContentExact=$sidecarContentExact, mediaValid=$laneBMediaValid)',
        };
        print(
          'ANDROID_EXPORT_UNIT_G_SMOKE_LANE_B: DONE (pass=$laneBPass, duration=${resultB.durationSeconds}, bytes=$outBytes, sidecar=${resultB.exportRoiSidecarPath})',
        );
      } catch (e, st) {
        print('ANDROID_EXPORT_UNIT_G_SMOKE_LANE_B: ERROR: $e\n$st');
        laneBResults = <String, dynamic>{
          'pass': false,
          'outputPath': laneBOutputPath,
          'outputBytes': 0,
          'durationSeconds': 0.0,
          'width': 0,
          'height': 0,
          'fps': 0,
          'exportRoiSidecarPath': null,
          'expectedRoiSidecarPath': laneBExpectedSidecarPath,
          'sidecarExists': false,
          'sidecarContentExact': false,
          'exportedMediaInfo': null,
          'error': '$e',
        };
        laneBPass = false;
      }

      // ── Lane C: NON_FIT_GUARDRAIL_REJECTION ───────────────────────────────
      print('ANDROID_EXPORT_UNIT_G_SMOKE_LANE_C: START');
      final laneCOutputPath = '${tempDir.path}/${runId}_lane_c_sentinel.mp4';
      final laneCExpectedSidecarPath = sidecarPathForVideoPath(laneCOutputPath);
      laneCSentinelVideoFile = File(laneCOutputPath);
      laneCSentinelSidecarFile = File(laneCExpectedSidecarPath);

      const videoSentinelContent = 'SENTINEL_PRE_EXISTING_UNIT_G_OUTPUT_DATA';
      const sidecarSentinelContent = '{"sentinel":true}';

      try {
        await laneCSentinelVideoFile.writeAsString(
          videoSentinelContent,
          flush: true,
        );
        await laneCSentinelSidecarFile.writeAsString(
          sidecarSentinelContent,
          flush: true,
        );

        final clipC = VGClipDescriptor(
          id: 'unit_g_lane_c_clip',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePathB,
          durationSeconds: 5.565,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.5,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final draftC = VGEditorDraft(
          id: 'unit_g_draft_lane_c',
          clips: [clipC],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fill,
          ),
        );

        final requestC = VGEditorExportRequest(
          outputPath: laneCOutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        String? exceptionCode;
        try {
          await VanguardTimelineExporter.exportDraft(
            draft: draftC,
            request: requestC,
          );
        } on PlatformException catch (pe) {
          exceptionCode = pe.code;
          print(
            'ANDROID_EXPORT_UNIT_G_SMOKE_LANE_C: Caught PlatformException code: ${pe.code}',
          );
        }

        final videoSentinelStillExists = await laneCSentinelVideoFile.exists();
        final currentVideoContent = videoSentinelStillExists
            ? await laneCSentinelVideoFile.readAsString()
            : '';
        final videoSentinelPreserved =
            videoSentinelStillExists &&
            (currentVideoContent == videoSentinelContent);

        final sidecarSentinelStillExists = await laneCSentinelSidecarFile
            .exists();
        final currentSidecarContent = sidecarSentinelStillExists
            ? await laneCSentinelSidecarFile.readAsString()
            : '';
        final sidecarSentinelPreserved =
            sidecarSentinelStillExists &&
            (currentSidecarContent == sidecarSentinelContent);

        final codeMatch = exceptionCode == 'UNSUPPORTED_EXPORT_FEATURE';
        laneCPass =
            codeMatch && videoSentinelPreserved && sidecarSentinelPreserved;

        final videoBytes = videoSentinelStillExists
            ? await laneCSentinelVideoFile.length()
            : 0;

        laneCResults = <String, dynamic>{
          'pass': laneCPass,
          'exceptionCode': exceptionCode,
          'videoSentinelPreserved': videoSentinelPreserved,
          'sidecarSentinelPreserved': sidecarSentinelPreserved,
          'outputPath': laneCOutputPath,
          'outputBytes': videoBytes,
          'durationSeconds': 0.0,
          'exportRoiSidecarPath': null,
          'expectedRoiSidecarPath': laneCExpectedSidecarPath,
          'sidecarExists': sidecarSentinelStillExists,
          'sidecarContentExact': sidecarSentinelPreserved,
          'error': laneCPass
              ? null
              : 'Rejection or preservation mismatch (code=$exceptionCode, videoPreserved=$videoSentinelPreserved, sidecarPreserved=$sidecarSentinelPreserved)',
        };
        print(
          'ANDROID_EXPORT_UNIT_G_SMOKE_LANE_C: DONE (pass=$laneCPass, code=$exceptionCode, videoPreserved=$videoSentinelPreserved, sidecarPreserved=$sidecarSentinelPreserved)',
        );
      } catch (e, st) {
        print('ANDROID_EXPORT_UNIT_G_SMOKE_LANE_C: ERROR: $e\n$st');
        laneCResults = <String, dynamic>{
          'pass': false,
          'exceptionCode': null,
          'videoSentinelPreserved': false,
          'sidecarSentinelPreserved': false,
          'outputPath': laneCOutputPath,
          'outputBytes': 0,
          'durationSeconds': 0.0,
          'exportRoiSidecarPath': null,
          'expectedRoiSidecarPath': laneCExpectedSidecarPath,
          'sidecarExists': false,
          'sidecarContentExact': false,
          'error': '$e',
        };
        laneCPass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_EXPORT_UNIT_G_SMOKE: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // ── Clean up all temp files ───────────────────────────────────────────
      final filesToClean = <String, File?>{
        'tempSourceClipA': tempSourceClipA,
        'tempSourceClipB': tempSourceClipB,
        'laneAOutputFile': laneAOutputFile,
        'laneASidecarFile': laneASidecarFile,
        'laneBOutputFile': laneBOutputFile,
        'laneBSidecarFile': laneBSidecarFile,
        'laneCSentinelVideoFile': laneCSentinelVideoFile,
        'laneCSentinelSidecarFile': laneCSentinelSidecarFile,
      };

      for (final entry in filesToClean.entries) {
        final f = entry.value;
        if (f != null) {
          try {
            if (await f.exists()) {
              final len = await f.length();
              print(
                'ANDROID_EXPORT_UNIT_G_SMOKE: Cleaning ${entry.key} at ${f.path} ($len bytes)',
              );
              await f.delete();
            }
          } catch (cleanE) {
            print(
              'ANDROID_EXPORT_UNIT_G_SMOKE: Warning: Failed to clean ${entry.key} at ${f.path}: $cleanE',
            );
          }
        }
      }
    }

    // ── Build and Print Aggregate JSON and Verdict ─────────────────────────
    final allPass =
        laneAPass && laneBPass && laneCPass && (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'AndroidExportUnitG',
      'target': 'android_physical',
      'pass': allPass,
      'sourceClipBMediaInfo': sourceClipBMediaInfo != null
          ? _mediaInfoToMap(sourceClipBMediaInfo)
          : null,
      'lanes': <String, dynamic>{
        'rotatedRawToPortrait':
            laneAResults ?? {'pass': false, 'error': 'not run'},
        'heterogeneousMixedToSquare':
            laneBResults ?? {'pass': false, 'error': 'not run'},
        'nonFitGuardrailRejection':
            laneCResults ?? {'pass': false, 'error': 'not run'},
      },
      'nonClaims': const <String>[
        'no transitions/overlays/spatial transforms',
        'no audio sidecar muxing in Unit G',
        'no ConnectsApp UI wiring',
      ],
      'error': topLevelError,
    };

    print('ANDROID_EXPORT_UNIT_G_SMOKE_JSON:${jsonEncode(payload)}');
    print(
      allPass
          ? 'ANDROID_EXPORT_UNIT_G_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_EXPORT_UNIT_G_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass ? 'PASS' : 'FAIL';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(allPass ? 0 : 1);
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
