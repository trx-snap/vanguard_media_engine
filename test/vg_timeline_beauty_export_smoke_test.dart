// vg_timeline_beauty_export_smoke_test.dart
// vanguard_media_engine — P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A:
// production `exportTimeline` Beauty V2 smoke Dart model, serialization, report
// and fail-closed contract unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_beauty_export_smoke.dart';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

VGTimelineBeautyExportSmokeClip _clip(
  String id, {
  double end = 2.0,
  Object? beautyIntensity = 0.5,
  String mediaKind = 'video',
}) => VGTimelineBeautyExportSmokeClip(
  id: id,
  sourcePath: '/data/local/tmp/$id.mov',
  trimStartSeconds: 0.0,
  trimEndSeconds: end,
  mediaKind: mediaKind,
  beautyIntensity: beautyIntensity,
);

VGTimelineBeautyExportSmokeRequest _request({
  String laneId = 'beauty_soft_single',
  List<VGTimelineBeautyExportSmokeClip>? clips,
  List<VGTimelineBeautyExportSmokeTransition>? transitions,
  VGTimelineBeautyExportSmokeExpectation expectation =
      const VGTimelineBeautyExportSmokeExpectation.success(),
}) => VGTimelineBeautyExportSmokeRequest(
  laneId: laneId,
  clips: clips ?? <VGTimelineBeautyExportSmokeClip>[_clip('clip-a')],
  transitions: transitions ?? const <VGTimelineBeautyExportSmokeTransition>[],
  outputPath: '/data/local/tmp/out_$laneId.mp4',
  expectation: expectation,
);

