// vg_timeline_overlay_export_smoke_test.dart
// vanguard_media_engine -- P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A:
// production `exportTimeline` static sticker overlay smoke Dart model, serialization,
// report, default suite, and contract unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_overlay_export_smoke.dart';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

VGTimelineOverlayExportSmokeClip _clip(
  String id, {
  double end = 2.0,
  Object? beautyIntensity,
  String mediaKind = 'video',
}) => VGTimelineOverlayExportSmokeClip(
  id: id,
  sourcePath: '/data/local/tmp/$id.mov',
  trimStartSeconds: 0.0,
  trimEndSeconds: end,
  mediaKind: mediaKind,
  beautyIntensity: beautyIntensity,
);

VGTimelineOverlayExportSmokeOverlay _sticker(
  String id, {
  String assetPath = '/data/local/tmp/sticker.png',
  double start = 0.0,
  double duration = 2.0,
  int zIndex = 0,
  double scale = 1.0,
  double opacity = 1.0,
  Object? keyframes,
}) => VGTimelineOverlayExportSmokeOverlay(
  id: id,
  assetPath: assetPath,
  startTimeSeconds: start,
  durationSeconds: duration,
  translationX: 100.0,
  translationY: 100.0,
  width: 200.0,
  height: 200.0,
  rotation: 0.0,
  scale: scale,
  opacity: opacity,
  zIndex: zIndex,
  type: 'sticker',
  keyframes: keyframes,
);

VGTimelineOverlayExportSmokeRequest _request({
  String laneId = 'single_clip_static_sticker_success',
  List<VGTimelineOverlayExportSmokeClip>? clips,
  List<VGTimelineOverlayExportSmokeOverlay>? overlays,
  List<VGTimelineOverlayExportSmokeTransition>? transitions,
  VGTimelineOverlayExportSmokeExpectation expectation =
      const VGTimelineOverlayExportSmokeExpectation.success(),
}) => VGTimelineOverlayExportSmokeRequest(
  laneId: laneId,
  clips: clips ?? <VGTimelineOverlayExportSmokeClip>[_clip('clip-1')],
  overlays: overlays ?? <VGTimelineOverlayExportSmokeOverlay>[_sticker('st-1')],
  transitions: transitions ?? const <VGTimelineOverlayExportSmokeTransition>[],
  outputPath: '/data/local/tmp/out_$laneId.mp4',
  expectation: expectation,
);

Map<String, Object?> _successResult({
  String backend = 'vulkan',
  double duration = 2.0,
  int overlayCount = 1,
  int transitionCount = 0,
  int? renderedOverlayFrameCount,
  int beautyClipCount = 0,
  int beautyFrameCount = 0,
  String path = '/data/local/tmp/out_single_clip_static_sticker_success.mp4',
}) => <String, Object?>{
  'success': true,
  'path': path,
  'durationSeconds': duration,
  'width': 720,
  'height': 1280,
  'fps': 30,
  'renderBackend': backend,
  'overlayCount': overlayCount,
  'transitionCount': transitionCount,
  if (renderedOverlayFrameCount != null)
    'renderedOverlayFrameCount': renderedOverlayFrameCount,
  'beautyClipCount': beautyClipCount,
  'beautyFrameCount': beautyFrameCount,
};

void _setMockHandler(
  Future<Object?> Function(String method, dynamic args) handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        _channel,
        (call) => handler(call.method, call.arguments),
      );
}

