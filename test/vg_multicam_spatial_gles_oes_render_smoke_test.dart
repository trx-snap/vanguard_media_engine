// vg_multicam_spatial_gles_oes_render_smoke_test.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-GLES-OES-SPATIAL-RENDER: Android
// True-DAG Phase 3 GLES-first spatial multi-texture diagnostic render pass
// OES smoke Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_multicam_spatial_gles_oes_texture_layout_render_readback_only_no_vulkan_no_camera_no_opacity_no_corner_radius_no_recording_no_product';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'pass': true,
  'decision': 'pass',
  'raw':
      'status=PASS;'
      'width=128;'
      'height=128;'
      'clientVersion=3;'
      'vendor=ARM;'
      'renderer=Mali-G78;'
      'version=OpenGL ES 3.2;'
      'rgbaADescribe=success;'
      'rgbaAFill=success;'
      'rgbaBDescribe=success;'
      'rgbaBFill=success;'
      'ycbcrADescribe=success;'
      'ycbcrAFormatIs420888=true;'
      'ycbcrBDescribe=success;'
      'ycbcrBFormatIs420888=true;'
      'preInitLane=rejected_as_expected;'
      'preInitLastError=backend_not_initialized;'
      'initialize=success;'
      'attach=success;'
      'importRgbaA=success;'
      'handleRgbaA=1001;'
      'targetRgbaA=3553;'
      'importRgbaB=success;'
      'handleRgbaB=1002;'
      'targetRgbaB=3553;'
      'importYcbcrA=success;'
      'handleYcbcrA=1003;'
      'targetYcbcrA=36197;'
      'importYcbcrB=success;'
      'handleYcbcrB=1004;'
      'targetYcbcrB=36197;'
      'invalidHandleLane=rejected_as_expected;'
      'invalidHandleLastError=invalid_buffer_handle;'
      'invalidRectLane=rejected_as_expected;'
      'invalidRectLastError=gles_multicam_spatial_compositor_invalid_rect;'
      'twoDOesOk=true;'
      'twoDOesTargetOk=true;'
      'twoDOesLastError=none;'
      'oesTwoDOk=true;'
      'oesTwoDTargetOk=true;'
      'oesTwoDLastError=none;'
      'oesOesOk=true;'
      'oesOesTargetOk=true;'
      'oesOesLastError=none;'
      'presentOesOes=success;'
      'presentOesOesLastError=none;'
      'releaseRgbaA=success;'
      'releaseRgbaAFence=-1;'
      'hasRgbaAAfterRelease=false;'
      'releaseRgbaB=success;'
      'releaseRgbaBFence=-1;'
      'hasRgbaBAfterRelease=false;'
      'releaseYcbcrA=success;'
      'releaseYcbcrAFence=-1;'
      'hasYcbcrAAfterRelease=false;'
      'releaseYcbcrB=success;'
      'releaseYcbcrBFence=-1;'
      'hasYcbcrBAfterRelease=false;'
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
    'rgbaADescribe': 'success',
    'rgbaAFill': 'success',
    'rgbaBDescribe': 'success',
    'rgbaBFill': 'success',
    'ycbcrADescribe': 'success',
    'ycbcrAFormatIs420888': true,
    'ycbcrBDescribe': 'success',
    'ycbcrBFormatIs420888': true,
    'preInitLane': 'rejected_as_expected',
    'preInitLastError': 'backend_not_initialized',
    'initialize': 'success',
    'attach': 'success',
    'importRgbaA': 'success',
    'handleRgbaA': 1001,
    'targetRgbaA': 3553,
    'importRgbaB': 'success',
    'handleRgbaB': 1002,
    'targetRgbaB': 3553,
    'importYcbcrA': 'success',
    'handleYcbcrA': 1003,
    'targetYcbcrA': 36197,
    'importYcbcrB': 'success',
    'handleYcbcrB': 1004,
    'targetYcbcrB': 36197,
    'invalidHandleLane': 'rejected_as_expected',
    'invalidHandleLastError': 'invalid_buffer_handle',
    'invalidRectLane': 'rejected_as_expected',
    'invalidRectLastError': 'gles_multicam_spatial_compositor_invalid_rect',
    'twoDOesOk': true,
    'twoDOesTargetOk': true,
    'twoDOesLastError': 'none',
    'oesTwoDOk': true,
    'oesTwoDTargetOk': true,
    'oesTwoDLastError': 'none',
    'oesOesOk': true,
    'oesOesTargetOk': true,
    'oesOesLastError': 'none',
    'presentOesOes': 'success',
    'presentOesOesLastError': 'none',
    'releaseRgbaA': 'success',
    'releaseRgbaAFence': -1,
    'hasRgbaAAfterRelease': false,
    'releaseRgbaB': 'success',
    'releaseRgbaBFence': -1,
    'hasRgbaBAfterRelease': false,
    'releaseYcbcrA': 'success',
    'releaseYcbcrAFence': -1,
    'hasYcbcrAAfterRelease': false,
    'releaseYcbcrB': 'success',
    'releaseYcbcrBFence': -1,
    'hasYcbcrBAfterRelease': false,
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

VGMultiCamSpatialGlesOesRenderSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGMultiCamSpatialGlesOesRenderSmokeReport.fromMap(
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

  group('VGMultiCamSpatialGlesOesRenderSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 3 values in order', () {
      expect(
        VGMultiCamSpatialGlesOesRenderSmokeDecision.values,
        orderedEquals(const [
          VGMultiCamSpatialGlesOesRenderSmokeDecision.pass,
          VGMultiCamSpatialGlesOesRenderSmokeDecision.fail,
          VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException,
        ]),
      );
      expect(
        VGMultiCamSpatialGlesOesRenderSmokeDecision.values.length,
        equals(3),
      );
    });

    test('fromRaw maps all known valid decision strings', () {
      expect(
        VGMultiCamSpatialGlesOesRenderSmokeDecision.fromRaw('pass'),
        equals(VGMultiCamSpatialGlesOesRenderSmokeDecision.pass),
      );
      expect(
        VGMultiCamSpatialGlesOesRenderSmokeDecision.fromRaw('PASS'),
        equals(VGMultiCamSpatialGlesOesRenderSmokeDecision.pass),
      );
      expect(
        VGMultiCamSpatialGlesOesRenderSmokeDecision.fromRaw('fail'),
        equals(VGMultiCamSpatialGlesOesRenderSmokeDecision.fail),
      );
      expect(
        VGMultiCamSpatialGlesOesRenderSmokeDecision.fromRaw('FAIL'),
        equals(VGMultiCamSpatialGlesOesRenderSmokeDecision.fail),
      );
      expect(
        VGMultiCamSpatialGlesOesRenderSmokeDecision.fromRaw('harnessException'),
        equals(VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException),
      );
      expect(
        VGMultiCamSpatialGlesOesRenderSmokeDecision.fromRaw(
          'harness_exception',
        ),
        equals(VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException),
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
            VGMultiCamSpatialGlesOesRenderSmokeDecision.fromRaw(invalid),
            equals(
              VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException,
            ),
          );
        }
      },
    );
  });

  group('VGMultiCamSpatialGlesOesRenderSmokeReport fromMap and toMap', () {
    test('pass report parses and round-trips all fields cleanly', () {
      final report = VGMultiCamSpatialGlesOesRenderSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(report.pass, isTrue);
      expect(
        report.decision,
        equals(VGMultiCamSpatialGlesOesRenderSmokeDecision.pass),
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
      expect(report.rgbaADescribePass, isTrue);
      expect(report.rgbaAFillPass, isTrue);
      expect(report.rgbaBDescribePass, isTrue);
      expect(report.rgbaBFillPass, isTrue);
      expect(report.ycbcrADescribePass, isTrue);
      expect(report.ycbcrAFormatIs420888, isTrue);
      expect(report.ycbcrBDescribePass, isTrue);
      expect(report.ycbcrBFormatIs420888, isTrue);
      expect(report.preInitLanePass, isTrue);
      expect(report.initializePass, isTrue);
      expect(report.attachPass, isTrue);
      expect(report.importRgbaAPass, isTrue);
      expect(report.importRgbaBPass, isTrue);
      expect(report.importYcbcrAPass, isTrue);
      expect(report.importYcbcrBPass, isTrue);

      // Validation / rejection lanes
      expect(report.invalidHandleLanePass, isTrue);
      expect(report.invalidRectLanePass, isTrue);

      // OES spatial composite render lanes
      expect(report.twoDOesPass, isTrue);
      expect(report.oesTwoDPass, isTrue);
      expect(report.oesOesPass, isTrue);
      expect(report.presentOesOesPass, isTrue);

      // Release / teardown lanes
      expect(report.releaseRgbaAPass, isTrue);
      expect(report.releaseRgbaBPass, isTrue);
      expect(report.releaseYcbcrAPass, isTrue);
      expect(report.releaseYcbcrBPass, isTrue);
      expect(report.hasRgbaAAfterReleasePass, isTrue);
      expect(report.hasRgbaBAfterReleasePass, isTrue);
      expect(report.hasYcbcrAAfterReleasePass, isTrue);
      expect(report.hasYcbcrBAfterReleasePass, isTrue);
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

      final roundTrip = VGMultiCamSpatialGlesOesRenderSmokeReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
    });

    test('fail report parses failure decision and lanes correctly', () {
      final report = VGMultiCamSpatialGlesOesRenderSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'decision': 'fail',
          'raw': 'status=FAIL;reason=readback_mismatch',
          'metrics': const <String, Object?>{
            'rgbaADescribe': 'success',
            'rgbaAFill': 'success',
            'rgbaBDescribe': 'success',
            'rgbaBFill': 'success',
            'ycbcrADescribe': 'success',
            'ycbcrAFormatIs420888': true,
            'ycbcrBDescribe': 'success',
            'ycbcrBFormatIs420888': true,
            'preInitLane': 'rejected_as_expected',
            'initialize': 'success',
            'attach': 'success',
            'importRgbaA': 'success',
            'importRgbaB': 'success',
            'importYcbcrA': 'success',
            'importYcbcrB': 'success',
            'invalidHandleLane': 'rejected_as_expected',
            'invalidRectLane': 'rejected_as_expected',
            'twoDOesOk': false,
            'twoDOesTargetOk': true,
            'oesTwoDOk': true,
            'oesTwoDTargetOk': true,
            'oesOesOk': true,
            'oesOesTargetOk': true,
            'presentOesOes': 'success',
            'releaseRgbaA': 'success',
            'releaseRgbaB': 'success',
            'releaseYcbcrA': 'success',
            'releaseYcbcrB': 'success',
            'hasRgbaAAfterRelease': false,
            'hasRgbaBAfterRelease': false,
            'hasYcbcrAAfterRelease': false,
            'hasYcbcrBAfterRelease': false,
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
        equals(VGMultiCamSpatialGlesOesRenderSmokeDecision.fail),
      );
      expect(report.isPass, isFalse);
      expect(report.isFail, isTrue);
      expect(report.isHarnessException, isFalse);

      expect(report.twoDOesPass, isFalse);
      expect(report.oesTwoDPass, isTrue);
      expect(report.oesOesPass, isTrue);
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
        final report = VGMultiCamSpatialGlesOesRenderSmokeReport.fromMap(
          invalid,
        );
        expect(report.pass, isFalse);
        expect(
          report.decision,
          equals(VGMultiCamSpatialGlesOesRenderSmokeDecision.harnessException),
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
        final reportFromRaw =
            VGMultiCamSpatialGlesOesRenderSmokeReport.fromMap({
              'pass': true,
              'raw':
                  'status=PASS;'
                  'rgbaADescribe=success;'
                  'rgbaAFill=success;'
                  'rgbaBDescribe=success;'
                  'rgbaBFill=success;'
                  'ycbcrADescribe=success;'
                  'ycbcrAFormatIs420888=true;'
                  'ycbcrBDescribe=success;'
                  'ycbcrBFormatIs420888=true;'
                  'preInitLane=rejected_as_expected;'
                  'initialize=success;'
                  'attach=success;'
                  'importRgbaA=success;'
                  'importRgbaB=success;'
                  'importYcbcrA=success;'
                  'importYcbcrB=success;'
                  'invalidHandleLane=rejected_as_expected;'
                  'invalidRectLane=rejected_as_expected;'
                  'twoDOesOk=true;'
                  'twoDOesTargetOk=true;'
                  'oesTwoDOk=true;'
                  'oesTwoDTargetOk=true;'
                  'oesOesOk=true;'
                  'oesOesTargetOk=true;'
                  'presentOesOes=success;'
                  'releaseRgbaA=success;'
                  'hasRgbaAAfterRelease=false;'
                  'releaseRgbaB=success;'
                  'hasRgbaBAfterRelease=false;'
                  'releaseYcbcrA=success;'
                  'hasYcbcrAAfterRelease=false;'
                  'releaseYcbcrB=success;'
                  'hasYcbcrBAfterRelease=false;'
                  'postReleaseLane=rejected_as_expected;'
                  'detach=success;'
                  'shutdown=success;'
                  'idempotentShutdown=success;'
                  'proofBoundary=$_kCanonicalProofBoundary',
              'proofBoundary': _kCanonicalProofBoundary,
            });

        expect(reportFromRaw.pass, isTrue);
        expect(reportFromRaw.rgbaADescribePass, isTrue);
        expect(reportFromRaw.initializePass, isTrue);
        expect(reportFromRaw.twoDOesPass, isTrue);
        expect(reportFromRaw.oesOesPass, isTrue);
        expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);
        expect(reportFromRaw.allNativeLanesPass, isTrue);
      },
    );

    test('fromMap stringifies non-string metrics values', () {
      final report = VGMultiCamSpatialGlesOesRenderSmokeReport.fromMap({
        'pass': true,
        'decision': 'pass',
        'metrics': <Object?, Object?>{
          'rgbaADescribe': 'success',
          'handleYcbcrA': 12345,
          'twoDOesOk': true,
          'hasRgbaAAfterRelease': false,
          10: 20,
        },
      });

      expect(report.metrics['handleYcbcrA'], equals('12345'));
      expect(report.metrics['twoDOesOk'], equals('true'));
      expect(report.metrics['hasRgbaAAfterRelease'], equals('false'));
      expect(report.metrics['10'], equals('20'));
    });
  });

  group(
    'VGMultiCamSpatialGlesOesRenderSmokeReport lane getters & proof boundary',
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

      test('OES lane getters require both the ok and targetOk sub-flags', () {
        final targetFailed = _createSampleReport({
          'metrics': {'twoDOesOk': true, 'twoDOesTargetOk': false},
        });
        expect(targetFailed.twoDOesPass, isFalse);
        expect(targetFailed.allNativeLanesPass, isFalse);

        final okFailed = _createSampleReport({
          'metrics': {'oesTwoDOk': false, 'oesTwoDTargetOk': true},
        });
        expect(okFailed.oesTwoDPass, isFalse);
        expect(okFailed.allNativeLanesPass, isFalse);
      });

      test('all individual lane failures falsify allNativeLanesPass', () {
        final base = _createSampleRawMap();
        final baseMetrics = Map<String, Object?>.from(base['metrics'] as Map);

        final laneFailureMutations = <String, Object?>{
          'rgbaADescribe': 'failed',
          'rgbaAFill': 'failed',
          'rgbaBDescribe': 'failed',
          'rgbaBFill': 'failed',
          'ycbcrADescribe': 'failed',
          'ycbcrAFormatIs420888': false,
          'ycbcrBDescribe': 'failed',
          'ycbcrBFormatIs420888': false,
          'preInitLane': 'failed',
          'initialize': 'failed',
          'attach': 'failed',
          'importRgbaA': 'failed',
          'importRgbaB': 'failed',
          'importYcbcrA': 'failed',
          'importYcbcrB': 'failed',
          'invalidHandleLane': 'failed',
          'invalidRectLane': 'failed',
          'twoDOesOk': false,
          'oesTwoDOk': false,
          'oesOesOk': false,
          'presentOesOes': 'failed',
          'releaseRgbaA': 'failed',
          'releaseRgbaB': 'failed',
          'releaseYcbcrA': 'failed',
          'releaseYcbcrB': 'failed',
          'hasRgbaAAfterRelease': true,
          'hasRgbaBAfterRelease': true,
          'hasYcbcrAAfterRelease': true,
          'hasYcbcrBAfterRelease': true,
          'postReleaseLane': 'failed',
          'detach': 'failed',
          'shutdown': 'failed',
          'idempotentShutdown': 'failed',
        };

        for (final entry in laneFailureMutations.entries) {
          final modifiedMetrics = Map<String, Object?>.from(baseMetrics);
          modifiedMetrics[entry.key] = entry.value;
          final report = VGMultiCamSpatialGlesOesRenderSmokeReport.fromMap({
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

  group('VGMultiCamSpatialGlesOesRenderSmokeReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a.toString(),
        contains('VGMultiCamSpatialGlesOesRenderSmokeReport('),
      );
      expect(a.toString(), contains('pass: true'));
      expect(
        a.toString(),
        contains('decision: VGMultiCamSpatialGlesOesRenderSmokeDecision.pass'),
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
      const channel = MethodChannel('test_spatial_oes_smoke_channel');
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
          await VGMultiCamSpatialGlesOesRenderSmokeReport.startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke(
            channel: channel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke'),
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
            await VGMultiCamSpatialGlesOesRenderSmokeReport.startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke(
              width: 256,
              height: 512,
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke'),
        );
        expect(capturedCall!.arguments, equals({'width': 256, 'height': 512}));
        expect(startResult.textureId, equals(88));
        expect(startResult.width, equals(256));
        expect(startResult.height, equals(512));
      },
    );

    test('start handles defensive non-map response', () async {
      const channel = MethodChannel('test_spatial_oes_smoke_non_map');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return 'unexpected_non_map';
      });

      final startResult =
          await VGMultiCamSpatialGlesOesRenderSmokeReport.startAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke(
            channel: channel,
          );

      expect(startResult.textureId, equals(-1));
      expect(startResult.width, equals(128));
      expect(startResult.height, equals(128));
    });

    test('dispose invokes with textureId and returns release status', () async {
      MethodCall? capturedCall;
      const channel = MethodChannel('test_spatial_oes_smoke_dispose');
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
          await VGMultiCamSpatialGlesOesRenderSmokeReport.disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke(
            textureId: 77,
            channel: channel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke'),
      );
      expect(capturedCall!.arguments, equals({'textureId': 77}));
      expect(released, isTrue);
    });

    test('dispose handles defensive non-map response', () async {
      const channel = MethodChannel('test_spatial_oes_smoke_dispose_non_map');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return null;
      });

      final released =
          await VGMultiCamSpatialGlesOesRenderSmokeReport.disposeAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke(
            textureId: 77,
            channel: channel,
          );

      expect(released, isFalse);
    });
  });
}
