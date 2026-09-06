// android_timeline_gles_beauty_export_physical_smoke.dart
// Vanguard Media Engine — P5-GLES-EXPORT-BEAUTY-PRODUCTION-ROUTE-A:
// Android production `exportTimeline` GLES forced Beauty V2 route proof.
//
// Proof boundary: production_exportTimeline_gles_beauty_v2_forced_route_a_no_vulkan_no_app
//
// Drives the REAL production `exportTimeline` MethodChannel route with top-level
// `debugForceRenderBackend: gles` using clip_A.mov copies (zero-rotation
// success fixture, ffprobe-verified no rotation tag), clip_B.mov (rotated
// negative fixture), and still_C.png:
//   Lane forced_gles_beauty_single_success      : 1 clip_A, beauty 0.5, no transition ->
//                                                  success, backend gles, duration ~2.0,
//                                                  beautyClipCount 1, exact beautyFrameCount 60
//   Lane forced_gles_beauty_mixed_success        : 2 clip_A copies, first beauty 0.75,
//                                                  second null, no transition -> success,
//                                                  backend gles, duration ~4.0,
//                                                  beautyClipCount 1, exact beautyFrameCount 60
//   Lane forced_gles_beauty_transition_fail_closed: clip_A + clip_A, dissolve 0.5s, first
//                                                  clip beauty 0.5 -> fails closed before
//                                                  pass-1 (UNSUPPORTED_EXPORT_FEATURE /
//                                                  gles_transition_not_eligible -- the
//                                                  selector's transition-force seam takes
//                                                  priority for this non-hard-cut-transition
//                                                  scope, see AndroidExportRenderBackendSelector)
//   Lane forced_gles_beauty_still_fail_closed    : still_C alone, beauty 0.5 -> fails closed
//                                                  before pass-1 (UNSUPPORTED_EXPORT_FEATURE /
//                                                  gles_beauty_not_eligible)
//   Lane forced_gles_beauty_rotated_fail_closed  : clip_B (rotated) alone, beauty 0.5 -> fails
//                                                  closed before pass-1 (UNSUPPORTED_EXPORT_FEATURE /
//                                                  gles_beauty_not_eligible)
//
// Emits ANDROID_TIMELINE_GLES_BEAUTY_EXPORT_JSON:<json> and the
// ANDROID_TIMELINE_GLES_BEAUTY_EXPORT_PHYSICAL_SMOKE_PASS/FAIL marker, then
// exits 0/1.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_timeline_beauty_export_smoke.dart';

void main() {
  runApp(const AndroidTimelineGlesBeautyExportSmokeApp());
}

class AndroidTimelineGlesBeautyExportSmokeApp extends StatefulWidget {
  const AndroidTimelineGlesBeautyExportSmokeApp({super.key});

  @override
  State<AndroidTimelineGlesBeautyExportSmokeApp> createState() =>
      _AndroidTimelineGlesBeautyExportSmokeAppState();
}