void _clearMockHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('constants and proof boundary contract', () {
    test('canonical proof boundary and markers match specification', () {
      expect(
        overlayProofBoundary,
        'production_exportTimeline_vulkan_static_sticker_overlay_route_a',
      );
      expect(
        VGTimelineOverlayExportSmokeReport.proofBoundary,
        'production_exportTimeline_vulkan_static_sticker_overlay_route_a',
      );
      expect(
        overlayPassMarker,
        'ANDROID_TIMELINE_OVERLAY_EXPORT_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGTimelineOverlayExportSmokeReport.passMarker,
        'ANDROID_TIMELINE_OVERLAY_EXPORT_PHYSICAL_SMOKE_PASS',
      );
      expect(
        overlayFailMarker,
        'ANDROID_TIMELINE_OVERLAY_EXPORT_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGTimelineOverlayExportSmokeReport.failMarker,
        'ANDROID_TIMELINE_OVERLAY_EXPORT_PHYSICAL_SMOKE_FAIL',
      );
      expect(VGTimelineOverlayExportSmokeReport.durationToleranceSeconds, 0.25);
      expect(overlayJsonPrefix, 'ANDROID_TIMELINE_OVERLAY_EXPORT_JSON:');
      expect(overlayLanePrefix, 'ANDROID_TIMELINE_OVERLAY_EXPORT_LANE:');
      expect(unsupportedExportFeatureCode, 'UNSUPPORTED_EXPORT_FEATURE');
      expect(invalidArgCode, 'INVALID_ARG');
      expect(fileUnreadableCode, 'FILE_UNREADABLE');
    });

    test('fail-closed tokens and default lane IDs match specification', () {
      expect(textOverlayToken, 'text');
      expect(emojiOverlayToken, 'emoji');
      expect(keyframesToken, 'keyframe');
      expect(overlaysWithBeautyToken, 'beauty');
      expect(unreadableAssetToken, 'asset');

      expect(defaultOverlaySmokeLaneIds, hasLength(14));
      expect(defaultOverlaySmokeLaneIds, <String>[
        'single_clip_static_sticker_success',
        'multi_layer_z_order_success',
        'time_interval_gating_success',
        'hard_cut_multiclip_success',
        'single_clip_dynamic_keyframe_success',
        'fail_closed_text_overlay',
        'fail_closed_emoji_overlay',
        'fail_closed_malformed_keyframes',
        'overlays_with_transition_dissolve_success',
        'overlays_with_transition_slide_left_success',
        'overlays_with_transition_wipe_right_success',
        'overlays_with_beauty_transition_overlap_success',
        'fail_closed_solo_overlays_with_beauty',
        'fail_closed_unreadable_asset',
      ]);
    });
  });

  group('overlay model and toMap serialization', () {
    test('toMap preserves sticker fields and omits keyframes by default', () {
      final sticker = VGTimelineOverlayExportSmokeOverlay(
        id: 'sticker-1',
        assetPath: '/data/local/tmp/star.png',
        startTimeSeconds: 0.5,
        durationSeconds: 2.0,
        translationX: 120.0,
        translationY: 240.0,
        width: 300.0,
        height: 300.0,
        rotation: 1.57,
        scale: 1.25,
        opacity: 0.9,
        zIndex: 3,
        type: 'sticker',
      );

      final map = sticker.toMap();
      expect(map['id'], 'sticker-1');
      expect(map['type'], 'sticker');
      expect(map['assetPath'], '/data/local/tmp/star.png');
      expect(map['startTimeSeconds'], 0.5);
      expect(map['durationSeconds'], 2.0);
      expect(map['translationX'], 120.0);
      expect(map['translationY'], 240.0);
      expect(map['width'], 300.0);
      expect(map['height'], 300.0);
      expect(map['rotation'], 1.57);
      expect(map['scale'], 1.25);
      expect(map['opacity'], 0.9);
      expect(map['zIndex'], 3);

      // Keyframes must be strictly absent by default
      expect(map.containsKey('keyframes'), isFalse);
      expect(map.containsKey('textContent'), isFalse);
    });

    test(
      'toMap includes keyframes when explicitly provided for negative lanes',
      () {
        final kfList = <Object?>[
          <String, Object?>{'timeSeconds': 1.0, 'scale': 1.0},
          <String, Object?>{'timeSeconds': 0.5, 'scale': 1.5},
        ];
        final overlay = VGTimelineOverlayExportSmokeOverlay(
          id: 'kf-overlay',
          assetPath: '/tmp/kf.png',
          keyframes: kfList,
        );

        final map = overlay.toMap();
        expect(map.containsKey('keyframes'), isTrue);
        expect(map['keyframes'], kfList);
      },
    );

    test(
      'toMap includes keyframes when explicitly provided for dynamic keyframe lanes',
      () {
        final kfList = <Object?>[
          <String, Object?>{
            'timeSeconds': 0.0,
            'translationX': 100.0,
            'translationY': 100.0,
            'width': 200.0,
            'height': 200.0,
            'rotation': 0.0,
            'scale': 1.0,
            'opacity': 0.2,
            'interpolation': 'easeInOut',
          },
          <String, Object?>{
            'timeSeconds': 2.0,
            'translationX': 300.0,
            'translationY': 300.0,
            'width': 240.0,
            'height': 240.0,
            'rotation': 0.0,
            'scale': 2.0,
            'opacity': 1.0,
            'interpolation': 'linear',
          },
        ];
        final overlay = VGTimelineOverlayExportSmokeOverlay(
          id: 'kf-overlay-dynamic',
          assetPath: '/tmp/kf.png',
          keyframes: kfList,
        );

        final map = overlay.toMap();
        expect(map.containsKey('keyframes'), isTrue);
        expect(map['keyframes'], kfList);
      },
    );

    test('isActiveAt calculates active interval [start, start + duration)', () {
      final overlay = VGTimelineOverlayExportSmokeOverlay(
        id: 'st',
        startTimeSeconds: 1.0,
        durationSeconds: 2.0,
      );

      expect(overlay.isActiveAt(-0.1), isFalse);
      expect(overlay.isActiveAt(0.5), isFalse);
      expect(overlay.isActiveAt(1.0), isTrue);
      expect(overlay.isActiveAt(2.0), isTrue);
      expect(overlay.isActiveAt(2.999), isTrue);
      expect(overlay.isActiveAt(3.0), isFalse);
      expect(overlay.isActiveAt(3.5), isFalse);

      const zeroDuration = VGTimelineOverlayExportSmokeOverlay(
        id: 'zero',
        startTimeSeconds: 1.0,
        durationSeconds: 0.0,
      );
      expect(zeroDuration.isActiveAt(1.0), isFalse);
    });

    test('fromMap roundtrip preserves overlay fields', () {
      final original = VGTimelineOverlayExportSmokeOverlay(
        id: 'st-roundtrip',
        assetPath: '/tmp/rt.png',
        startTimeSeconds: 1.0,
        durationSeconds: 3.0,
        translationX: 10.0,
        translationY: 20.0,
        width: 100.0,
        height: 80.0,
        rotation: 0.5,
        scale: 2.0,
        opacity: 0.8,
        zIndex: 5,
        type: 'sticker',
      );

      final parsed = VGTimelineOverlayExportSmokeOverlay.fromMap(
        original.toMap(),
      );
      expect(parsed, isNotNull);
      expect(parsed!.id, original.id);
      expect(parsed.assetPath, original.assetPath);
      expect(parsed.startTimeSeconds, original.startTimeSeconds);
      expect(parsed.durationSeconds, original.durationSeconds);
      expect(parsed.translationX, original.translationX);
      expect(parsed.translationY, original.translationY);
      expect(parsed.width, original.width);
      expect(parsed.height, original.height);
      expect(parsed.rotation, original.rotation);
      expect(parsed.scale, original.scale);
      expect(parsed.opacity, original.opacity);
      expect(parsed.zIndex, original.zIndex);
      expect(parsed.type, original.type);
    });
  });

  group('request model and toExportTimelineArguments', () {
    test('request args include overlays and empty transitions by default', () {
      final request = _request(
        laneId: 'arg_test',
        clips: <VGTimelineOverlayExportSmokeClip>[
          _clip('clip-a', end: 2.0),
          _clip('clip-b', end: 3.0),
        ],
        overlays: <VGTimelineOverlayExportSmokeOverlay>[
          _sticker('st-1', zIndex: 0),
          _sticker('st-2', zIndex: 1),
        ],
      );

      final args = request.toExportTimelineArguments();
      expect(args['outputPath'], '/data/local/tmp/out_arg_test.mp4');
      expect(args['width'], 720);
      expect(args['height'], 1280);
      expect(args['fps'], 30);
      expect(args['bitrateBps'], 4000000);

      final draft = args['draft'] as Map<String, Object?>;
      expect(draft['id'], 'vg-overlay-export-smoke-arg_test');
      expect(draft['canvasWidth'], 720);
      expect(draft['canvasHeight'], 1280);
      expect(draft['fps'], 30);

      // Transitions empty by default
      final transitions = draft['transitions'] as List<Object?>;
      expect(transitions, isEmpty);

      // Overlays included and serialized
      final overlays = draft['overlays'] as List<Object?>;
      expect(overlays, hasLength(2));
      expect((overlays[0] as Map)['id'], 'st-1');
      expect((overlays[1] as Map)['id'], 'st-2');
      expect((overlays[0] as Map)['type'], 'sticker');
      expect((overlays[1] as Map)['type'], 'sticker');
    });

    test('expected duration ignores overlays and sums clips', () {
      final request = VGTimelineOverlayExportSmokeRequest(
        laneId: 'duration_test',
        clips: <VGTimelineOverlayExportSmokeClip>[
          _clip('clip-1', end: 2.0),
          _clip('clip-2', end: 3.5),
        ],
        // Overlays with long or short intervals do NOT alter expected timeline duration
        overlays: <VGTimelineOverlayExportSmokeOverlay>[
          _sticker('st-long', start: 0.0, duration: 100.0),
          _sticker('st-short', start: 1.0, duration: 0.5),
        ],
        outputPath: '/tmp/out.mp4',
        expectation: const VGTimelineOverlayExportSmokeExpectation.success(),
      );

      expect(request.expectedDurationSeconds, closeTo(5.5, 1e-9));
      expect(request.expectedOverlayCount, 2);
    });

    test('expected duration clamps negative trim to 0.0', () {
      const clip = VGTimelineOverlayExportSmokeClip(
        id: 'bad',
        sourcePath: '/tmp/bad.mp4',
        trimStartSeconds: 5.0,
        trimEndSeconds: 2.0,
      );
      expect(clip.durationSeconds, 0.0);

      final request = VGTimelineOverlayExportSmokeRequest(
        laneId: 'clamp',
        clips: const <VGTimelineOverlayExportSmokeClip>[clip],
        outputPath: '/tmp/out.mp4',
        expectation: const VGTimelineOverlayExportSmokeExpectation.success(),
      );
      expect(request.expectedDurationSeconds, 0.0);
    });

    test(
      'expected duration subtracts non-hard-cut transition overlap durations',
      () {
        final request = VGTimelineOverlayExportSmokeRequest(
          laneId: 'transition_duration_test',
          clips: <VGTimelineOverlayExportSmokeClip>[
            _clip('clip-1', end: 2.0),
            _clip('clip-2', end: 2.0),
          ],
          transitions: const <VGTimelineOverlayExportSmokeTransition>[
            VGTimelineOverlayExportSmokeTransition(
              id: 'tr-1',
              type: 'dissolve',
              durationSeconds: 0.5,
              fromClipId: 'clip-1',
              toClipId: 'clip-2',
            ),
          ],
          outputPath: '/tmp/out.mp4',
          expectation: const VGTimelineOverlayExportSmokeExpectation.success(),
        );

        // 2.0 + 2.0 clip seconds minus the 0.5s dissolve overlap == 3.5.
        expect(request.expectedDurationSeconds, closeTo(3.5, 1e-9));
        expect(request.expectedTransitionCount, 1);
      },
    );

    test('hard-cut ("none") transition entries subtract zero duration', () {
      final request = VGTimelineOverlayExportSmokeRequest(
        laneId: 'hard_cut_duration_test',
        clips: <VGTimelineOverlayExportSmokeClip>[
          _clip('clip-1', end: 2.0),
          _clip('clip-2', end: 2.0),
        ],
        transitions: const <VGTimelineOverlayExportSmokeTransition>[
          VGTimelineOverlayExportSmokeTransition(
            id: 'tr-1',
            type: 'none',
            durationSeconds: 0.5,
            fromClipId: 'clip-1',
            toClipId: 'clip-2',
          ),
        ],
        outputPath: '/tmp/out.mp4',
        expectation: const VGTimelineOverlayExportSmokeExpectation.success(),
      );

      expect(request.expectedDurationSeconds, closeTo(4.0, 1e-9));
      expect(request.expectedTransitionCount, 0);
    });

    test(
      'z-order list in request remains caller order, sortedOverlays sorts zIndex asc then id asc',
      () {
        final o1 = _sticker('z-high', zIndex: 5);
        final o2 = _sticker('b-low', zIndex: 0);
        final o3 = _sticker('a-low', zIndex: 0);
        final o4 = _sticker('mid', zIndex: 2);

        // Caller order: o1, o2, o3, o4
        final request = VGTimelineOverlayExportSmokeRequest(
          laneId: 'z_order_test',
          clips: <VGTimelineOverlayExportSmokeClip>[_clip('c1')],
          overlays: <VGTimelineOverlayExportSmokeOverlay>[o1, o2, o3, o4],
          outputPath: '/tmp/out.mp4',
          expectation: const VGTimelineOverlayExportSmokeExpectation.success(),
        );

        // 1. In exportTimeline argument map, caller order is preserved
        final args = request.toExportTimelineArguments();
        final draftOverlays =
            (args['draft'] as Map<String, Object?>)['overlays']
                as List<Object?>;
        expect((draftOverlays[0] as Map)['id'], 'z-high');
        expect((draftOverlays[1] as Map)['id'], 'b-low');
        expect((draftOverlays[2] as Map)['id'], 'a-low');
        expect((draftOverlays[3] as Map)['id'], 'mid');

        // 2. Helper sortedOverlays sorts by zIndex asc, then id asc on ties
        final sorted = request.sortedOverlays;
        expect(sorted, hasLength(4));
        expect(sorted[0].id, 'a-low'); // zIndex 0, id 'a-low' < 'b-low'
        expect(sorted[0].zIndex, 0);
        expect(sorted[1].id, 'b-low'); // zIndex 0
        expect(sorted[1].zIndex, 0);
        expect(sorted[2].id, 'mid'); // zIndex 2
        expect(sorted[2].zIndex, 2);
        expect(sorted[3].id, 'z-high'); // zIndex 5
        expect(sorted[3].zIndex, 5);
      },
    );
  });

  group('lane report from export result', () {
    test('passes when vulkan, file exists, duration within tolerance', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(duration: 2.0 + 0.1),
        outputExists: true,
      );

      expect(report.pass, isTrue);
      expect(report.status, 'PASS');
      expect(report.renderBackend, 'vulkan');
      expect(report.durationDeltaSeconds, closeTo(0.1, 1e-9));
      expect(report.overlayCount, 1);
      expect(report.outputExists, isTrue);
      expect(report.failureReason, isEmpty);
    });

    test('fails when renderBackend is gles', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(backend: 'gles'),
        outputExists: true,
      );

      expect(report.pass, isFalse);
      expect(report.status, 'FAIL');
      expect(report.failureReason, startsWith('render_backend_not_vulkan'));
    });

    test('fails when output file is missing', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(),
        outputExists: false,
      );

      expect(report.pass, isFalse);
      expect(report.failureReason, 'output_file_missing');
    });

    test('fails when duration delta exceeds tolerance', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(duration: 2.0 + 0.5),
        outputExists: true,
      );

      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('duration_mismatch'));
    });

    test('fails when overlayCount mismatches expectation', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        _request(
          overlays: <VGTimelineOverlayExportSmokeOverlay>[
            _sticker('s1'),
            _sticker('s2'),
          ],
        ),
        _successResult(overlayCount: 1),
        outputExists: true,
      );

      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('overlay_count_mismatch'));
    });

    test('fails when transitionCount mismatches expectation', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        _request(
          transitions: const <VGTimelineOverlayExportSmokeTransition>[
            VGTimelineOverlayExportSmokeTransition(
              id: 'tr-1',
              type: 'dissolve',
              durationSeconds: 0.5,
              fromClipId: 'clip-1',
              toClipId: 'clip-2',
            ),
          ],
        ),
        _successResult(duration: 1.5, transitionCount: 0),
        outputExists: true,
      );

      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('transition_count_mismatch'));
    });

    test(
      'passes when renderedOverlayFrameCount meets the expected minimum',
      () {
        final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
          _request(
            expectation: const VGTimelineOverlayExportSmokeExpectation.success(
              expectedRenderedOverlayFrameCount: 10,
            ),
          ),
          _successResult(renderedOverlayFrameCount: 15),
          outputExists: true,
        );

        expect(report.pass, isTrue);
        expect(report.renderedOverlayFrameCount, 15);
      },
    );

    test(
      'fails when renderedOverlayFrameCount is below the expected minimum',
      () {
        final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
          _request(
            expectation: const VGTimelineOverlayExportSmokeExpectation.success(
              expectedRenderedOverlayFrameCount: 10,
            ),
          ),
          _successResult(renderedOverlayFrameCount: 3),
          outputExists: true,
        );

        expect(report.pass, isFalse);
        expect(
          report.failureReason,
          startsWith('rendered_overlay_frame_count_too_low'),
        );
      },
    );

    test('fails when a success lane reports a nonzero beautyClipCount', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(beautyClipCount: 1),
        outputExists: true,
      );

      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('beauty_clip_count_mismatch'));
    });

    test('fails when a success lane reports a nonzero beautyFrameCount', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(beautyFrameCount: 3),
        outputExists: true,
      );

      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('beauty_frame_count_not_zero'));
    });

    test('fails when beautyClipCount does not match a nonzero expectation', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        _request(
          expectation: const VGTimelineOverlayExportSmokeExpectation.success(
            expectedBeautyClipCount: 2,
            expectedBeautyFrameCountMin: 10,
          ),
        ),
        _successResult(beautyClipCount: 1, beautyFrameCount: 20),
        outputExists: true,
      );

      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('beauty_clip_count_mismatch'));
    });

    test(
      'fails when beautyFrameCount is below the expected minimum for a beauty lane',
      () {
        final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
          _request(
            expectation: const VGTimelineOverlayExportSmokeExpectation.success(
              expectedBeautyClipCount: 2,
              expectedBeautyFrameCountMin: 10,
            ),
          ),
          _successResult(beautyClipCount: 2, beautyFrameCount: 5),
          outputExists: true,
        );

        expect(report.pass, isFalse);
        expect(report.failureReason, startsWith('beauty_frame_count_too_low'));
      },
    );

    test(
      'passes when beautyClipCount matches and beautyFrameCount meets the expected minimum',
      () {
        final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
          _request(
            expectation: const VGTimelineOverlayExportSmokeExpectation.success(
              expectedBeautyClipCount: 2,
              expectedBeautyFrameCountMin: 10,
            ),
          ),
          _successResult(beautyClipCount: 2, beautyFrameCount: 15),
          outputExists: true,
        );

        expect(report.pass, isTrue);
        expect(report.beautyClipCount, 2);
        expect(report.beautyFrameCount, 15);
      },
    );

    test(
      'fails when beautyClipCount is missing on a positive beauty expectation',
      () {
        final result = _successResult(beautyFrameCount: 15)
          ..remove('beautyClipCount');

        final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
          _request(
            expectation: const VGTimelineOverlayExportSmokeExpectation.success(
              expectedBeautyClipCount: 2,
              expectedBeautyFrameCountMin: 10,
            ),
          ),
          result,
          outputExists: true,
        );

        expect(report.pass, isFalse);
        expect(report.failureReason, 'result_beauty_clip_count_missing');
      },
    );

    test(
      'fails when beautyFrameCount is missing on a positive beauty expectation',
      () {
        final result = _successResult(beautyClipCount: 2)
          ..remove('beautyFrameCount');

        final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
          _request(
            expectation: const VGTimelineOverlayExportSmokeExpectation.success(
              expectedBeautyClipCount: 2,
              expectedBeautyFrameCountMin: 10,
            ),
          ),
          result,
          outputExists: true,
        );

        expect(report.pass, isFalse);
        expect(report.failureReason, 'result_beauty_frame_count_missing');
      },
    );

    test(
      'passes when beauty counters are absent and expectedBeautyClipCount is zero',
      () {
        final result = _successResult()
          ..remove('beautyClipCount')
          ..remove('beautyFrameCount');

        final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
          _request(),
          result,
          outputExists: true,
        );

        expect(report.pass, isTrue);
        expect(report.beautyClipCount, isNull);
        expect(report.beautyFrameCount, isNull);
      },
    );

    test(
      'fails when expected overlayCount is required but missing from result',
      () {
        final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
          _request(
            expectation: const VGTimelineOverlayExportSmokeExpectation.success(
              expectedOverlayCount: 1,
            ),
          ),
          <String, Object?>{
            'success': true,
            'path': '/tmp/out.mp4',
            'durationSeconds': 2.0,
            'renderBackend': 'vulkan',
          },
          outputExists: true,
        );

        expect(report.pass, isFalse);
        expect(report.failureReason, 'result_overlay_count_missing');
      },
    );

    test('fails when native returns null result or success=false', () {
      final nullResult =
          VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
            _request(),
            null,
            outputExists: false,
          );
      expect(nullResult.pass, isFalse);
      expect(nullResult.failureReason, 'native_returned_null_result');

      final falseResult =
          VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
            _request(),
            <String, Object?>{'success': false},
            outputExists: false,
          );
      expect(falseResult.pass, isFalse);
      expect(falseResult.failureReason, 'result_success_false');
    });

    test('fails when fail-closed lane unexpectedly succeeds', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        _request(
          laneId: 'fail_closed_text_overlay',
          expectation: const VGTimelineOverlayExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
          ),
        ),
        _successResult(),
        outputExists: true,
      );

      expect(report.pass, isFalse);
      expect(report.failureReason, 'expected_fail_closed_but_export_succeeded');
    });
  });

  group('lane report from PlatformException (fail-closed contract)', () {
    test('passes when error code and message token match expectation', () {
      final report =
          VGTimelineOverlayExportSmokeLaneReport.fromPlatformException(
            _request(
              laneId: 'fail_closed_text_overlay',
              expectation:
                  const VGTimelineOverlayExportSmokeExpectation.failClosed(
                    errorCode: unsupportedExportFeatureCode,
                    messageContains: textOverlayToken,
                  ),
            ),
            PlatformException(
              code: unsupportedExportFeatureCode,
              message:
                  'exportTimeline: text overlays are not supported in Route-A',
            ),
          );

      expect(report.pass, isTrue);
      expect(report.status, 'PASS');
      expect(report.errorCode, unsupportedExportFeatureCode);
      expect(report.failureReason, isEmpty);
    });

    test(
      'passes when fail_closed_malformed_keyframes matches INVALID_ARG and keyframe token',
      () {
        final report = VGTimelineOverlayExportSmokeLaneReport.fromPlatformException(
          _request(
            laneId: 'fail_closed_malformed_keyframes',
            expectation:
                const VGTimelineOverlayExportSmokeExpectation.failClosed(
                  errorCode: invalidArgCode,
                  messageContains: keyframesToken,
                ),
          ),
          PlatformException(
            code: invalidArgCode,
            message:
                'exportTimeline: overlay sticker keyframe at index 1 has duplicate or non-monotonic timestamps',
          ),
        );

        expect(report.pass, isTrue);
        expect(report.status, 'PASS');
        expect(report.errorCode, invalidArgCode);
        expect(report.failureReason, isEmpty);
      },
    );

    test('fails when error code does not match', () {
      final report =
          VGTimelineOverlayExportSmokeLaneReport.fromPlatformException(
            _request(
              laneId: 'fail_closed_text_overlay',
              expectation:
                  const VGTimelineOverlayExportSmokeExpectation.failClosed(
                    errorCode: unsupportedExportFeatureCode,
                  ),
            ),
            PlatformException(
              code: 'EXPORT_FAILED',
              message: 'generic failure',
            ),
          );

      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('error_code_mismatch'));
    });

    test('fails when required message token is missing', () {
      final report =
          VGTimelineOverlayExportSmokeLaneReport.fromPlatformException(
            _request(
              laneId: 'fail_closed_emoji_overlay',
              expectation:
                  const VGTimelineOverlayExportSmokeExpectation.failClosed(
                    errorCode: unsupportedExportFeatureCode,
                    messageContains: emojiOverlayToken,
                  ),
            ),
            PlatformException(
              code: unsupportedExportFeatureCode,
              message: 'exportTimeline: unspecified error',
            ),
          );

      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('error_message_missing_token'));
    });

    test('fails when a positive success lane throws PlatformException', () {
      final report =
          VGTimelineOverlayExportSmokeLaneReport.fromPlatformException(
            _request(),
            PlatformException(
              code: 'UNSUPPORTED_EXPORT_FEATURE',
              message: 'overlays are not supported',
            ),
          );

      expect(report.pass, isFalse);
      expect(
        report.failureReason,
        'unexpected_platform_exception:UNSUPPORTED_EXPORT_FEATURE',
      );
    });

    test('harnessException wraps unexpected error', () {
      final report = VGTimelineOverlayExportSmokeLaneReport.harnessException(
        _request(),
        'unexpected bad state',
      );

      expect(report.pass, isFalse);
      expect(report.failureReason, 'harness_exception:unexpected bad state');
    });
  });

  group('whole-run report and canonical markers', () {
    test('PASS requires at least one positive lane and all lanes passing', () {
      final positiveLane =
          VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
            _request(),
            _successResult(),
            outputExists: true,
          );

      final failClosedLane =
          VGTimelineOverlayExportSmokeLaneReport.fromPlatformException(
            _request(
              laneId: 'fail_closed_text_overlay',
              expectation:
                  const VGTimelineOverlayExportSmokeExpectation.failClosed(
                    errorCode: unsupportedExportFeatureCode,
                  ),
            ),
            PlatformException(code: unsupportedExportFeatureCode),
          );

      final report = VGTimelineOverlayExportSmokeReport(
        lanes: <VGTimelineOverlayExportSmokeLaneReport>[
          positiveLane,
          failClosedLane,
        ],
      );

      expect(report.pass, isTrue);
      expect(report.status, 'PASS');
      expect(report.marker, overlayPassMarker);
      expect(report.failureReason, isEmpty);

      // Only fail-closed lanes is not a valid pass
      final onlyFailClosed = VGTimelineOverlayExportSmokeReport(
        lanes: <VGTimelineOverlayExportSmokeLaneReport>[failClosedLane],
      );
      expect(onlyFailClosed.pass, isFalse);
      expect(onlyFailClosed.marker, overlayFailMarker);

      // Empty lanes is not a valid pass
      const emptyReport = VGTimelineOverlayExportSmokeReport(lanes: []);
      expect(emptyReport.pass, isFalse);
      expect(emptyReport.marker, overlayFailMarker);
    });

    test('failing lane causes whole report to fail with prefixed reason', () {
      final positiveLane =
          VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
            _request(laneId: 'lane_pos'),
            _successResult(),
            outputExists: true,
          );

      final failingLane =
          VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
            _request(laneId: 'lane_fail'),
            _successResult(backend: 'gles'),
            outputExists: true,
          );

      final report = VGTimelineOverlayExportSmokeReport(
        lanes: <VGTimelineOverlayExportSmokeLaneReport>[
          positiveLane,
          failingLane,
        ],
      );

      expect(report.pass, isFalse);
      expect(report.status, 'FAIL');
      expect(report.marker, overlayFailMarker);
      expect(
        report.failureReason,
        startsWith('lane_fail:render_backend_not_vulkan'),
      );
    });

    test('toMap and fromMap roundtrip preserves report structure', () {
      final positiveLane =
          VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
            _request(
              laneId: 'overlays_with_transition_dissolve_success',
              transitions: const <VGTimelineOverlayExportSmokeTransition>[
                VGTimelineOverlayExportSmokeTransition(
                  id: 'tr-1',
                  type: 'dissolve',
                  durationSeconds: 0.5,
                  fromClipId: 'clip-1',
                  toClipId: 'clip-2',
                ),
              ],
              expectation:
                  const VGTimelineOverlayExportSmokeExpectation.success(
                    expectedTransitionCount: 1,
                    expectedRenderedOverlayFrameCount: 10,
                  ),
            ),
            _successResult(
              duration: 1.5,
              transitionCount: 1,
              renderedOverlayFrameCount: 12,
            ),
            outputExists: true,
          );

      final report = VGTimelineOverlayExportSmokeReport(
        lanes: <VGTimelineOverlayExportSmokeLaneReport>[positiveLane],
      );

      final map = report.toMap();
      expect(map['proofBoundary'], overlayProofBoundary);
      expect(map['marker'], overlayPassMarker);
      expect(map['status'], 'PASS');
      expect(map['pass'], isTrue);

      final parsed = VGTimelineOverlayExportSmokeReport.fromMap(map);
      expect(parsed.pass, isTrue);
      expect(parsed.marker, overlayPassMarker);
      expect(parsed.lanes, hasLength(1));
      expect(
        parsed.lanes.single.laneId,
        'overlays_with_transition_dissolve_success',
      );
      expect(parsed.lanes.single.renderBackend, 'vulkan');
      expect(parsed.lanes.single.overlayCount, 1);
      expect(parsed.lanes.single.transitionCount, 1);
      expect(parsed.lanes.single.expectedTransitionCount, 1);
      expect(parsed.lanes.single.renderedOverlayFrameCount, 12);
      expect(parsed.lanes.single.expectedRenderedOverlayFrameCount, 10);
      expect(parsed.lanes.single.beautyClipCount, 0);
      expect(parsed.lanes.single.beautyFrameCount, 0);
      expect(parsed.lanes.single.expectedBeautyClipCount, 0);
      expect(parsed.lanes.single.expectedBeautyFrameCountMin, 0);
    });

    test(
      'toMap and fromMap roundtrip preserves nonzero expected beauty fields',
      () {
        final beautyLane =
            VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
              _request(
                laneId: 'overlays_with_beauty_transition_overlap_success',
                expectation:
                    const VGTimelineOverlayExportSmokeExpectation.success(
                      expectedBeautyClipCount: 2,
                      expectedBeautyFrameCountMin: 100,
                    ),
              ),
              _successResult(beautyClipCount: 2, beautyFrameCount: 105),
              outputExists: true,
            );

        final map = beautyLane.toMap();
        final parsed = VGTimelineOverlayExportSmokeLaneReport.fromMap(map);
        expect(parsed.pass, isTrue);
        expect(parsed.beautyClipCount, 2);
        expect(parsed.beautyFrameCount, 105);
        expect(parsed.expectedBeautyClipCount, 2);
        expect(parsed.expectedBeautyFrameCountMin, 100);
      },
    );
  });

  group('runner over real exportTimeline MethodChannel', () {
    tearDown(_clearMockHandler);

    test(
      'invokes exportTimeline and parses successful Vulkan result',
      () async {
        String? seenMethod;
        Map<Object?, Object?>? seenArgs;

        _setMockHandler((method, args) async {
          seenMethod = method;
          seenArgs = args as Map<Object?, Object?>;
          return _successResult();
        });

        final runner = VGTimelineOverlayExportSmokeRunner(
          channel: _channel,
          fileExists: (path) =>
              path ==
              '/data/local/tmp/out_single_clip_static_sticker_success.mp4',
        );

        final report = await runner.run(<VGTimelineOverlayExportSmokeRequest>[
          _request(),
        ]);

        expect(seenMethod, 'exportTimeline');
        expect(seenArgs, isNotNull);

        final draft = seenArgs!['draft'] as Map<Object?, Object?>;
        expect(draft.containsKey('overlays'), isTrue);
        final overlays = draft['overlays'] as List<Object?>;
        expect(overlays, hasLength(1));
        expect((overlays.single as Map)['type'], 'sticker');

        expect(report.pass, isTrue);
        expect(report.lanes.single.outputExists, isTrue);
        expect(report.lanes.single.renderBackend, 'vulkan');
      },
    );

    test('handles expected PlatformException fail-closed lanes', () async {
      _setMockHandler((method, args) async {
        final draft = (args as Map)['draft'] as Map;
        final overlays = draft['overlays'] as List<Object?>;
        final type = (overlays.single as Map)['type'];
        if (type == 'text') {
          throw PlatformException(
            code: unsupportedExportFeatureCode,
            message:
                'exportTimeline: text overlays are not supported in Route-A',
          );
        }
        return _successResult();
      });

      final runner = VGTimelineOverlayExportSmokeRunner(
        channel: _channel,
        fileExists: (_) => true,
      );

      final report = await runner.run(<VGTimelineOverlayExportSmokeRequest>[
        _request(),
        _request(
          laneId: 'fail_closed_text_overlay',
          overlays: const <VGTimelineOverlayExportSmokeOverlay>[
            VGTimelineOverlayExportSmokeOverlay(
              id: 'txt',
              type: 'text',
              textContent: 'hello',
            ),
          ],
          expectation: const VGTimelineOverlayExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: 'text',
          ),
        ),
      ]);

      expect(report.pass, isTrue);
      expect(report.lanes, hasLength(2));
      expect(report.lanes[0].pass, isTrue);
      expect(report.lanes[1].pass, isTrue);
      expect(report.lanes[1].errorCode, unsupportedExportFeatureCode);
    });

    test('GLES backend result causes runner positive lane to fail', () async {
      _setMockHandler((method, args) async => _successResult(backend: 'gles'));

      final runner = VGTimelineOverlayExportSmokeRunner(
        channel: _channel,
        fileExists: (_) => true,
      );

      final report = await runner.run(<VGTimelineOverlayExportSmokeRequest>[
        _request(),
      ]);

      expect(report.pass, isFalse);
      expect(
        report.failureReason,
        startsWith(
          'single_clip_static_sticker_success:render_backend_not_vulkan',
        ),
      );
    });

    test(
      'missing plugin is caught as harness exception without throwing',
      () async {
        _clearMockHandler();

        final runner = VGTimelineOverlayExportSmokeRunner(
          channel: _channel,
          fileExists: (_) => true,
        );

        final report = await runner.run(<VGTimelineOverlayExportSmokeRequest>[
          _request(),
        ]);

        expect(report.pass, isFalse);
        expect(
          report.lanes.single.failureReason,
          startsWith('harness_exception:missing_plugin'),
        );
      },
    );
  });

  group('default suite construction', () {
    test(
      'buildDefaultOverlayExportSmokeSuite builds all 14 required lanes',
      () {
        final suite = buildDefaultOverlayExportSmokeSuite();

        expect(suite, hasLength(14));
        final laneIds = suite.map((r) => r.laneId).toList();
        expect(laneIds, defaultOverlaySmokeLaneIds);

        final successLanes = suite.where((r) => r.expectation.expectsSuccess);
        final failureLanes = suite.where((r) => !r.expectation.expectsSuccess);

        expect(successLanes, hasLength(9));
        expect(failureLanes, hasLength(5));

        // Lane 1: single_clip_static_sticker_success
        final lane1 = suite[0];
        expect(lane1.laneId, 'single_clip_static_sticker_success');
        expect(lane1.clips, hasLength(1));
        expect(lane1.overlays, hasLength(1));
        expect(lane1.overlays.single.type, 'sticker');
        expect(lane1.expectation.expectsSuccess, isTrue);

        // Lane 2: multi_layer_z_order_success
        final lane2 = suite[1];
        expect(lane2.laneId, 'multi_layer_z_order_success');
        expect(lane2.overlays, hasLength(2));
        expect(lane2.overlays[0].zIndex, 0);
        expect(lane2.overlays[1].zIndex, 1);
        expect(lane2.expectation.expectedOverlayCount, 2);

        // Lane 3: time_interval_gating_success
        final lane3 = suite[2];
        expect(lane3.laneId, 'time_interval_gating_success');
        expect(lane3.overlays.single.startTimeSeconds, 1.0);
        expect(lane3.overlays.single.durationSeconds, 1.5);
        expect(lane3.clips.single.durationSeconds, 4.0);

        // Lane 4: hard_cut_multiclip_success
        final lane4 = suite[3];
        expect(lane4.laneId, 'hard_cut_multiclip_success');
        expect(lane4.clips, hasLength(2));
        expect(lane4.transitions, isEmpty);
        expect(lane4.expectedDurationSeconds, 4.0);

        // Lane 5: single_clip_dynamic_keyframe_success
        final lane5 = suite[4];
        expect(lane5.laneId, 'single_clip_dynamic_keyframe_success');
        expect(lane5.clips, hasLength(1));
        expect(lane5.clips.single.durationSeconds, 2.0);
        expect(lane5.overlays, hasLength(1));
        expect(lane5.overlays.single.type, 'sticker');
        expect(lane5.overlays.single.startTimeSeconds, 0.0);
        expect(lane5.overlays.single.durationSeconds, 2.0);
        expect(lane5.overlays.single.keyframes, isA<List<Object?>>());
        expect((lane5.overlays.single.keyframes as List), hasLength(2));
        expect(lane5.expectation.expectsSuccess, isTrue);
        expect(lane5.expectation.expectedOverlayCount, 1);
        expect(lane5.expectation.expectedRenderedOverlayFrameCount, 55);
        expect(lane5.expectedDurationSeconds, 2.0);

        // Lane 6: fail_closed_text_overlay
        final lane6 = suite[5];
        expect(lane6.laneId, 'fail_closed_text_overlay');
        expect(lane6.overlays.single.type, 'text');
        expect(lane6.expectation.errorCode, unsupportedExportFeatureCode);
        expect(lane6.expectation.messageContains, textOverlayToken);

        // Lane 7: fail_closed_emoji_overlay
        final lane7 = suite[6];
        expect(lane7.laneId, 'fail_closed_emoji_overlay');
        expect(lane7.overlays.single.type, 'emoji');
        expect(lane7.expectation.errorCode, unsupportedExportFeatureCode);
        expect(lane7.expectation.messageContains, emojiOverlayToken);

        // Lane 8: fail_closed_malformed_keyframes
        final lane8 = suite[7];
        expect(lane8.laneId, 'fail_closed_malformed_keyframes');
        expect(lane8.overlays.single.keyframes, isNotNull);
        expect(lane8.expectation.errorCode, invalidArgCode);
        expect(lane8.expectation.messageContains, keyframesToken);

        // Lane 9: overlays_with_transition_dissolve_success
        final lane9 = suite[8];
        expect(lane9.laneId, 'overlays_with_transition_dissolve_success');
        expect(lane9.clips, hasLength(2));
        expect(lane9.transitions, hasLength(1));
        expect(lane9.transitions.single.type, 'dissolve');
        expect(lane9.overlays, hasLength(1));
        expect(lane9.expectation.expectsSuccess, isTrue);
        expect(lane9.expectation.expectedTransitionCount, 1);
        expect(lane9.expectation.expectedRenderedOverlayFrameCount, 10);
        // 2.0s + 2.0s clip seconds minus the 0.5s dissolve overlap == 3.5s.
        expect(lane9.expectedDurationSeconds, closeTo(3.5, 1e-9));
        expect(lane9.expectedTransitionCount, 1);

        // Lane 10: overlays_with_transition_slide_left_success
        final lane10 = suite[9];
        expect(lane10.laneId, 'overlays_with_transition_slide_left_success');
        expect(lane10.clips, hasLength(2));
        expect(lane10.clips[0].durationSeconds, 2.0);
        expect(lane10.clips[1].durationSeconds, 2.0);
        expect(lane10.transitions, hasLength(1));
        expect(lane10.transitions.single.type, 'slideLeft');
        expect(lane10.transitions.single.durationSeconds, 0.5);
        expect(lane10.overlays, hasLength(1));
        expect(lane10.overlays.single.startTimeSeconds, 1.5);
        expect(lane10.overlays.single.durationSeconds, 0.5);
        expect(lane10.expectation.expectsSuccess, isTrue);
        expect(lane10.expectation.expectedOverlayCount, 1);
        expect(lane10.expectation.expectedTransitionCount, 1);
        expect(lane10.expectation.expectedRenderedOverlayFrameCount, 10);
        expect(lane10.expectation.expectedBeautyClipCount, 0);
        expect(lane10.expectation.expectedBeautyFrameCountMin, 0);
        expect(lane10.expectedDurationSeconds, closeTo(3.5, 1e-9));
        expect(lane10.expectedTransitionCount, 1);

        // Lane 11: overlays_with_transition_wipe_right_success
        final lane11 = suite[10];
        expect(lane11.laneId, 'overlays_with_transition_wipe_right_success');
        expect(lane11.clips, hasLength(2));
        expect(lane11.clips[0].durationSeconds, 2.0);
        expect(lane11.clips[1].durationSeconds, 2.0);
        expect(lane11.transitions, hasLength(1));
        expect(lane11.transitions.single.type, 'wipeRight');
        expect(lane11.transitions.single.durationSeconds, 0.5);
        expect(lane11.overlays, hasLength(1));
        expect(lane11.overlays.single.startTimeSeconds, 1.5);
        expect(lane11.overlays.single.durationSeconds, 0.5);
        expect(lane11.expectation.expectsSuccess, isTrue);
        expect(lane11.expectation.expectedOverlayCount, 1);
        expect(lane11.expectation.expectedTransitionCount, 1);
        expect(lane11.expectation.expectedRenderedOverlayFrameCount, 10);
        expect(lane11.expectation.expectedBeautyClipCount, 0);
        expect(lane11.expectation.expectedBeautyFrameCountMin, 0);
        expect(lane11.expectedDurationSeconds, closeTo(3.5, 1e-9));
        expect(lane11.expectedTransitionCount, 1);

        // Lane 12: overlays_with_beauty_transition_overlap_success
        final lane12 = suite[11];
        expect(
          lane12.laneId,
          'overlays_with_beauty_transition_overlap_success',
        );
        expect(lane12.clips, hasLength(2));
        expect(lane12.clips[0].hasBeauty, isTrue);
        expect(lane12.clips[1].hasBeauty, isTrue);
        expect(lane12.transitions, hasLength(1));
        expect(lane12.transitions.single.type, 'dissolve');
        expect(lane12.overlays, hasLength(1));
        expect(lane12.overlays.single.startTimeSeconds, 1.6);
        expect(lane12.overlays.single.durationSeconds, 0.3);
        expect(lane12.expectation.expectsSuccess, isTrue);
        expect(lane12.expectation.expectedOverlayCount, 1);
        expect(lane12.expectation.expectedTransitionCount, 1);
        expect(lane12.expectation.expectedRenderedOverlayFrameCount, 6);
        expect(lane12.expectation.expectedBeautyClipCount, 2);
        expect(lane12.expectation.expectedBeautyFrameCountMin, 100);
        // 2.0s + 2.0s clip seconds minus the 0.5s dissolve overlap == 3.5s.
        expect(lane12.expectedDurationSeconds, closeTo(3.5, 1e-9));

        // Lane 13: fail_closed_solo_overlays_with_beauty
        final lane13 = suite[12];
        expect(lane13.laneId, 'fail_closed_solo_overlays_with_beauty');
        expect(lane13.clips.single.hasBeauty, isTrue);
        expect(lane13.transitions, isEmpty);
        expect(lane13.overlays.single.startTimeSeconds, 0.0);
        expect(lane13.overlays.single.durationSeconds, 2.0);
        expect(lane13.expectation.errorCode, unsupportedExportFeatureCode);
        expect(lane13.expectation.messageContains, overlaysWithBeautyToken);

        // Lane 14: fail_closed_unreadable_asset
        final lane14 = suite[13];
        expect(lane14.laneId, 'fail_closed_unreadable_asset');
        expect(lane14.expectation.errorCode, fileUnreadableCode);
        expect(lane14.expectation.messageContains, unreadableAssetToken);
      },
    );
  });
}
