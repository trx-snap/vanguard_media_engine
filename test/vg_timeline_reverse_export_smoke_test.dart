// vg_timeline_reverse_export_smoke_test.dart
// vanguard_media_engine -- P5-REVERSE-EXPORT-EXACT-GLES-ROUTE: production
// `exportTimeline` reversed-video smoke Dart model, serialization, report
// parsing, and fail-closed contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_reverse_export_smoke.dart';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

const List<double> _identityColorMatrix = <double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0,
];

VGTimelineReverseExportSmokeClip _clip(
  String id, {
  double start = 0.0,
  double end = 2.0,
  String sourcePath = '/data/local/tmp/clip.mov',
  String mediaKind = 'video',
  bool isReversed = false,
  List<double>? colorMatrix,
  double? beautyIntensity,
}) => VGTimelineReverseExportSmokeClip(
  id: id,
  sourcePath: sourcePath,
  trimStartSeconds: start,
  trimEndSeconds: end,
  mediaKind: mediaKind,
  isReversed: isReversed,
  colorMatrix: colorMatrix,
  beautyIntensity: beautyIntensity,
);

Map<String, Object?> _successResult({
  String backend = expectedReverseRenderBackend,
  double duration = 2.0,
  String path = '/data/local/tmp/out.mp4',
}) => <String, Object?>{
  'success': true,
  'path': path,
  'durationSeconds': duration,
  'width': 720,
  'height': 1280,
  'fps': 30,
  'exportRoiSidecarPath': '$path.roi.json',
  'renderBackend': backend,
  'transitionCount': 0,
};

// (a) single reversed clip.
VGTimelineReverseExportSmokeRequest _laneSingleReversed() =>
    VGTimelineReverseExportSmokeRequest(
      laneId: 'single_reversed',
      clips: <VGTimelineReverseExportSmokeClip>[
        _clip('clip-a', isReversed: true),
      ],
      outputPath: '/data/local/tmp/out_single_reversed.mp4',
      expectation: const VGTimelineReverseExportSmokeExpectation.success(),
    );

// (b) mixed forward + reversed hard cut (1.0s each => 2.0s total).
VGTimelineReverseExportSmokeRequest _laneMixedForwardReversed() =>
    VGTimelineReverseExportSmokeRequest(
      laneId: 'mixed_forward_reversed',
      clips: <VGTimelineReverseExportSmokeClip>[
        _clip('clip-a', end: 1.0),
        _clip('clip-b', end: 1.0, isReversed: true),
      ],
      outputPath: '/data/local/tmp/out_mixed.mp4',
      expectation: const VGTimelineReverseExportSmokeExpectation.success(),
    );

// (c) reversed + colorMatrix.
VGTimelineReverseExportSmokeRequest _laneReversedColorMatrix() =>
    VGTimelineReverseExportSmokeRequest(
      laneId: 'reversed_color_matrix',
      clips: <VGTimelineReverseExportSmokeClip>[
        _clip('clip-a', isReversed: true, colorMatrix: _identityColorMatrix),
      ],
      outputPath: '/data/local/tmp/out_color_matrix.mp4',
      expectation: const VGTimelineReverseExportSmokeExpectation.success(),
    );

// (d) reversed + transition fail closed.
VGTimelineReverseExportSmokeRequest _laneReversedTransition() =>
    VGTimelineReverseExportSmokeRequest(
      laneId: 'reversed_transition',
      clips: <VGTimelineReverseExportSmokeClip>[
        _clip('clip-a', isReversed: true),
        _clip('clip-b'),
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
      outputPath: '/data/local/tmp/out_reversed_transition.mp4',
      expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
        errorCode: unsupportedExportFeatureCode,
        messageContains: reversedClipsWithTransitionsToken,
      ),
    );

// (e) reversed + overlay fail closed.
VGTimelineReverseExportSmokeRequest _laneReversedOverlay() =>
    VGTimelineReverseExportSmokeRequest(
      laneId: 'reversed_overlay',
      clips: <VGTimelineReverseExportSmokeClip>[
        _clip('clip-a', isReversed: true),
      ],
      overlays: const <VGTimelineReverseExportSmokeOverlay>[
        VGTimelineReverseExportSmokeOverlay(
          id: 'ov-1',
          assetPath: '/data/local/tmp/sticker.png',
        ),
      ],
      outputPath: '/data/local/tmp/out_reversed_overlay.mp4',
      expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
        errorCode: unsupportedExportFeatureCode,
        messageContains: reversedClipsWithOverlaysToken,
      ),
    );

