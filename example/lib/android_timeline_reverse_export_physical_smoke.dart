// android_timeline_reverse_export_physical_smoke.dart
// Vanguard Media Engine -- P5-REVERSE-EXPORT-EXACT-GLES-ROUTE (parent backlog
// item P5-REVERSE-SIDECAR / reverse export parity):
// Android production `exportTimeline` narrow reversed-video export physical
// proof.
//
// Proof boundary: production_exportTimeline_gles_reverse_video_route
//
// Drives the REAL production `exportTimeline` MethodChannel route (no
// diagnostic native path, and this route never consumes
// AndroidReverseSidecarCoordinator/Transcoder preview output) with temp
// copies of clip_A.mov (rotation 0), clip_B.mov (rotation -90), and
// still_C.png:
//   Lane single_reversed              : one reversed video clip (clip_A) ->
//                                       success, renderBackend=gles,
//                                       duration ~= 2.0.
//   Lane mixed_forward_reversed       : one forward + one reversed hard-cut
//                                       clip (clip_A, 1.0s each) -> success,
//                                       renderBackend=gles, duration ~= 2.0.
//   Lane reversed_color_matrix        : one reversed clip (clip_A) with an
//                                       identity colorMatrix -> success,
//                                       renderBackend=gles.
//   Lane reversed_rotation_fail_closed: a reversed clip with rotation metadata
//                                       (clip_B) -> fail closed with
//                                       UNSUPPORTED_EXPORT_FEATURE.
//   Lane reversed_transition          : a reversed clip alongside a non-empty
//                                       transition list -> fail closed with
//                                       UNSUPPORTED_EXPORT_FEATURE.
//   Lane reversed_overlay             : a reversed clip alongside a sticker
//                                       overlay -> fail closed with
//                                       UNSUPPORTED_EXPORT_FEATURE.
//   Lane reversed_beauty              : a reversed clip with clip-level Beauty V2
//                                       -> fail closed with
//                                       UNSUPPORTED_EXPORT_FEATURE.
//   Lane reversed_audio_sidecar       : a reversed clip alongside a
//                                       draft.audioSidecar track -> fail closed
//                                       with UNSUPPORTED_EXPORT_FEATURE.
//   Lane image_reversed               : a still-image clip with isReversed=true
//                                       -> fail closed with INVALID_ARG.
//
// Emits ANDROID_TIMELINE_REVERSE_EXPORT_JSON:<json> and the PASS/FAIL
// marker, then exits 0/1. Cleans up only the temp files/directory this
// harness itself created.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_timeline_reverse_export_smoke.dart';

void main() {
  runApp(const AndroidTimelineReverseExportSmokeApp());
}

class AndroidTimelineReverseExportSmokeApp extends StatefulWidget {
  const AndroidTimelineReverseExportSmokeApp({super.key});

  @override
  State<AndroidTimelineReverseExportSmokeApp> createState() =>
      _AndroidTimelineReverseExportSmokeAppState();
}