class _AndroidTimelineGlesBeautyExportSmokeAppState
    extends State<AndroidTimelineGlesBeautyExportSmokeApp> {
  static const double _clipTrimEndSeconds = 2.0;

  String _status =
      'Running Android timeline GLES Beauty V2 export physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<File> _copyAsset(String asset, String target) async {
    final data = await rootBundle.load(asset);
    final file = File(target);
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return file;
  }

  void _safeDelete(File file) {
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  Future<void> _runSmoke() async {
    print('ANDROID_TIMELINE_GLES_BEAUTY_EXPORT_SMOKE: START');
    VGTimelineBeautyExportSmokeReport report;
    final tempDir = Directory.systemTemp;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final cleanupTargets = <File>[];

    try {
      final clipA1 = await _copyAsset(
        'assets/manual_test_clips/clip_A.mov',
        '${tempDir.path}/vg_gles_beauty_clipA1_$stamp.mov',
      );
      final clipA2 = await _copyAsset(
        'assets/manual_test_clips/clip_A.mov',
        '${tempDir.path}/vg_gles_beauty_clipA2_$stamp.mov',
      );
      final clipA3 = await _copyAsset(
        'assets/manual_test_clips/clip_A.mov',
        '${tempDir.path}/vg_gles_beauty_clipA3_$stamp.mov',
      );
      final clipRotatedB = await _copyAsset(
        'assets/manual_test_clips/clip_B.mov',
        '${tempDir.path}/vg_gles_beauty_clipB_rotated_$stamp.mov',
      );
      final still = await _copyAsset(
        'assets/manual_test_clips/still_C.png',
        '${tempDir.path}/vg_gles_beauty_still_$stamp.png',
      );
      cleanupTargets.addAll(<File>[
        clipA1,
        clipA2,
        clipA3,
        clipRotatedB,
        still,
      ]);

      VGTimelineBeautyExportSmokeClip videoClip(
        String id,
        String path, {
        Object? beautyIntensity,
      }) => VGTimelineBeautyExportSmokeClip(
        id: id,
        sourcePath: path,
        trimStartSeconds: 0.0,
        trimEndSeconds: _clipTrimEndSeconds,
        beautyIntensity: beautyIntensity,
      );

      final singleOutPath =
          '${tempDir.path}/vg_gles_beauty_export_single_$stamp.mp4';
      cleanupTargets.add(File(singleOutPath));
      cleanupTargets.add(File('$singleOutPath.roi.json'));

      final mixedOutPath =
          '${tempDir.path}/vg_gles_beauty_export_mixed_$stamp.mp4';
      cleanupTargets.add(File(mixedOutPath));
      cleanupTargets.add(File('$mixedOutPath.roi.json'));

      final transitionOutPath =
          '${tempDir.path}/vg_gles_beauty_export_transition_$stamp.mp4';
      cleanupTargets.add(File(transitionOutPath));
      cleanupTargets.add(File('$transitionOutPath.roi.json'));

      final stillOutPath =
          '${tempDir.path}/vg_gles_beauty_export_still_$stamp.mp4';
      cleanupTargets.add(File(stillOutPath));
      cleanupTargets.add(File('$stillOutPath.roi.json'));

      final rotatedOutPath =
          '${tempDir.path}/vg_gles_beauty_export_rotated_$stamp.mp4';
      cleanupTargets.add(File(rotatedOutPath));
      cleanupTargets.add(File('$rotatedOutPath.roi.json'));

      final requests = <VGTimelineBeautyExportSmokeRequest>[
        VGTimelineBeautyExportSmokeRequest(
          laneId: 'forced_gles_beauty_single_success',
          clips: <VGTimelineBeautyExportSmokeClip>[
            videoClip('clip-a', clipA1.path, beautyIntensity: 0.5),
          ],
          outputPath: singleOutPath,
          expectedRenderBackend: 'gles',
          debugForceRenderBackend: 'gles',
          expectation: const VGTimelineBeautyExportSmokeExpectation.success(
            expectedBeautyClipCount: 1,
            expectedBeautyFrameCount: 60,
          ),
        ),
        VGTimelineBeautyExportSmokeRequest(
          laneId: 'forced_gles_beauty_mixed_success',
          clips: <VGTimelineBeautyExportSmokeClip>[
            videoClip('clip-a', clipA1.path, beautyIntensity: 0.75),
            videoClip('clip-b', clipA2.path),
          ],
          outputPath: mixedOutPath,
          expectedRenderBackend: 'gles',
          debugForceRenderBackend: 'gles',
          expectation: const VGTimelineBeautyExportSmokeExpectation.success(
            expectedBeautyClipCount: 1,
            expectedBeautyFrameCount: 60,
          ),
        ),
        VGTimelineBeautyExportSmokeRequest(
          laneId: 'forced_gles_beauty_transition_fail_closed',
          clips: <VGTimelineBeautyExportSmokeClip>[
            videoClip('clip-a', clipA1.path, beautyIntensity: 0.5),
            videoClip('clip-b', clipA3.path),
          ],
          transitions: const <VGTimelineBeautyExportSmokeTransition>[
            VGTimelineBeautyExportSmokeTransition(
              id: 'tr-dissolve',
              type: 'dissolve',
              durationSeconds: 0.5,
              fromClipId: 'clip-a',
              toClipId: 'clip-b',
            ),
          ],
          outputPath: transitionOutPath,
          expectedRenderBackend: 'gles',
          debugForceRenderBackend: 'gles',
          expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: 'gles_transition_not_eligible',
          ),
        ),
        VGTimelineBeautyExportSmokeRequest(
          laneId: 'forced_gles_beauty_still_fail_closed',
          clips: <VGTimelineBeautyExportSmokeClip>[
            VGTimelineBeautyExportSmokeClip(
              id: 'still-c',
              sourcePath: still.path,
              trimStartSeconds: 0.0,
              trimEndSeconds: _clipTrimEndSeconds,
              mediaKind: 'image',
              beautyIntensity: 0.5,
            ),
          ],
          outputPath: stillOutPath,
          expectedRenderBackend: 'gles',
          debugForceRenderBackend: 'gles',
          expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: 'gles_beauty_not_eligible',
          ),
        ),
        VGTimelineBeautyExportSmokeRequest(
          laneId: 'forced_gles_beauty_rotated_fail_closed',
          clips: <VGTimelineBeautyExportSmokeClip>[
            videoClip(
              'clip-b-rotated',
              clipRotatedB.path,
              beautyIntensity: 0.5,
            ),
          ],
          outputPath: rotatedOutPath,
          expectedRenderBackend: 'gles',
          debugForceRenderBackend: 'gles',
          expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: 'gles_beauty_not_eligible',
          ),
        ),
      ];

      report = await const VGTimelineBeautyExportSmokeRunner().run(requests);
      for (final lane in report.lanes) {
        if (lane.outputPath != null && lane.outputPath!.isNotEmpty) {
          cleanupTargets.add(File(lane.outputPath!));
          cleanupTargets.add(File('${lane.outputPath!}.roi.json'));
        }
        print(
          'ANDROID_TIMELINE_GLES_BEAUTY_EXPORT_LANE:${jsonEncode(lane.toMap())}',
        );
      }
    } catch (error, stack) {
      print('ANDROID_TIMELINE_GLES_BEAUTY_EXPORT_ERROR: $error\n$stack');
      report = VGTimelineBeautyExportSmokeReport(
        lanes: <VGTimelineBeautyExportSmokeLaneReport>[
          VGTimelineBeautyExportSmokeLaneReport(
            laneId: 'harness',
            pass: false,
            status: 'FAIL',
            failureReason: 'harness_exception:$error',
            expectedSuccess: true,
            expectedDurationSeconds: 0.0,
          ),
        ],
      );
    } finally {
      for (final file in cleanupTargets) {
        _safeDelete(file);
      }
    }

    final marker = report.pass
        ? 'ANDROID_TIMELINE_GLES_BEAUTY_EXPORT_PHYSICAL_SMOKE_PASS'
        : 'ANDROID_TIMELINE_GLES_BEAUTY_EXPORT_PHYSICAL_SMOKE_FAIL';
    final payload = report.toMap();
    payload['proofBoundary'] =
        'production_exportTimeline_gles_beauty_v2_forced_route_a_no_vulkan_no_app';
    payload['marker'] = marker;
    print('ANDROID_TIMELINE_GLES_BEAUTY_EXPORT_JSON:${jsonEncode(payload)}');
    print(marker);

    if (mounted) {
      setState(() {
        _status = report.pass
            ? 'PASS\n${report.lanes.map((l) => '${l.laneId}: ${l.status} '
                  'backend=${l.renderBackend ?? '-'} '
                  'dur=${l.durationSeconds?.toStringAsFixed(3) ?? '-'}').join('\n')}'
            : 'FAIL: ${report.failureReason}';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(report.pass ? 0 : 1);
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
