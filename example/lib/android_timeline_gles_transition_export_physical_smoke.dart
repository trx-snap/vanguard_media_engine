// android_timeline_gles_transition_export_physical_smoke.dart
// Vanguard Media Engine — P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A,
// widened by P5-GLES-EXPORT-TRANSITION-SLIDE-WIPE,
// P5-GLES-EXPORT-TRANSITION-ROTATED-CLIPS, and
// P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS:
// Android production `exportTimeline` GLES forced transition route proof.
//
// Proof boundary: production_exportTimeline_gles_transition_slide_wipe_rotated_forced_route_a_no_vulkan_no_app
//
// Drives the REAL production `exportTimeline` MethodChannel route with top-level
// `debugForceRenderBackend: gles` using clip_A.mov copies (zero-rotation
// success fixture), clip_B.mov (real standard-rotation-metadata success
// fixture), and still_C.png copies:
//   Lane forced dissolve success   : dissolve 0.5 s (clip_A + clip_A) -> success,
//                                    renderBackend=gles, file exists,
//                                    duration ~= 3.5, transitionCount=1
//   Lane forced crossfade success  : crossfade 0.5 s (clip_A + clip_A) -> same expectations
//   Lane forced fade success       : fade 0.5 s (clip_A + clip_A) -> same expectations
//                                    (true fade through black supported on GLES)
//   Lane forced slideLeft success  : slideLeft 0.5 s (clip_A + clip_A) -> same expectations
//   Lane forced wipeRight success  : wipeRight 0.5 s (clip_A + clip_A) -> same expectations
//   Lane forced rotated clip success: dissolve 0.5 s (clip_A + rotated clip_B) -> success,
//                                    renderBackend=gles, file exists,
//                                    duration ~= 3.5, transitionCount=1 -- proves the
//                                    rotated fit-quad geometry (ported from
//                                    AndroidTimelineVideoEncoder's hard-cut path) renders
//                                    a real clip carrying standard Android rotation
//                                    metadata correctly on this route
//   Lane forced still-image dissolve success: image + video (still_C + clip_A) -> success,
//                                    renderBackend=gles, file exists,
//                                    duration ~= 3.5, transitionCount=1 -- proves
//                                    AndroidTimelineGlesTransitionImageRenderer's mixed
//                                    image/video overlap resolve path
//                                    (P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS)
//   Lane forced still-to-still dissolve success: image + image (still_C + still_C) -> success,
//                                    renderBackend=gles, file exists,
//                                    duration ~= 3.5, transitionCount=1 -- proves the
//                                    static image/image overlap resolve path
//
// Emits ANDROID_TIMELINE_GLES_TRANSITION_EXPORT_JSON:<json> and the
// ANDROID_TIMELINE_GLES_TRANSITION_EXPORT_PHYSICAL_SMOKE_PASS/FAIL marker, then
// exits 0/1.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_timeline_transition_export_smoke.dart';

void main() {
  runApp(const AndroidTimelineGlesTransitionExportSmokeApp());
}

class AndroidTimelineGlesTransitionExportSmokeApp extends StatefulWidget {
  const AndroidTimelineGlesTransitionExportSmokeApp({super.key});

  @override
  State<AndroidTimelineGlesTransitionExportSmokeApp> createState() =>
      _AndroidTimelineGlesTransitionExportSmokeAppState();
}

