// Vanguard Media Engine — Phase 5-Unit N: Android Multi-Clip ROI Sidecar Physical Smoke
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
  runApp(const AndroidRoiExportMulticlipMappingPhysicalSmokeApp());
}

class AndroidRoiExportMulticlipMappingPhysicalSmokeApp extends StatefulWidget {
  const AndroidRoiExportMulticlipMappingPhysicalSmokeApp({super.key});

  @override
  State<AndroidRoiExportMulticlipMappingPhysicalSmokeApp> createState() =>
      _AndroidRoiExportMulticlipMappingPhysicalSmokeAppState();
}

class _AndroidRoiExportMulticlipMappingPhysicalSmokeAppState
    extends State<AndroidRoiExportMulticlipMappingPhysicalSmokeApp> {
  String _status =
      'Initializing Android Hard-Cut Multi-Clip ROI Export Mapping Physical Smoke (Unit N)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 120), () {
      print('ANDROID_ROI_MULTICLIP_UNIT_N: TIMEOUT (120s exceeded)');
      print('ANDROID_ROI_MULTICLIP_UNIT_N_PHYSICAL_FAIL');
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
    recordingSessionId: 'source-session-unit-n',
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
    print('ANDROID_ROI_MULTICLIP_UNIT_N: START');
    final runId = 'unit_n_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? rawClipAssetFile;

    // Lane 1 files (two valid clips)
    File? lane1C1SourceFile, lane1C1SourceSidecarFile;
    File? lane1C2SourceFile, lane1C2SourceSidecarFile;
    File? lane1OutputFile, lane1SidecarFile;
    // Lane 2 files (three clips: c1 valid, c2 malformed, c3 valid)
    File? lane2C1SourceFile, lane2C1SourceSidecarFile;
    File? lane2C2SourceFile, lane2C2SourceSidecarFile;
    File? lane2C3SourceFile, lane2C3SourceSidecarFile;
    File? lane2OutputFile, lane2SidecarFile;
    // Lane 3 files (two clips: c1 missing sidecar, c2 malformed sidecar)
    File? lane3C1SourceFile, lane3C2SourceFile, lane3C2SourceSidecarFile;
    File? lane3OutputFile, lane3SidecarFile;

    var lane1Pass = false, lane2Pass = false, lane3Pass = false;
    var lane1Map = <String, dynamic>{};
    var lane2Map = <String, dynamic>{};
    var lane3Map = <String, dynamic>{};

    String? topLevelError;

    try {
      // ── Copy Asset Fixture to System Temp ─────────────────────────────────
      print('ANDROID_ROI_MULTICLIP_UNIT_N: Loading clip_B.mov fixture...');
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
        'ANDROID_ROI_MULTICLIP_UNIT_N: Source fixture inspected: '
        '${sourceMediaInfo.width}x${sourceMediaInfo.height} encoded, '
        '${sourceDisplayWidth}x$sourceDisplayHeight display, '
        'duration=${sourceMediaInfo.durationSeconds}s ($sourceDurationMs ms)',
      );

      // ── LANE 1: Primary - Real Multi-Clip Hard-Cut Timeline Export ────────
      print('ANDROID_ROI_MULTICLIP_UNIT_N_LANE1: START');
      final lane1C1Path = '${tempDir.path}/${runId}_l1_c1.mov';
      final lane1C1SidecarPath = sidecarPathForVideoPath(lane1C1Path);
      final lane1C2Path = '${tempDir.path}/${runId}_l1_c2.mov';
      final lane1C2SidecarPath = sidecarPathForVideoPath(lane1C2Path);
      final lane1OutputPath = '${tempDir.path}/${runId}_l1_out.mp4';
      final lane1ExpectedSidecarPath = sidecarPathForVideoPath(lane1OutputPath);
      lane1C1SourceFile = File(lane1C1Path);
      lane1C1SourceSidecarFile = File(lane1C1SidecarPath);
      lane1C2SourceFile = File(lane1C2Path);
      lane1C2SourceSidecarFile = File(lane1C2SidecarPath);
      lane1OutputFile = File(lane1OutputPath);
      lane1SidecarFile = File(lane1ExpectedSidecarPath);
      final lane1SidecarTempFile = File('$lane1ExpectedSidecarPath.vgtmp');
      final lane1SidecarRoiTempFile = File(
        '$lane1ExpectedSidecarPath.vgroitmp',
      );
      final lane1OutputTempFile = File('$lane1OutputPath.vgtmp');
      final lane1OutputPassthroughTempFile = File('$lane1OutputPath.vgptmp');

      try {
        await lane1C1SourceFile.writeAsBytes(rawBytes, flush: true);
        await lane1C2SourceFile.writeAsBytes(rawBytes, flush: true);

        // Clip 1: sample at 500ms
        final sample1 = VGROISample(
          timestampMs: 500,
          framePtsMs: 500,
          recordingRelativeMs: 500,
          box: VGROIBox(x: 0.20, y: 0.20, w: 0.30, h: 0.30),
          quality: 'detected',
          confidence: 0.95,
          paddingPolicy: 'normal',
        );
        final sidecar1 = _makeSourceSidecar(
          displayWidth: sourceDisplayWidth,
          displayHeight: sourceDisplayHeight,
          durationMs: sourceDurationMs,
          samples: [sample1],
        );
        await lane1C1SourceSidecarFile.writeAsString(
          jsonEncode(sidecar1.toJson()),
          flush: true,
        );

        // Clip 2: sample at 1500ms (trimmed by 0.5s to 1000ms relative to clip2)
        final sample2 = VGROISample(
          timestampMs: 1500,
          framePtsMs: 1500,
          recordingRelativeMs: 1500,
          box: VGROIBox(x: 0.30, y: 0.30, w: 0.40, h: 0.40),
          quality: 'detected',
          confidence: 0.90,
          paddingPolicy: 'normal',
        );
        final sidecar2 = _makeSourceSidecar(
          displayWidth: sourceDisplayWidth,
          displayHeight: sourceDisplayHeight,
          durationMs: sourceDurationMs,
          samples: [sample2],
        );
        await lane1C2SourceSidecarFile.writeAsString(
          jsonEncode(sidecar2.toJson()),
          flush: true,
        );

        final clip1 = VGClipDescriptor(
          id: 'lane1_clip1',
          mediaKind: VGMediaKind.video,
          sourcePath: lane1C1Path,
          durationSeconds: 5.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0, // 2000ms output duration
          startTimeSeconds: 0.0,
        );
        final clip2 = VGClipDescriptor(
          id: 'lane1_clip2',
          mediaKind: VGMediaKind.video,
          sourcePath: lane1C2Path,
          durationSeconds: 5.5,
          trimStartSeconds: 0.5,
          trimEndSeconds: 2.5, // 2000ms output duration
          startTimeSeconds: 2.0,
        );

        final draft = VGEditorDraft(
          id: 'unit_n_draft_lane1',
          clips: [clip1, clip2],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(width: 720, height: 1280),
        );

        final derivedDraft = draft
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final request = VGEditorExportRequest(
          outputPath: lane1OutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        final exportResult = await VanguardTimelineExporter.exportDraft(
          draft: derivedDraft,
          request: request,
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

            // Sample 1: at 500ms
            // Sample 2: (1500 - 500) + 2000 = 3000ms (> clip 1 duration 2000ms)
            if (parsedSidecar.samples.length == 2 &&
                parsedSidecar.samples[0].timestampMs == 500 &&
                parsedSidecar.samples[1].timestampMs == 3000 &&
                parsedSidecar.samples[1].timestampMs > 2000) {
              samplesValid = true;
            }

            final expWidth = exportResult.width ?? 720;
            final expHeight = exportResult.height ?? 1280;
            outputDimensionsMatch =
                (parsedSidecar.videoIdentity.width == expWidth) &&
                (parsedSidecar.videoIdentity.height == expHeight);
          } catch (e) {
            print(
              'ANDROID_ROI_MULTICLIP_UNIT_N_LANE1: Sidecar parse error: $e',
            );
          }
        }

        final sidecarPathMatches =
            exportResult.exportRoiSidecarPath == lane1ExpectedSidecarPath;

        final sidecarTempExists = await lane1SidecarTempFile.exists();
        final sidecarRoiTempExists = await lane1SidecarRoiTempFile.exists();
        final outTempExists = await lane1OutputTempFile.exists();
        final outPassthroughTempExists = await lane1OutputPassthroughTempFile
            .exists();
        final noTempResidue =
            !sidecarTempExists &&
            !sidecarRoiTempExists &&
            !outTempExists &&
            !outPassthroughTempExists;

        lane1Pass =
            exportResult.path.isNotEmpty &&
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
          'exportResultPath': exportResult.path,
          'exportRoiSidecarPath': exportResult.exportRoiSidecarPath,
        };

        print(
          'ANDROID_ROI_MULTICLIP_UNIT_N_LANE1: DONE (pass=$lane1Pass, '
          'sidecarParses=$sidecarParses, coordSpace=$coordSpaceValid, '
          'samplesValid=$samplesValid, dimsMatch=$outputDimensionsMatch, '
          'noTempResidue=$noTempResidue)',
        );
      } catch (e, st) {
        print('ANDROID_ROI_MULTICLIP_UNIT_N_LANE1: ERROR: $e\n$st');
        lane1Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane1Pass = false;
      }

      // ── LANE 2: Partial - Three Clips (C1 valid, C2 malformed, C3 valid) ──
      print('ANDROID_ROI_MULTICLIP_UNIT_N_LANE2: START');
      final lane2C1Path = '${tempDir.path}/${runId}_l2_c1.mov';
      final lane2C1SidecarPath = sidecarPathForVideoPath(lane2C1Path);
      final lane2C2Path = '${tempDir.path}/${runId}_l2_c2.mov';
      final lane2C2SidecarPath = sidecarPathForVideoPath(lane2C2Path);
      final lane2C3Path = '${tempDir.path}/${runId}_l2_c3.mov';
      final lane2C3SidecarPath = sidecarPathForVideoPath(lane2C3Path);
      final lane2OutputPath = '${tempDir.path}/${runId}_l2_out.mp4';
      final lane2ExpectedSidecarPath = sidecarPathForVideoPath(lane2OutputPath);
      lane2C1SourceFile = File(lane2C1Path);
      lane2C1SourceSidecarFile = File(lane2C1SidecarPath);
      lane2C2SourceFile = File(lane2C2Path);
      lane2C2SourceSidecarFile = File(lane2C2SidecarPath);
      lane2C3SourceFile = File(lane2C3Path);
      lane2C3SourceSidecarFile = File(lane2C3SidecarPath);
      lane2OutputFile = File(lane2OutputPath);
      lane2SidecarFile = File(lane2ExpectedSidecarPath);
      final lane2SidecarTempFile = File('$lane2ExpectedSidecarPath.vgtmp');
      final lane2SidecarRoiTempFile = File(
        '$lane2ExpectedSidecarPath.vgroitmp',
      );
      final lane2OutputTempFile = File('$lane2OutputPath.vgtmp');
      final lane2OutputPassthroughTempFile = File('$lane2OutputPath.vgptmp');

      try {
        await lane2C1SourceFile.writeAsBytes(rawBytes, flush: true);
        await lane2C2SourceFile.writeAsBytes(rawBytes, flush: true);
        await lane2C3SourceFile.writeAsBytes(rawBytes, flush: true);

        // Clip 1: valid sidecar with sample at 500ms
        final sample2C1 = VGROISample(
          timestampMs: 500,
          framePtsMs: 500,
          recordingRelativeMs: 500,
          box: VGROIBox(x: 0.15, y: 0.15, w: 0.25, h: 0.25),
          quality: 'detected',
        );
        final sidecar2C1 = _makeSourceSidecar(
          displayWidth: sourceDisplayWidth,
          displayHeight: sourceDisplayHeight,
          durationMs: sourceDurationMs,
          samples: [sample2C1],
        );
        await lane2C1SourceSidecarFile.writeAsString(
          jsonEncode(sidecar2C1.toJson()),
          flush: true,
        );

        // Clip 2: malformed sidecar
        await lane2C2SourceSidecarFile.writeAsString(
          '{"invalid_json": true, broken_sidecar_content',
          flush: true,
        );

        // Clip 3: valid sidecar with sample at 1000ms (trimmed by 0.5s to 500ms relative)
        final sample2C3 = VGROISample(
          timestampMs: 1000,
          framePtsMs: 1000,
          recordingRelativeMs: 1000,
          box: VGROIBox(x: 0.35, y: 0.35, w: 0.30, h: 0.30),
          quality: 'detected',
        );
        final sidecar2C3 = _makeSourceSidecar(
          displayWidth: sourceDisplayWidth,
          displayHeight: sourceDisplayHeight,
          durationMs: sourceDurationMs,
          samples: [sample2C3],
        );
        await lane2C3SourceSidecarFile.writeAsString(
          jsonEncode(sidecar2C3.toJson()),
          flush: true,
        );

        final clip2C1 = VGClipDescriptor(
          id: 'lane2_c1',
          mediaKind: VGMediaKind.video,
          sourcePath: lane2C1Path,
          durationSeconds: 5.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.5, // 1500ms output duration
          startTimeSeconds: 0.0,
        );
        final clip2C2 = VGClipDescriptor(
          id: 'lane2_c2',
          mediaKind: VGMediaKind.video,
          sourcePath: lane2C2Path,
          durationSeconds: 5.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0, // 1000ms output duration
          startTimeSeconds: 1.5,
        );
        final clip2C3 = VGClipDescriptor(
          id: 'lane2_c3',
          mediaKind: VGMediaKind.video,
          sourcePath: lane2C3Path,
          durationSeconds: 5.5,
          trimStartSeconds: 0.5,
          trimEndSeconds: 2.0, // 1500ms output duration
          startTimeSeconds: 2.5,
        );

        final draft2 = VGEditorDraft(
          id: 'unit_n_draft_lane2',
          clips: [clip2C1, clip2C2, clip2C3],
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

            // Clip 1 sample: 500ms
            // Clip 3 sample: (1000 - 500) + 1500 (clip1) + 1000 (clip2) = 3000ms
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
            print(
              'ANDROID_ROI_MULTICLIP_UNIT_N_LANE2: Sidecar parse error: $e',
            );
          }
        }

        final sidecarTempExists = await lane2SidecarTempFile.exists();
        final sidecarRoiTempExists = await lane2SidecarRoiTempFile.exists();
        final outTempExists = await lane2OutputTempFile.exists();
        final outPassthroughTempExists = await lane2OutputPassthroughTempFile
            .exists();
        final noTempResidue =
            !sidecarTempExists &&
            !sidecarRoiTempExists &&
            !outTempExists &&
            !outPassthroughTempExists;

        lane2Pass =
            exportResult2.path.isNotEmpty &&
            outExists &&
            outDiskBytes > 0 &&
            sidecarExists &&
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
          'ANDROID_ROI_MULTICLIP_UNIT_N_LANE2: DONE (pass=$lane2Pass, '
          'sidecarParses=$sidecarParses, coordSpace=$coordSpaceValid, '
          'samplesValid=$samplesValid, dimsMatch=$outputDimensionsMatch, '
          'noTempResidue=$noTempResidue)',
        );
      } catch (e, st) {
        print('ANDROID_ROI_MULTICLIP_UNIT_N_LANE2: ERROR: $e\n$st');
        lane2Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane2Pass = false;
      }

      // ── LANE 3: Fallback - Multi-Clip with No Usable Source Sidecars ───────
      print('ANDROID_ROI_MULTICLIP_UNIT_N_LANE3: START');
      final lane3C1Path = '${tempDir.path}/${runId}_l3_c1.mov';
      final lane3C2Path = '${tempDir.path}/${runId}_l3_c2.mov';
      final lane3C2SidecarPath = sidecarPathForVideoPath(lane3C2Path);
      final lane3OutputPath = '${tempDir.path}/${runId}_l3_out.mp4';
      final lane3ExpectedSidecarPath = sidecarPathForVideoPath(lane3OutputPath);
      lane3C1SourceFile = File(lane3C1Path);
      lane3C2SourceFile = File(lane3C2Path);
      lane3C2SourceSidecarFile = File(lane3C2SidecarPath);
      lane3OutputFile = File(lane3OutputPath);
      lane3SidecarFile = File(lane3ExpectedSidecarPath);
      final lane3SidecarTempFile = File('$lane3ExpectedSidecarPath.vgtmp');
      final lane3SidecarRoiTempFile = File(
        '$lane3ExpectedSidecarPath.vgroitmp',
      );
      final lane3OutputTempFile = File('$lane3OutputPath.vgtmp');
      final lane3OutputPassthroughTempFile = File('$lane3OutputPath.vgptmp');

      try {
        // Clip 1: write video, do NOT write sidecar (missing sidecar)
        await lane3C1SourceFile.writeAsBytes(rawBytes, flush: true);

        // Clip 2: write video, write broken JSON sidecar (malformed sidecar)
        await lane3C2SourceFile.writeAsBytes(rawBytes, flush: true);
        await lane3C2SourceSidecarFile.writeAsString(
          '{"invalid_json": broken',
          flush: true,
        );

        final clip3C1 = VGClipDescriptor(
          id: 'lane3_c1',
          mediaKind: VGMediaKind.video,
          sourcePath: lane3C1Path,
          durationSeconds: 5.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.5,
          startTimeSeconds: 0.0,
        );
        final clip3C2 = VGClipDescriptor(
          id: 'lane3_c2',
          mediaKind: VGMediaKind.video,
          sourcePath: lane3C2Path,
          durationSeconds: 5.5,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.5,
          startTimeSeconds: 1.5,
        );

        final draft3 = VGEditorDraft(
          id: 'unit_n_draft_lane3',
          clips: [clip3C1, clip3C2],
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
            sidecarParsesEmpty =
                sidecar.coordinateSpace == 'export_output_normalized' &&
                sidecar.finalized == true &&
                sidecar.samples.isEmpty &&
                sidecar.platform == 'android';
          } catch (e) {
            print(
              'ANDROID_ROI_MULTICLIP_UNIT_N_LANE3: Fallback sidecar parse error: $e',
            );
          }
        }

        final sidecarTempExists = await lane3SidecarTempFile.exists();
        final sidecarRoiTempExists = await lane3SidecarRoiTempFile.exists();
        final outTempExists = await lane3OutputTempFile.exists();
        final outPassthroughTempExists = await lane3OutputPassthroughTempFile
            .exists();
        final noTempResidue =
            !sidecarTempExists &&
            !sidecarRoiTempExists &&
            !outTempExists &&
            !outPassthroughTempExists;

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
          'ANDROID_ROI_MULTICLIP_UNIT_N_LANE3: DONE (pass=$lane3Pass, '
          'sidecarParsesEmpty=$sidecarParsesEmpty, noTempResidue=$noTempResidue)',
        );
      } catch (e, st) {
        print('ANDROID_ROI_MULTICLIP_UNIT_N_LANE3: ERROR: $e\n$st');
        lane3Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane3Pass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_ROI_MULTICLIP_UNIT_N: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // ── Clean up only harness-owned temp files ────────────────────────────
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
        lane1C1SourceFile,
        lane1C1SourceSidecarFile,
        lane1C2SourceFile,
        lane1C2SourceSidecarFile,
        lane2C1SourceFile,
        lane2C1SourceSidecarFile,
        lane2C2SourceFile,
        lane2C2SourceSidecarFile,
        lane2C3SourceFile,
        lane2C3SourceSidecarFile,
        lane3C1SourceFile,
        lane3C2SourceFile,
        lane3C2SourceSidecarFile,
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
    }

    print('ANDROID_ROI_MULTICLIP_UNIT_N_LANE1_PASS: $lane1Pass');
    print('ANDROID_ROI_MULTICLIP_UNIT_N_LANE2_PASS: $lane2Pass');
    print('ANDROID_ROI_MULTICLIP_UNIT_N_LANE3_PASS: $lane3Pass');

    final allPass =
        lane1Pass && lane2Pass && lane3Pass && (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase5UnitN',
      'target': 'android_roi_export_multiclip_mapping_physical',
      'pass': allPass,
      'lanes': <String, dynamic>{
        'lane1_multiclip_all_valid': lane1Map,
        'lane2_multiclip_partial_valid': lane2Map,
        'lane3_multiclip_fallback_empty': lane3Map,
      },
      'error': topLevelError,
    };

    print('ANDROID_ROI_MULTICLIP_UNIT_N_JSON:${jsonEncode(payload)}');
    print(
      allPass
          ? 'ANDROID_ROI_MULTICLIP_UNIT_N_PHYSICAL_PASS'
          : 'ANDROID_ROI_MULTICLIP_UNIT_N_PHYSICAL_FAIL',
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
