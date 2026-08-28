// android_dag_export_unit_d_smoke.dart
// Vanguard Media Engine — Android True-DAG Export Unit D ROI Physical Smoke Harness.
//
// Proof lanes:
//   Lane A: full local video export, direct-copy eligible original audio, verify ROI sidecar emission.
//   Lane B: two trimmed local hard-cut clips, PCM mixdown path, verify ROI sidecar emission.
//   Lane C: unsupported scaling rejection preserves pre-existing output video and sidecar.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

bool _isValidEmptyRoiSidecar(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) return false;
    final sidecar = VGROISidecar.fromJson(decoded);
    return sidecar.version == 1 &&
        sidecar.sourceType == 'export' &&
        sidecar.platform == 'android' &&
        sidecar.coordinateSpace == 'export_output_normalized' &&
        sidecar.recordingSessionId == 'android-empty-export' &&
        sidecar.coverage.coveragePercent == 0.0 &&
        sidecar.coverage.missingIntervals.isEmpty &&
        sidecar.samples.isEmpty &&
        sidecar.finalized == true;
  } catch (_) {
    return false;
  }
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
  runApp(const AndroidDagExportUnitDSmokeApp());
}

class AndroidDagExportUnitDSmokeApp extends StatefulWidget {
  const AndroidDagExportUnitDSmokeApp({super.key});

  @override
  State<AndroidDagExportUnitDSmokeApp> createState() =>
      _AndroidDagExportUnitDSmokeAppState();
}

