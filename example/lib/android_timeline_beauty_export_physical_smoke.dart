// android_timeline_beauty_export_physical_smoke.dart
// Vanguard Media Engine — P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A:
// Android production `exportTimeline` Beauty V2 smoke physical proof.
//
// Proof boundary: production_exportTimeline_vulkan_beauty_v2_route
//
// Drives the REAL production `exportTimeline` MethodChannel route (no
// diagnostic native path) with temp copies of registered assets:
//   Lane 1: beauty_soft_single               -> 1 video clip, trim 0..2s, beauty 0.5
//                                              success, backend vulkan, duration ~2.0,
//                                              beautyClipCount 1, beautyFrameCount >0
//   Lane 2: beauty_hard_cut_mixed            -> 2 video clips, no transitions, first beauty 0.75,
//                                              second null, success, duration ~4.0,
//                                              beautyClipCount 1, beautyFrameCount >0
//   Lane 3: beauty_transition_fail_closed    -> 2 video clips, beauty 0.5 on clip 1, dissolve 0.5s,
//                                              expect UNSUPPORTED_EXPORT_FEATURE,
//                                              token `beauty_v2_unsupported_with_transition`
//   Lane 4: beauty_invalid_negative          -> raw beauty -0.1, expect INVALID_ARG,
//                                              token `beautyIntensity`
//   Lane 5: beauty_non_vulkan_scope_fail_closed -> still image clip, beauty 0.5, no transition,
//                                              expect UNSUPPORTED_EXPORT_FEATURE,
//                                              token `beauty_v2_requires_vulkan`
//
// Boundary: real production MethodChannel `exportTimeline`; no diagnostic native method.
// Claims only production routing/fail-closed behavior on Android, not pixel quality, fleet,
// playback, GLES beauty, transitions+beauty, app/editor UI, iOS, or streaming/cache.
//
// Emits ANDROID_TIMELINE_BEAUTY_EXPORT_JSON:<json> and the PASS/FAIL marker, then exits 0/1.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_timeline_beauty_export_smoke.dart';

void main() {
  runApp(const AndroidTimelineBeautyExportSmokeApp());
}

class AndroidTimelineBeautyExportSmokeApp extends StatefulWidget {
  const AndroidTimelineBeautyExportSmokeApp({super.key});

  @override
  State<AndroidTimelineBeautyExportSmokeApp> createState() =>
      _AndroidTimelineBeautyExportSmokeAppState();
}

