// android_dag_export_unit_h_smoke.dart
// Vanguard Media Engine — Android True-DAG Export Unit H Physical Smoke Harness.
// Audio sidecar remux / mixdown and cancellation / concurrency lifecycle proof.
//
// Proof lanes:
//   Lane A: ROTATED_SCALED_WITH_ORIGINAL_AUDIO — Raw unpatched 1920x1080 clip_B (-90 deg rotation)
//           exported to 720x1280 portrait canvas with direct-copy eligible original audio.
//   Lane B: TRIMMED_AUDIO_MIXDOWN_WITH_ROTATED_FIT — Trimmed raw clip_B (sourceTrimStart=0.1)
//           exported to 720x1280 portrait canvas exercising PCM mixdown / AAC encode path.
//   Lane C: CONCURRENT_REJECTION_AND_ACTIVE_CANCEL — Long export rejects concurrent export with
//           EXPORT_IN_PROGRESS and cancels cleanly on cancelExport with EXPORT_CANCELLED.
//   Lane D: INVALID_DIMENSION_GUARDRAIL — Odd width 721 is rejected with INVALID_ARG and preserves
//           pre-existing sentinel output and sidecar files.

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
  runApp(const AndroidDagExportUnitHSmokeApp());
}

class AndroidDagExportUnitHSmokeApp extends StatefulWidget {
  const AndroidDagExportUnitHSmokeApp({super.key});

  @override
  State<AndroidDagExportUnitHSmokeApp> createState() =>
      _AndroidDagExportUnitHSmokeAppState();
}

