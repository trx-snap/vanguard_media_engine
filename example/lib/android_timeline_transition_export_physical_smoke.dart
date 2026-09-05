// android_timeline_transition_export_physical_smoke.dart
// Vanguard Media Engine — P5-COMPOSITOR-TRANS (PRODUCTION-EXPORT-ROUTE):
// Android production `exportTimeline` compositor-owned clip overlap
// transition physical proof.
//
// Proof boundary: production_exportTimeline_vulkan_compositor_transition_overlap_route
//
// Drives the REAL production `exportTimeline` MethodChannel route (no
// diagnostic native path) with two temp copies of clip_B.mov:
//   Lane dissolve   : dissolve 0.5 s   -> success, renderBackend=vulkan,
//                     file exists, duration ~= 2.0 + 2.0 - 0.5
//   Lane crossfade  : crossfade alias  -> same assertions
//   Lane slideLeft  : slide family     -> same assertions
//   Lane wipeRight  : wipe family      -> same assertions
//   Lane dissolve_audio_sidecar_success : dissolve 0.5 s + two audioSidecar
//                     tracks representing each clip's own original audio on
//                     the overlap-adjusted output timeline (P5-TRANSITION-
//                     AUDIO-SIDECAR-EXPORT) -> success, renderBackend=vulkan,
//                     duration ~= 3.5, transitionCount=1, output exists.
//   Lane fade       : `fade` must fail closed (UNSUPPORTED_EXPORT_FEATURE);
//                     it is never remapped to dissolve.
//   Lane noVulkan   : still image + video with a dissolve is outside the
//                     Vulkan safe scope; the selector must resolve to
//                     UNAVAILABLE and the session must fail closed with
//                     UNSUPPORTED_EXPORT_FEATURE / transitions_require_vulkan
//                     instead of re-encoding hard cuts through GLES.
// Cancel lane: intentionally omitted (reported as P2) -- a real mid-export
// cancel needs a second concurrent MethodChannel call timed against pass-1
// and is out of this harness's scope; it is not faked.
//
// Emits ANDROID_TIMELINE_TRANSITION_EXPORT_JSON:<json> and the PASS/FAIL
// marker, then exits 0/1.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_timeline_transition_export_smoke.dart';

void main() {
  runApp(const AndroidTimelineTransitionExportSmokeApp());
}

class AndroidTimelineTransitionExportSmokeApp extends StatefulWidget {
  const AndroidTimelineTransitionExportSmokeApp({super.key});

  @override
  State<AndroidTimelineTransitionExportSmokeApp> createState() =>
      _AndroidTimelineTransitionExportSmokeAppState();
}

