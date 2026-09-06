// vg_timeline_gles_beauty_export_smoke_test.dart
// vanguard_media_engine — P5-GLES-EXPORT-BEAUTY-PRODUCTION-ROUTE-A:
// focused Dart tests for the beauty smoke model's expectedRenderBackend /
// debugForceRenderBackend seam, mirroring the transition smoke's equivalent
// contract tests. Does not duplicate vg_timeline_beauty_export_smoke_test's
// (nonexistent) broader coverage -- this file is the sole focused test for
// this smoke model.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_beauty_export_smoke.dart';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

VGTimelineBeautyExportSmokeClip _clip(
  String id, {
  double end = 2.0,
  Object? beautyIntensity,
}) => VGTimelineBeautyExportSmokeClip(
  id: id,
  sourcePath: '/data/local/tmp/$id.mov',
  trimStartSeconds: 0.0,
  trimEndSeconds: end,
  beautyIntensity: beautyIntensity,
);

VGTimelineBeautyExportSmokeRequest _request({
  String laneId = 'beauty-gles',
  String expectedRenderBackend = 'vulkan',
  String? debugForceRenderBackend,
  VGTimelineBeautyExportSmokeExpectation expectation =
      const VGTimelineBeautyExportSmokeExpectation.success(),
}) => VGTimelineBeautyExportSmokeRequest(
  laneId: laneId,
  clips: <VGTimelineBeautyExportSmokeClip>[
    _clip('clip-a', beautyIntensity: 0.5),
  ],
  outputPath: '/data/local/tmp/out_$laneId.mp4',
  expectedRenderBackend: expectedRenderBackend,
  debugForceRenderBackend: debugForceRenderBackend,
  expectation: expectation,
);

Map<String, Object?> _successResult({
  String backend = 'vulkan',
  double duration = 2.0,
  int beautyClipCount = 1,
  int beautyFrameCount = 60,
  String path = '/data/local/tmp/out_beauty-gles.mp4',
}) => <String, Object?>{
  'success': true,
  'path': path,
  'durationSeconds': duration,
  'width': 720,
  'height': 1280,
  'fps': 30,
  'exportRoiSidecarPath': '$path.roi.json',
  'renderBackend': backend,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('request model', () {
    test(
      'default request does not emit debugForceRenderBackend and still expects vulkan',
      () {
        final request = _request();
        expect(request.expectedRenderBackend, 'vulkan');
        expect(request.debugForceRenderBackend, isNull);
        final args = request.toExportTimelineArguments();
        expect(args.containsKey('debugForceRenderBackend'), isFalse);
        final draft = args['draft'] as Map<String, Object?>;
        expect(draft.containsKey('debugForceRenderBackend'), isFalse);
      },
    );

    test(
      "debugForceRenderBackend == 'gles' is emitted as a top-level argument, not inside draft",
      () {
        final request = _request(
          expectedRenderBackend: 'gles',
          debugForceRenderBackend: 'gles',
        );
        expect(request.expectedRenderBackend, 'gles');
        expect(request.debugForceRenderBackend, 'gles');
        final args = request.toExportTimelineArguments();
        expect(args['debugForceRenderBackend'], 'gles');
        final draft = args['draft'] as Map<String, Object?>;
        expect(draft.containsKey('debugForceRenderBackend'), isFalse);
      },
    );
  });

  group('lane report from export result', () {
    test("a GLES result passes when expectedRenderBackend == 'gles'", () {
      final report = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(expectedRenderBackend: 'gles'),
        _successResult(backend: 'gles'),
        outputExists: true,
      );
      expect(report.pass, isTrue);
      expect(report.status, 'PASS');
      expect(report.renderBackend, 'gles');
      expect(report.failureReason, isEmpty);
    });

    test('a GLES result still fails for the default Vulkan expectation', () {
      final report = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(backend: 'gles'),
        outputExists: true,
      );
      expect(report.pass, isFalse);
      expect(report.failureReason, startsWith('render_backend_not_vulkan'));
    });

    test('passes when vulkan, file exists, duration within tolerance', () {
      final report = VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        _request(),
        _successResult(duration: 2.0),
        outputExists: true,
      );
      expect(report.pass, isTrue);
      expect(report.status, 'PASS');
      expect(report.renderBackend, 'vulkan');
    });
  });

  group('runner over the real exportTimeline method', () {
    test(
      'runner forwards debugForceRenderBackend at top level and passes GLES result',
      () async {
        Map<Object?, Object?>? seenArgs;
        _setMockHandler((method, args) async {
          seenArgs = args as Map<Object?, Object?>;
          return _successResult(backend: 'gles');
        });
        final runner = VGTimelineBeautyExportSmokeRunner(
          channel: _channel,
          fileExists: (_) => true,
        );
        final report = await runner.run(<VGTimelineBeautyExportSmokeRequest>[
          _request(
            expectedRenderBackend: 'gles',
            debugForceRenderBackend: 'gles',
          ),
        ]);
        expect(seenArgs!['debugForceRenderBackend'], 'gles');
        final draft = seenArgs!['draft'] as Map<Object?, Object?>;
        expect(draft.containsKey('debugForceRenderBackend'), isFalse);
        expect(report.pass, isTrue);
        expect(report.lanes.single.renderBackend, 'gles');
      },
    );

    test('a GLES-backed success fails the positive lane by default', () async {
      _setMockHandler((method, args) async => _successResult(backend: 'gles'));
      final runner = VGTimelineBeautyExportSmokeRunner(
        channel: _channel,
        fileExists: (_) => true,
      );
      final report = await runner.run(<VGTimelineBeautyExportSmokeRequest>[
        _request(),
      ]);
      expect(report.pass, isFalse);
      expect(
        report.failureReason,
        startsWith('beauty-gles:render_backend_not_vulkan'),
      );
    });
  });
}