class _AndroidDagExportUnitDSmokeAppState
    extends State<AndroidDagExportUnitDSmokeApp> {
  String _status = 'Running Android Export Unit D ROI Physical Smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_EXPORT_UNIT_D_ROI_SMOKE: START');
    final runId = 'unit_d_${DateTime.now().millisecondsSinceEpoch}';

    File? tempSourceClip;
    File? laneAOutputFile;
    File? laneASidecarFile;
    File? laneBOutputFile;
    File? laneBSidecarFile;
    File? laneCSentinelVideoFile;
    File? laneCSentinelSidecarFile;

    Map<String, dynamic>? laneAResults;
    Map<String, dynamic>? laneBResults;
    Map<String, dynamic>? laneCResults;

    var laneAPass = false;
    var laneBPass = false;
    var laneCPass = false;
    String? topLevelError;

    try {
      // ── Copy Asset Fixture to System Temp ─────────────────────────────────
      print('ANDROID_EXPORT_UNIT_D_ROI_SMOKE: Copying clip_B.mov to temp...');
      final clipByteData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final rawBytes = clipByteData.buffer.asUint8List(
        clipByteData.offsetInBytes,
        clipByteData.lengthInBytes,
      );
      final copy = Uint8List.fromList(rawBytes);

      // Normalize tkhd matrix to identity in the temp copy so Android MediaExtractor
      // reads rotation 0 without mutating the source fixture asset.
      const identityMatrix = <int>[
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x40,
        0x00,
        0x00,
        0x00,
      ];
      for (int i = 0; i <= copy.length - 4; i++) {
        if (copy[i] == 0x74 &&
            copy[i + 1] == 0x6B &&
            copy[i + 2] == 0x68 &&
            copy[i + 3] == 0x64) {
          final version = copy[i + 4];
          final matrixOffset = (version == 0) ? (i + 44) : (i + 56);
          if (matrixOffset + 36 <= copy.length) {
            for (int m = 0; m < 36; m++) {
              copy[matrixOffset + m] = identityMatrix[m];
            }
          }
        }
      }

      final tempDir = Directory.systemTemp;
      tempSourceClip = File('${tempDir.path}/${runId}_source_clip_B.mov');
      await tempSourceClip.writeAsBytes(copy, flush: true);
      final sourcePath = tempSourceClip.path;
      print(
        'ANDROID_EXPORT_UNIT_D_ROI_SMOKE: Temp source clip ready at $sourcePath',
      );

      // ── Lane A: Full local video export (direct-copy audio) + ROI sidecar ──
      print('ANDROID_EXPORT_UNIT_D_ROI_SMOKE_LANE_A: START');
      final laneAOutputPath = '${tempDir.path}/${runId}_lane_a_out.mp4';
      final laneAExpectedSidecarPath = sidecarPathForVideoPath(laneAOutputPath);
      laneAOutputFile = File(laneAOutputPath);
      laneASidecarFile = File(laneAExpectedSidecarPath);

      try {
        final clipA = VGClipDescriptor(
          id: 'unit_d_full_clip',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePath,
          durationSeconds: 5.565,
          trimStartSeconds: 0.0,
          trimEndSeconds: 5.565,
          startTimeSeconds: 0.0,
        );

        final rawDraftA = VGEditorDraft(
          id: 'unit_d_draft_lane_a',
          clips: [clipA],
          canvasWidth: 1920,
          canvasHeight: 1080,
          fps: 30,
        );

        final derivedDraftA = rawDraftA
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final requestA = VGEditorExportRequest(
          outputPath: laneAOutputPath,
          width: 1920,
          height: 1080,
          fps: 30,
          bitrateBps: 4000000,
        );

        final resultA = await VanguardTimelineExporter.exportDraft(
          draft: derivedDraftA,
          request: requestA,
        );

        final outExists = await laneAOutputFile.exists();
        final outBytes = outExists ? await laneAOutputFile.length() : 0;
        final pathMatch = resultA.path == laneAOutputPath;
        final dimsMatch =
            resultA.width == 1920 &&
            resultA.height == 1080 &&
            resultA.fps == 30;
        final durationValid =
            resultA.durationSeconds >= 5.0 && resultA.durationSeconds <= 6.2;

        final sidecarPathNonNull = resultA.exportRoiSidecarPath != null;
        final sidecarPathMatch =
            resultA.exportRoiSidecarPath == laneAExpectedSidecarPath;
        final sidecarExists = await laneASidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await laneASidecarFile.readAsString()
            : '';
        final sidecarContentExact = _isValidEmptyRoiSidecar(sidecarContent);

        laneAPass =
            outExists &&
            outBytes > 0 &&
            pathMatch &&
            dimsMatch &&
            durationValid &&
            sidecarPathNonNull &&
            sidecarPathMatch &&
            sidecarExists &&
            sidecarContentExact;

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
          'error': laneAPass
              ? null
              : 'Validation failed (exists=$outExists, bytes=$outBytes, pathMatch=$pathMatch, dimsMatch=$dimsMatch, durationValid=$durationValid, sidecarNonNull=$sidecarPathNonNull, sidecarPathMatch=$sidecarPathMatch, sidecarExists=$sidecarExists, sidecarContentExact=$sidecarContentExact)',
        };
        print(
          'ANDROID_EXPORT_UNIT_D_ROI_SMOKE_LANE_A: DONE (pass=$laneAPass, duration=${resultA.durationSeconds}, bytes=$outBytes, sidecar=${resultA.exportRoiSidecarPath})',
        );
      } catch (e, st) {
        print('ANDROID_EXPORT_UNIT_D_ROI_SMOKE_LANE_A: ERROR: $e\n$st');
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
          'error': '$e',
        };
        laneAPass = false;
      }

      // ── Lane B: Two trimmed local hard-cut clips (mixdown path) + ROI sidecar
      print('ANDROID_EXPORT_UNIT_D_ROI_SMOKE_LANE_B: START');
      final laneBOutputPath = '${tempDir.path}/${runId}_lane_b_out.mp4';
      final laneBExpectedSidecarPath = sidecarPathForVideoPath(laneBOutputPath);
      laneBOutputFile = File(laneBOutputPath);
      laneBSidecarFile = File(laneBExpectedSidecarPath);

      try {
        final clipB1 = VGClipDescriptor(
          id: 'unit_d_trim_1',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePath,
          durationSeconds: 5.565,
          trimStartSeconds: 0.5,
          trimEndSeconds: 2.0,
          startTimeSeconds: 0.0,
        );

        final clipB2 = VGClipDescriptor(
          id: 'unit_d_trim_2',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePath,
          durationSeconds: 5.565,
          trimStartSeconds: 2.0,
          trimEndSeconds: 3.5,
          startTimeSeconds: 1.5,
        );

        final rawDraftB = VGEditorDraft(
          id: 'unit_d_draft_lane_b',
          clips: [clipB1, clipB2],
          canvasWidth: 1920,
          canvasHeight: 1080,
          fps: 30,
        );

        final derivedDraftB = rawDraftB
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final requestB = VGEditorExportRequest(
          outputPath: laneBOutputPath,
          width: 1920,
          height: 1080,
          fps: 30,
          bitrateBps: 4000000,
        );

        final resultB = await VanguardTimelineExporter.exportDraft(
          draft: derivedDraftB,
          request: requestB,
        );

        final outExists = await laneBOutputFile.exists();
        final outBytes = outExists ? await laneBOutputFile.length() : 0;
        final pathMatch = resultB.path == laneBOutputPath;
        final dimsMatch =
            resultB.width == 1920 &&
            resultB.height == 1080 &&
            resultB.fps == 30;
        final durationValid =
            resultB.durationSeconds >= 2.6 && resultB.durationSeconds <= 3.4;

        final sidecarPathNonNull = resultB.exportRoiSidecarPath != null;
        final sidecarPathMatch =
            resultB.exportRoiSidecarPath == laneBExpectedSidecarPath;
        final sidecarExists = await laneBSidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await laneBSidecarFile.readAsString()
            : '';
        final sidecarContentExact = _isValidEmptyRoiSidecar(sidecarContent);

        laneBPass =
            outExists &&
            outBytes > 0 &&
            pathMatch &&
            dimsMatch &&
            durationValid &&
            sidecarPathNonNull &&
            sidecarPathMatch &&
            sidecarExists &&
            sidecarContentExact;

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
          'error': laneBPass
              ? null
              : 'Validation failed (exists=$outExists, bytes=$outBytes, pathMatch=$pathMatch, dimsMatch=$dimsMatch, durationValid=$durationValid, sidecarNonNull=$sidecarPathNonNull, sidecarPathMatch=$sidecarPathMatch, sidecarExists=$sidecarExists, sidecarContentExact=$sidecarContentExact)',
        };
        print(
          'ANDROID_EXPORT_UNIT_D_ROI_SMOKE_LANE_B: DONE (pass=$laneBPass, duration=${resultB.durationSeconds}, bytes=$outBytes, sidecar=${resultB.exportRoiSidecarPath})',
        );
      } catch (e, st) {
        print('ANDROID_EXPORT_UNIT_D_ROI_SMOKE_LANE_B: ERROR: $e\n$st');
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
          'error': '$e',
        };
        laneBPass = false;
      }

      // ── Lane C: Unsupported scaling rejection preserves sentinel video and sidecar
      print('ANDROID_EXPORT_UNIT_D_ROI_SMOKE_LANE_C: START');
      final laneCOutputPath = '${tempDir.path}/${runId}_lane_c_sentinel.mp4';
      final laneCExpectedSidecarPath = sidecarPathForVideoPath(laneCOutputPath);
      laneCSentinelVideoFile = File(laneCOutputPath);
      laneCSentinelSidecarFile = File(laneCExpectedSidecarPath);

      const videoSentinelContent = 'SENTINEL_PRE_EXISTING_UNIT_D_OUTPUT_DATA';
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
          id: 'unit_d_scaling_test_clip',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePath,
          durationSeconds: 5.565,
          trimStartSeconds: 0.0,
          trimEndSeconds: 5.565,
          startTimeSeconds: 0.0,
        );

        final rawDraftC = VGEditorDraft(
          id: 'unit_d_draft_lane_c',
          clips: [clipC],
          canvasWidth: 640,
          canvasHeight: 360,
          fps: 30,
        );

        final derivedDraftC = rawDraftC
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final requestC = VGEditorExportRequest(
          outputPath: laneCOutputPath,
          width: 640,
          height: 360,
          fps: 30,
          bitrateBps: 4000000,
        );

        String? exceptionCode;
        try {
          await VanguardTimelineExporter.exportDraft(
            draft: derivedDraftC,
            request: requestC,
          );
        } on PlatformException catch (pe) {
          exceptionCode = pe.code;
          print(
            'ANDROID_EXPORT_UNIT_D_ROI_SMOKE_LANE_C: Caught PlatformException code: ${pe.code}',
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
          'ANDROID_EXPORT_UNIT_D_ROI_SMOKE_LANE_C: DONE (pass=$laneCPass, code=$exceptionCode, videoPreserved=$videoSentinelPreserved, sidecarPreserved=$sidecarSentinelPreserved)',
        );
      } catch (e, st) {
        print('ANDROID_EXPORT_UNIT_D_ROI_SMOKE_LANE_C: ERROR: $e\n$st');
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
        'ANDROID_EXPORT_UNIT_D_ROI_SMOKE: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // ── Clean up all temp files ───────────────────────────────────────────
      if (tempSourceClip != null) {
        try {
          if (await tempSourceClip.exists()) {
            await tempSourceClip.delete();
          }
        } catch (_) {}
      }
      if (laneAOutputFile != null) {
        try {
          if (await laneAOutputFile.exists()) {
            await laneAOutputFile.delete();
          }
        } catch (_) {}
      }
      if (laneASidecarFile != null) {
        try {
          if (await laneASidecarFile.exists()) {
            await laneASidecarFile.delete();
          }
        } catch (_) {}
        try {
          final vgtmp = File('${laneASidecarFile.path}.vgtmp');
          if (await vgtmp.exists()) await vgtmp.delete();
          final vgroitmp = File('${laneASidecarFile.path}.vgroitmp');
          if (await vgroitmp.exists()) await vgroitmp.delete();
        } catch (_) {}
      }
      if (laneBOutputFile != null) {
        try {
          if (await laneBOutputFile.exists()) {
            await laneBOutputFile.delete();
          }
        } catch (_) {}
      }
      if (laneBSidecarFile != null) {
        try {
          if (await laneBSidecarFile.exists()) {
            await laneBSidecarFile.delete();
          }
        } catch (_) {}
        try {
          final vgtmp = File('${laneBSidecarFile.path}.vgtmp');
          if (await vgtmp.exists()) await vgtmp.delete();
          final vgroitmp = File('${laneBSidecarFile.path}.vgroitmp');
          if (await vgroitmp.exists()) await vgroitmp.delete();
        } catch (_) {}
      }
      if (laneCSentinelVideoFile != null) {
        try {
          if (await laneCSentinelVideoFile.exists()) {
            await laneCSentinelVideoFile.delete();
          }
        } catch (_) {}
      }
      if (laneCSentinelSidecarFile != null) {
        try {
          if (await laneCSentinelSidecarFile.exists()) {
            await laneCSentinelSidecarFile.delete();
          }
        } catch (_) {}
      }
    }

    // ── Build and Print Aggregate JSON and Verdict ─────────────────────────
    final allPass =
        laneAPass && laneBPass && laneCPass && (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'AndroidExportUnitDROI',
      'target': 'android_physical',
      'pass': allPass,
      'lanes': <String, dynamic>{
        'fullDirectCopy': laneAResults ?? {'pass': false, 'error': 'not run'},
        'trimmedMixdown': laneBResults ?? {'pass': false, 'error': 'not run'},
        'unsupportedScalingPreservesOutput':
            laneCResults ?? {'pass': false, 'error': 'not run'},
      },
      'openQuestions': const <String>[],
      'nonClaims': const <String>[
        'no source ROI mapping',
        'no ROI model parse',
        'no ImageOptimizer',
        'no slideshow',
        'no transitions/overlays/spatial transforms',
        'no ConnectsApp UI wiring',
      ],
      'error': topLevelError,
    };

    print('ANDROID_EXPORT_UNIT_D_ROI_SMOKE_JSON:${jsonEncode(payload)}');
    print(
      allPass
          ? 'ANDROID_EXPORT_UNIT_D_ROI_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_EXPORT_UNIT_D_ROI_PHYSICAL_SMOKE_FAIL',
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
