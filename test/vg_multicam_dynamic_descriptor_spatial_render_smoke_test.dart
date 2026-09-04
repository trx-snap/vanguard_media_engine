// vg_multicam_dynamic_descriptor_spatial_render_smoke_test.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER:
// Android True-DAG Phase 3 dynamic-descriptor spatial render smoke Dart
// model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'native_multicam_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_vulkan_no_camera_no_opacity_no_corner_radius_no_ycbcr_color_claim_no_recording_no_product';

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
      'descriptorParse=success;'
      'descriptorParseLastError=;'
      'layoutModeResolved=pip;'
      'anchorResolved=freeFloating;'
      'directionResolved=topBottom;'
      'layoutConvert=success;'
      'layoutConvertLastError=none;'
      'primaryRectX=0;'
      'primaryRectY=0;'
      'primaryRectW=128;'
      'primaryRectH=128;'
      'secondaryRectX=64;'
      'secondaryRectY=16;'
      'secondaryRectW=38;'
      'secondaryRectH=21;'
      'renderLaneMode=pip;'
      'primaryTextureKind=rgba;'
      'secondaryTextureKind=oes;'
      'renderDraw=success;'
      'renderDrawLastError=none;'
      'primaryTargetOk=true;'
      'secondaryTargetOk=true;'
      'primarySampleReadOk=true;'
      'secondarySampleReadOk=true;'
      'deterministicColorSide=primary;'
      'deterministicColorOk=true;'
      'presentLane=success;'
      'presentLaneLastError=none;'
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
    'descriptorParse': 'success',
    'descriptorParseLastError': '',
    'layoutModeResolved': 'pip',
    'anchorResolved': 'freeFloating',
    'directionResolved': 'topBottom',
    'layoutConvert': 'success',
    'layoutConvertLastError': 'none',
    'primaryRectX': 0,
    'primaryRectY': 0,
    'primaryRectW': 128,
    'primaryRectH': 128,
    'secondaryRectX': 64,
    'secondaryRectY': 16,
    'secondaryRectW': 38,
    'secondaryRectH': 21,
    'renderLaneMode': 'pip',
    'primaryTextureKind': 'rgba',
    'secondaryTextureKind': 'oes',
    'renderDraw': 'success',
    'renderDrawLastError': 'none',
    'primaryTargetOk': true,
    'secondaryTargetOk': true,
    'primarySampleReadOk': true,
    'secondarySampleReadOk': true,
    'deterministicColorSide': 'primary',
    'deterministicColorOk': true,
    'presentLane': 'success',
    'presentLaneLastError': 'none',
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