class _AndroidDagExportUnitHSmokeAppState
    extends State<AndroidDagExportUnitHSmokeApp> {
  String _status = 'Running Android Export Unit H Physical Smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_EXPORT_UNIT_H_SMOKE: START');
    final runId = 'unit_h_${DateTime.now().millisecondsSinceEpoch}';

    File? tempSourceClipB;
    File? laneAOutputFile;
    File? laneASidecarFile;
    File? laneBOutputFile;
    File? laneBSidecarFile;
    File? laneCOutputFile;
    File? laneCSidecarFile;
    File? laneCSecondOutputFile;
    File? laneCSecondSidecarFile;
    File? laneDSentinelVideoFile;
    File? laneDSentinelSidecarFile;

    MediaInfo? sourceClipBMediaInfo;
    Map<String, dynamic>? laneAResults;
    Map<String, dynamic>? laneBResults;
    Map<String, dynamic>? laneCResults;
    Map<String, dynamic>? laneDResults;
    final cleanupObservations = <String, dynamic>{};

    var laneAPass = false;
    var laneBPass = false;
    var laneCPass = false;
    var laneDPass = false;
    String? topLevelError;

    try {
      final tempDir = Directory.systemTemp;

      // ── Copy Asset Fixture to System Temp (Raw Unpatched clip_B.mov) ─────
      print(
        'ANDROID_EXPORT_UNIT_H_SMOKE: Copying raw unpatched clip_B.mov to temp...',
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
        'ANDROID_EXPORT_UNIT_H_SMOKE: Raw source clip B ready at $sourcePathB (${rawBytesB.length} bytes)',
      );

      // ── Inspect and Validate Source Clip B Rotation & Audio Metadata ─────
      print(
        'ANDROID_EXPORT_UNIT_H_SMOKE: Inspecting raw source clip B for rotation & audio metadata...',
      );
      final sourceInfoB = await VanguardMediaPreparer.inspectMedia(sourcePathB);
      print(
        'ANDROID_EXPORT_UNIT_H_SMOKE: Source clip B MediaInfo: $sourceInfoB',
      );
      final sourceBHasVideo = sourceInfoB != null && sourceInfoB.hasVideo;
      final sourceBHasAudio = sourceInfoB != null && sourceInfoB.hasAudio;
      final sourceBEncodedDimsValid =
          sourceInfoB != null &&
          (sourceInfoB.width == 1920 || sourceInfoB.encodedWidth == 1920) &&
          (sourceInfoB.height == 1080 || sourceInfoB.encodedHeight == 1080);
      final sourceBRotationValid =
          sourceInfoB != null &&
          ((sourceInfoB.rotationDegrees == 270 ||
                  sourceInfoB.rotationDegrees == -90) ||
              (sourceInfoB.hasRotationTransform &&
                  sourceInfoB.orientationStatus == 'valid'));

      final sourceBValid =
          sourceBHasVideo &&
          sourceBHasAudio &&
          sourceBEncodedDimsValid &&
          sourceBRotationValid;

      if (sourceInfoB == null || !sourceBValid) {
        throw Exception(
          'Source clip B failed metadata validation (hasVideo=$sourceBHasVideo, hasAudio=$sourceBHasAudio, encodedDims=$sourceBEncodedDimsValid, rotation=$sourceBRotationValid, info=$sourceInfoB)',
        );
      }
      sourceClipBMediaInfo = sourceInfoB;

      // ── Lane A: ROTATED_SCALED_WITH_ORIGINAL_AUDIO ───────────────────────
      print('ANDROID_EXPORT_UNIT_H_SMOKE_LANE_A: START');
      final laneAOutputPath = '${tempDir.path}/${runId}_lane_a_out.mp4';
      final laneAExpectedSidecarPath = sidecarPathForVideoPath(laneAOutputPath);
      laneAOutputFile = File(laneAOutputPath);
      laneASidecarFile = File(laneAExpectedSidecarPath);

      try {
        final clipA = VGClipDescriptor(
          id: 'unit_h_lane_a_clip',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePathB,
          durationSeconds: 5.565,
          trimStartSeconds: 0.0,
          trimEndSeconds: 5.565,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final rawDraftA = VGEditorDraft(
          id: 'unit_h_draft_lane_a',
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

        final derivedDraftA = rawDraftA
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final requestA = VGEditorExportRequest(
          outputPath: laneAOutputPath,
          width: 720,
          height: 1280,
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
            resultA.width == 720 && resultA.height == 1280 && resultA.fps == 30;
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

        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_A: Inspecting exported output media info...',
        );
        final laneAExportMediaInfo = await VanguardMediaPreparer.inspectMedia(
          laneAOutputPath,
        );
        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_A: Exported MediaInfo: $laneAExportMediaInfo',
        );

        final laneAMediaHasVideo =
            laneAExportMediaInfo != null && laneAExportMediaInfo.hasVideo;
        final laneAMediaHasAudio =
            laneAExportMediaInfo != null && laneAExportMediaInfo.hasAudio;
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
        final laneAAudioCodecValid =
            laneAExportMediaInfo != null &&
            laneAExportMediaInfo.audioCodec.isNotEmpty;

        final laneAMediaValid =
            laneAMediaHasVideo &&
            laneAMediaHasAudio &&
            laneAMediaDimsValid &&
            laneAMediaNoRotation &&
            laneAAudioCodecValid;

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
          'hasAudio': laneAMediaHasAudio,
          'audioCodec': laneAExportMediaInfo?.audioCodec,
          'exportedMediaInfo': laneAExportMediaInfo != null
              ? _mediaInfoToMap(laneAExportMediaInfo)
              : null,
          'error': laneAPass
              ? null
              : 'Validation failed (exists=$outExists, bytes=$outBytes, pathMatch=$pathMatch, dimsMatch=$dimsMatch, durationValid=$durationValid, sidecarNonNull=$sidecarPathNonNull, sidecarPathMatch=$sidecarPathMatch, sidecarExists=$sidecarExists, sidecarContentExact=$sidecarContentExact, mediaValid=$laneAMediaValid, hasAudio=$laneAMediaHasAudio, audioCodec=${laneAExportMediaInfo?.audioCodec})',
        };
        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_A: DONE (pass=$laneAPass, duration=${resultA.durationSeconds}, bytes=$outBytes, hasAudio=$laneAMediaHasAudio, codec=${laneAExportMediaInfo?.audioCodec})',
        );
      } catch (e, st) {
        print('ANDROID_EXPORT_UNIT_H_SMOKE_LANE_A: ERROR: $e\n$st');
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
          'hasAudio': false,
          'audioCodec': null,
          'exportedMediaInfo': null,
          'error': '$e',
        };
        laneAPass = false;
      }

      // ── Lane B: TRIMMED_AUDIO_MIXDOWN_WITH_ROTATED_FIT ───────────────────
      print('ANDROID_EXPORT_UNIT_H_SMOKE_LANE_B: START');
      final laneBOutputPath = '${tempDir.path}/${runId}_lane_b_out.mp4';
      final laneBExpectedSidecarPath = sidecarPathForVideoPath(laneBOutputPath);
      laneBOutputFile = File(laneBOutputPath);
      laneBSidecarFile = File(laneBExpectedSidecarPath);

      try {
        final clipB = VGClipDescriptor(
          id: 'unit_h_lane_b_clip',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePathB,
          durationSeconds: 5.565,
          trimStartSeconds: 0.1,
          trimEndSeconds: 2.1,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final rawDraftB = VGEditorDraft(
          id: 'unit_h_draft_lane_b',
          clips: [clipB],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final derivedDraftB = rawDraftB
            .flattenOriginalClipAudio()
            .applyAudioCompositionPolicy();

        final requestB = VGEditorExportRequest(
          outputPath: laneBOutputPath,
          width: 720,
          height: 1280,
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
            resultB.width == 720 && resultB.height == 1280 && resultB.fps == 30;
        final durationValid =
            resultB.durationSeconds >= 1.6 && resultB.durationSeconds <= 2.5;

        final sidecarPathNonNull = resultB.exportRoiSidecarPath != null;
        final sidecarPathMatch =
            resultB.exportRoiSidecarPath == laneBExpectedSidecarPath;
        final sidecarExists = await laneBSidecarFile.exists();
        final sidecarContent = sidecarExists
            ? await laneBSidecarFile.readAsString()
            : '';
        final sidecarContentExact = _isValidEmptyRoiSidecar(sidecarContent);

        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_B: Inspecting exported output media info...',
        );
        final laneBExportMediaInfo = await VanguardMediaPreparer.inspectMedia(
          laneBOutputPath,
        );
        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_B: Exported MediaInfo: $laneBExportMediaInfo',
        );

        final laneBMediaHasVideo =
            laneBExportMediaInfo != null && laneBExportMediaInfo.hasVideo;
        final laneBMediaHasAudio =
            laneBExportMediaInfo != null && laneBExportMediaInfo.hasAudio;
        final laneBMediaDimsValid =
            laneBExportMediaInfo != null &&
            laneBExportMediaInfo.width == 720 &&
            laneBExportMediaInfo.height == 1280 &&
            (laneBExportMediaInfo.encodedWidth == 0 ||
                laneBExportMediaInfo.encodedWidth == 720) &&
            (laneBExportMediaInfo.encodedHeight == 0 ||
                laneBExportMediaInfo.encodedHeight == 1280) &&
            (laneBExportMediaInfo.displayWidth == 0 ||
                laneBExportMediaInfo.displayWidth == 720) &&
            (laneBExportMediaInfo.displayHeight == 0 ||
                laneBExportMediaInfo.displayHeight == 1280);
        final laneBMediaNoRotation =
            laneBExportMediaInfo != null &&
            (!laneBExportMediaInfo.hasRotationTransform ||
                laneBExportMediaInfo.rotationDegrees == 0 ||
                laneBExportMediaInfo.rotationDegrees == null);

        final laneBMediaValid =
            laneBMediaHasVideo &&
            laneBMediaHasAudio &&
            laneBMediaDimsValid &&
            laneBMediaNoRotation;

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
          'hasAudio': laneBMediaHasAudio,
          'audioCodec': laneBExportMediaInfo?.audioCodec,
          'mixdownInferredFromTrimStart': true,
          'mixdownRouteEvidence':
              'sourceTrimStart=0.1s exceeds direct-copy 50ms tolerance; route exercises native PCM mixdown/AAC encoding (inferred from contract and log evidence, not returned by API)',
          'exportedMediaInfo': laneBExportMediaInfo != null
              ? _mediaInfoToMap(laneBExportMediaInfo)
              : null,
          'error': laneBPass
              ? null
              : 'Validation failed (exists=$outExists, bytes=$outBytes, pathMatch=$pathMatch, dimsMatch=$dimsMatch, durationValid=$durationValid, sidecarNonNull=$sidecarPathNonNull, sidecarPathMatch=$sidecarPathMatch, sidecarExists=$sidecarExists, sidecarContentExact=$sidecarContentExact, mediaValid=$laneBMediaValid, hasAudio=$laneBMediaHasAudio)',
        };
        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_B: DONE (pass=$laneBPass, duration=${resultB.durationSeconds}, bytes=$outBytes, hasAudio=$laneBMediaHasAudio)',
        );
      } catch (e, st) {
        print('ANDROID_EXPORT_UNIT_H_SMOKE_LANE_B: ERROR: $e\n$st');
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
          'hasAudio': false,
          'audioCodec': null,
          'mixdownInferredFromTrimStart': true,
          'mixdownRouteEvidence': null,
          'exportedMediaInfo': null,
          'error': '$e',
        };
        laneBPass = false;
      }

      // ── Lane C: CONCURRENT_REJECTION_AND_ACTIVE_CANCEL ───────────────────
      print('ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: START');
      final laneCOutputPath = '${tempDir.path}/${runId}_lane_c_out.mp4';
      final laneCExpectedSidecarPath = sidecarPathForVideoPath(laneCOutputPath);
      laneCOutputFile = File(laneCOutputPath);
      laneCSidecarFile = File(laneCExpectedSidecarPath);

      final laneCSecondOutputPath =
          '${tempDir.path}/${runId}_lane_c_second.mp4';
      final laneCSecondExpectedSidecarPath = sidecarPathForVideoPath(
        laneCSecondOutputPath,
      );
      laneCSecondOutputFile = File(laneCSecondOutputPath);
      laneCSecondSidecarFile = File(laneCSecondExpectedSidecarPath);

      String? concurrencyErrorCode;
      String? cancelErrorCode;

      try {
        // Build long video-only draft (10 clips x 5.565s = ~55.65s).
        const clipCount = 10;
        final longClips = List<VGClipDescriptor>.generate(
          clipCount,
          (i) => VGClipDescriptor(
            id: 'unit_h_lane_c_long_clip_$i',
            mediaKind: VGMediaKind.video,
            sourcePath: sourcePathB,
            durationSeconds: 5.565,
            trimStartSeconds: 0.0,
            trimEndSeconds: 5.565,
            startTimeSeconds: i * 5.565,
            speed: 1.0,
          ),
        );

        final longDraft = VGEditorDraft(
          id: 'unit_h_draft_lane_c_long',
          clips: longClips,
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final requestC1 = VGEditorExportRequest(
          outputPath: laneCOutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: Starting long export (duration ~55.65s)...',
        );
        final firstExportFuture = VanguardTimelineExporter.exportDraft(
          draft: longDraft,
          request: requestC1,
        );

        // Prepare second valid export to test concurrent rejection.
        final secondClip = VGClipDescriptor(
          id: 'unit_h_lane_c_second_clip',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePathB,
          durationSeconds: 5.565,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.0,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final secondDraft = VGEditorDraft(
          id: 'unit_h_draft_lane_c_second',
          clips: [secondClip],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 720,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final requestC2 = VGEditorExportRequest(
          outputPath: laneCSecondOutputPath,
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: Attempting concurrent second export...',
        );
        final retryDeadline = DateTime.now().add(
          const Duration(milliseconds: 2000),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));

        while (DateTime.now().isBefore(retryDeadline)) {
          try {
            await VanguardTimelineExporter.exportDraft(
              draft: secondDraft,
              request: requestC2,
            );
            print(
              'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: Warning: Second export did not throw, retrying...',
            );
            await Future<void>.delayed(const Duration(milliseconds: 100));
          } on PlatformException catch (pe) {
            concurrencyErrorCode = pe.code;
            print(
              'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: Second export caught PlatformException code: ${pe.code}',
            );
            if (pe.code == 'EXPORT_IN_PROGRESS') {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          } catch (e) {
            print(
              'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: Second export caught unexpected exception: $e',
            );
            break;
          }
        }

        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: Sending cancelExport on MethodChannel...',
        );
        await const MethodChannel(
          'vanguard_media_engine',
        ).invokeMethod<void>('cancelExport');

        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: Awaiting first export Future for cancellation verdict...',
        );
        try {
          final completedResult = await firstExportFuture;
          print(
            'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: First export unexpectedly succeeded: ${completedResult.path}',
          );
        } on PlatformException catch (pe) {
          cancelErrorCode = pe.code;
          print(
            'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: First export caught PlatformException code: ${pe.code} (${pe.message})',
          );
        } catch (e) {
          print(
            'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: First export caught unexpected error: $e',
          );
        }

        final outExists = await laneCOutputFile.exists();
        final outBytes = outExists ? await laneCOutputFile.length() : 0;
        final secondOutExists = await laneCSecondOutputFile.exists();
        final secondOutBytes = secondOutExists
            ? await laneCSecondOutputFile.length()
            : 0;

        final concurrencyPass = concurrencyErrorCode == 'EXPORT_IN_PROGRESS';
        final cancellationPass =
            (cancelErrorCode == 'EXPORT_CANCELLED') &&
            (!outExists || outBytes == 0);

        laneCPass = concurrencyPass && cancellationPass;

        laneCResults = <String, dynamic>{
          'pass': laneCPass,
          'concurrencyErrorCode': concurrencyErrorCode,
          'concurrencyValid': concurrencyPass,
          'cancelErrorCode': cancelErrorCode,
          'cancellationValid': cancellationPass,
          'firstOutputPath': laneCOutputPath,
          'firstOutputExists': outExists,
          'firstOutputBytes': outBytes,
          'secondOutputPath': laneCSecondOutputPath,
          'secondOutputExists': secondOutExists,
          'secondOutputBytes': secondOutBytes,
          'error': laneCPass
              ? null
              : 'Lifecycle mismatch (concurrencyPass=$concurrencyPass [code=$concurrencyErrorCode], cancellationPass=$cancellationPass [code=$cancelErrorCode, outExists=$outExists, outBytes=$outBytes])',
        };
        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: DONE (pass=$laneCPass, concurrencyCode=$concurrencyErrorCode, cancelCode=$cancelErrorCode, outBytes=$outBytes)',
        );
      } catch (e, st) {
        print('ANDROID_EXPORT_UNIT_H_SMOKE_LANE_C: ERROR: $e\n$st');
        laneCResults = <String, dynamic>{
          'pass': false,
          'concurrencyErrorCode': concurrencyErrorCode,
          'concurrencyValid': false,
          'cancelErrorCode': cancelErrorCode,
          'cancellationValid': false,
          'firstOutputPath': laneCOutputPath,
          'firstOutputExists': false,
          'firstOutputBytes': 0,
          'secondOutputPath': laneCSecondOutputPath,
          'secondOutputExists': false,
          'secondOutputBytes': 0,
          'error': '$e',
        };
        laneCPass = false;
      }

      // ── Lane D: INVALID_DIMENSION_GUARDRAIL ──────────────────────────────
      print('ANDROID_EXPORT_UNIT_H_SMOKE_LANE_D: START');
      final laneDOutputPath = '${tempDir.path}/${runId}_lane_d_sentinel.mp4';
      final laneDExpectedSidecarPath = sidecarPathForVideoPath(laneDOutputPath);
      laneDSentinelVideoFile = File(laneDOutputPath);
      laneDSentinelSidecarFile = File(laneDExpectedSidecarPath);

      const videoSentinelContent = 'SENTINEL_PRE_EXISTING_UNIT_H_OUTPUT_DATA';
      const sidecarSentinelContent = '{"sentinel":true}';

      try {
        await laneDSentinelVideoFile.writeAsString(
          videoSentinelContent,
          flush: true,
        );
        await laneDSentinelSidecarFile.writeAsString(
          sidecarSentinelContent,
          flush: true,
        );

        final clipD = VGClipDescriptor(
          id: 'unit_h_lane_d_clip',
          mediaKind: VGMediaKind.video,
          sourcePath: sourcePathB,
          durationSeconds: 5.565,
          trimStartSeconds: 0.0,
          trimEndSeconds: 1.5,
          startTimeSeconds: 0.0,
          speed: 1.0,
        );

        final draftD = VGEditorDraft(
          id: 'unit_h_draft_lane_d',
          clips: [clipD],
          canvasWidth: 721,
          canvasHeight: 1280,
          fps: 30,
          canvas: VGCanvasDescriptor(
            width: 721,
            height: 1280,
            contentMode: VGCanvasContentMode.fit,
          ),
        );

        final requestD = VGEditorExportRequest(
          outputPath: laneDOutputPath,
          width: 721,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        String? exceptionCodeD;
        try {
          await VanguardTimelineExporter.exportDraft(
            draft: draftD,
            request: requestD,
          );
        } on PlatformException catch (pe) {
          exceptionCodeD = pe.code;
          print(
            'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_D: Caught PlatformException code: ${pe.code}',
          );
        }

        final videoSentinelStillExists = await laneDSentinelVideoFile.exists();
        final currentVideoContent = videoSentinelStillExists
            ? await laneDSentinelVideoFile.readAsString()
            : '';
        final videoSentinelPreserved =
            videoSentinelStillExists &&
            (currentVideoContent == videoSentinelContent);

        final sidecarSentinelStillExists = await laneDSentinelSidecarFile
            .exists();
        final currentSidecarContent = sidecarSentinelStillExists
            ? await laneDSentinelSidecarFile.readAsString()
            : '';
        final sidecarSentinelPreserved =
            sidecarSentinelStillExists &&
            (currentSidecarContent == sidecarSentinelContent);

        final codeMatchD = exceptionCodeD == 'INVALID_ARG';
        laneDPass =
            codeMatchD && videoSentinelPreserved && sidecarSentinelPreserved;

        final videoBytes = videoSentinelStillExists
            ? await laneDSentinelVideoFile.length()
            : 0;

        laneDResults = <String, dynamic>{
          'pass': laneDPass,
          'exceptionCode': exceptionCodeD,
          'videoSentinelPreserved': videoSentinelPreserved,
          'sidecarSentinelPreserved': sidecarSentinelPreserved,
          'outputPath': laneDOutputPath,
          'outputBytes': videoBytes,
          'expectedRoiSidecarPath': laneDExpectedSidecarPath,
          'sidecarExists': sidecarSentinelStillExists,
          'sidecarContentExact': sidecarSentinelPreserved,
          'error': laneDPass
              ? null
              : 'Rejection or preservation mismatch (code=$exceptionCodeD, videoPreserved=$videoSentinelPreserved, sidecarPreserved=$sidecarSentinelPreserved)',
        };
        print(
          'ANDROID_EXPORT_UNIT_H_SMOKE_LANE_D: DONE (pass=$laneDPass, code=$exceptionCodeD, videoPreserved=$videoSentinelPreserved, sidecarPreserved=$sidecarSentinelPreserved)',
        );
      } catch (e, st) {
        print('ANDROID_EXPORT_UNIT_H_SMOKE_LANE_D: ERROR: $e\n$st');
        laneDResults = <String, dynamic>{
          'pass': false,
          'exceptionCode': null,
          'videoSentinelPreserved': false,
          'sidecarSentinelPreserved': false,
          'outputPath': laneDOutputPath,
          'outputBytes': 0,
          'expectedRoiSidecarPath': laneDExpectedSidecarPath,
          'sidecarExists': false,
          'sidecarContentExact': false,
          'error': '$e',
        };
        laneDPass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        'ANDROID_EXPORT_UNIT_H_SMOKE: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt',
      );
      topLevelError = '$topLevelE';
    } finally {
      // ── Clean up all temp files ───────────────────────────────────────────
      final filesToClean = <String, File?>{
        'tempSourceClipB': tempSourceClipB,
        'laneAOutputFile': laneAOutputFile,
        'laneASidecarFile': laneASidecarFile,
        'laneASidecarTemp': laneASidecarFile != null
            ? File('${laneASidecarFile.path}.vgtmp')
            : null,
        'laneASidecarRoiTemp': laneASidecarFile != null
            ? File('${laneASidecarFile.path}.vgroitmp')
            : null,
        'laneBOutputFile': laneBOutputFile,
        'laneBSidecarFile': laneBSidecarFile,
        'laneBSidecarTemp': laneBSidecarFile != null
            ? File('${laneBSidecarFile.path}.vgtmp')
            : null,
        'laneBSidecarRoiTemp': laneBSidecarFile != null
            ? File('${laneBSidecarFile.path}.vgroitmp')
            : null,
        'laneCOutputFile': laneCOutputFile,
        'laneCSidecarFile': laneCSidecarFile,
        'laneCSecondOutputFile': laneCSecondOutputFile,
        'laneCSecondSidecarFile': laneCSecondSidecarFile,
        'laneDSentinelVideoFile': laneDSentinelVideoFile,
        'laneDSentinelSidecarFile': laneDSentinelSidecarFile,
      };

      for (final entry in filesToClean.entries) {
        final f = entry.value;
        if (f != null) {
          try {
            if (await f.exists()) {
              final len = await f.length();
              print(
                'ANDROID_EXPORT_UNIT_H_SMOKE: Cleaning ${entry.key} at ${f.path} ($len bytes)',
              );
              await f.delete();
              cleanupObservations[entry.key] = {
                'path': f.path,
                'existed': true,
                'bytesBeforeDelete': len,
                'deleted': true,
              };
            } else {
              cleanupObservations[entry.key] = {
                'path': f.path,
                'existed': false,
                'deleted': false,
              };
            }
          } catch (cleanE) {
            print(
              'ANDROID_EXPORT_UNIT_H_SMOKE: Warning: Failed to clean ${entry.key} at ${f.path}: $cleanE',
            );
            cleanupObservations[entry.key] = {
              'path': f.path,
              'existed': true,
              'deleted': false,
              'cleanError': '$cleanE',
            };
          }
        }
      }
    }

    // ── Build and Print Aggregate JSON and Verdict ─────────────────────────
    final allPass =
        laneAPass &&
        laneBPass &&
        laneCPass &&
        laneDPass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'AndroidExportUnitH',
      'target': 'android_physical',
      'pass': allPass,
      'sourceClipBMediaInfo': sourceClipBMediaInfo != null
          ? _mediaInfoToMap(sourceClipBMediaInfo)
          : null,
      'lanes': <String, dynamic>{
        'rotatedScaledWithOriginalAudio':
            laneAResults ?? {'pass': false, 'error': 'not run'},
        'trimmedAudioMixdownWithRotatedFit':
            laneBResults ?? {'pass': false, 'error': 'not run'},
        'concurrentRejectionAndActiveCancel':
            laneCResults ?? {'pass': false, 'error': 'not run'},
        'invalidDimensionGuardrail':
            laneDResults ?? {'pass': false, 'error': 'not run'},
      },
      'cleanup': cleanupObservations,
      'nonClaims': const <String>[
        'no static cancel API cleanup',
        'no external music asset proof',
        'no deterministic micro-state pass2 cancellation proof',
        'no programmatic directCopy/mixdown route field from production API',
        'no full True-DAG compositor/export transitions/overlays/transforms',
      ],
      'error': topLevelError,
    };

    print('ANDROID_EXPORT_UNIT_H_SMOKE_JSON:${jsonEncode(payload)}');
    print(
      allPass
          ? 'ANDROID_EXPORT_UNIT_H_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_EXPORT_UNIT_H_PHYSICAL_SMOKE_FAIL',
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
