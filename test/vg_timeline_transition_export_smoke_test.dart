// vg_timeline_transition_export_smoke_test.dart
// vanguard_media_engine — P5-COMPOSITOR-TRANS (PRODUCTION-EXPORT-ROUTE):
// production `exportTimeline` transition smoke Dart model, parser, report
// and fail-closed contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_transition_export_smoke.dart';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

VGTimelineTransitionExportSmokeClip _clip(String id, {double end = 2.0}) =>
    VGTimelineTransitionExportSmokeClip(
      id: id,
      sourcePath: '/data/local/tmp/$id.mov',
      trimStartSeconds: 0.0,
      trimEndSeconds: end,
    );

VGTimelineTransitionExportSmokeRequest _request({
  String laneId = 'dissolve',
  String type = 'dissolve',
  double transitionSeconds = 0.5,
  VGTimelineTransitionExportSmokeExpectation expectation =
      const VGTimelineTransitionExportSmokeExpectation.success(),
}) => VGTimelineTransitionExportSmokeRequest(
  laneId: laneId,
  clips: <VGTimelineTransitionExportSmokeClip>[
    _clip('clip-a'),
    _clip('clip-b'),
  ],
  transitions: <VGTimelineTransitionExportSmokeTransition>[
    VGTimelineTransitionExportSmokeTransition(
      id: 'tr-1',
      type: type,
      durationSeconds: transitionSeconds,
      fromClipId: 'clip-a',
      toClipId: 'clip-b',
    ),
  ],
  outputPath: '/data/local/tmp/out_$laneId.mp4',
  expectation: expectation,
);

