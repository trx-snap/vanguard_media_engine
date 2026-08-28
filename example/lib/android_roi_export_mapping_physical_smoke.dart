// android_roi_export_mapping_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit M
// Android Source ROI Sidecar Ingestion & Export Transform Mapping Parity Physical Smoke Proof.

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
  runApp(const AndroidRoiExportMappingPhysicalSmokeApp());
}

class AndroidRoiExportMappingPhysicalSmokeApp extends StatefulWidget {
  const AndroidRoiExportMappingPhysicalSmokeApp({super.key});

  @override
  State<AndroidRoiExportMappingPhysicalSmokeApp> createState() =>
      _AndroidRoiExportMappingPhysicalSmokeAppState();
}

class _AndroidRoiExportMappingPhysicalSmokeAppState
    extends State<AndroidRoiExportMappingPhysicalSmokeApp> {
  String _status =
      'Initializing Android Source ROI Export Mapping Physical Smoke (Unit M)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 90), () {
      print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M: TIMEOUT (90s exceeded)');
      print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_PHYSICAL_FAIL');
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

  VGROISidecar _makeSourceSidecar({
    required int displayWidth,
    required int displayHeight,
    required int durationMs,
    required List<VGROISample> samples,
    String coordinateSpace = 'display_source_normalized',
  }) {
    return VGROISidecar(
      version: 1,
      sourceType: 'app_recorded',
      platform: 'android',
      coordinateSpace: coordinateSpace,
      recordingSessionId: 'source-session-unit-m',
      videoIdentity: VGROIIdentity(
        durationMs: durationMs,
        width: displayWidth,
        height: displayHeight,
        hash: null,
      ),
      coverage: VGROICoverage(coveragePercent: 1.0, missingIntervals: const []),
      samples: samples,
      finalized: true,
    );
  }

  Future<void> _runSmoke() async {
    print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M: START');
    final runId = 'unit_m_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? rawClipAssetFile;
    File? lane1SourceFile;
    File? lane1SourceSidecarFile;
    File? lane1OutputFile;
    File? lane1SidecarFile;

    File? lane2SourceFile;
    File? lane2SourceSidecarFile;
    File? lane2OutputFile;
    File? lane2SidecarFile;

    File? lane3aSourceFile;
    File? lane3aOutputFile;
    File? lane3aSidecarFile;

    File? lane3bSourceFile;
    File? lane3bSourceSidecarFile;
    File? lane3bOutputFile;
    File? lane3bSidecarFile;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;

    Map<String, dynamic> lane1Map = <String, dynamic>{};
    Map<String, dynamic> lane2Map = <String, dynamic>{};
    Map<String, dynamic> lane3Map = <String, dynamic>{};

    String? topLevelError;

    try {
      // ── Copy Asset Fixture to System Temp ─────────────────────────────────
      print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M: Loading clip_B.mov fixture...');
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
        'ANDROID_ROI_EXPORT_MAPPING_UNIT_M: Source fixture inspected: '
        '${sourceMediaInfo.width}x${sourceMediaInfo.height} encoded, '
        '${sourceDisplayWidth}x$sourceDisplayHeight display, '
        'duration=${sourceMediaInfo.durationSeconds}s ($sourceDurationMs ms)',
      );

      // ── LANE 1: Passthrough with valid source ROI sidecar ─────────────────
      print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE1: START');
      final lane1SourcePath = '${tempDir.path}/${runId}_lane1_source.mov';
      final lane1SourceSidecarPath = sidecarPathForVideoPath(lane1SourcePath);
      final lane1OutputPath = '${tempDir.path}/${runId}_lane1_out.mp4';
      final lane1ExpectedSidecarPath = sidecarPathForVideoPath(lane1OutputPath);

      lane1SourceFile = File(lane1SourcePath);
      lane1SourceSidecarFile = File(lane1SourceSidecarPath);
      lane1OutputFile = File(lane1OutputPath);
      lane1SidecarFile = File(lane1ExpectedSidecarPath);

      final lane1TempFile = File('$lane1OutputPath.vgptmp');
      final lane1SidecarTempFile = File('$lane1ExpectedSidecarPath.vgtmp');
      final lane1SidecarRoiTempFile = File(
        '$lane1ExpectedSidecarPath.vgroitmp',
      );

      try {
        await lane1SourceFile.writeAsBytes(rawBytes, flush: true);

        final sample1 = VGROISample(
          timestampMs: 500,
          framePtsMs: 500,
          recordingRelativeMs: 500,
          box: VGROIBox(x: 0.20, y: 0.15, w: 0.40, h: 0.35),
          quality: 'detected',
          confidence: 0.95,
          paddingPolicy: 'normal',
        );
        final lane1SourceSidecar = _makeSourceSidecar(
          displayWidth: sourceDisplayWidth,
          displayHeight: sourceDisplayHeight,
          durationMs: sourceDurationMs,
          samples: [sample1],
        );
        await lane1SourceSidecarFile.writeAsString(
          jsonEncode(lane1SourceSidecar.toJson()),
          flush: true,
        );

        final client = VGPassthroughRemuxClient();
        final lane1Report = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: lane1SourcePath,
            outputPath: lane1OutputPath,
          ),
        );

        lane1Map = lane1Report.toMap();

        final outExists = await lane1OutputFile.exists();
        final outDiskBytes = outExists ? await lane1OutputFile.length() : 0;
        final sidecarExists = await lane1SidecarFile.exists();

        var sidecarParses = false;
        var coordSpaceValid = false;
        var samplesNonEmpty = false;
        var displayGeometryMatches = false;

        if (sidecarExists) {
          try {
            final rawSidecarJson = await lane1SidecarFile.readAsString();
            final decoded = jsonDecode(rawSidecarJson) as Map<String, dynamic>;
            final parsedSidecar = VGROISidecar.fromJson(decoded);
            sidecarParses = true;
            coordSpaceValid =
                parsedSidecar.coordinateSpace == 'export_output_normalized';
            samplesNonEmpty = parsedSidecar.samples.isNotEmpty;
            displayGeometryMatches =
                (parsedSidecar.videoIdentity.width == sourceDisplayWidth) &&
                (parsedSidecar.videoIdentity.height == sourceDisplayHeight);
          } catch (e) {
            print(
              'ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE1: Sidecar parse error: $e',
            );
          }
        }

        final sidecarPathMatches =
            (lane1Report.exportRoiSidecarPath == lane1ExpectedSidecarPath) &&
            (lane1Report.roiSidecarPath == lane1ExpectedSidecarPath);

        final sidecarTempExists = await lane1SidecarTempFile.exists();
        final sidecarRoiTempExists = await lane1SidecarRoiTempFile.exists();
        final outTempExists = await lane1TempFile.exists();
        final noTempResidue =
            !sidecarTempExists && !sidecarRoiTempExists && !outTempExists;

        lane1Pass =
            lane1Report.success &&
            outExists &&
            outDiskBytes > 0 &&
            sidecarExists &&
            sidecarParses &&
            coordSpaceValid &&
            samplesNonEmpty &&
            sidecarPathMatches &&
            displayGeometryMatches &&
            noTempResidue;

        lane1Map['computed_pass'] = lane1Pass;
        lane1Map['sidecarExists'] = sidecarExists;
        lane1Map['sidecarParses'] = sidecarParses;
        lane1Map['coordSpaceValid'] = coordSpaceValid;
        lane1Map['samplesNonEmpty'] = samplesNonEmpty;
        lane1Map['displayGeometryMatches'] = displayGeometryMatches;
        lane1Map['sidecarPathMatches'] = sidecarPathMatches;
        lane1Map['noTempResidue'] = noTempResidue;

        print(
          'ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE1: DONE (pass=$lane1Pass, '
          'sidecarParses=$sidecarParses, coordSpace=$coordSpaceValid, '
          'samplesNonEmpty=$samplesNonEmpty, displayGeom=$displayGeometryMatches, '
          'noTempResidue=$noTempResidue)',
        );
      } catch (e, st) {
        print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE1: ERROR: $e\n$st');
        lane1Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane1Pass = false;
      }

      // ── LANE 2: Timeline single-clip with valid source ROI sidecar & trim ──
      print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE2: START');
      final lane2SourcePath = '${tempDir.path}/${runId}_lane2_source.mov';
      final lane2SourceSidecarPath = sidecarPathForVideoPath(lane2SourcePath);
      final lane2OutputPath = '${tempDir.path}/${runId}_lane2_out.mp4';
      final lane2ExpectedSidecarPath = sidecarPathForVideoPath(lane2OutputPath);

      lane2SourceFile = File(lane2SourcePath);
      lane2SourceSidecarFile = File(lane2SourceSidecarPath);
      lane2OutputFile = File(lane2OutputPath);
      lane2SidecarFile = File(lane2ExpectedSidecarPath);

      final lane2SidecarTempFile = File('$lane2ExpectedSidecarPath.vgtmp');
      final lane2SidecarRoiTempFile = File(
        '$lane2ExpectedSidecarPath.vgroitmp',
      );

      try {
        await lane2SourceFile.writeAsBytes(rawBytes, flush: true);

        final samples = [
          VGROISample(
            timestampMs: 0,
            framePtsMs: 0,
            recordingRelativeMs: 0,
            box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
            quality: 'detected',
          ),
          VGROISample(
            timestampMs: 1000,
            framePtsMs: 1000,
            recordingRelativeMs: 1000,
            box: VGROIBox(x: 0.2, y: 0.2, w: 0.3, h: 0.3),
            quality: 'detected',
          ),
          VGROISample(
            timestampMs: 2000,
            framePtsMs: 2000,
            recordingRelativeMs: 2000,
            box: VGROIBox(x: 0.3, y: 0.3, w: 0.4, h: 0.4),
            quality: 'detected',
          ),
          VGROISample(
            timestampMs: 4000,
            framePtsMs: 4000,
            recordingRelativeMs: 4000,
            box: VGROIBox(x: 0.4, y: 0.4, w: 0.5, h: 0.5),
            quality: 'detected',
          ),
        ];

        final lane2SourceSidecar = _makeSourceSidecar(
          displayWidth: sourceDisplayWidth,
          displayHeight: sourceDisplayHeight,
          durationMs: sourceDurationMs,
          samples: samples,
        );
        await lane2SourceSidecarFile.writeAsString(
          jsonEncode(lane2SourceSidecar.toJson()),
          flush: true,
        );

        final clip = VGClipDescriptor(
          id: 'unit_m_lane2_clip',
          mediaKind: VGMediaKind.video,
          sourcePath: lane2SourcePath,
          durationSeconds: 5.5,
          trimStartSeconds: 0.5,
          trimEndSeconds: 2.5,
          startTimeSeconds: 0.0,
        );

        final draft = VGEditorDraft(
          id: 'unit_m_draft_lane_2',
          clips: [clip],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final derivedDraft = draft
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final request = VGEditorExportRequest(
          outputPath: lane2OutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        final exportResult = await VanguardTimelineExporter.exportDraft(
          draft: derivedDraft,
          request: request,
        );

        final outExists = await lane2OutputFile.exists();
        final outDiskBytes = outExists ? await lane2OutputFile.length() : 0;
        final sidecarExists = await lane2SidecarFile.exists();

        var sidecarParses = false;
        var coordSpaceValid = false;
        var samplesTrimmedAndShifted = false;
        var outputDimensionsMatch = false;

        if (sidecarExists) {
          try {
            final rawSidecarJson = await lane2SidecarFile.readAsString();
            final decoded = jsonDecode(rawSidecarJson) as Map<String, dynamic>;
            final parsedSidecar = VGROISidecar.fromJson(decoded);
            sidecarParses = true;
            coordSpaceValid =
                parsedSidecar.coordinateSpace == 'export_output_normalized';

            // Samples at 0ms and 4000ms dropped. Samples at 1000ms and 2000ms survive.
            // 1000ms -> shifted by 500ms to 500ms
            // 2000ms -> shifted by 500ms to 1500ms
            if (parsedSidecar.samples.length == 2 &&
                parsedSidecar.samples[0].timestampMs == 500 &&
                parsedSidecar.samples[1].timestampMs == 1500) {
              samplesTrimmedAndShifted = true;
            }

            final expWidth = exportResult.width ?? 720;
            final expHeight = exportResult.height ?? 1280;
            outputDimensionsMatch =
                (parsedSidecar.videoIdentity.width == expWidth) &&
                (parsedSidecar.videoIdentity.height == expHeight);
          } catch (e) {
            print(
              'ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE2: Sidecar parse error: $e',
            );
          }
        }

        final sidecarTempExists = await lane2SidecarTempFile.exists();
        final sidecarRoiTempExists = await lane2SidecarRoiTempFile.exists();
        final noTempResidue = !sidecarTempExists && !sidecarRoiTempExists;

        lane2Pass =
            outExists &&
            outDiskBytes > 0 &&
            sidecarExists &&
            sidecarParses &&
            coordSpaceValid &&
            samplesTrimmedAndShifted &&
            outputDimensionsMatch &&
            noTempResidue;

        lane2Map = <String, dynamic>{
          'pass': lane2Pass,
          'outExists': outExists,
          'outDiskBytes': outDiskBytes,
          'sidecarExists': sidecarExists,
          'sidecarParses': sidecarParses,
          'coordSpaceValid': coordSpaceValid,
          'samplesTrimmedAndShifted': samplesTrimmedAndShifted,
          'outputDimensionsMatch': outputDimensionsMatch,
          'noTempResidue': noTempResidue,
          'exportResultPath': exportResult.path,
          'exportRoiSidecarPath': exportResult.exportRoiSidecarPath,
        };

        print(
          'ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE2: DONE (pass=$lane2Pass, '
          'sidecarParses=$sidecarParses, coordSpace=$coordSpaceValid, '
          'samplesTrimmed=$samplesTrimmedAndShifted, dimsMatch=$outputDimensionsMatch, '
          'noTempResidue=$noTempResidue)',
        );
      } catch (e, st) {
        print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE2: ERROR: $e\n$st');
        lane2Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane2Pass = false;
      }

      // ── LANE 3: Missing or malformed source sidecar fallback ──────────────
      print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE3: START');
      final lane3aSourcePath = '${tempDir.path}/${runId}_lane3a_missing.mov';
      final lane3aOutputPath = '${tempDir.path}/${runId}_lane3a_out.mp4';
      final lane3aExpectedSidecarPath = sidecarPathForVideoPath(
        lane3aOutputPath,
      );

      final lane3bSourcePath = '${tempDir.path}/${runId}_lane3b_malformed.mov';
      final lane3bSourceSidecarPath = sidecarPathForVideoPath(lane3bSourcePath);
      final lane3bOutputPath = '${tempDir.path}/${runId}_lane3b_out.mp4';
      final lane3bExpectedSidecarPath = sidecarPathForVideoPath(
        lane3bOutputPath,
      );

      lane3aSourceFile = File(lane3aSourcePath);
      lane3aOutputFile = File(lane3aOutputPath);
      lane3aSidecarFile = File(lane3aExpectedSidecarPath);

      lane3bSourceFile = File(lane3bSourcePath);
      lane3bSourceSidecarFile = File(lane3bSourceSidecarPath);
      lane3bOutputFile = File(lane3bOutputPath);
      lane3bSidecarFile = File(lane3bExpectedSidecarPath);

      final lane3aSidecarTempFile = File('$lane3aExpectedSidecarPath.vgtmp');
      final lane3aSidecarRoiTempFile = File(
        '$lane3aExpectedSidecarPath.vgroitmp',
      );
      final lane3bSidecarTempFile = File('$lane3bExpectedSidecarPath.vgtmp');
      final lane3bSidecarRoiTempFile = File(
        '$lane3bExpectedSidecarPath.vgroitmp',
      );

      try {
        final client = VGPassthroughRemuxClient();

        // ── Part A: Missing source sidecar ──
        await lane3aSourceFile.writeAsBytes(rawBytes, flush: true);
        // Ensure NO adjacent .roi.json exists for lane3a

        final report3a = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: lane3aSourcePath,
            outputPath: lane3aOutputPath,
          ),
        );

        final out3aExists = await lane3aOutputFile.exists();
        final sidecar3aExists = await lane3aSidecarFile.exists();

        var sidecar3aParsesEmpty = false;
        if (sidecar3aExists) {
          try {
            final raw = await lane3aSidecarFile.readAsString();
            final decoded = jsonDecode(raw) as Map<String, dynamic>;
            final sidecar = VGROISidecar.fromJson(decoded);
            sidecar3aParsesEmpty =
                sidecar.coordinateSpace == 'export_output_normalized' &&
                sidecar.finalized == true &&
                sidecar.samples.isEmpty &&
                sidecar.platform == 'android' &&
                sidecar.coverage.coveragePercent == 0.0;
          } catch (e) {
            print(
              'ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE3: 3A sidecar parse error: $e',
            );
          }
        }

        final temp3aExists =
            await lane3aSidecarTempFile.exists() ||
            await lane3aSidecarRoiTempFile.exists();

        final partAPass =
            report3a.success &&
            out3aExists &&
            sidecar3aExists &&
            sidecar3aParsesEmpty &&
            !temp3aExists;

        // ── Part B: Malformed source sidecar ──
        await lane3bSourceFile.writeAsBytes(rawBytes, flush: true);
        await lane3bSourceSidecarFile.writeAsString(
          '{"invalid_json": true, broken',
          flush: true,
        );

        final report3b = await client.export(
          VGPassthroughRemuxRequest(
            sourcePath: lane3bSourcePath,
            outputPath: lane3bOutputPath,
          ),
        );

        final out3bExists = await lane3bOutputFile.exists();
        final sidecar3bExists = await lane3bSidecarFile.exists();

        var sidecar3bParsesEmpty = false;
        if (sidecar3bExists) {
          try {
            final raw = await lane3bSidecarFile.readAsString();
            final decoded = jsonDecode(raw) as Map<String, dynamic>;
            final sidecar = VGROISidecar.fromJson(decoded);
            sidecar3bParsesEmpty =
                sidecar.coordinateSpace == 'export_output_normalized' &&
                sidecar.finalized == true &&
                sidecar.samples.isEmpty &&
                sidecar.platform == 'android' &&
                sidecar.coverage.coveragePercent == 0.0;
          } catch (e) {
            print(
              'ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE3: 3B sidecar parse error: $e',
            );
          }
        }

        final temp3bExists =
            await lane3bSidecarTempFile.exists() ||
            await lane3bSidecarRoiTempFile.exists();

        final partBPass =
            report3b.success &&
            out3bExists &&
            sidecar3bExists &&
            sidecar3bParsesEmpty &&
            !temp3bExists;

        lane3Pass = partAPass && partBPass;

        lane3Map = <String, dynamic>{
          'pass': lane3Pass,
          'partAPass': partAPass,
          'partBPass': partBPass,
          'sidecar3aParsesEmpty': sidecar3aParsesEmpty,
          'sidecar3bParsesEmpty': sidecar3bParsesEmpty,
          'temp3aExists': temp3aExists,
          'temp3bExists': temp3bExists,
        };

        print(
          'ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE3: DONE (pass=$lane3Pass, '
          'partA=$partAPass, partB=$partBPass)',
        );
      } catch (e, st) {
        print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE3: ERROR: $e\n$st');
        lane3Map = <String, dynamic>{'pass': false, 'error': '$e'};
        lane3Pass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_ROI_EXPORT_MAPPING_UNIT_M: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // ── Clean up only harness-owned temp files ────────────────────────────
      final filesToClean = <File?>[
        rawClipAssetFile,
        lane1SourceFile,
        lane1SourceSidecarFile,
        lane1OutputFile,
        lane1SidecarFile,
        if (lane1OutputFile != null) File('${lane1OutputFile.path}.vgptmp'),
        if (lane1SidecarFile != null) File('${lane1SidecarFile.path}.vgtmp'),
        if (lane1SidecarFile != null) File('${lane1SidecarFile.path}.vgroitmp'),
        lane2SourceFile,
        lane2SourceSidecarFile,
        lane2OutputFile,
        lane2SidecarFile,
        if (lane2OutputFile != null) File('${lane2OutputFile.path}.vgptmp'),
        if (lane2SidecarFile != null) File('${lane2SidecarFile.path}.vgtmp'),
        if (lane2SidecarFile != null) File('${lane2SidecarFile.path}.vgroitmp'),
        lane3aSourceFile,
        lane3aOutputFile,
        lane3aSidecarFile,
        if (lane3aOutputFile != null) File('${lane3aOutputFile.path}.vgptmp'),
        if (lane3aSidecarFile != null) File('${lane3aSidecarFile.path}.vgtmp'),
        if (lane3aSidecarFile != null)
          File('${lane3aSidecarFile.path}.vgroitmp'),
        lane3bSourceFile,
        lane3bSourceSidecarFile,
        lane3bOutputFile,
        lane3bSidecarFile,
        if (lane3bOutputFile != null) File('${lane3bOutputFile.path}.vgptmp'),
        if (lane3bSidecarFile != null) File('${lane3bSidecarFile.path}.vgtmp'),
        if (lane3bSidecarFile != null)
          File('${lane3bSidecarFile.path}.vgroitmp'),
      ];

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

    print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE1_PASS: $lane1Pass');
    print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE2_PASS: $lane2Pass');
    print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_LANE3_PASS: $lane3Pass');

    final allPass =
        lane1Pass && lane2Pass && lane3Pass && (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase5UnitM',
      'target': 'android_roi_export_mapping_physical',
      'pass': allPass,
      'lanes': <String, dynamic>{
        'lane1_passthrough_source_roi': lane1Map,
        'lane2_timeline_single_clip_roi_trim': lane2Map,
        'lane3_missing_malformed_fallback': lane3Map,
      },
      'error': topLevelError,
    };

    print('ANDROID_ROI_EXPORT_MAPPING_UNIT_M_JSON:${jsonEncode(payload)}');
    print(
      allPass
          ? 'ANDROID_ROI_EXPORT_MAPPING_UNIT_M_PHYSICAL_PASS'
          : 'ANDROID_ROI_EXPORT_MAPPING_UNIT_M_PHYSICAL_FAIL',
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