// (f) reversed + beauty fail closed.
VGTimelineReverseExportSmokeRequest _laneReversedBeauty() =>
    VGTimelineReverseExportSmokeRequest(
      laneId: 'reversed_beauty',
      clips: <VGTimelineReverseExportSmokeClip>[
        _clip('clip-a', isReversed: true, beautyIntensity: 0.5),
      ],
      outputPath: '/data/local/tmp/out_reversed_beauty.mp4',
      expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
        errorCode: unsupportedExportFeatureCode,
        messageContains: reversedClipsWithBeautyToken,
      ),
    );

// (g) reversed + audioSidecar fail closed.
VGTimelineReverseExportSmokeRequest _laneReversedAudioSidecar() =>
    VGTimelineReverseExportSmokeRequest(
      laneId: 'reversed_audio_sidecar',
      clips: <VGTimelineReverseExportSmokeClip>[
        _clip('clip-a', isReversed: true),
      ],
      audioTracks: const <VGTimelineReverseExportSmokeAudioTrack>[
        VGTimelineReverseExportSmokeAudioTrack(
          trackId: 'track-1',
          url: '/data/local/tmp/audio.m4a',
        ),
      ],
      outputPath: '/data/local/tmp/out_reversed_audio.mp4',
      expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
        errorCode: unsupportedExportFeatureCode,
        messageContains: reversedClipsWithAudioTracksToken,
      ),
    );