class _AndroidTimelineBeautyExportSmokeAppState
    extends State<AndroidTimelineBeautyExportSmokeApp> {
  static const double _clipTrimEndSeconds = 2.0;

  String _status =
      'Running Android timeline Beauty V2 export physical smoke...';

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

  Future<void> _runSmoke() async {
    print('ANDROID_TIMELINE_BEAUTY_EXPORT_SMOKE: START');
    VGTimelineBeautyExportSmokeReport report;
    final tempDir = Directory.systemTemp;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final createdFiles = <File>[];

    try {
      final clipA = await _copyAsset(
        'assets/manual_test_clips/clip_B.mov',
        '${tempDir.path}/vg_beauty_export_clipA_$stamp.mov',
      );
      final clipB = await _copyAsset(
        'assets/manual_test_clips/clip_B.mov',
        '${tempDir.path}/vg_beauty_export_clipB_$stamp.mov',
      );
      final still = await _copyAsset(
        'assets/manual_test_clips/still_C.png',
        '${tempDir.path}/vg_beauty_export_still_$stamp.png',
      );
      createdFiles.addAll(<File>[clipA, clipB, still]);

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

      String laneOutputPath(String laneId) {
        final path = '${tempDir.path}/vg_beauty_export_${laneId}_$stamp.mp4';
        createdFiles.add(File(path));
        createdFiles.add(File('$path.roi.json'));
        return path;
      }

      final requests = <VGTimelineBeautyExportSmokeRequest>[
        // Lane 1: beauty_soft_single
        VGTimelineBeautyExportSmokeRequest(
          laneId: 'beauty_soft_single',
          clips: <VGTimelineBeautyExportSmokeClip>[
            videoClip('clip-1', clipA.path, beautyIntensity: 0.5),
          ],
          outputPath: laneOutputPath('beauty_soft_single'),
          expectation: const VGTimelineBeautyExportSmokeExpectation.success(
            expectedBeautyClipCount: 1,
            expectedBeautyFrameCountPositive: true,
          ),
        ),

        // Lane 2: beauty_hard_cut_mixed
        VGTimelineBeautyExportSmokeRequest(
          laneId: 'beauty_hard_cut_mixed',
          clips: <VGTimelineBeautyExportSmokeClip>[
            videoClip('clip-1', clipA.path, beautyIntensity: 0.75),
            videoClip('clip-2', clipB.path, beautyIntensity: null),
          ],
          outputPath: laneOutputPath('beauty_hard_cut_mixed'),
          expectation: const VGTimelineBeautyExportSmokeExpectation.success(
            expectedBeautyClipCount: 1,
            expectedBeautyFrameCountPositive: true,
          ),
        ),

        // Lane 3: beauty_transition_fail_closed
        VGTimelineBeautyExportSmokeRequest(
          laneId: 'beauty_transition_fail_closed',
          clips: <VGTimelineBeautyExportSmokeClip>[
            videoClip('clip-1', clipA.path, beautyIntensity: 0.5),
            videoClip('clip-2', clipB.path, beautyIntensity: null),
          ],
          transitions: const <VGTimelineBeautyExportSmokeTransition>[
            VGTimelineBeautyExportSmokeTransition(
              id: 'tr-dissolve',
              type: 'dissolve',
              durationSeconds: 0.5,
              fromClipId: 'clip-1',
              toClipId: 'clip-2',
            ),
          ],
          outputPath: laneOutputPath('beauty_transition_fail_closed'),
          expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: beautyV2UnsupportedWithTransitionToken,
          ),
        ),

        // Lane 4: beauty_invalid_negative
        VGTimelineBeautyExportSmokeRequest(
          laneId: 'beauty_invalid_negative',
          clips: <VGTimelineBeautyExportSmokeClip>[
            videoClip('clip-1', clipA.path, beautyIntensity: -0.1),
          ],
          outputPath: laneOutputPath('beauty_invalid_negative'),
          expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
            errorCode: invalidArgCode,
            messageContains: beautyIntensityToken,
          ),
        ),

        // Lane 5: beauty_non_vulkan_scope_fail_closed
        VGTimelineBeautyExportSmokeRequest(
          laneId: 'beauty_non_vulkan_scope_fail_closed',
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
          outputPath: laneOutputPath('beauty_non_vulkan_scope_fail_closed'),
          expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: beautyV2RequiresVulkanToken,
          ),
        ),
      ];

      report = await const VGTimelineBeautyExportSmokeRunner().run(requests);
      for (final lane in report.lanes) {
        print('$beautyLanePrefix${jsonEncode(lane.toMap())}');
      }
    } catch (error, stack) {
      print('ANDROID_TIMELINE_BEAUTY_EXPORT_ERROR: $error\n$stack');
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
      for (final file in createdFiles) {
        try {
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
    }

    final payload = report.toMap();
    print('$beautyJsonPrefix${jsonEncode(payload)}');
    print(report.marker);

    if (mounted) {
      setState(() {
        _status = report.pass
            ? 'PASS\n${report.lanes.map((l) => '${l.laneId}: ${l.status} '
                  'backend=${l.renderBackend ?? '-'} '
                  'dur=${l.durationSeconds?.toStringAsFixed(3) ?? '-'} '
                  'beautyClips=${l.beautyClipCount ?? '-'} '
                  'beautyFrames=${l.beautyFrameCount ?? '-'}').join('\n')}'
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
