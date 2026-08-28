// android_roi_explicit_sidecar_unit_o_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit O: Android Explicit Source ROI Sidecar Physical Smoke
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

String sidecarPathForVideoPath(String videoPath) {
  final lastSeparator = videoPath.lastIndexOf('/');
  final lastDot = videoPath.lastIndexOf('.');
  if (lastDot <= lastSeparator) {
    return '$videoPath.roi.json';
  }
  return '${videoPath.substring(0, lastDot)}.roi.json';
}

void main() {
  runApp(const AndroidRoiExplicitSidecarUnitOPhysicalSmokeApp());
}

class AndroidRoiExplicitSidecarUnitOPhysicalSmokeApp extends StatefulWidget {
  const AndroidRoiExplicitSidecarUnitOPhysicalSmokeApp({super.key});

  @override
  State<AndroidRoiExplicitSidecarUnitOPhysicalSmokeApp> createState() =>
      _AndroidRoiExplicitSidecarUnitOPhysicalSmokeAppState();
}

class _AndroidRoiExplicitSidecarUnitOPhysicalSmokeAppState
    extends State<AndroidRoiExplicitSidecarUnitOPhysicalSmokeApp> {
  String _status =
      'Initializing Android Explicit Source ROI Sidecar Physical Smoke (Unit O)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 120), () {
      print('ANDROID_ROI_EXPLICIT_UNIT_O: TIMEOUT (120s exceeded)');
      print('ANDROID_ROI_EXPLICIT_UNIT_O_PHYSICAL_FAIL');
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
    String coordinateSpace = 'display_source_normalized',
  }) => VGROISidecar(
    version: 1,
    sourceType: 'app_recorded',
    platform: 'android',
    coordinateSpace: coordinateSpace,
    recordingSessionId: 'source-session-unit-o',
    videoIdentity: VGROIIdentity(
      durationMs: durationMs,
      width: displayWidth,
      height: displayHeight,
    ),
    coverage: VGROICoverage(coveragePercent: 1.0, missingIntervals: const []),
    samples: samples,
    finalized: true,
  );

  Future<void> _runSmoke() async {
    print('ANDROID_ROI_EXPLICIT_UNIT_O: START');
    final runId = 'unit_o_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? rawClipAssetFile;

    // Lane 1 files (Single clip with explicit non-adjacent sidecar)
    Directory? lane1ExplicitDir;
    File? lane1SourceFile;
    File? lane1ExplicitSidecarFile;
    File? lane1OutputFile;
    File? lane1SidecarFile;

    // Lane 2 files (Multi-clip with distinct explicit sidecars and timeline offsets)
    Directory? lane2ExplicitDir;
    File? lane2C1SourceFile, lane2C1ExplicitSidecarFile;
    File? lane2C2SourceFile, lane2C2ExplicitSidecarFile;
    File? lane2OutputFile, lane2SidecarFile;

    // Lane 3 files (Fail-closed: explicit non-existent path with adjacent valid sidecar present)
    File? lane3SourceFile, lane3AdjacentSidecarFile;
    File? lane3OutputFile, lane3SidecarFile;

    var lane1Pass = false, lane2Pass = false, lane3Pass = false;
    var lane1Map = <String, dynamic>{};
    var lane2Map = <String, dynamic>{};
    var lane3Map = <String, dynamic>{};

    String? topLevelError;

    try {
      // ── Copy Asset Fixture to System Temp ─────────────────────────────────
      print('ANDROID_ROI_EXPLICIT_UNIT_O: Loading clip_B.mov fixture...');
      final clipByteData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final rawBytes = clipByteData.buffer.asUint8List(
        clipByteData.offsetInBytes,
        clipByteData.lengthInBytes,
      );

      rawClipAssetFile = File('${tempDir.path}/${runId}_asset_clip_B.mov');
      await rawClipAssetFile.writeAsBytes(rawBytes, flush: true);

      final sourceMediaInfo = await VanguardMediaPreparer.inspectMedia(
        rawClipAssetFile.path,
      );
      if (sourceMediaInfo == null || !sourceMediaInfo.hasVideo) {
        throw Exception(
          'Failed to inspect source fixture clip_B.mov: info=$sourceMediaInfo',
        );
      }

      final sourceDisplayWidth = sourceMediaInfo.displayWidth > 0
          ? sourceMediaInfo.displayWidth
          : sourceMediaInfo.width;
      final sourceDisplayHeight = sourceMediaInfo.displayHeight > 0
          ? sourceMediaInfo.displayHeight
          : sourceMediaInfo.height;
      final sourceDurationMs = (sourceMediaInfo.durationSeconds * 1000).toInt();

      print(
        'ANDROID_ROI_EXPLICIT_UNIT_O: Source fixture inspected: '
        '${sourceMediaInfo.width}x${sourceMediaInfo.height} encoded, '
        '${sourceDisplayWidth}x$sourceDisplayHeight display, '
        'duration=${sourceMediaInfo.durationSeconds}s ($sourceDurationMs ms)',
      );

      // ── LANE 1: Single Clip with Explicit Non-Adjacent Sidecar ────────────
      print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE1: START');
      final lane1SourcePath = '${tempDir.path}/${runId}_l1_source.mov';
      final lane1AdjacentSidecarPath = sidecarPathForVideoPath(lane1SourcePath);
      lane1ExplicitDir = Directory('${tempDir.path}/${runId}_l1_sidecars')
        ..createSync(recursive: true);
      final lane1ExplicitSidecarPath =
          '${lane1ExplicitDir.path}/l1_explicit.roi.json';
      final lane1OutputPath = '${tempDir.path}/${runId}_l1_out.mp4';
      final lane1ExpectedSidecarPath = sidecarPathForVideoPath(lane1OutputPath);

      lane1SourceFile = File(lane1SourcePath);
      lane1ExplicitSidecarFile = File(lane1ExplicitSidecarPath);
      lane1OutputFile = File(lane1OutputPath);
      lane1SidecarFile = File(lane1ExpectedSidecarPath);

      final lane1SidecarRoiTempFile = File(
        '$lane1ExpectedSidecarPath.vgroitmp',
      );

      try {
        await lane1SourceFile.writeAsBytes(rawBytes, flush: true);

        // Ensure NO adjacent sidecar exists
        final adjacentFile = File(lane1AdjacentSidecarPath);
        if (await adjacentFile.exists()) {
          await adjacentFile.delete();
        }

        final sample1 = VGROISample(
          timestampMs: 1000,
          framePtsMs: 1000,
          recordingRelativeMs: 1000,
          box: VGROIBox(x: 0.25, y: 0.25, w: 0.35, h: 0.35),
          quality: 'detected',
          confidence: 0.95,
        );
        final lane1SourceSidecar = _makeSourceSidecar(
          displayWidth: sourceDisplayWidth,
          displayHeight: sourceDisplayHeight,
          durationMs: sourceDurationMs,
          samples: [sample1],
        );
        await lane1ExplicitSidecarFile.writeAsString(
          jsonEncode(lane1SourceSidecar.toJson()),
          flush: true,
        );

        final clip1 = VGClipDescriptor(
          id: 'l1_clip1',
          mediaKind: VGMediaKind.video,
          sourcePath: lane1SourcePath,
          sourceRoiSidecarPath: lane1ExplicitSidecarPath,
          durationSeconds: 5.5,
          trimStartSeconds: 0.5,
          trimEndSeconds: 2.5, // 2000ms output duration
          startTimeSeconds: 0.0,
        );

        final draft1 = VGEditorDraft(
          id: 'unit_o_draft_lane1',
          clips: [clip1],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(width: 720, height: 1280),
        );

        final derivedDraft1 = draft1
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final request1 = VGEditorExportRequest(
          outputPath: lane1OutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        final exportResult1 = await VanguardTimelineExporter.exportDraft(
          draft: derivedDraft1,
          request: request1,
        );

        final outExists = await lane1OutputFile.exists();
        final outDiskBytes = outExists ? await lane1OutputFile.length() : 0;
        final sidecarExists = await lane1SidecarFile.exists();

        var sidecarParses = false;
        var coordSpaceValid = false;
        var samplesValid = false;
        var outputDimensionsMatch = false;

        if (sidecarExists) {
          try {
            final rawSidecarJson = await lane1SidecarFile.readAsString();
            final decoded = jsonDecode(rawSidecarJson) as Map<String, dynamic>;
            final parsedSidecar = VGROISidecar.fromJson(decoded);
            sidecarParses = true;
            coordSpaceValid =
                parsedSidecar.coordinateSpace == 'export_output_normalized';

            // Sample at 1000ms trimmed by 500ms = 500ms
            if (parsedSidecar.samples.length == 1 &&
                parsedSidecar.samples[0].timestampMs == 500) {
              samplesValid = true;
            }

            final expWidth = exportResult1.width ?? 720;
            final expHeight = exportResult1.height ?? 1280;
            outputDimensionsMatch =
                (parsedSidecar.videoIdentity.width == expWidth) &&
                (parsedSidecar.videoIdentity.height == expHeight);
          } catch (e) {
            print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE1: Sidecar parse error: $e');
          }
        }

        final sidecarPathMatches =
            exportResult1.exportRoiSidecarPath == lane1ExpectedSidecarPath;
        final sidecarRoiTempExists = await lane1SidecarRoiTempFile.exists();
        final noTempResidue = !sidecarRoiTempExists;

        lane1Pass =
            exportResult1.path.isNotEmpty &&
            outExists &&
            outDiskBytes > 0 &&
            sidecarExists &&
            sidecarPathMatches &&
            sidecarParses &&
            coordSpaceValid &&
            samplesValid &&
            outputDimensionsMatch &&
            noTempResidue;

        lane1Map = <String, dynamic>{
          'pass': lane1Pass,
          'outExists': outExists,
          'outDiskBytes': outDiskBytes,
          'sidecarExists': sidecarExists,
          'sidecarPathMatches': sidecarPathMatches,
          'sidecarParses': sidecarParses,
          'coordSpaceValid': coordSpaceValid,
          'samplesValid': samplesValid,
          'outputDimensionsMatch': outputDimensionsMatch,
          'noTempResidue': noTempResidue,
          'exportResultPath': exportResult1.path,
          'exportRoiSidecarPath': exportResult1.exportRoiSidecarPath,
        };

        print(
          'ANDROID_ROI_EXPLICIT_UNIT_O_LANE1: DONE (pass=$lane1Pass, '
          'sidecarParses=$sidecarParses, coordSpace=$coordSpaceValid, '
          'samplesValid=$samplesValid, dimsMatch=$outputDimensionsMatch, '
          'noTempResidue=$noTempResidue)',
        );
      } catch (e, st) {
        print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE1: ERROR: $e\n$st');
        lane1Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane1Pass = false;
      }

      // ── LANE 2: Multi-Clip with Distinct Explicit Sidecars & Timeline Offsets ───
      print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE2: START');
      final lane2C1Path = '${tempDir.path}/${runId}_l2_c1.mov';
      final lane2C2Path = '${tempDir.path}/${runId}_l2_c2.mov';
      lane2ExplicitDir = Directory('${tempDir.path}/${runId}_l2_sidecars')
        ..createSync(recursive: true);
      final lane2C1ExplicitSidecarPath =
          '${lane2ExplicitDir.path}/l2_c1_explicit.roi.json';
      final lane2C2ExplicitSidecarPath =
          '${lane2ExplicitDir.path}/l2_c2_explicit.roi.json';
      final lane2OutputPath = '${tempDir.path}/${runId}_l2_out.mp4';
      final lane2ExpectedSidecarPath = sidecarPathForVideoPath(lane2OutputPath);

      lane2C1SourceFile = File(lane2C1Path);
      lane2C1ExplicitSidecarFile = File(lane2C1ExplicitSidecarPath);
      lane2C2SourceFile = File(lane2C2Path);
      lane2C2ExplicitSidecarFile = File(lane2C2ExplicitSidecarPath);
      lane2OutputFile = File(lane2OutputPath);
      lane2SidecarFile = File(lane2ExpectedSidecarPath);

      final lane2SidecarRoiTempFile = File(
        '$lane2ExpectedSidecarPath.vgroitmp',
      );

      try {
        await lane2C1SourceFile.writeAsBytes(rawBytes, flush: true);
        await lane2C2SourceFile.writeAsBytes(rawBytes, flush: true);

        // Ensure NO adjacent sidecars exist
        final adj1 = File(sidecarPathForVideoPath(lane2C1Path));
        if (await adj1.exists()) await adj1.delete();
        final adj2 = File(sidecarPathForVideoPath(lane2C2Path));
        if (await adj2.exists()) await adj2.delete();

        // Clip 1 explicit sidecar: sample at 500ms
        final sample2C1 = VGROISample(
          timestampMs: 500,
          framePtsMs: 500,
          recordingRelativeMs: 500,
          box: VGROIBox(x: 0.20, y: 0.20, w: 0.30, h: 0.30),
          quality: 'detected',
        );
        final sidecar2C1 = _makeSourceSidecar(
          displayWidth: sourceDisplayWidth,
          displayHeight: sourceDisplayHeight,
          durationMs: sourceDurationMs,
          samples: [sample2C1],
        );
        await lane2C1ExplicitSidecarFile.writeAsString(
          jsonEncode(sidecar2C1.toJson()),
          flush: true,
        );

        // Clip 2 explicit sidecar: sample at 1200ms
        final sample2C2 = VGROISample(
          timestampMs: 1200,
          framePtsMs: 1200,
          recordingRelativeMs: 1200,
          box: VGROIBox(x: 0.30, y: 0.30, w: 0.40, h: 0.40),
          quality: 'detected',
        );
        final sidecar2C2 = _makeSourceSidecar(
          displayWidth: sourceDisplayWidth,
          displayHeight: sourceDisplayHeight,
          durationMs: sourceDurationMs,
          samples: [sample2C2],
        );
        await lane2C2ExplicitSidecarFile.writeAsString(
          jsonEncode(sidecar2C2.toJson()),
          flush: true,
        );

        final clip2C1 = VGClipDescriptor(
          id: 'lane2_c1',
          mediaKind: VGMediaKind.video,
          sourcePath: lane2C1Path,
          sourceRoiSidecarPath: lane2C1ExplicitSidecarPath,
          durationSeconds: 5.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0, // 2000ms duration
          startTimeSeconds: 0.0,
        );
        final clip2C2 = VGClipDescriptor(
          id: 'lane2_c2',
          mediaKind: VGMediaKind.video,
          sourcePath: lane2C2Path,
          sourceRoiSidecarPath: lane2C2ExplicitSidecarPath,
          durationSeconds: 5.5,
          trimStartSeconds: 0.2,
          trimEndSeconds: 2.2, // 2000ms duration
          startTimeSeconds: 2.0,
        );

        final draft2 = VGEditorDraft(
          id: 'unit_o_draft_lane2',
          clips: [clip2C1, clip2C2],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(width: 720, height: 1280),
        );

        final derivedDraft2 = draft2
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final request2 = VGEditorExportRequest(
          outputPath: lane2OutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        final exportResult2 = await VanguardTimelineExporter.exportDraft(
          draft: derivedDraft2,
          request: request2,
        );

        final outExists = await lane2OutputFile.exists();
        final outDiskBytes = outExists ? await lane2OutputFile.length() : 0;
        final sidecarExists = await lane2SidecarFile.exists();

        var sidecarParses = false;
        var coordSpaceValid = false;
        var samplesValid = false;
        var outputDimensionsMatch = false;

        if (sidecarExists) {
          try {
            final rawSidecarJson = await lane2SidecarFile.readAsString();
            final decoded = jsonDecode(rawSidecarJson) as Map<String, dynamic>;
            final parsedSidecar = VGROISidecar.fromJson(decoded);
            sidecarParses = true;
            coordSpaceValid =
                parsedSidecar.coordinateSpace == 'export_output_normalized';

            // Sample 1: 500ms
            // Sample 2: (1200 - 200) + 2000 (clip 1) = 3000ms
            if (parsedSidecar.samples.length == 2 &&
                parsedSidecar.samples[0].timestampMs == 500 &&
                parsedSidecar.samples[1].timestampMs == 3000) {
              samplesValid = true;
            }

            final expWidth = exportResult2.width ?? 720;
            final expHeight = exportResult2.height ?? 1280;
            outputDimensionsMatch =
                (parsedSidecar.videoIdentity.width == expWidth) &&
                (parsedSidecar.videoIdentity.height == expHeight);
          } catch (e) {
            print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE2: Sidecar parse error: $e');
          }
        }

        final sidecarPathMatches =
            exportResult2.exportRoiSidecarPath == lane2ExpectedSidecarPath;
        final sidecarRoiTempExists = await lane2SidecarRoiTempFile.exists();
        final noTempResidue = !sidecarRoiTempExists;

        lane2Pass =
            exportResult2.path.isNotEmpty &&
            outExists &&
            outDiskBytes > 0 &&
            sidecarExists &&
            sidecarPathMatches &&
            sidecarParses &&
            coordSpaceValid &&
            samplesValid &&
            outputDimensionsMatch &&
            noTempResidue;

        lane2Map = <String, dynamic>{
          'pass': lane2Pass,
          'outExists': outExists,
          'outDiskBytes': outDiskBytes,
          'sidecarExists': sidecarExists,
          'sidecarParses': sidecarParses,
          'coordSpaceValid': coordSpaceValid,
          'samplesValid': samplesValid,
          'outputDimensionsMatch': outputDimensionsMatch,
          'noTempResidue': noTempResidue,
          'exportResultPath': exportResult2.path,
          'exportRoiSidecarPath': exportResult2.exportRoiSidecarPath,
        };

        print(
          'ANDROID_ROI_EXPLICIT_UNIT_O_LANE2: DONE (pass=$lane2Pass, '
          'sidecarParses=$sidecarParses, coordSpace=$coordSpaceValid, '
          'samplesValid=$samplesValid, dimsMatch=$outputDimensionsMatch, '
          'noTempResidue=$noTempResidue)',
        );
      } catch (e, st) {
        print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE2: ERROR: $e\n$st');
        lane2Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane2Pass = false;
      }

      // ── LANE 3: Fail-Closed Isolation (Explicit Non-Existent Path) ─────────
      print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE3: START');
      final lane3SourcePath = '${tempDir.path}/${runId}_l3_source.mov';
      final lane3AdjacentSidecarPath = sidecarPathForVideoPath(lane3SourcePath);
      final lane3NonExistentExplicitPath =
          '${tempDir.path}/${runId}_non_existent_explicit.roi.json';
      final lane3OutputPath = '${tempDir.path}/${runId}_l3_out.mp4';
      final lane3ExpectedSidecarPath = sidecarPathForVideoPath(lane3OutputPath);

      lane3SourceFile = File(lane3SourcePath);
      lane3AdjacentSidecarFile = File(lane3AdjacentSidecarPath);
      lane3OutputFile = File(lane3OutputPath);
      lane3SidecarFile = File(lane3ExpectedSidecarPath);

      final lane3SidecarRoiTempFile = File(
        '$lane3ExpectedSidecarPath.vgroitmp',
      );

      try {
        await lane3SourceFile.writeAsBytes(rawBytes, flush: true);

        // Write a VALID adjacent sidecar
        final sample3 = VGROISample(
          timestampMs: 500,
          framePtsMs: 500,
          recordingRelativeMs: 500,
          box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
          quality: 'detected',
        );
        final adjacentSidecar = _makeSourceSidecar(
          displayWidth: sourceDisplayWidth,
          displayHeight: sourceDisplayHeight,
          durationMs: sourceDurationMs,
          samples: [sample3],
        );
        await lane3AdjacentSidecarFile.writeAsString(
          jsonEncode(adjacentSidecar.toJson()),
          flush: true,
        );

        // Clip specifies an explicit path that does NOT exist
        final clip3 = VGClipDescriptor(
          id: 'l3_clip1',
          mediaKind: VGMediaKind.video,
          sourcePath: lane3SourcePath,
          sourceRoiSidecarPath: lane3NonExistentExplicitPath,
          durationSeconds: 5.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
          startTimeSeconds: 0.0,
        );

        final draft3 = VGEditorDraft(
          id: 'unit_o_draft_lane3',
          clips: [clip3],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(width: 720, height: 1280),
        );

        final derivedDraft3 = draft3
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final request3 = VGEditorExportRequest(
          outputPath: lane3OutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        final exportResult3 = await VanguardTimelineExporter.exportDraft(
          draft: derivedDraft3,
          request: request3,
        );

        final outExists = await lane3OutputFile.exists();
        final outDiskBytes = outExists ? await lane3OutputFile.length() : 0;
        final sidecarExists = await lane3SidecarFile.exists();

        var sidecarParsesEmpty = false;
        if (sidecarExists) {
          try {
            final raw = await lane3SidecarFile.readAsString();
            final decoded = jsonDecode(raw) as Map<String, dynamic>;
            final sidecar = VGROISidecar.fromJson(decoded);
            // Must NOT have picked up the sample from the adjacent sidecar
            sidecarParsesEmpty =
                sidecar.coordinateSpace == 'export_output_normalized' &&
                sidecar.samples.isEmpty;
          } catch (e) {
            print(
              'ANDROID_ROI_EXPLICIT_UNIT_O_LANE3: Fallback sidecar parse error: $e',
            );
          }
        }

        final sidecarRoiTempExists = await lane3SidecarRoiTempFile.exists();
        final noTempResidue = !sidecarRoiTempExists;

        lane3Pass =
            exportResult3.path.isNotEmpty &&
            outExists &&
            outDiskBytes > 0 &&
            sidecarExists &&
            sidecarParsesEmpty &&
            noTempResidue;

        lane3Map = <String, dynamic>{
          'pass': lane3Pass,
          'outExists': outExists,
          'outDiskBytes': outDiskBytes,
          'sidecarExists': sidecarExists,
          'sidecarParsesEmpty': sidecarParsesEmpty,
          'noTempResidue': noTempResidue,
          'exportResultPath': exportResult3.path,
          'exportRoiSidecarPath': exportResult3.exportRoiSidecarPath,
        };

        print(
          'ANDROID_ROI_EXPLICIT_UNIT_O_LANE3: DONE (pass=$lane3Pass, '
          'sidecarParsesEmpty=$sidecarParsesEmpty, noTempResidue=$noTempResidue)',
        );
      } catch (e, st) {
        print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE3: ERROR: $e\n$st');
        lane3Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane3Pass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_ROI_EXPLICIT_UNIT_O: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // ── Clean up harness-owned temp files ─────────────────────────────────
      Future<void> clean(File? f, [bool isBase = false]) async {
        if (f == null) return;
        try {
          if (await f.exists()) await f.delete();
          if (isBase) {
            for (final ext in ['.vgptmp', '.vgtmp', '.vgroitmp']) {
              final tf = File('${f.path}$ext');
              if (await tf.exists()) await tf.delete();
            }
          }
        } catch (_) {}
      }

      for (final f in [
        rawClipAssetFile,
        lane1SourceFile,
        lane1ExplicitSidecarFile,
        lane2C1SourceFile,
        lane2C1ExplicitSidecarFile,
        lane2C2SourceFile,
        lane2C2ExplicitSidecarFile,
        lane3SourceFile,
        lane3AdjacentSidecarFile,
      ]) {
        await clean(f);
      }
      for (final f in [
        lane1OutputFile,
        lane1SidecarFile,
        lane2OutputFile,
        lane2SidecarFile,
        lane3OutputFile,
        lane3SidecarFile,
      ]) {
        await clean(f, true);
      }
      for (final d in [lane1ExplicitDir, lane2ExplicitDir]) {
        if (d != null) {
          try {
            if (await d.exists()) {
              await d.delete(recursive: true);
            }
          } catch (_) {}
        }
      }
    }

    print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE1_PASS: $lane1Pass');
    print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE2_PASS: $lane2Pass');
    print('ANDROID_ROI_EXPLICIT_UNIT_O_LANE3_PASS: $lane3Pass');

    final allPass =
        lane1Pass && lane2Pass && lane3Pass && (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase5UnitO',
      'target': 'android_roi_explicit_sidecar_unit_o_physical_smoke',
      'pass': allPass,
      'lanes': <String, dynamic>{
        'lane1_single_clip_explicit_sidecar': lane1Map,
        'lane2_multiclip_explicit_sidecars_and_timeline_offsets': lane2Map,
        'lane3_fail_closed_isolation': lane3Map,
      },
      'error': topLevelError,
    };

    print('ANDROID_ROI_EXPLICIT_UNIT_O_JSON:${jsonEncode(payload)}');
    print(
      allPass
          ? 'ANDROID_ROI_EXPLICIT_UNIT_O_PHYSICAL_PASS'
          : 'ANDROID_ROI_EXPLICIT_UNIT_O_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass ? 'PASS' : 'FAIL';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
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