Map<String, Object?> _successResult({
  String backend = 'vulkan',
  double duration = 2.0,
  int beautyClipCount = 1,
  int beautyFrameCount = 60,
  String path = '/data/local/tmp/out_beauty_soft_single.mp4',
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

  group('request clip model and wire serialization', () {
    test('toMap includes beautyIntensity when non-null', () {
      final clip = _clip('clip-beauty', beautyIntensity: 0.75);
      final map = clip.toMap();
      expect(map['id'], 'clip-beauty');
      expect(map['sourcePath'], '/data/local/tmp/clip-beauty.mov');
      expect(map['mediaKind'], 'video');
      expect(map['trimStartSeconds'], 0.0);
      expect(map['trimEndSeconds'], 2.0);
      expect(map['durationSeconds'], 2.0);
      expect(map['beautyIntensity'], 0.75);
      expect(clip.hasBeauty, isTrue);
    });

    test('toMap omits beautyIntensity when null', () {
      final clip = _clip('clip-plain', beautyIntensity: null);
      final map = clip.toMap();
      expect(map['id'], 'clip-plain');
      expect(map.containsKey('beautyIntensity'), isFalse);
      expect(clip.hasBeauty, isFalse);
    });

    test('raw invalid beautyIntensity is preserved for negative testing', () {
      final rawNegative = _clip('clip-neg', beautyIntensity: -0.1);
      expect(rawNegative.toMap()['beautyIntensity'], -0.1);

      final rawString = _clip('clip-str', beautyIntensity: 'invalid');
      expect(rawString.toMap()['beautyIntensity'], 'invalid');
    });

    test('toExportTimelineArguments builds draft and top-level keys', () {
      final request = _request(
        clips: <VGTimelineBeautyExportSmokeClip>[
          _clip('clip-1', end: 2.0, beautyIntensity: 0.5),
          _clip('clip-2', end: 2.0, beautyIntensity: null),
        ],
      );
      final args = request.toExportTimelineArguments();
      expect(args['outputPath'], '/data/local/tmp/out_beauty_soft_single.mp4');
      expect(args['width'], 720);
      expect(args['height'], 1280);
      expect(args['fps'], 30);
      expect(args['bitrateBps'], 4000000);

      final draft = args['draft'] as Map<String, Object?>;
      expect(draft['id'], 'vg-beauty-export-smoke-beauty_soft_single');
      expect(draft['canvasWidth'], 720);
      expect(draft['canvasHeight'], 1280);
      expect(draft['fps'], 30);
      expect(draft['overlays'], isEmpty);

      final clips = draft['clips'] as List<Object?>;
      expect(clips, hasLength(2));
      expect((clips[0] as Map)['beautyIntensity'], 0.5);
      expect((clips[1] as Map).containsKey('beautyIntensity'), isFalse);

      expect(request.expectedDurationSeconds, 4.0);
      expect(request.expectedBeautyClipCount, 1);
      expect(request.expectedBeautyFrameCountPositive, isTrue);
    });
  });

  group('lane report from export result (success contract)', () {
    test(
      'passes when vulkan, file exists, duration in tolerance, counts valid',
      () {
        final report = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
          _request(),
          _successResult(
            duration: 2.05,
            beautyClipCount: 1,
            beautyFrameCount: 60,
          ),
          outputExists: true,
        );
        expect(report.pass, isTrue);
        expect(report.status, 'PASS');
        expect(report.renderBackend, 'vulkan');
        expect(report.outputExists, isTrue);
        expect(report.beautyClipCount, 1);
        expect(report.beautyFrameCount, 60);
        expect(report.durationDeltaSeconds, closeTo(0.05, 1e-9));
        expect(report.failureReason, isEmpty);
      },
    );

    test('fails when renderBackend is not vulkan', () {
      final report = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(backend: 'gles'),
        outputExists: true,
      );
      expect(report.pass, isFalse);
      expect(report.status, 'FAIL');
      expect(report.failureReason, 'render_backend_not_vulkan:gles');
    });

    test('fails when output file is missing', () {
      final report = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(),
        outputExists: false,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, 'output_file_missing');
    });

    test('fails when duration exceeds tolerance', () {
      final report = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(duration: 2.3),
        outputExists: true,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('duration_mismatch'));
    });

    test('fails when beautyClipCount disagrees with expected', () {
      final report = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(beautyClipCount: 0),
        outputExists: true,
      );
      expect(report.pass, isFalse);
      expect(
        report.failureReason,
        'beauty_clip_count_mismatch:reported=0:expected=1',
      );
    });

    test('fails when beautyFrameCount is not positive when expected', () {
      final reportZero = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(beautyFrameCount: 0),
        outputExists: true,
      );
      expect(reportZero.pass, isFalse);
      expect(
        reportZero.failureReason,
        'beauty_frame_count_not_positive:reported=0',
      );

      final reportNeg = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(beautyFrameCount: -5),
        outputExists: true,
      );
      expect(reportNeg.pass, isFalse);
      expect(
        reportNeg.failureReason,
        'beauty_frame_count_not_positive:reported=-5',
      );
    });

    test(
      'passes when expectedBeautyFrameCountPositive is false and count is 0',
      () {
        final requestNoBeauty = _request(
          clips: <VGTimelineBeautyExportSmokeClip>[
            _clip('plain', beautyIntensity: null),
          ],
          expectation: const VGTimelineBeautyExportSmokeExpectation.success(
            expectedBeautyClipCount: 0,
            expectedBeautyFrameCountPositive: false,
          ),
        );
        final report = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
          requestNoBeauty,
          _successResult(beautyClipCount: 0, beautyFrameCount: 0),
          outputExists: true,
        );
        expect(report.pass, isTrue);
        expect(report.beautyClipCount, 0);
        expect(report.beautyFrameCount, 0);
      },
    );

    test('null result and success=false fail', () {
      expect(
        VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
          _request(),
          null,
          outputExists: false,
        ).failureReason,
        'native_returned_null_result',
      );
      expect(
        VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
          _request(),
          <String, Object?>{'success': false},
          outputExists: false,
        ).failureReason,
        'result_success_false',
      );
    });

    test('a fail-closed lane that succeeded fails', () {
      final report = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(
          laneId: 'fail_lane',
          expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
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
    test(
      'beauty_transition_fail_closed passes with UNSUPPORTED_EXPORT_FEATURE and token',
      () {
        final request = _request(
          laneId: 'beauty_transition_fail_closed',
          expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: beautyV2UnsupportedWithTransitionToken,
          ),
        );
        final report = VGTimelineBeautyExportSmokeLaneReport.fromPlatformException(
          request,
          PlatformException(
            code: unsupportedExportFeatureCode,
            message:
                'exportTimeline: clip-level Beauty V2 is not supported alongside '
                'transitions (beauty_v2_unsupported_with_transition)',
          ),
        );
        expect(report.pass, isTrue);
        expect(report.status, 'PASS');
        expect(report.errorCode, unsupportedExportFeatureCode);
      },
    );

    test('beauty_invalid_negative passes with INVALID_ARG and token', () {
      final request = _request(
        laneId: 'beauty_invalid_negative',
        expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
          errorCode: invalidArgCode,
          messageContains: beautyIntensityToken,
        ),
      );
      final report = VGTimelineBeautyExportSmokeLaneReport.fromPlatformException(
        request,
        PlatformException(
          code: invalidArgCode,
          message:
              'exportTimeline: clip.beautyIntensity must be finite and in [0.0, 1.0]',
        ),
      );
      expect(report.pass, isTrue);
      expect(report.errorCode, invalidArgCode);
    });

    test(
      'beauty_non_vulkan_scope_fail_closed passes with UNSUPPORTED_EXPORT_FEATURE and token',
      () {
        final request = _request(
          laneId: 'beauty_non_vulkan_scope_fail_closed',
          expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
            errorCode: unsupportedExportFeatureCode,
            messageContains: beautyV2RequiresVulkanToken,
          ),
        );
        final report = VGTimelineBeautyExportSmokeLaneReport.fromPlatformException(
          request,
          PlatformException(
            code: unsupportedExportFeatureCode,
            message:
                'exportTimeline: Beauty V2 requires the Vulkan export backend '
                '(beauty_v2_requires_vulkan:vulkan_scope_not_supported)',
          ),
        );
        expect(report.pass, isTrue);
        expect(report.errorCode, unsupportedExportFeatureCode);
      },
    );

    test('wrong error code fails', () {
      final request = _request(
        laneId: 'beauty_invalid_negative',
        expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
          errorCode: invalidArgCode,
        ),
      );
      final report =
          VGTimelineBeautyExportSmokeLaneReport.fromPlatformException(
            request,
            PlatformException(code: 'EXPORT_FAILED', message: 'failed'),
          );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('error_code_mismatch'));
    });

    test('missing expected message token fails', () {
      final request = _request(
        laneId: 'beauty_invalid_negative',
        expectation: const VGTimelineBeautyExportSmokeExpectation.failClosed(
          errorCode: invalidArgCode,
          messageContains: 'beautyIntensity',
        ),
      );
      final report =
          VGTimelineBeautyExportSmokeLaneReport.fromPlatformException(
            request,
            PlatformException(
              code: invalidArgCode,
              message: 'exportTimeline: general error',
            ),
          );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('error_message_missing_token'));
    });

    test('unexpected exception on positive lane fails', () {
      final report =
          VGTimelineBeautyExportSmokeLaneReport.fromPlatformException(
            _request(),
            PlatformException(code: 'EXPORT_FAILED', message: 'encode failed'),
          );
      expect(report.pass, isFalse);
      expect(
        report.failureReason,
        'unexpected_platform_exception:EXPORT_FAILED',
      );
    });
  });

  group('whole-run report', () {
    test('PASS requires at least one positive lane and all lanes passing', () {
      final positive = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(),
        outputExists: true,
      );
      final failClosed =
          VGTimelineBeautyExportSmokeLaneReport.fromPlatformException(
            _request(
              laneId: 'invalid_lane',
              expectation:
                  const VGTimelineBeautyExportSmokeExpectation.failClosed(
                    errorCode: invalidArgCode,
                  ),
            ),
            PlatformException(code: invalidArgCode),
          );

      final report = VGTimelineBeautyExportSmokeReport(
        lanes: <VGTimelineBeautyExportSmokeLaneReport>[positive, failClosed],
      );
      expect(report.pass, isTrue);
      expect(report.marker, VGTimelineBeautyExportSmokeReport.passMarker);
      expect(report.failureReason, isEmpty);

      final onlyFailClosed = VGTimelineBeautyExportSmokeReport(
        lanes: <VGTimelineBeautyExportSmokeLaneReport>[failClosed],
      );
      expect(onlyFailClosed.pass, isFalse);
      expect(
        onlyFailClosed.marker,
        VGTimelineBeautyExportSmokeReport.failMarker,
      );

      expect(const VGTimelineBeautyExportSmokeReport(lanes: []).pass, isFalse);
    });

    test('one failing lane fails whole report', () {
      final positive = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(laneId: 'pos'),
        _successResult(),
        outputExists: true,
      );
      final failing = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(laneId: 'broken'),
        _successResult(backend: 'gles'),
        outputExists: true,
      );
      final report = VGTimelineBeautyExportSmokeReport(
        lanes: <VGTimelineBeautyExportSmokeLaneReport>[positive, failing],
      );
      expect(report.pass, isFalse);
      expect(report.status, 'FAIL');
      expect(report.marker, VGTimelineBeautyExportSmokeReport.failMarker);
      expect(
        report.failureReason,
        startsWith('broken:render_backend_not_vulkan'),
      );
    });

    test(
      'toMap and fromMap round-trip preserves proof boundary and fields',
      () {
        final positive = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
          _request(),
          _successResult(),
          outputExists: true,
        );
        final report = VGTimelineBeautyExportSmokeReport(
          lanes: <VGTimelineBeautyExportSmokeLaneReport>[positive],
        );
        final map = report.toMap();
        expect(
          map['proofBoundary'],
          VGTimelineBeautyExportSmokeReport.proofBoundary,
        );
        expect(map['marker'], VGTimelineBeautyExportSmokeReport.passMarker);

        final parsed = VGTimelineBeautyExportSmokeReport.fromMap(map);
        expect(parsed.pass, isTrue);
        expect(parsed.lanes, hasLength(1));
        expect(parsed.lanes.single.laneId, 'beauty_soft_single');
        expect(parsed.lanes.single.renderBackend, 'vulkan');
        expect(parsed.lanes.single.beautyClipCount, 1);
        expect(parsed.lanes.single.beautyFrameCount, 60);
      },
    );

    test('fromMap with malformed lanes yields failing report', () {
      final parsed = VGTimelineBeautyExportSmokeReport.fromMap(
        <Object?, Object?>{'lanes': 'invalid'},
      );
      expect(parsed.lanes, isEmpty);
      expect(parsed.pass, isFalse);
      expect(parsed.marker, VGTimelineBeautyExportSmokeReport.failMarker);
    });
  });

  group('runner over real exportTimeline method', () {
    tearDown(_clearMockHandler);

    test('invokes exportTimeline and parses success result', () async {
      String? seenMethod;
      Map<Object?, Object?>? seenArgs;
      _setMockHandler((method, args) async {
        seenMethod = method;
        seenArgs = args as Map<Object?, Object?>;
        return _successResult();
      });

      final runner = VGTimelineBeautyExportSmokeRunner(
        channel: _channel,
        fileExists: (path) =>
            path == '/data/local/tmp/out_beauty_soft_single.mp4',
      );
      final report = await runner.run(<VGTimelineBeautyExportSmokeRequest>[
        _request(),
      ]);
      expect(seenMethod, 'exportTimeline');
      final draft = seenArgs!['draft'] as Map<Object?, Object?>;
      final clips = draft['clips'] as List<Object?>;
      expect((clips.single as Map)['beautyIntensity'], 0.5);

      expect(report.pass, isTrue);
      expect(report.lanes.single.renderBackend, 'vulkan');
      expect(report.lanes.single.beautyClipCount, 1);
      expect(report.lanes.single.beautyFrameCount, 60);
    });

    test(
      'fail-closed PlatformException becomes passing fail-closed lane',
      () async {
        _setMockHandler((method, args) async {
          throw PlatformException(
            code: invalidArgCode,
            message:
                'exportTimeline: clip.beautyIntensity must be finite and in [0.0, 1.0]',
          );
        });

        final runner = VGTimelineBeautyExportSmokeRunner(
          channel: _channel,
          fileExists: (_) => true,
        );
        final report = await runner.runLane(
          _request(
            laneId: 'invalid_lane',
            expectation:
                const VGTimelineBeautyExportSmokeExpectation.failClosed(
                  errorCode: invalidArgCode,
                  messageContains: beautyIntensityToken,
                ),
          ),
        );
        expect(report.pass, isTrue);
        expect(report.errorCode, invalidArgCode);
      },
    );

    test('missing plugin becomes harness failure, does not throw', () async {
      _clearMockHandler();
      final runner = VGTimelineBeautyExportSmokeRunner(
        channel: _channel,
        fileExists: (_) => true,
      );
      final report = await runner.run(<VGTimelineBeautyExportSmokeRequest>[
        _request(),
      ]);
      expect(report.pass, isFalse);
      expect(
        report.lanes.single.failureReason,
        startsWith('harness_exception:missing_plugin'),
      );
    });
  });
}