Map<String, Object?> _successResult({
  String backend = 'vulkan',
  double duration = 3.5,
  int transitionCount = 1,
  String path = '/data/local/tmp/out_dissolve.mp4',
}) => <String, Object?>{
  'success': true,
  'path': path,
  'durationSeconds': duration,
  'width': 720,
  'height': 1280,
  'fps': 30,
  'exportRoiSidecarPath': '$path.roi.json',
  'renderBackend': backend,
  'transitionCount': transitionCount,
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

  group('transition wire-name parser contract', () {
    test('every supported family classifies as supported', () {
      for (final name in supportedTransitionWireNames) {
        expect(
          VGTimelineTransitionExportWireKind.classify(name),
          VGTimelineTransitionExportWireKind.supported,
          reason: name,
        );
      }
      expect(supportedTransitionWireNames, contains('dissolve'));
      expect(supportedTransitionWireNames, contains('crossfade'));
      expect(
        supportedTransitionWireNames.where((n) => n.startsWith('slide')),
        hasLength(4),
      );
      expect(
        supportedTransitionWireNames.where((n) => n.startsWith('wipe')),
        hasLength(4),
      );
    });

    test('classification is trimmed and case-insensitive like native', () {
      expect(
        VGTimelineTransitionExportWireKind.classify('  DISSOLVE '),
        VGTimelineTransitionExportWireKind.supported,
      );
      expect(
        VGTimelineTransitionExportWireKind.classify('wipeleft'),
        VGTimelineTransitionExportWireKind.supported,
      );
      expect(
        VGTimelineTransitionExportWireKind.classify('None'),
        VGTimelineTransitionExportWireKind.hardCut,
      );
    });

    test('fade is unsupported and never remapped', () {
      expect(failClosedTransitionWireNames, contains('fade'));
      expect(supportedTransitionWireNames, isNot(contains('fade')));
      expect(
        VGTimelineTransitionExportWireKind.classify('fade'),
        VGTimelineTransitionExportWireKind.unsupported,
      );
      expect(
        VGTimelineTransitionExportWireKind.classify('zoom'),
        VGTimelineTransitionExportWireKind.unsupported,
      );
      expect(
        VGTimelineTransitionExportWireKind.classify(''),
        VGTimelineTransitionExportWireKind.unsupported,
      );
    });
  });

  group('request model', () {
    test('expected duration is sum of trim windows minus overlaps', () {
      final request = _request();
      expect(request.expectedDurationSeconds, closeTo(3.5, 1e-9));
      expect(request.supportedTransitionCount, 1);
    });

    test(
      'hard cuts and unsupported types do not shorten expected duration',
      () {
        expect(
          _request(type: 'none').expectedDurationSeconds,
          closeTo(4.0, 1e-9),
        );
        expect(
          _request(type: 'fade').expectedDurationSeconds,
          closeTo(4.0, 1e-9),
        );
        expect(_request(type: 'fade').supportedTransitionCount, 0);
      },
    );

    test('expected duration never goes negative', () {
      final request = VGTimelineTransitionExportSmokeRequest(
        laneId: 'x',
        clips: <VGTimelineTransitionExportSmokeClip>[
          _clip('a', end: 0.2),
          _clip('b', end: 0.2),
        ],
        transitions: const <VGTimelineTransitionExportSmokeTransition>[
          VGTimelineTransitionExportSmokeTransition(
            id: 't',
            type: 'dissolve',
            durationSeconds: 1.0,
            fromClipId: 'a',
            toClipId: 'b',
          ),
        ],
        outputPath: '/tmp/x.mp4',
        expectation: const VGTimelineTransitionExportSmokeExpectation.success(),
      );
      expect(request.expectedDurationSeconds, 0.0);
    });

    test(
      'exportTimeline arguments preserve clip ids and raw transition types',
      () {
        final args = _request(type: 'slideLeft').toExportTimelineArguments();
        final draft = args['draft'] as Map<String, Object?>;
        final clips = draft['clips'] as List<Object?>;
        final transitions = draft['transitions'] as List<Object?>;
        expect(clips, hasLength(2));
        expect((clips[0] as Map)['id'], 'clip-a');
        expect((clips[1] as Map)['id'], 'clip-b');
        expect((clips[0] as Map)['mediaKind'], 'video');
        expect((clips[0] as Map)['trimEndSeconds'], 2.0);
        expect((clips[0] as Map)['speed'], 1.0);
        expect(transitions, hasLength(1));
        final t = transitions[0] as Map;
        expect(t['type'], 'slideLeft');
        expect(t['fromClipId'], 'clip-a');
        expect(t['toClipId'], 'clip-b');
        expect(t['durationSeconds'], 0.5);
        expect(draft['canvasWidth'], 720);
        expect(draft['canvasHeight'], 1280);
        expect(draft['fps'], 30);
        expect(draft['overlays'], isEmpty);
        expect(draft.containsKey('audioSidecar'), isFalse);
        expect(args['outputPath'], '/data/local/tmp/out_dissolve.mp4');
        expect(args['width'], 720);
        expect(args['height'], 1280);
        expect(args['fps'], 30);
        expect(args['bitrateBps'], 4000000);
      },
    );
  });

  group('lane report from export result', () {
    test('passes when vulkan, file exists, duration within tolerance', () {
      final report = VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(duration: 3.5 + 0.1),
        outputExists: true,
      );
      expect(report.pass, isTrue);
      expect(report.status, 'PASS');
      expect(report.renderBackend, 'vulkan');
      expect(report.durationDeltaSeconds, closeTo(0.1, 1e-9));
      expect(report.transitionCount, 1);
    });

    test('fails when renderBackend is gles', () {
      final report = VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(backend: 'gles'),
        outputExists: true,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('render_backend_not_vulkan'));
    });

    test('fails when the output file is missing', () {
      final report = VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(),
        outputExists: false,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, 'output_file_missing');
    });

    test('fails when duration is not overlap-shortened', () {
      // A hard-cut re-encode would report the full 4.0 s.
      final report = VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(duration: 4.0),
        outputExists: true,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('duration_mismatch'));
    });

    test('fails when transitionCount disagrees', () {
      final report = VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(transitionCount: 0),
        outputExists: true,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('transition_count_mismatch'));
    });

    test('null result and success=false fail', () {
      expect(
        VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
          _request(),
          null,
          outputExists: false,
        ).failureReason,
        'native_returned_null_result',
      );
      expect(
        VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
          _request(),
          <String, Object?>{'success': false},
          outputExists: false,
        ).failureReason,
        'result_success_false',
      );
    });

    test('a fail-closed lane that succeeded fails', () {
      final report = VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
        _request(
          laneId: 'fade',
          type: 'fade',
          expectation:
              const VGTimelineTransitionExportSmokeExpectation.failClosed(
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
    test('fade fail-closed passes with matching code and message token', () {
      final report =
          VGTimelineTransitionExportSmokeLaneReport.fromPlatformException(
            _request(
              laneId: 'fade',
              type: 'fade',
              expectation:
                  const VGTimelineTransitionExportSmokeExpectation.failClosed(
                    errorCode: unsupportedExportFeatureCode,
                    messageContains: 'not supported',
                  ),
            ),
            PlatformException(
              code: unsupportedExportFeatureCode,
              message:
                  "exportTimeline: transition type 'fade' is not supported",
            ),
          );
      expect(report.pass, isTrue);
      expect(report.errorCode, unsupportedExportFeatureCode);
    });

    test(
      'no-Vulkan fail-closed requires the transitions_require_vulkan token',
      () {
        final request = _request(
          laneId: 'novulkan',
          expectation:
              const VGTimelineTransitionExportSmokeExpectation.failClosed(
                errorCode: unsupportedExportFeatureCode,
                messageContains: transitionsRequireVulkanReason,
              ),
        );
        final pass =
            VGTimelineTransitionExportSmokeLaneReport.fromPlatformException(
              request,
              PlatformException(
                code: unsupportedExportFeatureCode,
                message:
                    'exportTimeline: transitions require the Vulkan export backend '
                    '(transitions_require_vulkan:vulkan_scope_not_supported)',
              ),
            );
        expect(pass.pass, isTrue);
        final wrongToken =
            VGTimelineTransitionExportSmokeLaneReport.fromPlatformException(
              request,
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
      },
    );

    test('wrong error code fails', () {
      final report =
          VGTimelineTransitionExportSmokeLaneReport.fromPlatformException(
            _request(
              laneId: 'fade',
              type: 'fade',
              expectation:
                  const VGTimelineTransitionExportSmokeExpectation.failClosed(
                    errorCode: unsupportedExportFeatureCode,
                  ),
            ),
            PlatformException(code: 'EXPORT_FAILED', message: 'pass-1 failed'),
          );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('error_code_mismatch'));
    });

    test('a positive lane that threw fails', () {
      final report =
          VGTimelineTransitionExportSmokeLaneReport.fromPlatformException(
            _request(),
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
      final positive =
          VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
            _request(),
            _successResult(),
            outputExists: true,
          );
      final failClosed =
          VGTimelineTransitionExportSmokeLaneReport.fromPlatformException(
            _request(
              laneId: 'fade',
              type: 'fade',
              expectation:
                  const VGTimelineTransitionExportSmokeExpectation.failClosed(
                    errorCode: unsupportedExportFeatureCode,
                  ),
            ),
            PlatformException(code: unsupportedExportFeatureCode),
          );
      final report = VGTimelineTransitionExportSmokeReport(
        lanes: <VGTimelineTransitionExportSmokeLaneReport>[
          positive,
          failClosed,
        ],
      );
      expect(report.pass, isTrue);
      expect(report.marker, VGTimelineTransitionExportSmokeReport.passMarker);
      expect(report.failureReason, isEmpty);

      final onlyFailClosed = VGTimelineTransitionExportSmokeReport(
        lanes: <VGTimelineTransitionExportSmokeLaneReport>[failClosed],
      );
      expect(onlyFailClosed.pass, isFalse);
      expect(
        const VGTimelineTransitionExportSmokeReport(lanes: []).pass,
        isFalse,
      );
    });

    test('toMap/fromMap round trip preserves lanes and verdict', () {
      final positive =
          VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
            _request(),
            _successResult(),
            outputExists: true,
          );
      final report = VGTimelineTransitionExportSmokeReport(
        lanes: <VGTimelineTransitionExportSmokeLaneReport>[positive],
      );
      final map = report.toMap();
      expect(
        map['proofBoundary'],
        VGTimelineTransitionExportSmokeReport.proofBoundary,
      );
      expect(map['marker'], VGTimelineTransitionExportSmokeReport.passMarker);
      final parsed = VGTimelineTransitionExportSmokeReport.fromMap(map);
      expect(parsed.pass, isTrue);
      expect(parsed.lanes, hasLength(1));
      expect(parsed.lanes.single.laneId, 'dissolve');
      expect(parsed.lanes.single.renderBackend, 'vulkan');
      expect(parsed.lanes.single.durationSeconds, 3.5);
      expect(parsed.lanes.single.expectedDurationSeconds, closeTo(3.5, 1e-9));
    });

    test('fromMap with malformed lanes yields a failing report', () {
      final parsed = VGTimelineTransitionExportSmokeReport.fromMap(
        <Object?, Object?>{'lanes': 'nope'},
      );
      expect(parsed.lanes, isEmpty);
      expect(parsed.pass, isFalse);
      expect(parsed.marker, VGTimelineTransitionExportSmokeReport.failMarker);
    });
  });

  group('runner over the real exportTimeline method', () {
    tearDown(_clearMockHandler);

    test(
      'invokes exportTimeline with the draft and passes a vulkan result',
      () async {
        String? seenMethod;
        Map<Object?, Object?>? seenArgs;
        _setMockHandler((method, args) async {
          seenMethod = method;
          seenArgs = args as Map<Object?, Object?>;
          return _successResult();
        });
        final runner = VGTimelineTransitionExportSmokeRunner(
          channel: _channel,
          fileExists: (path) => path == '/data/local/tmp/out_dissolve.mp4',
        );
        final report = await runner.run(
          <VGTimelineTransitionExportSmokeRequest>[_request()],
        );
        expect(seenMethod, 'exportTimeline');
        final draft = seenArgs!['draft'] as Map<Object?, Object?>;
        final transitions = draft['transitions'] as List<Object?>;
        expect((transitions.single as Map)['type'], 'dissolve');
        expect(report.pass, isTrue);
        expect(report.lanes.single.outputExists, isTrue);
      },
    );

    test(
      'fail-closed PlatformException from native passes the fade lane',
      () async {
        _setMockHandler((method, args) async {
          final draft = (args as Map)['draft'] as Map;
          final type = ((draft['transitions'] as List).single as Map)['type'];
          if (type == 'fade') {
            throw PlatformException(
              code: unsupportedExportFeatureCode,
              message:
                  "exportTimeline: transition type 'fade' is not supported",
            );
          }
          return _successResult();
        });
        final runner = VGTimelineTransitionExportSmokeRunner(
          channel: _channel,
          fileExists: (_) => true,
        );
        final report = await runner
            .run(<VGTimelineTransitionExportSmokeRequest>[
              _request(),
              _request(
                laneId: 'fade',
                type: 'fade',
                expectation:
                    const VGTimelineTransitionExportSmokeExpectation.failClosed(
                      errorCode: unsupportedExportFeatureCode,
                      messageContains: 'not supported',
                    ),
              ),
            ]);
        expect(report.pass, isTrue);
        expect(report.lanes, hasLength(2));
        expect(report.lanes[1].errorCode, unsupportedExportFeatureCode);
      },
    );

    test('a GLES-backed success fails the positive lane', () async {
      _setMockHandler((method, args) async => _successResult(backend: 'gles'));
      final runner = VGTimelineTransitionExportSmokeRunner(
        channel: _channel,
        fileExists: (_) => true,
      );
      final report = await runner.run(<VGTimelineTransitionExportSmokeRequest>[
        _request(),
      ]);
      expect(report.pass, isFalse);
      expect(
        report.failureReason,
        startsWith('dissolve:render_backend_not_vulkan'),
      );
    });

    test('a missing plugin becomes a harness failure, not a throw', () async {
      _clearMockHandler();
      final runner = VGTimelineTransitionExportSmokeRunner(
        channel: _channel,
        fileExists: (_) => true,
      );
      final report = await runner.run(<VGTimelineTransitionExportSmokeRequest>[
        _request(),
      ]);
      expect(report.pass, isFalse);
      expect(
        report.lanes.single.failureReason,
        startsWith('harness_exception'),
      );
    });
  });
}