class _AndroidTimelineGlesTransitionExportSmokeAppState
    extends State<AndroidTimelineGlesTransitionExportSmokeApp> {
  static const double _clipTrimEndSeconds = 2.0;
  static const double _transitionSeconds = 0.5;

  String _status =
      'Running Android timeline GLES transition export physical smoke...';

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
    print('ANDROID_TIMELINE_GLES_TRANSITION_EXPORT_SMOKE: START');
    VGTimelineTransitionExportSmokeReport report;
    final tempDir = Directory.systemTemp;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final cleanupTargets = <File>[];

    try {
      final clipA1 = await _copyAsset(
        'assets/manual_test_clips/clip_A.mov',
        '${tempDir.path}/vg_gles_trans_clipA1_$stamp.mov',
      );
      final clipA2 = await _copyAsset(
        'assets/manual_test_clips/clip_A.mov',
        '${tempDir.path}/vg_gles_trans_clipA2_$stamp.mov',
      );
      final clipRotatedB = await _copyAsset(
        'assets/manual_test_clips/clip_B.mov',
        '${tempDir.path}/vg_gles_trans_clipB_rotated_$stamp.mov',
      );
      final still1 = await _copyAsset(
        'assets/manual_test_clips/still_C.png',
        '${tempDir.path}/vg_gles_trans_still1_$stamp.png',
      );
      final still2 = await _copyAsset(
        'assets/manual_test_clips/still_C.png',
        '${tempDir.path}/vg_gles_trans_still2_$stamp.png',
      );
      cleanupTargets.addAll(<File>[
        clipA1,
        clipA2,
        clipRotatedB,
        still1,
        still2,
      ]);

      VGTimelineTransitionExportSmokeClip imageClip(String id, String path) =>
          VGTimelineTransitionExportSmokeClip(
            id: id,
            sourcePath: path,
            trimStartSeconds: 0.0,
            trimEndSeconds: _clipTrimEndSeconds,
            mediaKind: 'image',
          );

      VGTimelineTransitionExportSmokeClip videoClip(String id, String path) =>
          VGTimelineTransitionExportSmokeClip(
            id: id,
            sourcePath: path,
            trimStartSeconds: 0.0,
            trimEndSeconds: _clipTrimEndSeconds,
          );

      VGTimelineTransitionExportSmokeRequest positiveLane(String type) {
        final outPath =
            '${tempDir.path}/vg_gles_trans_export_${type}_$stamp.mp4';
        cleanupTargets.add(File(outPath));
        cleanupTargets.add(File('$outPath.roi.json'));
        return VGTimelineTransitionExportSmokeRequest(
          laneId: 'forced_${type}_success',
          clips: <VGTimelineTransitionExportSmokeClip>[
            videoClip('clip-a', clipA1.path),
            videoClip('clip-b', clipA2.path),
          ],
          transitions: <VGTimelineTransitionExportSmokeTransition>[
            VGTimelineTransitionExportSmokeTransition(
              id: 'tr-$type',
              type: type,
              durationSeconds: _transitionSeconds,
              fromClipId: 'clip-a',
              toClipId: 'clip-b',
            ),
          ],
          outputPath: outPath,
          expectedRenderBackend: 'gles',
          debugForceRenderBackend: 'gles',
          expectation:
              const VGTimelineTransitionExportSmokeExpectation.success(),
        );
      }

      final stillOutPath =
          '${tempDir.path}/vg_gles_trans_export_still_dissolve_$stamp.mp4';
      cleanupTargets.add(File(stillOutPath));
      cleanupTargets.add(File('$stillOutPath.roi.json'));

      final stillToStillOutPath =
          '${tempDir.path}/vg_gles_trans_export_still_to_still_dissolve_$stamp.mp4';
      cleanupTargets.add(File(stillToStillOutPath));
      cleanupTargets.add(File('$stillToStillOutPath.roi.json'));

      final rotatedOutPath =
          '${tempDir.path}/vg_gles_trans_export_rotated_$stamp.mp4';
      cleanupTargets.add(File(rotatedOutPath));
      cleanupTargets.add(File('$rotatedOutPath.roi.json'));

      final requests = <VGTimelineTransitionExportSmokeRequest>[
        positiveLane('dissolve'),
        positiveLane('crossfade'),
        positiveLane('fade'),
        positiveLane('slideLeft'),
        positiveLane('wipeRight'),
        VGTimelineTransitionExportSmokeRequest(
          laneId: 'forced_still_image_dissolve_success',
          clips: <VGTimelineTransitionExportSmokeClip>[
            imageClip('still-c', still1.path),
            videoClip('clip-b', clipA2.path),
          ],
          transitions: const <VGTimelineTransitionExportSmokeTransition>[
            VGTimelineTransitionExportSmokeTransition(
              id: 'tr-still-dissolve',
              type: 'dissolve',
              durationSeconds: _transitionSeconds,
              fromClipId: 'still-c',
              toClipId: 'clip-b',
            ),
          ],
          outputPath: stillOutPath,
          expectedRenderBackend: 'gles',
          debugForceRenderBackend: 'gles',
          expectation:
              const VGTimelineTransitionExportSmokeExpectation.success(),
        ),
        VGTimelineTransitionExportSmokeRequest(
          laneId: 'forced_still_to_still_dissolve_success',
          clips: <VGTimelineTransitionExportSmokeClip>[
            imageClip('still-a', still1.path),
            imageClip('still-b', still2.path),
          ],
          transitions: const <VGTimelineTransitionExportSmokeTransition>[
            VGTimelineTransitionExportSmokeTransition(
              id: 'tr-still-to-still-dissolve',
              type: 'dissolve',
              durationSeconds: _transitionSeconds,
              fromClipId: 'still-a',
              toClipId: 'still-b',
            ),
          ],
          outputPath: stillToStillOutPath,
          expectedRenderBackend: 'gles',
          debugForceRenderBackend: 'gles',
          expectation:
              const VGTimelineTransitionExportSmokeExpectation.success(),
        ),
        VGTimelineTransitionExportSmokeRequest(
          laneId: 'forced_rotated_clip_success',
          clips: <VGTimelineTransitionExportSmokeClip>[
            videoClip('clip-a', clipA1.path),
            videoClip('clip-b', clipRotatedB.path),
          ],
          transitions: const <VGTimelineTransitionExportSmokeTransition>[
            VGTimelineTransitionExportSmokeTransition(
              id: 'tr-rotated-clip',
              type: 'dissolve',
              durationSeconds: _transitionSeconds,
              fromClipId: 'clip-a',
              toClipId: 'clip-b',
            ),
          ],
          outputPath: rotatedOutPath,
          expectedRenderBackend: 'gles',
          debugForceRenderBackend: 'gles',
          expectation:
              const VGTimelineTransitionExportSmokeExpectation.success(),
        ),
      ];

      report = await const VGTimelineTransitionExportSmokeRunner().run(
        requests,
      );
      for (final lane in report.lanes) {
        if (lane.outputPath != null && lane.outputPath!.isNotEmpty) {
          cleanupTargets.add(File(lane.outputPath!));
          cleanupTargets.add(File('${lane.outputPath!}.roi.json'));
        }
        print(
          'ANDROID_TIMELINE_GLES_TRANSITION_EXPORT_LANE:${jsonEncode(lane.toMap())}',
        );
      }
    } catch (error, stack) {
      print('ANDROID_TIMELINE_GLES_TRANSITION_EXPORT_ERROR: $error\n$stack');
      report = VGTimelineTransitionExportSmokeReport(
        lanes: <VGTimelineTransitionExportSmokeLaneReport>[
          VGTimelineTransitionExportSmokeLaneReport(
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
        ? 'ANDROID_TIMELINE_GLES_TRANSITION_EXPORT_PHYSICAL_SMOKE_PASS'
        : 'ANDROID_TIMELINE_GLES_TRANSITION_EXPORT_PHYSICAL_SMOKE_FAIL';
    final payload = report.toMap();
    payload['proofBoundary'] =
        'production_exportTimeline_gles_transition_slide_wipe_rotated_forced_route_a_no_vulkan_no_app';
    payload['marker'] = marker;
    print(
      'ANDROID_TIMELINE_GLES_TRANSITION_EXPORT_JSON:${jsonEncode(payload)}',
    );
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