VGMultiCamDynamicDescriptorSpatialRenderSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.fromMap(
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

  group('VGMultiCamDynamicDescriptorSpatialRenderInput', () {
    test(
      'freeFloatingPip factory serializes exact expected map shape and never includes cornerRadius/opacity',
      () {
        final input =
            VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip();
        final map = input.toMap();

        expect(map['layoutMode'], equals('pip'));
        expect(map['pipAnchor'], equals('freeFloating'));
        expect(map['pipCenterX'], equals(0.7));
        expect(map['pipCenterY'], equals(0.3));
        expect(map['pipWidthFraction'], equals(0.3));
        expect(map['pipAspectRatio'], equals(9.0 / 16.0));
        expect(map['pipMarginFraction'], equals(0.05));
        expect(map['splitDirection'], equals('topBottom'));
        expect(map['splitRatio'], equals(0.5));
        expect(map.containsKey('cornerRadius'), isFalse);
        expect(map.containsKey('opacity'), isFalse);
        expect(
          map.keys.toSet(),
          equals(const {
            'layoutMode',
            'pipAnchor',
            'pipCenterX',
            'pipCenterY',
            'pipWidthFraction',
            'pipAspectRatio',
            'pipMarginFraction',
            'splitDirection',
            'splitRatio',
          }),
        );
      },
    );

    test('leftRightSplit factory serializes exact expected map shape', () {
      final input =
          VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit();
      final map = input.toMap();

      expect(map['layoutMode'], equals('splitScreen'));
      expect(map['splitDirection'], equals('leftRight'));
      expect(map['splitRatio'], equals(0.4));
      expect(map.containsKey('cornerRadius'), isFalse);
      expect(map.containsKey('opacity'), isFalse);
    });

    test('custom constructor honors every field', () {
      const input = VGMultiCamDynamicDescriptorSpatialRenderInput(
        layoutMode: VGDualCameraLayoutMode.splitScreen,
        pipAnchor: VGPiPAnchor.topLeft,
        pipCenterX: 0.1,
        pipCenterY: 0.9,
        pipWidthFraction: 0.25,
        pipAspectRatio: 1.5,
        pipMarginFraction: 0.02,
        splitDirection: VGSplitScreenDirection.leftRight,
        splitRatio: 0.6,
      );
      final map = input.toMap();
      expect(map['pipAnchor'], equals('topLeft'));
      expect(map['pipCenterX'], equals(0.1));
      expect(map['pipCenterY'], equals(0.9));
      expect(map['pipWidthFraction'], equals(0.25));
      expect(map['pipAspectRatio'], equals(1.5));
      expect(map['pipMarginFraction'], equals(0.02));
      expect(map['splitRatio'], equals(0.6));
    });
  });

  group(
    'VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision enum & fromRaw',
    () {
      test('enum has exact expected 3 values in order', () {
        expect(
          VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.values,
          orderedEquals(const [
            VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.pass,
            VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fail,
            VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision
                .harnessException,
          ]),
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.values.length,
          equals(3),
        );
      });

      test('fromRaw maps all known valid decision strings', () {
        expect(
          VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fromRaw('pass'),
          equals(VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.pass),
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fromRaw('PASS'),
          equals(VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.pass),
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fromRaw('fail'),
          equals(VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fail),
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fromRaw(
            'harnessException',
          ),
          equals(
            VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision
                .harnessException,
          ),
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fromRaw(
            'harness_exception',
          ),
          equals(
            VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision
                .harnessException,
          ),
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
              VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fromRaw(
                invalid,
              ),
              equals(
                VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision
                    .harnessException,
              ),
            );
          }
        },
      );
    },
  );

  group('VGMultiCamDynamicDescriptorSpatialRenderSmokeReport fromMap and toMap', () {
    test(
      'pass report (freeFloating PiP lane) parses and round-trips all fields cleanly',
      () {
        final report =
            VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.fromMap(
              _createSampleRawMap(),
            );

        expect(report.pass, isTrue);
        expect(
          report.decision,
          equals(VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.pass),
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
        expect(report.initializePass, isTrue);
        expect(report.attachPass, isTrue);
        expect(report.importRgbaAPass, isTrue);
        expect(report.importRgbaBPass, isTrue);
        expect(report.importYcbcrAPass, isTrue);
        expect(report.importYcbcrBPass, isTrue);

        // Descriptor parse / layout conversion lanes
        expect(report.descriptorParsePass, isTrue);
        expect(report.layoutModeResolved, equals('pip'));
        expect(report.anchorResolved, equals('freeFloating'));
        expect(report.directionResolved, equals('topBottom'));
        expect(report.layoutConvertPass, isTrue);
        expect(report.primaryRectX, equals(0));
        expect(report.primaryRectY, equals(0));
        expect(report.primaryRectWidth, equals(128));
        expect(report.primaryRectHeight, equals(128));
        expect(report.secondaryRectX, equals(64));
        expect(report.secondaryRectY, equals(16));
        expect(report.secondaryRectWidth, equals(38));
        expect(report.secondaryRectHeight, equals(21));

        // Render / readback lanes
        expect(report.renderLaneMode, equals('pip'));
        expect(report.primaryTextureKind, equals('rgba'));
        expect(report.secondaryTextureKind, equals('oes'));
        expect(report.renderDrawPass, isTrue);
        expect(report.primaryTargetOkPass, isTrue);
        expect(report.secondaryTargetOkPass, isTrue);
        expect(report.primarySampleReadOkPass, isTrue);
        expect(report.secondarySampleReadOkPass, isTrue);
        expect(report.deterministicColorSide, equals('primary'));
        expect(report.deterministicColorOkPass, isTrue);
        expect(report.presentLanePass, isTrue);

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

        final roundTrip =
            VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.fromMap(
              serialized,
            );
        expect(roundTrip, equals(report));
      },
    );

    test(
      'leftRight split lane report parses OES-primary/RGBA-secondary render lane fields',
      () {
        final report =
            VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.fromMap(
              _createSampleRawMap({
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
                  'descriptorParse': 'success',
                  'descriptorParseLastError': '',
                  'layoutModeResolved': 'splitScreen',
                  'anchorResolved': 'freeFloating',
                  'directionResolved': 'leftRight',
                  'layoutConvert': 'success',
                  'layoutConvertLastError': 'none',
                  'primaryRectX': 0,
                  'primaryRectY': 0,
                  'primaryRectW': 51,
                  'primaryRectH': 128,
                  'secondaryRectX': 51,
                  'secondaryRectY': 0,
                  'secondaryRectW': 77,
                  'secondaryRectH': 128,
                  'renderLaneMode': 'splitScreen',
                  'primaryTextureKind': 'oes',
                  'secondaryTextureKind': 'rgba',
                  'renderDraw': 'success',
                  'renderDrawLastError': 'none',
                  'primaryTargetOk': true,
                  'secondaryTargetOk': true,
                  'primarySampleReadOk': true,
                  'secondarySampleReadOk': true,
                  'deterministicColorSide': 'secondary',
                  'deterministicColorOk': true,
                  'presentLane': 'success',
                  'presentLaneLastError': 'none',
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
              }),
            );

        expect(report.renderLaneMode, equals('splitScreen'));
        expect(report.primaryTextureKind, equals('oes'));
        expect(report.secondaryTextureKind, equals('rgba'));
        expect(report.deterministicColorSide, equals('secondary'));
        expect(report.deterministicColorOkPass, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test(
      'malformed/unknown descriptor fail report parses fail-closed lane correctly',
      () {
        final report = VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.fromMap(
          _createSampleRawMap({
            'pass': false,
            'decision': 'fail',
            'raw':
                'status=FAIL;descriptorParse=failed;lastError=unknown_layout_mode',
            'metrics': const <String, Object?>{
              'descriptorParse': 'failed',
              'descriptorParseLastError': 'unknown_layout_mode',
              'layoutModeResolved': '',
              'anchorResolved': '',
              'directionResolved': '',
              'layoutConvert': 'not_run',
              'renderDraw': 'not_run',
            },
            'lastError': 'unknown_layout_mode',
          }),
        );

        expect(report.pass, isFalse);
        expect(
          report.decision,
          equals(VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision.fail),
        );
        expect(report.isFail, isTrue);
        expect(report.descriptorParsePass, isFalse);
        expect(report.layoutConvertPass, isFalse);
        expect(report.renderDrawPass, isFalse);
        expect(report.lastError, equals('unknown_layout_mode'));
        expect(report.allNativeLanesPass, isFalse);
      },
    );

    test('defensive fromMap handles non-map input', () {
      final report =
          VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.fromMap(
            'not_a_map',
          );
      expect(report.pass, isFalse);
      expect(
        report.decision,
        equals(
          VGMultiCamDynamicDescriptorSpatialRenderSmokeDecision
              .harnessException,
        ),
      );
      expect(report.lastError, equals('native_result_not_a_map'));
      expect(report.textureId, equals(-1));
    });
  });

  group(
    'VGMultiCamDynamicDescriptorSpatialRenderSmokeReport value semantics',
    () {
      test('equal reports compare equal and share hashCode', () {
        final a = _createSampleReport();
        final b = _createSampleReport();
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('differing fields produce unequal reports', () {
        final base = _createSampleReport();
        final diffs = <Map<String, Object?>>[
          {'pass': false, 'decision': 'fail'},
          {'textureId': 99},
          {'surfaceProducerReleased': true},
          {'width': 256},
          {'height': 256},
          {'lastError': 'something_else'},
          {'proofBoundary': 'different_boundary'},
        ];
        for (final diff in diffs) {
          final variant = _createSampleReport(diff);
          expect(base, isNot(equals(variant)));
          expect(base.hashCode, isNot(equals(variant.hashCode)));
        }
      });
    },
  );

  group('start & dispose MethodChannel wrappers', () {
    test(
      'start invokes with descriptor map and default width/height 128',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_dynamic_descriptor_spatial_smoke_channel',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return <String, Object?>{
            'started': true,
            'textureId': 77,
            'width': 128,
            'height': 128,
          };
        });

        final descriptor =
            VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip()
                .toMap();
        final startResult =
            await VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
              descriptor: descriptor,
              channel: channel,
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals(
            'startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke',
          ),
        );
        expect(
          capturedCall!.arguments,
          equals({'width': 128, 'height': 128, 'descriptor': descriptor}),
        );
        expect(startResult.textureId, equals(77));
        expect(startResult.width, equals(128));
        expect(startResult.height, equals(128));
      },
    );

    test(
      'start invokes with custom width/height and uses default channel',
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

        final descriptor =
            VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit()
                .toMap();
        final startResult =
            await VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
              descriptor: descriptor,
              width: 256,
              height: 512,
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals(
            'startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke',
          ),
        );
        expect(
          capturedCall!.arguments,
          equals({'width': 256, 'height': 512, 'descriptor': descriptor}),
        );
        expect(startResult.textureId, equals(88));
        expect(startResult.width, equals(256));
        expect(startResult.height, equals(512));
      },
    );

    test(
      'start allows a deliberately malformed/unknown descriptor map through the wrapper',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_dynamic_descriptor_spatial_smoke_malformed',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return <String, Object?>{
            'started': true,
            'textureId': 5,
            'width': 128,
            'height': 128,
          };
        });

        const malformedDescriptor = <String, Object?>{
          'layoutMode': 'notARealMode',
          'pipAnchor': 'freeFloating',
          'pipCenterX': 0.5,
          'pipCenterY': 0.5,
          'pipWidthFraction': 0.3,
          'pipAspectRatio': 1.0,
          'pipMarginFraction': 0.05,
          'splitDirection': 'topBottom',
          'splitRatio': 0.5,
        };

        await VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
          descriptor: malformedDescriptor,
          channel: channel,
        );

        expect(capturedCall, isNotNull);
        expect(
          (capturedCall!.arguments as Map)['descriptor'],
          equals(malformedDescriptor),
        );
      },
    );

    test('start handles defensive non-map response', () async {
      const channel = MethodChannel(
        'test_dynamic_descriptor_spatial_smoke_non_map',
      );
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return 'unexpected_non_map';
      });

      final startResult =
          await VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.startAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip()
                    .toMap(),
            channel: channel,
          );

      expect(startResult.textureId, equals(-1));
      expect(startResult.width, equals(128));
      expect(startResult.height, equals(128));
    });

    test('dispose invokes with textureId and returns release status', () async {
      MethodCall? capturedCall;
      const channel = MethodChannel(
        'test_dynamic_descriptor_spatial_smoke_dispose',
      );
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
          await VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.disposeAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
            textureId: 77,
            channel: channel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals(
          'disposeAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke',
        ),
      );
      expect(capturedCall!.arguments, equals({'textureId': 77}));
      expect(released, isTrue);
    });

    test('dispose handles defensive non-map response', () async {
      const channel = MethodChannel(
        'test_dynamic_descriptor_spatial_smoke_dispose_non_map',
      );
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return null;
      });

      final released =
          await VGMultiCamDynamicDescriptorSpatialRenderSmokeReport.disposeAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
            textureId: 77,
            channel: channel,
          );

      expect(released, isFalse);
    });
  });
}