// (h) image + isReversed invalid arg.
VGTimelineReverseExportSmokeRequest _laneImageReversed() =>
    VGTimelineReverseExportSmokeRequest(
      laneId: 'image_reversed',
      clips: <VGTimelineReverseExportSmokeClip>[
        _clip(
          'clip-a',
          mediaKind: 'image',
          isReversed: true,
          sourcePath: '/data/local/tmp/still.png',
        ),
      ],
      outputPath: '/data/local/tmp/out_image_reversed.mp4',
      expectation: const VGTimelineReverseExportSmokeExpectation.failClosed(
        errorCode: invalidArgExportCode,
        messageContains: reversedClipIsReversedToken,
      ),
    );

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

  group('clip serialization', () {
    test('forward clip defaults isReversed to false', () {
      final map = _clip('clip-a').toMap();
      expect(map['isReversed'], isFalse);
      expect(map['mediaKind'], 'video');
      expect(map.containsKey('colorMatrix'), isFalse);
      expect(map.containsKey('beautyIntensity'), isFalse);
    });

    test('reversed clip serializes isReversed true', () {
      final map = _clip('clip-a', isReversed: true).toMap();
      expect(map['isReversed'], isTrue);
    });

    test('colorMatrix is only present when set', () {
      final withMatrix = _clip(
        'clip-a',
        isReversed: true,
        colorMatrix: _identityColorMatrix,
      ).toMap();
      expect(withMatrix['colorMatrix'], _identityColorMatrix);

      final withoutMatrix = _clip('clip-a', isReversed: true).toMap();
      expect(withoutMatrix.containsKey('colorMatrix'), isFalse);
    });

    test('beautyIntensity is only present when set', () {
      final withBeauty = _clip(
        'clip-a',
        isReversed: true,
        beautyIntensity: 0.5,
      ).toMap();
      expect(withBeauty['beautyIntensity'], 0.5);
    });
  });

  group('request wire shape', () {
    test('expected duration is the plain sum of clip trim windows', () {
      expect(_laneSingleReversed().expectedDurationSeconds, closeTo(2.0, 1e-9));
      expect(
        _laneMixedForwardReversed().expectedDurationSeconds,
        closeTo(2.0, 1e-9),
      );
    });

    test('(a) single reversed clip arguments carry isReversed=true', () {
      final args = _laneSingleReversed().toExportTimelineArguments();
      final draft = args['draft'] as Map<String, Object?>;
      final clips = draft['clips'] as List<Object?>;
      expect(clips, hasLength(1));
      expect((clips[0] as Map)['isReversed'], isTrue);
      expect((clips[0] as Map)['mediaKind'], 'video');
      expect(draft['transitions'], isEmpty);
      expect(draft['overlays'], isEmpty);
      expect(draft.containsKey('audioSidecar'), isFalse);
    });

    test('(b) mixed forward + reversed clips preserve per-clip isReversed', () {
      final args = _laneMixedForwardReversed().toExportTimelineArguments();
      final draft = args['draft'] as Map<String, Object?>;
      final clips = draft['clips'] as List<Object?>;
      expect(clips, hasLength(2));
      expect((clips[0] as Map)['isReversed'], isFalse);
      expect((clips[1] as Map)['isReversed'], isTrue);
    });

    test('(c) reversed + colorMatrix arguments carry the 20-value list', () {
      final args = _laneReversedColorMatrix().toExportTimelineArguments();
      final draft = args['draft'] as Map<String, Object?>;
      final clips = draft['clips'] as List<Object?>;
      expect((clips[0] as Map)['isReversed'], isTrue);
      expect((clips[0] as Map)['colorMatrix'], hasLength(20));
    });

    test('(d) reversed + transition arguments carry a non-empty list', () {
      final args = _laneReversedTransition().toExportTimelineArguments();
      final draft = args['draft'] as Map<String, Object?>;
      expect(draft['transitions'], hasLength(1));
    });

    test('(e) reversed + overlay arguments carry a non-empty list', () {
      final args = _laneReversedOverlay().toExportTimelineArguments();
      final draft = args['draft'] as Map<String, Object?>;
      expect(draft['overlays'], hasLength(1));
      expect((draft['overlays'] as List).single, isA<Map>());
    });

    test('(f) reversed + beauty arguments carry beautyIntensity', () {
      final args = _laneReversedBeauty().toExportTimelineArguments();
      final draft = args['draft'] as Map<String, Object?>;
      final clips = draft['clips'] as List<Object?>;
      expect((clips[0] as Map)['beautyIntensity'], 0.5);
    });

    test(
      '(g) reversed + audioSidecar arguments carry a non-empty tracks list',
      () {
        final args = _laneReversedAudioSidecar().toExportTimelineArguments();
        final draft = args['draft'] as Map<String, Object?>;
        expect(draft.containsKey('audioSidecar'), isTrue);
        final sidecar = draft['audioSidecar'] as Map<String, Object?>;
        expect(sidecar['tracks'], hasLength(1));
      },
    );

    test('(h) image + isReversed arguments preserve both fields', () {
      final args = _laneImageReversed().toExportTimelineArguments();
      final draft = args['draft'] as Map<String, Object?>;
      final clips = draft['clips'] as List<Object?>;
      expect((clips[0] as Map)['mediaKind'], 'image');
      expect((clips[0] as Map)['isReversed'], isTrue);
    });
  });

  group('lane report from export result', () {
    test('(a) passes when gles, file exists, duration within tolerance', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromExportResult(
        _laneSingleReversed(),
        _successResult(duration: 2.0 + 0.05),
        outputExists: true,
      );
      expect(report.pass, isTrue);
      expect(report.status, 'PASS');
      expect(report.renderBackend, expectedReverseRenderBackend);
      expect(report.durationDeltaSeconds, closeTo(0.05, 1e-9));
    });

    test('(b) mixed forward+reversed passes when gles and duration ~2.0', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromExportResult(
        _laneMixedForwardReversed(),
        _successResult(duration: 2.0),
        outputExists: true,
      );
      expect(report.pass, isTrue);
      expect(report.renderBackend, expectedReverseRenderBackend);
    });

    test('(c) reversed + colorMatrix passes with the same success shape', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromExportResult(
        _laneReversedColorMatrix(),
        _successResult(duration: 2.0),
        outputExists: true,
      );
      expect(report.pass, isTrue);
      expect(report.renderBackend, expectedReverseRenderBackend);
    });

    test('fails when renderBackend is vulkan', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromExportResult(
        _laneSingleReversed(),
        _successResult(backend: 'vulkan'),
        outputExists: true,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('render_backend_not_gles'));
    });

    test('fails when the output file is missing', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromExportResult(
        _laneSingleReversed(),
        _successResult(),
        outputExists: false,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, 'output_file_missing');
    });

    test('fails when duration is outside tolerance', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromExportResult(
        _laneSingleReversed(),
        _successResult(duration: 5.0),
        outputExists: true,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('duration_mismatch'));
    });

    test('null result and success=false fail', () {
      expect(
        VGTimelineReverseExportSmokeLaneReport.fromExportResult(
          _laneSingleReversed(),
          null,
          outputExists: false,
        ).failureReason,
        'native_returned_null_result',
      );
      expect(
        VGTimelineReverseExportSmokeLaneReport.fromExportResult(
          _laneSingleReversed(),
          <String, Object?>{'success': false},
          outputExists: false,
        ).failureReason,
        'result_success_false',
      );
    });

    test('a fail-closed lane that succeeded fails', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromExportResult(
        _laneReversedTransition(),
        _successResult(),
        outputExists: true,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, 'expected_fail_closed_but_export_succeeded');
    });
  });

  group('lane report from PlatformException (fail-closed contract)', () {
    test('(d) reversed + transition requires the transitions token', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
        _laneReversedTransition(),
        PlatformException(
          code: unsupportedExportFeatureCode,
          message:
              'exportTimeline: reversed clips with transitions are not supported',
        ),
      );
      expect(report.pass, isTrue);

      final wrongToken =
          VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
            _laneReversedTransition(),
            PlatformException(
              code: unsupportedExportFeatureCode,
              message: 'exportTimeline: overlays are not supported',
            ),
          );
      expect(wrongToken.pass, isFalse);
      expect(
        wrongToken.failureReason,
        startsWith('error_message_missing_token'),
      );
    });

    test('(e) reversed + overlay requires the overlays token', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
        _laneReversedOverlay(),
        PlatformException(
          code: unsupportedExportFeatureCode,
          message:
              'exportTimeline: reversed clips with overlays are not supported',
        ),
      );
      expect(report.pass, isTrue);
    });

    test('(f) reversed + beauty requires the Beauty V2 token', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
        _laneReversedBeauty(),
        PlatformException(
          code: unsupportedExportFeatureCode,
          message:
              'exportTimeline: reversed clips with Beauty V2 are not supported',
        ),
      );
      expect(report.pass, isTrue);
    });

    test('(g) reversed + audioSidecar requires the audio tracks token', () {
      final report = VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
        _laneReversedAudioSidecar(),
        PlatformException(
          code: unsupportedExportFeatureCode,
          message:
              'exportTimeline: reversed clips with audio tracks are not supported',
        ),
      );
      expect(report.pass, isTrue);
    });

    test(
      '(h) image + isReversed requires INVALID_ARG and the isReversed token, '
      'and the native message also names video',
      () {
        const message =
            "exportTimeline: clip.isReversed is only supported for video "
            "clips (mediaKind 'image' with isReversed=true)";
        final report =
            VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
              _laneImageReversed(),
              PlatformException(code: invalidArgExportCode, message: message),
            );
        expect(report.pass, isTrue);
        expect(message, contains(reversedClipIsReversedToken));
        expect(message, contains(reversedClipVideoToken));

        final wrongCode =
            VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
              _laneImageReversed(),
              PlatformException(
                code: unsupportedExportFeatureCode,
                message: message,
              ),
            );
        expect(wrongCode.pass, isFalse);
        expect(wrongCode.failureReason, startsWith('error_code_mismatch'));
      },
    );

    test('wrong error code fails', () {
      final report =
          VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
            _laneReversedTransition(),
            PlatformException(code: 'EXPORT_FAILED', message: 'pass-1 failed'),
          );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('error_code_mismatch'));
    });

    test('a positive lane that threw fails', () {
      final report =
          VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
            _laneSingleReversed(),
            PlatformException(code: 'EXPORT_FAILED', message: 'pass-1 failed'),
          );
      expect(report.pass, isFalse);
      expect(
        report.failureReason,
        'unexpected_platform_exception:EXPORT_FAILED',
      );
    });
  });

  group('whole-run report', () {
    test('PASS requires a positive lane and every lane passing', () {
      final positive = VGTimelineReverseExportSmokeLaneReport.fromExportResult(
        _laneSingleReversed(),
        _successResult(),
        outputExists: true,
      );
      final failClosed =
          VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
            _laneImageReversed(),
            PlatformException(
              code: invalidArgExportCode,
              message:
                  "exportTimeline: clip.isReversed is only supported for video "
                  "clips (mediaKind 'image' with isReversed=true)",
            ),
          );
      final report = VGTimelineReverseExportSmokeReport(
        lanes: <VGTimelineReverseExportSmokeLaneReport>[positive, failClosed],
      );
      expect(report.pass, isTrue);
      expect(report.marker, VGTimelineReverseExportSmokeReport.passMarker);
      expect(report.failureReason, isEmpty);

      final onlyFailClosed = VGTimelineReverseExportSmokeReport(
        lanes: <VGTimelineReverseExportSmokeLaneReport>[failClosed],
      );
      expect(onlyFailClosed.pass, isFalse);
      expect(const VGTimelineReverseExportSmokeReport(lanes: []).pass, isFalse);
    });

    test('toMap/fromMap round trip preserves lanes and verdict', () {
      final positive = VGTimelineReverseExportSmokeLaneReport.fromExportResult(
        _laneSingleReversed(),
        _successResult(duration: 2.0),
        outputExists: true,
      );
      final report = VGTimelineReverseExportSmokeReport(
        lanes: <VGTimelineReverseExportSmokeLaneReport>[positive],
      );
      final map = report.toMap();
      expect(
        map['proofBoundary'],
        VGTimelineReverseExportSmokeReport.proofBoundary,
      );
      expect(map['marker'], VGTimelineReverseExportSmokeReport.passMarker);
      final parsed = VGTimelineReverseExportSmokeReport.fromMap(map);
      expect(parsed.pass, isTrue);
      expect(parsed.lanes, hasLength(1));
      expect(parsed.lanes.single.laneId, 'single_reversed');
      expect(parsed.lanes.single.renderBackend, expectedReverseRenderBackend);
      expect(parsed.lanes.single.durationSeconds, 2.0);
    });

    test('fromMap with malformed lanes yields a failing report', () {
      final parsed = VGTimelineReverseExportSmokeReport.fromMap(
        <Object?, Object?>{'lanes': 'nope'},
      );
      expect(parsed.lanes, isEmpty);
      expect(parsed.pass, isFalse);
      expect(parsed.marker, VGTimelineReverseExportSmokeReport.failMarker);
    });
  });

  group('runner over the real exportTimeline method', () {
    tearDown(_clearMockHandler);

    test(
      '(a) invokes exportTimeline with isReversed and passes a gles result',
      () async {
        String? seenMethod;
        Map<Object?, Object?>? seenArgs;
        _setMockHandler((method, args) async {
          seenMethod = method;
          seenArgs = args as Map<Object?, Object?>;
          return _successResult(
            duration: 2.0,
            path: '/data/local/tmp/out_single_reversed.mp4',
          );
        });
        final runner = VGTimelineReverseExportSmokeRunner(
          channel: _channel,
          fileExists: (path) =>
              path == '/data/local/tmp/out_single_reversed.mp4',
        );
        final report = await runner.run(<VGTimelineReverseExportSmokeRequest>[
          _laneSingleReversed(),
        ]);
        expect(seenMethod, 'exportTimeline');
        final draft = seenArgs!['draft'] as Map<Object?, Object?>;
        final clips = draft['clips'] as List<Object?>;
        expect((clips.single as Map)['isReversed'], isTrue);
        expect(report.pass, isTrue);
        expect(report.lanes.single.outputExists, isTrue);
      },
    );

    test('(b) mixed forward+reversed hard cut passes end to end', () async {
      _setMockHandler((method, args) async {
        return _successResult(
          duration: 2.0,
          path: '/data/local/tmp/out_mixed.mp4',
        );
      });
      final runner = VGTimelineReverseExportSmokeRunner(
        channel: _channel,
        fileExists: (_) => true,
      );
      final report = await runner.run(<VGTimelineReverseExportSmokeRequest>[
        _laneMixedForwardReversed(),
      ]);
      expect(report.pass, isTrue);
      expect(report.lanes.single.renderBackend, expectedReverseRenderBackend);
    });

    test(
      'fail-closed PlatformException from native passes the reversed lanes',
      () async {
        _setMockHandler((method, args) async {
          final draft = (args as Map)['draft'] as Map;
          final transitions = draft['transitions'] as List;
          if (transitions.isNotEmpty) {
            throw PlatformException(
              code: unsupportedExportFeatureCode,
              message:
                  'exportTimeline: reversed clips with transitions are not supported',
            );
          }
          return _successResult();
        });
        final runner = VGTimelineReverseExportSmokeRunner(
          channel: _channel,
          fileExists: (_) => true,
        );
        final report = await runner.run(<VGTimelineReverseExportSmokeRequest>[
          _laneSingleReversed(),
          _laneReversedTransition(),
        ]);
        expect(report.pass, isTrue);
        expect(report.lanes, hasLength(2));
        expect(report.lanes[1].errorCode, unsupportedExportFeatureCode);
      },
    );

    test('a vulkan-backed success fails the positive lane', () async {
      _setMockHandler(
        (method, args) async => _successResult(backend: 'vulkan'),
      );
      final runner = VGTimelineReverseExportSmokeRunner(
        channel: _channel,
        fileExists: (_) => true,
      );
      final report = await runner.run(<VGTimelineReverseExportSmokeRequest>[
        _laneSingleReversed(),
      ]);
      expect(report.pass, isFalse);
      expect(
        report.failureReason,
        startsWith('single_reversed:render_backend_not_gles'),
      );
    });

    test('a missing plugin becomes a harness failure, not a throw', () async {
      _clearMockHandler();
      final runner = VGTimelineReverseExportSmokeRunner(
        channel: _channel,
        fileExists: (_) => true,
      );
      final report = await runner.run(<VGTimelineReverseExportSmokeRequest>[
        _laneSingleReversed(),
      ]);
      expect(report.pass, isFalse);
      expect(
        report.lanes.single.failureReason,
        startsWith('harness_exception'),
      );
    });
  });
}
