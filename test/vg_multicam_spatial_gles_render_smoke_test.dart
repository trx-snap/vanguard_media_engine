// vg_multicam_spatial_gles_render_smoke_test.dart
// vanguard_media_engine — P3-MULTICAM-NODE: Android True-DAG Phase 3
// GLES-first spatial multi-texture diagnostic render pass smoke Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_multicam_spatial_gles_two_texture_layout_render_readback_only_no_vulkan_no_camera_no_oes_proof_no_opacity_no_corner_radius_no_recording_no_product';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'pass': true,
  'decision': 'pass',
  'raw':
      'status=PASS;'
      'clientVersion=3;'
      'vendor=ARM;'
      'renderer=Mali-G78;'
      'version=OpenGL ES 3.2;'
      'bufferADescribe=success;'
      'bufferAFill=success;'
      'bufferBDescribe=success;'
      'bufferBFill=success;'
      'preInitLane=rejected_as_expected;'
      'preInitLastError=not_initialized;'
      'initialize=success;'
      'attach=success;'
      'importBufferA=success;'
      'handleA=1001;'
      'targetA=3553;'
      'importBufferB=success;'
      'handleB=1002;'
      'targetB=3553;'
      'invalidHandleLane=rejected_as_expected;'
      'invalidHandleLastError=invalid_buffer_handle;'
      'invalidRectLane=rejected_as_expected;'
      'invalidRectLastError=gles_multicam_spatial_compositor_invalid_rect;'
      'topBottomSplitOk=true;'
      'topBottomSplitLastError=none;'
      'leftRightSplitOk=true;'
      'leftRightSplitLastError=none;'
      'pipTopLeftOk=true;'
      'pipTopLeftLastError=none;'
      'pipFreeFloatingOk=true;'
      'pipFreeFloatingLastError=none;'
      'sentinelClearOk=true;'
      'presentComposite=success;'
      'presentCompositeLastError=none;'
      'releaseBufferA=success;'
      'releaseBufferAFence=-1;'
      'hasAAfterRelease=false;'
      'releaseBufferB=success;'
      'releaseBufferBFence=-1;'
      'hasBAfterRelease=false;'
      'postReleaseLane=rejected_as_expected;'
      'postReleaseLastError=invalid_buffer_handle;'
      'detach=success;'
      'shutdown=success;'
      'idempotentShutdown=success;'
      'proofBoundary=$_kCanonicalProofBoundary;'
      'lastError=none',
  'proofBoundary': _kCanonicalProofBoundary,
  'metrics': const <String, Object?>{
    'clientVersion': 3,
    'vendor': 'ARM',
    'renderer': 'Mali-G78',
    'version': 'OpenGL ES 3.2',
    'bufferADescribe': 'success',
    'bufferAFill': 'success',
    'bufferBDescribe': 'success',
    'bufferBFill': 'success',
    'preInitLane': 'rejected_as_expected',
    'preInitLastError': 'not_initialized',
    'initialize': 'success',
    'attach': 'success',
    'importBufferA': 'success',
    'handleA': 1001,
    'targetA': 3553,
    'importBufferB': 'success',
    'handleB': 1002,
    'targetB': 3553,
    'invalidHandleLane': 'rejected_as_expected',
    'invalidHandleLastError': 'invalid_buffer_handle',
    'invalidRectLane': 'rejected_as_expected',
    'invalidRectLastError': 'gles_multicam_spatial_compositor_invalid_rect',
    'topBottomSplitOk': true,
    'topBottomSplitLastError': 'none',
    'leftRightSplitOk': true,
    'leftRightSplitLastError': 'none',
    'pipTopLeftOk': true,
    'pipTopLeftLastError': 'none',
    'pipFreeFloatingOk': true,
    'pipFreeFloatingLastError': 'none',
    'sentinelClearOk': true,
    'presentComposite': 'success',
    'presentCompositeLastError': 'none',
    'releaseBufferA': 'success',
    'releaseBufferAFence': -1,
    'hasAAfterRelease': false,
    'releaseBufferB': 'success',
    'releaseBufferBFence': -1,
    'hasBAfterRelease': false,
    'postReleaseLane': 'rejected_as_expected',
    'postReleaseLastError': 'invalid_buffer_handle',
    'detach': 'success',
    'shutdown': 'success',
    'idempotentShutdown': 'success',
  },
  'lastError': 'none',
  'textureId': 42,
  'surfaceProducerReleased': false,
  'width': 128,
  'height': 128,
  if (overrides != null) ...overrides,
};

VGMultiCamSpatialGlesRenderSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGMultiCamSpatialGlesRenderSmokeReport.fromMap(
  _createSampleRawMap(overrides),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGMultiCamSpatialGlesRenderSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 3 values in order', () {
      expect(
        VGMultiCamSpatialGlesRenderSmokeDecision.values,
        orderedEquals(const [
          VGMultiCamSpatialGlesRenderSmokeDecision.pass,
          VGMultiCamSpatialGlesRenderSmokeDecision.fail,
          VGMultiCamSpatialGlesRenderSmokeDecision.harnessException,
        ]),
      );
      expect(VGMultiCamSpatialGlesRenderSmokeDecision.values.length, equals(3));
    });

    test('fromRaw maps all known valid decision strings', () {
      expect(
        VGMultiCamSpatialGlesRenderSmokeDecision.fromRaw('pass'),
        equals(VGMultiCamSpatialGlesRenderSmokeDecision.pass),
      );
      expect(
        VGMultiCamSpatialGlesRenderSmokeDecision.fromRaw('PASS'),
        equals(VGMultiCamSpatialGlesRenderSmokeDecision.pass),
      );
      expect(
        VGMultiCamSpatialGlesRenderSmokeDecision.fromRaw('fail'),
        equals(VGMultiCamSpatialGlesRenderSmokeDecision.fail),
      );
      expect(
        VGMultiCamSpatialGlesRenderSmokeDecision.fromRaw('FAIL'),
        equals(VGMultiCamSpatialGlesRenderSmokeDecision.fail),
      );
      expect(
        VGMultiCamSpatialGlesRenderSmokeDecision.fromRaw('harnessException'),
        equals(VGMultiCamSpatialGlesRenderSmokeDecision.harnessException),
      );
      expect(
        VGMultiCamSpatialGlesRenderSmokeDecision.fromRaw('harness_exception'),
        equals(VGMultiCamSpatialGlesRenderSmokeDecision.harnessException),
      );
    });

    test(
      'fromRaw falls back to harnessException for unknown, non-string, or null values',
      () {
        const invalidValues = <Object?>[
          'unknownDecision',
          '',
          null,
          123,
          3.14,
          true,
          <String>[],
          <String, Object?>{},
        ];
        for (final invalid in invalidValues) {
          expect(
            VGMultiCamSpatialGlesRenderSmokeDecision.fromRaw(invalid),
            equals(VGMultiCamSpatialGlesRenderSmokeDecision.harnessException),
          );
        }
      },
    );
  });

  group('VGMultiCamSpatialGlesRenderSmokeReport fromMap and toMap', () {
    test('pass report parses and round-trips all fields cleanly', () {
      final report = VGMultiCamSpatialGlesRenderSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(report.pass, isTrue);
      expect(
        report.decision,
        equals(VGMultiCamSpatialGlesRenderSmokeDecision.pass),
      );
      expect(report.isPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isHarnessException, isFalse);

      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.textureId, equals(42));
      expect(report.surfaceProducerReleased, isFalse);
      expect(report.width, equals(128));
      expect(report.height, equals(128));
      expect(report.lastError, equals('none'));

      // Setup / import lanes
      expect(report.bufferADescribePass, isTrue);
      expect(report.bufferAFillPass, isTrue);
      expect(report.bufferBDescribePass, isTrue);
      expect(report.bufferBFillPass, isTrue);
      expect(report.preInitLanePass, isTrue);
      expect(report.initializePass, isTrue);
      expect(report.attachPass, isTrue);
      expect(report.importBufferAPass, isTrue);
      expect(report.importBufferBPass, isTrue);

      // Validation / rejection lanes
      expect(report.invalidHandleLanePass, isTrue);
      expect(report.invalidRectLanePass, isTrue);

      // Spatial composite render lanes
      expect(report.topBottomSplitPass, isTrue);
      expect(report.leftRightSplitPass, isTrue);
      expect(report.pipTopLeftPass, isTrue);
      expect(report.pipFreeFloatingPass, isTrue);
      expect(report.sentinelClearPass, isTrue);
      expect(report.presentCompositePass, isTrue);

      // Release / teardown lanes
      expect(report.releaseBufferAPass, isTrue);
      expect(report.releaseBufferBPass, isTrue);
      expect(report.hasAAfterReleasePass, isTrue);
      expect(report.hasBAfterReleasePass, isTrue);
      expect(report.postReleaseLanePass, isTrue);
      expect(report.detachPass, isTrue);
      expect(report.shutdownPass, isTrue);
      expect(report.idempotentShutdownPass, isTrue);

      // Aggregate
      expect(report.allNativeLanesPass, isTrue);

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], equals('pass'));
      expect(serialized['raw'], equals(report.raw));
      expect(serialized['proofBoundary'], equals(report.proofBoundary));
      expect(serialized['textureId'], equals(42));
      expect(serialized['surfaceProducerReleased'], isFalse);
      expect(serialized['width'], equals(128));
      expect(serialized['height'], equals(128));
      expect(serialized['lastError'], equals('none'));

      final roundTrip = VGMultiCamSpatialGlesRenderSmokeReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
    });

    test('fail report parses failure decision and lanes correctly', () {
      final report = VGMultiCamSpatialGlesRenderSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'decision': 'fail',
          'raw': 'status=FAIL;reason=readback_mismatch',
          'metrics': const <String, Object?>{
            'bufferADescribe': 'success',
            'bufferAFill': 'success',
            'bufferBDescribe': 'success',
            'bufferBFill': 'success',
            'preInitLane': 'rejected_as_expected',
            'initialize': 'success',
            'attach': 'success',
            'importBufferA': 'success',
            'importBufferB': 'success',
            'invalidHandleLane': 'rejected_as_expected',
            'invalidRectLane': 'rejected_as_expected',
            'topBottomSplitOk': false,
            'leftRightSplitOk': true,
            'pipTopLeftOk': true,
            'pipFreeFloatingOk': true,
            'sentinelClearOk': true,
            'presentComposite': 'success',
            'releaseBufferA': 'success',
            'releaseBufferB': 'success',
            'hasAAfterRelease': false,
            'hasBAfterRelease': false,
            'postReleaseLane': 'rejected_as_expected',
            'detach': 'success',
            'shutdown': 'success',
            'idempotentShutdown': 'success',
          },
          'lastError': 'readback_mismatch',
        }),
      );

      expect(report.pass, isFalse);
      expect(
        report.decision,
        equals(VGMultiCamSpatialGlesRenderSmokeDecision.fail),
      );
      expect(report.isPass, isFalse);
      expect(report.isFail, isTrue);
      expect(report.isHarnessException, isFalse);

      expect(report.topBottomSplitPass, isFalse);
      expect(report.leftRightSplitPass, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.lastError, equals('readback_mismatch'));
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGMultiCamSpatialGlesRenderSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(
          report.decision,
          equals(VGMultiCamSpatialGlesRenderSmokeDecision.harnessException),
        );
        expect(report.isHarnessException, isTrue);
        expect(report.proofBoundary, isEmpty);
        expect(
          report.metrics,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.lastError, equals('native_result_not_a_map'));
        expect(report.textureId, equals(-1));
        expect(report.surfaceProducerReleased, isFalse);
        expect(report.width, equals(0));
        expect(report.height, equals(0));
        expect(report.allNativeLanesPass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
      }
    });

    test(
      'fromMap handles missing metrics map and falls back to raw string key/value parsing',
      () {
        final reportFromRaw = VGMultiCamSpatialGlesRenderSmokeReport.fromMap({
          'pass': true,
          'raw':
              'status=PASS;'
              'bufferADescribe=success;'
              'bufferAFill=success;'
              'bufferBDescribe=success;'
              'bufferBFill=success;'
              'preInitLane=rejected_as_expected;'
              'initialize=success;'
              'attach=success;'
              'importBufferA=success;'
              'importBufferB=success;'
              'invalidHandleLane=rejected_as_expected;'
              'invalidRectLane=rejected_as_expected;'
              'topBottomSplitOk=true;'
              'leftRightSplitOk=true;'
              'pipTopLeftOk=true;'
              'pipFreeFloatingOk=true;'
              'sentinelClearOk=true;'
              'presentComposite=success;'
              'releaseBufferA=success;'
              'hasAAfterRelease=false;'
              'releaseBufferB=success;'
              'hasBAfterRelease=false;'
              'postReleaseLane=rejected_as_expected;'
              'detach=success;'
              'shutdown=success;'
              'idempotentShutdown=success;'
              'proofBoundary=$_kCanonicalProofBoundary',
          'proofBoundary': _kCanonicalProofBoundary,
        });

        expect(reportFromRaw.pass, isTrue);
        expect(reportFromRaw.bufferADescribePass, isTrue);
        expect(reportFromRaw.initializePass, isTrue);
        expect(reportFromRaw.topBottomSplitPass, isTrue);
        expect(reportFromRaw.pipTopLeftPass, isTrue);
        expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
        expect(reportFromRaw.allNativeLanesPass, isTrue);
      },
    );

    test('fromMap stringifies non-string metrics values', () {
      final report = VGMultiCamSpatialGlesRenderSmokeReport.fromMap({
        'pass': true,
        'decision': 'pass',
        'metrics': <Object?, Object?>{
          'bufferADescribe': 'success',
          'handleA': 12345,
          'topBottomSplitOk': true,
          'hasAAfterRelease': false,
          10: 20,
        },
      });

      expect(report.metrics['handleA'], equals('12345'));
      expect(report.metrics['topBottomSplitOk'], equals('true'));
      expect(report.metrics['hasAAfterRelease'], equals('false'));
      expect(report.metrics['10'], equals('20'));
    });
  });

  group(
    'VGMultiCamSpatialGlesRenderSmokeReport lane getters & proof boundary',
    () {
      test('proof boundary validation strictly checks canonical string', () {
        final reportValid = _createSampleReport();
        expect(reportValid.hasCanonicalProofBoundary, isTrue);

        final reportInvalid = _createSampleReport({
          'proofBoundary': 'wrong_proof_boundary_string',
        });
        expect(reportInvalid.hasCanonicalProofBoundary, isFalse);
      });

      test(
        'invalidHandleLane and invalidRectLane getters reflect expected status',
        () {
          final validReport = _createSampleReport();
          expect(validReport.invalidHandleLanePass, isTrue);
          expect(validReport.invalidRectLanePass, isTrue);

          final handleFailed = _createSampleReport({
            'metrics': {'invalidHandleLane': 'failed'},
          });
          expect(handleFailed.invalidHandleLanePass, isFalse);
          expect(handleFailed.allNativeLanesPass, isFalse);

          final rectFailed = _createSampleReport({
            'metrics': {'invalidRectLane': 'failed'},
          });
          expect(rectFailed.invalidRectLanePass, isFalse);
          expect(rectFailed.allNativeLanesPass, isFalse);
        },
      );

      test('all individual lane failures falsify allNativeLanesPass', () {
        final base = _createSampleRawMap();
        final baseMetrics = Map<String, Object?>.from(base['metrics'] as Map);

        final laneFailureMutations = <String, Object?>{
          'bufferADescribe': 'failed',
          'bufferAFill': 'failed',
          'bufferBDescribe': 'failed',
          'bufferBFill': 'failed',
          'preInitLane': 'failed',
          'initialize': 'failed',
          'attach': 'failed',
          'importBufferA': 'failed',
          'importBufferB': 'failed',
          'invalidHandleLane': 'failed',
          'invalidRectLane': 'failed',
          'topBottomSplitOk': false,
          'leftRightSplitOk': false,
          'pipTopLeftOk': false,
          'pipFreeFloatingOk': false,
          'sentinelClearOk': false,
          'presentComposite': 'failed',
          'releaseBufferA': 'failed',
          'releaseBufferB': 'failed',
          'hasAAfterRelease': true,
          'hasBAfterRelease': true,
          'postReleaseLane': 'failed',
          'detach': 'failed',
          'shutdown': 'failed',
          'idempotentShutdown': 'failed',
        };

        for (final entry in laneFailureMutations.entries) {
          final modifiedMetrics = Map<String, Object?>.from(baseMetrics);
          modifiedMetrics[entry.key] = entry.value;
          final report = VGMultiCamSpatialGlesRenderSmokeReport.fromMap({
            ...base,
            'metrics': modifiedMetrics,
          });
          expect(
            report.allNativeLanesPass,
            isFalse,
            reason:
                'Failed lane ${entry.key} must cause allNativeLanesPass to be false',
          );
        }
      });
    },
  );

  group('VGMultiCamSpatialGlesRenderSmokeReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGMultiCamSpatialGlesRenderSmokeReport('));
      expect(a.toString(), contains('pass: true'));
      expect(
        a.toString(),
        contains('decision: VGMultiCamSpatialGlesRenderSmokeDecision.pass'),
      );
      expect(a.toString(), contains('textureId: 42'));
      expect(
        a.toString(),
        contains('proofBoundary: $_kCanonicalProofBoundary'),
      );
    });

    test(
      'stable metrics hash produces equal hash and equality with different map key order',
      () {
        final report1 = _createSampleReport({
          'metrics': const {'alpha': '1', 'beta': '2', 'gamma': '3'},
        });
        final report2 = _createSampleReport({
          'metrics': const {'gamma': '3', 'alpha': '1', 'beta': '2'},
        });

        expect(report1, equals(report2));
        expect(report1.hashCode, equals(report2.hashCode));
      },
    );

    test('inequality when any single field differs', () {
      final base = _createSampleReport();
      final diffs = <Map<String, Object?>>[
        {'pass': false},
        {'decision': 'fail'},
        {'raw': 'status=FAIL'},
        {'proofBoundary': 'other_boundary'},
        {'textureId': 99},
        {'surfaceProducerReleased': true},
        {'width': 256},
        {'height': 256},
        {'lastError': 'some_error'},
        {
          'metrics': <String, String>{'initialize': 'failed'},
        },
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('start & dispose MethodChannel wrappers', () {
    test('start invokes with default width and height 128', () async {
      MethodCall? capturedCall;
      const channel = MethodChannel('test_spatial_smoke_channel');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        return <String, Object?>{
          'started': true,
          'textureId': 77,
          'width': 128,
          'height': 128,
        };
      });

      final startResult =
          await VGMultiCamSpatialGlesRenderSmokeReport.startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke(
            channel: channel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke'),
      );
      expect(capturedCall!.arguments, equals({'width': 128, 'height': 128}));
      expect(startResult.textureId, equals(77));
      expect(startResult.width, equals(128));
      expect(startResult.height, equals(128));
    });

    test(
      'start invokes with custom width and height and uses default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return <String, Object?>{
            'started': true,
            'textureId': 88,
            'width': 256,
            'height': 512,
          };
        });

        final startResult =
            await VGMultiCamSpatialGlesRenderSmokeReport.startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke(
              width: 256,
              height: 512,
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke'),
        );
        expect(capturedCall!.arguments, equals({'width': 256, 'height': 512}));
        expect(startResult.textureId, equals(88));
        expect(startResult.width, equals(256));
        expect(startResult.height, equals(512));
      },
    );

    test('start handles defensive non-map response', () async {
      const channel = MethodChannel('test_spatial_smoke_non_map');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return 'unexpected_non_map';
      });

      final startResult =
          await VGMultiCamSpatialGlesRenderSmokeReport.startAndroidDagPhase3MultiCamSpatialGlesRenderSmoke(
            channel: channel,
          );

      expect(startResult.textureId, equals(-1));
      expect(startResult.width, equals(128));
      expect(startResult.height, equals(128));
    });

    test('dispose invokes with textureId and returns release status', () async {
      MethodCall? capturedCall;
      const channel = MethodChannel('test_spatial_smoke_dispose');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        return <String, Object?>{
          'pass': true,
          'textureId': 77,
          'surfaceProducerReleased': true,
          'raw': 'status=OK;disposed=true',
        };
      });

      final released =
          await VGMultiCamSpatialGlesRenderSmokeReport.disposeAndroidDagPhase3MultiCamSpatialGlesRenderSmoke(
            textureId: 77,
            channel: channel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('disposeAndroidDagPhase3MultiCamSpatialGlesRenderSmoke'),
      );
      expect(capturedCall!.arguments, equals({'textureId': 77}));
      expect(released, isTrue);
    });

    test('dispose handles defensive non-map response', () async {
      const channel = MethodChannel('test_spatial_smoke_dispose_non_map');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return null;
      });

      final released =
          await VGMultiCamSpatialGlesRenderSmokeReport.disposeAndroidDagPhase3MultiCamSpatialGlesRenderSmoke(
            textureId: 77,
            channel: channel,
          );

      expect(released, isFalse);
    });
  });
}