class _AndroidTimelineReverseExportSmokeAppState
    extends State<AndroidTimelineReverseExportSmokeApp> {
  static const double _clipTrimEndSeconds = 2.0;
  static const double _halfClipTrimEndSeconds = 1.0;
  static const List<double> _identityColorMatrix = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ];

  String _status = 'Running Android timeline reverse export physical smoke...';

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
    print('ANDROID_TIMELINE_REVERSE_EXPORT_SMOKE: START');
    VGTimelineReverseExportSmokeReport report;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final workDir = Directory(
      '${Directory.systemTemp.path}/vg_reverse_export_smoke_$stamp',
    );
    final cleanupFiles = <File>[];

    try {
      workDir.createSync(recursive: true);

      final clipA = await _copyAsset(
        'assets/manual_test_clips/clip_A.mov',
        '${workDir.path}/vg_reverse_export_clipA_$stamp.mov',
      );
      final clipB = await _copyAsset(
        'assets/manual_test_clips/clip_B.mov',
        '${workDir.path}/vg_reverse_export_clipB_$stamp.mov',
      );
      final still = await _copyAsset(
        'assets/manual_test_clips/still_C.png',
        '${workDir.path}/vg_reverse_export_still_$stamp.png',
      );
      cleanupFiles.addAll(<File>[clipA, clipB, still]);

      VGTimelineReverseExportSmokeClip videoClip(
        String id,
        String path, {
        double end = _clipTrimEndSeconds,
        bool isReversed = false,
        List<double>? colorMatrix,
        double? beautyIntensity,
      }) => VGTimelineReverseExportSmokeClip(
        id: id,
        sourcePath: path,
        trimStartSeconds: 0.0,
        trimEndSeconds: end,
        isReversed: isReversed,
        colorMatrix: colorMatrix,
        beautyIntensity: beautyIntensity,
      );

      final requests = <VGTimelineReverseExportSmokeRequest>[
        VGTimelineReverseExportSmokeRequest(
          laneId: 'single_reversed',
          clips: <VGTimelineReverseExportSmokeClip>[
            videoClip('clip-a', clipA.path, isReversed: true),
          ],
          outputPath: '${workDir.path}/vg_reverse_export_single_$stamp.mp4',
          expectation: const VGTimelineReverseExportSmokeExpectation.success(),
        ),
        VGTimelineReverseExportSmokeRequest(
          laneId: 'mixed_forward_reversed',
          clips: <VGTimelineReverseExportSmokeClip>[
            videoClip('clip-a', clipA.path, end: _halfClipTrimEndSeconds),
            videoClip(
              'clip-b',
              clipA.path,
              end: _halfClipTrimEndSeconds,
              isReversed: true,
            ),
          ],
          outputPath: '${workDir.path}/vg_reverse_export_mixed_$stamp.mp4',
          expectation: const VGTimelineReverseExportSmokeExpectation.success(),
        ),
        VGTimelineReverseExportSmokeRequest(
          laneId: 'reversed_color_matrix',
          clips: <VGTimelineReverseExportSmokeClip>[
            videoClip(
              'clip-a',
              clipA.path,
              isReversed: true,
              colorMatrix: _identityColorMatrix,
            ),
          ],
          outputPath:
              '${workDir.path}/vg_reverse_export_colormatrix_$stamp.mp4',
          expectation: const VGTimelineReverseExportSmokeExpectation.success(),
        ),
        VGTimelineReverseExportSmokeRequest(
          laneId: 'reversed_rotation_fail_closed',
          clips: <VGTimelineReverseExportSmokeClip>[
            videoClip('clip-b', clipB.path, isReversed: true),
          ],
          outputPath: '${workDir.path}/vg_reverse_export_rotation_$stamp.mp4',
          expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: reversedClipsWithRotationToken,
          ),
        ),
        VGTimelineReverseExportSmokeRequest(
          laneId: 'reversed_transition',
          clips: <VGTimelineReverseExportSmokeClip>[
            videoClip('clip-a', clipA.path, isReversed: true),
            videoClip('clip-b', clipB.path),
          ],
          transitions: const <VGTimelineReverseExportSmokeTransition>[
            VGTimelineReverseExportSmokeTransition(
              id: 'tr-1',
              type: 'dissolve',
              durationSeconds: 0.5,
              fromClipId: 'clip-a',
              toClipId: 'clip-b',
            ),
          ],
          outputPath: '${workDir.path}/vg_reverse_export_transition_$stamp.mp4',
          expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: reversedClipsWithTransitionsToken,
          ),
        ),
        VGTimelineReverseExportSmokeRequest(
          laneId: 'reversed_overlay',
          clips: <VGTimelineReverseExportSmokeClip>[
            videoClip('clip-a', clipA.path, isReversed: true),
          ],
          overlays: <VGTimelineReverseExportSmokeOverlay>[
            VGTimelineReverseExportSmokeOverlay(
              id: 'ov-1',
              assetPath: still.path,
            ),
          ],
          outputPath: '${workDir.path}/vg_reverse_export_overlay_$stamp.mp4',
          expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: reversedClipsWithOverlaysToken,
          ),
        ),
        VGTimelineReverseExportSmokeRequest(
          laneId: 'reversed_beauty',
          clips: <VGTimelineReverseExportSmokeClip>[
            videoClip(
              'clip-a',
              clipA.path,
              isReversed: true,
              beautyIntensity: 0.5,
            ),
          ],
          outputPath: '${workDir.path}/vg_reverse_export_beauty_$stamp.mp4',
          expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: reversedClipsWithBeautyToken,
          ),
        ),
        VGTimelineReverseExportSmokeRequest(
          laneId: 'reversed_audio_sidecar',
          clips: <VGTimelineReverseExportSmokeClip>[
            videoClip('clip-a', clipA.path, isReversed: true),
          ],
          audioTracks: const <VGTimelineReverseExportSmokeAudioTrack>[
            VGTimelineReverseExportSmokeAudioTrack(
              trackId: 'track-1',
              url: '/data/local/tmp/vg_reverse_export_audio_not_used.m4a',
            ),
          ],
          outputPath:
              '${workDir.path}/vg_reverse_export_audio_sidecar_$stamp.mp4',
          expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: reversedClipsWithAudioTracksToken,
          ),
        ),
        VGTimelineReverseExportSmokeRequest(
          laneId: 'image_reversed',
          clips: <VGTimelineReverseExportSmokeClip>[
            VGTimelineReverseExportSmokeClip(
              id: 'still-c',
              sourcePath: still.path,
              trimStartSeconds: 0.0,
              trimEndSeconds: _clipTrimEndSeconds,
              mediaKind: 'image',
              isReversed: true,
            ),
          ],
          outputPath: '${workDir.path}/vg_reverse_export_image_$stamp.mp4',
          expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
            errorCode: invalidArgExportCode,
            messageContains: reversedClipIsReversedToken,
          ),
        ),
      ];

      for (final request in requests) {
        cleanupFiles.add(File(request.outputPath));
        cleanupFiles.add(File('${request.outputPath}.roi.json'));
      }

      report = await const VGTimelineReverseExportSmokeRunner().run(requests);
      for (final lane in report.lanes) {
        print(
          'ANDROID_TIMELINE_REVERSE_EXPORT_LANE:${jsonEncode(lane.toMap())}',
        );
      }
    } catch (error, stack) {
      print('ANDROID_TIMELINE_REVERSE_EXPORT_ERROR: $error\n$stack');
      report = VGTimelineReverseExportSmokeReport(
        lanes: <VGTimelineReverseExportSmokeLaneReport>[
          VGTimelineReverseExportSmokeLaneReport(
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
      for (final file in cleanupFiles) {
        try {
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
      try {
        if (workDir.existsSync()) {
          workDir.deleteSync();
        }
      } catch (_) {}
    }

    final payload = report.toMap();
    print('ANDROID_TIMELINE_REVERSE_EXPORT_JSON:${jsonEncode(payload)}');
    print(report.marker);

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