class _AndroidTimelineTransitionExportSmokeAppState
    extends State<AndroidTimelineTransitionExportSmokeApp> {
  static const double _clipTrimEndSeconds = 2.0;
  static const double _transitionSeconds = 0.5;

  String _status =
      'Running Android timeline transition export physical smoke...';

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
    print('ANDROID_TIMELINE_TRANSITION_EXPORT_SMOKE: START');
    VGTimelineTransitionExportSmokeReport report;
    final tempDir = Directory.systemTemp;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final createdFiles = <File>[];

    try {
      final clipA = await _copyAsset(
        'assets/manual_test_clips/clip_B.mov',
        '${tempDir.path}/vg_trans_export_clipA_$stamp.mov',
      );
      final clipB = await _copyAsset(
        'assets/manual_test_clips/clip_B.mov',
        '${tempDir.path}/vg_trans_export_clipB_$stamp.mov',
      );
      final still = await _copyAsset(
        'assets/manual_test_clips/still_C.png',
        '${tempDir.path}/vg_trans_export_still_$stamp.png',
      );
      createdFiles.addAll(<File>[clipA, clipB, still]);

      VGTimelineTransitionExportSmokeClip videoClip(String id, String path) =>
          VGTimelineTransitionExportSmokeClip(
            id: id,
            sourcePath: path,
            trimStartSeconds: 0.0,
            trimEndSeconds: _clipTrimEndSeconds,
          );

      VGTimelineTransitionExportSmokeRequest positiveLane(String type) =>
          VGTimelineTransitionExportSmokeRequest(
            laneId: type,
            clips: <VGTimelineTransitionExportSmokeClip>[
              videoClip('clip-a', clipA.path),
              videoClip('clip-b', clipB.path),
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
            outputPath: '${tempDir.path}/vg_trans_export_${type}_$stamp.mp4',
            expectation:
                const VGTimelineTransitionExportSmokeExpectation.success(),
          );

      final requests = <VGTimelineTransitionExportSmokeRequest>[
        positiveLane('dissolve'),
        positiveLane('crossfade'),
        positiveLane('slideLeft'),
        positiveLane('wipeRight'),
        VGTimelineTransitionExportSmokeRequest(
          laneId: 'dissolve_audio_sidecar_success',
          clips: <VGTimelineTransitionExportSmokeClip>[
            videoClip('clip-a', clipA.path),
            videoClip('clip-b', clipB.path),
          ],
          transitions: <VGTimelineTransitionExportSmokeTransition>[
            VGTimelineTransitionExportSmokeTransition(
              id: 'tr-dissolve-audio-sidecar',
              type: 'dissolve',
              durationSeconds: _transitionSeconds,
              fromClipId: 'clip-a',
              toClipId: 'clip-b',
            ),
          ],
          // Original clip audio on the overlap-adjusted output timeline:
          // clip-a occupies [0.0, 2.0) fading out into the overlap, clip-b
          // occupies [1.5, 3.5) fading in out of it -- the same shape
          // flattenOriginalClipAudio produces for a transition timeline.
          audioSidecarTracks: <VGTimelineTransitionExportSmokeAudioTrack>[
            VGTimelineTransitionExportSmokeAudioTrack(
              trackId: 'audio-clip-a',
              url: clipA.path,
              startTime: 0.0,
              duration: _clipTrimEndSeconds,
              fadeOutSeconds: _transitionSeconds,
            ),
            VGTimelineTransitionExportSmokeAudioTrack(
              trackId: 'audio-clip-b',
              url: clipB.path,
              startTime: _clipTrimEndSeconds - _transitionSeconds,
              duration: _clipTrimEndSeconds,
              fadeInSeconds: _transitionSeconds,
            ),
          ],
          outputPath:
              '${tempDir.path}/vg_trans_export_dissolve_audio_sidecar_success_$stamp.mp4',
          expectation:
              const VGTimelineTransitionExportSmokeExpectation.success(),
        ),
        VGTimelineTransitionExportSmokeRequest(
          laneId: 'fade_fail_closed',
          clips: <VGTimelineTransitionExportSmokeClip>[
            videoClip('clip-a', clipA.path),
            videoClip('clip-b', clipB.path),
          ],
          transitions: const <VGTimelineTransitionExportSmokeTransition>[
            VGTimelineTransitionExportSmokeTransition(
              id: 'tr-fade',
              type: 'fade',
              durationSeconds: _transitionSeconds,
              fromClipId: 'clip-a',
              toClipId: 'clip-b',
            ),
          ],
          outputPath: '${tempDir.path}/vg_trans_export_fade_$stamp.mp4',
          expectation:
              const VGTimelineTransitionExportSmokeExpectation.failClosed(
                errorCode: unsupportedExportFeatureCode,
                messageContains: 'not supported',
              ),
        ),
        VGTimelineTransitionExportSmokeRequest(
          laneId: 'no_vulkan_no_gles_fallback',
          clips: <VGTimelineTransitionExportSmokeClip>[
            VGTimelineTransitionExportSmokeClip(
              id: 'still-c',
              sourcePath: still.path,
              trimStartSeconds: 0.0,
              trimEndSeconds: _clipTrimEndSeconds,
              mediaKind: 'image',
            ),
            videoClip('clip-b', clipB.path),
          ],
          transitions: const <VGTimelineTransitionExportSmokeTransition>[
            VGTimelineTransitionExportSmokeTransition(
              id: 'tr-still',
              type: 'dissolve',
              durationSeconds: _transitionSeconds,
              fromClipId: 'still-c',
              toClipId: 'clip-b',
            ),
          ],
          outputPath: '${tempDir.path}/vg_trans_export_novulkan_$stamp.mp4',
          expectation:
              const VGTimelineTransitionExportSmokeExpectation.failClosed(
                errorCode: unsupportedExportFeatureCode,
                messageContains: transitionsRequireVulkanReason,
              ),
        ),
      ];

      report = await const VGTimelineTransitionExportSmokeRunner().run(
        requests,
      );
      for (final lane in report.lanes) {
        print(
          'ANDROID_TIMELINE_TRANSITION_EXPORT_LANE:${jsonEncode(lane.toMap())}',
        );
      }
    } catch (error, stack) {
      print('ANDROID_TIMELINE_TRANSITION_EXPORT_ERROR: $error\n$stack');
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
    }

    final payload = report.toMap();
    payload['cancelLane'] = 'omitted_p2_not_faked';
    print('ANDROID_TIMELINE_TRANSITION_EXPORT_JSON:${jsonEncode(payload)}');
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
